#!/usr/bin/env bash
# Runs the unit tests. Optional arg is an -only-testing filter,
# e.g. ./scripts/test.sh DogballWhisperTests/HotkeyMatcherTests
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate

ARGS=()
[[ -n "${1:-}" ]] && ARGS+=(-only-testing:"$1")

xcodebuild test \
  -project DogballWhisper.xcodeproj \
  -scheme DogballWhisper \
  -configuration Debug \
  -derivedDataPath build/DerivedData \
  -destination 'platform=macOS' \
  ${ARGS[@]+"${ARGS[@]}"}
