import AppKit
import ClaudeEngine

/// An AskUserQuestion request in the transcript: the questions with their options, then Skip and Answer.
final class QuestionCardView: NSView, CardContent, ActiveAppearing {
  private let form: QuestionForm
  private let formWidth: NSLayoutConstraint

  var isActive: Bool {
    didSet { needsDisplay = true }
  }

  override var isFlipped: Bool { true }

  init(questions: [UserQuestion], isActive: Bool, decide: @escaping ([String: String]?) -> Void) {
    form = QuestionForm(questions, answersOnReturn: false, decide: decide)
    formWidth = form.widthAnchor.constraint(equalToConstant: form.width)
    self.isActive = isActive
    super.init(frame: .zero)
    addSubview(form)
    NSLayoutConstraint.activate([form.topAnchor.constraint(equalTo: topAnchor), form.leadingAnchor.constraint(equalTo: leadingAnchor), formWidth])
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Question")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("QuestionCardView is built in code") }

  /// Session > Answer and Skip Question.
  @discardableResult func submit() -> Bool { form.submit() }

  func skip() { form.skip() }

  func height(for width: CGFloat) -> CGFloat {
    if form.width != width {
      form.width = width
      formWidth.constant = width
    }

    return form.fittingSize.height
  }

  /// An accent-colored wash and border, gray in an inactive window.
  override func draw(_ dirtyRect: NSRect) {
    let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
    let tint = isActive ? NSColor.controlAccentColor : NSColor.secondaryLabelColor

    tint.withAlphaComponent(0.06).setFill()
    outline.fill()
    tint.withAlphaComponent(0.5).setStroke()
    outline.stroke()
  }
}
