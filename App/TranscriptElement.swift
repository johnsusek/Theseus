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
  /// Images the call returned, drawn small at the row's right edge.
  var thumbnails: [Thumbnail] = []
}

/// An image a tool call returned. Two are the same when their ids are, so comparing rows never compares image bytes.
struct Thumbnail: Equatable {
  var id: String
  var data: Data

  static func == (lhs: Thumbnail, rhs: Thumbnail) -> Bool { lhs.id == rhs.id }
}

/// A run of finished tool calls as one sentence.
struct GroupRow: Equatable {
  var id: String
  var summary: [SummaryPart]
  var added = 0
  var removed = 0
  var isExpanded = false
  /// The running turn's last run of calls reads as what the turn is doing, with its timer, until the turn moves on.
  var activity: Activity?
  var thumbnails: [Thumbnail] = []
}

/// A command the user ran from the desktop app, which records it as a prompt of its own: `<bash-input>` with its output.
struct ShellRun: Equatable {
  var command: String
  var output: String

  init?(prompt: String?) {
    guard let prompt, prompt.hasPrefix("<bash-input>"), let match = prompt.firstMatch(of: /<bash-input>([\s\S]*?)<\/bash-input>(?:<bash-stdout>([\s\S]*?)<\/bash-stdout>)?(?:<bash-stderr>([\s\S]*?)<\/bash-stderr>)?/) else { return nil }

    let entities = [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")]
    command = String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
    output = [match.2, match.3].compactMap { $0 }.map { stream in
      entities.reduce(String(stream)) { $0.replacingOccurrences(of: $1.0, with: $1.1) }.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }.joined(separator: "\n")
  }
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
  /// Patch lines, each starting with a space, `+` or `-`, under the name of the `file` they change and colored as its language.
  case diff([String], file: String? = nil)
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
    case prompt(String)
    /// A turn something other than a person started.
    case notice(symbol: String, text: String, source: String)
    /// Markdown.
    case reply(String)
    /// A thinking block, shown in a verbose transcript.
    case thought(String)
    /// What the running turn is doing, and when it started.
    case activity(text: String, since: Date)
    case tool(ToolRow)
    case group(GroupRow)
    case detail([DetailBlock])
    /// A command the user ran, or only its output when it sits under the reply's code block it came from.
    case shell(command: String?, output: String)
    case tasks([TaskItem])
    case permission(requestId: String)
    case nextStep(NextStep)
    case footer(TurnFooter)
  }

  let id: String
  var kind: Kind
  /// The turn the element belongs to. Sent prompts, the activity line and unplaced requests have none.
  var turn: Int?
  /// Points of space above.
  var spacing = 18.0
  var box: BoxSlot?
}

/// Under a finished turn, shown while the pointer is over the turn: "2:14 PM · 1m 52s", and the turn's replies for its Copy button.
struct TurnFooter: Equatable {
  var text: String
  var replies: String
}

/// The model's `wrap_up` call, which the transcript draws as a card under its turn instead of a tool row.
let wrapUpToolName = "mcp__theseus__wrap_up"

/// The desktop app's own turn tools, in sessions it ran: its `wrap_up` reads as a card like Theseus's, and its task list call has no row.
private let wrapUpToolNames: Set = [wrapUpToolName, "mcp__ccd_turn__wrap_up"]
private let unshownToolNames = wrapUpToolNames.union(["mcp__ccd_turn__update_plan"])

/// The last turn's recap, with a question and reply buttons. It goes away once anything is sent, as the desktop app's does.
struct NextStep: Equatable {
  var recap: String
  var ask: String?
  var actions: [String]

  init(input: JSONValue) {
    recap = input["recap"]?.string ?? ""
    ask = input["ask"]?.string.flatMap { $0.allSatisfy(\.isWhitespace) ? nil : $0 }
    // The desktop app's actions are objects with a label.
    actions = Array((input["actions"]?.array ?? []).compactMap { $0.string ?? $0["label"]?.string }.prefix(2))
  }
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
  var transcript = Transcript()
  var streaming: [StreamingMessage.Block] = []
  var tasks: [TaskItem] = []
  var pending: [PendingRequest] = []
  /// A process is attached, so the last turn can still be running.
  var isLive = false
  /// Shown after everything else until their echo arrives, so a prompt appears when it is sent, also one queued behind a running turn.
  var sent: [SentPrompt] = []
  /// Shown under the running turn while the session is busy.
  var activity: Activity?
}

