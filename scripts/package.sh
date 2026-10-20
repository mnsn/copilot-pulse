#!/bin/bash
# Builds what a GitHub release ships, into build/release: a universal "Copilot Pulse.app", checked
# and zipped, the zip's SHA-256, and release notes from CHANGELOG.md (notes.md for the release page,
# changes.md for the appcast that scripts/make-appcast.sh writes).
#   scripts/package.sh [tag]   with a tag such as v0.1.0, fails unless it matches Info.plist and is
#                              higher than every earlier v* tag.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Copilot Pulse.app"
OUT="build/release"
ZIP="Copilot-Pulse.zip"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
# The build sets CFBundleVersion to this version, and Sparkle offers an update only when that's
# higher than the installed app's, so keep it to plain numbers that compare the same way.
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "The version in Resources/Info.plist ($VERSION) isn't like 1.2.3." >&2
    exit 1
fi
if [[ $# -gt 0 ]]; then
    if [[ "$1" != "v$VERSION" ]]; then
        echo "The tag $1 doesn't match the version in Resources/Info.plist ($VERSION)." >&2
        exit 1
    fi
    if [[ "$(git rev-parse --is-shallow-repository)" == true ]]; then
        echo "Comparing with earlier releases needs every tag; fetch the full history." >&2
        exit 1
    fi
    LATEST="$(git tag --list 'v*' | grep -vxF "$1" | sed 's/^v//' | sort -V | tail -n 1 || true)"
    if [[ -n "$LATEST" && "$(printf '%s\n%s\n' "$LATEST" "$VERSION" | sort -V | tail -n 1)" != "$VERSION" ]] ||
        [[ "$LATEST" == "$VERSION" ]]; then
        echo "Version $VERSION isn't higher than the latest release, $LATEST." >&2
        exit 1
    fi
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

After that, it updates itself: the second time you open it, it asks whether to check for updates
automatically. The [README](https://github.com/mnsn/copilot-pulse#install) has the details, and
how to build it from source.

SHA-256 of $ZIP: \`$SHA256\`
EOF
# The release notes that the app shows before it updates (see scripts/make-appcast.sh).
unwrap > "$OUT/changes.md" <<< "$CHANGES"
echo "Packaged $OUT/$ZIP (version $VERSION)"
