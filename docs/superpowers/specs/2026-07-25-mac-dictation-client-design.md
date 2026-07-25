# Dogball Whisper — macOS Dictation Client

**Date:** 2026-07-25
**Status:** Approved design, kept current with the shipped app

This document is the source of invariants for the project, so where the code
has moved on, this has to move with it rather than describe the app that was
originally planned. Places where the current behaviour is a deliberate reversal
of the original plan say so.

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
- Published to strangers: Developer ID signed, hardened runtime, notarized and
  stapled, shipped as a zip from GitHub releases. No DMG and no auto-update, so
  the version string baked in at release time is the only way to tell which
  build someone is running. (This reverses the original "personal tool, signed
  locally, no notarization" plan — Gatekeeper refuses an un-notarized download
  on any machine but the one that built it.)
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

**`PolishService`** — OpenRouter `/chat/completions`, with `reasoning: {enabled: false}`
because thinking tokens only add latency here. Key read from Keychain. 3-second
timeout, no retry. Returns the raw transcript unchanged on any error, timeout, empty
response, or missing key — cleanup is never allowed to block or lose a dictation.
Errors describe themselves by status code and cause, never by the provider's response
body: providers echo the submitted text back in moderation rejections, and that body
would otherwise reach the system log and the settings window.

Default system prompt, editable in Settings, and deliberately domain-neutral — anything
about who the speaker is rewrites words they actually said:

> Remove filler words, false starts, stutters, and repeated words. Fix punctuation and
> capitalization. Do not rephrase, reorder, translate, or add anything, and keep the
> speaker's own wording. Return only the cleaned text.

A second preset (`Preferences.developerCleanupPrompt`, offered as a button in
Settings > Cleanup) adds the one instruction that cannot be a default: fixing technical
terms the speech model mishears, such as "Maine" for "main".

Default model: `openai/gpt-4.1-nano` — chosen by measurement rather than reputation
(0.86s median round trip over three transcript lengths and three runs each, and the most
faithful of the fast ones). Changeable from a shortlist in Settings or by typing any
OpenRouter model ID. Models whose endpoints refuse a disabled-reasoning request, the
Gemini family among them, are deliberately absent from the shortlist, and the 400 they
answer with is turned into a named error rather than a silent timeout.

**`CaretLocator`** — roots the query at the frontmost app's own
`AXUIElementCreateApplication` element rather than `AXUIElementCreateSystemWide`, which
is what makes Chromium- and WebKit-based apps answer `kAXFocusedUIElementAttribute` at
all. From the reported focused element it descends to the text leaf that actually owns a
selection, then tries three tiers for the rect: the WebKit/Chromium text-marker range,
`kAXSelectedTextRangeAttribute` → `kAXBoundsForRangeParameterizedAttribute`, and the
focused element's own frame as a last resort. Returns the caret rect in screen
coordinates, or nil. Also exposes the focused app's PID so the coordinator can detect
focus changes, and whether the target is a password field (see *Secure fields* below).

Everything in it is bounded, because it runs on the main actor while the user is already
talking: a 50ms messaging timeout per app element, and a node budget plus a wall-clock
deadline on the descent. Running out of any of them degrades to "no caret", never to a
stall.

Electron and Chromium apps build their accessibility tree only when asked, via the
`AXEnhancedUserInterface` / `AXManualAccessibility` attributes. Those are set from a
background queue when such an app is *activated*, long before the hotkey is pressed —
never synchronously on the dictation path, and never on an app that does not look
Chromium/Electron. `AXEnhancedUserInterface` is the flag VoiceOver sets; on a native
AppKit app it changes window-resize and animation behaviour permanently, which is what
window managers fight with, so it must not be applied speculatively.

**`TextInserter`** — saves the current pasteboard items, writes the text, posts a
synthetic ⌘V (`CGEvent` with `.cghidEventTap`), restores the previous pasteboard after
~150ms, and only if nothing else has touched the pasteboard since. Protocol-backed for
tests. Alternate `.clipboardOnly` mode selectable in Settings for users who don't want
synthetic keystrokes. Pasting is gated on the target app still being frontmost, on
Accessibility being granted, and on secure input not having engaged since the dictation
started; any of those falls through to leaving the text on the clipboard and saying so,
rather than posting a keystroke that would be silently swallowed.

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
| Secure input engaged, or the focused element is a password field | Refuse: no recording, panel shows "Not in a password field" |
| Secure input engages *during* transcription or cleanup | No paste; text is left on the clipboard and the panel says so |

Pasting into the wrong window is the one unrecoverable failure mode, which is why the
focus check is a hard gate rather than a warning.

### Secure fields

The most safety-critical behaviour in the app, and the one place a bug means shipping a
password to a third party: dictated text goes to OpenRouter for cleanup, so dictating
into a password field would send the password there.

Two checks, because neither alone is enough:

1. `IsSecureEventInputEnabled()` — in-process, costs nothing, needs no permission, and
   is the *only* signal that catches a terminal password prompt, since a `sudo` prompt
   is an ordinary `AXTextArea` with nothing secure about it in the accessibility tree.
   Checked first, before anything else in `begin()`.
