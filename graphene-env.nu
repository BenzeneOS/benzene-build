# Stable BUILD_DATETIME (midnight today) to avoid unnecessary rebuilds when re-entering shell
def today-midnight [] { date now | format date "%Y-%m-%d" | into datetime | format date "%s" }

def --env setup-build-env [] {
  $env.OUT_DIR = $"out-($env.DEVICE)"
  $"source build/envsetup.sh && lunch ($env.DEVICE)-cur-($env.TYPE)" | capture-foreign-env --shell /bin/bash | load-env
  $env.BUILD_DATETIME = (today-midnight)
  $env.BUILD_NUMBER = (date now | format date "%Y%m%d00")
}

setup-build-env
print $"Lunched ($env.DEVICE)-cur-($env.TYPE) [OUT_DIR=($env.OUT_DIR)]"

def lunch-device [] {
  setup-build-env
  print $"Re-lunched ($env.DEVICE)-cur-($env.TYPE) [OUT_DIR=($env.OUT_DIR)]"
}

def setup-adevtool [] { yarn --cwd vendor/adevtool/ install }

def gen-vendor [] { vendor/adevtool/bin/run generate-all $"--devices=($env.DEVICE)" }

def gen-compile-commands [] {
  print "Generating compile-commands.json for clangd..."
  bash -c $"source build/envsetup.sh && lunch ($env.DEVICE)-cur-($env.TYPE) && m ($env.OUT_DIR)/soong/development/ide/compdb/compile_commands.json"
  print "Done! Symlinking to project root..."
  ln -sf $"($env.OUT_DIR)/soong/development/ide/compdb/compile_commands.json" compile-commands.json
  print "compile-commands.json ready for clangd!"
}

def build-vendor [] { m vendorbootimage vendorkernelbootimage target-files-package }

def build-ota [] { m otatools-package }

def finalize [] { script/finalize.sh }

def gen-release [] {
  script/generate-release.sh $env.DEVICE $env.BUILD_NUMBER
}

def build-all [] {
  m vendorbootimage vendorkernelbootimage target-files-package
  m otatools-package
  script/finalize.sh
  script/generate-release.sh $env.DEVICE $env.BUILD_NUMBER
  root-ota
}

def sign-ota [] {
  script/generate-release.sh $env.DEVICE $env.BUILD_NUMBER
}

def root-ota [] {
  let device = $env.DEVICE

  if ($device | str starts-with "sdk_phone") or ($device == "emu64x") {
    print "Skipping root-ota for emulator (already has root in eng builds)"
    return
  }

  let release_dir = $"releases/($env.BUILD_NUMBER)/release-($device)-($env.BUILD_NUMBER)"
  let input_ota = $"($release_dir)/($device)-ota_update-($env.BUILD_NUMBER).zip"
  let output_ota = $"($release_dir)/($device)-ota_update-($env.BUILD_NUMBER)-magisk.zip"

  if not ($input_ota | path exists) {
    print $"Error: OTA not found at ($input_ota)"
    return
  }

  print $"Patching ($device) OTA with Magisk..."
  (avbroot ota patch
    --input $input_ota
    --magisk "Magisk.apk"
    --magisk-preinit-device metadata
    --key-avb $"keys/($device)/avb.pem"
    --key-ota $"keys/($device)/releasekey.pem"
    --cert-ota $"keys/($device)/releasekey.x509.pem"
    --output $output_ota)

  print $"Rooted OTA created: ($output_ota)"
}

let DEVICE_SERIALS = {
  komodo: "47021FDAS004YA",
  lynx: "2A291JEHN03207",
}

