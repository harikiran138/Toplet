// Tests for the ClockRules rules (run by tests/pure/run.sh).
import Foundation
var failures = 0
func check(_ got: String?, _ want: String?, _ line: Int = #line) { let g = got?.replacingOccurrences(of: "\u{202F}", with: " "); if g != want { failures += 1; print("FAIL \(line): got \(g ?? "nil") want \(want ?? "nil")") } }
let en = Locale(identifier: "en_US"), gb = Locale(identifier: "en_GB")
let ist = TimeZone(identifier: "Asia/Kolkata")!
var cal = Calendar(identifier: .gregorian); cal.timeZone = ist; cal.locale = en
let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 16, minute: 30))! // Wed
check(ClockHourFormat.twelveHour.string(from: now, timeZone: ist, locale: gb), "4:30 pm")
check(ClockHourFormat.twelveHour.string(from: now, timeZone: ist, locale: en), "4:30 PM")
check(ClockHourFormat.twentyFourHour.string(from: now, timeZone: ist, locale: en), "16:30")
check(ClockHourFormat.system.string(from: now, timeZone: ist, locale: gb), "16:30")
check(ClockHourFormat.twentyFourHour.string(hour: 7, minute: 5, locale: en), "07:05")
check(ClockHourFormat.twelveHour.string(hour: 0, minute: 0, locale: en), "12:00 AM")
func fmt(_ d: Date?) -> String? { d.map { let f = DateFormatter(); f.locale = en; f.timeZone = ist; f.dateFormat = "EEE d HH:mm"; return f.string(from: $0) } }
check(fmt(NotchAlarm(hour: 7, minute: 0).nextFire(after: now, calendar: cal)), "Thu 22 07:00")
check(fmt(NotchAlarm(hour: 17, minute: 0).nextFire(after: now, calendar: cal)), "Wed 21 17:00")
check(fmt(NotchAlarm(hour: 16, minute: 30).nextFire(after: now, calendar: cal)), "Thu 22 16:30") // strictly after
check(fmt(NotchAlarm(hour: 9, minute: 0, repeatDays: [2, 3, 4, 5, 6]).nextFire(after: cal.date(byAdding: .day, value: 2, to: now)!, calendar: cal)), "Mon 26 09:00") // Fri 16:30 -> Mon
check(fmt(NotchAlarm(hour: 9, minute: 0, isEnabled: false).nextFire(after: now, calendar: cal)), nil)
check(NotchAlarm(hour: 9, minute: 0, repeatDays: Set(1...7)).repeatSummary, "Every day")
check(NotchAlarm(hour: 9, minute: 0, repeatDays: [2,3,4,5,6]).repeatSummary, "Weekdays")
check(NotchAlarm(hour: 9, minute: 0, repeatDays: [1, 7]).repeatSummary, "Weekends")
check(NotchAlarm(hour: 9, minute: 0).repeatSummary, "Once")
check(WorldClockLabel.city("America/New_York"), "New York")
check(WorldClockLabel.relative(TimeZone(identifier: "Asia/Tokyo")!, now: now, here: ist), "Today, +3:30")
check(WorldClockLabel.relative(TimeZone(identifier: "Pacific/Auckland")!, now: now, here: ist), "Tomorrow, +7:30")
check(WorldClockLabel.relative(TimeZone(identifier: "America/Los_Angeles")!, now: now, here: ist), "Today, −12:30")
check(WorldClockLabel.relative(ist, now: now, here: ist), "Same time")
print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
