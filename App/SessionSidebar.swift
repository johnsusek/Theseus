import AppKit
import ClaudeWorkspace

/// A conversation window's sidebar: the project's sessions in the start page's order, with the window's own session selected.
/// A click or Return opens the session.
final class SessionSidebar: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
  var onOpen: (Session) -> Void = { _ in }
  /// The session of the conversation beside the sidebar, which the selection returns to.
  weak var current: Session? {
    didSet { selectCurrent() }
  }
  private let table = SidebarTableView()
  private var sessions: [Session] = []

  override func loadView() {
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
    column.resizingMask = .autoresizingMask
    table.addTableColumn(column)
    table.headerView = nil
    table.style = .sourceList
    table.rowSizeStyle = .custom
    table.rowHeight = 40
    table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
    table.allowsEmptySelection = true
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.action = #selector(clickRow(_:))
    table.onReturn = { [unowned self] in open(table.selectedRow) }
    table.onResign = { [unowned self] in selectCurrent() }
    table.setAccessibilityLabel("Sessions")

    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    view = scroll
  }

  /// Lists `sessions`, reloading only when they change or move. While the list has focus its selection stays where the arrows put it.
  func show(_ sessions: [Session]) {
    guard sessions.map(\.id) != self.sessions.map(\.id) else {
      for (row, session) in sessions.enumerated() { (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell)?.show(session) }
      return
    }

    let selected = self.sessions.indices.contains(table.selectedRow) ? self.sessions[table.selectedRow].id : nil
    self.sessions = sessions
    table.reloadData()

    guard table.isFocused, let row = sessions.firstIndex(where: { $0.id == selected }) else { return selectCurrent() }

    table.selectRowIndexes([row], byExtendingSelection: false)
  }

  private func selectCurrent() {
    guard isViewLoaded, !table.isFocused else { return }

    guard let row = sessions.firstIndex(where: { $0 === current }) else { return table.deselectAll(nil) }

    table.selectRowIndexes([row], byExtendingSelection: false)
    table.scrollRowToVisible(row)
  }

  @objc private func clickRow(_ sender: Any?) {
    open(table.clickedRow)
  }

  private func open(_ row: Int) {
    guard sessions.indices.contains(row) else { return }

    onOpen(sessions[row])
    view.window?.makeFirstResponder(nil)
    selectCurrent()
  }

  func numberOfRows(in tableView: NSTableView) -> Int { sessions.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let cell = tableView.makeView(withIdentifier: SidebarCell.identifier, owner: nil) as? SidebarCell ?? SidebarCell()
    cell.show(sessions[row])
    return cell
  }
}

/// The sidebar's table: Return opens the selected row, and losing focus hands the selection back to the window's session.
private final class SidebarTableView: NSTableView {
  var onReturn: () -> Void = {}
  var onResign: () -> Void = {}

  var isFocused: Bool { window?.firstResponder === self }

  override func keyDown(with event: NSEvent) {
    guard event.keyCode == 36 || event.keyCode == 76 else { return super.keyDown(with: event) }

    onReturn()
  }

  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()

    if resigned { Task { @MainActor in onResign() } }

    return resigned
  }
}

/// A session's row: its status mark and title, then what it is doing or how it closed, and when it was last active.
private final class SidebarCell: NSTableCellView {
  static let identifier = NSUserInterfaceItemIdentifier("SidebarCell")
  private let mark = RowStatusMark()
  private let title = cellLabel()
  private let detail = cellLabel(.secondaryLabelColor)
  private let date = cellLabel(.secondaryLabelColor)

  init() {
    super.init(frame: .zero)
    identifier = Self.identifier
    textField = title
    detail.font = .systemFont(ofSize: 11)
    date.font = .systemFont(ofSize: 11)
    date.setContentCompressionResistancePriority(.required, for: .horizontal)
    date.setContentHuggingPriority(.required, for: .horizontal)

    for view in [mark, title, detail, date] { addSubview(view) }

    NSLayoutConstraint.activate([
      mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -2),
      mark.centerYAnchor.constraint(equalTo: centerYAnchor),
      title.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 2),
      title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
      title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
      detail.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
      detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      detail.trailingAnchor.constraint(lessThanOrEqualTo: date.leadingAnchor, constant: -6),
      date.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
      date.firstBaselineAnchor.constraint(equalTo: detail.firstBaselineAnchor)
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("SidebarCell is built in code") }

  func show(_ session: Session) {
    let text = session.detailText

    mark.show(status: session.rowStatus, isUnread: session.isUnread)
    title.stringValue = session.rowTitle
    detail.stringValue = text
    date.stringValue = updatedText(session.lastActive, now: .now)
    toolTip = text.isEmpty ? session.rowTitle : session.rowTitle + "\n" + text
  }
}

/// A conversation window's content: the session sidebar and the conversation. Showing or hiding the sidebar does the same in every tab
/// of the window, so switching tabs leaves it in place, and new windows start the way it was left.
final class ConversationSplitController: NSSplitViewController {
  static let showsSidebarKey = "ShowsSidebar"
  let sidebar = SessionSidebar()
  private let sidebarItem: NSSplitViewItem
  /// The first window's sidebar starts 240 pt wide once the split view has a width; later ones take the last width set.
  private var placesSidebar = false

  init(content: NSView) {
    sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
    super.init(nibName: nil, bundle: nil)
    let conversation = NSViewController()
    conversation.view = content
    sidebarItem.minimumThickness = 180
    sidebarItem.maximumThickness = 360
    addSplitViewItem(sidebarItem)
    addSplitViewItem(NSSplitViewItem(viewController: conversation))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("ConversationSplitController is built in code") }

  override func viewDidLoad() {
    super.viewDidLoad()
    splitView.autosaveName = "ConversationSidebar"
    placesSidebar = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames ConversationSidebar") == nil
    sidebarItem.isCollapsed = !(UserDefaults.standard.object(forKey: Self.showsSidebarKey) as? Bool ?? true)
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    guard placesSidebar, splitView.bounds.width > 0 else { return }

    placesSidebar = false
    splitView.setPosition(240, ofDividerAt: 0)
  }

  override func toggleSidebar(_ sender: Any?) {
    let shows = sidebarItem.isCollapsed
    super.toggleSidebar(sender)
    UserDefaults.standard.set(shows, forKey: Self.showsSidebarKey)

    for window in view.window?.tabGroup?.windows ?? [] where window !== view.window {
      (window.contentViewController as? ConversationSplitController)?.sidebarItem.isCollapsed = !shows
    }
  }

  override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(toggleSidebar(_:)) { (item as? NSMenuItem)?.title = sidebarItem.isCollapsed ? "Show Sidebar" : "Hide Sidebar" }

    return super.validateUserInterfaceItem(item)
  }
}
