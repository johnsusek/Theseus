import AppKit
import ClaudeWorkspace

/// Safari's start page colors in dark mode. Light mode keeps the system colors.
extension NSColor {
  static let pillFill = startPage(dark: 0x656565, light: .tertiarySystemFill)
  static let pillHover = startPage(dark: 0x6f6f6f, light: .secondarySystemFill)
  static let pillPressed = startPage(dark: 0x7a7a7a, light: .systemFill)
  static let pillTitle = startPage(dark: 0xefefef, light: .labelColor)
  static let pillDetail = startPage(dark: 0xd8d8d8, light: .labelColor.withAlphaComponent(0.8))
  static let startHeading = startPage(dark: 0xededed, light: .labelColor)
  static let startLink = startPage(dark: 0x0091ff, light: .linkColor)

  private static func startPage(dark hex: Int, light: NSColor) -> NSColor {
    let dark = NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    return NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
  }
}

/// A session on the start page: a rounded button with its status mark, its title, what it is doing or asks under the title
/// (else how its last turn closed), the controls that answer a request, and when it was last active.
final class SessionPill: NSButton {
  /// The least height; a two-line detail grows the pill, and the other pill in its row with it.
  static let height = 48.0
  let session: Session
  private let mark = RowStatusMark()
  private let titleLabel = cellLabel(.pillTitle)
  private let detail = cellLabel(.pillDetail, truncation: .byWordWrapping)
  /// The Activity column's cell without its text: Deny and Allow, Answer, or Review.
  private let answers = ActivityCellView()
  private let date = cellLabel(.pillDetail)
  /// Holds the title and the detail under it, centered in the pill.
  private let text = NSLayoutGuide()
  private lazy var alone = titleLabel.bottomAnchor.constraint(equalTo: text.bottomAnchor)
  private lazy var withDetail = detail.bottomAnchor.constraint(equalTo: text.bottomAnchor)
  private var isHovered = false {
    didSet { needsDisplay = true }
  }

  private var shape: NSBezierPath { NSBezierPath(roundedRect: bounds, xRadius: 18, yRadius: 18) }

