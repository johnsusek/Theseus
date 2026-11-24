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

private let editPhrase = ToolPhrase("Edited", "Editing", "Could not edit", "edited a file", "made %d edits")
private let searchPhrase = ToolPhrase("Searched for", "Searching for", "Could not search for", "ran a search", "ran %d searches")
private let agentPhrase = ToolPhrase("Ran agent", "Running agent", "Could not run agent", "ran an agent", "ran %d agents")
private let skillPhrase = ToolPhrase("Ran skill", "Running skill", "Could not run skill", "ran a skill", "ran skill %d times")
private let readPhrase = ToolPhrase("Read", "Reading", "Could not read", "read a file", "read %d files")
private let taskListPhrase = ToolPhrase("Checked the task list", "Checking the task list", "Could not check the task list", "checked the task list", "checked the task list %d times")

private let toolPhrases: [String: ToolPhrase] = [
  "Read": readPhrase,
  "Write": ToolPhrase("Created", "Creating", "Could not create", "created a file", "created %d files"),
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
  "Skill": skillPhrase,
  "ToolSearch": ToolPhrase("Looked up tools", "Looking up tools", "Could not look up tools", "looked up tools", "looked up tools %d times"),
  "ExitPlanMode": ToolPhrase("Proposed a plan", "Proposing a plan", "Proposed a plan", "proposed a plan", "proposed %d plans"),
  "AskUserQuestion": ToolPhrase("Asked a question", "Asking a question", "Could not ask a question", "asked a question", "asked %d questions")
]

/// The desktop app's browser tools, keyed by tool name, or by name and action for its `computer` tool.
private let browser = "mcp__Claude_Browser__"
private let clickPhrase = ToolPhrase("Clicked", "Clicking", "Could not click", "clicked", "clicked")
private let readPagePhrase = ToolPhrase("Read page", "Reading page", "Could not read page", "read page", "read page")

private let browserPhrases: [String: ToolPhrase] = [
  "preview_start": ToolPhrase("Started preview", "Starting preview", "Could not start preview", "started preview", "started %d previews"),
  "navigate": ToolPhrase("Opened page", "Opening page", "Could not open page", "opened page", "opened %d pages"),
  "javascript_tool": ToolPhrase("Ran page script", "Running page script", "Could not run page script", "ran page script", "ran %d page scripts"),
  "find": ToolPhrase("Found", "Finding", "Could not find", "found", "found"),
  "read_page": readPagePhrase,
  "get_page_text": readPagePhrase,
  "form_input": ToolPhrase("Filled form", "Filling form", "Could not fill form", "filled form", "filled form"),
  "computer/screenshot": ToolPhrase("Captured page", "Capturing page", "Could not capture page", "captured page", "captured page"),
  "computer/zoom": ToolPhrase("Captured page", "Capturing page", "Could not capture page", "captured page", "captured page"),
  "computer/left_click": clickPhrase,
  "computer/right_click": clickPhrase,
  "computer/double_click": clickPhrase,
  "computer/triple_click": clickPhrase,
  "computer/type": ToolPhrase("Typed", "Typing", "Could not type", "typed", "typed"),
  "computer/key": ToolPhrase("Pressed key", "Pressing key", "Could not press key", "pressed key", "pressed keys"),
  "computer/scroll": ToolPhrase("Scrolled", "Scrolling", "Could not scroll", "scrolled", "scrolled"),
  "computer/scroll_to": ToolPhrase("Scrolled", "Scrolling", "Could not scroll", "scrolled", "scrolled"),
  "computer/hover": ToolPhrase("Hovered", "Hovering", "Could not hover", "hovered", "hovered"),
  "computer/wait": ToolPhrase("Waited", "Waiting", "Could not wait", "waited", "waited")
]

private let fileTools: Set<String> = ["Read", "Write", "Edit", "MultiEdit", "NotebookEdit"]

/// A tool without a phrase of its own reads "Used <name>".
func toolPhrase(for name: String) -> ToolPhrase {
  if let phrase = toolPhrases[name] ?? (name.hasPrefix(browser) ? browserPhrases[String(name.dropFirst(browser.count))] : nil) { return phrase }

  let display = toolDisplayName(name)
  return ToolPhrase("Used \(display)", "Using \(display)", "Could not use \(display)", "used \(display)", "used \(display) %d times")
}

