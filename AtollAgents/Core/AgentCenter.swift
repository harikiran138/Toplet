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
import Combine

public enum HooksState: Equatable, Sendable {
    case notInstalled
    case installed(claude: Bool, codex: Bool)       // which agents currently have Atoll's hooks
    case error(String)
}

/// Where the core keeps its files and how it behaves. Defaults are the production paths; tests inject temp paths.
/// ADDITIVE (not part of the original contract): `AgentCenter()` and `AgentCenter.shared` use `AgentCenterConfig()`.
public struct AgentCenterConfig {
    /// nil = `~/.atoll/run/agent.sock` (short on purpose: sun_path is 104 bytes).
    public var socketPath: String?
    public var claudeDir: String?                    // default: CLAUDE_CONFIG_DIR or ~/.claude
    public var codexDir: String?                     // default: CODEX_HOME or ~/.codex
    public var boardURL: URL?                        // default: ~/Library/Application Support/Atoll/agents-board.json
    public var approvalTimeout: TimeInterval = 90
    public var discoveryInterval: TimeInterval = 15
    public var enableDiscovery = true
    public var enableServer = true
    /// Single on-demand `claude agents --json` call during `refreshDiscovery()`. Off by default, never polled.
    public var allowClaudeAgentsCLI = false

    // Test seams (module-internal)
    var processSource: ProcessSource?
    var jumper: TerminalJumper?
    var quickRunner: QuickTaskRunner?
    var activationObserver: ActivationObserving?
    var discoveryActiveInterval: TimeInterval = 5
    var passivePolicy = PassivePolicy.default
    var boardDebounce: TimeInterval = 0.5
    var publishInterval: TimeInterval = 0.1

    public init(socketPath: String? = nil, claudeDir: String? = nil, codexDir: String? = nil, boardURL: URL? = nil) {
        self.socketPath = socketPath; self.claudeDir = claudeDir; self.codexDir = codexDir; self.boardURL = boardURL
    }
}

/// Monotonic numbering of snapshots; only ever touched on the engine's serial queue.
final class SnapshotCounter {
    private var n = 0
    func next() -> Int { n += 1; return n }
}

/// The single object the notch UI observes. Must stay cheap when the feature is disabled (nothing runs until `start()`).
@MainActor
public final class AgentCenter: ObservableObject {
    public static let shared = AgentCenter()

    // MARK: Published state (UI reads these)
    @Published public internal(set) var sessions: [AgentSession] = []        // sorted: attention first, then most recent
    @Published public internal(set) var pending: [PendingApproval] = []      // oldest first
    @Published public var board: [BoardSection] = []                        // user's sections and small tasks
    @Published public internal(set) var isRunning = false                   // socket server + discovery active
    @Published public internal(set) var serverError: String?                // why the channel could not start
    @Published public internal(set) var hooksState: HooksState = .notInstalled
    @Published public internal(set) var unseenCompletionCount = 0           // sessions that finished since the user last looked
    @Published public internal(set) var lastNotice: String?                 // short transient message for the UI (jump failed, task started ...)

    @Published internal var activityNotices: [AgentActivityNotice] = []
    @Published internal var quotaReadings: [AgentQuotaReading] = []
    @Published internal var focusTimer = AgentFocusTimer()
    @Published internal var usageReport = AgentUsageReport()
    private var usageTask: Task<Void, Never>?
    private var usageHistory: AgentUsageHistory?

    // MARK: Core wiring (additive)
    let config: AgentCenterConfig
    /// The hooks module's installer plugs in here (it conforms to `HookInstalling`). Default: read-only marker check.
    public var hookInstaller: HookInstalling
    private var engine: AgentEngine?
    var engineForTesting: AgentEngine? { engine }
    private var generation = 0
    private var boardStore: BoardStore?
    private var boardLoaded = false
    private var suppressBoardSave = false
    private var boardCancellable: AnyCancellable?
    private var noticeTask: Task<Void, Never>?
    private lazy var jumper: TerminalJumper = config.jumper ?? TerminalJumper()
    private lazy var activationObserver: ActivationObserving = config.activationObserver ?? WorkspaceActivationObserver()
    private var fastPolling = false
    private var lastSnapshotSeq = 0
    private lazy var quickRunner: QuickTaskRunner = config.quickRunner ?? QuickTaskRunner()

    public init() {
        self.config = AgentCenterConfig()
        self.hookInstaller = NoopHookInstaller()
    }

