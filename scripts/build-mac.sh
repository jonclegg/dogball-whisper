#!/usr/bin/env bash
# Generates the project, builds Release, and installs into /Applications.
# Usage: ./scripts/build-mac.sh [--launch]
set -euo pipefail
cd "$(dirname "$0")/.."

LAUNCH=false
[[ "${1:-}" == "--launch" ]] && LAUNCH=true

xcodegen generate

xcodebuild \
  -project DogballWhisper.xcodeproj \
  -scheme DogballWhisper \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  -destination 'platform=macOS' \
  build

APP="build/DerivedData/Build/Products/Release/Dogball Whisper.app"
[[ -d "$APP" ]] || { echo "Build product not found at $APP"; exit 1; }

pkill -x "Dogball Whisper" 2>/dev/null || true
sleep 1
rm -rf "/Applications/Dogball Whisper.app"
cp -R "$APP" /Applications/
echo "Installed /Applications/Dogball Whisper.app"

codesign --verify --strict "/Applications/Dogball Whisper.app"

$LAUNCH && open "/Applications/Dogball Whisper.app"
