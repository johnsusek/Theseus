import Foundation

/// One edit to the transcript's text: the elements at `old` give way to the new elements at `new`.
struct ElementEdit: Equatable {
  var old: Range<Int>
  var new: Range<Int>
}

/// The edits that turn `old` into `new`, last first, so applying one leaves the ranges of those before it valid.
/// Equal elements are left alone.
func elementEdits(from old: [TranscriptElement], to new: [TranscriptElement]) -> [ElementEdit] {
  func same(_ oldIndex: Int, _ newIndex: Int) -> Bool { old[oldIndex] == new[newIndex] }

  let shorter = min(old.count, new.count)
  var prefix = 0
  var suffix = 0

  while prefix < shorter, same(prefix, prefix) { prefix += 1 }

  while suffix < shorter - prefix, same(old.count - 1 - suffix, new.count - 1 - suffix) { suffix += 1 }

  let oldIds = old[prefix..<(old.count - suffix)].map(\.id)
  let newIds = new[prefix..<(new.count - suffix)].map(\.id)
  var removed: Set<Int> = []
  var inserted: Set<Int> = []
  var edits: [ElementEdit] = []
  var oldIndex = 0
  var newIndex = 0
  var isOpen = false

  for change in newIds.difference(from: oldIds) {
    switch change {
    case .remove(let offset, _, _): removed.insert(offset)
    case .insert(let offset, _, _): inserted.insert(offset)
    }
  }

  /// Grows the edit in progress, or starts one where the last unchanged element ended.
  func change(old oldCount: Int, new newCount: Int) {
    if !isOpen { edits.append(ElementEdit(old: (prefix + oldIndex)..<(prefix + oldIndex), new: (prefix + newIndex)..<(prefix + newIndex))) }

    let last = edits.count - 1
    edits[last].old = edits[last].old.lowerBound..<(edits[last].old.upperBound + oldCount)
    edits[last].new = edits[last].new.lowerBound..<(edits[last].new.upperBound + newCount)
    isOpen = true
    oldIndex += oldCount
    newIndex += newCount
  }

  while oldIndex < oldIds.count || newIndex < newIds.count {
    if oldIndex < oldIds.count, removed.contains(oldIndex) {
      change(old: 1, new: 0)
    } else if newIndex < newIds.count, inserted.contains(newIndex) {
      change(old: 0, new: 1)
    } else if same(prefix + oldIndex, prefix + newIndex) {
      isOpen = false
      oldIndex += 1
      newIndex += 1
    } else {
      change(old: 1, new: 1)
    }
  }

  return edits.reversed()
}

/// How many UTF-16 units two attributed strings share from the start, counting characters and attributes.
/// Replacing only what follows keeps a streaming reply's earlier paragraphs, and a selection in them, untouched.
func commonPrefixLength(_ first: NSAttributedString, _ second: NSAttributedString) -> Int {
  let shared = (first.string as NSString).commonPrefix(with: second.string, options: .literal).utf16.count
  let limit = NSRange(location: 0, length: shared)
  var index = 0

  while index < shared {
    var firstRange = NSRange()
    var secondRange = NSRange()
    let firstAttributes = first.attributes(at: index, longestEffectiveRange: &firstRange, in: limit)
    let secondAttributes = second.attributes(at: index, longestEffectiveRange: &secondRange, in: limit)
    guard NSDictionary(dictionary: firstAttributes).isEqual(to: secondAttributes) else { return index }

    index = min(NSMaxRange(firstRange), NSMaxRange(secondRange))
  }

  // Two emoji can share the first half of a surrogate pair, which must not be split from its second half.
  if shared > 0, shared < first.length, UTF16.isLeadSurrogate((first.string as NSString).character(at: shared - 1)) { return shared - 1 }

  return shared
}

