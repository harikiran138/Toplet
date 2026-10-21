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

import Foundation

// Pure clock rules (no SwiftUI, no storage): hour-format choice, alarm recurrence, time zone labels.

/// The app-wide 12/24-hour choice. `.system` follows System Settings › General › Date & Time.
enum ClockHourFormat: String, CaseIterable, Identifiable, Codable {
    case system, twelveHour, twentyFourHour
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "Match System"
        case .twelveHour: return "12-hour (4:30 PM)"
        case .twentyFourHour: return "24-hour (16:30)"
        }
    }

    /// DateFormatter template: "j" lets the locale pick, "h"+"a" forces 12-hour, "H" forces 24-hour.
    func template(seconds: Bool = false) -> String {
        let s = seconds ? "ss" : ""
        switch self {
        case .system: return "jmm" + s
        case .twelveHour: return "hmm" + s + "a"
        case .twentyFourHour: return "HHmm" + s
        }
    }

    func string(from date: Date, timeZone: TimeZone = .autoupdatingCurrent, seconds: Bool = false,
                locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template(seconds: seconds))
        return formatter.string(from: date)
    }

    /// The same formatting for an alarm's hour and minute, which have no date.
    func string(hour: Int, minute: Int, locale: Locale = .autoupdatingCurrent) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour, minute: minute))!
        return string(from: date, timeZone: calendar.timeZone, locale: locale)
    }
}

struct NotchAlarm: Codable, Equatable, Identifiable {
    var id = UUID()
    var hour: Int
    var minute: Int
    var label = ""
    var isEnabled = true
    /// Weekdays it repeats on, Calendar numbering (1 = Sunday … 7 = Saturday). Empty: rings once.
    var repeatDays: Set<Int> = []

    /// The next moment this alarm rings strictly after `date`, or nil when it is switched off.
    func nextFire(after date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        guard isEnabled else { return nil }
        let time = DateComponents(hour: hour, minute: minute, second: 0)
        if repeatDays.isEmpty {
            return calendar.nextDate(after: date, matching: time, matchingPolicy: .nextTime)
        }
        return repeatDays.compactMap { weekday -> Date? in
            var match = time
            match.weekday = weekday
            return calendar.nextDate(after: date, matching: match, matchingPolicy: .nextTime)
        }.min()
    }

    /// "Every day", "Weekdays", "Weekends", "Mon, Wed" or "Once".
    var repeatSummary: String {
        switch repeatDays {
        case []: return "Once"
        case Set(1...7): return "Every day"
        case [2, 3, 4, 5, 6]: return "Weekdays"
        case [1, 7]: return "Weekends"
        default:
            let symbols = Calendar.autoupdatingCurrent.shortWeekdaySymbols
            // Monday-first reading order, as in the Clock app.
            return [2, 3, 4, 5, 6, 7, 1].filter(repeatDays.contains).map { symbols[$0 - 1] }.joined(separator: ", ")
        }
    }
}

enum WorldClockLabel {
    /// "Tokyo" from "Asia/Tokyo", "New York" from "America/New_York".
    static func city(_ identifier: String) -> String {
        (identifier.split(separator: "/").last.map(String.init) ?? identifier).replacingOccurrences(of: "_", with: " ")
    }

    /// Offset from here the way the Clock app reads it: "Today, +3:30", "Tomorrow, +9", "Yesterday, −5", "Same time".
    static func relative(_ zone: TimeZone, now: Date, here: TimeZone = .autoupdatingCurrent) -> String {
        let delta = zone.secondsFromGMT(for: now) - here.secondsFromGMT(for: now)
        var hereCalendar = Calendar(identifier: .gregorian); hereCalendar.timeZone = here
        var thereCalendar = Calendar(identifier: .gregorian); thereCalendar.timeZone = zone
        let hereDay = hereCalendar.dateComponents([.year, .month, .day], from: now)
        let thereDay = thereCalendar.dateComponents([.year, .month, .day], from: now)
        let dayDiff = thereCalendar.dateComponents([.day], from: thereCalendar.date(from: hereDay)!, to: thereCalendar.date(from: thereDay)!).day ?? 0
        let day = dayDiff > 0 ? "Tomorrow" : dayDiff < 0 ? "Yesterday" : "Today"
        guard delta != 0 else { return "Same time" }
        let hours = abs(delta) / 3600, minutes = (abs(delta) % 3600) / 60
        let sign = delta > 0 ? "+" : "−"
        return "\(day), \(sign)\(hours)" + (minutes > 0 ? ":\(String(format: "%02d", minutes))" : "")
    }
}
