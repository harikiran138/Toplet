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
import Darwin

// Facade behaviour with a fake clock and a fake scheduler (no real timers), plus the real socket and the real script going through it.

@MainActor
final class FakeScheduler: NotificationScheduling {
    struct Job { var delay: TimeInterval; var fire: @MainActor () -> Void }
    private(set) var jobs: [Int: Job] = [:]
    private var nextID = 0
    private(set) var scheduledTotal = 0
    private(set) var maxConcurrent = 0
    var lastDelay: TimeInterval?

    func schedule(after delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> () -> Void {
        nextID += 1
        let id = nextID
        jobs[id] = Job(delay: delay, fire: fire)
        scheduledTotal += 1
        lastDelay = delay
        maxConcurrent = Swift.max(maxConcurrent, jobs.count)
        return { [weak self] in MainActor.assumeIsolated { _ = self?.jobs.removeValue(forKey: id) } }
    }

    /// Runs (and removes) every armed job, like the timer firing.
    @discardableResult
    func fireAll() -> Int {
        let js = jobs.sorted { $0.key < $1.key }.map { $0.value }
        jobs.removeAll()
        for j in js { j.fire() }
        return js.count
    }
}

final class CenterLog {
    var presents: [(display: NotificationDisplay, ttl: TimeInterval)] = []
    var retracts: [UUID] = []
    var actions: [NotificationAction] = []
    var persisted: [NotificationSettings] = []
    var focus = false
}

@MainActor
final class CenterHarness {
    let clock = FakeClock()
    let scheduler = FakeScheduler()
    let log = CenterLog()
    let center: NotchNotificationCenter

    init(_ f: (inout NotificationSettings) -> Void = { _ in }, makeIngress: (() -> NotificationIngressServer)? = nil, start: Bool = true) {
        let log = self.log
        center = NotchNotificationCenter(settings: enabledSettings(f), persist: { log.persisted.append($0) }, clock: clock.read, scheduler: scheduler,
                                         isFocusActive: { log.focus }, actionHandler: { log.actions.append($0) }, makeIngress: makeIngress)
        center.onPresent = { d, t in log.presents.append((d, t)) }
        center.onRetract = { log.retracts.append($0) }
        if start { center.start() }
    }

