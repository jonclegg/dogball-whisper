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

- [ ] Fresh install, or the full reset below, then launch: the setup window
      appears, not the dictation panel. All four commands matter. Leaving the
      preferences plist behind keeps the onboarding flag and the active model,
      and leaving `FluidAudio` behind keeps the whole Parakeet download, so
      skipping either leaves you testing a returning launch, not a first run:

          rm -rf ~/Library/Application\ Support/DogballWhisper
          rm -rf ~/Library/Application\ Support/FluidAudio
          defaults delete com.jonclegg.DogballWhisper
          tccutil reset All com.jonclegg.DogballWhisper
- [ ] Grant Microphone from the setup window: the row turns green immediately
- [ ] Grant Input Monitoring from the setup window: macOS offers to quit and
      reopen the app; the hotkey does not work until you accept that
- [ ] Grant Accessibility from the setup window: the row turns green within
      a second (it is polled, not pushed)
- [ ] Download the default model from the setup window: progress advances,
      then "Start dictating" becomes enabled
- [ ] **(never verified)** Installed but not active: with the model files
      already downloaded, run `defaults delete com.jonclegg.DogballWhisper`
      and relaunch. The model row offers a "Use" button rather than a bare
      checkmark, and clicking it enables "Start dictating". A checkmark with
      no control there would be a dead end, since finishing needs an *active*
      model, not just an installed one
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
- [ ] Secure-field refusal: click into a password field (Safari or Chrome's
      own sign-in form works, or any macOS password prompt) and hold the
      dictation key. Recording never starts — no mic level animation, no
      "Recording" panel — and the panel shows the notice "Not in a password
      field" instead. Confirm nothing is pasted and no request is made to
      OpenRouter (this is the one case a leak would mean shipping a
      password to a third party, so treat any deviation as a blocker, not
      a nit)
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
- [ ] **(never verified)** Focus-change gate: start dictating into TextEdit,
      then ⌘-Tab to another app *before* releasing the key. Nothing is pasted
      into the app you switched to, the panel says the text was copied to the
      clipboard, and ⌘V in TextEdit afterward pastes it. The spec calls
      pasting into the wrong window the one unrecoverable failure mode, and
      no test covers this gate, so it is only ever checked here

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
- [ ] **(never verified)** Promised or lazy clipboard payload: copy a file
      from Finder (a file promise) or a large image from Preview, then
      dictate. Nothing stalls while the snapshot resolves every declared
      type, the dictated text lands, and ⌘V afterward still pastes the
      original file or image, not a placeholder. This is the one clipboard
      shape `PasteboardSnapshot` cannot capture lazily, so it forces every
      type to resolve up front

## 5. Panel placement

- [ ] Native app with a caret (TextEdit): panel floats just above the caret
- [ ] Browser text field (Twitter/X compose box, and a Gmail compose body):
      panel floats just above the caret, not at the bottom of the screen.
      This is the main case `CaretLocator`'s app-rooted query plus text-leaf
      descent exists for
- [ ] Electron app (VS Code's editor or find box, and a Slack message box):
      panel floats just above the caret. This depends on the
      `AXEnhancedUserInterface`/`AXManualAccessibility` nudge landing before
      the first query — if the panel appears at the bottom center on the
      *first* dictation in a freshly-focused Electron app but follows the
      caret correctly from the second dictation onward, the nudge is
      arriving but the tree isn't built yet on the very first query; note
      that distinction rather than just pass/fail
- [ ] A field where no rect at all is available: panel falls back to bottom
      center rather than to some earlier bad position, and nothing traps
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
      network and retry the install: it resumes from where it stopped rather
      than starting over, it succeeds, and the error message disappears
      instead of sitting next to the finished model
- [ ] Delete a model: it returns to Not installed and its files are gone
      from `~/Library/Application Support/DogballWhisper/Models` (Whisper
      variants; Parakeet's own mirror-managed folder lives alongside it,
      see `ModelCatalog.installedLocation`)
- [ ] Quit mid-download, relaunch, download again: it resumes rather than
      restarting from zero. Progress picks up near the fraction it stopped at
      instead of 0%, and the `.partial` file in the model directory keeps
      growing from the size it already had. Do this well into the download so
      you are inside `Encoder.mlmodelc/weights/weight.bin`, which is 92% of
      the payload and the only file where whole-file resume would have been
      indistinguishable from starting over
- [ ] **(never verified)** Click "Use" on a large model and watch the row
      while it loads: a spinner replaces the button, and Install, Use, and
      Delete are disabled on every row until the load finishes. Double-clicking
      "Use" must not start two activations
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

## 9. Latency

The spec's budget is under 1.5 seconds from key release to inserted text for
a five-second utterance, with cleanup enabled. Nothing in the suite measures
this, so measure it here, on the active model you actually ship with.

- [ ] **(never verified)** Dictate a five-second sentence into TextEdit and
      time from the moment you let go of the key to the moment the text
      appears: under 1.5 seconds. Do it three times and take the worst, not
      the best. If it misses, note which stage is slow (the panel shows
      "Transcribing" and "Polishing" separately) rather than just the total
- [ ] **(never verified)** Same measurement on a cold start (first dictation
      after launch): slower is expected, but note the number, since that is
      the one a new user sees first
- [ ] **(never verified)** No clipped first word: press the key and start
      talking immediately, with no pause. The first word is in the transcript.
      `AudioRecorder` pre-arms the next recording with `prepareToRecord()` at
      launch and after every dictation, so `start()` should just be a
      `record()` call on already-opened hardware; this is the only way to
      confirm that actually removes the clip, since nothing in the test
      suite can touch the real microphone. If the first word is missing,
      check whether a prepared recorder was actually available (see
      `AudioRecorder.prewarm()`) or whether it fell back to preparing inline

## 10. Microphone integration test

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
