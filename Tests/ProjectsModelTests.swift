import Foundation
import Testing
@testable import ClaudeEngine
@testable import ClaudeWorkspace

@MainActor
struct ProjectsModelTests {
  let now = Date(timeIntervalSince1970: 1_800_000_000)

  /// Projects holding sessions named by their ids, updated `minutes` ago.
  func projects(_ layout: [(String, [(id: String, minutes: Double)])]) -> [Project] {
    layout.map { name, sessions in
      let project = Project(path: URL(filePath: "/tmp/\(name)", directoryHint: .isDirectory))

      project.sessions = sessions.map { entry in
        let session = Session(id: entry.id, workingDirectory: project.path, updatedAt: now.addingTimeInterval(-entry.minutes * 60))
        session.appTitle = entry.id
        session.transcriptFile = project.path.appending(path: "\(entry.id).jsonl")
        session.project = project
        return session
      }
      return project
    }
  }

  func ids(_ groups: [SessionGroup]) -> [String] {
    groups.map { group in "\(group.project?.name ?? "Pinned"): " + group.sessions.map(\.id).joined(separator: " ") }
  }

  @Test func groupsByProjectWithPinnedOnTop() {
    let all = projects([("old", [("a", 300), ("b", 30)]), ("new", [("c", 5), ("d", 60)])])
    all[0].sessions[0].isPinned = true

    #expect(ids(ProjectsQuery().groups(all)) == ["Pinned: a", "new: c d", "old: b"])
  }

  @Test func archivedSessionsShowOnlyWhenAsked() {
    let all = projects([("app", [("a", 1), ("b", 2)]), ("lib", [("c", 3)])])
    all[0].sessions[1].isArchived = true
    all[1].sessions[0].isArchived = true
    var query = ProjectsQuery()

    // A project whose sessions are all hidden keeps its row until a filter or a search hides it.
    #expect(ids(query.groups(all)) == ["app: a", "lib: "])
    query.showsArchived = true
    #expect(ids(query.groups(all)) == ["app: a b", "lib: c"])
    query.search = "b"
    #expect(ids(query.groups(all)) == ["app: b", "lib: c"])
  }

  @Test func historyListsArchivedAndSkipsBlankSessions() {
    let all = projects([("app", [("a", 10), ("b", 5), ("c", 1)])])
    all[0].sessions[0].isArchived = true
    all[0].sessions[2].transcriptFile = nil
    var query = ProjectsQuery()
    query.showsArchived = true
    query.sortOrder = [NSSortDescriptor(key: "updated", ascending: false)]

    #expect(query.sessions(all[0].sessions, now: now).map(\.id) == ["b", "a"])
  }

  @Test func historyGroupsByDay() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    // 2027-01-15 08:00 UTC, so 3 and 6 hours ago are today and 10 hours ago is yesterday.
    let all = projects([("app", [("a", 3 * 60), ("b", 6 * 60), ("c", 10 * 60), ("d", 40 * 60)])])
    let days = sessionsByDay(all[0].sessions, calendar: calendar)

