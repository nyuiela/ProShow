#!/bin/zsh
# Optionally copy the just-built Debug app to a stable path so TCC (camera / screen / mic)
# grants survive rebuilds.
#
# Off by default. A build never touches /Applications/ProShow.app unless you opt in:
#   PROSHOW_PIN_DEBUG_APP=1                  pin to /Applications/ProShow.app
#   PROSHOW_STABLE_APP=/some/other/Path.app  pin there instead (an explicit path is the opt-in;
#                                            a path under /Applications still needs PROSHOW_PIN_DEBUG_APP=1)
# Even when opted in, the existing app is moved to ~/.Trash (never deleted), and a signed
# Release build (team-signed, no get-task-allow) is never replaced.
set -euo pipefail

SRC="${1:-}"
DEST="${PROSHOW_STABLE_APP:-/Applications/ProShow.app}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

skip() { echo "pin_debug_app: skipped ($1)"; exit 0; }

if [[ "${CONFIGURATION:-Debug}" == "Release" ]]; then
    skip "Release build"
fi
if [[ -z "$SRC" || ! -d "$SRC" ]]; then
    echo "pin_debug_app: missing built app: ${SRC:-<empty>}" >&2
    exit 1
fi

case "${DEST:A}" in
    /Applications/*)
        [[ "${PROSHOW_PIN_DEBUG_APP:-0}" == "1" ]] || skip "set PROSHOW_PIN_DEBUG_APP=1 to pin $DEST"
        ;;
    *)
        [[ -n "${PROSHOW_STABLE_APP:-}" || "${PROSHOW_PIN_DEBUG_APP:-0}" == "1" ]] || skip "no destination opted in"
        ;;
esac

if [[ -d "$DEST" ]]; then
    # A signed Release install: valid signature with a team and no get-task-allow. Leave it alone.
    # Capture first: with pipefail, `codesign | grep -q` can fail on SIGPIPE and hide a Release app.
    sig_info="$(codesign -dv "$DEST" 2>&1 || true)"
    entitlements="$(codesign -d --entitlements - "$DEST" 2>/dev/null || true)"
    if codesign --verify --strict "$DEST" 2>/dev/null \
        && [[ "$sig_info" == *$'\n'TeamIdentifier=[A-Z0-9]* && "$sig_info" != *TeamIdentifier=not\ set* ]] \
        && [[ "$entitlements" != *get-task-allow* ]]; then
        echo "pin_debug_app: refusing: $DEST is a signed Release build; not replacing it" >&2
        exit 0
    fi
    stamp="$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$HOME/.Trash"
    mv "$DEST" "$HOME/.Trash/$(basename "$DEST" .app)-pinned-$stamp.app"
fi

mkdir -p "$(dirname "$DEST")"
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
