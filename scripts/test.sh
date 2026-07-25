#!/usr/bin/env bash
# Runs the unit tests. Optional arg is an -only-testing filter,
# e.g. ./scripts/test.sh DogballWhisperTests/HotkeyMatcherTests
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate

ARGS=()
[[ -n "${1:-}" ]] && ARGS+=(-only-testing:"$1")

# xcodebuild launches the test host through LaunchServices, which does not
# inherit this shell's environment. Xcode copies TEST_RUNNER_-prefixed
# variables into the test process, so forward the integration-test gates.
GATES=()
for gate in RUN_AUDIO_IT RUN_ENGINE_IT RUN_MIRROR_IT; do
  value="${!gate:-}"
  [[ -n "$value" ]] && GATES+=("TEST_RUNNER_$gate=$value")
done

env ${GATES[@]+"${GATES[@]}"} xcodebuild test \
  -project DogballWhisper.xcodeproj \
  -scheme DogballWhisper \
  -configuration Debug \
  -derivedDataPath build/DerivedData \
  -destination 'platform=macOS' \
  ${ARGS[@]+"${ARGS[@]}"}
