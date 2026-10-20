#!/bin/bash
# Checks a built "Copilot Pulse.app" before it ships: its signatures are valid, it has code for both
# Apple silicon and Intel, it embeds Sparkle (the updater) and loads it, it's set up for signed
# updates, and on this Mac it sorts the demo sessions into the expected groups.
#   scripts/check-app.sh [app]   (default: build/Copilot Pulse.app, relative to the repository)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/Copilot Pulse.app}"
BIN="$APP/Contents/MacOS/CopilotPulse"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
PLIST="$APP/Contents/Info.plist"

fail() {
    echo "$APP: $1" >&2
    exit 1
}
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null; }

# Every signature, and each nested one on its own so a failure names it. Ad hoc, and without the
# hardened runtime, whose library validation would refuse to load an ad-hoc signed Sparkle.
codesign --verify --deep --strict "$APP"
for code in "$FRAMEWORK/Versions/B/Autoupdate" "$FRAMEWORK/Versions/B/Updater.app" "$FRAMEWORK"; do
    codesign --verify --strict "$code" || fail "${code#"$APP/"} has an invalid signature."
done
if codesign -dv "$APP" 2>&1 | grep '^CodeDirectory.*flags=.*runtime' >/dev/null; then
    fail "is signed with the hardened runtime."
fi

# Sparkle, with its symlinks and without the XPC services, loaded through the app's Frameworks.
[[ -L "$FRAMEWORK/Versions/Current" && -L "$FRAMEWORK/Sparkle" ]] || fail "has no Sparkle.framework, or it lost its symlinks."
[[ ! -e "$FRAMEWORK/Versions/B/XPCServices" ]] || fail "still has Sparkle's XPC services."
[[ -f "$APP/Contents/Resources/Sparkle-LICENSE.txt" ]] || fail "doesn't include Sparkle's license."
otool -L "$BIN" | grep '@rpath/Sparkle.framework/' >/dev/null || fail "doesn't link Sparkle."
ARCHS="$(lipo -archs "$BIN")"
for arch in arm64 x86_64; do
    if [[ " $ARCHS " != *" $arch "* ]]; then
        fail "${BIN#"$APP/"} has no $arch code (only $ARCHS)."
    fi
    [[ " $(lipo -archs "$FRAMEWORK/Versions/B/Sparkle") " == *" $arch "* ]] || fail "Sparkle has no $arch code."
    otool -arch "$arch" -l "$BIN" | grep 'path @executable_path/../Frameworks ' >/dev/null ||
        fail "${BIN#"$APP/"} ($arch) has no @executable_path/../Frameworks rpath."
done

# Signed updates only, from the feed in the latest GitHub release; Sparkle compares CFBundleVersion.
[[ -n "$(plist SUFeedURL)" ]] || fail "has no SUFeedURL."
[[ "$(plist SUPublicEDKey | base64 -d 2>/dev/null | wc -c | tr -d ' ')" == 32 ]] || fail "has no valid SUPublicEDKey."
[[ "$(plist SURequireSignedFeed)" == true && "$(plist SUVerifyUpdateBeforeExtraction)" == true ]] ||
    fail "doesn't require signed updates and appcasts."
for key in SUEnableSystemProfiling SUEnableDownloaderService SUEnableInstallerLauncherService; do
    [[ -z "$(plist "$key")" ]] || fail "sets $key."
done
[[ "$(plist CFBundleVersion)" == "$(plist CFBundleShortVersionString)" ]] ||
    fail "has a CFBundleVersion that isn't its version."

"$BIN" --help >/dev/null || fail "doesn't run its command-line mode."
make -s demo-check PULSE="$BIN"
echo "Checked $APP: valid signatures, $ARCHS, Sparkle embedded, and it runs on this Mac ($(uname -m))."
