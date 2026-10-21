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
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import SwiftUI
import Defaults

enum AntigravityPool: String, CaseIterable {
    case gemini = "Gemini"
    case claude = "Claude"
}

struct NotchLLMUsageView: View {
    @ObservedObject private var manager = LLMUsageManager.shared
    @State private var antigravityPool: AntigravityPool = .gemini
    @Default(.showLLMUsageDetails) private var showDetails
    @Default(.llmUsagePercentStyle) private var percentStyle
    @Default(.pinnedUsageProvider) private var pinnedProvider

    private func isEnabled(_ provider: ProviderID) -> Bool { Defaults[provider.enabledKey] }

    private var enabledProviders: [ProviderID] {
        ProviderID.allCases.filter { isEnabled($0) }
    }

    var body: some View {
        // Ticks every 30 s (from now, not the minute boundary, so countdowns never overstate) while the tab is open.
        TimelineView(.periodic(from: Date(), by: 30)) { context in
            HStack(alignment: .top, spacing: 10) {
                ForEach(enabledProviders) { provider in
                    card(for: provider, now: context.date)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .environment(\.colorScheme, .dark)
        .onAppear { manager.refreshAll() }
        .onChange(of: showDetails) { _, _ in manager.refreshAll(force: true) }
    }

    @ViewBuilder
    private func card(for provider: ProviderID, now: Date) -> some View {
        let result = manager.results[provider] ?? .loading
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(provider.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)
                // Subscription plan badge (e.g. "Max 5x"). Only set for Claude; nil elsewhere.
                if case .success(let snap) = result, let plan = snap.plan {
                    Text(plan)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.white.opacity(0.12), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if provider == .antigravity {
                    Picker("", selection: $antigravityPool) {
                        Text("Gemini").tag(AntigravityPool.gemini)
                        Text("Claude").tag(AntigravityPool.claude)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                    .controlSize(.mini)
                }
                if provider != .newAPI {
                    pinButton(provider)
                }
            }
            switch result {
            case .loading:
                ProgressView().controlSize(.small)
            case .failure(let reason):
                Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                footer(updated: nil, now: now)
            case .success(let snap):
                if provider == .newAPI {
                    newAPISuccess(snap)
                } else {
                    success(snap, provider: provider, now: now)
                }
                Spacer(minLength: 0)
                footer(updated: snap.lastUpdated, now: now)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        // Stretch every card to the height the panel offers so the row stays uniform
        // (the intent behind the former fixed card height) without a hard-coded size
        // that either clips content or leaves blank space.
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .notchSurface(cornerRadius: 12)
    }

    @ViewBuilder
    private func success(_ snap: UsageSnapshot, provider: ProviderID, now: Date) -> some View {
        let rows = UsageLimitWording.rows(for: provider, snapshot: snap,
                                          antigravityPool: antigravityPool == .gemini ? "gemini" : "claude")
        VStack(alignment: .leading, spacing: 8) {
            if rows.isEmpty {
                if showDetails && provider != .cursor {
                    window("Today", snap.today, prominent: true)
                    window("Week", snap.week)
                    window("Session", snap.session)
                }
                Text("Limits unavailable").font(.caption2).foregroundStyle(.secondary.opacity(0.7))
            } else {
                ForEach(rows) { row in limitRow(row, now: now) }
                // Token counts and estimated cost come from local logs (or, for Antigravity, the
                // language server's history); they are extra detail, off unless asked for.
                if showDetails && provider != .cursor && (snap.hasLocalTotals || provider == .antigravity) {
                    VStack(alignment: .leading, spacing: 2) {
                        window("Today", snap.today, compact: true)
                        window("Week", snap.week, compact: true)
                    }
                }
            }
        }
    }

    /// One limit laid out like the Claude app: "Session limit … Resets in 1 hr 45 min  47%" over a bar.
    /// When the card is too narrow for one line, the reset time moves under the bar.
    private func limitRow(_ row: UsageLimitRow, now: Date) -> some View {
        let reset = UsageLimitWording.reset(row.limit.resetsAt, now: now)
        let percent = UsageLimitWording.percent(row.limit, style: percentStyle)
        let title = Text(row.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
        let value = Text(percent).font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
        return ViewThatFits(in: .horizontal) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    title
                    Spacer(minLength: 8)
                    if let reset { Text(reset).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                    value
                }
                bar(row.limit)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    title.truncationMode(.tail)
                    Spacer(minLength: 4)
                    value
                }
                bar(row.limit)
                if let reset { Text(reset).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func bar(_ limit: UsageLimit) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule().fill(gaugeTint(limit.fraction))
                    .frame(width: limit.fraction > 0 ? max(4, geo.size.width * limit.fraction) : 0)
            }
        }
        .frame(height: 5)
    }

    private func gaugeTint(_ fraction: Double) -> Color {
        if fraction > 0.95 { return .red }
        if fraction > 0.9 { return .orange }
        return .accentColor
    }

    /// Filled while pinned, like the lyrics pin: the strip it controls only shows once the notch closes.
    private func pinButton(_ provider: ProviderID) -> some View {
        let pinned = pinnedProvider == provider.rawValue
        return Button {
            withAnimation(.smooth) {
                pinnedProvider = pinned ? "" : provider.rawValue
            }
        } label: {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(pinned ? Color.accentColor : Color.white.opacity(0.5))
                .rotationEffect(.degrees(pinned ? 0 : 45))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pinned
            ? "Stop showing \(provider.displayName) limits under the closed notch"
            : "Keep \(provider.displayName) limits under the closed notch")
        .accessibilityLabel(pinned
            ? "Unpin \(provider.displayName) limits from closed notch"
            : "Pin \(provider.displayName) limits to closed notch")
    }

    private func footer(updated: Date?, now: Date) -> some View {
        HStack(spacing: 4) {
            if let updated, updated > .distantPast {
                Text(updatedText(updated, now: now))
            }
            Spacer(minLength: 0)
            Button {
                manager.refreshAll(force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(manager.isRefreshing ? 180 : 0))
                    .animation(.smooth, value: manager.isRefreshing)
                    .frame(width: 16, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(manager.isRefreshing)
            .help("Refresh now")
            .accessibilityLabel("Refresh usage")
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary.opacity(0.8))
    }

    private func updatedText(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "Updated just now" }
        if minutes < 60 { return "Updated \(minutes) min ago" }
        return "Updated " + UsageLimitWording.duration(now.timeIntervalSince(date)) + " ago"
    }

    private func newAPISuccess(_ snap: UsageSnapshot) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(snap.newAPIAccounts) { account in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(account.name)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            if account.errorMessage != nil {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .help(account.errorMessage ?? "New API account has an error")
                            }
                        }

                        if let errorMessage = account.errorMessage,
                           account.balanceQuota == nil {
                            Text(errorMessage)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        } else {
                            quotaRow("Balance", account.balanceQuota, prominent: true)
                            quotaRow("Used", account.usedQuota)
                            quotaRow("Today", account.todayQuota)
                            quotaRow("Week", account.weekQuota)
                            HStack(spacing: 12) {
                                metric("RPM", account.currentRPM)
                                metric("TPM", account.currentTPM)
                                metric("Requests", account.requestCount)
                            }
                            if let errorMessage = account.errorMessage {
                                Text(errorMessage)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.bottom, 2)
                    .overlay(alignment: .bottom) {
                        if account.id != snap.newAPIAccounts.last?.id {
                            Rectangle()
                                .fill(.white.opacity(0.1))
                                .frame(height: 1)
                        }
                    }
                }
            }
        }
        .frame(height: 135)
    }

    private func quotaRow(_ label: String, _ value: Int?, prominent: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Text(value.map(quota) ?? "-")
                .font(.system(size: prominent ? 15 : 11, weight: prominent ? .bold : .semibold, design: .rounded))
                .monospacedDigit()
            Spacer()
        }
    }

    private func metric(_ label: String, _ value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value.map(quota) ?? "-")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
        }
    }

    private func window(_ label: String, _ totals: UsageTotals, prominent: Bool = false, compact: Bool = false) -> some View {
        let displayValue: String
        if totals.isPercentage {
            displayValue = "\(totals.totalTokens)%"
        } else {
            displayValue = tokens(totals.totalTokens)
        }
        
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: compact ? 56 : 48, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(displayValue)
                .font(.system(size: compact ? 11 : (prominent ? 17 : 13), weight: prominent ? .bold : .semibold, design: .rounded))
                .monospacedDigit()
            Spacer(minLength: 4)
            if totals.isPercentage {
                // Quota providers store the remaining fraction in costUSD; it is not money.
                let leftPct = Int((max(0, min(1, totals.costUSD)) * 100).rounded())
                Text("\(leftPct)% left")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            } else {
                Text(costLabel(totals))
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    .help(costHelp(totals))
            }
        }
    }

    /// Cost is an estimate computed from local token counts against the API price
    /// table — not a subscription bill. When some models used have no entry in the
    /// table we cannot price them: show "\(money)+" when a partial amount is known,
    /// and an explicit "est. n/a" instead of a misleading "$0.00+" when nothing is.
    private func costLabel(_ totals: UsageTotals) -> String {
        guard totals.hasUnpricedModel else { return money(totals.costUSD) }
        return totals.costUSD > 0 ? money(totals.costUSD) + "+" : "est. n/a"
    }

    private func costHelp(_ totals: UsageTotals) -> String {
        if totals.hasUnpricedModel {
            return "Estimated API-equivalent cost from local token counts (not your subscription bill). Some models used do not have usable pricing, so this is partial or unavailable."
        }
        return "Estimated API-equivalent cost from local token counts (cache reads and writes priced at the provider's cache rates), not your subscription bill."
    }

    private func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.1fk", Double(n) / 1_000)
        default: return "\(n)"
        }
    }

    private func quota(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.1fk", Double(n) / 1_000)
        default: return "\(n)"
        }
    }

    // Locale-aware formatting pinned to USD — amounts come from the USD pricing table, so the currency code stays fixed.
    private static let currencyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        return f
    }()

    private func money(_ v: Double) -> String {
        Self.currencyFormatter.string(from: v as NSNumber) ?? String(format: "$%.2f", v)
    }
}
