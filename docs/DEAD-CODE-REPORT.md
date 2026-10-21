# Dead-code and unused-resource report

Audit of `Toplet/` (363 Swift files, 116,833 lines), `TopletTests/`, `TopletUITests/`, `Toplet.xcodeproj`, 2026-10-21, branch `local-build`. **Read-only**: nothing was edited or removed. Tags: OBSERVED (file:line / command result), INFERRED, UNKNOWN. Line numbers are as of the audit; another process was editing `DynamicIslandApp.swift` during the audit, so re-anchor on the quoted signature before deleting.

## 0. Totals

| Removal set | Items | Swift files deleted whole | Lines | Bytes | Risk |
|---|---:|---:|---:|---:|---|
| A. Whole files with zero references (incl. 6 empty stub files) | 28 files | 28 | 1,793 | 67,847 | NONE |
| B. Whole files referenced only by `#Preview` or by set-A code | 14 files | 14 | 2,000 | 67,234 | LOW (preview-only) |
| C. Dead types / functions / properties / preview blocks / `if false` block inside live files | 32 types, 79 funcs, 27 props, 6 previews, 1 dead branch | 0 (edits in 74 files) | 2,057 | 76,666 | NONE (private) / LOW (internal) |
| **Swift total** | | **42** | **5,850** (5.0% of 116,833) | **211,747** (~206 KB) | |
| `metal/visualizer.metal` (unreferenced shader) | 1 | 1 | 18 | 414 | NONE |
| `LottieAnimations/Lock.json` (only user is dead `LockIconLottieView`; 4 pbxproj lines) | 1 | 1 | n/a | 4,090 | LOW |
| Unused imagesets `LinkedIn`, `chrome`, `defaultmusic` (empty) | 3 | n/a | n/a | 41,682 | LOW |
| `logo.imageset` (only users are dead `ProOnboard`, `StatusBarMenu`) | 1 | n/a | n/a | 1,566,789 | LOW |
| Root `Localizable.xcstrings` (not in target; stale duplicate) | 1 | n/a | n/a | 2,647,006 | LOW |
| 74 stale String Catalog entries absent from code | 74 keys | n/a | n/a | ~112,488 | NEEDS-CHECK |
| SwiftPM `Pow`, `open-meteo` (declared, never linked, never imported) | 2 packages | n/a | n/a | 0 in repo (saves resolve/clone) | LOW |
| Dead `Defaults` keys (of 373) | 4 zero-ref + 1 dead-code-only | n/a | 5 decl lines | n/a | NONE |
| Duplicate `MediaRemoteAdapter.framework` copy | 1 | n/a | n/a | 462,128 (binary; 460 KB dir) | NEEDS-CHECK |

## 1. Method: what "zero references" means here

1. **Token proof (OBSERVED, script).** Every Swift file (363 app + 23 test/UI-test) was stripped of comments and string-literal contents (newlines preserved), then tokenised into identifiers. A declaration (`class/struct/enum/protocol/actor/typealias`, `func`, `var/let`) is dead when its name occurs **only on declaration lines of that name** and inside its own body. Mentions in comments or strings do not count as references (they are listed separately as `grep -w` hits).
2. **Cascade.** Dead types/functions are removed from the token pool and the test is repeated until nothing changes (tier 1, tier 2, ...). `#Preview` bodies and `PreviewProvider` types are then removed and the test repeated (set B).
3. **Closure check (OBSERVED, script).** After deleting every range in this report, a final scan found **no code reference outside the removal set** to any removed type, function or property name (22 raw hits were the same short names, e.g. `show`, `path`, `makeNSView`, belonging to other live symbols; for the unit names themselves the result was empty). Six `#Preview` blocks must be deleted with the types they instantiate (section 3).
4. **Dynamic lookup survey (OBSERVED).** `NSClassFromString` is used 3 times, all for system/private classes (`KeyboardBrightnessClient`, CoreBrightness client names, `NSGlassEffectView`); `NSSelectorFromString` only for system selectors; **no `Mirror`**, no `dlsym` of app symbols (only `DisplayServices*` and `IOReport*`), 34 `#selector` uses (their tokens count as references), `setValue(forKey:)` only on system objects. The Xcode project uses a synchronized group, so every file under `Toplet/` except `Info.plist` compiles (`project.pbxproj:130-145`); there is no per-file membership to edit. No app type is reachable by string.
5. **Deliberately not flagged:** `@main` (`DynamicNotchApp`), protocol witnesses and delegate callbacks (`makeNSView`, `updateNSView`, `makeCoordinator`, `makeBody`, `placeSubviews`, `draggingSession`, `windowWillClose`, `urlSession`, `centralManager*`, `locationManager*`, `sharingService*`, `cookiesDidChange`, SwiftTerm delegate methods, `NSXPC` protocol methods in `ExtensionXPCService.swift`), `@objc`/`override` members, C-layout struct fields in `utils/SMC.swift`, IOReport `dlsym` wrappers.
6. **Risk scale:** NONE = private/fileprivate or a whole file whose every symbol has zero references; LOW = internal symbol with zero whole-module references (module-wide proof, no dynamic access found); NEEDS-CHECK = could be reached by a path this audit cannot see (string keys, persisted data, CI scripts).

## 2. Whole files

### 2.A Set A: zero references (risk NONE)

`grep -w` = `grep -rnwI --include='*.swift' -- <Symbol> DynamicIsland TopletTests TopletUITests | wc -l` for the file's main symbol (includes the declaration line and any comment/string mention). 'Outside' = code references outside the removal set = 0 for all rows. Rows with a larger count are referenced only from other set-A/B code or strings (tier 2+).

