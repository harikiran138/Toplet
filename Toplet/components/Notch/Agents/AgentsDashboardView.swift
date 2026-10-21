import SwiftUI
import AppKit

/// Installed app assets only; no network logo fetching. Cache both hits and misses.
@MainActor
final class AgentAppIcons {
    static let shared = AgentAppIcons()
    private var hits: [String: NSImage] = [:]
    private var misses: Set<String> = []
    func icon(_ bundle: String) -> NSImage? {
        if let image = hits[bundle] { return image }
        guard !misses.contains(bundle) else { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { misses.insert(bundle); return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        hits[bundle] = image
        return image
    }
}

struct AgentAppIdentity: View {
    let kind: AgentKind
    var hostBundleID: String?
    var body: some View {
        let bundle = kind == .claudeCode ? "com.anthropic.claudefordesktop" : "com.openai.codex"
        Group {
            if let image = AgentAppIcons.shared.icon(bundle) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: AgentsTheme.symbol(for: kind)).resizable().scaledToFit()
                    .padding(4).foregroundStyle(AgentsTheme.color(for: kind))
            }
        }
        .frame(width: 23, height: 23)
        .accessibilityLabel(kind.displayName)
        .help(kind.displayName + (hostBundleID.map { " · \($0)" } ?? ""))
    }
}

enum AgentsDashboardTab: String, CaseIterable, Identifiable {
    // Games moved to their own notch tab (NotchGamesView) so a game no longer competes with agent activity.
    case activity = "Activity", usage = "Usage", alerts = "Alerts", focus = "Focus"
    var id: String { rawValue }
}

struct AgentsDashboardView: View {
    @ObservedObject var center: AgentCenter
    @ObservedObject var ui: AgentsUIState
    let now: Date
    var onRefreshUsage: () -> Void = {}
    @Environment(\.agentsMotion) private var motion

