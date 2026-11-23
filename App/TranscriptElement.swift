import ClaudeEngine
import Foundation

/// One tool call as a sentence.
struct ToolRow: Equatable {
  enum State: Equatable {
    case running, waiting, completed, failed
  }

  /// The tool call's id, which a click toggles.
  var id: String
  var verb: String
  var target: String
  /// Gray text after the target: an agent's type and usage, and the duration in a verbose transcript.
  var note = ""
  var added = 0
  var removed = 0
  var state = State.completed
  var isExpanded = false
  var tooltip = ""
  var copy: CopySource?
}

/// A run of finished tool calls as one sentence.
struct GroupRow: Equatable {
  var id: String
  var summary: String
  var added = 0
  var removed = 0
  var isExpanded = false
}

/// What a context menu's Copy item puts on the pasteboard.
struct CopySource: Equatable {
  let title: String
  let text: String
}

/// A piece of what an expanded tool row shows under it.
enum DetailBlock: Equatable {
  case command(String)
  /// Monospaced lines.
  case output(String)
  /// Patch lines, each starting with a space, `+` or `-`.
  case diff([String])
  /// Markdown, for an agent's report.
  case report(String)
  /// A line that shows the rest of a capped output when clicked.
  case more(id: String, hidden: Int)
  case less(id: String)
  case note(String)
}

/// Where a row or its detail sits in an expanded group's bordered list.
struct BoxSlot: Equatable {
  var isFirst = false
  var isLast = false
}

/// One piece of the transcript. The text view holds each element's text in order,
/// and replaces only the elements that changed.
struct TranscriptElement: Equatable, Identifiable {
  enum Kind: Equatable {
    case header(String)
    case prompt(String)
    /// A turn something other than a person started.
    case notice(symbol: String, text: String, source: String)
    /// Markdown.
    case reply(String)
    /// A thinking block, shown in a verbose transcript.
    case thought(String)
    /// Claude is thinking right now.
    case thinking
    case tool(ToolRow)
    case group(GroupRow)
    case detail([DetailBlock])
    case tasks([TaskItem])
    case permission(requestId: String)
    case footer(String)
  }

  let id: String
  var kind: Kind
  /// Points of space above.
  var spacing = 12.0
  var box: BoxSlot?
}

/// A permission prompt waiting for an answer.
struct PendingRequest: Equatable {
  var requestId: String
  var toolUseId: String?
}

struct TranscriptInput {
  var header = ""
  var transcript = Transcript()
  var streaming: [StreamingMessage.Block] = []
  var tasks: [TaskItem] = []
  var pending: [PendingRequest] = []
  /// A process is attached, so the last turn can still be running.
  var isLive = false
}

/// Turns a transcript into elements. Finished turns are kept between calls, so a streaming reply rebuilds only the last turn.
struct TranscriptBuilder {
  /// A verbose transcript expands every row and shows thinking.
  var isVerbose = false { didSet { cache = [:] } }
  /// Rows and groups the user opened.
  var expanded: Set<String> = [] { didSet { cache = [:] } }
  /// Tool calls whose capped output is shown in full.
  var unfolded: Set<String> = [] { didSet { cache = [:] } }
  var calendar = Calendar.current
  var locale = Locale.current

  private var cache: [Int: CachedTurn] = [:]
  private static let cappedLines = 16
  private static let mostLines = 2000

  private struct AgentState: Equatable {
    var status: ClaudeTask.Status
    var usage: ClaudeTask.Usage?
    var summary: String?
  }

  private struct TurnKey: Equatable {
    var range: Range<Int>
    var status: Turn.Status
    var isRunning: Bool
    var tasks: [TaskItem]
    var pending: [PendingRequest]
  }

  private struct CachedTurn {
    var key: TurnKey
    var agentIds: [String]
    var agents: [AgentState?]
    var built: BuiltTurn
  }

  private struct BuiltTurn {
    var elements: [TranscriptElement] = []
    /// Requests shown under their tool call.
    var placed: Set<String> = []
    var agentIds: [String] = []
  }

