import AppKit

/// A conversation window's content: a title bar that blurs what is behind the window, as Safari's toolbar does, then the transcript and the prompt field floating over its bottom edge.
/// A blank conversation shows the start page over a blur of what is behind the window, as Safari's start page does, and its picks just above the prompt.
final class ConversationView: NSView {
  let transcript = TranscriptView()
  let prompt = PromptField()
  let picks = NewConversationView()
  let startPage = StartPageView()
  private let backdrop = NSVisualEffectView()
  /// Covers the title bar, and the tab bar when it shows, which the content runs under.
  private let titlebar = NSVisualEffectView()
  private let separator = NSBox()
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
    titlebar.blendingMode = .behindWindow
    titlebar.material = .titlebar
    separator.boxType = .custom
    separator.borderWidth = 0
    separator.fillColor = .separatorColor

    for view in [transcript, backdrop, startPage, picks, prompt, titlebar, separator] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }

    NSLayoutConstraint.activate([
      widthAnchor.constraint(greaterThanOrEqualToConstant: 500),
      heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
      titlebar.topAnchor.constraint(equalTo: topAnchor),
      titlebar.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
      titlebar.leadingAnchor.constraint(equalTo: leadingAnchor),
      titlebar.trailingAnchor.constraint(equalTo: trailingAnchor),
      separator.topAnchor.constraint(equalTo: titlebar.bottomAnchor, constant: -1),
      separator.heightAnchor.constraint(equalToConstant: 1),
      separator.leadingAnchor.constraint(equalTo: leadingAnchor),
      separator.trailingAnchor.constraint(equalTo: trailingAnchor),
      transcript.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
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

  /// The transcript's last lines scroll clear of the field, however tall the draft makes it.
  override func layout() {
    super.layout()
    transcript.bottomInset = prompt.frame.height + 8
  }
}
