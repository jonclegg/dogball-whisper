# Dogball Whisper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS menu-bar dictation client: hold right ⌥, talk, release, and the transcribed and cleaned-up text is pasted into whatever field had focus.

**Architecture:** One `LSUIElement` SwiftUI + AppKit app. A `CGEventTap` detects the hold-to-talk key, `AVAudioRecorder` writes a 16kHz mono WAV, an on-device engine (FluidAudio/Parakeet or WhisperKit) transcribes the file, OpenRouter cleans the text, and a synthetic ⌘V pastes it. `DictationCoordinator` is the only stateful piece and talks exclusively to protocols, so its whole state machine is unit-testable with fakes.

**Tech Stack:** Swift 5.10, SwiftUI + AppKit, XCTest, xcodegen, FluidAudio 0.15.x, WhisperKit 0.18.x, Accessibility (AX) API, CoreGraphics event taps, `SMAppService`.

**Spec:** `docs/superpowers/specs/2026-07-25-mac-dictation-client-design.md`

## Global Constraints

- Deployment target **macOS 14.0**, Apple Silicon. (FluidAudio's floor is macOS 14.)
- `SWIFT_VERSION: "5.10"` on every target. Swift 6 strict concurrency fights event taps and AX callbacks for no benefit here.
- **No App Sandbox and no Hardened Runtime.** An Accessibility client cannot be sandboxed; hardened runtime would require extra entitlements for the mic. No entitlements file at all.
- Signed with **`Developer ID Application: Jonathan Clegg (22CTWHGWQQ)`**, bundle ID **`com.jonclegg.DogballWhisper`**, both fixed forever. macOS keys Accessibility and Input Monitoring grants to the signature plus bundle ID — changing either makes the user re-grant every permission.
- **Never open Xcode.** Everything is `xcodegen` + `xcodebuild` from `scripts/`. The `.xcodeproj` is gitignored.
- Audio never leaves the machine. Only transcript text is sent to OpenRouter, and only when a key is present.
- The OpenRouter API key lives in the Keychain, never in `UserDefaults`, never logged.
- Cleanup failure must never lose a dictation: every error, timeout, or missing-key path inserts the raw transcript.
- Transcription is file-based: `transcribe(_ audioURL: URL) async throws -> String`. Both frameworks take a file (FluidAudio `transcribe(_ url:decoderState:)`, WhisperKit `transcribe(audioPath:)`), so the recorder writes a WAV and the URL is passed straight through. (This supersedes the spec's `[Float]` signature.)
- User-visible copy is sentence case, no exclamation marks, no em dashes.
- Commit after every task. Conventional-commit prefixes (`feat:`, `test:`, `chore:`).

## File Structure

```
project.yml                          xcodegen spec (app target + test target + scheme)
scripts/build-mac.sh                 generate, build, sign, install into /Applications
scripts/test.sh                      xcodebuild test wrapper
DogballWhisper/
  App/DogballWhisperApp.swift        @main NSApplicationDelegate, owns the coordinator
  App/MenuBarController.swift        NSStatusItem, state icon, menu
  App/LoginItem.swift                SMAppService register/unregister
  Core/Preferences.swift             typed UserDefaults wrapper
  Core/KeychainStore.swift           OpenRouter key storage
  Core/DictationCoordinator.swift    the state machine
  Core/Permissions.swift             mic / input monitoring / accessibility probes
  Hotkey/HotkeyBinding.swift         binding model + key code constants
  Hotkey/HotkeyMatcher.swift         pure event -> signal state machine
  Hotkey/HotkeyMonitor.swift         CGEventTap wrapper feeding the matcher
  Capture/AudioRecorder.swift        AVAudioRecorder, 16kHz mono WAV, level meter
  Transcribe/TranscriptionEngine.swift   protocol + EngineKind
  Transcribe/ParakeetEngine.swift    FluidAudio AsrManager
  Transcribe/WhisperKitEngine.swift  WhisperKit pipeline
  Transcribe/ModelMirror.swift       CloudFront Parakeet downloader (ported)
  Transcribe/ModelCatalog.swift      installable model descriptors + install state
  Transcribe/ModelManager.swift      install / delete / activate + progress
  Transcribe/parakeet-manifest.json  bundled manifest (copied from whisper-polish)
  Polish/PolishService.swift         OpenRouter cleanup
  Insert/CaretLocator.swift          AX focused element -> caret rect + pid
  Insert/TextInserter.swift          pasteboard snapshot + synthetic ⌘V
  Insert/PasteboardSnapshot.swift    save/restore pasteboard contents
  UI/DictationPanel.swift            non-activating NSPanel host
  UI/PanelPositioner.swift           pure geometry: caret rect -> panel origin
  UI/WaveformView.swift              level bars
  UI/SettingsView.swift              General / Models / Cleanup tabs
  UI/ShortcutRecorderView.swift      captures a custom combo
  UI/OnboardingView.swift            permissions -> model -> hotkey -> key
Tests/
  HotkeyMatcherTests.swift  AudioRecorderTests.swift  PanelPositionerTests.swift
  PasteboardSnapshotTests.swift  DictationCoordinatorTests.swift  PolishServiceTests.swift
  ModelCatalogTests.swift  ModelMirrorIntegrationTests.swift  PreferencesTests.swift
  EngineIntegrationTests.swift  Fixtures/hello.wav
docs/MANUAL-SMOKE.md                 the checklist that covers what can't be faked
```

Tasks 1–7 build a working end-to-end dictation with no UI polish. Tasks 8–13 layer on the panel, cleanup, model management, settings, onboarding, and login item.

---

### Task 1: Project skeleton, build script, menu-bar stub

**Files:**
- Create: `project.yml`, `scripts/build-mac.sh`, `scripts/test.sh`, `DogballWhisper/App/DogballWhisperApp.swift`, `DogballWhisper/App/MenuBarController.swift`, `Tests/SkeletonTests.swift`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: `MenuBarController` with `init()` and `var statusItem: NSStatusItem`; app target named `DogballWhisper`; `scripts/build-mac.sh [--launch]`; `scripts/test.sh [test-filter]`.

- [ ] **Step 1: Write `project.yml`**

```yaml
name: DogballWhisper
options:
  bundleIdPrefix: com.jonclegg
  deploymentTarget:
    macOS: "14.0"
  createIntermediateGroups: true

packages:
  FluidAudio:
    url: https://github.com/FluidInference/FluidAudio
    from: 0.15.4
  WhisperKit:
    url: https://github.com/argmaxinc/WhisperKit
    from: 0.18.0

targets:
  DogballWhisper:
    type: application
    platform: macOS
    sources:
      - path: DogballWhisper
    dependencies:
      - package: FluidAudio
      - package: WhisperKit
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.jonclegg.DogballWhisper
        PRODUCT_NAME: Dogball Whisper
        MARKETING_VERSION: "1.0"
        CURRENT_PROJECT_VERSION: "1"
        SWIFT_VERSION: "5.10"
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_LSUIElement: YES
        INFOPLIST_KEY_NSHumanReadableCopyright: ""
        INFOPLIST_KEY_NSMicrophoneUsageDescription: "Dogball Whisper records your voice while you hold the dictation key, and transcribes it on this Mac."
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: "Developer ID Application"
        DEVELOPMENT_TEAM: 22CTWHGWQQ
        ENABLE_HARDENED_RUNTIME: NO
        ENABLE_APP_SANDBOX: NO
        ENABLE_USER_SCRIPT_SANDBOXING: NO

  DogballWhisperTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: Tests
    dependencies:
      - target: DogballWhisper
    settings:
      base:
        SWIFT_VERSION: "5.10"
        GENERATE_INFOPLIST_FILE: YES

schemes:
  DogballWhisper:
    build:
      targets:
        DogballWhisper: all
        DogballWhisperTests: [test]
    run:
      config: Debug
    test:
      config: Debug
      targets:
        - DogballWhisperTests
```

- [ ] **Step 2: Write the app entry point and menu-bar stub**

`DogballWhisper/App/DogballWhisperApp.swift`:

```swift
import AppKit

@main
enum DogballWhisperMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController()
    }
}
```

`DogballWhisper/App/MenuBarController.swift`:

```swift
import AppKit

/// Owns the status-bar item. Task 7 gives it live dictation state.
final class MenuBarController {
    let statusItem: NSStatusItem

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "mic",
            accessibilityDescription: "Dogball Whisper"
        )

        let menu = NSMenu()
        menu.addItem(
            withTitle: "Quit Dogball Whisper",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        statusItem.menu = menu
    }
}
```

- [ ] **Step 3: Write the build and test scripts**

`scripts/build-mac.sh`:

```bash
#!/usr/bin/env bash
# Generates the project, builds Release, and installs into /Applications.
# Usage: ./scripts/build-mac.sh [--launch]
set -euo pipefail
cd "$(dirname "$0")/.."

LAUNCH=false
[[ "${1:-}" == "--launch" ]] && LAUNCH=true

xcodegen generate

xcodebuild \
  -project DogballWhisper.xcodeproj \
  -scheme DogballWhisper \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  -destination 'platform=macOS' \
  build

APP="build/DerivedData/Build/Products/Release/Dogball Whisper.app"
[[ -d "$APP" ]] || { echo "Build product not found at $APP"; exit 1; }

pkill -x "Dogball Whisper" 2>/dev/null || true
sleep 1
rm -rf "/Applications/Dogball Whisper.app"
cp -R "$APP" /Applications/
echo "Installed /Applications/Dogball Whisper.app"

codesign --verify --strict "/Applications/Dogball Whisper.app"

# An `$LAUNCH && open ...` one-liner here would make the no-flag invocation
# exit 1, because `false` would be the last command the script ran.
if [[ "$LAUNCH" == true ]]; then
  open "/Applications/Dogball Whisper.app"
fi
```

`scripts/test.sh`:

```bash
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
  "${ARGS[@]}"
```

Then `chmod +x scripts/*.sh`.

- [ ] **Step 4: Write a skeleton test**

`Tests/SkeletonTests.swift`:

```swift
import XCTest
@testable import DogballWhisper

final class SkeletonTests: XCTestCase {
    func testMenuBarControllerCreatesAStatusItemWithAMenu() {
        let controller = MenuBarController()
        XCTAssertNotNil(controller.statusItem.button)
        XCTAssertEqual(controller.statusItem.menu?.items.count, 1)
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `./scripts/test.sh`
Expected: PASS. First run resolves FluidAudio and WhisperKit from SwiftPM, which takes a few minutes.

- [ ] **Step 6: Add the build outputs to `.gitignore`**

Append to `.gitignore` (it already has `build/`, `*.xcodeproj`, `.claude/worktrees/`):

```
DerivedData/
*.xcuserstate
```

- [ ] **Step 7: Install and verify by hand**

Run: `./scripts/build-mac.sh --launch`
Expected: a mic glyph appears in the menu bar, no Dock icon, no window. Clicking it shows "Quit Dogball Whisper".

- [ ] **Step 8: Commit**

```bash
git add project.yml scripts DogballWhisper Tests .gitignore
git commit -m "feat: menu-bar app skeleton with headless build script"
```

---

### Task 2: Preferences and Keychain storage

**Files:**
- Create: `DogballWhisper/Core/Preferences.swift`, `DogballWhisper/Core/KeychainStore.swift`, `Tests/PreferencesTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `final class Preferences` with `init(defaults: UserDefaults = .standard)` and mutable properties `hotkeyBinding: HotkeyBinding` (defined in Task 3 — until then, store `Data`), `activeModelID: String?`, `cleanupEnabled: Bool`, `cleanupModelID: String`, `cleanupPrompt: String`, `insertionMode: InsertionMode`, `hasCompletedOnboarding: Bool`. Static `Preferences.defaultCleanupPrompt: String` and `Preferences.defaultCleanupModelID: String`.
  - `enum InsertionMode: String, Codable { case paste, clipboardOnly }`
  - `enum KeychainStore` with `@discardableResult static func save(_ key: String) -> Bool`, `static func read() -> String?`, `@discardableResult static func delete() -> Bool`.

- [ ] **Step 1: Write the failing tests**

`Tests/PreferencesTests.swift`:

```swift
import XCTest
@testable import DogballWhisper

final class PreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "DogballWhisperTests.Preferences"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultsAreUsableOnFirstLaunch() {
        let prefs = Preferences(defaults: defaults)
        XCTAssertNil(prefs.activeModelID)
        XCTAssertTrue(prefs.cleanupEnabled)
        XCTAssertEqual(prefs.cleanupModelID, Preferences.defaultCleanupModelID)
        XCTAssertEqual(prefs.cleanupPrompt, Preferences.defaultCleanupPrompt)
        XCTAssertEqual(prefs.insertionMode, .paste)
        XCTAssertFalse(prefs.hasCompletedOnboarding)
    }

    func testValuesRoundTripThroughDefaults() {
        let prefs = Preferences(defaults: defaults)
        prefs.activeModelID = "parakeet-v3"
        prefs.cleanupEnabled = false
        prefs.insertionMode = .clipboardOnly
        prefs.cleanupPrompt = "Strip the ums."
        prefs.hasCompletedOnboarding = true

        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.activeModelID, "parakeet-v3")
        XCTAssertFalse(reloaded.cleanupEnabled)
        XCTAssertEqual(reloaded.insertionMode, .clipboardOnly)
        XCTAssertEqual(reloaded.cleanupPrompt, "Strip the ums.")
        XCTAssertTrue(reloaded.hasCompletedOnboarding)
    }

    func testEmptyCleanupPromptFallsBackToTheDefault() {
        let prefs = Preferences(defaults: defaults)
        prefs.cleanupPrompt = "   "
        XCTAssertEqual(prefs.cleanupPrompt, Preferences.defaultCleanupPrompt)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh DogballWhisperTests/PreferencesTests`
Expected: FAIL — "cannot find 'Preferences' in scope".

- [ ] **Step 3: Implement `Preferences`**

`DogballWhisper/Core/Preferences.swift`:

```swift
import Foundation

enum InsertionMode: String, Codable {
    case paste
    case clipboardOnly
}

/// Typed wrapper over UserDefaults. Everything the user can configure except
/// the OpenRouter key, which lives in the Keychain.
final class Preferences {
    private enum Key {
        static let hotkeyBinding = "hotkeyBinding"
        static let activeModelID = "activeModelID"
        static let cleanupEnabled = "cleanupEnabled"
        static let cleanupModelID = "cleanupModelID"
        static let cleanupPrompt = "cleanupPrompt"
        static let insertionMode = "insertionMode"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    static let defaultCleanupModelID = "anthropic/claude-haiku-4.5"

    static let defaultCleanupPrompt = """
        Clean up this dictated text. Remove filler words (um, uh, like, you know), \
        false starts, stutters, and repeated words. Fix punctuation and capitalization. \
        Do not rephrase, reorder, summarize, or add anything. Keep the speaker's exact \
        wording and voice otherwise. Return only the cleaned text.
        """

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.cleanupEnabled: true,
            Key.cleanupModelID: Self.defaultCleanupModelID,
            Key.insertionMode: InsertionMode.paste.rawValue,
        ])
    }

    var activeModelID: String? {
        get { defaults.string(forKey: Key.activeModelID) }
        set { defaults.set(newValue, forKey: Key.activeModelID) }
    }

    var cleanupEnabled: Bool {
        get { defaults.bool(forKey: Key.cleanupEnabled) }
        set { defaults.set(newValue, forKey: Key.cleanupEnabled) }
    }

    var cleanupModelID: String {
        get {
            let stored = defaults.string(forKey: Key.cleanupModelID) ?? ""
            return stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Self.defaultCleanupModelID : stored
        }
        set { defaults.set(newValue, forKey: Key.cleanupModelID) }
    }

    /// Blank prompts would silently turn cleanup into a passthrough, so an
    /// empty value reads back as the default instead.
    var cleanupPrompt: String {
        get {
            let stored = defaults.string(forKey: Key.cleanupPrompt) ?? ""
            return stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Self.defaultCleanupPrompt : stored
        }
        set { defaults.set(newValue, forKey: Key.cleanupPrompt) }
    }

    var insertionMode: InsertionMode {
        get { InsertionMode(rawValue: defaults.string(forKey: Key.insertionMode) ?? "") ?? .paste }
        set { defaults.set(newValue.rawValue, forKey: Key.insertionMode) }
    }

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Key.hasCompletedOnboarding) }
        set { defaults.set(newValue, forKey: Key.hasCompletedOnboarding) }
    }

    /// Raw storage for the hotkey binding; Task 3 encodes/decodes it.
    var hotkeyBindingData: Data? {
        get { defaults.data(forKey: Key.hotkeyBinding) }
        set { defaults.set(newValue, forKey: Key.hotkeyBinding) }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh DogballWhisperTests/PreferencesTests`
Expected: PASS.

- [ ] **Step 5: Implement `KeychainStore`**

`DogballWhisper/Core/KeychainStore.swift`:

```swift
import Foundation
import Security

/// Stores the OpenRouter API key in the login keychain. Never logged,
/// never written to UserDefaults.
enum KeychainStore {
    private static let service = "com.jonclegg.DogballWhisper"
    private static let account = "openrouter-api-key"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        delete()
        guard !key.isEmpty else { return true }
        var query = baseQuery
        query[kSecValueData as String] = Data(key.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    @discardableResult
    static func delete() -> Bool {
        SecItemDelete(baseQuery as CFDictionary) == errSecSuccess
    }
}
```

There is no unit test for `KeychainStore`: writing to the real login keychain from a test bundle prompts for authorization and pollutes the user's keychain. It is covered by the Settings "Test" button in Task 11 and the manual checklist.

- [ ] **Step 6: Run the full suite**

Run: `./scripts/test.sh`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add DogballWhisper/Core Tests/PreferencesTests.swift
git commit -m "feat: typed preferences and keychain storage"
```

---

### Task 3: Hotkey binding, matcher, and event tap

**Files:**
- Create: `DogballWhisper/Hotkey/HotkeyBinding.swift`, `DogballWhisper/Hotkey/HotkeyMatcher.swift`, `DogballWhisper/Hotkey/HotkeyMonitor.swift`, `Tests/HotkeyMatcherTests.swift`
- Modify: `DogballWhisper/Core/Preferences.swift`

**Interfaces:**
- Consumes: `Preferences.hotkeyBindingData`.
- Produces:
  - `struct HotkeyBinding: Codable, Equatable` with `static let rightOption/rightCommand/fn: HotkeyBinding`, `init(comboKeyCode: UInt16, modifiers: CGEventFlags)`, `var displayName: String`, `var isModifierOnly: Bool`.
  - `enum HotkeyInput { case flagsChanged(keyCode: UInt16, flags: CGEventFlags), keyDown(keyCode: UInt16, flags: CGEventFlags) }`
  - `enum HotkeySignal { case began, ended, cancelled }`
  - `struct HotkeyMatcher` with `init(binding: HotkeyBinding)`, `var binding: HotkeyBinding`, `private(set) var isEngaged: Bool`, `mutating func handle(_ input: HotkeyInput) -> HotkeySignal?`, and `func consumesEvent(_ input: HotkeyInput) -> Bool`.
  - `final class HotkeyMonitor` with `init(binding: HotkeyBinding, onSignal: @escaping (HotkeySignal) -> Void)`, `func start() throws`, `func stop()`, `var binding: HotkeyBinding { get set }`, `var onEscape: (() -> Void)?`.
  - `Preferences.hotkeyBinding: HotkeyBinding` (decoded, defaulting to `.rightOption`).

- [ ] **Step 1: Write the failing tests**

`Tests/HotkeyMatcherTests.swift`:

```swift
import XCTest
import CoreGraphics
@testable import DogballWhisper

final class HotkeyMatcherTests: XCTestCase {

    // Right option pressed alone starts a dictation; releasing it ends one.
    func testModifierOnlyBindingBeginsAndEnds() {
        var matcher = HotkeyMatcher(binding: .rightOption)

        XCTAssertEqual(matcher.handle(.flagsChanged(keyCode: 61, flags: [.maskAlternate])), .began)
        XCTAssertTrue(matcher.isEngaged)
        XCTAssertEqual(matcher.handle(.flagsChanged(keyCode: 61, flags: [])), .ended)
        XCTAssertFalse(matcher.isEngaged)
    }

    // The left option key must not trigger a binding on the right one.
    func testOppositeSideKeyIsIgnored() {
        var matcher = HotkeyMatcher(binding: .rightOption)
        XCTAssertNil(matcher.handle(.flagsChanged(keyCode: 58, flags: [.maskAlternate])))
        XCTAssertFalse(matcher.isEngaged)
    }

    // Holding shift and then pressing right option is a different gesture;
    // starting there would hijack real shortcuts.
    func testDoesNotBeginWhenAnotherModifierIsAlreadyHeld() {
        var matcher = HotkeyMatcher(binding: .rightOption)
        XCTAssertNil(matcher.handle(.flagsChanged(keyCode: 61, flags: [.maskAlternate, .maskShift])))
        XCTAssertFalse(matcher.isEngaged)
    }

    // This is what keeps option-e (accents) and option-click shortcuts working:
    // any real key pressed while the hotkey is held abandons the dictation.
    func testKeyPressedWhileEngagedCancels() {
        var matcher = HotkeyMatcher(binding: .rightOption)
        XCTAssertEqual(matcher.handle(.flagsChanged(keyCode: 61, flags: [.maskAlternate])), .began)
        XCTAssertEqual(matcher.handle(.keyDown(keyCode: 14, flags: [.maskAlternate])), .cancelled)
        XCTAssertFalse(matcher.isEngaged)
        // The later release must not be reported as a normal end.
        XCTAssertNil(matcher.handle(.flagsChanged(keyCode: 61, flags: [])))
    }

    func testAnotherModifierPressedWhileEngagedCancels() {
        var matcher = HotkeyMatcher(binding: .rightOption)
        XCTAssertEqual(matcher.handle(.flagsChanged(keyCode: 61, flags: [.maskAlternate])), .began)
        XCTAssertEqual(
            matcher.handle(.flagsChanged(keyCode: 56, flags: [.maskAlternate, .maskShift])),
            .cancelled
        )
    }

    // Bits like non-coalesced and caps lock ride along on real events and
    // must not read as "another modifier is down".
    func testIrrelevantFlagBitsAreIgnored() {
        var matcher = HotkeyMatcher(binding: .rightOption)
        let noisy: CGEventFlags = [.maskAlternate, .maskNonCoalesced, .maskAlphaShift]
        XCTAssertEqual(matcher.handle(.flagsChanged(keyCode: 61, flags: noisy)), .began)
    }

    func testFnBindingUsesTheSecondaryFnMask() {
        var matcher = HotkeyMatcher(binding: .fn)
        XCTAssertEqual(matcher.handle(.flagsChanged(keyCode: 63, flags: [.maskSecondaryFn])), .began)
        XCTAssertEqual(matcher.handle(.flagsChanged(keyCode: 63, flags: [])), .ended)
    }

    // A custom combo begins on key down and ends when the key or its
    // modifiers are released.
    func testComboBindingBeginsOnKeyDownAndEndsOnRelease() {
        var matcher = HotkeyMatcher(
            binding: HotkeyBinding(comboKeyCode: 49, modifiers: [.maskAlternate])
        )
        XCTAssertEqual(matcher.handle(.keyDown(keyCode: 49, flags: [.maskAlternate])), .began)
        XCTAssertEqual(matcher.handle(.flagsChanged(keyCode: 58, flags: [])), .ended)
    }

    // Combos must be swallowed or the app would also receive the keystroke.
    // Modifier-only bindings must never be swallowed.
    func testOnlyComboEventsAreConsumed() {
        let combo = HotkeyMatcher(binding: HotkeyBinding(comboKeyCode: 49, modifiers: [.maskAlternate]))
        XCTAssertTrue(combo.consumesEvent(.keyDown(keyCode: 49, flags: [.maskAlternate])))
        XCTAssertFalse(combo.consumesEvent(.keyDown(keyCode: 14, flags: [.maskAlternate])))

        let modifierOnly = HotkeyMatcher(binding: .rightOption)
        XCTAssertFalse(modifierOnly.consumesEvent(.flagsChanged(keyCode: 61, flags: [.maskAlternate])))
    }

    func testDisplayNames() {
        XCTAssertEqual(HotkeyBinding.rightOption.displayName, "Right ⌥")
        XCTAssertEqual(HotkeyBinding.rightCommand.displayName, "Right ⌘")
        XCTAssertEqual(HotkeyBinding.fn.displayName, "fn")
        XCTAssertEqual(
            HotkeyBinding(comboKeyCode: 49, modifiers: [.maskAlternate]).displayName,
            "⌥Space"
        )
    }

    func testBindingSurvivesEncodingRoundTrip() throws {
        let binding = HotkeyBinding(comboKeyCode: 49, modifiers: [.maskAlternate, .maskControl])
        let data = try JSONEncoder().encode(binding)
        XCTAssertEqual(try JSONDecoder().decode(HotkeyBinding.self, from: data), binding)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh DogballWhisperTests/HotkeyMatcherTests`
Expected: FAIL — "cannot find 'HotkeyMatcher' in scope".

- [ ] **Step 3: Implement `HotkeyBinding`**

`DogballWhisper/Hotkey/HotkeyBinding.swift`:

```swift
import CoreGraphics
import Foundation

/// Virtual key codes for the modifier keys we can bind. flagsChanged events
/// carry the code of the physical key that changed, which is the only way to
/// tell left from right (the flag masks themselves are side-agnostic).
enum ModifierKeyCode {
    static let rightCommand: UInt16 = 54
    static let leftCommand: UInt16 = 55
    static let leftShift: UInt16 = 56
    static let leftOption: UInt16 = 58
    static let rightOption: UInt16 = 61
    static let rightShift: UInt16 = 60
    static let leftControl: UInt16 = 59
    static let rightControl: UInt16 = 62
    static let fn: UInt16 = 63

    /// The device-independent flag that appears when this key goes down.
    static func mask(for keyCode: UInt16) -> CGEventFlags? {
        switch keyCode {
        case rightCommand, leftCommand: return .maskCommand
        case leftShift, rightShift: return .maskShift
        case leftOption, rightOption: return .maskAlternate
        case leftControl, rightControl: return .maskControl
        case fn: return .maskSecondaryFn
        default: return nil
        }
    }
}

/// Hashable because SwiftUI's hotkey Picker tags rows with binding values.
struct HotkeyBinding: Codable, Equatable, Hashable {
    enum Kind: String, Codable {
        case modifierOnly
        case combo
    }

    let kind: Kind
    let keyCode: UInt16
    /// Raw CGEventFlags bits. Empty for modifier-only bindings.
    let modifierBits: UInt64

    var modifiers: CGEventFlags { CGEventFlags(rawValue: modifierBits) }
    var isModifierOnly: Bool { kind == .modifierOnly }

    static let rightOption = HotkeyBinding(
        kind: .modifierOnly, keyCode: ModifierKeyCode.rightOption, modifierBits: 0)
    static let rightCommand = HotkeyBinding(
        kind: .modifierOnly, keyCode: ModifierKeyCode.rightCommand, modifierBits: 0)
    static let fn = HotkeyBinding(
        kind: .modifierOnly, keyCode: ModifierKeyCode.fn, modifierBits: 0)

    init(kind: Kind, keyCode: UInt16, modifierBits: UInt64) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifierBits = modifierBits
    }

    init(comboKeyCode: UInt16, modifiers: CGEventFlags) {
        self.init(kind: .combo, keyCode: comboKeyCode, modifierBits: modifiers.rawValue)
    }

    var displayName: String {
        switch kind {
        case .modifierOnly:
            switch keyCode {
            case ModifierKeyCode.rightOption: return "Right ⌥"
            case ModifierKeyCode.rightCommand: return "Right ⌘"
            case ModifierKeyCode.fn: return "fn"
            default: return "Key \(keyCode)"
            }
        case .combo:
            var name = ""
            if modifiers.contains(.maskControl) { name += "⌃" }
            if modifiers.contains(.maskAlternate) { name += "⌥" }
            if modifiers.contains(.maskShift) { name += "⇧" }
            if modifiers.contains(.maskCommand) { name += "⌘" }
            return name + KeyCodeNames.name(for: keyCode)
        }
    }
}

enum KeyCodeNames {
    private static let names: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
        34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        36: "Return", 48: "Tab", 49: "Space", 53: "Escape",
    ]

    static func name(for keyCode: UInt16) -> String {
        names[keyCode] ?? "Key \(keyCode)"
    }
}
```

- [ ] **Step 4: Implement `HotkeyMatcher`**

`DogballWhisper/Hotkey/HotkeyMatcher.swift`:

```swift
import CoreGraphics

enum HotkeyInput: Equatable {
    case flagsChanged(keyCode: UInt16, flags: CGEventFlags)
    case keyDown(keyCode: UInt16, flags: CGEventFlags)
}

enum HotkeySignal: Equatable {
    case began
    case ended
    case cancelled
}

/// Pure state machine translating keyboard events into dictation signals.
/// No CoreGraphics tap involved, so every rule above is unit-testable.
struct HotkeyMatcher {
    /// The only flags that matter. Caps lock, numeric pad, help, and the
    /// non-coalesced bit ride along on real events and must be ignored.
    static let relevantMasks: CGEventFlags = [
        .maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn,
    ]

    var binding: HotkeyBinding
    private(set) var isEngaged = false

    init(binding: HotkeyBinding) {
        self.binding = binding
    }

    mutating func handle(_ input: HotkeyInput) -> HotkeySignal? {
        binding.isModifierOnly ? handleModifierOnly(input) : handleCombo(input)
    }

    /// Combo bindings must be swallowed by the tap so the focused app never
    /// receives the keystroke. Modifier-only bindings are always passed
    /// through, since swallowing them would break the modifier itself.
    func consumesEvent(_ input: HotkeyInput) -> Bool {
        guard !binding.isModifierOnly else { return false }
        guard case let .keyDown(keyCode, flags) = input else { return false }
        return keyCode == binding.keyCode && Self.filtered(flags) == binding.modifiers
    }

    private static func filtered(_ flags: CGEventFlags) -> CGEventFlags {
        flags.intersection(relevantMasks)
    }

    private mutating func handleModifierOnly(_ input: HotkeyInput) -> HotkeySignal? {
        guard let targetMask = ModifierKeyCode.mask(for: binding.keyCode) else { return nil }

        switch input {
        case let .keyDown(_, _):
            // Any real key while held means the user is typing a shortcut.
            guard isEngaged else { return nil }
            isEngaged = false
            return .cancelled

        case let .flagsChanged(keyCode, rawFlags):
            let flags = Self.filtered(rawFlags)
            let others = flags.subtracting(targetMask)

            if keyCode == binding.keyCode {
                if flags.contains(targetMask) {
                    guard !isEngaged, others.isEmpty else { return nil }
                    isEngaged = true
                    return .began
                } else {
                    guard isEngaged else { return nil }
                    isEngaged = false
                    return .ended
                }
            }

            // A different modifier changed while we were engaged.
            guard isEngaged, !others.isEmpty else { return nil }
            isEngaged = false
            return .cancelled
        }
    }

    private mutating func handleCombo(_ input: HotkeyInput) -> HotkeySignal? {
        switch input {
        case let .keyDown(keyCode, rawFlags):
            guard !isEngaged,
                  keyCode == binding.keyCode,
                  Self.filtered(rawFlags) == binding.modifiers
            else { return nil }
            isEngaged = true
            return .began

        case let .flagsChanged(_, rawFlags):
            // Releasing any of the combo's modifiers ends the dictation.
            guard isEngaged, !Self.filtered(rawFlags).contains(binding.modifiers) else { return nil }
            isEngaged = false
            return .ended
        }
    }
}
```

Note: a combo binding ends on modifier release rather than key release, because a held key repeats and macOS does not deliver a keyUp through a `keyDown`-only tap.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/test.sh DogballWhisperTests/HotkeyMatcherTests`
Expected: PASS (all twelve).

- [ ] **Step 6: Implement `HotkeyMonitor`**

`DogballWhisper/Hotkey/HotkeyMonitor.swift`:

```swift
import CoreGraphics
import Foundation

enum HotkeyMonitorError: LocalizedError {
    case tapCreationFailed

    var errorDescription: String? {
        "Dogball Whisper could not watch the keyboard. Grant Input Monitoring in System Settings."
    }
}

/// Wraps a CGEventTap and feeds it into HotkeyMatcher. Deliberately thin:
/// all decisions live in the matcher, which is testable.
final class HotkeyMonitor {
    var binding: HotkeyBinding {
        didSet { matcher.binding = binding }
    }

    /// Called when escape is pressed, so the coordinator can abandon work that
    /// is already in flight. Never consumes the key.
    var onEscape: (() -> Void)?

    private static let escapeKeyCode: UInt16 = 53

    private var matcher: HotkeyMatcher
    private let onSignal: (HotkeySignal) -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    init(binding: HotkeyBinding, onSignal: @escaping (HotkeySignal) -> Void) {
        self.binding = binding
        self.matcher = HotkeyMatcher(binding: binding)
        self.onSignal = onSignal
    }

    func start() throws {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(proxy: proxy, type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw HotkeyMonitorError.tapCreationFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
    }

    private func handle(
        proxy: CGEventTapProxy, type: CGEventType, event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // The system disables a tap that takes too long; re-enable and move on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let input: HotkeyInput
        switch type {
        case .flagsChanged: input = .flagsChanged(keyCode: keyCode, flags: event.flags)
        case .keyDown: input = .keyDown(keyCode: keyCode, flags: event.flags)
        default: return Unmanaged.passUnretained(event)
        }

        if type == .keyDown, keyCode == Self.escapeKeyCode, let onEscape {
            DispatchQueue.main.async { onEscape() }
        }

        let consume = matcher.consumesEvent(input)
        if let signal = matcher.handle(input) {
            let callback = onSignal
            DispatchQueue.main.async { callback(signal) }
        }
        return consume ? nil : Unmanaged.passUnretained(event)
    }
}
```

- [ ] **Step 7: Add the decoded binding to `Preferences`**

Add to `DogballWhisper/Core/Preferences.swift`:

```swift
    var hotkeyBinding: HotkeyBinding {
        get {
            guard let data = hotkeyBindingData,
                  let binding = try? JSONDecoder().decode(HotkeyBinding.self, from: data)
            else { return .rightOption }
            return binding
        }
        set { hotkeyBindingData = try? JSONEncoder().encode(newValue) }
    }
```

Add to `Tests/PreferencesTests.swift`:

```swift
    func testHotkeyBindingDefaultsToRightOptionAndRoundTrips() {
        let prefs = Preferences(defaults: defaults)
        XCTAssertEqual(prefs.hotkeyBinding, .rightOption)

        prefs.hotkeyBinding = .fn
        XCTAssertEqual(Preferences(defaults: defaults).hotkeyBinding, .fn)
    }
```

- [ ] **Step 8: Run the full suite**

Run: `./scripts/test.sh`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add DogballWhisper/Hotkey DogballWhisper/Core/Preferences.swift Tests
git commit -m "feat: hold-to-talk hotkey matcher and event tap"
```

---

### Task 4: Audio recorder

**Files:**
- Create: `DogballWhisper/Capture/AudioRecorder.swift`, `Tests/AudioRecorderTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct RecordedAudio: Equatable { let url: URL; let duration: TimeInterval }`
  - `protocol AudioRecording: AnyObject { var levels: [Float] { get }; func start() throws; func stop() -> RecordedAudio?; func cancel() }`
  - `final class AudioRecorder: AudioRecording` with `init(onLevels: @escaping ([Float]) -> Void = { _ in })`, `static func requestPermission() async -> Bool`, `static func normalizedLevel(fromDb:at:) -> Float`, `static let levelWindowSize = 40`, `static let meterWarmUp: TimeInterval = 0.3`.

- [ ] **Step 1: Write the failing tests**

`Tests/AudioRecorderTests.swift`:

```swift
import XCTest
@testable import DogballWhisper

final class AudioRecorderTests: XCTestCase {

    // The meter reports full scale before it has processed real audio, and the
    // mic's auto-gain settles during the first fraction of a second. Both would
    // draw a spurious burst of tall bars the moment recording starts.
    func testWarmUpReadingsRenderAsSilence() {
        XCTAssertEqual(AudioRecorder.normalizedLevel(fromDb: 0, at: 0.05), 0)
        XCTAssertEqual(AudioRecorder.normalizedLevel(fromDb: -10, at: 0.2), 0)
    }

    func testDecibelsMapIntoZeroToOneAfterWarmUp() {
        XCTAssertEqual(AudioRecorder.normalizedLevel(fromDb: 0, at: 1.0), 1)
        XCTAssertEqual(AudioRecorder.normalizedLevel(fromDb: -25, at: 1.0), 0.5)
        XCTAssertEqual(AudioRecorder.normalizedLevel(fromDb: -50, at: 1.0), 0)
        XCTAssertEqual(AudioRecorder.normalizedLevel(fromDb: -160, at: 1.0), 0)
    }

    func testLevelsStartFullWidthSoTheWaveformDoesNotGrowFromNothing() {
        let recorder = AudioRecorder()
        XCTAssertEqual(recorder.levels.count, AudioRecorder.levelWindowSize)
        XCTAssertTrue(recorder.levels.allSatisfy { $0 == 0 })
    }

    func testStopWithoutStartReturnsNil() {
        let recorder = AudioRecorder()
        XCTAssertNil(recorder.stop())
    }

    // Guards the contract the engines depend on: a real 16kHz mono WAV on disk.
    // Needs mic permission, so it is opt-in: RUN_AUDIO_IT=1 ./scripts/test.sh
    func testRecordsA16kMonoWavFile() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_AUDIO_IT"] == "1")
        let recorder = AudioRecorder()
        try recorder.start()
        try await Task.sleep(nanoseconds: 500_000_000)
        let result = try XCTUnwrap(recorder.stop())

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
        XCTAssertGreaterThan(result.duration, 0.3)

        let file = try AVAudioFile(forReading: result.url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)

        recorder.cancel()
    }
}
```

Add `import AVFoundation` at the top of the test file.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh DogballWhisperTests/AudioRecorderTests`
Expected: FAIL — "cannot find 'AudioRecorder' in scope".

- [ ] **Step 3: Implement `AudioRecorder`**

`DogballWhisper/Capture/AudioRecorder.swift`:

```swift
import AVFoundation

struct RecordedAudio: Equatable {
    let url: URL
    let duration: TimeInterval
}

protocol AudioRecording: AnyObject {
    var levels: [Float] { get }
    func start() throws
    func stop() -> RecordedAudio?
    func cancel()
}

/// Records 16kHz mono PCM straight to a WAV file, which is exactly what both
/// transcription engines want. There is no AVAudioSession on macOS, so there is
/// nothing to configure or tear down around each recording.
final class AudioRecorder: NSObject, AudioRecording {
    static let levelWindowSize = 40
    static let meterWarmUp: TimeInterval = 0.3

    private(set) var levels: [Float] = Array(repeating: 0, count: AudioRecorder.levelWindowSize)

    private let onLevels: ([Float]) -> Void
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var fileURL: URL?

    init(onLevels: @escaping ([Float]) -> Void = { _ in }) {
        self.onLevels = onLevels
    }

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Maps a metered dBFS reading (-160...0) to a 0...1 bar height, treating
    /// anything inside the warm-up window as silence.
    static func normalizedLevel(fromDb db: Float, at time: TimeInterval) -> Float {
        guard time >= meterWarmUp else { return 0 }
        return max(0, min(1, (db + 50) / 50))
    }

    static var recordingsDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DogballWhisper/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    func start() throws {
        let url = Self.recordingsDirectory.appendingPathComponent("\(UUID().uuidString).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.record()

        self.recorder = recorder
        self.fileURL = url
        self.levels = Array(repeating: 0, count: Self.levelWindowSize)

        timer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { [weak self] _ in
            self?.sampleMeter()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() -> RecordedAudio? {
        timer?.invalidate()
        timer = nil
        guard let recorder, let fileURL else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        self.fileURL = nil
        return RecordedAudio(url: fileURL, duration: duration)
    }

    func cancel() {
        if let result = stop() {
            try? FileManager.default.removeItem(at: result.url)
        }
    }

    private func sampleMeter() {
        guard let recorder else { return }
        recorder.updateMeters()
        let level = Self.normalizedLevel(
            fromDb: recorder.averagePower(forChannel: 0), at: recorder.currentTime)
        levels.append(level)
        if levels.count > Self.levelWindowSize { levels.removeFirst() }
        onLevels(levels)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh DogballWhisperTests/AudioRecorderTests`
Expected: PASS, with the integration test skipped.

- [ ] **Step 5: Run the integration test once by hand**

Run: `RUN_AUDIO_IT=1 ./scripts/test.sh DogballWhisperTests/AudioRecorderTests`
Expected: PASS. macOS prompts for microphone access the first time; approve it.

- [ ] **Step 6: Commit**

```bash
git add DogballWhisper/Capture Tests/AudioRecorderTests.swift
git commit -m "feat: 16kHz mono audio recorder with level metering"
```

---

### Task 5: Transcription engine protocol and Parakeet

**Files:**
- Create: `DogballWhisper/Transcribe/TranscriptionEngine.swift`, `DogballWhisper/Transcribe/ParakeetEngine.swift`, `DogballWhisper/Transcribe/ModelMirror.swift`, `DogballWhisper/Transcribe/parakeet-manifest.json`, `Tests/ModelMirrorIntegrationTests.swift`, `Tests/EngineIntegrationTests.swift`, `Tests/Fixtures/hello.wav`
- Modify: `project.yml` (bundle the manifest and the fixture)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum EngineKind: String, Codable { case parakeet, whisper }`
  - `protocol TranscriptionEngine: AnyObject { var kind: EngineKind { get }; var isLoaded: Bool { get }; func load() async throws; func unload(); func transcribe(_ audioURL: URL) async throws -> String }`
  - `enum TranscriptionError: LocalizedError { case notLoaded, noModelInstalled }`
  - `final class ParakeetEngine: TranscriptionEngine`
  - `enum ModelMirror` with `static let baseURL`, `static func isComplete() -> Bool`, `static func download(onProgress:) async throws`, `static func loadManifest() throws -> Manifest`, `static func modelsDirectory(prefix:) -> URL`, `static func deleteModel() throws`.

- [ ] **Step 1: Copy the mirror and manifest from whisper-polish**

```bash
cp ~/dev/whisper-polish/WhisperPolish/Services/ModelMirror.swift DogballWhisper/Transcribe/ModelMirror.swift
cp ~/dev/whisper-polish/WhisperPolish/parakeet-manifest.json DogballWhisper/Transcribe/parakeet-manifest.json
```

The file ports unchanged: it already writes into `~/Library/Application Support/FluidAudio/Models/<prefix>/`, which is FluidAudio's cache directory on macOS too. Add one function to it for the model manager in Task 10:

```swift
    /// Removes every mirrored file so the model can be reinstalled.
    static func deleteModel() throws {
        let manifest = try loadManifest()
        let dir = modelsDirectory(prefix: manifest.prefix)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
```

- [ ] **Step 2: Bundle the manifest and add a test fixture**

In `project.yml`, under the app target's `sources`, the whole `DogballWhisper` directory is already included, so the JSON is bundled as a resource automatically. Add the fixture to the test target:

```yaml
  DogballWhisperTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: Tests
      - path: Tests/Fixtures
        buildPhase: resources
```

Record the fixture (say the words "hello there" clearly):

```bash
mkdir -p Tests/Fixtures
# Record ~2 seconds of speech at 16kHz mono:
sox -d -r 16000 -c 1 -b 16 Tests/Fixtures/hello.wav trim 0 2
# If sox is unavailable: use QuickTime Player > New Audio Recording, then
# afconvert -f WAVE -d LEI16@16000 -c 1 input.m4a Tests/Fixtures/hello.wav
```

- [ ] **Step 3: Add the mirror tests**

`Tests/ModelMirrorIntegrationTests.swift`:

```swift
import XCTest
@testable import DogballWhisper

final class ModelMirrorIntegrationTests: XCTestCase {

    // The manifest is what makes byte-accurate progress and the size check
    // possible, so a malformed or unbundled manifest must fail loudly here
    // rather than halfway through a 483MB download.
    func testBundledManifestIsUsable() throws {
        let manifest = try ModelMirror.loadManifest()
        XCTAssertFalse(manifest.prefix.isEmpty)
        XCTAssertFalse(manifest.files.isEmpty)
        XCTAssertEqual(manifest.files.reduce(0) { $0 + $1.size }, manifest.totalBytes)
        XCTAssertTrue(manifest.files.allSatisfy { $0.size > 0 && !$0.path.isEmpty })
    }

    func testModelsDirectoryIsFluidAudiosCacheLocation() throws {
        let path = ModelMirror.modelsDirectory(prefix: "some-model").path
        XCTAssertTrue(path.contains("Application Support/FluidAudio/Models/some-model"), path)
    }

    // Live download against CloudFront. Reports progress, verifies every file's
    // size, and resumes rather than restarting when files are already present.
    // Run with: RUN_MIRROR_IT=1 ./scripts/test.sh DogballWhisperTests/ModelMirrorIntegrationTests
    func testMirrorDownloadsThenReportsCompleteAndResumesInstantly() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_MIRROR_IT"] == "1",
            "Set RUN_MIRROR_IT=1 to run the live mirror download test")

        var fractions: [Double] = []
        try await ModelMirror.download { fractions.append($0) }

        XCTAssertTrue(ModelMirror.isComplete())
        XCTAssertEqual(fractions.last, 1.0)
        XCTAssertEqual(fractions, fractions.sorted(), "progress must not go backwards")

        // Second pass: everything is on disk, so it should finish immediately
        // and still report completion.
        var resumed: [Double] = []
        try await ModelMirror.download { resumed.append($0) }
        XCTAssertEqual(resumed.last, 1.0)
    }
}
```

- [ ] **Step 4: Run the mirror tests**

Run: `./scripts/test.sh DogballWhisperTests/ModelMirrorIntegrationTests`
Expected: the two fast tests PASS, the download test skipped. If `testBundledManifestIsUsable` fails with `manifestMissing`, the JSON is not being bundled as a resource — check that `parakeet-manifest.json` sits inside the `DogballWhisper` source directory.

- [ ] **Step 5: Write the failing engine integration test**

`Tests/EngineIntegrationTests.swift`:

```swift
import XCTest
@testable import DogballWhisper