| File | Lines | Bytes | Main symbol | grep -w | Why dead | Removal |
|---|---:|---:|---|---:|---|---|
| `Toplet/components/BottomRoundedRectangle.swift` | 60 | 2,072 | `BottomRoundedRectangle` | 1 | Shape never instantiated | `rm "Toplet/components/BottomRoundedRectangle.swift"` |
| `Toplet/components/Live activities/LiveActivityModifier.swift` | 59 | 1,790 | `ActivityType` | 3 |  | `rm "Toplet/components/Live activities/LiveActivityModifier.swift"` |
| `Toplet/components/LockScreen/LockScreenDynamicIslandReplica.swift` | 19 | 727 | `LockScreenDynamicIslandReplica.swift` | 0 | license header only (no code), 19 lines | `rm "Toplet/components/LockScreen/LockScreenDynamicIslandReplica.swift"` |
| `Toplet/components/LockScreen/LockScreenLiveActivity.swift` | 150 | 5,932 | `LockScreenLiveActivity` | 1 | view never instantiated | `rm "Toplet/components/LockScreen/LockScreenLiveActivity.swift"` |
| `Toplet/components/Onboarding/ProOnboarding.swift` | 117 | 5,037 | `ProOnboard` | 1 | view never instantiated; contains `if false` | `rm "Toplet/components/Onboarding/ProOnboarding.swift"` |
| `Toplet/components/Settings/ListItemPopover.swift` | 44 | 1,400 | `ListItemPopover` | 1 | never instantiated | `rm "Toplet/components/Settings/ListItemPopover.swift"` |
| `Toplet/components/Shelf/AirDrop.swift` | 52 | 1,703 | `AirDrop` | 19 | only used by dead `AirDropView` (62 other `AirDrop` hits are strings/localisation) | `rm "Toplet/components/Shelf/AirDrop.swift"` |
| `Toplet/components/Shelf/AirDropView.swift` | 178 | 8,405 | `AirDropView` | 1 | never instantiated | `rm "Toplet/components/Shelf/AirDropView.swift"` |
| `Toplet/components/Shelf/DragDropView.swift` | 68 | 2,010 | `DragDropView` | 4 | only used by dead `DragDropViewRepresentable` | `rm "Toplet/components/Shelf/DragDropView.swift"` |
| `Toplet/components/Shelf/DropItemView.swift` | 91 | 3,339 | `DropItemView` | 1 | never instantiated | `rm "Toplet/components/Shelf/DropItemView.swift"` |
| `Toplet/components/Shelf/Services/ShareServiceFinder.swift` | 75 | 2,613 | `ShareServiceFinder` | 1 | never instantiated | `rm "Toplet/components/Shelf/Services/ShareServiceFinder.swift"` |
| `Toplet/components/Stats/DetailedTimelineGraph.swift` | 19 | 727 | `DetailedTimelineGraph.swift` | 0 | license header only (no code), 19 lines | `rm "Toplet/components/Stats/DetailedTimelineGraph.swift"` |
| `Toplet/components/Stats/DualTimelineGraph.swift` | 19 | 727 | `DualTimelineGraph.swift` | 0 | license header only (no code), 19 lines | `rm "Toplet/components/Stats/DualTimelineGraph.swift"` |
| `Toplet/extensions/AlbumArtFlipModifier.swift` | 19 | 727 | `AlbumArtFlipModifier.swift` | 2 | license header only (no code), 19 lines | `rm "Toplet/extensions/AlbumArtFlipModifier.swift"` |
| `Toplet/extensions/Button+Bouncing.swift` | 52 | 1,869 | `BouncingButtonStyle` | 3 | only `bouncingStyle` ext (unused) | `rm "Toplet/extensions/Button+Bouncing.swift"` |
| `Toplet/extensions/MouseTracker.swift` | 34 | 1,161 | `MouseTracker.swift` | 0 | `NSScreen.screenWithMouse` never read | `rm "Toplet/extensions/MouseTracker.swift"` |
| `Toplet/helpers/AppleScriptError.swift` | 25 | 847 | `AppleScriptError` | 7 | only used by dead `AppleScriptRunner` | `rm "Toplet/helpers/AppleScriptError.swift"` |
| `Toplet/helpers/AppleScriptRunner.swift` | 42 | 1,478 | `AppleScriptRunner` | 3 | only used by dead `SystemVolumeManager` | `rm "Toplet/helpers/AppleScriptRunner.swift"` |
| `Toplet/helpers/Clipboard+Content.swift` | 48 | 2,329 | `Clipboard+Content.swift` | 0 | `getAttributedString`/`isText` extensions never called | `rm "Toplet/helpers/Clipboard+Content.swift"` |
| `Toplet/helpers/SystemHUDDebugger.swift` | 93 | 3,625 | `SystemHUDDebugger` | 1 | debug helper, never called | `rm "Toplet/helpers/SystemHUDDebugger.swift"` |
| `Toplet/managers/ClipboardWindowManager.swift` | 119 | 4,333 | `ClipboardWindowManager` | 2 | `.shared` never used | `rm "Toplet/managers/ClipboardWindowManager.swift"` |
| `Toplet/managers/ColorPickerManager_Fixed.swift` | 19 | 727 | `ColorPickerManager_Fixed.swift` | 0 | license header only (no code), 19 lines | `rm "Toplet/managers/ColorPickerManager_Fixed.swift"` |
| `Toplet/managers/LockScreenReminderWidgetManager.swift` | 132 | 4,695 | `LockScreenReminderWidgetManager` | 4 | `.shared` never used | `rm "Toplet/managers/LockScreenReminderWidgetManager.swift"` |
| `Toplet/managers/SystemDisplayManager.swift` | 83 | 2,959 | `SystemDisplayManager` | 2 | never used (spawns `corebrightnessdiag`) | `rm "Toplet/managers/SystemDisplayManager.swift"` |
| `Toplet/managers/SystemKeyObserver.swift` | 54 | 2,448 | `SystemKeyObserver` | 4 | NSApplication subclass, never set as principal class (no `NSPrincipalClass` in pbxproj/Info.plist) | `rm "Toplet/managers/SystemKeyObserver.swift"` |
| `Toplet/managers/SystemVolumeManager.swift` | 45 | 1,681 | `SystemVolumeManager` | 1 | never used | `rm "Toplet/managers/SystemVolumeManager.swift"` |
| `Toplet/menu/StatusBarMenu.swift` | 58 | 1,759 | `StatusBarMenu` | 1 | never used (only user of `logo` imageset besides ProOnboard) | `rm "Toplet/menu/StatusBarMenu.swift"` |
| `Toplet/utils/Environment+LockScreenReplica.swift` | 19 | 727 | `Environment+LockScreenReplica.swift` | 0 | license header only (no code), 19 lines | `rm "Toplet/utils/Environment+LockScreenReplica.swift"` |

### 2.B Set B: referenced only by `#Preview` or by set-A code (risk LOW)

Removing these also removes their `#Preview` blocks (inside the same file). Each type's only non-self code references are a `#Preview` or a set-A type.

| File | Lines | Bytes | Types in file | Removal |
|---|---:|---:|---|---|
| `Toplet/components/Clipboard/ClipboardWindow.swift` | 314 | 11,126 | `ClipboardWindow`, `ClipboardWindowHeader`, `ClipboardWindowContent`, `ClipboardEmptyState` | `rm "Toplet/components/Clipboard/ClipboardWindow.swift"` |
| `Toplet/components/ColorPicker/ColorPickedFeedbackView.swift` | 78 | 2,810 | `ColorPickedFeedbackView` | `rm "Toplet/components/ColorPicker/ColorPickedFeedbackView.swift"` |
| `Toplet/components/DynamicIslandSystemTiles.swift` | 109 | 3,642 | `SystemItemButton`, `DynamicIslandSystemTiles` | `rm "Toplet/components/DynamicIslandSystemTiles.swift"` |
| `Toplet/components/EmptyState.swift` | 45 | 1,456 | `EmptyStateView` | `rm "Toplet/components/EmptyState.swift"` |
| `Toplet/components/Notch/ClipboardHistoryPopover.swift` | 215 | 7,335 | `ClipboardHistoryPopover`, `ClipboardItemRow` | `rm "Toplet/components/Notch/ClipboardHistoryPopover.swift"` |
| `Toplet/components/Notch/DynamicIslandExtrasMenu.swift` | 121 | 3,634 | `DynamicIslandLargeButtons`, `DynamicIslandExtrasMenu` | `rm "Toplet/components/Notch/DynamicIslandExtrasMenu.swift"` |
| `Toplet/components/ProgressIndicator.swift` | 79 | 2,158 | `CircularProgressView`, `ProgressIndicatorType`, `ProgressIndicator` | `rm "Toplet/components/ProgressIndicator.swift"` |
| `Toplet/components/Settings/CustomUpdaterViews/AtollUserDriver.swift` | 273 | 9,403 | `AtollUserDriver`, `UpdateUIState`, `UpdatePhase`, `UpdateCheckingView` | `rm "Toplet/components/Settings/CustomUpdaterViews/AtollUserDriver.swift"` |
| `Toplet/components/Settings/CustomUpdaterViews/UpdateErrorView.swift` | 130 | 4,273 | `UpdateErrorView` | `rm "Toplet/components/Settings/CustomUpdaterViews/UpdateErrorView.swift"` |
| `Toplet/components/Settings/CustomUpdaterViews/UpdateNotFoundView.swift` | 136 | 4,585 | `UpdateNotFoundView` | `rm "Toplet/components/Settings/CustomUpdaterViews/UpdateNotFoundView.swift"` |
| `Toplet/components/Settings/CustomUpdaterViews/UpdateProgressView.swift` | 251 | 9,231 | `UpdateProgressView` | `rm "Toplet/components/Settings/CustomUpdaterViews/UpdateProgressView.swift"` |
| `Toplet/components/TestView.swift` | 108 | 3,890 | `FluidSlider` | `rm "Toplet/components/TestView.swift"` |
| `Toplet/components/Tips/TipStore.swift` | 90 | 2,194 | `HUDsTip`, `CBTip`, `TipsView` | `rm "Toplet/components/Tips/TipStore.swift"` |
| `Toplet/components/WhatsNewView.swift` | 51 | 1,497 | `WhatsNewView` | `rm "Toplet/components/WhatsNewView.swift"` |

Dependency order: delete `ClipboardWindowManager.swift` (A) with `ClipboardWindow.swift` (B); `AtollUserDriver.swift` (B) holds `UpdateUIState`/`UpdatePhase`, whose last non-preview user is `UpdateFoundView` (section 3), so remove that preview block together with it.

## 3. Dead declarations inside live files

### 3.1 Types (nested or top-level) with zero references

