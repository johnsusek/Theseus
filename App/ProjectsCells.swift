import AppKit
import ClaudeEngine
import ClaudeWorkspace

/// The Projects window's answers, which a row's buttons send through the responder chain to the window's controller.
@MainActor @objc protocol RowRequestActions {
  func allowRow(_ sender: NSControl)
  func denyRow(_ sender: NSControl)
  func answerRow(_ sender: NSPopUpButton)
  func reviewRow(_ sender: NSControl)
}

extension ProjectsColumn {
  /// The column with its widths and sort. Context starts hidden.
  func makeTableColumn() -> NSTableColumn {
    let column = NSTableColumn(identifier: identifier)
    let widths: [ProjectsColumn: (CGFloat, CGFloat)] = [.title: (200, 300), .status: (200, 320), .tasks: (70, 86), .changes: (60, 80), .context: (50, 60), .location: (90, 150), .updated: (70, 90)]

    column.title = heading
    column.minWidth = widths[self]?.0 ?? 60
    column.width = widths[self]?.1 ?? 80
    column.resizingMask = self == .title || self == .status ? [.autoresizingMask, .userResizingMask] : .userResizingMask
    // The status sort puts what needs you first; Updated puts the newest first.
    column.sortDescriptorPrototype = NSSortDescriptor(key: rawValue, ascending: self != .updated && self != .changes && self != .context && self != .tasks)
    column.isHidden = self == .context
    return column
  }

  /// A new cell for this column's rows.
  func makeCell() -> NSView {
    let cell: NSView

    switch self {
    case .title: cell = NameCellView()
    case .status: cell = ActivityCellView()
    case .tasks: cell = TaskCellView()
    case .changes: cell = ChangesCellView()
    case .context: cell = TextCellView(alignment: .right)
    case .location: cell = TextCellView(truncation: .byTruncatingMiddle)
    case .updated: cell = TextCellView()
    }

    cell.identifier = identifier
    return cell
  }
}

/// Puts a session's values for `column` in a cell from `ProjectsColumn.makeCell`.
@MainActor
func configureCell(_ view: NSView, _ column: ProjectsColumn, _ session: Session) {
  switch column {
  case .title:
    (view as? NameCellView)?.show(title: session.rowTitle, status: session.rowStatus, isUnread: session.isUnread, isDimmed: session.isArchived)
  case .status:
    (view as? ActivityCellView)?.show(session.activityText, request: session.request)
  case .tasks:
    (view as? TaskCellView)?.show(done: session.tasksDone, total: session.tasksTotal)
  case .changes:
    (view as? ChangesCellView)?.show(added: session.linesAdded, removed: session.linesRemoved, counts: !session.transcript.changedFiles.isEmpty)
  case .context:
    (view as? NSTableCellView)?.textField?.stringValue = session.contextFraction.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? ""
  case .location:
    // A pinned session is listed outside its project, so its location names the project.
    let location = session.isPinned ? [session.project?.name ?? "", session.location].filter { !$0.isEmpty }.joined(separator: " · ") : session.location
    (view as? NSTableCellView)?.textField?.stringValue = location
    (view as? NSTableCellView)?.textField?.toolTip = session.workingDirectory.path
  case .updated:
    (view as? NSTableCellView)?.textField?.stringValue = updatedText(session.lastActive, now: .now)
  }
}

/// A label for a table cell: one line, truncated, in the system font.
@MainActor
func cellLabel(_ color: NSColor = .labelColor, truncation: NSLineBreakMode = .byTruncatingTail) -> NSTextField {
  let label = NSTextField(labelWithString: "")
  label.textColor = color
  label.lineBreakMode = truncation
  label.translatesAutoresizingMaskIntoConstraints = false
  label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  return label
}

/// A cell whose label fills it, centered vertically.
final class TextCellView: NSTableCellView {
  init(color: NSColor = .secondaryLabelColor, truncation: NSLineBreakMode = .byTruncatingTail, alignment: NSTextAlignment = .natural) {
    super.init(frame: .zero)
    let label = cellLabel(color, truncation: truncation)

    label.alignment = alignment
    textField = label
    addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
      label.centerYAnchor.constraint(equalTo: centerYAnchor)
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("TextCellView is built in code") }
}

