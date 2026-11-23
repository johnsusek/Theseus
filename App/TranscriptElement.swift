import ClaudeEngine
import Foundation

/// One tool call as a sentence.
struct ToolRow: Equatable {
  enum State: Equatable {
    /// `stopped` is a call that got no result before its turn ended.
    case running, waiting, completed, failed, stopped
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

/// A prompt the app sent that the CLI has not echoed back yet. The echo carries the same uuid.
struct SentPrompt: Equatable {
  var uuid: String
  var text: String
}

struct TranscriptInput {
  var header = ""
  var transcript = Transcript()
  var streaming: [StreamingMessage.Block] = []
  var tasks: [TaskItem] = []
  var pending: [PendingRequest] = []
  /// A process is attached, so the last turn can still be running.
  var isLive = false
  /// Shown after everything else until their echo arrives, so a prompt appears when it is sent, also one queued behind a running turn.
  var sent: [SentPrompt] = []
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
    /// Tells a turn from one with the same number in another conversation shown by the same builder.
    var lastItemId: String?
    var status: Turn.Status
    var isRunning: Bool
    var tasks: [TaskItem]
    var pending: [PendingRequest]
    /// A footer names the day unless it is today.
    var today: Date
  }

  private struct CachedTurn {
    var key: TurnKey
    var agents: [AgentState?]
    var built: BuiltTurn
  }

  private struct BuiltTurn {
    var elements: [TranscriptElement] = []
    /// Requests shown under their tool call.
    var placed: Set<String> = []
    var agentIds: [String] = []
    /// Calls with no result yet. One can still arrive after the turn's own frames have stopped.
    var openCallIds: [String] = []
  }

  private enum Entry {
    case reply(id: String, text: String)
    case thought(id: String, text: String)
    case thinking(id: String)
    case prompt(id: String, text: String, origin: String?)
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
    /// The turn being built can still get results for its calls.
    var isRunning = false
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
    var context = Context(transcript: input.transcript, pending: input.pending, agents: Dictionary(input.transcript.tasks.map { ($0.id, $0) }) { first, _ in first })
    let today = calendar.startOfDay(for: .now)
    var elements = [TranscriptElement(id: "header", kind: .header(input.header), spacing: 0)]
    var placed: Set<String> = []
    var streamed = false

    for (index, turn) in turns.enumerated() {
      let isRunning = index == turns.count - 1 && input.isLive && turn.status == .running
      let key = TurnKey(range: turn.messageRange, lastItemId: turn.items.last?.id, status: turn.status, isRunning: isRunning, tasks: isRunning ? input.tasks : [], pending: input.pending, today: today)
      var built: BuiltTurn

      context.isRunning = isRunning

      if isRunning, !input.streaming.isEmpty {
        streamed = true
        built = build(turn, key: key, streaming: input.streaming, context: context)
      } else if let cached = cache[turn.id], cached.key == key, isCurrent(cached, context: context) {
        built = cached.built
      } else {
        built = build(turn, key: key, streaming: [], context: context)
        cache[turn.id] = CachedTurn(key: key, agents: built.agentIds.map { agentState(context.agents[$0]) }, built: built)
      }

      elements += built.elements
      placed.formUnion(built.placed)
    }

    context.isRunning = true

    // Stream events can outrun the frame that opens their turn.
    if !streamed, input.isLive, !input.streaming.isEmpty {
      elements += blocks(entries(turnId: "tail", items: [], streaming: input.streaming, context: context), tasks: [], context: context).elements
    }

    for prompt in input.sent { elements.append(TranscriptElement(id: "sent/\(prompt.uuid)", kind: .prompt(prompt.text), spacing: 22)) }

    // A subagent's request has no row on the main thread, so its card goes last.
    for request in input.pending where !placed.contains(request.requestId) {
      elements.append(TranscriptElement(id: "permission/\(request.requestId)", kind: .permission(requestId: request.requestId)))
    }

    return elements
  }