    public init(config: AgentCenterConfig) {
        self.config = config
        self.hookInstaller = NoopHookInstaller(inspector: HookMarkerInspector(claudeDir: config.claudeDir, codexDir: config.codexDir))
    }

    /// Test/preview factory: fixed data, no server, no discovery.
    public static func preview(sessions: [AgentSession] = [], pending: [PendingApproval] = [],
                               board: [BoardSection] = [], hooks: HooksState = .notInstalled) -> AgentCenter {
        let c = AgentCenter()
        c.sessions = sessions; c.pending = pending; c.board = board; c.hooksState = hooks
        return c
    }

    // MARK: Lifecycle (called only while the feature is enabled)

    /// Idempotent. Starts the private socket server and passive discovery, loads the board.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        serverError = nil
        startUsageHistory()
        loadBoardIfNeeded()
        hooksState = hookInstaller.state()

        generation += 1
        lastSnapshotSeq = 0
        let gen = generation
        var ec = AgentEngine.Config()
        ec.socketPath = config.socketPath
        ec.approvalTimeout = config.approvalTimeout
        ec.discoveryInterval = config.discoveryInterval
        ec.discoveryActiveInterval = config.discoveryActiveInterval
        ec.passive = config.passivePolicy
        ec.enableDiscovery = config.enableDiscovery
        ec.enableServer = config.enableServer
        ec.discovery = DiscoveryConfig(claudeDir: config.claudeDir, codexDir: config.codexDir)
        ec.discovery.allowClaudeAgentsCLI = config.allowClaudeAgentsCLI
        ec.processSource = config.processSource
        ec.publishInterval = config.publishInterval
        // The default resolver can ask NSRunningApplication; plist resolution is the deterministic fallback.
        ec.appResolver = RunningAppResolver()
        ec.tmuxResolver = { tty in
            TmuxTool.target(forTTY: tty).map { JumpTarget.tmux(target: $0, clientBundleID: nil) }
        }
        let eng = AgentEngine(config: ec)
        // Engine -> main hop. Snapshots are numbered on the (serial) engine queue so that ordering never depends on how the
        // hops are scheduled; `Task { @MainActor }` replaces nested DispatchQueue.main.async + assumeIsolated closures.
        let seq = SnapshotCounter()
        eng.onSnapshot = { [weak self] sessions, pending in
            let n = seq.next()
            Task { @MainActor [weak self] in self?.apply(sessions: sessions, pending: pending, generation: gen, seq: n) }
        }
        eng.onServerError = { [weak self] message in
            let text: String? = message.map { String($0) }
            Task { @MainActor [weak self] in
                guard let self = self, self.generation == gen else { return }
                self.serverError = text
            }
        }
        engine = eng
        eng.start()
        if fastPolling { eng.setFastPolling(true) }
        activationObserver.start { [weak self] bundleID in
            MainActor.assumeIsolated { self?.hostAppActivated(bundleID) }
        }
    }

    /// Releases the socket, timers, queues and file handles. Pending approvals fall back to the agent's own prompt.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        usageTask?.cancel(); usageTask = nil
        if let history = usageHistory { Task { await history.flush() } }
        usageHistory = nil
        generation += 1
        activationObserver.stop()
        engine?.stop()
        engine = nil
        sessions = []
        pending = []
        unseenCompletionCount = 0
        serverError = nil
        boardStore?.flush()
        noticeTask?.cancel(); noticeTask = nil
    }

    private func startUsageHistory() {
        guard config.enableDiscovery else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        let customRoot = config.claudeDir ?? config.codexDir ?? config.boardURL?.deletingLastPathComponent().path
        let claudeFallback = customRoot.map { $0 + "/no-claude-source" } ?? env["CLAUDE_CONFIG_DIR"] ?? home.appendingPathComponent(".claude").path
        let codexFallback = customRoot.map { $0 + "/no-codex-source" } ?? env["CODEX_HOME"] ?? home.appendingPathComponent(".codex").path
        let claude = URL(fileURLWithPath: config.claudeDir ?? claudeFallback).appendingPathComponent("projects")
        let codex = URL(fileURLWithPath: config.codexDir ?? codexFallback).appendingPathComponent("sessions")
        let support = config.boardURL?.deletingLastPathComponent() ?? customRoot.map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent("Library/Application Support/Atoll")
        let history = AgentUsageHistory(claudeRoot: claude, codexRoot: codex, archiveURL: support.appendingPathComponent("agents-usage-v1.json"))
        usageHistory = history
        usageTask = Task { [weak self] in
            while !Task.isCancelled {
                let report = await history.refresh()
                guard !Task.isCancelled, let self, self.isRunning else { return }
                if self.usageReport != report { self.usageReport = report }
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            }
        }
    }

    private func apply(sessions s: [AgentSession], pending p: [PendingApproval], generation gen: Int, seq: Int) {
        guard gen == generation, isRunning, seq > lastSnapshotSeq else { return }
        lastSnapshotSeq = seq
        if sessions != s {
            let previous = Dictionary(sessions.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            let notices = s.compactMap { next in
                previous[next.key].flatMap { AgentActivityNotice.transition(from: $0, to: next, at: Date()) }
            }
            if !notices.isEmpty { activityNotices = Array((notices + activityNotices).prefix(50)) }
            sessions = s
        }
        let unseen = s.reduce(0) { $0 + ($1.hasUnseenCompletion ? 1 : 0) }
        if unseenCompletionCount != unseen { unseenCompletionCount = unseen }
        if pending != p { pending = p }
    }

    func setNotice(_ message: String?) {
        lastNotice = message
        noticeTask?.cancel()
        guard message != nil else { return }
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            self?.lastNotice = nil
        }
    }

    // MARK: Approvals

    /// Answers on the connection that owns `id`. Unknown ids (already answered, timed out, disconnected) are ignored.
    public func decide(_ id: UUID, _ decision: ApprovalDecision) {
        pending.removeAll { $0.id == id }
        engine?.decide(id, decision)
    }

    // MARK: Jumping to the terminal / app that hosts a session

    public func jump(to key: SessionKey) {
        acknowledge(key)                                   // pressing jump means the user is looking
        guard let s = sessions.first(where: { $0.key == key }) else { setNotice("That session is no longer running."); return }
        jumper.jump(to: s) { [weak self] result in
            MainActor.assumeIsolated {
                if case .failed(let message) = result { self?.setNotice(message) } else { self?.setNotice(nil) }
            }
        }
    }

    // MARK: "Finished since you last looked"

    /// Clears the completion flag of one session (jump, opening it, a new prompt also clear it).
    public func acknowledge(_ key: SessionKey) {
        engine?.acknowledge(key)
        setLocal { $0.key == key }
    }

    public func acknowledgeAll() {
        engine?.acknowledgeAll()
        setLocal { _ in true }
    }

    /// The user activated `bundleID`: sessions hosted there have been seen. Called by the NSWorkspace observer (tests inject one).
    func hostAppActivated(_ bundleID: String) {
        guard sessions.contains(where: { $0.hasUnseenCompletion && $0.hostAppBundleID == bundleID }) else { return }
        engine?.acknowledge(hostBundleID: bundleID)
        setLocal { $0.hostAppBundleID == bundleID }
    }

    /// Optimistic local update so the badge disappears immediately; the engine's next snapshot confirms it.
    private func setLocal(_ match: (AgentSession) -> Bool) {
        var changed = false
        var copy = sessions
        for i in copy.indices where copy[i].hasUnseenCompletion && match(copy[i]) { copy[i].hasUnseenCompletion = false; changed = true }
        guard changed else { return }
        sessions = copy
        unseenCompletionCount = copy.reduce(0) { $0 + ($1.hasUnseenCompletion ? 1 : 0) }
    }

    // MARK: Polling budget

    /// Call with true while the Agents tab / notch indicator is visible (one pass per 5 s), false otherwise (15-60 s).
    /// Nothing runs at all while the center is stopped.
    public func setNeedsFastPolling(_ on: Bool) {
        fastPolling = on
        engine?.setFastPolling(on)
    }

    // MARK: Hooks (explicit, user-initiated, reversible)

    public func previewHookChanges() -> String { hookInstaller.preview() }

    public func installHooks(claude: Bool, codex: Bool) {
        do {
            try hookInstaller.install(claude: claude, codex: codex)
            hooksState = hookInstaller.state()
            setNotice("Hooks installed. New agent sessions will report to Toplet.")
        } catch {
            hooksState = .error(error.localizedDescription)
        }
    }

    public func uninstallHooks() {
        do {
            try hookInstaller.uninstall()
            hooksState = hookInstaller.state()
            setNotice("Toplet hooks removed.")
        } catch {
            hooksState = .error(error.localizedDescription)
        }
    }

    public func refreshDiscovery() {
        hooksState = hookInstaller.state()
        engine?.refreshDiscovery()
    }

    // MARK: The user's board (sections and small tasks), persisted locally

    private func loadBoardIfNeeded() {
        guard !boardLoaded else { return }
        boardLoaded = true
        let store = BoardStore(url: config.boardURL ?? BoardStore.defaultURL(), debounce: config.boardDebounce)
        store.onError = { [weak self] message in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.setNotice(message) } }
        }
        boardStore = store
        suppressBoardSave = true
        board = store.load()
        suppressBoardSave = false
        if store.lastLoadWasCorrupt { setNotice("The board file was unreadable; a copy was kept as agents-board.json.corrupt.") }
        boardCancellable = $board.dropFirst().sink { [weak self] value in
            MainActor.assumeIsolated {
                guard let self = self, !self.suppressBoardSave else { return }
                self.boardStore?.scheduleSave(value)
            }
        }
    }

    private var totalTasks: Int { board.reduce(0) { $0 + $1.tasks.count } }

    @discardableResult public func addSection(title: String) -> UUID {
        let id = UUID()
        guard board.count < BoardStore.maxSections else { setNotice("The board is full (\(BoardStore.maxSections) sections)."); return id }
        let t = BoardStore.cleanTitle(title)
        board.append(BoardSection(id: id, title: t.isEmpty ? "Untitled" : t))
        return id
    }

    public func renameSection(_ id: UUID, to title: String) {
        let t = BoardStore.cleanTitle(title)
        guard !t.isEmpty, let i = board.firstIndex(where: { $0.id == id }) else { return }
        board[i].title = t
    }

    public func deleteSection(_ id: UUID) { board.removeAll { $0.id == id } }

    public func toggleCollapsed(_ id: UUID) {
        guard let i = board.firstIndex(where: { $0.id == id }) else { return }
        board[i].isCollapsed.toggle()
    }

    @discardableResult public func addTask(in section: UUID, title: String) -> UUID? {
        let t = BoardStore.cleanTitle(title)
        guard !t.isEmpty, let i = board.firstIndex(where: { $0.id == section }) else { return nil }
        guard totalTasks < BoardStore.maxTasks else { setNotice("The board is full (\(BoardStore.maxTasks) tasks)."); return nil }
        let task = BoardTask(title: t)
        board[i].tasks.append(task)
        return task.id
    }

    public func updateTask(_ id: UUID, title: String? = nil, notes: String? = nil) {
        guard let (s, t) = locate(task: id) else { return }
        if let title = title {
            let c = BoardStore.cleanTitle(title)
            if !c.isEmpty { board[s].tasks[t].title = c }
        }
        if let notes = notes { board[s].tasks[t].notes = BoardStore.cleanNotes(notes) }
    }

    public func toggleTask(_ id: UUID) {
        guard let (s, t) = locate(task: id) else { return }
        board[s].tasks[t].isDone.toggle()
    }

    public func deleteTask(_ id: UUID) {
        guard let (s, t) = locate(task: id) else { return }
        board[s].tasks.remove(at: t)
    }

    public func moveTask(_ id: UUID, toSection section: UUID, at index: Int) {
        guard let (s, t) = locate(task: id), let target = board.firstIndex(where: { $0.id == section }) else { return }
        let task = board[s].tasks.remove(at: t)
        let i = max(0, min(index, board[target].tasks.count))
        board[target].tasks.insert(task, at: i)
    }

    private func locate(task id: UUID) -> (Int, Int)? {
        for (s, sec) in board.enumerated() { if let t = sec.tasks.firstIndex(where: { $0.id == id }) { return (s, t) } }
        return nil
    }

    /// Starts a board task with an agent: Claude -> `claude --bg "<title>"` in `cwd` (supervised background session);
    /// Codex -> opens `codex://threads/new?prompt=&path=` (user presses send). Never auto-approves anything.
    public func startQuickTask(_ taskID: UUID, with agent: AgentKind, cwd: URL) {
        guard let (s, t) = locate(task: taskID) else { return }
        let title = board[s].tasks[t].title
        quickRunner.start(title: title, agent: agent, cwd: cwd) { [weak self] outcome in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.setNotice(outcome.message)
                guard outcome.kind != .failed, let (s2, t2) = self.locate(task: taskID) else { return }
                self.board[s2].tasks[t2].agent = agent
                if let id = outcome.sessionID { self.board[s2].tasks[t2].linkedSessionID = id }
            }
        }
    }
}
