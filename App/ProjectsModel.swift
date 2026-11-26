import ClaudeEngine
import ClaudeWorkspace
import Foundation

/// A session's state in the Projects window, in the order its status sort runs: what needs you first, what is closed last.
enum RowStatus: Int, CaseIterable {
  case waiting, failed, running, finished, closed

  var title: String { ["Needs Input", "Failed", "Running", "Finished", "Closed"][rawValue] }
  var symbol: String { ["exclamationmark.triangle", "xmark.circle", "circle.dotted", "checkmark.circle", "moon.zzz"][rawValue] }
}

/// How recently a session must have been active to show: hours count back from now, days are calendar days with today as the first.
enum UpdatedRange: Int, CaseIterable {
  case anyTime, fourHours, eightHours, today, twoDays, week, month

  var title: String { ["Any Time", "Last 4 Hours", "Last 8 Hours", "Today", "Last 2 Days", "Last 7 Days", "Last 30 Days"][rawValue] }

  func start(now: Date, calendar: Calendar = .current) -> Date? {
    let today = calendar.startOfDay(for: now)

    switch self {
    case .anyTime: return nil
    case .fourHours: return now.addingTimeInterval(-4 * 3600)
    case .eightHours: return now.addingTimeInterval(-8 * 3600)
    case .today: return today
    case .twoDays: return calendar.date(byAdding: .day, value: -1, to: today)
    case .week: return calendar.date(byAdding: .day, value: -6, to: today)
    case .month: return calendar.date(byAdding: .day, value: -29, to: today)
    }
  }
}

/// What a waiting session asks for, which decides the control that answers it.
enum RequestKind {
  case permission, question, plan

  init(_ request: PermissionRequest) {
    switch request.toolName {
    case "AskUserQuestion": self = .question
    case "ExitPlanMode": self = .plan
    default: self = .permission
    }
  }
}

extension Session {
  /// The oldest request the running process waits on.
  var request: PermissionRequest? { live?.isRunning == true ? live?.pendingPermissions.first : nil }

  /// Closed without a process; finished once a process, here or in another app, is up and idle; failed when the last turn failed or the process died.
  var rowStatus: RowStatus {
    if let owner {
      if owner.status == "waiting" { return .waiting }

      return owner.isBusy ? .running : .finished
    }

    guard let live else { return transcript.turns.last?.status == .failed ? .failed : .closed }

    if live.isRunning, request != nil || live.state == .requiresAction { return .waiting }

    if live.exit.map({ $0.failure != nil || ($0.code ?? 0) != 0 }) == true || transcript.turns.last?.status == .failed { return .failed }

    if live.isRunning, live.state == .running { return .running }

    return live.isRunning ? .finished : .closed
  }

  /// The request a waiting session asks, what a running one is doing, why a failed one stopped.
  /// A session another app has open says where it waits.
  var activityText: String {
    if let request {
      if RequestKind(request) == .question { return request.questions.first?.question ?? "Asking a question" }

      return requestSummary(request, projectName: project?.name ?? "")
    }

    if let owner, owner.status == "waiting" { return "Waiting in " + ownerName(entrypoint: owner.entrypoint) }

    guard let live else { return "" }

    switch rowStatus {
    case .waiting:
      return "Waiting for approval"
    case .running:
      return activityLine(summary: live.activity, isWaiting: false, transcript: transcript)
    case .failed:
      if let failure = live.exit?.failure { return failure }

      if let code = live.exit?.code, code != 0 { return "Exited with code \(code)" }

      return "The last turn failed"
    default:
      return ""
    }
  }

  /// Answers the open permission request, as its card's buttons would with the checkbox off.
  func answerPermission(allow: Bool) {
    guard let request, RequestKind(request) == .permission else { return }

    live?.respond(to: request, with: permissionDecision(for: request, allow: allow, always: false))
  }

  /// Answers the open request's only question with one of its options.
  func answerQuestion(_ label: String) {
    guard let request, let question = request.questions.first else { return }

    live?.respond(to: request, with: .answer([question.question: label], to: request))
  }

  /// What the session is doing or asks, else the first line of how its last turn closed, as plain text.
  var detailText: String {
    let activity = activityText

    guard activity.isEmpty, let closing else { return activity }

    let line = closing.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) }.map(String.init) ?? ""
    return (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map { String($0.characters) } ?? line
  }

  /// "2 hr. ago", "Yesterday": when the session was last active.
  var lastActiveText: String {
    let relative = lastActive.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    return relative.prefix(1).capitalized + relative.dropFirst()
  }

  /// The title, else the first prompt, cut to one line.
  var rowTitle: String {
    let source = title ?? transcript.turns.lazy.compactMap { $0.prompt?.text }.first ?? ""
    let line = source.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces) ?? ""
    return line.isEmpty ? "New Conversation" : line
  }

  /// "feature · main": the worktree and the branch.
  var location: String { [worktree, gitBranch].compactMap(\.self).joined(separator: " · ") }

  var tasksDone: Int { live?.taskList.tasks.count { $0.status == .completed } ?? 0 }
  var tasksTotal: Int { live?.taskList.tasks.count ?? 0 }
  var linesAdded: Int { transcript.changedFiles.reduce(0) { $0 + $1.lineDelta.added } }
  var linesRemoved: Int { transcript.changedFiles.reduce(0) { $0 + $1.lineDelta.removed } }

  /// How full the context window is, from 0 to 1. Nil without a reading.
  var contextFraction: Double? {
    guard let usage = live?.contextUsage, usage.maxTokens > 0 else { return nil }

    return Double(usage.totalTokens) / Double(usage.maxTokens)
  }

  /// When anything last happened: the transcript's date on disk, or the newest turn of a live process.
  var lastActive: Date { max(updatedAt, transcript.turns.last?.startedAt ?? .distantPast) }
}