/// Real models, real audio, real download. Opt-in because the first run pulls
/// ~500MB: RUN_ENGINE_IT=1 ./scripts/test.sh DogballWhisperTests/EngineIntegrationTests
final class EngineIntegrationTests: XCTestCase {

    private func fixtureURL() throws -> URL {
        try XCTUnwrap(Bundle(for: EngineIntegrationTests.self)
            .url(forResource: "hello", withExtension: "wav"))
    }

    func testParakeetTranscribesTheFixture() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_ENGINE_IT"] == "1")
        let engine = ParakeetEngine()
        try await engine.load()
        XCTAssertTrue(engine.isLoaded)

        let text = try await engine.transcribe(try fixtureURL())
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.lowercased().contains("hello"), "got: \(text)")
    }

    func testTranscribingBeforeLoadingThrows() async {
        let engine = ParakeetEngine()
        do {
            _ = try await engine.transcribe(URL(fileURLWithPath: "/dev/null"))
            XCTFail("expected notLoaded")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .notLoaded)
        }
    }
}
```

- [ ] **Step 6: Run the test to verify it fails**

Run: `./scripts/test.sh DogballWhisperTests/EngineIntegrationTests`
Expected: FAIL — "cannot find 'ParakeetEngine' in scope".

- [ ] **Step 7: Implement the protocol and the Parakeet engine**

`DogballWhisper/Transcribe/TranscriptionEngine.swift`:

```swift
import Foundation