/// A session's status as a mark: a spinner while running, a yellow dot while waiting, a cross after a failure, a dot while unread.
/// A group passes a symbol instead. The mark has a fixed slot, so titles beside it line up.
final class RowStatusMark: NSView {
  private let mark = NSImageView()
  private let spinner = NSProgressIndicator()

  private let spinnerSize: Double
  /// The one size of every dot and cross in a compact mark; a table row's marks keep their own sizes.
  private let dotSize: Double?

  /// A compact mark has a smaller spinner and same-size dots, for a start page pill's corner.
  init(compact: Bool = false) {
    spinnerSize = compact ? 12 : 14
    dotSize = compact ? 9 : nil
    super.init(frame: .zero)
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    spinner.toolTip = RowStatus.running.title
    spinner.setAccessibilityLabel(RowStatus.running.title)
    translatesAutoresizingMaskIntoConstraints = false

    for view in [mark, spinner] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }

    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: 20),
      heightAnchor.constraint(equalToConstant: 16),
      mark.centerXAnchor.constraint(equalTo: centerXAnchor),
      mark.centerYAnchor.constraint(equalTo: centerYAnchor),
      spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
      spinner.widthAnchor.constraint(equalToConstant: spinnerSize),
      spinner.heightAnchor.constraint(equalToConstant: spinnerSize)
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("RowStatusMark is built in code") }

  /// An unread session that is not waiting, failed or running shows a dot.
  func show(status: RowStatus? = nil, symbol: String? = nil, isUnread: Bool = false) {
    if status == .running {
      spinner.startAnimation(nil)
    } else {
      spinner.stopAnimation(nil)
    }

    mark.image = nil
    mark.toolTip = status?.title
    mark.symbolConfiguration = nil

    switch status {
    case .waiting:
      mark.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: RowStatus.waiting.title)
      mark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: dotSize ?? 9, weight: .regular)
      mark.contentTintColor = .systemYellow
    case .failed:
      mark.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: RowStatus.failed.title)
      mark.symbolConfiguration = dotSize.map { NSImage.SymbolConfiguration(pointSize: $0, weight: .regular) }
      mark.contentTintColor = .systemRed
    case .finished where isUnread, .closed where isUnread:
      mark.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Unread")
      mark.toolTip = "Unread"
      mark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: dotSize ?? 7, weight: .regular)
      mark.contentTintColor = .controlAccentColor
    default:
      mark.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
      mark.contentTintColor = .secondaryLabelColor
    }
  }
}

/// The Name column: a session's status mark or a group's symbol, then the title.
final class NameCellView: NSTableCellView {
  private let mark = RowStatusMark()

