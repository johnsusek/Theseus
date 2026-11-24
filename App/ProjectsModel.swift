import ClaudeEngine
import ClaudeWorkspace
import Foundation

/// A session's state in the Projects window, in the order its status sort runs: what needs you first, what is closed last.
enum RowStatus: Int, CaseIterable {
  case waiting, failed, running, finished, closed

  var title: String { ["Needs Input", "Failed", "Running", "Finished", "Closed"][rawValue] }
  var symbol: String { ["exclamationmark.triangle", "xmark.circle", "circle.dotted", "checkmark.circle", "moon.zzz"][rawValue] }
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

  /// Closed without a process; finished once a process is up and idle; failed when the last turn failed or the process died.
  var rowStatus: RowStatus {
    guard let live else { return transcript.turns.last?.status == .failed ? .failed : .closed }

    if live.isRunning, request != nil || live.state == .requiresAction { return .waiting }

    if live.exit.map({ $0.failure != nil || ($0.code ?? 0) != 0 }) == true || transcript.turns.last?.status == .failed { return .failed }

    if live.isRunning, live.state == .running { return .running }

    return live.isRunning ? .finished : .closed
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

/// What the Projects window shows: the status filter, the search field, Show Archived Sessions and the column sort.
struct ProjectsQuery {
  var filter: RowStatus?
  var showsArchived = false
  var search = ""
  var sortOrder = [NSSortDescriptor(key: "status", ascending: true), NSSortDescriptor(key: "updated", ascending: false)]

  var isFiltered: Bool { filter != nil || !search.isEmpty }

  /// A conversation that has written nothing and run no turn is an empty tab still starting, so it stays out of the list.
  @MainActor
  func shows(_ session: Session) -> Bool {
    guard session.transcriptFile != nil || !session.transcript.turns.isEmpty else { return false }

    guard showsArchived || !session.isArchived else { return false }

    guard filter == nil || session.rowStatus == filter else { return false }

    return search.isEmpty || session.rowTitle.localizedCaseInsensitiveContains(search) || session.project?.name.localizedCaseInsensitiveContains(search) == true
  }

  /// Pinned sessions on top, then each project's other sessions. A project with nothing shown keeps its row until a filter or a search hides it.
  @MainActor
  func groups(_ projects: [Project]) -> [SessionGroup] {
    let shown = projects.flatMap(\.sessions).filter(shows)
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
