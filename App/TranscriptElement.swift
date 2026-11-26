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
  /// A background agent's row has nothing to open: its report comes back as a message of its own.
  var opens = true
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
  var summary: String
  /// The file a summary names at its end, "read quit-s.png", drawn as a row's target rather than gray.
  var file = ""
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
    /// A thinking block's text, which reads as prose like a reply.
    case thought(String)
    /// What the running turn is doing, and when it started.
    case activity(text: String, since: Date)
    case tool(ToolRow)
    case group(GroupRow)
    case detail([DetailBlock])
    /// A command the user ran, or only its output when it sits under the reply's code block it came from.
    case shell(command: String?, output: String)
    /// AskUserQuestion's questions with the answers picked, in a bordered box.
    case question([AnsweredQuestion])
    /// An image SendUserFile showed the user, drawn large.
    case image(SentImage)
    /// ReportFindings' findings in a bordered card.
    case review(ReviewCard)
    /// An earlier turn's next-step question, which opens to show its recap.
    case ask(String, isExpanded: Bool)
    case tasks([PlanStep])
    /// A gray line under the transcript, "2 subagents working", while agents run on after their turn.
    case status(String)
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

/// A row of the task list card: a step of the desktop app's `update_plan` list, or a task from the CLI's task list.
struct PlanStep: Equatable {
  enum State: Equatable {
    /// `waiting` is a step whose turn ended while agents it started still run.
    case done, running, waiting, pending
  }

  var title: String
  var state: State
  /// "2 subagents working" under a waiting step.
  var note: String?
}

struct AnsweredQuestion: Equatable {
  var question: String
  var answer: String?
}

/// A file SendUserFile showed the user, by its path.
struct SentImage: Equatable {
  var id: String
  var path: String
}

/// A code review's findings: "High effort, 6 findings", then each finding, grouped by file in the order the files first come up.
struct ReviewCard: Equatable {
  var heading: String
  var findings: [ReviewFinding]
}

struct ReviewFinding: Equatable {
  var id: String
  var file: String
  var title: String
  /// The finding in full, which shows while it is open.
  var detail: String
  var severity: String?
  /// What was done about it, from this report or a later one: `fixed`, `skipped` or `no_change_needed`.
  var outcome: String?
  var isExpanded = false
}

/// Under a finished turn, shown while the pointer is over the turn: "2:14 PM · 1m 52s", and the turn's replies for its Copy button.
struct TurnFooter: Equatable {
  var text: String
  var replies: String
}

/// The model's `wrap_up` call, which the transcript draws as a card under its turn instead of a tool row.
let wrapUpToolName = "mcp__theseus__wrap_up"

/// The desktop app's own turn tools, in sessions it ran: its `wrap_up` reads as a card like Theseus's, and its task list call has no row.
/// An earlier turn's `wrap_up` leaves its question as a row.
private let wrapUpToolNames: Set = [wrapUpToolName, "mcp__ccd_turn__wrap_up"]
private let planToolName = "mcp__ccd_turn__update_plan"
private let unshownToolNames = wrapUpToolNames.union([planToolName])

/// The last turn's recap, with a question and reply buttons. It goes away once anything is sent, as the desktop app's does.
struct NextStep: Equatable {
  var recap: String
  var ask: String?
  var actions: [String]

  init(input: JSONValue) {
    recap = input["recap"]?.string ?? ""
    ask = input["ask"]?.string.flatMap { $0.allSatisfy(\.isWhitespace) ? nil : $0 }
    // The desktop app's actions are objects with a label, or with one of its own actions, which a button sends by name.
    // Archiving and starting a session are not replies, so they get no button.
    actions = Array((input["actions"]?.array ?? []).compactMap { $0.string ?? $0["label"]?.string ?? $0["action"]?.string.flatMap { appActions[$0] } }.prefix(2))
  }
}

