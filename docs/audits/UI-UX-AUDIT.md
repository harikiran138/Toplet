# Toplet UI/UX and Accessibility Audit

Date: 2026-10-21. Scope: the `Toplet/` app target (SwiftUI + AppKit, macOS 14.6+). I only read the code. I did not build, run, profile or take screenshots, so every finding comes from source and cites `path:line`. A finding marked **(verify)** follows from the code, but its effect at runtime still needs to be checked by hand. Paths are relative to the repository root.

Other sessions were editing the same worktree during this audit, between about 16:30 and 16:51 IST. I re-checked the cited lines after writing and fixed the ones that had moved. Two findings were already fixed by those edits and are marked **(fixed during audit)**: the `⌘⇧T` default and `SUFeedURL`. Check line numbers against the current tree before acting on them.

How to read the tables: **Sev** is the severity I judged (H = blocks or misleads users, M = clear friction, L = polish). Effort is S (under half a day), M (1 to 3 days) or L (a week or more).

---

## 0. Executive summary

1. **The notch is not forced dark.** I found no `NSAppearance`/`preferredColorScheme` for the notch window. Only three tabs force `.dark` locally (`DynamicIslandWindow` has none; `NotchClockView.swift:73`, `NotchLLMUsageView.swift:51`, `NotchGamesView.swift:50`). Tabs that use `.primary`/`.secondary` on the black notch body (Stats, Color Picker, Clipboard, Notes, Timer, Home) will render dark text on black in Light Mode **(verify)**.
2. **Icon-only controls are mostly unlabeled.** `TabButton` takes a `label` and never uses it (`DynamicIslandHeader`'s tab row: `components/Tabs/TabButton.swift:26,31-37`). All seven header buttons have no label or tooltip (`components/Notch/DynamicIslandHeader.swift:120,136,183,215,242,270,305`). A heuristic scan found 59 more unlabeled icon-only `Button`s (section 3.1).
3. **Reduce Motion is honoured in only 4 files.** Those are Clock, Games and two Agents files. The notch's own open/close/hover springs, the tab-switch slide and the header blur all ignore it (`ContentView.swift:319-331,690-706,2334`; `DynamicIslandHeader.swift:97-98`). That leaves 455 of the 483 animation call sites app-wide in files that never read the setting.
4. **The default global shortcuts take over common system and app shortcuts.** `⌘⇧V` (paste and match style), `⌘⇧A`, `⌘⇧P`, `⌘⇧H`, `⌘⇧I` and `⌘⇧K` are registered globally and enabled by default (`Shortcuts/ShortcutConstants.swift:27-38`, `models/Constants.swift:1412`). The `⌘⇧T` demo-timer default was removed during the audit (`ShortcutConstants.swift:35-36`).
5. **The design language is fragmented.** In `components/Notch` I counted 14 distinct corner radii, 28 font sizes, 34 opacity literals and 40 animation curves. `NotchSurface` is adopted by only 5 of 12 tabs.
6. **The update UI contradicts the update state.** Updates are disabled (`models/TopletProject.swift:33`), yet the auto-update toggles and a 5-channel picker stay live (`SoftwareUpdater.swift:69-76`, `SettingsView.swift:4233-4268`). `Info.plist` no longer has any `SUFeedURL`; the upstream Atoll entry was removed during the audit. These controls therefore have nothing to act on.
7. **Destructive actions are confirmed inconsistently.** The notch asks before clearing clipboard history (`NotchClipboardView.swift:97`). Settings, the popover and the panel clear the same data at once (`SettingsView.swift:8615,8621`, `ClipboardPopover.swift:105`, `ClipboardPanel.swift:325`).
8. **Onboarding opens with a jargon dialog.** "Focus detection mode: Use DevTools / Use without DevTools" appears before the Welcome screen (`components/Onboarding/OnboardingView.swift:131-146`). Onboarding has no Accessibility-permission step, although HUD replacement needs it (`SettingsView.swift:2888`).

---

## 1. Interface inventory

| # | Surface | Entry / main file | Notes |
|---|---|---|---|
| 1 | Closed notch (idle) | `ContentView.swift:1055-1182` | Hello animation on first launch (`ContentView.swift:1061-1067`), then live activities, or the shelf indicator when the shelf has items (`:1167`). Expands +8 pt on hover (`:1115-1116`, `:1400`). |
| 2 | Closed-notch live activities | `ContentView.swift:1083-1182` | Timer, reminder, recording, focus, Caps Lock, extension payload, shelf, music, battery, agents (`AgentsClosedLiveActivity`, `:1139`). Pinned LLM usage strip: `components/Notch/PinnedUsageView.swift:37-68`. |
| 3 | Sneak peeks / inline HUD | `ContentView.swift:1122-1250`; `components/Live activities/InlineHUD.swift`; `SystemEventIndicatorModifier.swift` | 16 sneak types (`DynamicIslandViewCoordinator.swift:24-39`). Style is standard or inline (`models/Constants.swift:1061`). |
| 4 | System HUD / OSD replacements | `components/OSD/CustomOSDView.swift`, `VerticalHUDView.swift`, `CircularHUDView.swift` | Configured under Settings › "Controls" (`SettingsView.swift:100`). |
| 5 | Connectivity HUD | `components/Network/NetworkConnectivityHUD.swift` | Centred on the camera housing (`ContentView.swift:1284-1285`). |
| 6 | Expanded notch: header | `components/Notch/DynamicIslandHeader.swift:86-330` | Tab row on the left, utility buttons on the right (mirror, clipboard, colour picker, timer, app volume, caffeinate, settings, recording/focus indicators). |
| 7 | Expanded tabs | `ContentView.swift:1291-1320`; tab list `components/Tabs/TabSelectionView.swift:68-128` | Home, Shelf, Timer, Stats, Usage (LLM), Agents, Notes/Clipboard, Terminal, Clock, Games, extension tabs. `NotchViews.colorPicker` is routed (`ContentView.swift:1304`) but nothing assigns it (only `DynamicIslandViewCoordinator.swift:102` lists it), so `NotchColorPickerView` looks unreachable **(verify)**. |
| 8 | Music, standard | `components/Notch/NotchHomeView.swift:758-841` (slot-configurable controls) | Slots are configured in `components/Settings/MusicSlotConfigurationView.swift`. |
| 9 | Music, minimalistic | `components/Notch/MinimalisticMusicPlayerView.swift` (1,416 lines) | Enabling it hides the tab row (`DynamicIslandHeader.swift:89`) and 9 Settings tabs (`SettingsView.swift:1036-1043`). |
| 10 | Utility popovers / panels | `components/Clipboard/ClipboardPopover.swift`, `ClipboardPanel.swift`; `components/ColorPicker/*`; `components/Timer/TimerPopover.swift`; `components/Audio/PerAppVolumePopover.swift`; `components/Caffeinate/CaffeinatePopover.swift`; `components/ScreenAssistant/*` | Each has its own chrome: 3 material sites in `ChatPanels.swift`, 2 in `ColorPickerPanel.swift`. |
| 11 | Lock screen widgets | `components/LockScreen/*` | Configured in Settings › Lock Screen, split into General/Widgets (`SettingsView.swift:212`, `:5700-5783`). |
| 12 | Widget / slot configuration | `MusicSlotConfigurationView.swift:56-133`; Lock Screen widgets `SettingsView.swift:5649+` | Slots are remapped by drag and drop (`MusicSlotConfigurationView.swift:58,89,165-169`). |
| 13 | Idle / character animation editor | `components/Settings/IdleAnimationsSettingsSection.swift:39-170`; `AnimationEditorView.swift:22-630` | Sheet with a minimum size of 860×620 (`AnimationEditorView.swift:100-102`). |
| 14 | Settings window | `components/Settings/SettingsWindowController.swift:34-38`; `SettingsView.swift:626-720` | 22 tabs in 8 groups (`SettingsView.swift:21-118`). Sidebar search covers about 217 indexed settings. |
| 15 | Onboarding | `components/Onboarding/OnboardingView.swift:27-147` | Welcome, then Camera, Calendar, Music source, Profiles, Finish. Fixed size 400×600 (`:125`). |
| 16 | Permission explanations | `PermissionsRequestView.swift:24-75`; `SettingsPermissionCallout` (`SettingsView.swift:9189-9246`, 7 uses); main-menu Accessibility/Permissions menus (`DynamicIslandApp.swift:1211-1250`); `Info.plist:10-15` | |
| 17 | Menu bar extra | `DynamicIslandApp.swift:57-82` | Settings, Check for Updates, Restart, Quit. Icon `sailboat.fill`. |
| 18 | Update experience | `components/Settings/SoftwareUpdater.swift`; About (`SettingsView.swift:4145-4292`) | See 5.6. |
| 19 | Error states | LLM failure (`NotchLLMUsageView.swift:92-95`), import errors (`AnimationEditorView.swift:103`, `IdleAnimationsSettingsSection.swift:167-170`), API key (`ChatPanels.swift:432`), LocalSend failure (`ContentView.swift:484-485`), crash report (`SettingsView.swift:7090-7094`) | No shared error component. |
| 20 | Empty states | Clipboard `NotchClipboardView.swift:137-150`; Notes `NotchNotesView.swift:652`; Clock `NotchClockView.swift:235`; Colours `NotchColorPickerView.swift:127-131`; Stats `NotchStatsView.swift:323,338`; Shelf `ShelfView.swift:159`; music `MinimalisticMusicPlayerView.swift:58` | Wording and casing vary (section 6). |
| 21 | Multi-display | `SettingsView.swift:1227-1250` (all displays / specific display / auto-switch), `:1462-1479` (external style, hide until hovered); `ContentView.swift:444-475,748-751` | Sneak peeks target a screen (`ContentView.swift:444-447`). |

Reference quality bar: the Agents UI has named tokens (`components/Notch/Agents/AgentsTheme.swift:31-48`), named motion with a reduce-motion gate (`AgentsMotion.swift:34-42,70-80`), a three-path surface (`AgentsSurface.swift:75-160`) and VoiceOver announcements (`NotchAgentsView.swift:172`). Small housekeeping note: the "canonical" copy has already drifted from the shipped one (`AtollAgents/UI/AgentsComponents.swift:268` vs `Toplet/components/Notch/Agents/AgentsComponents.swift:268`).

---

## 2. Visual consistency

### 2.1 Measured spread (grep over `Toplet/components/Notch`)

| Property | All of `components/Notch` | Excluding `Agents/` | Most common values (count) |
|---|---|---|---|
| `cornerRadius: <literal>` | 14 distinct / 61 uses | 12 / 57 | 12 (18), 8 (7), 6 (7), 14 (7), 10 (6), 16 (4) |
| `.system(size:)` | 28 distinct / 254 uses | 20 / 133 | 11 (46), 10 (45), 12 (34), 10.5 (20), 16 (12), 14 (12), 13 (10), 11.5 (9) |
| Opacity literals `opacity(0.x)` | 34 distinct / 177 uses | 29 / 136 | 0.3 (19), 0.1 (15), 0.5 (13), 0.7 (12), 0.2 (10), 0.85 (9), 0.6 (9) |
| Animation curves | 40 distinct / 83 uses | 23 / 61 | `.smooth` (11), `.easeInOut(0.2)` (10), `.easeInOut(0.4)` (9), `.smooth(0.25)` (6), `.bouncy` (4), `spring(0.35, 0.8)` (3) |
| Durations | 18 distinct | | 0.2 (14), 0.4 (9), 0.25 (6), 0.3 (3), 0.18 (3) |
| Spring `response:` values | 10 distinct | | 0.35 (4), 0.45 (3), 0.38 (3) |
| `spacing:` | | | 8 (59), 6 (50), 4 (34), 12 (21), 10 (16) |
| `.padding(n)` | | | 8 (34), 12 (30), 4 (23), 6 (18) |
| Semantic text styles | 57 uses vs 254 `.system(size:)` | | `.caption` (31), `.caption2` (13), `.headline` (9) |

App-wide (`components/` + `ContentView.swift`): 21 distinct radii over 239 uses, 34 distinct font sizes, 623 `.system(size:)` calls in the target, and 60 distinct `Color(red:green:blue:)` literals. These counts exclude ternaries such as `opacity(isHovered ? 0.12 : 0.08)`, so the real spread is larger.

Spacing and corners were built with care: `DynamicIslandHeader.swift:114-116` reasons about the gap between controls, and `AgentsTheme.swift:43-48` applies the concentric-radius rule. Most of the spread comes from every tab choosing its own values.

### 2.2 Surfaces that bypass `NotchSurface`

`NotchSurface` (`components/Notch/NotchSurface.swift:25-69`) is used by Clock (11), Games (7), Timer (2: `NotchTimerView.swift:113,339`), Notes (1: `NotchNotesView.swift:605`) and LLM Usage (1). Home, Shelf, Stats, Clipboard, Color Picker and Terminal draw their own fills. Examples:

| File:line | Ad-hoc surface |
|---|---|
| `NotchClipboardView.swift:126,208,260` | `Color.white.opacity(0.1)`, hover `0.12/0.08`, `0.06` |
| `NotchNotesView.swift:57,515,535,548,562,574,771,788,818,828,969,994` | 12 hand-rolled `white.opacity(0.05…0.2)` backgrounds |
| `NotchStatsView.swift:496` | `white.opacity(0.08)` card fill |
| `NotchTimerView.swift:268,501,670` | `0.12`, `0.16`, `0.08` fills next to `notchSurface` in the same file |
| `NotchHomeView.swift:278` | `Color.black.opacity(0.3)` |
| `MinimalisticMusicPlayerView.swift:660-662` | popover `RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.92))` |
| `NotchGamesView.swift:295` | `Color.black.opacity(0.6)` in a 16 pt rectangle |
| `NotchColorPickerView.swift:278` | `Color.black.opacity(0.9)` |
| `TabSelectionView.swift:148` | Selected tab pill uses `Color(nsColor: .secondarySystemFill).opacity(0.25)`, which depends on appearance (see section 4) |
| `DynamicIslandHeader.swift:122-127` (repeated 7×) | `Capsule().fill(.black)` button chrome |

These fills skip the Reduce Transparency and Increase Contrast branches that `NotchSurface.swift:36-52` provides.

There are also three default corner radii for a "card": `NotchSurface` uses 12 (`NotchSurface.swift:72`), Agents uses 16 (`AgentsTheme.swift:44`), and Timer uses 14 (`NotchTimerView.swift:113`).

Settings also uses four badge styles: a blue "BETA" capsule (`SettingsView.swift:791,802`), a grey "Beta" `customBadge` (5 uses), an "ALPHA" badge (`SettingsView.swift:7340`) and a "Coming soon" badge (`SettingsView.swift:5033`).

### 2.3 Proposed design tokens

The scale matches the current majority values, so tabs can adopt it one at a time without visible change. File suggestion: `Toplet/components/Notch/TopletTokens.swift`. Map `AgentsTheme`'s `static var`s onto it at start-up, as its header comment invites (`AgentsTheme.swift:20-22`).

```swift
import SwiftUI
import AppKit

/// One source of truth for the notch, its popovers and Settings. Values are the most common
/// literals measured in components/Notch (see docs/audits/UI-UX-AUDIT.md §2.1).
enum TopletSpace {                       // spacing: 8 (59×), 6 (50×), 4 (34×), 12 (21×)
    static let xxs: CGFloat = 2
    static let xs:  CGFloat = 4
    static let s:   CGFloat = 6
    static let m:   CGFloat = 8          // default stack spacing, Agents cardPadding
    static let l:   CGFloat = 12         // card padding, tab content inset
    static let xl:  CGFloat = 16
    static let xxl: CGFloat = 20
    static let minTarget: CGFloat = 28   // AgentsTheme.minTarget; header uses 30
}

enum TopletRadius {                      // 12 (18×), 8 (7×), 6 (7×), 14 (7×), 16 (4×)
    static let chip:    CGFloat = 6      // badges, small swatches
    static let control: CGFloat = 8      // buttons/rows inside a card (= card - padding)
    static let card:    CGFloat = 12     // NotchSurface default
    static let panel:   CGFloat = 16     // popovers, Agents cards, large tiles
    static func inner(_ outer: CGFloat, padding: CGFloat) -> CGFloat { max(0, outer - padding) }
}

/// Text styles, not point sizes, so text can follow an in-app text-size preference
/// (macOS sizes: caption2/caption/footnote 10, subheadline 11, callout 12, body/headline 13,
/// title3 15, title2 17). Replaces .system(size: 10/10.5/11/11.5/12/13/15/16/17).
enum TopletType {
    static let micro    = Font.caption2                       // was 9–10 pt
    static let caption  = Font.subheadline                    // was 10.5–11.5 pt
    static let label    = Font.callout.weight(.medium)        // was 12 pt
    static let body     = Font.body                           // was 13 pt
    static let title    = Font.headline                       // was 13 pt semibold
    static let display  = Font.title3.weight(.semibold)       // was 15–16 pt
    static let numeric  = Font.body.monospacedDigit()
    static let glyph    = Font.system(.body, weight: .medium) // header glyphs, scale with text
}

/// Deep-ocean identity for the ship (menu bar uses sailboat.fill, DynamicIslandApp.swift:57).
/// Contrast measured against #000 (the notch body) and #FFF (Settings, light mode).
enum TopletOcean {
    static let abyss   = Color(hex: 0x03111C)   // opaque Reduce-Transparency fill on the notch
    static let trench  = Color(hex: 0x072235)   // card fill when opaque
    static let deep    = Color(hex: 0x0B3550)   // selected-row fill
    static let tide    = Color(hex: 0x1F6FA8)   // 5.4:1 on white -> accent in light Settings
    static let current = Color(hex: 0x3A9BDC)   // 6.9:1 on black -> accent on the notch
    static let lagoon  = Color(hex: 0x38B2AC)   // 8.1:1 on black -> success/"live"
    static let seafoam = Color(hex: 0x7FD8C8)   // 12.6:1 on black -> highlights, progress
    static let foam    = Color(hex: 0xE8F6F5)   // primary text tint on the notch
    static let coral   = Color(hex: 0xFF7F66)   // 8.5:1 on black -> attention (replaces raw .orange)

    /// Accent that adapts: `current` on dark, `tide` on light. The notch is always dark.
    static let accent = Color(light: tide, dark: current)
}

enum TopletColor {                        // semantic roles; the notch is forced to .dark
    static let textPrimary   = Color.white.opacity(0.9)   // 0.85 (9×) / 0.9 (5×) today
    static let textSecondary = Color.white.opacity(0.6)   // 7.4:1 on black
    static let textTertiary  = Color.white.opacity(0.5)   // floor: 5.3:1 (0.35 = 3.0:1 fails AA)
    static let fillSubtle    = Color.white.opacity(0.06)  // AgentsTheme.cardFill
    static let fill          = Color.white.opacity(0.10)
    static let fillHover     = Color.white.opacity(0.12)  // Clipboard/Notes hover today
    static let fillStrong    = Color.white.opacity(0.16)
    static let hairline      = Color.white.opacity(0.12)
    static let success = TopletOcean.lagoon, attention = TopletOcean.coral, danger = Color.red
}

enum TopletMotion {                       // .smooth (11×), easeInOut 0.2 (10×), spring 0.35/0.8
    static let quick      = Animation.smooth(duration: 0.2)   // hover, press, symbol swaps
    static let standard   = Animation.smooth(duration: 0.3)   // tab content, list changes
    static let emphasized = Animation.spring(response: 0.35, dampingFraction: 0.8)
    static let notchOpen  = Animation.spring(response: 0.42, dampingFraction: 1.0) // ContentView.swift:691
    static let notchClose = Animation.spring(response: 0.45, dampingFraction: 1.0) // ContentView.swift:701
    static let hover      = Animation.bouncy.speed(1.2)                            // ContentView.swift:690
    static let reduced    = Animation.easeInOut(duration: 0.15)                    // crossfade only

    static func resolve(_ a: Animation, reduceMotion: Bool) -> Animation { reduceMotion ? reduced : a }
    static func transition(_ t: AnyTransition, reduceMotion: Bool) -> AnyTransition { reduceMotion ? .opacity : t }
}

/// Component states, shared by every tappable thing in the notch.
enum TopletState {
    static let pressedScale: CGFloat = 0.96          // Games/Agents press feedback
    static let disabledOpacity: Double = 0.5         // SettingsView.swift:3642 already uses 0.5
    static let focusRingWidth: CGFloat = 2           // TopletOcean.accent
    static let selectedTint = TopletOcean.accent     // pass to .notchSurface(tint:)
}

struct TopletAnimation<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation; let value: V
    func body(content: Content) -> some View {
        content.animation(TopletMotion.resolve(animation, reduceMotion: reduceMotion), value: value)
    }
}
extension View {
    func topletAnimation<V: Equatable>(_ a: Animation, value: V) -> some View { modifier(TopletAnimation(animation: a, value: value)) }
}

extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255) }
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light) })
    }
}
```

Adoption order: (1) force the notch to `.dark` at the root (section 4), (2) replace `Color.white.opacity(…)` card fills with `.notchSurface(cornerRadius: TopletRadius.card)`, (3) replace `.system(size:)` with `TopletType`, starting with the 10/11/12 pt majority, (4) route each `withAnimation` through `TopletMotion` or `topletAnimation`.

---

## 3. Accessibility

### 3.1 Icon-only buttons without an `accessibilityLabel`

Method: a script found each `Button` whose label contains `Image(systemName:)`, contains no `Text`/`Label`/title, and has no `accessibilityLabel` in the label or within the following 30 lines. I removed 3 false positives by hand. SF Symbols get a generic automatic description (for example "xmark.circle.fill"), and `.help` only supplies a hint, so a symbol with a tooltip still lacks a contextual label. 13 of these at least have `.help`.

**Notch header and tabs (highest traffic, no label and no tooltip):**
- `components/Tabs/TabButton.swift:32`: every tab. `label` is accepted at `:26` and never used, and there is no `.isSelected` trait.
- `components/Notch/DynamicIslandHeader.swift:120` (mirror), `:136` (clipboard), `:183` (colour picker), `:215` (timer), `:242` (app volume), `:270` (caffeinate), `:305` (settings).
- Music transport via `HoverButton` (`components/HoverButton.swift:49`, no label parameter): play/pause, previous/next (drawn by `SkipTrackGlyph` with no image, so VoiceOver gets nothing), seek ±10, shuffle, repeat, lyrics, like (`NotchHomeView.swift:763-841`).

**Notch tabs:** `NotchClipboardView.swift:120` (trash), `:217`; `MinimalisticMusicPlayerView.swift:495`, `:510` (info); `NotchNotesView.swift:509,524,542,556,568,595,783,794,823,1011`; `NotchClockView.swift:339`; `NotchColorPickerView.swift:326`; `NotchHomeView.swift:1554` (mute); `NotchTerminalView.swift:140` (restart shell).

**Popovers and panels:** `ClipboardPopover.swift:105,148,243,257,267`; `ClipboardPanel.swift:292,325,638`; `ColorPickerPanel.swift:273,296,489,504,625,686`; `ColorPickerPopover.swift:42`; `PerAppVolumePopover.swift:148`; `RankedProcessPopover.swift:53`; `FileShareView.swift:142`; `DynamicIslandCalendar.swift:615,622`; `LockScreenTimerWidget.swift:306`; `ChatPanels.swift:226,401,413,618,630`; `ScreenAssistantPanel.swift:148,167,201`; `ModelSelectionPanel.swift:151`.

**Settings:** `SettingsView.swift:5075` (+), `:5086` (−), `:8137` (edit), `:8146` (delete); `ExtensionsSettings.swift:245`; `IdleAnimationsSettingsSection.swift:436`; `AnimationEditorView.swift:213,226`; `MediaSourceCapabilities.swift:109`.

Other unlabeled controls: 10 `Picker("", …)`, for example `NotchLLMUsageView.swift:77` and `SettingsView.swift:3901,3990,6283,6373,8555,8568,8769,8900,8913`. Some of these may have a row label beside them. The editor's sliders are created without labels (`AnimationEditorView.swift:602,604`).

### 3.2 Reduce Motion

Only `NotchClockView.swift:42-129`, `NotchGamesView.swift:22-235`, `Agents/NotchAgentsView.swift:47` and `Agents/AgentsClosedIndicator.swift:100` read `accessibilityReduceMotion`. Of the 483 `withAnimation`/`.animation(` sites in the target, 28 are in those files. Notable motion that ignores the setting:

| Motion | File:line |
|---|---|
| Notch hover bounce and open/close springs, blur-replace transition | `ContentView.swift:690-706`, `:2334`, `:2387` |
| Tab switch slide (`.move(edge:)` + opacity) | `ContentView.swift:319-331`, applied `:1325` |
| Header tabs blur 20 pt on close | `DynamicIslandHeader.swift:97-98`, `:369` |
| Expanding-view blur-replace | `ContentView.swift:1148,1151` |
| Repeat-forever pulses and spinners | `components/Live activities/PulsingModifier.swift:29`, `DynamicIslandBattery.swift:869,874`, `components/UI/RecordingIndicator.swift:66`, `NotchNotesView.swift:500`, `SpinningCircleDownloadView.swift:39`, `SettingsView.swift:583` |
| Onboarding cross-fades of 0.6 s | `OnboardingView.swift:50,64,70,…` |

Inside an otherwise compliant tab (Clock, Games), the outer slide in `ContentView.swift:319-331` still runs.

### 3.3 Reduce Transparency and Increase Contrast

- These are handled only in `NotchSurface.swift:30-52` and `AgentsSurface.swift:82-171`. The ad-hoc fills in section 2.2 have no high-contrast hairline and no opaque fallback.
- The OSD backgrounds use whatever material the user picks (`CustomOSDView.swift:159-181`, `VerticalHUDView.swift:262-264`) with no Reduce Transparency branch. System materials usually adapt on their own **(verify for `glassEffect`)**.
- I found no `colorSchemeContrast` checks for text. Low-contrast secondary text on the black notch includes `NotchGamesView.swift:203` (white 0.35, 3.0:1, below AA 4.5:1) and `NotchStatsView.swift:458` (0.45, 4.4:1). Text has 7 `white.opacity(≤0.55)` foreground sites in total.

### 3.4 Dynamic Type / larger text

The target has 623 `.system(size:)` calls: 254 in `components/Notch`, 61 in Settings, 52 in LockScreen, 35 each in Clipboard and ColorPicker. 23 sites use sizes from 6 to 9.5 pt. macOS does not drive Dynamic Type for third-party apps the way iOS does, so the practical fix is text styles (section 2.3) plus an in-app "Text size" preference fed through `\.dynamicTypeSize`. The notch's fixed heights would need to grow with it: tabs are designed for roughly 168 to 228 pt of content (`AgentsTheme.swift:65-79`).

### 3.5 Keyboard navigation and focus

- The notch window can become key (`components/Notch/DynamicIslandWindow.swift:63-69`). The tabs have no `.focusable`, `onKeyPress` or arrow-key tab switching. Only three in-notch keyboard shortcuts exist: `NotchClockView.swift:401`, `NotchGamesView.swift:77`, `NotchNotesView.swift:98`.
- Opening with the keyboard is a dead end. The ⌘⇧I handler opens the notch without making the window key, then **auto-closes it after 3 s** (`DynamicIslandApp.swift:1100-1134`, timer `:1131`). A keyboard or VoiceOver user cannot reach the tabs in that time.
- Plain-style `Button`s in the header (`DynamicIslandHeader.swift:130,160,…`) take keyboard focus only if Full Keyboard Access is on, and they show no custom focus ring.

### 3.6 VoiceOver grouping and announcements

- Outside Agents there are 11 `accessibilityElement(children:)` uses. OSD, live activities, downloads, Clipboard, ColorPicker, Stats, ScreenAssistant and Onboarding have **zero** accessibility modifiers (count per folder: `OSD` 0, `Live activities` 0, `Clipboard` 0, `ColorPicker` 0, `Stats` 0, `Onboarding` 0).
- HUD value changes (volume, brightness, battery) are never announced. The only `AccessibilityNotification.Announcement` is in `Agents/NotchAgentsView.swift:172`.
- Good examples to copy: `NotchGamesView.swift:216,243,261` (per-cell labels), `NotchClockView.swift:387`, `PinnedUsageView.swift:46,68`, `LockScreen/*` (24 modifiers).

### 3.7 State shown by colour alone

| Control | Evidence |
|---|---|
| Selected tab | Grey vs white glyph plus a faint pill (`TabSelectionView.swift:144-155`); no selected trait |
| Shuffle / repeat active | Icon colour switches to the brand accent (`NotchHomeView.swift:804-818`) |
| Notes sync in progress | Icon turns yellow (`NotchNotesView.swift:513`) |
| Copy-link success | Glyph and colour change, nothing announced (`MinimalisticMusicPlayerView.swift:499-501`) |
| Caffeinate | Fill **and** colour change (`DynamicIslandHeader.swift:279-286`): an acceptable pattern |

---

## 4. Light and dark mode

**The notch.** I could not find any code that pins the notch window or its root view to dark: no `NSAppearance`, `preferredColorScheme` or `.environment(\.colorScheme, …)` in `ContentView.swift`, `DynamicIslandWindow.swift` or `DynamicIslandApp.swift`. Clock, LLM Usage and Games each force `.dark` locally (`NotchClockView.swift:73`, `NotchLLMUsageView.swift:51`, `NotchGamesView.swift:50`), and Agents says it does the same (`AgentsTheme.swift:25`). That strongly suggests the default is the system appearance. In Light Mode, these would then render dark text on the black notch **(verify)**:

- `NotchStatsView.swift:321,340` (`.primary` titles in the empty states)
- `NotchColorPickerView.swift:45,80,84,129,247,319` (`.primary`)
- `.secondary` in Home (12), ColorPicker (13), Clipboard (5), Notes (6), Timer (5) and Terminal (2)
- The tab pill uses `Color(nsColor: .secondarySystemFill)` (`TabSelectionView.swift:148`)
- `components/Stats/*DetailView.swift` (`.primary` fills and text, for example `CPUStatsSharedViews.swift:47,328`)

Fix: set `.environment(\.colorScheme, .dark)` once on the notch root in `ContentView`, or set `window.appearance = NSAppearance(named: .darkAqua)` on `DynamicIslandWindow`, and drop the per-tab overrides.

**Settings window** (follows the system; no override in `SettingsWindowController.swift`):

| File:line | Problem in Light Mode |
|---|---|
| `SettingsView.swift:945,998` | Search field and suggestion list hairline `Color.white.opacity(0.08)` is invisible on a light material |
| `SettingsView.swift:1006` | Suggestion hover `Color.white.opacity(0.08)` gives no visible hover |
| `SettingsView.swift:697-704` | macOS 26 window background is `.clear` glass tinted `white 0.1`; legibility depends on the wallpaper **(verify)** |
| `SettingsView.swift:150` | Devices tab tint `rgb(0.10, 0.11, 0.12)`, a near-black tile that blends with the dark-mode sidebar |
| `AnimationEditorView.swift:171,554,627` | White 0.05 to 0.08 strokes and fills are invisible on light |
| `ClipboardPanel.swift:246,256`; `ColorPickerPanel.swift:637` | White gradient, stroke and hover on panels that do not force dark **(verify)** |

Intentional white-on-preview text (lock-screen positioning preview, `SettingsView.swift:6939-6990`; notch preview `IdleAnimationsSettingsSection.swift:398`) is fine.

---

## 5. Interaction quality

### 5.1 Hover to open and close
- Open-on-hover is on by default with a 0.3 s dwell (`models/Constants.swift:992,994`). The dwell can be set to 0 (`SettingsView.swift:1450`), which invites accidental opens.
- Leaving the notch closes it after a hard-coded **100 ms** (`ContentView.swift:2373`). A small overshoot while moving to a header button or the edge of a popover therefore closes the panel. The opt-in "Extend hover area" is off by default (`Constants.swift:995`).
- Each hover entry plays a haptic (`ContentView.swift:2338-2340`), on by default (`Constants.swift:993`) and throttled to 300 ms (`:2503-2508`).
- "Sticky" tabs (Games always; Terminal and Clock in some states) ignore hover-out and need a click outside (`ContentView.swift:2497-2499`). Nothing on screen says so.
- "Hide until hovered" removes the notch entirely on external displays (`ContentView.swift:748-751`), with no hint of where to hover.

### 5.2 Scroll gesture conflicts
- The open/close gesture uses one scroll-event hub for the whole system (`extensions/PanGesture.swift:52-110`) and a `DragGesture(minimumDistance: 0)` on the whole notch (`PanGesture.swift:39-46`).
- Close is suppressed only while `vm.isScrollGestureActive` (`ContentView.swift:2646`). Only Notes (`NotchNotesView.swift:719,1065`), Terminal (`NotchTerminalView.swift:202`), Clipboard (`NotchClipboardView.swift:166`), Home (`NotchHomeView.swift:319`) and the ruler picker (`RulerTimerPicker.swift:268-332`) register suppression.
- Vertical scroll views in LLM Usage (`NotchLLMUsageView.swift:244`), Clock (`NotchClockView.swift:146,232`), Timer (`List`, `NotchTimerView.swift:118`) and Agents (`NotchAgentsView.swift:203`) do not, so scrolling them can also drive the close gesture **(verify)**.

### 5.3 Gesture discoverability
- The only description of the gestures is a Settings footer (`SettingsView.swift:1426`). Onboarding does not mention gestures.
- That footer contradicts the toggle above it. It says the swipe gestures apply "when Open notch on hover is disabled", but "Enable gestures" is *disabled* when hover-open is off (`SettingsView.swift:1376`).
- Two similarly named toggles, "Reverse swipe gestures" and "Reverse open/close scroll gestures" (`SettingsView.swift:1397,1416`), differ only in jargon.
- The same clipboard glyph does four different things depending on a setting (`DynamicIslandHeader.swift:136-152`).

### 5.4 Destructive actions without confirmation
| Action | File:line | Notes |
|---|---|---|
| Clear clipboard history / pinned (Settings) | `SettingsView.swift:8615,8621` | The footer says "permanent"; the notch version *does* confirm (`NotchClipboardView.swift:97`) |
| Clear history / pinned (popover, panel) | `ClipboardPopover.swift:105-110`; `ClipboardPanel.swift:325-330` | Icon-only trash |
| Clear All Files (Screen Assistant) | `SettingsView.swift:8804` | |
| Clear Color History | `SettingsView.swift:8965` | The panel version confirms (`ColorPickerPanel.swift:220`) |
| Clear stats data | `SettingsView.swift:8362` | |
| Reset all app volumes | `SettingsView.swift:2768` | |
| Delete a note (row trash) | `NotchNotesView.swift:823` | Delete *all* confirms (`:703`) |
| Restart shell (kills running jobs) | `NotchTerminalView.swift:140-147` | 10 pt glyph |
| Remove custom visualizer (−) | `SettingsView.swift:5086-5098` | |
| Editor "Reset All" | `AnimationEditorView.swift:443` | |
| Remove extension (row) | `ExtensionsSettings.swift:498` | A section-level alert exists at `:53`; check that it is wired to this button **(verify)** |

### 5.5 Dead, placeholder or misleading controls
- **Copy latest crash report** filters for `"Toplet"` + `.crash` (`SettingsView.swift:7087`). The product is `Toplet` (`project.pbxproj` `PRODUCT_NAME = Toplet`) and current macOS writes `.ips`, so the button will always report "No crash reports found for DynamicIsland" (`:7092`).
- **Update channel picker and auto-update toggles** stay live while updates are disabled (section 5.6).
- **"Custom music live activity animation" (Coming soon)** is shown with a non-functional picker (`SettingsView.swift:5021-5034`).
- **`NotchColorPickerView`** is unreachable (inventory row 7).
- **Search results with no highlight target:** "Enable Custom OSD" (`SettingsView.swift:303`) and "LocalSend Device Picker Style" (`:363`, highlight ID "Device Picker Style", never applied at `:4595`). Choosing either opens the tab with nothing highlighted.
- **Misleading loading state:** each LLM card defaults to `.loading` (`NotchLLMUsageView.swift:58`) and shows a bare spinner (`:90-91`) with no timeout or "not configured" text.
- **Empty states that point at Settings without a button:** `NotchStatsView.swift:323`, `NotchColorPickerView.swift:47`.
- The colour-picker empty state hard-codes "Cmd+Shift+P" (`NotchColorPickerView.swift:131`), but the shortcut can be changed (`ShortcutConstants.swift:28`).

### 5.6 Update experience
- `TopletProject.updatesFeedBase = nil` (`models/TopletProject.swift:33`) makes `UpdateChannel.feedURL` return nil (`models/UpdateChannel.swift:53-54`). The delegate passes that nil to Sparkle (`services/AtollUpdaterDelegate.swift:24-26`).
- Sparkle's delegate contract treats nil as "use the default feed" (`SUFeedURL`). When I first read `Info.plist` it pointed at the upstream Atoll appcast. That key was removed during the audit **(fixed during audit)**, so no feed exists anywhere now. Confirm that Sparkle starts without an error alert when "Automatically check" is on **(verify)**.
- "Check for Updates…" is correctly disabled, with a tooltip (`SoftwareUpdater.swift:48-51`). But "Automatically check/download updates" (`:69-76`) and the 5-channel picker (`SettingsView.swift:4233-4268`) remain active and imply updates exist.

### 5.7 Global shortcut defaults
All shortcuts are enabled by default (`Constants.swift:1412`), and most features they need are on by default (`Constants.swift:1332,1360,1366,1373,1383`):

- `⌘⇧T` (a "demo" 5-minute timer) captured the browsers' "reopen closed tab". Its default was removed during the audit (`ShortcutConstants.swift:35-36`) **(fixed during audit)**.
- `⌘⇧V` opens clipboard history (`:27`), which captures "Paste and Match Style".
- `⌘⇧A` (`:29`), `⌘⇧P` (`:28`), `⌘⇧H` (`:32`), `⌘⇧I` (`:33`) and `⌘⇧K` (`:37`) collide with Finder and common app shortcuts.

### 5.8 Settings organisation
- Tabs are grouped as Core / Media & Display / System / Productivity / Utilities / Developer / Integrations / Info (`SettingsView.swift:74-87`). "Stats" sits under *Developer*, and the toggles for the **Games, Clock and LLM Usage tabs** are buried in Stats › General (`SettingsView.swift:8010-8024`). No Settings tab exists for Clock, Games or Usage.
- HUD settings are titled "Controls" (`SettingsView.swift:100`), while their copy says "HUD" and "OSD".
- Search has no "no results" state (the sidebar simply empties; `SettingsView.swift:652-668`). Downloads entries are filtered out of suggestions (`:884`).
- The same calendar look-ahead picker appears in two tabs (`SettingsView.swift:3901` and `:6283`).
- The window is resizable (`SettingsWindowController.swift:34`), but the content is fixed at 700 pt wide (`SettingsView.swift:684`).
- 20 section footers are right-aligned (`multilineTextAlignment(.trailing)`, for example `SettingsView.swift:1427`). Grouped forms normally use leading alignment.
- Minimalistic mode hides 9 tabs without explanation (`SettingsView.swift:1036-1043`).

### 5.9 Onboarding
- It opens with a confirmation dialog in developer jargon ("Use DevTools") that points to "the menu bar" (`OnboardingView.swift:131-146`). The setting actually lives in the app's main menu (`DynamicIslandApp.swift:1176-1208`), not the sailboat menu-bar extra (`:57-82`).
- There is no Accessibility step, no step indicator, no Back button, and the window is fixed at 400×600 (`OnboardingView.swift:125`).

### 5.10 Tooltips
The target has 74 `.help(` calls. `DynamicIslandHeader.swift` and `TabButton.swift` have none, and 23 of the 74 are in `SettingsView.swift`.

---

## 6. Copy quality

| Issue | Evidence | Suggested |
|---|---|---|
| Typo | `"unkown"`, `SettingsView.swift:4178` | "Unknown" |
| "calender" | Not found in any user-visible Swift string or `Localizable.xcstrings` | — |
| Product names mixed | Settings strings: "Dynamic Island" 27×, "notch" 110×, "Toplet" 21×; e.g. "Show media controls in Dynamic Island" `SettingsView.swift:3282`, "Accessibility permission lets Dynamic Island replace…" `:2888` | "Toplet" for the app, "notch" for the surface; "Dynamic Island" only for the external pill style (`:2020`) |
| Internal identifier shown to users | "Hide DynamicIsland Options" `SettingsView.swift:3646`; "No crash reports found for DynamicIsland" `:7092` | "Hide in full screen"; "No Toplet crash reports found" |
| "Toplet" used as a noun for the notch | "so the Toplet opens gracefully" `AnimationEditorView.swift:390` | "so the notch grows with it" |
| Upstream branding users see | Privacy policy → `ebullioscopic.github.io/DynamicIsland` (`WelcomeView.swift:64`, `OnboardingFinishView.swift:65`); Ebullioscopic logo on Welcome (`WelcomeView.swift:78`); "Made with ❤️ by Ebullioscopic" (`SettingsView.swift:4273`); Marketplace `getatoll.app` (`ExtensionsSettings.swift:72,81`); donation text describing upstream's cause (`SettingsView.swift:4226`, URL `strings/constants.swift:22`) | Credit upstream explicitly ("Based on Atoll by Ebullioscopic") and use Toplet's own privacy URL, or none |
| SDK name in end-user copy | "AtollExtensionKit" `ExtensionsSettings.swift:99,139,162` | "Toplet-compatible extensions (built with AtollExtensionKit)" |
| Jargon | "Use DevTools / Use without DevTools" (`OnboardingView.swift:136-141`, `DynamicIslandApp.swift:1189-1197`); "NowPlaying app" (`SettingsView.swift:3650`); "HUD" 74× and "OSD" 23× in Settings strings; "v\(n)" variant labels (`SettingsView.swift:2302,6465,7503,9087`) | "Detect Focus using Full Disk Access" (or whatever DevTools grants); "the app that's playing"; "On-screen indicator"; "Style 1/2/3" |
| Inconsistent names | "ColorPicker Disabled", "Enable ColorPicker in Settings → ColorPicker" (`NotchColorPickerView.swift:43,47`) vs tab "Color Picker" (`SettingsView.swift:105`) | "Color Picker" everywhere |
| Spelling variant | "colour" in Timer settings (`SettingsView.swift:434-437,7575,7647,7892`) vs "Color" elsewhere (`:2281,2316,2400`) | Pick US "color" (most strings) |
| Permission CTAs | "Allow Access" (`PermissionsRequestView.swift:66`), "Request Access"/"Open Settings" (`SettingsView.swift:9204-9205`), "Request Accessibility Access" (`DynamicIslandApp.swift:1216`) | "Grant Access…" and "Open System Settings" |
| Casing | "Get started" (`WelcomeView.swift:56`) vs "Not Now" (`PermissionsRequestView.swift:64`); "No Colors Yet" (`NotchColorPickerView.swift:127`) vs "No copies yet" (`NotchClipboardView.swift:142`); "Reset to defaults" (`MusicSlotConfigurationView.swift:133`) vs "Reset to Default" (`SettingsView.swift:2355`); "Settings" (`DynamicIslandApp.swift:58`) vs "Settings…" (`:89`) | Title case for buttons and menu items, sentence case for empty-state lines |
| Badges | "BETA" / "Beta" / "ALPHA" / "Coming soon" (section 2.2) | One `StatusBadge(.beta/.alpha)` |

---

## 7. Prioritised recommendations (top 20)

### Quick wins (S)
| # | Recommendation | Files | Effort |
|---|---|---|---|
| 1 | Force dark appearance at the notch root and drop the per-tab overrides | `ContentView.swift` (root), `components/Notch/DynamicIslandWindow.swift:33-60`; remove `NotchClockView.swift:73`, `NotchLLMUsageView.swift:51`, `NotchGamesView.swift:50` | S |
| 2 | Use `TabButton.label` for `accessibilityLabel` + `.help`, and add the `.isSelected` trait; label and tooltip the 7 header buttons; add a `label:` parameter to `HoverButton` | `Tabs/TabButton.swift:31-37`, `DynamicIslandHeader.swift:120-315`, `HoverButton.swift:25-49`, `NotchHomeView.swift:763-841` | S |
| 3 | Ship unassigned (or `⌃⌥`-based) defaults for global shortcuts; at minimum unbind `⌘⇧V` (`⌘⇧T` is already done) | `Shortcuts/ShortcutConstants.swift:27-38` | S |
| 4 | Confirm every permanent clear/delete/reset with one shared `confirmationDialog` | `SettingsView.swift:2768,5086,8362,8615,8621,8804,8965`; `ClipboardPopover.swift:105`; `ClipboardPanel.swift:325`; `NotchNotesView.swift:823`; `NotchTerminalView.swift:140`; `AnimationEditorView.swift:443` | S |
| 5 | Hide auto-update toggles and the channel picker while `updatesFeedBase == nil`; show "Updates are not published yet" instead | `SoftwareUpdater.swift:66-83`, `SettingsView.swift:4233-4268` | S |
| 6 | Fix the crash-report filter (`Toplet`, `.ips`) and its message | `SettingsView.swift:7080-7094` | S |
| 7 | Fix the gesture toggle/footer contradiction and merge the two "reverse" toggles | `SettingsView.swift:1376,1397,1416,1426` | S |
| 8 | Register scroll suppression in LLM Usage, Clock, Timer list and Agents scroll views | `NotchLLMUsageView.swift:244`, `NotchClockView.swift:146,232`, `NotchTimerView.swift:118`, `Agents/NotchAgentsView.swift:203` | S |
| 9 | Rebrand visible strings: privacy URL, credits, marketplace, "Toplet"/"Dynamic Island", typo "unkown", "colour" | section 6 table | S |
| 10 | Give the LLM cards a "Not set up" / timeout state, and add "Open Settings" buttons to empty states; read the colour-picker shortcut from `KeyboardShortcuts` | `NotchLLMUsageView.swift:58,90`, `NotchStatsView.swift:318-345`, `NotchColorPickerView.swift:40-50,131` | S |
| 11 | Label the 10 `Picker("")` and the editor sliders; raise secondary text to ≥ 0.5 white | section 3.1; `NotchGamesView.swift:203`, `NotchStatsView.swift:458` | S |

### Medium (M)
| # | Recommendation | Files | Effort |
|---|---|---|---|
| 12 | Gate notch-level motion on Reduce Motion: hover bounce, open/close springs, tab slide, header blur, repeat-forever pulses | `ContentView.swift:319-331,690-706,1148-1151,2334,2387`; `DynamicIslandHeader.swift:97-98,369`; `PulsingModifier.swift:29`; `DynamicIslandBattery.swift:869-874`; `RecordingIndicator.swift:66` | M |
| 13 | Keyboard access: make the notch key when opened by shortcut, cancel the 3 s auto-close while it is focused, add ←/→ tab switching and Esc to close | `DynamicIslandApp.swift:1100-1134`, `ContentView.swift`, `Tabs/TabSelectionView.swift:130-166` | M |
| 14 | Onboarding: drop the opening DevTools dialog (move it to a Focus step in plain language), add an Accessibility step, a step indicator and Back | `Onboarding/OnboardingView.swift:27-147`, `PermissionsRequestView.swift` | M |
| 15 | Settings IA: add a "Notch Tabs" page (Games, Clock, Usage, Terminal, Agents toggles and order), move Stats out of "Developer", add a no-results state, de-duplicate the calendar pickers | `SettingsView.swift:21-118,652-668,3901,6283,8010-8024` | M |
| 16 | Settings light mode and resizing: replace white-opacity hairlines and hovers with `Color(nsColor: .separatorColor)` / `.quaternaryLabelColor`, fix the Devices tint, let the content track the window width, make footers leading-aligned | `SettingsView.swift:150,684,697-713,945,998,1006`; `AnimationEditorView.swift:171,554,627` | M |
| 17 | Hover robustness: make the 100 ms exit delay a token (about 250 ms) with a hover bridge to popovers; clamp the minimum dwell to ≥ 0.1 s; show a one-time hint for sticky tabs | `ContentView.swift:2351,2373,2497-2499`; `SettingsView.swift:1450` | M |

### Larger redesigns (L)
| # | Recommendation | Files | Effort |
|---|---|---|---|
| 18 | Add `TopletTokens.swift` (section 2.3) and migrate Home, Shelf, Stats, Clipboard, Notes, Terminal and header chrome to `notchSurface` plus the tokens; map `AgentsTheme` onto it | `components/Notch/*`, `DynamicIslandHeader.swift:122-310`, `Agents/AgentsTheme.swift:31-48` | L |
| 19 | Typography: replace the 623 `.system(size:)` with `TopletType` text styles, add an in-app text-size setting, and let notch heights grow with it | all `components/**`; `sizing/matters.swift` | L |
| 20 | VoiceOver pass for HUD/OSD, live activities, Clipboard, Color Picker, Stats and Screen Assistant: grouping, values (`accessibilityValue` for sliders and gauges) and announcements for HUD changes | `components/OSD/*`, `components/Live activities/*`, `components/Clipboard/*`, `components/ColorPicker/*`, `components/Stats/*`, `components/ScreenAssistant/*` | L |

Also worth doing: either wire `NotchViews.colorPicker` to a tab or delete `NotchColorPickerView.swift`, and choose one canonical copy of the Agents UI so `AgentsComponents.swift:268` stops drifting.

---

## Appendix: how the numbers were produced

All counts come from `grep -rhoE` over `--include='*.swift'` in the paths named. Patterns used:

- Radii: `cornerRadius: *[0-9.]+`
- Fonts: `\.system\(size: *[0-9.]+`
- Opacity: `opacity\(0?\.[0-9]+\)|opacity\([01](\.0)?\)`
- Curves: `\.(easeInOut|easeOut|easeIn|linear|spring|smooth|snappy|bouncy|interactiveSpring|interpolatingSpring)(\([^)]*\))?`
- Animation sites: `withAnimation|\.animation\(`

The icon-button scan was a brace-matching Python script, run read-only and kept in the session scratchpad, not in the repo. Its output was filtered by hand for false positives. Contrast ratios are WCAG 2.x relative-luminance ratios of the flattened colour on `#000000`/`#FFFFFF`. Variables, ternaries and computed values are not counted, so every count is a lower bound.
