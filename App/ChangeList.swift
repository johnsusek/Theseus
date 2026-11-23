import AppKit

/// The changes popover: the files the session's edits changed. A row opens in its default app, drags out as a file,
/// and its context menu opens it, shows it in Finder or copies its path.
final class ChangeListController: ListController, NSMenuItemValidation {
  var rows: [ChangeRow] = [] {
    didSet {
      if rows != oldValue { reload(rows.map(\.id)) }
    }
  }

  init() {
    super.init(rowHeight: 25, visibleRows: 10, label: "Changes")
  }

  override func loadView() {
    super.loadView()
    let menu = NSMenu()

    for (title, action) in [("Open", #selector(openFromMenu(_:))), ("Reveal in Finder", #selector(revealInFinder(_:))), ("Copy Path", #selector(copyPath(_:)))] {
      menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
    }

    tableView.menu = menu
    tableView.target = self
    tableView.doubleAction = #selector(openSelection(_:))
    tableView.onReturn = { [unowned self] in openSelection(nil) }
    tableView.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let identifier = NSUserInterfaceItemIdentifier("change")
    let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ChangeCellView ?? ChangeCellView()

    cell.identifier = identifier
    cell.row = rows[row]
    return cell
  }

  /// A row drags out as its file, when the file is still there.
  func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
    FileManager.default.fileExists(atPath: rows[row].path) ? NSURL(fileURLWithPath: rows[row].path) : nil
  }

  func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? { rows[row].name }

  private func urls(_ indexes: IndexSet) -> [URL] {
    indexes.map { URL(filePath: rows[$0].path) }.filter { FileManager.default.fileExists(atPath: $0.path) }
  }

  private func open(_ indexes: IndexSet) {
    let files = urls(indexes)

    // A file the session has since deleted has nothing to open.
    if files.count < indexes.count { NSSound.beep() }

    for file in files { NSWorkspace.shared.open(file) }
  }

  /// Double-click and Return.
  @objc private func openSelection(_ sender: Any?) {
    open(tableView.selectedRowIndexes)
  }

  @objc private func openFromMenu(_ sender: Any?) {
    open(tableView.menuRows)
  }

  @objc private func revealInFinder(_ sender: Any?) {
    NSWorkspace.shared.activateFileViewerSelecting(urls(tableView.menuRows))
  }

  @objc private func copyPath(_ sender: Any?) {
    write(tableView.menuRows)
  }

  /// Edit > Copy with the list in front copies the selected files' paths.
  @objc func copy(_ sender: Any?) {
    write(tableView.selectedRowIndexes)
  }

  private func write(_ indexes: IndexSet) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(indexes.map { rows[$0].path }.joined(separator: "\n"), forType: .string)
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(copy(_:)): !tableView.selectedRowIndexes.isEmpty
    case #selector(copyPath(_:)): !tableView.menuRows.isEmpty
    default: !urls(tableView.menuRows).isEmpty
    }
  }
}

/// One changed file: a document icon, its name, its folder and its line counts.
final class ChangeCellView: NSTableCellView {
  var row: ChangeRow? {
    didSet {
      if row != oldValue { show() }
    }
  }

  /// A selected row in a focused list draws its counts in the row's text color.
  override var backgroundStyle: NSView.BackgroundStyle {
    didSet {
      if backgroundStyle != oldValue { show() }
    }
  }

  private static let digits = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
  private let icon = NSImageView()
  private let name = NSTextField(labelWithString: "")
  private let folder = NSTextField(labelWithString: "")
  private let delta = NSTextField(labelWithString: "")

  init() {
    super.init(frame: .zero)
    icon.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
    icon.contentTintColor = .secondaryLabelColor
    name.lineBreakMode = .byTruncatingMiddle
    name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    name.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    folder.textColor = .secondaryLabelColor
    folder.lineBreakMode = .byTruncatingHead
    folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    folder.setContentHuggingPriority(.defaultLow, for: .horizontal)
    delta.setContentCompressionResistancePriority(.required, for: .horizontal)
    delta.setContentHuggingPriority(.required, for: .horizontal)

    for view in [icon, name, folder, delta] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
      view.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
    }

    textField = name
    imageView = icon

    NSLayoutConstraint.activate([
      icon.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
      folder.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 8),
      delta.leadingAnchor.constraint(greaterThanOrEqualTo: folder.trailingAnchor, constant: 8),
      delta.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("ChangeCellView is built in code") }

  private func show() {
    guard let row else { return }

    name.stringValue = row.name
    folder.stringValue = row.folder
    delta.attributedStringValue = lineDeltaText(added: row.added, removed: row.removed, font: Self.digits, isActive: true, isEmphasized: backgroundStyle == .emphasized)
    toolTip = row.path
  }
}
