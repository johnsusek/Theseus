import AppKit
import ClaudeEngine

/// A colored mark that is a view, so it can animate and go gray in an inactive window.
enum StatusMark {
  case running, failed
}

/// Turns one element into the attributed text the transcript holds for it.
@MainActor
struct TranscriptRenderer {
  /// The text container's width, which decides where prompt bubbles start and how wide tables can be.
  var columnWidth = 720.0
  /// Makes the view attachment for a task list or a permission request.
  var card: (TranscriptElement) -> NSTextAttachment = { _ in NSTextAttachment() }
  var mark: (StatusMark) -> NSTextAttachment = { _ in NSTextAttachment() }

  private var secondary: [NSAttributedString.Key: Any] { [.font: TranscriptStyle.font, .foregroundColor: NSColor.secondaryLabelColor] }

  /// The element's text, ended by a newline. Empty for an element with nothing to show, such as a reply that is only an opening code fence.
  func attributedString(for element: TranscriptElement) -> NSAttributedString {
    var paragraphs = paragraphs(for: element)
    guard !paragraphs.isEmpty else { return NSAttributedString() }

    paragraphs[0].restyle { $0.paragraphSpacingBefore += element.spacing }

    if let slot = element.box {
      var isRow = false

      if case .tool = element.kind { isRow = true }

      // A row keeps the border's padding above and below it. Its detail follows directly, so it pads only under itself.
      paragraphs[0].restyle { $0.paragraphSpacingBefore += isRow ? 8 : 0 }
      paragraphs[paragraphs.count - 1].restyle { $0.paragraphSpacing += 8 }

      for index in paragraphs.indices {
        paragraphs[index].decoration.box = Decoration.Box(isFirst: slot.isFirst && index == 0, isLast: slot.isLast && index == paragraphs.count - 1, topGap: slot.isFirst && index == 0 ? element.spacing : 0, hasDivider: isRow && !slot.isFirst && index == 0)
      }
    }

    return paragraphs.joined(terminated: true)
  }

  /// What a permission card shows of the tool call it asks about.
  func permissionBody(_ body: PermissionPrompt.Body) -> NSAttributedString {
    switch body {
    case .diff(let lines):
      codeLines(lines, tinted: true, inset: 0, color: .labelColor).joined(terminated: false)
    case .code(let text):
      codeLines(text.components(separatedBy: "\n"), tinted: false, inset: 0, color: .labelColor).joined(terminated: false)
    case .markdown(let text):
      Markdown.paragraphs(text, style: MarkdownStyle(font: NSFont.systemFont(ofSize: 13), lineSpacing: 3)).joined(terminated: false)
    case .text(let text):
      TranscriptStyle.text(text, font: NSFont.systemFont(ofSize: 13))
    }
  }

  private func paragraphs(for element: TranscriptElement) -> [Paragraph] {
    let inset = element.box == nil ? 0 : Decoration.boxInset

    switch element.kind {
    case .header(let text):
      return [line(TranscriptStyle.text(text, font: TranscriptStyle.callout, color: .secondaryLabelColor))]
    case .prompt(let text):
      return bubble(text)
    case .notice(let symbol, let text, _):
      let content = NSMutableAttributedString(attributedString: TranscriptStyle.symbol(symbol, pointSize: 11, in: TranscriptStyle.callout))
      content.append(TranscriptStyle.text("  " + text, font: TranscriptStyle.callout, color: .secondaryLabelColor))
      return [line(content)]
    case .reply(let text):
      return Markdown.paragraphs(text, style: MarkdownStyle(width: columnWidth))
    case .thought(let text):
      return Markdown.paragraphs(text, style: MarkdownStyle(font: NSFont.systemFont(ofSize: 13), color: .secondaryLabelColor, lineSpacing: 3, width: columnWidth))
    case .thinking:
      let content = NSMutableAttributedString(attachment: mark(.running))
      content.append(NSAttributedString(string: " Thinking", attributes: secondary))
      return [line(content)]
    case .tool(let row):
      return [toolRow(row, inset: inset)]
    case .group(let group):
      let content = NSMutableAttributedString(string: group.summary, attributes: secondary)
      content.append(delta(added: group.added, removed: group.removed))
      content.append(chevron(isOpen: group.isExpanded))
      return [line(content, toggle: group.id)]
    case .detail(let blocks):
      return detail(blocks, inset: inset)
    case .tasks, .permission:
      return [line(NSAttributedString(attachment: card(element)))]
    case .footer(let text):
      return [line(TranscriptStyle.text(text, font: TranscriptStyle.calloutDigits, color: .secondaryLabelColor))]
    }
  }

  private func line(_ content: NSAttributedString, indent: CGFloat = 0, toggle: String? = nil) -> Paragraph {
    var base: [NSAttributedString.Key: Any] = [.paragraphStyle: TranscriptStyle.paragraph(indent: indent, tail: indent), .font: TranscriptStyle.font]

    if let toggle { base[.toggle] = toggle }

    return Paragraph(content: content, base: base)
  }

