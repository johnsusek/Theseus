import AppKit
import ClaudeEngine
import ClaudeWorkspace

extension NSToolbarItem.Identifier {
  static let newSession = NSToolbarItem.Identifier("newSession")
  static let statusFilter = NSToolbarItem.Identifier("statusFilter")
  static let answer = NSToolbarItem.Identifier("answer")
  static let search = NSToolbarItem.Identifier("search")
}

/// The Projects window's commands. Menu bar items act on the selection; context menu items carry the sessions they were opened on,
/// because the rows can move under an open menu.
extension ProjectsWindowController: NSMenuDelegate, NSMenuItemValidation, NSToolbarDelegate, NSSearchFieldDelegate, RowRequestActions {
  // MARK: Targets

  /// The sessions a command acts on: a context menu item's own, else the selection.
  private func targets(_ sender: Any?) -> [Session] {
    (sender as? NSMenuItem)?.representedObject as? [Session] ?? selectedSessions
  }

  /// The sessions among `sessions` that wait on a permission request, which Allow and Deny answer.
  private func asking(_ sessions: [Session]) -> [(Session, PermissionRequest)] {
    sessions.compactMap { session in session.request.flatMap { RequestKind($0) == .permission ? (session, $0) : nil } }
  }

  private func session(for control: NSView) -> Session? {
    let row = outline.row(for: control)
    return row >= 0 ? outline.item(atRow: row) as? Session : nil
  }

  // MARK: Opening

  @objc func openSession(_ sender: Any?) {
    let sessions = targets(sender)

    // Return on a group row opens or closes it.
    if sessions.isEmpty {
      for case let group as GroupItem in selectedItems { toggle(group) }
      return
    }

    for session in sessions { app.showConversation(session) }
  }

  @objc func openClicked(_ sender: Any?) {
    let row = outline.clickedRow
    guard row >= 0, let item = outline.item(atRow: row) else { return }

    if let session = item as? Session { return app.showConversation(session) }

    if let group = item as? GroupItem { toggle(group) }
  }

  private func toggle(_ group: GroupItem) {
    if outline.isItemExpanded(group) {
      outline.collapseItem(group)
    } else {
      outline.expandItem(group)
    }
  }

  /// The toolbar button: a new session in the selected row's project, else the last project.
  @objc func newSession(_ sender: Any?) {
    guard let project = selectedProject else { return app.newConversation(sender) }

    app.openConversation(in: project.path)
  }

  @objc func newSessionIn(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? URL else { return }

    app.openConversation(in: url)
  }

  private var selectedProject: Project? {
    selectedItems.lazy.compactMap { ($0 as? Session)?.project ?? ($0 as? GroupItem)?.project }.first
  }

  // MARK: Requests

  @objc func allowRequest(_ sender: Any?) {
    answer(selectedSessions, allow: true)
  }

  @objc func denyRequest(_ sender: Any?) {
    answer(selectedSessions, allow: false)
  }

  /// Answers the permission requests among `sessions`, as their cards' buttons would with the checkbox off.
  private func answer(_ sessions: [Session], allow: Bool) {
    for (session, request) in asking(sessions) { session.live?.respond(to: request, with: permissionDecision(for: request, allow: allow, always: false)) }
  }

  /// Session > Show Request, Command-Y: the selected session's request in full.
  @objc func showRequest(_ sender: Any?) {
    guard selectedSessions.count == 1 else { return }

    peek(selectedSessions[0])
  }

  func allowRow(_ sender: NSControl) {
    answer([session(for: sender)].compactMap(\.self), allow: true)
  }

  func denyRow(_ sender: NSControl) {
    answer([session(for: sender)].compactMap(\.self), allow: false)
  }

  func answerRow(_ sender: NSPopUpButton) {
    guard let session = session(for: sender), let request = session.request, let question = request.questions.first, let label = sender.selectedItem?.representedObject as? String else { return }

    session.live?.respond(to: request, with: .answer([question.question: label], to: request))
  }

  /// Review opens a plan's conversation, where the plan reads in full; Answer… shows several questions in the popover.
  func reviewRow(_ sender: NSControl) {
    guard let session = session(for: sender), let request = session.request else { return }

    if RequestKind(request) == .plan { return app.showConversation(session) }

    peek(session)
  }

  // MARK: Session commands

  @objc func togglePinned(_ sender: Any?) {
    let sessions = targets(sender)
    let pin = !sessions.allSatisfy(\.isPinned)

    perform("The Session Could Not Be Pinned") { for session in sessions { try workspace.setPinned(session, pin) } }
  }