enum EngineKind: String, Codable {
    case parakeet
    case whisper
}

enum TranscriptionError: LocalizedError, Equatable {
    case notLoaded
    case noModelInstalled

    var errorDescription: String? {
        switch self {
        case .notLoaded:
            return "The transcription model is still loading."
        case .noModelInstalled:
            return "No model installed. Open Settings and download one."
        }
    }
}

/// One loaded speech model. Implementations keep the model resident so no
/// dictation pays a cold-start cost.
protocol TranscriptionEngine: AnyObject {
    var kind: EngineKind { get }
    var isLoaded: Bool { get }
    func load() async throws
    func unload()
    func transcribe(_ audioURL: URL) async throws -> String
}
```

`DogballWhisper/Transcribe/ParakeetEngine.swift`:

```swift
import FluidAudio
import Foundation

/// Parakeet TDT 0.6b v3 via FluidAudio. Model files come from our own
/// CloudFront mirror (see ModelMirror) so FluidAudio never touches HuggingFace
/// and we get byte-accurate download progress.
final class ParakeetEngine: TranscriptionEngine {
    let kind: EngineKind = .parakeet
    private(set) var isLoaded = false

    private var manager: AsrManager?
    private let onDownloadProgress: (Double) -> Void

    init(onDownloadProgress: @escaping (Double) -> Void = { _ in }) {
        self.onDownloadProgress = onDownloadProgress
    }

    func load() async throws {
        guard !isLoaded else { return }
        if !ModelMirror.isComplete() {
            try await ModelMirror.download(onProgress: onDownloadProgress)
        }
        let models = try await AsrModels.downloadAndLoad()
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        isLoaded = true
    }

    func unload() {
        manager = nil
        isLoaded = false
    }

