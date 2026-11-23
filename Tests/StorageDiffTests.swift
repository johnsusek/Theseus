import AppKit
import Testing

struct StorageDiffTests {
  func element(_ id: String, _ text: String) -> TranscriptElement { TranscriptElement(id: id, kind: .reply(text)) }

  /// Applies edits to a list of ids the way the view applies them to its text, to check they produce the new list.
  func applying(_ edits: [ElementEdit], from old: [TranscriptElement], to new: [TranscriptElement]) -> [TranscriptElement] {
    var result = old
    for edit in edits { result.replaceSubrange(edit.old, with: new[edit.new]) }
    return result
  }

  @Test func unchangedElementsAreLeftAlone() {
    let old = [element("a", "one"), element("b", "two"), element("c", "three")]

    #expect(elementEdits(from: old, to: old).isEmpty)
    #expect(elementEdits(from: [], to: []).isEmpty)
  }

  @Test func growingTailTouchesOnlyTheLastElements() {
    let old = [element("a", "one"), element("b", "two")]
    let new = [element("a", "one"), element("b", "two more"), element("c", "three")]

    #expect(elementEdits(from: old, to: new) == [ElementEdit(old: 1..<2, new: 1..<3)])
  }

  @Test func appendingReendsTheOldLastElement() {
    let old = [element("a", "one"), element("b", "two")]
    let new = old + [element("c", "three")]

    // "b" is equal but gains the newline that ends every element except the last.
    #expect(elementEdits(from: old, to: new) == [ElementEdit(old: 1..<2, new: 1..<3)])
  }

  @Test func separateChangesBecomeSeparateEdits() {
    let old = [element("a", "one"), element("b", "two"), element("c", "three"), element("d", "four"), element("e", "five")]
    let new = [element("a", "one"), element("b", "TWO"), element("c", "three"), element("x", "new"), element("d", "four"), element("e", "five")]
    let edits = elementEdits(from: old, to: new)

    #expect(edits == [ElementEdit(old: 3..<3, new: 3..<4), ElementEdit(old: 1..<2, new: 1..<2)])
    #expect(applying(edits, from: old, to: new) == new)
  }

  @Test func removalsMovesAndRewritesAllApply() {
    let old = [element("a", "one"), element("b", "two"), element("c", "three"), element("d", "four")]

    for new in [[element("a", "one"), element("d", "four")], [element("d", "four"), element("a", "one"), element("b", "two"), element("c", "three")], [element("z", "all new")], []] {
      #expect(applying(elementEdits(from: old, to: new), from: old, to: new) == new)
    }
  }

  @Test func commonPrefixStopsWhereTextOrAttributesDiffer() {
    let plain: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14)]
    let bold: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 14)]
    let first = NSMutableAttributedString(string: "Hello world", attributes: plain)
    let longer = NSMutableAttributedString(string: "Hello world, again", attributes: plain)
    let restyled = NSMutableAttributedString(string: "Hello world", attributes: plain)
    restyled.addAttributes(bold, range: NSRange(location: 6, length: 5))

    #expect(commonPrefixLength(first, longer) == 11)
    #expect(commonPrefixLength(first, restyled) == 6)
    #expect(commonPrefixLength(first, NSAttributedString(string: "Help", attributes: plain)) == 3)
    #expect(commonPrefixLength(first, NSAttributedString()) == 0)
  }
}
