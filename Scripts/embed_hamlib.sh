#!/bin/sh
# Copies Homebrew's libhamlib (plus any non-system dylibs it depends on, e.g.
# libusb) into the app's Frameworks folder, rewrites their install names so
# they load from there, and code signs them.
#
# At runtime HamlibBridge.c dlopen()s this embedded copy alongside any
# externally installed Hamlib and uses whichever is newest.
set -eu

HAMLIB_LIB="${HAMLIB_LIB:-/opt/homebrew/opt/hamlib/lib/libhamlib.4.dylib}"
if [ ! -f "$HAMLIB_LIB" ] && [ -f /usr/local/opt/hamlib/lib/libhamlib.4.dylib ]; then
    HAMLIB_LIB=/usr/local/opt/hamlib/lib/libhamlib.4.dylib
fi
if [ ! -f "$HAMLIB_LIB" ]; then
    echo "error: libhamlib.4.dylib not found; install it with 'brew install hamlib'" >&2
    exit 1
fi

DEST="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
mkdir -p "$DEST"

# Non-system dylibs a library links against (skips /usr/lib, /System and
# its own install name).
external_deps() {
    otool -L "$1" | tail -n +2 | awk '{print $1}' \
        | grep -v -e '^/usr/lib/' -e '^/System/' -e '^@' \
        | grep -v -x "$(otool -D "$1" | tail -n 1)" || true
}

# Copies a dylib into DEST, then recursively does the same for its
# external dependencies, pointing each reference at @loader_path.
embed() {
    local src="$1"
    local name="$(basename "$src")"
    local dst="$DEST/$name"
    local deps="$(external_deps "$src")"
    local dep

    cp -f "$src" "$dst"
    chmod u+w "$dst"
    install_name_tool -id "@rpath/$name" "$dst" 2>/dev/null
    for dep in $deps; do
        install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$dst" 2>/dev/null
    done

    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
        --options runtime --timestamp=none "$dst"

    for dep in $deps; do
        embed "$dep"
    done
}

embed "$HAMLIB_LIB"
