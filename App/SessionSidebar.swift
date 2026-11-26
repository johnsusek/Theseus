import AppKit
import ClaudeWorkspace

/// A sidebar section's header row. One object per title, so the outline view sees the same item across reloads.
private final class SidebarHeader {
  let title: String

  init(_ title: String) { self.title = title }
}

/// A conversation window's sidebar: the project's sessions as `SidebarStyle` lists and draws them, subsessions under their parent,
/// with the window's own session selected. A click or Return opens the session.
final class SessionSidebar: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
  var onOpen: (Session) -> Void = { _ in }
  /// The session of the conversation beside the sidebar, which the selection returns to.
  weak var current: Session? {
    // The conversation re-sets this on every refresh; re-selecting each time would scroll the list back while someone browses it.
    didSet { if current !== oldValue, !outline.isFocused { selectCurrent() } }
  }
  private let outline = SidebarOutlineView()
  private var style = SidebarStyle()
  private var rows: [AnyObject] = []
  private var subsessions: [ObjectIdentifier: [Session]] = [:]
  private var headers: [String: SidebarHeader] = [:]
  /// Parents the user closed; every other parent opens when the rows are rebuilt.
  private var collapsed: Set<String> = []
  private var isReloading = false

  override func loadView() {
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
    column.resizingMask = .autoresizingMask
    outline.addTableColumn(column)
    outline.outlineTableColumn = column
    outline.headerView = nil
    outline.style = .sourceList
    outline.rowSizeStyle = .custom
    outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
    outline.allowsEmptySelection = true
    outline.dataSource = self
    outline.delegate = self
    outline.target = self
    outline.action = #selector(clickRow(_:))
    outline.onReturn = { [unowned self] in open(outline.selectedRow) }
    outline.onResign = { [unowned self] in if !outline.isFocused { selectCurrent() } }
    outline.setAccessibilityLabel("Sessions")

    let scroll = NSScrollView()
    scroll.documentView = outline
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    view = scroll
  }

  /// Lists `roots` and their subsessions in `style`. The rows are rebuilt only when the list or the style changes; otherwise the visible
  /// cells refresh in place. While the list has focus its selection stays where the arrows put it.
  func show(_ roots: [Session], style: SidebarStyle) {
    let now = Date.now
    var rows: [AnyObject] = []
    var subsessions: [ObjectIdentifier: [Session]] = [:]
    var pending: [Session] = []

    for section in sidebarSections(roots, style: style, now: now) {
      if let title = section.title {
        let header = headers[title] ?? SidebarHeader(title)
        headers[title] = header
        rows.append(header)
      }

      rows += section.sessions as [AnyObject]
      pending += section.sessions
    }

    while let session = pending.popLast() {
      let shown = sidebarOrder(session.children.filter { sidebarShows($0, style: style, now: now) }, style.order)

      guard !shown.isEmpty else { continue }

      subsessions[ObjectIdentifier(session)] = shown
      pending += shown
    }

    let unchanged = style == self.style && rows.map(ObjectIdentifier.init) == self.rows.map(ObjectIdentifier.init)
      && subsessions.mapValues { $0.map(ObjectIdentifier.init) } == self.subsessions.mapValues { $0.map(ObjectIdentifier.init) }

    guard !unchanged else {
      var resized = IndexSet()

      for row in 0..<outline.numberOfRows {
        guard let session = outline.item(atRow: row) as? Session else { continue }

        (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell)?.show(session, style: style)

        if outline.rect(ofRow: row).height != SidebarCell.height(for: style, session: session) { resized.insert(row) }
      }

      guard !resized.isEmpty else { return }

      return NSAnimationContext.runAnimationGroup { context in
        context.duration = 0
        outline.noteHeightOfRows(withIndexesChanged: resized)
      }
    }

    let selected = outline.isFocused ? outline.item(atRow: outline.selectedRow) as AnyObject? : nil
    self.rows = rows
    self.subsessions = subsessions
    self.style = style
    outline.titleLine = (style.padding, SidebarCell.lineHeight(style))
    isReloading = true
    outline.reloadData()
    expand(rows.compactMap { $0 as? Session })
    isReloading = false

    guard let selected, outline.row(forItem: selected) >= 0 else { return selectCurrent() }

    outline.selectRowIndexes([outline.row(forItem: selected)], byExtendingSelection: false)
  }

  /// Opens every parent among `sessions` and below them, except the ones the user closed.
  private func expand(_ sessions: [Session]) {
    for session in sessions {
      guard let shown = subsessions[ObjectIdentifier(session)], !collapsed.contains(session.id) else { continue }

      outline.expandItem(session)
      expand(shown)
    }
  }

  private func selectCurrent() {
    guard isViewLoaded else { return }

    guard let current else { return outline.deselectAll(nil) }

    var ancestors: [Session] = []
    var ancestor = current.parent

    while let parent = ancestor {
      ancestors.insert(parent, at: 0)
      ancestor = parent.parent
    }

    for parent in ancestors { outline.expandItem(parent) }

    let row = outline.row(forItem: current)

    guard row >= 0 else { return outline.deselectAll(nil) }

    outline.selectRowIndexes([row], byExtendingSelection: false)
    outline.scrollRowToVisible(row)
  }

  @objc private func clickRow(_ sender: Any?) {
    open(outline.clickedRow)
  }

  private func open(_ row: Int) {
    guard let session = outline.item(atRow: row) as? Session else { return }

    onOpen(session)

    // The picked session's tab now holds the focused selection; this tab's list goes back to its own session.
    if session !== current { selectCurrent() }
  }

  /// Takes keyboard focus, so the selection draws in the accent color and the arrows move it.
  func focus() {
    view.window?.makeFirstResponder(outline)
  }

  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    guard let session = item as? Session else { return item == nil ? rows.count : 0 }

    return subsessions[ObjectIdentifier(session)]?.count ?? 0
  }

  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    guard let session = item as? Session else { return rows[index] }

    return subsessions[ObjectIdentifier(session), default: []][index]
  }

  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Session).map { subsessions[ObjectIdentifier($0)] != nil } ?? false }

  func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is SidebarHeader }

  func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is Session }

  func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { item is SidebarHeader ? 26 : (item as? Session).map { SidebarCell.height(for: style, session: $0) } ?? 0 }

  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
    if let header = item as? SidebarHeader {
      let cell = outlineView.makeView(withIdentifier: HeaderCell.identifier, owner: nil) as? HeaderCell ?? HeaderCell()
      cell.textField?.stringValue = header.title
      return cell
    }

    guard let session = item as? Session else { return nil }

    let cell = outlineView.makeView(withIdentifier: SidebarCell.identifier, owner: nil) as? SidebarCell ?? SidebarCell()
    cell.show(session, style: style)
    return cell
  }

  func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { item is Session ? SidebarRowView(separators: !style.compact) : nil }

  func outlineViewItemDidExpand(_ notification: Notification) {
    guard !isReloading, let session = notification.userInfo?["NSObject"] as? Session else { return }

    collapsed.remove(session.id)
  }

  func outlineViewItemDidCollapse(_ notification: Notification) {
    guard !isReloading, let session = notification.userInfo?["NSObject"] as? Session else { return }

    collapsed.insert(session.id)
  }
}