  init(_ session: Session) {
    self.session = session
    super.init(frame: .zero)
    title = ""
    isBordered = false
    translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
    date.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    date.setContentCompressionResistancePriority(.required, for: .horizontal)
    detail.font = .systemFont(ofSize: 11)
    detail.maximumNumberOfLines = 2
    detail.cell?.truncatesLastVisibleLine = true
    detail.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    answers.translatesAutoresizingMaskIntoConstraints = false

    for view in [mark, titleLabel, detail, answers, date] { addSubview(view) }

    addLayoutGuide(text)

    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))

    // As narrow as its buttons allow, and nothing without a request.
    let narrow = answers.widthAnchor.constraint(equalToConstant: 0)
    narrow.priority = NSLayoutConstraint.Priority(200)
    let least = heightAnchor.constraint(equalToConstant: Self.height)
    least.priority = .defaultLow

    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: Self.height),
      heightAnchor.constraint(greaterThanOrEqualTo: text.heightAnchor, constant: 12),
      least,
      text.centerYAnchor.constraint(equalTo: centerYAnchor),
      titleLabel.topAnchor.constraint(equalTo: text.topAnchor),
      mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      mark.centerYAnchor.constraint(equalTo: centerYAnchor),
      titleLabel.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 6),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: answers.leadingAnchor, constant: -8),
      detail.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
      detail.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      detail.trailingAnchor.constraint(equalTo: answers.leadingAnchor, constant: -8),
      answers.topAnchor.constraint(equalTo: topAnchor),
      answers.bottomAnchor.constraint(equalTo: bottomAnchor),
      answers.trailingAnchor.constraint(equalTo: date.leadingAnchor, constant: -8),
      date.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      date.centerYAnchor.constraint(equalTo: centerYAnchor),
      narrow
    ])
    update()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("SessionPill is built in code") }

  /// Puts the session's current status, title, activity or closing line, request and date in the pill. A pill with neither centers its title.
  func update() {
    var activity = session.activityText

    if activity.isEmpty, let closing = session.closing {
      let line = closing.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) }.map(String.init) ?? ""
      activity = (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map { String($0.characters) } ?? line
    }

    mark.show(status: session.rowStatus, isUnread: session.isUnread)
    titleLabel.stringValue = session.rowTitle
    let relative = session.lastActive.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    date.stringValue = relative.prefix(1).capitalized + relative.dropFirst()
    detail.stringValue = activity
    detail.isHidden = activity.isEmpty
    toolTip = activity.isEmpty ? session.rowTitle : session.rowTitle + "\n" + activity
    setAccessibilityLabel(session.rowTitle)
    answers.show("", request: session.request)
    NSLayoutConstraint.deactivate([alone, withDetail])
    (activity.isEmpty ? alone : withDetail).isActive = true
  }

  /// A wrapping label needs its width to know its height.
  override func layout() {
    super.layout()

    guard detail.preferredMaxLayoutWidth != detail.frame.width else { return }

    detail.preferredMaxLayoutWidth = detail.frame.width
    super.layout()
  }

  /// A click anywhere is a click on the pill, except on the answer controls.
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let hit = super.hitTest(point) else { return nil }

    return hit.isDescendant(of: answers) ? hit : self
  }

  override func draw(_ dirtyRect: NSRect) {
    let fill: NSColor

    if isHighlighted {
      fill = .pillPressed
    } else if isHovered {
      fill = .pillHover
    } else {
      fill = .pillFill
    }

    fill.setFill()
    shape.fill()
  }

  override var focusRingMaskBounds: NSRect { bounds }

  override func drawFocusRingMask() {
    shape.fill()
  }

  override func mouseEntered(with event: NSEvent) {
    isHovered = true
  }

  override func mouseExited(with event: NSEvent) {
    isHovered = false
  }
}

/// Session pills two to a row, three once the grid is wide enough, each row's pills as tall as each other. Each session keeps its pill, so a pill whose session moves slides to its new place.
final class PillGrid: NSView {
  static let spacing = 10.0
  /// The least width that takes three columns.
  static let threeColumnWidth = 900.0
  var onOpen: (Session) -> Void = { _ in }
  private(set) var pills: [SessionPill] = []
  private var placement: [NSLayoutConstraint] = []
  private var columns = 2

  override var isFlipped: Bool { true }

