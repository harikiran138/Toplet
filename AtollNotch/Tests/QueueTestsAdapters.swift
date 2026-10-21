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
#if canImport(UserNotifications)
import UserNotifications
#endif

// Adapters: agents, extensions, EventKit stubs, and Atoll's own UNUserNotificationCenter bridge. Everything runs on fakes:
// no EventKit, no UserNotifications center, no AtollAgents module.

@MainActor
final class QBox {
    var q: NotificationQueue
    let clock = FakeClock()
    var emitted: [NotchNotification] = []
    init(_ f: (inout NotificationSettings) -> Void = { _ in }, focus: Bool = false) { q = mkQ(focus: focus, f) }
    func emit(_ n: NotchNotification) -> NotificationQueue.Decision { emitted.append(n); return q.accept(n, now: clock.read()) }
}

@MainActor
final class FakeCalendarProvider: CalendarAlertProviding {
    var onAlert: ((CalendarAlert) -> Void)?
    var starts = 0, stops = 0
    func start() { starts += 1 }
    func stop() { stops += 1 }
}

@MainActor
final class FakeReminderProvider: ReminderAlertProviding {
    var onAlert: ((ReminderAlert) -> Void)?
    var starts = 0, stops = 0
    func start() { starts += 1 }
    func stop() { stops += 1 }
}

@MainActor
final class FakeSystemProvider: SystemNotificationCenterProviding {
    var handler: SystemNotificationHandling?
    var installs = 0
    var requests = 0
    var result = SystemAuthorizationResult(granted: true, errorDescription: nil, at: Date(timeIntervalSince1970: 42))
    func install(handler: SystemNotificationHandling?) { installs += 1; self.handler = handler }
    func requestAuthorization(_ completion: @escaping @MainActor (SystemAuthorizationResult) -> Void) { requests += 1; completion(result) }
}

private func isShown(_ d: NotificationQueue.Decision?) -> Bool { if let d = d, case .shown = d { return true }; return false }
private func isDeduped(_ d: NotificationQueue.Decision?) -> Bool { if let d = d, case .deduped = d { return true }; return false }
private func isQueued(_ d: NotificationQueue.Decision?) -> Bool { if let d = d, case .queued = d { return true }; return false }