let RELOAD_COMPONENTS = {
  # APKs in system_ext/priv-app
  Settings: { src: "system_ext/priv-app/Settings/Settings.apk", dest: "/system_ext/priv-app/Settings/", clear_oat: false },
  SystemUI: { src: "system_ext/priv-app/SystemUI/SystemUI.apk", dest: "/system_ext/priv-app/SystemUI/", clear_oat: true },
  Launcher3: { src: "system_ext/priv-app/Launcher3QuickStep/Launcher3QuickStep.apk", dest: "/system_ext/priv-app/Launcher3QuickStep/", clear_oat: true },

  # Framework JARs
  framework: { src: "system/framework/framework.jar", dest: "/system/framework/", clear_oat: false },
  services: { src: "system/framework/services.jar", dest: "/system/framework/", clear_oat: false },
}

# Ensure device is rooted and remounted for hot-reload
def adb-setup [serial: string] {
  # Check if already rooted by testing shell id
  let id_check = (do { ^adb -s $serial shell "id -u" } | complete)
  let is_root = ($id_check.stdout | str trim) == "0"

  if not $is_root {
    print "Enabling adb root..."
    let root_result = (do { ^adb -s $serial root } | complete)
    if ($root_result.exit_code != 0) {
      print $"Error: adb root failed - ($root_result.stderr)"
      return false
    }
    sleep 1sec
  }

  # Check if already remounted by trying to touch a file
  let touch_check = (do { ^adb -s $serial shell "touch /system/.remount_test && rm /system/.remount_test" } | complete)
  if ($touch_check.exit_code == 0) {
    # Already remounted
    return true
  }

  # Need to remount
  print "Remounting partitions..."
  let remount_result = (do { ^adb -s $serial remount } | complete)
  if ($remount_result.exit_code == 0) and not ($remount_result.stdout | str contains "failed") {
    return true
  }

  # Remount failed - need reboot cycle
  print "Remount failed (first boot?), rebooting to enable..."
  ^adb -s $serial reboot
  print "Waiting for device to reboot..."
  ^adb -s $serial wait-for-device
  sleep 5sec
  ^adb -s $serial root
  sleep 1sec
  let retry = (do { ^adb -s $serial remount } | complete)
  if ($retry.exit_code != 0) or ($retry.stdout | str contains "failed") {
    print $"Error: remount still failed - ($retry.stderr)"
    return false
  }

  return true
}

# Build and hot-reload components to device
def reload [...components: string] {
  if ($components | is-empty) {
    print "Usage: reload <component> [component...]"
    print $"Available: ($RELOAD_COMPONENTS | columns | str join ', ')"
    return
  }

  let device = $env.DEVICE
  let serial = ($DEVICE_SERIALS | get -o $device)
  if ($serial == null) {
    print $"Error: No serial for ($device). Add it to DEVICE_SERIALS."
    return
  }

  let product_out = $"($env.OUT_DIR)/target/product/($device)"

  # Validate all components exist in mapping
  for comp in $components {
    if not ($comp in ($RELOAD_COMPONENTS | columns)) {
      print $"Error: Unknown component '($comp)'"
      print $"Available: ($RELOAD_COMPONENTS | columns | str join ', ')"
      return
    }
  }

  # Build first
  print $"Building: ($components | str join ' ')"
  m ...$components

  # Setup device (root + remount) - skips if already done
  if not (adb-setup $serial) {
    return
  }

  # Push each component
  for comp in $components {
    let info = ($RELOAD_COMPONENTS | get $comp)
    let src = $"($product_out)/($info.src)"
    let dest = $info.dest

    if not ($src | path exists) {
      print $"Error: ($src) not found"
      return
    }

    if $info.clear_oat {
      print $"Clearing oat for ($comp)..."
      ^adb -s $serial shell $"rm -rf ($dest)oat"
    }

    print $"Pushing ($comp)..."
    ^adb -s $serial push $src $dest
  }

  print "Restarting system..."
  ^adb -s $serial shell "stop; start"
  print "Done"
}

