import Foundation
import Defaults

/// One plan limit as the user reads it: a plain title plus how much of it is used.
struct UsageLimitRow: Equatable, Identifiable {
    let title: String
    /// Short form for tight spaces such as the strip pinned under the closed notch.
    let shortTitle: String
    let limit: UsageLimit
    var id: String { title }
}

enum UsagePercentStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case used, left
    var id: String { rawValue }
    var displayName: String { self == .used ? "Used" : "Left" }
}

/// Wording for plan limits, kept in step with the Claude app's usage panel:
/// "Session limit", "Weekly · all models", "Resets in 1 hr 45 min", "Resets Wed 4:30 AM", "47%".
enum UsageLimitWording {
    /// Under a day away a countdown ("Resets in 1 hr 45 min", "Resets in 12 min"); within a week the
    /// weekday and time ("Resets Wed 4:30 AM"); further out the date ("Resets Nov 3").
    /// nil once the reset has passed: the next refresh brings the new window.
    static func reset(_ date: Date?, now: Date = Date(), locale: Locale = .autoupdatingCurrent,
                      calendar: Calendar = .autoupdatingCurrent) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        if seconds < 86_400 {
            return "Resets in " + duration(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(seconds < 7 * 86_400 ? "EEEjmm" : "MMMd")
        return "Resets " + formatter.string(from: date)
    }

    /// "1 hr 45 min", "2 hr", "12 min". Rounded up so a reset never reads "0 min" while still ahead.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    /// Whole percentage: "47%" used by default, as the Claude app shows it, or "53% left".
    static func percent(_ limit: UsageLimit, style: UsagePercentStyle) -> String {
        let used = Int((limit.fraction * 100).rounded())
        return style == .used ? "\(used)%" : "\(max(0, 100 - used))% left"
    }

    /// The limits a provider's card shows, in display order.
    static func rows(for provider: ProviderID, snapshot: UsageSnapshot, antigravityPool: String = "gemini") -> [UsageLimitRow] {
        switch provider {
        case .cursor:
            // Cursor meters a monthly billing cycle, not a 5-hour session.
            return [
                snapshot.sessionLimit.map { UsageLimitRow(title: "Monthly · Cursor models", shortTitle: "Cursor", limit: $0) },
                snapshot.weekLimit.map { UsageLimitRow(title: "Monthly · other models", shortTitle: "Other", limit: $0) },
            ].compactMap { $0 }
        case .antigravity:
            // Antigravity reports the fraction *remaining* per pool in costUSD; turn it into percent used.
            func limit(_ name: String) -> UsageLimit? {
                guard let model = snapshot.models.first(where: { $0.model == name && $0.pool == antigravityPool }) else { return nil }
                let remaining = max(0, min(1, model.totals.costUSD))
                return UsageLimit(used: (1 - remaining) * 100, limit: 100, resetsAt: model.resetsAt)
            }
            return [
                limit("Session").map { UsageLimitRow(title: "Session limit", shortTitle: "Session", limit: $0) },
                limit("Weekly").map { UsageLimitRow(title: "Weekly · all models", shortTitle: "Weekly", limit: $0) },
            ].compactMap { $0 }
        case .claude, .codex, .newAPI:
            return [
                snapshot.sessionLimit.map { UsageLimitRow(title: "Session limit", shortTitle: "Session", limit: $0) },
                snapshot.weekLimit.map { UsageLimitRow(title: "Weekly · all models", shortTitle: "Weekly", limit: $0) },
            ].compactMap { $0 } + snapshot.modelLimits
        }
    }
}
