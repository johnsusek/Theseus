import ClaudeWorkspace
import Foundation
import Observation

/// A pick in the Sidebar Configuration panel, shown as a pop-up of its cases' titles.
protocol SidebarChoice: CaseIterable, Codable, RawRepresentable where RawValue == Int, AllCases == [Self] {
  var title: String { get }
}

/// How a conversation window's sidebar lists and draws sessions. Pinned sessions always come first, and subsessions always nest under their parent.
struct SidebarStyle: Codable, Equatable {
  enum Grouping: Int, SidebarChoice {
    case none, date, status

    var title: String { ["None", "Date", "Status"][rawValue] }
  }

  enum Order: Int, SidebarChoice {
    case attention, lastActive, created, title

    var title: String { ["Attention", "Last Active", "Created", "Title"][rawValue] }
  }

  enum DateStyle: Int, SidebarChoice {
    case time, relative, short

    var title: String { ["Time", "Relative", "Short"][rawValue] }
  }

  var grouping = Grouping.none
  var order = Order.attention
  var titleLines = 1
  var boldTitle = true
  var showsPrompt = true
  var showsResponse = true
  var responseLines = 2
  var showsActivity = true
  var showsDate = true
  var dateStyle = DateStyle.time
  var showsUnread = true
  var showsWorktree = true
  var showsTasks = false
  /// Tight rows of small text without separators.
  var compact = false
  var showsArchived = false

  var padding: Double { compact ? 4 : 9 }
  var textPoints: Double { compact ? 11 : 13 }

  /// Mail's message list, which is also the default.
  static let mail = SidebarStyle()
  /// Nova's sidebar: one plain line per session.
  static let nova = SidebarStyle(boldTitle: false, showsPrompt: false, showsResponse: false, showsDate: false, compact: true)
}

/// The sidebar style every window draws, kept in UserDefaults.
@MainActor @Observable
final class SidebarSettings {
  static let shared = SidebarSettings()
  private static let key = "SidebarStyle"

  var style: SidebarStyle {
    didSet { UserDefaults.standard.set(try? JSONEncoder().encode(style), forKey: Self.key) }
  }

  private init() {
    guard let data = UserDefaults.standard.data(forKey: Self.key) else {
      style = .mail
      return
    }

    do {
      style = try JSONDecoder().decode(SidebarStyle.self, from: data)
    } catch {
      log.error("Saved sidebar style unreadable, using Mail's: \(error)")
      style = .mail
    }
  }
}

/// A run of sidebar rows under an optional header.
struct SidebarSection {
  let title: String?
  let sessions: [Session]
}

/// The sessions a sidebar lists: any with a transcript or a turn, archived ones only when the style asks, and every waiting or running one.
@MainActor
func sidebarShows(_ session: Session, style: SidebarStyle, now: Date) -> Bool {
  var query = ProjectsQuery()
  query.showsArchived = style.showsArchived
  return query.shows(session, now: now) || session.rowStatus == .waiting || session.rowStatus == .running
}

/// Attention puts waiting sessions first, then running, then unread, each newest first, then the rest newest first.
@MainActor
func sidebarOrder(_ sessions: [Session], _ order: SidebarStyle.Order) -> [Session] {
  switch order {
  case .attention:
    let rank = { (session: Session) in
      if session.rowStatus == .waiting { return 0 }

      if session.rowStatus == .running { return 1 }

      return session.isUnread && !session.isArchived ? 2 : 3
    }
    return sessions.sorted { (rank($0), $1.lastActive) < (rank($1), $0.lastActive) }
  case .lastActive:
    return sessions.sorted { $0.lastActive > $1.lastActive }
  case .created:
    return sessions.sorted { ($0.createdAt ?? $0.updatedAt) > ($1.createdAt ?? $1.updatedAt) }
  case .title:
    return sessions.sorted { $0.rowTitle.localizedStandardCompare($1.rowTitle) == .orderedAscending }
  }
}

/// The sidebar's top-level rows: Pinned, then the other sessions in one untitled run or in date or status groups. Empty sections are left out.
@MainActor
func sidebarSections(_ roots: [Session], style: SidebarStyle, now: Date, calendar: Calendar = .current) -> [SidebarSection] {
  let shown = sidebarOrder(roots.filter { sidebarShows($0, style: style, now: now) }, style.order)
  let pinned = shown.filter(\.isPinned)
  let rest = shown.filter { !$0.isPinned }
  var sections = [SidebarSection(title: "Pinned", sessions: pinned)]

  switch style.grouping {
  case .none:
    sections.append(SidebarSection(title: pinned.isEmpty ? nil : "Sessions", sessions: rest))
  case .date:
    let today = calendar.startOfDay(for: now)
    let starts = [today, calendar.date(byAdding: .day, value: -1, to: today) ?? today, calendar.date(byAdding: .day, value: -7, to: today) ?? today, .distantPast]
    let titles = ["Today", "Yesterday", "Previous 7 Days", "Older"]

    for (index, title) in titles.enumerated() {
      sections.append(SidebarSection(title: title, sessions: rest.filter { session in starts.firstIndex { session.lastActive >= $0 } == index }))
    }
  case .status:
    let group = { (session: Session) in
      switch session.rowStatus {
      case .waiting: return 0
      case .running: return 1
      case .failed: return 2
      default: return session.isUnread ? 3 : 4
      }
    }
    let titles = ["Needs Input", "Running", "Failed", "Unread", "Idle"]

    for (index, title) in titles.enumerated() {
      sections.append(SidebarSection(title: title, sessions: rest.filter { group($0) == index }))
    }
  }

  return sections.filter { !$0.sessions.isEmpty }
}

/// "now", "12m", "3h", "2d", "5w".
func shortAge(_ date: Date, now: Date) -> String {
  let minutes = Int(now.timeIntervalSince(date) / 60)

  if minutes < 1 { return "now" }

  if minutes < 60 { return "\(minutes)m" }

  if minutes < 1440 { return "\(minutes / 60)h" }

  if minutes < 10080 { return "\(minutes / 1440)d" }

  return "\(minutes / 10080)w"
}
