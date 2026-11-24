import Testing
@testable import ClaudeEngine

struct ToolPhraseTests {
  @Test func mcpToolNamesAreReadable() {
    #expect(toolDisplayName("mcp__SafariPilot__get_page_text") == "SafariPilot get page text")
    #expect(toolDisplayName("mcp__1a59c906-04da-521d-bda7-7f71b9f9e01c__batch") == "batch")
    #expect(toolDisplayName("WebFetch") == "WebFetch")
    #expect(toolPhrase(for: "mcp__ccd_session__mark_chapter").past == "Used ccd session mark chapter")
  }

  @Test func targetsAreFileNamesCommandsAndPatterns() {
    #expect(toolTarget("Read", input: ["file_path": "/tmp/Sources/TerminalView.swift"]) == "TerminalView.swift")
    #expect(toolTarget("NotebookEdit", input: ["notebook_path": "/tmp/a.ipynb"]) == "a.ipynb")
    #expect(toolTarget("Bash", input: ["command": "swift test --filter X\necho done"]) == "swift\u{2026}")
    #expect(toolTarget("Bash", input: ["command": "cd /tmp/a b && cd c && python3 - <<'EOF'"]) == "python3\u{2026}")
    #expect(toolTarget("Bash", input: ["command": "ls"]) == "ls")
    #expect(toolTarget("Grep", input: ["pattern": "TODO"]) == "TODO")
    #expect(toolTarget("WebFetch", input: ["url": "https://example.com/docs/page"]) == "example.com")
    #expect(toolTarget("TaskUpdate", input: ["taskId": "1"]) == "")
  }

  @Test func descriptionsTakeTheRowsTense() {
    #expect(conjugated("List project folder contents", isRunning: false) == "Listed project folder contents")
    #expect(conjugated("List project folder contents", isRunning: true) == "Listing project folder contents")
    #expect(["Run the tests", "Stop the server", "Create a file", "Copy notes", "Commit it", "Show status"].map { conjugated($0, isRunning: false) } == ["Ran the tests", "Stopped the server", "Created a file", "Copied notes", "Committed it", "Showed status"])
    #expect(["Run the tests", "Stop the server", "Create a file", "Tie it", "Open it"].map { conjugated($0, isRunning: true) } == ["Running the tests", "Stopping the server", "Creating a file", "Tying it", "Opening it"])
    #expect(conjugated("Checking status", isRunning: false) == "Checking status")
    #expect(conjugated("git: status", isRunning: false) == "git: status")
    #expect(toolActivity("Bash", input: ["command": "ls", "description": "List files"]) == "Listing files")
  }

  @Test func longCommandsLoseTheirMiddle() {
    let command = String(repeating: "a", count: 60) + String(repeating: "b", count: 60)
    let cut = oneLine(command, limit: 80)

    #expect(cut.count == 80)
    #expect(cut.hasPrefix("aaa") && cut.hasSuffix("bbb") && cut.contains("\u{2026}"))
  }

  @Test func summaryCountsEachKindOfCall() {
    #expect(toolSummary([("Read", "a.swift"), ("Read", "b.swift"), ("Bash", "swift test")]).map(\.text).joined() == "Read 2 files, ran a command")
    #expect(toolSummary([("Edit", "a.swift"), ("Grep", "TODO"), ("Glob", "*.swift"), ("MultiEdit", "b.swift")]).map(\.text).joined() == "Made 2 edits, ran 2 searches")
    #expect(toolSummary([("Write", "notes.md"), ("mcp__SafariPilot__click", "")]) == [SummaryPart(text: "Created "), SummaryPart(text: "notes.md", isTarget: true), SummaryPart(text: ", used SafariPilot click")])
  }
}
