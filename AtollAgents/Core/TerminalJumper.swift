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
#if canImport(AppKit)
import AppKit
#endif

// Jump table (research 4.3). This is the ONLY Core file that touches AppKit (NSWorkspace / NSRunningApplication).
// NEVER synthesises keystrokes and never uses Accessibility. Inputs that reach AppleScript are validated and escaped.

// MARK: - Seams (real implementations below, fakes in tests)

protocol AppleScriptRunning {
    func run(_ source: String) -> AppleScriptOutcome
}

enum AppleScriptOutcome: Equatable {
    case ok(String)
    case notAuthorized                 // Automation permission missing (error -1743)
    case failed(Int, String)
}

protocol URLOpening {
    @discardableResult func open(_ url: URL) -> Bool
}

protocol AppActivating {
    /// Activates a running app by bundle id. false when it is not running.
    func activate(bundleID: String) -> Bool
    func isRunning(bundleID: String) -> Bool
}

/// Reports which app the user just brought to the front (bundle id). Used to clear "finished since you last looked".
protocol ActivationObserving: AnyObject {
    func start(_ handler: @escaping (String) -> Void)
    func stop()
}

final class NoopActivationObserver: ActivationObserving {
    init() {}
    func start(_ handler: @escaping (String) -> Void) {}
    func stop() {}
}

struct NSAppleScriptRunner: AppleScriptRunning {
    init() {}
    func run(_ source: String) -> AppleScriptOutcome {
        guard let script = NSAppleScript(source: source) else { return .failed(-1, "could not compile script") }
        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        if let e = err {
            let code = (e[NSAppleScript.errorNumber] as? Int) ?? -1
            let msg = (e[NSAppleScript.errorMessage] as? String) ?? "AppleScript error"
            if code == -1743 { return .notAuthorized }
            return .failed(code, msg)
        }
        return .ok(result.stringValue ?? "")
    }
}

#if canImport(AppKit)
/// Idea credited to realfishsam/agent-notch (MIT): NSWorkspace.didActivateApplicationNotification. Own implementation.
final class WorkspaceActivationObserver: ActivationObserving {
    private var token: NSObjectProtocol?
    init() {}
    func start(_ handler: @escaping (String) -> Void) {
        guard token == nil else { return }
        token = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, let id = app.bundleIdentifier { handler(id) }
        }
    }
    func stop() {
        if let t = token { NSWorkspace.shared.notificationCenter.removeObserver(t); token = nil }
    }
}

struct WorkspaceURLOpener: URLOpening {
    init() {}
    @discardableResult func open(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }
}

struct WorkspaceAppActivator: AppActivating {
    init() {}
    func activate(bundleID: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return false }
        return app.activate()
    }
    func isRunning(bundleID: String) -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
}

/// The outermost `.app` containing the executable (Info.plist) wins: NSRunningApplication reports nested helper apps
/// ("Code Helper") under their own bundle id, which is not the terminal/IDE the user sees. NSRunningApplication is the
/// fallback for processes whose path is unknown.
final class RunningAppResolver: AppResolver {
    private let plist = PlistAppResolver()
    init() {}
    func bundleID(forPid pid: Int32, executablePath: String?) -> String? {
        if let id = plist.bundleID(forPid: pid, executablePath: executablePath) { return id }
        if executablePath == nil { return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier }
        return nil
    }
}
#else
typealias WorkspaceActivationObserver = NoopActivationObserver
struct WorkspaceURLOpener: URLOpening {
    init() {}
    @discardableResult func open(_ url: URL) -> Bool { false }
}
struct WorkspaceAppActivator: AppActivating {
    init() {}
    func activate(bundleID: String) -> Bool { false }
    func isRunning(bundleID: String) -> Bool { false }
}
typealias RunningAppResolver = PlistAppResolver
#endif

// MARK: - Escaping / validation

