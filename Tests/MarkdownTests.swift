import AppKit
import Testing

@MainActor
struct MarkdownTests {
  func text(_ source: String) -> String { Markdown.paragraphs(source).joined(terminated: false).string }

  func decorations(_ source: String) -> [Decoration?] { Markdown.paragraphs(source).map { ($0.base[.decoration] as? DecorationValue)?.decoration } }

  @Test func chunksSplitOnlyBetweenTopLevelBlocks() {
    #expect(Markdown.chunks(of: "One.\n\nTwo.\n\n\nThree.") == ["One.", "Two.", "Three."])
    #expect(Markdown.chunks(of: "```\ncode\n\nmore\n```\n\nAfter") == ["```\ncode\n\nmore\n```", "After"])
    #expect(Markdown.chunks(of: "- item\n\n  continued\n\nNext") == ["- item\n\n  continued", "Next"])
    #expect(Markdown.chunks(of: "Text\n\n```swift\nlet half = ") == ["Text", "```swift\nlet half = "])
    #expect(Markdown.chunks(of: "").isEmpty)
    // A fence indented four spaces is code inside the example, so it does not close the block.
    #expect(Markdown.chunks(of: "```markdown\n- item\n\n    ```\n\nStill inside\n```\n\nAfter.") == ["```markdown\n- item\n\n    ```\n\nStill inside\n```", "After."])
  }

  @Test func blocksBecomeParagraphs() {
    // A single newline breaks the line inside its paragraph, as a hard break does.
    #expect(text("# Title\n\nBody with **bold** and `code`.\nSame paragraph.") == "Title\nBody with bold and code.\u{2028}Same paragraph.")
    #expect(text("1. First\n2. Second\n   - Nested") == "\t1.\tFirst\n\t2.\tSecond\n\t\u{2022}\tNested")
    #expect(text("Line one\\\nLine two") == "Line one\u{2028}Line two")
    #expect(text("| Name | Count |\n|:--|--:|\n| turns | 12 |") == "Name\tCount\nturns\t12")
    // An empty cell keeps its column.
    #expect(text("| a | b | c |\n|---|---|---|\n| 1 |   | 3 |") == "a\tb\tc\n1\t\t3")
  }

  @Test func wideTablesWrapCellsInsideTheirColumns() {
    let source = "| Key | Purpose |\n|---|---|\n| groupID | App group shared by the app, the agent and the extension |"
    let wrapped = Markdown.paragraphs(source, style: MarkdownStyle(width: 260))
    let row = wrapped[1].content.string

    #expect(Markdown.paragraphs(source)[1].content.string == "groupID\tApp group shared by the app, the agent and the extension")
    // Every line of the row starts in the first column and puts the purpose's words after one tab.
    #expect(row.contains("\u{2028}"))
    #expect(row.components(separatedBy: "\u{2028}").allSatisfy { $0.components(separatedBy: "\t").count == 2 })
    #expect(row.components(separatedBy: "\u{2028}").map { $0.components(separatedBy: "\t")[1] }.joined(separator: " ") == "App group shared by the app, the agent and the extension")
    #expect(wrapped[1].base[.fitsColumn] as? Bool == true)
  }

  @Test func fittingNarrowsOnlyTheWideColumns() {
    #expect(Markdown.fit([50, 100], into: 200) == [50, 100])
    #expect(Markdown.fit([50, 300, 300], into: 250) == [50, 100, 100])
    // Columns go no narrower than their longest word while the words fit, and shrink in proportion once they don't.
    #expect(Markdown.fit([200, 200], minimums: [150, 50], into: 250) == [150, 100])
    #expect(Markdown.fit([200, 200], minimums: [100, 100], into: 100) == [50, 50])
    #expect(Markdown.fit([10, 10], into: 5) == [2, 2])
  }

  @Test func wideTablesKeepTheirWordsWholeAndStayInTheColumn() {
    let header = (1...6).map { "Heading\($0)" }
    let source = "| " + header.joined(separator: " | ") + " |\n|" + String(repeating: "---|", count: 6) + "\n| " + (1...6).map { "Language\($0) words" }.joined(separator: " | ") + " |"
    let width = 520.0
    let rows = Markdown.paragraphs(source, style: MarkdownStyle(width: width))
    let lines = rows.flatMap { $0.content.string.components(separatedBy: "\u{2028}") }

    // Each heading is whole on one line of its row, and no row is wider than the column.
    #expect(header.allSatisfy { heading in lines.contains { $0.components(separatedBy: "\t").contains(heading) } })
    #expect(rows.allSatisfy { ($0.base[.paragraphStyle] as? NSParagraphStyle)?.tabStops.last.map { $0.location <= width } ?? true })
  }