/// A row with Mail's separator when the style asks for it: a hairline under the row from the title's leading edge, left out beside a selected row.
private final class SidebarRowView: NSTableRowView {
  private let separators: Bool

  override var isSelected: Bool {
    didSet { needsDisplay = true }
  }
  override var isNextRowSelected: Bool {
    didSet { needsDisplay = true }
  }

  init(separators: Bool) {
    self.separators = separators
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("SidebarRowView is built in code") }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard separators, !isSelected, !isNextRowSelected, let cell = subviews.lazy.compactMap({ $0 as? SidebarCell }).first else { return }

    let leading = cell.convert(cell.title.frame.origin, to: self).x
    let thickness = 1 / (window?.backingScaleFactor ?? 2)
    NSColor.separatorColor.setFill()
    NSRect(x: leading, y: bounds.maxY - thickness, width: bounds.maxX - leading, height: thickness).fill()
  }
}

/// The sidebar's outline: Return opens the selected row, losing focus hands the selection back to the window's session, and a
/// disclosure triangle sits on its row's title line.
private final class SidebarOutlineView: NSOutlineView {
  var onReturn: () -> Void = {}
  var onResign: () -> Void = {}
  /// Where a session row's title line starts below the row's top, and its height.
  var titleLine: (top: Double, height: Double) = (0, 0)

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

  override func frameOfOutlineCell(atRow row: Int) -> NSRect {
    var frame = super.frameOfOutlineCell(atRow: row)

    guard !frame.isEmpty, item(atRow: row) is Session else { return frame }

    frame.origin.y = rect(ofRow: row).minY + titleLine.top + (titleLine.height - frame.height) / 2
    return frame
  }
}

/// A section header; the source list styles its label.
private final class HeaderCell: NSTableCellView {
  static let identifier = NSUserInterfaceItemIdentifier("HeaderCell")

