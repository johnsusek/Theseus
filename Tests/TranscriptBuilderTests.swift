import Foundation
import Testing
@testable import ClaudeEngine

struct TranscriptBuilderTests {
  let patch: JSONValue = [["oldStart": 1, "oldLines": 2, "newStart": 1, "newLines": 3, "lines": [" keep", "-old", "+new", "+more"]]]

  func shapes(_ transcript: Transcript, streaming: [StreamingMessage.Block] = [], isLive: Bool = false, change: (inout TranscriptBuilder) -> Void = { _ in }) -> [String] {
    var builder = makeBuilder()
    change(&builder)
    return builder.elements(for: TranscriptInput(header: "Started in Theseus", transcript: transcript, streaming: streaming, isLive: isLive)).map(\.shape)
  }

  @Test func turnReadsPromptReplyToolsAndFooter() throws {
    let transcript = try transcript([
      prompt("Add dates"),
      said("Reading first."),
      call("t1", "Read", ["file_path": "/tmp/A.swift"]), returned("t1", "a"),
      call("t2", "Read", ["file_path": "/tmp/B.swift"]), returned("t2", "b"),
      call("t3", "Bash", ["command": "swift test"]), returned("t3", "ok"),
      call("t4", "Bash", ["command": "swift build"]), returned("t4", "error", isError: true),
      call("t5", "Edit", ["file_path": "/tmp/A.swift"]), returned("t5", "done", output: ["structuredPatch": patch]),
      said("Done."),
      finished()
    ])

    #expect(shapes(transcript) == [
      "header", "prompt(Add dates)", "reply(Reading first.)", "group(Read 2 files, ran a command)", "tool(Ran swift build)", "tool(Edited A.swift)", "reply(Done.)", "footer(1m 52s)"
    ])
  }

  @Test func footerGivesTheStartAndTheDuration() throws {
    var builder = makeBuilder()
    let elements = builder.elements(for: TranscriptInput(transcript: try transcript([prompt("Go", at: "14:14:00"), said("Done."), finished()])))

    guard case .footer(let text) = elements.last?.kind else { return #expect(Bool(false), "The footer is missing") }

    #expect(text.hasPrefix("Nov 20"))
    #expect(text.contains("2:14"))
    #expect(text.hasSuffix(" \u{B7} 1m 52s"))
  }

  @Test func rowsCarryStateCountsAndCopyText() throws {
    let transcript = try transcript([
      prompt("Go"),
      call("t1", "Edit", ["file_path": "/tmp/A.swift"], at: "10:00:01"), returned("t1", "done", output: ["structuredPatch": patch], at: "10:00:03"),
      call("t2", "Bash", ["command": "swift build"]), returned("t2", "error", isError: true),
      call("t3", "Bash", ["command": "sleep 60"])
    ])
    var builder = makeBuilder()
    let rows = builder.elements(for: TranscriptInput(transcript: transcript, pending: [PendingRequest(requestId: "r1", toolUseId: "t3")], isLive: true)).compactMap { element -> ToolRow? in
      if case .tool(let row) = element.kind { row } else { nil }
    }

    #expect(rows.map(\.state) == [.completed, .failed, .waiting])
    #expect(rows.map(\.verb) == ["Edited", "Ran", "Running"])
    #expect(rows[0].added == 2 && rows[0].removed == 1)
    #expect(rows[0].copy == CopySource(title: "Copy Path", text: "/tmp/A.swift"))
    #expect(rows[0].tooltip == "/tmp/A.swift\n2.0s")
    #expect(rows[2].copy == CopySource(title: "Copy Command", text: "sleep 60"))
  }

  @Test func expandedGroupListsItsRowsInABox() throws {
    let transcript = try transcript([
      prompt("Go"),
      call("t1", "Read", ["file_path": "/tmp/A.swift"]), returned("t1", "a"),
      call("t2", "Bash", ["command": "swift test"]), returned("t2", "6 tests passed")
    ])
    var builder = makeBuilder()
    builder.toggle("group/t1")
    builder.toggle("t2")
    let elements = builder.elements(for: TranscriptInput(transcript: transcript))

    #expect(elements.map(\.shape) == ["header", "prompt(Go)", "group(Read A.swift, ran a command)", "tool(Read A.swift)", "tool(Ran swift test)", "detail"])
    #expect(elements.map(\.box) == [nil, nil, nil, BoxSlot(isFirst: true), BoxSlot(), BoxSlot(isLast: true)])
    #expect(elements[5].kind == .detail([.command("$ swift test"), .output("6 tests passed")]))

    builder.toggle("group/t1")
    #expect(builder.elements(for: TranscriptInput(transcript: transcript)).count == 3)
  }

  @Test func detailShowsPatchesAndCapsLongOutput() throws {
    let output = (1...40).map { "line \($0)" }.joined(separator: "\n")
    let transcript = try transcript([
      prompt("Go"),
      call("t1", "Edit", ["file_path": "/tmp/A.swift"]), returned("t1", "done", output: ["structuredPatch": patch]),
      said("Next."),
      call("t2", "Write", ["file_path": "/tmp/B.swift"]), returned("t2", "done", output: ["type": "create", "content": "one\ntwo\n", "structuredPatch": []]),
      said("Next."),
      call("t3", "Bash", ["command": "seq 40"]), returned("t3", output)
    ])
    var builder = makeBuilder()
    builder.isVerbose = true

    func details() -> [[DetailBlock]] {
      builder.elements(for: TranscriptInput(transcript: transcript)).compactMap { element in
        if case .detail(let blocks) = element.kind { blocks } else { nil }
      }
    }

    #expect(details()[0] == [.diff([" keep", "-old", "+new", "+more"])])
    #expect(details()[1] == [.diff(["+one", "+two"])])
    #expect(details()[2] == [.command("$ seq 40"), .output((1...16).map { "line \($0)" }.joined(separator: "\n")), .more(id: "t3/more", hidden: 24)])

    builder.toggle("t3/more")
    #expect(details()[2] == [.command("$ seq 40"), .output(output), .less(id: "t3/more")])
  }

  @Test func streamedBlocksKeepTheirPlaceWhenTheirFrameArrives() throws {
    let frames = [prompt("Go"), said("First.")]
    var builder = makeBuilder()
    let streaming = builder.elements(for: TranscriptInput(transcript: try transcript(frames), streaming: [.text("Second, still "), .toolUse(id: "t1", name: "Bash", partialInput: "{\"comm")], isLive: true))
    let grown = builder.elements(for: TranscriptInput(transcript: try transcript(frames), streaming: [.text("Second, still coming."), .toolUse(id: "t1", name: "Bash", partialInput: "{\"comm")], isLive: true))
    let committed = builder.elements(for: TranscriptInput(transcript: try transcript(frames + [said("Second, still coming.")]), streaming: [.toolUse(id: "t1", name: "Bash", partialInput: "{\"comm")], isLive: true))

    #expect(streaming.map(\.shape) == ["header", "prompt(Go)", "reply(First.)", "reply(Second, still)", "tool(Running)"])
    #expect(elementEdits(from: streaming, to: grown) == [ElementEdit(old: 3..<4, new: 3..<4)])
    #expect(elementEdits(from: grown, to: committed).isEmpty)
  }

  @Test func thinkingShowsOnlyWhileItStreamsOrInVerbose() throws {
    let transcript = try transcript([prompt("Go"), thought("Weighing it."), said("Answer.")])

    #expect(shapes(transcript) == ["header", "prompt(Go)", "reply(Answer.)"])
    #expect(shapes(transcript) { $0.isVerbose = true } == ["header", "prompt(Go)", "thought(Weighing it.)", "reply(Answer.)"])
    #expect(shapes(transcript, streaming: [.thinking("Hmm")], isLive: true) == ["header", "prompt(Go)", "reply(Answer.)", "thinking"])
  }

  @Test func permissionCardSitsUnderItsCallOrLast() throws {
    let transcript = try transcript([prompt("Go"), call("t1", "Bash", ["command": "rm -rf build"]), call("t2", "Read", ["file_path": "/tmp/a"])])
    var builder = makeBuilder()
    let pending = [PendingRequest(requestId: "r1", toolUseId: "t1"), PendingRequest(requestId: "r2", toolUseId: "from-a-subagent")]

    #expect(builder.elements(for: TranscriptInput(transcript: transcript, pending: pending, isLive: true)).map(\.shape) == [
      "header", "prompt(Go)", "tool(Running rm -rf build)", "permission(r1)", "tool(Reading a)", "permission(r2)"
    ])
    #expect(builder.elements(for: TranscriptInput(transcript: transcript, isLive: true)).map(\.shape) == ["header", "prompt(Go)", "tool(Running rm -rf build)", "tool(Reading a)"])
  }

  @Test func taskListFollowsTheRunningTurnsFirstBlock() throws {
    let frames = [prompt("Go"), said("Planning."), call("k1", "TaskCreate", ["subject": "Write tests"]), returned("k1", "ok", output: ["task": ["id": "1", "subject": "Write tests"]])]
    let running = try transcript(frames)
    var builder = makeBuilder()
    let tasks = TaskList(running).tasks

    #expect(tasks.count == 1)
    #expect(builder.elements(for: TranscriptInput(transcript: running, tasks: tasks, isLive: true)).map(\.shape) == ["header", "prompt(Go)", "reply(Planning.)", "tasks(1)", "tool(Added task Write tests)"])
    #expect(builder.elements(for: TranscriptInput(transcript: try transcript(frames + [finished()]), tasks: tasks, isLive: true)).map(\.shape).contains("tasks(1)") == false)
    #expect(builder.elements(for: TranscriptInput(transcript: running, tasks: tasks)).map(\.shape).contains("tasks(1)") == false)
  }

  @Test func taskListShowsBeforeTheTurnHasAnythingElse() throws {
    let tasks = TaskList(try transcript([call("k1", "TaskCreate", ["subject": "Write tests"]), returned("k1", "ok", output: ["task": ["id": "1", "subject": "Write tests"]])])).tasks
    var builder = makeBuilder()
    let bare = try transcript([prompt("Go")])

    #expect(builder.elements(for: TranscriptInput(transcript: bare, tasks: tasks, isLive: true)).map(\.shape) == ["header", "prompt(Go)", "tasks(1)"])
    #expect(builder.elements(for: TranscriptInput(transcript: bare, streaming: [.thinking("Hmm")], tasks: tasks, isLive: true)).map(\.shape) == ["header", "prompt(Go)", "thinking", "tasks(1)"])
    #expect(builder.elements(for: TranscriptInput(transcript: try transcript([prompt("Go"), thought("Hmm")]), tasks: tasks, isLive: true)).map(\.shape) == ["header", "prompt(Go)", "tasks(1)"])
  }

  @Test func unansweredCallInAnEndedTurnIsStopped() throws {
    var cut = try transcript([prompt("Go"), call("t1", "Bash", ["command": "sleep 600"])])
    var builder = makeBuilder()

    func states(_ transcript: Transcript, isLive: Bool) -> [ToolRow.State] {
      builder.elements(for: TranscriptInput(transcript: transcript, isLive: isLive)).compactMap { element in
        if case .tool(let row) = element.kind { row.state } else { nil }
      }
    }

    #expect(states(cut, isLive: true) == [.running])
    cut.endTurn()
    #expect(states(cut, isLive: false) == [.stopped])

    // A result that arrives after the turn has ended still reaches a turn the builder has kept.
    cut.apply(try Message.decode(returned("t1", "late"), from: try returned("t1", "late").encoded()))
    #expect(states(cut, isLive: false).first == .completed)
  }

  @Test func midTurnNotificationIsALineNotABubble() throws {
    let transcript = try transcript([
      prompt("Go"), said("Working."),
      prompt("<task-notification><summary>Agent finished</summary></task-notification>", at: "10:01:00", origin: "task_notification"),
      prompt("And one more thing", at: "10:02:00")
    ])

    #expect(shapes(transcript, isLive: true) == ["header", "prompt(Go)", "reply(Working.)", "notice(bell, Agent finished)", "prompt(And one more thing)"])
  }

  @Test func turnsOtherThingsStartedAreOneLine() throws {
    let transcript = try transcript([
      prompt("<task-notification><task-id>7</task-id><summary>Agent finished scanning</summary></task-notification>", origin: "task_notification"), said("Noted."), finished(milliseconds: 2400),
      prompt("Nightly check\nwith details", at: "11:00:00", origin: "scheduled"), said("Fine."), finished(milliseconds: 900),
      prompt("Typed by a person", at: "12:00:00", origin: "host_synthetic")
    ])

    #expect(shapes(transcript) == [
      "header", "notice(bell, Agent finished scanning)", "reply(Noted.)", "footer(2.4s)",
      "notice(clock, Nightly check \u{2026})", "reply(Fine.)", "footer(0.9s)", "prompt(Typed by a person)"
    ])
  }

  @Test func agentRowsShowTypeAndUsage() throws {
    let transcript = try transcript([
      prompt("Go"),
      call("agent-1", "Agent", ["description": "Scan the repo", "prompt": "Scan", "subagent_type": "Explore"]),
      ["type": "system", "subtype": "task_progress", "tool_use_id": "agent-1", "task_id": "a1", "usage": ["total_tokens": 34_512, "tool_uses": 12, "duration_ms": 900]],
      returned("agent-1", "Found two files", output: ["status": "completed", "agentId": "a1"])
    ])
    var builder = makeBuilder()
    builder.toggle("agent-1")
    let elements = builder.elements(for: TranscriptInput(transcript: transcript))

    guard case .tool(let row) = elements[2].kind else { return #expect(Bool(false), "The agent's row is missing") }

    #expect(row.verb == "Ran agent" && row.target == "Scan the repo")
    #expect(row.note == "Explore \u{B7} 12 tool uses \u{B7} 34.5k tokens")
    #expect(elements[3].kind == .detail([.report("Found two files")]))
  }

  @Test func earlierTurnsAreUnchangedWhenALaterOneGrows() throws {
    let frames = [prompt("Go"), said("One."), finished(), prompt("Again", at: "10:05:00"), said("Two.")]
    var builder = makeBuilder()
    let first = builder.elements(for: TranscriptInput(transcript: try transcript(frames), isLive: true))
    let second = builder.elements(for: TranscriptInput(transcript: try transcript(frames + [said("Three.")]), isLive: true))

    #expect(Array(second.prefix(first.count)) == first)
    #expect(second.last?.shape == "reply(Three.)")
  }
}
