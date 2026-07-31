#!/usr/bin/env bash
# Push arbitrary files into /system on a rooted userdebug device.
#
#   live    bind-mount over an existing path. Takes effect immediately, gone on reboot.
#   persist write through adb remount's overlay. Survives reboot. Needs verity off
#           once, via `adb disable-verity && adb reboot`.
#
# persist used to stage into a Magisk module because Magisk magic-mounts /system
# and collides with remount's overlay at boot. With Magisk gone that collision
# does not exist, so remount is usable directly.
set -euo pipefail

STAGE=/data/adb/.pushsys
DEFAULT_KEYS=$HOME/projects/grapheneos/keys/cheetah
DEV="${ANDROID_SERIAL:-}"
adb_() { if [ -n "$DEV" ]; then adb -s "$DEV" "$@"; else adb "$@"; fi; }
sh_() { adb_ shell "$*"; }

# Magisk's `su` lands in u:r:magisk:s0, which cannot write /data/adb. `adb root`
# gives the unconfined u:r:su:s0 that can. It is lost on every reboot, so re-run.
need_root() {
    case "$(adb_ shell id 2>/dev/null)" in
    *uid=0*) return 0 ;;
    esac
    adb_ root >/dev/null 2>&1 || true
    sleep 4
    adb_ wait-for-device
    case "$(adb_ shell id 2>/dev/null)" in
    *uid=0*) ;;
    *) echo "error: could not get adb root" >&2; exit 1 ;;
    esac
}

usage() {
    cat >&2 <<EOF
usage: push-system.sh <app|live|persist|unlive|list|reset> [args]

  app     [built-apk]                  re-sign with the platform key and install now, no reboot
                                       (defaults to this build's PushCompat.apk)
  live    <local-file> <system-path>   bind-mount now, no reboot (path must exist)
  persist <local-file> <system-path>   write via adb remount overlay (survives reboot)
  unlive  <system-path>                undo a live bind-mount
  list                                 show what is staged and what is live
  reset                                clear live staging and reset the remount overlay

  <system-path> is absolute, e.g. /system/etc/permissions/foo.xml
  Set ANDROID_SERIAL to pin the device, KEYS to override $DEFAULT_KEYS.
EOF
    exit 2
}

case "${1:-}" in
app)
    # Soong signs with the AOSP testkey; the device runs release-signed images, so an
    # unsigned-over install dies with INSTALL_FAILED_UPDATE_INCOMPATIBLE. Re-sign with the
    # real platform key first. platform.pk8 is PBES2-encrypted, so apksigner will prompt.
    # Default to the current build's PushCompat, so `push-system.sh app` is enough.
    dev=${DEVICE:-cheetah}
    apk=${2:-${OUT:-$HOME/projects/grapheneos/out-$dev/target/product/$dev}/system/priv-app/PushCompat/PushCompat.apk}
    [ -f "$apk" ] || { echo "error: no such apk: $apk" >&2; exit 1; }
    echo "apk: $apk ($(stat -c%s "$apk") bytes, $(date -r "$apk" '+%H:%M'))"
    # A pm-installed update runs from /data/app, whose classloader namespace cannot
    # reach /system/lib64 — the Soong APK ships lib-less, so on-device (JNI) code
    # dies with UnsatisfiedLinkError unless the APK carries its own copy.
    stage=""
    if [ "$(basename "$apk")" = "PushCompat.apk" ]; then
        so=$(dirname "$apk")/../../lib64/libpushcompat_jni.so
        if [ -f "$so" ]; then
            zipalign=$HOME/projects/grapheneos/prebuilts/sdk/tools/linux/bin/zipalign
            command -v zip >/dev/null || { echo "error: zip not in PATH" >&2; exit 1; }
            [ -x "$zipalign" ] || { echo "error: missing $zipalign" >&2; exit 1; }
            stage=$(mktemp -d -t pushcompat-lib-XXXXXX)
            trap 'rm -rf "$stage"' EXIT INT TERM
            mkdir -p "$stage/lib/arm64-v8a"
            cp "$so" "$stage/lib/arm64-v8a/"
            cp "$apk" "$stage/embedded.apk"
            (cd "$stage" && zip -q -0 -X embedded.apk lib/arm64-v8a/libpushcompat_jni.so)
            "$zipalign" -f -P 16 4 "$stage/embedded.apk" "$stage/aligned.apk"
            apk=$stage/aligned.apk
            echo "  embedded libpushcompat_jni.so ($(stat -c%s "$so") bytes)"
        else
            echo "  WARNING: no libpushcompat_jni.so next to this build; on-device mode will break" >&2
        fi
    fi
    keys=${KEYS:-$DEFAULT_KEYS}
    for f in "$keys/platform.pk8" "$keys/platform.x509.pem"; do
        [ -f "$f" ] || { echo "error: missing $f (set KEYS=)" >&2; exit 1; }
    done
    need_root
    # GrapheneOS refuses sideloaded system-app updates unless this is set. persist., so once is enough.
    if [ "$(adb_ shell getprop persist.allow_unknown_system_app_updates | tr -d '\r')" != "1" ]; then
        echo "enabling persist.allow_unknown_system_app_updates"
        adb_ shell setprop persist.allow_unknown_system_app_updates 1
    fi
    # Development builds keep versionCode stable, so allow replacing the system
    # package with another build at that same version.
    if [ "$(adb_ shell getprop persist.disable_same_versionCode_sys_pkg_update_check | tr -d '\r')" != "1" ]; then
        echo "enabling persist.disable_same_versionCode_sys_pkg_update_check"
        adb_ shell setprop persist.disable_same_versionCode_sys_pkg_update_check 1
    fi
    signed=$(mktemp -t pushcompat-signed-XXXXXX.apk)
    # apksigner --key takes an UNENCRYPTED PKCS#8 DER and does not prompt: on an
    # encrypted key it dies with "Not an RSA, EC, or DSA private key". So decrypt
    # once with openssl (which does prompt) into a private temp file.
    keydir=$(mktemp -d -t pushcompat-key-XXXXXX)
    chmod 700 "$keydir"
    trap 'rm -f "$signed"; rm -rf "$keydir" ${stage:+"$stage"}' EXIT INT TERM
    echo "decrypting platform.pk8 — enter the key password:"
    openssl pkey -inform DER -in "$keys/platform.pk8" -outform DER \
        -out "$keydir/platform.pk8"
    # v4 signing emits <out>.idsig, which adb passes to the installer to set up
    # fs-verity. Updating a system package REQUIRES it: a plain streamed install
    # fails with "fs-verity not set up for system package update".
    echo "signing (v2/v3 + v4)"
    apksigner sign --key "$keydir/platform.pk8" --cert "$keys/platform.x509.pem" \
        --v4-signing-enabled true --out "$signed" "$apk"
    [ -f "$signed.idsig" ] || { echo "error: apksigner did not produce $signed.idsig" >&2; exit 1; }
    echo "  idsig: $(stat -c%s "$signed.idsig") bytes"
    trap 'rm -f "$signed" "$signed.idsig"; rm -rf "$keydir" ${stage:+"$stage"}' EXIT INT TERM

    # Keep this non-incremental: system packages reject incremental sessions. A
    # normal multi-file session preserves the adjacent idsig, letting PackageInstaller
    # enable fs-verity before accepting the system-package update.
    echo "installing (non-incremental APK + idsig)"
    adb_ install-multiple --no-incremental -r "$signed" "$signed.idsig"
    echo "== result =="
    adb_ shell dumpsys package com.benzeneos.pushcompat |
        grep -E 'codePath|versionCode|PRIVILEGED|CHANGE_DEVICE_IDLE_TEMP_WHITELIST: granted|c2dm.permission.SEND: granted' |
        sed 's/^ */  /'
    ;;
