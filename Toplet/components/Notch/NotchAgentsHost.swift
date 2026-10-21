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
import Defaults

// Hosts for the standalone agents views (components/Notch/Agents/, synced from AtollAgents/UI). They live here, outside
// that folder, because `local/sync-agents.sh` replaces everything inside it.

/// Open-notch height for the Agents tab. The tab shows a header, the metric strip, the session list and the board, so the
/// old fixed 240 pt left only the first session row visible. It now fits its content: as tall as what is on screen needs
/// (measured by `AgentsNotchFit`), never below the 240 pt design minimum and never above the user's maximum, a fraction of
/// the notch screen's visible height (Settings > AI Agents). Anything beyond the maximum scrolls.
enum AgentsNotchSizing {
    static let minimumHeight: CGFloat = 240
    static let fractionRange: ClosedRange<Double> = 0.3...0.8

    /// The user's ceiling for the notch screen.
    static func maximumHeight(screenName: String?) -> CGFloat {
        let screen = screenName.flatMap { name in NSScreen.screens.first { $0.localizedName == name } } ?? NSScreen.main
        let visible = screen?.visibleFrame.height ?? 800
        let fraction = min(max(Defaults[.agentsPanelHeightFraction], fractionRange.lowerBound), fractionRange.upperBound)
        let ceiling = max(minimumHeight, visible - 60)
        return min(max(minimumHeight, (visible * fraction).rounded()), ceiling)
    }

    /// Main thread only (SwiftUI bodies and the app delegate's window sizing).
    static func height(screenName: String?) -> CGFloat {
        let maximum = maximumHeight(screenName: screenName)
        guard let fitted = AgentsNotchFit.shared.fittedHeight else { return maximum }
        return min(max(minimumHeight, fitted), maximum)
    }
}

/// Turns the Agents view's (content, visible) heights into the notch height that shows all of it. Works from the height
/// currently in use, so it needs no knowledge of the tab row or paddings above the view. Reports are settled for a moment
/// first (the notch animates while it resizes, and mid-animation viewports would overshoot), rounded to 8 pt and ignored
/// when the change is smaller than that, so a ticking clock or a hover never makes the notch twitch. Main thread only.
final class AgentsNotchFit: ObservableObject {
    static let shared = AgentsNotchFit()
    @Published private(set) var fittedHeight: CGFloat?
    private var pending: DispatchWorkItem?

    func report(content: CGFloat, viewport: CGFloat, currentHeight: CGFloat) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let target = ((currentHeight + content - viewport) / 8).rounded(.up) * 8
            if let old = self.fittedHeight, abs(old - target) < 8 { return }
            self.fittedHeight = target
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}

/// The "Agents" notch tab. `isActive` = the notch is open and this tab is selected; while false the view runs no clock.
struct NotchAgentsHostView: View {
    @ObservedObject private var runtime = AgentsRuntime.shared
    @ObservedObject private var usage = LLMUsageManager.shared
    @EnvironmentObject private var vm: DynamicIslandViewModel
    let isActive: Bool