| Name | Location (line range) | Lines | Bytes | grep -w (swift) | Risk | Signature anchor |
|---|---|---:|---:|---:|---|---|
| `FullScreenDropDelegate` | `Toplet/ContentView.swift:3304-3321` | 18 | 377 | 1 | LOW | `struct FullScreenDropDelegate: DropDelegate {` |
| `AuthenticationState` | `Toplet/MediaControllers/YouTube Music Controller/YouTubeMusicAuthentication.swift:83-102` | 20 | 421 | 1 | LOW | `enum AuthenticationState: Sendable {` |
| `LockIconLottieView` | `Toplet/components/LockScreen/LockIconAnimationView.swift:166-193` | 28 | 777 | 2 | LOW | `struct LockIconLottieView: View {` |
| `TypingLyricView` | `Toplet/components/Notch/MinimalisticMusicPlayerView.swift:164-219` | 56 | 1939 | 2 | LOW | `struct TypingLyricView: View {` |
| `PrivacyIndicatorIcon` | `Toplet/components/PrivacyIndicatorIcon.swift:55-124` | 70 | 2169 | 9 | LOW | `struct PrivacyIndicatorIcon: View {` |
| `PrivacyIndicatorContainer` | `Toplet/components/PrivacyIndicatorIcon.swift:128-159` | 32 | 1174 | 4 | LOW | `struct PrivacyIndicatorContainer: View {` |
| `PrivacyIndicatorDetailView` | `Toplet/components/PrivacyIndicatorIcon.swift:163-224` | 62 | 2336 | 2 | LOW | `struct PrivacyIndicatorDetailView: View {` |
| `ScreenAssistantPanelView` | `Toplet/components/ScreenAssistant/ScreenAssistantPanel.swift:96-110` | 15 | 398 | 2 | LOW | `struct ScreenAssistantPanelView: View {` |
| `ApiKeyAlertView` | `Toplet/components/ScreenAssistant/ScreenAssistantPanel.swift:236-257` | 22 | 653 | 2 | LOW | `struct ApiKeyAlertView: View {` |
| `ScreenshotError` | `Toplet/components/ScreenAssistant/ScreenshotSnippingTool.swift:64-68` | 5 | 124 | 1 | LOW | `enum ScreenshotError: Error {` |
| `UpdateFoundView` | `Toplet/components/Settings/CustomUpdaterViews/UpdateFoundView.swift:26-190` | 165 | 6027 | 3 | LOW | `struct UpdateFoundView: View {` |
| `EditPanelView` | `Toplet/components/Settings/EditPanelView.swift:25-46` | 22 | 696 | 3 | LOW | `struct EditPanelView: View {` |
| `SharingServiceDelegate` | `Toplet/components/Shelf/Services/QuickShareService.swift:273-273` | 1 | 50 | 2 | NONE | `private class SharingServiceDelegate: NSObject {}` |
| `LegendRow` | `Toplet/components/Stats/CPUStatsSharedViews.swift:308-327` | 20 | 560 | 1 | LOW | `struct LegendRow: View {` |
| `LoadAverageRow` | `Toplet/components/Stats/CPUStatsSharedViews.swift:329-344` | 16 | 613 | 2 | LOW | `struct LoadAverageRow: View {` |
| `LoadAverageValue` | `Toplet/components/Stats/CPUStatsSharedViews.swift:346-360` | 15 | 428 | 4 | LOW | `struct LoadAverageValue: View {` |
| `CPUDetailsGrid` | `Toplet/components/Stats/CPUStatsSharedViews.swift:443-480` | 38 | 1688 | 1 | LOW | `struct CPUDetailsGrid: View {` |
| `TimerIconView` | `Toplet/components/Timer/TimerIconAnimation.swift:56-68` | 13 | 484 | 1 | LOW | `struct TimerIconView: NSViewRepresentable {` |
| `RecordingIndicator_Previews` | `Toplet/components/UI/RecordingIndicator.swift:80-110` | 31 | 991 | 1 | LOW | `struct RecordingIndicator_Previews: PreviewProvider {` |
| `RecordingIndicatorLarge` | `Toplet/components/UI/RecordingIndicator.swift:114-158` | 45 | 1830 | 1 | LOW | `struct RecordingIndicatorLarge: View {` |
| `RecordingIndicatorSubtle` | `Toplet/components/UI/RecordingIndicator.swift:162-183` | 22 | 779 | 1 | LOW | `struct RecordingIndicatorSubtle: View {` |
| `SettingsEnum` | `Toplet/enums/generic.swift:103-112` | 10 | 159 | 1 | LOW | `enum SettingsEnum {` |
| `BundleAppIcon` | `Toplet/extensions/BundleInfos.swift:46-52` | 7 | 180 | 1 | LOW | `struct BundleAppIcon: View {` |
| `AppIcons` | `Toplet/helpers/AppIcons.swift:23-49` | 27 | 832 | 2 | LOW | `struct AppIcons {` |
| `Display` | `Toplet/helpers/SensorError.swift:22-26` | 5 | 103 | 27 | LOW | `enum Display: Error {` |
| `BetterDisplayRequestData` | `Toplet/managers/BetterDisplayManager.swift:45-49` | 5 | 143 | 2 | LOW | `struct BetterDisplayRequestData: Codable {` |
| `BetterDisplayResponseData` | `Toplet/managers/BetterDisplayManager.swift:52-56` | 5 | 115 | 3 | LOW | `struct BetterDisplayResponseData: Codable {` |
| `ColorFormatter` | `Toplet/managers/ColorPickerManager.swift:41-58` | 18 | 421 | 2 | LOW | `struct ColorFormatter {` |
| `LunarControlCategory` | `Toplet/managers/LunarManager.swift:39-43` | 5 | 84 | 1 | LOW | `enum LunarControlCategory {` |
| `WebcamError` | `Toplet/managers/WebcamManager.swift:67-82` | 16 | 534 | 1 | LOW | `enum WebcamError: Error, LocalizedError {` |
| `ViewLifecycleTracker` | `Toplet/utils/Logger.swift:140-154` | 15 | 453 | 2 | LOW | `struct ViewLifecycleTracker: ViewModifier {` |
| `FanMode` | `Toplet/utils/SMC.swift:53-56` | 4 | 81 | 2 | LOW | `public enum FanMode: Int, Codable {` |

Rows `BetterDisplayRequestData/ResponseData`, `ViewLifecycleTracker`, `FanMode`, `UpdateFoundView`, `PrivacyIndicator*`, `ScreenAssistantPanelView`, `EditPanelView` are tier 2+ (they become dead after the functions below or after their `#Preview` is deleted).

### 3.2 Functions with zero references

