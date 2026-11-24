import ClaudeEngine
import Foundation

/// How a tool call reads as a finished row, as a running row, as a row that did not run, and in a group's summary sentence.
struct ToolPhrase: Equatable {
  let past: String
  let present: String
  /// A call that failed before it did anything, such as one that was denied.
  let failed: String
  /// One call in a summary. `%@` takes the call's target.
  let one: String
  /// Several calls in a summary. `%d` takes the count.
  let many: String

  init(_ past: String, _ present: String, _ failed: String, _ one: String, _ many: String) {
    self.past = past
    self.present = present
    self.failed = failed
    self.one = one
    self.many = many
  }
}

private let editPhrase = ToolPhrase("Edited", "Editing", "Could not edit", "edited %@", "made %d edits")
private let searchPhrase = ToolPhrase("Searched for", "Searching for", "Could not search for", "ran a search", "ran %d searches")
private let agentPhrase = ToolPhrase("Ran agent", "Running agent", "Could not run agent", "ran an agent", "ran %d agents")
private let taskListPhrase = ToolPhrase("Checked the task list", "Checking the task list", "Could not check the task list", "checked the task list", "checked the task list %d times")

private let toolPhrases: [String: ToolPhrase] = [
  "Read": ToolPhrase("Read", "Reading", "Could not read", "read %@", "read %d files"),
  "Write": ToolPhrase("Created", "Creating", "Could not create", "created %@", "created %d files"),
  "Edit": editPhrase,
  "MultiEdit": editPhrase,
  "NotebookEdit": editPhrase,
  "Bash": ToolPhrase("Ran", "Running", "Could not run", "ran a command", "ran %d commands"),
  "Grep": searchPhrase,
  "Glob": searchPhrase,
  "Agent": agentPhrase,
  "Task": agentPhrase,
  "WebFetch": ToolPhrase("Fetched", "Fetching", "Could not fetch", "fetched %@", "fetched %d pages"),
  "WebSearch": ToolPhrase("Searched the web for", "Searching the web for", "Could not search the web for", "searched the web", "ran %d web searches"),
  "TaskCreate": ToolPhrase("Added task", "Adding task", "Could not add task", "added a task", "added %d tasks"),
  "TaskUpdate": ToolPhrase("Updated a task", "Updating a task", "Could not update a task", "updated a task", "updated %d tasks"),
  "TaskList": taskListPhrase,
  "TaskGet": taskListPhrase,
  "TodoWrite": ToolPhrase("Updated the task list", "Updating the task list", "Could not update the task list", "updated the task list", "updated the task list %d times"),
  "Skill": ToolPhrase("Used skill", "Using skill", "Could not use skill", "used a skill", "used %d skills"),
  "ToolSearch": ToolPhrase("Looked up tools", "Looking up tools", "Could not look up tools", "looked up tools", "looked up tools %d times"),
  "ExitPlanMode": ToolPhrase("Proposed a plan", "Proposing a plan", "Proposed a plan", "proposed a plan", "proposed %d plans"),
  "AskUserQuestion": ToolPhrase("Asked a question", "Asking a question", "Could not ask a question", "asked a question", "asked %d questions")
]

private let fileTools: Set<String> = ["Read", "Write", "Edit", "MultiEdit", "NotebookEdit"]

/// A tool without a phrase of its own reads "Used <name>".
func toolPhrase(for name: String) -> ToolPhrase {
  if let phrase = toolPhrases[name] { return phrase }

  let display = toolDisplayName(name)
  return ToolPhrase("Used \(display)", "Using \(display)", "Could not use \(display)", "used \(display)", "used \(display) %d times")
}

/// `mcp__SafariPilot__get_page_text` reads "SafariPilot get page text". A server named by a UUID is left out.
func toolDisplayName(_ name: String) -> String {
  guard name.hasPrefix("mcp__") else { return name }

  let parts = name.dropFirst(5).components(separatedBy: "__")
  guard parts.count > 1 else { return parts[0].replacingOccurrences(of: "_", with: " ") }

  let tool = parts.dropFirst().joined(separator: " ").replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")

  if UUID(uuidString: parts[0]) != nil { return tool }

  return parts[0].replacingOccurrences(of: "_", with: " ") + " " + tool
}

