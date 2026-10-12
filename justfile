# ProShow local recipes.
# Debug builds compile in build/DerivedData, then pin to
# /Applications/ProShow.app so TCC permissions survive every Run.

set shell := ["zsh", "-cu"]

project := "ProShow.xcodeproj"
scheme := "ProShow"
destination := "platform=macOS"
derived := "build/DerivedData"
debug_product := derived / "Build/Products/Debug/ProShow.app"
stable_app := "/Applications/ProShow.app"

# List recipes
default:
    @just --list

# Resolve Swift packages into the shared DerivedData
resolve:
    xcodebuild \
        -project {{project}} \
        -scheme {{scheme}} \
        -derivedDataPath {{derived}} \
        -resolvePackageDependencies

# Debug build, then pin /Applications/ProShow.app
build: resolve
    xcodebuild \
        -project {{project}} \
        -scheme {{scheme}} \
        -configuration Debug \
        -destination '{{destination}}' \
        -derivedDataPath {{derived}} \
        build
    ./scripts/pin_debug_app.sh "{{debug_product}}"

# Build, pin, and launch the stable Debug app
start: build
    #!/usr/bin/env zsh
    set -euo pipefail
    app="${PROSHOW_STABLE_APP:-/Applications/ProShow.app}"
    if [[ ! -d "$app" ]]; then
        echo "Stable app missing: $app" >&2
        exit 1
    fi
    osascript -e 'tell application "ProShow" to quit' >/dev/null 2>&1 || true
    pkill -x ProShow >/dev/null 2>&1 || true
    open -n "$app"

# Alias for start
run: start

# Quit a running ProShow instance
stop:
    -osascript -e 'tell application "ProShow" to quit'
    -pkill -x ProShow

# Unit tests
test: resolve
    xcodebuild test \
        -project {{project}} \
        -scheme {{scheme}} \
        -destination '{{destination}}' \
        -derivedDataPath {{derived}}

# Remove leftover SYMROOT products and this checkout's DerivedData
# Does not delete /Applications/ProShow.app — that path owns TCC grants.
clean:
    rm -rf build/Debug build/Release build/ProShow.build "{{derived}}"
    xcodebuild \
        -project {{project}} \
        -scheme {{scheme}} \
        -destination '{{destination}}' \
        -derivedDataPath {{derived}} \
        clean || true

# Open the Xcode project
xcode:
    open {{project}}

# Release DMG (skips notarization unless AC_NOTARY_PROFILE is set)
release:
    ./build_release.sh --skip-notarize

# Print the stable Debug app path (grant camera / screen / mic to this)
app-path:
    @printenv PROSHOW_STABLE_APP || echo /Applications/ProShow.app
