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

import AppKit
import Defaults
import SwiftUI

/// The pinned provider's plan limits as one line under the closed notch, e.g.
/// "Claude  Session ▰▱ 47% · 1 hr 45 min   Weekly ▰▱ 18%".
///
/// Same contract as PinnedLyricsModifier: height-only padding plus an overlay, so the strip never
/// reports an intrinsic width to the closed notch's stack. It drops detail until it fits the width
/// the notch already has.
struct PinnedUsageModifier: ViewModifier {
    @ObservedObject private var manager = LLMUsageManager.shared
    @Default(.pinnedUsageProvider) private var pinnedRaw
    @Default(.enableLLMUsageFeature) private var featureEnabled
    @Default(.llmUsagePercentStyle) private var percentStyle
    let isVisible: Bool
    let isContentHidden: Bool

    func body(content: Content) -> some View {
        let rows = PinnedUsageView.rows(manager: manager)
        let height = PinnedUsageView.reservedHeight(isEligible: isVisible, rows: rows)
        content
            .padding(.bottom, height)
            .overlay(alignment: .bottom) {
                if height > 0, let provider = manager.pinnedProvider {
                    strip(provider: provider, rows: rows)
                        .opacity(isContentHidden ? 0 : 1)
                        .accessibilityHidden(isContentHidden)
                }
            }
            .animation(.smooth(duration: 0.28), value: height)
    }

    private func strip(provider: ProviderID, rows: [UsageLimitRow]) -> some View {
        TimelineView(.periodic(from: Date(), by: 30)) { context in
            ViewThatFits(in: .horizontal) {
                line(provider: provider, rows: rows, now: context.date, name: true, reset: true)
                line(provider: provider, rows: rows, now: context.date, name: false, reset: true)
                line(provider: provider, rows: rows, now: context.date, name: false, reset: false)
                line(provider: provider, rows: Array(rows.prefix(1)), now: context.date, name: false, reset: false)
            }
        }
        .font(.system(size: PinnedUsageView.fontSize, weight: .medium))
        .padding(.horizontal, 10)
        // The overlay is offered the notch's own width; never draw past it.
        .frame(maxWidth: .infinity)
        .frame(height: PinnedUsageView.rowHeight)
        .padding(.bottom, PinnedUsageView.gap)
        .clipped()
        .accessibilityElement(children: .combine)
    }

    private func line(provider: ProviderID, rows: [UsageLimitRow], now: Date, name: Bool, reset: Bool) -> some View {
        HStack(spacing: 10) {
            if name {
                Text(provider.displayName).fontWeight(.semibold).foregroundStyle(.white.opacity(0.85))
            }
            ForEach(Array(rows.prefix(2).enumerated()), id: \.element.id) { index, row in
                HStack(spacing: 4) {
                    Text(row.shortTitle).foregroundStyle(.white.opacity(0.55))
                    miniBar(row.limit)
                    Text(UsageLimitWording.percent(row.limit, style: percentStyle))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.9))
                    // Only the first (session) window gets a countdown; a weekly date is too long here.
                    if reset, index == 0, let countdown = countdown(row.limit.resetsAt, now: now) {
                        Text("· " + countdown).foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func countdown(_ date: Date?, now: Date) -> String? {
        guard let remaining = date?.timeIntervalSince(now), remaining > 0, remaining < 86_400 else { return nil }
        return UsageLimitWording.duration(remaining)
    }

    private func miniBar(_ limit: UsageLimit) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.18))
            Capsule().fill(limit.fraction > 0.9 ? Color.orange : Color.accentColor)
                .frame(width: limit.fraction > 0 ? max(3, 26 * limit.fraction) : 0)
        }
        .frame(width: 26, height: 4)
    }
}

extension View {
    func pinnedUsage(isVisible: Bool, isContentHidden: Bool = false) -> some View {
        modifier(PinnedUsageModifier(isVisible: isVisible, isContentHidden: isContentHidden))
    }
}

enum PinnedUsageView {
    static let fontSize: CGFloat = 10
    static let gap: CGFloat = 4
    static let rowHeight: CGFloat = {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        return (font.ascender - font.descender + font.leading).rounded(.up) + 2
    }()

    /// The pinned provider's limits, empty when nothing is pinned or no reading has arrived yet.
    @MainActor
    static func rows(manager: LLMUsageManager) -> [UsageLimitRow] {
        guard let provider = manager.pinnedProvider,
              case .success(let snapshot) = manager.results[provider] else { return [] }
        return UsageLimitWording.rows(for: provider, snapshot: snapshot)
    }

    static func reservedHeight(isEligible: Bool, rows: [UsageLimitRow]) -> CGFloat {
        isEligible && !rows.isEmpty ? rowHeight + gap : 0
    }
}