enum AppleScriptEscaper {
    /// A complete AppleScript string literal (with quotes) for arbitrary input: backslash and quote escaped,
    /// control characters dropped. Nothing in `s` can terminate the literal or start code.
    static func literal(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u.value {
            case 0x5C: out += "\\\\"
            case 0x22: out += "\\\""
            case 0..<0x20, 0x7F, 0x2028, 0x2029: out += " "
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }

    static let ttyPattern = try! NSRegularExpression(pattern: "^/dev/ttys[0-9]{1,5}\\z")
    static func isValidTTY(_ s: String) -> Bool {
        ttyPattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}

// MARK: - tmux

enum TmuxTool {
    struct Pane: Equatable { var tty: String; var target: String; var window: String; var session: String; var pid: Int32 }

    static let format = "#{pane_tty}\t#{session_name}\t#{window_index}\t#{pane_index}\t#{pane_pid}"

    static func parsePanes(_ out: String) -> [Pane] {
        var panes: [Pane] = []
        for line in out.split(separator: "\n").prefix(2000) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5, let pid = Int32(f[4]), Int(f[2]) != nil, Int(f[3]) != nil, !f[1].isEmpty, !f[1].hasPrefix("-") else { continue }
            panes.append(Pane(tty: f[0], target: "\(f[1]):\(f[2]).\(f[3])", window: "\(f[1]):\(f[2])", session: f[1], pid: pid))
        }
        return panes
    }

    static func locate() -> String? { ExecutableLocator.find("tmux") }

    static func listPanes(runner: ProcessRunning, tmux: String) -> [Pane] {
        let r = runner.run(executable: tmux, arguments: ["list-panes", "-a", "-F", format], cwd: nil, timeout: 1.5, maxOutput: 256 * 1024)
        return r.succeeded ? parsePanes(r.stdout) : []
    }

    /// session:window.pane of the pane whose tty is `tty`.
    static func target(forTTY tty: String, runner: ProcessRunning = SystemProcessRunner()) -> String? {
        guard AppleScriptEscaper.isValidTTY(tty), let tmux = locate() else { return nil }
        return listPanes(runner: runner, tmux: tmux).first(where: { $0.tty == tty })?.target
    }

    /// Argument arrays for the jump sequence (no shell): switch-client, select-window, select-pane.
    static func jumpCommands(for pane: Pane) -> [[String]] {
        [["switch-client", "-t", pane.session], ["select-window", "-t", pane.window], ["select-pane", "-t", pane.target]]
    }
}

// MARK: - Jumper

enum JumpResult: Equatable {
    case ok
    case failed(String)
}

final class TerminalJumper {
    static let denialCooldown: TimeInterval = 60

    let scripts: AppleScriptRunning
    let opener: URLOpening
    let activator: AppActivating
    let runner: ProcessRunning
    let pidAlive: (Int32, Date?) -> Bool
    let processCwd: (Int32) -> String?
    let now: () -> Date
    let locateTmux: () -> String?
    private var deniedAt: [String: Date] = [:]

    init(scripts: AppleScriptRunning = NSAppleScriptRunner(), opener: URLOpening = WorkspaceURLOpener(),
         activator: AppActivating = WorkspaceAppActivator(), runner: ProcessRunning = SystemProcessRunner(),
         pidAlive: @escaping (Int32, Date?) -> Bool = { ProcessLiveness.isAlive(pid: $0, expectedStart: $1) },
         processCwd: @escaping (Int32) -> String? = { LibprocSource().cwd($0) },
         now: @escaping () -> Date = Date.init, locateTmux: @escaping () -> String? = { TmuxTool.locate() }) {
        self.locateTmux = locateTmux
        self.scripts = scripts; self.opener = opener; self.activator = activator; self.runner = runner
        self.pidAlive = pidAlive; self.processCwd = processCwd; self.now = now
    }

    /// Checks done before any jump: the process is alive and, for passively discovered sessions, still in the claimed cwd.
    func validate(_ s: AgentSession) -> String? {
        if case .deepLink = s.jump { return nil }                  // thread deep links need no process
        if let pid = s.pid {
            guard pidAlive(pid, s.processStart) else { return "That session has ended." }
            if !s.isLive, !s.cwd.isEmpty, let actual = processCwd(pid), actual != s.cwd {
                return "That session no longer matches its process; refresh and try again."
            }
        }
        return nil
    }

    /// Jumps to the session's terminal/app. `completion` is always called on the main queue.
    func jump(to s: AgentSession, completion: @escaping (JumpResult) -> Void) {
        if let problem = validate(s) { finish(.failed(problem), completion); return }
        guard let target = s.jump else {
            if let b = s.hostAppBundleID { finish(activate(b, label: b), completion) }
            else { finish(.failed("No terminal or app is known for this session."), completion) }
            return
        }
        switch target {
        case .terminal(let bundleID, let tty):
            finish(jumpTerminal(bundleID: bundleID, tty: tty, cwd: s.cwd, title: s.title ?? s.name), completion)
        case .tmux(let t, let client):
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let r = jumpTmux(target: t, tty: s.tty, clientBundleID: client)
                finish(r, completion)
            }
        case .deepLink(let url):
            guard url.scheme == "codex" else { finish(.failed("Unsupported link."), completion); return }
            finish(opener.open(url) ? .ok : .failed("Could not open the Codex thread."), completion)
        case .app(let bundleID):
            finish(activate(bundleID, label: bundleID), completion)
        }
    }

