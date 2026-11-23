import ClaudeEngine
import Foundation

/// What a permission card says: a title, what the tool would do, and the words for its checkbox and buttons.
struct PermissionPrompt: Equatable {
  enum Body: Equatable {
    /// Patch lines, each starting with a space, `+` or `-`.
    case diff([String])
    case code(String)
    case markdown(String)
    case text(String)
  }

  var title: String
  var symbol: String
  var body: Body
  /// The label for saving the CLI's suggested rules with the answer. Nil when it suggested none.
  var checkbox: String?
  var allowTitle = "Allow"
  var denyTitle = "Deny"
  var isPlan = false

  init(toolName: String, displayName: String?, input: JSONValue, description: String?, suggestions: [PermissionUpdate], projectName: String, fileExists: Bool) {
    let file = toolPath(toolName, input: input).map { URL(filePath: $0).lastPathComponent } ?? ""
    checkbox = suggestionLabel(suggestions, projectName: projectName)

    switch toolName {
    case "ExitPlanMode":
      title = "Approve this plan?"
      symbol = "list.bullet.clipboard"
      body = .markdown(input["plan"]?.string ?? "")
      allowTitle = "Approve"
      denyTitle = "Keep Planning"
      isPlan = true
    case "Edit", "MultiEdit", "NotebookEdit":
      let edits = input["edits"]?.array ?? [input]
      title = "Edit \(file)?"
      symbol = "pencil.line"
      body = .diff(edits.flatMap { editLines(old: $0["old_string"]?.string ?? "", new: $0["new_string"]?.string ?? $0["new_source"]?.string ?? "") })
    case "Write":
      title = fileExists ? "Replace \(file)?" : "Create \(file)?"
      symbol = "doc.badge.plus"
      body = .code((input["content"]?.string ?? "").trimmingCharacters(in: .newlines))
    case "Bash":
      title = "Run this command?"
      symbol = "terminal"
      body = .code((input["command"]?.string ?? "").trimmingCharacters(in: .newlines))
    default:
      title = "Allow \(displayName ?? toolDisplayName(toolName))?"
      symbol = "hand.raised"
      body = .text(description ?? readableJSON(input))
    }
  }
}

extension PermissionPrompt {
  init(_ request: PermissionRequest, projectName: String) {
    let exists = request.input["file_path"]?.string.map { FileManager.default.fileExists(atPath: $0) } ?? false
    self.init(toolName: request.toolName, displayName: request.displayName, input: request.input, description: request.description, suggestions: request.suggestions, projectName: projectName, fileExists: exists)
  }
}

/// What Allow or Deny on a card sends back. `always` saves the rules the CLI suggested.
func permissionDecision(for request: PermissionRequest, allow: Bool, always: Bool) -> PermissionDecision {
  if request.plan != nil { return allow ? .approvePlan() : .rejectPlan(feedback: "Keep planning. The user did not approve this plan.") }

  if allow { return .allow(updatedPermissions: always ? request.suggestions : []) }

  return .deny(message: "The user denied this request.")
}

/// An edit as patch lines: the lines both strings start and end with are context, the rest are removed and added.
func editLines(old: String, new: String) -> [String] {
  let oldLines = old.isEmpty ? [] : old.components(separatedBy: "\n")
  let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")
  let shorter = min(oldLines.count, newLines.count)
  var head = 0
  var tail = 0

  while head < shorter, oldLines[head] == newLines[head] { head += 1 }

  while tail < shorter - head, oldLines[oldLines.count - 1 - tail] == newLines[newLines.count - 1 - tail] { tail += 1 }

  return oldLines[..<head].map { " " + $0 } + oldLines[head..<(oldLines.count - tail)].map { "-" + $0 } + newLines[head..<(newLines.count - tail)].map { "+" + $0 } + oldLines[(oldLines.count - tail)...].map { " " + $0 }
}

/// The CLI's suggested rule changes in plain words: "Always allow swift test in Theseus", "Allow all edits this session".
func suggestionLabel(_ suggestions: [PermissionUpdate], projectName: String) -> String? {
  guard !suggestions.isEmpty else { return nil }

  func scoped(_ what: String, _ destination: PermissionUpdate.Destination, verb: String = "allow") -> String {
    switch destination {
    case .session: "\(verb.capitalized) \(what) this session"
    case .projectSettings, .localSettings: "Always \(verb) \(what) in \(projectName)"
    case .userSettings: "Always \(verb) \(what) in every project"
    case .cliArg: "\(verb.capitalized) \(what)"
    }
  }

  let phrases = suggestions.map { suggestion in
    switch suggestion {
    case .addRules(let rules, let behavior, let destination):
      scoped(rules.map(ruleText).joined(separator: " and "), destination, verb: behavior == .allow ? "allow" : behavior == .deny ? "deny" : "ask before")
    case .setMode(.acceptEdits, _):
      "Allow all edits this session"
    case .setMode(.bypassPermissions, _):
      "Skip permission prompts this session"
    case .setMode(let mode, _):
      "Switch to \(mode.rawValue) mode"
    case .addDirectories(let directories, let destination):
      scoped("access to " + directories.map { URL(filePath: $0).lastPathComponent }.joined(separator: " and "), destination)
    default:
      "Save the suggested permission change"
    }
  }

  return phrases[0] + phrases.dropFirst().map { " and " + $0.prefix(1).lowercased() + $0.dropFirst() }.joined()
}

/// A rule as the thing it allows: "swift test" for `Bash(swift test:*)`, "edits in Sources" for `Edit(/Sources/**)`.
private func ruleText(_ rule: PermissionRule) -> String {
  let content = rule.ruleContent ?? ""
  let folder = URL(filePath: content.replacing(/\/?\*+$/, with: "")).lastPathComponent

  switch rule.toolName {
  case "Bash":
    return content.isEmpty ? "all commands" : content.replacing(/:\*$/, with: "")
  case "Edit", "Write", "MultiEdit", "NotebookEdit":
    return content.isEmpty ? "all edits" : "edits in \(folder)"
  case "Read":
    return content.isEmpty ? "reading files" : "reading \(folder)"
  case "WebFetch":
    return content.isEmpty ? "fetching pages" : "fetching \(content.replacing(/^domain:/, with: ""))"
  default:
    return content.isEmpty ? toolDisplayName(rule.toolName) : "\(toolDisplayName(rule.toolName)) \(content)"
  }
}
