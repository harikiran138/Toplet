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

// The ATTENTION strip: one card per pending approval.
//
// Safety rules baked into this file (docs/AI-AGENTS-RESEARCH.md 5.2 item 7):
//  - Allow / Deny / Always allow are offered ONLY when the owning session is a live (hook-verified) session. For an
//    unknown or passively discovered session the card is informational and the only action is "Let terminal decide".
//  - There is no default keyboard shortcut on Allow (a stray Return must never approve a tool call).
//  - "Always allow" lives in a secondary menu and needs an explicit second step (inline confirmation, not a sheet,
//    so it also works inside the non-activating notch window).
//  - All text comes from an untrusted local process: it is rendered verbatim, never as markdown or links.

struct ApprovalCardView: View {
    let approval: PendingApproval
    let session: AgentSession?
    let now: Date
    let glassNamespace: Namespace.ID
    let isExpanded: Bool
    let alwaysAllow: PermissionSuggestion?          // non-nil: the card shows the confirmation step
    let onToggleDetail: () -> Void
    let onDecide: (ApprovalDecision) -> Void
    let onRequestAlways: (PermissionSuggestion) -> Void
    let onCancelAlways: () -> Void

    @Environment(\.agentsMotion) private var m

    private var verified: Bool { session?.isLive == true }
    private var kind: AgentKind { approval.sessionKey.kind }
    private var project: String { session?.projectName ?? "Unknown session" }
    private var remaining: TimeInterval { approval.expiresAt.timeIntervalSince(now) }
    private var fraction: Double {
        let total = approval.expiresAt.timeIntervalSince(approval.createdAt)
        guard total > 0 else { return 0 }
        return min(1, max(0, remaining / total))
    }
    private var urgent: Bool { remaining <= 10 }
    private var hasDetail: Bool { !(approval.detail ?? "").isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow
            summaryRow
            if isExpanded, let detail = approval.detail, !detail.isEmpty {
                detailBox(detail)
                    .modifier(FrozenReveal())
                    .transition(.agentsReveal(animates: m.animates))
            }
            if let alwaysAllow, verified {
                confirmRow(alwaysAllow)
            } else if verified {
                actionRow
            } else {
                unverifiedRow
            }
            countdownBar
        }
        .padding(12)
        .agentsGlass(tint: AgentsTheme.attention, id: "approval-\(approval.id.uuidString)", in: glassNamespace)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: Pieces

    private var titleRow: some View {
        HStack(spacing: 7) {
            AgentGlyph(kind: kind, size: 18)
            Text(verbatim: project)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            AgentBadge(kind: kind)
            if approval.agentID != nil {
                AgentsChip(text: "subagent", systemImage: "person.2.fill", tint: Color.secondary)
            }
            if !verified {
                AgentsChip(text: "unverified", systemImage: "questionmark.circle.fill", tint: AgentsTheme.attention)
            }
            Spacer(minLength: 6)
            HStack(spacing: 3) {
                Image(systemName: "timer").font(.system(size: 9.5, weight: .semibold))
                Text(verbatim: AgentsFormat.countdown(remaining: remaining))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(urgent ? AgentsTheme.danger : Color.secondary)
            .accessibilityLabel("Expires in \(max(0, Int(remaining.rounded(.up)))) seconds")
        }
    }

    private var summaryRow: some View {
        HStack(spacing: 7) {
            Text(verbatim: approval.tool)
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(AgentsTheme.attention)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .agentsInset(tint: AgentsTheme.attention, shape: .rounded(AgentsTheme.chipRadius))
                .fixedSize()
            Text(verbatim: AgentsFormat.oneLine(approval.summary))
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if hasDetail {
                Button(action: onToggleDetail) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .frame(width: AgentsTheme.minTarget, height: AgentsTheme.minTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Hide details" : "Show details")
            }
        }
    }

    private func detailBox(_ detail: String) -> some View {
        ScrollView(.vertical) {
            Text(verbatim: detail)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 84)
        .environment(\.layoutDirection, .leftToRight)     // code reads left to right even in RTL locales
        .background(AgentsTheme.codeFill, in: RoundedRectangle(cornerRadius: AgentsTheme.innerRadius, style: .continuous))
        .accessibilityLabel("Details: \(detail)")
    }

    private var actionRow: some View {
        // Never wire Return/Space to Allow: the approve buttons are not keyboard-focusable and carry no default action.
        ViewThatFits(in: .horizontal) {
            actionRow(allow: "Allow once", terminal: "Let terminal decide", more: true)
            actionRow(allow: "Allow", terminal: "Terminal", more: false)
        }
    }

    private func actionRow(allow: String, terminal: String, more: Bool) -> some View {
        HStack(spacing: 8) {
            Button(allow) { onDecide(.allowOnce) }
                .buttonStyle(AgentsButtonStyle(kind: .primary, prominentTint: Color(red: 0.16, green: 0.62, blue: 0.36)))
                .focusable(false)
                .help("Approve this single tool call")
                .accessibilityHint("Approves this single tool call")
            Button("Deny") { onDecide(.deny(message: nil)) }
                .buttonStyle(AgentsButtonStyle(kind: .destructive))
                .help("Deny this tool call")
            Button(terminal) { onDecide(.letTerminalDecide) }
                .buttonStyle(AgentsButtonStyle(kind: .quiet))
                .help("Close this card; the agent shows its own prompt")
                .accessibilityHint("Closes this card; the agent shows its own prompt")
            Spacer(minLength: 4)
            if more && !approval.suggestions.isEmpty {
                AgentsMenu {
                    ForEach(approval.suggestions) { s in
                        Button { onRequestAlways(s) } label: { Text(verbatim: s.label + "…") }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                        .padding(.horizontal, 8)
                        .frame(minHeight: AgentsTheme.minTarget)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More options, including Always allow")
                .accessibilityLabel("More options: always allow")
            }
        }
    }

    private func confirmRow(_ s: PermissionSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: (s.label.lowercased().hasPrefix("always") ? s.label : "Always allow: " + s.label) + "?")
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(2)
            Text("This saves a permission rule in the agent's own settings, so it stops asking for this. You can remove it there later.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Always allow") { onDecide(.allowAlways(suggestionIndex: s.id)) }
                    .buttonStyle(AgentsButtonStyle(kind: .primary, prominentTint: AgentsTheme.attention))
                    .focusable(false)
                Button("Cancel", action: onCancelAlways).buttonStyle(AgentsButtonStyle(kind: .quiet))
            }
        }
    }

    private var unverifiedRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text("Not a verified live session, so Toplet will not approve for it. Answer in the terminal.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Let terminal decide") { onDecide(.letTerminalDecide) }
                .buttonStyle(AgentsButtonStyle(kind: .quiet))
        }
    }

    private var countdownBar: some View {
        let color = urgent ? AgentsTheme.danger : AgentsTheme.attention
        return Capsule(style: .continuous)
            .fill(Color.white.opacity(0.10))
            .frame(height: 3)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule(style: .continuous).fill(color.opacity(0.9)).frame(width: geo.size.width * fraction)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        "Approval needed. \(kind.displayName), \(project). \(approval.tool): \(AgentsFormat.oneLine(approval.summary)). "
            + (verified ? "" : "Unverified session. ")
            + "Expires in \(max(0, Int(remaining.rounded(.up)))) seconds."
    }
}
