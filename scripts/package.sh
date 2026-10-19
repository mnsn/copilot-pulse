#!/bin/bash
# Builds what a GitHub release ships, into build/release: a universal "Copilot Pulse.app", checked
# and zipped, the zip's SHA-256, and release notes from CHANGELOG.md.
#   scripts/package.sh [tag]   with a tag such as v0.1.0, fails unless it matches Info.plist.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Copilot Pulse.app"
OUT="build/release"
ZIP="Copilot-Pulse.zip"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
if [[ $# -gt 0 && "$1" != "v$VERSION" ]]; then
    echo "The tag $1 doesn't match the version in Resources/Info.plist ($VERSION)." >&2
    exit 1
fi
# The CHANGELOG.md section for this version, without its heading.
CHANGES="$(awk -v version="$VERSION" '
    /^## / { found = ($2 == version); started = 0; next }
    found && (started || NF) { started = 1; print }
' CHANGELOG.md)"
if [[ -z "$CHANGES" ]]; then
    echo "CHANGELOG.md has no section for $VERSION (a heading like \"## $VERSION - YYYY-MM-DD\")." >&2
    exit 1
fi

./scripts/build-app.sh --universal
./scripts/check-app.sh "$APP"

rm -rf "$OUT"
mkdir -p "$OUT"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$ZIP"
(cd "$OUT" && shasum -a 256 "$ZIP" > "$ZIP.sha256")
SHA256="$(cut -d ' ' -f 1 "$OUT/$ZIP.sha256")"

# GitHub shows every line break in release notes, so join the lines that wrap a paragraph or a list
# item.
unwrap() {
    awk '
        function flush() { if (text != "") print text; text = "" }
        /^[[:space:]]*```/ { flush(); fenced = !fenced; print; next }
        fenced || /^[[:space:]]*$/ || /^[#|]/ { flush(); print; next }
        ($0 " ") ~ /^[[:space:]]*([-*+>]|[0-9]+[.)])[[:space:]]/ { flush(); text = $0; next }
        text != "" { sub(/^[[:space:]]+/, ""); text = text " " $0; next }
        { text = $0 }
        END { flush() }
    '
}

unwrap > "$OUT/notes.md" <<EOF
$CHANGES

## Install

Requires macOS 15 or later, on Apple silicon or Intel.

1. Download **$ZIP** below, unzip it, and move **Copilot Pulse** to your Applications folder.
2. Open it. The app isn't notarized, so macOS blocks it the first time: click **Done**, then
   **Open Anyway** in **System Settings › Privacy & Security**.

The [README](https://github.com/mnsn/copilot-pulse#install) has the details, and how to build it
from source.

SHA-256 of $ZIP: \`$SHA256\`
EOF
echo "Packaged $OUT/$ZIP (version $VERSION)"
