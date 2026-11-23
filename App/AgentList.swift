import AppKit

/// The agents popover: every agent of the session, running ones first, with Stop in its context menu.
final class AgentListController: ListController, NSMenuItemValidation {
  /// Stops the given agents.
  var onStop: ([AgentRow]) -> Void = { _ in }

  var rows: [AgentRow] = [] {
    didSet {
      guard rows != oldValue else { return }

      reload(rows.map(\.id))
      updateTicker()
    }
  }

  private var ticker: Task<Void, Never>?

  init() {
    super.init(rowHeight: 42, visibleRows: 6, label: "Agents")
  }

  private var isShown = false

  /// The agents the context menu is for that can be stopped.
  private var stoppable: [AgentRow] { rows.filter { menuIds.contains($0.id) && $0.state == .running && $0.taskId != nil } }

  override func loadView() {
    super.loadView()
    setMenu([("Stop", #selector(stopAgents(_:)))])
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    isShown = true
    updateTicker()
  }

  override func viewDidDisappear() {
    super.viewDidDisappear()
    isShown = false
    updateTicker()
  }

  /// A running agent's elapsed time counts up once a second while the list is on screen.
  private func updateTicker() {
    let isNeeded = isShown && rows.contains { $0.state == .running }

    if isNeeded, ticker == nil {
      ticker = everySecond(self) { list in
        for row in 0..<list.tableView.numberOfRows { (list.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? AgentCellView)?.showElapsed() }
      }
    } else if !isNeeded {
      ticker?.cancel()
      ticker = nil
    }
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let identifier = NSUserInterfaceItemIdentifier("agent")
    let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? AgentCellView ?? AgentCellView()

    cell.identifier = identifier
    cell.row = rows[row]
    return cell
  }

  func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? { rows[row].title }

  @objc private func stopAgents(_ sender: Any?) {
    onStop(stoppable)
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { !stoppable.isEmpty }
}

/// One agent: a spinner or a mark, its description over its type and what it is doing, and its time over its tokens.
final class AgentCellView: NSTableCellView {
  var row: AgentRow? {
    didSet {
      if row != oldValue { show() }
    }
  }

  private static let callout = NSFont.systemFont(ofSize: 12)
  private static let digits = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
  private let spinner = NSProgressIndicator()
  private let mark = NSImageView()
  private let title = NSTextField(labelWithString: "")
  private let detail = NSTextField(labelWithString: "")
  private let elapsed = NSTextField(labelWithString: "")
  private let tokens = NSTextField(labelWithString: "")

  init() {
    super.init(frame: .zero)
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    spinner.setAccessibilityLabel("Running")
    title.lineBreakMode = .byTruncatingTail
    detail.font = Self.callout
    detail.textColor = .secondaryLabelColor
    detail.lineBreakMode = .byTruncatingMiddle

    for label in [elapsed, tokens] {
      label.font = Self.digits
      label.textColor = .secondaryLabelColor
      label.alignment = .right
    }

    // The labels are the cell's own subviews, so each takes the row's selected text color.
    for label in [title, detail] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }

    for label in [elapsed, tokens] {
      label.setContentHuggingPriority(.required, for: .horizontal)
      label.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    for view in [spinner, mark, title, detail, elapsed, tokens] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }

    textField = title

    NSLayoutConstraint.activate([
      spinner.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
      mark.centerXAnchor.constraint(equalTo: spinner.centerXAnchor),
      mark.centerYAnchor.constraint(equalTo: centerYAnchor),
      title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
      title.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      title.trailingAnchor.constraint(lessThanOrEqualTo: elapsed.leadingAnchor, constant: -8),
      detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
      detail.trailingAnchor.constraint(lessThanOrEqualTo: tokens.leadingAnchor, constant: -8),
      elapsed.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
      elapsed.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
      tokens.trailingAnchor.constraint(equalTo: elapsed.trailingAnchor),
      tokens.firstBaselineAnchor.constraint(equalTo: detail.firstBaselineAnchor)
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("AgentCellView is built in code") }

  private func show() {
    guard let row else { return }

    let symbols: [AgentRow.State: (name: String, label: String, color: NSColor)] = [
      .done: ("checkmark", "Finished", .secondaryLabelColor),
      .failed: ("exclamationmark.circle.fill", "Failed", .systemRed),
      .stopped: ("stop.circle", "Stopped", .secondaryLabelColor)
    ]

    title.stringValue = row.title
    detail.stringValue = row.detail
    tokens.stringValue = row.tokens
    toolTip = row.detail
    mark.isHidden = row.state == .running

    if let symbol = symbols[row.state] {
      mark.image = NSImage(systemSymbolName: symbol.name, accessibilityDescription: symbol.label)
      mark.contentTintColor = symbol.color
      spinner.stopAnimation(nil)
    } else {
      spinner.startAnimation(nil)
    }

    showElapsed()
  }

  /// A running agent's time since it started, or how long a finished one took.
  func showElapsed() {
    guard let row else { return }

    var seconds = row.duration.map { Int($0.components.seconds) }

    if row.state == .running { seconds = row.startedAt.map { max(Int(Date.now.timeIntervalSince($0)), 0) } }

    elapsed.stringValue = seconds.map(elapsedText) ?? ""
  }
}