    private func finish(_ r: JumpResult, _ completion: @escaping (JumpResult) -> Void) {
        if Thread.isMainThread { completion(r) } else { DispatchQueue.main.async { completion(r) } }
    }

    // MARK: Terminal.app / iTerm2 / Ghostty

    func jumpTerminal(bundleID: String, tty: String?, cwd: String, title: String?) -> JumpResult {
        let name = TerminalJumper.displayName(bundleID)
        if let d = deniedAt[bundleID], now().timeIntervalSince(d) < TerminalJumper.denialCooldown {
            _ = activator.activate(bundleID: bundleID)
            return .failed("Toplet needs Automation permission to control \(name) (System Settings > Privacy & Security > Automation).")
        }
        guard activator.isRunning(bundleID: bundleID) else { return .failed("\(name) is not running.") }
        guard let script = TerminalJumper.script(bundleID: bundleID, tty: tty, cwd: cwd) else {
            return activate(bundleID, label: name)           // no per-tab control for this terminal: activate it
        }
        switch scripts.run(script) {
        case .ok(let out):
            if out == "notfound" { _ = activator.activate(bundleID: bundleID); return .failed("Could not find that session's tab in \(name); activated it instead.") }
            return .ok
        case .notAuthorized:
            deniedAt[bundleID] = now()
            _ = activator.activate(bundleID: bundleID)
            return .failed("Toplet needs Automation permission to control \(name) (System Settings > Privacy & Security > Automation).")
        case .failed(_, _):
            _ = activator.activate(bundleID: bundleID)
            return .failed("Could not switch to the session in \(name); activated it instead.")
        }
    }

    /// AppleScript for the terminal, or nil when the terminal has no scriptable per-tab focus. Inputs are validated/escaped.
    static func script(bundleID: String, tty: String?, cwd: String) -> String? {
        switch bundleID {
        case "com.apple.Terminal":
            guard let tty = tty, AppleScriptEscaper.isValidTTY(tty) else { return nil }
            let t = AppleScriptEscaper.literal(tty)
            return """
            tell application id "com.apple.Terminal"
              activate
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is \(t) then
                    set selected tab of w to t
                    set index of w to 1
                    return "ok"
                  end if
                end repeat
              end repeat
              return "notfound"
            end tell
            """
        case "com.googlecode.iterm2":
            guard let tty = tty, AppleScriptEscaper.isValidTTY(tty) else { return nil }
            let t = AppleScriptEscaper.literal(tty)
            return """
            tell application id "com.googlecode.iterm2"
              activate
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is \(t) then
                      select w
                      tell w to select t
                      select s
                      return "ok"
                    end if
                  end repeat
                end repeat
              end repeat
              return "notfound"
            end tell
            """
        case "com.mitchellh.ghostty":
            guard !cwd.isEmpty else { return nil }
            let c = AppleScriptEscaper.literal(cwd)
            return """
            tell application id "com.mitchellh.ghostty"
              set matches to every terminal whose working directory is \(c)
              if (count of matches) is 0 then return "notfound"
              focus (item 1 of matches)
              activate
              return "ok"
            end tell
            """
        default:
            return nil
        }
    }

    static func displayName(_ bundleID: String) -> String {
        switch bundleID {
        case "com.apple.Terminal": return "Terminal"
        case "com.googlecode.iterm2": return "iTerm2"
        case "com.mitchellh.ghostty": return "Ghostty"
        case "com.microsoft.VSCode": return "VS Code"
        case "com.todesktop.230313mzl4w4u92": return "Cursor"
        default: return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        }
    }

    // MARK: tmux

    func jumpTmux(target: String, tty: String?, clientBundleID: String?) -> JumpResult {
        guard let tmux = locateTmux() else { return .failed("tmux was not found.") }
        var pane: TmuxTool.Pane?
        let panes = TmuxTool.listPanes(runner: runner, tmux: tmux)
        if let tty = tty { pane = panes.first(where: { $0.tty == tty }) }
        if pane == nil { pane = panes.first(where: { $0.target == target }) }
        guard let p = pane else { return .failed("That tmux pane no longer exists.") }
        for (i, args) in TmuxTool.jumpCommands(for: p).enumerated() {
            let r = runner.run(executable: tmux, arguments: args, cwd: nil, timeout: 1.5, maxOutput: 4096)
            // switch-client fails when no client is attached to the current session context: not fatal.
            if !r.succeeded && i > 0 { return .failed("tmux could not select the pane.") }
        }
        if let b = clientBundleID { _ = activator.activate(bundleID: b) }
        return .ok
    }

    // MARK: Plain activation

    func activate(_ bundleID: String, label: String) -> JumpResult {
        activator.activate(bundleID: bundleID) ? .ok : .failed("\(TerminalJumper.displayName(label)) is not running.")
    }
}
