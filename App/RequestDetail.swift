import AppKit
import ClaudeEngine

/// A request in full, in the popover on its row: the transcript's permission card for a permission or a plan, a form for questions.
/// None of its controls answers on Esc, which only closes the popover.
final class RequestDetailController: NSViewController {
  static let width = 480.0
  let request: PermissionRequest
  private let projectName: String
  private let answer: (PermissionDecision) -> Void
  private let layoutDelegate = TranscriptLayoutDelegate()

  init(request: PermissionRequest, projectName: String, answer: @escaping (PermissionDecision) -> Void) {
    self.request = request
    self.projectName = projectName
    self.answer = answer
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("RequestDetailController is built in code") }

  override func loadView() {
    if RequestKind(request) == .question {
      let form = QuestionForm(request.questions, answersOnReturn: true) { [unowned self] answers in
        answer(answers.map { .answer($0, to: request) } ?? .deny(message: "The user declined to answer."))
      }
      form.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
      view = form
      preferredContentSize = form.fittingSize
      return
    }

    let prompt = PermissionPrompt(request, projectName: projectName)
    let state = PermissionCardState()
    let card = PermissionCardView(prompt: prompt, body: TranscriptRenderer().permissionBody(prompt.body), bodyLimit: prompt.isPlan ? 420 : 220, layoutDelegate: layoutDelegate, state: state, isActive: true) { [unowned self] allow in
      answer(permissionDecision(for: request, allow: allow, always: state.always))
    }
    let size = NSSize(width: Self.width, height: card.height(for: Self.width))

    card.frame = NSRect(origin: .zero, size: size)
    view = card
    preferredContentSize = size
  }
}

/// AskUserQuestion's questions, each with its options as radio buttons, or checkboxes when several can be picked.
/// Answer hands back every question's picks; Skip hands back nil. In the transcript Answer has no key equivalent, since Return belongs to the prompt field.
final class QuestionForm: NSStackView {
  private let questions: [UserQuestion]
  private var choices: [[NSButton]] = []
  /// Each question's last choice, Other, and the field its answer is typed in.
  private var others: [(button: NSButton, field: NSTextField)] = []
  /// Whether each question takes several picks.
  private var multiple: [Bool] = []
  private let send = NSButton(title: "Answer", target: nil, action: nil)
  private let decide: ([String: String]?) -> Void
  /// Wrapping labels and how far each sits in from the form's padding.
  private var wrapping: [(label: NSTextField, indent: CGFloat)] = []

  /// The width the form's text wraps to.
  var width = RequestDetailController.width {
    didSet { for item in wrapping { item.label.preferredMaxLayoutWidth = width - 32 - item.indent } }
  }