@MainActor
func runAdapterTests() async {
    section("Agent adapter: mapping")
    do {
        let box = QBox()
        let a = AgentNotificationAdapter(source: .agentClaude, now: box.clock.read)
        check(a.handle(AgentNotificationEvent(sessionID: "s1", project: "p", kind: .finished)) == nil, "not started: nothing is emitted")
        check(a.observe(sessionID: "s1", project: "p", from: .running, to: .done) == nil, "not started: observe emits nothing")
        a.start(emit: box.emit)
        check(a.isStarted, "started")
        _ = a.handle(AgentNotificationEvent(sessionID: "s1", project: "myproj", kind: .needsPermission, detail: "Bash: npm test"))
        let n = box.emitted.last!
        eq(n.title, "Claude Code needs permission in myproj", "needs-permission title")
        check(n.priority == .high && n.iconSymbol == "hand.raised.fill" && n.source == .agentClaude && n.appName == "Claude Code", "needs-permission: high priority, symbol, source, app")
        eq(n.action, .openAgentSession("s1"), "needs-permission links to the agent session")
        check(n.dedupeKey == "agent|s1" && n.threadID == "s1" && n.body == "Bash: npm test", "dedupe key per session, thread, body is the detail")
        let fin = a.notification(for: AgentNotificationEvent(sessionID: "s1", project: "myproj", kind: .finished))
        check(fin.title == "Claude Code finished in myproj" && fin.priority == .normal && fin.iconSymbol == "checkmark.circle.fill", "finished")
        let fail = a.notification(for: AgentNotificationEvent(sessionID: "s1", project: "myproj", kind: .failed, detail: "exit 1"))
        check(fail.title == "Claude Code failed in myproj" && fail.priority == .high && fail.iconSymbol == "exclamationmark.triangle.fill", "failed")
        let inp = a.notification(for: AgentNotificationEvent(sessionID: "s1", project: "myproj", kind: .needsInput))
        check(inp.title == "Claude Code is waiting for you in myproj" && inp.priority == .normal, "needs input")
        let cx = AgentNotificationAdapter(source: .agentCodex, now: box.clock.read)
        let cn = cx.notification(for: AgentNotificationEvent(sessionID: "c1", project: "repo", kind: .finished))
        check(cn.title == "Codex finished in repo" && cn.source == .agentCodex && cn.appName == "Codex", "the Codex adapter names Codex")
        eq(a.notification(for: AgentNotificationEvent(sessionID: "s", project: "my\u{202E}pr\u{200B}oj", kind: .finished)).title, "Claude Code finished in myproj", "bidi/zero-width in the project name is stripped")
        eq(a.notification(for: AgentNotificationEvent(sessionID: "s", project: "  ", kind: .finished)).title, "Claude Code finished in a project", "empty project name has a fallback")
        check(a.notification(for: AgentNotificationEvent(sessionID: "s", project: String(repeating: "p", count: 200), kind: .finished)).title.count <= "Claude Code finished in ".count + 40, "long project names are bounded")
        a.stop()
        check(!a.isStarted && a.handle(AgentNotificationEvent(sessionID: "s", project: "p", kind: .failed)) == nil, "stopped: nothing is emitted")
    }
    section("Agent adapter: status transitions")
    do {
        let table: [(AgentActivity, AgentActivity, AgentNotificationEvent.Kind?)] = [
            (.running, .needsPermission, .needsPermission), (.idle, .needsPermission, .needsPermission), (.running, .waitingInput, .needsInput),
            (.running, .done, .finished), (.starting, .done, .finished), (.needsPermission, .done, .finished), (.waitingInput, .done, .finished),
            (.idle, .done, nil), (.done, .done, nil), (.stopped, .done, nil), (.unknown, .done, nil),
            (.running, .failed, .failed), (.idle, .failed, .failed), (.failed, .failed, nil),
            (.running, .idle, nil), (.running, .stopped, nil), (.unknown, .running, nil), (.idle, .running, nil), (.running, .starting, nil),
        ]
        for (o, n, kind) in table {
            let box = QBox()
            let a = AgentNotificationAdapter(source: .agentClaude, now: box.clock.read)
            a.start(emit: box.emit)
            let d = a.observe(sessionID: "s", project: "p", from: o, to: n)
            if let kind = kind {
                let want = a.notification(for: AgentNotificationEvent(sessionID: "s", project: "p", kind: kind)).title
                check(d != nil && box.emitted.last?.title == want, "\(o.rawValue) -> \(n.rawValue) emits \"\(kind)\"")
            } else {
                check(d == nil && box.emitted.isEmpty, "\(o.rawValue) -> \(n.rawValue) emits nothing")
            }
        }
    }
    section("Agent adapter: through the queue")
    do {
        let box = QBox()
        let a = AgentNotificationAdapter(source: .agentClaude, now: box.clock.read)
        a.start(emit: box.emit)
        check(isShown(a.observe(sessionID: "s1", project: "alpha", from: .running, to: .needsPermission)), "needs permission is shown")
        box.clock.advance(5)
        let d = a.observe(sessionID: "s1", project: "alpha", from: .needsPermission, to: .done)
        check(isDeduped(d), "the same session's next state REPLACES the earlier notification (deduped per session)")
        eq(box.q.current?.display.title ?? "", "Claude Code finished in alpha", "...so the live notification now says finished")
        eq(box.q.queuedCount, 0, "...and nothing stacked")
        box.q.dismissAll(now: box.clock.read())
        let box2 = QBox()
        let b = AgentNotificationAdapter(source: .agentClaude, now: box2.clock.read)
        b.start(emit: box2.emit)
        _ = b.observe(sessionID: "s1", project: "alpha", from: .running, to: .needsPermission)
        check(isQueued(b.observe(sessionID: "s2", project: "beta", from: .running, to: .needsPermission)), "a different session gets its own notification")
        let box3 = QBox { $0.privacyMode = .hidePreview }
        let c = AgentNotificationAdapter(source: .agentClaude, now: box3.clock.read)
        c.start(emit: box3.emit)
        _ = c.observe(sessionID: "s", project: "alpha", from: .running, to: .needsPermission, detail: "rm -rf SECRETPATH7")
        check(box3.q.current?.display.body == nil && !allText(box3.q.current!.display).contains("SECRETPATH7"), "the tool detail is hidden under the default privacy mode")
        eq(box3.q.current?.display.title ?? "", "Claude Code needs permission in alpha", "...while the headline stays visible")
        check(box3.q.current?.display.hasAction == true, "the click action (open the session) survives redaction")
        let box4 = QBox(focus: true)
        let d4 = AgentNotificationAdapter(source: .agentClaude, now: box4.clock.read)
        d4.start(emit: box4.emit)
        let r = d4.observe(sessionID: "s", project: "p", from: .running, to: .needsPermission)
        check({ if let r = r, case .silenced = r { return true }; return false }(), "Focus silences a high (non-critical) agent notification by default")
        let h = CenterHarness()
        let viaCenter = AgentNotificationAdapter(source: .agentClaude, now: h.clock.read)
        h.center.addAdapter(viaCenter)
        _ = viaCenter.observe(sessionID: "s9", project: "gamma", from: .running, to: .failed)
        eq(h.center.current?.title ?? "", "Claude Code failed in gamma", "wired through the facade")
        check(h.center.performAction(h.center.current!.id) && h.log.actions == [.openAgentSession("s9")], "...and clicking it asks for the agent session")
        h.center.settings.enabledSources.remove(.agentClaude)
        check(!viaCenter.isStarted && viaCenter.observe(sessionID: "s", project: "p", from: .running, to: .done) == nil, "switching the agent source off stops the adapter")
    }

    section("Extension adapter: authorisation and identity")
    do {
        let box = QBox()
        let asked = Atomic<[String]>([])
        let allowed = Atomic<Set<String>>(["com.good.app"])
        let ext = AuthorizedExtensionNotificationAdapter(isAuthorized: { id in asked.mutate { $0.append(id) }; return allowed.get().contains(id) }, now: box.clock.read)
        let req = ExtensionNotificationRequest(claimedBundleID: "com.good.app", appName: "Good", title: "Hi", body: "Body", priority: .high, dedupeKey: "k")
        check(ext.receive(req, verifiedBundleID: "com.good.app") == nil, "not started: refused")
        ext.start(emit: box.emit)
        let d = ext.receive(req, verifiedBundleID: "com.good.app")
        check(isShown(d), "authorised and identity matches: shown")
        let n = box.emitted.last!
        check(n.source == .extensionApp && n.bundleID == "com.good.app" && n.appName == "Good" && n.priority == .high, "source, VERIFIED bundle id, app name, priority")
        eq(n.dedupeKey ?? "", "ext|com.good.app|k", "the dedupe key is namespaced by the verified bundle id")
        eq(n.action, .activateApp(bundleID: "com.good.app"), "clicking activates the verified app")
        let before = box.emitted.count
        let spoof = ExtensionNotificationRequest(claimedBundleID: "com.apple.mail", appName: "Mail", title: "Your password expires")
        check(ext.receive(spoof, verifiedBundleID: "com.evil.app") == nil, "a payload claiming another app's identity is refused (spoofing)")
        check(ext.receive(req, verifiedBundleID: "com.evil.app") == nil, "claimed != verified is refused even when the claimed app is authorised")
        allowed.set([])
        check(ext.receive(req, verifiedBundleID: "com.good.app") == nil, "an app without an existing authorisation is refused")
        allowed.set(["com.good.app"])
        check(ext.receive(req, verifiedBundleID: "nodots") == nil, "a malformed verified id is refused")
        let wrong = ExtensionNotificationRequest(claimedBundleID: "nodots", appName: "X", title: "t")
        check(ext.receive(wrong, verifiedBundleID: "nodots") == nil, "a malformed identity is refused on both sides")
        eq(box.emitted.count, before, "nothing from the refused requests was emitted")
        ext.stop()
        check(ext.receive(req, verifiedBundleID: "com.good.app") == nil, "stopped: refused")
        check(asked.get().allSatisfy { $0 == "com.good.app" } && !asked.get().isEmpty, "the authorisation check was only ever asked about verified identities")
        let calls = Atomic(0)
        let ext2 = AuthorizedExtensionNotificationAdapter(isAuthorized: { _ in calls.mutate { $0 += 1 }; return true }, now: box.clock.read)
        ext2.start(emit: box.emit)
        _ = ext2.receive(spoof, verifiedBundleID: "com.evil.app")
        eq(calls.get(), 0, "the authorisation check is never asked about an identity that failed verification")
    }

    section("EventKit adapters (fakes)")
    do {
        let box = QBox()
        let prov = FakeCalendarProvider()
        let cal = CalendarNotificationAdapter(provider: prov, now: box.clock.read)
        cal.start(emit: box.emit)
        eq(prov.starts, 1, "calendar provider started")
        let soon = box.clock.now.addingTimeInterval(30)
        prov.onAlert?(CalendarAlert(eventID: "e1", title: "Standup", start: soon, location: "Room 4", calendarName: "Work"))
        let n = box.emitted.last!
        check(n.title == "Standup" && n.subtitle == "Starting now" && n.body == "Room 4" && n.appName == "Work", "calendar alert fields")
        check(n.source == .calendar && n.iconSymbol == "calendar" && n.priority == .high && n.action == .activateApp(bundleID: "com.apple.iCal"), "calendar: source, symbol, priority high when imminent, action")
        prov.onAlert?(CalendarAlert(eventID: "e2", title: "Later", start: box.clock.now.addingTimeInterval(300)))
        check(box.emitted.last?.priority == .normal && box.emitted.last?.subtitle == "In 5 min" && box.emitted.last?.appName == "Calendar", "a later event is normal priority with a relative time")
        let n0 = box.q.queuedCount + 1
        prov.onAlert?(CalendarAlert(eventID: "e1", title: "Standup", start: soon, location: "Room 4", calendarName: "Work"))
        check(isDeduped(cal.lastDecision), "the same alert delivered twice is deduped")
        prov.onAlert?(CalendarAlert(eventID: "e1", title: "Standup", start: soon.addingTimeInterval(3600), location: "Room 4", calendarName: "Work"))
        check(!isDeduped(cal.lastDecision) && n0 >= 1, "a moved event (new start time) is a new notification")
        cal.stop()
        eq(prov.stops, 1, "calendar provider stopped")
        check(prov.onAlert == nil, "...and unhooked")
        let count = box.emitted.count
        cal.handle(CalendarAlert(eventID: "e9", title: "x", start: Date()))
        eq(box.emitted.count, count, "stopped: alerts are ignored")
        let rbox = QBox()
        let rp = FakeReminderProvider()
        let rem = RemindersNotificationAdapter(provider: rp, now: rbox.clock.read)
        rem.start(emit: rbox.emit)
        rp.onAlert?(ReminderAlert(reminderID: "r1", title: "Call mum", due: rbox.clock.now.addingTimeInterval(120), listName: "Home"))
        let r = rbox.emitted.last!
        check(r.title == "Call mum" && r.appName == "Home" && r.subtitle == "In 2 min" && r.priority == .normal && r.source == .reminders, "reminder fields")
        check(r.iconSymbol == "checklist" && r.action == .activateApp(bundleID: "com.apple.reminders"), "reminder symbol and action")
        rp.onAlert?(ReminderAlert(reminderID: "r2", title: "Pills", due: nil, isCritical: true))
        check(rbox.emitted.last?.priority == .critical && rbox.emitted.last?.subtitle == nil && rbox.emitted.last?.appName == "Reminders", "a critical reminder without a due date")
        rem.stop()
        check(rp.stops == 1 && rp.onAlert == nil, "reminder provider stopped and unhooked")
        let fbox = QBox(focus: true)
        let fp = FakeReminderProvider()
        let fr = RemindersNotificationAdapter(provider: fp, now: fbox.clock.read)
        fr.start(emit: fbox.emit)
        fp.onAlert?(ReminderAlert(reminderID: "r3", title: "normal"))
        check({ if let d = fr.lastDecision, case .silenced = d { return true }; return false }(), "Focus silences a normal reminder")
        fp.onAlert?(ReminderAlert(reminderID: "r4", title: "urgent", isCritical: true))
        check(isShown(fr.lastDecision), "...but a critical reminder still shows")
    }
    section("Relative time phrases")
    do {
        let now = Date(timeIntervalSince1970: 5_000_000)
        func p(_ s: TimeInterval) -> String { NotificationRelativeTime.phrase(from: now, to: now.addingTimeInterval(s)) }
        eq(p(0), "Starting now", "now"); eq(p(59), "Starting now", "59 s ahead"); eq(p(-59), "Starting now", "59 s ago")
        eq(p(60), "In 1 min", "60 s"); eq(p(300), "In 5 min", "5 min"); eq(p(5400), "In 90 min", "90 min")
        eq(p(7200), "In 2 h", "2 h"); eq(p(-180), "Started 3 min ago", "3 min ago"); eq(p(-10800), "Started 3 h ago", "3 h ago")
    }
    section("Toplet's own UNUserNotificationCenter bridge (protocol level)")
    do {
        let box = QBox()
        let prov = FakeSystemProvider()
        let sys = AtollSystemNotificationAdapter(provider: prov, now: box.clock.read)
        eq(sys.source, .atoll, "source is .atoll")
        check(sys.willPresent(SystemNotificationInfo(identifier: "i", title: "t")) == .showSystemBanner, "not started: let macOS show the banner")
        sys.start(emit: box.emit)
        check(prov.handler === sys && prov.installs == 1, "start installs the delegate handler")
        check(prov.requests == 0 && sys.authorizationRequests == 0 && sys.lastAuthorization == nil, "start() never prompts for permission")
        sys.requestAuthorization()
        check(prov.requests == 1 && sys.lastAuthorization?.granted == true && sys.lastAuthorization?.errorDescription == nil, "authorisation result is recorded (the T10 probe)")
        prov.result = SystemAuthorizationResult(granted: false, errorDescription: "Notifications are not allowed", at: Date())
        sys.requestAuthorization()
        check(sys.lastAuthorization?.granted == false && sys.lastAuthorization?.errorDescription == "Notifications are not allowed" && sys.authorizationRequests == 2, "a denial and its error are recorded")
        let info = SystemNotificationInfo(identifier: "id-1", title: "Timer done", subtitle: "Kitchen", body: "Pasta", threadIdentifier: "th", urlString: "https://example.com/t")
        check(sys.willPresent(info) == .suppressBanner, "shown in the notch: the system banner is suppressed")
        let n = box.emitted.last!
        check(n.title == "Timer done" && n.subtitle == "Kitchen" && n.body == "Pasta" && n.appName == "Toplet" && n.source == .atoll && n.threadID == "th", "fields mapped")
        eq(n.action, .openURL(URL(string: "https://example.com/t")!), "a valid atollURL becomes an action")
        eq(n.dedupeKey ?? "", "atoll|id-1", "dedupe by the system notification identifier")
        let curID = box.q.current?.id
        check(sys.willPresent(info) == .suppressBanner && box.q.queuedCount == 0 && box.q.current?.id == curID, "the same identifier again does not stack (deduped, banner still suppressed)")
        eq(sys.notification(for: SystemNotificationInfo(identifier: "x", title: "x", urlString: "javascript:alert(1)")).action, .none, "a javascript: atollURL is dropped")
        eq(sys.notification(for: SystemNotificationInfo(identifier: "x", title: "x", urlString: "not a url")).action, .none, "a malformed atollURL is dropped")
        let fe = AtollSystemNotificationAdapter(provider: FakeSystemProvider(), now: box.clock.read)
        fe.fileExists = { _ in false }
        eq(fe.notification(for: SystemNotificationInfo(identifier: "x", title: "x", urlString: "file:///nope")).action, .none, "a file atollURL to a missing path is dropped")
        let got = Atomic<[String]>([])
        sys.onActivate = { i in got.mutate { $0.append(i.identifier) } }
        sys.didActivate(info)
        eq(got.get(), ["id-1"], "didActivate calls the activation callback with the notification")
        sys.stop()
        check(prov.handler == nil && prov.installs == 2, "stop removes the delegate handler")
        let off = QBox { $0.enabled = false }
        let sys2 = AtollSystemNotificationAdapter(provider: FakeSystemProvider(), now: off.clock.read)
        sys2.start(emit: off.emit)
        check(sys2.willPresent(info) == .showSystemBanner, "notch notifications off: macOS shows its own banner")
        let off2 = QBox { $0.enabledSources = [.cli] }
        let sys3 = AtollSystemNotificationAdapter(provider: FakeSystemProvider(), now: off2.clock.read)
        sys3.start(emit: off2.emit)
        check(sys3.willPresent(info) == .showSystemBanner, "the Toplet source switched off: macOS shows its own banner")
        let lim = QBox { $0.rateLimitPerMinute = 1 }
        let sys4 = AtollSystemNotificationAdapter(provider: FakeSystemProvider(), now: lim.clock.read)
        sys4.start(emit: lim.emit)
        _ = sys4.willPresent(SystemNotificationInfo(identifier: "a", title: "a"))
        check(sys4.willPresent(SystemNotificationInfo(identifier: "b", title: "b")) == .suppressBanner, "rate-limited: still suppressed (a flood must not fall back to banners)")
        let foc = QBox(focus: true)
        let sys5 = AtollSystemNotificationAdapter(provider: FakeSystemProvider(), now: foc.clock.read)
        sys5.start(emit: foc.emit)
        check(sys5.willPresent(info) == .suppressBanner && foc.q.current == nil, "silenced by Focus: no notch, no extra banner")
    }
    #if canImport(UserNotifications)
    do {
        let c = UNMutableNotificationContent()
        c.title = "Hello"; c.subtitle = "Sub"; c.body = "Body"; c.threadIdentifier = "thr"; c.userInfo = ["atollURL": "https://example.com/z"]
        let i = SystemNotificationInfo.make(identifier: "abc", content: c)
        check(i.identifier == "abc" && i.title == "Hello" && i.subtitle == "Sub" && i.body == "Body" && i.threadIdentifier == "thr" && i.urlString == "https://example.com/z", "UNNotificationContent -> SystemNotificationInfo")
        let e = UNMutableNotificationContent()
        e.title = "Only title"; e.userInfo = ["atollURL": 5]
        let j = SystemNotificationInfo.make(identifier: "e", content: e)
        check(j.subtitle == nil && j.body == nil && j.threadIdentifier == nil && j.urlString == nil, "empty fields become nil and a non-string atollURL is ignored")
    }
    #endif
}
