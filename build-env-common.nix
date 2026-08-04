{
  commonProfile = /* sh */ ''
    export ALLOW_NINJA_ENV=true
    export OFFICIAL_BUILD=true
    export ANDROID_BUILD_ENVIRONMENT_CONFIG=benzene-rbe
    export ANDROID_BUILD_ENVIRONMENT_CONFIG_DIR="."
    export BUILD_DATETIME=''${BUILD_DATETIME:-$(date -d "today 00:00" +%s)}
    export BUILD_NUMBER=''${BUILD_NUMBER:-$(date +%Y%m%d00)}
    export SOONG_INCREMENTAL_ANALYSIS=true
  '';
}
