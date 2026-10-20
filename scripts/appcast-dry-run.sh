#!/bin/bash
# A dry run of how a release signs its update, with a throwaway key instead of the real one, so that
# a broken release pipeline shows up before a tag is pushed. Run it after scripts/package.sh; CI does.
# It signs a copy of the packaged app that trusts the throwaway key, with scripts/make-appcast.sh,
# then checks the result with scripts/verify-appcast.swift and Sparkle's sign_update, and checks that
# the verifier rejects another key, a changed appcast and a changed zip.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Copilot Pulse.app"
ZIP="Copilot-Pulse.zip"
PREFIX="https://github.com/mnsn/copilot-pulse/releases/download/v0.0.0-dry-run/"
TOOLS=".build/artifacts/sparkle/Sparkle/bin"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
REAL_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A throwaway key: a random seed, as generate_keys exports it, and its public key.
(umask 077 && head -c 32 /dev/urandom | base64 > "$WORK/private-key")
PUBLIC_KEY="$(swift - "$WORK/private-key" <<'SWIFT'
import CryptoKit
import Foundation
let seed = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: seed.trimmingCharacters(in: .whitespacesAndNewlines))!)
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
)"

# The packaged app, trusting the throwaway key, zipped the way scripts/package.sh zips it.
mkdir "$WORK/release"
ditto "$APP" "$WORK/Copilot Pulse.app"
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $PUBLIC_KEY" "$WORK/Copilot Pulse.app/Contents/Info.plist"
codesign --force --sign - "$WORK/Copilot Pulse.app"
ditto -c -k --sequesterRsrc --keepParent "$WORK/Copilot Pulse.app" "$WORK/release/$ZIP"
cp build/release/changes.md "$WORK/release/changes.md"

./scripts/make-appcast.sh "$WORK/release" "$PREFIX" < "$WORK/private-key"

swiftc -O scripts/verify-appcast.swift -o "$WORK/verify-appcast"
verify() { "$WORK/verify-appcast" "$1" "$2" "$PREFIX" "$3" "$VERSION"; }
APPCAST="$WORK/release/appcast.xml"
verify "$APPCAST" "$WORK/release/$ZIP" "$PUBLIC_KEY"
"$TOOLS/sign_update" --verify --ed-key-file - "$APPCAST" < "$WORK/private-key"
SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$APPCAST")"
"$TOOLS/sign_update" --verify --ed-key-file - "$WORK/release/$ZIP" "$SIGNATURE" < "$WORK/private-key"

sed 's#<title>#<title>Changed #' "$APPCAST" > "$WORK/changed.xml"
cp "$WORK/release/$ZIP" "$WORK/$ZIP"
printf 'A' | dd of="$WORK/$ZIP" bs=1 seek=4096 conv=notrunc 2>/dev/null
if cmp -s "$WORK/release/$ZIP" "$WORK/$ZIP"; then
    printf 'B' | dd of="$WORK/$ZIP" bs=1 seek=4096 conv=notrunc 2>/dev/null
fi
expect_rejected() {
    if verify "$2" "$3" "$4" 2>/dev/null; then
        echo "verify-appcast.swift accepted $1." >&2
        exit 1
    fi
}
expect_rejected "another key" "$APPCAST" "$WORK/release/$ZIP" "$REAL_KEY"
expect_rejected "a changed appcast" "$WORK/changed.xml" "$WORK/release/$ZIP" "$PUBLIC_KEY"
expect_rejected "a changed zip" "$APPCAST" "$WORK/$ZIP" "$PUBLIC_KEY"
echo "Dry run passed: a release signs and verifies its update and appcast."
