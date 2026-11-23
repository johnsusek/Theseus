import AppKit
import ClaudeEngine
import ClaudeWorkspace

/// One conversation, in a panel that is a tab of its project's window.
final class ConversationController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
  private let project: URL
  private unowned let app: AppDelegate
  private let content = ConversationView()
  private let tabStatus = TabStatusView()
  private let permissions = PermissionSheet()
  private var session: Session?
  private var starting: Task<Session, any Error>?
  private var startFailed = false
  /// The last send, so prompts reach the CLI in the order they were typed.
  private var sending: Task<Void, Never>?
  private var hasSent = false
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
    panel.contentMinSize = NSSize(width: 500, height: 220)
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
    let starting = Task { [workspace = app.workspace, project] in try await workspace.start(in: project) }
    self.starting = starting
    startFailed = false

    Task {
      do {
        session = try await starting.value
        keepCurrent(self) { $0.refresh() }
      } catch {
        startFailed = true
        report(error, as: "Claude Could Not Start")
      }
    }
  }

  /// Pushes the session's state into the window. Runs again whenever something it read changes.
  private func refresh() {
    guard let window, let session, let live = session.live else { return }

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
    content.transcript.show(session.transcript, streaming: live.streaming)
    permissions.update(live, on: window)
  }

  /// Sends the draft, waiting for the process if it is still starting. The CLI queues a prompt sent mid-turn.
  private func send() {
    let text = content.prompt.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    content.prompt.draft = ""

    if startFailed { start() }

    sending = Task { [previous = sending, starting] in
      await previous?.value

      do {
        // A failed start has already put up its own alert.
        guard let live = try? await starting?.value.live else { return restore(text) }

        try await live.send(text)
        hasSent = true
      } catch {
        restore(text)
        report(error, as: "The Prompt Could Not Be Sent")
      }
    }
  }

  private func restore(_ text: String) {
    if content.prompt.draft.isEmpty { content.prompt.draft = text }
  }

  private func report(_ error: any Error, as title: String) {
    guard let window else { return }

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = error.localizedDescription
    alert.beginSheetModal(for: window)
  }

  // MARK: Commands

  @objc func newConversation(_ sender: Any?) {
    app.openConversation(in: project)
  }

  /// The tab bar's + button.
  override func newWindowForTab(_ sender: Any?) {
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

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    menuItem.action == #selector(stopSession(_:)) ? isBusy : true
  }

  // MARK: Window

  func windowDidBecomeKey(_ notification: Notification) {
    // A permission request that arrived while this tab was in the background is asked now.
    refresh()
  }

  func windowDidBecomeMain(_ notification: Notification) {
    content.prompt.updateButton()
  }

  func windowDidResignMain(_ notification: Notification) {
    content.prompt.updateButton()
  }

  func windowDidMove(_ notification: Notification) {
    window?.saveFrame(usingName: frameName)
  }

  func windowDidResize(_ notification: Notification) {
    window?.saveFrame(usingName: frameName)
  }

  /// A conversation that has run a turn keeps running without its tab. One that never sent a prompt is discarded.
  func windowWillClose(_ notification: Notification) {
    app.closed(self)

    Task {
      await sending?.value
      guard !hasSent, let session = try? await starting?.value else { return }

      do {
        try await app.workspace.close(session)
      } catch {
        log.error("Could not discard a blank session: \(error.localizedDescription)")
      }
    }
  }
}