| Name | Location (line range) | Lines | Bytes | grep -w (swift) | Risk | Signature anchor |
|---|---|---:|---:|---:|---|---|
| `reminderIconName` | `Toplet/ContentView.swift:1819-1821` | 3 | 261 | 1 | NONE | `private func reminderIconName(for reminder: ReminderLiveActivityManager.ReminderEntr` |
| `applicationShouldTerminate` | `Toplet/DynamicIslandApp.swift:284-296` | 13 | 914 | 1 | LOW | `func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateR` |
| `deviceHasNotch` | `Toplet/DynamicIslandApp.swift:1575-1584` | 10 | 272 | 1 | LOW | `func deviceHasNotch() -> Bool {` |
| `showEmpty` | `Toplet/DynamicIslandViewCoordinator.swift:450-452` | 3 | 57 | 1 | LOW | `func showEmpty() {` |
| `toggleClipboardPopover` | `Toplet/DynamicIslandViewCoordinator.swift:457-460` | 4 | 151 | 1 | LOW | `func toggleClipboardPopover() {` |
| `refreshPlaybackModes` | `Toplet/MediaControllers/TidalController.swift:131-140` | 10 | 378 | 1 | LOW | `func refreshPlaybackModes() async {` |
| `positionNearMouse` | `Toplet/components/Clipboard/ClipboardPanel.swift:163-179` | 17 | 754 | 1 | LOW | `func positionNearMouse() {` |
| `scaleDownEditor` | `Toplet/components/Notch/NotchNotesView.swift:410-412` | 3 | 65 | 1 | NONE | `private func scaleDownEditor() {` |
| `graphView` | `Toplet/components/Notch/NotchStatsView.swift:310-312` | 3 | 113 | 1 | LOW | `func graphView(for graphData: GraphData) -> some View {` |
| `startAreaScreenshot` | `Toplet/components/ScreenAssistant/ScreenshotSnippingTool.swift:87-89` | 3 | 133 | 1 | LOW | `func startAreaScreenshot(completion: @escaping (URL) -> Void) {` |
| `startFullScreenshot` | `Toplet/components/ScreenAssistant/ScreenshotSnippingTool.swift:91-93` | 3 | 133 | 1 | LOW | `func startFullScreenshot(completion: @escaping (URL) -> Void) {` |
| `startWindowScreenshot` | `Toplet/components/ScreenAssistant/ScreenshotSnippingTool.swift:95-97` | 3 | 137 | 1 | LOW | `func startWindowScreenshot(completion: @escaping (URL) -> Void) {` |
| `cancelSnipping` | `Toplet/components/ScreenAssistant/ScreenshotSnippingTool.swift:197-200` | 4 | 115 | 1 | LOW | `func cancelSnipping() {` |
| `proFeatureBadge` | `Toplet/components/Settings/SettingsView.swift:7319-7326` | 8 | 354 | 1 | LOW | `func proFeatureBadge() -> some View {` |
| `comingSoonTag` | `Toplet/components/Settings/SettingsView.swift:7328-7336` | 9 | 282 | 1 | LOW | `func comingSoonTag() -> some View {` |
| `warningBadge` | `Toplet/components/Settings/SettingsView.swift:7360-7375` | 16 | 504 | 1 | LOW | `func warningBadge(_ text: String, _ description: String) -> some View {` |
| `popRestart` | `Toplet/components/Shelf/Ext+NSAlert.swift:31-42` | 12 | 541 | 1 | LOW | `static func popRestart(_ error: String, completion: @escaping () -> Void) {` |
| `withAccess` | `Toplet/components/Shelf/Models/Bookmark.swift:127-133` | 7 | 295 | 2 | LOW | `func withAccess<T: Sendable>(_ block: @Sendable (URL) async throws -> T) async rethr` |
| `withAccess` | `Toplet/components/Shelf/Models/Bookmark.swift:135-141` | 7 | 251 | 2 | LOW | `func withAccess<T>(_ block: (URL) throws -> T) rethrows -> T? {` |
| `loadDisplayName` | `Toplet/components/Shelf/Models/ShelfItem.swift:138-190` | 53 | 2595 | 3 | LOW | `func loadDisplayName() async -> String {` |
| `loadIcon` | `Toplet/components/Shelf/Models/ShelfItem.swift:192-209` | 18 | 763 | 2 | LOW | `func loadIcon() async -> NSImage {` |
| `clearAllRejectedStatuses` | `Toplet/components/Shelf/Services/LocalSendService.swift:83-85` | 3 | 82 | 1 | LOW | `func clearAllRejectedStatuses() {` |
| `arpNeighborIPs` | `Toplet/components/Shelf/Services/LocalSendService.swift:388-437` | 50 | 1870 | 1 | NONE | `private func arpNeighborIPs() -> [String] {` |
| `localSubnetSweepIPs` | `Toplet/components/Shelf/Services/LocalSendService.swift:439-452` | 14 | 553 | 1 | NONE | `private func localSubnetSweepIPs(radius: Int) -> [String] {` |
| `showQuickLook` | `Toplet/components/Shelf/Services/QuickLookService.swift:92-94` | 3 | 106 | 1 | LOW | `func showQuickLook(urls: [URL]) {` |
| `reveal` | `Toplet/components/Shelf/Services/ShelfActionService.swift:44-49` | 6 | 241 | 3 | LOW | `static func reveal(_ item: ShelfItem) {` |
| `copyPath` | `Toplet/components/Shelf/Services/ShelfActionService.swift:51-57` | 7 | 297 | 1 | LOW | `static func copyPath(_ item: ShelfItem) {` |
| `createFile` | `Toplet/components/Shelf/Services/TemporaryFileStorageService.swift:135-143` | 9 | 269 | 1 | NONE | `private func createFile(at url: URL, data: Data) -> URL? {` |
| `cleanExpiredFiles` | `Toplet/components/Shelf/TrayDrop.swift:56-63` | 8 | 227 | 1 | LOW | `func cleanExpiredFiles() {` |
| `loadDisplayName` | `Toplet/components/Shelf/ViewModels/ShelfItemViewModel.swift:84-91` | 8 | 386 | 3 | LOW | `func loadDisplayName() async {` |
| `loadIcon` | `Toplet/components/Shelf/ViewModels/ShelfItemViewModel.swift:126-133` | 8 | 367 | 2 | LOW | `func loadIcon() async {` |
| `resolveFileURL` | `Toplet/components/Shelf/ViewModels/ShelfItemViewModel.swift:140-145` | 6 | 247 | 1 | LOW | `func resolveFileURL() async -> URL? {` |
| `loadOpenWithApps` | `Toplet/components/Shelf/ViewModels/ShelfItemViewModel.swift:306-330` | 25 | 1278 | 1 | LOW | `func loadOpenWithApps() -> [URL] {` |
| `ensureValidAnchor` | `Toplet/components/Shelf/ViewModels/ShelfSelectionModel.swift:116-120` | 5 | 203 | 1 | LOW | `func ensureValidAnchor(in allItems: [ShelfItem]) {` |
| `gigabytes` | `Toplet/components/Stats/StatsFormatting.swift:73-78` | 6 | 311 | 1 | LOW | `static func gigabytes(_ value: Double) -> String {` |
| `isNewVersion` | `Toplet/extensions/BundleInfos.swift:54-64` | 11 | 362 | 1 | LOW | `func isNewVersion() -> Bool {` |
| `isExtensionRunning` | `Toplet/extensions/BundleInfos.swift:66-72` | 7 | 208 | 1 | LOW | `func isExtensionRunning(_ bundleID: String) -> Bool {` |
| `dayOfTheWeek` | `Toplet/extensions/DataTypes+Extensions.swift:52-57` | 6 | 287 | 1 | LOW | `func dayOfTheWeek(dayOfWeek: Int) -> String {` |
| `averageColor` | `Toplet/extensions/NSImage+Extensions.swift:48-135` | 88 | 3668 | 1 | LOW | `func averageColor(completion: @escaping (NSColor?) -> Void) {` |
| `requestSync` | `Toplet/managers/AppleNotesSyncManager.swift:65-72` | 8 | 292 | 1 | LOW | `func requestSync(localNotes: [NoteItem]) {` |
| `sendRequest` | `Toplet/managers/BetterDisplayManager.swift:427-502` | 76 | 2919 | 2 | LOW | `func sendRequest(` |
| `handleDeviceConnected` | `Toplet/managers/BluetoothAudioManager.swift:489-518` | 30 | 1120 | 1 | NONE | `private func handleDeviceConnected(_ notification: Notification) {` |
| `handleDeviceDisconnected` | `Toplet/managers/BluetoothAudioManager.swift:521-538` | 18 | 740 | 1 | NONE | `private func handleDeviceDisconnected(_ notification: Notification) {` |
| `toggleMonitoring` | `Toplet/managers/CameraMonitor.swift:142-148` | 7 | 148 | 4 | LOW | `func toggleMonitoring() {` |
| `toggleColorPicker` | `Toplet/managers/ColorPickerManager.swift:78-84` | 7 | 155 | 1 | LOW | `func toggleColorPicker() {` |
| `stopColorPicking` | `Toplet/managers/ColorPickerManager.swift:123-126` | 4 | 123 | 2 | LOW | `func stopColorPicking() {` |
| `togglePanel` | `Toplet/managers/ColorPickerManager.swift:128-130` | 3 | 63 | 1 | LOW | `func togglePanel() {` |
| `updateFeatureToggles` | `Toplet/managers/Extensions/ExtensionAuthorizationManager.swift:45-54` | 10 | 733 | 1 | LOW | `func updateFeatureToggles(extensionsEnabled: Bool? = nil,` |
| `recordDeniedRequest` | `Toplet/managers/Extensions/ExtensionAuthorizationManager.swift:161-166` | 6 | 281 | 1 | LOW | `func recordDeniedRequest(bundleIdentifier: String, reason: String) {` |
| `loadStoredUserAnimations` | `Toplet/managers/IdleAnimationManager.swift:137-161` | 25 | 1061 | 1 | NONE | `private func loadStoredUserAnimations() -> [CustomIdleAnimation]? {` |
| `updateAnimation` | `Toplet/managers/IdleAnimationManager.swift:278-299` | 22 | 821 | 1 | LOW | `func updateAnimation(_ animation: CustomIdleAnimation, name: String? = nil, speed: C` |
| `resolveRates` | `Toplet/managers/LLMUsage/ModelPricing.swift:25-34` | 10 | 523 | 1 | LOW | `static func resolveRates(for modelId: String) -> (prompt: Double, completion: Double` |
| `setPreviewMode` | `Toplet/managers/LockScreenTimerWidgetManager.swift:59-63` | 5 | 161 | 1 | LOW | `func setPreviewMode(_ enabled: Bool) {` |
| `formattedTimeToFullCharge` | `Toplet/managers/MacBatteryManager.swift:69-82` | 14 | 423 | 1 | LOW | `func formattedTimeToFullCharge() -> String? {` |
| `toggleMonitoring` | `Toplet/managers/MicrophoneMonitor.swift:145-151` | 7 | 148 | 4 | LOW | `func toggleMonitoring() {` |
| `fetchLyrics` | `Toplet/managers/MusicManager.swift:1771-1773` | 3 | 136 | 2 | LOW | `func fetchLyrics() {` |
| `toggleLyrics` | `Toplet/managers/MusicManager.swift:2233-2254` | 22 | 847 | 1 | LOW | `func toggleLyrics() {` |
| `toggleMonitoring` | `Toplet/managers/PrivacyIndicatorManager.swift:239-245` | 7 | 196 | 4 | LOW | `func toggleMonitoring() {` |
| `getStatusString` | `Toplet/managers/PrivacyIndicatorManager.swift:248-255` | 8 | 443 | 1 | LOW | `func getStatusString() -> String {` |
| `clearChat` | `Toplet/managers/ScreenAssistantManager.swift:1176-1178` | 3 | 64 | 1 | LOW | `func clearChat() {` |
| `toggleMonitoring` | `Toplet/managers/ScreenRecordingManager.swift:242-248` | 7 | 148 | 4 | LOW | `func toggleMonitoring() {` |
| `getProcessesRankedByCPU` | `Toplet/managers/StatsManager.swift:1414-1417` | 4 | 170 | 1 | LOW | `func getProcessesRankedByCPU() -> [ProcessStats] {` |
| `isOSDUIHelperRunningAsync` | `Toplet/managers/SystemOSDManager.swift:544-551` | 8 | 318 | 1 | LOW | `public static func isOSDUIHelperRunningAsync() async -> Bool {` |
| `isTerminalFirstResponder` | `Toplet/managers/TerminalManager.swift:613-617` | 5 | 243 | 1 | LOW | `func isTerminalFirstResponder() -> Bool {` |
| `formattedElapsedTime` | `Toplet/managers/TimerManager.swift:532-534` | 3 | 95 | 1 | LOW | `func formattedElapsedTime() -> String {` |
| `formattedTotalDuration` | `Toplet/managers/TimerManager.swift:536-538` | 3 | 99 | 1 | LOW | `func formattedTotalDuration() -> String {` |
| `updateWindowInteractivity` | `Toplet/managers/VerticalHUDWindowManager.swift:121-125` | 5 | 141 | 1 | NONE | `private func updateWindowInteractivity() {` |
| `preferredDynamicIslandTargetScreenName` | `Toplet/models/BatteryStatusViewModel.swift:244-265` | 22 | 849 | 1 | NONE | `private func preferredDynamicIslandTargetScreenName() -> String? {` |
| `isMouseHovering` | `Toplet/models/DynamicIslandViewModel.swift:382-393` | 12 | 450 | 1 | LOW | `func isMouseHovering(position: NSPoint = NSEvent.mouseLocation) -> Bool {` |
| `fantasticalShowURL` | `Toplet/models/EventModel.swift:159-168` | 10 | 499 | 1 | LOW | `static func fantasticalShowURL(for date: Date? = nil) -> URL? {` |
| `requestCloseIfReady` | `Toplet/models/SharingStateManager.swift:53-57` | 5 | 136 | 1 | LOW | `func requestCloseIfReady() {` |
| `cleanupNotificationObservers` | `Toplet/observers/FullscreenMediaDetection.swift:154-156` | 3 | 123 | 1 | NONE | `private func cleanupNotificationObservers() {` |
| `trackMemory` | `Toplet/utils/Logger.swift:106-131` | 26 | 919 | 3 | LOW | `static func trackMemory(` |
| `trackLifecycle` | `Toplet/utils/Logger.swift:135-137` | 3 | 135 | 1 | LOW | `func trackLifecycle(_ identifier: String) -> some View {` |
| `getStringValue` | `Toplet/utils/SMC.swift:275-313` | 39 | 1688 | 1 | LOW | `public func getStringValue(_ key: String) -> String? {` |
| `getAllKeys` | `Toplet/utils/SMC.swift:315-344` | 30 | 901 | 1 | LOW | `public func getAllKeys() -> [String] {` |
| `setFanMode` | `Toplet/utils/SMC.swift:361-432` | 72 | 3220 | 1 | LOW | `public func setFanMode(_ id: Int, mode: FanMode) {` |
| `setFanSpeed` | `Toplet/utils/SMC.swift:434-469` | 36 | 1348 | 1 | LOW | `public func setFanSpeed(_ id: Int, speed: Int) {` |
| `resetFans` | `Toplet/utils/SMC.swift:471-479` | 9 | 327 | 1 | LOW | `public func resetFans() {` |

