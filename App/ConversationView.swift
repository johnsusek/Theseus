import AppKit

/// A conversation window's content: the transcript and the prompt field floating over its bottom edge.
/// A blank conversation shows its picks centered above the prompt.
final class ConversationView: NSView {
  let transcript = TranscriptView()
  let prompt = PromptField()
  let picks = NewConversationView()

  init() {
    super.init(frame: .zero)
    prompt.textView.finder = transcript.textView

    let above = NSLayoutGuide()
    addLayoutGuide(above)

    for view in [transcript, picks, prompt] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }

    NSLayoutConstraint.activate([
      widthAnchor.constraint(greaterThanOrEqualToConstant: 500),
      heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
      transcript.topAnchor.constraint(equalTo: topAnchor),
      transcript.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
      transcript.leadingAnchor.constraint(equalTo: leadingAnchor),
      transcript.trailingAnchor.constraint(equalTo: trailingAnchor),
      prompt.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      prompt.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      prompt.bottomAnchor.constraint(equalTo: transcript.bottomAnchor),
      above.topAnchor.constraint(equalTo: topAnchor),
      above.bottomAnchor.constraint(equalTo: prompt.topAnchor),
      picks.centerXAnchor.constraint(equalTo: centerXAnchor),
      picks.centerYAnchor.constraint(equalTo: above.centerYAnchor)
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("ConversationView is built in code") }

  /// The transcript's last lines scroll clear of the field, however tall the draft makes it.
  override func layout() {
    super.layout()
    transcript.bottomInset = prompt.frame.height + 8
  }
}
