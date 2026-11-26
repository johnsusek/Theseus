import AppKit
import ClaudeEngine
import ClaudeWorkspace

/// The outline's columns, in their default order. The raw value is the column identifier and its sort key.
enum ProjectsColumn: String, CaseIterable {
  case title, status, tasks, changes, context, location, updated

  var heading: String { ["Name", "Activity", "Tasks", "Changes", "Context", "Location", "Updated"][Self.allCases.firstIndex(of: self) ?? 0] }
  var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }
}

/// Pinned, or a project, as an outline item. The window keeps one per id so the outline sees the same object across reloads.
final class GroupItem {
  let id: String
  var project: Project?
  var sessions: [Session] = []

  init(id: String) {
    self.id = id
  }
}

/// Return opens the selection, Space shows the selected row's request and Esc closes it.
final class ProjectsOutlineView: NSOutlineView {
  var onReturn: () -> Void = {}
  var onSpace: () -> Bool = { false }
  var onEscape: () -> Bool = { false }

  override func keyDown(with event: NSEvent) {
    // Return and Enter.
    if event.keyCode == 36 || event.keyCode == 76 { return onReturn() }

    if event.keyCode == 53, onEscape() { return }

    if event.charactersIgnoringModifiers == " ", event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty, onSpace() { return }

    super.keyDown(with: event)
  }
}

