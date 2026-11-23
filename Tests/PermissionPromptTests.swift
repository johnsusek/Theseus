import Testing
@testable import ClaudeEngine

struct PermissionPromptTests {
  func prompt(_ tool: String, _ input: JSONValue, suggestions: [PermissionUpdate] = [], description: String? = nil, fileExists: Bool = false) -> PermissionPrompt {
    PermissionPrompt(toolName: tool, displayName: nil, input: input, description: description, suggestions: suggestions, projectName: "Theseus", fileExists: fileExists)
  }

  @Test func titlesNameTheFileOrTheAction() {
    #expect(prompt("Edit", ["file_path": "/tmp/RemoteTerminalView.swift", "old_string": "a", "new_string": "b"]).title == "Edit RemoteTerminalView.swift?")
    #expect(prompt("Bash", ["command": "swift test"]).title == "Run this command?")
    #expect(prompt("Write", ["file_path": "/tmp/notes.md", "content": "hi"]).title == "Create notes.md?")
    #expect(prompt("Write", ["file_path": "/tmp/notes.md", "content": "hi"], fileExists: true).title == "Replace notes.md?")
    #expect(prompt("mcp__SafariPilot__click", [:]).title == "Allow SafariPilot click?")
  }

  @Test func bodiesShowWhatWouldHappen() {
    #expect(prompt("Bash", ["command": "swift test"]).body == .code("swift test"))
    #expect(prompt("Write", ["file_path": "/tmp/a", "content": "one\ntwo"]).body == .code("one\ntwo"))
    #expect(prompt("Edit", ["file_path": "/tmp/a", "old_string": "keep\nold\nend", "new_string": "keep\nnew\nmore\nend"]).body == .diff([" keep", "-old", "+new", "+more", " end"]))
    #expect(prompt("WebFetch", ["url": "https://example.com"], description: "Fetch example.com").body == .text("Fetch example.com"))
  }

  @Test func planAsksForApproval() {
    let plan = prompt("ExitPlanMode", ["plan": "1. Do it"])

    #expect(plan.body == .markdown("1. Do it"))
    #expect(plan.allowTitle == "Approve" && plan.denyTitle == "Keep Planning" && plan.isPlan)
    #expect(prompt("ExitPlanMode", ["plan": "1. Do it"], suggestions: [.setMode(.acceptEdits, destination: .session)]).checkbox == nil)
  }

  @Test func suggestionsReadAsPlainWords() {
    let rule = PermissionRule(toolName: "Bash", ruleContent: "swift test:*")

    #expect(suggestionLabel([], projectName: "Theseus") == nil)
    #expect(suggestionLabel([.addRules([rule], behavior: .allow, destination: .localSettings)], projectName: "Theseus") == "Always allow swift test in Theseus")
    #expect(suggestionLabel([.addRules([rule], behavior: .allow, destination: .session)], projectName: "Theseus") == "Allow swift test this session")
    #expect(suggestionLabel([.addRules([rule], behavior: .allow, destination: .userSettings)], projectName: "Theseus") == "Always allow swift test in every project")
    #expect(suggestionLabel([.setMode(.acceptEdits, destination: .session)], projectName: "Theseus") == "Allow all edits this session")
    #expect(suggestionLabel([.addRules([PermissionRule(toolName: "Read", ruleContent: "//Users/me/Code/Other/**")], behavior: .allow, destination: .session), .addDirectories(["/Users/me/Code/Other"], destination: .session)], projectName: "Theseus") == "Allow reading Other this session and allow access to Other this session")
    #expect(suggestionLabel([.addRules([PermissionRule(toolName: "mcp__SafariPilot__click")], behavior: .allow, destination: .projectSettings)], projectName: "Theseus") == "Always allow SafariPilot click in Theseus")
  }

  @Test func checkboxComesFromTheSuggestions() {
    #expect(prompt("Bash", ["command": "ls"]).checkbox == nil)
    #expect(prompt("Edit", ["file_path": "/tmp/a"], suggestions: [.setMode(.acceptEdits, destination: .session)]).checkbox == "Allow all edits this session")
  }
}
