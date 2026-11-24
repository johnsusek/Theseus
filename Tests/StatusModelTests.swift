import Foundation
import Testing
@testable import ClaudeEngine

struct StatusModelTests {
  let english = Locale(identifier: "en_US")

  func agentCall(_ id: String, _ description: String, type: String = "Explore", at time: String = "10:00:00") -> JSONValue {
    call(id, "Agent", ["description": .string(description), "subagent_type": .string(type)], at: time)
  }

  func inside(_ agent: String, _ id: String, _ name: String, _ input: JSONValue) -> JSONValue {
    ["type": "assistant", "message": ["id": "m", "model": "x", "content": [["type": "tool_use", "id": .string(id), "name": .string(name), "input": input]]], "parent_tool_use_id": .string(agent)]
  }

  @Test func tooltipsCountOneAndMany() {
    var state = StatusRowState(runningAgents: 1, changedFiles: 1)

    #expect(state.agentsTooltip == "1 Agent Running")
    #expect(state.changesTooltip == "1 Changed File")

    state.runningAgents = 3
    state.changedFiles = 12
    #expect(state.agentsTooltip == "3 Agents Running")
    #expect(state.changesTooltip == "12 Changed Files")
  }

  @Test func contextTooltipShortensCounts() {
    let state = StatusRowState(contextUsed: 54_800, contextMax: 200_000)

    #expect(state.contextTooltip(locale: english) == "Context: 54.8k of 200k tokens (27%)")
    #expect(state.contextFraction == 0.274)
    #expect(StatusRowState(contextUsed: 950, contextMax: 1_000_000).contextTooltip(locale: english) == "Context: 950 of 1M tokens (0%)")
    #expect(StatusRowState(contextUsed: 300, contextMax: 200).contextFraction == 1)
    #expect(StatusRowState().contextFraction == 0)
  }

  @Test func timesReadAsClocksAndSpans() {
    #expect(timerText(7) == "0:07")
    #expect(timerText(199) == "3:19")
    #expect(timerText(3723) == "1:02:03")
    #expect(elapsedText(48) == "48s")
    #expect(elapsedText(124) == "2m 04s")
    #expect(elapsedText(3725) == "1h 02m")
    #expect(tokenCount(18_230, locale: english) == "18.2k tokens")
    #expect(tokenCount(412, locale: english) == "412 tokens")
  }

  @Test func namesForModelsEffortsAndModes() throws {
    func model(_ value: String, _ name: String, _ resolved: String) throws -> InitializeInfo.Model {
      try JSONValue.object(["value": .string(value), "displayName": .string(name), "description": "", "resolvedModel": .string(resolved)]).decode(InitializeInfo.Model.self)
    }

    let models = [try model("default", "Default (recommended)", "claude-opus-5-5"), try model("opus", "Opus 5.5", "claude-opus-5-5"), try model("haiku", "Haiku 5.5", "claude-haiku-5-5")]

    #expect(modelName(models[0], id: "claude-opus-5-5", among: models) == "Opus 5.5")
    #expect(modelName(models[2], id: "claude-haiku-5-5", among: models) == "Haiku 5.5")
    #expect(modelName(models[0], id: nil, among: [models[0]]) == "Default (recommended)")
    #expect(modelName(nil, id: "claude-custom", among: models) == "claude-custom")
    #expect(modelName(nil, id: nil, among: models) == "Unknown Model")
    #expect(["low", "medium", "high", "xhigh", "max"].map(effortName) == ["Low", "Medium", "High", "Extra High", "Max"])
    #expect([PermissionMode.default, .acceptEdits, .plan, .auto, .bypassPermissions].map(modeName) == ["Ask", "Accept Edits", "Plan", "Auto", "Bypass Permissions"])
  }

  @Test func activityPrefersApprovalThenSummaryThenTheRunningCall() throws {
    let idle = try transcript([prompt("Go"), said("Looking.")])
    let reading = try transcript([prompt("Go"), call("t1", "Read", ["file_path": "/tmp/a.swift"]), returned("t1", "ok"), call("t2", "Bash", ["command": "swift test"])])

    #expect(activityLine(summary: nil, isWaiting: false, transcript: idle) == "Thinking")
    #expect(activityLine(summary: nil, isWaiting: false, transcript: reading) == "Running swift\u{2026}")
    #expect(activityLine(summary: "Running the tests", isWaiting: false, transcript: reading) == "Running the tests")
    #expect(activityLine(summary: "Running the tests", isWaiting: true, transcript: reading) == "Waiting for approval")
    #expect(activityLine(summary: "", isWaiting: false, transcript: reading) == "Running swift\u{2026}")
  }

