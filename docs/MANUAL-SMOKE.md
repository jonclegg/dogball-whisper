# Manual smoke checklist

Covers what cannot be faked in tests: the event tap, Accessibility queries,
synthetic paste, and anything that needs a real permission grant or a real
reboot. The unit suite proves the logic underneath these features; it does
not prove the app. Run this before calling a change done.

Items marked **(never verified)** exist because this feature was built and
reviewed on a machine with no interactive Accessibility or Input Monitoring
grant and a microphone that hangs Core Audio. They have only ever been
checked by reading code and building, never by running the app. Give them
extra attention.

Build and install: `./scripts/build-mac.sh --launch`

Work top to bottom in one sitting: sections are ordered so you set the app
up once, then reuse that state (a running dictation session, an open
Settings window) across nearby checks instead of tearing it down and
rebuilding it for each one.

## 1. First run and permissions

- [ ] Fresh install (or delete `~/Library/Application Support/DogballWhisper`
      and reset permissions with `tccutil reset All com.jonclegg.DogballWhisper`):
      launching shows the setup window, not the dictation panel
- [ ] Grant Microphone from the setup window: the row turns green immediately
- [ ] Grant Input Monitoring from the setup window: macOS offers to quit and
      reopen the app; the hotkey does not work until you accept that
- [ ] Grant Accessibility from the setup window: the row turns green within
      a second (it is polled, not pushed)
- [ ] Download the default model from the setup window: progress advances,
      then "Start dictating" becomes enabled
- [ ] **(never verified)** Close the setup window with the titlebar's red
      button before finishing: the window disappears, the app does not quit,
      and the menu bar shows a "Finish setup…" item above the separator
- [ ] **(never verified)** Click "Finish setup…" in the menu: the same setup
      window reopens with your prior progress (granted permissions, installed
      model) still intact
- [ ] Finish setup for real ("Start dictating"): the setup window closes,
      "Finish setup…" disappears from the menu for the rest of the run, and
      the app has no Dock icon and no other window open

## 2. Hotkey behavior

- [ ] Hold right ⌥ and release: dictation runs (panel appears, then inserts)
- [ ] Tap right ⌥ quickly (below the hold threshold): nothing happens, no
      error panel
- [ ] Hold right ⌥ and press E: dictation cancels and no accent is broken
      (⌥E then E still types é in a text field afterward)
- [ ] Press esc while holding the hotkey: nothing is inserted, recording
      stops silently
- [ ] **(never verified)** Press esc right after releasing, while the panel
      says "Transcribing" or "Polishing": nothing is inserted and no error
      panel appears (this exercises `DictationCoordinator.abort()`, which is
      the only reachable path when the transcription or cleanup call is
      hung, not just slow)
- [ ] Press esc with no dictation running: normal esc behavior in the
      focused app is unaffected (for example, esc still closes a dialog)
- [ ] Rebind to right ⌘ in Settings and confirm it works without a relaunch
- [ ] Rebind to a custom combo (⌃⇧D) and confirm the keystroke does not
      reach the app you were typing in
- [ ] **(never verified)** Rebind to fn with System Settings > Keyboard >
      "Press 🌐 to" set to anything other than "Do Nothing": Settings shows
      the orange warning and an "Open keyboard settings" button that opens
      the Keyboard pane. Set "Press 🌐 to" to "Do Nothing" and confirm the
      warning disappears and fn now works as the dictation key
- [ ] **(never verified)** Hold the hotkey to start a dictation, then, while
      still holding it, switch the binding in Settings to a different key:
      the in-flight recording cancels cleanly (panel dismisses, mic icon
      returns to idle) rather than recording forever. This is the
      `HotkeyMonitor.binding.didSet` calling `matcher.rebind`, which emits
      a `.cancelled` signal for the abandoned dictation

## 3. Insertion across app kinds

Do these back to back; the panel-placement checks in the next section reuse
the same apps.

- [ ] TextEdit: dictated text lands at the caret
- [ ] VS Code (Electron): text lands at the caret
- [ ] Terminal: text lands at the prompt
- [ ] Slack or Discord message box: text lands, no stray newline sent
- [ ] Browser text field (Chrome or Safari): text lands

## 4. Clipboard behavior

- [ ] Copy "keepme", dictate something, then ⌘V: pastes "keepme" back (the
      delayed pasteboard restore returned your original clipboard)