/// Every session in every project, grouped by project with Pinned on top, and the one place to answer a request without opening its conversation.
final class ProjectsWindowController: NSWindowController, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSPopoverDelegate {
  unowned let app: AppDelegate
  let outline = ProjectsOutlineView()
  var query = ProjectsQuery(saved: UserDefaults.standard.dictionary(forKey: "ProjectsQuery") ?? [:]) {
    didSet { UserDefaults.standard.set(query.saved, forKey: "ProjectsQuery") }
  }
  /// The top level as shown.
  private(set) var groups: [GroupItem] = []
  private var groupItems: [String: GroupItem] = [:]
  /// Ids of the groups the user collapsed. Every other group opens expanded.
  private var collapsed = Set(UserDefaults.standard.stringArray(forKey: "ProjectsCollapsed") ?? [])
  private var isReloading = false
  /// Menus open anywhere in the app. Rows wait to be rebuilt until none is, so an open menu keeps its control.
  private var openMenus = 0
  /// Counts the times the window started watching the workspace, so only the newest pass runs and a closed window's pass ends.
  private var watching = 0
  private var isWatching = false
  private(set) var popover: NSPopover?
  /// The session whose request the popover shows.
  private weak var peeked: Session?
  private var ticker: Timer?
  let filter = NSSegmentedControl()
  let updatedFilter = NSPopUpButton()
  let newItem = NSMenuToolbarItem(itemIdentifier: .newSession)
  let denyItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("deny"))
  let allowItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("allow"))
  let searchItem = NSSearchToolbarItem(itemIdentifier: .search)

  var workspace: Workspace { app.workspace }
  var selectedItems: [Any] { outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) } }
  var selectedSessions: [Session] { selectedItems.compactMap { $0 as? Session } }

  init(app: AppDelegate) {
    self.app = app
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 660), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    super.init(window: window)

    window.title = "Projects"
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.contentMinSize = NSSize(width: 640, height: 280)
    window.toolbarStyle = .unified
    window.delegate = self
    window.center()
    window.setFrameAutosaveName("Projects")

    let scroll = NSScrollView()
    scroll.documentView = outline
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    window.contentView = scroll
    window.initialFirstResponder = outline

    makeOutline()
    makeToolbar()
    NotificationCenter.default.addObserver(self, selector: #selector(menuOpened(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(menuClosed(_:)), name: NSMenu.didEndTrackingNotification, object: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("ProjectsWindowController is built in code") }

  private func makeOutline() {
    for column in ProjectsColumn.allCases { outline.addTableColumn(column.makeTableColumn()) }

    outline.outlineTableColumn = outline.tableColumns.first
    outline.style = .inset
    outline.usesAlternatingRowBackgroundColors = true
    outline.rowHeight = 26
    outline.allowsMultipleSelection = true
    outline.allowsColumnReordering = true
    outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    outline.autosaveName = "ProjectsColumns"
    outline.autosaveTableColumns = true
    outline.sortDescriptors = query.sortOrder
    outline.dataSource = self
    outline.delegate = self
    outline.target = self
    outline.doubleAction = #selector(openClicked(_:))
    outline.onReturn = { [unowned self] in openSession(nil) }
    outline.onEscape = { [unowned self] in
      guard let popover else { return false }

      popover.close()
      return true
    }
    outline.onSpace = { [unowned self] in
      guard selectedSessions.count == 1, selectedItems.count == 1, selectedSessions[0].request != nil else { return false }

      peek(selectedSessions[0])
      return true
    }
    outline.setAccessibilityLabel("Sessions")

    let rowMenu = NSMenu()
    rowMenu.delegate = self
    outline.menu = rowMenu

    let columnMenu = NSMenu()
    columnMenu.delegate = self
    outline.headerView?.menu = columnMenu
  }

  // MARK: Refresh

  /// Keeps the outline current while the window is open, and the Updated column's relative times and the Updated filter with it.
  func watch() {
    watching += 1
    isWatching = true
    ticker?.invalidate()
    ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    keepCurrent(self) { [generation = watching] controller in
      if controller.watching == generation { controller.refresh() }
    }
  }

  /// Rebuilds the outline when its rows changed and otherwise updates the cells on screen. Runs again whenever anything it read changes.
  func refresh() {
    let shown = query.groups(workspace.projects)
    let unchanged = shown.map(\.id) == groups.map(\.id) && zip(shown, groups).allSatisfy { new, old in new.sessions.map(ObjectIdentifier.init) == old.sessions.map(ObjectIdentifier.init) }

    window?.subtitle = tally(workspace.projects.flatMap(\.sessions).map(\.rowStatus))

    // Rebuilding the rows would take the popover's anchor or an open menu's control away; they catch up when it closes.
    if unchanged || popover != nil || openMenus > 0 {
      reconfigureVisible()
    } else {
      groups = shown.map { group in
        let item = groupItems[group.id] ?? GroupItem(id: group.id)
        item.project = group.project
        item.sessions = group.sessions
        groupItems[group.id] = item
        return item
      }
      reload()
    }

    updateToolbar()

    // The request was answered here, in its conversation, or withdrawn.
    if let detail = popover?.contentViewController as? RequestDetailController, peeked?.request?.requestId != detail.request.requestId { popover?.close() }
  }

  /// Reloads the rows, keeping the selection on the same items and each group open or closed as the user left it.
  private func reload() {
    let selected = Set(selectedItems.map { ObjectIdentifier($0 as AnyObject) })

    isReloading = true
    outline.reloadData()

    for group in groups {
      if collapsed.contains(group.id) {
        outline.collapseItem(group)
      } else {
        outline.expandItem(group)
      }
    }

    isReloading = false

    let rows = (0..<outline.numberOfRows).filter { row in outline.item(atRow: row).map { selected.contains(ObjectIdentifier($0 as AnyObject)) } ?? false }
    outline.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
  }

  /// Puts each on-screen cell's current values in it, keeping the views, so a popover's anchor and a pressed button survive.
  func reconfigureVisible() {
    let rows = outline.rows(in: outline.visibleRect)

    for row in rows.lowerBound..<rows.upperBound {
      guard let item = outline.item(atRow: row) else { continue }

      for (index, column) in outline.tableColumns.enumerated() where !column.isHidden {
        guard let view = outline.view(atColumn: index, row: row, makeIfNecessary: false), let kind = ProjectsColumn(rawValue: column.identifier.rawValue) else { continue }

        configure(view, kind, item)
      }
    }
  }

  private func configure(_ view: NSView, _ column: ProjectsColumn, _ item: Any) {
    if let group = item as? GroupItem { return configure(view, column, group) }

    if let session = item as? Session { configureCell(view, column, session) }
  }

  private func configure(_ view: NSView, _ column: ProjectsColumn, _ group: GroupItem) {
    switch column {
    case .title:
      (view as? NameCellView)?.show(title: group.project?.name ?? "Pinned", symbol: group.project == nil ? "pin" : "folder")
    case .status:
      (view as? ActivityCellView)?.show(tally(group.sessions.map(\.rowStatus)), request: nil)
    case .tasks:
      (view as? TaskCellView)?.show(done: 0, total: 0)
    case .changes:
      (view as? ChangesCellView)?.show(added: 0, removed: 0, counts: false)
    case .location:
      let path = group.project.map { ($0.path.path as NSString).abbreviatingWithTildeInPath } ?? ""
      (view as? NSTableCellView)?.textField?.stringValue = path
      (view as? NSTableCellView)?.textField?.toolTip = path
    case .context, .updated:
      (view as? NSTableCellView)?.textField?.stringValue = ""
    }
  }

  // MARK: Outline

  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    guard let item else { return groups.count }

    return (item as? GroupItem)?.sessions.count ?? 0
  }

  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    guard let group = item as? GroupItem else { return groups[index] }

    return group.sessions[index]
  }

  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    (item as? GroupItem).map { !$0.sessions.isEmpty } ?? false
  }

  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
    guard let tableColumn, let column = ProjectsColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }

    let view = outlineView.makeView(withIdentifier: tableColumn.identifier, owner: self) ?? column.makeCell()
    configure(view, column, item)
    return view
  }

  func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
    guard tableColumn?.identifier == ProjectsColumn.title.identifier else { return nil }

    return (item as? Session)?.rowTitle ?? (item as? GroupItem)?.project?.name
  }

  func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
    query.sortOrder = outlineView.sortDescriptors
    refresh()
  }

  func outlineViewSelectionDidChange(_ notification: Notification) {
    updateToolbar()
  }

  func outlineViewItemDidExpand(_ notification: Notification) {
    remember(notification, collapsed: false)
  }

  func outlineViewItemDidCollapse(_ notification: Notification) {
    remember(notification, collapsed: true)
  }

  private func remember(_ notification: Notification, collapsed isCollapsed: Bool) {
    guard !isReloading, let group = notification.userInfo?["NSObject"] as? GroupItem else { return }

    if isCollapsed {
      collapsed.insert(group.id)
    } else {
      collapsed.remove(group.id)
    }

    UserDefaults.standard.set(Array(collapsed).sorted(), forKey: "ProjectsCollapsed")
  }

  // MARK: Request popover

  /// Shows the session's open request in a popover on its row.
  func peek(_ session: Session) {
    guard let request = session.request else { return }

    let row = outline.row(forItem: session)
    guard row >= 0 else { return }

    popover?.close()
    outline.scrollRowToVisible(row)

    guard let rowView = outline.rowView(atRow: row, makeIfNecessary: true) else { return }

    let column = outline.column(withIdentifier: ProjectsColumn.status.identifier)
    let shown = column >= 0 && !outline.tableColumns[column].isHidden ? column : 0
    let anchor = outline.convert(outline.frameOfCell(atColumn: shown, row: row), to: rowView)
    let detail = RequestDetailController(request: request, projectName: session.project?.name ?? "") { [weak self, weak session] decision in
      session?.live?.respond(to: request, with: decision)
      self?.popover?.close()
    }
    let popover = NSPopover()

    popover.behavior = .transient
    popover.contentViewController = detail
    popover.delegate = self
    popover.show(relativeTo: anchor, of: rowView, preferredEdge: .maxY)
    self.popover = popover
    peeked = session
  }

  func popoverDidClose(_ notification: Notification) {
    guard notification.object as? NSPopover === popover else { return }

    popover = nil
    peeked = nil

    if isWatching { refresh() }
  }

  @objc private func menuOpened(_ notification: Notification) {
    openMenus += 1
  }

  @objc private func menuClosed(_ notification: Notification) {
    openMenus = max(openMenus - 1, 0)

    if openMenus == 0, isWatching { refresh() }
  }

  // MARK: Window

  func windowWillClose(_ notification: Notification) {
    popover?.close()
    watching += 1
    isWatching = false
    ticker?.invalidate()
    ticker = nil
    UserDefaults.standard.set(false, forKey: "ProjectsOpen")
  }

  override func showWindow(_ sender: Any?) {
    if window?.isVisible != true { watch() }

    super.showWindow(sender)
    UserDefaults.standard.set(true, forKey: "ProjectsOpen")
  }

  func windowDidBecomeMain(_ notification: Notification) {
    reconfigureVisible()
  }

  func windowDidResignMain(_ notification: Notification) {
    reconfigureVisible()
  }
}
