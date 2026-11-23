import AppKit

extension NSAttributedString.Key {
  /// A `DecorationValue`, on a paragraph the layout draws something behind.
  static let decoration = NSAttributedString.Key("Theseus.decoration")
  /// The id a click on the paragraph opens or closes.
  static let toggle = NSAttributedString.Key("Theseus.toggle")
  /// The color a run has in the main window. Other windows show it gray.
  static let activeTint = NSAttributedString.Key("Theseus.activeTint")
  /// The width of a prompt's widest line, which sets where its bubble starts.
  static let bubbleWidth = NSAttributedString.Key("Theseus.bubbleWidth")
}

/// What the layout draws behind one paragraph: a slice of a bubble, code block or diff, a group's border, quote bars, a rule.
struct Decoration: Hashable, Sendable, Codable {
  enum Fill: Hashable, Sendable, Codable {
    case bubble, code, added, removed

    var radius: CGFloat {
      switch self {
      case .bubble: 16
      case .code: 8
      case .added, .removed: 6
      }
    }

    /// How far the fill reaches above the first line and below the last.
    var padding: CGFloat {
      switch self {
      case .bubble: 9
      case .code: 8
      case .added, .removed: 1
      }
    }
  }

  struct Box: Hashable, Sendable, Codable {
    var isFirst = false
    var isLast = false
    /// Space kept clear above the border, on the first paragraph.
    var topGap: CGFloat = 0
    var hasDivider = false
  }

  enum Rule: Hashable, Sendable, Codable {
    case below, middle
  }

  /// A bubble leaves at least `bubbleLead` of the column free on its left, and pads its text by `bubbleInset`.
  static let bubbleLead = 80.0
  static let bubbleInset = 14.0
  /// Rows and their detail sit this far inside a group's border.
  static let boxInset = 12.0

  var fill: Fill?
  /// The fill's left edge in the column, and how far its right edge stops short of the column's. A bubble starts at its text instead.
  var left: CGFloat = 0
  var right: CGFloat = 0
  var roundsTop = false
  var roundsBottom = false
  var box: Box?
  var quoteBars: [CGFloat] = []
  var rule: Rule?
}

/// A `Decoration` as an attribute value. AppKit archives attributed text for Look Up, Share and Services,
/// and a bare Swift struct in it makes the archiver throw.
final class DecorationValue: NSObject, NSSecureCoding {
  static var supportsSecureCoding: Bool { true }
  let decoration: Decoration

  init(_ decoration: Decoration) {
    self.decoration = decoration
  }

  init?(coder: NSCoder) {
    guard let data = coder.decodeObject(of: NSData.self, forKey: "decoration"), let decoration = try? JSONDecoder().decode(Decoration.self, from: data as Data) else { return nil }

    self.decoration = decoration
  }

  func encode(with coder: NSCoder) {
    coder.encode(try? JSONEncoder().encode(decoration), forKey: "decoration")
  }

  override var hash: Int { decoration.hashValue }

  override func isEqual(_ object: Any?) -> Bool { (object as? DecorationValue)?.decoration == decoration }
}

/// One paragraph of an element. `base` also styles the newline that ends it, which an empty line needs to keep its decoration.
struct Paragraph {
  var content: NSAttributedString
  var base: [NSAttributedString.Key: Any]

  var style: NSMutableParagraphStyle {
    get { (base[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle() }
    set { base[.paragraphStyle] = newValue }
  }

  var decoration: Decoration {
    get { (base[.decoration] as? DecorationValue)?.decoration ?? Decoration() }
    set { base[.decoration] = DecorationValue(newValue) }
  }

  mutating func restyle(_ change: (NSMutableParagraphStyle) -> Void) {
    let copy = style
    change(copy)
    style = copy
  }
}

extension [Paragraph] {
  /// The paragraphs as one string, each but the last ended by a newline. `terminated` ends the last one too.
  func joined(terminated: Bool) -> NSAttributedString {
    let result = NSMutableAttributedString()

    for (index, paragraph) in enumerated() {
      let start = result.length
      result.append(paragraph.content)

      if index < count - 1 || terminated { result.append(NSAttributedString(string: "\n")) }

      let range = NSRange(location: start, length: result.length - start)

      // The content's own attributes win over the paragraph's.
      for (key, value) in paragraph.base {
        result.enumerateAttribute(key, in: range) { existing, subrange, _ in
          if existing == nil { result.addAttribute(key, value: value, range: subrange) }
        }
      }
    }

    return result
  }
}

@MainActor
enum TranscriptStyle {
  static let font = NSFont.systemFont(ofSize: 14)
  static let callout = NSFont.systemFont(ofSize: 12)
  static let digits = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)
  static let calloutDigits = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
  static let code = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  private static var symbols: [String: NSTextAttachment] = [:]

  static func paragraph(before: CGFloat = 0, after: CGFloat = 0, indent: CGFloat = 0, tail: CGFloat = 0, lineSpacing: CGFloat = 0) -> NSMutableParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.paragraphSpacingBefore = before
    style.paragraphSpacing = after
    style.headIndent = indent
    style.firstLineHeadIndent = indent
    style.tailIndent = -tail
    style.lineSpacing = lineSpacing
    return style
  }

  static func text(_ string: String, font: NSFont = font, color: NSColor = .labelColor) -> NSAttributedString {
    NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
  }

  /// A gray SF Symbol set in a line of `font`. The attachment is shared, so re-rendered text compares equal to what the view holds.
  static func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .regular, in font: NSFont = font) -> NSAttributedString {
    let key = "\(name) \(pointSize) \(weight.rawValue) \(font.pointSize)"

    if let attachment = symbols[key] { return NSAttributedString(attachment: attachment) }

    let attachment = NSTextAttachment()
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight).applying(NSImage.SymbolConfiguration(hierarchicalColor: .secondaryLabelColor))

    if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
      attachment.image = image
      attachment.bounds = CGRect(x: 0, y: ((font.capHeight - image.size.height) / 2).rounded(), width: image.size.width, height: image.size.height)
    } else {
      log.error("No SF Symbol named \(name)")
    }

    symbols[key] = attachment
    return NSAttributedString(attachment: attachment)
  }

  /// Where a bubble's text starts: far enough right that its widest line ends at the column's edge, but never inside the lead.
  static func bubbleIndent(textWidth: CGFloat, columnWidth: CGFloat) -> CGFloat {
    max(Decoration.bubbleLead + Decoration.bubbleInset, columnWidth - Decoration.bubbleInset - ceil(textWidth) - 1)
  }
}
