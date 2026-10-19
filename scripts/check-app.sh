#!/bin/bash
# Checks a built "Copilot Pulse.app" before it ships: its signature is valid, it has code for both
# Apple silicon and Intel, and on this Mac it sorts the demo sessions into the expected groups.
#   scripts/check-app.sh [app]   (default: build/Copilot Pulse.app, relative to the repository)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/Copilot Pulse.app}"
BIN="$APP/Contents/MacOS/CopilotPulse"

codesign --verify --deep --strict "$APP"
ARCHS="$(lipo -archs "$BIN")"
for arch in arm64 x86_64; do
    if [[ " $ARCHS " != *" $arch "* ]]; then
        echo "$BIN has no $arch code (only $ARCHS)." >&2
        exit 1
    fi
done
make -s demo-check PULSE="$BIN"
echo "Checked $APP: valid signature, $ARCHS, and it runs on this Mac ($(uname -m))."
