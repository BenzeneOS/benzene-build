if ($env.DEVICE == lynx and $env.TYPE == userdebug) or ($env.DEVICE == sdk_phone64_x86_64 and $env.TYPE == eng) {
  print "Disabling dexpreopt for ($env.DEVICE)-($env.TYPE)"
  $env.WITH_DEXPREOPT = "false"
}

$env.OUT_DIR = $"out-($env.DEVICE)"

$"source build/envsetup.sh && lunch ($env.DEVICE)-cur-($env.TYPE)" | capture-foreign-env --shell /bin/bash | load-env
print $"Lunched ($env.DEVICE)-cur-($env.TYPE) [OUT_DIR=($env.OUT_DIR)]"

def lunch-device [] {
  if $env.DEVICE == "lynx" and $env.TYPE == "userdebug" {
    $env.WITH_DEXPREOPT = "false"
  } else {
    $env.WITH_DEXPREOPT = "true"
  }
  $env.OUT_DIR = $"out-($env.DEVICE)"
  $"source build/envsetup.sh && lunch ($env.DEVICE)-cur-($env.TYPE)" | capture-foreign-env --shell /bin/bash | load-env
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
def gen-release [build_number?: string] {
  let bn = if ($build_number == null) { $env.BUILD_NUMBER } else { $build_number }
  script/generate-release.sh $env.DEVICE $bn
}
def build-all [build_number?: string] {
  let bn = if ($build_number == null) { $env.BUILD_NUMBER } else { $build_number }
  m vendorbootimage vendorkernelbootimage target-files-package
  m otatools-package
  script/finalize.sh
  script/generate-release.sh $env.DEVICE $bn
  root-ota $bn
}

def root-ota [build_number?: string, --magisk-apk: string = "Magisk.apk"] {
  let device = $env.DEVICE

  if ($device | str starts-with "sdk_phone") or ($device == "emu64x") {
    print "Skipping root-ota for emulator (already has root in eng builds)"
    return
  }

  let bn = if ($build_number == null) { $env.BUILD_NUMBER } else { $build_number }
  let release_dir = $"releases/($bn)/release-($device)-($bn)"
  let input_ota = $"($release_dir)/($device)-ota_update-($bn).zip"
  let output_ota = $"($release_dir)/($device)-ota_update-($bn)-magisk.zip"

  if not ($input_ota | path exists) {
    print $"Error: OTA not found at ($input_ota)"
    return
  }

  print $"Patching ($device) OTA with Magisk..."
  (avbroot ota patch
    --input $input_ota
    --magisk $magisk_apk
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

def sideload [build_number?: string, --rooted = true] {
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

  let bn = if ($build_number == null) { $env.BUILD_NUMBER } else { $build_number }
  let release_dir = $"releases/($bn)/release-($device)-($bn)"
  let ota_file = if $rooted {
    $"($release_dir)/($device)-ota_update-($bn)-magisk.zip"
  } else {
    $"($release_dir)/($device)-ota_update-($bn).zip"
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