2. The `AXSecureTextField` subrole — catches a web `input[type=password]`, which does
   not engage secure event input. Checked on the reported focused element *and* on every
   node the descent walks, since the element reported as focused is frequently a
   container above the secure leaf. This one runs after `recorder.start()` (the caret
   query is deliberately kept out of the user's first syllable), so the recording that
   already began is thrown away, and nothing is transcribed, cleaned, or inserted.

Both refuse identically: no recording, and the panel shows "Not in a password field".
The refusal *reason* is logged only under the verbose diagnostics flag — a persisted
record of the moments a user sat at a password prompt is not something to keep by
default.

Secure input is checked once more immediately before the paste, because transcription
and cleanup take a second or more and a `sudo` prompt, an auth sheet, or Terminal's
Secure Keyboard Entry can arrive inside that window. Secure input swallows synthetic
keystrokes silently, so the text is left on the clipboard and the user is told, rather
than vanishing.

A known false positive comes with this: an app that leaves secure event input engaged
behind it makes dictation refuse everywhere until that app releases it. Refusing wrongly
is the acceptable direction of that trade.

## Diagnostics

Two levels, split by what is worth persisting about a user who never asked for
diagnostics. Failures and refusals are always logged. Per-dictation detail — caret
coordinates, character counts, cleanup timings, paste sizes — is off unless the user
turns it on:

    defaults write com.jonclegg.DogballWhisper verboseDiagnostics -bool YES

At `notice` with `.public` these persist in the system log store for days, and one line
per dictation is a durable timeline of when someone dictated and how much they said.
Neither level ever records transcript text, cleaned text, or the API key.

## Permissions

Requested during onboarding, each row showing live status with a "Recheck" button, since
macOS never re-prompts after a denial.

- **Microphone** — `AVCaptureDevice.requestAccess(for: .audio)`. Required.
- **Accessibility** — required, and carries three things: the event tap, the caret
  query, and the synthetic ⌘V. `AXIsProcessTrustedWithOptions` prompts once; then a
  deep-link and poll.
- **Input Monitoring** — optional. Not requestable programmatically: detect with
  `CGPreflightListenEventAccess()`, deep-link to
  `x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent`, poll
  until granted.

Microphone and Accessibility are the hard requirements — the app is gated until both are
granted. **This inverts the original plan, deliberately**: a session event tap runs on
the Accessibility grant, and macOS will not even list an app under Input Monitoring
until it has installed a tap, so requiring Input Monitoring deadlocked setup on a clean
machine. `PermissionKind.isRequired` is the single source of truth for this
(`self != .inputMonitoring`); anything that reintroduces Input Monitoring as a
requirement reintroduces that deadlock.

## UI

**Menu bar** — icon reflects state (idle mic glyph / filled red while recording /
progress indicator while working). Menu: active model name, Settings…, Launch at Login
toggle, Quit.

**Dictation panel** — small borderless `NSPanel`, `.floating` level, non-activating
(`.nonactivatingPanel`, so focus never leaves the target app), ignores mouse events,
rounded translucent background, 104×34pt (`PanelPositioner.panelSize`, deliberately
smaller than the 220×56 first drawn: it sits over the text you are dictating into and
had no business covering that much of it). Contents: waveform bars while recording, a
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
  cleanup prompt, insertion mode, onboarding-complete flag, and the undisplayed
  `verboseDiagnostics` flag.
- **Keychain** — OpenRouter API key only. Clearing the key field in Settings (or in
  setup) deletes it: that is the user's only way to stop sending dictated text to a
  third party, so an emptied field must never leave a stored key behind.
- `~/Library/Application Support/DogballWhisper/Models/` — downloaded models.

No dictation history is stored anywhere; audio buffers are in-memory and dropped after
transcription.

## Build and install

- `xcodegen` from `project.yml`; the `.xcodeproj` is gitignored. Never open Xcode.
- SwiftPM dependencies: FluidAudio (from 0.15.4) and WhisperKit (from 0.18.0). Nothing else.
- Signed with `Developer ID Application: Jonathan Clegg (22CTWHGWQQ)`, bundle ID
  `com.jonclegg.DogballWhisper`. The signing identity and bundle ID are fixed
  permanently: macOS keys Accessibility and Input Monitoring grants to the signature plus
  bundle ID, so changing either forces the user to re-grant every permission.
- No sandbox, ever — an Accessibility client cannot be sandboxed. Hardened Runtime **is**
  enabled, in Release only, because notarization requires it (this reverses the original
  "no hardened runtime" line). Release only is itself load-bearing: Hardened Runtime
  refuses to load an injected library, so a hardened test host hangs before the XCTest
  bundle can connect. Tests build Debug.
- `./scripts/build-mac.sh` — `xcodebuild` release build, local codesign, copy the `.app`
  into `/Applications`, optional `--launch`. A build from here reports version `0.0.0`,
  which is how you tell it apart from a published one.
- `./scripts/release-macos.sh <tag> [--dry-run]` — the only way a build reaches anyone
  else: Release build, signature and hardened-runtime verification, notarize, staple,
  Gatekeeper check, zip, GitHub release. `MARKETING_VERSION` and
  `CURRENT_PROJECT_VERSION` are derived from the tag and the commit count, and the script
  refuses a tag that is not greater than every tag that already exists — with no
  auto-update and no crash reporting, the version string is the only way to know which
  build a bug report is about.
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
