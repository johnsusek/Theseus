import AppKit
import Testing

@MainActor
struct MarkdownTests {
  func text(_ source: String) -> String { Markdown.paragraphs(source).joined(terminated: false).string }

  func decorations(_ source: String) -> [Decoration?] { Markdown.paragraphs(source).map { $0.base[.decoration] as? Decoration } }

  @Test func chunksSplitOnlyBetweenTopLevelBlocks() {
    #expect(Markdown.chunks(of: "One.\n\nTwo.\n\n\nThree.") == ["One.", "Two.", "Three."])
    #expect(Markdown.chunks(of: "```\ncode\n\nmore\n```\n\nAfter") == ["```\ncode\n\nmore\n```", "After"])
    #expect(Markdown.chunks(of: "- item\n\n  continued\n\nNext") == ["- item\n\n  continued", "Next"])
    #expect(Markdown.chunks(of: "Text\n\n```swift\nlet half = ") == ["Text", "```swift\nlet half = "])
    #expect(Markdown.chunks(of: "").isEmpty)
  }

  @Test func blocksBecomeParagraphs() {
    #expect(text("# Title\n\nBody with **bold** and `code`.\nSame paragraph.") == "Title\nBody with bold and code. Same paragraph.")
    #expect(text("1. First\n2. Second\n   - Nested") == "\t1.\tFirst\n\t2.\tSecond\n\t\u{2022}\tNested")
    #expect(text("Line one\\\nLine two") == "Line one\u{2028}Line two")
    #expect(text("| Name | Count |\n|:--|--:|\n| turns | 12 |") == "Name\tCount\nturns\t12")
  }

  @Test func inlineStylesMapToAttributes() {
    let rendered = Markdown.paragraphs("Plain **bold** *italic* `code` ~~gone~~ [link](https://example.com)").joined(terminated: false)
    let string = rendered.string as NSString

    func attributes(of word: String) -> [NSAttributedString.Key: Any] { rendered.attributes(at: string.range(of: word).location, effectiveRange: nil) }

    #expect((attributes(of: "bold")[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    #expect((attributes(of: "italic")[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic) == true)
    #expect((attributes(of: "code")[.font] as? NSFont)?.isFixedPitch == true)
    #expect(attributes(of: "code")[.backgroundColor] != nil)
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

    #expect(spacings == [0, 18, 10, 4, 10])
    #expect(Markdown.paragraphs("```\ncode\n```")[0].style.paragraphSpacingBefore == Decoration.Fill.code.padding)
  }

  @Test func chunkedParsingMatchesOnePass() {
    let source = "Intro\n\n1. one\n2. two\n\n> quote\n\n```\ncode\n\nmore\n```\n\nEnd"

    #expect(text(source) == "Intro\n\t1.\tone\n\t2.\ttwo\nquote\ncode\n\nmore\nEnd")
  }
}
