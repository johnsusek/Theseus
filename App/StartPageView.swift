import AppKit
import ClaudeWorkspace

/// A session on the start page: a rounded button with its status mark, its title, what it is doing or asks under the title
/// (else how its last turn closed), the controls that answer a request, and when it was last active.
final class SessionPill: NSButton {
  static let height = 48.0
  let session: Session
  private let mark = RowStatusMark()
  private let titleLabel = cellLabel()
  private let detail = cellLabel(.secondaryLabelColor)
  /// The Activity column's cell without its text: Deny and Allow, Answer, or Review.
  private let answers = ActivityCellView()
  private let date = cellLabel(.secondaryLabelColor)
  private lazy var centered = titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
  private lazy var raised = titleLabel.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1)
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
    titleLabel.font = .systemFont(ofSize: 14)
    date.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    date.setContentCompressionResistancePriority(.required, for: .horizontal)
    answers.translatesAutoresizingMaskIntoConstraints = false

    for view in [mark, titleLabel, detail, answers, date] { addSubview(view) }

    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))

    // As narrow as its buttons allow, and nothing without a request.
    let narrow = answers.widthAnchor.constraint(equalToConstant: 0)
    narrow.priority = NSLayoutConstraint.Priority(200)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: Self.height),
      mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      mark.centerYAnchor.constraint(equalTo: centerYAnchor),
      titleLabel.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 6),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: answers.leadingAnchor, constant: -8),
      detail.topAnchor.constraint(equalTo: centerYAnchor, constant: 1),
      detail.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      detail.trailingAnchor.constraint(lessThanOrEqualTo: answers.leadingAnchor, constant: -8),
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
    NSLayoutConstraint.deactivate([centered, raised])
    (activity.isEmpty ? centered : raised).isActive = true
  }

  /// A click anywhere is a click on the pill, except on the answer controls.
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let hit = super.hitTest(point) else { return nil }

    return hit.isDescendant(of: answers) ? hit : self
  }

  override func draw(_ dirtyRect: NSRect) {
    let fill: NSColor

    if isHighlighted {
      fill = .systemFill
    } else if isHovered {
      fill = .secondarySystemFill
    } else {
      fill = .tertiarySystemFill
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

/// A blank conversation's page: this project's sessions that wait on you, run or are unread, and its recent ones.
/// See History swaps it for every session in the project.
final class StartPageView: NSView {
  var onOpen: (Session) -> Void = { _ in } {
    didSet { history.onOpen = onOpen }
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
  /// Waiting, running and unread sessions, two to a row.
  private let list = NSStackView()
  private let recentList = NSStackView()
  private let viewMore = NSButton(title: "View More", target: nil, action: nil)
  /// The sessions last shown, kept for View More. The recent list shows the first `recentLimit` of `recent`.
  private var sessions: [Session] = []
  private var recent: [Session] = []
  private var recentLimit = 6
  private var pills: [SessionPill] = []
  /// The ids of the sessions in each list.
  private var shown: [[String]]?

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

    for stack in [list, recentList] {
      stack.orientation = .vertical
      stack.spacing = 10
    }

    let recentHeading = headingRow("Recent Sessions", trailing: linkButton("See History"))
    viewMore.isBordered = false
    viewMore.contentTintColor = .linkColor
    viewMore.font = .systemFont(ofSize: 14)
    viewMore.target = self
    viewMore.action = #selector(showMoreRecent(_:))
    page.setViews([heading("Sessions"), list, recentHeading, recentList, viewMore], in: .top)
    page.setCustomSpacing(32, after: list)

    let search = NSSearchField()
    search.placeholderString = "Search History"
    search.target = self
    search.action = #selector(searchHistory(_:))
    search.widthAnchor.constraint(equalToConstant: 200).isActive = true

    let trailing = NSStackView(views: [search, linkButton("Hide History")])
    trailing.spacing = 16
    let historyHeading = headingRow("History", trailing: trailing)
    historyPane.orientation = .vertical
    historyPane.alignment = .leading
    historyPane.spacing = 10
    historyPane.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 0, right: 24)
    historyPane.setViews([historyHeading, history], in: .top)
    historyPane.isHidden = true

    // Below the window's own size priorities, or the 720 pt cap on the page would cap the window too.
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
      page.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
      fill,
      list.widthAnchor.constraint(equalTo: page.widthAnchor),
      // Two rows of pills, so Recent Sessions starts in the same place however many sessions there are.
      list.heightAnchor.constraint(greaterThanOrEqualToConstant: SessionPill.height * 2 + list.spacing),
      recentHeading.widthAnchor.constraint(equalTo: page.widthAnchor),
      recentList.widthAnchor.constraint(equalTo: page.widthAnchor),
      historyHeading.widthAnchor.constraint(equalTo: historyPane.widthAnchor, constant: -48),
      history.widthAnchor.constraint(equalTo: historyPane.widthAnchor, constant: -48)
    ])
    show(sessions: [], recent: [])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("StartPageView is built in code") }

  /// Rebuilds the pills when their sessions changed and otherwise updates them. `recent` is newest first; the list shows six more with each View More.
  func show(sessions: [Session], recent: [Session]) {
    self.sessions = sessions
    self.recent = recent
    let shownRecent = Array(recent.prefix(recentLimit))
    let ids = [sessions.map(\.id), shownRecent.map(\.id)]
    viewMore.isHidden = recent.count <= recentLimit

    if ids == shown {
      for pill in pills { pill.update() }
      return
    }

    shown = ids
    pills = []
    fill(list, with: sessions)
    fill(recentList, with: shownRecent)
  }

  /// The session a pill's or a history row's control belongs to.
  func session(for control: NSView) -> Session? {
    sequence(first: control, next: \.superview).lazy.compactMap { ($0 as? SessionPill)?.session }.first ?? history.session(for: control)
  }

  /// Puts a pill for each session in `stack`, two to a row.
  private func fill(_ stack: NSStackView, with sessions: [Session]) {
    let made = sessions.map(SessionPill.init)
    pills += made

    for pill in made {
      pill.target = self
      pill.action = #selector(openPill(_:))
    }

    let rows = stride(from: 0, to: made.count, by: 2).map { index in
      let row = NSStackView(views: [made[index], index + 1 < made.count ? made[index + 1] : NSView()])
      row.distribution = .fillEqually
      row.spacing = 10
      return row
    }
    stack.setViews(rows, in: .top)
    NSLayoutConstraint.activate(rows.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
  }

  private func heading(_ title: String) -> NSTextField {
    let heading = NSTextField(labelWithString: title)
    heading.font = .systemFont(ofSize: 22, weight: .bold)
    return heading
  }

  private func headingRow(_ title: String, trailing: NSView) -> NSStackView {
    let row = NSStackView()
    row.alignment = .centerY
    row.setViews([heading(title)], in: .leading)
    row.setViews([trailing], in: .trailing)
    return row
  }

  /// See History and Hide History, which send View > Show History through the responder chain.
  private func linkButton(_ title: String) -> NSButton {
    let button = NSButton(title: title, target: nil, action: #selector(ConversationController.toggleHistory(_:)))
    button.isBordered = false
    button.contentTintColor = .linkColor
    button.font = .systemFont(ofSize: 14)
    return button
  }

  @objc private func showMoreRecent(_ sender: Any?) {
    recentLimit += 6
    show(sessions: sessions, recent: recent)
  }

  @objc private func searchHistory(_ sender: NSSearchField) {
    history.search = sender.stringValue
  }

  @objc private func openPill(_ sender: SessionPill) {
    onOpen(sender.session)
  }
}

/// The start page's scrolling content, laid out from the top.
private final class StartPageDocument: NSView {
  override var isFlipped: Bool { true }
}
