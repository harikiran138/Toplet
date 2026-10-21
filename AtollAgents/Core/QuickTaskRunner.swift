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

/// Starts a board task with an agent. Runs only on an explicit user click.
/// Claude: `claude --bg <title>` (argument array, never a shell) in `cwd`. Codex: opens `codex://threads/new?...` and
/// the user presses send. No auto-approve or permission-skipping flag is ever passed.
final class QuickTaskRunner {
    struct Outcome: Equatable {
        enum Kind: Equatable { case started, opened, failed }
        var kind: Kind
        var message: String
        var sessionID: String?          // AgentSession.id style ("claude:<id>") when the output named one
        var output: String
    }

    static let maxPromptLength = 1000
    static let maxOutput = 16 * 1024

    let runner: ProcessRunning
    let opener: URLOpening
    let locateClaude: () -> String?

    init(runner: ProcessRunning = SystemProcessRunner(), opener: URLOpening = WorkspaceURLOpener(),
         locateClaude: @escaping () -> String? = { ExecutableLocator.find("claude") }) {
        self.runner = runner; self.opener = opener; self.locateClaude = locateClaude
    }

    // MARK: Pure helpers

    static func prompt(from title: String) -> String { AgentText.clean(title, max: maxPromptLength) }

    /// Exactly ["--bg", <prompt>]: never any auto-approve flag. A leading dash would be parsed as an option, so it is prefixed.
    static func claudeArguments(prompt: String) -> [String] {
        ["--bg", prompt.hasPrefix("-") ? "Task: " + prompt : prompt]
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func percentEncode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }

    /// `codex://threads/new?prompt=<pct>&path=<pct>`
    static func codexURL(prompt: String, cwd: String) -> URL? {
        URL(string: "codex://threads/new?prompt=\(percentEncode(prompt))&path=\(percentEncode(cwd))")
    }

    static let uuidPattern = try! NSRegularExpression(pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

    /// The id `claude --bg` prints (a UUID, or failing that nothing: we never invent one).
    static func extractSessionID(from output: String) -> String? {
        guard let m = uuidPattern.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let r = Range(m.range, in: output) else { return nil }
        return String(output[r]).lowercased()
    }

    // MARK: Start

    /// `completion` is called on the main queue.
    func start(title: String, agent: AgentKind, cwd: URL, completion: @escaping (Outcome) -> Void) {
        let prompt = QuickTaskRunner.prompt(from: title)
        func done(_ o: Outcome) { DispatchQueue.main.async { completion(o) } }
        guard !prompt.isEmpty else { return done(Outcome(kind: .failed, message: "The task has no title.", sessionID: nil, output: "")) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDir), isDir.boolValue else {
            return done(Outcome(kind: .failed, message: "The folder \(AgentText.shortPath(cwd.path, max: 60)) does not exist.", sessionID: nil, output: ""))
        }
        switch agent {
        case .claudeCode:
            guard let claude = locateClaude() else {
                return done(Outcome(kind: .failed, message: "Could not find the claude command (checked PATH, ~/.local/bin and Homebrew).", sessionID: nil, output: ""))
            }
            let args = QuickTaskRunner.claudeArguments(prompt: prompt)
            DispatchQueue.global(qos: .userInitiated).async { [runner] in
                let r = runner.run(executable: claude, arguments: args, cwd: cwd.path, timeout: 30, maxOutput: QuickTaskRunner.maxOutput)
                if let e = r.launchError { return done(Outcome(kind: .failed, message: "Could not start claude: \(AgentText.clean(e, max: 120))", sessionID: nil, output: "")) }
                if r.timedOut { return done(Outcome(kind: .failed, message: "claude did not answer in time.", sessionID: nil, output: AgentText.clean(r.stdout, max: 300))) }
                let text = (r.stdout + "\n" + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                let shown = AgentText.clean(text, max: 300)
                guard r.status == 0 else {
                    return done(Outcome(kind: .failed, message: "claude failed: " + (shown.isEmpty ? "exit \(r.status)" : AgentText.clean(shown, max: 160)), sessionID: nil, output: shown))
                }
                let id = QuickTaskRunner.extractSessionID(from: text).map { "claude:\($0)" }
                let first = AgentText.clean(text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "", max: 120)
                done(Outcome(kind: .started, message: first.isEmpty ? "Started in the background." : "Started in the background: \(first)", sessionID: id, output: shown))
            }
        case .codex:
            guard let url = QuickTaskRunner.codexURL(prompt: prompt, cwd: cwd.path) else {
                return done(Outcome(kind: .failed, message: "Could not build the Codex link.", sessionID: nil, output: ""))
            }
            DispatchQueue.main.async { [opener] in
                let ok = opener.open(url)
                completion(ok ? Outcome(kind: .opened, message: "Opened in Codex: press send to start it.", sessionID: nil, output: "")
                              : Outcome(kind: .failed, message: "Could not open Codex (is it installed?).", sessionID: nil, output: ""))
            }
        }
    }
}
