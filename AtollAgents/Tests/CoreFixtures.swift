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

// FIXTURES: doc-derived, NOT yet recorded from a live session. They follow docs/AI-AGENTS-RESEARCH.md sections 2.2,
// 3.3 and 3.6. Field names are high-confidence but not byte-exact; the parsers must tolerate variations.

enum Fx {
    static let sid = "5f0e3c1a-1111-4222-8333-444455556666"
    static let cwd = "/Users/dev/proj"

    /// Common Claude hook fields (research 2.2).
    static func claude(_ event: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var o: [String: Any] = [
            "session_id": sid, "prompt_id": "9d6f0c0e-0000-4000-8000-000000000001",
            "transcript_path": "/Users/dev/.claude/projects/-Users-dev-proj/\(sid).jsonl",
            "cwd": cwd, "permission_mode": "default", "hook_event_name": event,
        ]
        for (k, v) in extra { o[k] = v }
        return o
    }

    static func codex(_ event: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var o: [String: Any] = [
            "session_id": "0198aaaa-bbbb-7ccc-8ddd-eeeeffff0000", "transcript_path": NSNull(), "cwd": cwd,
            "hook_event_name": event, "model": "gpt-5-codex", "permission_mode": "default", "turn_id": "turn-1",
        ]
        for (k, v) in extra { o[k] = v }
        return o
    }

    static let codexSID = "0198aaaa-bbbb-7ccc-8ddd-eeeeffff0000"

