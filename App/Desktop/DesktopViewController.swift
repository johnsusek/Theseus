import AppKit
import StagehandShared

/// The Private Desktop's view, the same in a conversation's pane and in its own window: a bar, then the setup checklist until every
/// item passes, and after that its screen, scaled to fit and streamed while the view shows or picture in picture has it.
@MainActor
final class DesktopViewController: NSViewController {
  private let desktop: PrivateDesktop
  private let name = NSTextField(labelWithString: "Private Desktop")
  private let takeOver = NSButton(title: "Take Over", target: nil, action: nil)
  private let placement = barButton("macwindow.on.rectangle", "Detach Private Desktop", #selector(DesktopPane.togglePrivateDesktopDetached(_:)))
  private let pictureButton = barButton("pip.enter", "Enter Picture in Picture", #selector(DesktopPane.togglePictureInPicture(_:)))
  private let checklist = NSStackView()
  private var rows: [DesktopItem: (icon: NSImageView, fix: NSTextField)] = [:]
  private let checkAgain = NSButton(title: "Check Again", target: nil, action: nil)
  private let screen = DesktopScreenView()
  private var stream: Task<Void, Never>?
  let picture = DesktopPictureInPicture()

  var isInPictureInPicture: Bool { picture.isLive }
  /// Picture in picture starts from the screen as shown, and stops from anywhere.
  var canTogglePictureInPicture: Bool { picture.isLive || (picture.isSupported && desktop.isOn && view.window?.occlusionState.contains(.visible) == true) }

  init(desktop: PrivateDesktop) {
    self.desktop = desktop
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("DesktopViewController is built in code") }

  override func loadView() {
    let close = barButton("xmark", "Hide Private Desktop", #selector(DesktopPane.hidePrivateDesktop(_:)))
    let bar = NSStackView(views: [name, takeOver, pictureButton, placement, close])
    let rule = NSBox()
    let body = NSView()
    let column = NSStackView(views: [bar, rule, body])

    name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    name.lineBreakMode = .byTruncatingTail
    name.setContentHuggingPriority(.defaultLow, for: .horizontal)
    name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    takeOver.controlSize = .small
    takeOver.bezelStyle = .push
    takeOver.target = self
    takeOver.action = #selector(toggleTakeOver(_:))
    takeOver.toolTip = "Stops Claude from driving the Private Desktop until you hand it back"
    bar.orientation = .horizontal
    bar.spacing = 8
    bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 10)
    rule.boxType = .separator
    column.orientation = .vertical
    column.spacing = 0
    column.translatesAutoresizingMaskIntoConstraints = false

    buildChecklist()
    showPictureButton()
    picture.onChange = { [weak self] in
      self?.showPictureButton()
      self?.streamIfVisible()
    }

    for part in [screen, checklist] as [NSView] {
      part.translatesAutoresizingMaskIntoConstraints = false
      body.addSubview(part)
    }

    view = NSView()
    view.addSubview(column)

    NSLayoutConstraint.activate([
      column.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      column.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      column.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      column.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      view.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
      view.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
      screen.leadingAnchor.constraint(equalTo: body.leadingAnchor),
      screen.trailingAnchor.constraint(equalTo: body.trailingAnchor),
      screen.topAnchor.constraint(equalTo: body.topAnchor),
      screen.bottomAnchor.constraint(equalTo: body.bottomAnchor),
      checklist.centerXAnchor.constraint(equalTo: body.centerXAnchor),
      checklist.centerYAnchor.constraint(equalTo: body.centerYAnchor),
      checklist.widthAnchor.constraint(lessThanOrEqualTo: body.widthAnchor, constant: -40)
    ] + [bar, rule, body].map { $0.widthAnchor.constraint(equalTo: column.widthAnchor) })

    NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged(_:)), name: NSWindow.didChangeOcclusionStateNotification, object: nil)
    keepCurrent(self) { $0.update() }
  }