  init(_ questions: [UserQuestion], answersOnReturn: Bool, decide: @escaping ([String: String]?) -> Void) {
    self.questions = questions
    self.decide = decide
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .leading
    spacing = 14
    edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
    translatesAutoresizingMaskIntoConstraints = false

    for question in questions { addArrangedSubview(section(question)) }

    let skip = NSButton(title: "Skip", target: self, action: #selector(pressSkip))
    let row = NSStackView(views: [NSView(), skip, send])

    send.target = self
    send.action = #selector(pressAnswer)
    send.keyEquivalent = answersOnReturn ? "\r" : ""
    skip.toolTip = "Decline to Answer"
    row.spacing = 8
    addArrangedSubview(row)
    row.widthAnchor.constraint(equalTo: widthAnchor, constant: -32).isActive = true
    update()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("QuestionForm is built in code") }

  private func section(_ question: UserQuestion) -> NSView {
    let text = NSTextField(wrappingLabelWithString: question.question)
    let options = NSStackView()
    var buttons: [NSButton] = []

    text.font = .systemFont(ofSize: 13, weight: .semibold)
    text.isSelectable = true
    text.preferredMaxLayoutWidth = width - 32
    wrapping.append((text, 0))
    options.orientation = .vertical
    options.alignment = .leading
    options.spacing = 4

    for option in question.options {
      // Radio buttons that share a superview and an action act as one group.
      let button = question.multiSelect ? NSButton(checkboxWithTitle: option.label, target: self, action: #selector(picked)) : NSButton(radioButtonWithTitle: option.label, target: self, action: #selector(picked))
      button.toolTip = option.description
      buttons.append(button)
      options.addArrangedSubview(button)

      guard let description = option.description, !description.isEmpty else { continue }

      let detail = NSTextField(wrappingLabelWithString: description)
      detail.textColor = .secondaryLabelColor
      detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
      detail.preferredMaxLayoutWidth = width - 52
      wrapping.append((detail, 20))
      options.addArrangedSubview(detail)
      options.setCustomSpacing(6, after: detail)
      detail.leadingAnchor.constraint(equalTo: options.leadingAnchor, constant: 20).isActive = true
    }

    // Other takes an answer in the user's own words, as the CLI's own question form does. Typing in its field picks it.
    let other = question.multiSelect ? NSButton(checkboxWithTitle: "Other:", target: self, action: #selector(picked)) : NSButton(radioButtonWithTitle: "Other:", target: self, action: #selector(picked))
    let field = NSTextField(string: "")
    field.placeholderString = "Type your own answer"
    field.delegate = self
    field.setAccessibilityLabel("Other Answer")
    field.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
    let otherRow = NSStackView(views: [other, field])
    otherRow.spacing = 6
    options.addArrangedSubview(otherRow)
    buttons.append(other)
    others.append((other, field))
    multiple.append(question.multiSelect)

    choices.append(buttons)

    let views = [question.header.map { header -> NSView in
      let label = NSTextField(labelWithString: header.uppercased())
      label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
      label.textColor = .secondaryLabelColor
      return label
    }, text, options].compactMap(\.self)
    let stack = NSStackView(views: views)

    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    return stack
  }

  /// Each question's picked labels, several joined with ", " as the CLI expects. Nil while a question has no pick.
  private var answers: [String: String]? {
    var answers: [String: String] = [:]

    for ((question, buttons), other) in zip(zip(questions, choices), others) {
      let typed = other.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      // Other counts once something is typed in it.
      if other.button.state == .on, typed.isEmpty { return nil }

      let picked = buttons.filter { $0.state == .on }.map { $0 === other.button ? typed : $0.title }
      guard !picked.isEmpty else { return nil }

      answers[question.question] = picked.joined(separator: ", ")
    }

    return answers
  }

  private func update() {
    send.isEnabled = answers != nil
  }

  /// Other's radio button sits in a row of its own, outside the options' automatic group, so one choice turns off the rest here.
  @objc private func picked(_ sender: NSButton) {
    if sender.state == .on, let index = choices.firstIndex(where: { $0.contains(sender) }), !multiple[index] {
      for button in choices[index] where button !== sender { button.state = .off }
    }

    if let other = others.first(where: { $0.button === sender }), sender.state == .on { window?.makeFirstResponder(other.field) }

    update()
  }

  /// Answers with what is picked, when every question has an answer. Returns whether it did.
  @discardableResult func submit() -> Bool {
    guard let answers else { return false }

    decide(answers)
    return true
  }

  func skip() {
    decide(nil)
  }

  @objc private func pressAnswer() {
    submit()
  }

  @objc private func pressSkip() {
    decide(nil)
  }
}

extension QuestionForm: NSTextFieldDelegate {
  /// Typing an answer picks Other.
  func controlTextDidChange(_ note: Notification) {
    guard let field = note.object as? NSTextField, let other = others.first(where: { $0.field === field }) else { return }

    if !field.stringValue.isEmpty, other.button.state != .on {
      other.button.state = .on
      picked(other.button)
    } else {
      update()
    }
  }
}
