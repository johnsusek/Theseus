import AppKit

/// The Session menu's submenus, whose items come from the conversation in front.
enum SessionMenu: Int {
  case model = 1, effort, mode
}

/// Fills the Session menu's Model, Effort and Permission Mode submenus when the menu opens, and disables the ones with nothing to offer.
final class SessionMenuDelegate: NSObject, NSMenuDelegate {
  func menuNeedsUpdate(_ menu: NSMenu) {
    // With a popover open the key window is the popover's, and the conversation is the main window.
    // An inactive app has neither, and accessibility clients still open its menus, so the frontmost conversation answers.
    // With the Projects window in front there is no conversation to pick for.
    let front = [NSApp.keyWindow, NSApp.mainWindow].compactMap(\.self)
    let windows = front.isEmpty ? NSApp.orderedWindows : front
    let conversation = windows.lazy.compactMap { $0.windowController as? ConversationController }.first

    for item in menu.items {
      guard let submenu = item.submenu, let kind = SessionMenu(rawValue: item.tag) else { continue }

      submenu.items = conversation?.menuItems(kind) ?? []
      item.isEnabled = submenu.numberOfItems > 0
    }
  }
}

/// The menu bar. Every action goes to the responder chain, so commands follow the key window and disable when nothing takes them.
@MainActor
func makeMainMenu(recentProjects: any NSMenuDelegate, sessionMenus: any NSMenuDelegate) -> NSMenu {
  let name = "Theseus"
  let services = NSMenu(title: "Services")
  let recent = NSMenu(title: "Open Recent")
  let session = NSMenu(title: "Session")
  let window = NSMenu(title: "Window")
  let help = NSMenu(title: "Help")
  let main = NSMenu()

  recent.delegate = recentProjects
  session.delegate = sessionMenus

  main.items = [
    menu(name, [
      item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
      .separator(),
      submenu(services),
      .separator(),
      item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"),
      item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
      item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
      .separator(),
      item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q")
    ]),
    menu("File", [
      item("New Conversation", #selector(AppDelegate.newConversation(_:)), "n"),
      item("Open Project…", #selector(AppDelegate.openProject(_:)), "o"),
      submenu(recent),
      .separator(),
      item("Close", #selector(NSWindow.performClose(_:)), "w")
    ]),
    menu("Edit", [
      item("Undo", Selector(("undo:")), "z"),
      item("Redo", Selector(("redo:")), "z", [.command, .shift]),
      .separator(),
      item("Cut", #selector(NSText.cut(_:)), "x"),
      item("Copy", #selector(NSText.copy(_:)), "c"),
      item("Paste", #selector(NSText.paste(_:)), "v"),
      item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
      item("Delete", #selector(NSText.delete(_:))),
      item("Select All", #selector(NSText.selectAll(_:)), "a"),
      .separator(),
      menu("Find", [
        find("Find…", .showFindInterface, "f"),
        find("Find and Replace…", .showReplaceInterface, "f", [.command, .option]),
        find("Find Next", .nextMatch, "g"),
        find("Find Previous", .previousMatch, "g", [.command, .shift]),
        find("Use Selection for Find", .setSearchString, "e"),
        item("Jump to Selection", #selector(NSResponder.centerSelectionInVisibleArea(_:)), "j")
      ]),
      menu("Spelling and Grammar", [
        item("Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":"),
        item("Check Document Now", #selector(NSText.checkSpelling(_:)), ";"),
        .separator(),
        item("Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:))),
        item("Check Grammar With Spelling", #selector(NSTextView.toggleGrammarChecking(_:))),
        item("Correct Spelling Automatically", #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)))
      ]),
      menu("Substitutions", [
        item("Show Substitutions", #selector(NSTextView.orderFrontSubstitutionsPanel(_:))),
        .separator(),
        item("Smart Copy/Paste", #selector(NSTextView.toggleSmartInsertDelete(_:))),
        item("Smart Quotes", #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:))),
        item("Smart Dashes", #selector(NSTextView.toggleAutomaticDashSubstitution(_:))),
        item("Smart Links", #selector(NSTextView.toggleAutomaticLinkDetection(_:))),
        item("Data Detectors", #selector(NSTextView.toggleAutomaticDataDetection(_:))),
        item("Text Replacement", #selector(NSTextView.toggleAutomaticTextReplacement(_:)))
      ]),
      menu("Transformations", [
        item("Make Upper Case", #selector(NSResponder.uppercaseWord(_:))),
        item("Make Lower Case", #selector(NSResponder.lowercaseWord(_:))),
        item("Capitalize", #selector(NSResponder.capitalizeWord(_:)))
      ]),
      menu("Speech", [
        item("Start Speaking", #selector(NSTextView.startSpeaking(_:))),
        item("Stop Speaking", #selector(NSTextView.stopSpeaking(_:)))
      ])
    ]),
    menu("View", [
      item("Show Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
      item("Sidebar Configuration", #selector(AppDelegate.showSidebarConfiguration(_:)), "s", [.command, .option]),
      .separator(),
      item("Show Agents", #selector(ConversationController.showAgents(_:)), "a", [.command, .control]),
      item("Show Changes", #selector(ConversationController.showChanges(_:)), "c", [.command, .control]),
      item("Show Verbose Transcript", #selector(ConversationController.toggleVerboseTranscript(_:))),
      item("Show History", #selector(ConversationController.toggleHistory(_:)), "y"),
      .separator(),
      item("Show Browser", #selector(Browser.toggleBrowser(_:)), "b", [.command, .option]),
      item("Detach Browser", #selector(Browser.toggleBrowserDetached(_:))),
      item("Show Preview", #selector(Preview.togglePreview(_:))),
      item("Detach Preview", #selector(Preview.togglePreviewDetached(_:))),
      .separator(),
      item("Show Archived Sessions", #selector(ProjectsWindowController.toggleArchivedSessions(_:))),
      menu("Filter", [item("All Sessions", #selector(ProjectsWindowController.filterSessions(_:)), tag: -1), .separator()]
        + RowStatus.allCases.map { item($0.title, #selector(ProjectsWindowController.filterSessions(_:)), tag: $0.rawValue) }
        + [.separator(), .sectionHeader(title: "Updated")]
        + UpdatedRange.allCases.map { item($0.title, #selector(ProjectsWindowController.filterUpdated(_:)), tag: $0.rawValue) }),
      .separator(),
      item("Show Tab Bar", #selector(NSWindow.toggleTabBar(_:))),
      item("Show All Tabs", #selector(NSWindow.toggleTabOverview(_:)), "\\", [.command, .shift]),
      .separator(),
      item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
    ]),
    menu("Browser", [
      item("Open Location…", #selector(Browser.openBrowserLocation(_:)), "l"),
      item("New Tab", #selector(Browser.newBrowserTab(_:)), "t", [.command, .option]),
      item("Close Tab", #selector(Browser.closeBrowserTab(_:)), "w", [.command, .option]),
      .separator(),
      item("Back", #selector(Browser.browserBack(_:)), "["),
      item("Forward", #selector(Browser.browserForward(_:)), "]"),
      item("Reload Page", #selector(Browser.reloadBrowserPage(_:)), "r")
    ]),
    submenu(session),
    submenu(window),
    submenu(help)
  ]

  session.items = [
    item("Allow", #selector(ConversationController.allowRequest(_:)), "\r"),
    item("Deny", #selector(ConversationController.denyRequest(_:)), "d"),
    item("Show Request", #selector(ProjectsWindowController.showRequest(_:)), "y", [.command, .option]),
    .separator(),
    item("Open", #selector(ProjectsWindowController.openSession(_:))),
    item("Pin", #selector(ProjectsWindowController.togglePinned(_:))),
    item("Rename…", #selector(ProjectsWindowController.renameSession(_:))),
    item("Archive", #selector(ProjectsWindowController.toggleArchived(_:))),
    .separator(),
    item("Stop", #selector(ConversationController.stopSession(_:)), "."),
    .separator(),
    sessionSubmenu("Model", .model),
    sessionSubmenu("Effort", .effort),
    item("Fast Mode", #selector(ConversationController.toggleFastMode(_:))),
    sessionSubmenu("Permission Mode", .mode)
  ]

  window.items = [
    item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
    item("Zoom", #selector(NSWindow.performZoom(_:))),
    .separator(),
    item("Projects", #selector(AppDelegate.showProjects(_:)), "0", [.command, .shift]),
    item("Private Desktop", #selector(AppDelegate.showPrivateDesktop(_:))),
    .separator(),
    item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
  ]

  NSApp.servicesMenu = services
  NSApp.windowsMenu = window
  NSApp.helpMenu = help
  return main
}

@MainActor
private func item(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
  let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
  item.keyEquivalentModifierMask = modifiers
  item.tag = tag
  return item
}

/// The text finder reads which command to run from the item's tag.
@MainActor
private func find(_ title: String, _ action: NSTextFinder.Action, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
  item(title, #selector(NSResponder.performTextFinderAction(_:)), key, modifiers, tag: action.rawValue)
}

@MainActor
private func submenu(_ menu: NSMenu) -> NSMenuItem {
  let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
  item.submenu = menu
  return item
}

@MainActor
private func sessionSubmenu(_ title: String, _ kind: SessionMenu) -> NSMenuItem {
  let item = submenu(NSMenu(title: title))
  item.tag = kind.rawValue
  return item
}

@MainActor
private func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
  let menu = NSMenu(title: title)
  menu.items = items
  return submenu(menu)
}
