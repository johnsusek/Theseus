import AppKit

/// Whether the transcript's window is main. Colored decorations draw gray when it is not.
/// Only touched on the main thread, where AppKit lays out and draws text.
final class DecorationState: @unchecked Sendable {
  var isActive = true
}

/// Gives every paragraph that carries a `Decoration` a fragment that draws it.
final class TranscriptLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
  let state = DecorationState()

  func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
    guard let text = (textElement as? NSTextParagraph)?.attributedString, text.length > 0 else { return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange) }

    let decoration = (text.attribute(.decoration, at: 0, effectiveRange: nil) as? DecorationValue)?.decoration
    var hasCode = false

    text.enumerateAttribute(.inlineCode, in: NSRange(location: 0, length: text.length)) { value, _, stop in
      hasCode = value != nil
      stop.pointee = ObjCBool(hasCode)
    }

    guard decoration != nil || hasCode else { return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange) }

    let style = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    return DecoratedFragment(textElement: textElement, decoration: decoration ?? Decoration(), headIndent: style?.headIndent ?? 0, appearance: state)
  }
}

/// A paragraph with something drawn behind it: its slice of a bubble, code block or diff, a group's border, quote bars, a rule, or inline code chips.
/// Consecutive paragraphs of one block each draw a slice, and the slices meet at the fragments' shared edges.
final class DecoratedFragment: NSTextLayoutFragment {
  private let decoration: Decoration
  private let headIndent: CGFloat
  private let appearance: DecorationState

  init(textElement: NSTextElement, decoration: Decoration, headIndent: CGFloat, appearance: DecorationState) {
    self.decoration = decoration
    self.headIndent = headIndent
    self.appearance = appearance
    super.init(textElement: textElement, range: textElement.elementRange)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("DecoratedFragment is built in code") }

  /// The column's full width at this paragraph's height, in the fragment's coordinates, whose origin is the text's left edge.
  private var column: CGRect {
    let frame = layoutFragmentFrame
    return CGRect(x: -frame.minX, y: 0, width: textLayoutManager?.textContainer?.size.width ?? frame.maxX, height: frame.height)
  }

  /// A fill's padding sits in the paragraph's spacing before and after, which the text's first and last paragraphs do not fully get, so the surface reaches past the frame.
  override var renderingSurfaceBounds: CGRect {
    var bounds = super.renderingSurfaceBounds.union(column)

    if let fill = decoration.fill, decoration.roundsTop, let first = textLineFragments.first { bounds = bounds.union(CGRect(x: column.minX, y: first.typographicBounds.minY - fill.padding, width: column.width, height: fill.padding)) }

    if let fill = decoration.fill, decoration.roundsBottom, let last = textLineFragments.last { bounds = bounds.union(CGRect(x: column.minX, y: 0, width: column.width, height: last.typographicBounds.maxY + fill.padding)) }

    return bounds
  }

  override func draw(at point: CGPoint, in context: CGContext) {
    context.saveGState()
    context.translateBy(x: point.x, y: point.y)

    if let fill = decoration.fill { draw(fill, in: context) }

    if let box = decoration.box { draw(box, in: context) }

    if let first = textLineFragments.first, let last = textLineFragments.last {
      let lines = first.typographicBounds.union(last.typographicBounds)
      context.setFillColor(NSColor.tertiaryLabelColor.cgColor)

      for bar in decoration.quoteBars { context.fill(CGRect(x: column.minX + bar, y: lines.minY - 2, width: 3, height: lines.height + 4)) }

      if let rule = decoration.rule {
        context.setFillColor(NSColor.separatorColor.cgColor)
        context.fill(CGRect(x: column.minX + decoration.left, y: rule == .middle ? lines.midY : column.height - 1, width: column.width - decoration.left - decoration.right, height: 1))
      }
    }

    drawChips(in: context)

    context.restoreGState()
    super.draw(at: point, in: context)
  }

