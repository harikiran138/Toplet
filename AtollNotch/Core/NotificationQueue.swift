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

// Pure notification queue (docs/NOTIFICATIONS-IDLE-AUDIT.md sections 2.7, 7.5, test T3).
// Foundation only. No clock, no timers, no I/O of its own: every call receives `now`, so tests drive it with a fake clock.
//
// Privacy invariant: the queue redacts at ACCEPT time and keeps only the redacted `NotificationDisplay` (plus the
// action, which is not text). The raw title/subtitle/body of a redacted notification is never stored in the queue,
// its history, or any decision value, so nothing downstream can leak what the user chose to hide.

// MARK: - Sanitiser and validators

enum NotificationText {
    static let ellipsis = "\u{2026}"
    static let maxTitle = 120
    static let maxSubtitle = 120
    static let maxBody = 400
    static let maxAppName = 60
    static let maxKey = 128
    static let maxSymbol = 64
    static let maxURLBytes = 2048

    /// Cleans untrusted text for display. Output has no control, bidi, zero-width or other invisible format characters,
    /// no ANSI escape sequences, bounded combining-mark runs, and at most `max` grapheme clusters (ellipsis included).
    /// multiline == false collapses all whitespace; true keeps newlines (at most one blank line in a row).
    static func clean(_ input: String, max: Int, multiline: Bool = false) -> String {
        guard max > 0 else { return "" }
        // Bound the work: a 100 MB string costs the same as a 10 KB one.
        let scalarLimit = Swift.max(256, max * 12)
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(Swift.min(scalarLimit, 4096))
        var inputTruncated = false
        for s in input.unicodeScalars {
            if scalars.count >= scalarLimit { inputTruncated = true; break }
            scalars.append(s)
        }

        var out = String.UnicodeScalarView()
        var pendingSpace = false
        var newlineRun = 0
        var markRun = 0
        var atLineStart = true
        var i = 0
        let n = scalars.count

        func flushSpace() {
            if pendingSpace && !atLineStart { out.append(" ") }
            pendingSpace = false
        }

        while i < n {
            let s = scalars[i]
            let v = s.value

            if v == 0x1B {                                   // ANSI escape: swallow the whole sequence
                i += 1
                if i < n {
                    let c = scalars[i].value
                    if c == 0x5B {
                        i += 1
                        while i < n, !(0x40...0x7E).contains(scalars[i].value) { i += 1 }
                        i += 1
                    } else if c == 0x5D || c == 0x50 || c == 0x5F || c == 0x5E {
                        i += 1
                        while i < n {
                            if scalars[i].value == 0x07 { i += 1; break }
                            if scalars[i].value == 0x1B { i += 2; break }
                            i += 1
                        }
                    } else {
                        i += 1
                    }
                }
                continue
            }

            if v == 0x0A || v == 0x0D || v == 0x0B || v == 0x0C || v == 0x85 || v == 0x2028 || v == 0x2029 {
                if v == 0x0D, i + 1 < n, scalars[i + 1].value == 0x0A { i += 1 }
                i += 1
                if multiline {
                    pendingSpace = false
                    newlineRun += 1
                    if newlineRun <= 2 && !out.isEmpty { out.append("\n"); atLineStart = true }
                } else {
                    pendingSpace = true
                }
                markRun = 0
                continue
            }

            if v == 0x09 || s.properties.isWhitespace {
                pendingSpace = true
                markRun = 0
                i += 1
                continue
            }

            if shouldDrop(s) {
                // A zero-width joiner between two emoji is part of the glyph. Keep it only there.
                if v == 0x200D, let prev = out.last, prev.value > 0xFF, prev.properties.isEmoji || prev.value == 0xFE0F,
                   i + 1 < n, scalars[i + 1].value > 0xFF, scalars[i + 1].properties.isEmoji {
                    out.append(s)
                }
                i += 1
                continue
            }

            switch s.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark:
                markRun += 1
                if markRun > 4 { i += 1; continue }          // zalgo
            default:
                markRun = 0
            }

            flushSpace()
            newlineRun = 0
            atLineStart = false
            out.append(s)
            i += 1
        }