    func advance(_ s: TimeInterval) { clock.advance(s) }
    func tick(_ s: TimeInterval) { clock.advance(s); scheduler.fireAll() }
}

@MainActor
final class FakeAdapter: NotificationAdapter {
    let source: NotificationSource
    var starts = 0, stops = 0
    var emit: ((NotchNotification) -> NotificationQueue.Decision)?
    init(_ s: NotificationSource) { source = s }
    func start(emit: @escaping @MainActor (NotchNotification) -> NotificationQueue.Decision) { starts += 1; self.emit = emit }
    func stop() { stops += 1; emit = nil }
}

private func shown(_ d: NotificationQueue.Decision) -> Bool { if case .shown = d { return true }; return false }
private func queued(_ d: NotificationQueue.Decision) -> Bool { if case .queued = d { return true }; return false }

@MainActor
func runCenterTests() async {
    let baselineFDs = socketFDCount()

    section("Facade: lifecycle and disabled == zero cost")
    do {
        let h = CenterHarness(start: false)
        eq(h.center.present(note("x")), .dropped(.disabled), "before start(): dropped")
        check(h.center.current == nil && !h.center.isRunning && h.scheduler.jobs.isEmpty, "before start(): nothing exists")
        h.center.start(); h.center.start()
        check(h.center.isRunning, "start() is idempotent")
        h.center.stop(); h.center.stop()
        check(!h.center.isRunning, "stop() is idempotent")
        eq(h.center.present(note("x")), .dropped(.disabled), "after stop(): dropped")
        let h2 = CenterHarness { $0.enabled = false }
        eq(h2.center.present(note("x")), .dropped(.disabled), "enabled == false: dropped even when started")
        check(!h2.center.isIngressRunning && h2.scheduler.jobs.isEmpty, "enabled == false: no socket, no timer")
        h2.center.settings.enabled = true
        check(shown(h2.center.present(note("x"))), "flipping enabled on at runtime takes effect without restart")
    }
    section("Facade: present, queue, one timer, expiry")
    do {
        let h = CenterHarness()
        let a = note("A"), b = note("B")
        check(shown(h.center.present(a)), "first is shown")
        eq(h.center.current?.title ?? "", "A", "current is published")
        eq(h.log.presents.count, 1, "onPresent called once")
        eq(h.log.presents.first?.ttl ?? 0, 4, "onPresent carries the TTL (default 4 s)")
        check(h.scheduler.jobs.count == 1 && h.scheduler.lastDelay == 4, "exactly one timer, armed for 4 s")
        check(queued(h.center.present(b)), "second is queued")
        eq(h.center.queuedCount, 1, "queuedCount is published")
        eq(h.scheduler.scheduledTotal, 1, "queueing did not re-arm the timer")
        h.tick(4)
        eq(h.center.current?.title ?? "", "B", "at the deadline the next item is presented")
        eq(h.log.presents.count, 2, "onPresent called for the next item")
        check(h.scheduler.jobs.count == 1 && h.scheduler.lastDelay == 4, "the timer is re-armed for the new item")
        eq(h.center.queuedCount, 0, "queuedCount drops")
        h.tick(4)
        check(h.center.current == nil && h.log.retracts.count == 1, "when nothing is left the arbiter is told to retract")
        eq(h.log.retracts.first ?? UUID(), b.id, "...naming the item")
        check(h.scheduler.jobs.isEmpty && !h.center.hasArmedTimer, "idle: no timer is armed")
        eq(h.center.history.map { $0.display.title }, ["B", "A"], "history is published, newest first")
        h.tick(100)
        check(h.log.presents.count == 2 && h.log.retracts.count == 1, "a stray timer fire when idle changes nothing")
    }
    do {  // early timer fire must not expire anything
        let h = CenterHarness()
        _ = h.center.present(note("A"))
        h.advance(1)
        h.scheduler.fireAll()
        eq(h.center.current?.title ?? "", "A", "a timer that fires early expires nothing")
        check(h.scheduler.jobs.count == 1 && abs((h.scheduler.lastDelay ?? 0) - 3) < 0.001, "...and re-arms for the remaining 3 s")
    }
    section("Facade: hover pauses and resumes the TTL")
    do {
        let h = CenterHarness()
        _ = h.center.present(note("A"))
        h.advance(1)
        h.center.setHovering(true)
        check(h.scheduler.jobs.isEmpty, "hover cancels the timer (no polling while paused)")
        h.advance(100)
        check(h.center.current?.title == "A" && h.scheduler.jobs.isEmpty, "a hovered notification never expires")
        h.center.setHovering(false)
        check(h.scheduler.jobs.count == 1 && abs((h.scheduler.lastDelay ?? 0) - 3) < 0.001, "leaving resumes with the remaining 3 s")
        h.tick(3)
        check(h.center.current == nil, "expires after the remaining time")
        h.center.setHovering(true)
        _ = h.center.present(note("B"))
        check(h.scheduler.jobs.isEmpty, "an item shown while hovering starts paused")
        h.center.setHovering(false)
        check(h.scheduler.jobs.count == 1 && h.scheduler.lastDelay == 4, "...and gets its full TTL when the hover ends")
        h.center.setHovering(false)
        eq(h.scheduler.scheduledTotal, 3, "repeating the same hover state does nothing")
        h.center.stop()
        h.center.setHovering(true)
        check(h.scheduler.jobs.isEmpty, "hover while stopped is ignored")
    }
    section("Facade: dismiss, dismissAll, actions")
    do {
        let h = CenterHarness()
        let a = note("A"), b = note("B"), c = note("C")
        for n in [a, b, c] { _ = h.center.present(n) }
        check(h.center.dismiss(a.id), "dismiss current")
        eq(h.center.current?.title ?? "", "B", "the next item takes over")
        eq(h.log.presents.last?.display.title ?? "", "B", "onPresent for the successor")
        check(h.center.dismiss(c.id), "dismiss a queued item")
        check(!h.center.dismiss(UUID()), "dismiss unknown id is false")
        h.center.dismissAll()
        check(h.center.current == nil && h.center.queuedCount == 0 && h.log.retracts.last == b.id, "dismissAll retracts the current item")
        check(h.scheduler.jobs.isEmpty, "...and cancels the timer")
        eq(h.center.history.first?.outcome ?? .expired, .dismissed, "dismissals are recorded")
    }
    do {
        let h = CenterHarness()
        let url = URL(string: "https://example.com/pr/1")!
        let a = note("Click me", action: .openURL(url)), none = note("No action")
        _ = h.center.present(a)
        _ = h.center.present(none)
        check(h.center.performAction(a.id), "performAction on a clickable item")
        eq(h.log.actions, [.openURL(url)], "the injected handler received the validated action")
        eq(h.center.current?.title ?? "", "No action", "performing the action dismisses the item")
        eq(h.center.history.first?.outcome ?? .expired, .actioned, "history records actioned")
        check(!h.center.performAction(a.id), "a second click on the same item does nothing")
        eq(h.log.actions.count, 1, "...the handler is not called twice")
        check(!h.center.performAction(none.id), "an item without an action cannot be performed")
        check(!h.center.performAction(UUID()), "unknown id")
        let file = makeTmp("act") + "/note.txt"
        write(file, "x")
        let f = note("File", action: .openURL(URL(fileURLWithPath: file)))
        _ = h.center.present(f)
        try? FileManager.default.removeItem(atPath: file)
        check(!h.center.performAction(f.id), "an action is validated again at click time (the file vanished)")
        eq(h.log.actions.count, 1, "...so the handler was not called")
        let h2 = CenterHarness()
        for (name, act) in [("activateApp", NotificationAction.activateApp(bundleID: "com.apple.Terminal")), ("openNotchTab", .openNotchTab("agents")), ("openAgentSession", .openAgentSession("s1"))] {
            let n = note(name, action: act)
            _ = h2.center.present(n)
            check(h2.center.performAction(n.id), "performAction: \(name)")
            h2.center.dismissAll()
        }
        eq(h2.log.actions, [.activateApp(bundleID: "com.apple.Terminal"), .openNotchTab("agents"), .openAgentSession("s1")], "each action kind reached the handler unchanged")
    }
    section("Facade: dedupe, preemption, privacy, Focus")
    do {
        let h = CenterHarness()
        let a = note("v1", key: "k")
        _ = h.center.present(a)
        h.advance(2)
        eq(h.center.present(note("v2", key: "k")), .deduped(a.id), "same key: deduped into the live item")
        eq(h.log.presents.count, 2, "onPresent is called again with the new content")
        check(h.log.presents.last?.display.title == "v2" && h.log.presents.last?.display.id == a.id, "...same id, new text")
        check(h.scheduler.jobs.count == 1 && h.scheduler.lastDelay == 4, "...and the TTL timer restarts")
        eq(h.center.present(note("v2", key: "k")), .deduped(a.id), "an identical update is deduped too")
        eq(h.log.presents.count, 2, "...without re-presenting unchanged content")
    }
    do {
        let h = CenterHarness()
        let a = note("A", ttl: 10), hi = note("H", priority: .high)
        _ = h.center.present(a)
        h.advance(3)
        check(shown(h.center.present(hi)), "a high item preempts")
        check(h.log.presents.last?.display.title == "H" && h.log.presents.last?.ttl == 4, "onPresent for the preemptor")
        check(abs((h.scheduler.lastDelay ?? 0) - 4) < 0.001, "the timer follows the new current item")
        h.tick(4)
        eq(h.center.current?.title ?? "", "A", "the preempted item resumes")
        check(abs((h.log.presents.last?.ttl ?? 0) - 7) < 0.001 && abs((h.scheduler.lastDelay ?? 0) - 7) < 0.001, "...with its remaining 7 s")
        h.tick(7)
        check(h.center.current == nil, "...and then ends")
    }
    do {
        let h = CenterHarness { $0.privacyMode = .hideAll }
        _ = h.center.present(note("SECRETT1", body: "SECRETB2", subtitle: "SECRETS3", app: "Mail"))
        eq(h.center.current?.title ?? "", "Notification from Mail", "hideAll through the facade")
        let dump = String(reflecting: h.log.presents) + String(reflecting: h.center.history) + String(reflecting: h.center.current as Any)
        check(!dump.contains("SECRETT1") && !dump.contains("SECRETB2") && !dump.contains("SECRETS3"), "no hidden text in onPresent, history or current")
        h.center.settings.privacyMode = .off
        h.center.dismissAll()
        _ = h.center.present(note("Visible1", body: "VisibleB2", subtitle: "VisibleS3"))
        check(h.center.current?.body == "VisibleB2" && h.center.current?.isRedacted == false, "changing the privacy mode applies to later notifications")
        check(h.log.persisted.last?.privacyMode == .off, "settings changes go through the injected persistence closure")
    }
    do {
        let h = CenterHarness()
        h.log.focus = true
        let d = h.center.present(note("quiet"))
        check({ if case .silenced = d { return true }; return false }(), "Focus on (default silenceExceptCritical): silenced")
        check(h.center.current == nil && h.log.presents.isEmpty && h.center.history.first?.isSilenced == true, "...never presented, recorded in history with the flag")
        check(shown(h.center.present(note("urgent", priority: .critical))), "critical still shows during Focus")
        h.center.dismissAll()
        h.center.settings.focusPolicy = .show
        check(shown(h.center.present(note("anyway"))), "policy show ignores Focus")
        h.center.dismissAll()
        h.log.focus = false
        h.center.settings.focusPolicy = .silence
        check(shown(h.center.present(note("free"))), "Focus off: shown under any policy")
    }
    section("Facade: settings changes")
    do {
        let h = CenterHarness()
        let n0 = h.log.persisted.count
        h.center.settings.defaultDuration = 4
        eq(h.log.persisted.count, n0, "assigning an equal value does not persist")
        h.center.settings.defaultDuration = 9
        eq(h.log.persisted.count, n0 + 1, "a real change persists once")
        _ = h.center.present(note("a", source: .cli))
        _ = h.center.present(note("b", source: .cli))
        _ = h.center.present(note("c", source: .atoll))
        h.center.settings.enabledSources.remove(.cli)
        eq(h.center.current?.title ?? "", "c", "switching a source off purges its live items and promotes the rest")
        eq(h.center.queuedCount, 0, "...including queued ones")
        eq(h.center.present(note("d", source: .cli)), .dropped(.sourceDisabled), "...and later notifications from it are dropped")
        h.center.settings.enabled = false
        check(h.center.current == nil && h.scheduler.jobs.isEmpty && h.log.retracts.count >= 1, "master switch off clears everything and cancels the timer")
        h.center.settings.enabled = true
        check(shown(h.center.present(note("again", source: .atoll))), "master switch on again: works")
        h.center.settings.historyLimit = 1
        h.center.dismissAll()
        eq(h.center.history.count, 1, "historyLimit applies to the published history")
        h.center.clearHistory()
        check(h.center.history.isEmpty, "clearHistory")
        h.center.stop()
        check(h.center.current == nil && h.scheduler.jobs.isEmpty, "stop() leaves nothing armed")
    }
    section("Facade: reply mapping for the socket")
    do {
        let id = UUID()
        typealias C = NotchNotificationCenter
        eq(C.reply(for: .shown(id, preempted: nil), id: UUID()), .ok(id: id), "shown -> ok with the id")
        eq(C.reply(for: .queued(id, position: 2), id: UUID()), .ok(id: id), "queued -> ok")
        eq(C.reply(for: .deduped(id), id: UUID()), .ok(id: id), "deduped -> ok with the EXISTING id")
        eq(C.reply(for: .silenced(id), id: UUID()), .ok(id: id), "silenced -> ok (the sender did nothing wrong)")
        eq(C.reply(for: .rateLimited, id: id), .error("rate limited"), "rateLimited -> error")
        check({ if case .error(let m) = C.reply(for: .dropped(.disabled), id: id) { return m.contains("turned off") }; return false }(), "disabled -> error")
        check({ if case .error(let m) = C.reply(for: .dropped(.sourceDisabled), id: id) { return m.contains("command line") }; return false }(), "sourceDisabled -> error")
        check({ if case .error = C.reply(for: .dropped(.invalidContent), id: id) { return true }; return false }(), "invalidContent -> error")
        check({ if case .error = C.reply(for: .dropped(.queueFull), id: id) { return true }; return false }(), "queueFull -> error")
    }
    section("Facade: adapters")
    do {
        let h = CenterHarness()
        let cal = FakeAdapter(.calendar), agent = FakeAdapter(.agentClaude)
        h.center.addAdapter(cal); h.center.addAdapter(agent); h.center.addAdapter(cal)
        eq(cal.starts, 1, "an adapter is started once even if added twice")
        let d = cal.emit?(note("from cal", source: .calendar))
        check(d.map(shown) == true && h.center.current?.title == "from cal", "an adapter's emit goes through present")
        h.center.settings.enabledSources.remove(.calendar)
        eq(cal.stops, 1, "switching a source off stops its adapter")
        check(cal.emit == nil && agent.stops == 0, "...only that adapter")
        h.center.settings.enabledSources.insert(.calendar)
        eq(cal.starts, 2, "switching it back on restarts it")
        h.center.stop()
        check(cal.stops == 2 && agent.stops == 1, "stop() stops every running adapter")
        h.center.start()
        eq(agent.starts, 2, "start() starts them again")
        h.center.removeAdapter(agent)
        eq(agent.stops, 2, "removeAdapter stops it")
        let h2 = CenterHarness(start: false)
        let late = FakeAdapter(.cli)
        h2.center.addAdapter(late)
        eq(late.starts, 0, "an adapter added before start() does not run")
        h2.center.start()
        eq(late.starts, 1, "...until start()")
        let h3 = CenterHarness { $0.enabled = false }
        let idle = FakeAdapter(.cli)
        h3.center.addAdapter(idle)
        eq(idle.starts, 0, "a disabled facade runs no adapters")
    }
    section("Facade: one timer, ever (seeded fuzz)")
    do {
        var bad = 0
        for seed in [11, 12, 13, 14] as [UInt64] {
            var rng = SplitMix64(seed: seed)
            let h = CenterHarness { $0.maxQueue = 4 }
            var ids: [UUID] = []
            var hover = false
            for _ in 0..<300 {
                switch rng.next() % 8 {
                case 0..<3:
                    let n = note("t\(rng.next() % 9)", priority: NotificationPriority(rawValue: Int(rng.next() % 4))!, key: rng.next() % 3 == 0 ? "k\(rng.next() % 4)" : nil)
                    ids.append(n.id)
                    _ = h.center.present(n)
                case 3: if let id = ids.randomElement(using: &rng) { _ = h.center.dismiss(id) }
                case 4: hover.toggle(); h.center.setHovering(hover)
                case 5: h.advance(Double(rng.next() % 5)); h.scheduler.fireAll()
                case 6: h.advance(Double(rng.next() % 2000) / 1000)
                default: h.scheduler.fireAll()
                }
                if h.scheduler.jobs.count > 1 { bad += 1 }
                if h.center.current == nil && !h.scheduler.jobs.isEmpty { bad += 1 }
                if h.center.current != nil && !hover && h.scheduler.jobs.isEmpty { bad += 1 }
                if h.center.current != nil && hover && !h.scheduler.jobs.isEmpty { bad += 1 }
            }
            if h.scheduler.maxConcurrent > 1 { bad += 1 }
        }
        eq(bad, 0, "at most ONE timer is armed at any time; idle or hovered means none (4 x 300 random operations)")
    }

    section("Facade + real socket + real script (end to end)")
    do {
        let dir = makeTmp("fc")
        let path = dir + "/.atoll/run/notify.sock"
        let h = CenterHarness({ $0.rateLimitPerMinute = 3 }, makeIngress: { NotificationIngressServer(socketPath: path) })
        check(h.center.isIngressRunning && FileManager.default.fileExists(atPath: path), "enabled + .cli source: the socket exists")
        eq(h.center.ingressError, nil, "no ingress error")
        let reply = await onBackground { RawClient.request(path: path, "{\"v\":1,\"title\":\"From socket\",\"body\":\"secret body\",\"priority\":\"high\",\"url\":\"https://example.com/a\"}") }
        check(reply.reply?["ok"] as? Bool == true, "a socket request is accepted through the facade")
        eq(h.center.current?.title ?? "", "From socket", "...and becomes the current notification")
        eq(reply.reply?["id"] as? String ?? "", h.center.current?.id.uuidString ?? "x", "...the reply id is the notification id")
        check(h.center.current?.body == nil && h.center.current?.isRedacted == true, "default privacy (hidePreview): the body never reaches the display")
        check(h.center.current?.appName == "atoll-notify" && h.center.current?.hasAction == true && h.center.current?.priority == .high, "app name, action and priority arrive")
        if let script = ProcessInfo.processInfo.environment["AN_NOTIFY_SCRIPT"] {
            let env = ["HOME": makeTmp("fh"), "ATOLL_NOTIFY_SOCKET": path]
            let r = await runProcess(script, ["-t", "From script", "-a", "make", "--sensitive", "-b", "hidden body"], env: env)
            check(r.status == 0 && r.stderr.isEmpty, "the real script delivers through the facade (exit 0)")
            check(h.center.queuedCount == 1 && h.center.history.isEmpty, "...queued behind the current item")
            h.center.dismissAll()
            let r2 = await runProcess(script, ["-t", "Third"], env: env)
            check(r2.status == 0, "third request inside the minute is still within the limit of 3")
            let r3 = await runProcess(script, ["-t", "Fourth"], env: env)
            check(r3.status == 1 && r3.stderr.contains("rate limited"), "the fourth is rejected by the queue's rate limit: exit 1, \"rate limited\"")
            h.center.settings.enabledSources.remove(.cli)
            check(!h.center.isIngressRunning && !FileManager.default.fileExists(atPath: path), "switching the CLI source off closes the socket")
            let r4 = await runProcess(script, ["-t", "Nobody home"], env: env)
            check(r4.status == 0 && r4.stderr.contains("not running"), "...and the script reports not running (exit 0)")
            h.center.settings.enabledSources.insert(.cli)
            check(h.center.isIngressRunning, "switching it back on reopens the socket")
        } else { check(false, "AN_NOTIFY_SCRIPT missing") }
        h.center.stop()
        check(!h.center.isIngressRunning && !FileManager.default.fileExists(atPath: path), "stop() closes the socket and removes the file")
        check(await waitUntil { socketFDCount() <= baselineFDs }, "no socket descriptor remains after stop (\(socketFDCount()) vs \(baselineFDs))")
    }
    do {  // the facade survives an insecure directory
        let base = makeTmp("bad")
        mkdir(base + "/open", 0o755); chmod(base + "/open", 0o755)
        let h = CenterHarness(makeIngress: { NotificationIngressServer(socketPath: base + "/open/n.sock") })
        check(!h.center.isIngressRunning && h.center.ingressError?.contains("0700") == true, "an insecure socket directory is reported via ingressError, not a crash")
        check(shown(h.center.present(note("still works"))), "...and in-process notifications still work")
        h.center.stop()
    }
    do {  // a wrong-uid server config through the facade: nothing gets in
        let dir = makeTmp("wu")
        let path = dir + "/.atoll/run/notify.sock"
        let h = CenterHarness(makeIngress: { NotificationIngressServer(socketPath: path, allowedPeerUID: geteuid() &+ 1) })
        let r = await onBackground { RawClient.request(path: path, "{\"v\":1,\"title\":\"foreign\"}") }
        check(r.reply == nil && h.center.current == nil, "a peer with another uid is refused before the facade sees anything")
        h.center.stop()
    }
}

@MainActor
func runSourceLintTests() {
    section("Privacy lint: the Core files never log, persist or broadcast")
    guard let script = ProcessInfo.processInfo.environment["AN_NOTIFY_SCRIPT"] else { check(false, "AN_NOTIFY_SCRIPT missing"); return }
    let repo = ((script as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
    let core = repo + "/AtollNotch/Core"
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: core)) ?? []).filter { $0.hasSuffix(".swift") && ($0.hasPrefix("Notification") || $0 == "NotchNotificationCenter.swift") }
    check(files.count >= 5, "found the notification Core files (\(files.count))")
    let banned = ["print(", "NSLog(", "os_log", "Logger(", "debugPrint(", "dump(", ".write(to", "createFile", "UserDefaults", "Defaults[", "DistributedNotificationCenter",
                  "NSUbiquitousKeyValueStore", "FileHandle(forWriting", "OutputStream", "URLSession", "NWConnection", "CFSocket", "AF_INET", "WebSocket"]
    for f in files.sorted() {
        let text = (try? String(contentsOfFile: core + "/" + f, encoding: .utf8)) ?? ""
        let code = text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        let hits = banned.filter { code.contains($0) }
        check(hits.isEmpty, "\(f): no logging, persistence, broadcast or network API \(hits.isEmpty ? "" : String(describing: hits))")
        check(text.contains("GNU General Public License"), "\(f): GPL header present")
    }
}

func onBackground<T>(_ f: @escaping () -> T) async -> T {
    await withCheckedContinuation { cont in DispatchQueue.global().async { cont.resume(returning: f()) } }
}