  private enum Entry {
    case reply(id: String, text: String)
    case thought(id: String, text: String)
    case thinking(id: String)
    case prompt(id: String, text: String)
    case tool(id: String, name: String, input: JSONValue, call: ToolCall?)

    var folds: Bool {
      guard case .tool(_, _, _, let call) = self else { return false }

      return call?.status == .completed
    }
  }

  private struct Context {
    var transcript: Transcript
    var pending: [PendingRequest]
    var agents: [String: ClaudeTask]
  }

  /// Opens or closes a row or group, or shows or hides the rest of a capped output.
  mutating func toggle(_ id: String) {
    if id.hasSuffix("/more") {
      unfolded.formSymmetricDifference([String(id.dropLast(5))])
    } else {
      expanded.formSymmetricDifference([id])
    }
  }

  mutating func elements(for input: TranscriptInput) -> [TranscriptElement] {
    let turns = input.transcript.turns
    let context = Context(transcript: input.transcript, pending: input.pending, agents: Dictionary(input.transcript.tasks.map { ($0.id, $0) }) { first, _ in first })
    var elements = [TranscriptElement(id: "header", kind: .header(input.header), spacing: 0)]
    var placed: Set<String> = []
    var streamed = false

    for (index, turn) in turns.enumerated() {
      let isRunning = index == turns.count - 1 && input.isLive && turn.status == .running
      let key = TurnKey(range: turn.messageRange, status: turn.status, isRunning: isRunning, tasks: isRunning ? input.tasks : [], pending: input.pending)
      var built: BuiltTurn

      if isRunning, !input.streaming.isEmpty {
        streamed = true
        built = build(turn, key: key, streaming: input.streaming, context: context)
      } else if let cached = cache[turn.id], cached.key == key, cached.agentIds.map({ agentState(context.agents[$0]) }) == cached.agents {
        built = cached.built
      } else {
        built = build(turn, key: key, streaming: [], context: context)
        cache[turn.id] = CachedTurn(key: key, agentIds: built.agentIds, agents: built.agentIds.map { agentState(context.agents[$0]) }, built: built)
      }

      elements += built.elements
      placed.formUnion(built.placed)
    }

    // Stream events can outrun the frame that opens their turn.
    if !streamed, input.isLive, !input.streaming.isEmpty {
      elements += blocks(entries(turnId: "tail", items: [], streaming: input.streaming, context: context), tasks: [], context: context).elements
    }

    // A subagent's request has no row on the main thread, so its card goes last.
    for request in input.pending where !placed.contains(request.requestId) {
      elements.append(TranscriptElement(id: "permission/\(request.requestId)", kind: .permission(requestId: request.requestId)))
    }

    return elements
  }

  private func agentState(_ task: ClaudeTask?) -> AgentState? {
    task.map { AgentState(status: $0.status, usage: $0.usage, summary: $0.summary) }
  }

  private func build(_ turn: Turn, key: TurnKey, streaming: [StreamingMessage.Block], context: Context) -> BuiltTurn {
    var built = BuiltTurn()

    if let prompt = turn.prompt?.text, !prompt.allSatisfy(\.isWhitespace) {
      built.elements.append(TranscriptElement(id: "\(turn.id)/prompt", kind: promptKind(prompt, origin: turn.origin), spacing: 22))
    }

    let body = blocks(entries(turnId: String(turn.id), items: turn.items, streaming: streaming, context: context), tasks: key.tasks, context: context)
    built.elements += body.elements
    built.placed = body.placed
    built.agentIds = body.agentIds

    if !key.isRunning, turn.status != .running, let footer = footer(for: turn) {
      built.elements.append(TranscriptElement(id: "\(turn.id)/footer", kind: .footer(footer)))
    }

    return built
  }

  private func promptKind(_ prompt: String, origin: String?) -> TranscriptElement.Kind {
    let symbols = ["task_notification": "bell", "scheduled": "clock", "peer": "arrow.left.arrow.right"]
    guard let symbol = origin.flatMap({ symbols[$0] }) else { return .prompt(prompt.trimmingCharacters(in: .whitespacesAndNewlines)) }

    var line = prompt

    // A task notification wraps its one-line summary in tags.
    if let start = prompt.range(of: "<summary>"), let end = prompt.range(of: "</summary>", range: start.upperBound..<prompt.endIndex) {
      line = String(prompt[start.upperBound..<end.lowerBound])
    }

    return .notice(symbol: symbol, text: oneLine(line.replacing(/<[^>]+>/, with: ""), limit: 120), source: prompt)
  }