        var result = String(out)
        while let last = result.unicodeScalars.last, last == "\n" || last == " " { result.unicodeScalars.removeLast() }
        if result.isEmpty { return "" }
        return truncate(result, max: max, force: inputTruncated)
    }

    static func cleanOptional(_ s: String?, max: Int, multiline: Bool = false) -> String? {
        guard let s = s else { return nil }
        let c = clean(s, max: max, multiline: multiline)
        return c.isEmpty ? nil : c
    }

    /// At most `max` graphemes including the ellipsis.
    static func truncate(_ s: String, max: Int, force: Bool = false) -> String {
        guard max > 0 else { return "" }
        let total = s.count
        if total <= max && !force { return s }
        if total < max && force { return s + ellipsis }
        if max == 1 { return ellipsis }
        var head = String(s.prefix(max - 1))
        while let last = head.unicodeScalars.last, last == " " || last == "\n" { head.unicodeScalars.removeLast() }
        return head + ellipsis
    }

    /// True for scalars that must never reach the UI.
    static func shouldDrop(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if v < 0x20 || (0x7F...0x9F).contains(v) { return true }
        switch v {
        case 0x115F, 0x1160, 0x17B4, 0x17B5, 0x3164, 0xFFA0, 0x034F, 0x180B...0x180F: return true
        case 0xE0000...0xE007F: return true                  // tag characters (hidden text)
        case 0xE0100...0xE01EF: return false
        default: break
        }
        switch s.properties.generalCategory {
        case .control, .format, .privateUse, .surrogate, .unassigned: return true
        default: return false
        }
    }

    // MARK: Identifiers

    /// SF Symbol names: [A-Za-z0-9.] only, bounded, no leading/trailing/double dots.
    static func symbol(_ s: String?) -> String? {
        guard let s = s, !s.isEmpty, s.utf8.count <= maxSymbol else { return nil }
        for b in s.utf8 {
            let ok = (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) || b == 0x2E
            if !ok { return nil }
        }
        if s.hasPrefix(".") || s.hasSuffix(".") || s.contains("..") { return nil }
        return s
    }

    /// Reverse-DNS bundle identifier: [A-Za-z0-9._-], at least one interior dot, <= 155 bytes.
    static func bundleID(_ s: String?) -> String? {
        guard let s = s, s.utf8.count >= 3, s.utf8.count <= 155 else { return nil }
        for b in s.utf8 {
            let ok = (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) || b == 0x2E || b == 0x2D || b == 0x5F
            if !ok { return nil }
        }
        if s.hasPrefix(".") || s.hasSuffix(".") || s.contains("..") || !s.contains(".") { return nil }
        return s
    }

    /// Notch tab identifier, e.g. "agents".
    static func tab(_ s: String?) -> String? {
        guard let s = s, !s.isEmpty, s.utf8.count <= 32 else { return nil }
        for b in s.utf8 {
            let ok = (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) || b == 0x2D || b == 0x5F
            if !ok { return nil }
        }
        return s
    }
}

enum NotificationURLPolicy {
    /// Schemes that run code or embed content. Refused even though custom schemes are otherwise allowed.
    static let blockedSchemes: Set<String> = ["javascript", "data", "vbscript", "about", "blob", "applescript", "osascript",
                                              "view-source", "jar", "livescript", "mocha", "feed", "ws", "wss", "ftp"]
    /// `file:` targets that LAUNCH something when opened.
    static let blockedFileExtensions: Set<String> = ["app", "command", "tool", "terminal", "workflow", "action", "wflow", "pkg", "mpkg",
                                                     "dmg", "jar", "saver", "prefpane", "osax", "appex", "xpc", "bundle", "plugin",
                                                     "scpt", "scptd", "scriptsuite", "webloc", "inetloc", "fileloc", "url", "pif"]

    static func isValidScheme(_ s: String) -> Bool {
        guard let f = s.unicodeScalars.first, (0x61...0x7A).contains(f.value), s.utf8.count <= 32 else { return false }
        return s.unicodeScalars.allSatisfy { (0x61...0x7A).contains($0.value) || (0x30...0x39).contains($0.value) || $0 == "+" || $0 == "-" || $0 == "." }
    }

