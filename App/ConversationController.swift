import AppKit
import ClaudeEngine
import ClaudeWorkspace

/// One conversation, in a panel that is a tab of its project's window.
final class ConversationController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
  private let project: URL
  private unowned let app: AppDelegate
  private let content = ConversationView()
  private let tabStatus = TabStatusView()
  private var session: Session?
  private var starting: Task<Session, any Error>?
  private var startFailed = false
  /// The last send, so prompts reach the CLI in the order they were typed.
  private var sending: Task<Void, Never>?
  private var hasSent = false
  private var isClosed = false
  /// Counts the sessions this tab has started, so only the newest one's observation keeps running.
  private var generation = 0
  private weak var watchedGroup: NSWindowTabGroup?
  private var groupWatch: NSKeyValueObservation?

  private var frameName: String { "Project \(project.path)" }
  private var isBusy: Bool { session?.live.map { $0.state != .idle } ?? false }

  /// The session's title, else its first prompt, cut to one line.
  private var conversationTitle: String {
    let source = session?.title ?? session?.transcript.turns.lazy.compactMap { $0.prompt?.text }.first ?? ""
    let line = source.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces) ?? ""
    return line.isEmpty ? "New Conversation" : line
  }

  init(app: AppDelegate, project: URL) {
    self.app = app
    self.project = project
    let panel = ConversationPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520), styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow], backing: .buffered, defer: false)
    super.init(window: panel)

    panel.titlebarAppearsTransparent = true
    panel.isFloatingPanel = false
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = false
    panel.isReleasedWhenClosed = false
    panel.isExcludedFromWindowsMenu = false
    // With nothing to restore, a relaunch always gets its untitled-file request.
    panel.isRestorable = false
    panel.collectionBehavior.formUnion([.fullScreenNone, .managed, .participatesInCycle])
    panel.tabbingIdentifier = project.path
    panel.tab.accessoryView = tabStatus
    panel.representedURL = project
    panel.contentView = content
    panel.initialFirstResponder = content.prompt.textView
    panel.delegate = self

    content.prompt.textView.placeholder = "Describe a task or ask a question"
    content.prompt.onSend = { [unowned self] in send() }
    content.prompt.onStop = { [unowned self] in stopSession(nil) }
    content.transcript.onDecision = { [unowned self] request, decision in session?.live?.respond(to: request, with: decision) }
    start()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("ConversationController is built in code") }

  /// Joins the project's open window as a tab, or opens a window where the project's last one was.
  func open() {
    guard let window else { return }

    let others = NSApp.windows.filter { $0 !== window && $0 is ConversationPanel && $0.isVisible && $0.tabbingIdentifier == window.tabbingIdentifier }

    retitle()

    if let target = others.first(where: \.isKeyWindow) ?? others.first {
      target.addTabbedWindow(window, ordered: .above)
    } else if !window.setFrameUsingName(frameName) {
      if let key = NSApp.keyWindow as? ConversationPanel {
        window.setFrameTopLeftPoint(NSPoint(x: key.frame.minX + 24, y: key.frame.maxY - 24))
      } else {
        window.center()
      }
    }

    window.makeKeyAndOrderFront(nil)
    retitle()
  }

  /// The window is titled with the project and the tab with the conversation. With the tab bar hidden
  /// the conversation joins the window title.
  func retitle() {
    guard let window else { return }

    let group = window.tabGroup
    let conversation = conversationTitle
    var title = project.lastPathComponent

    if group !== watchedGroup {
      watchedGroup = group
      groupWatch = group?.observe(\.windows) { [weak self] _, _ in Task { @MainActor in self?.retitle() } }
    }

    if group?.isTabBarVisible != true { title += " – \(conversation)" }

    if window.tab.title != conversation { window.tab.title = conversation }

    if window.title != title { window.title = title }
  }

  // MARK: Session

  /// Starts the `claude` process. A failed start is reported once, and the next send tries again.
  private func start() {
    if let session { discard(session) }

    session = nil
    generation += 1
    let starting = Task { [workspace = app.workspace, project] in try await workspace.start(in: project) { $0.enableTaskTools = true } }
    self.starting = starting
    startFailed = false

    Task { [generation] in
      do {
        session = try await starting.value

        // A pass for an earlier start reads nothing observable, which ends its loop.
        keepCurrent(self) { controller in
          if controller.generation == generation { controller.refresh() }
        }
      } catch {
        startFailed = true
        report(error, as: "Claude Could Not Start")
      }
    }
  }

  /// Pushes the session's state into the window. Runs again whenever something it read changes.
  private func refresh() {
    guard let session, let live = session.live else { return }

    retitle()

    if !live.pendingPermissions.isEmpty || live.state == .requiresAction {
      tabStatus.status = .needsInput
    } else if live.state == .running {
      tabStatus.status = .running
    } else {
      tabStatus.status = .idle
    }

    content.prompt.isBusy = isBusy
    content.prompt.textView.placeholder = session.transcript.turns.isEmpty ? "Describe a task or ask a question" : "Reply"

    let place = [session.worktree ?? project.lastPathComponent, session.gitBranch].compactMap { $0 }.joined(separator: " \u{B7} ")
    let pending = live.pendingPermissions.map { PendingRequest(requestId: $0.requestId, toolUseId: $0.toolUseId) }
    let input = TranscriptInput(header: "Started in \(place)", transcript: session.transcript, streaming: live.streaming.blocks, tasks: live.taskList.tasks, pending: pending, isLive: live.isRunning)
    content.transcript.show(input, requests: live.pendingPermissions, projectName: project.lastPathComponent)
  }

  /// Sends the draft, waiting for the process if it is still starting and resuming the session if its process has exited.
  /// The CLI queues a prompt sent mid-turn.
  private func send() {
    let text = content.prompt.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    content.prompt.draft = ""

    // A process that exited before its first prompt left nothing to resume, so it starts over like a failed start.
    if startFailed || (!hasSent && session?.live?.isRunning == false) { start() }

    sending = Task { [previous = sending, starting] in
      await previous?.value

      do {
        // A failed start has already put up its own alert.
        guard let session = try? await starting?.value else { return restore(text) }

        try await app.workspace.open(session) { $0.enableTaskTools = true }.send(text)
        hasSent = true
      } catch {
        restore(text)
        report(error, as: "The Prompt Could Not Be Sent")
      }
    }
  }

  /// Puts a prompt that was not sent back in the field, after anything typed since.
  private func restore(_ text: String) {
    let draft = content.prompt.draft
    content.prompt.draft = draft.isEmpty ? text : draft + "\n" + text
  }

  private func discard(_ session: Session) {
    Task {
      do {
        try await app.workspace.close(session)
      } catch {
        log.error("Could not discard a blank session: \(error.localizedDescription)")
      }
    }
  }

  private func report(_ error: any Error, as title: String) {
    guard let window, !isClosed else { return log.error("\(title): \(error.localizedDescription)") }

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = error.localizedDescription
    // A sheet needs its window on screen, so a background tab comes forward.
    window.makeKeyAndOrderFront(nil)
    alert.beginSheetModal(for: window)
  }

  // MARK: Commands

  @objc func newConversation(_ sender: Any?) {
    app.openConversation(in: project)
  }

  @objc func stopSession(_ sender: Any?) {
    guard let live = session?.live else { return }

    Task {
      do {
        try await live.interrupt()
      } catch {
        report(error, as: "Claude Could Not Be Stopped")
      }
    }
  }

  /// Session > Allow and Deny answer the oldest permission request, as its card's buttons would.
  @objc func allowRequest(_ sender: Any?) {
    content.transcript.answerOldestRequest(allow: true)
  }

  @objc func denyRequest(_ sender: Any?) {
    content.transcript.answerOldestRequest(allow: false)
  }

  @objc func toggleVerboseTranscript(_ sender: Any?) {
    content.transcript.isVerbose.toggle()
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(stopSession(_:)):
      return isBusy
    case #selector(allowRequest(_:)), #selector(denyRequest(_:)):
      return content.transcript.hasPendingRequest
    case #selector(toggleVerboseTranscript(_:)):
      menuItem.title = content.transcript.isVerbose ? "Show Normal Transcript" : "Show Verbose Transcript"
      return true
    default:
      return true
    }
  }

  // MARK: Window

  func windowDidBecomeMain(_ notification: Notification) {
    content.prompt.updateButton()
    content.transcript.windowActiveChanged()
  }

  func windowDidResignMain(_ notification: Notification) {
    content.prompt.updateButton()
    content.transcript.windowActiveChanged()
  }

  func windowDidMove(_ notification: Notification) {
    window?.saveFrame(usingName: frameName)
  }

  func windowDidResize(_ notification: Notification) {
    window?.saveFrame(usingName: frameName)
  }

  /// A conversation that has run a turn keeps running without its tab. One that never sent a prompt is discarded.
  func windowWillClose(_ notification: Notification) {
    isClosed = true
    app.closed(self)

    Task {
      await sending?.value
      guard !hasSent, let session = try? await starting?.value else { return }

      discard(session)
    }
  }
}