  /// A prompt's lines share one rounded fill that hugs the column's right edge. Each line is a paragraph, drawn as a slice of the fill.
  private func bubble(_ text: String) -> [Paragraph] {
    let lines = text.components(separatedBy: "\n")
    let width = lines.map { TranscriptStyle.text($0).size().width }.max() ?? 0
    let indent = TranscriptStyle.bubbleIndent(textWidth: width, columnWidth: columnWidth)
    let padding = Decoration.Fill.bubble.padding
    let lineSpacing = 4.0

    return lines.enumerated().map { index, text in
      let isFirst = index == 0
      let isLast = index == lines.count - 1
      // TextKit 2 puts the line spacing above each line, the first included.
      let style = TranscriptStyle.paragraph(before: isFirst ? padding - lineSpacing : 0, after: isLast ? padding : 0, indent: indent, tail: Decoration.bubbleInset, lineSpacing: lineSpacing)
      let decoration = Decoration(fill: .bubble, roundsTop: isFirst, roundsBottom: isLast)
      return Paragraph(content: TranscriptStyle.text(text), base: [.paragraphStyle: style, .decoration: DecorationValue(decoration), .bubbleWidth: width, .font: TranscriptStyle.font, .foregroundColor: NSColor.labelColor])
    }
  }

  /// "Read TerminalView.swift", "Running swift test": a gray verb, what it acted on, line counts, and a chevron.
  private func toolRow(_ row: ToolRow, inset: CGFloat) -> Paragraph {
    let content = NSMutableAttributedString()

    if row.state == .running || row.state == .waiting {
      content.append(NSAttributedString(attachment: mark(.running)))
      content.append(NSAttributedString(string: " ", attributes: secondary))
    }

    content.append(NSAttributedString(string: row.verb, attributes: secondary))

    if !row.target.isEmpty { content.append(TranscriptStyle.text(" " + row.target)) }

    if !row.note.isEmpty { content.append(NSAttributedString(string: "  " + row.note, attributes: secondary)) }

    content.append(delta(added: row.added, removed: row.removed))

    if row.state == .failed {
      content.append(NSAttributedString(string: " ", attributes: secondary))
      content.append(NSAttributedString(attachment: mark(.failed)))
    }

    if row.state == .waiting { content.append(NSAttributedString(string: "  Needs Approval", attributes: secondary)) }

    if row.state == .stopped { content.append(NSAttributedString(string: "  Stopped", attributes: secondary)) }

    content.append(chevron(isOpen: row.isExpanded))

    var paragraph = line(content, indent: inset, toggle: row.id)

    if !row.tooltip.isEmpty { paragraph.base[.toolTip] = row.tooltip }

    return paragraph
  }

  /// "  +12 -3", or nothing for a call that changed no lines.
  private func delta(added: Int, removed: Int) -> NSAttributedString {
    guard added > 0 || removed > 0 else { return NSAttributedString() }

    let result = NSMutableAttributedString(string: "  ", attributes: [.font: TranscriptStyle.digits])
    result.append(lineDeltaText(added: added, removed: removed, font: TranscriptStyle.digits, isActive: true))
    return result
  }

  private func chevron(isOpen: Bool) -> NSAttributedString {
    let result = NSMutableAttributedString(string: "  ", attributes: secondary)
    result.append(TranscriptStyle.symbol(isOpen ? "chevron.down" : "chevron.right", pointSize: 9, weight: .semibold))
    return result
  }

  private func detail(_ blocks: [DetailBlock], inset: CGFloat) -> [Paragraph] {
    var paragraphs: [Paragraph] = []

    for block in blocks {
      let before = paragraphs.isEmpty ? 0.0 : 8.0
      var added: [Paragraph]

      switch block {
      case .command(let text):
        added = Markdown.codeLines(text, left: inset, right: inset, before: before)
      case .output(let text):
        added = codeLines(text.components(separatedBy: "\n"), tinted: false, inset: inset, color: .secondaryLabelColor)
      case .diff(let lines):
        added = codeLines(lines, tinted: true, inset: inset, color: .secondaryLabelColor)
      case .report(let text):
        added = Markdown.paragraphs(text, style: MarkdownStyle(font: NSFont.systemFont(ofSize: 13), color: .secondaryLabelColor, lineSpacing: 3, left: inset, right: inset, width: columnWidth))
      case .more(let id, let hidden):
        added = [line(TranscriptStyle.text("Show \(hidden.formatted()) More Lines", font: TranscriptStyle.callout, color: .secondaryLabelColor), indent: inset, toggle: id)]
      case .less(let id):
        added = [line(TranscriptStyle.text("Show Fewer Lines", font: TranscriptStyle.callout, color: .secondaryLabelColor), indent: inset, toggle: id)]
      case .note(let text):
        added = [line(TranscriptStyle.text(text, font: TranscriptStyle.callout, color: .secondaryLabelColor), indent: inset)]
      }

      // The command block took its spacing above, under its padding.
      if case .command = block {} else if !added.isEmpty {
        added[0].restyle { $0.paragraphSpacingBefore += before }
      }

      paragraphs += added
    }

    return paragraphs
  }

  /// Monospaced lines. A patch's added and removed lines get a tinted row with a bar at its leading edge.
  private func codeLines(_ lines: [String], tinted: Bool, inset: CGFloat, color: NSColor) -> [Paragraph] {
    let fills: [Character: Decoration.Fill] = ["+": .added, "-": .removed]

    return lines.enumerated().map { index, text in
      var base: [NSAttributedString.Key: Any] = [.paragraphStyle: TranscriptStyle.paragraph(indent: inset + 10, tail: inset + 4), .font: TranscriptStyle.code, .foregroundColor: color]

      if tinted, let fill = text.first.flatMap({ fills[$0] }) {
        base[.decoration] = DecorationValue(Decoration(fill: fill, left: inset, right: inset, roundsTop: index == 0, roundsBottom: index == lines.count - 1))
      }

      return Paragraph(content: TranscriptStyle.text(text, font: TranscriptStyle.code, color: color), base: base)
    }
  }
}
