{
  pkgs ? import <nixpkgs> { config.allowUnfree = true; },
}:
let
  fhs = pkgs.buildFHSEnv {
    name = "android-env";

    targetPkgs =
      pkgs: with pkgs; [
        nushell
        nu_scripts
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
        nodejs
        yarn
        e2fsprogs

        # X11/Wayland for emulator
        libX11
        libXext
        libXrender
        libXtst
        libXi
        libXcursor
        libGL
        libpulseaudio
        libxkbcommon
        wayland
        libglvnd
        libpng
        nss
        nspr
        alsa-lib
        dbus
        systemd
        vulkan-loader
        expat
        libdrm
        libxcb
        libxkbfile
        libbsd
        xcbutilcursor
        xcbutilimage
        xcbutilkeysyms
        xcbutilrenderutil
        xcbutilwm
        libSM
        libICE
        xcbutil
        libXrandr
        libXfixes

        # Development tools
        jdk21
        kotlin
        gradle

        # Language servers
        kotlin-language-server
        jdt-language-server
        clang-tools
        rust-analyzer
        typescript-language-server

        ktlint
        google-java-format

        # Additional build tools
        sccache # Speed up rebuilds (better than ccache, supports Rust)
        ninja # Build system
        cmake
        pkg-config

        # Python LSP if needed
        python3Packages.python-lsp-server

        # Documentation tools
        doxygen
        graphviz
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

    # Bind host /etc entries needed by nushell config (atuin, nushell, direnv, etc.)
    extraBwrapArgs = [
      "--symlink"
      "/.host-etc/nushell"
      "/etc/nushell"
      "--symlink"
      "/.host-etc/atuin"
      "/etc/atuin"
    ];

    runScript = pkgs.writeScript "graphene-shell" ''
      #!${pkgs.bash}/bin/bash
      if [ -z "''${DEVICE:-}" ]; then
        echo "Error: the DEVICE env var must be set"
        echo "Usage: DEVICE=komodo nix-shell"
        exit 1
      fi
      export DEVICE="''${DEVICE}"
      export TYPE="''${TYPE:-userdebug}"
      export NU_LIB_DIRS="${pkgs.nu_scripts}/share/nu_scripts"
      NU_CONFIG_ARGS=""
      if [ -f /etc/nushell/config.nu ]; then
        NU_CONFIG_ARGS="--config /etc/nushell/config.nu"
      fi
      exec ${pkgs.nushell}/bin/nu $NU_CONFIG_ARGS -e "use ${pkgs.nu_scripts}/share/nu_scripts/modules/capture-foreign-env; source graphene-env.nu"
    '';

    profile = ''
      export ALLOW_NINJA_ENV=true
      source build/envsetup.sh 2>/dev/null
      export OFFICIAL_BUILD=true
      export QT_QPA_PLATFORM=xcb
      unset LD_PRELOAD

      export JAVA_HOME="${pkgs.jdk17}"

      export ANDROID_BUILD_ENVIRONMENT_CONFIG=benzene-rbe
      export ANDROID_BUILD_ENVIRONMENT_CONFIG_DIR="."

      echo "LSP servers available:"
      echo "  - kotlin-language-server (Kotlin)"
      echo "  - jdtls (Java)"
      echo "  - clangd (C/C++)"

      echo "GrapheneOS build environment loaded!"
      echo "Available shortcuts:"
      echo "  setup-adevtool          - Install adevtool dependencies"
      echo "  gen-vendor CODENAME     - Generate vendor files for device"
      echo "  lunch-device [DEVICE]   - Lunch device (default: komodo)"
      echo "  build-vendor            - Build vendor boot images"
      echo "  build-ota               - Build OTA tools package"
      echo "  finalize                - Copy build artifacts to releases"
      echo "  gen-release DEV BUILD   - Generate signed release build"
    '';
  };
in
pkgs.stdenv.mkDerivation {
  name = "android-env-shell";
  nativeBuildInputs = [ fhs ];
  shellHook = "exec android-env";
}
