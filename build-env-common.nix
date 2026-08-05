{
  commonProfile = /* sh */ ''
    _top="$PWD"
    while [ ! -d "$_top/.repo" ] && [ "$_top" != / ]; do
      _top="$(dirname "$_top")"
    done
    if [ -d "$_top/.repo" ]; then
      cd "$_top"
    else
      echo "Warning: no .repo above $PWD; run this from the source tree" >&2
    fi
    unset _top

    export ALLOW_NINJA_ENV=true
    export OFFICIAL_BUILD=true
    export ANDROID_BUILD_ENVIRONMENT_CONFIG=benzene-rbe
    export ANDROID_BUILD_ENVIRONMENT_CONFIG_DIR="."
    export USE_DEX2OAT_DEBUG=false
    export BUILD_DATETIME=''${BUILD_DATETIME:-$(date -d "today 00:00" +%s)}
    export BUILD_NUMBER=''${BUILD_NUMBER:-$(date +%Y%m%d00)}
    export SOONG_INCREMENTAL_ANALYSIS=true
    export SOONG_UI_TABLE_HEIGHT=''${SOONG_UI_TABLE_HEIGHT:-8}
    export NINJA_STATUS=''${NINJA_STATUS:-"[%p %f/%t %r run %l left] "}

    if [ ! -f "$ANDROID_BUILD_ENVIRONMENT_CONFIG_DIR/$ANDROID_BUILD_ENVIRONMENT_CONFIG.json" ]; then
      echo "Error: $ANDROID_BUILD_ENVIRONMENT_CONFIG.json not found in $PWD/$ANDROID_BUILD_ENVIRONMENT_CONFIG_DIR" >&2
      echo "soong skips a missing env config silently, so USE_RBE would be unset and" >&2
      echo "every C++ command string in the tree would change. Fix before building." >&2
    fi
  '';
}
