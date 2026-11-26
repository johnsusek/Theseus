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

  @Test func blankFindingsAndEmptyQuestionsRender() {
    let finding = ReviewFinding(id: "r/0", file: "a.swift", title: "Blank", detail: "\n\n", isExpanded: true)
    #expect(renderer.attributedString(for: TranscriptElement(id: "r", kind: .review(ReviewCard(heading: "1 finding", findings: [finding])))).length > 0)
    _ = renderer.attributedString(for: TranscriptElement(id: "q", kind: .question([])))
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

  @Test func runningRowsCarryAMarkAndFailedRowsSaySo() {
    var marks = 0
    var renderer = TranscriptRenderer()
    renderer.mark = {
      marks += 1
      return NSTextAttachment()
    }

    let running = renderer.attributedString(for: TranscriptElement(id: "t1", kind: .tool(ToolRow(id: "t1", verb: "Running", target: "swift test", state: .running))))
    let waiting = renderer.attributedString(for: TranscriptElement(id: "t2", kind: .tool(ToolRow(id: "t2", verb: "Editing", target: "A.swift", state: .waiting))))
    let failed = renderer.attributedString(for: TranscriptElement(id: "t3", kind: .tool(ToolRow(id: "t3", verb: "Build the app", target: "", state: .failed))))
    let denied = renderer.attributedString(for: TranscriptElement(id: "t5", kind: .tool(ToolRow(id: "t5", verb: "Could not run", target: "rm", note: "Denied", state: .failed))))
    let stopped = renderer.attributedString(for: TranscriptElement(id: "t4", kind: .tool(ToolRow(id: "t4", verb: "Running", target: "sleep 600", state: .stopped))))

    #expect(marks == 2)
    #expect(running.string.replacingOccurrences(of: "\u{FFFC}", with: "@") == "@ Running swift test  @\n")
    #expect(waiting.string.replacingOccurrences(of: "\u{FFFC}", with: "@") == "@ Editing A.swift  Needs Approval  @\n")
    #expect(failed.string.replacingOccurrences(of: "\u{FFFC}", with: "@") == "Build the app  Failed  @\n")
    #expect(failed.attribute(.foregroundColor, at: failed.string.count - 5, effectiveRange: nil) as? NSColor == .systemRed)
    #expect(denied.string.replacingOccurrences(of: "\u{FFFC}", with: "@") == "Could not run rm  Denied  @\n")
    #expect(stopped.string.replacingOccurrences(of: "\u{FFFC}", with: "@") == "Running sleep 600  Stopped  @\n")
  }

  @Test func liveGroupsShowTheActivityAndTimerAndRowsShowThumbnails() {
    var clocks: [Bool?] = []
    var renderer = TranscriptRenderer()
    renderer.columnWidth = 600
    renderer.clock = { _, chevron in
      clocks.append(chevron)
      return NSTextAttachment()
    }

    let live = renderer.attributedString(for: TranscriptElement(id: "g", kind: .group(GroupRow(id: "g", summary: "Ran 2 commands", added: 3, activity: Activity(text: "Building the app", since: .now)))))
    let row = renderer.attributedString(for: TranscriptElement(id: "t1", kind: .tool(ToolRow(id: "t1", verb: "Read", target: "a.png", thumbnails: [Thumbnail(id: "t1/0", data: Data())]))))

    #expect(clocks == [false])
    #expect(live.string.replacingOccurrences(of: "\u{FFFC}", with: "@") == "@ Building the app  @\n")
    #expect(row.string.replacingOccurrences(of: "\u{FFFC}", with: "@") == "Read a.png  @\t@\n")
    #expect((row.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.tabStops.map(\.location) == [566])
    #expect(row.attribute(.fitsColumn, at: 0, effectiveRange: nil) as? Bool == true)
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

  @Test func patchesUnderAFileNameAreColored() {
    let detail = renderer.attributedString(for: TranscriptElement(id: "t1/detail", kind: .detail([.diff(["+let a = 1"], file: "A.swift")])))
    let keyword = detail.attribute(.foregroundColor, at: (detail.string as NSString).range(of: "let").location, effectiveRange: nil) as? NSColor

    #expect(detail.string == "A.swift\n\t1\tlet a = 1\n")
    #expect(keyword != nil && keyword != NSColor.labelColor)
  }

  @Test func decoratedTextCanBeArchived() throws {
    let text = renderer.attributedString(for: TranscriptElement(id: "p", kind: .reply("> quoted\n\n```swift\nlet code = 1\n```")))
    let data = try NSKeyedArchiver.archivedData(withRootObject: text, requiringSecureCoding: false)
    let copy = try #require(try NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSAttributedString.self, DecorationValue.self, NSParagraphStyle.self, NSFont.self, NSColor.self, NSTextTab.self], from: data) as? NSAttributedString)

    #expect((copy.attribute(.decoration, at: copy.length - 2, effectiveRange: nil) as? DecorationValue)?.decoration.fill == .code)
  }
}