- [ ] **(never verified)** Copy "keepme", dictate, and in the roughly 150ms
      window right after the panel shows the dictated text landed, press
      ⌘C to copy something else ("dontclobber"): ⌘V afterward pastes
      "dontclobber", not "keepme". This exercises the change-count gate in
      `PasteboardTextInserter`, which exists so a delayed restore cannot
      stomp a newer copy
- [ ] **(never verified)** Fire two dictations back to back, faster than the
      ~150ms restore delay between them (e.g. hold-release-hold-release
      quickly for two short phrases): the second dictation's text is what
      ends up pasted, and the first dictation's pending clipboard restore
      does not overwrite it afterward

## 5. Panel placement

- [ ] Native app with a caret (TextEdit): panel floats just above the caret
- [ ] App reporting no caret (most Electron apps): panel appears near the
      bottom center
- [ ] Caret near the top of the screen: panel flips below it instead of
      clipping off the top
- [ ] Second display: panel appears on the display holding the caret
- [ ] **(never verified)** Put an app into native full screen (its own
      Space) and dictate into it: the panel still appears on top instead of
      being invisible. This is what `.fullScreenAuxiliary` on the panel's
      `collectionBehavior` was added for; it has never been seen working
- [ ] Focus never moves: the app you were typing in stays active (frontmost,
      cursor blinking) throughout every check above

## 6. Cleanup (OpenRouter polish)

- [ ] With a valid key: "so um I was uh thinking" inserts without the
      fillers
- [ ] Wrong key in Settings: raw transcript still inserts, panel shows no
      scary error
- [ ] Wi-Fi off: raw transcript inserts within about 3 seconds (the hard
      cleanup timeout)
- [ ] Cleanup toggled off: raw transcript inserts immediately
- [ ] Settings > Cleanup > Test returns cleaned sample text

## 7. Models

- [ ] Install a Whisper model: progress advances, then it shows Installed
- [ ] Make it active in Settings: the menu bar's model name updates to it
      immediately, and the next dictation uses it
- [ ] **(never verified)** While a model is downloading, kill the network
      (Wi-Fi off, or unplug ethernet) partway through: Settings shows a
      visible error rather than a silently stuck progress bar. Restore the
      network and retry the install: it succeeds
- [ ] Delete a model: it returns to Not installed and its files are gone
      from `~/Library/Application Support/DogballWhisper/Models` (Whisper
      variants; Parakeet's own mirror-managed folder lives alongside it,
      see `ModelCatalog.installedLocation`)
- [ ] Quit mid-download, relaunch, download again: it resumes rather than
      restarting from zero
- [ ] **(never verified)** With two models installed, switch the active one
      in Settings, then open the menu bar menu without touching Settings
      again: the name shown is the newly active model, not the previous one
      or a stale label

## 8. Lifecycle

- [ ] **(never verified)** Launch at login on, then a real reboot (not just
      relaunching the app): the app is in the menu bar with no window open,
      and dictation works with no re-prompting for permissions
- [ ] Launch at login off, reboot: the app does not start
- [ ] **(never verified)** Rebuild (`./scripts/build-mac.sh`) and reinstall
      over the existing app, then relaunch: macOS does not ask for any
      permission again. This is the stable bundle ID and signing identity
      property; if it ever fails, check that neither changed
- [ ] No Dock icon and no window at launch once onboarding is done

## 9. Microphone integration test

The audio pipeline has an XCTest that talks to the real microphone. It is
gated because it needs an actual mic permission grant for the *test host*
process, not the app, and there is no way to grant that non-interactively.
Run it yourself at a machine with a mic and permissions available:

    RUN_AUDIO_IT=1 ./scripts/test.sh DogballWhisperTests/AudioRecorderTests

`scripts/test.sh` forwards `RUN_AUDIO_IT` (and `RUN_ENGINE_IT`,
`RUN_MIRROR_IT`) into the test host as `TEST_RUNNER_RUN_AUDIO_IT` etc.
because `xcodebuild` launches the test host through LaunchServices, which
does not inherit the invoking shell's environment; only Xcode's
`TEST_RUNNER_`-prefixed variables get copied through. If this test can't see
the gate, check that mechanism before assuming the test itself is broken.

This cannot run headlessly or in CI. **(never verified)**: run it at least
once per macOS version you ship to.
