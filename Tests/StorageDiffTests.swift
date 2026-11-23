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

  @Test func appendingLeavesEveryOldElementAlone() {
    let old = [element("a", "one"), element("b", "two")]

    #expect(elementEdits(from: old, to: old + [element("c", "three")]) == [ElementEdit(old: 2..<2, new: 2..<3)])
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

  @Test func commonPrefixKeepsSurrogatePairsWhole() {
    // Both emoji start with the same high surrogate.
    #expect(commonPrefixLength(NSAttributedString(string: "ab\u{1F600}"), NSAttributedString(string: "ab\u{1F601}")) == 2)
  }
}

/// The storage bookkeeping, checked against rendering the whole list from scratch.
@MainActor
struct TranscriptTextTests {
  /// A reply's text ended by a newline; a reply with no text renders nothing, like an element with no paragraphs.
  func render(_ element: TranscriptElement) -> NSAttributedString {
    guard case .reply(let text) = element.kind, !text.isEmpty else { return NSAttributedString() }

    return NSAttributedString(string: text + "\n", attributes: [.toggle: element.id])
  }

  func whole(_ elements: [TranscriptElement]) -> NSAttributedString {
    let text = NSMutableAttributedString()
    for element in elements { text.append(render(element)) }

    if text.length > 0 { text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1)) }

    return text
  }

  func element(_ id: String, _ text: String) -> TranscriptElement { TranscriptElement(id: id, kind: .reply(text)) }

  @Test func appendingWritesOnlyTheNewText() {
    var text = TranscriptText()
    let storage = NSMutableAttributedString()
    let first = [element("a", "one"), element("b", "two")]

    #expect(text.update(to: first, in: storage, render: render) == [NSRange(location: 0, length: 7)])
    #expect(storage.string == "one\ntwo")
    // "two" keeps its characters; only its newline and the new element are written.
    #expect(text.update(to: first + [element("c", "three")], in: storage, render: render) == [NSRange(location: 7, length: 6)])
    #expect(storage.string == "one\ntwo\nthree")
    #expect(text.update(to: first, in: storage, render: render) == [NSRange(location: 7, length: 0)])
    #expect(storage.string == "one\ntwo")
  }

  @Test func growingElementWritesOnlyItsTail() {
    var text = TranscriptText()
    let storage = NSMutableAttributedString()

    _ = text.update(to: [element("a", "one"), element("b", "streaming"), element("c", "last")], in: storage, render: render)
    // The shared "streaming" stays; what follows it, newline included, is written.
    #expect(text.update(to: [element("a", "one"), element("b", "streaming more"), element("c", "last")], in: storage, render: render) == [NSRange(location: 13, length: 6)])
    #expect(storage.string == "one\nstreaming more\nlast")
    #expect(text.range(of: "b", in: storage.length) == NSRange(location: 4, length: 15))
    #expect(text.range(of: "c", in: storage.length) == NSRange(location: 19, length: 4))
    #expect(text.element(at: 5)?.id == "b")
  }

  @Test func randomEditsMatchAFullRender() {
    var seed: UInt64 = 42

    func random(_ bound: Int) -> Int {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((seed >> 33) % UInt64(bound))
    }

    for _ in 0..<300 {
      var text = TranscriptText()
      let storage = NSMutableAttributedString()
      var elements: [TranscriptElement] = []
      var nextId = 0

      for _ in 0..<25 {
        for _ in 0..<(1 + random(3)) {
          let words = ["", "a", "bc", "longer text", "two\nlines"]

          switch random(5) {
          case 0 where !elements.isEmpty:
            elements.remove(at: random(elements.count))
          case 1 where !elements.isEmpty:
            let index = random(elements.count)
            elements[index] = element(elements[index].id, words[random(words.count)])
          case 2 where elements.count > 1:
            elements.swapAt(random(elements.count), random(elements.count))
          default:
            nextId += 1
            elements.insert(element("e\(nextId)", words[random(words.count)]), at: random(elements.count + 1))
          }
        }

        _ = text.update(to: elements, in: storage, render: render)

        if !storage.isEqual(to: whole(elements)) {
          #expect(storage.string == whole(elements).string, "The text differs from a full render")
          return
        }
      }
    }
  }
}