  @Test func filePathInCodeIsALink() {
    let rendered = Markdown.paragraphs("Open `/Applications/Theseus.app` from `/Users/bench/seeds/` or `Markdown.swift`").joined(terminated: false)
    let string = rendered.string as NSString

    #expect(rendered.attribute(.link, at: string.range(of: "Theseus.app").location, effectiveRange: nil) as? URL == URL(filePath: "/Applications/Theseus.app"))
    #expect(rendered.attribute(.inlineCode, at: string.range(of: "seeds").location, effectiveRange: nil) != nil)
    #expect(rendered.attribute(.inlineCode, at: string.range(of: "Markdown").location, effectiveRange: nil) != nil)
  }

  @Test func inlineStylesMapToAttributes() {
    let rendered = Markdown.paragraphs("Plain **bold** *italic* `code` ~~gone~~ [link](https://example.com)").joined(terminated: false)
    let string = rendered.string as NSString

    func attributes(of word: String) -> [NSAttributedString.Key: Any] { rendered.attributes(at: string.range(of: word).location, effectiveRange: nil) }

    #expect(attributes(of: "bold")[.font] as? NSFont == NSFont.systemFont(ofSize: MarkdownStyle().font.pointSize, weight: .semibold))
    #expect((attributes(of: "italic")[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic) == true)
    #expect((attributes(of: "code")[.font] as? NSFont)?.isFixedPitch == true)
    #expect(attributes(of: "code")[.inlineCode] != nil)
    #expect(attributes(of: "gone")[.strikethroughStyle] as? Int == NSUnderlineStyle.single.rawValue)
    #expect(attributes(of: "link")[.link] as? URL == URL(string: "https://example.com"))
    #expect(attributes(of: "Plain")[.backgroundColor] == nil)
  }

  @Test func codeBlocksAreOneRoundedFill() {
    let fills = decorations("Before\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\nAfter")

    #expect(fills.map { $0?.fill } == [nil, .code, .code, .code, nil])
    #expect(fills.map { $0?.roundsTop ?? false } == [false, true, false, false, false])
    #expect(fills.map { $0?.roundsBottom ?? false } == [false, false, false, true, false])
  }

  @Test func unclosedFenceStillRendersAsCode() {
    #expect(text("Streaming:\n\n```swift\nlet half = ") == "Streaming:\nlet half = ")
    #expect(decorations("Streaming:\n\n```swift\nlet half = ").map { $0?.fill } == [nil, .code])
    #expect(text("```") == "")
  }

  @Test func quotesAndRulesAreDecorated() {
    #expect(decorations("> quoted\n\n---\n\nplain").map { $0?.quoteBars ?? [] } == [[0], [], []])
    #expect(decorations("> quoted\n\n---\n\nplain").map { $0?.rule } == [nil, .middle, nil])
    #expect(decorations("| A |\n|---|\n| b |").map { $0?.rule } == [.below, nil])
  }

  @Test func firstBlockSitsFlushAndLaterOnesAreSpaced() {
    let spacings = Markdown.paragraphs("One\n\n## Two\n\n- a\n- b\n\nThree").map(\.style.paragraphSpacingBefore)

    #expect(spacings == [0, 18, 12, 4, 22])
    #expect(Markdown.paragraphs("```\ncode\n```")[0].style.paragraphSpacingBefore == Decoration.Fill.code.padding)
  }

  @Test func quotesCurlOutsideCode() {
    #expect(Markdown.curled("\"hello\", it's 'done'", after: nil) == "\u{201C}hello\u{201D}, it\u{2019}s \u{2018}done\u{2019}")
    #expect(Markdown.curled("\" ok", after: "a") == "\u{201D} ok")
    #expect(Markdown.paragraphs("Say `\"x\"` and \"y\"").joined(terminated: false).string == "Say \"x\" and \u{201C}y\u{201D}")
  }

  @Test func chunkedParsingMatchesOnePass() {
    let source = "Intro\n\n1. one\n2. two\n\n> quote\n\n```\ncode\n\nmore\n```\n\nEnd"

    #expect(text(source) == "Intro\n\t1.\tone\n\t2.\ttwo\nquote\ncode\n\nmore\nEnd")
  }
}
