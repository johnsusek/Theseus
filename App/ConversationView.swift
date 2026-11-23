import AppKit

/// A conversation window's content: the transcript, with the prompt field floating over its bottom edge.
final class ConversationView: NSView {
  let transcript = TranscriptView()
  let prompt = PromptField()

  init() {
    super.init(frame: .zero)
    prompt.textView.finder = transcript.textView

    for view in [transcript, prompt] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }

    NSLayoutConstraint.activate([
      widthAnchor.constraint(greaterThanOrEqualToConstant: 500),
      heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
      transcript.topAnchor.constraint(equalTo: topAnchor),
      transcript.bottomAnchor.constraint(equalTo: bottomAnchor),
      transcript.leadingAnchor.constraint(equalTo: leadingAnchor),
      transcript.trailingAnchor.constraint(equalTo: trailingAnchor),
      prompt.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      prompt.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      prompt.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("ConversationView is built in code") }

  /// The transcript's last lines scroll clear of the field, however tall the draft makes it.
  override func layout() {
    super.layout()
    transcript.bottomInset = prompt.frame.maxY + 8
  }
}