    func transcribe(_ audioURL: URL) async throws -> String {
        guard let manager else { throw TranscriptionError.notLoaded }
        var decoderState = try TdtDecoderState()
        let result = try await manager.transcribe(audioURL, decoderState: &decoderState)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 8: Run the fast test to verify it passes**

Run: `./scripts/test.sh DogballWhisperTests/EngineIntegrationTests`
Expected: PASS, with the download test skipped.

- [ ] **Step 9: Run the real transcription once**

Run: `RUN_ENGINE_IT=1 ./scripts/test.sh DogballWhisperTests/EngineIntegrationTests`
Expected: PASS. The first run downloads ~483MB from CloudFront, so allow several minutes. If it fails on the manifest, confirm `parakeet-manifest.json` made it into the app bundle's resources.

- [ ] **Step 10: Commit**

```bash
git add DogballWhisper/Transcribe Tests project.yml
git commit -m "feat: parakeet transcription engine with mirrored model download"
```

---

### Task 6: Caret location and text insertion

**Files:**
- Create: `DogballWhisper/Insert/PasteboardSnapshot.swift`, `DogballWhisper/Insert/TextInserter.swift`, `DogballWhisper/Insert/CaretLocator.swift`, `Tests/PasteboardSnapshotTests.swift`

**Interfaces:**
- Consumes: `InsertionMode` (Task 2).
- Produces:
  - `struct PasteboardSnapshot` with `static func capture(from: NSPasteboard) -> PasteboardSnapshot` and `func restore(to: NSPasteboard)`.
  - `struct CaretLocation: Equatable { let rectQuartz: CGRect?; let pid: pid_t? }`, `enum CaretLocator { static func current() -> CaretLocation }`.
  - `enum InsertOutcome: Equatable { case pasted, copiedToClipboard }`
  - `protocol TextInserting { func insert(_ text: String, targetPID: pid_t?, mode: InsertionMode) -> InsertOutcome }`
  - `final class PasteboardTextInserter: TextInserting`.

- [ ] **Step 1: Write the failing tests**

`Tests/PasteboardSnapshotTests.swift`:

```swift
import XCTest
@testable import DogballWhisper

final class PasteboardSnapshotTests: XCTestCase {
    // A private pasteboard, so tests never touch the user's real clipboard.
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: .init("com.jonclegg.DogballWhisper.tests"))
        pasteboard.clearContents()
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        super.tearDown()
    }

    func testRestoringBringsBackTheOriginalText() {
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("dictated", forType: .string)
        XCTAssertEqual(pasteboard.string(forType: .string), "dictated")

        snapshot.restore(to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testRestoringPreservesMultipleTypesOnOneItem() {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("plain", forType: .string)
        item.setString("<b>rich</b>", forType: .html)
        pasteboard.writeObjects([item])

        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("dictated", forType: .string)
        snapshot.restore(to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "plain")
        XCTAssertEqual(pasteboard.string(forType: .html), "<b>rich</b>")
    }

    func testRestoringAnEmptyClipboardLeavesItEmpty() {
        pasteboard.clearContents()
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.setString("dictated", forType: .string)
        snapshot.restore(to: pasteboard)
        XCTAssertNil(pasteboard.string(forType: .string))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh DogballWhisperTests/PasteboardSnapshotTests`
Expected: FAIL — "cannot find 'PasteboardSnapshot' in scope".

- [ ] **Step 3: Implement `PasteboardSnapshot`**

`DogballWhisper/Insert/PasteboardSnapshot.swift`:

```swift
import AppKit

/// A copy of the clipboard's contents, so dictating never costs the user
/// whatever they had copied.
struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { contents[type] = data }
            }
            return contents
        }
        return PasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { contents -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh DogballWhisperTests/PasteboardSnapshotTests`
Expected: PASS.

- [ ] **Step 5: Implement `TextInserter`**

`DogballWhisper/Insert/TextInserter.swift`:

```swift
import AppKit
import CoreGraphics

enum InsertOutcome: Equatable {
    case pasted
    case copiedToClipboard
}

protocol TextInserting {
    func insert(_ text: String, targetPID: pid_t?, mode: InsertionMode) -> InsertOutcome
}

/// Puts text on the clipboard, sends ⌘V to whatever is focused, then restores
/// the clipboard. Pasting is the only approach that works everywhere: native
/// apps, Electron, terminals, and web text fields all handle it identically.
final class PasteboardTextInserter: TextInserting {
    /// Long enough for the frontmost app to service the paste before we put the
    /// old contents back.
    static let restoreDelay: TimeInterval = 0.15

    private let virtualKeyV: CGKeyCode = 9

    func insert(_ text: String, targetPID: pid_t?, mode: InsertionMode) -> InsertOutcome {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Pasting into the wrong window is the one unrecoverable failure, so
        // bail out to a plain copy if focus moved while we were working.
        let stillFocused = targetPID == nil
            || NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID
        guard mode == .paste, stillFocused, AXIsProcessTrusted() else {
            return .copiedToClipboard
        }

        postCommandV()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDelay) {
            snapshot.restore(to: pasteboard)
        }
        return .pasted
    }

    private func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Without this, keys the user is physically holding suppress our events.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalKeyboardEvents, .permitLocalMouseEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyV, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyV, keyDown: false)
        // Set flags explicitly so a still-held modifier cannot turn this into
        // some other shortcut.
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
```

- [ ] **Step 6: Implement `CaretLocator`**

`DogballWhisper/Insert/CaretLocator.swift`:

```swift
import AppKit
import ApplicationServices

struct CaretLocation: Equatable {
    /// Caret rect in Quartz screen coordinates (origin top-left), or nil when
    /// the focused app does not report one.
    let rectQuartz: CGRect?
    let pid: pid_t?

    static let unknown = CaretLocation(rectQuartz: nil, pid: nil)
}

/// Asks the focused UI element where its insertion point is. Many Electron and
/// web apps answer nothing, which is expected: callers fall back to a fixed
/// panel position.
enum CaretLocator {
    static func current() -> CaretLocation {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard AXIsProcessTrusted() else { return CaretLocation(rectQuartz: nil, pid: frontPID) }

        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
            CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return CaretLocation(rectQuartz: nil, pid: frontPID) }
        let focused = focusedRef as! AXUIElement

        var elementPID: pid_t = 0
        AXUIElementGetPid(focused, &elementPID)
        let pid = elementPID != 0 ? elementPID : frontPID

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
            let range = rangeRef
        else { return CaretLocation(rectQuartz: nil, pid: pid) }

        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            focused,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            range,
            &boundsRef) == .success,
            let boundsValue = boundsRef
        else { return CaretLocation(rectQuartz: nil, pid: pid) }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect), rect.width >= 0 else {
            return CaretLocation(rectQuartz: nil, pid: pid)
        }
        return CaretLocation(rectQuartz: rect, pid: pid)
    }
}
```

- [ ] **Step 7: Run the full suite**

Run: `./scripts/test.sh`
Expected: PASS. `TextInserter` and `CaretLocator` have no unit tests: both are thin wrappers over system services that cannot be faked meaningfully. They are covered end-to-end in Task 7 and by the manual checklist in Task 13.

- [ ] **Step 8: Commit**

```bash
git add DogballWhisper/Insert Tests/PasteboardSnapshotTests.swift
git commit -m "feat: caret location and clipboard-preserving text insertion"
```

---

### Task 7: Dictation coordinator, first working end-to-end dictation

**Files:**
- Create: `DogballWhisper/Core/DictationCoordinator.swift`, `Tests/DictationCoordinatorTests.swift`
- Modify: `DogballWhisper/App/DogballWhisperApp.swift`, `DogballWhisper/App/MenuBarController.swift`

**Interfaces:**
- Consumes: `AudioRecording`, `TranscriptionEngine`, `TextInserting`, `CaretLocator`, `HotkeyMonitor`, `Preferences`.
- Produces:
  - `enum DictationState: Equatable { case idle, recording, transcribing, polishing, failed(String), notice(String) }`
  - `protocol TextCleaning { func clean(_ text: String, prompt: String, model: String) async throws -> String }` (implemented in Task 9; the coordinator ships with `cleaner: TextCleaning?` = nil).
  - `protocol DictationPresenting: AnyObject { func present(state: DictationState, at location: CaretLocation, levels: [Float]) ; func dismiss(after: TimeInterval) }`
  - `@MainActor final class DictationCoordinator` with `init(recorder:engineProvider:inserter:cleaner:presenter:preferences:config:)`, `func handle(_ signal: HotkeySignal)`, `func abort()`, `private(set) var state: DictationState`, `var onStateChange: ((DictationState) -> Void)?`, and `struct Config { var minimumDuration: TimeInterval = 0.3; var cleanupTimeout: TimeInterval = 3; var noticeDismissDelay: TimeInterval = 1.5 }`.
  - `typealias EngineProvider = () -> TranscriptionEngine?`

- [ ] **Step 1: Write the failing tests**

`Tests/DictationCoordinatorTests.swift`:

```swift
import XCTest
@testable import DogballWhisper

// MARK: - Fakes

final class FakeRecorder: AudioRecording {
    var levels: [Float] = [0, 0.5, 1]
    var startCount = 0
    var cancelCount = 0
    var nextResult: RecordedAudio? = RecordedAudio(
        url: URL(fileURLWithPath: "/tmp/dogball-test.wav"), duration: 2)
    var startError: Error?

    func start() throws {
        if let startError { throw startError }
        startCount += 1
    }
    func stop() -> RecordedAudio? { nextResult }
    func cancel() { cancelCount += 1 }
}

final class FakeEngine: TranscriptionEngine {
    let kind: EngineKind = .parakeet
    var isLoaded = true
    var result = "um so the thing is"
    var error: Error?
    var delay: TimeInterval = 0

    func load() async throws {}
    func unload() {}
    func transcribe(_ audioURL: URL) async throws -> String {
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        if let error { throw error }
        return result
    }
}

final class FakeCleaner: TextCleaning {
    var result = "So the thing is."
    var error: Error?
    var delay: TimeInterval = 0
    private(set) var receivedText: String?

    func clean(_ text: String, prompt: String, model: String) async throws -> String {
        receivedText = text
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        if let error { throw error }
        return result
    }
}

final class FakeInserter: TextInserting {
    var outcome: InsertOutcome = .pasted
    private(set) var inserted: [String] = []

    func insert(_ text: String, targetPID: pid_t?, mode: InsertionMode) -> InsertOutcome {
        inserted.append(text)
        return outcome
    }
}

final class FakePresenter: DictationPresenting {
    private(set) var states: [DictationState] = []
    private(set) var dismissCount = 0

    func present(state: DictationState, at location: CaretLocation, levels: [Float]) {
        states.append(state)
    }
    func dismiss(after: TimeInterval) { dismissCount += 1 }
}

// MARK: - Tests

@MainActor
final class DictationCoordinatorTests: XCTestCase {
    private var recorder: FakeRecorder!
    private var engine: FakeEngine!
    private var cleaner: FakeCleaner!
    private var inserter: FakeInserter!
    private var presenter: FakePresenter!
    private var prefs: Preferences!
    private let suiteName = "DogballWhisperTests.Coordinator"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        recorder = FakeRecorder()
        engine = FakeEngine()
        cleaner = FakeCleaner()
        inserter = FakeInserter()
        presenter = FakePresenter()
        prefs = Preferences(defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeCoordinator(
        cleaner: TextCleaning? = nil,
        config: DictationCoordinator.Config = .init(minimumDuration: 0.3, cleanupTimeout: 0.2)
    ) -> DictationCoordinator {
        DictationCoordinator(
            recorder: recorder,
            engineProvider: { [engine] in engine },
            inserter: inserter,
            cleaner: cleaner,
            presenter: presenter,
            preferences: prefs,
            config: config
        )
    }

    /// Drives the coordinator through one press and release, waiting for the
    /// async work it kicks off on release.
    private func dictate(_ coordinator: DictationCoordinator) async {
        coordinator.handle(.began)
        coordinator.handle(.ended)
        await coordinator.waitForWork()
    }

    func testHappyPathRecordsTranscribesAndInserts() async {
        let coordinator = makeCoordinator()
        await dictate(coordinator)

        XCTAssertEqual(recorder.startCount, 1)
        XCTAssertEqual(inserter.inserted, ["um so the thing is"])
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertTrue(presenter.states.contains(.recording))
        XCTAssertTrue(presenter.states.contains(.transcribing))
    }

    func testCleanedTextIsInsertedWhenCleanupIsEnabled() async {
        let coordinator = makeCoordinator(cleaner: cleaner)
        await dictate(coordinator)

        XCTAssertEqual(cleaner.receivedText, "um so the thing is")
        XCTAssertEqual(inserter.inserted, ["So the thing is."])
        XCTAssertTrue(presenter.states.contains(.polishing))
    }

    func testCleanupIsSkippedWhenDisabled() async {
        prefs.cleanupEnabled = false
        let coordinator = makeCoordinator(cleaner: cleaner)
        await dictate(coordinator)

        XCTAssertNil(cleaner.receivedText)
        XCTAssertEqual(inserter.inserted, ["um so the thing is"])
    }

    // Cleanup must never cost the user a dictation.
    func testCleanupErrorFallsBackToTheRawTranscript() async {
        cleaner.error = URLError(.notConnectedToInternet)
        let coordinator = makeCoordinator(cleaner: cleaner)
        await dictate(coordinator)
        XCTAssertEqual(inserter.inserted, ["um so the thing is"])
    }

    func testCleanupTimeoutFallsBackToTheRawTranscript() async {
        cleaner.delay = 5
        let coordinator = makeCoordinator(cleaner: cleaner)
        await dictate(coordinator)
        XCTAssertEqual(inserter.inserted, ["um so the thing is"])
    }

    // A tap of the hotkey is not a dictation.
    func testRecordingsShorterThanTheMinimumAreDiscardedSilently() async {
        recorder.nextResult = RecordedAudio(url: URL(fileURLWithPath: "/tmp/x.wav"), duration: 0.1)
        let coordinator = makeCoordinator()
        await dictate(coordinator)

        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertFalse(presenter.states.contains(where: { if case .failed = $0 { return true }; return false }))
    }

    func testCancelDiscardsTheRecordingWithoutInserting() async {
        let coordinator = makeCoordinator()
        coordinator.handle(.began)
        coordinator.handle(.cancelled)
        await coordinator.waitForWork()

        XCTAssertEqual(recorder.cancelCount, 1)
        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testEmptyTranscriptShowsANoticeAndInsertsNothing() async {
        engine.result = "   "
        let coordinator = makeCoordinator()
        await dictate(coordinator)

        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertTrue(presenter.states.contains(.notice("No speech")))
    }

    func testTranscriptionFailureIsSurfaced() async {
        engine.error = TranscriptionError.notLoaded
        let coordinator = makeCoordinator()
        await dictate(coordinator)

        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertTrue(presenter.states.contains(where: { if case .failed = $0 { return true }; return false }))
    }

    func testMissingEngineFailsWithAnActionableMessage() async {
        let coordinator = DictationCoordinator(
            recorder: recorder,
            engineProvider: { nil },
            inserter: inserter,
            cleaner: nil,
            presenter: presenter,
            preferences: prefs,
            config: .init(minimumDuration: 0.3, cleanupTimeout: 0.2)
        )
        coordinator.handle(.began)
        await coordinator.waitForWork()

        XCTAssertEqual(recorder.startCount, 0)
        XCTAssertEqual(
            coordinator.state,
            .failed(TranscriptionError.noModelInstalled.localizedDescription))
    }

    func testFocusChangeReportsThatTheTextWasCopiedInstead() async {
        inserter.outcome = .copiedToClipboard
        let coordinator = makeCoordinator()
        await dictate(coordinator)

        XCTAssertTrue(presenter.states.contains(.notice("Copied to clipboard")))
    }

    // Escape after release abandons transcription or cleanup that is already
    // running, and does it quietly rather than as an error.
    func testAbortDuringTranscriptionInsertsNothing() async {
        engine.delay = 0.4
        let coordinator = makeCoordinator()
        coordinator.handle(.began)
        coordinator.handle(.ended)
        coordinator.abort()
        await coordinator.waitForWork()

        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertFalse(
            presenter.states.contains(where: { if case .failed = $0 { return true }; return false }))
    }

    func testAbortWhileIdleDoesNothing() async {
        let coordinator = makeCoordinator()
        coordinator.abort()
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testTriggeringAgainWhileBusyIsIgnored() async {
        engine.delay = 0.2
        let coordinator = makeCoordinator()
        coordinator.handle(.began)
        coordinator.handle(.ended)
        coordinator.handle(.began)  // ignored: still transcribing
        await coordinator.waitForWork()

        XCTAssertEqual(recorder.startCount, 1)
        XCTAssertEqual(inserter.inserted.count, 1)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh DogballWhisperTests/DictationCoordinatorTests`
Expected: FAIL — "cannot find 'DictationCoordinator' in scope".

- [ ] **Step 3: Implement `DictationCoordinator`**

`DogballWhisper/Core/DictationCoordinator.swift`:

```swift
import AppKit
import Foundation

enum DictationState: Equatable {
    case idle
    case recording
    case transcribing
    case polishing
    /// Something went wrong; the message is shown in the panel.
    case failed(String)
    /// Nothing went wrong but there is something to say ("No speech").
    case notice(String)
}

protocol TextCleaning {
    func clean(_ text: String, prompt: String, model: String) async throws -> String
}

protocol DictationPresenting: AnyObject {
    func present(state: DictationState, at location: CaretLocation, levels: [Float])
    func dismiss(after: TimeInterval)
}

typealias EngineProvider = () -> TranscriptionEngine?

/// The single stateful component: turns hotkey signals into recorded audio,
/// text, and a paste. Everything it touches is a protocol so the whole state
/// machine runs in tests without a mic, a model, or a keyboard.
@MainActor
final class DictationCoordinator {
    struct Config {
        var minimumDuration: TimeInterval = 0.3
        var cleanupTimeout: TimeInterval = 3
        var noticeDismissDelay: TimeInterval = 1.5
    }

    private(set) var state: DictationState = .idle {
        didSet {
            guard state != oldValue else { return }
            presenter.present(state: state, at: location, levels: recorder.levels)
            onStateChange?(state)
        }
    }

    var onStateChange: ((DictationState) -> Void)?

    private let recorder: AudioRecording
    private let engineProvider: EngineProvider
    private let inserter: TextInserting
    private let cleaner: TextCleaning?
    private let presenter: DictationPresenting
    private let preferences: Preferences
    private let config: Config

    private var location: CaretLocation = .unknown
    private var work: Task<Void, Never>?

    init(
        recorder: AudioRecording,
        engineProvider: @escaping EngineProvider,
        inserter: TextInserting,
        cleaner: TextCleaning?,
        presenter: DictationPresenting,
        preferences: Preferences,
        config: Config = Config()
    ) {
        self.recorder = recorder
        self.engineProvider = engineProvider
        self.inserter = inserter
        self.cleaner = cleaner
        self.presenter = presenter
        self.preferences = preferences
        self.config = config
    }

    func handle(_ signal: HotkeySignal) {
        switch signal {
        case .began: begin()
        case .ended: end()
        case .cancelled: cancel()
        }
    }

    /// Escape after release: give up on transcription or cleanup already in
    /// flight. Nothing is inserted and nothing is reported as an error.
    func abort() {
        switch state {
        case .transcribing, .polishing:
            work?.cancel()
        case .recording:
            cancel()
        case .idle, .failed, .notice:
            break
        }
    }

    /// Test hook: awaits whatever asynchronous work the last signal started.
    func waitForWork() async {
        await work?.value
    }

    private func begin() {
        guard state == .idle else { return }
        guard engineProvider() != nil else {
            fail(TranscriptionError.noModelInstalled.localizedDescription)
            return
        }
        location = CaretLocator.current()
        do {
            try recorder.start()
            state = .recording
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func cancel() {
        guard state == .recording else { return }
        recorder.cancel()
        state = .idle
        presenter.dismiss(after: 0)
    }

    private func end() {
        guard state == .recording else { return }
        guard let audio = recorder.stop() else {
            state = .idle
            presenter.dismiss(after: 0)
            return
        }

        // Too short to be speech: the user tapped the key by accident.
        guard audio.duration >= config.minimumDuration else {
            try? FileManager.default.removeItem(at: audio.url)
            state = .idle
            presenter.dismiss(after: 0)
            return
        }

        state = .transcribing
        work = Task { [weak self] in
            await self?.finish(audio: audio)
        }
    }

    private func finish(audio: RecordedAudio) async {
        defer { try? FileManager.default.removeItem(at: audio.url) }

        guard let engine = engineProvider() else {
            fail(TranscriptionError.noModelInstalled.localizedDescription)
            return
        }

        let transcript: String
        do {
            if !engine.isLoaded { try await engine.load() }
            transcript = try await engine.transcribe(audio.url)
        } catch is CancellationError {
            abandon()
            return
        } catch {
            if Task.isCancelled {
                abandon()
            } else {
                fail(error.localizedDescription)
            }
            return
        }

        guard !Task.isCancelled else {
            abandon()
            return
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            notice("No speech")
            return
        }

        let finalText = await cleanIfEnabled(trimmed)

        // One last check: aborting during cleanup must not paste anything.
        guard !Task.isCancelled else {
            abandon()
            return
        }

        let outcome = inserter.insert(
            finalText, targetPID: location.pid, mode: preferences.insertionMode)

        switch outcome {
        case .pasted:
            state = .idle
            presenter.dismiss(after: 0)
        case .copiedToClipboard:
            notice("Copied to clipboard")
        }
    }

    /// Cleanup is best-effort by design: any failure, timeout, or missing key
    /// falls through to the raw transcript rather than losing the dictation.
    private func cleanIfEnabled(_ text: String) async -> String {
        guard preferences.cleanupEnabled, let cleaner else { return text }
        state = .polishing
        do {
            return try await withTimeout(seconds: config.cleanupTimeout) {
                try await cleaner.clean(
                    text,
                    prompt: self.preferences.cleanupPrompt,
                    model: self.preferences.cleanupModelID
                )
            }
        } catch {
            return text
        }
    }

    /// The user asked to stop, so this is not a failure worth reporting.
    private func abandon() {
        state = .idle
        presenter.dismiss(after: 0)
    }

    private func fail(_ message: String) {
        state = .failed(message)
        presenter.dismiss(after: config.noticeDismissDelay)
        state = .idle
    }

    private func notice(_ message: String) {
        state = .notice(message)
        presenter.dismiss(after: config.noticeDismissDelay)
        state = .idle
    }
}

struct TimedOutError: Error {}

/// Runs `operation`, giving up after `seconds`.
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimedOutError()
        }
        guard let result = try await group.next() else { throw TimedOutError() }
        group.cancelAll()
        return result
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh DogballWhisperTests/DictationCoordinatorTests`
Expected: PASS (all twelve).

- [ ] **Step 5: Wire the real app together**

Replace `DogballWhisper/App/DogballWhisperApp.swift`:

```swift
import AppKit

@main
enum DogballWhisperMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private var coordinator: DictationCoordinator?
    private var monitor: HotkeyMonitor?
    private var engine: TranscriptionEngine?
    private let preferences = Preferences()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menuBar = MenuBarController()
        self.menuBar = menuBar

        // Task 8 replaces this with the floating panel.
        let presenter = LoggingPresenter()
        let engine = ParakeetEngine()
        self.engine = engine

        let coordinator = DictationCoordinator(
            recorder: AudioRecorder(),
            engineProvider: { [weak self] in self?.engine },
            inserter: PasteboardTextInserter(),
            cleaner: nil,
            presenter: presenter,
            preferences: preferences
        )
        coordinator.onStateChange = { [weak menuBar] state in
            menuBar?.update(state: state)
        }
        self.coordinator = coordinator

        let monitor = HotkeyMonitor(binding: preferences.hotkeyBinding) { signal in
            MainActor.assumeIsolated { coordinator.handle(signal) }
        }
        monitor.onEscape = { MainActor.assumeIsolated { coordinator.abort() } }
        self.monitor = monitor
        do {
            try monitor.start()
        } catch {
            NSLog("Hotkey monitor failed: \(error.localizedDescription)")
        }

        // Load the model up front so the first dictation is not slow.
        Task { try? await engine.load() }
    }
}

/// Placeholder presenter until the floating panel lands in Task 8.
final class LoggingPresenter: DictationPresenting {
    func present(state: DictationState, at location: CaretLocation, levels: [Float]) {
        NSLog("state: \(state)")
    }
    func dismiss(after: TimeInterval) {}
}
```

Add to `MenuBarController`:

```swift
    func update(state: DictationState) {
        let symbol: String
        switch state {
        case .idle, .notice: symbol = "mic"
        case .recording: symbol = "mic.fill"
        case .transcribing, .polishing: symbol = "waveform"
        case .failed: symbol = "exclamationmark.triangle"
        }
        statusItem.button?.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: "Dogball Whisper")
    }
```

- [ ] **Step 6: Run the full suite**

Run: `./scripts/test.sh`
Expected: PASS.

- [ ] **Step 7: Verify the first real dictation by hand**

Run: `./scripts/build-mac.sh --launch`

Then grant Input Monitoring and Accessibility to "Dogball Whisper" in System Settings > Privacy & Security when prompted (the tap fails to create until Input Monitoring is granted, so relaunch after granting). Open TextEdit, click into the document, hold right ⌥, say "hello there this is a test", release.

Expected: the menu-bar icon fills red while held, then the transcribed text appears in TextEdit within about a second and the clipboard still holds whatever it held before.

- [ ] **Step 8: Commit**

```bash
git add DogballWhisper Tests/DictationCoordinatorTests.swift
git commit -m "feat: dictation coordinator wired end to end"
```

---

### Task 8: Floating panel, waveform, and positioning

**Files:**
- Create: `DogballWhisper/UI/PanelPositioner.swift`, `DogballWhisper/UI/WaveformView.swift`, `DogballWhisper/UI/DictationPanel.swift`, `Tests/PanelPositionerTests.swift`
- Modify: `DogballWhisper/App/DogballWhisperApp.swift` (swap `LoggingPresenter` for the panel)

**Interfaces:**
- Consumes: `DictationState`, `CaretLocation`, `DictationPresenting`.
- Produces:
  - `enum PanelPositioner` with `static let panelSize = CGSize(width: 220, height: 56)`, `static let caretGap: CGFloat = 10`, `static func origin(panelSize:caretRectQuartz:screenFrame:primaryScreenMaxY:) -> CGPoint`.
  - `struct WaveformView: View` with `init(levels: [Float])`.
  - `final class DictationPanelController: DictationPresenting`.

- [ ] **Step 1: Write the failing tests**

`Tests/PanelPositionerTests.swift`:

```swift
import XCTest
@testable import DogballWhisper

final class PanelPositionerTests: XCTestCase {
    // A 1440x900 main display. Cocoa origin is bottom-left; AX rects are
    // top-left, so primaryScreenMaxY is what converts between them.
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let primaryMaxY: CGFloat = 900
    private let size = PanelPositioner.panelSize

    private func origin(caret: CGRect?) -> CGPoint {
        PanelPositioner.origin(
            panelSize: size,
            caretRectQuartz: caret,
            screenFrame: screen,
            primaryScreenMaxY: primaryMaxY
        )
    }

    func testWithoutACaretThePanelSitsNearTheBottomCenter() {
        let point = origin(caret: nil)
        XCTAssertEqual(point.x, (1440 - size.width) / 2, accuracy: 0.5)
        XCTAssertEqual(point.y, screen.minY + PanelPositioner.bottomInset, accuracy: 0.5)
    }

    // A caret 300pt down from the top of a 900pt screen is at Cocoa y=600;
    // the panel's bottom edge goes a gap above the caret's top edge.
    func testPanelFloatsJustAboveTheCaret() {
        let caret = CGRect(x: 500, y: 300, width: 1, height: 18)
        let point = origin(caret: caret)
        XCTAssertEqual(point.x, 500 - size.width / 2, accuracy: 0.5)
        XCTAssertEqual(point.y, 600 + PanelPositioner.caretGap, accuracy: 0.5)
    }

    // Near the top of the screen there is no room above, so it goes below
    // instead of being clipped off-screen.
    func testPanelFlipsBelowTheCaretWhenThereIsNoRoomAbove() {
        let caret = CGRect(x: 700, y: 10, width: 1, height: 18)
        let point = origin(caret: caret)
        let caretBottomCocoa = primaryMaxY - (10 + 18)
        XCTAssertEqual(point.y, caretBottomCocoa - size.height - PanelPositioner.caretGap, accuracy: 0.5)
    }

    func testPanelIsClampedInsideTheScreenHorizontally() {
        XCTAssertEqual(origin(caret: CGRect(x: 2, y: 400, width: 1, height: 18)).x,
                       screen.minX + PanelPositioner.edgeInset, accuracy: 0.5)
        XCTAssertEqual(origin(caret: CGRect(x: 1438, y: 400, width: 1, height: 18)).x,
                       screen.maxX - size.width - PanelPositioner.edgeInset, accuracy: 0.5)
    }

    // A zero rect is what some apps report instead of nothing at all.
    func testZeroCaretRectIsTreatedAsNoCaret() {
        XCTAssertEqual(origin(caret: .zero), origin(caret: nil))
    }

    // Second display to the right of the primary one.
    func testCaretOnASecondaryDisplayStaysOnThatDisplay() {
        let secondary = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let point = PanelPositioner.origin(
            panelSize: size,
            caretRectQuartz: CGRect(x: 2000, y: 500, width: 1, height: 18),
            screenFrame: secondary,
            primaryScreenMaxY: primaryMaxY
        )
        XCTAssertGreaterThanOrEqual(point.x, secondary.minX)
        XCTAssertLessThanOrEqual(point.x + size.width, secondary.maxX)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh DogballWhisperTests/PanelPositionerTests`
Expected: FAIL — "cannot find 'PanelPositioner' in scope".

- [ ] **Step 3: Implement `PanelPositioner`**

`DogballWhisper/UI/PanelPositioner.swift`:

```swift
import CoreGraphics

/// Pure geometry, so the awkward part (AX reports top-left origins, Cocoa uses
/// bottom-left) is covered by tests instead of guesswork on screen.
enum PanelPositioner {
    static let panelSize = CGSize(width: 220, height: 56)
    static let caretGap: CGFloat = 10
    static let edgeInset: CGFloat = 8
    static let bottomInset: CGFloat = 120

    static func origin(
        panelSize: CGSize,
        caretRectQuartz: CGRect?,
        screenFrame: CGRect,
        primaryScreenMaxY: CGFloat
    ) -> CGPoint {
        guard let caret = caretRectQuartz, caret != .zero, caret.height > 0 else {
            return CGPoint(
                x: screenFrame.midX - panelSize.width / 2,
                y: screenFrame.minY + bottomInset
            )
        }

        let caretTopCocoa = primaryScreenMaxY - caret.minY
        let caretBottomCocoa = primaryScreenMaxY - caret.maxY

        var y = caretTopCocoa + caretGap
        if y + panelSize.height > screenFrame.maxY - edgeInset {
            y = caretBottomCocoa - panelSize.height - caretGap
        }
        y = min(max(y, screenFrame.minY + edgeInset), screenFrame.maxY - panelSize.height - edgeInset)

        let x = min(
            max(caret.midX - panelSize.width / 2, screenFrame.minX + edgeInset),
            screenFrame.maxX - panelSize.width - edgeInset
        )
        return CGPoint(x: x, y: y)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh DogballWhisperTests/PanelPositionerTests`
Expected: PASS (all six).

- [ ] **Step 5: Implement the waveform view**

`DogballWhisper/UI/WaveformView.swift`:

```swift
import SwiftUI

/// Live level bars. Levels arrive newest-last, so the bars scroll leftward.
struct WaveformView: View {
    let levels: [Float]

    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 2
    private let minHeight: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(.primary.opacity(0.75))
                        .frame(
                            width: barWidth,
                            height: max(minHeight, CGFloat(level) * geometry.size.height)
                        )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(.linear(duration: 0.05), value: levels)
        }
    }
}

/// The panel's whole content: bars while recording, a line of text otherwise.
struct DictationPanelContent: View {
    let state: DictationState
    let levels: [Float]

    var body: some View {
        ZStack {
            switch state {
            case .recording:
                WaveformView(levels: levels)
                    .padding(.horizontal, 16)
                    .frame(height: 28)
            case .transcribing:
                label("Transcribing…")
            case .polishing:
                label("Polishing…")
            case let .notice(message):
                label(message)
            case let .failed(message):
                label(message).foregroundStyle(.orange)
            case .idle:
                EmptyView()
            }
        }
        .frame(width: PanelPositioner.panelSize.width, height: PanelPositioner.panelSize.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
    }
}
```

- [ ] **Step 6: Implement the panel controller**

`DogballWhisper/UI/DictationPanel.swift`:

```swift
import AppKit
import Observation
import SwiftUI

/// A borderless, non-activating panel floating above every window. It must
/// never take focus: the whole point is that the app you were typing in stays
/// focused so the paste lands there.
@MainActor
final class DictationPanelController: DictationPresenting {
    private let panel: NSPanel
    private let model = PanelModel()
    private var dismissTimer: Timer?

    init() {
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: PanelPositioner.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: PanelRoot(model: model))
    }

    func present(state: DictationState, at location: CaretLocation, levels: [Float]) {
        guard state != .idle else { return }
        dismissTimer?.invalidate()
        model.state = state
        model.levels = levels

        let screen = screenContaining(location.rectQuartz) ?? NSScreen.main
        let origin = PanelPositioner.origin(
            panelSize: PanelPositioner.panelSize,
            caretRectQuartz: location.rectQuartz,
            screenFrame: screen?.visibleFrame ?? .zero,
            primaryScreenMaxY: NSScreen.screens.first?.frame.maxY ?? 0
        )
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    /// Called with a delay so error and notice text is readable before it goes.
    func dismiss(after delay: TimeInterval) {
        dismissTimer?.invalidate()
        guard delay > 0 else {
            panel.orderOut(nil)
            return
        }
        dismissTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.orderOut(nil) }
        }
    }

    /// Levels arrive at ~30Hz during recording, separately from state changes.
    func updateLevels(_ levels: [Float]) {
        model.levels = levels
    }

    /// AX rects are top-left origin, so flip before matching against screens.
    private func screenContaining(_ quartzRect: CGRect?) -> NSScreen? {
        guard let quartzRect, quartzRect != .zero,
              let primaryMaxY = NSScreen.screens.first?.frame.maxY
        else { return NSScreen.main }
        let point = CGPoint(x: quartzRect.midX, y: primaryMaxY - quartzRect.midY)
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }
}

@Observable
final class PanelModel {
    var state: DictationState = .idle
    var levels: [Float] = []
}

private struct PanelRoot: View {
    let model: PanelModel

    var body: some View {
        DictationPanelContent(state: model.state, levels: model.levels)
    }
}
```

- [ ] **Step 7: Wire the panel into the app**

In `DogballWhisper/App/DogballWhisperApp.swift`, delete `LoggingPresenter` entirely and replace the presenter and recorder construction inside `applicationDidFinishLaunching`. The recorder pushes levels straight to the panel, separately from state changes, so the bars animate at 30Hz without the coordinator in the loop:

```swift
        let panel = DictationPanelController()
        self.panel = panel

        let recorder = AudioRecorder(onLevels: { levels in
            MainActor.assumeIsolated { panel.updateLevels(levels) }
        })

        let coordinator = DictationCoordinator(
            recorder: recorder,
            engineProvider: { [weak self] in self?.engine },
            inserter: PasteboardTextInserter(),
            cleaner: nil,
            presenter: panel,
            preferences: preferences
        )
```

Add `private var panel: DictationPanelController?` alongside the delegate's other stored properties, and mark `AppDelegate` as `@MainActor` if it is not already.

- [ ] **Step 8: Run the full suite and verify by hand**

Run: `./scripts/test.sh && ./scripts/build-mac.sh --launch`

Expected: PASS, then holding right ⌥ in TextEdit shows a small translucent panel with animating bars right above the caret; it switches to "Transcribing…" on release and disappears when the text lands. In a browser text field (no AX caret) it appears near the bottom center of the screen instead. Focus never leaves the app you were typing in.

- [ ] **Step 9: Commit**

```bash
git add DogballWhisper/UI DogballWhisper/App Tests/PanelPositionerTests.swift
git commit -m "feat: caret-anchored floating panel with live waveform"
```

---

### Task 9: OpenRouter cleanup

**Files:**
- Create: `DogballWhisper/Polish/PolishService.swift`, `Tests/PolishServiceTests.swift`
- Modify: `DogballWhisper/App/DogballWhisperApp.swift` (pass the cleaner into the coordinator)

**Interfaces:**
- Consumes: `TextCleaning` (Task 7), `KeychainStore` (Task 2), `Preferences.cleanupPrompt`, `Preferences.cleanupModelID`.
- Produces:
  - `enum PolishError: LocalizedError, Equatable { case missingAPIKey, emptyResponse, http(Int, String) }`
  - `final class PolishService: TextCleaning` with `init(session: URLSession = .shared, keyProvider: @escaping () -> String? = { KeychainStore.read() })` and `func clean(_ text: String, prompt: String, model: String) async throws -> String`.

- [ ] **Step 1: Write the failing tests**

`Tests/PolishServiceTests.swift`:

```swift
import XCTest
@testable import DogballWhisper

/// Intercepts URLSession traffic so the tests never hit the network.
final class StubURLProtocol: URLProtocol {
    struct Stub {
        var statusCode = 200
        var body = Data()
        var error: Error?
    }

    nonisolated(unsafe) static var stub = Stub()
    nonisolated(unsafe) static var lastRequestBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequestBody = request.httpBody
            ?? request.httpBodyStream.flatMap { stream in
                stream.open()
                var data = Data()
                let size = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
                defer { buffer.deallocate(); stream.close() }
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: size)
                    if read <= 0 { break }
                    data.append(buffer, count: read)
                }
                return data
            }

        if let error = Self.stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.stub.statusCode,
            httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class PolishServiceTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
        StubURLProtocol.stub = .init()
        StubURLProtocol.lastRequestBody = nil
    }

    private func makeService(key: String? = "sk-test") -> PolishService {
        PolishService(session: session, keyProvider: { key })
    }

    private func chatResponse(_ content: String) -> Data {
        Data(#"{"choices":[{"message":{"content":"\#(content)"}}]}"#.utf8)
    }

    func testReturnsTheCleanedText() async throws {
        StubURLProtocol.stub.body = chatResponse("So the thing is.")
        let result = try await makeService().clean(
            "um so the thing is", prompt: "Clean it.", model: "anthropic/claude-haiku-4.5")
        XCTAssertEqual(result, "So the thing is.")
    }

    func testSendsThePromptModelAndTextToOpenRouter() async throws {
        StubURLProtocol.stub.body = chatResponse("ok")
        _ = try await makeService().clean("raw text", prompt: "MY PROMPT", model: "some/model")

        let body = try XCTUnwrap(StubURLProtocol.lastRequestBody)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "some/model")
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.first?["role"], "system")
        XCTAssertEqual(messages.first?["content"], "MY PROMPT")
        XCTAssertEqual(messages.last?["content"], "raw text")
        // Thinking tokens would blow the latency budget for no gain.
        XCTAssertEqual((json["reasoning"] as? [String: Any])?["enabled"] as? Bool, false)
    }

    func testMissingKeyThrowsBeforeAnyRequest() async {
        do {
            _ = try await makeService(key: nil).clean("x", prompt: "p", model: "m")
            XCTFail("expected missingAPIKey")
        } catch {
            XCTAssertEqual(error as? PolishError, .missingAPIKey)
        }
        XCTAssertNil(StubURLProtocol.lastRequestBody)
    }

    func testHTTPErrorIsReportedWithItsStatusCode() async {
        StubURLProtocol.stub.statusCode = 402
        StubURLProtocol.stub.body = Data(#"{"error":"insufficient credits"}"#.utf8)
        do {
            _ = try await makeService().clean("x", prompt: "p", model: "m")
            XCTFail("expected http error")
        } catch {
            guard case let .http(code, _)? = error as? PolishError else {
                return XCTFail("got \(error)")
            }
            XCTAssertEqual(code, 402)
        }
    }

    func testEmptyContentThrows() async {
        StubURLProtocol.stub.body = chatResponse("   ")
        do {
            _ = try await makeService().clean("x", prompt: "p", model: "m")
            XCTFail("expected emptyResponse")
        } catch {
            XCTAssertEqual(error as? PolishError, .emptyResponse)
        }
    }

    func testMalformedJSONThrows() async {
        StubURLProtocol.stub.body = Data("not json".utf8)
        do {
            _ = try await makeService().clean("x", prompt: "p", model: "m")
            XCTFail("expected a decoding error")
        } catch {
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testTransportErrorPropagates() async {
        StubURLProtocol.stub.error = URLError(.notConnectedToInternet)
        do {
            _ = try await makeService().clean("x", prompt: "p", model: "m")
            XCTFail("expected a URLError")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    // Model output sometimes arrives wrapped in quotes or a fenced block.
    func testWrappingQuotesAreStripped() async throws {
        StubURLProtocol.stub.body = chatResponse("\\\"So the thing is.\\\"")
        let quoted = try await makeService().clean("x", prompt: "p", model: "m")
        XCTAssertEqual(quoted, "So the thing is.")
    }

    func testCodeFencesAreStripped() {
        XCTAssertEqual(
            PolishService.unwrap("```\nSo the thing is.\n```"), "So the thing is.")
        XCTAssertEqual(
            PolishService.unwrap("```text\nSo the thing is.\n```"), "So the thing is.")
        // Real content that merely contains backticks must survive untouched.
        XCTAssertEqual(PolishService.unwrap("Use `git status` first."), "Use `git status` first.")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh DogballWhisperTests/PolishServiceTests`
Expected: FAIL — "cannot find 'PolishService' in scope".

- [ ] **Step 3: Implement `PolishService`**

`DogballWhisper/Polish/PolishService.swift`:

```swift
import Foundation

enum PolishError: LocalizedError, Equatable {
    case missingAPIKey
    case emptyResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your OpenRouter API key in Settings."
        case .emptyResponse:
            return "The cleanup model returned nothing."
        case let .http(code, body):
            return "OpenRouter error \(code): \(body)"
        }
    }
}

/// Strips disfluencies from a transcript via OpenRouter. The coordinator treats
/// every error here as "insert the raw transcript", so this type is free to
/// throw rather than paper over failures.
final class PolishService: TextCleaning {
    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        struct Reasoning: Encodable {
            let enabled: Bool
        }
        let model: String
        let messages: [Message]
        let temperature: Double
        /// Cleanup needs no thinking tokens; they only add latency.
        let reasoning = Reasoning(enabled: false)
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    private let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private let session: URLSession
    private let keyProvider: () -> String?

    init(
        session: URLSession = .shared,
        keyProvider: @escaping () -> String? = { KeychainStore.read() }
    ) {
        self.session = session
        self.keyProvider = keyProvider
    }

    func clean(_ text: String, prompt: String, model: String) async throws -> String {
        guard let key = keyProvider(), !key.isEmpty else { throw PolishError.missingAPIKey }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(
                model: model,
                messages: [
                    .init(role: "system", content: prompt),
                    .init(role: "user", content: text),
                ],
                temperature: 0
            )
        )

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PolishError.http(
                http.statusCode, String(data: data.prefix(300), encoding: .utf8) ?? "")
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        let content = Self.unwrap(decoded.choices.first?.message.content ?? "")
        guard !content.isEmpty else { throw PolishError.emptyResponse }
        return content
    }

    /// Models occasionally wrap their answer in quotes or a code fence even
    /// when told not to.
    static func unwrap(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()  // the opening fence, plus any language tag
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                lines.removeLast()
            }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh DogballWhisperTests/PolishServiceTests`
Expected: PASS (all nine).

- [ ] **Step 5: Wire the cleaner into the app**

In `DogballWhisper/App/DogballWhisperApp.swift`, change the coordinator's `cleaner:` argument from `nil` to `PolishService()`.

- [ ] **Step 6: Run the full suite and verify by hand**

Run: `./scripts/test.sh`
Expected: PASS.

There is no UI for the key yet (Task 11), so seed the Keychain once from a debugger-free path: temporarily add `KeychainStore.save("sk-or-...")` to `applicationDidFinishLaunching`, run `./scripts/build-mac.sh --launch`, dictate a sentence full of "um"s, confirm the pasted text is clean, then remove that line and rebuild.

Expected: filler words gone, wording otherwise unchanged, and total time from release to paste still around a second.

- [ ] **Step 7: Commit**

```bash
git add DogballWhisper/Polish DogballWhisper/App Tests/PolishServiceTests.swift
git commit -m "feat: openrouter cleanup pass with raw-transcript fallback"
```

---

### Task 10: Model catalog, downloader, and WhisperKit engine

**Files:**
- Create: `DogballWhisper/Transcribe/ModelCatalog.swift`, `DogballWhisper/Transcribe/ModelManager.swift`, `DogballWhisper/Transcribe/WhisperKitEngine.swift`, `Tests/ModelCatalogTests.swift`
- Modify: `DogballWhisper/App/DogballWhisperApp.swift`, `Tests/EngineIntegrationTests.swift`

**Interfaces:**
- Consumes: `EngineKind`, `TranscriptionEngine`, `ModelMirror`, `Preferences.activeModelID`.
- Produces:
  - `struct ModelDescriptor: Identifiable, Equatable { enum Source: Equatable { case parakeetMirror; case whisperKit(variant: String) }; let id: String; let name: String; let detail: String; let engineKind: EngineKind; let sizeBytes: Int64; let source: Source }`
  - `enum ModelInstallState: Equatable { case notInstalled, downloading(Double), installed, active }`
  - `enum ModelCatalog { static let all: [ModelDescriptor]; static func descriptor(id: String) -> ModelDescriptor?; static var defaultModelID: String; static func installedLocation(for: ModelDescriptor) -> URL; static func isInstalled(_: ModelDescriptor) -> Bool; static func state(for: ModelDescriptor, activeID: String?, progress: [String: Double]) -> ModelInstallState }`
  - `@MainActor final class ModelManager` with `init(preferences: Preferences)`, `var progress: [String: Double]`, `func install(_ descriptor: ModelDescriptor) async throws`, `func delete(_ descriptor: ModelDescriptor) throws`, `func makeActive(_ descriptor: ModelDescriptor) async throws`, `var activeEngine: TranscriptionEngine?`, `func loadActiveEngine() async`.
  - `final class WhisperKitEngine: TranscriptionEngine` with `init(variant: String, onDownloadProgress:)`.

- [ ] **Step 1: Write the failing tests**

`Tests/ModelCatalogTests.swift`:

```swift
import XCTest
@testable import DogballWhisper

final class ModelCatalogTests: XCTestCase {

    func testCatalogListsParakeetAndFourWhisperModels() {
        XCTAssertEqual(ModelCatalog.all.count, 5)
        XCTAssertEqual(ModelCatalog.all.filter { $0.engineKind == .parakeet }.count, 1)
        XCTAssertEqual(ModelCatalog.all.filter { $0.engineKind == .whisper }.count, 4)
    }

    func testEveryDescriptorHasAUniqueIDAndANonZeroSize() {
        let ids = ModelCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ModelCatalog.all.allSatisfy { $0.sizeBytes > 0 })
    }

    func testDefaultModelIsParakeet() {
        let descriptor = ModelCatalog.descriptor(id: ModelCatalog.defaultModelID)
        XCTAssertEqual(descriptor?.engineKind, .parakeet)
    }

    func testLookupOfAnUnknownIDReturnsNil() {
        XCTAssertNil(ModelCatalog.descriptor(id: "nope"))
    }

    // Whisper models live under our own Application Support directory rather
    // than ~/Documents, which is where WhisperKit would put them by default.
    func testWhisperModelsLiveUnderApplicationSupport() throws {
        let whisper = try XCTUnwrap(ModelCatalog.all.first { $0.engineKind == .whisper })
        let path = ModelCatalog.installedLocation(for: whisper).path
        XCTAssertTrue(path.contains("Application Support/DogballWhisper/Models"), path)
        XCTAssertTrue(path.hasSuffix("argmaxinc/whisperkit-coreml/\(whisperVariant(whisper))"), path)
    }

    private func whisperVariant(_ descriptor: ModelDescriptor) -> String {
        guard case let .whisperKit(variant) = descriptor.source else { return "" }
        return variant
    }

    func testStateReportsActiveDownloadingAndNotInstalled() throws {
        let descriptor = try XCTUnwrap(ModelCatalog.descriptor(id: ModelCatalog.defaultModelID))

        XCTAssertEqual(
            ModelCatalog.state(for: descriptor, activeID: nil, progress: [descriptor.id: 0.4]),
            .downloading(0.4))

        // Not installed on disk, so neither "active" nor "installed" can apply.
        if !ModelCatalog.isInstalled(descriptor) {
            XCTAssertEqual(
                ModelCatalog.state(for: descriptor, activeID: descriptor.id, progress: [:]),
                .notInstalled)
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh DogballWhisperTests/ModelCatalogTests`
Expected: FAIL — "cannot find 'ModelCatalog' in scope".

- [ ] **Step 3: Implement `ModelCatalog`**

`DogballWhisper/Transcribe/ModelCatalog.swift`:

```swift
import Foundation

struct ModelDescriptor: Identifiable, Equatable {
    enum Source: Equatable {
        case parakeetMirror
        /// A directory name in argmaxinc/whisperkit-coreml.
        case whisperKit(variant: String)
    }

    let id: String
    let name: String
    let detail: String
    let engineKind: EngineKind
    let sizeBytes: Int64
    let source: Source

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

enum ModelInstallState: Equatable {
    case notInstalled
    case downloading(Double)
    case installed
    case active
}

enum ModelCatalog {
    static let defaultModelID = "parakeet-v3"

    static let all: [ModelDescriptor] = [
        ModelDescriptor(
            id: defaultModelID,
            name: "Parakeet V3",
            detail: "Fastest, 25 European languages",
            engineKind: .parakeet,
            sizeBytes: 483_000_000,
            source: .parakeetMirror
        ),
        ModelDescriptor(
            id: "whisper-tiny-en",
            name: "Whisper Tiny (English)",
            detail: "Smallest, least accurate",
            engineKind: .whisper,
            sizeBytes: 75_000_000,
            source: .whisperKit(variant: "openai_whisper-tiny.en")
        ),
        ModelDescriptor(
            id: "whisper-base-en",
            name: "Whisper Base (English)",
            detail: "Small and quick",
            engineKind: .whisper,
            sizeBytes: 145_000_000,
            source: .whisperKit(variant: "openai_whisper-base.en")
        ),
        ModelDescriptor(
            id: "whisper-small-en",
            name: "Whisper Small (English)",
            detail: "Good accuracy",
            engineKind: .whisper,
            sizeBytes: 483_000_000,
            source: .whisperKit(variant: "openai_whisper-small.en")
        ),
        ModelDescriptor(
            id: "whisper-large-v3-turbo",
            name: "Whisper Large V3 Turbo",
            detail: "Most accurate, 99 languages",
            engineKind: .whisper,
            sizeBytes: 632_000_000,
            source: .whisperKit(variant: "openai_whisper-large-v3-v20240930_turbo_632MB")
        ),
    ]

    static func descriptor(id: String) -> ModelDescriptor? {
        all.first { $0.id == id }
    }

    /// Our own download root. WhisperKit defaults to ~/Documents, which is the
    /// wrong place for a background menu-bar app's model files.
    static var whisperDownloadBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DogballWhisper/Models", isDirectory: true)
    }

    static func installedLocation(for descriptor: ModelDescriptor) -> URL {
        switch descriptor.source {
        case .parakeetMirror:
            let prefix = (try? ModelMirror.loadManifest().prefix) ?? "parakeet-tdt-0.6b-v3"
            return ModelMirror.modelsDirectory(prefix: prefix)
        case let .whisperKit(variant):
            return whisperDownloadBase
                .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
                .appendingPathComponent(variant, isDirectory: true)
        }
    }

    static func isInstalled(_ descriptor: ModelDescriptor) -> Bool {
        switch descriptor.source {
        case .parakeetMirror:
            return ModelMirror.isComplete()
        case .whisperKit:
            let folder = installedLocation(for: descriptor)
            let required = [
                "config.json",
                "AudioEncoder.mlmodelc/weights/weight.bin",
                "TextDecoder.mlmodelc/weights/weight.bin",
                "MelSpectrogram.mlmodelc/weights/weight.bin",
            ]
            return required.allSatisfy {
                FileManager.default.fileExists(
                    atPath: folder.appendingPathComponent($0).path)
            }
        }
    }

    static func state(
        for descriptor: ModelDescriptor, activeID: String?, progress: [String: Double]
    ) -> ModelInstallState {
        if let fraction = progress[descriptor.id] { return .downloading(fraction) }
        guard isInstalled(descriptor) else { return .notInstalled }
        return descriptor.id == activeID ? .active : .installed
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh DogballWhisperTests/ModelCatalogTests`
Expected: PASS (all six).

- [ ] **Step 5: Implement `WhisperKitEngine`**

`DogballWhisper/Transcribe/WhisperKitEngine.swift`:

```swift
import Foundation
import WhisperKit

/// A Whisper model via WhisperKit. Once the files are on disk we never let
/// WhisperKit re-sync against HuggingFace: that rewrites files and forces a
/// slow CoreML recompile on the next load.
final class WhisperKitEngine: TranscriptionEngine {
    let kind: EngineKind = .whisper
    private(set) var isLoaded = false

    private let variant: String
    private let onDownloadProgress: (Double) -> Void
    private var pipeline: WhisperKit?

    init(variant: String, onDownloadProgress: @escaping (Double) -> Void = { _ in }) {
        self.variant = variant
        self.onDownloadProgress = onDownloadProgress
    }

    func load() async throws {
        guard !isLoaded else { return }
        let descriptor = ModelCatalog.all.first {
            if case let .whisperKit(v) = $0.source { return v == variant }
            return false
        }
        var folder = descriptor.map(ModelCatalog.installedLocation(for:))
            ?? ModelCatalog.whisperDownloadBase

        if descriptor.map(ModelCatalog.isInstalled) != true {
            folder = try await WhisperKit.download(
                variant: variant,
                downloadBase: ModelCatalog.whisperDownloadBase,
                progressCallback: { [onDownloadProgress] progress in
                    onDownloadProgress(progress.fractionCompleted)
                }
            )
        }

        let config = WhisperKitConfig(
            model: variant,
            modelFolder: folder.path,
            load: true,
            download: false
        )
        pipeline = try await WhisperKit(config)
        isLoaded = true
    }

    func unload() {
        pipeline = nil
        isLoaded = false
    }

    func transcribe(_ audioURL: URL) async throws -> String {
        guard let pipeline else { throw TranscriptionError.notLoaded }
        let results = try await pipeline.transcribe(audioPath: audioURL.path)
        return results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 6: Implement `ModelManager`**

`DogballWhisper/Transcribe/ModelManager.swift`:

```swift
import Foundation
import Observation

/// Owns model installation and which engine is live. One download at a time,
/// because two 500MB transfers at once help nobody.
@MainActor
@Observable
final class ModelManager {
    /// Download fraction per model ID, present only while downloading.
    private(set) var progress: [String: Double] = [:]
    private(set) var activeEngine: TranscriptionEngine?
    private(set) var lastError: String?

    private let preferences: Preferences
    private var installTask: Task<Void, Error>?

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    var activeModelID: String? {
        preferences.activeModelID
    }

    var isBusy: Bool { installTask != nil }

    func state(for descriptor: ModelDescriptor) -> ModelInstallState {
        ModelCatalog.state(
            for: descriptor, activeID: preferences.activeModelID, progress: progress)
    }

    func install(_ descriptor: ModelDescriptor) async throws {
        guard installTask == nil else { return }
        progress[descriptor.id] = 0

        // Loading an engine is what downloads it, so install is "load, then
        // throw the engine away" unless it becomes the active model below.
        let engine = makeEngine(for: descriptor) { [weak self] fraction in
            Task { @MainActor in self?.progress[descriptor.id] = fraction }
        }
        let task = Task {
            try await engine.load()
            engine.unload()
        }
        installTask = task

        // Cleared here rather than in the task's defer: the task starts running
        // immediately, so a defer could clear installTask before it was set and
        // leave a stale value that blocks every later install.
        defer {
            progress[descriptor.id] = nil
            installTask = nil
        }
        do {
            try await task.value
        } catch {
            lastError = error.localizedDescription
            throw error
        }
        // First model installed becomes the active one.
        if preferences.activeModelID == nil {
            try await makeActive(descriptor)
        }
    }

    func delete(_ descriptor: ModelDescriptor) throws {
        if preferences.activeModelID == descriptor.id {
            activeEngine?.unload()
            activeEngine = nil
            preferences.activeModelID = nil
        }
        switch descriptor.source {
        case .parakeetMirror:
            try ModelMirror.deleteModel()
        case .whisperKit:
            let folder = ModelCatalog.installedLocation(for: descriptor)
            if FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.removeItem(at: folder)
            }
        }
    }

    func makeActive(_ descriptor: ModelDescriptor) async throws {
        activeEngine?.unload()
        activeEngine = nil
        preferences.activeModelID = descriptor.id
        try await loadActiveEngineThrowing()
    }

    /// Called at launch so the first dictation does not pay a cold start.
    func loadActiveEngine() async {
        do {
            try await loadActiveEngineThrowing()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func loadActiveEngineThrowing() async throws {
        guard let id = preferences.activeModelID,
              let descriptor = ModelCatalog.descriptor(id: id),
              ModelCatalog.isInstalled(descriptor)
        else {
            activeEngine = nil
            return
        }
        let engine = makeEngine(for: descriptor) { _ in }
        try await engine.load()
        activeEngine = engine
    }

    private func makeEngine(
        for descriptor: ModelDescriptor, onProgress: @escaping (Double) -> Void
    ) -> TranscriptionEngine {
        switch descriptor.source {
        case .parakeetMirror:
            return ParakeetEngine(onDownloadProgress: onProgress)
        case let .whisperKit(variant):
            return WhisperKitEngine(variant: variant, onDownloadProgress: onProgress)
        }
    }
}
```

- [ ] **Step 7: Route the app through `ModelManager`**

In `DogballWhisper/App/DogballWhisperApp.swift`, replace the hard-coded `ParakeetEngine` with the manager, and expose it for Task 11:

```swift
    let models: ModelManager

    override init() {
        let preferences = Preferences()
        self.preferences = preferences
        self.models = ModelManager(preferences: preferences)
        super.init()
    }
```

then use `engineProvider: { [weak self] in self?.models.activeEngine }` and replace the launch-time load with:

```swift
        Task { await models.loadActiveEngine() }
```

Delete the `engine` property and its `ParakeetEngine()` construction.

- [ ] **Step 8: Add a WhisperKit integration test**

Append to `Tests/EngineIntegrationTests.swift`:

```swift
    func testWhisperKitTranscribesTheFixture() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_ENGINE_IT"] == "1")
        let engine = WhisperKitEngine(variant: "openai_whisper-base.en")
        try await engine.load()

        let text = try await engine.transcribe(try fixtureURL())
        XCTAssertTrue(text.lowercased().contains("hello"), "got: \(text)")
        XCTAssertTrue(
            ModelCatalog.isInstalled(
                try XCTUnwrap(ModelCatalog.descriptor(id: "whisper-base-en"))),
            "download landed somewhere other than the expected folder")
    }
```

- [ ] **Step 9: Run the tests**

Run: `./scripts/test.sh`
Expected: PASS.

Run: `RUN_ENGINE_IT=1 ./scripts/test.sh DogballWhisperTests/EngineIntegrationTests`
Expected: PASS. This downloads the Whisper base model (~145MB). If `isInstalled` comes back false, list the download base and reconcile the variant directory name with the assertion:

```bash
find ~/Library/Application\ Support/DogballWhisper/Models -maxdepth 4 -type d
```

- [ ] **Step 10: Commit**

```bash
git add DogballWhisper/Transcribe DogballWhisper/App Tests
git commit -m "feat: model catalog, installer, and whisperkit engine"
```

---

### Task 11: Settings window, hotkey picker, launch at login, and menu

**Files:**
- Create: `DogballWhisper/App/LoginItem.swift`, `DogballWhisper/UI/SettingsView.swift`, `DogballWhisper/UI/ShortcutRecorderView.swift`, `DogballWhisper/UI/SettingsWindowController.swift`
- Modify: `DogballWhisper/App/MenuBarController.swift`, `DogballWhisper/App/DogballWhisperApp.swift`

**Interfaces:**
- Consumes: `Preferences`, `ModelManager`, `ModelCatalog`, `KeychainStore`, `PolishService`, `HotkeyBinding`.
- Produces:
  - `enum LoginItem` with `static var isEnabled: Bool`, `static func setEnabled(_ enabled: Bool)`.
  - `@MainActor final class SettingsWindowController` with `init(preferences:models:onHotkeyChange:)` and `func show()`.
  - `struct SettingsView: View`, `struct ShortcutRecorderView: View` with `init(binding: Binding<HotkeyBinding>)`.
  - `MenuBarController.init(onOpenSettings: @escaping () -> Void)`, `func update(state: DictationState)`, `func setActiveModelName(_ name: String?)`.

- [ ] **Step 1: Implement `LoginItem`**

`DogballWhisper/App/LoginItem.swift`:

```swift
import Foundation
import ServiceManagement

/// Launch at login via SMAppService. No helper bundle and no deprecated
/// LSSharedFileList shimming: registering the main app is enough.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Launch at login change failed: \(error.localizedDescription)")
        }
    }
}
```

There is no unit test: `SMAppService` mutates real system state and reports `.requiresApproval` from an unsigned test host. It is covered by the reboot check in the smoke pass.

- [ ] **Step 2: Implement the shortcut recorder**

`DogballWhisper/UI/ShortcutRecorderView.swift`:

```swift
import AppKit
import SwiftUI