  init() {
    super.init(frame: .zero)
    identifier = Self.identifier
    let label = cellLabel()
    textField = label
    addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
      label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
      label.centerYAnchor.constraint(equalTo: centerYAnchor)
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("HeaderCell is built in code") }
}

/// A session's row. The style picks its parts: the title after its status dot, with a worktree symbol and the date beside it, then the
/// last prompt in italics, the last response or what the session is doing, and task progress. A part the row has nothing for takes no
/// lines, so rows of one style can differ in height.
private final class SidebarCell: NSTableCellView {
  static let identifier = NSUserInterfaceItemIdentifier("SidebarCell")
  /// Closing text as a row shows it, by the text it came from, so a refresh parses only what changed.
  private static let previews = {
    let cache = NSCache<NSString, NSString>()
    cache.countLimit = 500
    return cache
  }()
  let title = sidebarLabel()
  private let worktree = NSImageView()
  private let date = sidebarLabel(.secondaryLabelColor)
  private let prompt = sidebarLabel(.secondaryLabelColor)
  private let preview = sidebarLabel(.secondaryLabelColor)
  private let detail = sidebarLabel(.secondaryLabelColor)
  private var style = SidebarStyle()
  private var session: Session?

  /// The title carries an inline status dot, so its attributed text is rebuilt in the selection's colors.
  override var backgroundStyle: NSView.BackgroundStyle {
    didSet { showTitle() }
  }

  override var isFlipped: Bool { true }

  init() {
    super.init(frame: .zero)
    identifier = Self.identifier
    worktree.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Worktree")
    worktree.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
    worktree.contentTintColor = .tertiaryLabelColor

    for view in [title, worktree, date, prompt, preview, detail] { addSubview(view) }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("SidebarCell is built in code") }

  private static var lineHeights: [Double: Double] = [:]

  /// A label's own line height, which runs a point above the layout manager's default at some sizes, so a second line would not fit.
  static func lineHeight(_ style: SidebarStyle) -> Double {
    let size = style.textPoints

    if let height = lineHeights[size] { return height }

    let label = NSTextField(labelWithString: "Xg")
    label.font = .systemFont(ofSize: size)
    lineHeights[size] = label.cell!.cellSize.height
    return lineHeights[size]!
  }

  /// The lines of text each part takes: title, prompt, response, tasks; zero for a part the style hides or the session has nothing for.
  private static func lineCounts(_ style: SidebarStyle, session: Session) -> [Int] {
    let hasResponse = (style.showsActivity && !session.activityText.isEmpty) || session.closing?.contains(where: { !$0.isWhitespace }) == true
    return [style.titleLines, style.showsPrompt && !promptText(session).isEmpty ? 1 : 0, style.showsResponse && hasResponse ? style.responseLines : 0, style.showsTasks && session.tasksTotal > 0 ? 1 : 0]
  }

  /// The last prompt on one line, empty for an untitled session, whose title is its prompt already.
  private static func promptText(_ session: Session) -> String {
    guard session.appTitle != nil || session.customTitle != nil else { return "" }

    return session.lastPrompt?.split(whereSeparator: \.isNewline).joined(separator: " ") ?? ""
  }

  static func height(for style: SidebarStyle, session: Session) -> Double {
    let counts = lineCounts(style, session: session).filter { $0 > 0 }
    return 2 * style.padding + Double(counts.reduce(0, +)) * lineHeight(style) + 2 * Double(counts.count - 1)
  }

  override func layout() {
    super.layout()

    guard let session else { return }

    let lineHeight = Self.lineHeight(style)
    let counts = Self.lineCounts(style, session: session)
    let leading = 2.0
    let trailing = bounds.width - 4
    var top = style.padding
    let dateWidth = date.isHidden ? 0 : ceil(date.fittingSize.width)
    let titleRight = trailing - (dateWidth > 0 ? dateWidth + 6 : 0) - (worktree.isHidden ? 0 : 15)
    let titleWidth = style.titleLines == 1 ? min(ceil(title.fittingSize.width), titleRight - leading) : titleRight - leading

    date.frame = NSRect(x: trailing - dateWidth, y: top, width: dateWidth, height: lineHeight)
    title.frame = NSRect(x: leading, y: top, width: max(0, titleWidth), height: Double(style.titleLines) * lineHeight)
    worktree.frame = NSRect(x: title.frame.maxX + 3, y: top + (lineHeight - 12) / 2, width: 12, height: 12)
    top += title.frame.height + 2

    for (label, count) in zip([prompt, preview, detail], counts.dropFirst()) where count > 0 {
      label.frame = NSRect(x: leading, y: top, width: max(0, trailing - leading), height: Double(count) * lineHeight)
      top += label.frame.height + 2
    }
  }

