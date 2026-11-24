import AppKit
import Testing

@MainActor
struct TranscriptRendererTests {
  let renderer = TranscriptRenderer()

  func paragraphStyle(_ text: NSAttributedString, at location: Int = 0) -> NSParagraphStyle? { text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle }

  @Test func elementsEndWithANewlineAndAnEmptyOneRendersNothing() {
    #expect(renderer.attributedString(for: TranscriptElement(id: "a", kind: .reply("Hello"))).string == "Hello\n")
    #expect(renderer.attributedString(for: TranscriptElement(id: "b", kind: .reply("```"))).length == 0)
  }

  @Test func promptIsABubbleThatHugsTheRightEdge() {
    let text = renderer.attributedString(for: TranscriptElement(id: "p", kind: .prompt("Short\n\nprompt"), spacing: 22))
    let decorations = [0, 6, 7].map { (text.attribute(.decoration, at: $0, effectiveRange: nil) as? DecorationValue)?.decoration }
    let width = text.attribute(.bubbleWidth, at: 0, effectiveRange: nil) as? CGFloat ?? 0
    let style = paragraphStyle(text)

    #expect(text.string == "Short\n\nprompt\n")
    #expect(decorations.map { $0?.fill } == [.bubble, .bubble, .bubble])
    #expect(decorations.map { $0?.roundsTop } == [true, false, false])
    #expect(decorations.map { $0?.roundsBottom } == [false, false, true])
    #expect(width > 30 && width < 80)
    #expect(style?.headIndent == TranscriptStyle.bubbleIndent(textWidth: width, columnWidth: 720))
    #expect((style?.headIndent ?? 0) > 600)
    #expect(style?.paragraphSpacingBefore == CGFloat(30))
  }

  @Test func longPromptStartsAfterTheLead() {
    let text = renderer.attributedString(for: TranscriptElement(id: "p", kind: .prompt(String(repeating: "word ", count: 80))))

    #expect(paragraphStyle(text)?.headIndent == CGFloat(Decoration.bubbleLead + Decoration.bubbleInset))
    #expect(paragraphStyle(text)?.tailIndent == CGFloat(-Decoration.bubbleInset))
  }

  @Test func toolRowTogglesAndTintsItsLineCounts() {
    let row = ToolRow(id: "t1", verb: "Edited", target: "A.swift", added: 12, removed: 3, isExpanded: false, tooltip: "/tmp/A.swift")
    let text = renderer.attributedString(for: TranscriptElement(id: "t1", kind: .tool(row)))
    let string = text.string as NSString

    #expect(text.string.replacingOccurrences(of: "\u{FFFC}", with: "@") == "Edited A.swift  +12 -3  @\n")
    #expect(text.attribute(.toggle, at: 0, effectiveRange: nil) as? String == "t1")
    #expect(text.attribute(.toggle, at: text.length - 1, effectiveRange: nil) as? String == "t1")
    #expect(text.attribute(.toolTip, at: 0, effectiveRange: nil) as? String == "/tmp/A.swift")
    #expect(text.attribute(.activeTint, at: string.range(of: "+12").location, effectiveRange: nil) as? NSColor == .systemGreen)
    #expect(text.attribute(.activeTint, at: string.range(of: "-3").location, effectiveRange: nil) as? NSColor == .systemRed)
    #expect(text.attribute(.activeTint, at: 0, effectiveRange: nil) == nil)
  }

  @Test func runningAndFailedRowsCarryAMark() {
    var marks: [StatusMark] = []
    var renderer = TranscriptRenderer()
    renderer.mark = { mark in
      marks.append(mark)
      return NSTextAttachment()
    }

    let running = renderer.attributedString(for: TranscriptElement(id: "t1", kind: .tool(ToolRow(id: "t1", verb: "Running", target: "swift test", state: .running))))
    let waiting = renderer.attributedString(for: TranscriptElement(id: "t2", kind: .tool(ToolRow(id: "t2", verb: "Editing", target: "A.swift", state: .waiting))))
    let failed = renderer.attributedString(for: TranscriptElement(id: "t3", kind: .tool(ToolRow(id: "t3", verb: "Ran", target: "swift build", state: .failed))))

    let stopped = renderer.attributedString(for: TranscriptElement(id: "t4", kind: .tool(ToolRow(id: "t4", verb: "Running", target: "sleep 600", state: .stopped))))

    #expect(marks == [.running, .running, .failed])
    #expect(running.string.replacingOccurrences(of: "\u{FFFC}", with: "@") == "@ Running swift test  @\n")
    #expect(waiting.string.replacingOccurrences(of: "\u{FFFC}", with: "@") == "@ Editing A.swift  Needs Approval  @\n")
    #expect(failed.string.replacingOccurrences(of: "\u{FFFC}", with: "@") == "Ran swift build @  @\n")
    #expect(stopped.string.replacingOccurrences(of: "\u{FFFC}", with: "@") == "Running sleep 600  Stopped  @\n")
  }