  @Test func agentRowsPutRunningFirstAndSayWhatEachIsDoing() throws {
    let frames: [JSONValue] = [
      prompt("Go"),
      agentCall("done", "Find every makeNSView", type: "general-purpose", at: "10:00:00"),
      returned("done", "3 views read the theme once\nDetails follow", output: ["status": "completed", "agentId": "a-done"], at: "10:00:48"),
      agentCall("broken", "Check the diff viewer", at: "10:00:50"),
      returned("broken", "The agent hit an error", isError: true, at: "10:00:51"),
      agentCall("reading", "SSH terminal theme handling", at: "10:01:00"),
      ["type": "system", "subtype": "task_started", "task_id": "a-reading", "tool_use_id": "reading", "task_type": "local_agent", "description": "SSH terminal theme handling"],
      inside("reading", "r1", "Read", ["file_path": "/tmp/RemoteTerminalView.swift"]),
      ["type": "system", "subtype": "task_progress", "task_id": "a-reading", "tool_use_id": "reading", "description": "Reading RemoteTerminalView.swift", "usage": ["total_tokens": 18_230, "tool_uses": 1, "duration_ms": 900]],
      agentCall("thinking", "Diff viewer theme handling", at: "10:01:05")
    ]
    var transcript = try transcript(frames)
    let rows = agentRows(transcript, locale: english)

    #expect(rows.map(\.id) == ["reading", "thinking", "done", "broken"])
    #expect(rows.map(\.state) == [.running, .running, .done, .failed])
    #expect(rows.map(\.title) == ["SSH terminal theme handling", "Diff viewer theme handling", "Find every makeNSView", "Check the diff viewer"])
    #expect(rows.map(\.detail) == ["Explore \u{B7} Reading RemoteTerminalView.swift", "Explore \u{B7} Thinking", "general-purpose \u{B7} Finished: 3 views read the theme once \u{2026}", "Explore \u{B7} Failed: The agent hit an error"])
    #expect(rows.map(\.taskId) == ["a-reading", nil, "a-done", nil])
    #expect(rows[0].tokens == "18.2k tokens")
    #expect(rows[1].tokens == "")
    #expect(rows[0].duration == nil)
    #expect(rows[2].duration == .seconds(48))

    // The process is gone, so nothing is still running.
    transcript.stopActiveTasks()
    #expect(agentRows(transcript).map(\.state) == [.done, .failed, .stopped, .stopped])
    #expect(agentRows(transcript).last?.detail == "Explore \u{B7} Stopped")
  }

  @Test func changeRowsNameTheFolderBelowTheProject() throws {
    func write(_ id: String, _ path: String, lines: [String]) -> [JSONValue] {
      [call(id, "Edit", ["file_path": .string(path)]), returned(id, "ok", output: ["filePath": .string(path), "structuredPatch": [["lines": .array(lines.map(JSONValue.string))]]])]
    }

    let transcript = try transcript([prompt("Go")] + write("e1", "/tmp/repo/Sources/Theme/TerminalTheme.swift", lines: ["+a", "+b", "-c"]) + write("e2", "/tmp/repo/README.md", lines: ["+a"]) + write("e3", "/tmp/elsewhere/notes.txt", lines: ["-a"]) + write("e4", "/tmp/repo/README.md", lines: ["-b"]))
    let rows = changeRows(transcript.changedFiles, base: URL(filePath: "/tmp/repo/"))

    #expect(rows.map(\.name) == ["TerminalTheme.swift", "README.md", "notes.txt"])
    #expect(rows.map(\.folder) == ["Sources/Theme", "", "/tmp/elsewhere"])
    #expect(rows.map(\.added) == [2, 1, 0])
    #expect(rows.map(\.removed) == [1, 1, 1])
  }
}