    static let claudeEvents: [(name: String, json: [String: Any])] = [
        ("SessionStart", claude("SessionStart", ["source": "startup", "model": "claude-opus-4-7"])),
        ("SessionEnd", claude("SessionEnd", ["reason": "other"])),
        ("UserPromptSubmit", claude("UserPromptSubmit", ["prompt": "fix the failing test"])),
        ("PreToolUse", claude("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "npm test", "description": "Run tests"], "tool_use_id": "toolu_01"])),
        ("PermissionRequest", claude("PermissionRequest", [
            "tool_name": "Bash", "tool_input": ["command": "npm test"],
            "permission_suggestions": [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "npm test:*"]], "behavior": "allow", "destination": "localSettings"]],
        ])),
        ("PostToolUse", claude("PostToolUse", ["tool_name": "Bash", "tool_input": ["command": "npm test"], "tool_response": ["stdout": "ok"], "tool_use_id": "toolu_01", "duration_ms": 1234])),
        ("PostToolUseFailure", claude("PostToolUseFailure", ["tool_name": "Bash", "tool_input": ["command": "false"], "tool_use_id": "toolu_02", "error": "exit 1"])),
        ("PermissionDenied", claude("PermissionDenied", ["tool_name": "Bash", "reason": "denied by rule"])),
        ("Notification", claude("Notification", ["message": "Claude is waiting for your input", "notification_type": "idle_prompt"])),
        ("Stop", claude("Stop", ["stop_hook_active": false, "last_assistant_message": "Done. All tests pass."])),
        ("StopFailure", claude("StopFailure", ["error": "rate_limit"])),
        ("SubagentStart", claude("SubagentStart", ["agent_id": "agent-1", "agent_type": "Explore"])),
        ("SubagentStop", claude("SubagentStop", ["agent_id": "agent-1", "agent_type": "Explore", "last_assistant_message": "found it", "agent_transcript_path": "/x/subagents/agent-agent-1.jsonl"])),
        ("TaskCreated", claude("TaskCreated", ["task_id": "1", "task_subject": "Write tests"])),
        ("TaskCompleted", claude("TaskCompleted", ["task_id": "1", "task_subject": "Write tests"])),
        ("PreCompact", claude("PreCompact", ["trigger": "auto"])),
        ("PostCompact", claude("PostCompact", ["trigger": "auto", "compact_summary": "..."])),
    ]

    static let codexEvents: [(name: String, json: [String: Any])] = [
        ("SessionStart", codex("SessionStart", ["source": "startup"])),
        ("UserPromptSubmit", codex("UserPromptSubmit", ["prompt": "add a unit test"])),
        ("PreToolUse", codex("PreToolUse", ["tool_name": "exec_command", "tool_input": ["cmd": "ls -la"], "tool_use_id": "call_1"])),
        ("PermissionRequest", codex("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "rm -rf build", "description": "Remove build output"]])),
        ("PostToolUse", codex("PostToolUse", ["tool_name": "exec_command", "tool_input": ["cmd": "ls -la"], "tool_response": ["output": "x"], "tool_use_id": "call_1"])),
        ("Stop", codex("Stop", ["stop_hook_active": false, "last_assistant_message": "Finished."])),
        ("Interrupt", codex("Interrupt")),
        ("SubagentStart", codex("SubagentStart", ["agent_id": "sub-9", "agent_type": "worker"])),
        ("SubagentStop", codex("SubagentStop", ["agent_id": "sub-9", "agent_type": "worker", "agent_transcript_path": "/x"])),
        ("SessionEnd", codex("SessionEnd", ["reason": "other"])),
        ("PreCompact", codex("PreCompact", ["trigger": "auto"])),
    ]

    /// A rollout line (research 3.6): {timestamp, type, payload}.
    static func rollout(_ type: String, _ payload: [String: Any], ts: String = "2026-10-21T09:00:00.000Z") -> [String: Any] {
        ["timestamp": ts, "type": type, "payload": payload]
    }

    static func eventMsg(_ t: String, _ extra: [String: Any] = [:], ts: String = "2026-10-21T09:00:00.000Z") -> [String: Any] {
        var p: [String: Any] = ["type": t]
        for (k, v) in extra { p[k] = v }
        return rollout("event_msg", p, ts: ts)
    }

    static let rolloutLines: [[String: Any]] = [
        rollout("session_meta", ["id": codexSID, "cwd": cwd, "cli_version": "0.163.0", "model_provider": "openai"]),
        rollout("turn_context", ["cwd": cwd, "model": "gpt-5-codex", "approval_policy": "on-request"]),
        eventMsg("task_started"), eventMsg("turn_started"),
        eventMsg("user_message", ["message": "refactor the parser"]),
        eventMsg("agent_message", ["message": "Working on it."]),
        eventMsg("plan_update", ["plan": [["step": "Read code", "status": "completed"], ["step": "Edit", "status": "in_progress"], ["step": "Test", "status": "pending"]]]),
        eventMsg("exec_approval_request", ["command": ["bash", "-lc", "make"]]),
        eventMsg("apply_patch_approval_request", ["call_id": "c1"]),
        eventMsg("request_permissions", [:]),
        eventMsg("request_user_input", [:]),
        eventMsg("exec_command_begin", ["call_id": "c2", "command": ["bash", "-lc", "make"]]),
        eventMsg("exec_command_end", ["call_id": "c2", "exit_code": 0]),
        eventMsg("patch_apply_begin", ["call_id": "c3", "changes": ["src/a.swift": [:]]]),
        eventMsg("patch_apply_end", ["call_id": "c3", "success": true]),
        eventMsg("mcp_tool_call_begin", ["call_id": "c4", "invocation": ["server": "gh", "tool": "pr"]]),
        eventMsg("mcp_tool_call_end", ["call_id": "c4"]),
        eventMsg("token_count", ["info": ["total_token_usage": ["total_tokens": 1000], "last_token_usage": ["total_tokens": 20000], "model_context_window": 200000],
                                 "rate_limits": ["primary": ["used_percent": 12.5, "window_minutes": 300], "secondary": ["used_percent": 40.0, "window_minutes": 10080]]]),
        eventMsg("context_compacted"),
        eventMsg("collab_agent_spawn_begin", ["call_id": "s1"]), eventMsg("collab_agent_spawn_end", ["call_id": "s1", "new_thread_id": "child1", "status": "running"]),
        eventMsg("sub_agent_activity", ["agent_thread_id": "s2"]),
        eventMsg("task_complete", ["last_agent_message": "All done."]), eventMsg("turn_complete"),
        eventMsg("turn_aborted"), eventMsg("shutdown_complete"),
        rollout("response_item", ["type": "function_call", "name": "update_plan", "arguments": "{\"plan\":[{\"step\":\"A\",\"status\":\"pending\"}]}"]),
        rollout("response_item", ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Hello from the model"]]]),
        rollout("compacted", [:]),
    ]
}
