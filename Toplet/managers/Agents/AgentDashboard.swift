import Foundation

struct AgentActivitySummary: Equatable {
    var running = 0
    var idle = 0
    var waiting = 0
    var finished = 0
    var failed = 0
    var tasksDone = 0
    var tasksTotal = 0
    var subagentsRunning = 0
    var subagentsIdle = 0
    var subagentsWaiting = 0
    static func make(_ sessions: [AgentSession]) -> Self {
        var s = Self()
        for a in sessions {
            switch a.status {
            case .starting, .running: s.running += 1
            case .idle: s.idle += 1
            case .needsPermission, .waitingInput: s.waiting += 1
            case .done, .stopped: s.finished += 1
            case .failed: s.failed += 1
            case .unknown: break
            }
            s.tasksDone += a.tasks.filter { $0.status == .completed }.count
            s.tasksTotal += a.tasks.filter { $0.status != .cancelled }.count
            s.subagentsRunning += a.subagents.filter { $0.status == .running }.count
            s.subagentsIdle += a.subagents.filter { $0.status == .idle }.count
            s.subagentsWaiting += a.subagents.filter { $0.status == .waiting }.count
        }
        return s
    }
}

/// Deadline-based timer: continues correctly through tab changes, app inactivity and system sleep.
struct AgentFocusTimer {
    var duration: TimeInterval = 25 * 60
    var deadline: Date?
    var pausedRemaining: TimeInterval?
    var started = false
    func remaining(at now: Date) -> TimeInterval { max(0, deadline.map { $0.timeIntervalSince(now) } ?? pausedRemaining ?? duration) }
    func finished(at now: Date) -> Bool { started && remaining(at: now) == 0 }
    mutating func start(at now: Date) { started = true; deadline = now.addingTimeInterval(pausedRemaining ?? duration); pausedRemaining = nil }
    mutating func pause(at now: Date) { pausedRemaining = remaining(at: now); deadline = nil }
    mutating func reset(minutes: Int? = nil) {
        if let m = minutes { duration = TimeInterval(min(90, max(1, m)) * 60) }
        deadline = nil; pausedRemaining = nil; started = false
    }
}

/// Small, opt-in game; no background timers or input interception.
struct AgentPairsGame {
    var cards = [0, 0, 1, 1, 2, 2, 3, 3].shuffled()
    var selected: [Int] = []
    var matched: Set<Int> = []
    var moves = 0
    var won: Bool { matched.count == cards.count }
    mutating func reveal(_ index: Int) {
        guard cards.indices.contains(index), !matched.contains(index) else { return }
        if selected.count == 2 { selected = [] }
        guard !selected.contains(index) else { return }
        selected.append(index)
        if selected.count == 2 {
            moves += 1
            if cards[selected[0]] == cards[selected[1]] { matched.formUnion(selected); selected = [] }
        }
    }
    mutating func reset() { self = Self() }
}

struct AgentQuotaReading: Equatable, Sendable, Identifiable {
    var kind: AgentKind
    var fiveHourPercent: Double?
    var sevenDayPercent: Double?
    var fiveHourReset: Date?
    var sevenDayReset: Date?
    var todayEstimatedCost: Double?
    var observedAt: Date
    var id: AgentKind { kind }
}

struct AgentActivityNotice: Identifiable, Equatable, Sendable {
    enum Category: String, Sendable { case needsYou = "Needs you", completed = "Completed", failed = "Failed" }
    var id = UUID()
    var key: SessionKey
    var project: String
    var category: Category
    var at: Date
    var title: String {
        switch category {
        case .needsYou: return "Needs your attention"
        case .completed: return "Turn finished"
        case .failed: return "Session needs review"
        }
    }
    static func transition(from old: AgentSession, to new: AgentSession, at: Date) -> Self? {
        guard old.key == new.key, old.status != new.status else { return nil }
        let category: Category
        switch new.status {
        case .needsPermission, .waitingInput: category = .needsYou
        case .failed: category = .failed
        case .idle, .done:
            guard old.status == .running || old.status == .starting else { return nil }
            category = .completed
        default: return nil
        }
        return Self(key: new.key, project: new.projectName, category: category, at: at)
    }
}