/// The values a column sorts by, for a session and for a group, which sorts like its most urgent session.
struct SortKeys {
  var title = ""
  var status = RowStatus.closed
  var progress = 0.0
  var changes = 0
  var context = 0.0
  var location = ""
  var updated = Date.distantPast

  @MainActor
  init(_ session: Session) {
    title = session.rowTitle
    status = session.rowStatus
    progress = session.tasksTotal == 0 ? 0 : Double(session.tasksDone) / Double(session.tasksTotal)
    changes = session.linesAdded + session.linesRemoved
    context = session.contextFraction ?? 0
    location = session.location
    updated = session.lastActive
  }

  init(group title: String, _ children: [SortKeys]) {
    self.title = title
    status = children.map(\.status).min { $0.rawValue < $1.rawValue } ?? .closed
    updated = children.map(\.updated).max() ?? .distantPast
  }

  func compare(_ other: SortKeys, by key: String) -> ComparisonResult {
    switch key {
    case "title": title.localizedStandardCompare(other.title)
    case "status": order(status.rawValue, other.status.rawValue)
    case "tasks": order(progress, other.progress)
    case "changes": order(changes, other.changes)
    case "context": order(context, other.context)
    case "location": location.localizedStandardCompare(other.location)
    default: order(updated, other.updated)
    }
  }

  private func order<Value: Comparable>(_ left: Value, _ right: Value) -> ComparisonResult {
    left < right ? .orderedAscending : left > right ? .orderedDescending : .orderedSame
  }

  /// True when `self` comes before `other` under `descriptors`, each a column's key.
  func precedes(_ other: SortKeys, by descriptors: [NSSortDescriptor]) -> Bool {
    for descriptor in descriptors {
      let result = compare(other, by: descriptor.key ?? "")

      if result != .orderedSame { return descriptor.ascending == (result == .orderedAscending) }
    }

    return false
  }
}

/// One top-level row: Pinned, or a project.
struct SessionGroup {
  /// "pinned", or the project's path.
  let id: String
  let project: Project?
  let sessions: [Session]
}

/// What the Projects window shows: the status filter (none picked shows every status), the Updated filter, the search field, Show Archived Sessions and the column sort.
struct ProjectsQuery {
  var statuses: Set<RowStatus> = []
  var updated = UpdatedRange.anyTime
  var showsArchived = false
  var search = ""
  var sortOrder = [NSSortDescriptor(key: "status", ascending: true), NSSortDescriptor(key: "updated", ascending: false)]

  var isFiltered: Bool { !statuses.isEmpty || updated != .anyTime || !search.isEmpty }

  /// Everything but the search, which starts empty each launch. Each sort key is prefixed "+" for ascending or "-" for descending.
  var saved: [String: Any] {
    ["statuses": statuses.map(\.rawValue).sorted(), "updated": updated.rawValue, "showsArchived": showsArchived, "sort": sortOrder.compactMap { descriptor in descriptor.key.map { (descriptor.ascending ? "+" : "-") + $0 } }]
  }

  init() {}

  init(saved: [String: Any]) {
    statuses = Set((saved["statuses"] as? [Int] ?? []).compactMap(RowStatus.init))
    updated = (saved["updated"] as? Int).flatMap(UpdatedRange.init) ?? .anyTime
    showsArchived = saved["showsArchived"] as? Bool ?? false

    if let sort = saved["sort"] as? [String], !sort.isEmpty {
      sortOrder = sort.map { NSSortDescriptor(key: String($0.dropFirst()), ascending: $0.hasPrefix("+")) }
    }
  }

  /// A conversation that has written nothing and run no turn is an empty tab still starting, so it stays out of the list.
  @MainActor
  func shows(_ session: Session, now: Date) -> Bool {
    guard session.transcriptFile != nil || !session.transcript.turns.isEmpty else { return false }

    guard showsArchived || !session.isArchived else { return false }

    guard statuses.isEmpty || statuses.contains(session.rowStatus) else { return false }

    if let start = updated.start(now: now), session.lastActive < start { return false }

    return search.isEmpty || session.rowTitle.localizedCaseInsensitiveContains(search) || session.project?.name.localizedCaseInsensitiveContains(search) == true
  }

