# eng builds disable R8 automatically for modules with d8_on_eng: true

$"source build/envsetup.sh && lunch ($env.DEVICE)-cur-($env.TYPE)" | capture-foreign-env --shell /bin/bash | load-env
print $"Lunched ($env.DEVICE)-cur-($env.TYPE)"

def lunch-device [] {
  $"source build/envsetup.sh && lunch ($env.DEVICE)-cur-($env.TYPE)" | capture-foreign-env --shell /bin/bash | load-env
  print $"Re-lunched ($env.DEVICE)-cur-($env.TYPE)"
}

def setup-adevtool [] { yarn --cwd vendor/adevtool/ install }
def gen-vendor [] { vendor/adevtool/bin/run generate-all $"--devices=($env.DEVICE)" }
def gen-compile-commands [] {
  print "Generating compile-commands.json for clangd..."
  bash -c $"source build/envsetup.sh && lunch ($env.DEVICE)-cur-($env.TYPE) && m out/soong/development/ide/compdb/compile_commands.json"
  print "Done! Symlinking to project root..."
  ln -sf out/soong/development/ide/compdb/compile_commands.json compile-commands.json
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
}
