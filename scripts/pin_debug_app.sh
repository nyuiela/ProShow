#!/bin/zsh
# Copy the just-built Debug app to /Applications/ProShow.app so TCC (camera /
# screen / mic) stays granted across Xcode Run and `just start`.
set -euo pipefail

SRC="${1:-}"
DEST="${PROSHOW_STABLE_APP:-/Applications/ProShow.app}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ -z "$SRC" || ! -d "$SRC" ]]; then
    echo "pin_debug_app: missing built app: ${SRC:-<empty>}" >&2
    exit 1
fi

if [[ "${CONFIGURATION:-Debug}" == "Release" ]]; then
    echo "pin_debug_app: skipping Release"
    exit 0
fi

mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
ditto "$SRC" "$DEST"

if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$DEST"
    # Drop leftover DerivedData / SYMROOT copies so Launch Services cannot
    # revive an older ProShow.app after the next Run.
    for stale in \
        "$PWD/build/DerivedData/Build/Products/Debug/ProShow.app" \
        "$PWD/build/Debug/ProShow.app" \
        "$PWD/build/Release/ProShow.app" \
        "$HOME/Applications/ProShow.app"
    do
        if [[ -d "$stale" && "$stale" != "$DEST" ]]; then
            "$LSREGISTER" -u "$stale" 2>/dev/null || true
        fi
    done
    if [[ -d "$HOME/Library/Developer/Xcode/DerivedData" ]]; then
        find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 4 -name "ProShow.app" -type d 2>/dev/null \
            | while read -r stale; do
                if [[ "$stale" != "$DEST" ]]; then
                    "$LSREGISTER" -u "$stale" 2>/dev/null || true
                fi
            done
    fi
fi

echo "Pinned ProShow → $DEST"