  /// A turn's items, then the blocks still streaming. An item's id is its place in the turn,
  /// so a streamed block keeps its id, and its text in the view, when its frame arrives.
  private func entries(turnId: String, items: [TurnItem], streaming: [StreamingMessage.Block], context: Context) -> [Entry] {
    var entries: [Entry] = []

    for (index, item) in items.enumerated() {
      let id = "\(turnId)/\(index)"

      switch item.content {
      case .text(let text):
        if !text.allSatisfy(\.isWhitespace) { entries.append(.reply(id: id, text: text)) }
      case .thinking(let text):
        if isVerbose, !text.allSatisfy(\.isWhitespace) { entries.append(.thought(id: id, text: text)) }
      case .toolCall(let callId):
        if let call = context.transcript.toolCall(callId) { entries.append(.tool(id: callId, name: call.name, input: call.input, call: call)) }
      case .prompt(let blocks):
        if !blocks.text.allSatisfy(\.isWhitespace) { entries.append(.prompt(id: id, text: blocks.text)) }
      }
    }

    for (index, block) in streaming.enumerated() {
      let id = "\(turnId)/\(items.count + index)"

      switch block {
      case .text(let text):
        if !text.allSatisfy(\.isWhitespace) { entries.append(.reply(id: id, text: text)) }
      case .thinking(let text):
        if isVerbose, !text.allSatisfy(\.isWhitespace) {
          entries.append(.thought(id: id, text: text))
        } else {
          entries.append(.thinking(id: id))
        }
      case .toolUse(let callId, let name, let partialInput):
        // The input JSON rarely parses before the block ends, and the row needs none of it to say what is running.
        entries.append(.tool(id: callId, name: name, input: (try? JSONValue(parsing: Data(partialInput.utf8))) ?? [:], call: nil))
      case .other:
        break
      }
    }

    return entries
  }

  /// Folds runs of finished tool calls into groups and lays the entries out as elements. A running turn's task list follows its first block.
  private func blocks(_ entries: [Entry], tasks: [TaskItem], context: Context) -> BuiltTurn {
    var built = BuiltTurn()
    var index = 0
    var isFirst = true

    while index < entries.count {
      var end = index + 1

      if entries[index].folds {
        while end < entries.count, entries[end].folds { end += 1 }
      }

      let run = Array(entries[index..<end])

      if run.count > 1 {
        group(run, into: &built, context: context)
      } else {
        single(run[0], into: &built, context: context)
      }

      if isFirst, !tasks.isEmpty { built.elements.append(TranscriptElement(id: "tasks", kind: .tasks(tasks))) }

      isFirst = false
      index = end
    }

    return built
  }

  private func single(_ entry: Entry, into built: inout BuiltTurn, context: Context) {
    switch entry {
    case .reply(let id, let text):
      built.elements.append(TranscriptElement(id: id, kind: .reply(text.trimmingCharacters(in: .whitespacesAndNewlines))))
    case .thought(let id, let text):
      built.elements.append(TranscriptElement(id: id, kind: .thought(text.trimmingCharacters(in: .whitespacesAndNewlines))))
    case .thinking(let id):
      built.elements.append(TranscriptElement(id: id, kind: .thinking))
    case .prompt(let id, let text):
      built.elements.append(TranscriptElement(id: id, kind: .prompt(text.trimmingCharacters(in: .whitespacesAndNewlines))))
    case .tool(let id, let name, let input, let call):
      let row = row(id: id, name: name, input: input, call: call, context: context)
      built.elements.append(TranscriptElement(id: id, kind: .tool(row)))

      if context.agents[id] != nil { built.agentIds.append(id) }

      for request in context.pending where request.toolUseId == id {
        built.elements.append(TranscriptElement(id: "permission/\(request.requestId)", kind: .permission(requestId: request.requestId), spacing: 8))
        built.placed.insert(request.requestId)
      }

      let detail = detail(id: id, name: name, input: input, call: call, context: context)

      if row.isExpanded, !detail.isEmpty { built.elements.append(TranscriptElement(id: "\(id)/detail", kind: .detail(detail), spacing: 8)) }
    }
  }

