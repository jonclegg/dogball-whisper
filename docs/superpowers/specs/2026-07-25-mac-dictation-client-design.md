# Dogball Whisper — macOS Dictation Client

**Date:** 2026-07-25
**Status:** Approved design

## Purpose

A lightweight, native macOS menu-bar dictation client. Hold a key, talk, release — the
text appears in whatever field had focus, transcribed on-device and cleaned of
disfluencies by a fast remote model. No Dock icon, no window management, no cloud audio.

Prior art: `~/dev/whisper-polish` (iOS) already runs Parakeet V3 via FluidAudio and
polishes text through OpenRouter. `TranscriptionService.swift`, `ModelMirror.swift`, and
`PolishService.swift` port to macOS with minimal change.

## Constraints and non-goals

- macOS 14+, Apple Silicon only.
- `LSUIElement` app: menu-bar item plus transient panels. No main window, no Dock icon.
- Audio never leaves the machine. Only transcribed *text* goes to OpenRouter, and only
  when the user has supplied a key.
- Personal tool: signed locally, no notarization, no DMG, no auto-update.
- Not in scope: streaming partial transcripts, custom vocabulary, dictation commands
  ("new line", "period"), history/log of past dictations, multi-model chaining,
  iCloud sync, in-panel editing.

## Architecture

Single SwiftUI + AppKit target. Eight units, each with one responsibility and a protocol
boundary where behavior needs faking in tests. No unit below imports the UI layer.

```
DogballWhisper/
  App/          DogballWhisperApp.swift, MenuBarController.swift, LoginItem.swift
  Hotkey/       HotkeyMonitor.swift, HotkeyBinding.swift
  Capture/      AudioRecorder.swift
  Transcribe/   TranscriptionEngine.swift, ParakeetEngine.swift, WhisperKitEngine.swift,
                ModelCatalog.swift, ModelDownloader.swift
  Polish/       PolishService.swift
  Insert/       TextInserter.swift, CaretLocator.swift
  UI/           DictationPanel.swift, WaveformView.swift, SettingsView.swift,
                OnboardingView.swift
  Core/         DictationCoordinator.swift, Permissions.swift, Preferences.swift
Tests/          coordinator state machine, polish service, engine integration
scripts/        build-mac.sh
project.yml     xcodegen
```

### Components

**`HotkeyMonitor`** — a `CGEventTap` on `flagsChanged` and `keyDown`. Emits:
- `.began` when the bound modifier goes down with no other modifier or key held
- `.ended` on its release
- `.cancelled` if any other key is pressed while it is held

The cancel rule is what keeps `⌥e` (accents) and `fn+←` working normally. Modifier-only
bindings are matched by keycode so left and right keys are distinguished: right ⌥ = 61,
right ⌘ = 54, fn = 63. `HotkeyBinding` is the single abstraction over
"modifier-only key" and "modifier+key combo" so the picker has one code path.

**`AudioRecorder`** — `AVAudioRecorder` writing 16kHz mono 16-bit LE PCM straight to a
WAV file. Device open and file creation are pre-armed ahead of time by calling
`prepareToRecord()` on a not-yet-started recorder — at app launch (once mic access is
already authorized), again after every `stop()`/`cancel()`, and again if the default
input device changes — so `.began` → `start()` is usually just the already-prepared
recorder's `record()` call. Preparing never engages the microphone: it does not light
the recording indicator, and it never triggers the permission prompt (pre-warming is
gated on authorization already being granted). If nothing is armed in time, `start()`
prepares inline instead, exactly as it did before pre-warming existed. Publishes a
metered level stream (~30Hz) for the waveform and returns the full recording on stop.
Protocol-backed for tests.

**`TranscriptionEngine`** — `func transcribe(_ audioURL: URL) async throws -> String`, plus
`load()` / `unload()`. It takes a file rather than a sample buffer because that is what
both frameworks want (FluidAudio `transcribe(_ url:decoderState:)`, WhisperKit
`transcribe(audioPath:)`) and what the recorder already produces. Two implementations:
- `ParakeetEngine` — FluidAudio (0.15.x), Parakeet TDT 0.6b v3, English.
- `WhisperKitEngine` — WhisperKit (0.18.x), any installed Whisper model, multilingual.

The active model stays loaded in memory so no dictation pays a cold-start cost.

