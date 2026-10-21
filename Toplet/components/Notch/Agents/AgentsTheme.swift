/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 */


import SwiftUI
import AppKit

// Visual tokens and small formatting helpers for the Agents UI. The UI deliberately knows nothing about Atoll's
// own types (Defaults, DynamicIslandViewModel ...) so it compiles standalone; the integration step can map
// `AgentsTheme` to Atoll's theme by assigning the few `static var`s below once at start-up.
//
// Conventions copied from the existing notch views (NotchLLMUsageView, NotchClipboardView, NotchNotesView):
//  - black notch background (provided by the host), content forced to the dark colour scheme,
//  - cards are `Color.white.opacity(0.06)` in a 12 pt continuous rounded rectangle, hairlines at 0.10,
//  - `.headline` section titles, `.caption/.caption2` secondary text, SF Symbols, `.smooth` / spring animations,
//  - the accent is the system accent (`Color.accentColor`): Atoll defines no fixed brand colour (#FF5C00 does not
//    appear anywhere in the code base); orange is used only for "needs you" states, as in NotchStatsView.

enum AgentsTheme {
    /// Interactive accent. The host may replace it (for example with Atoll's own accent) before showing the view.
    static var accent: Color = .accentColor
    static var attention: Color = .orange
    static var success: Color = .green
    static var danger: Color = .red

    static let cardFill = Color.white.opacity(0.06)
    static let cardFillStrong = Color.white.opacity(0.10)
    static let hairline = Color.white.opacity(0.10)
    static let codeFill = Color.black.opacity(0.45)

    /// 8 pt grid; corners are continuous and concentric: inner radius = outer radius - container padding.
    static let cardRadius: CGFloat = 16
    static let cardPadding: CGFloat = 8
    static var innerRadius: CGFloat { cardRadius - cardPadding }    // 8
    static let chipRadius: CGFloat = 8
    static let minTarget: CGFloat = 28                              // HIG minimum hit target on macOS

    static func color(for kind: AgentKind) -> Color {
        switch kind {
        case .claudeCode: return Color(red: 0.85, green: 0.47, blue: 0.34)   // warm terracotta
        case .codex: return Color(red: 0.36, green: 0.78, blue: 0.69)        // teal
        }
    }

    static func symbol(for kind: AgentKind) -> String {
        switch kind {
        case .claudeCode: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// Sizes the section is designed for. Measured in the code base:
///  - `openNotchSize` (Toplet/sizing/matters.swift): width = Defaults[.openNotchWidth] (default 640, raised to
///    the tab-count minimum, up to 770), height = 200. Tabs may ask for more (notes list 240, split 260).
///  - the notch content is inset by `notchHorizontalPadding` (14 pt with corner scaling, 19 without) on each side, and the
///    open header row (DynamicIslandHeader, tabs) takes `max(24, closedNotchHeight)` (about 32 pt).
/// So under the tab row the section gets roughly 612 x 168 pt at the default height. It is designed to look right from
/// 168 pt upward and scrolls vertically when its content is taller. The host (`AgentsNotchSizing` in
/// NotchAgentsHost.swift) sizes the `.agents` tab to fit this content (reported through `onContentFit`), between 240 pt and
/// a user-set fraction of the screen height.
enum AgentsLayout {
    static let contentWidth: CGFloat = 612
    static let recommendedNotchHeight: CGFloat = 240
    static let headerRowHeight: CGFloat = 32
    static let contentHeight: CGFloat = recommendedNotchHeight - headerRowHeight   // 208
    static let minimumContentHeight: CGFloat = 168                                 // default 200 pt notch
    static let settingsWidth: CGFloat = 700                                        // SettingsForm in SettingsView.swift
}

// MARK: - Formatting

enum AgentsFormat {
    /// "12s", "2m 03s", "1h 05m".
    static func elapsed(since date: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        if s < 86_400 { return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m" }
        return "\(s / 86_400)d"
    }

    /// Coarser form for idle/done sessions where seconds are noise: "3m", "2h", "4d".
    static func coarse(since date: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }

    static func countdown(remaining: TimeInterval) -> String {
        let s = max(0, Int(remaining.rounded(.up)))
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    /// "/Users/me/Desktop/github/Atoll" -> "~/Desktop/github/Atoll" when short, else "…/github/Atoll" (last two components).
    static func shortPath(_ path: String) -> String {
        var p = path
        let home = NSHomeDirectory()
        if p == home { return "~" }
        if p.hasPrefix(home + "/") { p = "~" + p.dropFirst(home.count) }
        let parts = p.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.count <= 3 { return p }
        return "…/" + parts.suffix(2).joined(separator: "/")
    }

    /// Collapses newlines/tabs so a one-line label really is one line (the model already sanitised the text).
    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: { $0.isNewline || $0 == "\t" }).joined(separator: " ")
    }
}

// MARK: - Status presentation

extension SessionStatus {
    var label: String {
        switch self {
        case .starting: return "Starting"
        case .running: return "Running"
        case .waitingInput: return "Waiting for you"
        case .needsPermission: return "Needs permission"
        case .idle: return "Idle"
        case .done: return "Done"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        case .unknown: return "Unknown"
        }
    }

    var dotColor: Color {
        switch self {
        case .running, .starting: return AgentsTheme.success
        case .needsPermission, .waitingInput: return AgentsTheme.attention
        case .failed: return AgentsTheme.danger
        case .idle: return Color.gray
        case .done, .stopped, .unknown: return Color.white.opacity(0.28)
        }
    }

    var isLiveActivity: Bool { self == .running || self == .starting }
}

extension AgentKind {
    var shortName: String { self == .claudeCode ? "Claude" : "Codex" }
}