  private func group(_ run: [Entry], into built: inout BuiltTurn, context: Context) {
    var rows: [(row: ToolRow, detail: [DetailBlock])] = []
    var calls: [(name: String, target: String)] = []

    for case .tool(let id, let name, let input, let call) in run {
      let row = row(id: id, name: name, input: input, call: call, context: context)
      rows.append((row, row.isExpanded ? detail(id: id, name: name, input: input, call: call, context: context) : []))
      calls.append((name, row.target))

      if context.agents[id] != nil { built.agentIds.append(id) }
    }

    let id = "group/\(rows[0].row.id)"
    let isExpanded = isVerbose || expanded.contains(id)
    let header = GroupRow(id: id, summary: toolSummary(calls), added: rows.reduce(0) { $0 + $1.row.added }, removed: rows.reduce(0) { $0 + $1.row.removed }, isExpanded: isExpanded)
    built.elements.append(TranscriptElement(id: id, kind: .group(header)))
    guard isExpanded else { return }

    for (index, entry) in rows.enumerated() {
      let isLast = index == rows.count - 1
      built.elements.append(TranscriptElement(id: entry.row.id, kind: .tool(entry.row), spacing: index == 0 ? 8 : 0, box: BoxSlot(isFirst: index == 0, isLast: isLast && entry.detail.isEmpty)))

      if !entry.detail.isEmpty {
        built.elements.append(TranscriptElement(id: "\(entry.row.id)/detail", kind: .detail(entry.detail), spacing: 0, box: BoxSlot(isLast: isLast)))
      }
    }
  }

  private func row(id: String, name: String, input: JSONValue, call: ToolCall?, context: Context) -> ToolRow {
    let phrase = toolPhrase(for: name)
    let target = toolTarget(name, input: input)
    let duration = call?.duration.map(durationText)
    var row = ToolRow(id: id, verb: phrase.present, target: target, isExpanded: isVerbose || expanded.contains(id))
    var notes: [String] = []
    var tips: [String] = []

    switch call?.status {
    case .completed:
      row.state = .completed
      row.verb = phrase.past
    case .failed:
      row.state = .failed
      row.verb = phrase.past
    default:
      row.state = context.pending.contains { $0.toolUseId == id } ? .waiting : .running
    }

    if let task = context.agents[id] {
      if let type = task.subagentType { notes.append(type) }

      if let usage = task.usage {
        notes.append(usage.toolUses == 1 ? "1 tool use" : "\(usage.toolUses) tool uses")
        notes.append(tokenCount(usage.totalTokens))
      }
    }

    if let command = input["command"]?.string, name == "Bash" {
      row.copy = CopySource(title: "Copy Command", text: command)
      tips.append(command)
    } else if let path = toolPath(name, input: input) {
      row.copy = CopySource(title: "Copy Path", text: path)
      tips.append(path)
    } else if !target.isEmpty {
      tips.append(target)
    }

    if let duration {
      tips.append(duration)

      if isVerbose { notes.append(duration) }
    }

    row.note = notes.joined(separator: " \u{B7} ")
    row.tooltip = tips.joined(separator: "\n")
    row.added = call?.lineDelta?.added ?? 0
    row.removed = call?.lineDelta?.removed ?? 0
    return row
  }

