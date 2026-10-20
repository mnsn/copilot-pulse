#!/bin/bash
# Signs a packaged release for Sparkle, the in-app updater: writes appcast.xml next to the zip, with
# the zip's EdDSA signature and the CHANGELOG.md section as release notes, and signs the appcast.
#   scripts/make-appcast.sh <release dir> <download URL prefix> < private-key
# Run scripts/package.sh first; its output is in build/release. The download URL prefix is where the
# zip will be, such as https://github.com/mnsn/copilot-pulse/releases/download/v0.2.0/.
# The private EdDSA key comes on standard input, in the form `generate_keys -x` exports it. Never
# pass it as an argument. scripts/verify-appcast.swift checks the result with the public key.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <release dir> <download URL prefix> < private-key" >&2
    exit 2
fi
RELEASE="$1"
PREFIX="$2"
ZIP="Copilot-Pulse.zip"
TOOLS=".build/artifacts/sparkle/Sparkle/bin"

KEY=""
IFS= read -r KEY || true
if [[ -z "$KEY" ]]; then
    echo "No private EdDSA key on standard input." >&2
    exit 1
fi
if [[ ! -x "$TOOLS/generate_appcast" ]]; then
    swift package resolve
fi

# generate_appcast reads every archive in a folder, and release notes named after each one.
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp "$RELEASE/$ZIP" "$STAGING/$ZIP"
cp "$RELEASE/changes.md" "$STAGING/${ZIP%.zip}.md"

# The app sets SURequireSignedFeed, so this signs the appcast as well as the zip. No delta updates.
printf '%s\n' "$KEY" | "$TOOLS/generate_appcast" --ed-key-file - \
    --download-url-prefix "$PREFIX" --embed-release-notes --maximum-deltas 0 \
    -o "$RELEASE/appcast.xml" "$STAGING" | tee "$STAGING/output.txt"

# generate_appcast only warns when the key doesn't match the app's SUPublicEDKey, and then leaves
# the zip unsigned.
if grep -q -i -e "warning" -e "error" "$STAGING/output.txt" ||
    ! grep -q 'sparkle:edSignature=' "$RELEASE/appcast.xml" ||
    ! grep -q '<!-- sparkle-signatures:' "$RELEASE/appcast.xml"; then
    echo "The appcast or the zip isn't signed." >&2
    rm -f "$RELEASE/appcast.xml"
    exit 1
fi
echo "Signed $RELEASE/$ZIP and wrote $RELEASE/appcast.xml"