/// The desktop app's `wrap_up` actions that a reply can carry out, by the label its buttons show.
private let appActions = ["commit": "Commit changes", "create_pr": "Create PR", "merge": "Merge PR", "fix_ci": "Fix CI", "address_comments": "Address comments", "resolve_conflicts": "Resolve conflicts", "verify": "Verify"]

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
  /// A verbose transcript expands every row.
  var isVerbose = false { didSet { cache = [:] } }
  /// Rows and groups the user opened.
  var expanded: Set<String> = [] { didSet { cache = [:] } }
  /// Tool calls whose capped output is shown in full.
  var unfolded: Set<String> = [] { didSet { cache = [:] } }
  /// Next-step cards the user closed, which show as an earlier turn's question row.
  var dismissed: Set<String> = [] { didSet { cache = [:] } }
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
    /// The task list card the turn ends with, only ever on the last turn.
    var tasks: [PlanStep]
    var pending: [PendingRequest]
    /// A footer names the day unless it is today.
    var today: Date
    var activity: Activity?
    /// Commands run from this turn's code blocks, shown under them.
    var runs: [ShellRun]
    /// The turn opens with a command shown under an earlier turn's code block, so it shows no prompt.
    var isAttached: Bool
    /// The next turn is a command run from this turn's code block, which answers its next-step question.
    var isFollowedByRun: Bool
    /// The next turn shows no prompt, so it reads as more of this one, and this one leaves the footer to it.
    var continuesInNext: Bool
    var outcomes: [String: String]
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
    /// An answered AskUserQuestion.
    case question(id: String, call: ToolCall)
    /// A finished SendUserFile.
    case sentFile(id: String, call: ToolCall)
    /// A finished ReportFindings.
    case review(id: String, call: ToolCall)
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
    /// What later reports said was done about findings, by `findingKey`.
    var outcomes: [String: String] = [:]
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

    // A report of what was done about a review's findings also marks them in the review's own card.
    for call in context.transcript.toolCalls where call.name == "ReportFindings" {
      for finding in call.input["findings"]?.array ?? [] {
        if let outcome = finding["outcome"]?.string { context.outcomes[findingKey(finding)] = outcome }
      }
    }

    // A command run from a code block goes under that block in the turn before it, as the desktop app shows it.
    for turn in turns {
      guard let run = ShellRun(prompt: turn.prompt?.text) else {
        replied = turn
        continue
      }

      // Claude can carry on after the command, and its reply can hold the next command.
      defer { if !turn.items.isEmpty { replied = turn } }

      let hasBlock = replied?.items.contains { item in
        guard case .text(let text) = item.content else { return false }

        return fencedBlocks(text).contains { $0.code == run.command }
      }

      guard let replied, hasBlock == true else { continue }

      runs[replied.id, default: []].append(run)
      attached.insert(turn.id)
    }

    let plan = plan(input.transcript)
    let isLastRunning = input.isLive && turns.last?.status == .running
    let lastPlans = turns.last?.toolCallIds.contains { input.transcript.toolCall($0)?.name == planToolName } == true
    let card = cardSteps(plan, tasks: input.tasks, isRunning: isLastRunning, hasPlanned: lastPlans, agents: context.agents)

    for (index, turn) in turns.enumerated() {
      let isRunning = index == turns.count - 1 && isLastRunning
      let isLatest = index == turns.count - 1 && !isRunning && input.sent.isEmpty
      let next = index + 1 < turns.count ? turns[index + 1] : nil
      let isFollowedByRun = next.map { attached.contains($0.id) } ?? false
      // A subagent's hand-back reads as more of the turn before it too.
      let continuesInNext = isFollowedByRun || next?.origin == "task_notification" || (next?.origin == "peer" && next?.prompt?.text.contains("[Subagent hand-back]") == true)
      let key = TurnKey(range: turn.messageRange, lastItemId: turn.items.last?.id, status: turn.status, isRunning: isRunning, isLatest: isLatest, tasks: index == turns.count - 1 ? card : [], pending: input.pending, today: today, activity: isRunning ? input.activity : nil, runs: runs[turn.id] ?? [], isAttached: attached.contains(turn.id), isFollowedByRun: isFollowedByRun, continuesInNext: continuesInNext, outcomes: context.outcomes)
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

    // Agents still running after their turn, other than those the task list card counts under its step.
    let shownInCard = card.contains { $0.state == .waiting }
    let working = isLastRunning || !input.isLive ? 0 : context.agents.values.count { task in
      task.kind == .agent && task.parentId == nil && task.status.isActive && !(shownInCard && plan.agentSteps[task.id] == plan.steps.firstIndex { $0.status == .inProgress })
    }

    if working > 0 { elements.append(TranscriptElement(id: "working", kind: .status(subagentsWorking(working)), spacing: 30)) }

    // A subagent's request has no row on the main thread, so its card goes last.
    for request in input.pending where !placed.contains(request.requestId) {
      elements.append(TranscriptElement(id: "permission/\(request.requestId)", kind: .permission(requestId: request.requestId)))
    }

    if !elements.isEmpty { elements[0].spacing = 0 }

    return elements
  }

  private struct Plan {
    var steps: [(title: String, status: TaskItem.Status)] = []
    /// The step that was in progress when each Agent call was made, by the call's id.
    var agentSteps: [String: Int] = [:]
  }

  /// The desktop app's task list as the session's `update_plan` calls left it.
  private func plan(_ transcript: Transcript) -> Plan {
    var plan = Plan()

    for turn in transcript.turns {
      for case .toolCall(let id) in turn.items.map(\.content) {
        guard let call = transcript.toolCall(id) else { continue }

        if call.name == "Agent" || call.name == "Task" { plan.agentSteps[id] = plan.steps.firstIndex { $0.status == .inProgress } }

        guard call.name == planToolName, !call.isError else { continue }

        let input = call.input

        // A new list starts over, so agents started under the old one belong to none of its steps.
        if let items = input["items"]?.array {
          plan.steps = items.map { (title: $0["content"]?.string ?? "", status: $0["status"]?.string.flatMap(TaskItem.Status.init) ?? .pending) }
          plan.agentSteps = [:]
        }

        if input["advance"]?.bool == true {
          if let current = plan.steps.firstIndex(where: { $0.status == .inProgress }) { plan.steps[current].status = .completed }

          if let next = plan.steps.firstIndex(where: { $0.status == .pending }) { plan.steps[next].status = .inProgress }
        }

        for number in (input["done"]?.array ?? []).compactMap(\.int) where plan.steps.indices.contains(number - 1) { plan.steps[number - 1].status = .completed }

        if let number = input["start"]?.int, plan.steps.indices.contains(number - 1) { plan.steps[number - 1].status = .inProgress }
      }
    }

    return plan
  }

  /// The card the last turn ends with: the plan while the turn runs and a step is left, or, once a turn that changed the plan ends,
  /// the plan while agents its current step started still run. Without a plan, the CLI's task list while the turn runs.
  private func cardSteps(_ plan: Plan, tasks: [TaskItem], isRunning: Bool, hasPlanned: Bool, agents: [String: ClaudeTask]) -> [PlanStep] {
    let state: (TaskItem.Status) -> PlanStep.State = { $0 == .completed ? .done : $0 == .inProgress ? .running : .pending }

    guard !plan.steps.isEmpty else { return isRunning ? tasks.map { PlanStep(title: $0.status == .inProgress ? $0.activeForm ?? $0.subject : $0.subject, state: state($0.status)) } : [] }

    var steps = plan.steps.map { PlanStep(title: $0.title, state: state($0.status)) }

    if isRunning { return steps.contains { $0.state != .done } ? steps : [] }

    guard hasPlanned, let current = plan.steps.firstIndex(where: { $0.status == .inProgress }) else { return [] }

    let working = plan.agentSteps.count { $0.value == current && agents[$0.key]?.status.isActive == true }
    guard working > 0 else { return [] }

    steps[current].state = .waiting
    steps[current].note = subagentsWorking(working)
    return steps
  }

  private func subagentsWorking(_ count: Int) -> String { count == 1 ? "1 subagent working" : "\(count) subagents working" }

  private func agentState(_ task: ClaudeTask?) -> AgentState? {
    task.map { AgentState(status: $0.status, usage: $0.usage, summary: $0.summary) }
  }

  /// Whether what a kept turn showed of its agents and unanswered calls still holds. Neither changes the turn's own frames.
  private func isCurrent(_ cached: CachedTurn, context: Context) -> Bool {
    cached.built.agentIds.map { agentState(context.agents[$0]) } == cached.agents && cached.built.openCallIds.allSatisfy { context.transcript.toolCall($0)?.result == nil }
  }

  private func build(_ turn: Turn, key: TurnKey, streaming: [StreamingMessage.Block], context: Context) -> BuiltTurn {
    var built = BuiltTurn()
    // A subagent's message that opens the turn folds with the turn's first calls.
    var leading: [Entry] = []

    if let run = ShellRun(prompt: turn.prompt?.text) {
      if !key.isAttached { built.elements.append(TranscriptElement(id: "\(turn.id)/shell", kind: .shell(command: run.command, output: run.output), spacing: 22)) }
    } else if let prompt = turn.prompt?.text, message(id: "", text: prompt, context: context) != nil {
      leading = [.prompt(id: "\(turn.id)/prompt", text: prompt, origin: turn.origin)]
    } else if let prompt = turn.prompt?.text, !prompt.allSatisfy(\.isWhitespace), let kind = promptKind(prompt, origin: turn.origin) {
      built.elements.append(TranscriptElement(id: "\(turn.id)/prompt", kind: kind, spacing: 22))
    }

    var body = blocks(leading + entries(turnId: String(turn.id), items: turn.items, streaming: streaming, context: context), tasks: key.tasks, context: context)

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

    let step = wrapUp.map { NextStep(input: $0.input) }
    // The desktop app draws no box for a recap that leaves the user nothing to answer; its closing message says the rest.
    let hasCard = wrapUp?.name == wrapUpToolName || step?.ask != nil || step?.actions.isEmpty == false

    if let wrapUp, context.isLatest, hasCard, !dismissed.contains("\(turn.id)/next") {
      built.elements.append(TranscriptElement(id: "\(turn.id)/next", kind: .nextStep(NextStep(input: wrapUp.input))))
    } else if let wrapUp, !key.isFollowedByRun, let ask = NextStep(input: wrapUp.input).ask {
      let id = "\(turn.id)/ask"
      let isExpanded = expanded.contains(id)
      let recap = NextStep(input: wrapUp.input).recap
      built.elements.append(TranscriptElement(id: id, kind: .ask(ask, isExpanded: isExpanded), spacing: 30))

      if isExpanded, !recap.isEmpty { built.elements.append(TranscriptElement(id: "\(id)/detail", kind: .detail([.report(recap)]), spacing: 8)) }
    }

    if turn.status != .running, !key.continuesInNext, let footer = footer(for: turn, in: context.transcript) {
      let replies = turn.items.compactMap { item -> String? in
        guard case .text(let text) = item.content, !text.allSatisfy(\.isWhitespace) else { return nil }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
      }

      built.elements.append(TranscriptElement(id: "\(turn.id)/footer", kind: .footer(TurnFooter(text: footer, replies: replies.joined(separator: "\n\n")))))
    }

    for index in built.elements.indices { built.elements[index].turn = turn.id }

    return built
  }

  /// A subagent's report, handed back as a prompt of its own, or its notice that it finished, as a row that folds with the calls around it.
  /// The hand-back reads "Message from subagent" and the agent's description, and opens to the report.
  /// The notice reads "Background subagent completed · Seed transcripts · took 4m 1s".
  private func message(id: String, text: String, context: Context) -> (row: ToolRow, detail: [DetailBlock], name: String)? {
    if let match = text.firstMatch(of: /<agent-message from="([^"]*)">([\s\S]*?)<\/agent-message>/), match.2.contains("[Subagent hand-back]") {
      let agentId = String(match.1)
      let task = context.agents.values.first { $0.taskId == agentId }
      let row = ToolRow(id: id, verb: "Message from subagent", target: task?.description ?? "", isExpanded: isVerbose || expanded.contains(id))
      return (row, [.report(agentReport(String(match.2)))], "SubagentMessage")
    }

    guard text.contains("<task-notification>"), let summary = text.firstMatch(of: /<summary>Agent "([\s\S]*)" finished<\/summary>/) else { return nil }

    let took = text.firstMatch(of: /<duration_ms>(\d+)<\/duration_ms>/).flatMap { Int($0.1) }.map { "took " + durationText(.milliseconds($0)) }
    var row = ToolRow(id: id, verb: ["Background subagent completed", String(summary.1), took].compactMap { $0 }.joined(separator: " \u{B7} "), target: "")
    row.opens = false
    return (row, [], "SubagentFinished")
  }

  /// Nil for a task notification, which the desktop app does not show.
  private func promptKind(_ prompt: String, origin: String?) -> TranscriptElement.Kind? {
    guard origin != "task_notification" else { return nil }

    let symbols = ["scheduled": "clock", "peer": "arrow.left.arrow.right"]
    guard let symbol = origin.flatMap({ symbols[$0] }) else { return .prompt(prompt.trimmingCharacters(in: .whitespacesAndNewlines)) }

    var line = prompt

    // A notice wraps its one-line summary in tags.
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
        if !text.allSatisfy(\.isWhitespace) { entries.append(.thought(id: id, text: text)) }
      case .toolCall(let callId):
        guard let call = context.transcript.toolCall(callId), !unshownToolNames.contains(call.name) else { break }

        if call.name == "AskUserQuestion", call.status == .completed {
          entries.append(.question(id: callId, call: call))
        } else if call.name == "SendUserFile", call.status == .completed {
          entries.append(.sentFile(id: callId, call: call))
        } else if call.name == "ReportFindings", call.status == .completed {
          entries.append(.review(id: callId, call: call))
        } else {
          entries.append(.tool(id: callId, name: call.name, input: call.input, call: call))
        }
      case .prompt(let blocks, let origin):
        // Of the task notices only a subagent's finishing shows; the others would split the calls around them.
        guard !blocks.text.allSatisfy(\.isWhitespace), origin != "task_notification" || message(id: id, text: blocks.text, context: context) != nil else { break }

        entries.append(.prompt(id: id, text: blocks.text, origin: origin))
      }
    }

    for (index, block) in streaming.enumerated() {
      let id = "\(turnId)/\(items.count + index)"

      switch block {
      case .text(let text):
        if !text.allSatisfy(\.isWhitespace) { entries.append(.reply(id: id, text: text)) }
      case .thinking(let text):
        if !text.allSatisfy(\.isWhitespace) { entries.append(.thought(id: id, text: text)) }
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

  /// Folds runs of finished tool calls into groups and lays the entries out as elements, with the task list card after them.
  private func blocks(_ entries: [Entry], tasks: [PlanStep], context: Context) -> BuiltTurn {
    var built = BuiltTurn()
    var index = 0
    var followsPrompt = false
    var liveStart: Int?

    while index < entries.count {
      let start = built.elements.count
      var end = index + 1

      if folds(entries[index], context: context) {
        while end < entries.count, folds(entries[end], context: context) { end += 1 }
      }

      let run = Array(entries[index..<end])
      // Subagent messages fold only with calls; on their own each shows as its row.
      let hasCall = run.contains { if case .tool = $0 { true } else { false } }
      // While the turn runs, its last calls fold under what it is doing, as the desktop app shows them.
      let live = context.isRunning && end == entries.count && hasCall ? context.activity : nil

      if hasCall, run.count > 1 || live != nil {
        if live != nil { liveStart = built.elements.count }

        group(run, live: live, into: &built, context: context)
        built.showsActivity = live != nil
      } else {
        for entry in run { single(entry, into: &built, context: context) }
      }

      // A prompt taken mid-turn gets the room a turn's own prompt does.
      if followsPrompt, start < built.elements.count { built.elements[start].spacing = 34 }

      if case .prompt = run[0], start < built.elements.count, case .prompt = built.elements[start].kind { followsPrompt = true } else { followsPrompt = false }

      index = end
    }

    // The task list follows what the turn has shown so far, above what it is doing now.
    if !tasks.isEmpty { built.elements.insert(TranscriptElement(id: "tasks", kind: .tasks(tasks)), at: liveStart ?? built.elements.count) }

    return built
  }

  /// A tool call folds into a group unless it waits on a permission card, which shows under its own row. So does a subagent's message.
  private func folds(_ entry: Entry, context: Context) -> Bool {
    if case .prompt(let id, let text, _) = entry { return message(id: id, text: text, context: context) != nil }

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
      if let message = message(id: id, text: text, context: context) {
        built.elements.append(TranscriptElement(id: id, kind: .tool(message.row)))

        if message.row.isExpanded { built.elements.append(TranscriptElement(id: "\(id)/detail", kind: .detail(message.detail), spacing: 8)) }

        return
      }

      guard let kind = promptKind(text, origin: origin) else { break }

      var isBubble = false

      if case .prompt = kind { isBubble = true }

      built.elements.append(TranscriptElement(id: id, kind: kind, spacing: isBubble ? 22 : 18))
    case .question(let id, let call):
      question(id: id, call: call, into: &built, context: context)
    case .review(let id, let call):
      review(id: id, call: call, into: &built, context: context)
    case .sentFile(let id, let call):
      if let caption = call.input["caption"]?.string, !caption.allSatisfy(\.isWhitespace) { built.elements.append(TranscriptElement(id: "\(id)/caption", kind: .reply(caption))) }

      for (index, path) in (call.input["files"]?.array ?? []).compactMap(\.string).enumerated() {
        if imageExtensions.contains(URL(filePath: path).pathExtension.lowercased()) {
          built.elements.append(TranscriptElement(id: "\(id)/\(index)", kind: .image(SentImage(id: "\(id)/\(index)", path: path)), spacing: 8))
        } else {
          var row = row(id: "\(id)/\(index)", name: "SendUserFile", input: call.input, call: call, context: context)
          row.verb = "Sent"
          row.target = URL(filePath: path).lastPathComponent
          row.copy = CopySource(title: "Copy Path", text: path)
          row.tooltip = path
          built.elements.append(TranscriptElement(id: row.id, kind: .tool(row)))
        }
      }
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

    for entry in run {
      if case .prompt(let id, let text, _) = entry, let message = message(id: id, text: text, context: context) {
        rows.append((message.row, message.row.isExpanded ? message.detail : []))
        calls.append((message.name, ""))
      }

      guard case .tool(let id, let name, let input, let call) = entry else { continue }

      let row = row(id: id, name: name, input: input, call: call, context: context)
      rows.append((row, row.isExpanded ? detail(id: id, name: name, input: input, call: call, context: context) : []))
      // A Write that replaced a file counts as an edit.
      calls += (isUpdate(name, call: call) ? ["Edit"] : phraseNames(name, input: input)).map { ($0, toolPath(name, input: input) ?? row.target) }

      if context.agents[id] != nil { built.agentIds.append(id) }

      if call?.result == nil { built.openCallIds.append(id) }
    }

    let id = "group/\(rows[0].row.id)"
    let isExpanded = isVerbose || expanded.contains(id)
    let failed = rows.count { $0.row.state == .failed }
    var summary = toolSummary(calls)

    if failed > 0 { summary += ", \(failed) failed" }

    let reads = Set(calls.filter { $0.name == "Read" }.map { ($0.target as NSString).lastPathComponent })
    let file = reads.count == 1 && summary.hasSuffix("read \(reads.first!)") ? reads.first! : ""
    let header = GroupRow(id: id, summary: summary, file: file, added: rows.reduce(0) { $0 + $1.row.added }, removed: rows.reduce(0) { $0 + $1.row.removed }, isExpanded: isExpanded, activity: live, thumbnails: Array(rows.flatMap(\.row.thumbnails).prefix(4)))
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

  /// The questions with the answers picked, or one row when the user answered in the chat instead.
  private func question(id: String, call: ToolCall, into built: inout BuiltTurn, context: Context) {
    let answers = call.output?["answers"]?.object ?? [:]
    let questions = (call.input["questions"]?.array ?? []).map { item in
      let text = item["question"]?.string ?? ""
      return (text: text, header: item["header"]?.string ?? text, answer: answers[text]?.string)
    }

    // The CLI fills in this answer for a question the user skipped by sending a message.
    if questions.contains(where: { $0.answer?.hasPrefix("[User did not answer") == true }) {
      var row = row(id: id, name: call.name, input: call.input, call: call, context: context)
      row.verb = "Asked " + questions.map { "\u{201C}\($0.header)\u{201D}" }.joined(separator: ", ")
      row.target = ""
      row.note = "Replied in chat"
      built.elements.append(TranscriptElement(id: id, kind: .tool(row)))

      if row.isExpanded { built.elements.append(TranscriptElement(id: "\(id)/detail", kind: .detail([.report(questions.map(\.text).joined(separator: "\n\n"))]), spacing: 8)) }

      return
    }

    built.elements.append(TranscriptElement(id: id, kind: .question(questions.map { AnsweredQuestion(question: $0.text, answer: $0.answer) }), box: BoxSlot(isFirst: true, isLast: true)))
  }

  /// A review's findings in a card. A report of what was done about them is one row, "Code review 1 fixed, 5 skipped", that opens to its card.
  private func review(id: String, call: ToolCall, into built: inout BuiltTurn, context: Context) {
    let items = call.input["findings"]?.array ?? []
    let level = call.input["level"]?.string.map { ($0 == "xhigh" ? "Extra high" : $0.capitalized) + " effort" }
    let total = items.count == 1 ? "1 finding" : "\(items.count) findings"
    let findings = items.enumerated().map { index, item in
      let findingId = "\(id)/\(index)"
      let title = item["short_summary"]?.string ?? oneLine(item["summary"]?.string ?? "", limit: 80)
      let detail = [item["summary"]?.string, item["failure_scenario"]?.string].compactMap { $0 }.joined(separator: "\n\n")
      return ReviewFinding(id: findingId, file: ((item["file"]?.string ?? "") as NSString).lastPathComponent, title: title, detail: detail, severity: item["severity"]?.string, outcome: item["outcome"]?.string ?? context.outcomes[findingKey(item)], isExpanded: isVerbose || expanded.contains(findingId))
    }
    let card = TranscriptElement(id: id, kind: .review(ReviewCard(heading: [level, total].compactMap { $0 }.joined(separator: ", "), findings: findings)), box: BoxSlot(isFirst: true, isLast: true))

    guard items.contains(where: { $0["outcome"] != nil }) else { return built.elements.append(card) }

    let counts = [("fixed", "fixed"), ("skipped", "skipped"), ("no_change_needed", "needed no change")].compactMap { outcome, words in
      let count = findings.count { $0.outcome == outcome }
      return count > 0 ? "\(count) \(words)" : nil
    }
    let rowId = "\(id)/outcome"
    let isExpanded = isVerbose || expanded.contains(rowId)
    built.elements.append(TranscriptElement(id: rowId, kind: .group(GroupRow(id: rowId, summary: ["Code review", counts.joined(separator: ", ")].filter { !$0.isEmpty }.joined(separator: " "), isExpanded: isExpanded))))

    if isExpanded {
      var open = card
      open.spacing = 8
      built.elements.append(open)
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
      // A question waits on an answer, not an approval, so its row reads as running.
      let isPending = name != "AskUserQuestion" && context.pending.contains { $0.toolUseId == id }
      row.state = isPending ? .waiting : context.isRunning ? .running : .stopped
    }

    if row.state == .completed, isUpdate(name, call: call) { row.verb = "Updated" }

    if let task = context.agents[id], task.isBackground {
      row.opens = false
      row.isExpanded = false
    } else if let task = context.agents[id] {
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
      row.verb = toolSummary(names.map { ($0, "") })
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
      let shown = bounded("$ " + command)
      blocks.append(.command(shown.text))
      blocks += shown.trailer
    } else if toolPhrase(for: name).past.hasPrefix("Used ") {
      // A tool without a phrase of its own says nothing about its input in the row, so the detail shows it.
      let json = readableJSON(input)

      if !json.isEmpty {
        let shown = bounded(json)
        blocks.append(.output(shown.text))
        blocks += shown.trailer
      }
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

  /// A tool's input in full, up to the most lines and line length an unfolded output shows, so a huge heredoc or argument cannot stall the render.
  private func bounded(_ text: String) -> (text: String, trailer: [DetailBlock]) {
    let lines = text.components(separatedBy: "\n")
    let shown = lines.prefix(Self.mostLines).map { $0.count > 2000 ? String($0.prefix(2000)) + "\u{2026}" : $0 }
    let trailer: [DetailBlock] = lines.count > Self.mostLines ? [.note("\((lines.count - Self.mostLines).formatted(.number.locale(locale))) more lines not shown")] : []
    return (shown.joined(separator: "\n"), trailer)
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

/// Matches a finding in a later report to the same finding in an earlier one.
private func findingKey(_ finding: JSONValue) -> String {
  "\(finding["file"]?.string ?? "")|\(finding["short_summary"]?.string ?? finding["summary"]?.string ?? "")"
}

/// Files SendUserFile shows as an image.
private let imageExtensions: Set = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]

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
