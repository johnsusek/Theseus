import AppKit
import ClaudeEngine

/// The Projects window's answers, which a row's buttons send through the responder chain to the window's controller.
@MainActor @objc protocol RowRequestActions {
  func allowRow(_ sender: NSControl)
  func denyRow(_ sender: NSControl)
  func answerRow(_ sender: NSPopUpButton)
  func reviewRow(_ sender: NSControl)
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

/// The Name column: a session's status mark or a group's symbol, then the title. The mark has a fixed slot so titles line up.
final class NameCellView: NSTableCellView {
  private let mark = NSImageView()
  private let spinner = NSProgressIndicator()

  init() {
    super.init(frame: .zero)
    let label = cellLabel()

    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    spinner.toolTip = RowStatus.running.title
    spinner.setAccessibilityLabel(RowStatus.running.title)
    textField = label
    imageView = mark

    for view in [mark, spinner, label] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }

    NSLayoutConstraint.activate([
      mark.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      mark.centerYAnchor.constraint(equalTo: centerYAnchor),
      spinner.centerXAnchor.constraint(equalTo: mark.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
      spinner.widthAnchor.constraint(equalToConstant: 14),
      spinner.heightAnchor.constraint(equalToConstant: 14),
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
      label.centerYAnchor.constraint(equalTo: centerYAnchor)
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("NameCellView is built in code") }

  /// A session's row passes its status; a group's passes its symbol.
  func show(title: String, status: RowStatus? = nil, symbol: String? = nil, isDimmed: Bool = false) {
    textField?.stringValue = title
    textField?.textColor = isDimmed ? .secondaryLabelColor : .labelColor
    toolTip = title

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
      mark.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: RowStatus.waiting.title)
      mark.contentTintColor = .systemOrange
    case .failed:
      mark.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: RowStatus.failed.title)
      mark.contentTintColor = .systemRed
    case .finished:
      mark.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: RowStatus.finished.title)
      mark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 7, weight: .regular)
      mark.contentTintColor = .controlAccentColor
    default:
      mark.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
      mark.contentTintColor = .secondaryLabelColor
    }
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

    guard picksOne, kind == .question else { return }

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
