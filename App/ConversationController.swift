import AppKit
import ClaudeEngine
import ClaudeWorkspace
import Quartz

/// One conversation, in a window that is a tab of its project's window.
final class ConversationController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSPopoverDelegate, RowRequestActions {
  private let project: URL
  private unowned let app: AppDelegate
  private let content = ConversationView()
  private lazy var split = ConversationSplitController(content: content)
  private let tabStatus = TabStatusView()
  private(set) var session: Session?
  private var starting: Task<Session, any Error>?
  private var startFailed = false
  /// The last send, so prompts reach the CLI in the order they were typed.
  private var sending: Task<Void, Never>?
  private var hasSent = false
  /// Prompts sent and not yet echoed back by the CLI.
  private var sent: [SentPrompt] = []
  private var isClosed = false
  /// Counts the sessions this tab has started, so only the newest one's observation keeps running.
  private var generation = 0
  private weak var watchedGroup: NSWindowTabGroup?
  private var groupWatch: NSKeyValueObservation?
  /// Whether the sidebar's observation is running. A tab behind another lets it end and starts it again when it comes forward.
  private var watchesSidebar = false
  /// When the session last went from idle to busy, which the activity timer counts from until the turn has a date.
  private var busySince: Date?
  private var agentsPopover: NSPopover?
  private var changesPopover: NSPopover?
  /// The click that closed a popover, and that popover's chip. The same click on that chip must not open it again.
  private var closingClick: (chip: NSView, event: Int)?
  /// How many of the session's issues are already in the log.
  private var loggedIssues = 0
  private var preview: PreviewWindowController?
  private(set) lazy var browser = Browser(conversation: self)
  /// How much wider the window got to make room for the browser's pane, given back when the pane closes.
  private var browserGrowth = 0.0
  private var linkPopover: NSPopover?
  /// Counts the times the start page started watching the workspace, so only the newest pass runs.
  private var startPageWatch = 0
  /// The session id the window's restorable state holds.
  private var encodedSessionId: String?

  private var frameName: String { "Project \(project.path)" }
  private var isBusy: Bool { session?.live.map { $0.state != .idle } == true || isOwnerBusy }
  /// The other process reports busy while background agents run after its turn, so a turn its transcript shows ended counts as idle.
  private var isOwnerBusy: Bool { session?.owner?.isBusy == true && session?.transcript.turns.last?.status == .running }
  private var agentList: AgentListController? { agentsPopover?.contentViewController as? AgentListController }
  private var changeList: ChangeListController? { changesPopover?.contentViewController as? ChangeListController }

  private var conversationTitle: String { session?.rowTitle ?? "New Conversation" }

  /// A blank conversation when `session` is nil, which starts its process at once; otherwise that session's conversation.
  init(app: AppDelegate, project: URL, session existing: Session? = nil) {
    self.app = app
    self.project = project
    let window = ConversationWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 520), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    super.init(window: window)

