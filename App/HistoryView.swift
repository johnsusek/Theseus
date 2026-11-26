import AppKit
import ClaudeWorkspace

/// Return opens the selected session, or opens or closes the selected day. Esc leaves the history.
/// Rows run edge to edge with the chevron near the left edge, and sessions line up with their day instead of indenting under it.
final class HistoryOutlineView: NSOutlineView {
  var onReturn: () -> Void = {}
  var onEscape: () -> Void = {}
  private let titleInset = 28.0

  override func frameOfOutlineCell(atRow row: Int) -> NSRect {
    var frame = super.frameOfOutlineCell(atRow: row)
    frame.origin.x = 8
    return frame
  }

  override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
    let frame = super.frameOfCell(atColumn: column, row: row)
    guard column == 0 else { return frame }

    return NSRect(x: titleInset, y: frame.minY, width: frame.maxX - titleInset, height: frame.height)
  }

  override func keyDown(with event: NSEvent) {
    // Return and Enter.
    if event.keyCode == 36 || event.keyCode == 76 { return onReturn() }

    if event.keyCode == 53 { return onEscape() }

    super.keyDown(with: event)
  }
}

/// One day of the history, as an outline item. The view keeps one per day so the outline sees the same object across reloads.
final class HistoryDay {
  let day: Date
  var sessions: [Session] = []

  init(day: Date) {
    self.day = day
  }
}

/// Every session in a project, archived ones too, newest first and grouped by day, as an outline without headers.
final class HistoryView: NSScrollView, NSOutlineViewDataSource, NSOutlineViewDelegate {
  let outline = HistoryOutlineView()
  var onOpen: (Session) -> Void = { _ in }
  /// Shows only sessions whose title contains it, with every day open.
  var search = "" {
    didSet {
      // Days open and close with the search even when the same sessions match, and a search that matches nothing still empties the list.
      days = []
      reloads = true
      show(all)
    }
  }
  /// Set by a new search, so `show` reloads even when the days it finds look unchanged.
  private var reloads = false
  /// The sessions last passed to `show`, which a new search filters again.
  private var all: [Session] = []
  private var days: [HistoryDay] = []
  private var dayItems: [Date: HistoryDay] = [:]
  /// Days the user closed. Every other day opens expanded.
  private var collapsed = Set<Date>()
  private var isReloading = false
  private var query = ProjectsQuery()

  init() {
    super.init(frame: .zero)
    query.showsArchived = true
    query.sortOrder = [NSSortDescriptor(key: "updated", ascending: false)]

    for column in [ProjectsColumn.title, .status, .updated] {
      let tableColumn = column.makeTableColumn()
      tableColumn.resizingMask = []
      outline.addTableColumn(tableColumn)
    }

    outline.outlineTableColumn = outline.tableColumns.first
    outline.headerView = nil
    outline.style = .plain
    outline.usesAlternatingRowBackgroundColors = true
    outline.rowHeight = 26
    outline.dataSource = self
    outline.delegate = self
    outline.target = self
    outline.doubleAction = #selector(openClicked(_:))
    outline.onReturn = { [unowned self] in open(outline.item(atRow: outline.selectedRow)) }
    outline.setAccessibilityLabel("History")
    documentView = outline
    drawsBackground = false
    hasVerticalScroller = true
    autohidesScrollers = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("HistoryView is built in code") }

  /// Updated keeps its width; Name and Activity share the rest of the visible width.
  override func layout() {
    super.layout()
    let columns = outline.tableColumns
    let spacing = outline.intercellSpacing.width * CGFloat(columns.count)
    let shared = max(contentView.bounds.width - columns[2].width - spacing, 0) / 2

    columns[0].width = shared
    columns[1].width = shared
  }