/// The transcript's text as the text view holds it: every element's text in order, each ended by a newline.
/// The storage leaves out the very last newline, which TextKit 2 would lay out as an empty line under the transcript.
@MainActor
struct TranscriptText {
  private struct Entry {
    var element: TranscriptElement
    /// The UTF-16 length of the element's text with the newline that ends it. Zero for an element that renders nothing.
    var length: Int
    /// That newline with its attributes, to put back when the element stops being the last one.
    var terminator: NSAttributedString
  }

  private var entries: [Entry] = []

  /// Changes `storage` to hold `fresh`, rendering only the elements that changed, and returns the ranges it wrote.
  /// `render` gives an element's text ended by a newline. Text that an edit shares with what is already there is not
  /// written again, so a streaming reply rewrites only its tail and an element in front of an appended one is not touched.
  mutating func update(to fresh: [TranscriptElement], in storage: NSMutableAttributedString, render: (TranscriptElement) -> NSAttributedString) -> [NSRange] {
    let starts = entries.reduce(into: [0]) { starts, entry in starts.append(starts[starts.count - 1] + entry.length) }
    let total = starts[starts.count - 1]
    var edits: [ElementEdit] = []
    var written: [NSRange] = []

    // Edits with only empty elements between them touch the same characters, so they become one.
    for edit in elementEdits(from: entries.map(\.element), to: fresh) {
      if let last = edits.last, starts[edit.old.upperBound] == starts[last.old.lowerBound] {
        edits[edits.count - 1] = ElementEdit(old: edit.old.lowerBound..<last.old.upperBound, new: edit.new.lowerBound..<last.new.upperBound)
      } else {
        edits.append(edit)
      }
    }

    for edit in edits {
      let pieces = edit.new.map { render(fresh[$0]) }
      let text = NSMutableAttributedString()
      let lower = starts[edit.old.lowerBound]
      var range = NSRange(location: lower, length: starts[edit.old.upperBound] - lower)

      for piece in pieces { text.append(piece) }

      // The last edit reaches the end of the text, where the storage is one newline short.
      if starts[edit.old.upperBound] == total {
        let start = min(lower, storage.length)

        if text.length > 0 {
          text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))

          // Text added after the old last element gives that element its newline back.
          if lower == total, let terminator = entries[..<edit.old.lowerBound].last(where: { $0.length > 0 })?.terminator { text.insert(terminator, at: 0) }

          range = NSRange(location: start, length: storage.length - start)
        } else if lower < total {
          // The tail is gone, so the element before it becomes the last and gives up its newline.
          range = NSRange(location: max(lower - 1, 0), length: storage.length - max(lower - 1, 0))
        } else {
          range = NSRange(location: storage.length, length: 0)
        }
      }

      let shared = commonPrefixLength(storage.attributedSubstring(from: range), text)
      let change = NSRange(location: range.location + shared, length: range.length - shared)
      let replacement = text.attributedSubstring(from: NSRange(location: shared, length: text.length - shared))

      storage.replaceCharacters(in: change, with: replacement)
      // Earlier edits sit after this one and move by what it added or removed.
      written = written.map { NSRange(location: $0.location + replacement.length - change.length, length: $0.length) }
      written.append(NSRange(location: change.location, length: replacement.length))
      entries.replaceSubrange(edit.old, with: zip(edit.new, pieces).map { index, piece in
        Entry(element: fresh[index], length: piece.length, terminator: piece.length > 0 ? piece.attributedSubstring(from: NSRange(location: piece.length - 1, length: 1)) : NSAttributedString())
      })
    }

    return written
  }

  /// Where an element's text is in a storage of `length` characters.
  func range(of id: String, in length: Int) -> NSRange? {
    var location = 0

    for entry in entries {
      if entry.element.id == id { return NSRange(location: location, length: min(entry.length, length - location)) }

      location += entry.length
    }

    return nil
  }

  func element(at offset: Int) -> TranscriptElement? {
    var end = 0

    for entry in entries {
      end += entry.length

      if offset < end { return entry.element }
    }

    return entries.last?.element
  }
}
