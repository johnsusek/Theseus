import AppKit
import ClaudeWorkspace

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  let workspace: Workspace
  private var conversations: [ConversationController] = []
  private let sessionMenus = SessionMenuDelegate()
  private var projectPanel: NSOpenPanel?

  /// A headless check passes a workspace that runs a stand-in CLI and keeps its records elsewhere.
  init(workspace: Workspace = Workspace(recordsDirectory: URL.applicationSupportDirectory.appending(path: "Theseus"))) {
    self.workspace = workspace
  }

  func applicationWillFinishLaunching(_ notification: Notification) {
    NSApp.mainMenu = makeMainMenu(recentProjects: self, sessionMenus: sessionMenus)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
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

  /// A click on the Dock icon. AppKit's own handling does not count panels as visible windows, and every conversation is one,
  /// so it would open another conversation on each click.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    let windows = conversations.compactMap(\.window)

    // A hidden app's windows are not visible either; unhiding brings them back.
    if sender.isHidden || projectPanel != nil || windows.contains(where: \.isVisible) { return false }

    if let minimized = windows.first(where: \.isMiniaturized) {
      minimized.deminiaturize(nil)
    } else {
      newConversation(nil)
    }

    return false
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls where url.hasDirectoryPath { openConversation(in: url) }
  }

  /// Closes every `claude` process before the app exits, so none is orphaned.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let engines = workspace.projects.flatMap(\.sessions).compactMap(\.live).filter(\.isRunning).map(\.engine)
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

  func closed(_ controller: ConversationController) {
    conversations.removeAll { $0 === controller }
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