    private var selectedKind: AgentKind? { ui.selectedUsageKind }
    private var windowHours: Int { ui.usageWindowHours }
    private var focusTimer: AgentFocusTimer { center.focusTimer }
    private var summary: AgentActivitySummary { .make(center.sessions) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Agents view", selection: $ui.dashboardTab) {
                ForEach(AgentsDashboardTab.allCases) { item in Text(item.rawValue).tag(item) }
            }.pickerStyle(.segmented).labelsHidden()
            switch ui.dashboardTab {
            case .activity: overview
            case .usage: usage
            case .alerts: alerts
            case .focus: focus
            }
        }
    }
    private func metric(_ title: String, _ value: String, _ symbol: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(color)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(9).agentsInset()
    }
    private func activityMetric(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(color)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(6).agentsInset()
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Narrow notches (minimalistic UI, Dynamic Island style on external displays) get a 2 x 2 grid instead of
            // four squeezed cards.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { metricCards }
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow { workingMetric; needsYouMetric }
                    GridRow { idleMetric; tasksMetric }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    activityStatus
                    Spacer(minLength: 0)
                    subagentsLine
                }
                VStack(alignment: .leading, spacing: 3) {
                    activityStatus
                    subagentsLine
                }
            }
        }.padding(8).agentsGlass()
    }
    private var workingMetric: some View { activityMetric("Working", "\(summary.running)", AgentsTheme.success) }
    private var needsYouMetric: some View { activityMetric("Needs you", "\(summary.waiting)", AgentsTheme.attention) }
    private var idleMetric: some View { activityMetric("Idle", "\(summary.idle)", .secondary) }
    private var tasksMetric: some View {
        activityMetric("Tasks done", "\(summary.tasksDone)/\(summary.tasksTotal)", .primary)
            .help("Discovered session checklists; cancelled tasks are excluded")
    }
    @ViewBuilder private var metricCards: some View { workingMetric; needsYouMetric; idleMetric; tasksMetric }
    private var activityStatus: some View {
        HStack(spacing: 6) {
            Image(systemName: activitySymbol).foregroundStyle(activityColor)
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
            Text(activityTitle).font(.system(size: 11, weight: .medium)).lineLimit(1).fixedSize()
            if let since = center.sessions.filter({ $0.status == .running || $0.status == .starting }).map(\.statusSince).min() {
                Text(AgentsFormat.elapsed(since: since, now: now)).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
    private var subagentsLine: some View {
        Text("Subagents: \(summary.subagentsRunning) working · \(summary.subagentsIdle) idle · \(summary.subagentsWaiting) waiting")
            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
    }
    private var activitySymbol: String {
        if summary.waiting > 0 { return "hand.raised.fill" }
        if summary.failed > 0 { return "exclamationmark.triangle.fill" }
        if summary.running > 0 { return "waveform.path" }
        if summary.finished > 0 { return "checkmark.seal.fill" }
        return "moon.stars.fill"
    }
    private var activityColor: Color {
        summary.waiting > 0 ? AgentsTheme.attention : summary.failed > 0 ? AgentsTheme.danger : summary.running > 0 ? AgentsTheme.success : .secondary
    }
    private var activityTitle: String {
        if summary.waiting > 0 { return "An agent needs your attention" }
        if summary.failed > 0 { return "\(summary.failed) session(s) need review" }
        if summary.running > 0 { return "Your agents are working" }
        return "All quiet · take a breath"
    }
    private func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return String(n)
    }
    private var usage: some View {
        let report = center.usageReport
        let start = windowHours == 0 ? Calendar.current.startOfDay(for: now) : now.addingTimeInterval(-Double(windowHours) * 3600)
        let total = report.totals(since: start, until: now, kind: selectedKind)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Provider", selection: $ui.selectedUsageKind) {
                    Text("All agents").tag(nil as AgentKind?)
                    ForEach(AgentKind.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                }.labelsHidden().frame(maxWidth: 180)
                Spacer()
                Picker("Usage period", selection: $ui.usageWindowHours) {
                    Text("Last hour").tag(1)
                    Text("Today").tag(0)
                    Text("24 hours").tag(24)
                    Text("7 days").tag(168)
                }.labelsHidden().frame(maxWidth: 180)
            }
            HStack(spacing: 6) {
                metric("Tokens", compact(total.total), "number", .primary)
                metric("Input", compact(total.input), "arrow.down", .primary)
                metric("Output", compact(total.output), "arrow.up", .primary)
                metric("Cache", compact(total.cacheRead + total.cacheWrite), "internaldrive", .secondary)
            }
            hourlyChart(report)
            quotaCards
            Button("Refresh limits", action: onRefreshUsage).font(.system(size: 10))
            Text(report.indexing ? "Indexing local history… totals are partial." : "Local Claude Code + Codex logs · rolling windows · includes cache reads and writes")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if let issue = report.issue { Text(issue).font(.system(size: 10)).foregroundStyle(AgentsTheme.attention) }
            if report.records.isEmpty && !report.indexing {
                Text("No recorded usage yet. Make an API request in Claude Code or Codex, then history refreshes automatically.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            let projects = Dictionary(grouping: report.records.filter { $0.at >= start && $0.at <= now && (selectedKind == nil || $0.kind == selectedKind) }, by: \.project)
            ForEach(projects.keys.sorted { tokenCount(projects[$0]!) > tokenCount(projects[$1]!) }.prefix(5), id: \.self) { project in
                HStack {
                    Label(project, systemImage: "folder").lineLimit(1)
                    Spacer()
                    Text(compact(tokenCount(projects[project]!)) + " tokens").monospacedDigit()
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("Context percentage and plan limits are separate from tokens consumed. Log totals cover this Mac; they are not an account-wide bill.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(12).agentsGlass()
    }
    private var quotaCards: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(center.quotaReadings.filter { selectedKind == nil || $0.kind == selectedKind }) { reading in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        AgentAppIdentity(kind: reading.kind)
                        Text(reading.kind.displayName).font(.system(size: 11, weight: .semibold))
                        Spacer()
                        if let cost = reading.todayEstimatedCost {
                            Text(String(format: "Today ≈ $%.2f", cost)).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    quotaRow("Session limit", reading.fiveHourPercent, reading.fiveHourReset)
                    quotaRow("Weekly · all models", reading.sevenDayPercent, reading.sevenDayReset)
                    Text(usageAge(reading.observedAt))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }.padding(8).agentsInset()
            }
        }
    }
    private func usageAge(_ date: Date) -> String {
        let age = AgentsFormat.coarse(since: date, now: now)
        return age == "now" ? "Provider snapshot · updated just now" : "Provider snapshot · updated \(age) ago"
    }
    /// Worded like the Claude app: "Resets in 1 hr 45 min" under a day away, else "Resets Wed 4:30 AM".
    private func resetLabel(_ reset: Date) -> String {
        let remaining = reset.timeIntervalSince(now)
        guard remaining >= 86_400 else {
            let minutes = max(1, Int((remaining / 60).rounded(.up)))
            if minutes < 60 { return "Resets in \(minutes) min" }
            return minutes % 60 == 0 ? "Resets in \(minutes / 60) hr" : "Resets in \(minutes / 60) hr \(minutes % 60) min"
        }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(remaining < 7 * 86_400 ? "EEEjmm" : "MMMd")
        return "Resets " + formatter.string(from: reset)
    }
    @ViewBuilder private func quotaRow(_ title: String, _ percentage: Double?, _ reset: Date?) -> some View {
        if let percentage, percentage.isFinite {
            let expired = reset.map { $0 <= now } ?? false
            HStack {
                Text(title)
                Spacer()
                if let reset, reset > now {
                    Text(resetLabel(reset)).foregroundStyle(.secondary)
                }
                Text(expired ? "Awaiting refresh" : "\(Int(min(100, max(0, percentage)).rounded()))%")
            }.font(.system(size: 10)).monospacedDigit()
            if !expired { ProgressView(value: min(100, max(0, percentage)), total: 100).tint(percentage >= 85 ? AgentsTheme.attention : AgentsTheme.success) }
        }
    }

    private func tokenCount(_ records: [AgentUsageRecord]) -> Int { records.reduce(0) { $0 + $1.tokens.total } }
    private func hourlyChart(_ report: AgentUsageReport) -> some View {
        let count = windowHours == 1 ? 12 : 24
        let span = windowHours == 0 ? max(1, now.timeIntervalSince(Calendar.current.startOfDay(for: now))) : Double(windowHours) * 3600
        let step = span / Double(count)
        var values = Array(repeating: 0, count: count)
        let beginning = now.addingTimeInterval(-span)
        for record in report.records where record.at >= beginning && record.at <= now && (selectedKind == nil || record.kind == selectedKind) {
            let index = min(count - 1, Int(record.at.timeIntervalSince(beginning) / step))
            values[index] += record.tokens.total
        }
        let peak = max(1, values.max() ?? 1)
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(values.indices, id: \.self) { i in
                RoundedRectangle(cornerRadius: 3).fill(AgentsTheme.color(for: selectedKind ?? .claudeCode).opacity(values[i] == 0 ? 0.15 : 0.85))
                    .frame(maxWidth: .infinity).frame(height: max(3, 40 * CGFloat(values[i]) / CGFloat(peak)))
                    .help("\(values[i]) tokens")
            }
        }.frame(height: 40, alignment: .bottom)
        .accessibilityElement(children: .ignore).accessibilityLabel("Usage trend, oldest to newest")
        .accessibilityValue("\(values.filter { $0 > 0 }.count) active intervals; peak \(peak) tokens")
    }
    private var alerts: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Agent updates", systemImage: "bell.badge.fill").font(.headline)
                Spacer()
                Button("Clear") { center.activityNotices = [] }.disabled(center.activityNotices.isEmpty)
            }
            if center.activityNotices.isEmpty {
                Text("New attention requests, failed sessions and finished turns appear here. No conversation content is stored.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(center.activityNotices) { notice in
                Button { center.jump(to: notice.key) } label: {
                    HStack(spacing: 8) {
                        AgentAppIdentity(kind: notice.key.kind)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(notice.title).font(.system(size: 11, weight: .semibold))
                            Text(notice.project + " · " + notice.key.kind.displayName).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(notice.category.rawValue).font(.system(size: 10)).foregroundStyle(notice.category == .needsYou ? AgentsTheme.attention : Color.secondary)
                        Text(AgentsFormat.coarse(since: notice.at, now: now)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(8).agentsInset()
                }.buttonStyle(.plain).help("Open the source session")
            }
            Text("Last 50 observed transitions · this run only · other apps require a supported integration")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }.padding(12).agentsGlass()
    }

    private var focus: some View {
        let remaining = focusTimer.remaining(at: now)
        return VStack(spacing: 10) {
            Image(systemName: focusTimer.finished(at: now) ? "checkmark.seal.fill" : "timer")
                .font(.system(size: 24)).foregroundStyle(AgentsTheme.success)
            Text(focusTimer.finished(at: now) ? "Focus complete" : AgentsFormat.countdown(remaining: remaining))
                .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
            Text("Focus while your agents work. The timer continues when this tab closes.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                ForEach([15, 25, 50], id: \.self) { minutes in
                    Button("\(minutes)m") { center.focusTimer.reset(minutes: minutes) }.disabled(focusTimer.deadline != nil)
                }
                Spacer()
                Button("Reset") { center.focusTimer.reset() }
                Button(focusTimer.deadline == nil ? "Start" : "Pause") {
                    if focusTimer.deadline == nil { if focusTimer.finished(at: now) { center.focusTimer.reset() }; center.focusTimer.start(at: now) }
                    else { center.focusTimer.pause(at: now) }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(14).agentsGlass()
    }
}