  @objc func toggleArchived(_ sender: Any?) {
    let sessions = targets(sender)
    let archive = !sessions.allSatisfy(\.isArchived)

    perform("The Session Could Not Be Archived") { for session in sessions { try workspace.setArchived(session, archive) } }
  }

  @objc func renameSession(_ sender: Any?) {
    guard let window, let session = targets(sender).first else { return }

    let alert = NSAlert()
    let field = NSTextField(string: session.rowTitle)

    field.frame = NSRect(x: 0, y: 0, width: 300, height: 22)
    alert.messageText = "Rename Conversation"
    alert.accessoryView = field
    alert.addButton(withTitle: "Rename")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field

    alert.beginSheetModal(for: window) { [unowned self] response in
      guard response == .alertFirstButtonReturn else { return }

      let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      perform("The Session Could Not Be Renamed") { try workspace.rename(session, to: title.isEmpty ? nil : title) }
    }
  }

  /// Session > Stop: interrupts the turn of every selected session that is working.
  @objc func stopSession(_ sender: Any?) {
    for live in targets(sender).compactMap(\.live) where live.isRunning && live.state != .idle {
      interrupt(live) { [weak self] error in self?.report(error, as: "Claude Could Not Be Stopped") }
    }
  }

  private func perform(_ failure: String, _ change: () throws -> Void) {
    do {
      try change()
    } catch {
      report(error, as: failure)
    }
  }

  private func report(_ error: any Error, as title: String) {
    showError(error, as: title, on: window?.isVisible == true ? window : nil)
  }

  // MARK: View commands

  @objc func toggleArchivedSessions(_ sender: Any?) {
    query.showsArchived.toggle()
    refresh()
  }

  /// The toolbar's segments and View > Filter's items: 0 shows every session, the rest one status each.
  @objc func filterSessions(_ sender: Any?) {
    let index = (sender as? NSSegmentedControl)?.selectedSegment ?? (sender as? NSMenuItem)?.tag ?? 0

    query.filter = index == 0 ? nil : RowStatus(rawValue: index - 1)
    filter.selectedSegment = index
    refresh()
  }

