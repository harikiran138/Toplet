// Tests for managers/LLMUsage/UsageLimitWording.swift (run by tests/pure/run.sh).
import Foundation
var failures = 0
func check(_ got: String?, _ want: String?, _ line: Int = #line) { let got = got?.replacingOccurrences(of: "\u{202F}", with: " "); if got != want { failures += 1; print("FAIL line \(line): got \(got ?? "nil") want \(want ?? "nil")") } }
let en = Locale(identifier: "en_US")
var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 14, minute: 45))! // Wed
func r(_ s: TimeInterval) -> String? { UsageLimitWording.reset(now.addingTimeInterval(s), now: now, locale: en, calendar: cal) }
check(r(105 * 60), "Resets in 1 hr 45 min")
check(r(104 * 60 + 30), "Resets in 1 hr 45 min")   // rounds up, never "0 min"
check(r(2 * 3600), "Resets in 2 hr")
check(r(12 * 60), "Resets in 12 min")
check(r(10), "Resets in 1 min")
check(r(0), nil); check(r(-60), nil)
check(UsageLimitWording.reset(nil, now: now), nil)
let wedNext = cal.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 4, minute: 30))!
check(UsageLimitWording.reset(wedNext, now: now, locale: en, calendar: cal), "Resets Wed 4:30 AM")
let far = cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 9))!
check(UsageLimitWording.reset(far, now: now, locale: en, calendar: cal), "Resets Nov 3")
check(UsageLimitWording.percent(UsageLimit(used: 47, limit: 100), style: .used), "47%")
check(UsageLimitWording.percent(UsageLimit(used: 47, limit: 100), style: .left), "53% left")
check(UsageLimitWording.percent(UsageLimit(used: 140, limit: 100), style: .left), "0% left")
var snap = UsageSnapshot()
snap.sessionLimit = UsageLimit(used: 47, limit: 100); snap.weekLimit = UsageLimit(used: 18, limit: 100)
snap.modelLimits = [UsageLimitRow(title: "Weekly · Sonnet only", shortTitle: "Sonnet", limit: UsageLimit(used: 5, limit: 100))]
check(UsageLimitWording.rows(for: .claude, snapshot: snap).map(\.title).joined(separator: "|"), "Session limit|Weekly · all models|Weekly · Sonnet only")
check(UsageLimitWording.rows(for: .cursor, snapshot: snap).map(\.title).joined(separator: "|"), "Monthly · Cursor models|Monthly · other models")
var ag = UsageSnapshot()
ag.models = [ModelUsage(model: "Session", totals: UsageTotals(costUSD: 0.75, isPercentage: true), pool: "gemini"),
             ModelUsage(model: "Weekly", totals: UsageTotals(costUSD: 0.2, isPercentage: true), pool: "claude")]
let g = UsageLimitWording.rows(for: .antigravity, snapshot: ag)
check(g.map { "\($0.title)=\(UsageLimitWording.percent($0.limit, style: .used))" }.joined(), "Session limit=25%")
check(UsageLimitWording.rows(for: .antigravity, snapshot: ag, antigravityPool: "claude").map { UsageLimitWording.percent($0.limit, style: .used) }.joined(), "80%")
check(UsageLimitWording.rows(for: .claude, snapshot: UsageSnapshot()).isEmpty ? "empty" : "rows", "empty")
print(failures == 0 ? "ALL PASS" : "\(failures) FAILED"); exit(failures == 0 ? 0 : 1)