    #expect(days.map { $0.sessions.map(\.id) } == [["a", "b"], ["c"], ["d"]])
    #expect(days.map { dayTitle($0.day, now: now, calendar: calendar) }.prefix(2) == ["Today", "Yesterday"])
  }

  @Test func searchMatchesTitleOrProject() {
    let all = projects([("theseus", [("fix menus", 1)]), ("engine", [("loader", 2)])])
    var query = ProjectsQuery()

    query.search = "MENU"
    #expect(ids(query.groups(all)) == ["theseus: fix menus"])
    query.search = "engine"
    #expect(ids(query.groups(all)) == ["engine: loader"])
  }

  @Test func statusFilterAndSort() throws {
    let all = projects([("app", [("a", 10), ("b", 20), ("c", 5)])])
    all[0].sessions[1].transcript = try transcript([prompt("Go"), said("No"), ["type": "result", "subtype": "error_during_execution", "is_error": true, "num_turns": 1, "duration_ms": 10, "duration_api_ms": 4]])
    var query = ProjectsQuery()

    #expect(all[0].sessions.map(\.rowStatus) == [.closed, .failed, .closed])
    #expect(ids(query.groups(all)) == ["app: b c a"])
    query.statuses = [.failed]
    #expect(ids(query.groups(all)) == ["app: b"])
    query.statuses = [.running]
    #expect(query.groups(all).isEmpty)
    query.statuses = [.running, .failed]
    #expect(ids(query.groups(all)) == ["app: b"])
    query.statuses = [.failed, .closed]
    #expect(ids(query.groups(all)) == ["app: b c a"])
    query.statuses = []
    query.sortOrder = [NSSortDescriptor(key: "title", ascending: false)]
    #expect(ids(query.groups(all)) == ["app: c b a"])
  }

  @Test func updatedFilterCountsHoursAndCalendarDays() throws {
    // `now` is 08:00 UTC, so 20 hours ago is yesterday.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let all = projects([("app", [("today", 60), ("yesterday", 60 * 20), ("lastWeek", 60 * 24 * 5), ("old", 60 * 24 * 40)])])
    var query = ProjectsQuery()

    #expect(UpdatedRange.anyTime.start(now: now, calendar: calendar) == nil)
    #expect(UpdatedRange.today.start(now: now, calendar: calendar) == now.addingTimeInterval(-8 * 3600))
    #expect(UpdatedRange.twoDays.start(now: now, calendar: calendar) == now.addingTimeInterval(-32 * 3600))
    query.updated = .fourHours
    #expect(ids(query.groups(all, now: now)) == ["app: today"])
    query.updated = .twoDays
    #expect(ids(query.groups(all, now: now)) == ["app: today yesterday"])
    query.updated = .week
    #expect(ids(query.groups(all, now: now)) == ["app: today yesterday lastWeek"])
    query.updated = .anyTime
    #expect(ids(query.groups(all, now: now)) == ["app: today yesterday lastWeek old"])
  }

  @Test func blankConversationsStayOut() throws {
    let all = projects([("app", [("a", 1), ("b", 2)])])
    let blank = all[0].sessions[1]
    blank.transcriptFile = nil

    #expect(ids(ProjectsQuery().groups(all)) == ["app: a"])
    blank.transcript = try transcript([prompt("Go")])
    #expect(ids(ProjectsQuery().groups(all)) == ["app: a b"])
  }

  @Test func rowTitleIsTheFirstLine() {
    let session = Session(id: "s", workingDirectory: URL(filePath: "/tmp"), updatedAt: now)

    #expect(session.rowTitle == "New Conversation")
    session.lastPrompt = "  Fix the loader\nand the tests"
    #expect(session.rowTitle == "Fix the loader")
    session.worktree = "feature"
    session.gitBranch = "main"
    #expect(session.location == "feature · main")
  }

  @Test func savedQueryRoundTripsWithoutSearch() {
    var query = ProjectsQuery()
    query.statuses = [.waiting, .failed]
    query.updated = .week
    query.showsArchived = true
    query.search = "app"
    query.sortOrder = [NSSortDescriptor(key: "title", ascending: true), NSSortDescriptor(key: "updated", ascending: false)]

    let restored = ProjectsQuery(saved: query.saved)

    #expect(restored.statuses == [.waiting, .failed])
    #expect(restored.updated == .week)
    #expect(restored.showsArchived)
    #expect(restored.search == "")
    #expect(restored.sortOrder.map { "\($0.key ?? "") \($0.ascending)" } == ["title true", "updated false"])
    #expect(ProjectsQuery(saved: [:]).sortOrder == ProjectsQuery().sortOrder)
  }

  @Test func tallyCountsLiveStatuses() {
    #expect(tally([.waiting, .running, .waiting, .closed, .finished]) == "2 waiting, 1 running")
    #expect(tally([.closed, .finished]) == "")
  }

  @Test func updatedReadsLikeFinder() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!

    #expect(updatedText(now.addingTimeInterval(-20), now: now, calendar: calendar) == "Now")
    #expect(updatedText(now.addingTimeInterval(-12 * 60), now: now, calendar: calendar) == "12 min ago")
    #expect(updatedText(now.addingTimeInterval(-26 * 3600), now: now, calendar: calendar) == "Yesterday")
  }
}