  private func draw(_ fill: Decoration.Fill, in context: CGContext) {
    guard let first = textLineFragments.first, let last = textLineFragments.last else { return }

    // A bubble starts at its text, wherever the widest line put it.
    let left = fill == .bubble ? column.minX + headIndent - Decoration.bubbleInset : column.minX + decoration.left
    let top = decoration.roundsTop ? first.typographicBounds.minY - fill.padding : 0
    let bottom = decoration.roundsBottom ? last.typographicBounds.maxY + fill.padding : column.height
    let slice = CGRect(x: left, y: top, width: column.maxX - decoration.right - left, height: bottom - top)
    guard slice.width > 0, slice.height > 0 else { return }

    // Corners are round only where the block starts or ends, so the clip runs past the slice's other edges.
    var clip = slice

    if !decoration.roundsTop { clip = CGRect(x: clip.minX, y: clip.minY - fill.radius, width: clip.width, height: clip.height + fill.radius) }

    if !decoration.roundsBottom { clip.size.height += fill.radius }

    let radius = min(fill.radius, clip.width / 2, clip.height / 2)
    let tints: [Decoration.Fill: NSColor] = [.added: .systemGreen, .removed: .systemRed]

    context.saveGState()

    // A code block is an outline. It runs past the slice where the block goes on, so only the block's ends draw a top or bottom edge.
    if fill == .code {
      context.clip(to: slice)
      context.setStrokeColor(NSColor.separatorColor.cgColor)
      context.setLineWidth(1)
      context.addPath(CGPath(roundedRect: clip.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
      context.strokePath()
      context.restoreGState()
      return
    }

    context.addPath(CGPath(roundedRect: clip, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.clip()

    if let tint = tints[fill].map({ appearance.isActive ? $0 : .secondaryLabelColor }) {
      context.setFillColor(tint.withAlphaComponent(0.16).cgColor)
      context.fill(slice)
      context.setFillColor(tint.cgColor)
      context.fill(CGRect(x: slice.minX, y: slice.minY, width: 3, height: slice.height))
    } else {
      context.setFillColor(NSColor.tertiarySystemFill.cgColor)
      context.fill(slice)
    }

    context.restoreGState()
  }

  /// A rounded fill behind each inline code span or badge, one per line the span reaches. The span's kerning leaves room for the padding.
  private func drawChips(in context: CGContext) {
    for line in textLineFragments {
      let string = line.attributedString
      let bounds = line.typographicBounds

      string.enumerateAttribute(.inlineCode, in: line.characterRange) { value, run, _ in
        guard value != nil, let font = string.attribute(.font, at: run.location, effectiveRange: nil) as? NSFont else { return }

        // A badge carries its own fill.
        context.setFillColor(((value as? NSColor) ?? .quaternarySystemFill).cgColor)

        let start = line.locationForCharacter(at: run.location).x
        let end = line.locationForCharacter(at: NSMaxRange(run)).x
        let baseline = bounds.minY + line.glyphOrigin.y
        let chip = CGRect(x: bounds.minX + start - Decoration.chipPadding, y: baseline - font.ascender - 1, width: end - start + Decoration.chipPadding, height: font.ascender - font.descender + 2)
        context.addPath(CGPath(roundedRect: chip, cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.fillPath()
      }
    }
  }

  /// The border of an expanded group's list: the top and corners on its first paragraph, the sides on every one, the bottom on its last.
  private func draw(_ box: Decoration.Box, in context: CGContext) {
    let radius = 10.0
    let slice = CGRect(x: column.minX, y: box.topGap, width: column.width, height: column.height - box.topGap)
    var outline = slice.insetBy(dx: 0.5, dy: 0)

    if box.isFirst {
      outline.origin.y += 0.5
      outline.size.height -= 0.5
    } else {
      outline.origin.y -= radius * 2
      outline.size.height += radius * 2
    }

    outline.size.height += box.isLast ? -0.5 : radius * 2

    context.saveGState()
    context.clip(to: slice)
    context.setStrokeColor(NSColor.separatorColor.cgColor)
    context.setLineWidth(1)
    context.addPath(CGPath(roundedRect: outline, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.strokePath()

    if box.hasDivider {
      context.setFillColor(NSColor.separatorColor.cgColor)
      context.fill(CGRect(x: slice.minX, y: 0, width: slice.width, height: 1))
    }

    context.restoreGState()
  }
}