    window.isReleasedWhenClosed = false
    // Quit and Keep Windows, or the system's setting to keep windows, brings the tab back with its conversation.
    window.isRestorable = true
    window.restorationClass = ConversationRestoration.self
    window.identifier = NSUserInterfaceItemIdentifier("Conversation")
    window.collectionBehavior.formUnion([.fullScreenNone, .managed, .participatesInCycle])
    window.tabbingIdentifier = project.path
    window.tab.accessoryView = tabStatus
    window.representedURL = project
    // A content view controller sizes the window to its view, so the view starts at the window's size.
    split.view.frame = NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size)
    window.contentViewController = split
    window.initialFirstResponder = content.prompt.textView
    window.delegate = self

    content.prompt.textView.placeholder = "Describe a task or ask a question"
    content.prompt.onSend = { [unowned self] in send() }
    content.prompt.onStop = { [unowned self] in stopSession(nil) }
    content.transcript.onDecision = { [unowned self] request, decision in session?.live?.respond(to: request, with: decision) }
    content.transcript.onLink = { [unowned self] link, rect in openLink(link, at: rect) }
    content.transcript.onReply = { [unowned self] text in send(text) }
    content.transcript.onOpenPage = { [unowned self] address in browser.reveal(address) }
    content.prompt.agents.target = self
    content.prompt.agents.action = #selector(showAgents(_:))
    content.prompt.changes.target = self
    content.prompt.changes.action = #selector(showChanges(_:))
    content.prompt.settingsItems = { [unowned self] in settingsMenuItems() }
    content.picks.menuItems = { [unowned self] button in
      if button === content.picks.model { return menuItems(.model) + [.separator(), pickItem("Fast Mode", #selector(toggleFastMode(_:)), nil)] }

      return menuItems(button === content.picks.effort ? .effort : .mode)
    }

    content.startPage.onOpen = { [unowned self] picked in openFromStartPage(picked) }
    // The sidebar keeps focus in the tab it brings forward, as a source list does after a click.
    split.sidebar.onOpen = { [unowned self] picked in
      if content.showsStartPage { openFromStartPage(picked) } else { app.showConversation(picked) }

      app.conversation(for: picked)?.split.sidebar.focus()
    }
    watchSidebar()
    content.startPage.history.outline.onEscape = { [unowned self] in toggleHistory(nil) }
    // The empty transcript would show its own scroller beside the start page's.
    content.showsStartPage = existing == nil
    content.transcript.isHidden = existing == nil

    if let existing {
      attach(existing)
    } else {
      start()
      watchStartPage()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("ConversationController is built in code") }

  /// Joins the project's open window as a tab, or opens a window where the project's last one was.
  func open() {
    guard let window else { return }

    let others = NSApp.windows.filter { $0 !== window && $0 is ConversationWindow && $0.isVisible && $0.tabbingIdentifier == window.tabbingIdentifier }

    retitle()

    if let target = others.first(where: \.isKeyWindow) ?? others.first {
      target.addTabbedWindow(window, ordered: .above)
    } else {
      let restored = window.setFrameUsingName(frameName)
      // The frontmost project window, whether or not the app is active: a folder opened from Finder arrives while it is not.
      let front = NSApp.orderedWindows.first { $0 !== window && $0 is ConversationWindow && $0.isVisible }
      let covers = NSApp.windows.contains { $0 !== window && $0 is ConversationWindow && $0.isVisible && $0.frame.origin == window.frame.origin }
      let visible = (front?.screen ?? window.screen ?? NSScreen.main)?.visibleFrame
      var frame = window.frame

      // A new project's window, or one whose saved place another window now holds, steps down and right from the front one,
      // back to the screen's top left when that would leave the screen. With no window to step from, it is centered.
      // These set the frame outright: `center()` and `setFrameTopLeftPoint` leave a window this early where it is.
      if let front, !restored || covers {
        frame.origin = NSPoint(x: front.frame.minX + 24, y: front.frame.maxY - 24 - frame.height)

        if let visible, frame.maxX > visible.maxX || frame.minY < visible.minY { frame.origin = NSPoint(x: visible.minX + 24, y: visible.maxY - 24 - frame.height) }

        window.setFrame(frame, display: false)
      } else if !restored, let visible {
        frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.minY + (visible.height - frame.height) * 2 / 3)
        window.setFrame(frame, display: false)
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

  /// Shows a conversation that already exists. Its history loads read-only, and the first send resumes it,
  /// unless its process is still running, as it is for a conversation whose tab was closed.
  private func attach(_ session: Session) {
    self.session = session
    hasSent = true
    starting = Task { session }

    keepCurrent(self) { $0.refresh() }

    Task {
      do {
        try await app.workspace.loadHistory(session)
      } catch {
        report(error, as: "The Conversation Could Not Be Loaded")
      }
    }
  }

  /// Pushes the session's state into the window. Runs again whenever something it read changes.
  /// A conversation opened from its history has no process until its first send.
  private func refresh() {
    guard let session else { return }

    let live = session.live
    let owner = session.owner
    let requests = live?.pendingPermissions ?? []
    let isWaiting = !requests.isEmpty || live?.state == .requiresAction || owner?.status == "waiting"

    retitle()
    markReadIfShown()
    split.sidebar.current = session

    // A conversation is worth restoring by its id once it has a turn; before that a relaunch gives a blank one.
    let restorableId = session.transcript.turns.isEmpty ? nil : session.id

    if restorableId != encodedSessionId {
      encodedSessionId = restorableId
      window?.invalidateRestorableState()
    }

    if isWaiting {
      tabStatus.status = .needsInput
    } else if live?.state == .running || isOwnerBusy {
      tabStatus.status = .running
    } else {
      tabStatus.status = .idle
    }

    if !sent.isEmpty {
      let echoed = Set(session.transcript.messages.compactMap(\.uuid))
      sent.removeAll { echoed.contains($0.uuid) }
    }

    // Stop is only for this app's own process.
    content.prompt.isBusy = isBusy && owner == nil
    content.prompt.isLocked = owner != nil
    content.transcript.canReply = owner == nil

    let isBlank = owner == nil && session.transcript.turns.isEmpty && sent.isEmpty

    if let owner {
      content.prompt.textView.placeholder = "Running in " + ownerName(entrypoint: owner.entrypoint)
    } else {
      let asks = requests.contains { RequestKind($0) == .question }
      content.prompt.textView.placeholder = isBlank ? "Describe a task or ask a question" : asks ? "Type your own answer, or pick one above" : "Reply"
    }

    // A conversation's first prompt replaces the start page for good.
    if !isBlank {
      content.showsStartPage = false
      content.transcript.isHidden = false
    }

    content.picks.isHidden = !isBlank || live == nil
    // Past the start page the picks move into the prompt, so the mode a conversation runs in always shows.
    content.prompt.settings.isHidden = isBlank || live?.isRunning != true

    if let live {
      let model = modelName(live.modelInfo, id: live.model, among: live.initializeInfo?.models ?? [])
      let effort = live.effort.map(effortName) ?? ""
      let mode = live.permissionMode.map(modeName) ?? "Unknown Mode"
      content.picks.show(model: model, effort: effort, mode: mode)
      content.prompt.showSettings(mode: mode, detail: [model, effort.isEmpty ? "" : effort + " effort", mode + " mode"].filter { !$0.isEmpty }.joined(separator: " \u{B7} "))
      content.prompt.context = ContextMeter(used: live.contextUsage?.totalTokens ?? 0, max: live.contextUsage?.maxTokens ?? 0)
    }

    let pending = requests.map { PendingRequest(requestId: $0.requestId, toolUseId: $0.toolUseId) }
    let tasks = live?.taskList.tasks ?? TaskList(session.transcript).tasks
    var input = TranscriptInput(transcript: session.transcript, streaming: live?.streaming.blocks ?? [], tasks: tasks, pending: pending, isLive: live?.isRunning == true || owner != nil, sent: sent)
    busySince = isBusy ? busySince ?? .now : nil

    if let busySince {
      let turn = session.transcript.turns.last.flatMap { $0.status == .running ? $0 : nil }
      let text = requests.first.map(RequestKind.init) == .question ? "Waiting for an answer" : activityLine(summary: live?.activity, isWaiting: isWaiting, transcript: session.transcript)
      input.activity = Activity(text: text, since: turn?.startedAt ?? busySince)
    }

    content.transcript.show(input, requests: requests, projectName: project.lastPathComponent)
    showChips(session, live)
  }

  /// Fills the prompt's agents badge and changes chip and whichever of their popovers is open.
  private func showChips(_ session: Session, _ live: LiveSession?) {
    let transcript = session.transcript
    var chips = ChipCounts()
    chips.runningAgents = transcript.tasks.count { $0.kind == .agent && $0.status.isActive }
    chips.showsAgents = chips.runningAgents > 0 || agentsPopover != nil
    chips.changedFiles = transcript.changedFiles.count
    chips.added = transcript.changedFiles.reduce(0) { $0 + $1.lineDelta.added }
    chips.removed = transcript.changedFiles.reduce(0) { $0 + $1.lineDelta.removed }

    agentList?.rows = agentRows(transcript)
    changeList?.rows = changeRows(transcript.changedFiles, base: session.workingDirectory)

    content.prompt.chips = chips
    guard let live else { return }

    for issue in live.issues.dropFirst(loggedIssues) { log.error("\(issue)") }

    loggedIssues = live.issues.count
  }

  /// Sends the draft, waiting for the process if it is still starting and resuming the session if its process has exited.
  /// The CLI queues a prompt sent mid-turn.
  /// A reply typed while Claude waits on a question answers it in the user's own words, rather than queueing behind it.
  private func send() {
    let text = content.prompt.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    content.prompt.draft = ""

    if let live = session?.live, let question = live.pendingPermissions.first(where: { RequestKind($0) == .question }) {
      let questions = question.questions
      let decision: PermissionDecision = questions.count == 1 ? .answer([questions[0].question: text], to: question) : .deny(message: "The user answered in their own words instead of picking options: \(text)")
      return live.respond(to: question, with: decision)
    }

    send(text)
  }

  private func send(_ text: String) {
    let prompt = SentPrompt(uuid: UUID().uuidString.lowercased(), text: text)
    sent.append(prompt)
    refresh()

    // A process that exited before its first prompt left nothing to resume, so it starts over like a failed start.
    if startFailed || (!hasSent && session?.live?.isRunning == false) { start() }

    sending = Task { [previous = sending, starting] in
      await previous?.value

      do {
        // A failed start has already put up its own alert.
        guard let session = try? await starting?.value else { return restore(prompt) }

        try await app.workspace.open(session) { $0.enableTaskTools = true }.send(text, uuid: prompt.uuid)
        hasSent = true
      } catch {
        restore(prompt)
        report(error, as: "The Prompt Could Not Be Sent")
      }
    }
  }

  /// Puts a prompt that was not sent back in the field, after anything typed since.
  private func restore(_ prompt: SentPrompt) {
    let draft = content.prompt.draft
    sent.removeAll { $0 == prompt }
    content.prompt.draft = draft.isEmpty ? prompt.text : draft + "\n" + prompt.text
    refresh()
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
    showError(error, as: title, on: isClosed ? nil : window)
  }

  // MARK: Commands

  /// A shell code block's Run button: the code runs in a new Terminal window, in the session's folder.
  @objc func runInTerminal(_ sender: CodeButtonsView) {
    let directory = (session?.workingDirectory ?? project).path
    let script = FileManager.default.temporaryDirectory.appending(path: "Theseus-\(UUID().uuidString.prefix(8)).command")
    let quoted = "'" + directory.replacingOccurrences(of: "'", with: "'\\''") + "'"

    do {
      try "cd \(quoted)\n\(sender.code)\n".write(to: script, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    } catch {
      return report(error, as: "Could not run the code in Terminal")
    }

    Task {
      do {
        try await NSWorkspace.shared.open([script], withApplicationAt: URL(filePath: "/System/Applications/Utilities/Terminal.app"), configuration: NSWorkspace.OpenConfiguration())
      } catch {
        report(error, as: "Could not run the code in Terminal")
      }
    }
  }

  @objc func newConversation(_ sender: Any?) {
    app.openConversation(in: project)
  }

  @objc func stopSession(_ sender: Any?) {
    guard let live = session?.live else { return }

    interrupt(live) { [weak self] error in self?.report(error, as: "Claude Could Not Be Stopped") }
  }

  /// Session > Allow and Deny answer the oldest permission request, as its card's buttons would.
  @objc func allowRequest(_ sender: Any?) {
    if !content.transcript.answerOldestRequest(allow: true) { NSSound.beep() }
  }

  @objc func denyRequest(_ sender: Any?) {
    content.transcript.answerOldestRequest(allow: false)
  }

  @objc func toggleVerboseTranscript(_ sender: Any?) {
    content.transcript.isVerbose.toggle()
  }

  // MARK: Start page

  /// Keeps the start page current while it shows. A pass that finds it hidden reads nothing, which ends the loop.
  private func watchStartPage() {
    startPageWatch += 1
    keepCurrent(self) { [generation = startPageWatch] controller in
      if controller.startPageWatch == generation { controller.refreshStartPage() }
    }
  }

  /// Waiting sessions, then running ones, then unread ones, each newest first, then the rest newest first; or every session in the history.
  private func refreshStartPage() {
    let page = content.startPage
    guard !page.isHidden else { return }

    let sessions = projectSessions

    if page.showsHistory { return page.history.show(sessions) }

    let order = sessionListOrder(sessions.filter { $0 !== session })
    page.show(order.sessions, leading: order.leading)
  }

  private var projectSessions: [Session] { app.workspace.projects.first { $0.path.standardizedFileURL.path == project.path }?.sessions ?? [] }

  private func watchSidebar() {
    guard !watchesSidebar else { return }

    watchesSidebar = true
    keepCurrent(self) { $0.refreshSidebar() }
  }

  /// The sidebar lists the project's sessions as the sidebar style says, subsessions under their parent. A tab behind another reads
  /// nothing, which ends its observation, so only the tab on screen keeps its sidebar current.
  private func refreshSidebar() {
    if let window, !window.isMainWindow, let selected = window.tabGroup?.selectedWindow, selected !== window {
      watchesSidebar = false
      return
    }

    split.sidebar.show(projectSessions.filter { $0.parent == nil }, style: SidebarSettings.shared.style)
  }

  /// A session picked on the start page takes this tab's place, unless it is open in another tab or a draft is typed here.
  private func openFromStartPage(_ picked: Session) {
    let replaces = app.conversation(for: picked) == nil && content.prompt.draft.isEmpty

    app.showConversation(picked)

    if replaces { close() }
  }

  /// View > Show History, and the start page's See History and Hide History.
  @objc func toggleHistory(_ sender: Any?) {
    let page = content.startPage
    page.showsHistory.toggle()
    window?.makeFirstResponder(page.showsHistory ? page.history.outline : content.prompt.textView)
    watchStartPage()
  }

  func allowRow(_ sender: NSControl) {
    content.startPage.session(for: sender)?.answerPermission(allow: true)
  }

  func denyRow(_ sender: NSControl) {
    content.startPage.session(for: sender)?.answerPermission(allow: false)
  }

  func answerRow(_ sender: NSPopUpButton) {
    guard let label = sender.selectedItem?.representedObject as? String else { return }

    content.startPage.session(for: sender)?.answerQuestion(label)
  }

  /// A plan or several questions read in full in their own conversation.
  func reviewRow(_ sender: NSControl) {
    guard let picked = content.startPage.session(for: sender) else { return }

    openFromStartPage(picked)
  }

  // MARK: Agents and changes

  @objc func showAgents(_ sender: Any?) {
    guard agentsPopover == nil, !isClosingClick(on: content.prompt.agents) else { return }

    let list = AgentListController()
    list.onStop = { [unowned self] rows in stop(rows) }
    present(list, under: content.prompt.agents, as: \.agentsPopover)
  }

  @objc func showChanges(_ sender: Any?) {
    guard changesPopover == nil, !isClosingClick(on: content.prompt.changes) else { return }

    present(ChangeListController(), under: content.prompt.changes, as: \.changesPopover)
  }

  /// A click on a chip whose popover is open closes the popover, as any click outside it does, and the chip's action follows.
  /// A mouse-down and its mouse-up share an event number.
  private func isClosingClick(on chip: NSView) -> Bool {
    guard let closingClick, closingClick.chip === chip, let event = NSApp.currentEvent, event.type == .leftMouseUp || event.type == .leftMouseDown else { return false }

    return event.eventNumber == closingClick.event
  }

  /// Shows `list` in a popover above `chip`.
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
    let chip = notification.object as? NSPopover === agentsPopover ? content.prompt.agents : content.prompt.changes

    closingClick = NSApp.currentEvent.flatMap { $0.type == .leftMouseDown ? (chip, $0.eventNumber) : nil }
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

  /// The items of a session menu, for a blank conversation's pickers and the menu bar's. `validateMenuItem` checks the current one.
  func menuItems(_ kind: SessionMenu) -> [NSMenuItem] {
    guard let live = session?.live else { return [] }

    let items: [NSMenuItem]

    switch kind {
    case .model:
      items = (live.initializeInfo?.models ?? []).map { model in
        let item = pickItem(model.displayName, #selector(pickModel(_:)), model.value)
        item.toolTip = model.description
        return item
      }
    case .effort:
      items = (live.modelInfo?.supportedEffortLevels ?? []).map { pickItem(effortName($0), #selector(pickEffort(_:)), $0) }
    case .mode:
      // The CLI refuses to enter bypassPermissions in a session launched without it, so it is not offered.
      let modes: [PermissionMode] = live.modelInfo?.supportsAutoMode == true ? [.default, .acceptEdits, .plan, .auto] : [.default, .acceptEdits, .plan]

      items = modes.map { pickItem(modeName($0), #selector(pickPermissionMode(_:)), $0.rawValue) }
    }

    return items
  }

  /// The prompt's settings menu: the permission modes, then the model and effort in submenus.
  private func settingsMenuItems() -> [NSMenuItem] {
    func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      item.submenu = NSMenu(title: title)
      item.submenu?.items = items
      return item
    }

    let efforts = menuItems(.effort)
    return menuItems(.mode) + [.separator(), submenu("Model", menuItems(.model) + [.separator(), pickItem("Fast Mode", #selector(toggleFastMode(_:)), nil)])] + (efforts.isEmpty ? [] : [submenu("Effort", efforts)])
  }

  /// An item that picks `value` in this conversation, whichever window is key when it is chosen.
  private func pickItem(_ title: String, _ action: Selector, _ value: String?) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.representedObject = value
    return item
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

    // A mode picked for a new conversation is what the next one starts in; one picked partway through, say Plan for one question, is not.
    let isSetup = !content.picks.isHidden

    change("The Permission Mode Could Not Be Changed") { if isSetup { $0.permissionMode = mode } } with: { try await $0.setPermissionMode(mode) }
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
    // A resumed session has a live process before it has answered `initialize`.
    let canPick = live?.isRunning == true && live?.initializeInfo != nil

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
      // A model without fast mode can still turn off the flag an earlier model set.
      menuItem.state = live?.fastMode == true ? .on : .off
      return canPick && (live?.fastMode == true || live?.modelInfo?.supportsFastMode == true)
    case #selector(stopSession(_:)):
      return isBusy
    case #selector(allowRequest(_:)), #selector(denyRequest(_:)):
      let isQuestion = content.transcript.oldestRequestKind == .question
      let isAllow = menuItem.action == #selector(allowRequest(_:))
      menuItem.title = isQuestion ? (isAllow ? "Answer" : "Skip Question") : (isAllow ? "Allow" : "Deny")
      return content.transcript.oldestRequestKind != nil
    case #selector(toggleHistory(_:)):
      menuItem.title = content.startPage.showsHistory ? "Hide History" : "Show History"
      return content.showsStartPage
    case #selector(toggleVerboseTranscript(_:)):
      menuItem.title = content.transcript.isVerbose ? "Show Normal Transcript" : "Show Verbose Transcript"
      return true
    default:
      return true
    }
  }

  // MARK: Window

  func windowDidBecomeMain(_ notification: Notification) {
    watchSidebar()
    windowActiveChanged()
    markReadIfShown()
  }

  /// A conversation in the main window counts as read, also when a turn ends while it is there.
  private func markReadIfShown() {
    guard let session, window?.isMainWindow == true, session.isUnread else { return }

    do {
      try app.workspace.markRead(session)
    } catch {
      report(error, as: "The Conversation Could Not Be Marked Read")
    }
  }

  func windowDidResignMain(_ notification: Notification) {
    windowActiveChanged()
  }

  private func windowActiveChanged() {
    content.prompt.windowActiveChanged()
    content.transcript.windowActiveChanged()
  }

  func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
    state.encode(project.path as NSString, forKey: ConversationRestoration.projectKey)

    if let encodedSessionId { state.encode(encodedSessionId as NSString, forKey: ConversationRestoration.sessionKey) }
  }

  func windowDidMove(_ notification: Notification) {
    window?.saveFrame(usingName: frameName)
  }

  func windowDidResize(_ notification: Notification) {
    window?.saveFrame(usingName: frameName)
  }

  /// A conversation that has run a turn keeps running without its tab. One that never sent a prompt is discarded.
  /// A path link shows its file in a Quick Look popover pointing at the link, and a folder opens in Finder; web links open as usual.
  private func openLink(_ link: Any, at rect: NSRect) -> Bool {
    guard let url = FilePaths.target(ofLink: link, in: session?.workingDirectory ?? project) else { return false }

    var isFolder: ObjCBool = false

    if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) {
      guard let window else { return true }
      let alert = NSAlert()
      alert.messageText = "“\(url.lastPathComponent)” doesn’t exist."
      alert.informativeText = url.path
      alert.beginSheetModal(for: window)
    } else if isFolder.boolValue {
      NSWorkspace.shared.open(url)
    } else {
      quickLook(url, at: rect)
    }

    return true
  }

  private func quickLook(_ url: URL, at rect: NSRect) {
    linkPopover?.close()
    let view = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 560, height: 420), style: .normal)!
    view.previewItem = url as NSURL
    let controller = NSViewController()
    controller.view = view
    let popover = NSPopover()
    popover.behavior = .transient
    popover.contentViewController = controller
    popover.show(relativeTo: rect, of: content.transcript.textView, preferredEdge: .maxY)
    linkPopover = popover
  }

    func showPreview(of url: URL) {
    let controller = preview ?? PreviewWindowController()

    preview = controller
    controller.show(url)
  }

  // MARK: Browser

  /// The folder a file page may read, and relative addresses resolve in.
  var browserFolder: URL { session?.workingDirectory ?? project }

  /// Opens the browser's pane. The window grows to its right by the pane's width, as far as its screen allows, so the transcript keeps its width.
  func showBrowserPane(_ controller: NSViewController) {
    guard let window, !split.showsBrowser else { return }

    if let visible = window.screen?.visibleFrame {
      var frame = window.frame

      browserGrowth = max(0, min(split.browserWidth, visible.width - frame.width))
      frame.size.width += browserGrowth
      frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - frame.width))
      window.setFrame(frame, display: true)
    }

    split.showBrowser(controller)
  }

  func hideBrowserPane() {
    guard let window, split.showsBrowser else { return }

    split.hideBrowser()
    window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: window.frame.width - browserGrowth, height: window.frame.height)), display: true)
    browserGrowth = 0
  }

  /// Browser commands from the menu bar and the pane's buttons reach the browser from this window.
  override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
    browser.responds(to: action) ? browser : super.supplementalTarget(forAction: action, sender: sender)
  }

  func windowWillClose(_ notification: Notification) {
    isClosed = true
    preview?.close()
    browser.close()
    app.closed(self)

    Task {
      await sending?.value
      guard !hasSent, let session = try? await starting?.value else { return }

      discard(session)
    }
  }
}

/// Rebuilds a conversation tab from its restorable state: its project, and its session once it had a turn.
/// AppKit puts the restored windows back in their frames and tab groups.
final class ConversationRestoration: NSObject, NSWindowRestoration {
  static let projectKey = "project"
  static let sessionKey = "session"

  static func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder, completionHandler: @escaping (NSWindow?, (any Error)?) -> Void) {
    let path = state.decodeObject(of: NSString.self, forKey: projectKey) as String?
    let id = state.decodeObject(of: NSString.self, forKey: sessionKey) as String?
    nonisolated(unsafe) let done = completionHandler

    MainActor.assumeIsolated {
      guard let app = NSApp.delegate as? AppDelegate, let path else { return done(nil, nil) }

      app.restoreConversation(in: URL(filePath: path, directoryHint: .isDirectory), sessionId: id) { done($0, nil) }
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