  init() {
    super.init(frame: .zero)
    let label = cellLabel()

    textField = label
    addSubview(mark)
    addSubview(label)

    NSLayoutConstraint.activate([
      mark.leadingAnchor.constraint(equalTo: leadingAnchor),
      mark.centerYAnchor.constraint(equalTo: centerYAnchor),
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
      label.centerYAnchor.constraint(equalTo: centerYAnchor)
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("NameCellView is built in code") }

  /// A session's row passes its status; a group's passes its symbol.
  func show(title: String, status: RowStatus? = nil, symbol: String? = nil, isUnread: Bool = false, isDimmed: Bool = false) {
    textField?.stringValue = title
    textField?.textColor = isDimmed ? .secondaryLabelColor : .labelColor
    toolTip = title
    mark.show(status: status, symbol: symbol, isUnread: isUnread)
  }
}

/// The Activity column: what the session is doing, and the smallest control that answers its request.
/// Deny and Allow for a permission, a pull-down of the options for one question, Answer… for several, Review for a plan.
final class ActivityCellView: NSTableCellView {
  private let deny = NSButton(title: "Deny", target: nil, action: #selector(RowRequestActions.denyRow(_:)))
  private let allow = NSButton(title: "Allow", target: nil, action: #selector(RowRequestActions.allowRow(_:)))
  private let answer = NSPopUpButton(frame: .zero, pullsDown: true)
  private let review = NSButton(title: "Review", target: nil, action: #selector(RowRequestActions.reviewRow(_:)))
  private let buttons = NSStackView()
  /// The request whose options the pull-down lists. Its menu is rebuilt only for another request, so an open menu stays put.
  private var listedRequest: String?

  init() {
    super.init(frame: .zero)
    let label = cellLabel(.secondaryLabelColor)

    for button in [deny, allow, review] {
      button.controlSize = .small
      button.bezelStyle = .push
    }

    deny.toolTip = "Deny (Command-D)"
    allow.toolTip = "Allow (Command-Return)"
    answer.controlSize = .small
    answer.action = #selector(RowRequestActions.answerRow(_:))
    answer.addItem(withTitle: "Answer")
    buttons.orientation = .horizontal
    buttons.spacing = 4
    buttons.setViews([deny, allow, answer, review], in: .trailing)
    buttons.translatesAutoresizingMaskIntoConstraints = false
    buttons.setContentCompressionResistancePriority(.required, for: .horizontal)
    textField = label
    addSubview(label)
    addSubview(buttons)

    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      buttons.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 6),
      buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
      buttons.centerYAnchor.constraint(equalTo: centerYAnchor)
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("ActivityCellView is built in code") }

  /// `request` is the session's oldest open request, which the cell offers to answer.
  func show(_ text: String, request: PermissionRequest?) {
    let kind = request.map(RequestKind.init)
    let questions = request?.questions ?? []
    let picksOne = questions.count == 1 && !questions[0].multiSelect

    textField?.stringValue = text
    textField?.textColor = request == nil ? .secondaryLabelColor : .labelColor
    textField?.toolTip = text
    deny.isHidden = kind != .permission
    allow.isHidden = kind != .permission
    answer.isHidden = kind != .question || !picksOne
    review.isHidden = kind != .plan && (kind != .question || picksOne)
    review.title = kind == .plan ? "Review" : "Answer…"
    review.toolTip = kind == .plan ? "Review the Plan (Command-Y)" : "Answer the Questions (Command-Y)"

    guard picksOne, kind == .question, request?.requestId != listedRequest else { return }

    listedRequest = request?.requestId
    // The pull-down shows its first item as its title; the rest are the options.
    answer.menu?.items = [NSMenuItem(title: "Answer", action: nil, keyEquivalent: "")] + questions[0].options.map { option in
      let item = NSMenuItem(title: option.label, action: nil, keyEquivalent: "")
      item.toolTip = option.description
      item.representedObject = option.label
      return item
    }
    answer.toolTip = questions[0].question
  }
}

/// The Tasks column: a bar and "3/5" while the session has a task list.
final class TaskCellView: NSTableCellView {
  private let bar = NSProgressIndicator()

  init() {
    super.init(frame: .zero)
    let label = cellLabel(.secondaryLabelColor)

    label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    bar.style = .bar
    bar.controlSize = .small
    bar.isIndeterminate = false
    bar.translatesAutoresizingMaskIntoConstraints = false
    textField = label
    addSubview(bar)
    addSubview(label)

    NSLayoutConstraint.activate([
      bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
      bar.widthAnchor.constraint(equalToConstant: 36),
      bar.centerYAnchor.constraint(equalTo: centerYAnchor),
      label.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 6),
      label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
      label.centerYAnchor.constraint(equalTo: centerYAnchor)
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("TaskCellView is built in code") }

  func show(done: Int, total: Int) {
    bar.isHidden = total == 0
    bar.maxValue = Double(max(total, 1))
    bar.doubleValue = Double(done)
    textField?.stringValue = total == 0 ? "" : "\(done)/\(total)"
    setAccessibilityValue(total == 0 ? nil : "\(done) of \(total) tasks done")
  }
}

/// The Changes column: "+12 -3", green and red except in a selected row.
final class ChangesCellView: NSTableCellView {
  private static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
  private var delta: (added: Int, removed: Int)?

  override var backgroundStyle: NSView.BackgroundStyle {
    didSet { render() }
  }

  init() {
    super.init(frame: .zero)
    let label = cellLabel(.secondaryLabelColor)

    textField = label
    addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
      label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
      label.centerYAnchor.constraint(equalTo: centerYAnchor)
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("ChangesCellView is built in code") }

  /// Nil for a row with no changes to count.
  func show(added: Int, removed: Int, counts: Bool) {
    delta = counts ? (added, removed) : nil
    render()
  }

  private func render() {
    guard let delta else {
      textField?.stringValue = ""
      return
    }

    textField?.attributedStringValue = lineDeltaText(added: delta.added, removed: delta.removed, font: Self.font, isActive: window?.isMainWindow ?? true, isEmphasized: backgroundStyle == .emphasized)
  }
}