    var body: some View {
        NotchAgentsView(
            center: runtime.center,
            isActive: isActive,
            onOpenSettings: { AgentsRuntime.shared.openSettings() },
            onInstallHooks: { AgentsRuntime.shared.openSettings() },
            onAcknowledge: { key in AgentsRuntime.shared.center.acknowledge(key) },
            onAcknowledgeAll: { AgentsRuntime.shared.center.acknowledgeAll() },
            onRefreshUsage: { refreshPlanQuota() },
            onContentFit: { content, viewport in
                guard isActive else { return }
                AgentsNotchFit.shared.report(content: content, viewport: viewport,
                                             currentHeight: AgentsNotchSizing.height(screenName: vm.screen))
            }
        )
        // Long prompts give the rows an ideal width far wider than the notch; the tab always takes the width it is
        // offered and never asks for more, so nothing pushes the notch wider or gets cut off at its edges.
        .frame(minWidth: 0, idealWidth: AgentsLayout.contentWidth, maxWidth: .infinity, alignment: .top)
        .onReceive(usage.$results) { values in
            runtime.center.quotaReadings = [ProviderID.claude, .codex].compactMap { provider in
                guard case .success(let snapshot) = values[provider] else { return nil }
                return AgentQuotaReading(kind: provider == .claude ? .claudeCode : .codex,
                    fiveHourPercent: snapshot.sessionLimit.map { $0.fraction * 100 },
                    sevenDayPercent: snapshot.weekLimit.map { $0.fraction * 100 },
                    fiveHourReset: snapshot.sessionLimit?.resetsAt, sevenDayReset: snapshot.weekLimit?.resetsAt,
                    todayEstimatedCost: snapshot.hasLocalTotals && !snapshot.today.hasUnpricedModel ? snapshot.today.costUSD : nil,
                    observedAt: snapshot.lastUpdated)
            }
        }
        .onAppear { runtime.setTabVisible(isActive) }
        .onChange(of: isActive) { _, active in runtime.setTabVisible(active) }
        .onDisappear { runtime.setTabVisible(false) }
    }
    /// Quota refresh must not invoke the legacy full-history log scan: the incremental ledger owns token history.
    private func refreshPlanQuota() {
        Task { @MainActor in
            var readings: [AgentQuotaReading] = []
            if Defaults[.enableClaudeProvider] {
                let value = await ClaudeQuotaClient().fetchLimits()
                readings.append(AgentQuotaReading(kind: .claudeCode,
                    fiveHourPercent: value.session.map { $0.fraction * 100 }, sevenDayPercent: value.week.map { $0.fraction * 100 },
                    fiveHourReset: value.session?.resetsAt, sevenDayReset: value.week?.resetsAt,
                    todayEstimatedCost: nil, observedAt: Date()))
            }
            if Defaults[.enableCodexProvider] {
                let value = await CodexQuotaClient().fetchLimits()
                readings.append(AgentQuotaReading(kind: .codex,
                    fiveHourPercent: value.session.map { $0.fraction * 100 }, sevenDayPercent: value.week.map { $0.fraction * 100 },
                    fiveHourReset: value.session?.resetsAt, sevenDayReset: value.week?.resetsAt,
                    todayEstimatedCost: nil, observedAt: Date()))
            }
            runtime.center.quotaReadings = readings
        }
    }

}

/// Closed-notch live activity: a small glyph per active agent kind on the left wing, the black notch body in the middle and
/// an equally wide empty right wing so the shape stays centred on the camera housing (the same recipe as the timer and
/// recording activities). Only inserted into the chain by ContentView when the summary is not empty, so with no active
/// agent it takes no width at all.
struct AgentsClosedLiveActivity: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject private var model = AgentsClosedModel.shared
    let isHovering: Bool
    let onTap: () -> Void

    /// Wing height contract from the indicator: effectiveClosedNotchHeight - 12, +12 while hovering.
    private var glyphHeight: CGFloat { max(0, vm.effectiveClosedNotchHeight - (isHovering ? 0 : 12)) }
    private let wingPadding: CGFloat = 8

    /// The glyph only animates while it matters: when hovered or when an agent needs you (permission / waiting). A permanent
    /// breathing glyph keeps SwiftUI rendering at display rate (measured ~10 % CPU on an idle Mac); static it costs nothing.
    private var animates: Bool {
        isHovering || model.summary.kinds.contains { $0.state == .attention }
    }

    private var wingWidth: CGFloat {
        let w = AgentsClosedIndicator.width(for: model.summary, height: glyphHeight)
        return w == 0 ? 0 : max(42, w + wingPadding)
    }

    private var tokenLabel: String {
        if model.hourTokens >= 1_000_000 { return String(format: "%.1fM", Double(model.hourTokens) / 1_000_000) }
        if model.hourTokens >= 1000 { return String(format: "%.1fK", Double(model.hourTokens) / 1000) }
        return "\(model.hourTokens)"
    }

    var body: some View {
        HStack(spacing: 0) {
            AgentsClosedIndicator(summary: model.summary, height: glyphHeight, isActive: animates, onTap: onTap)
                .padding(.leading, wingPadding / 2)
                .frame(width: wingWidth, height: glyphHeight, alignment: .leading)
            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width + (isHovering ? 8 : 0), height: glyphHeight)
            Text((model.usageIndexing ? "~" : "") + tokenLabel)
                .font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: wingWidth, height: glyphHeight)
                .help("\(model.hourTokens) tokens in the last hour on this Mac" + (model.usageIndexing ? "; history is still indexing, so this is partial" : ""))
                .accessibilityLabel((model.usageIndexing ? "Partial total: " : "") + "\(model.hourTokens) tokens in the last hour")
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
        .transition(.opacity.animation(.smooth(duration: 0.25)))
    }
}
