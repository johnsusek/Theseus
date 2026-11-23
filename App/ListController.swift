import AppKit

/// A table whose Return key opens the selection.
final class ListTableView: NSTableView {
  var onReturn: () -> Void = {}

  override func keyDown(with event: NSEvent) {
    // Return and Enter.
    if event.keyCode == 36 || event.keyCode == 76 { return onReturn() }

    super.keyDown(with: event)
  }
}

/// A popover's content: one column of rows, tall enough for `visibleRows` of them before it scrolls.
/// Subclasses hold the rows and make the row views.
class ListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
  static let width = 420.0
  let tableView = ListTableView()
  /// The rows' ids, in the order shown.
  private(set) var ids: [String] = []
  /// The rows the open context menu is for: the clicked row alone when it is outside the selection, the whole selection
  /// when it is inside, and none for a click below the last row. They are ids because the rows can reorder under an open menu.
  private(set) var menuIds: [String] = []

  var selectedIds: [String] { tableView.selectedRowIndexes.filter { $0 < ids.count }.map { ids[$0] } }
  private let visibleRows: Int

  init(rowHeight: CGFloat, visibleRows: Int, label: String) {
    self.visibleRows = visibleRows
    super.init(nibName: nil, bundle: nil)
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))

    column.resizingMask = .autoresizingMask
    tableView.addTableColumn(column)
    tableView.headerView = nil
    tableView.style = .inset
    tableView.rowHeight = rowHeight
    tableView.intercellSpacing = .zero
    tableView.backgroundColor = .clear
    tableView.allowsMultipleSelection = true
    tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
    tableView.dataSource = self
    tableView.delegate = self
    tableView.setAccessibilityLabel(label)
    fitHeight()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("ListController is built in code") }

  override func loadView() {
    let scrollView = NSScrollView()

    scrollView.documentView = tableView
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    view = scrollView
  }

  /// Shows `newIds`' rows, keeping the selection on the rows it was on.
  func reload(_ newIds: [String]) {
    let selected = Set(selectedIds)

    ids = newIds
    tableView.reloadData()
    tableView.selectRowIndexes(IndexSet(ids.indices.filter { selected.contains(ids[$0]) }), byExtendingSelection: false)
    fitHeight()
  }

  /// A popover follows its content's preferred size. An inset table pads its rows above and below, by the same amount.
  private func fitHeight() {
    let padding = ids.isEmpty ? 10 : tableView.rect(ofRow: 0).minY
    preferredContentSize = NSSize(width: Self.width, height: tableView.rowHeight * CGFloat(min(max(ids.count, 1), visibleRows)) + padding * 2)
  }

  /// The table takes the keyboard when the list opens, so the arrow keys work at once.
  override func viewDidAppear() {
    super.viewDidAppear()
    view.window?.makeFirstResponder(tableView)
  }

  /// Gives the table its context menu, whose commands then act on `menuIds`.
  func setMenu(_ items: [(title: String, action: Selector)]) {
    let menu = NSMenu()

    for item in items { menu.addItem(withTitle: item.title, action: item.action, keyEquivalent: "").target = self }

    menu.delegate = self
    tableView.menu = menu
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    let clicked = tableView.clickedRow

    menuIds = []

    if clicked >= 0, clicked < ids.count { menuIds = tableView.selectedRowIndexes.contains(clicked) ? selectedIds : [ids[clicked]] }
  }

  func numberOfRows(in tableView: NSTableView) -> Int { ids.count }
}