# Quick flash via fastboot - much faster than sideload, skips signing
# --skip-boot: Skip boot images to preserve Magisk root (use when kernel didn't change)
# --only-system: Only flash system/vendor (fastest, for framework-only changes)
def quick-flash [--skip-boot = false, --only-system = false, --skip-reboot = false] {
  let device = $env.DEVICE
  let out_dir = $env.OUT_DIR
  let product_out = $"($out_dir)/target/product/($device)"

  if ($device | str starts-with "sdk_phone") or ($device == "emu64x") {
    print "Use emulator commands for emulator devices"
    return
  }

  let serial = ($DEVICE_SERIALS | get -o $device)
  if ($serial == null) {
    print $"Error: No known serial for device ($device). Add it to DEVICE_SERIALS."
    return
  }

  # Check if images exist
  let system_img = $"($product_out)/system.img"
  if not ($system_img | path exists) {
    print $"Error: system.img not found. Run 'm' first to build."
    return
  }

  # Get device into fastbootd
  print "Getting device into fastbootd mode..."
  let fb_devices = (fastboot devices | str trim)
  if ($fb_devices | is-empty) {
    print "Device not in fastboot, rebooting via adb..."
    adb -s $serial reboot bootloader
    sleep 3sec
  }

  print "Rebooting to fastbootd (userspace fastboot for dynamic partitions)..."
  fastboot -s $serial reboot fastboot
  sleep 3sec

  # Flash system partitions (always)
  print "Flashing system..."
  fastboot -s $serial flash system $"($product_out)/system.img"

  print "Flashing system_ext..."
  fastboot -s $serial flash system_ext $"($product_out)/system_ext.img"

  print "Flashing product..."
  fastboot -s $serial flash product $"($product_out)/product.img"

  print "Flashing vendor..."
  fastboot -s $serial flash vendor $"($product_out)/vendor.img"

  if not $only_system {
    print "Flashing system_dlkm..."
    fastboot -s $serial flash system_dlkm $"($product_out)/system_dlkm.img"

    print "Flashing vendor_dlkm..."
    fastboot -s $serial flash vendor_dlkm $"($product_out)/vendor_dlkm.img"

    if not $skip_boot {
      print "Flashing boot (will lose Magisk root)..."
      fastboot -s $serial flash boot $"($product_out)/boot.img"

      print "Flashing vendor_boot..."
      fastboot -s $serial flash vendor_boot $"($product_out)/vendor_boot.img"

      print "Flashing vendor_kernel_boot..."
      fastboot -s $serial flash vendor_kernel_boot $"($product_out)/vendor_kernel_boot.img"

      print "Flashing dtbo..."
      fastboot -s $serial flash dtbo $"($product_out)/dtbo.img"

      print "Flashing init_boot..."
      fastboot -s $serial flash init_boot $"($product_out)/init_boot.img"

      print "Flashing vbmeta..."
      fastboot -s $serial flash vbmeta $"($product_out)/vbmeta.img"
    } else {
      print "Skipping boot images (preserving Magisk root)"
      # Flash vbmeta with verification disabled to allow mismatched boot images
      print "Flashing vbmeta (with verification disabled for Magisk compatibility)..."
      fastboot -s $serial flash vbmeta --disable-verity --disable-verification $"($product_out)/vbmeta.img"
    }
  } else {
    print "Only-system mode: skipped dlkm and boot images"
    # Flash vbmeta with verification disabled to allow mismatched boot images
    print "Flashing vbmeta (with verification disabled for Magisk compatibility)..."
    fastboot -s $serial flash vbmeta --disable-verity --disable-verification $"($product_out)/vbmeta.img"
  }

  if not $skip_reboot {
    print "Rebooting..."
    fastboot -s $serial reboot
  }

  print "Done! Quick flash complete."
}

# Build and quick-flash in one command
# --skip-boot preserves Magisk (use for framework-only changes)
def build-flash [--skip-boot = true] {
  print "Building..."
  m
  print "Flashing..."
  quick-flash --skip-boot=$skip_boot
}