  /// What an expanded row shows: Bash's command and output, an edit's patch, an agent's report, anything else's result text.
  private func detail(id: String, name: String, input: JSONValue, call: ToolCall?, context: Context) -> [DetailBlock] {
    var blocks: [DetailBlock] = []
    let result = call?.result.map { $0.text.trimmingCharacters(in: .newlines) } ?? ""

    if name == "Bash", let command = input["command"]?.string {
      blocks.append(.command("$ " + command))
    } else if toolPhrase(for: name).past.hasPrefix("Used "), case .object(let fields) = input, !fields.isEmpty, let json = try? JSONEncoder.readable.encode(input) {
      blocks.append(.output(String(decoding: json, as: UTF8.self)))
    }

    if let task = context.agents[id] {
      let report = task.summary ?? result

      if !report.isEmpty { blocks.append(.report(report)) }

      return blocks
    }

    guard let call, call.result != nil else { return blocks }

    let patch = call.isError ? [] : patchLines(call.output)

    if !patch.isEmpty {
      let shown = capped(patch, id: id)
      blocks.append(.diff(shown.lines))
      blocks += shown.trailer
    } else if !result.isEmpty {
      let shown = capped(result.components(separatedBy: "\n"), id: id)
      blocks.append(.output(shown.lines.joined(separator: "\n")))
      blocks += shown.trailer
    }

    return blocks
  }

  /// The lines to show of a long output, and the lines under them that say what was left out.
  private func capped(_ lines: [String], id: String) -> (lines: [String], trailer: [DetailBlock]) {
    let isUnfolded = unfolded.contains(id)
    let limit = isUnfolded ? Self.mostLines : Self.cappedLines
    let shown = lines.prefix(limit).map { $0.count > 2000 ? String($0.prefix(2000)) + "\u{2026}" : $0 }
    var trailer: [DetailBlock] = []

    if lines.count > limit, !isUnfolded { trailer.append(.more(id: "\(id)/more", hidden: lines.count - limit)) }

    if lines.count > limit, isUnfolded { trailer.append(.note("\((lines.count - limit).formatted(.number.locale(locale))) more lines not shown")) }

    if lines.count > Self.cappedLines, isUnfolded { trailer.append(.less(id: "\(id)/more")) }

    return (shown, trailer)
  }

  /// An Edit or Write result as patch lines. A created file has no patch, so its content is all added lines.
  private func patchLines(_ output: JSONValue?) -> [String] {
    guard let hunks = output?["structuredPatch"]?.array else { return [] }

    if hunks.isEmpty, output?["type"]?.string == "create", let content = output?["content"]?.string, !content.isEmpty {
      var lines = content.components(separatedBy: "\n")

      if lines.last == "" { lines.removeLast() }

      return lines.map { "+" + $0 }
    }

    return hunks.flatMap { hunk in
      let lines = hunk["lines"]?.array?.compactMap(\.string) ?? []
      guard hunks.count > 1, let oldStart = hunk["oldStart"]?.int, let oldLines = hunk["oldLines"]?.int, let newStart = hunk["newStart"]?.int, let newLines = hunk["newLines"]?.int else { return lines }

      return ["@@ -\(oldStart),\(oldLines) +\(newStart),\(newLines) @@"] + lines
    }
  }

  private func footer(for turn: Turn) -> String? {
    guard let startedAt = turn.startedAt else { return nil }

    var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour().minute()

    // "2:14 PM" today, "Nov 20, 2:14 PM" for an earlier day, with the year once it differs.
    if !calendar.isDateInToday(startedAt) { style = style.month(.abbreviated).day() }

    if !calendar.isDate(startedAt, equalTo: .now, toGranularity: .year) { style = style.year() }

    return [startedAt.formatted(style), turn.duration.map(durationText)].compactMap { $0 }.joined(separator: " \u{B7} ")
  }

  /// "0.4s" under ten seconds, "1m 52s" above.
  private func durationText(_ duration: Duration) -> String {
    if duration < .seconds(10) { return duration.formatted(.units(allowed: [.seconds], width: .narrow, fractionalPart: .show(length: 1)).locale(locale)) }

    return duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow).locale(locale))
  }

  private func tokenCount(_ tokens: Int) -> String {
    if tokens < 1000 { return "\(tokens) tokens" }

    return (Double(tokens) / 1000).formatted(.number.precision(.fractionLength(1)).locale(locale)) + "k tokens"
  }
}

extension JSONEncoder {
  /// Indented, with keys in a stable order.
  fileprivate static let readable = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()
}