  /// Reloads the rows when the days or their sessions changed, keeping the selection, and otherwise updates the cells on screen.
  func show(_ sessions: [Session]) {
    all = sessions
    let matching = query.sessions(sessions).filter { search.isEmpty || $0.rowTitle.localizedCaseInsensitiveContains(search) }
    let grouped = sessionsByDay(matching)
    let unchanged = grouped.map(\.day) == days.map(\.day) && zip(grouped, days).allSatisfy { new, old in new.sessions.map(ObjectIdentifier.init) == old.sessions.map(ObjectIdentifier.init) }

    if unchanged, !reloads { return reconfigureVisible() }

    reloads = false
    let selected = outline.item(atRow: outline.selectedRow) as AnyObject?
    days = grouped.map { group in
      let item = dayItems[group.day] ?? HistoryDay(day: group.day)
      item.sessions = group.sessions
      dayItems[group.day] = item
      return item
    }
    isReloading = true
    outline.reloadData()

    for day in days where search.isEmpty && collapsed.contains(day.day) { outline.collapseItem(day) }

    for day in days where !search.isEmpty || !collapsed.contains(day.day) { outline.expandItem(day) }

    isReloading = false
    let row = selected.map { outline.row(forItem: $0) } ?? -1

    if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
  }

  func session(for control: NSView) -> Session? {
    let row = outline.row(for: control)
    return row >= 0 ? outline.item(atRow: row) as? Session : nil
  }

  private func reconfigureVisible() {
    let visible = outline.rows(in: outline.visibleRect)

    for row in visible.lowerBound..<visible.upperBound {
      guard let item = outline.item(atRow: row) else { continue }

      for (index, column) in outline.tableColumns.enumerated() {
        guard let view = outline.view(atColumn: index, row: row, makeIfNecessary: false), let kind = ProjectsColumn(rawValue: column.identifier.rawValue) else { continue }

        configure(view, kind, item)
      }
    }
  }

  /// A day shows its date and how many sessions it holds; a session's Updated column shows only its time once it is not from today.
  private func configure(_ view: NSView, _ column: ProjectsColumn, _ item: Any) {
    if let day = item as? HistoryDay {
      switch column {
      case .title: (view as? NameCellView)?.show(title: dayTitle(day.day, now: .now), symbol: "clock")
      case .status: (view as? ActivityCellView)?.show(day.sessions.count == 1 ? "1 session" : "\(day.sessions.count) sessions", request: nil)
      default: (view as? NSTableCellView)?.textField?.stringValue = ""
      }
      return
    }

    guard let session = item as? Session else { return }

    configureCell(view, column, session)

    if column == .updated, !Calendar.current.isDateInToday(session.lastActive) { (view as? NSTableCellView)?.textField?.stringValue = session.lastActive.formatted(date: .omitted, time: .shortened) }
  }

  private func open(_ item: Any?) {
    if let session = item as? Session { return onOpen(session) }

    guard let day = item as? HistoryDay else { return }

    if outline.isItemExpanded(day) {
      outline.collapseItem(day)
    } else {
      outline.expandItem(day)
    }
  }

  @objc private func openClicked(_ sender: Any?) {
    open(outline.item(atRow: outline.clickedRow))
  }

  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    guard let item else { return days.count }

    return (item as? HistoryDay)?.sessions.count ?? 0
  }

  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    guard let day = item as? HistoryDay else { return days[index] }

    return day.sessions[index]
  }

  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is HistoryDay }

  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
    guard let tableColumn, let column = ProjectsColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }

    let view = outlineView.makeView(withIdentifier: tableColumn.identifier, owner: self) ?? column.makeCell()
    configure(view, column, item)
    return view
  }

  func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
    tableColumn?.identifier == ProjectsColumn.title.identifier ? (item as? Session)?.rowTitle : nil
  }

  func outlineViewItemDidExpand(_ notification: Notification) {
    remember(notification, collapsed: false)
  }

  func outlineViewItemDidCollapse(_ notification: Notification) {
    remember(notification, collapsed: true)
  }

  /// Keeps what the user opened and closed, outside a search, which opens every day.
  private func remember(_ notification: Notification, collapsed isCollapsed: Bool) {
    guard !isReloading, search.isEmpty, let day = notification.userInfo?["NSObject"] as? HistoryDay else { return }

    if isCollapsed {
      collapsed.insert(day.day)
    } else {
      collapsed.remove(day.day)
    }
  }
}
