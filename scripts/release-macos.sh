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

# The version string is the only way to tell which build someone is running:
# there is no auto-update and no crash reporting, so a bug report says
# "1.0 (1)" for every build ever shipped unless this is derived from the tag.
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "Tag must look like v1.2.3, got '$TAG'"
MARKETING_VERSION="${TAG#v}"
# Monotonic across the whole history, and monotonic is all CURRENT_PROJECT_VERSION
# has to be.
BUILD_NUMBER="$(git rev-list --count HEAD)"

# Every tag that already exists, locally or on the remote. A version that is
# not greater than one of these would publish a build that looks older than
# it is, or collide with one already downloaded.
EXISTING_TAGS="$(
  {
    git tag --list 'v*'
    git ls-remote --tags origin 2>/dev/null | sed 's|.*refs/tags/||; s|\^{}$||'
  } | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -u || true
)"
if [[ -n "$EXISTING_TAGS" ]]; then
  LATEST_TAG="$(printf '%s\n' "$EXISTING_TAGS" | sort -V | tail -1)"
  if printf '%s\n' "$EXISTING_TAGS" | grep -qx "$TAG"; then
    fail "$TAG already exists"
  fi
  HIGHEST="$(printf '%s\n%s\n' "$LATEST_TAG" "$TAG" | sort -V | tail -1)"
  [[ "$HIGHEST" == "$TAG" ]] \
    || fail "$TAG is not greater than the latest existing tag ($LATEST_TAG)"
fi

# Fail early and loudly rather than 10 minutes into a build.
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  fail "notarytool profile '$NOTARY_PROFILE' is missing. Create it once with:
  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id jonclegg@gmail.com --team-id $TEAM_ID"
fi

step "Building Release $MARKETING_VERSION ($BUILD_NUMBER)"
xcodegen generate
# These two override project.yml's placeholders for every target in this
# invocation, and land in the generated Info.plist.
xcodebuild \
  -project DogballWhisper.xcodeproj \
  -scheme DogballWhisper \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  -destination 'platform=macOS' \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  build

[[ -d "$APP_PATH" ]] || fail "Build product not found at $APP_PATH"

step "Verifying the version, signature, and hardened runtime"
BUILT_VERSION="$(defaults read "$PWD/$APP_PATH/Contents/Info" CFBundleShortVersionString)"
[[ "$BUILT_VERSION" == "$MARKETING_VERSION" ]] \
  || fail "Built app reports version $BUILT_VERSION, expected $MARKETING_VERSION"
codesign --verify --strict --verbose=2 "$APP_PATH"
# 'runtime' in the flags is what notarization requires. Capture first rather
# than piping into `grep -q`: grep exits on the first match, codesign dies of
# SIGPIPE, and `set -o pipefail` reports that as a failed check on a build that
# was in fact correct.
SIGNING_INFO="$(codesign -d --verbose=2 "$APP_PATH" 2>&1)"
case "$SIGNING_INFO" in
  *flags=*runtime*) ;;
  *) fail "Hardened Runtime is not enabled on the built app" ;;
esac
# get-task-allow must be absent or the notary service rejects the submission.
if codesign -d --entitlements - "$APP_PATH" 2>/dev/null | grep -q "get-task-allow"; then
  fail "get-task-allow is present; notarization will reject this build"
fi

step "Notarizing (this waits on Apple, usually a few minutes)"
mkdir -p "$DIST_DIR"
ditto -c -k --keepParent "$APP_PATH" "$DIST_DIR/notarize.zip"
# `notarytool submit --wait` exits 0 even when the submission comes back
# Invalid, so the status has to be read rather than trusted. Without this the
# script sails on to stapling and fails there with a confusing CloudKit error
# instead of Apple's actual reason.
SUBMIT_OUTPUT="$(xcrun notarytool submit "$DIST_DIR/notarize.zip" \
  --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
echo "$SUBMIT_OUTPUT"
case "$SUBMIT_OUTPUT" in
  *"status: Accepted"*) ;;
  *)
    SUBMISSION_ID="$(printf '%s\n' "$SUBMIT_OUTPUT" | awk '/^ *id: / { print $2; exit }')"
    if [[ -n "$SUBMISSION_ID" ]]; then
      printf "\n--- notary log for %s ---\n" "$SUBMISSION_ID"
      xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" || true
    fi
    fail "Notarization did not succeed"
    ;;
esac

step "Stapling"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
# The real proof: Gatekeeper accepts it as if it had been downloaded.
# `-t exec` is the app-bundle rule set; `-t install` asks about installer
# packages and answers a question nobody asked here.
spctl -a -vvv -t exec "$APP_PATH"

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