**`ModelCatalog` / `ModelDownloader`** — declarative catalog of installable models with
engine, display name, download size, and source. Parakeet V3 (~483MB) comes from the
existing CloudFront mirror (`d36t08oi3ecji2.cloudfront.net`) using the bundled
`parakeet-manifest.json` for byte-accurate progress; Whisper models
(tiny / base / small / large-v3-turbo) come from WhisperKit's own HuggingFace repo.
Downloads are resumable, run one at a time, continue when Settings is closed, and land in
`~/Library/Application Support/DogballWhisper/Models/`. Models can be deleted. Exactly
one model is Active; switching unloads the previous engine and loads the new one.

**`PolishService`** — OpenRouter `/chat/completions`. Key read from Keychain. 3-second
timeout, no retry. Returns the raw transcript unchanged on any error, timeout, empty
response, or missing key — cleanup is never allowed to block or lose a dictation.

Default system prompt, editable in Settings:

> Clean up this dictated text. Remove filler words (um, uh, like, you know), false
> starts, stutters, and repeated words. Fix punctuation and capitalization. Do not
> rephrase, reorder, summarize, or add anything — keep the speaker's exact wording and
> voice otherwise. Return only the cleaned text.

Default model: `anthropic/claude-haiku-4.5` — fast and cheap enough to stay inside the
latency budget. Changeable via a free-text OpenRouter model ID, with the same shortlist
whisper-polish offers (`google/gemini-3.5-flash`, `z-ai/glm-5-turbo`, `openai/gpt-4.1`)
as suggestions.

**`CaretLocator`** — reads the focused element via
`AXUIElementCreateSystemWide` → `kAXFocusedUIElementAttribute`, then
`kAXSelectedTextRangeAttribute` → `kAXBoundsForRangeParameterizedAttribute`. Returns
the caret rect in screen coordinates, or nil. Also exposes the focused app's PID so the
coordinator can detect focus changes.

**`TextInserter`** — saves the current pasteboard items, writes the text, posts a
synthetic ⌘V (`CGEvent` with `.cghidEventTap`), restores the previous pasteboard after
~150ms. Protocol-backed for tests. Alternate `.clipboardOnly` mode selectable in
Settings for users who don't want synthetic keystrokes.

**`DictationCoordinator`** — the only stateful component:
`idle → recording → transcribing → polishing → inserting → idle`. Owns cancellation,
error surfacing, and the panel's lifecycle. Everything it touches is a protocol, so the
full state machine is unit-testable headlessly.

## Dictation flow

