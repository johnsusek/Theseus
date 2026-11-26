import AppKit

/// A conversation window's content: the transcript and the prompt field floating over its bottom edge.
/// A blank conversation shows the start page, and its picks just above the prompt.
final class ConversationView: NSView {
  let transcript = TranscriptView()
  let prompt = PromptField()
  let picks = NewConversationView()
  let startPage = StartPageView()

  init() {
    super.init(frame: .zero)
    prompt.textView.finder = transcript.textView

    for view in [transcript, startPage, picks, prompt] {
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
      startPage.topAnchor.constraint(equalTo: topAnchor),
      startPage.leadingAnchor.constraint(equalTo: leadingAnchor),
      startPage.trailingAnchor.constraint(equalTo: trailingAnchor),
      startPage.bottomAnchor.constraint(equalTo: picks.topAnchor, constant: -12),
      picks.centerXAnchor.constraint(equalTo: centerXAnchor),
      picks.bottomAnchor.constraint(equalTo: prompt.topAnchor, constant: -10)
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
