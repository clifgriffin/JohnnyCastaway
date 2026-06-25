#!/bin/bash
# build-saver.sh
#
# Build the JohnnyScreenSaver.saver bundle.
#
# Steps:
#   1. swift build -c release  (produces libJohnnyScreenSaver.dylib)
#   2. Assemble + sign JohnnyScreenSaver.saver in a temp staging dir,
#      then publish the finished bundle to ./build/
#   3. Optionally install to ~/Library/Screen Savers/ and reload
#
# Why stage in $TMPDIR: when the repo lives under an iCloud-synced folder
# (e.g. ~/Documents), the file provider re-applies com.apple.FinderInfo to
# freshly-created files faster than `xattr -cr` can strip it, so `codesign`
# aborts with "resource fork, Finder information, or similar detritus not
# allowed". $TMPDIR is never synced, so assembling and signing there
# sidesteps the race entirely; only the finished, sealed bundle is copied
# back into the (possibly synced) tree.
#
# Flags:
#   --debug     Build configuration debug (default: release)
#   --install   Copy to ~/Library/Screen Savers/ after building
#   --reload    With --install, prompt SystemSettings to reload
#
# Output: ./build/JohnnyScreenSaver.saver

set -euo pipefail

CONFIG="release"
INSTALL=0
RELOAD=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)   CONFIG="debug";   shift ;;
        --install) INSTALL=1;        shift ;;
        --reload)  RELOAD=1;         shift ;;
        *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac
done

# Resolve script-dir-relative paths so the script works from any CWD.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(dirname "$SCRIPT_DIR")"     # Apps/JohnnyScreenSaver
BUILD_DIR="$PKG_DIR/build"
SAVER_NAME="JohnnyScreenSaver"

# Assemble + sign in a temp dir that no file provider syncs (see header).
STAGE_DIR="$(mktemp -d -t johnny-saver)"
trap 'rm -rf "$STAGE_DIR"' EXIT
SAVER_BUNDLE="$STAGE_DIR/$SAVER_NAME.saver"

echo "==> Building $SAVER_NAME ($CONFIG)…"
cd "$PKG_DIR"
swift build -c "$CONFIG"

DYLIB="$PKG_DIR/.build/$CONFIG/lib${SAVER_NAME}.dylib"
if [[ ! -f "$DYLIB" ]]; then
    echo "Build failed: $DYLIB not found" >&2
    exit 1
fi

echo "==> Assembling bundle…"
mkdir -p "$SAVER_BUNDLE/Contents/MacOS"
mkdir -p "$SAVER_BUNDLE/Contents/Resources"

# The Mach-O executable, named to match CFBundleExecutable in Info.plist.
cp "$DYLIB" "$SAVER_BUNDLE/Contents/MacOS/$SAVER_NAME"

# Info.plist
cp "$PKG_DIR/Resources/Info.plist" "$SAVER_BUNDLE/Contents/Info.plist"

# Renderer's compiled Metal library, if present.
METALLIB_CANDIDATES=(
    "$PKG_DIR/.build/$CONFIG/JohnnyMetalRenderer_JohnnyMetalRenderer.bundle/Contents/Resources/default.metallib"
    "$PKG_DIR/.build/$CONFIG/JohnnyMetalRenderer_JohnnyMetalRenderer.bundle/default.metallib"
)
for cand in "${METALLIB_CANDIDATES[@]}"; do
    if [[ -f "$cand" ]]; then
        cp "$cand" "$SAVER_BUNDLE/Contents/Resources/"
        echo "    metallib: $cand"
        break
    fi
done

# Sanity: require the principal class to be present in the binary.
# Capture nm's output first rather than piping into `grep -q`: under
# `set -o pipefail`, grep -q closing the pipe early sends SIGPIPE to nm,
# which trips the pipeline and yields a false negative.  Match with -F
# because the symbol contains a literal '$' (a regex end-of-line anchor).
saver_syms="$(nm "$SAVER_BUNDLE/Contents/MacOS/$SAVER_NAME" 2>/dev/null || true)"
if ! grep -qF '_OBJC_CLASS_$_JohnnyScreenSaverView' <<<"$saver_syms"; then
    echo "WARNING: principal class _OBJC_CLASS_\$_JohnnyScreenSaverView not found" >&2
    echo "  legacyScreenSaver may fail to instantiate the view." >&2
fi

echo "==> Signing bundle (ad-hoc)…"
# Strip any Finder metadata / resource forks first — codesign refuses to
# seal a bundle that has them.  Staging in $TMPDIR means nothing should
# re-add them, but clear once more for belt-and-braces.  Re-sign the whole
# bundle so that:
#   • The identifier becomes nz.petesmith.JohnnyScreenSaver (from Info.plist)
#   • Info.plist is bound into the CodeDirectory
#   • Sealed Resources are created
# Without this step the linker leaves only an adhoc,linker-signed stub on
# the Mach-O, which does NOT bind Info.plist — System Settings never matches
# the bundle to its configure-sheet entry.
xattr -cr "$SAVER_BUNDLE"
codesign --force --deep --sign - "$SAVER_BUNDLE"
codesign --verify --verbose "$SAVER_BUNDLE"

echo "==> Publishing to ./build…"
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_DIR/$SAVER_NAME.saver"
cp -R "$SAVER_BUNDLE" "$BUILD_DIR/"
# Best-effort: the file provider may re-taint this copy in a synced tree;
# the seal still verifies, but keep the published artifact tidy.
xattr -cr "$BUILD_DIR/$SAVER_NAME.saver" 2>/dev/null || true

echo "==> Built: $BUILD_DIR/$SAVER_NAME.saver"

if [[ $INSTALL -eq 1 ]]; then
    INSTALL_DIR="$HOME/Library/Screen Savers"
    mkdir -p "$INSTALL_DIR"
    rm -rf "$INSTALL_DIR/$SAVER_NAME.saver"
    # Install straight from the clean staging copy, not the build/ copy.
    cp -R "$SAVER_BUNDLE" "$INSTALL_DIR/"
    # Strip any xattrs cp -R may have added to the installed copy.
    xattr -cr "$INSTALL_DIR/$SAVER_NAME.saver" 2>/dev/null || true
    codesign --verify --verbose "$INSTALL_DIR/$SAVER_NAME.saver"
    echo "==> Installed: $INSTALL_DIR/$SAVER_NAME.saver"

    if [[ $RELOAD -eq 1 ]]; then
        # Kill the legacyScreenSaver process so System Settings re-loads
        # the saver fresh on next preview/activation.
        killall legacyScreenSaver 2>/dev/null || true
        echo "==> Killed legacyScreenSaver (will respawn on demand)"
    fi
fi
