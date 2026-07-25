#!/usr/bin/env bash
# release-macos.sh — build Release, notarize, staple, and publish a GitHub release.
#
# One-time prereq, run by a human because it needs an app-specific password
# from appleid.apple.com typed interactively:
#
#   xcrun notarytool store-credentials DogballWhisper \
#     --apple-id jonclegg@gmail.com --team-id 22CTWHGWQQ
#
# Usage:
#   ./scripts/release-macos.sh v0.1.0          # build, notarize, staple, publish
#   ./scripts/release-macos.sh v0.1.0 --dry-run  # everything except publishing
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID="22CTWHGWQQ"
APP_NAME="Dogball Whisper"
NOTARY_PROFILE="${NOTARY_PROFILE:-DogballWhisper}"
BUILD_DIR="build/DerivedData/Build/Products/Release"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
DIST_DIR="build/dist"

TAG="${1:-}"
DRY_RUN=false
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN=true

fail() { printf "\033[1;31m✗ %s\033[0m\n" "$1" >&2; exit 1; }
step() { printf "\n\033[1m→ %s\033[0m\n" "$1"; }

[[ -n "$TAG" ]] || fail "Usage: ./scripts/release-macos.sh <tag> [--dry-run]"

# Fail early and loudly rather than 10 minutes into a build.
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  fail "notarytool profile '$NOTARY_PROFILE' is missing. Create it once with:
  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id jonclegg@gmail.com --team-id $TEAM_ID"
fi

step "Building Release"
xcodegen generate
xcodebuild \
  -project DogballWhisper.xcodeproj \
  -scheme DogballWhisper \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  -destination 'platform=macOS' \
  build

[[ -d "$APP_PATH" ]] || fail "Build product not found at $APP_PATH"

step "Verifying the signature and hardened runtime"
codesign --verify --strict --verbose=2 "$APP_PATH"
# 'runtime' in the flags is what notarization requires.
codesign -d --verbose=2 "$APP_PATH" 2>&1 | grep -q "flags=.*runtime" \
  || fail "Hardened Runtime is not enabled on the built app"
# get-task-allow must be absent or the notary service rejects the submission.
if codesign -d --entitlements - "$APP_PATH" 2>/dev/null | grep -q "get-task-allow"; then
  fail "get-task-allow is present; notarization will reject this build"
fi

step "Notarizing (this waits on Apple, usually a few minutes)"
mkdir -p "$DIST_DIR"
ditto -c -k --keepParent "$APP_PATH" "$DIST_DIR/notarize.zip"
xcrun notarytool submit "$DIST_DIR/notarize.zip" \
  --keychain-profile "$NOTARY_PROFILE" --wait

step "Stapling"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
# The real proof: Gatekeeper accepts it as if it had been downloaded.
spctl -a -vvv -t install "$APP_PATH"

step "Packaging"
ZIP="$DIST_DIR/DogballWhisper-$TAG.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP_PATH" "$ZIP"
echo "Wrote $ZIP"

if $DRY_RUN; then
  printf "\n\033[1;33m✓ Dry run: built, notarized, stapled. Nothing published.\033[0m\n"
  exit 0
fi

step "Publishing the GitHub release"
gh release create "$TAG" "$ZIP" \
  --title "$APP_NAME $TAG" \
  --notes "Notarized build for Apple Silicon, macOS 14 or later.

Download, unzip, and drag \`$APP_NAME.app\` into Applications. On first launch it
walks you through microphone and Accessibility access and downloads a speech
model. Hold right option, talk, release, and the text appears where you were
typing.

Accessibility is what carries the hotkey and the paste, so grant it when asked.
Input Monitoring is listed as optional and is usually unnecessary."

printf "\n\033[1;32m✓ %s %s published.\033[0m\n" "$APP_NAME" "$TAG"