  private func agentState(_ task: ClaudeTask?) -> AgentState? {
    task.map { AgentState(status: $0.status, usage: $0.usage, summary: $0.summary) }
  }

  /// Whether what a kept turn showed of its agents and unanswered calls still holds. Neither changes the turn's own frames.
  private func isCurrent(_ cached: CachedTurn, context: Context) -> Bool {
    cached.built.agentIds.map { agentState(context.agents[$0]) } == cached.agents && cached.built.openCallIds.allSatisfy { context.transcript.toolCall($0)?.result == nil }
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
    built.openCallIds = body.openCallIds

    if turn.status != .running, let footer = footer(for: turn, in: context.transcript) {
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
      case .prompt(let blocks, let origin):
        if !blocks.text.allSatisfy(\.isWhitespace) { entries.append(.prompt(id: id, text: blocks.text, origin: origin)) }
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

    // A turn with nothing to show yet, or only thinking that has since been folded away, still lists its tasks.
    if isFirst, !tasks.isEmpty { built.elements.append(TranscriptElement(id: "tasks", kind: .tasks(tasks))) }

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
    case .prompt(let id, let text, let origin):
      built.elements.append(TranscriptElement(id: id, kind: promptKind(text, origin: origin)))
    case .tool(let id, let name, let input, let call):
      let row = row(id: id, name: name, input: input, call: call, context: context)
      built.elements.append(TranscriptElement(id: id, kind: .tool(row)))

      if context.agents[id] != nil { built.agentIds.append(id) }

      if call?.result == nil { built.openCallIds.append(id) }

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
      // The CLI wraps a call it refused before running in tool_use_error, and words a denial as below.
      let result = call?.result?.text ?? ""
      let isDenied = result.hasPrefix("The user denied") || result.hasPrefix("Permission for this")

      row.state = .failed
      row.verb = isDenied || result.hasPrefix("<tool_use_error>") ? phrase.failed : phrase.past

      if isDenied { notes.append("Denied") }
    default:
      row.state = context.pending.contains { $0.toolUseId == id } ? .waiting : context.isRunning ? .running : .stopped
    }

    if let task = context.agents[id] {
      if let type = task.subagentType { notes.append(type) }

      if let usage = task.usage {
        notes.append(usage.toolUses == 1 ? "1 tool use" : "\(usage.toolUses) tool uses")
        notes.append(tokenCount(usage.totalTokens, locale: locale))
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
    } else if toolPhrase(for: name).past.hasPrefix("Used ") {
      // A tool without a phrase of its own says nothing about its input in the row, so the detail shows it.
      let json = readableJSON(input)

      if !json.isEmpty { blocks.append(.output(json)) }
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

  /// "2:14 PM · 1m 52s", with "Stopped" after a turn the user interrupted, which the CLI marks with a user message of its own.
  private func footer(for turn: Turn, in transcript: Transcript) -> String? {
    guard let startedAt = turn.startedAt else { return nil }

    let wasStopped = transcript.messages[turn.messageRange].contains { message in
      guard case .user(let user) = message.kind else { return false }

      return user.content.text.hasPrefix("[Request interrupted by user")
    }

    var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour().minute()

    // "2:14 PM" today, "Nov 20, 2:14 PM" for an earlier day, with the year once it differs.
    if !calendar.isDateInToday(startedAt) { style = style.month(.abbreviated).day() }

    if !calendar.isDate(startedAt, equalTo: .now, toGranularity: .year) { style = style.year() }

    return [startedAt.formatted(style), turn.duration.map(durationText), wasStopped ? "Stopped" : nil].compactMap { $0 }.joined(separator: " \u{B7} ")
  }

  /// "0.4s" under ten seconds, "1m 52s" above.
  private func durationText(_ duration: Duration) -> String {
    if duration < .seconds(10) { return duration.formatted(.units(allowed: [.seconds], width: .narrow, fractionalPart: .show(length: 1)).locale(locale)) }

    return duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow).locale(locale))
  }
}