struct Activity: Equatable {
  var text: String
  var since: Date
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
    var isLatest: Bool
    var tasks: [TaskItem]
    var pending: [PendingRequest]
    /// A footer names the day unless it is today.
    var today: Date
    var activity: Activity?
    /// Commands run from this turn's code blocks, shown under them.
    var runs: [ShellRun]
    /// The turn is a command shown under an earlier turn's code block, so it shows nothing itself.
    var isAttached: Bool
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
    /// The turn's last group shows the activity, so the activity line is left out.
    var showsActivity = false
  }

  private enum Entry {
    case reply(id: String, text: String)
    case thought(id: String, text: String)
    case prompt(id: String, text: String, origin: String?)
    case tool(id: String, name: String, input: JSONValue, call: ToolCall?)
  }

  private struct Context {
    var transcript: Transcript
    var pending: [PendingRequest]
    var agents: [String: ClaudeTask]
    /// The turn being built can still get results for its calls.
    var isRunning = false
    /// The turn being built is the last one, finished, with nothing sent after it.
    var isLatest = false
    var activity: Activity?
    var runs: [ShellRun] = []
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
    var elements: [TranscriptElement] = []
    var placed: Set<String> = []
    var streamed = false
    // Sent prompts are queued behind the running turn only once that turn shows its own prompt. `system/init` opens a turn before the echo.
    var isQueuedBehind = false
    var showsActivity = false
    var runs: [Int: [ShellRun]] = [:]
    var attached: Set<Int> = []
    var replied: Turn?

    // A command run from a code block goes under that block in the turn before it, as the desktop app shows it.
    for turn in turns {
      guard let run = ShellRun(prompt: turn.prompt?.text) else {
        replied = turn
        continue
      }

      let hasBlock = replied?.items.contains { item in
        guard case .text(let text) = item.content else { return false }

        return fencedBlocks(text).contains { $0.code == run.command }
      }

      guard let replied, hasBlock == true else { continue }

      runs[replied.id, default: []].append(run)
      attached.insert(turn.id)
    }

    for (index, turn) in turns.enumerated() {
      let isRunning = index == turns.count - 1 && input.isLive && turn.status == .running
      let isLatest = index == turns.count - 1 && !isRunning && input.sent.isEmpty
      let key = TurnKey(range: turn.messageRange, lastItemId: turn.items.last?.id, status: turn.status, isRunning: isRunning, isLatest: isLatest, tasks: isRunning ? input.tasks : [], pending: input.pending, today: today, activity: isRunning ? input.activity : nil, runs: runs[turn.id] ?? [], isAttached: attached.contains(turn.id))
      var built: BuiltTurn

      context.isRunning = isRunning
      context.isLatest = isLatest
      context.activity = key.activity
      context.runs = key.runs
      isQueuedBehind = isRunning && turn.prompt != nil

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
      showsActivity = showsActivity || built.showsActivity
    }

    context.isRunning = true
    context.activity = nil
    context.runs = []

    // Stream events can outrun the frame that opens their turn.
    if !streamed, input.isLive, !input.streaming.isEmpty {
      elements += blocks(entries(turnId: "tail", items: [], streaming: input.streaming, context: context), tasks: [], context: context).elements
    }

    let activity = showsActivity ? nil : input.activity.map { TranscriptElement(id: "activity", kind: .activity(text: $0.text, since: $0.since)) }

    if let activity, isQueuedBehind { elements.append(activity) }

    for prompt in input.sent { elements.append(TranscriptElement(id: "sent/\(prompt.uuid)", kind: .prompt(prompt.text), spacing: 22)) }

    if let activity, !isQueuedBehind { elements.append(activity) }

    // A subagent's request has no row on the main thread, so its card goes last.
    for request in input.pending where !placed.contains(request.requestId) {
      elements.append(TranscriptElement(id: "permission/\(request.requestId)", kind: .permission(requestId: request.requestId)))
    }

    if !elements.isEmpty { elements[0].spacing = 0 }

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

    if let run = ShellRun(prompt: turn.prompt?.text) {
      if !key.isAttached { built.elements.append(TranscriptElement(id: "\(turn.id)/shell", kind: .shell(command: run.command, output: run.output), turn: turn.id, spacing: 22)) }

      return built
    }

    if let prompt = turn.prompt?.text, !prompt.allSatisfy(\.isWhitespace) {
      built.elements.append(TranscriptElement(id: "\(turn.id)/prompt", kind: promptKind(prompt, origin: turn.origin), spacing: 22))
    }

    var body = blocks(entries(turnId: String(turn.id), items: turn.items, streaming: streaming, context: context), tasks: key.tasks, context: context)

    // The desktop app leaves more room under a prompt than between a turn's own blocks.
    if !built.elements.isEmpty, !body.elements.isEmpty { body.elements[0].spacing = 34 }

    built.elements += body.elements
    built.placed = body.placed
    built.agentIds = body.agentIds
    built.openCallIds = body.openCallIds
    built.showsActivity = body.showsActivity

    let wrapUp = turn.items.reversed().lazy.compactMap { item -> ToolCall? in
      guard case .toolCall(let callId) = item.content else { return nil }
      return context.transcript.toolCall(callId).flatMap { wrapUpToolNames.contains($0.name) ? $0 : nil }
    }.first

    if let wrapUp, context.isLatest { built.elements.append(TranscriptElement(id: "\(turn.id)/next", kind: .nextStep(NextStep(input: wrapUp.input)))) }

    if turn.status != .running, let footer = footer(for: turn, in: context.transcript) {
      let replies = turn.items.compactMap { item -> String? in
        guard case .text(let text) = item.content, !text.allSatisfy(\.isWhitespace) else { return nil }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
      }

      built.elements.append(TranscriptElement(id: "\(turn.id)/footer", kind: .footer(TurnFooter(text: footer, replies: replies.joined(separator: "\n\n")))))
    }

    for index in built.elements.indices { built.elements[index].turn = turn.id }

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
        if let call = context.transcript.toolCall(callId), !unshownToolNames.contains(call.name) { entries.append(.tool(id: callId, name: call.name, input: call.input, call: call)) }
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
        if isVerbose, !text.allSatisfy(\.isWhitespace) { entries.append(.thought(id: id, text: text)) }
      case .toolUse(let callId, let name, let partialInput):
        guard !unshownToolNames.contains(name) else { break }

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

      if folds(entries[index], context: context) {
        while end < entries.count, folds(entries[end], context: context) { end += 1 }
      }

      let run = Array(entries[index..<end])
      // While the turn runs, its last calls fold under what it is doing, as the desktop app shows them.
      let live = context.isRunning && end == entries.count && folds(run[0], context: context) ? context.activity : nil

      if run.count > 1 || live != nil {
        group(run, live: live, into: &built, context: context)
        built.showsActivity = live != nil
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

  /// A tool call folds into a group unless it waits on a permission card, which shows under its own row.
  private func folds(_ entry: Entry, context: Context) -> Bool {
    guard case .tool(let id, _, _, _) = entry else { return false }

    return !context.pending.contains { $0.toolUseId == id }
  }

  private func single(_ entry: Entry, into built: inout BuiltTurn, context: Context) {
    switch entry {
    case .reply(let id, let text):
      var rest = text[...]
      var pieces = 0

      // A reply splits after each code block a command was run from, with the command's output between the halves.
      for block in fencedBlocks(text) {
        guard let run = context.runs.last(where: { $0.command == block.code }) else { continue }

        let piece = text[rest.startIndex..<block.end].trimmingCharacters(in: .whitespacesAndNewlines)

        if !piece.isEmpty { built.elements.append(TranscriptElement(id: pieces == 0 ? id : "\(id)/\(pieces)", kind: .reply(piece))) }

        built.elements.append(TranscriptElement(id: "\(id)/run\(pieces)", kind: .shell(command: nil, output: run.output), spacing: 6))
        rest = text[block.end...]
        pieces += 1
      }

      let piece = rest.trimmingCharacters(in: .whitespacesAndNewlines)

      if !piece.isEmpty { built.elements.append(TranscriptElement(id: pieces == 0 ? id : "\(id)/\(pieces)", kind: .reply(piece))) }
    case .thought(let id, let text):
      built.elements.append(TranscriptElement(id: id, kind: .thought(text.trimmingCharacters(in: .whitespacesAndNewlines))))
    case .prompt(let id, let text, let origin):
      built.elements.append(TranscriptElement(id: id, kind: promptKind(text, origin: origin)))
    case .tool(let id, let name, let input, let call):
      var row = row(id: id, name: name, input: input, call: call, context: context)

      // A finished command on its own with no description reads as a summary; its text is in the tooltip and the detail.
      if name == "Bash", row.verb == toolPhrase(for: name).past, !row.target.isEmpty {
        row.verb = "Ran a command"
        row.target = ""
      }

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

  /// A run of calls as one summary sentence, "Ran 4 commands, edited a file, 1 failed", or as the `live` activity while the turn runs.
  private func group(_ run: [Entry], live: Activity?, into built: inout BuiltTurn, context: Context) {
    var rows: [(row: ToolRow, detail: [DetailBlock])] = []
    var calls: [(name: String, target: String)] = []

    for case .tool(let id, let name, let input, let call) in run {
      let row = row(id: id, name: name, input: input, call: call, context: context)
      rows.append((row, row.isExpanded ? detail(id: id, name: name, input: input, call: call, context: context) : []))
      // A Write that replaced a file counts as an edit.
      calls += (isUpdate(name, call: call) ? ["Edit"] : phraseNames(name, input: input)).map { ($0, row.target) }

      if context.agents[id] != nil { built.agentIds.append(id) }

      if call?.result == nil { built.openCallIds.append(id) }
    }

    let id = "group/\(rows[0].row.id)"
    let isExpanded = isVerbose || expanded.contains(id)
    let failed = rows.count { $0.row.state == .failed }
    var summary = toolSummary(calls)

    if failed > 0 { summary.append(SummaryPart(text: ", \(failed) failed")) }

    let header = GroupRow(id: id, summary: summary, added: rows.reduce(0) { $0 + $1.row.added }, removed: rows.reduce(0) { $0 + $1.row.removed }, isExpanded: isExpanded, activity: live, thumbnails: Array(rows.flatMap(\.row.thumbnails).prefix(4)))
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
    let names = phraseNames(name, input: input)
    let phrase = toolPhrase(for: names.count == 1 ? names[0] : name)
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

    if row.state == .completed, isUpdate(name, call: call) { row.verb = "Updated" }

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

    // A command reads as its description, in the row's tense.
    // A command that failed keeps its description as written, as the desktop app shows it.
    if name == "Bash", let description = input["description"]?.string, !description.isEmpty, row.verb == phrase.past || row.verb == phrase.present {
      row.verb = row.state == .failed ? description : conjugated(description, isRunning: row.verb == phrase.present)
      row.target = ""
    }

    // A browser batch reads as the actions in it.
    if names.count > 1 {
      row.verb = toolSummary(names.map { ($0, "") }).map(\.text).joined()
      row.target = ""
    }

    row.note = notes.joined(separator: " \u{B7} ")
    row.tooltip = tips.joined(separator: "\n")
    row.added = call?.lineDelta?.added ?? 0
    row.removed = call?.lineDelta?.removed ?? 0
    row.thumbnails = (call?.result ?? []).enumerated().compactMap { index, block in
      guard case .image(.base64(let data, _)) = block else { return nil }

      return Thumbnail(id: "\(id)/\(index)", data: data)
    }
    return row
  }

  /// A Write whose file already existed, which the CLI reports as an update.
  private func isUpdate(_ name: String, call: ToolCall?) -> Bool {
    name == "Write" && call?.output?["type"]?.string == "update"
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

    let patch = call.isError ? [] : patchLines(call.output) ?? []

    if !patch.isEmpty {
      let shown = capped(patch, id: id)
      blocks.append(.diff(shown.lines, file: toolPath(name, input: input).map { URL(filePath: $0).lastPathComponent }))
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

/// A reply's fenced code blocks: each block's code, trimmed, and where its closing fence line ends.
func fencedBlocks(_ text: String) -> [(code: String, end: String.Index)] {
  var blocks: [(code: String, end: String.Index)] = []
  var fence: Substring?
  var lines: [Substring] = []
  var start = text.startIndex

  while start < text.endIndex {
    let end = text[start...].firstIndex(of: "\n") ?? text.endIndex
    let line = text[start..<end]
    let trimmed = line.drop { $0 == " " }
    let marker = trimmed.prefix { $0 == "`" || $0 == "~" }

    if let open = fence {
      if marker.count >= open.count, marker.first == open.first, trimmed.dropFirst(marker.count).allSatisfy(\.isWhitespace) {
        blocks.append((lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), end))
        fence = nil
      } else {
        lines.append(line)
      }
    } else if marker.count >= 3, Set(marker).count == 1 {
      fence = marker
      lines = []
    }

    start = end < text.endIndex ? text.index(after: end) : end
  }

  return blocks
}