/// Captures a custom modifier+key combo. Uses a local NSEvent monitor rather
/// than the global tap: this only needs to see events while the settings window
/// is focused, so it needs no extra permission.
struct ShortcutRecorderView: View {
    @Binding var binding: HotkeyBinding
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button(isRecording ? "Press a key combination…" : binding.displayName) {
            isRecording ? stop() : start()
        }
        .buttonStyle(.bordered)
        .onDisappear(perform: stop)
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
                .intersection(HotkeyMatcher.relevantMasks)
            // Escape abandons recording; a bare key is not a usable global hotkey.
            if event.keyCode == 53 {
                stop()
                return nil
            }
            guard !flags.isEmpty else { return nil }
            binding = HotkeyBinding(comboKeyCode: event.keyCode, modifiers: flags)
            stop()
            return nil
        }
    }

    private func stop() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
```

- [ ] **Step 3: Implement the settings view**

`DogballWhisper/UI/SettingsView.swift`:

```swift
import SwiftUI

struct SettingsView: View {
    let preferences: Preferences
    let models: ModelManager
    let onHotkeyChange: (HotkeyBinding) -> Void

    var body: some View {
        TabView {
            GeneralSettingsTab(preferences: preferences, onHotkeyChange: onHotkeyChange)
                .tabItem { Label("General", systemImage: "gearshape") }
            ModelsSettingsTab(models: models)
                .tabItem { Label("Models", systemImage: "square.and.arrow.down") }
            CleanupSettingsTab(preferences: preferences)
                .tabItem { Label("Cleanup", systemImage: "wand.and.sparkles") }
        }
        .frame(width: 520, height: 420)
    }
}

