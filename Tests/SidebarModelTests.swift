import Foundation
import Testing
@testable import ClaudeWorkspace

@MainActor
struct SidebarModelTests {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let project = Project(path: URL(filePath: "/tmp/app", directoryHint: .isDirectory))
  var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    return calendar
  }

  /// Sessions named by their ids, last active `minutes` ago.
  func sessions(_ entries: [(id: String, minutes: Double)]) -> [Session] {
    entries.map { entry in
      let session = Session(id: entry.id, workingDirectory: project.path, updatedAt: now.addingTimeInterval(-entry.minutes * 60))
      session.appTitle = entry.id
      session.transcriptFile = project.path.appending(path: "\(entry.id).jsonl")
      session.project = project
      return session
    }
  }

  func layout(_ roots: [Session], _ style: SidebarStyle) -> [String] {
    sidebarSections(roots, style: style, now: now, calendar: calendar).map { section in "\(section.title ?? "-"): " + section.sessions.map(\.id).joined(separator: " ") }
  }

  @Test func listsNewestFirstWithoutHeaders() {
    #expect(layout(sessions([("a", 30), ("b", 5), ("c", 60)]), SidebarStyle()) == ["-: b a c"])
  }

  @Test func pinnedComeFirstUnderTheirOwnHeader() {
    let roots = sessions([("a", 30), ("b", 5), ("c", 60)])
    roots[2].isPinned = true

    #expect(layout(roots, SidebarStyle()) == ["Pinned: c", "Sessions: b a"])
  }

  @Test func groupsByDate() {
    var style = SidebarStyle()
    style.grouping = .date

    // Now is 08:00 UTC, so 20 hours back is yesterday.
    #expect(layout(sessions([("today", 60), ("yesterday", 20 * 60), ("week", 3 * 1440), ("old", 30 * 1440)]), style) == ["Today: today", "Yesterday: yesterday", "Previous 7 Days: week", "Older: old"])
  }

  @Test func groupsByStatusLeavingEmptyGroupsOut() {
    var style = SidebarStyle()
    style.grouping = .status
    let roots = sessions([("read", 5), ("unread", 10)])
    roots[1].turnEndedAt = now

    #expect(layout(roots, style) == ["Unread: unread", "Idle: read"])
  }

  @Test func archivedShowOnlyWhenAsked() {
    var style = SidebarStyle()
    let roots = sessions([("a", 5), ("b", 10)])
    roots[0].isArchived = true

    #expect(layout(roots, style) == ["-: b"])

    style.showsArchived = true
    #expect(layout(roots, style) == ["-: a b"])
  }

  @Test func sortsByTitle() {
    var style = SidebarStyle()
    style.order = .title

    #expect(layout(sessions([("beta", 5), ("Alpha", 10), ("gamma", 1)]), style) == ["-: Alpha beta gamma"])
  }

  @Test func shortAges() {
    #expect([0.5, 12, 180, 3 * 1440, 21 * 1440].map { shortAge(now.addingTimeInterval(-$0 * 60), now: now) } == ["now", "12m", "3h", "3d", "3w"])
  }

  @Test func stylesRoundTripThroughJSON() throws {
    let data = try JSONEncoder().encode(SidebarStyle.nova)

    #expect(try JSONDecoder().decode(SidebarStyle.self, from: data) == .nova)
  }
}
