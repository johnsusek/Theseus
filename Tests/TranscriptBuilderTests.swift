import Foundation
import Testing
@testable import ClaudeEngine

struct TranscriptBuilderTests {
  let patch: JSONValue = [["oldStart": 1, "oldLines": 2, "newStart": 1, "newLines": 3, "lines": [" keep", "-old", "+new", "+more"]]]

  func shapes(_ transcript: Transcript, streaming: [StreamingMessage.Block] = [], isLive: Bool = false, change: (inout TranscriptBuilder) -> Void = { _ in }) -> [String] {
    var builder = makeBuilder()
    change(&builder)
    return builder.elements(for: TranscriptInput(transcript: transcript, streaming: streaming, isLive: isLive)).map(\.shape)
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
      "prompt(Add dates)", "reply(Reading first.)", "group(Read 2 files, ran 2 commands, edited a file, 1 failed)", "reply(Done.)", "footer(1m 52s)"
    ])
  }

  @Test func wrapUpBecomesACardAfterTheTurnsReplies() throws {
    let wrapUp: JSONValue = ["recap": "Preview added.", "ask": "Commit it?", "actions": ["Commit", "Not yet", "Later"]]
    let frames = [prompt("Add a preview"), call("t1", wrapUpToolName, wrapUp), returned("t1", "Shown."), said("Added the preview."), finished()]
    var builder = makeBuilder()
    let open = builder.elements(for: TranscriptInput(transcript: try transcript(frames), isLive: true)).map(\.shape)
    let answered = builder.elements(for: TranscriptInput(transcript: try transcript(frames), isLive: true, sent: [SentPrompt(uuid: "u", text: "Commit")])).map(\.shape)

    #expect(open == ["prompt(Add a preview)", "reply(Added the preview.)", "next(Preview added. | Commit it? [\"Commit\", \"Not yet\"])", "footer(1m 52s)"])
    #expect(!answered.contains { $0.hasPrefix("next(") })

    let desktop: JSONValue = ["recap": "Done.", "ask": "Commit?", "actions": [["label": "Commit", "action": "commit"]]]
    let desktopFrames = [prompt("Go"), call("t1", "mcp__ccd_turn__update_plan", ["items": []]), returned("t1", "ok"), call("t2", "mcp__ccd_turn__wrap_up", desktop), returned("t2", "ok"), finished()]
    #expect(shapes(try transcript(desktopFrames)) == ["prompt(Go)", "next(Done. | Commit? [\"Commit\"])", "footer(1m 52s)"])
  }

  @Test func onlyTheLastTurnShowsItsRecap() throws {
    let wrapUp: JSONValue = ["recap": "Done.", "ask": "Push?", "actions": ["Push"]]
    let shown = shapes(try transcript([prompt("One"), call("t1", wrapUpToolName, wrapUp), returned("t1", "Shown."), finished(), prompt("Two", at: "10:05:00"), said("Ok."), finished()]))

    #expect(!shown.contains { $0.hasPrefix("next(") })
    #expect(!shown.contains { $0.hasPrefix("tool(") })
  }

    @Test func stoppedTurnSaysSoInItsFooter() throws {
    let interrupted: JSONValue = ["type": "user", "uuid": "i1", "message": ["role": "user", "content": [["type": "text", "text": "[Request interrupted by user]"]]], "parent_tool_use_id": nil]
    var builder = makeBuilder()
    let elements = builder.elements(for: TranscriptInput(transcript: try transcript([prompt("Go"), said("Half a"), interrupted, finished()])))

    guard case .footer(let text) = elements.last?.kind else { return #expect(Bool(false), "The footer is missing") }

    #expect(text.text.hasSuffix(" \u{B7} Stopped"))
  }

  @Test func sentPromptsShowAfterTheRunningTurn() throws {
    var builder = makeBuilder()
    let running = try transcript([prompt("First"), said("Working.")])
    let elements = builder.elements(for: TranscriptInput(transcript: running, isLive: true, sent: [SentPrompt(uuid: "q", text: "Queued")]))

    #expect(elements.map(\.shape) == ["prompt(First)", "reply(Working.)", "prompt(Queued)"])
    #expect(elements.last?.id == "sent/q")
  }

  @Test func footerGivesTheStartAndTheDuration() throws {
    var builder = makeBuilder()
    let elements = builder.elements(for: TranscriptInput(transcript: try transcript([prompt("Go", at: "14:14:00"), said("Done."), said("Also this."), finished()])))

    guard case .footer(let footer) = elements.last?.kind else { return #expect(Bool(false), "The footer is missing") }

    let text = footer.text
    #expect(footer.replies == "Done.\n\nAlso this.")
    #expect(Set(elements.map(\.turn)) == [elements[0].turn] && elements[0].turn != nil)
    #expect(text.hasPrefix("Nov 20"))
    #expect(text.contains("2:14"))
    #expect(text.hasSuffix(" \u{B7} 1m 52s"))
  }

  @Test func rowsCarryStateCountsAndCopyText() throws {
    let transcript = try transcript([
      prompt("Go"),
      call("t1", "Edit", ["file_path": "/tmp/A.swift"], at: "10:00:01"), returned("t1", "done", output: ["structuredPatch": patch], at: "10:00:03"),
      call("t2", "Bash", ["command": "swift build"]), returned("t2", "error", isError: true),
      call("t3", "Bash", ["command": "sleep 60"]),
      call("t4", "Write", ["file_path": "/tmp/B.swift"]), returned("t4", "The user denied this request.", isError: true),
      call("t5", "Edit", ["file_path": "/tmp/C.swift"]), returned("t5", "<tool_use_error>String to replace not found in file.</tool_use_error>", isError: true)
    ])
    var builder = makeBuilder()
    builder.toggle("group/t1")
    builder.toggle("group/t4")
    let rows = builder.elements(for: TranscriptInput(transcript: transcript, pending: [PendingRequest(requestId: "r1", toolUseId: "t3")], isLive: true)).compactMap { element -> ToolRow? in
      if case .tool(let row) = element.kind { row } else { nil }
    }

    #expect(rows.map(\.state) == [.completed, .failed, .waiting, .failed, .failed])
    #expect(rows.map(\.verb) == ["Edited", "Ran", "Running", "Could not create", "Could not edit"])
    #expect(rows.map(\.note) == ["", "", "", "Denied", ""])
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

    #expect(elements.map(\.shape) == ["prompt(Go)", "group(Read A.swift, ran a command)", "tool(Read A.swift)", "tool(Ran swift\u{2026})", "detail"])
    #expect(elements.map(\.box) == [nil, nil, BoxSlot(isFirst: true), BoxSlot(), BoxSlot(isLast: true)])
    #expect(elements[4].kind == .detail([.command("$ swift test"), .output("6 tests passed")]))

    builder.toggle("group/t1")
    #expect(builder.elements(for: TranscriptInput(transcript: transcript)).count == 2)
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

    #expect(details()[0] == [.diff(["@@ -1,2 +1,3 @@", " keep", "-old", "+new", "+more"], file: "A.swift")])
    #expect(details()[1] == [.diff(["+one", "+two"], file: "B.swift")])
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

    #expect(streaming.map(\.shape) == ["prompt(Go)", "reply(First.)", "reply(Second, still)", "tool(Running)"])
    #expect(elementEdits(from: streaming, to: grown) == [ElementEdit(old: 2..<3, new: 2..<3)])
    #expect(elementEdits(from: grown, to: committed).isEmpty)
  }

  @Test func thinkingWithTextShows() throws {
    let transcript = try transcript([prompt("Go"), thought("Weighing it."), thought(""), said("Answer.")])

    #expect(shapes(transcript) == ["prompt(Go)", "thought(Weighing it.)", "reply(Answer.)"])
    #expect(shapes(transcript, streaming: [.thinking("Hmm")], isLive: true) == ["prompt(Go)", "thought(Weighing it.)", "reply(Answer.)", "thought(Hmm)"])
  }

  @Test func activityFollowsTheRunningTurnBeforeQueuedPrompts() throws {
    let transcript = try transcript([prompt("Go"), said("Looking.")])
    var builder = makeBuilder()
    let input = TranscriptInput(transcript: transcript, isLive: true, sent: [SentPrompt(uuid: "u1", text: "Next")], activity: Activity(text: "Thinking", since: .now))

    #expect(builder.elements(for: input).map(\.shape) == ["prompt(Go)", "reply(Looking.)", "activity(Thinking)", "prompt(Next)"])
  }

  @Test func activityFollowsAFirstPromptNotEchoedYet() throws {
    var builder = makeBuilder()
    let input = TranscriptInput(isLive: true, sent: [SentPrompt(uuid: "u1", text: "Go")], activity: Activity(text: "Thinking", since: .now))

    #expect(builder.elements(for: input).map(\.shape) == ["prompt(Go)", "activity(Thinking)"])

    let opened = try transcript([["type": "system", "subtype": "init", "uuid": "i1", "session_id": "s", "cwd": "/tmp", "model": "x", "permissionMode": "default", "tools": [], "mcp_servers": [], "slash_commands": [], "output_style": "default", "apiKeySource": "none", "claude_code_version": "2"]])
    #expect(builder.elements(for: TranscriptInput(transcript: opened, isLive: true, sent: input.sent, activity: input.activity)).map(\.shape) == ["prompt(Go)", "activity(Thinking)"])
  }

  @Test func permissionCardSitsUnderItsCallOrLast() throws {
    let transcript = try transcript([prompt("Go"), call("t1", "Bash", ["command": "rm -rf build"]), call("t2", "Read", ["file_path": "/tmp/a"])])
    var builder = makeBuilder()
    let pending = [PendingRequest(requestId: "r1", toolUseId: "t1"), PendingRequest(requestId: "r2", toolUseId: "from-a-subagent")]

    #expect(builder.elements(for: TranscriptInput(transcript: transcript, pending: pending, isLive: true)).map(\.shape) == [
      "prompt(Go)", "tool(Running rm\u{2026})", "permission(r1)", "tool(Reading a)", "permission(r2)"
    ])
    #expect(builder.elements(for: TranscriptInput(transcript: transcript, isLive: true)).map(\.shape) == ["prompt(Go)", "group(Ran a command, read a)"])
  }

  @Test func taskListFollowsTheRunningTurnsFirstBlock() throws {
    let frames = [prompt("Go"), said("Planning."), call("k1", "TaskCreate", ["subject": "Write tests"]), returned("k1", "ok", output: ["task": ["id": "1", "subject": "Write tests"]])]
    let running = try transcript(frames)
    var builder = makeBuilder()
    let tasks = TaskList(running).tasks

    #expect(tasks.count == 1)
    #expect(builder.elements(for: TranscriptInput(transcript: running, tasks: tasks, isLive: true)).map(\.shape) == ["prompt(Go)", "reply(Planning.)", "tasks(1)", "tool(Added task Write tests)"])
    #expect(builder.elements(for: TranscriptInput(transcript: try transcript(frames + [finished()]), tasks: tasks, isLive: true)).map(\.shape).contains("tasks(1)") == false)
    #expect(builder.elements(for: TranscriptInput(transcript: running, tasks: tasks)).map(\.shape).contains("tasks(1)") == false)
  }

  @Test func taskListShowsBeforeTheTurnHasAnythingElse() throws {
    let tasks = TaskList(try transcript([call("k1", "TaskCreate", ["subject": "Write tests"]), returned("k1", "ok", output: ["task": ["id": "1", "subject": "Write tests"]])])).tasks
    var builder = makeBuilder()
    let bare = try transcript([prompt("Go")])

    #expect(builder.elements(for: TranscriptInput(transcript: bare, tasks: tasks, isLive: true)).map(\.shape) == ["prompt(Go)", "tasks(1)"])
    #expect(builder.elements(for: TranscriptInput(transcript: try transcript([prompt("Go"), thought("")]), tasks: tasks, isLive: true)).map(\.shape) == ["prompt(Go)", "tasks(1)"])
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

  @Test func midTurnNotificationIsHidden() throws {
    let transcript = try transcript([
      prompt("Go"), said("Working."),
      prompt("<task-notification><summary>Agent finished</summary></task-notification>", at: "10:01:00", origin: "task_notification"),
      prompt("And one more thing", at: "10:02:00")
    ])

    #expect(shapes(transcript, isLive: true) == ["prompt(Go)", "reply(Working.)", "prompt(And one more thing)"])
  }

  @Test func turnsOtherThingsStartedAreOneLine() throws {
    let transcript = try transcript([
      prompt("<task-notification><task-id>7</task-id><summary>Agent finished scanning</summary></task-notification>", origin: "task_notification"), said("Noted."), finished(milliseconds: 2400),
      prompt("Nightly check\nwith details", at: "11:00:00", origin: "scheduled"), said("Fine."), finished(milliseconds: 900),
      prompt("Typed by a person", at: "12:00:00", origin: "host_synthetic")
    ])

    #expect(shapes(transcript) == [
      "reply(Noted.)", "footer(2.4s)",
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

    guard case .tool(let row) = elements[1].kind else { return #expect(Bool(false), "The agent's row is missing") }

    #expect(row.verb == "Ran agent" && row.target == "Scan the repo")
    #expect(row.note == "Explore \u{B7} 12 tool uses \u{B7} 34.5k tokens")
    #expect(elements[2].kind == .detail([.report("Found two files")]))
  }

  @Test func earlierTurnsAreUnchangedWhenALaterOneGrows() throws {
    let frames = [prompt("Go"), said("One."), finished(), prompt("Again", at: "10:05:00"), said("Two.")]
    var builder = makeBuilder()
    let first = builder.elements(for: TranscriptInput(transcript: try transcript(frames), isLive: true))
    let second = builder.elements(for: TranscriptInput(transcript: try transcript(frames + [said("Three.")]), isLive: true))

    #expect(Array(second.prefix(first.count)) == first)
    #expect(second.last?.shape == "reply(Three.)")
  }

  @Test func runningTurnFoldsItsLastCallsUnderTheActivity() throws {
    let frames = [prompt("Go"), call("t1", "Bash", ["command": "ls", "description": "List files"]), returned("t1", "a"), call("t2", "Bash", ["command": "make", "description": "Build it"])]
    var builder = makeBuilder()
    let activity = Activity(text: "Building it", since: .now)
    let running = builder.elements(for: TranscriptInput(transcript: try transcript(frames), isLive: true, activity: activity)).map(\.shape)
    let replied = builder.elements(for: TranscriptInput(transcript: try transcript(frames + [returned("t2", "ok"), said("Built.")]), isLive: true, activity: activity)).map(\.shape)

    #expect(running == ["prompt(Go)", "live(Building it)"])
    #expect(replied == ["prompt(Go)", "group(Ran 2 commands)", "reply(Built.)", "activity(Building it)"])
  }

  @Test func failedCommandKeepsItsDescriptionAndWriteOverAFileReadsAsAnUpdate() throws {
    let rows = try transcript([
      prompt("Go"),
      call("t1", "Bash", ["command": "make", "description": "Build the app"]), returned("t1", "Exit code 2", isError: true),
      said("Fixing."),
      call("t2", "Write", ["file_path": "/tmp/A.swift"]), returned("t2", "updated", output: ["type": "update"]),
      said("Done.")
    ])

    #expect(shapes(rows) == ["prompt(Go)", "tool(Build the app)", "reply(Fixing.)", "tool(Updated A.swift)", "reply(Done.)"])
  }

  @Test func commandRunFromACodeBlockShowsItsOutputUnderTheBlock() throws {
    let reply = "Run this:\n\n```bash\nlook.sh 1\n```\n\nThen tell me."
    let ran = prompt("<bash-input>look.sh 1</bash-input><bash-stdout>shot 1 -&gt; bloom</bash-stdout><bash-stderr></bash-stderr>", at: "10:05:00")
    let other = prompt("<bash-input>date</bash-input><bash-stdout>Tue</bash-stdout><bash-stderr></bash-stderr>", at: "10:06:00")

    let shown = shapes(try transcript([prompt("Go"), said(reply), finished(), ran, finished(), other]))

    #expect(shown == [
      "prompt(Go)", "reply(Run this:\n\n```bash\nlook.sh 1\n```)", "shell(shot 1 -> bloom)", "reply(Then tell me.)", "footer(1m 52s)", "shell(date | Tue)"
    ])
  }

  @Test func turnStartedByARunKeepsWhatClaudeDidNext() throws {
    let reply = "Run this:\n\n```bash\nlook.sh 1\n```"
    let wrapUp: JSONValue = ["recap": "Staged.", "ask": "Did look.sh 1 run?", "actions": [["label": "Done"]]]
    let ran = prompt("<bash-input>look.sh 1</bash-input><bash-stdout>ok</bash-stdout>", at: "10:05:00")
    let shown = shapes(try transcript([prompt("Go"), said(reply), call("w1", "mcp__ccd_turn__wrap_up", wrapUp), returned("w1", "Shown"), finished(), ran, said("Captured."), finished(milliseconds: 3000)]))

    #expect(shown == ["prompt(Go)", "reply(Run this:\n\n```bash\nlook.sh 1\n```)", "shell(ok)", "reply(Captured.)", "footer(3.0s)"])
  }

  @Test func earlierTurnKeepsItsQuestionAsARow() throws {
    let wrapUp: JSONValue = ["recap": "Staged.", "ask": "Retake now?", "actions": [["label": "Retake"]]]
    let turns = try transcript([prompt("Go"), said("Ready."), call("w1", "mcp__ccd_turn__wrap_up", wrapUp), returned("w1", "Shown"), finished(milliseconds: 1000), prompt("Retake", at: "10:01:00"), said("Done."), finished(milliseconds: 1000)])

    #expect(shapes(turns) == ["prompt(Go)", "reply(Ready.)", "ask(Retake now?)", "footer(1.0s)", "prompt(Retake)", "reply(Done.)", "footer(1.0s)"])
    #expect(shapes(turns) { $0.toggle("0/ask") }.contains("detail"))
  }

  @Test func answeredQuestionAndSentImageSplitTheGroup() throws {
    let questions: JSONValue = ["questions": [["question": "Which wallpaper?", "header": "Wallpaper", "options": [["label": "Vivid"]]]]]
    let skipped: JSONValue = ["questions": [["question": "Which gradient?", "header": "Gradient", "options": [["label": "Bloom"]]]]]
    let shown = shapes(try transcript([
      prompt("Go"),
      call("b1", "Bash", ["command": "ls"]), returned("b1", "a"),
      call("q1", "AskUserQuestion", questions), returned("q1", "answered", output: ["answers": ["Which wallpaper?": "Vivid"]]),
      call("r1", "Read", ["file_path": "/tmp/sheet.png"]), returned("r1", "image"),
      call("s1", "SendUserFile", ["files": ["/tmp/crops.png"], "caption": "The crops"]), returned("s1", "1 file delivered to user."),
      call("q2", "AskUserQuestion", skipped), returned("q2", "skipped", output: ["answers": ["Which gradient?": "[User did not answer this question \u{2014} they sent a message instead.]"]])
    ]))

    #expect(shown == ["prompt(Go)", "tool(Ran a command)", "question(Which wallpaper? = Vivid)", "tool(Read sheet.png)", "reply(The crops)", "image(crops.png)", "tool(Asked \u{201C}Gradient\u{201D})"])
  }

  @Test func summaryNamesALoneReadAndPutsSkillsLast() throws {
    let shown = shapes(try transcript([
      prompt("Go"),
      call("k1", "Skill", ["skill": "stagehand"]), returned("k1", "ok"),
      call("b1", "Bash", ["command": "ls"]), returned("b1", "a"),
      call("r1", "Read", ["file_path": "/tmp/menubar.png"]), returned("r1", "image"),
      said("Next."),
      call("e1", "Edit", ["file_path": "/tmp/a.swift"]), returned("e1", "ok"),
      call("r2", "Read", ["file_path": "/tmp/b.swift"]), returned("r2", "b")
    ]))

    #expect(shown == ["prompt(Go)", "group(Ran a command, read menubar.png, ran a skill)", "reply(Next.)", "group(Edited a file, read a file)"])
  }

  @Test func imageResultsBecomeThumbnails() throws {
    let image: JSONValue = ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "iVBORw0KGgo="]]
    let result: JSONValue = ["type": "user", "uuid": "r-t1", "message": ["content": [["type": "tool_result", "tool_use_id": "t1", "content": [image], "is_error": false]]], "parent_tool_use_id": nil]
    var builder = makeBuilder()
    let elements = builder.elements(for: TranscriptInput(transcript: try transcript([prompt("Go"), call("t1", "Read", ["file_path": "/tmp/a.png"]), result, call("t2", "Bash", ["command": "ls"]), returned("t2", "a")])))

    guard case .group(let group) = elements.last?.kind else { return #expect(Bool(false), "The group is missing") }
    #expect(group.thumbnails.map(\.id) == ["t1/0"])
  }
}