private struct GeneralSettingsTab: View {
    let preferences: Preferences
    let onHotkeyChange: (HotkeyBinding) -> Void

    @State private var binding: HotkeyBinding = .rightOption
    @State private var insertionMode: InsertionMode = .paste
    @State private var launchAtLogin = false
    @State private var fnWarning: String?

    var body: some View {
        Form {
            Section("Hold to talk") {
                Picker("Key", selection: presetSelection) {
                    Text("Right ⌥").tag(HotkeyBinding.rightOption)
                    Text("Right ⌘").tag(HotkeyBinding.rightCommand)
                    Text("fn / 🌐").tag(HotkeyBinding.fn)
                    Text("Custom").tag(customTag)
                }
                if binding.kind == .combo {
                    ShortcutRecorderView(binding: $binding)
                }
                if let fnWarning {
                    Text(fnWarning).font(.callout).foregroundStyle(.orange)
                    Button("Open keyboard settings") {
                        Permissions.openKeyboardSettings()
                    }
                }
            }
            Section("Insertion") {
                Picker("When dictation finishes", selection: $insertionMode) {
                    Text("Paste into the focused app").tag(InsertionMode.paste)
                    Text("Copy to the clipboard only").tag(InsertionMode.clipboardOnly)
                }
                .pickerStyle(.radioGroup)
            }
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            binding = preferences.hotkeyBinding
            insertionMode = preferences.insertionMode
            launchAtLogin = LoginItem.isEnabled
            refreshFnWarning()
        }
        .onChange(of: binding) { _, new in
            preferences.hotkeyBinding = new
            onHotkeyChange(new)
            refreshFnWarning()
        }
        .onChange(of: insertionMode) { _, new in preferences.insertionMode = new }
        .onChange(of: launchAtLogin) { _, new in LoginItem.setEnabled(new) }
    }

