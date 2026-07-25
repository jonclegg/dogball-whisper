# Dogball Whisper

A menu-bar dictation client for macOS. Hold right ⌥, talk, let go, and the
text appears wherever you were typing. Transcription runs on this Mac; an
optional OpenRouter pass strips ums and ahs.

## Download

[Latest release](https://github.com/jonclegg/dogball-whisper/releases/latest) —
a notarized build for Apple Silicon, macOS 14 or later. Unzip it, drag
`Dogball Whisper.app` into Applications, and open it. First launch walks you
through microphone and Accessibility access and downloads a speech model.

Grant Accessibility when asked: it carries both the hotkey and the paste.
Input Monitoring is listed as optional and is usually unnecessary.

## Build and install

    ./scripts/build-mac.sh [--launch]   # builds Release, signs, installs to /Applications
    ./scripts/test.sh [filter]          # unit tests, optional -only-testing filter
                                         # e.g. ./scripts/test.sh DogballWhisperTests/HotkeyMatcherTests
    ./scripts/release-macos.sh v1.2.3 [--dry-run]   # notarize, staple, publish

A local `build-mac.sh` build reports version 0.0.0. Only the release script
stamps a real version, taken from the tag, and it refuses a tag that is not
greater than every tag that already exists — with no auto-update and no
crash reporting, the version string is the only way to tell which build a
bug report is about.

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

Microphone and Accessibility are required. Accessibility carries three
things: the event tap that sees the hotkey, the caret query that positions
the panel, and the synthetic ⌘V that pastes.

Input Monitoring is optional and usually unnecessary. A session event tap
runs on the Accessibility grant, and macOS will not even list an app under
Input Monitoring until it has installed a tap. If you do grant it, macOS
offers to quit and reopen the app.

Bundle ID (`com.jonclegg.DogballWhisper`) and signing identity
(`Developer ID Application: Jonathan Clegg (22CTWHGWQQ)`) are fixed on
purpose. macOS keys Accessibility and Input Monitoring grants to both, so
changing either forces every user to re-grant everything.

## Cleanup prompts

The shipped prompt removes disfluencies and fixes punctuation and
capitalization, and nothing else: it says nothing about what you are
dictating about, because anything domain-specific rewrites words you
actually said.

Settings > Cleanup also offers a developer preset, which additionally fixes
technical terms the speech model mishears:

> Remove filler words, false starts, stutters, and repeated words. Fix
> punctuation and capitalization. The speaker is a developer: fix misheard
> technical terms ("Maine" is "main", "guess" is "git"). Do not rephrase or
> add anything. Return only the cleaned text.

The prompt is a plain text field, so that pattern adapts to any field with
its own vocabulary. Keep it short: it is read by the model on every
dictation, between letting go of the key and the text appearing.

Cleanup only happens if you supply an OpenRouter key, and only your
transcribed text is ever sent. To stop it, clear the API key field in
Settings > Cleanup: an empty field deletes the stored key rather than
leaving it in the Keychain.

## Diagnostics

Failures are always logged. Per-dictation detail (caret position, character
counts, cleanup timings) is off, because those lines persist in the system
log store for days and would record when you dictated and how much you said.
Turn it on only while chasing something:

    defaults write com.jonclegg.DogballWhisper verboseDiagnostics -bool YES
    # quit and reopen the app, reproduce, then:
    log show --last 10m --predicate 'subsystem == "com.jonclegg.DogballWhisper"'
    defaults write com.jonclegg.DogballWhisper verboseDiagnostics -bool NO

Neither level ever logs what you said, the cleaned text, or your API key.

## Models

Parakeet V3 (the default) downloads from a privately hosted CloudFront
mirror. The four Whisper variants download from WhisperKit's HuggingFace
repo. They land in different places, and that is deliberate:

- Whisper variants go to
  `~/Library/Application Support/DogballWhisper/Models/`.
- Parakeet goes to
  `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3/`,
  because FluidAudio loads it from its own cache directory and cannot be
  pointed at ours.

Either way, downloads run one at a time and are resumable at byte
granularity, managed by `Transcribe/ModelManager.swift`.

## Layout

- `Hotkey/` - the event tap and the pure matcher that decides began / ended / cancelled
- `Capture/` - 16kHz mono WAV recording with level metering
- `Transcribe/` - engine protocol, Parakeet (FluidAudio), Whisper (WhisperKit), model catalog
- `Polish/` - the OpenRouter cleanup call
- `Insert/` - caret location and clipboard-preserving paste
- `Core/DictationCoordinator.swift` - the state machine everything else hangs off
- `UI/` - floating panel, settings, onboarding

## Docs

- `docs/superpowers/specs/` - the design doc, kept current with the app
- `docs/superpowers/plans/` - the implementation plan this was built from
- `docs/MANUAL-SMOKE.md` - the pre-ship checklist for everything the test
  suite cannot verify by itself