1. **Hotkey down** — capture the focused app PID and caret rect; the panel fades in just
   above the caret (bottom-center of the active screen if there's no caret); recording
   starts; waveform animates from live RMS.
2. **Hotkey up** — panel switches to "Transcribing…"; buffer goes to the active engine.
3. **Transcript non-empty and cleanup enabled** — panel shows "Polishing…"; OpenRouter
   call with a 3s ceiling.
4. **Insert** — `TextInserter` pastes into the app captured in step 1; panel fades out.

Target: under 1.5s from release to inserted text for a 5-second utterance.

### Edge cases

| Condition | Behavior |
|---|---|
| Any other key pressed while the hotkey is held | `.cancelled` — discard audio, no insert (this is what preserves `⌥e`, `fn+←`, and covers `esc`) |
| `esc` pressed after release, during transcribing or polishing | Abandon the in-flight work, no insert |
| Recording under 300ms | Discarded as an accidental tap, no panel error |
| Empty transcript | Panel shows "No speech", fades out |
| Focus moved to a different app since step 1 | Skip the paste; copy to clipboard and tell the user in the panel |
| No caret available | Panel at bottom-center; insertion still proceeds |
| Cleanup fails, times out, or no key | Insert the raw transcript |
| No model installed | Panel points at Settings → Models; recording is refused |
| Hotkey pressed while a dictation is still finishing | Ignored until back to `idle` |

Pasting into the wrong window is the one unrecoverable failure mode, which is why the
focus check is a hard gate rather than a warning.

## Permissions

Requested during onboarding, each row showing live status with a "Recheck" button, since
macOS never re-prompts after a denial.

- **Microphone** — `AVCaptureDevice.requestAccess(for: .audio)`.
- **Input Monitoring** — required for the `CGEventTap`. Not requestable
  programmatically: detect with `CGPreflightListenEventAccess()`, deep-link to
  `x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent`, poll
  until granted.
- **Accessibility** — required for the caret query and synthetic ⌘V.
  `AXIsProcessTrustedWithOptions` prompts once; then the same deep-link and poll.

Mic and Input Monitoring are hard requirements — the app is gated until both are
granted. Accessibility being absent degrades to clipboard-only insertion with a
bottom-center panel.

## UI

**Menu bar** — icon reflects state (idle mic glyph / filled red while recording /
progress indicator while working). Menu: active model name, Settings…, Launch at Login
toggle, Quit.

**Dictation panel** — small borderless `NSPanel`, `.floating` level, non-activating
(`.nonactivatingPanel`, so focus never leaves the target app), ignores mouse events,
rounded translucent background, ~220×56pt. Contents: waveform bars while recording, a
one-line status while working, a one-line error when something fails. Auto-dismisses;
never a modal dialog.

**Onboarding** — one small window on first launch: three permission rows → download a
model → pick a hotkey → optional OpenRouter key.

**Settings** — three tabs:
- *General* — hotkey binding, launch at login, insertion mode (paste / clipboard only).
- *Models* — the catalog table: name, engine, size, state (Not installed / Downloading
  % / Installed / Active), with install, delete, and "Make active".
- *Cleanup* — enable toggle, OpenRouter key field (stored in Keychain), model ID,
  editable prompt, and a "Test" button that round-trips a canned disfluent sentence and
  shows the result.

**Hotkey defaults and conflicts** — default is **right ⌥ held**. Alternatives in the
picker: right ⌘, fn/🌐, or a custom modifier+key combo. The combo recorder is a local
`NSEvent` monitor in the settings window, which needs no extra permission and no third-party
package. If the user selects fn, the app reads
`defaults read com.apple.HIToolbox AppleFnUsageType` and, when it isn't `0`, offers to
deep-link to System Settings → Keyboard → "Press 🌐 to" → *Do Nothing*, because macOS
otherwise consumes the key.

## Persistence

- `UserDefaults` — hotkey binding, active model ID, cleanup enabled, cleanup model ID,
  cleanup prompt, insertion mode, onboarding-complete flag.
- **Keychain** — OpenRouter API key only.
- `~/Library/Application Support/DogballWhisper/Models/` — downloaded models.

No dictation history is stored anywhere; audio buffers are in-memory and dropped after
transcription.

## Build and install

- `xcodegen` from `project.yml`; the `.xcodeproj` is gitignored. Never open Xcode.
- SwiftPM dependencies: FluidAudio (from 0.15.4) and WhisperKit (from 0.18.0). Nothing else.
- Signed with `Developer ID Application: Jonathan Clegg (22CTWHGWQQ)`, bundle ID
  `com.jonclegg.DogballWhisper`, no sandbox, no hardened runtime. Both are fixed
  permanently: macOS keys Accessibility and Input Monitoring grants to the signature plus
  bundle ID, so changing either forces the user to re-grant every permission.
- `./scripts/build-mac.sh` — `xcodebuild` release build, local codesign, copy the `.app`
  into `/Applications`, optional `--launch`.
- Launch at login via `SMAppService.mainApp.register()` — no helper bundle, no
  deprecated login-item APIs.
- Standalone git repo at `~/dev/dogball_whisper` (added to `~/dev/.gitignore`); feature
  work happens in worktrees under `.claude/worktrees/`.

## Testing

- **`DictationCoordinator`** — unit tests over the full state machine with fake
  recorder, engine, polish service, and inserter: happy path, cancel, sub-300ms,
  empty transcript, polish timeout, polish error, focus change, no model installed,
  re-trigger while busy.
- **`PolishService`** — stubbed `URLProtocol` for success / HTTP error / timeout / malformed
  JSON, asserting raw-text fallthrough in every failure case. One live OpenRouter test
  gated behind an env var, same convention as whisper-polish.
- **`ModelDownloader`** — local HTTP fixture: progress reporting, resume after
  interruption, checksum/size mismatch handling.
- **Engine integration** — one fixture WAV through the real Parakeet model, gated behind
  an env var (needs the downloaded model).
- **Manual smoke checklist** — the event tap, AX caret query, and synthetic paste can't be
  meaningfully faked. Checklist covers: paste into Notes, VS Code, Terminal, Slack, and
  a browser text field; caret positioning in a native app and an Electron app; cancel via
  `esc`; hotkey rebinding; launch-at-login across a reboot.