    /// Sentinel for the "Custom" row, so picking it switches the UI into
    /// recording mode without clobbering an existing custom binding.
    private var customTag: HotkeyBinding {
        binding.kind == .combo ? binding : HotkeyBinding(comboKeyCode: 49, modifiers: [.maskControl])
    }

    private var presetSelection: Binding<HotkeyBinding> {
        Binding(get: { binding }, set: { binding = $0 })
    }

    /// macOS claims fn for emoji, input switching, or its own dictation unless
    /// "Press 🌐 to" is set to Do Nothing.
    private func refreshFnWarning() {
        guard binding == .fn else {
            fnWarning = nil
            return
        }
        fnWarning = Permissions.fnKeyIsClaimedBySystem
            ? "macOS currently uses fn for something else. Set Keyboard > Press 🌐 to > Do Nothing."
            : nil
    }
}

private struct ModelsSettingsTab: View {
    let models: ModelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(ModelCatalog.all) { descriptor in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(descriptor.name).font(.body)
                        Text("\(descriptor.detail) · \(descriptor.sizeLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    controls(for: descriptor)
                }
                .padding(.vertical, 4)
            }
            if let error = models.lastError {
                Text(error).font(.caption).foregroundStyle(.orange).padding(12)
            }
        }
    }

    @ViewBuilder
    private func controls(for descriptor: ModelDescriptor) -> some View {
        switch models.state(for: descriptor) {
        case .notInstalled:
            Button("Install") { Task { try? await models.install(descriptor) } }
                .disabled(models.isBusy)
        case let .downloading(fraction):
            ProgressView(value: fraction).frame(width: 90)
        case .installed:
            HStack(spacing: 8) {
                Button("Use") { Task { try? await models.makeActive(descriptor) } }
                Button("Delete") { try? models.delete(descriptor) }
            }
        case .active:
            HStack(spacing: 8) {
                Text("Active").foregroundStyle(.secondary)
                Button("Delete") { try? models.delete(descriptor) }
            }
        }
    }
}

private struct CleanupSettingsTab: View {
    let preferences: Preferences