  func show(_ session: Session, style: SidebarStyle) {
    self.style = style
    self.session = session
    let size = style.textPoints
    let font = NSFont.systemFont(ofSize: size)
    var text = style.showsActivity ? session.activityText : ""

    if text.isEmpty, let closing = session.closing {
      let source = String(closing.prefix(600)) as NSString

      if let cached = Self.previews.object(forKey: source) {
        text = cached as String
      } else {
        let lines = (source as String).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces).trimmingPrefix(while: { $0 == "#" }) }
        let joined = lines.joined(separator: " ")
        text = (try? AttributedString(markdown: joined, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map { String($0.characters) } ?? joined
        Self.previews.setObject(text as NSString, forKey: source)
      }
    }

    for label in [date, preview, detail] { label.font = font }

    title.maximumNumberOfLines = style.titleLines
    title.lineBreakMode = style.titleLines == 1 ? .byTruncatingTail : .byWordWrapping
    worktree.isHidden = !style.showsWorktree || session.worktree == nil
    worktree.toolTip = session.worktree.map { "Worktree \($0)" }
    date.isHidden = !style.showsDate

    switch style.dateStyle {
    case .time: date.stringValue = updatedText(session.lastActive, now: .now)
    case .relative: date.stringValue = session.lastActiveText
    case .short: date.stringValue = shortAge(session.lastActive, now: .now)
    }

    let counts = Self.lineCounts(style, session: session)
    prompt.isHidden = counts[1] == 0
    prompt.font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    prompt.stringValue = Self.promptText(session)
    preview.isHidden = counts[2] == 0
    preview.maximumNumberOfLines = style.responseLines
    preview.lineBreakMode = style.responseLines == 1 ? .byTruncatingTail : .byWordWrapping
    preview.stringValue = text
    detail.isHidden = counts[3] == 0
    detail.stringValue = session.tasksTotal > 0 ? "\(session.tasksDone)/\(session.tasksTotal) tasks" : ""
    toolTip = text.isEmpty ? session.rowTitle : session.rowTitle + "\n" + text
    showTitle()
    needsLayout = true
  }

  /// The title after its status dot.
  private func showTitle() {
    guard let session else { return }

    let selected = backgroundStyle == .emphasized
    let size = style.textPoints
    let font = NSFont.systemFont(ofSize: size)
    let titleFont = style.boldTitle ? NSFont.boldSystemFont(ofSize: size) : font
    let titleColor = selected ? NSColor.alternateSelectedControlTextColor : session.isArchived ? .secondaryLabelColor : .labelColor
    let titleText = NSMutableAttributedString()
    let unread = style.showsUnread && session.isUnread
    var dot: (name: String, color: NSColor)?

    switch session.rowStatus {
    case .waiting: dot = ("circle.fill", .systemYellow)
    case .failed: dot = ("xmark.circle.fill", .systemRed)
    case .running: dot = ("circle.fill", .systemGreen)
    case .finished where unread, .closed where unread: dot = ("circle.fill", selected ? .alternateSelectedControlTextColor : .controlAccentColor)
    default: break
    }

    if let dot {
      titleText.append(inlineSymbol(dot.name, color: dot.color, font: titleFont, pointSize: round(size * 0.6)))
      titleText.append(NSAttributedString(string: " "))
    }

    titleText.append(NSAttributedString(string: session.rowTitle))
    let titleParagraph = NSMutableParagraphStyle()
    titleParagraph.lineBreakMode = title.lineBreakMode
    titleText.addAttributes([.font: titleFont, .foregroundColor: titleColor, .paragraphStyle: titleParagraph], range: NSRange(location: 0, length: titleText.length))
    title.attributedStringValue = titleText
  }
}

/// A symbol in `color`, centered on the cap height of `font` so it sits level with the text after it.
@MainActor
private func inlineSymbol(_ name: String, color: NSColor, font: NSFont, pointSize: Double) -> NSAttributedString {
  let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular).applying(.init(paletteColors: [color]))
  let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(configuration)!
  let attachment = NSTextAttachment()
  attachment.image = image
  attachment.bounds = NSRect(x: 0, y: (font.capHeight - image.size.height) / 2, width: image.size.width, height: image.size.height)
  return NSAttributedString(attachment: attachment)
}

/// A frame-laid label for a sidebar row; the row sets its lines and wrapping.
@MainActor
private func sidebarLabel(_ color: NSColor = .labelColor) -> NSTextField {
  let label = NSTextField(labelWithString: "")
  label.textColor = color
  label.cell?.truncatesLastVisibleLine = true
  return label
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