Notes: `fetchLyrics` (MusicManager) and `stopColorPicking`, `trackMemory` are tier 2 (their only callers are `toggleLyrics`, `toggleColorPicker`, `trackLifecycle`). `handleDeviceConnected`/`handleDeviceDisconnected` are private and pre-date the current DistributedNotification handlers. `toggleMonitoring` appears four times (Camera, Microphone, PrivacyIndicator, ScreenRecording); each is a distinct method with no caller.

### 3.3 Properties with zero references (private or provable)

| Name | Location (line range) | Lines | Bytes | grep -w (swift) | Risk | Signature anchor |
|---|---|---:|---:|---:|---|---|
| `dynamicNotchResizeAnimation` | `Toplet/ContentView.swift:300-302` | 3 | 76 | 1 | NONE | `private var dynamicNotchResizeAnimation: Animation? {` |
| `recordingHUDInlineExpandedOnHover` | `Toplet/ContentView.swift:551-553` | 3 | 112 | 1 | NONE | `private var recordingHUDInlineExpandedOnHover: Bool {` |
| `recordingHUDExtraWidth` | `Toplet/ContentView.swift:555-557` | 3 | 94 | 1 | NONE | `private var recordingHUDExtraWidth: CGFloat {` |
| `recordingHUDExtraHeight` | `Toplet/ContentView.swift:559-561` | 3 | 96 | 1 | NONE | `private var recordingHUDExtraHeight: CGFloat {` |
| `lastMusicItem` | `Toplet/MediaControllers/NowPlayingController.swift:51-53` | 3 | 132 | 1 | NONE | `private var lastMusicItem:` |
| `sliderExtraHeight` | `Toplet/components/LockScreen/LockScreenMusicPanel.swift:1358-1360` | 3 | 130 | 1 | NONE | `private var sliderExtraHeight: CGFloat {` |
| `lyricsExtraHeight` | `Toplet/components/LockScreen/LockScreenMusicPanel.swift:1366-1368` | 3 | 130 | 1 | NONE | `private var lyricsExtraHeight: CGFloat {` |
| `paneBackgroundColor` | `Toplet/components/Settings/SettingsView.swift:2003-2005` | 3 | 99 | 1 | NONE | `private var paneBackgroundColor: Color {` |
| `notchWidthRange` | `Toplet/components/Settings/SettingsView.swift:4899-4903` | 5 | 224 | 1 | NONE | `private var notchWidthRange: ClosedRange<Double> {` |
| `defaultOpenNotchWidth` | `Toplet/components/Settings/SettingsView.swift:4904-4906` | 3 | 101 | 1 | NONE | `private var defaultOpenNotchWidth: CGFloat {` |
| `showAlphaWarning` | `Toplet/components/Settings/SettingsView.swift:8965-8965` | 1 | 48 | 1 | NONE | `@State private var showAlphaWarning = false` |
| `fontDisplayName` | `Toplet/components/Settings/SettingsView.swift:9354-9356` | 3 | 126 | 1 | NONE | `private var fontDisplayName: String {` |
| `dataSource` | `Toplet/components/Shelf/Services/QuickLookService.swift:37-38` | 2 | 91 | 1 | NONE | `private var dataSource: QuickLookDataSource?` |
| `previewPanelObserver` | `Toplet/components/Shelf/Services/QuickLookService.swift:39-40` | 2 | 44 | 1 | NONE | `private var previewPanelObserver: Any?` |
| `quickShareLifecycle` | `Toplet/components/Shelf/ViewModels/ShelfItemViewModel.swift:40-41` | 2 | 112 | 1 | NONE | `private var quickShareLifecycle: SharingLifecycleDelegate?` |
| `notchToggleProviders` | `Toplet/components/Shelf/Views/FileShareView.swift:47-49` | 3 | 159 | 1 | NONE | `private var notchToggleProviders: [QuickShareProvider] {` |
| `showStack` | `Toplet/components/Shelf/Views/ShelfItemView.swift:48-48` | 1 | 41 | 1 | NONE | `@State private var showStack = false` |
| `notificationSelector` | `Toplet/helpers/CoreBrightnessDisplayClient.swift:30-30` | 1 | 85 | 1 | NONE | `private let notificationSelector = NSSelectorFromString("setNotificationBlock:")` |
| `syncFolderName` | `Toplet/managers/AppleNotesSyncManager.swift:56-56` | 1 | 48 | 4 | NONE | `private static let syncFolderName = "Atoll"` |
| `responseObserver` | `Toplet/managers/BetterDisplayManager.swift:110-115` | 6 | 321 | 1 | NONE | `private var responseObserver: NSObjectProtocol?` |
| `IOBluetoothDeviceConnectionNotification` | `Toplet/managers/BluetoothAudioManager.swift:2948-2948` | 1 | 96 | 1 | NONE | `private let IOBluetoothDeviceConnectionNotification = "IOBluetoothDeviceConnectionNo` |
| `IOBluetoothDeviceDisconnectionNotification` | `Toplet/managers/BluetoothAudioManager.swift:2949-2949` | 1 | 102 | 1 | NONE | `private let IOBluetoothDeviceDisconnectionNotification = "IOBluetoothDeviceDisconnec` |
| `isCleaningUp` | `Toplet/managers/WebcamManager.swift:63-63` | 1 | 43 | 1 | NONE | `private var isCleaningUp: Bool = false` |
| `wasCharging` | `Toplet/models/BatteryStatusViewModel.swift:38-38` | 1 | 42 | 1 | NONE | `private var wasCharging: Bool = false` |
| `powerSourceChangedCallback` | `Toplet/models/BatteryStatusViewModel.swift:39-41` | 3 | 202 | 1 | NONE | `private var powerSourceChangedCallback: IOPowerSourceCallbackType?` |
| `availableDirectories` | `Toplet/models/Constants.swift:29-31` | 3 | 116 | 1 | NONE | `private let availableDirectories = FileManager` |
| `contentElementTypeFields` | `Toplet/services/Extensions/ExtensionRPCService.swift:48-50` | 3 | 156 | 1 | NONE | `private static let contentElementTypeFields: Set<String> = [` |