    @State private var enabled = true
    @State private var apiKey = ""
    @State private var modelID = ""
    @State private var prompt = ""
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section {
                Toggle("Clean up transcripts", isOn: $enabled)
                Text("Only the transcribed text is sent to OpenRouter. Audio never leaves this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("OpenRouter") {
                SecureField("API key", text: $apiKey)
                TextField("Model", text: $modelID)
                Text("Suggestions: anthropic/claude-haiku-4.5, google/gemini-3.5-flash, z-ai/glm-5-turbo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Prompt") {
                TextEditor(text: $prompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 110)
                Button("Reset to default") { prompt = Preferences.defaultCleanupPrompt }
            }
            Section {
                HStack {
                    Button("Test") { runTest() }.disabled(isTesting)
                    if let testResult {
                        Text(testResult).font(.caption).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            enabled = preferences.cleanupEnabled
            modelID = preferences.cleanupModelID
            prompt = preferences.cleanupPrompt
            apiKey = KeychainStore.read() ?? ""
        }
        .onChange(of: enabled) { _, new in preferences.cleanupEnabled = new }
        .onChange(of: modelID) { _, new in preferences.cleanupModelID = new }
        .onChange(of: prompt) { _, new in preferences.cleanupPrompt = new }
        .onChange(of: apiKey) { _, new in KeychainStore.save(new) }
    }

    private func runTest() {
        isTesting = true
        testResult = "Testing…"
        let sample = "so um I was thinking that we could uh maybe ship it on friday"
        Task {
            do {
                let cleaned = try await PolishService().clean(
                    sample, prompt: prompt, model: modelID)
                testResult = cleaned
            } catch {
                testResult = error.localizedDescription
            }
            isTesting = false
        }
    }
}
```

- [ ] **Step 4: Implement the settings window controller**

`DogballWhisper/UI/SettingsWindowController.swift`:

```swift
import AppKit
import SwiftUI

/// Hosts the settings view in a normal window. An accessory app has no menu
/// bar of its own, so the window is created on demand and reused.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let preferences: Preferences
    private let models: ModelManager
    private let onHotkeyChange: (HotkeyBinding) -> Void

    init(
        preferences: Preferences,
        models: ModelManager,
        onHotkeyChange: @escaping (HotkeyBinding) -> Void
    ) {
        self.preferences = preferences
        self.models = models
        self.onHotkeyChange = onHotkeyChange
    }

    func show() {
        if window == nil {
            let view = SettingsView(
                preferences: preferences, models: models, onHotkeyChange: onHotkeyChange)
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 520, height: 420),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Dogball Whisper Settings"
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
```

- [ ] **Step 5: Rebuild the menu**

Replace `DogballWhisper/App/MenuBarController.swift`:

```swift
import AppKit

/// The status-bar item: the app's only persistent UI.
final class MenuBarController: NSObject {
    let statusItem: NSStatusItem

    private let onOpenSettings: () -> Void
    private let activeModelItem = NSMenuItem(title: "No model installed", action: nil, keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(
        title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    init(onOpenSettings: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "mic", accessibilityDescription: "Dogball Whisper")

        let menu = NSMenu()
        activeModelItem.isEnabled = false
        menu.addItem(activeModelItem)
        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        launchAtLoginItem.target = self
        launchAtLoginItem.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Dogball Whisper",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        statusItem.menu = menu
    }

    func update(state: DictationState) {
        let symbol: String
        switch state {
        case .idle, .notice: symbol = "mic"
        case .recording: symbol = "mic.fill"
        case .transcribing, .polishing: symbol = "waveform"
        case .failed: symbol = "exclamationmark.triangle"
        }
        statusItem.button?.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: "Dogball Whisper")
        statusItem.button?.contentTintColor = state == .recording ? .systemRed : nil
    }

    func setActiveModelName(_ name: String?) {
        activeModelItem.title = name ?? "No model installed"
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func toggleLaunchAtLogin() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        launchAtLoginItem.state = LoginItem.isEnabled ? .on : .off
    }
}
```

- [ ] **Step 6: Assemble the final `AppDelegate`**

Replace the whole of `DogballWhisper/App/DogballWhisperApp.swift`:

```swift
import AppKit

@main
enum DogballWhisperMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences()
    private lazy var models = ModelManager(preferences: preferences)

    private var menuBar: MenuBarController?
    private var panel: DictationPanelController?
    private var coordinator: DictationCoordinator?
    private var monitor: HotkeyMonitor?
    private var settings: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = DictationPanelController()
        self.panel = panel

        let recorder = AudioRecorder(onLevels: { levels in
            MainActor.assumeIsolated { panel.updateLevels(levels) }
        })

        let coordinator = DictationCoordinator(
            recorder: recorder,
            engineProvider: { [weak self] in self?.models.activeEngine },
            inserter: PasteboardTextInserter(),
            cleaner: PolishService(),
            presenter: panel,
            preferences: preferences
        )
        self.coordinator = coordinator

        let menuBar = MenuBarController(onOpenSettings: { [weak self] in self?.showSettings() })
        menuBar.setActiveModelName(
            preferences.activeModelID.flatMap { ModelCatalog.descriptor(id: $0)?.name })
        self.menuBar = menuBar
        coordinator.onStateChange = { [weak menuBar] state in menuBar?.update(state: state) }

        let monitor = HotkeyMonitor(binding: preferences.hotkeyBinding) { signal in
            MainActor.assumeIsolated { coordinator.handle(signal) }
        }
        monitor.onEscape = { MainActor.assumeIsolated { coordinator.abort() } }
        self.monitor = monitor

        // Task 12 puts onboarding in front of this.
        startMonitoring()
        Task {
            await models.loadActiveEngine()
            menuBar.setActiveModelName(
                preferences.activeModelID.flatMap { ModelCatalog.descriptor(id: $0)?.name })
        }
    }

    func startMonitoring() {
        do {
            try monitor?.start()
        } catch {
            NSLog("Hotkey monitor failed: \(error.localizedDescription)")
        }
    }

    private func showSettings() {
        if settings == nil {
            settings = SettingsWindowController(
                preferences: preferences,
                models: models,
                onHotkeyChange: { [weak self] binding in self?.monitor?.binding = binding }
            )
        }
        settings?.show()
    }

}
```

This task ends with a compiling, runnable app: settings reachable from the menu, hotkey rebindable, models installable. Onboarding wraps the launch path in Task 12.

- [ ] **Step 7: Build and check the settings UI**

Run: `./scripts/test.sh && ./scripts/build-mac.sh --launch`

Expected: PASS, then the menu has Settings…, Launch at login, and Quit. In Settings: the hotkey picker switches bindings and dictation follows the change with no relaunch; the Models tab installs Whisper Base with live progress and "Use" switches the active model; the Cleanup tab stores a key and the Test button returns cleaned sample text.

- [ ] **Step 8: Commit**

```bash
git add DogballWhisper/UI DogballWhisper/App
git commit -m "feat: settings window, launch at login, and menu"
```

---

### Task 12: Permissions and onboarding

**Files:**
- Create: `DogballWhisper/Core/Permissions.swift`, `DogballWhisper/UI/OnboardingView.swift`, `Tests/PermissionsTests.swift`
- Modify: `DogballWhisper/App/DogballWhisperApp.swift`

**Interfaces:**
- Consumes: `Preferences`, `ModelManager`, `ModelCatalog`, `AudioRecorder.requestPermission()`.
- Produces:
  - `enum PermissionKind: String, CaseIterable { case microphone, inputMonitoring, accessibility }` with `var title: String`, `var explanation: String`, `var isRequired: Bool`.
  - `enum Permissions` with `static func isGranted(_: PermissionKind) -> Bool`, `static func request(_: PermissionKind) async`, `static func openSettings(for: PermissionKind)`, `static func openKeyboardSettings()`, `static var allRequiredGranted: Bool`, `static var fnKeyIsClaimedBySystem: Bool`, `static func summary(granted:) -> String`.
  - `@MainActor final class OnboardingWindowController` with `init(preferences:models:onFinished:)` and `func show()`.

- [ ] **Step 1: Write the failing tests**

`Tests/PermissionsTests.swift`:

```swift
import XCTest
@testable import DogballWhisper

final class PermissionsTests: XCTestCase {

    // Accessibility is optional: without it we degrade to clipboard-only
    // insertion rather than refusing to run.
    func testOnlyMicrophoneAndInputMonitoringAreRequired() {
        XCTAssertTrue(PermissionKind.microphone.isRequired)
        XCTAssertTrue(PermissionKind.inputMonitoring.isRequired)
        XCTAssertFalse(PermissionKind.accessibility.isRequired)
    }

    func testEveryPermissionHasUserFacingCopy() {
        for kind in PermissionKind.allCases {
            XCTAssertFalse(kind.title.isEmpty)
            XCTAssertFalse(kind.explanation.isEmpty)
        }
    }

    func testSettingsDeepLinksPointAtThePrivacyPanes() {
        XCTAssertTrue(
            Permissions.settingsURL(for: .inputMonitoring).absoluteString
                .contains("Privacy_ListenEvent"))
        XCTAssertTrue(
            Permissions.settingsURL(for: .accessibility).absoluteString
                .contains("Privacy_Accessibility"))
        XCTAssertTrue(
            Permissions.settingsURL(for: .microphone).absoluteString
                .contains("Privacy_Microphone"))
    }

    func testSummaryNamesWhatIsStillMissing() {
        XCTAssertEqual(Permissions.summary(granted: []), "Microphone and Input Monitoring needed")
        XCTAssertEqual(Permissions.summary(granted: [.microphone]), "Input Monitoring needed")
        XCTAssertEqual(
            Permissions.summary(granted: [.microphone, .inputMonitoring]),
            "Ready")
    }

    // 0 means "Do Nothing", which is the only value that leaves fn to us.
    func testFnUsageValuesOtherThanDoNothingCountAsClaimed() {
        XCTAssertFalse(Permissions.fnUsageIsClaimed(0))
        XCTAssertTrue(Permissions.fnUsageIsClaimed(1))
        XCTAssertTrue(Permissions.fnUsageIsClaimed(2))
        XCTAssertTrue(Permissions.fnUsageIsClaimed(3))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh DogballWhisperTests/PermissionsTests`
Expected: FAIL — "cannot find 'PermissionKind' in scope".

- [ ] **Step 3: Implement `Permissions`**

`DogballWhisper/Core/Permissions.swift`:

```swift
import AVFoundation
import AppKit
import ApplicationServices

enum PermissionKind: String, CaseIterable {
    case microphone
    case inputMonitoring
    case accessibility

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .inputMonitoring: return "Input Monitoring"
        case .accessibility: return "Accessibility"
        }
    }

    var explanation: String {
        switch self {
        case .microphone:
            return "Records your voice while you hold the dictation key. Audio stays on this Mac."
        case .inputMonitoring:
            return "Notices when you hold the dictation key, in any app."
        case .accessibility:
            return "Finds your text cursor and pastes the finished text. Without it, text is copied to the clipboard instead."
        }
    }

    /// Accessibility is optional: the app degrades to clipboard-only insertion.
    var isRequired: Bool {
        self != .accessibility
    }
}

enum Permissions {
    static func isGranted(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .inputMonitoring:
            return CGPreflightListenEventAccess()
        case .accessibility:
            return AXIsProcessTrusted()
        }
    }

    static var allRequiredGranted: Bool {
        PermissionKind.allCases.filter(\.isRequired).allSatisfy(isGranted)
    }

    /// Only microphone and accessibility can be prompted for. Input Monitoring
    /// has no request API that returns a result, so its row deep-links to
    /// System Settings and the UI polls until it flips.
    static func request(_ kind: PermissionKind) async {
        switch kind {
        case .microphone:
            _ = await AudioRecorder.requestPermission()
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        }
    }

    static func settingsURL(for kind: PermissionKind) -> URL {
        let anchor: String
        switch kind {
        case .microphone: anchor = "Privacy_Microphone"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .accessibility: anchor = "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    static func openSettings(for kind: PermissionKind) {
        NSWorkspace.shared.open(settingsURL(for: kind))
    }

    static func openKeyboardSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    static func summary(granted: Set<PermissionKind>) -> String {
        let missing = PermissionKind.allCases
            .filter { $0.isRequired && !granted.contains($0) }
            .map(\.title)
        guard !missing.isEmpty else { return "Ready" }
        return missing.joined(separator: " and ") + " needed"
    }

    /// System Settings > Keyboard > "Press 🌐 to". Anything but 0 (Do Nothing)
    /// means macOS consumes the fn key before we see it.
    static func fnUsageIsClaimed(_ value: Int) -> Bool {
        value != 0
    }

    static var fnKeyIsClaimedBySystem: Bool {
        let value = UserDefaults(suiteName: "com.apple.HIToolbox")?
            .integer(forKey: "AppleFnUsageType") ?? 0
        return fnUsageIsClaimed(value)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh DogballWhisperTests/PermissionsTests`
Expected: PASS (all five).

- [ ] **Step 5: Implement onboarding**

`DogballWhisper/UI/OnboardingView.swift`:

```swift
import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    private let preferences: Preferences
    private let models: ModelManager
    private let onFinished: () -> Void

    init(preferences: Preferences, models: ModelManager, onFinished: @escaping () -> Void) {
        self.preferences = preferences
        self.models = models
        self.onFinished = onFinished
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 520, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Set up Dogball Whisper"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: OnboardingView(
                    preferences: preferences,
                    models: models,
                    onFinished: { [weak self] in
                        self?.onFinished()
                        self?.window?.close()
                    }
                )
            )
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct OnboardingView: View {
    let preferences: Preferences
    let models: ModelManager
    let onFinished: () -> Void

    @State private var granted: Set<PermissionKind> = []
    @State private var apiKey = ""
    /// Input Monitoring cannot report back, so the UI polls while it is open.
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Hold right ⌥, talk, let go. The text lands wherever you were typing.")
                .font(.title3)

            VStack(spacing: 10) {
                ForEach(PermissionKind.allCases, id: \.self) { kind in
                    permissionRow(kind)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Speech model").font(.headline)
                if let descriptor = ModelCatalog.descriptor(id: ModelCatalog.defaultModelID) {
                    HStack {
                        Text("\(descriptor.name) · \(descriptor.sizeLabel)")
                        Spacer()
                        switch models.state(for: descriptor) {
                        case .notInstalled:
                            Button("Download") { Task { try? await models.install(descriptor) } }
                        case let .downloading(fraction):
                            ProgressView(value: fraction).frame(width: 120)
                        case .installed, .active:
                            Label("Installed", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    Text("More models are available in Settings once you are set up.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Cleanup (optional)").font(.headline)
                SecureField("OpenRouter API key", text: $apiKey)
                Text("Removes ums and ahs and fixes punctuation. Only text is sent, never audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack {
                Text(Permissions.summary(granted: granted))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Start dictating") {
                    KeychainStore.save(apiKey)
                    onFinished()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canFinish)
            }
        }
        .padding(20)
        .onAppear {
            refresh()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { refresh() }
            }
        }
        .onDisappear {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    private var canFinish: Bool {
        Permissions.allRequiredGranted && models.activeModelID != nil
    }

    private func permissionRow(_ kind: PermissionKind) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(
                systemName: granted.contains(kind)
                    ? "checkmark.circle.fill" : "circle.dashed"
            )
            .foregroundStyle(granted.contains(kind) ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title + (kind.isRequired ? "" : " (optional)")).font(.body)
                Text(kind.explanation).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted.contains(kind) {
                Button("Grant") {
                    Task {
                        await Permissions.request(kind)
                        // macOS never re-prompts after a denial, so send the
                        // user straight to the pane when the prompt no-ops.
                        if !Permissions.isGranted(kind) {
                            Permissions.openSettings(for: kind)
                        }
                        refresh()
                    }
                }
            }
        }
    }

    private func refresh() {
        granted = Set(PermissionKind.allCases.filter(Permissions.isGranted))
    }
}
```

- [ ] **Step 6: Put onboarding in front of the launch path**

In `DogballWhisper/App/DogballWhisperApp.swift`, add `private var onboarding: OnboardingWindowController?` alongside the other stored properties, replace the unconditional startup block at the end of `applicationDidFinishLaunching`:

```swift
        if preferences.hasCompletedOnboarding && Permissions.allRequiredGranted {
            startMonitoring()
            Task {
                await models.loadActiveEngine()
                menuBar.setActiveModelName(
                    preferences.activeModelID.flatMap { ModelCatalog.descriptor(id: $0)?.name })
            }
        } else {
            showOnboarding()
        }
    }
```

and add:

```swift
    private func showOnboarding() {
        if onboarding == nil {
            onboarding = OnboardingWindowController(
                preferences: preferences,
                models: models,
                onFinished: { [weak self] in
                    guard let self else { return }
                    self.preferences.hasCompletedOnboarding = true
                    self.startMonitoring()
                    Task { await self.models.loadActiveEngine() }
                }
            )
        }
        onboarding?.show()
    }
```

- [ ] **Step 7: Build and walk through onboarding**

Run: `./scripts/build-mac.sh --launch`

To see it from scratch, reset the stored flag first:

```bash
defaults delete com.jonclegg.DogballWhisper hasCompletedOnboarding 2>/dev/null || true
```

Expected: the setup window opens, each permission row flips to a green check as it is granted (Input Monitoring flips within a second of granting it in System Settings, thanks to the poll), the Parakeet download shows real progress, and "Start dictating" enables only when both required permissions are granted and a model is active. Note that granting Input Monitoring makes macOS ask to quit and reopen the app; that is normal, and the event tap only works after the relaunch.

- [ ] **Step 8: Run the full suite and commit**

```bash
./scripts/test.sh
git add DogballWhisper/Core/Permissions.swift DogballWhisper/UI/OnboardingView.swift Tests/PermissionsTests.swift
git commit -m "feat: permission handling and first-run onboarding"
```

---

### Task 13: Docs and the manual smoke pass

**Files:**
- Create: `docs/MANUAL-SMOKE.md`, `README.md`

**Interfaces:**
- Consumes: everything built so far. Produces no code.


- [ ] **Step 1: Write the manual smoke checklist**

`docs/MANUAL-SMOKE.md`:

```markdown
# Manual smoke checklist

Covers what cannot be faked in tests: the event tap, Accessibility queries, and
synthetic paste. Run it before calling a change done.

Build and install: `./scripts/build-mac.sh --launch`

## Insertion across app kinds
- [ ] TextEdit: dictated text lands at the caret
- [ ] VS Code (Electron): text lands at the caret
- [ ] Terminal: text lands at the prompt
- [ ] Slack or Discord message box: text lands, no stray newline sent
- [ ] Browser text field (Chrome or Safari): text lands
- [ ] Clipboard check: copy "keepme", dictate, then ⌘V pastes "keepme"

## Panel placement
- [ ] Native app with a caret (TextEdit): panel floats just above the caret
- [ ] App reporting no caret (most Electron apps): panel appears near the bottom center
- [ ] Caret near the top of the screen: panel flips below it instead of clipping
- [ ] Second display: panel appears on the display holding the caret
- [ ] Fullscreen app: panel still appears on top
- [ ] Focus never moves: the app you were typing in stays active throughout

## Hotkey behavior
- [ ] Hold right ⌥ and release: dictation runs
- [ ] Tap right ⌥ quickly: nothing happens, no error panel
- [ ] Hold right ⌥ and press E: dictation cancels and no accent is broken (⌥E then E still types é)
- [ ] Rebind to right ⌘ in Settings and confirm it works without a relaunch
- [ ] Rebind to a custom combo (⌃⇧D) and confirm the keystroke does not reach the app
- [ ] Rebind to fn: if "Press 🌐 to" is not Do Nothing, the warning appears and the button opens Keyboard settings
- [ ] Press esc while holding: nothing is inserted
- [ ] Press esc right after releasing (while it says Transcribing or Polishing): nothing is inserted and no error appears
- [ ] Press esc with no dictation running: normal esc behavior in the focused app is unaffected

## Cleanup
- [ ] With a valid key: "so um I was uh thinking" inserts without the fillers
- [ ] Wrong key in Settings: raw transcript still inserts, panel shows no scary error
- [ ] Wi-Fi off: raw transcript inserts within about 3 seconds
- [ ] Cleanup toggled off: raw transcript inserts immediately
- [ ] Settings > Cleanup > Test returns cleaned sample text

## Models
- [ ] Install a Whisper model: progress advances, then it shows Installed
- [ ] Make it active: the menu shows its name and dictation uses it
- [ ] Delete it: it returns to Not installed and the files are gone from Application Support
- [ ] Quit mid-download, relaunch, download again: it resumes rather than restarting

## Lifecycle
- [ ] Launch at login on, reboot: the app is in the menu bar and dictation works with no re-prompting
- [ ] Launch at login off, reboot: the app does not start
- [ ] Rebuild and reinstall: macOS does not ask for permissions again (stable signature and bundle ID)
- [ ] No Dock icon and no window at launch once onboarding is done
```

- [ ] **Step 2: Write the README**

`README.md`:

```markdown
# Dogball Whisper

A menu-bar dictation client for macOS. Hold right ⌥, talk, let go, and the text
appears wherever you were typing. Transcription runs on this Mac; an optional
OpenRouter pass strips ums and ahs.

## Build and install

    ./scripts/build-mac.sh --launch    # builds Release, signs, installs to /Applications
    ./scripts/test.sh                  # unit tests
    RUN_ENGINE_IT=1 ./scripts/test.sh DogballWhisperTests/EngineIntegrationTests
    RUN_AUDIO_IT=1 ./scripts/test.sh DogballWhisperTests/AudioRecorderTests

Never open Xcode: `project.yml` plus `xcodegen` owns the project file, which is
gitignored.

## Permissions

Microphone and Input Monitoring are required. Accessibility is optional but
worth granting: without it the panel cannot find your caret and text is copied
to the clipboard instead of pasted.

Bundle ID and signing identity are fixed on purpose. macOS keys permission
grants to both, so changing either forces you to re-grant everything.

## Layout

- `Hotkey/` — the event tap and the pure matcher that decides began / ended / cancelled
- `Capture/` — 16kHz mono WAV recording with level metering
- `Transcribe/` — engine protocol, Parakeet (FluidAudio), Whisper (WhisperKit), model catalog
- `Polish/` — the OpenRouter cleanup call
- `Insert/` — caret location and clipboard-preserving paste
- `Core/DictationCoordinator.swift` — the state machine everything else hangs off
- `UI/` — floating panel, settings, onboarding

Docs: `docs/superpowers/specs/` for the design, `docs/MANUAL-SMOKE.md` for the
pre-ship checklist.
```

- [ ] **Step 3: Run the full suite**

Run: `./scripts/test.sh`
Expected: PASS, every test.

- [ ] **Step 4: Work the smoke checklist**

Run: `./scripts/build-mac.sh --launch`, then walk `docs/MANUAL-SMOKE.md` top to bottom. Fix anything that fails before moving on; note in the commit message anything deliberately left failing.

- [ ] **Step 5: Commit**

```bash
git add docs/MANUAL-SMOKE.md README.md
git commit -m "docs: readme and manual smoke checklist"
```

---

## Notes for the implementer

- **Every task ends with a compiling, testable app.** Tasks are ordered so nothing references a type that does not exist yet. If a task leaves you with a build error, re-read its step list before inventing a stub.
- **Regenerate after touching `project.yml`.** Both scripts run `xcodegen generate` first, so a new source file is picked up automatically. Adding a directory outside `DogballWhisper/` or `Tests/` needs a `project.yml` change.
- **Granting Input Monitoring restarts the app.** macOS prompts to quit and reopen; the tap does not work until it does. This is expected, not a bug.
- **Never change the bundle ID or the signing identity.** Every permission grant is keyed to them.
- **The 3-second cleanup timeout is a hard product decision**, not a placeholder. If a model is regularly slower than that, change the model, not the timeout.