# Flash a factory image WITHOUT wiping user data
# Use --wipe to explicitly wipe data (e.g., for clean install)
def flash-factory [factory_dir: string, --wipe = false] {
  let device = $env.DEVICE
  let serial = ($DEVICE_SERIALS | get -o $device)

  if ($serial == null) {
    print $"Error: No known serial for device ($device)"
    return
  }

  # Check factory dir exists
  if not ($factory_dir | path exists) {
    print $"Error: Factory directory not found: ($factory_dir)"
    return
  }

  let bootloader = $"($factory_dir)/bootloader.img"
  let radio = $"($factory_dir)/radio.img"

  if not ($bootloader | path exists) {
    print $"Error: bootloader.img not found in ($factory_dir)"
    return
  }

  print "Flashing factory image (preserving user data)..."

  # Flash bootloader
  print "Flashing bootloader..."
  fastboot -s $serial flash bootloader $bootloader
  fastboot -s $serial reboot bootloader
  sleep 3sec

  # Flash radio if exists
  if ($radio | path exists) {
    print "Flashing radio..."
    fastboot -s $serial flash radio $radio
    fastboot -s $serial reboot bootloader
    sleep 3sec
  }

  # Reboot to fastbootd for dynamic partitions
  print "Rebooting to fastbootd..."
  fastboot -s $serial reboot fastboot
  sleep 4sec

  # Flash all images from image-*.zip (already extracted)
  let images = [
    "system.img", "system_ext.img", "product.img", "vendor.img",
    "system_dlkm.img", "vendor_dlkm.img", "boot.img", "init_boot.img",
    "vendor_boot.img", "vendor_kernel_boot.img", "dtbo.img", "vbmeta.img"
  ]

  for img in $images {
    let img_path = $"($factory_dir)/($img)"
    let partition = ($img | str replace ".img" "")
    if ($img_path | path exists) {
      print $"Flashing ($partition)..."
      fastboot -s $serial flash $partition $img_path
    }
  }

  # Only wipe if explicitly requested
  if $wipe {
    print "Wiping userdata and metadata (--wipe specified)..."
    fastboot -s $serial erase userdata
    fastboot -s $serial erase metadata
  } else {
    print "Preserving user data (use --wipe to erase)"
  }

  print "Rebooting..."
  fastboot -s $serial reboot

  print "Done! Factory image flashed."
}

def sideload [--rooted = true] {
  let device = $env.DEVICE

  if ($device | str starts-with "sdk_phone") or ($device == "emu64x") {
    print "Skipping sideload for emulator"
    return
  }

  let serial = ($DEVICE_SERIALS | get -o $device)
  if ($serial == null) {
    print $"Error: No known serial for device ($device). Add it to DEVICE_SERIALS."
    return
  }

  let connected_devices = (adb devices | lines | skip 1 | where { $in | str contains "device" } | each { $in | split row "\t" | first })
  if ($connected_devices | is-empty) {
    print "Error: No device connected"
    return
  }

  if not ($serial in $connected_devices) {
    print $"Error: Expected device not connected!"
    print $"  Expected: ($serial) \(($device))"
    print $"  Connected: ($connected_devices | str join ', ')"
    return
  }

  let release_dir = $"releases/($env.BUILD_NUMBER)/release-($device)-($env.BUILD_NUMBER)"
  let ota_file = if $rooted {
    $"($release_dir)/($device)-ota_update-($env.BUILD_NUMBER)-magisk.zip"
  } else {
    $"($release_dir)/($device)-ota_update-($env.BUILD_NUMBER).zip"
  }

  if not ($ota_file | path exists) {
    print $"Error: OTA not found at ($ota_file)"
    return
  }

  print $"Rebooting ($device) to recovery..."
  adb -s $serial reboot recovery

  print "Waiting for recovery mode (select 'Apply update from ADB' on device)..."
  sleep 5sec

  mut ready = false
  for _ in 1..30 {
    let status = (adb devices | str contains "sideload")
    if $status {
      $ready = true
      break
    }
    sleep 2sec
  }

  if not $ready {
    print "Error: Device not in sideload mode. Select 'Apply update from ADB' on device."
    return
  }

  print $"Sideloading ($ota_file)..."
  adb -s $serial sideload $ota_file

  print "Done! Device will reboot automatically."
}