### 3.4 `#Preview` blocks to delete together with the types above

| Name | Location (line range) | Lines | Bytes | grep -w (swift) | Risk | Signature anchor |
|---|---|---:|---:|---:|---|---|
| `#Preview (PrivacyIndicatorIcon)` | `Toplet/components/PrivacyIndicatorIcon.swift:227-236` | 10 | 328 | 0 | LOW | `#Preview("Single Indicators") {` |
| `#Preview (PrivacyIndicatorContainer)` | `Toplet/components/PrivacyIndicatorIcon.swift:238-266` | 29 | 794 | 0 | LOW | `#Preview("Container") {` |
| `#Preview (PrivacyIndicatorDetailView)` | `Toplet/components/PrivacyIndicatorIcon.swift:268-278` | 11 | 285 | 0 | LOW | `#Preview("Detail View") {` |
| `#Preview (ScreenAssistantPanelView)` | `Toplet/components/ScreenAssistant/ScreenAssistantPanel.swift:259-263` | 5 | 79 | 0 | LOW | `#Preview {` |
| `#Preview (UpdateFoundView, UpdateUIState)` | `Toplet/components/Settings/CustomUpdaterViews/UpdateFoundView.swift:211-218` | 8 | 305 | 0 | LOW | `#Preview("Update Found") {` |
| `#Preview (EditPanelView)` | `Toplet/components/Settings/EditPanelView.swift:48-50` | 3 | 33 | 0 | LOW | `#Preview {` |

### 3.5 Internal members with zero references (NOT counted in totals; NEEDS-CHECK)

Zero code references by name, but each is public-ish API of a live type, a `@Published` that may be reflected by SwiftUI, or a holder with side effects:

- Eager-init holders, **not dead**: `DynamicIslandApp.swift` stored properties `bluetoothAudioManager`, `lockScreenPanelManager`, `mediaControlsStateCoordinator`, `systemTimerBridge`, `downloadManager` (~lines 112-121). Their value is never read, but declaring them forces `*.shared` to initialise at launch. Removing them changes startup order (and is the lever for lazy start in PERFORMANCE-AUDIT).
- `DynamicIslandApp.swift:31` `openWindow` (@Environment, unused), `:109` `whatsNewWindow`; `DynamicIslandViewCoordinator.swift:127` `showWhatsNew` and `:153` `hudReplacement` (`@AppStorage` strings, never read), `:164` `optionKeyPressed` (@Published, never read or written).
- `Shortcuts/ShortcutConstants.swift:30-31` `decreaseBacklight`, `increaseBacklight` (KeyboardShortcuts names; a saved binding may still exist in UserDefaults).
- `audio/AudioTap.swift:430` `isCapturing`; `components/Calendar/DynamicIslandCalendar.swift:173` `showsText`; `components/Live activities/DynamicIslandBattery.swift:33` `animationStyle` (allocates a `DynamicIslandAnimations()` per instance); `components/Live activities/SystemEventIndicatorModifier.swift:38` `showSlider` (constant false); `managers/LockScreenManager.swift:32` `lockExpand`; `sizing/matters.swift:27-28` `downloadSneakSize`, `batterySneakSize`.
- `managers/CameraMonitor.swift:370` `currentCameraStatus`, `MicrophoneMonitor.swift:317` `currentMicStatus`, `ScreenRecordingManager.swift:517` `currentRecordingStatus`, `ClipboardManager.swift:234` `pinnedHistory`, `MusicManager.swift:606` `isSpotifyActive`, `:616` `activeSourceSupportsFavoriting`, `:720` `isTransitioning`, `PrivacyIndicatorManager.swift:36` `showsRecordingPulsator`, `:272` `screenRecording`, `SystemHUDManager.swift:217` `isOperationInProgress`, `TimerManager.swift:84,88,105` `currentColor`, `formattedTimeRemaining`, `timerNSColor`, `SpotifyAuthManager.swift:48` `hasConfiguredCookie`, `YouTubeMusicAuthentication.swift:35` `currentToken`.
- `models/EventModel.swift:80,81,99` `isEvent`, `isBirthday`, `isMeeting`; `extensions/BundleInfos.swift:29,32`; `extensions/DataTypes+Extensions.swift:28-29` `yesterday`, `tomorrow`; `components/Shelf/ViewModels/ShelfSelectionModel.swift:42,44`; `ShelfItemViewModel.swift:37-38` `isRenaming`, `draftTitle`; `components/Shelf/DropItem.swift:62`; `services/Extensions/ExtensionRPCMessages.swift:153` `objectValue`; `StatsManager.swift` computed percentages (`:62,67,72,275,324,1371-1389`).
- Unused `@Default(...) var x` wrappers (13 of 581): `SettingsView.swift:1124,1714,2847,8953`, `TabSelectionView.swift:50,54`, `InlineHUD.swift:105`, `ColorPickerPanel.swift:549`, `TimerPopover.swift:25`, and `ContentView.swift:96,102,103,104` (the latter sit under the comment "Battery settings reactivity" and may be deliberate invalidation triggers; keep unless ContentView is refactored).

## 4. `Defaults` keys (373 declared in `models/Constants.swift`)

Method: every `.keyName` token (dot-prefixed, so `Defaults[.k]`, `@Default(.k)`, `Defaults.Toggle(key: .k)`, `Defaults.publisher(.k)`) and every `"keyName"` string literal across Swift sources, excluding the declaration line. 373 keys parsed.

