import AppKit
import ClaudeWorkspace
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  let workspace: Workspace
  let previewServers = PreviewServers()
  let privateDesktop = PrivateDesktop(accounts: DesktopTools.readAccounts)
  private lazy var desktopWindow = DesktopWindowController(desktop: privateDesktop)
  private var conversations: [ConversationController] = []
  private let sessionMenus = SessionMenuDelegate()
  private var projectPanel: NSOpenPanel?
  private var projects: ProjectsWindowController?
  private lazy var sidebarConfiguration = SidebarConfigurationController()

  /// A headless check passes a workspace that runs a stand-in CLI and keeps its records elsewhere.
  init(workspace: Workspace = Workspace(recordsDirectory: URL.applicationSupportDirectory.appending(path: "Theseus"))) {
    self.workspace = workspace
    super.init()
    Markdown.codeButtons = CodeButtonsView.attachment
    workspace.hostServers = { [unowned self] session in HostTools.servers(for: session, app: self) }

    // Sessions launched while the Private Desktop is on are told about it.
    keepCurrent(self) { app in
      let desktop = app.privateDesktop.isOn ? "\n" + DesktopTools.prompt(user: app.privateDesktop.user) : ""
      app.workspace.appendSystemPrompt = HostTools.prompt + desktop
    }
  }

  func applicationWillFinishLaunching(_ notification: Notification) {
    NSApp.mainMenu = makeMainMenu(recentProjects: self, sessionMenus: sessionMenus)
  }

  /// Opening the Projects window scans the transcripts itself.
  func applicationDidFinishLaunching(_ notification: Notification) {
    UNUserNotificationCenter.current().delegate = self
    privateDesktop.start()

    // Follows the sessions a terminal or another app has open, and which ones the desktop app has shown.
    Task {
      while true {
        await workspace.readOwners()
        await workspace.readDesktop()
        try? await Task.sleep(for: .seconds(1))
      }
    }

    if UserDefaults.standard.bool(forKey: "ProjectsOpen") { return showProjects(nil) }

    rescan()
  }

  private func rescan() {
    Task {
      do {
        try await workspace.reload()
      } catch {
        log.error("Could not scan the Claude projects: \(error.localizedDescription)")
      }
    }
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  /// AppKit asks for an untitled file when the app launches without a folder to open.
  func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
    newConversation(nil)
    return true
  }

  /// A click on the Dock icon: brings back a minimized conversation, or opens one when no window is showing.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    let windows = conversations.compactMap(\.window)

    // A hidden app's windows are not visible either; unhiding brings them back.
    if sender.isHidden || projectPanel != nil || projects?.window?.isVisible == true || windows.contains(where: \.isVisible) { return false }

    if let minimized = windows.first(where: \.isMiniaturized) {
      minimized.deminiaturize(nil)
    } else {
      newConversation(nil)
    }

    return false
  }

  /// A folder opened from Finder or the Dock answers the Open panel the launch put up, so the panel goes.
  func application(_ application: NSApplication, open urls: [URL]) {
    let folders = urls.filter(\.hasDirectoryPath)
    guard !folders.isEmpty else { return }

    projectPanel?.cancel(nil)

    for url in folders { openConversation(in: url) }
  }

  /// Closes every `claude` process before the app exits, so none is orphaned. Quitting mid-turn stops that turn, so it asks first.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let running = workspace.projects.flatMap(\.sessions).compactMap(\.live).filter(\.isRunning)
    let working = running.filter { $0.state != .idle }.count

    if working > 0 {
      let alert = NSAlert()
      alert.messageText = working == 1 ? "A conversation is still running." : "\(working) conversations are still running."
      alert.informativeText = "Quitting Theseus stops \(working == 1 ? "its turn" : "their turns") where \(working == 1 ? "it is" : "they are"). You can resume \(working == 1 ? "it" : "them") later."
      alert.addButton(withTitle: "Quit")
      alert.addButton(withTitle: "Cancel")

      if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
    }

    let engines = running.map(\.engine)
    guard !engines.isEmpty else { return .terminateNow }

    Task {
      await withTaskGroup(of: Void.self) { group in
        for engine in engines {
          group.addTask { await engine.close(timeout: .seconds(2)) }
        }
      }

      sender.reply(toApplicationShouldTerminate: true)
    }

    return .terminateLater
  }

  /// Dev servers the browser started end with the app.
  func applicationWillTerminate(_ notification: Notification) { previewServers.stopAll() }

  // MARK: Projects

  /// Opens a blank conversation in `folder`: a new tab in the project's window when it has one.
  func openConversation(in folder: URL) {
    let project = folder.standardizedFileURL
    let controller = ConversationController(app: self, project: project)

    conversations.append(controller)
    controller.open()
    UserDefaults.standard.set(project.path, forKey: "LastProject")
    NSDocumentController.shared.noteNewRecentDocumentURL(project)
  }

  /// The scan restored conversations wait for, so they can find their sessions.
  private lazy var firstScan = Task { [workspace] in try? await workspace.reload() }

  /// A conversation tab coming back after a relaunch. A session that no longer exists comes back as a blank conversation,
  /// and a project folder that no longer exists does not come back.
  func restoreConversation(in folder: URL, sessionId: String?, done: @escaping (NSWindow?) -> Void) {
    let project = folder.standardizedFileURL
    var isFolder: ObjCBool = false
    guard FileManager.default.fileExists(atPath: project.path, isDirectory: &isFolder), isFolder.boolValue else { return done(nil) }

    nonisolated(unsafe) let done = done

    Task {
      var session: Session?

      if let sessionId {
        await firstScan.value
        session = workspace.session(sessionId)
      }

      let controller = ConversationController(app: self, project: project, session: session)
      conversations.append(controller)
      controller.retitle()
      done(controller.window)
    }
  }

  /// Brings the session's tab forward, or opens it as a new tab in its project's window.
  func showConversation(_ session: Session) {
    if let open = conversation(for: session) { return open.window?.makeKeyAndOrderFront(nil) ?? () }

    let controller = ConversationController(app: self, project: session.project?.path ?? session.workingDirectory, session: session)
    conversations.append(controller)
    controller.open()
  }

  /// Window > Projects. Opening it rescans the transcripts, which picks up sessions run outside the app.
  @objc func showProjects(_ sender: Any?) {
    let controller = projects ?? ProjectsWindowController(app: self)

    projects = controller
    controller.showWindow(sender)
    rescan()
  }

  /// View > Sidebar Configuration.
  @objc func showSidebarConfiguration(_ sender: Any?) {
    sidebarConfiguration.showWindow(sender)
  }

  func conversation(for session: Session) -> ConversationController? { conversations.first { $0.session === session } }

  func closed(_ controller: ConversationController) {
    conversations.removeAll { $0 === controller }
    if let session = controller.session { privateDesktop.release(session) }
  }

  /// Window > Private Desktop.
  @objc func showPrivateDesktop(_ sender: Any?) {
    desktopWindow.showWindow(sender)
  }

  /// File > New Conversation with no project window in front: the last project, or the Open Project panel.
  @objc func newConversation(_ sender: Any?) {
    var isFolder: ObjCBool = false

    guard let path = UserDefaults.standard.string(forKey: "LastProject"), FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else { return openProject(sender) }

    openConversation(in: URL(filePath: path, directoryHint: .isDirectory))
  }

  @objc func openProject(_ sender: Any?) {
    if let projectPanel { return projectPanel.makeKeyAndOrderFront(sender) }

    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    projectPanel = panel

    Task {
      let response = await panel.begin()
      projectPanel = nil
      guard response == .OK, let url = panel.url else { return }

      openConversation(in: url)
    }
  }

  @objc func openRecentProject(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? URL else { return }

    openConversation(in: url)
  }

  // MARK: Open Recent

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()

    for url in NSDocumentController.shared.recentDocumentURLs {
      let item = menu.addItem(withTitle: url.lastPathComponent, action: #selector(openRecentProject(_:)), keyEquivalent: "")
      let icon = NSWorkspace.shared.icon(forFile: url.path)

      icon.size = NSSize(width: 16, height: 16)
      item.image = icon
      item.representedObject = url
      item.toolTip = url.path
    }

    if menu.numberOfItems > 0 { menu.addItem(.separator()) }

    menu.addItem(withTitle: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "").target = NSDocumentController.shared
  }

  /// The menu has no shortcuts, so AppKit need not rebuild it to look for one on every key press.
  func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>, action: UnsafeMutablePointer<Selector?>) -> Bool { false }
}

/// Notifications the model posts with the notify tool. Clicking one brings its conversation forward.
extension AppDelegate: UNUserNotificationCenterDelegate {
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    let id = response.notification.request.content.userInfo["session"] as? String

    await MainActor.run {
      guard let id, let session = workspace.session(id) else { return }

      NSApp.activate()
      showConversation(session)
    }
  }

  /// Shown while Theseus is active too, unless the conversation it is about is the key window.
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
    let id = notification.request.content.userInfo["session"] as? String

    return await MainActor.run {
      let isKey = id.flatMap { workspace.session($0) }.flatMap { conversation(for: $0)?.window?.isKeyWindow } == true
      return isKey ? [] : [.banner, .sound]
    }
  }
}
