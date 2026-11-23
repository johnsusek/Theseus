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
    #expect(toolTarget("Bash", input: ["command": "swift test --filter X\necho done"]) == "swift test --filter X \u{2026}")
    #expect(toolTarget("Grep", input: ["pattern": "TODO"]) == "TODO")
    #expect(toolTarget("WebFetch", input: ["url": "https://example.com/docs/page"]) == "example.com")
    #expect(toolTarget("TaskUpdate", input: ["taskId": "1"]) == "")
  }

  @Test func longCommandsLoseTheirMiddle() {
    let command = String(repeating: "a", count: 60) + String(repeating: "b", count: 60)
    let cut = oneLine(command, limit: 80)

    #expect(cut.count == 80)
    #expect(cut.hasPrefix("aaa") && cut.hasSuffix("bbb") && cut.contains("\u{2026}"))
  }

  @Test func summaryCountsEachKindOfCall() {
    #expect(toolSummary([("Read", "a.swift"), ("Read", "b.swift"), ("Bash", "swift test")]) == "Read 2 files, ran a command")
    #expect(toolSummary([("Edit", "a.swift"), ("Grep", "TODO"), ("Glob", "*.swift"), ("MultiEdit", "b.swift")]) == "Made 2 edits, ran 2 searches")
    #expect(toolSummary([("Write", "notes.md"), ("mcp__SafariPilot__click", "")]) == "Created notes.md, used SafariPilot click")
  }
}