| Class | Keys | Evidence |
|---|---|---|
| **A. Zero references anywhere** (no read, write, observe, Settings control, string use) | `enableSafariDownloads` (Constants.swift:1200), `alwaysHideInFullscreen` (:1235), `enableWobbleAnimation` (:1240), `autoStartStatsMonitoring` (:1290) | `.name` count 0, `"name"` count 0. No Settings control exists, so none is a decorative switch. Remove the declaration line; any stored value in the user's plist is harmless. Risk NONE. |
| **B. Referenced only by dead code** | `tileShowLabels` (:1035) | only in dead `SystemItemButton` (`DynamicIslandSystemTiles.swift:33`). Risk NONE after set B. |
| **C. Decorative switches** (a Settings control writes it, nothing reads it) | `expandedDragDetection` (:1227): `SettingsView.swift:4490` `Defaults.Toggle(key: .expandedDragDetection)` ("Expanded drag detection area"), wrapper at :4417. `colorHistorySize` (:1355): `SettingsView.swift:8877` Picker bound to `$colorHistorySize`; `ColorPickerManager.swift:161` hard-codes 50. | OBSERVED: the only references are the Settings wrapper/control. Fix by wiring or removing the control; removing the key alone leaves a dead control. Risk LOW. |
| **D. Unused wrapper only** (no control, no consumer) | `showEmojis` (:1020; SettingsView:1124), `selectedDownloadIconStyle` (:1203; :1714), `systemHUDSensitivity` (:1404; :2847), `hasSeenOSDAlphaWarning` (:1452; :8953) | `@Default` var never used in its file. Delete wrapper and key. Risk LOW. |
| **E. Never written, display only** | `releaseName` (:991; shown by `SettingsView.swift:4137`), `customVisualizers` (:1048; read at SettingsView:5151-5152; `CustomVisualizer` type at Constants.swift:39 only serves it) | constants in practice; NEEDS-CHECK. |
| **F. Legacy / migration only** (keep while migrations run) | `musicAuxLeftControl`, `musicAuxRightControl`, `enableGradient`, `capsLockIndicatorUseGreenColor`, `enableBetterDisplayIntegration`, `enableLunarIntegration`, `didMigrateMusicAuxControls`, `didMigrateMusicControlSlots`, `didMigrateThirdPartyDDCIntegration`, `didMigrateCapsLockTintMode`, `didMigrateClipboardShortcutToV` | referenced only inside `Defaults.Keys.migrate*` in Constants.swift:1540-1642. NEEDS-CHECK: dropping them breaks upgrades from old versions. |

No key is write-only (0 keys whose every reference is an assignment). `Defaults` never de-duplicates writes (vendored `UserDefaults.swift:12-19` always calls `set`), so `syncLegacyThirdPartyDDCKeys()` (Constants.swift:1630-1635), which rewrites two legacy keys on every launch and every DDC key change, wakes any observer of those keys each time.

## 5. Dead branches and commented-out code

| Item | Location | Evidence | Removal |
|---|---|---|---|
| `if false { Text("PRO") ... }` | `components/Onboarding/WelcomeView.swift:51-65` (15 lines, 961 bytes, counted in section 0) | literal `false`; `grep -rn "if false"` = 2 hits (this and ProOnboarding.swift:45, which is in set A) | delete lines 51-65 |
| `shouldHideDuringDrag` always false (`... && false`) | `components/Shelf/Views/ShelfItemView.swift:54`, used by `if !shouldHideDuringDrag` at :63 | constant-false operand makes the condition always true | delete :54, unwrap the `if` at :63 (re-indent) |
| Commented-out duplicate property block | `DynamicIslandApp.swift` ~137-143 (7 lines) | `//    let calendarManager = ...` | delete |
| Commented-out `#if DEBUG ... .keyboardShortcut` snippet | `ContentView.swift` ~855-861 (6 lines) | comment only | delete |
| `#if false`, `#if 0`, `while false`, `guard true`, `&& false`/`|| true` elsewhere | none | grep over all Swift | n/a |
| Commented-out blocks longer than 15 lines | **none**. Four comment runs of 16-22 lines exist (`LockScreenMusicPanel.swift:192-213`, `NowPlayingController.swift:351-367`, `TidalController.swift:173-189`, `BluetoothAudioManager.swift:136-151`) but all are explanatory prose, not code | script (keyword heuristic) + manual read | keep |

## 6. Resources

| Resource | Size | Evidence | Verdict |
|---|---:|---|---|
| `metal/visualizer.metal` | 18 lines / 414 B | no `import Metal*`, `MTL*`, `ShaderLibrary`, `makeDefaultLibrary`; names `vertexShader`/`fragmentShader` appear only in the file | **dead, NONE.** Also removes the Metal compile step (needs full Xcode). |
| `Assets.xcassets/LinkedIn.imageset` | 23,580 B | `"LinkedIn"` / `.linkedIn` 0 uses; only mention is a URL in dead `ProOnboarding.swift:61` | dead, LOW |
| `Assets.xcassets/chrome.imageset` (3 identical PNGs) | 17,831 B | `"chrome"` / `.chrome` 0 uses | dead, LOW |
| `Assets.xcassets/defaultmusic.imageset` | 271 B (no image file; Contents.json only) | 0 uses; `MusicManager.swift:105` uses an SF Symbol | dead, LOW |
| `Assets.xcassets/logo.imageset` | 1,566,789 B | users: `ProOnboarding.swift:34`, `StatusBarMenu.swift:49`, both set A | dead after set A, LOW |
| `logo2.imageset` (1,929,367 B) | | used by `WelcomeView.swift:39`; **byte-identical** to `AppIcon.appiconset/Atoll_1024.png` and `.github/assets/atoll-logo.png` (md5) | alive; 1.9 MB duplicate could be replaced by the app icon, NEEDS-CHECK |
| `bolt`, `plug` imagesets | 8 KB each | referenced via `Image(iconStatus)` where `iconStatus` returns `"bolt"`/`"plug"` (`DynamicIslandBattery.swift:38-47,171`) | alive (dynamic name) |
| `AmazonMusicLogo`, `CiderLogo`, `TidalLogo`, `YouTubeMusicLogo` | | returned by `SettingsView.swift:3104-3107` | alive |
| `Github`, `glassdesktop`, `desktop`, `sparkle`, `spotlight`, `ebullioscopic`, `logo2`, `LocalSend` | | `Image(.github)` at `DynamicIslandExtrasMenu.swift:59` (set B file; `SettingsView.swift:4192` also uses `Image("Github")`), others used by live views | alive |
| `AppIconAlpha/Beta/Dev/Nightly.appiconset` (~1.7 MB each) | ~7.0 MB | no Swift reference; `AppIconDev` is `ASSETCATALOG_COMPILER_APPICON_NAME` for Debug (`project.pbxproj:780`), the others are chosen by `.github/workflows/release.yml:271-273` | alive via build config / CI; keep |
| Orphan files inside the catalog | 0 | every file listed in a `Contents.json` | none |
| Audio: `audio-feedback.m4a`, `dynamic.m4a`, `lowbattery.mp3`, `timer.mp3` | | `SystemChangesObserver.swift:457`, `TimerManager.swift:503-504`, `DynamicIslandApp.swift` `audioPlayer.play(fileName: "dynamic"...)`, `BatteryStatusViewModel.swift:290` | alive |
| Audio: `lock.mp3`, `unlock.mp3` | | `LockScreenManager.swift:497` via `type.resourceName` | alive (dynamic) |
| `BluetoothHUDAnimations/*.mov` (8) | 3.3 MB | name = `String(describing: BluetoothAudioDeviceType case)` (`BluetoothAudioManager.swift:2799-2800,2836`); all 8 cases exist | alive |
| `LottieAnimations/Dog waiting, Moody Dog, Orange Cat Peeping, Reindeer` | | `IdleAnimationManager.swift:107` | alive |
| `LottieAnimations/FingerprintScan.json` | 28,146 B | `LockIconAnimationView.swift:119` | alive |
| `LottieAnimations/Lock.json` | 4,090 B | only `LottieAnimation.named("Lock")` at `LockIconAnimationView.swift:170`, inside dead `LockIconLottieView` (:166-193) | dead after LockIconLottieView; also delete pbxproj lines 23, 92, 271, 474 |
| `managers/LLMUsage/pricing.json` | 25,201 B | `ModelPricingManager.swift:109,119` | alive |
| Root `Localizable.xcstrings` | 2,647,006 B, 796 keys | `grep -c Localizable project.pbxproj` = 0; target catalog `Toplet/Localizable.xcstrings` has 1,601 keys; 70 keys exist only in the root copy (older text) | stale duplicate, LOW (confirm no script reads it: `scripts/`, `.github/` not found to) |
| `Toplet/Localizable.xcstrings` stale entries | 163 flagged `extractionState: stale` by Xcode | 89 of them still occur as literal text somewhere in Swift (e.g. "20", "Accent"); **74 occur nowhere** (e.g. "Activate your license", "Custom Timer Duration", "Download icon style", "Built-in System Monitoring") ~112,488 B | NEEDS-CHECK: Xcode's own stale marker plus no literal match; some contain quotes that may be escaped in source, so re-run Xcode "Clean up strings" rather than hand-delete |
| 20 non-stale catalog keys with no literal match | | multi-line concatenations / escaped quotes (e.g. "Pin items to add them to favorites", "Lock screen glass mode") | NEEDS-CHECK, do not delete |

