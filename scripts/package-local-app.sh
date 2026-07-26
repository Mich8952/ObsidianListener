#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
DERIVED="$(mktemp -d "${TMPDIR:-/tmp}/MeetingNotesBuild.XXXXXX")"
OUTPUT="$ROOT/dist/MeetingNotes.app"
SOURCE="$DERIVED/Build/Products/Release/MeetingNotes.app"
trap 'rm -rf "$DERIVED"' EXIT

cd "$ROOT"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes -configuration Release \
  -derivedDataPath "$DERIVED" build

mkdir -p "$ROOT/dist"
rm -rf "$OUTPUT"
ditto "$SOURCE" "$OUTPUT"

codesign --force --sign - --timestamp=none --generate-entitlement-der \
  --entitlements "$ROOT/MeetingNotes/MeetingNotes.entitlements" "$OUTPUT"
codesign --verify --deep --strict --verbose=2 "$OUTPUT"
echo "Built $OUTPUT"
echo "No API key is embedded. Enter it once in Settings; it persists in macOS Keychain."
