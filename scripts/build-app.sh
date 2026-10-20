#!/bin/bash
# Builds "Copilot Pulse.app" into ./build, for this Mac's architecture.
#   --universal   builds for both Apple silicon and Intel instead (the release build).
#   --install     also copies it to ~/Applications and (re)launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Copilot Pulse"
EXECUTABLE="CopilotPulse"
APP="build/$APP_NAME.app"

UNIVERSAL=false
INSTALL=false
for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=true ;;
        --install) INSTALL=true ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

BUILD_FLAGS=(-c release)
if $UNIVERSAL; then
    BUILD_FLAGS+=(--arch arm64 --arch x86_64)
fi
swift build "${BUILD_FLAGS[@]}" --product "$EXECUTABLE"
BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"

# The build copies Sparkle.framework, the in-app updater, next to the executable.
SPARKLE=""
for candidate in "$BIN_DIR/Sparkle.framework" "$BIN_DIR/PackageFrameworks/Sparkle.framework"; do
    if [[ -d "$candidate" ]]; then
        SPARKLE="$candidate"
        break
    fi
done
if [[ -z "$SPARKLE" ]]; then
    echo "Sparkle.framework isn't in $BIN_DIR." >&2
    exit 1
fi
# Sparkle's license covers the code it bundles too. The app ships the copy in Resources.
SPARKLE_LICENSE=".build/artifacts/sparkle/Sparkle/LICENSE"
if ! cmp -s Resources/Sparkle-LICENSE.txt "$SPARKLE_LICENSE"; then
    echo "Resources/Sparkle-LICENSE.txt differs from $SPARKLE_LICENSE. Copy the new license over it." >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
if /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist >/dev/null 2>&1; then
    echo "Resources/Info.plist sets CFBundleVersion. Remove it: the build sets it to CFBundleShortVersionString." >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Sparkle offers an update when its CFBundleVersion is higher than the running app's, so it's the
# version itself (scripts/package.sh checks that each release's version is higher).
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
cp Resources/Sparkle-LICENSE.txt "$APP/Contents/Resources/Sparkle-LICENSE.txt"

# ditto keeps the framework's symlinks. A non-sandboxed app doesn't use Sparkle's XPC services, so
# leave them out: less code shipped, and less to attack.
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
ditto "$SPARKLE" "$FRAMEWORK"
rm -rf "$FRAMEWORK/XPCServices" "$FRAMEWORK/Versions/Current/XPCServices"

# Ad-hoc signatures, enough to run locally and to register as a login item, from the inside out.
# Sparkle's helpers keep the ad-hoc signatures they ship with, and the framework is signed again
# without the XPC services. No hardened runtime: its library validation would refuse to load an
# ad-hoc signed framework.
codesign --force --sign - --preserve-metadata=identifier,entitlements,flags,runtime "$FRAMEWORK"
codesign --force --sign - "$APP"
echo "Built $APP (version $VERSION, $(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE"))"

if $INSTALL; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"

    # Quit a running copy so the new build takes over.
    pids="$(pgrep -f "/$APP_NAME.app/Contents/MacOS/$EXECUTABLE" || true)"
    if [[ -n "$pids" ]]; then
        kill $pids 2>/dev/null || true
        for _ in {1..50}; do
            pgrep -f "/$APP_NAME.app/Contents/MacOS/$EXECUTABLE" >/dev/null || break
            sleep 0.1
        done
    fi

    rm -rf "$DEST/$APP_NAME.app"
    cp -R "$APP" "$DEST/"
    open "$DEST/$APP_NAME.app"
    echo "Installed and launched $DEST/$APP_NAME.app"
fi
