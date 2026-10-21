// Tests for the ShipMood rules (run by tests/pure/run.sh).
import Foundation
var failures = 0
func eq<T: Equatable>(_ a: T, _ b: T, _ msg: String, _ line: Int = #line) { if a != b { failures += 1; print("FAIL \(line) \(msg): \(a) != \(b)") } }
var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
let noon = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12))!
let night = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 23, minute: 30))!
func mood(_ s: ShipSignals, _ now: Date = noon) -> ShipMood { ShipBrain.mood(for: s, now: now, calendar: cal) }
eq(mood(ShipSignals()), .idle, "nothing happening")
eq(mood(ShipSignals(), night), .sleeping, "night")
eq(mood(ShipSignals(online: false)), .offline, "offline")
eq(mood(ShipSignals(charging: true)), .charging, "charging")
eq(mood(ShipSignals(musicPlaying: true, charging: true)), .music, "music beats charging")
eq(mood(ShipSignals(musicPlaying: true, timerRunning: true)), .attentive, "timer beats music")
eq(mood(ShipSignals(downloading: true, timerRunning: true)), .sailing, "download beats timer")
eq(mood(ShipSignals(batteryPercent: 10, downloading: true)), .lowBattery, "low battery beats download")
eq(mood(ShipSignals(charging: true, batteryPercent: 10)), .charging, "low but charging is charging")
eq(mood(ShipSignals(isHovering: true, batteryPercent: 10)), .hover, "hover beats low battery")
eq(mood(ShipSignals(isHovering: true, lastClick: noon - 0.5)), .greeting, "click greets")
eq(mood(ShipSignals(lastClick: noon - 5)), .idle, "greeting expires")
eq(mood(ShipSignals(lastDownloadFinished: noon - 2, lastTimerFinished: noon - 1)), .alert, "timer alert beats celebration")
eq(mood(ShipSignals(lastDownloadFinished: noon - 2)), .celebrating, "celebrate")
eq(mood(ShipSignals(lastDownloadFinished: noon + 10)), .idle, "future dates ignored")
eq(ShipBrain.nextChange(for: ShipSignals(lastClick: noon - 0.2, lastDownloadFinished: noon - 1), now: noon)!.timeIntervalSince(noon).rounded(), 1, "next change = greeting end")
eq(ShipBrain.nextChange(for: ShipSignals(), now: noon) == nil, true, "nothing transient")
eq(ShipMotion.for(.music).adjusted(reduceMotion: true, lowPower: false), .still, "reduce motion freezes")
eq(ShipMotion.for(.music).adjusted(reduceMotion: false, lowPower: true), .still, "low power freezes")
let p = ShipMotion.for(.idle).pose(at: 0); eq(p.dy, 0, "pose at t0")
eq(ShipMotion.still.pose(at: 5).dy, 0, "still never moves")
eq(Set(ShipMood.allCases.map(\.title)).count, ShipMood.allCases.count, "unique titles")
print(failures == 0 ? "ALL PASS" : "\(failures) FAILED"); exit(failures == 0 ? 0 : 1)