/// The file a file tool works on.
func toolPath(_ name: String, input: JSONValue) -> String? {
  guard fileTools.contains(name) else { return nil }

  return input["file_path"]?.string ?? input["notebook_path"]?.string
}

/// What follows the verb in a tool row: a file name, a command cut to one line, a pattern.
func toolTarget(_ name: String, input: JSONValue) -> String {
  if let path = toolPath(name, input: input) { return URL(filePath: path).lastPathComponent }

  switch name {
  case "Bash": return commandName(input["command"]?.string ?? "")
  case "Grep", "Glob": return oneLine(input["pattern"]?.string ?? "", limit: 60)
  case "Agent", "Task": return oneLine(input["description"]?.string ?? "", limit: 80)
  case "WebFetch": return input["url"]?.string.flatMap { URL(string: $0)?.host() } ?? oneLine(input["url"]?.string ?? "", limit: 60)
  case "WebSearch": return oneLine(input["query"]?.string ?? "", limit: 60)
  case "TaskCreate": return oneLine(input["subject"]?.string ?? "", limit: 60)
  case "Skill": return input["skill"]?.string ?? ""
  default: return ""
  }
}

/// The program a command runs, past any leading `cd`, with an ellipsis when more follows: "python3\u{2026}".
func commandName(_ command: String) -> String {
  var rest = command.trimmingCharacters(in: .whitespacesAndNewlines)

  while rest.hasPrefix("cd "), let range = rest.range(of: "&&") { rest = rest[range.upperBound...].trimmingCharacters(in: .whitespaces) }

  let name = String(rest.prefix { !$0.isWhitespace && $0 != ";" })
  return name.count < rest.count ? name + "\u{2026}" : name
}

/// A running call as a sentence: "Reading TerminalView.swift".
func toolActivity(_ name: String, input: JSONValue) -> String {
  [toolPhrase(for: name).present, toolTarget(name, input: input)].filter { !$0.isEmpty }.joined(separator: " ")
}

/// The first line of `text`, with the middle cut out when it is longer than `limit`.
func oneLine(_ text: String, limit: Int) -> String {
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  let line = String(trimmed.prefix { !$0.isNewline })
  let continues = line.count < trimmed.count
  guard line.count > limit else { return continues ? line + " \u{2026}" : line }

  let head = line.prefix(limit * 2 / 3)
  let tail = line.suffix(limit - head.count - 1)
  return "\(head)\u{2026}\(tail)"
}

/// One piece of a summary sentence. A target, such as a file name, is set apart from the words around it.
struct SummaryPart: Equatable {
  var text: String
  var isTarget = false
}

/// A run of calls as one sentence: "Read 2 files, ran a command".
func toolSummary(_ calls: [(name: String, target: String)]) -> [SummaryPart] {
  var phrases: [ToolPhrase] = []
  var parts: [SummaryPart] = []

  for call in calls where !phrases.contains(toolPhrase(for: call.name)) { phrases.append(toolPhrase(for: call.name)) }

  for (index, phrase) in phrases.enumerated() {
    let matching = calls.filter { toolPhrase(for: $0.name) == phrase }
    var text = matching.count > 1 ? String(format: phrase.many, matching.count) : phrase.one

    if index == 0 { text = text.prefix(1).uppercased() + text.dropFirst() } else { text = ", " + text }

    guard matching.count == 1, let range = text.range(of: "%@") else {
      parts.append(SummaryPart(text: text))
      continue
    }

    parts.append(SummaryPart(text: String(text[..<range.lowerBound])))
    parts.append(SummaryPart(text: matching[0].target, isTarget: true))
    parts.append(SummaryPart(text: String(text[range.upperBound...])))
  }

  return parts.filter { !$0.text.isEmpty }
}

/// A tool's input as indented JSON with its keys in a stable order. Empty for an input with no fields.
func readableJSON(_ input: JSONValue) -> String {
  guard case .object(let fields) = input, !fields.isEmpty else { return "" }

  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  return (try? encoder.encode(input)).map { String(decoding: $0, as: UTF8.self) } ?? ""
}
