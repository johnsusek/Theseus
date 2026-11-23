import AppKit
import ClaudeEngine
import ClaudeWorkspace

/// One conversation, in a panel that is a tab of its project's window.
final class ConversationController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSPopoverDelegate {
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
  /// When the session last went from idle to busy, which the activity timer counts from until the turn has a date.
  private var busySince: Date?
  private var agentsPopover: NSPopover?
  private var changesPopover: NSPopover?
  /// The click that closed a popover. The same click on the popover's own chip must not open it again.
  private var closingClick: Int?
  /// How many of the session's issues are already in the log.
  private var loggedIssues = 0

  private var frameName: String { "Project \(project.path)" }
  private var isBusy: Bool { session?.live.map { $0.state != .idle } ?? false }
  private var agentList: AgentListController? { agentsPopover?.contentViewController as? AgentListController }
  private var changeList: ChangeListController? { changesPopover?.contentViewController as? ChangeListController }

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
    content.status.agents.target = self
    content.status.agents.action = #selector(showAgents(_:))
    content.status.changes.target = self
    content.status.changes.action = #selector(showChanges(_:))
    content.status.menuItems = { [unowned self] button in button === content.status.model ? menuItems(.model, labeled: true) + menuItems(.effort, labeled: true) + [.separator(), fastModeItem()] : menuItems(.mode) }
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
    loggedIssues = 0
    generation += 1
    let starting = Task { [workspace = app.workspace, project] in try await workspace.start(in: project, settings: .lastChosen) { $0.enableTaskTools = true } }
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
    showStatus(session, live)
  }

  /// Fills the status row and whichever of its popovers is open.
  private func showStatus(_ session: Session, _ live: LiveSession) {
    let transcript = session.transcript
    var status = StatusRowState()

    for issue in live.issues.dropFirst(loggedIssues) { log.error("\(issue)") }

    loggedIssues = live.issues.count
    busySince = isBusy ? busySince ?? .now : nil
    status.runningAgents = live.isRunning ? transcript.tasks.count { $0.kind == .agent && $0.status.isActive } : 0
    status.showsAgents = status.runningAgents > 0 || agentsPopover != nil
    status.changedFiles = transcript.changedFiles.count
    status.added = transcript.changedFiles.reduce(0) { $0 + $1.lineDelta.added }
    status.removed = transcript.changedFiles.reduce(0) { $0 + $1.lineDelta.removed }

    if isBusy {
      let turn = transcript.turns.last.flatMap { $0.status == .running ? $0 : nil }
      status.activity = activityLine(summary: live.activity, isWaiting: !live.pendingPermissions.isEmpty || live.state == .requiresAction, transcript: transcript)
      status.busySince = turn?.startedAt ?? busySince
    }

    status.hasSession = true
    status.model = modelName(live.modelInfo, id: live.model, among: live.initializeInfo?.models ?? [])
    status.effort = live.effort.map(effortName) ?? ""
    status.mode = live.permissionMode.map(modeName) ?? "Unknown Mode"
    status.contextUsed = live.contextUsage?.totalTokens ?? 0
    status.contextMax = live.contextUsage?.maxTokens ?? 0
    content.status.state = status
    agentList?.rows = agentRows(transcript, processIsRunning: live.isRunning)
    changeList?.rows = changeRows(transcript.changedFiles, base: session.workingDirectory)
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

  // MARK: Agents and changes

  @objc func showAgents(_ sender: Any?) {
    guard agentsPopover == nil, !isClosingClick else { return }

    let list = AgentListController()
    list.onStop = { [unowned self] rows in stop(rows) }
    present(list, under: content.status.agents, as: \.agentsPopover)
  }

  @objc func showChanges(_ sender: Any?) {
    guard changesPopover == nil, !isClosingClick else { return }

    present(ChangeListController(), under: content.status.changes, as: \.changesPopover)
  }

  /// A click on a chip whose popover is open closes the popover, as any click outside it does, and its action follows.
  private var isClosingClick: Bool { closingClick != nil && closingClick == NSApp.currentEvent.flatMap { $0.type == .leftMouseUp || $0.type == .leftMouseDown ? $0.eventNumber : nil } }

  /// Shows `list` in a popover under `chip`.
  private func present(_ list: ListController, under chip: NSView, as slot: ReferenceWritableKeyPath<ConversationController, NSPopover?>) {
    let popover = NSPopover()

    popover.behavior = .transient
    popover.contentViewController = list
    popover.delegate = self
    self[keyPath: slot] = popover
    // Fills the list, and puts the agents badge on screen when no agent is running.
    refresh()
    content.layoutSubtreeIfNeeded()
    popover.show(relativeTo: chip.bounds, of: chip, preferredEdge: .minY)
  }

  func popoverWillClose(_ notification: Notification) {
    closingClick = NSApp.currentEvent.flatMap { $0.type == .leftMouseDown ? $0.eventNumber : nil }
  }

  func popoverDidClose(_ notification: Notification) {
    if notification.object as? NSPopover === agentsPopover { agentsPopover = nil } else { changesPopover = nil }

    // The badge leaves with its popover when no agent is running.
    refresh()
  }

  private func stop(_ rows: [AgentRow]) {
    guard let live = session?.live else { return }

    Task {
      do {
        for taskId in rows.filter({ $0.state == .running }).compactMap(\.taskId) { try await live.engine.stopTask(taskId) }
      } catch {
        report(error, as: "The Agent Could Not Be Stopped")
      }
    }
  }

  // MARK: Model, effort and permission mode

  /// The items of a session menu, for the status row's menus and the menu bar's. `validateMenuItem` checks the current one.
  func menuItems(_ kind: SessionMenu, labeled: Bool = false) -> [NSMenuItem] {
    guard let live = session?.live else { return [] }

    var items: [NSMenuItem] = []

    switch kind {
    case .model:
      items = (live.initializeInfo?.models ?? []).map { model in
        let item = NSMenuItem(title: model.displayName, action: #selector(pickModel(_:)), keyEquivalent: "")
        item.representedObject = model.value
        item.toolTip = model.description
        return item
      }
    case .effort:
      items = (live.modelInfo?.supportedEffortLevels ?? []).map { level in
        let item = NSMenuItem(title: effortName(level), action: #selector(pickEffort(_:)), keyEquivalent: "")
        item.representedObject = level
        return item
      }
    case .mode:
      // The CLI refuses to enter bypassPermissions in a session launched without it, so it is not offered.
      let modes: [PermissionMode] = live.modelInfo?.supportsAutoMode == true ? [.default, .acceptEdits, .plan, .auto] : [.default, .acceptEdits, .plan]

      items = modes.map { mode in
        let item = NSMenuItem(title: modeName(mode), action: #selector(pickPermissionMode(_:)), keyEquivalent: "")
        item.representedObject = mode.rawValue
        return item
      }
    }

    if labeled, !items.isEmpty { items.insert(.sectionHeader(title: kind == .model ? "Model" : "Effort"), at: 0) }

    return items
  }

  private func fastModeItem() -> NSMenuItem {
    NSMenuItem(title: "Fast Mode", action: #selector(toggleFastMode(_:)), keyEquivalent: "")
  }

  @objc func pickModel(_ sender: NSMenuItem) {
    guard let value = sender.representedObject as? String else { return }

    change("The Model Could Not Be Changed") { $0.model = value } with: { try await $0.setModel(value) }
  }

  @objc func pickEffort(_ sender: NSMenuItem) {
    guard let level = sender.representedObject as? String else { return }

    change("The Effort Could Not Be Changed") { $0.effort = level } with: { try await $0.setEffort(level) }
  }

  @objc func pickPermissionMode(_ sender: NSMenuItem) {
    guard let mode = (sender.representedObject as? String).map(PermissionMode.init(rawValue:)) else { return }

    change("The Permission Mode Could Not Be Changed") { $0.permissionMode = mode } with: { try await $0.setPermissionMode(mode) }
  }

  @objc func toggleFastMode(_ sender: Any?) {
    guard let isOn = session?.live.map({ !$0.fastMode }) else { return }

    change("Fast Mode Could Not Be Changed") { $0.fastMode = isOn } with: { try await $0.setFastMode(isOn) }
  }

  /// Sends a pick to the session. One that succeeds is what the next new conversation starts with;
  /// one that fails is reported, and the row keeps showing what the session still has.
  private func change(_ failure: String, remember: @escaping (inout SessionSettings) -> Void, with apply: @escaping (LiveSession) async throws -> Void) {
    guard let live = session?.live else { return }

    Task {
      do {
        try await apply(live)
        remember(&SessionSettings.lastChosen)
      } catch {
        report(error, as: failure)
      }
    }
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    let live = session?.live
    let pick = menuItem.representedObject as? String
    let canPick = live?.isRunning == true

    switch menuItem.action {
    case #selector(showAgents(_:)):
      return session?.transcript.tasks.contains { $0.kind == .agent } ?? false
    case #selector(showChanges(_:)):
      return !(session?.transcript.changedFiles.isEmpty ?? true)
    case #selector(pickModel(_:)):
      menuItem.state = pick == live?.modelInfo?.value ? .on : .off
      return canPick
    case #selector(pickEffort(_:)):
      menuItem.state = pick == live?.effort ? .on : .off
      return canPick
    case #selector(pickPermissionMode(_:)):
      menuItem.state = pick == live?.permissionMode?.rawValue ? .on : .off
      return canPick
    case #selector(toggleFastMode(_:)):
      menuItem.state = live?.fastMode == true ? .on : .off
      return canPick && live?.modelInfo?.supportsFastMode == true
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
    windowActiveChanged()
  }

  func windowDidResignMain(_ notification: Notification) {
    windowActiveChanged()
  }

  private func windowActiveChanged() {
    content.prompt.updateButton()
    content.transcript.windowActiveChanged()
    content.status.windowActiveChanged()
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

extension SessionSettings {
  /// What a new conversation starts with: the model, effort, permission mode and fast mode last picked in any conversation.
  static var lastChosen: SessionSettings {
    get { UserDefaults.standard.data(forKey: "LastSessionSettings").flatMap { try? JSONDecoder().decode(SessionSettings.self, from: $0) } ?? SessionSettings() }
    set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "LastSessionSettings") }
  }
}
