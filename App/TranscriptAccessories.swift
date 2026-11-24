import AppKit

/// A small borderless symbol button for the transcript's code blocks and turn footers.
@MainActor
private func symbolButton(_ symbol: String, label: String, target: AnyObject, action: Selector) -> NSButton {
  let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(), target: target, action: action)
  button.isBordered = false
  button.contentTintColor = .secondaryLabelColor
  button.toolTip = label
  button.frame.size = NSSize(width: 22, height: 18)
  return button
}

/// Copies a button's text, and shows a checkmark on it for a moment.
@MainActor
private func copyShowingCheck(_ text: String, from button: NSButton) {
  NSPasteboard.general.clearContents()
  NSPasteboard.general.setString(text, forType: .string)

  let image = button.image
  button.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")

  Task { @MainActor in
    try? await Task.sleep(for: .seconds(1.5))
    button.image = image
  }
}

/// Copy, and Run for a shell block, at the end of a code block's first line. Run goes up the responder chain to the conversation.
final class CodeButtonsView: NSView {
  let code: String
  private static let shells: Set = ["bash", "sh", "zsh", "shell", "console"]
  private static var attachments: [String: (attachment: NSTextAttachment, width: CGFloat)] = [:]

  /// The buttons for a block, shared by every render of the same code so unchanged text compares equal.
  static func attachment(code: String, language: String?) -> (attachment: NSTextAttachment, width: CGFloat) {
    let key = (language ?? "") + "\n" + code

    if let made = attachments[key] { return made }

    if attachments.count > 500 { attachments = [:] }

    let isRunnable = shells.contains(language?.lowercased() ?? "")
    let size = NSSize(width: isRunnable ? 44 : 22, height: 18)
    let made: (attachment: NSTextAttachment, width: CGFloat) = (ViewAttachment(size: size) { CodeButtonsView(code: code, isRunnable: isRunnable) }, size.width)
    attachments[key] = made
    return made
  }

  private init(code: String, isRunnable: Bool) {
    self.code = code
    super.init(frame: NSRect(x: 0, y: 0, width: isRunnable ? 44 : 22, height: 18))

    let copyButton = symbolButton("doc.on.doc", label: "Copy", target: self, action: #selector(copyCode(_:)))
    addSubview(copyButton)

    if isRunnable {
      let run = symbolButton("play", label: "Run in Terminal", target: self, action: #selector(run(_:)))
      addSubview(run)
      copyButton.frame.origin.x = 22
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("CodeButtonsView is built in code") }

  @objc private func copyCode(_ sender: NSButton) { copyShowingCheck(code, from: sender) }

  @objc private func run(_ sender: NSButton) { NSApp.sendAction(#selector(ConversationController.runInTerminal(_:)), to: nil, from: self) }
}

/// Under a finished turn: Copy for its replies, then its time and duration. It shows while the pointer is over its turn.
final class TurnFooterView: NSView, CardContent {
  let turn: Int
  private let replies: String

  override var isFlipped: Bool { true }

  init(footer: TurnFooter, turn: Int, isShown: Bool) {
    self.turn = turn
    replies = footer.replies
    super.init(frame: .zero)

    let label = NSTextField(labelWithString: footer.text)
    label.font = TranscriptStyle.calloutDigits
    label.textColor = .secondaryLabelColor
    label.isSelectable = true
    label.sizeToFit()

    var x = 0.0

    if !replies.isEmpty {
      let button = symbolButton("doc.on.doc", label: "Copy Reply", target: self, action: #selector(copyReplies(_:)))
      addSubview(button)
      x = button.frame.maxX + 6
    }

    label.frame.origin = NSPoint(x: x, y: 1)
    addSubview(label)
    alphaValue = isShown ? 1 : 0
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("TurnFooterView is built in code") }

  func height(for width: CGFloat) -> CGFloat { 18 }

  @objc private func copyReplies(_ sender: NSButton) { copyShowingCheck(replies, from: sender) }
}