  @objc func toggleColumn(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String, let column = outline.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id)) else { return }

    column.isHidden.toggle()
    reconfigureVisible()
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    let sessions = targets(menuItem)

    switch menuItem.action {
    case #selector(openSession(_:)):
      return !sessions.isEmpty || selectedItems.contains { $0 is GroupItem }
    case #selector(togglePinned(_:)):
      menuItem.title = !sessions.isEmpty && sessions.allSatisfy(\.isPinned) ? "Unpin" : "Pin"
      return !sessions.isEmpty
    case #selector(toggleArchived(_:)):
      menuItem.title = !sessions.isEmpty && sessions.allSatisfy(\.isArchived) ? "Unarchive" : "Archive"
      return !sessions.isEmpty
    case #selector(renameSession(_:)):
      return sessions.count == 1
    case #selector(stopSession(_:)):
      return sessions.contains { $0.live.map { $0.isRunning && $0.state != .idle } ?? false }
    case #selector(allowRequest(_:)), #selector(denyRequest(_:)):
      return !asking(sessions).isEmpty
    case #selector(showRequest(_:)):
      return sessions.count == 1 && sessions[0].request != nil
    case #selector(toggleArchivedSessions(_:)):
      menuItem.title = query.showsArchived ? "Hide Archived Sessions" : "Show Archived Sessions"
      return true
    case #selector(filterSessions(_:)):
      menuItem.state = menuItem.tag == filter.selectedSegment ? .on : .off
      return true
    default:
      return true
    }
  }

  // MARK: Menus

  func menuNeedsUpdate(_ menu: NSMenu) {
    if menu === outline.menu { return fillRowMenu(menu) }

    if menu === outline.headerView?.menu {
      menu.items = outline.tableColumns.dropFirst().map { column in
        let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = column.identifier.rawValue
        item.state = column.isHidden ? .off : .on
        return item
      }
      return
    }

    // The New Session button's menu.
    menu.items = workspace.projects.map { project in
      let item = NSMenuItem(title: project.name, action: #selector(newSessionIn(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = project.path
      item.toolTip = (project.path.path as NSString).abbreviatingWithTildeInPath
      return item
    } + [.separator(), NSMenuItem(title: "Choose Folder…", action: #selector(AppDelegate.openProject(_:)), keyEquivalent: "")]
  }

  /// The clicked row alone when it is outside the selection, the whole selection when it is inside.
  private func fillRowMenu(_ menu: NSMenu) {
    let clicked = outline.clickedRow
    var items: [Any] = []

    if clicked >= 0, let item = outline.item(atRow: clicked) { items = outline.selectedRowIndexes.contains(clicked) ? selectedItems : [item] }

    let sessions = items.compactMap { $0 as? Session }

    func entry(_ title: String, _ action: Selector) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
      item.target = self
      item.representedObject = sessions
      return item
    }

    guard sessions.isEmpty, let project = (items.first as? GroupItem)?.project else {
      menu.items = items.isEmpty ? [] : [entry("Open", #selector(openSession(_:))), .separator(), entry("Pin", #selector(togglePinned(_:))), entry("Rename…", #selector(renameSession(_:))), entry("Archive", #selector(toggleArchived(_:))), .separator(), entry("Stop", #selector(stopSession(_:)))]
      return
    }

    let item = NSMenuItem(title: "New Session", action: #selector(newSessionIn(_:)), keyEquivalent: "")
    item.target = self
    item.representedObject = project.path
    menu.items = [item]
  }

  // MARK: Toolbar

  func makeToolbar() {
    let toolbar = NSToolbar(identifier: "Projects")
    let projects = NSMenu()

    projects.delegate = self
    newItem.menu = projects
    newItem.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "New Session")
    newItem.label = "New Session"
    newItem.target = self
    newItem.action = #selector(newSession(_:))
    newItem.showsIndicator = true

    let statuses: [(String, String)] = [("tray.full", "All Sessions")] + RowStatus.allCases.map { ($0.symbol, $0.title) }
    filter.segmentCount = statuses.count
    filter.trackingMode = .selectOne
    filter.target = self
    filter.action = #selector(filterSessions(_:))

    for (index, status) in statuses.enumerated() {
      filter.setImage(NSImage(systemSymbolName: status.0, accessibilityDescription: status.1), forSegment: index)
      filter.setToolTip(status.1, forSegment: index)
    }

    filter.selectedSegment = 0
    filter.setAccessibilityLabel("Show Sessions by Status")

    for (item, symbol, title, action) in [(denyItem, "xmark", "Deny", #selector(denyRequest(_:))), (allowItem, "checkmark", "Allow", #selector(allowRequest(_:)))] {
      item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
      item.label = title
      item.toolTip = "\(title) the Selected Requests (\(title == "Deny" ? "Command-D" : "Command-Return"))"
      item.target = self
      item.action = action
      item.autovalidates = false
    }

    searchItem.searchField.delegate = self
    searchItem.searchField.placeholderString = "Search"

    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = true
    toolbar.autosavesConfiguration = true
    window?.toolbar = toolbar
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.newSession, .statusFilter, .flexibleSpace, .answer, .search]
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar) + [.space]
  }

  func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
    switch itemIdentifier {
    case .newSession:
      return newItem
    case .statusFilter:
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      item.view = filter
      item.label = "Show"
      item.toolTip = "Show Sessions by Status"
      return item
    case .answer:
      let group = NSToolbarItemGroup(itemIdentifier: itemIdentifier)
      group.subitems = [denyItem, allowItem]
      group.label = "Answer"
      return group
    case .search:
      return searchItem
    default:
      return nil
    }
  }

  /// Deny and Allow follow the selection's permission requests; New Session names the project it opens in.
  func updateToolbar() {
    let canAnswer = !asking(selectedSessions).isEmpty

    denyItem.isEnabled = canAnswer
    allowItem.isEnabled = canAnswer
    newItem.toolTip = selectedProject.map { "New Session in \($0.name)" } ?? "New Session"
  }

  // MARK: Search

  func controlTextDidChange(_ notification: Notification) {
    query.search = searchItem.searchField.stringValue
    refresh()
  }

  /// Up and Down in the search field move the selection while typing continues.
  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    guard selector == #selector(NSResponder.moveUp(_:)) || selector == #selector(NSResponder.moveDown(_:)), outline.numberOfRows > 0 else { return false }

    let current = outline.selectedRowIndexes.last ?? -1
    let next = selector == #selector(NSResponder.moveUp(_:)) ? max(current - 1, 0) : min(current + 1, outline.numberOfRows - 1)

    outline.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
    outline.scrollRowToVisible(next)
    return true
  }
}