/// The names a call's phrases are looked up by: its own, a browser `computer` call's with its action, or one per action of a browser batch.
func phraseNames(_ name: String, input: JSONValue) -> [String] {
  if name == browser + "browser_batch" {
    let names = (input["actions"]?.array ?? []).flatMap { phraseNames(browser + ($0["name"]?.string ?? ""), input: $0["input"] ?? [:]) }
    return names.isEmpty ? [name] : names
  }

  if name == browser + "computer", let action = input["action"]?.string { return [name + "/" + action] }

  return [name]
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
  case browser + "preview_start": return input["name"]?.string ?? ""
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

/// A running call as a sentence: "Reading TerminalView.swift", or a command's description: "Listing the project folder".
func toolActivity(_ name: String, input: JSONValue) -> String {
  if name == "Bash", let description = input["description"]?.string, !description.isEmpty { return conjugated(description, isRunning: true) }

  return [toolPhrase(for: name).present, toolTarget(name, input: input)].filter { !$0.isEmpty }.joined(separator: " ")
}

private let pastForms = ["run": "ran", "rerun": "reran", "build": "built", "rebuild": "rebuilt", "make": "made", "find": "found", "read": "read", "write": "wrote", "rewrite": "rewrote", "get": "got", "set": "set", "put": "put", "send": "sent", "take": "took", "give": "gave", "keep": "kept", "do": "did", "undo": "undid", "go": "went", "begin": "began", "split": "split", "commit": "committed", "submit": "submitted", "fetch": "fetched"]

/// A description written as a command, "List files", in the tense a row needs: "Listed files" when done, "Listing files" while running.
/// A description that does not start with a plain verb stays as it is.
func conjugated(_ description: String, isRunning: Bool) -> String {
  let first = String(description.prefix { $0.isLetter })
  let word = first.lowercased()
  guard word.count > 1, word.count == description.prefix(while: { !$0.isWhitespace }).count, !word.hasSuffix("ing"), !word.hasSuffix("ed") else { return description }

  // One vowel then one consonant at the end, as in "stop" and "plan", doubles the consonant.
  let doubles = word.wholeMatch(of: /[^aeiou]*[aeiou][^aeiouwxy]/) != nil || ["commit", "submit"].contains(word)
  var verb: String

  if isRunning {
    if word.hasSuffix("ie") {
      verb = word.dropLast(2) + "ying"
    } else if word.hasSuffix("e"), !word.hasSuffix("ee"), word != "be" {
      verb = word.dropLast() + "ing"
    } else {
      verb = word + (doubles ? String(word.last!) : "") + "ing"
    }
  } else if let past = pastForms[word] {
    verb = past
  } else if word.hasSuffix("e") {
    verb = word + "d"
  } else if word.hasSuffix("y"), let before = word.dropLast().last, !"aeiou".contains(before) {
    verb = word.dropLast() + "ied"
  } else {
    verb = word + (doubles ? String(word.last!) : "") + "ed"
  }

  if first.first?.isUppercase == true { verb = verb.prefix(1).uppercased() + verb.dropFirst() }

  var rest = String(description.dropFirst(first.count))

  // "Generate the files and preview the crop": a second verb is taken as one when an object or nothing follows it.
  if let range = rest.range(of: " and ") {
    let words = rest[range.upperBound...].split(separator: " ", maxSplits: 2)
    let next = words.count > 1 ? words[1].lowercased() : nil

    // A plural noun ends in "s"; a verb seldom does.
    if let second = words.first, second.allSatisfy(\.isLowercase), !second.hasSuffix("s") || second.hasSuffix("ss"), next.map({ objectWords.contains($0) || $0.hasSuffix("'s") || $0.hasSuffix("\u{2019}s") }) ?? true {
      rest = rest[..<range.upperBound] + conjugated(String(rest[range.upperBound...]), isRunning: isRunning)
    }
  }

  return verb + rest
}

private let objectWords: Set = ["the", "a", "an", "it", "them", "its", "their", "this", "that", "these", "those", "each", "every", "all", "any", "some", "my", "your", "our", "his", "her"]

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

/// A run of calls as one sentence: "Read 2 files, ran a command", with skills last. `namesRead` names a lone read's file: "read Notes.md".
func toolSummary(_ calls: [(name: String, target: String)], namesRead: Bool = false) -> [SummaryPart] {
  var phrases: [ToolPhrase] = []
  var parts: [SummaryPart] = []

  for call in calls where !phrases.contains(toolPhrase(for: call.name)) { phrases.append(toolPhrase(for: call.name)) }

  phrases = phrases.filter { $0 != skillPhrase } + phrases.filter { $0 == skillPhrase }

  for (index, phrase) in phrases.enumerated() {
    let matching = calls.filter { toolPhrase(for: $0.name) == phrase }
    let one = namesRead && phrase == readPhrase && !matching[0].target.isEmpty ? "read %@" : phrase.one
    var text = matching.count > 1 ? String(format: phrase.many, matching.count) : one

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