live)
    [ $# -eq 3 ] || usage
    local_file=$2 target=$3
    need_root
    sh_ "test -e '$target'" ||
        { echo "error: $target does not exist; bind-mount needs an existing file. Use 'persist'." >&2; exit 1; }
    name=$(echo "$target" | tr '/' '_')
    adb_ push "$local_file" /data/local/tmp/.pushsys >/dev/null
    sh_ "mkdir -p $STAGE &&
         cp /data/local/tmp/.pushsys $STAGE/'$name' &&
         chown 0:0 $STAGE/'$name' &&
         chmod 644 $STAGE/'$name' &&
         chcon u:object_r:system_file:s0 $STAGE/'$name' &&
         mount --bind $STAGE/'$name' '$target' &&
         touch $STAGE/.live &&
         grep -qxF '$target' $STAGE/.live || echo '$target' >> $STAGE/.live"
    echo "live: $target (active now, reverts on reboot)"
    ;;
persist)
    [ $# -eq 3 ] || usage
    local_file=$2 target=$3
    need_root
    case "$target" in
    /system/*) ;;
    *) echo "error: <system-path> must start with /system/" >&2; exit 1 ;;
    esac
    # Without Magisk there is no magic mount to collide with, so adb remount's
    # overlayfs is usable and survives reboot. It needs verity off once:
    #   adb disable-verity && adb reboot
    if ! adb_ remount >/dev/null 2>&1; then
        echo "error: adb remount failed. Run 'adb disable-verity && adb reboot' once, then retry." >&2
        exit 1
    fi
    adb_ push "$local_file" "$target" >/dev/null
    sh_ "chown 0:0 '$target' && chmod 644 '$target' && chcon u:object_r:system_file:s0 '$target'"
    echo "persisted: $target (survives reboot via remount overlay)"
    ;;
unlive)
    [ $# -eq 2 ] || usage
    need_root
    # Exactly ONE umount: bind mounts stack, and the layer underneath ours may be
    # Magisk's own magic mount. Peeling that exposes Magisk's 0-byte stub and the
    # file stays broken until the next boot.
    sh_ "umount '$2'"
    sh_ "if [ -f $STAGE/.live ]; then grep -vxF '$2' $STAGE/.live > $STAGE/.live.n || true; mv $STAGE/.live.n $STAGE/.live; fi"
    echo "unlive: $2 (removed one layer)"
    ;;
list)
    need_root
    echo "== remount overlay =="
    sh_ "awk '\$3==\"overlay\" && \$2 ~ /^\\/system/ {print \"  \" \$2 \"  [active]\"}' /proc/mounts | head -20 || true; grep -q ' overlay ' /proc/mounts || echo '  (none)'"
    echo "== live bind-mounts over /system =="
    sh_ "if [ -s $STAGE/.live ]; then while read -r t; do
             if awk -v t=\"\$t\" '\$2==t{f=1} END{exit !f}' /proc/mounts; then
                 echo \"  \$t  [mounted]\"; else echo \"  \$t  [stale]\"; fi
         done < $STAGE/.live; else echo '  (none)'; fi"
    ;;
reset)
    need_root
    sh_ "rm -rf $STAGE"
    adb_ remount -R >/dev/null 2>&1 || true
    echo "cleared live staging and reset the remount overlay (device will reboot)"
    ;;
*) usage ;;
esac