  /// Shows a pill for each session in order. On screen, kept pills slide to their places, new ones fade in and gone ones fade out.
  func show(_ sessions: [Session]) {
    let old = Dictionary(uniqueKeysWithValues: pills.map { ($0.session.id, $0) })
    let before = old.mapValues(\.frame)
    let listed = Set(sessions.map(\.id))
    let gone = pills.filter { !listed.contains($0.session.id) }

    // A gone pill holds its place while it fades.
    for pill in gone { pill.translatesAutoresizingMaskIntoConstraints = true }

    pills = sessions.map { session in
      if let pill = old[session.id] {
        pill.update()
        return pill
      }

      let pill = SessionPill(session)
      pill.target = self
      pill.action = #selector(openPill(_:))
      addSubview(pill)
      return pill
    }
    place()

    guard let content = window?.contentView, !before.isEmpty else {
      for pill in gone { pill.removeFromSuperview() }
      return
    }

    content.layoutSubtreeIfNeeded()
    let moves = pills.compactMap { pill in before[pill.session.id].map { (pill: pill, from: $0, to: pill.frame) } }
    let added = pills.filter { before[$0.session.id] == nil }

    for move in moves { move.pill.frame = move.from }

    for pill in added { pill.alphaValue = 0 }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.3
      context.allowsImplicitAnimation = true

      for move in moves { move.pill.animator().frame = move.to }

      for pill in added { pill.animator().alphaValue = 1 }

      for pill in gone { pill.animator().alphaValue = 0 }
    } completionHandler: {
      for pill in gone { pill.removeFromSuperview() }
    }
  }

  override func layout() {
    super.layout()
    let wanted = bounds.width >= Self.threeColumnWidth ? 3 : 2

    if wanted != columns {
      columns = wanted
      place()
    }
  }

  /// Pins each row under the one before; the other pills of a row share its first pill's top and bottom.
  private func place() {
    NSLayoutConstraint.deactivate(placement)
    placement = []
    var above = topAnchor
    var gap = 0.0
    let count = CGFloat(columns)

    for index in stride(from: 0, to: pills.count, by: columns) {
      let row = pills[index..<min(index + columns, pills.count)]
      let first = pills[index]
      placement.append(first.topAnchor.constraint(equalTo: above, constant: gap))

      for (column, pill) in row.enumerated() {
        placement += [
          pill.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 1 / count, constant: -Self.spacing * (count - 1) / count),
          column == 0 ? pill.leadingAnchor.constraint(equalTo: leadingAnchor) : pill.leadingAnchor.constraint(equalTo: pills[index + column - 1].trailingAnchor, constant: Self.spacing)
        ]

        if column > 0 { placement += [pill.topAnchor.constraint(equalTo: first.topAnchor), pill.bottomAnchor.constraint(equalTo: first.bottomAnchor)] }
      }

      above = first.bottomAnchor
      gap = Self.spacing
    }

    placement.append(bottomAnchor.constraint(equalTo: above))
    NSLayoutConstraint.activate(placement)
  }

  @objc private func openPill(_ sender: SessionPill) {
    onOpen(sender.session)
  }
}

/// A blank conversation's page: this project's sessions, those that wait on you, run or are unread first.
/// See History swaps it for every session in the project.
final class StartPageView: NSView {
  var onOpen: (Session) -> Void = { _ in } {
    didSet {
      grid.onOpen = onOpen
      history.onOpen = onOpen
    }
  }
  let history = HistoryView()
  var showsHistory = false {
    didSet {
      startScroll.isHidden = showsHistory
      historyPane.isHidden = !showsHistory
    }
  }
  private let startScroll = NSScrollView()
  private let historyPane = NSStackView()
  private let page = NSStackView()
  private let grid = PillGrid()
  private let showAll = NSButton(title: "Show All", target: nil, action: nil)
  /// The sessions last shown, kept for Show All.
  private var sessions: [Session] = []
  /// How many sessions lead the list and always show.
  private var leading = 0
  private var showsAll = false
  /// The ids of the sessions shown.
  private var shown: [String]?

  init() {
    super.init(frame: .zero)

    let document = StartPageDocument()
    document.translatesAutoresizingMaskIntoConstraints = false
    page.orientation = .vertical
    page.alignment = .leading
    page.spacing = 14
    page.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(page)
    startScroll.documentView = document
    startScroll.drawsBackground = false
    startScroll.hasVerticalScroller = true
    startScroll.autohidesScrollers = true
    grid.translatesAutoresizingMaskIntoConstraints = false

    showAll.isBordered = false
    showAll.contentTintColor = .startLink
    showAll.font = .systemFont(ofSize: 13)
    showAll.imagePosition = .imageTrailing
    showAll.target = self
    showAll.action = #selector(toggleShowAll(_:))
    let links = NSStackView(views: [linkButton("See History"), showAll])
    links.spacing = 16
    links.setHuggingPriority(.defaultHigh, for: .horizontal)
    let sessionsHeading = headingRow("Sessions", trailing: links)
    page.setViews([sessionsHeading, grid], in: .top)

    let search = NSSearchField()
    search.placeholderString = "Search History"
    search.target = self
    search.action = #selector(searchHistory(_:))
    search.widthAnchor.constraint(equalToConstant: 200).isActive = true

    let trailing = NSStackView(views: [search, linkButton("Hide History")])
    trailing.spacing = 16
    let historyHeading = headingRow("History", trailing: trailing)
    historyPane.orientation = .vertical
    historyPane.alignment = .centerX
    historyPane.spacing = 10
    historyPane.edgeInsets = NSEdgeInsets(top: 24, left: 0, bottom: 0, right: 0)
    historyPane.setViews([historyHeading, history], in: .top)
    historyPane.isHidden = true

    // Below the window's own size priorities, or the cap on the page's width would cap the window too.
    let fill = page.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -48)
    fill.priority = .dragThatCannotResizeWindow

