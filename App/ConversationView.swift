import AppKit

/// A conversation window's content, which runs under the see-through title bar: the transcript and the prompt field floating over its bottom edge.
/// A blank conversation shows the start page over a blur of what is behind the window, as Safari's start page does, and its picks just above the prompt.
final class ConversationView: NSView {
  let transcript = TranscriptView()
  let prompt = PromptField()
  let picks = NewConversationView()
  let startPage = StartPageView()
  private let backdrop = NSVisualEffectView()
  var showsStartPage: Bool {
    get { !startPage.isHidden }
    set {
      startPage.isHidden = !newValue
      backdrop.isHidden = !newValue
    }
  }

  init() {
    super.init(frame: .zero)
    prompt.textView.finder = transcript.textView
    backdrop.blendingMode = .behindWindow
    backdrop.material = .underWindowBackground

    for view in [transcript, backdrop, startPage, picks, prompt] {
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
      backdrop.topAnchor.constraint(equalTo: topAnchor),
      backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
      backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
      backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
      prompt.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      prompt.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      prompt.bottomAnchor.constraint(equalTo: transcript.bottomAnchor),
      startPage.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
      startPage.leadingAnchor.constraint(equalTo: leadingAnchor),
      startPage.trailingAnchor.constraint(equalTo: trailingAnchor),
      startPage.bottomAnchor.constraint(equalTo: picks.topAnchor, constant: -12),
      picks.centerXAnchor.constraint(equalTo: centerXAnchor),
      picks.bottomAnchor.constraint(equalTo: prompt.topAnchor, constant: -10)
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("ConversationView is built in code") }

  /// The transcript's first lines scroll clear of the title bar, and its last lines clear of the field, however tall the draft makes it.
  override func layout() {
    super.layout()
    transcript.topInset = safeAreaInsets.top
    transcript.bottomInset = prompt.frame.height + 8
  }
}
