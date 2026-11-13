#!/bin/sh
# Container entrypoint: prepares the data and cache folders and the Wine prefix, then runs the
# server (or the command given to the container, with the same environment).
#
# The container may run as any uid:gid (compose `user:`), often one without an entry in
# /etc/passwd, so HOME and USER are set here instead of being looked up.
set -eu

fail() {
    echo "entrypoint: $*" >&2
    exit 1
}

data_dir="${LRRP_DATA_DIR:-/data}"
cache_dir="${LRRP_CACHE_DIR:-/cache}"
export WINEPREFIX="${LRRP_WINEPREFIX:-$data_dir/wine}"
export HOME="$data_dir/home"
export USER="${USER:-lrrp}"

for dir in "$data_dir" "$cache_dir" "$HOME"; do
    mkdir -p "$dir" 2>/dev/null || fail "cannot create $dir as uid $(id -u):$(id -g)"
    [ -w "$dir" ] || fail "$dir is not writable by uid $(id -u):$(id -g); fix the owner of the volume"
done

# Wine refuses a prefix that belongs to another user. This happens when the container ran as
# a different uid before.
if [ -e "$WINEPREFIX" ]; then
    owner="$(stat -c %u "$WINEPREFIX")"
    [ "$owner" = "$(id -u)" ] ||
        fail "the Wine prefix $WINEPREFIX belongs to uid $owner, but the container runs as" \
            "uid $(id -u); run it as uid $owner again, or remove the prefix (the converter" \
            "then has to be installed again)"
fi

if [ ! -f "$WINEPREFIX/system.reg" ]; then
    echo "entrypoint: creating the Wine prefix in $WINEPREFIX (first start, may take a minute)"
    # mscoree and mshtml are switched off for this run so that wineboot does not offer to install
    # Wine Mono and Wine Gecko in a dialog that nobody can see on the virtual display.
    # wineserver -w runs inside the same display and waits until the prefix is written.
    WINEDLLOVERRIDES="mscoree,mshtml=" xvfb-run -a sh -c 'wineboot -i && wineserver -w' ||
        fail "creating the Wine prefix failed (exit code $?)"
    [ -f "$WINEPREFIX/system.reg" ] || fail "wineboot did not create the Wine prefix in $WINEPREFIX"
fi

# Without a Vulkan device the converter aborts in vkd3d unless this empty marker file exists.
# Wine 8.0 names the user profile after $USER (set above); any other profile already in the
# prefix gets the marker too. It is checked at every start.
for profile in "$WINEPREFIX/drive_c/users/$USER" "$WINEPREFIX"/drive_c/users/*; do
    case "${profile##*/}" in
        Public | "*") continue ;;
    esac
    marker_dir="$profile/AppData/Roaming/Adobe/CameraRaw/GPU/Adobe DNG Converter"
    mkdir -p "$marker_dir"
    [ -e "$marker_dir/TempDisableGPU2" ] || : >"$marker_dir/TempDisableGPU2"
done

if [ "$#" -eq 0 ]; then
    set -- python -m lrrp
fi
exec "$@"
