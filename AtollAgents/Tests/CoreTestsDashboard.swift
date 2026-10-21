import Foundation

func runDashboardTests() async {
    section("Dashboard models and accounting")
    let now = Date()
    var timer = AgentFocusTimer()
    timer.start(at: now)
    eq(Int(timer.remaining(at: now.addingTimeInterval(60))), 1440, "focus deadline subtracts elapsed time")
    timer.pause(at: now.addingTimeInterval(60))
    eq(Int(timer.remaining(at: now.addingTimeInterval(3600))), 1440, "paused focus does not consume time")
    timer.start(at: now.addingTimeInterval(3600))
    check(timer.finished(at: now.addingTimeInterval(6000)), "focus completes through sleep or inactive view")
    timer.reset(minutes: 15)
    eq(Int(timer.remaining(at: now)), 900, "focus presets reset the deadline")
    var game = AgentPairsGame()
    game.cards = [0, 1, 0, 1, 2, 2, 3, 3]
    game.reveal(0); game.reveal(1)
    eq(game.moves, 1, "pairs mismatch counts one move")
    game.reveal(0); game.reveal(2)
    eq(game.matched, Set([0, 2]), "new selection clears mismatch and matches pair")
    game.reveal(0)
    eq(game.moves, 2, "matched card cannot be selected again")
    check(AgentText.userFacingPrompt("<send_user_message_question_reply>private envelope") == nil, "internal Codex reply is hidden")
    check(AgentText.userFacingPrompt("<task-notification>background result</task-notification>") == nil, "Claude background task envelopes are hidden")
    check(AgentText.userFacingPrompt("<teammate-message teammate_id=\"a\">internal relay</teammate-message>") == nil, "team relay envelopes are hidden")
    eq(AgentText.userFacingPrompt("Improve the <header> component"), "Improve the <header> component", "ordinary markup in real prompts survives")
    var parent = AgentSession(key: SessionKey(kind: .claudeCode, id: "session"), cwd: "/project", status: .running)
    parent.tasks = [AgentTask(id: "1", title: "Done", status: .completed), AgentTask(id: "2", title: "Skipped", status: .cancelled)]
    parent.subagents = [Subagent(id: "idle", status: .idle), Subagent(id: "waiting", status: .waiting)]
    var completed = parent
    completed.status = .idle
    check(AgentActivityNotice.transition(from: parent, to: completed, at: now)?.category == .completed, "running to idle creates a turn-finished notice")
    check(AgentActivityNotice.transition(from: completed, to: completed, at: now) == nil, "unchanged discovery does not repeat notices")
    completed.status = .needsPermission
    check(AgentActivityNotice.transition(from: parent, to: completed, at: now)?.category == .needsYou, "permission requests are classified separately")
    let counts = AgentActivitySummary.make([parent])
    eq(counts.tasksTotal, 1, "cancelled tasks excluded from denominator")
    eq(counts.subagentsIdle, 1, "idle subagents counted separately")
    eq(counts.subagentsWaiting, 1, "waiting subagents counted separately")

    let tmp = URL(fileURLWithPath: makeTmp("usage"))
    let claude = tmp.appendingPathComponent("claude")
    let codex = tmp.appendingPathComponent("codex")
    try! FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
    func claudeLine(_ output: Int, _ id: String = "response") -> String {
        "{\"type\":\"assistant\",\"sessionId\":\"session\",\"timestamp\":\"\(stamp)\",\"cwd\":\"/projects/demo\",\"message\":{\"id\":\"\(id)\",\"model\":\"claude\",\"usage\":{\"input_tokens\":10,\"output_tokens\":\(output),\"cache_read_input_tokens\":100,\"cache_creation_input_tokens\":5}}}\n"
    }
    let file = claude.appendingPathComponent("session.jsonl")
    try! (claudeLine(2) + claudeLine(7)).write(to: file, atomically: true, encoding: .utf8)
    let checkpoint = tmp.appendingPathComponent("checkpoint.json")
    let history = AgentUsageHistory(claudeRoot: claude, codexRoot: codex, archiveURL: checkpoint, saveInterval: 0)
    let first = await history.refresh(now: now)
    eq(first.totals(since: now.addingTimeInterval(-3600), until: now).total, 122, "streamed Claude response counted once with cache components")
    let again = await history.refresh(now: now)
    eq(again.records, first.records, "unchanged refresh is idempotent")
    let restarted = AgentUsageHistory(claudeRoot: claude, codexRoot: codex, archiveURL: checkpoint, saveInterval: 0)
    let restored = await restarted.refresh(now: now)
    eq(restored.records, first.records, "checkpoint restore does not double count")
    let append = try! FileHandle(forWritingTo: file)
    try! append.seekToEnd(); try! append.write(contentsOf: Data(claudeLine(3, "second").utf8)); try! append.close()
    let updated = await restarted.refresh(now: now)
    eq(updated.records.count, 2, "incremental append adds only new requests")
    eq(updated.totals(for: parent.key).total, 240, "session attribution includes deduplicated request totals")
    func codexLine(_ input: Int, _ output: Int) -> String {
        "{\"type\":\"event_msg\",\"timestamp\":\"\(stamp)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\"cached_input_tokens\":20}}}}\n"
    }
    let cx = codex.appendingPathComponent("thread.jsonl")
    try! (codexLine(100, 10) + codexLine(100, 10) + codexLine(150, 20)).write(to: cx, atomically: true, encoding: .utf8)
    let withCodex = await restarted.refresh(now: now)
    eq(withCodex.totals(since: now.addingTimeInterval(-3600), until: now, kind: .codex).total, 170, "Codex cumulative counters use deltas, not repeated sums")
    eq(withCodex.totals(since: now.addingTimeInterval(-30), until: now).total, 0, "time-window boundary excludes older usage")
    try! codexLine(150, 20).write(to: cx, atomically: true, encoding: .utf8)
    let codexRotated = await restarted.refresh(now: now)
    eq(codexRotated.totals(since: now.addingTimeInterval(-3600), until: now, kind: .codex).total, 170, "truncated Codex log reuses cumulative snapshot identity without inflating a prior delta")
    // Truncation/rotation replays safely because Claude response IDs remain stable.
    try! claudeLine(7).write(to: file, atomically: true, encoding: .utf8)
    let rotated = await restarted.refresh(now: now)
    eq(rotated.records.filter { $0.kind == .claudeCode }.count, 2, "log rotation does not duplicate known responses or erase historical requests")
    let checkpointBefore = (try! Data(contentsOf: checkpoint)).count
    let oversizedModel = claudeLine(1, "long-model").replacingOccurrences(of: "\"model\":\"claude\"", with: "\"model\":\"" + String(repeating: "x", count: 200_000) + "\"")
    try! oversizedModel.write(to: claude.appendingPathComponent("long-model.jsonl"), atomically: true, encoding: .utf8)
    _ = await restarted.refresh(now: now)
    let checkpointAfter = (try! Data(contentsOf: checkpoint)).count
    check(checkpointAfter - checkpointBefore < 2_000, "a 200 KB model field cannot bloat the usage checkpoint")

    // The multi-MB checkpoint is written at most once per saveInterval, and flush() writes what is pending.
    let slowFile = tmp.appendingPathComponent("slow-checkpoint.json")
    let slow = AgentUsageHistory(claudeRoot: claude, codexRoot: codex, archiveURL: slowFile, saveInterval: 60)
    let firstSlow = await slow.refresh(now: now)
    check(FileManager.default.fileExists(atPath: slowFile.path), "first refresh writes the checkpoint")
    let savedSize = (try! Data(contentsOf: slowFile)).count
    let append2 = try! FileHandle(forWritingTo: file)
    try! append2.seekToEnd(); try! append2.write(contentsOf: Data(claudeLine(4, "third").utf8)); try! append2.close()
    let soon = await slow.refresh(now: now.addingTimeInterval(10))
    eq(soon.records.count, firstSlow.records.count + 1, "new usage is reported immediately")
    eq((try! Data(contentsOf: slowFile)).count, savedSize, "a change within the save interval is not written yet")
    let unchanged = await slow.refresh(now: now.addingTimeInterval(20))
    eq(unchanged, soon, "an unchanged refresh returns an identical report")
    await slow.flush()
    check((try! Data(contentsOf: slowFile)).count > savedSize, "flush writes pending changes")

}
