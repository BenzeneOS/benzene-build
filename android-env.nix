# Standalone nix expression for the Android FHS environment
# Use with: nix-build android-env.nix
{
  pkgs ? import <nixpkgs> { config.allowUnfree = true; },
}:

pkgs.buildFHSEnv {
  name = "android-env";
  targetPkgs =
    pkgs: with pkgs; [
      git
      gitRepo
      gnupg
      curl
      procps
      openssl
      gnumake
      nettools
      androidenv.androidPkgs.platform-tools
      schedtool
      util-linux
      m4
      gperf
      perl
      zip
      unzip
      bison
      flex
      lzop
      (python3.withPackages (
        ps: with ps; [
          protobuf
          lz4 # avbroot
        ]
      ))
      freetype
      fontconfig

      # adevtool
      nodejs
      yarn
      e2fsprogs
    ];

  multiPkgs =
    pkgs: with pkgs; [
      zlib
      ncurses5
      freetype
      fontconfig
      signify
      inotify-tools
    ];

  runScript = "bash";

  profile =
    (import ./build-env-common.nix).commonProfile
    + /* sh */ ''
      export LD_LIBRARY_PATH=/usr/lib:/usr/lib32
      echo "Android build environment loaded"
      echo "Run 'source build/envsetup.sh' to initialize the Android build system"
    '';
}

