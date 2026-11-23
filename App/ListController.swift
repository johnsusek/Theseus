import AppKit

/// A table whose Return key opens the selection, and which says what rows its context menu is for.
final class ListTableView: NSTableView {
  var onReturn: () -> Void = {}

  /// The rows a context menu command acts on: the clicked row alone when it is outside the selection, the whole
  /// selection when it is inside, and nothing for a click below the last row.
  var menuRows: IndexSet {
    if clickedRow < 0 { return [] }

    return selectedRowIndexes.contains(clickedRow) ? selectedRowIndexes : [clickedRow]
  }

  override func keyDown(with event: NSEvent) {
    // Return and Enter.
    if event.keyCode == 36 || event.keyCode == 76 { return onReturn() }

    super.keyDown(with: event)
  }
}

/// A popover's content: one column of rows, tall enough for `visibleRows` of them before it scrolls.
/// Subclasses hold the rows and make the row views.
class ListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
  static let width = 420.0
  let tableView = ListTableView()
  /// The rows' ids, in the order shown.
  private(set) var ids: [String] = []
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
    let selected = Set(tableView.selectedRowIndexes.compactMap { $0 < ids.count ? ids[$0] : nil })

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

  func numberOfRows(in tableView: NSTableView) -> Int { ids.count }
}
