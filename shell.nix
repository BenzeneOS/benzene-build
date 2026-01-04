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
        # adevtool
        nodejs
        yarn
        e2fsprogs
        (pkgs.python3.withPackages (pkgs: [ pkgs.protobuf ]))

        # X11/Wayland for emulator
        xorg.libX11
        xorg.libXext
        xorg.libXrender
        xorg.libXtst
        xorg.libXi
        xorg.libXcursor
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
        xorg.libxcb
        xorg.libxkbfile
        libbsd
        xorg.xcbutilcursor
        xorg.xcbutilimage
        xorg.xcbutilkeysyms
        xorg.xcbutilrenderutil
        xorg.xcbutilwm
        xorg.libSM
        xorg.libICE
        xorg.libX11
        xorg.libxcb
        xorg.xcbutil
        xorg.libXrandr
        xorg.libXfixes
        libxkbcommon

        # Development tools
        jdk21
        kotlin
        gradle

        # Language servers
        kotlin-language-server
        jdt-language-server
        clang-tools
        rust-analyzer
        nodePackages.typescript-language-server

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
      exec ${pkgs.nushell}/bin/nu -e "use ${pkgs.nu_scripts}/share/nu_scripts/modules/capture-foreign-env; source graphene-env.nu"
    '';

    profile = ''
      export ALLOW_NINJA_ENV=true
      export LD_LIBRARY_PATH=/usr/lib:/usr/lib32
      source build/envsetup.sh 2>/dev/null
      export OFFICIAL_BUILD=true
      export QT_QPA_PLATFORM=xcb
      unset LD_PRELOAD

      export JAVA_HOME="${pkgs.jdk17}"

      export USE_CCACHE=1
      export CCACHE_DIR="$XDG_CACHE_HOME/sccache-aosp"
      export CCACHE_EXEC="$(which sccache)"
      export SCCACHE_DIR="$XDG_CACHE_HOME/sccache-aosp"
      export SCCACHE_CACHE_SIZE="100G"
      sccache --start-server 2>/dev/null

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