    for view in [startScroll, historyPane] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
      NSLayoutConstraint.activate([
        view.topAnchor.constraint(equalTo: topAnchor),
        view.bottomAnchor.constraint(equalTo: bottomAnchor),
        view.leadingAnchor.constraint(equalTo: leadingAnchor),
        view.trailingAnchor.constraint(equalTo: trailingAnchor)
      ])
    }

    NSLayoutConstraint.activate([
      document.topAnchor.constraint(equalTo: startScroll.contentView.topAnchor),
      document.leadingAnchor.constraint(equalTo: startScroll.contentView.leadingAnchor),
      document.trailingAnchor.constraint(equalTo: startScroll.contentView.trailingAnchor),
      page.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
      page.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
      page.centerXAnchor.constraint(equalTo: document.centerXAnchor),
      page.widthAnchor.constraint(lessThanOrEqualToConstant: 1040),
      fill,
      sessionsHeading.widthAnchor.constraint(equalTo: page.widthAnchor),
      grid.widthAnchor.constraint(equalTo: page.widthAnchor),
      historyHeading.widthAnchor.constraint(equalTo: historyPane.widthAnchor, constant: -48),
      history.widthAnchor.constraint(equalTo: historyPane.widthAnchor)
    ])
    show([], leading: 0)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("StartPageView is built in code") }

  /// Shows the first `leading` sessions and enough of the rest to make six, or every session after Show All.
  func show(_ sessions: [Session], leading: Int) {
    self.sessions = sessions
    self.leading = leading
    let visible = showsAll ? sessions : Array(sessions.prefix(max(6, leading)))
    let ids = visible.map(\.id)
    showAll.isHidden = !showsAll && sessions.count <= visible.count
    showAll.title = showsAll ? "Show Less" : "Show All"
    showAll.image = NSImage(systemSymbolName: showsAll ? "chevron.down" : "chevron.right", accessibilityDescription: nil)

    if ids == shown {
      for pill in grid.pills { pill.update() }
      return
    }

    shown = ids
    grid.show(visible)
  }

  /// The session a pill's or a history row's control belongs to.
  func session(for control: NSView) -> Session? {
    sequence(first: control, next: \.superview).lazy.compactMap { ($0 as? SessionPill)?.session }.first ?? history.session(for: control)
  }

  private func headingRow(_ title: String, trailing: NSView) -> NSStackView {
    let heading = NSTextField(labelWithString: title)
    heading.font = .systemFont(ofSize: 22, weight: .bold)
    heading.textColor = .startHeading
    let row = NSStackView()
    row.alignment = .centerY
    row.setViews([heading], in: .leading)
    row.setViews([trailing], in: .trailing)
    return row
  }

  /// See History and Hide History, which send View > Show History through the responder chain.
  private func linkButton(_ title: String) -> NSButton {
    let button = NSButton(title: title, target: nil, action: #selector(ConversationController.toggleHistory(_:)))
    button.isBordered = false
    button.contentTintColor = .startLink
    button.font = .systemFont(ofSize: 13)
    return button
  }

  @objc private func toggleShowAll(_ sender: Any?) {
    showsAll.toggle()
    show(sessions, leading: leading)
  }

  @objc private func searchHistory(_ sender: NSSearchField) {
    history.search = sender.stringValue
  }
}

/// The start page's scrolling content, laid out from the top.
private final class StartPageDocument: NSView {
  override var isFlipped: Bool { true }
}
