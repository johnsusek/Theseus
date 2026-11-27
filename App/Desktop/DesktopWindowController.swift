import AppKit
import StagehandShared

/// Window > Private Desktop: the setup checklist until every item passes, then a read-only live view of its screen, streamed while the window shows.
@MainActor
final class DesktopWindowController: NSWindowController, NSWindowDelegate {
  private let desktop: PrivateDesktop
  private let checklist = NSStackView()
  private var rows: [DesktopItem: (icon: NSImageView, fix: NSTextField)] = [:]
  private let checkAgain = NSButton(title: "Check Again", target: nil, action: nil)
  private let screen = NSImageView()
  private let takeOver = NSButton(title: "Take Over", target: nil, action: nil)
  private let accessory = NSTitlebarAccessoryViewController()
  private var stream: Task<Void, Never>?

  init(desktop: PrivateDesktop) {
    self.desktop = desktop
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
    window.title = "Private Desktop"
    window.minSize = NSSize(width: 480, height: 320)
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    window.setFrameAutosaveName("PrivateDesktop")
    if window.frame.origin == .zero { window.center() }

    build(in: window)
    keepCurrent(self) { $0.update() }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("DesktopWindowController is built in code") }

  private func build(in window: NSWindow) {
    let content = NSView()
    window.contentView = content

    screen.imageScaling = .scaleProportionallyUpOrDown
    screen.wantsLayer = true
    screen.layer?.backgroundColor = NSColor.black.cgColor
    screen.setAccessibilityLabel("Private Desktop screen")

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
      fix.preferredMaxLayoutWidth = 420
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

    takeOver.bezelStyle = .accessoryBarAction
    takeOver.target = self
    takeOver.action = #selector(toggleTakeOver(_:))
    takeOver.toolTip = "Stops Claude from driving the Private Desktop until you hand it back"
    let holder = NSView()
    holder.frame = NSRect(x: 0, y: 0, width: takeOver.fittingSize.width + 24, height: 28)
    takeOver.frame.origin = NSPoint(x: 8, y: (28 - takeOver.fittingSize.height) / 2)
    takeOver.setFrameSize(takeOver.fittingSize)
    holder.addSubview(takeOver)
    accessory.view = holder
    accessory.layoutAttribute = .trailing
    window.addTitlebarAccessoryViewController(accessory)

    for view in [screen, checklist] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(view)
    }

    NSLayoutConstraint.activate([
      screen.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      screen.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      screen.topAnchor.constraint(equalTo: content.topAnchor),
      screen.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      checklist.centerXAnchor.constraint(equalTo: content.centerXAnchor),
      checklist.centerYAnchor.constraint(equalTo: content.centerYAnchor),
      checklist.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -40)
    ])
  }

  private func update() {
    let isOn = desktop.isOn
    screen.isHidden = !isOn
    checklist.isHidden = isOn
    accessory.isHidden = !isOn
    takeOver.title = desktop.isTakenByUser ? "Hand Back" : "Take Over"
    window?.title = desktop.holder?.title ?? "Private Desktop"
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

  /// Streams frames only while the screen view shows in a visible window.
  private func streamIfVisible() {
    let visible = desktop.isOn && window?.isVisible == true && window?.occlusionState.contains(.visible) == true

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

          screen.image = NSImage(data: frame)
        }
      } catch {
        log.error("Private Desktop stream ended: \(error)")
      }

      // A cancelled stream was replaced or stopped on purpose; one that ended by itself starts again on the next update.
      if !Task.isCancelled { self?.stream = nil }
    }
  }

  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    Task { await desktop.check() }
  }

  @objc private func checkAgain(_ sender: Any?) {
    Task { await desktop.check() }
  }

  @objc private func toggleTakeOver(_ sender: Any?) {
    desktop.isTakenByUser.toggle()
  }

  func windowDidChangeOcclusionState(_ notification: Notification) { streamIfVisible() }

  func windowWillClose(_ notification: Notification) {
    stream?.cancel()
    stream = nil
  }
}
