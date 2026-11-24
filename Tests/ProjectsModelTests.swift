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
    query.filter = .failed
    #expect(ids(query.groups(all)) == ["app: b"])
    query.filter = .running
    #expect(query.groups(all).isEmpty)
    query.filter = nil
    query.sortOrder = [NSSortDescriptor(key: "title", ascending: false)]
    #expect(ids(query.groups(all)) == ["app: c b a"])
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