    /// Syntactic validation only. For custom schemes nothing checks that an app handles them.
    static func validate(_ raw: String, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL? {
        // Trim ASCII whitespace only: Foundation's wider trim would silently swallow a trailing zero-width character.
        let t = String(String.UnicodeScalarView(raw.unicodeScalars.drop(while: { [" ", "\t", "\n", "\r"].contains($0) }).reversed().drop(while: { [" ", "\t", "\n", "\r"].contains($0) }).reversed()))
        guard !t.isEmpty, t.utf8.count <= NotificationText.maxURLBytes else { return nil }
        for s in t.unicodeScalars {
            if s.properties.isWhitespace || NotificationText.shouldDrop(s) { return nil }   // no spaces, controls, bidi, zero-width
        }
        guard var comps = URLComponents(string: t), let scheme0 = comps.scheme else { return nil }
        comps.scheme = scheme0.lowercased()
        return check(comps, scheme: scheme0.lowercased(), fileExists: fileExists)
    }

    static func validate(url: URL, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL? {
        validate(url.absoluteString, fileExists: fileExists)
    }

    private static func check(_ comps: URLComponents, scheme: String, fileExists: (String) -> Bool) -> URL? {
        guard isValidScheme(scheme), !blockedSchemes.contains(scheme) else { return nil }
        switch scheme {
        case "http", "https":
            guard let h = comps.host, !h.isEmpty, comps.user == nil, comps.password == nil else { return nil }
            return comps.url
        case "mailto":
            guard !comps.path.isEmpty || !(comps.query ?? "").isEmpty else { return nil }
            return comps.url
        case "file":
            if let h = comps.host, !h.isEmpty, h.lowercased() != "localhost" { return nil }
            let path = comps.path
            guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
            let resolved = (path as NSString).standardizingPath
            let ext = (resolved as NSString).pathExtension.lowercased()
            if blockedFileExtensions.contains(ext) { return nil }
            // A symlink must not smuggle a launchable target past the extension check.
            let real = URL(fileURLWithPath: resolved).resolvingSymlinksInPath().path
            if blockedFileExtensions.contains((real as NSString).pathExtension.lowercased()) { return nil }
            guard fileExists(resolved) else { return nil }
            return URL(fileURLWithPath: resolved)
        default:
            // Custom scheme: must carry something after the colon.
            guard (comps.host?.isEmpty == false) || !comps.path.isEmpty || !(comps.query ?? "").isEmpty else { return nil }
            return comps.url
        }
    }
}

extension NotificationSource {
    /// Shown when the sender gave no usable app name.
    var defaultAppName: String {
        switch self {
        case .atoll: return "Toplet"
        case .cli: return "atoll-notify"
        case .extensionApp: return "Extension"
        case .agentClaude: return "Claude Code"
        case .agentCodex: return "Codex"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        }
    }
}

// MARK: - History

struct NotificationHistoryItem: Identifiable, Equatable {
    enum Outcome: String, Equatable {
        case expired        // shown, TTL ran out
        case dismissed      // shown, user or code dismissed it
        case actioned       // shown, user clicked it
        case silenced       // Focus policy: never shown
        case evicted        // pushed out of a full queue (or arrived into one): never shown
        case stale          // waited in the queue past its useful life: never shown
        case cleared        // removed by dismissAll / source switched off / facade stopped
    }
    var id: UUID
    var display: NotificationDisplay            // already redacted according to the privacy mode at accept time
    var source: NotificationSource
    var action: NotificationAction
    var receivedAt: Date
    var endedAt: Date
    var outcome: Outcome
    var wasShown: Bool
    var isSilenced: Bool { outcome == .silenced }
}

// MARK: - Queue

struct NotificationQueue {
    enum DropReason: Equatable { case disabled, sourceDisabled, invalidContent, queueFull }

    enum Decision: Equatable {
        case shown(UUID, preempted: UUID?)      // now the current item (a lower-priority current was pushed back with its remaining TTL)
        case queued(UUID, position: Int)        // 0 = next up
        case deduped(UUID)                      // merged into / ignored as a duplicate of the item with this id
        case rateLimited
        case silenced(UUID)                     // Focus policy: recorded in history, never shown
        case dropped(DropReason)
    }

    struct Entry: Identifiable, Equatable {
        var id: UUID
        var display: NotificationDisplay
        var action: NotificationAction
        var source: NotificationSource
        var dedupeKey: String
        var receivedAt: Date
        var arrival: Int
        var ttl: TimeInterval
        var remaining: TimeInterval
        var deadline: Date?                     // nil while pending or paused
        var wasShown: Bool
        var priority: NotificationPriority { display.priority }
    }

    private struct Recent { var id: UUID; var at: Date; var display: NotificationDisplay }

    // Tunables (not part of the user-facing contract).
    var preemptThreshold: NotificationPriority = .high      // a newcomer needs at least this priority AND to outrank the current item to preempt it
    var pendingMaxAge: TimeInterval = 120                   // a never-shown, non-critical item older than this is dropped on dequeue
    var criticalRateMultiplier: Int = 4                     // flood ceiling for critical items (they are never evicted or silenced)
    static let rateWindow: TimeInterval = 60
    static let maxRecentKeys = 512
    static let minTTL: TimeInterval = 1
    static let maxTTL: TimeInterval = 300

    var settings: NotificationSettings { didSet { trimHistory() } }
    var isFocusActive: () -> Bool
    var fileExists: (String) -> Bool

    private(set) var current: Entry?
    private(set) var pending: [Entry] = []
    private(set) var history: [NotificationHistoryItem] = []      // newest first
    private(set) var isPaused = false
    private var arrivalCounter = 0
    private var stamps: [NotificationSource: [Date]] = [:]
    private var recent: [String: Recent] = [:]

    init(settings: NotificationSettings = NotificationSettings(),
         isFocusActive: @escaping () -> Bool = { false },
         fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.settings = settings
        self.isFocusActive = isFocusActive
        self.fileExists = fileExists
    }

    var queuedCount: Int { pending.count }
    var isIdle: Bool { current == nil && pending.isEmpty }
    /// When the current item's TTL ends. nil when nothing is showing or the TTL is paused (hover).
    var nextDeadline: Date? { current?.deadline }

    // MARK: Accept

    mutating func accept(_ n: NotchNotification, now: Date) -> Decision {
        guard settings.enabled else { return .dropped(.disabled) }
        guard settings.enabledSources.contains(n.source) else { return .dropped(.sourceDisabled) }
        prune(now)
        guard let m = sanitised(n, now: now) else { return .dropped(.invalidContent) }

        guard admitRate(source: m.source, priority: m.priority, now: now) else { return .rateLimited }

        let key = effectiveKey(m)
        let display = Self.redact(m, mode: settings.privacyMode)
        var id = m.id
        if id == current?.id || pending.contains(where: { $0.id == id }) { id = UUID() }
        let ttl = m.ttl ?? Self.clampTTL(settings.defaultDuration)

        // 1. Same key as a live item: replace content in place (keeps arrival position), restart its TTL.
        if let r = replaceLive(key: key, display: display, action: m.action, ttl: ttl, now: now) {
            enforceCap(now: now)                            // a replace can preempt, which pushes the old current item back
            guard isLive(r) else { return .dropped(.queueFull) }
            recent[key] = Recent(id: r, at: now, display: display)
            return .deduped(r)
        }
        // 2. Same key seen recently and nothing changed: ignore. (Changed content is a new notification.)
        if let r = recent[key], now.timeIntervalSince(r.at) < settings.dedupeWindow, Self.sameContent(r.display, display) {
            recent[key] = Recent(id: r.id, at: now, display: r.display)
            return .deduped(r.id)
        }

        var shownDisplay = display
        shownDisplay.id = id

        // 3. Focus policy: recorded, never shown.
        if focusSilences(m.priority) {
            appendHistory(NotificationHistoryItem(id: id, display: shownDisplay, source: m.source, action: m.action, receivedAt: now,
                                                  endedAt: now, outcome: .silenced, wasShown: false))
            recent[key] = Recent(id: id, at: now, display: shownDisplay)
            return .silenced(id)
        }

        // 4. Insert, preempt if warranted, then enforce the cap.
        arrivalCounter += 1
        let entry = Entry(id: id, display: shownDisplay, action: m.action, source: m.source, dedupeKey: key, receivedAt: now,
                          arrival: arrivalCounter, ttl: ttl, remaining: ttl, deadline: nil, wasShown: false)
        insertSorted(entry)
        let preempted = settle(now: now)
        enforceCap(now: now)

        if current?.id == id { recent[key] = Recent(id: id, at: now, display: shownDisplay); return .shown(id, preempted: preempted) }
        if let idx = pending.firstIndex(where: { $0.id == id }) { recent[key] = Recent(id: id, at: now, display: shownDisplay); return .queued(id, position: idx) }
        return .dropped(.queueFull)
    }

    // MARK: Time

    /// Expires the current item if its TTL ended, drops stale queued items, promotes the next item.
    mutating func advance(now: Date) {
        prune(now)
        if let c = current, let d = c.deadline, d <= now {
            current = nil
            end(c, .expired, now)
        }
        purgeStale(now)
        _ = settle(now: now)
        enforceCap(now: now)
    }

    /// Hover pause: freezes the current item's remaining TTL. New items promoted while paused start paused.
    mutating func setPaused(_ paused: Bool, now: Date) {
        guard paused != isPaused else { return }
        isPaused = paused
        guard var c = current else { return }
        if paused { c.remaining = remaining(of: c, now: now); c.deadline = nil }
        else { c.deadline = now.addingTimeInterval(c.remaining) }
        current = c
    }

    // MARK: Dismissal

    @discardableResult
    mutating func dismiss(id: UUID, outcome: NotificationHistoryItem.Outcome = .dismissed, now: Date) -> Bool {
        if let c = current, c.id == id {
            current = nil
            end(c, outcome, now)
            purgeStale(now)
            _ = settle(now: now)
            return true
        }
        if let i = pending.firstIndex(where: { $0.id == id }) {
            let e = pending.remove(at: i)
            end(e, outcome, now)
            return true
        }
        return false
    }

    mutating func dismissAll(outcome: NotificationHistoryItem.Outcome = .cleared, now: Date) {
        if let c = current { current = nil; end(c, outcome, now) }
        let all = pending
        pending = []
        for e in all { end(e, outcome, now) }
    }

    /// Removes every live item that came from `source` (used when the user switches a source off).
    mutating func purge(source: NotificationSource, now: Date) {
        if let c = current, c.source == source {
            current = nil
            end(c, .cleared, now)
        }
        let gone = pending.filter { $0.source == source }
        pending.removeAll { $0.source == source }
        for e in gone { end(e, .cleared, now) }
        purgeStale(now)
        _ = settle(now: now)
    }

    mutating func clearHistory() { history = [] }

    private mutating func trimHistory() {
        let limit = Swift.max(settings.historyLimit, 0)
        if history.count > limit { history.removeLast(history.count - limit) }
    }

    func action(for id: UUID) -> NotificationAction? {
        if let c = current, c.id == id { return c.action }
        if let e = pending.first(where: { $0.id == id }) { return e.action }
        return history.first(where: { $0.id == id })?.action
    }

    func isLive(_ id: UUID) -> Bool { current?.id == id || pending.contains(where: { $0.id == id }) }

    // MARK: Privacy

    /// The ONLY place raw text is turned into something the UI may show. `isSensitive` forces at least hidePreview.
    static func redact(_ n: NotchNotification, mode: NotificationPrivacyMode) -> NotificationDisplay {
        let effective = strictest(mode, n.isSensitive ? .hidePreview : .off)
        let hasAction = n.action != .none
        switch effective {
        case .off:
            return NotificationDisplay(id: n.id, appName: n.appName, iconSymbol: n.iconSymbol, bundleID: n.bundleID, title: n.title,
                                       subtitle: n.subtitle, body: n.body, isRedacted: false, priority: n.priority, hasAction: hasAction)
        case .hidePreview:
            return NotificationDisplay(id: n.id, appName: n.appName, iconSymbol: n.iconSymbol, bundleID: n.bundleID, title: n.title,
                                       subtitle: nil, body: nil, isRedacted: true, priority: n.priority, hasAction: hasAction)
        case .hideAll:
            return NotificationDisplay(id: n.id, appName: n.appName, iconSymbol: n.iconSymbol, bundleID: n.bundleID,
                                       title: "Notification from \(n.appName)", subtitle: nil, body: nil, isRedacted: true,
                                       priority: n.priority, hasAction: hasAction)
        }
    }

    static func strictest(_ a: NotificationPrivacyMode, _ b: NotificationPrivacyMode) -> NotificationPrivacyMode {
        func rank(_ m: NotificationPrivacyMode) -> Int { switch m { case .off: return 0; case .hidePreview: return 1; case .hideAll: return 2 } }
        return rank(a) >= rank(b) ? a : b
    }

    // MARK: Sanitising

    static func clampTTL(_ t: TimeInterval) -> TimeInterval {
        guard t.isFinite, t > 0 else { return 4 }
        return Swift.min(Swift.max(t, minTTL), maxTTL)
    }

    /// Returns the notification with every string cleaned and every identifier/URL validated, or nil when there is no usable title.
    func sanitised(_ n: NotchNotification, now: Date) -> NotchNotification? {
        var m = n
        let title = NotificationText.clean(n.title, max: NotificationText.maxTitle)
        guard !title.isEmpty else { return nil }
        m.title = title
        m.subtitle = NotificationText.cleanOptional(n.subtitle, max: NotificationText.maxSubtitle)
        m.body = NotificationText.cleanOptional(n.body, max: NotificationText.maxBody, multiline: true)
        let app = NotificationText.clean(n.appName, max: NotificationText.maxAppName)
        m.appName = app.isEmpty ? n.source.defaultAppName : app
        m.bundleID = NotificationText.bundleID(n.bundleID)
        m.iconSymbol = NotificationText.symbol(n.iconSymbol)
        m.threadID = NotificationText.cleanOptional(n.threadID, max: NotificationText.maxKey)
        m.dedupeKey = NotificationText.cleanOptional(n.dedupeKey, max: NotificationText.maxKey)
        m.action = validated(n.action)
        m.receivedAt = now                                  // the sender's clock is not trusted
        if let t = n.ttl, t.isFinite, t > 0 { m.ttl = Self.clampTTL(t) } else { m.ttl = nil }
        return m
    }

    func validated(_ a: NotificationAction) -> NotificationAction {
        switch a {
        case .none: return .none
        case .openURL(let u):
            if let ok = NotificationURLPolicy.validate(url: u, fileExists: fileExists) { return .openURL(ok) }
            return .none
        case .activateApp(let b):
            if let ok = NotificationText.bundleID(b) { return .activateApp(bundleID: ok) }
            return .none
        case .openNotchTab(let t):
            if let ok = NotificationText.tab(t) { return .openNotchTab(ok) }
            return .none
        case .openAgentSession(let s):
            if let ok = NotificationText.cleanOptional(s, max: NotificationText.maxKey) { return .openAgentSession(ok) }
            return .none
        }
    }

    private func effectiveKey(_ m: NotchNotification) -> String {
        if let k = m.dedupeKey { return "k|\(m.source.rawValue)|\(k)" }
        var h = Hasher()
        h.combine(m.appName); h.combine(m.threadID); h.combine(m.title); h.combine(m.subtitle); h.combine(m.body)
        return "i|\(m.source.rawValue)|\(h.finalize())"
    }

    private static func sameContent(_ a: NotificationDisplay, _ b: NotificationDisplay) -> Bool {
        var x = a
        x.id = b.id
        return x == b
    }

    // MARK: Internals

    private func focusSilences(_ p: NotificationPriority) -> Bool {
        switch settings.focusPolicy {
        case .show: return false
        case .silence: return isFocusActive()
        case .silenceExceptCritical: return p != .critical && isFocusActive()
        }
    }

    private mutating func admitRate(source: NotificationSource, priority: NotificationPriority, now: Date) -> Bool {
        let limit = settings.rateLimitPerMinute
        if limit <= 0 { return true }                       // 0 = unlimited
        var list = (stamps[source] ?? []).filter { now.timeIntervalSince($0) < Self.rateWindow }
        let cap = priority == .critical ? limit &* criticalRateMultiplier : limit
        if list.count >= cap { stamps[source] = list; return false }
        list.append(now)
        stamps[source] = list
        return true
    }

    private mutating func prune(_ now: Date) {
        if !recent.isEmpty {
            let w = settings.dedupeWindow
            recent = recent.filter { now.timeIntervalSince($0.value.at) < w }
            if recent.count > Self.maxRecentKeys {
                let keep = recent.sorted { $0.value.at > $1.value.at }.prefix(Self.maxRecentKeys)
                recent = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            }
        }
        if !stamps.isEmpty {
            for (s, l) in stamps {
                let f = l.filter { now.timeIntervalSince($0) < Self.rateWindow }
                if f.isEmpty { stamps.removeValue(forKey: s) } else { stamps[s] = f }
            }
        }
    }

    private mutating func replaceLive(key: String, display: NotificationDisplay, action: NotificationAction, ttl: TimeInterval, now: Date) -> UUID? {
        if var c = current, c.dedupeKey == key {
            var d = display; d.id = c.id
            c.display = d; c.action = action; c.ttl = ttl; c.remaining = ttl; c.receivedAt = now
            c.deadline = isPaused ? nil : now.addingTimeInterval(ttl)
            current = c
            return c.id
        }
        if let i = pending.firstIndex(where: { $0.dedupeKey == key }) {
            var e = pending[i]
            var d = display; d.id = e.id
            e.display = d; e.action = action; e.ttl = ttl; e.remaining = ttl; e.receivedAt = now
            pending.remove(at: i)
            insertSorted(e)
            _ = settle(now: now)
            return e.id
        }
        return nil
    }

    private mutating func insertSorted(_ e: Entry) {
        pending.append(e)
        pending.sort { a, b in a.priority != b.priority ? a.priority > b.priority : a.arrival < b.arrival }
    }

    private func remaining(of e: Entry, now: Date) -> TimeInterval {
        if let d = e.deadline { return Swift.max(0, d.timeIntervalSince(now)) }
        return e.remaining
    }

    private func isStale(_ e: Entry, now: Date) -> Bool {
        !e.wasShown && e.priority != .critical && now.timeIntervalSince(e.receivedAt) > pendingMaxAge
    }

    private mutating func purgeStale(_ now: Date) {
        var keep: [Entry] = [], stale: [Entry] = []
        for e in pending { if isStale(e, now: now) { stale.append(e) } else { keep.append(e) } }
        guard !stale.isEmpty else { return }
        pending = keep
        for e in stale { end(e, .stale, now) }
    }

    /// Promotes when nothing is current; preempts when a pending item warrants it. Returns the preempted id.
    private mutating func settle(now: Date) -> UUID? {
        var preempted: UUID?
        if current == nil {
            promoteNext(now: now)
        } else if let best = pending.first, let cur = current, best.priority > cur.priority, best.priority >= preemptThreshold {
            var old = cur
            old.remaining = remaining(of: cur, now: now)
            old.deadline = nil
            current = nil
            if old.remaining > 0.001 { insertSorted(old); preempted = old.id }
            else { end(old, .expired, now) }
            promoteNext(now: now)
        }
        return preempted
    }

    private mutating func promoteNext(now: Date) {
        while !pending.isEmpty {
            var e = pending.removeFirst()
            if isStale(e, now: now) { end(e, .stale, now); continue }
            if e.remaining <= 0.001 { end(e, .expired, now); continue }
            e.wasShown = true
            e.deadline = isPaused ? nil : now.addingTimeInterval(e.remaining)
            current = e
            return
        }
    }

    /// Oldest-lowest-priority eviction. Critical items are never evicted (the cap may be exceeded by criticals alone).
    private mutating func enforceCap(now: Date) {
        let cap = Swift.max(settings.maxQueue, 0)
        while pending.count > cap {
            let victims = pending.enumerated().filter { $0.element.priority != .critical }
            guard let v = victims.min(by: { a, b in
                a.element.priority != b.element.priority ? a.element.priority < b.element.priority : a.element.arrival < b.element.arrival
            }) else { return }
            let e = pending.remove(at: v.offset)
            end(e, .evicted, now)
        }
    }

    private mutating func end(_ e: Entry, _ outcome: NotificationHistoryItem.Outcome, _ now: Date) {
        appendHistory(NotificationHistoryItem(id: e.id, display: e.display, source: e.source, action: e.action, receivedAt: e.receivedAt,
                                              endedAt: now, outcome: outcome, wasShown: e.wasShown))
    }

    private mutating func appendHistory(_ h: NotificationHistoryItem) {
        let limit = Swift.max(settings.historyLimit, 0)
        guard limit > 0 else { history = []; return }
        history.insert(h, at: 0)
        if history.count > limit { history.removeLast(history.count - limit) }
    }
}