  private func buildChecklist() {
    checklist.orientation = .vertical
    checklist.alignment = .leading
    checklist.spacing = 14

    for item in DesktopItem.allCases {
      let icon = NSImageView()
      icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
      let title = NSTextField(labelWithString: item.title)
      title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
      let fix = NSTextField(wrappingLabelWithString: "")
      fix.textColor = .secondaryLabelColor
      fix.preferredMaxLayoutWidth = 260
      let text = NSStackView(views: [title, fix])
      text.orientation = .vertical
      text.alignment = .leading
      text.spacing = 2
      let row = NSStackView(views: [icon, text])
      row.alignment = .firstBaseline
      row.spacing = 8
      checklist.addArrangedSubview(row)
      rows[item] = (icon, fix)
    }

    checkAgain.target = self
    checkAgain.action = #selector(checkAgain(_:))
    checklist.addArrangedSubview(checkAgain)
    checklist.setCustomSpacing(20, after: checklist.arrangedSubviews[DesktopItem.allCases.count - 1])
  }

  /// The holder's title while a conversation drives it.
  var heading: String { desktop.holder?.title ?? "Private Desktop" }

  private func update() {
    let isOn = desktop.isOn
    screen.isHidden = !isOn
    checklist.isHidden = isOn
    takeOver.isHidden = !isOn
    pictureButton.isHidden = !isOn || !picture.isSupported
    takeOver.title = desktop.isTakenByUser ? "Hand Back" : "Take Over"
    name.stringValue = heading
    checkAgain.isEnabled = !desktop.isChecking
    let published = FileManager.default.fileExists(atPath: sharedRoot + "/install.sh")

    for (item, row) in rows {
      let status = desktop.statuses[item] ?? .unchecked
      let symbol = switch status {
      case .passed: ("checkmark.circle.fill", NSColor.systemGreen, "Passed")
      case .failed: ("xmark.circle.fill", NSColor.systemRed, "Failed")
      case .unchecked: ("circle", NSColor.tertiaryLabelColor, "Not checked")
      }

      row.icon.image = NSImage(systemSymbolName: symbol.0, accessibilityDescription: symbol.2)
      row.icon.contentTintColor = symbol.1
      row.fix.stringValue = item.fix(user: desktop.user, agentPublished: published)
      row.fix.isHidden = status != .failed
    }

    streamIfVisible()
  }

  /// Says where the view sits, on the bar's placement button.
  func placed(inPane: Bool) {
    loadViewIfNeeded()

    let label = inPane ? "Detach Private Desktop" : "Attach Private Desktop"

    placement.image = NSImage(systemSymbolName: inPane ? "macwindow.on.rectangle" : "sidebar.right", accessibilityDescription: label)
    placement.toolTip = label
    placement.setAccessibilityLabel(label)
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    streamIfVisible()
    Task { await desktop.check() }
  }

  override func viewDidDisappear() {
    super.viewDidDisappear()
    streamIfVisible()
  }

  @objc private func occlusionChanged(_ notification: Notification) {
    if notification.object as? NSWindow === view.window { streamIfVisible() }
  }

  /// Streams frames only while the screen shows in a visible window.
  private func streamIfVisible() {
    let visible = desktop.isOn && (picture.isLive || view.window?.occlusionState.contains(.visible) == true)

    if !visible {
      stream?.cancel()
      stream = nil
      return
    }

    guard stream == nil else { return }

    stream = Task { [weak self, socket = desktop.socket] in
      do {
        for try await frame in Stagehand.stream(socket: socket) {
          guard let self, !Task.isCancelled else { return }

          screen.show(frame)
          picture.show(frame)
        }
      } catch {
        log.error("Private Desktop stream ended: \(error)")
      }

      // A cancelled stream was replaced or stopped on purpose; one that ended by itself starts again on the next update.
      if !Task.isCancelled { self?.stream = nil }
    }
  }

  // MARK: Picture in picture

  private func showPictureButton() {
    let label = isInPictureInPicture ? "Exit Picture in Picture" : "Enter Picture in Picture"

    pictureButton.image = NSImage(systemSymbolName: isInPictureInPicture ? "pip.exit" : "pip.enter", accessibilityDescription: label)
    pictureButton.toolTip = label
    pictureButton.setAccessibilityLabel(label)
  }

  func togglePictureInPicture() {
    if picture.isLive { return picture.stop() }

    guard let window = view.window else { return }

    picture.start(over: window.convertToScreen(screen.convert(screen.bounds, to: nil)))
  }

  // MARK: Actions

  @objc private func checkAgain(_ sender: Any?) {
    Task { await desktop.check() }
  }

  @objc private func toggleTakeOver(_ sender: Any?) {
    desktop.isTakenByUser.toggle()
  }
}