  /// The sessions this query shows from `sessions`, in its sort order.
  @MainActor
  func sessions(_ sessions: [Session], now: Date = .now) -> [Session] {
    let shown = sessions.filter { shows($0, now: now) }
    let keys = Dictionary(shown.map { (ObjectIdentifier($0), SortKeys($0)) }) { first, _ in first }
    return shown.sorted { keys[ObjectIdentifier($0)]!.precedes(keys[ObjectIdentifier($1)]!, by: sortOrder) }
  }

  /// Pinned sessions on top, then each project's other sessions. A project with nothing shown keeps its row until a filter or a search hides it.
  @MainActor
  func groups(_ projects: [Project], now: Date = .now) -> [SessionGroup] {
    let shown = projects.flatMap(\.sessions).filter { shows($0, now: now) }
    let keys = Dictionary(shown.map { (ObjectIdentifier($0), SortKeys($0)) }) { first, _ in first }
    let sorted = { (sessions: [Session]) in sessions.sorted { keys[ObjectIdentifier($0)]!.precedes(keys[ObjectIdentifier($1)]!, by: sortOrder) } }
    let pinned = SessionGroup(id: "pinned", project: nil, sessions: sorted(shown.filter(\.isPinned)))

    let folders = projects.map { project in SessionGroup(id: project.path.path, project: project, sessions: sorted(shown.filter { $0.project === project && !$0.isPinned })) }
      .filter { !$0.sessions.isEmpty || !isFiltered }
      .map { group in (group, SortKeys(group: group.project?.name ?? "", group.sessions.compactMap { keys[ObjectIdentifier($0)] })) }
      .sorted { $0.1.precedes($1.1, by: sortOrder) }
      .map(\.0)

    return (pinned.sessions.isEmpty ? [] : [pinned]) + folders
  }
}

/// The start page's and the sidebar's order: waiting sessions, then running ones, then unread ones, each newest first, then the rest newest first.
/// `leading` counts the first three groups.
@MainActor
func sessionListOrder(_ sessions: [Session]) -> (sessions: [Session], leading: Int) {
  let newest = sessions.sorted { $0.lastActive > $1.lastActive }
  let waiting = newest.filter { $0.rowStatus == .waiting }
  let running = newest.filter { $0.rowStatus == .running }
  let unread = newest.filter { $0.isUnread && !$0.isArchived && $0.rowStatus != .waiting && $0.rowStatus != .running }
  let listed = Set((waiting + running + unread).map(ObjectIdentifier.init))
  let recent = newest.filter { !listed.contains(ObjectIdentifier($0)) && ProjectsQuery().shows($0, now: .now) }
  return (waiting + running + unread + recent, listed.count)
}

/// "2 waiting, 1 failed, 1 running", or empty when none of the sessions is live.
func tally(_ statuses: [RowStatus]) -> String {
  [(RowStatus.waiting, "waiting"), (.failed, "failed"), (.running, "running")].compactMap { status, word in
    let count = statuses.count { $0 == status }
    return count > 0 ? "\(count) \(word)" : nil
  }
  .joined(separator: ", ")
}

/// "Now", "12 min ago", "3:41 PM" earlier today, "Yesterday", then a short date.
func updatedText(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
  let seconds = now.timeIntervalSince(date)

  if seconds < 60 { return "Now" }

  if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }

  if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }

  if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }

  return date.formatted(date: .numeric, time: .omitted)
}

/// Sessions grouped by the calendar day they were last active. Sessions of one day must be next to each other, as a sort by date leaves them.
@MainActor
func sessionsByDay(_ sessions: [Session], calendar: Calendar = .current) -> [(day: Date, sessions: [Session])] {
  var days: [(day: Date, sessions: [Session])] = []

  for session in sessions {
    let day = calendar.startOfDay(for: session.lastActive)

    if days.last?.day == day {
      days[days.count - 1].sessions.append(session)
    } else {
      days.append((day, [session]))
    }
  }

  return days
}

/// "Today", "Yesterday", then "Monday, November 23, 2026".
func dayTitle(_ day: Date, now: Date, calendar: Calendar = .current) -> String {
  if calendar.isDate(day, inSameDayAs: now) { return "Today" }

  if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }

  return day.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
}

/// A permission request in one line for a row, which offers Allow right beside it: a command names the command,
/// and anything else says what its card's title says.
func requestSummary(_ request: PermissionRequest, projectName: String) -> String {
  let prompt = PermissionPrompt(request, projectName: projectName)
  guard request.toolName == "Bash", case .code(let command) = prompt.body, !command.isEmpty else { return prompt.title }

  let line = command.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? command
  let shown = line.count > 80 ? line.prefix(79) + "\u{2026}" : line + (command.contains("\n") ? " \u{2026}" : "")
  return "Run \u{201C}\(shown)\u{201D}?"
}
