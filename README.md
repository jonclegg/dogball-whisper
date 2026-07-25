# Dogball Whisper

A menu-bar dictation client for macOS. Hold right ⌥, talk, let go, and the
text appears wherever you were typing. Transcription runs on this Mac; an
optional OpenRouter pass strips ums and ahs.

## Build and install

    ./scripts/build-mac.sh [--launch]   # builds Release, signs, installs to /Applications
    ./scripts/test.sh [filter]          # unit tests, optional -only-testing filter
                                         # e.g. ./scripts/test.sh DogballWhisperTests/HotkeyMatcherTests

Never open Xcode: `project.yml` plus `xcodegen` owns the project file, which
is gitignored. Both scripts run `xcodegen generate` first, so a new source
file is picked up automatically.

The unit suite proves the logic in isolation (state machine, geometry,
parsing, gating). It does not prove the app works: the event tap,
Accessibility queries, and synthetic paste all need a real permission grant
and a real window to type into, which the suite cannot fake. See
`docs/MANUAL-SMOKE.md` for that.

### Gated integration tests

A few tests need real hardware or a real network call and are gated behind
environment variables so they don't run by default:

    RUN_ENGINE_IT=1 ./scripts/test.sh DogballWhisperTests/EngineIntegrationTests
    RUN_AUDIO_IT=1 ./scripts/test.sh DogballWhisperTests/AudioRecorderTests
    RUN_MIRROR_IT=1 ./scripts/test.sh DogballWhisperTests/ModelMirrorIntegrationTests

`scripts/test.sh` forwards `RUN_AUDIO_IT`, `RUN_ENGINE_IT`, and
`RUN_MIRROR_IT` into the test host as `TEST_RUNNER_`-prefixed variables.
This exists because `xcodebuild` launches the test host through
LaunchServices, which does not inherit the invoking shell's environment;
only variables Xcode copies through with that prefix reach the process. If
a gated test looks like it's not seeing its flag, check that mechanism
before assuming the gate itself is broken.

`RUN_AUDIO_IT` in particular needs an interactive microphone permission
grant for the test host, not just the app, so it can't run headlessly or in
CI.

## Permissions

Microphone and Input Monitoring are required. Accessibility is optional but
strongly recommended: without it, text is copied to the clipboard instead
of pasted, and the waveform panel sits at a fixed position instead of
following your caret.

Granting Input Monitoring makes macOS offer to quit and reopen the app; the
event tap only works after that relaunch.

Bundle ID (`com.jonclegg.DogballWhisper`) and signing identity
(`Developer ID Application: Jonathan Clegg (22CTWHGWQQ)`) are fixed on
purpose. macOS keys Accessibility and Input Monitoring grants to both, so
changing either forces every user to re-grant everything.

## Models

Parakeet V3 (the default) downloads from a privately hosted CloudFront
mirror. The four Whisper variants download from WhisperKit's HuggingFace
repo. Both land in the app's Application Support directory, managed one at
a time by `Transcribe/ModelManager.swift`.

## Layout

- `Hotkey/` - the event tap and the pure matcher that decides began / ended / cancelled
- `Capture/` - 16kHz mono WAV recording with level metering
- `Transcribe/` - engine protocol, Parakeet (FluidAudio), Whisper (WhisperKit), model catalog
- `Polish/` - the OpenRouter cleanup call
- `Insert/` - caret location and clipboard-preserving paste
- `Core/DictationCoordinator.swift` - the state machine everything else hangs off
- `UI/` - floating panel, settings, onboarding

## Docs

- `docs/superpowers/specs/` - the original design doc
- `docs/superpowers/plans/` - the implementation plan this was built from
- `docs/MANUAL-SMOKE.md` - the pre-ship checklist for everything the test
  suite cannot verify by itself
