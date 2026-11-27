import AppKit
import ClaudeWorkspace
import StagehandShared

/// A second logged-in macOS account that conversations drive with the desktop_* tools while the user keeps their own screen.
/// It turns on when every checklist item passes, and lets one conversation's turn drive it at a time.
@MainActor @Observable
final class PrivateDesktop {
  enum Status: Equatable { case unchecked, passed, failed }

  /// The conversation turn driving it: the lease ends when that session's turn ends.
  private struct Lease {
    weak var session: Session?
    var turnEndedAt: Date?
  }

  private(set) var statuses: [DesktopItem: Status] = [:]
  private(set) var user: String?
  private(set) var screen: CGSize?
  private(set) var isChecking = false
  /// Every item passed at the last check. Sessions launched while it holds get the tools.
  private(set) var isOn = false
  /// The user took it from Claude in the Private Desktop window.
  var isTakenByUser = false {
    didSet { lease = nil }
  }

  private var lease: Lease?
  @ObservationIgnored let socket: String
  @ObservationIgnored private let accounts: @MainActor () async -> StageAccounts

  var failing: DesktopItem? { DesktopItem.allCases.first { statuses[$0] != .passed } }

  var holder: Session? {
    guard let lease, let session = lease.session, session.live?.isRunning != false, session.turnEndedAt == lease.turnEndedAt else { return nil }

    return session
  }

  init(socket: String = socketPath, accounts: @escaping @MainActor () async -> StageAccounts) {
    self.socket = socket
    self.accounts = accounts
  }

  /// Checks now, then every 30 seconds while it is on, so a logout turns it off.
  func start() {
    Task { [weak self] in
      await self?.check()

      while true {
        try? await Task.sleep(for: .seconds(30))
        guard let self else { return }

        if isOn { await check() }
      }
    }
  }

  func check() async {
    guard !isChecking else { return }

    isChecking = true
    let results = await runChecks()
    statuses = Dictionary(uniqueKeysWithValues: DesktopItem.allCases.map { ($0, results[$0] ?? .unchecked) })
    isOn = failing == nil
    isChecking = false
  }

  private func runChecks() async -> [DesktopItem: Status] {
    var results: [DesktopItem: Status] = [:]

    func passes(_ item: DesktopItem, _ passed: Bool) -> Bool {
      results[item] = passed ? .passed : .failed
      return passed
    }

    let found = await accounts()
    user = found.loggedIn.first ?? found.users.first
    guard passes(.account, !found.users.isEmpty), passes(.loggedIn, !found.loggedIn.isEmpty) else { return results }

    let answer = try? await Stagehand.send("display", socket: socket)
    let report = answer.flatMap { $0.ok ? DisplayReport($0.output) : nil }
    guard passes(.agent, report != nil), let report else { return results }

    user = report.user
    screen = report.screen
    guard passes(.accessibility, report.accessibility) else { return results }

    var captured = false

    if report.screenRecording, let shot = try? await Stagehand.send("shot", ["--1x"], socket: socket), let image = shot.image {
      captured = !DesktopChecks.isUniform(image)
    }

    guard passes(.screenRecording, captured) else { return results }

    let center = "\(Int(report.screen.width / 2)),\(Int(report.screen.height / 2))"
    let pointer = try? await Stagehand.send("pointer", [center], socket: socket)
    _ = passes(.input, pointer.map { $0.ok && DesktopChecks.pointerReadsBack($0.output) } ?? false)
    return results
  }

  /// Sends one command for `session`'s turn, taking the lease when no other turn holds it.
  func send(_ command: String, _ args: [String] = [], for session: Session) async throws -> Response {
    if let item = failing { throw DesktopFailure("The Private Desktop is off because \"\(item.title)\" failed its check. Ask the user to open Window > Private Desktop.") }
    if isTakenByUser { throw DesktopFailure("The user has taken over the Private Desktop. Wait, or ask them to hand it back.") }
    if let holder, holder !== session { throw DesktopFailure("Private Desktop is in use by \(holder.title ?? "another conversation").") }

    if holder == nil { lease = Lease(session: session, turnEndedAt: session.turnEndedAt) }

    let response = try await Stagehand.send(command, args, socket: socket)
    guard response.ok else { throw DesktopFailure(response.output) }

    return response
  }

  func release(_ session: Session) {
    if lease?.session === session { lease = nil }
  }
}

struct DesktopFailure: LocalizedError {
  let errorDescription: String?

  init(_ message: String) { errorDescription = message }
}