  @Test func boxedRowsAndDetailCarryTheBorder() {
    let row = TranscriptElement(id: "t1", kind: .tool(ToolRow(id: "t1", verb: "Ran", target: "ls")), spacing: 8, box: BoxSlot(isFirst: true))
    let detail = TranscriptElement(id: "t1/detail", kind: .detail([.command("$ ls"), .diff([" keep", "-old", "+new"])]), spacing: 0, box: BoxSlot(isLast: true))
    let rowText = renderer.attributedString(for: row)
    let detailText = renderer.attributedString(for: detail)
    let boxes = [0, 5, 10, 14].map { (detailText.attribute(.decoration, at: $0, effectiveRange: nil) as? DecorationValue)?.decoration.box }

    #expect((rowText.attribute(.decoration, at: 0, effectiveRange: nil) as? DecorationValue)?.decoration.box == Decoration.Box(isFirst: true, isLast: false, topGap: 8, hasDivider: false))
    #expect(paragraphStyle(rowText)?.headIndent == CGFloat(Decoration.boxInset))
    #expect(paragraphStyle(rowText)?.paragraphSpacingBefore == CGFloat(16))
    #expect(detailText.string == "$ ls\nkeep\nold\nnew\n")
    #expect(boxes.map { $0?.isLast } == [false, false, false, true])
    #expect([0, 5, 10, 14].map { (detailText.attribute(.decoration, at: $0, effectiveRange: nil) as? DecorationValue)?.decoration.fill } == [.code, nil, .removed, .added])
    #expect(paragraphStyle(detailText, at: 14)?.paragraphSpacing == CGFloat(8))
  }

  @Test func cardsAreOneAttachment() {
    var asked: [String] = []
    var renderer = TranscriptRenderer()
    renderer.card = { element in
      asked.append(element.id)
      return NSTextAttachment()
    }

    let text = renderer.attributedString(for: TranscriptElement(id: "permission/r1", kind: .permission(requestId: "r1"), spacing: 8))

    #expect(asked == ["permission/r1"])
    #expect(text.string == "\u{FFFC}\n")
    #expect(paragraphStyle(text)?.paragraphSpacingBefore == CGFloat(8))
  }

  @Test func permissionBodyTintsAnEdit() {
    let body = renderer.permissionBody(.diff([" keep", "-old", "+new"]))

    #expect(body.string == "keep\nold\nnew")
    #expect([0, 5, 9].map { (body.attribute(.decoration, at: $0, effectiveRange: nil) as? DecorationValue)?.decoration.fill } == [nil, .removed, .added])
  }

  @Test func hunkHeadersNumberTheLines() {
    let body = renderer.permissionBody(.diff(["@@ -3,2 +3,3 @@", " keep", "-old", "+new", "+more", "@@ -9,1 +10,1 @@", " ten"]))

    #expect(body.string == "\t3\tkeep\n\t4\told\n\t4\tnew\n\t5\tmore\n\t\t\u{22EF}\n\t10\tten")
    #expect(renderer.permissionBody(.diff(["+a", "+b"])).string == "\t1\ta\n\t2\tb")
  }

  @Test func decoratedTextCanBeArchived() throws {
    let text = renderer.attributedString(for: TranscriptElement(id: "p", kind: .reply("> quoted\n\n```\ncode\n```")))
    let data = try NSKeyedArchiver.archivedData(withRootObject: text, requiringSecureCoding: false)
    let copy = try #require(try NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSAttributedString.self, DecorationValue.self, NSParagraphStyle.self, NSFont.self, NSColor.self, NSTextTab.self], from: data) as? NSAttributedString)

    #expect((copy.attribute(.decoration, at: copy.length - 2, effectiveRange: nil) as? DecorationValue)?.decoration.fill == .code)
  }
}
