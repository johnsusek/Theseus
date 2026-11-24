import AppKit

struct MarkdownStyle: Hashable {
  var font = NSFont.systemFont(ofSize: 15)
  var color = NSColor.labelColor
  var lineSpacing = 3.0
  /// Space kept clear on each side of every block.
  var left = 0.0
  var right = 0.0
  /// The column's width. Tables wider than it wrap their cells.
  var width = CGFloat.infinity
}

/// Markdown as styled paragraphs: headings, lists, quotes, fenced code on a rounded background, tables as tab-stopped rows.
@MainActor
enum Markdown {
  private struct Chunk: Hashable {
    var text: String
    var style: MarkdownStyle
  }

  private struct Table {
    var identity: Int
    var columns: [PresentationIntent.TableColumn]
    /// A row's cells by column. An empty cell has no entry.
    var rows: [(identity: Int, isHeader: Bool, cells: [Int: NSAttributedString])] = []
    var left: CGFloat
    var quoteBars: [CGFloat]
  }

  private static var cache: [Chunk: [Paragraph]] = [:]
  private static var cachedBytes = 0
  private static let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: true, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)

  /// Parses `source` in chunks and keeps every chunk but the last, so a reply that grows as it streams only parses its last chunk again.
  /// The last chunk is the one still growing; keeping each of its versions would hold a long code block once per delta.
  static func paragraphs(_ source: String, style: MarkdownStyle = MarkdownStyle()) -> [Paragraph] {
    let chunks = chunks(of: source)
    var result: [Paragraph] = []

    if cachedBytes > 4_000_000 {
      cache = [:]
      cachedBytes = 0
    }

    for (index, text) in chunks.enumerated() {
      let key = Chunk(text: text, style: style)
      var parsed = cache[key] ?? parse(text, style: style)

      if index < chunks.count - 1, cache[key] == nil {
        cache[key] = parsed
        cachedBytes += text.utf8.count
      }

      // The first block sits flush with what is above it; a code block keeps only its own padding.
      if result.isEmpty, !parsed.isEmpty {
        let padding = parsed[0].decoration.fill.map(\.padding) ?? 0
        parsed[0].restyle { $0.paragraphSpacingBefore = padding }
      }

      // A list ends at a chunk's end, so the room a list leaves under it is added here.
      if index > 0, !parsed.isEmpty, let last = chunks[index - 1].split(separator: "\n").last, last.wholeMatch(of: /\s*([-*+]|\d+[.)])\s.*|\s+\S.*/) != nil, (try? /\s*([-*+]|\d+[.)])\s/.prefixMatch(in: text)) == nil {
        parsed[0].restyle { $0.paragraphSpacingBefore += listGap }
      }

      result += parsed
    }

    return result
  }

  /// Splits at blank lines that end a top-level block: outside a code fence, and before a line that is not indented.
  static func chunks(of source: String) -> [String] {
    var chunks: [String] = []
    var current: [Substring] = []
    var blanks: [Substring] = []
    var fence: Substring?

    for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.drop { $0 == " " }
      // Four or more spaces of indentation make a line code, not a fence.
      let marker = line.count - trimmed.count < 4 ? trimmed.prefix { $0 == "`" || $0 == "~" } : ""

      if line.allSatisfy(\.isWhitespace), fence == nil {
        blanks.append(line)
        continue
      }

      if !blanks.isEmpty, !current.isEmpty, line.first?.isWhitespace == false {
        chunks.append(current.joined(separator: "\n"))
        current = []
      } else {
        current += current.isEmpty ? [] : blanks
      }

      blanks = []
      current.append(line)

      if let open = fence {
        if marker.count >= open.count, marker.first == open.first, trimmed.dropFirst(marker.count).allSatisfy(\.isWhitespace) { fence = nil }
      } else if marker.count >= 3, Set(marker).count == 1 {
        fence = marker
      }
    }

    if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }

    return chunks
  }

  private static let blockSpacing = 12.0
  /// Extra room under a list.
  private static let listGap = 10.0

  private static func parse(_ text: String, style: MarkdownStyle) -> [Paragraph] {
    guard let parsed = try? AttributedString(markdown: text, options: options) else {
      log.error("Markdown did not parse; showing it as plain text")
      return [Paragraph(content: TranscriptStyle.text(text, font: style.font, color: style.color), base: [.paragraphStyle: TranscriptStyle.paragraph(before: blockSpacing, indent: style.left, tail: style.right, lineSpacing: style.lineSpacing)])]
    }

    var paragraphs: [Paragraph] = []
    var blocks: [(intent: PresentationIntent?, runs: [AttributedString.Runs.Run])] = []
    var seenItems: Set<Int> = []
    var table: Table?
    var wasListItem = false

    for run in parsed.runs {
      if let last = blocks.indices.last, blocks[last].intent == run.presentationIntent {
        blocks[last].runs.append(run)
      } else {
        blocks.append((run.presentationIntent, [run]))
      }
    }

    for block in blocks {
      let components = Array((block.intent?.components ?? []).reversed())
      var left = style.left
      var quoteBars: [CGFloat] = []
      var listStart: CGFloat?
      var isOrdered = false
      var marker: String?
      var font = style.font
      var before = blockSpacing
      var cell: (table: Int, columns: [PresentationIntent.TableColumn], row: Int, column: Int, isHeader: Bool)?
      var code = false
      var language: String?
      var isRule = false

      for component in components {
        switch component.kind {
        case .blockQuote:
          quoteBars.append(left)
          left += 14
        case .orderedList, .unorderedList:
          isOrdered = component.kind == .orderedList
          listStart = left
          left += 33
        case .listItem(let ordinal):
          // Only an item's first block carries its marker.
          marker = seenItems.insert(component.identity).inserted ? (isOrdered ? "\(ordinal)." : "\u{2022}") : nil
        case .header(let level):
          font = NSFont.systemFont(ofSize: [1: 20.0, 2: 17, 3: 15][level] ?? style.font.pointSize, weight: level < 3 ? .bold : .semibold)
          before = 18
        case .codeBlock(let languageHint):
          code = true
          language = languageHint
        case .thematicBreak:
          isRule = true
        case .table(let columns):
          cell = (component.identity, columns, 0, 0, false)
        case .tableHeaderRow:
          cell?.row = component.identity
          cell?.isHeader = true
        case .tableRow:
          cell?.row = component.identity
        case .tableCell(let column):
          cell?.column = column
        default:
          break
        }
      }

      if let cell {
        if table?.identity != cell.table {
          paragraphs += table.map { rows($0, style: style) } ?? []
          table = Table(identity: cell.table, columns: cell.columns, left: left, quoteBars: quoteBars)
        }

        var rows = table?.rows ?? []

        if rows.last?.identity != cell.row { rows.append((cell.row, cell.isHeader, [:])) }

        rows[rows.count - 1].cells[cell.column] = inline(parsed, runs: block.runs, font: cell.isHeader ? NSFont.systemFont(ofSize: style.font.pointSize, weight: .semibold) : style.font, color: style.color)
        table?.rows = rows
        continue
      }

      paragraphs += table.map { rows($0, style: style) } ?? []
      table = nil

      if marker != nil, wasListItem { before = 4 }

      if listStart == nil, wasListItem { before += listGap }

      wasListItem = listStart != nil
      var decoration = Decoration(quoteBars: quoteBars)

      if code {
        let source = block.runs.map { String(parsed[$0.range].characters) }.joined()
        paragraphs += codeLines(source.hasSuffix("\n") ? String(source.dropLast()) : source, language: language, left: left, right: style.right, before: before, color: style.color, quoteBars: quoteBars, width: style.width)
        continue
      }

      if isRule {
        decoration.rule = .middle
        decoration.left = left
        decoration.right = style.right
        paragraphs.append(Paragraph(content: TranscriptStyle.text(" ", font: style.font), base: [.paragraphStyle: TranscriptStyle.paragraph(before: before), .decoration: DecorationValue(decoration)]))
        continue
      }

      let content = inline(parsed, runs: block.runs, font: font, color: quoteBars.isEmpty ? style.color : .secondaryLabelColor)

      // Raw HTML blocks keep their line ending, which would leave an empty paragraph behind.
      while content.string.hasSuffix("\n") { content.deleteCharacters(in: NSRange(location: content.length - 1, length: 1)) }

      let paragraph = TranscriptStyle.paragraph(before: before, indent: left, tail: style.right, lineSpacing: style.lineSpacing)

      if let marker, let listStart {
        paragraph.firstLineHeadIndent = listStart
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: listStart + 23), NSTextTab(textAlignment: .left, location: left)]
        // A bullet in the text's own weight reads smaller than the desktop app's.
        let markerFont = isOrdered ? style.font : NSFont.systemFont(ofSize: style.font.pointSize, weight: .heavy)
        content.insert(TranscriptStyle.text("\t\(marker)\t", font: markerFont, color: style.color), at: 0)
      }

      var base: [NSAttributedString.Key: Any] = [.paragraphStyle: paragraph, .font: font, .foregroundColor: style.color]

      if !quoteBars.isEmpty { base[.decoration] = DecorationValue(decoration) }

      paragraphs.append(Paragraph(content: content, base: base))
    }

    return paragraphs + (table.map { rows($0, style: style) } ?? [])
  }

  /// Monospaced lines on one rounded background, a paragraph per line.
  /// With a column `width`, the block is only as wide as its widest line.
  /// Makes the Copy and Run buttons at the end of a code block's first line, and says how wide they are. The app sets it; without it a block has no buttons.
  static var codeButtons: ((_ code: String, _ language: String?) -> (attachment: NSTextAttachment, width: CGFloat))?

  /// With a column `width`, the block is only as wide as its widest line, and its first line ends in the code buttons.
  /// A `badge`, such as a command output's terminal symbol, takes the buttons' place, and its block spans the column.
  static func codeLines(_ source: String, language: String? = nil, left: CGFloat, right: CGFloat, before: CGFloat, color: NSColor = .labelColor, quoteBars: [CGFloat] = [], width: CGFloat = .infinity, badge: NSAttributedString? = nil) -> [Paragraph] {
    let lines = source.components(separatedBy: "\n")
    let colored = CodeHighlighter.lines(lines, language: language, font: TranscriptStyle.code, color: color)
    let buttons = width.isFinite && badge == nil ? codeButtons?(source, language) : nil
    let trailing = buttons.map { NSAttributedString(attachment: $0.attachment) } ?? badge
    let gap = 16.0
    var widest = colored.map { ceil($0.size().width) }.max() ?? 0

    if let buttons { widest = max(widest, ceil(colored[0].size().width) + gap + buttons.width) }

    let right = width.isFinite && badge == nil ? max(right, width - left - widest - 2 * Decoration.codeInset - 1) : right

    return colored.enumerated().map { index, content in
      let isFirst = index == 0
      let isLast = index == lines.count - 1
      let padding = Decoration.Fill.code.padding
      // TextKit 2 puts the line spacing above each line, the first included.
      let style = TranscriptStyle.paragraph(before: isFirst ? before + padding - TranscriptStyle.codeLineSpacing : 0, after: isLast ? padding : 0, indent: left + Decoration.codeInset, tail: right + Decoration.codeInset, lineSpacing: TranscriptStyle.codeLineSpacing)
      let decoration = Decoration(fill: .code, left: left, right: right, roundsTop: isFirst, roundsBottom: isLast, quoteBars: quoteBars)
      var base: [NSAttributedString.Key: Any] = [.paragraphStyle: style, .decoration: DecorationValue(decoration), .font: TranscriptStyle.code, .foregroundColor: color]

      if width.isFinite { base[.fitsColumn] = true }

      // A tab stop at the text's right edge puts the buttons there.
      if isFirst, width.isFinite, let trailing {
        style.tabStops = [NSTextTab(textAlignment: .right, location: width - right - Decoration.codeInset)]
        content.append(NSAttributedString(string: "\t", attributes: [.font: TranscriptStyle.code]))
        content.append(trailing)
      }

      return Paragraph(content: content, base: base)
    }
  }


  /// TextKit 2 has no table layout, so a row is a line per wrapped cell line, with a tab stop per column.
  /// A column is as wide as its widest cell while the table fits the column; otherwise `fit` narrows the widest columns.
  private static func rows(_ table: Table, style: MarkdownStyle) -> [Paragraph] {
    let gap = 24.0
    var widths = [CGFloat](repeating: 0, count: table.columns.count)

    for row in table.rows {
      for (column, cell) in row.cells where column < widths.count { widths[column] = max(widths[column], ceil(cell.size().width)) }
    }

    widths = fit(widths, into: style.width - style.right - table.left - gap * CGFloat(max(widths.count - 1, 0)))
    var starts: [CGFloat] = []
    var next = table.left

    for width in widths {
      starts.append(next)
      next += width + gap
    }

    // The first column starts the line. A tab there would skip to the second stop, so only a right or centered first column gets one.
    let leadsWithTab = table.columns.first.map { $0.alignment == .right || $0.alignment == .center } ?? false
    let stops = zip(table.columns, zip(starts, widths)).map { column, frame in
      switch column.alignment {
      case .right: NSTextTab(textAlignment: .right, location: frame.0 + frame.1)
      case .center: NSTextTab(textAlignment: .center, location: frame.0 + frame.1 / 2)
      default: NSTextTab(textAlignment: .left, location: frame.0)
      }
    }

    return table.rows.enumerated().map { index, row in
      let cells = table.columns.indices.map { column in row.cells[column].map { lines($0, width: widths[column]) } ?? [] }
      let content = NSMutableAttributedString()
      let isLast = index == table.rows.count - 1
      let style = TranscriptStyle.paragraph(before: index == 0 ? blockSpacing : 4, after: isLast ? 0 : 4, indent: table.left)
      var decoration = Decoration(left: table.left, quoteBars: table.quoteBars)

      style.tabStops = Array(stops.dropFirst(leadsWithTab ? 0 : 1))
      // A line a rounding error too wide would wrap its last word back to the first column.
      style.lineBreakMode = .byClipping

      for line in 0..<max(cells.map(\.count).max() ?? 0, 1) {
        if line > 0 { content.append(NSAttributedString(string: "\u{2028}")) }

        for column in table.columns.indices {
          if column > 0 || leadsWithTab { content.append(NSAttributedString(string: "\t")) }

          if line < cells[column].count { content.append(cells[column][line]) }
        }
      }

      // A rule under every row but the last keeps wrapped rows apart.
      if !isLast { decoration.rule = .below }

      return Paragraph(content: content, base: [.paragraphStyle: style, .decoration: DecorationValue(decoration), .font: TranscriptStyle.font, .fitsColumn: true])
    }
  }

  /// Column widths that add up to at most `available`. Columns narrower than an even share keep their width,
  /// and the others split what is left evenly, but none goes under 40 pt.
  static func fit(_ widths: [CGFloat], into available: CGFloat) -> [CGFloat] {
    guard widths.reduce(0, +) > available else { return widths }

    var fitted = widths
    var wide = Set(widths.indices)
    var budget = available

    while true {
      let share = budget / CGFloat(wide.count)
      let narrow = wide.filter { widths[$0] <= share }

      if narrow.isEmpty {
        for column in wide { fitted[column] = max(floor(share), 40) }

        return fitted
      }

      for column in narrow { budget -= widths[column] }

      wide.subtract(narrow)
    }
  }

  /// A cell's lines when it wraps at `width`: at a line separator, between words, or inside a word too long for a line.
  private static func lines(_ cell: NSAttributedString, width: CGFloat) -> [NSAttributedString] {
    guard ceil(cell.size().width) > width || cell.string.contains("\u{2028}") else { return [cell] }

    let typesetter = CTTypesetterCreateWithAttributedString(cell)
    var lines: [NSAttributedString] = []
    var start = 0

    while start < cell.length {
      var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))

      if count == 0 { count = max(CTTypesetterSuggestClusterBreak(typesetter, start, Double(width)), 1) }

      let line = NSMutableAttributedString(attributedString: cell.attributedSubstring(from: NSRange(location: start, length: count)))

      while let last = line.string.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) { line.deleteCharacters(in: NSRange(location: line.length - 1, length: 1)) }

      lines.append(line)
      start += count
    }

    return lines
  }

  /// Straight quotes as typographic ones. A quote opens at the start, after a space or after an opening bracket or quote.
  static func curled(_ text: String, after previous: Character?) -> String {
    var result = ""
    var before = previous

    for character in text {
      let opens = before.map { $0.isWhitespace || "([{\u{201C}\u{2018}\u{2014}\u{2013}".contains($0) } ?? true

      switch character {
      case "\"": result.append(opens ? "\u{201C}" : "\u{201D}")
      case "'": result.append(opens ? "\u{2018}" : "\u{2019}")
      default: result.append(character)
      }

      before = character
    }

    return result
  }

  private static func inline(_ parsed: AttributedString, runs: [AttributedString.Runs.Run], font: NSFont, color: NSColor) -> NSMutableAttributedString {
    let result = NSMutableAttributedString()

    for run in runs {
      let intent = run.inlinePresentationIntent ?? []
      // A hard break stays inside its paragraph as a line separator.
      let source = String(parsed[run.range].characters)
      let text = intent.contains(.lineBreak) ? "\u{2028}" : intent.contains(.code) ? source : curled(source, after: result.string.last)
      var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
      var traits = font.fontDescriptor.symbolicTraits

      if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }

      if intent.contains(.emphasized) { traits.insert(.italic) }

      if intent.contains(.code), !text.isEmpty {
        attributes[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1.5, weight: traits.contains(.bold) ? .semibold : .regular)
        attributes[.inlineCode] = true

        // Kerning after the character before the span and after its last character makes room for the chip's padding.
        if result.length > 0, result.attribute(.inlineCode, at: result.length - 1, effectiveRange: nil) == nil { result.addAttribute(.kern, value: Decoration.chipPadding, range: NSRange(location: result.length - 1, length: 1)) }

        let span = NSMutableAttributedString(string: text, attributes: attributes)
        span.addAttribute(.kern, value: Decoration.chipPadding, range: NSRange(location: span.length - 1, length: 1))
        result.append(span)
        continue
      } else if traits != font.fontDescriptor.symbolicTraits {
        attributes[.font] = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
      }

      if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }

      if let link = run.link ?? run.imageURL { attributes[.link] = link }

      result.append(NSAttributedString(string: text, attributes: attributes))
    }

    return result
  }
}
