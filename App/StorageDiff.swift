import Foundation

/// One edit to the transcript's text: the elements at `old` give way to the new elements at `new`.
struct ElementEdit: Equatable {
  var old: Range<Int>
  var new: Range<Int>
}

/// The edits that turn `old` into `new`, last first, so applying one leaves the ranges of those after it valid.
/// An element is left alone when its content is equal and it still is, or still is not, the last one, which decides whether a newline ends it.
func elementEdits(from old: [TranscriptElement], to new: [TranscriptElement]) -> [ElementEdit] {
  func same(_ oldIndex: Int, _ newIndex: Int) -> Bool {
    old[oldIndex] == new[newIndex] && (oldIndex == old.count - 1) == (newIndex == new.count - 1)
  }

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

  return shared
}