## 7. SwiftPM packages

| Package | In `project.pbxproj` | Product linked to a target? | `import` count | Verdict |
|---|---|---|---:|---|
| **Pow** (EmergeTools) | `XCRemoteSwiftPackageReference` at lines 431 (list) and 1024-1030 | **No** (`packageProductDependencies` of target `DynamicIsland`, lines 380-391, lists LaunchAtLogin, Sparkle, KeyboardShortcuts, Collections, Defaults, SwiftUIIntrospect, LottieUI, MacroVisionKit, SkyLightWindow, AtollExtensionKit, SwiftTerm) | 0 (`import Pow` absent; no Pow effect calls found) | **unused** |
| **open-meteo** | reference at lines 437 and 992-998 | **No** | 0; weather uses `URLSession` against `https://api.open-meteo.com` (`LockScreenWeatherManager.swift:712`) and local `OpenMeteo*` Swift types | **unused** (the repo is a full server project; it slows resolution) |
Removal of Pow and open-meteo is **safe for the build** (OBSERVED: neither is in any target's dependency list or any `Frameworks` phase): delete the two `XCRemoteSwiftPackageReference` blocks and their two lines in `PBXProject.packageReferences`, then remove the `pow` and `open-meteo` pins from `project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (or let Xcode re-resolve). `swift-argument-parser` stays (needed by SwiftTerm, INFERRED). All other 11 declared packages are imported at least once (Lottie via LottieUI; OrderedCollections via Collections).

## 8. Duplicate code and files

| Duplicate | Evidence | Action |
|---|---|---|
| 6 header-only Swift files, byte-identical (727 B each): `LockScreenDynamicIslandReplica.swift`, `DetailedTimelineGraph.swift`, `DualTimelineGraph.swift`, `AlbumArtFlipModifier.swift`, `ColorPickerManager_Fixed.swift`, `Environment+LockScreenReplica.swift` | `md5` identical; zero code lines. `albumArtFlip` modifier really lives in `MusicManager.swift:2309-2339` | delete (set A) |
| `Frameworks/MediaRemoteAdapter.framework` vs `mediaremote-adapter/MediaRemoteAdapter.framework` | all files md5-identical, 460 KB each; project references the `Frameworks/` copy (`project.pbxproj:29,125,249,472`) | NEEDS-CHECK: keep `mediaremote-adapter/mediaremote-adapter.pl` (bundled), delete the second framework copy only if no script reads it |
| `AudioSpectrum` (`components/Music/MusicVisualizer.swift:28`) vs `RealTimeAudioSpectrum` (`audio/RealTimeAudioSpectrum.swift:29`) | 18 overlapping 14-line windows; same `setupBars`/`startAnimating` | merge behind one class with an injected update closure (refactor, not deletion) |
| `MinimalisticMusicPlayerView.swift` vs `NotchHomeView.swift` | 20 overlapping windows (slider, controls) | refactor |
| `LockScreenReminderWidgetPanelManager` / `LockScreenWeatherPanelManager` / `LockScreenTimerWidgetManager` / `ExtensionLockScreenWidgetPresentationController` / `LockScreenLiveActivityWindowManager` | 3-10 overlapping windows each (show/hide animation) | refactor |
| `BetterDisplayManager` vs `LunarManager` | 6 overlapping windows | refactor |
| function-local `struct TextBlockData` copy-pasted | `ShelfItem.swift:156` and `ShelfItemViewModel.swift:99` | hoist to one type |
| `SettingsView.swift` internal repetition | 66 overlapping windows within the file | refactor |
| Same-bytes assets | `Github.imageset` 3 identical SVGs; `chrome` 3 identical PNGs; `logo2` = `AppIcon` 1024 = `.github/assets/atoll-logo.png` (1,929,367 B x3); `AppIcon.appiconset` has 3 identical pairs (`Atoll_1024 (2)`, `(1)`, `(5)` and their ` 1` copies) | collapse appearances in `Contents.json`, NEEDS-CHECK |

## 9. Looks dead but is alive (do not remove)

`DynamicNotchApp` (`@main`); `AtollUpdaterDelegate` (`DynamicIslandApp.swift:36`); `CheckForUpdatesView` (`MenuBarExtra`, ~:60); eager-init holders listed in 3.5; `lock.mp3`/`unlock.mp3`; `bolt`/`plug` imagesets; `AppIcon*` sets; `FingerprintScan.json`; `BluetoothLEBatteryReader` delegate methods; `AudioBridge` (used by `AudioTap.swift:112`); `IOReport*` wrappers; `SMC` struct fields; `ExtensionXPCService` protocol methods; `MediaChecker` (one-shot perl spawn at `MusicManager.swift:749`).

## 10. Removal procedure

1. Delete set A files, then set B files (`rm`), in one commit; build; fix nothing (the closure check says nothing else references them).
2. Per file in sections 3.1-3.4, delete the listed line ranges **bottom to top** (`sed -i '' 'START,ENDd' FILE`), re-anchoring on the signature column first; then build. Tier-2 items (marked in notes) must go in the same pass as their only callers.
3. Delete the `if false` block (WelcomeView) and the `shouldHideDuringDrag` condition.
4. Delete the 4 zero-ref keys, `tileShowLabels`, and decide on class C/D keys.
5. Delete `visualizer.metal`, `LinkedIn`/`chrome`/`defaultmusic`/`logo` imagesets, `Lock.json` (+ pbxproj lines 23, 92, 271, 474), root `Localizable.xcstrings`.
6. Edit `project.pbxproj` and `Package.resolved` for Pow and open-meteo.
7. Verification (not run during this audit): clean build of scheme `DynamicIsland`, run the 22 XCTest files in `TopletTests/`, launch and open each notch tab.

Totals if everything in sections 2-3 and 5 is applied: **42 files, 5,850 lines, 211,747 bytes of Swift**, plus ~4.3 MB of non-Swift resources (sections 0 and 6).

## 11. Status after application (2026-10-21, commit `d4da1fe`)

Applied by `docs/OPTIMISATION-RESULTS.md` section 2; release build clean, test copy launched.

| Report section | Status |
|---|---|
| 2.A set A (28 files) | **removed** |
| 2.B set B (14 files) | **removed**; `UpdateFoundView.swift` (3.1) also removed whole because only an unused private `String` extension was left |
| 3.1 types, 3.2 functions, 3.3 properties, 3.4 previews | **removed** except `applicationShouldTerminate` (a live `NSApplicationDelegate` callback that now logs the quit sender; false positive) |
| 3.3 `AppleNotesSyncManager.syncFolderName` | **kept**: the report's token proof ignores string interpolation, and the property is used in AppleScript text (`"\(Self.syncFolderName)"`); the compiler caught it |
| Cascade found afterwards | removed: `DownloadIconStyle`, `QuickLookDataSource`, BetterDisplay `request/responseNotificationName`, `AppleNotesSyncManager.syncTask` |
| 3.5 internal members | NEEDS-CHECK, untouched (except the 4 `SettingsView` `@Default` wrappers, audit item P08) |
| 4 class A keys (4), class B (`tileShowLabels`), class D (4) | **removed**; classes C, E, F untouched |
| 5 `if false` (WelcomeView), `shouldHideDuringDrag`, two commented blocks | **removed** |
| 6 resources | **removed**: `visualizer.metal`, imagesets `LinkedIn`, `chrome`, `defaultmusic`, `logo`, root `Localizable.xcstrings`. **Kept**: `Lock.json` (explicit `project.pbxproj` references), `logo2`, AppIcon sets, stale catalog entries (NEEDS-CHECK) |
| 7 SwiftPM `Pow`, `open-meteo` | **not applied** (needs `project.pbxproj` / `Package.resolved` edit and Xcode to validate) |
| 8 duplicates | not applied (refactors / NEEDS-CHECK) |
