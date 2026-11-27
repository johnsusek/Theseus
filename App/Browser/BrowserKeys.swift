import AppKit

/// One key press for a page: the hardware key, the characters it types, and the modifiers held.
struct KeyStroke: Equatable {
  var code: UInt16
  var characters: String
  var modifiers: NSEvent.ModifierFlags = []
}

struct UnknownKey: LocalizedError {
  let errorDescription: String?
}

/// Key names and characters as key presses on a US keyboard, which is what a page's `code` and `keyCode` report.
enum BrowserKeys {
  /// Each printable key's plain and shifted character, by key code.
  private static let printable: [UInt16: String] = [
    0: "aA", 1: "sS", 2: "dD", 3: "fF", 4: "hH", 5: "gG", 6: "zZ", 7: "xX", 8: "cC", 9: "vV", 11: "bB", 12: "qQ", 13: "wW", 14: "eE", 15: "rR", 16: "yY", 17: "tT",
    18: "1!", 19: "2@", 20: "3#", 21: "4$", 22: "6^", 23: "5%", 24: "=+", 25: "9(", 26: "7&", 27: "-_", 28: "8*", 29: "0)", 30: "]}", 31: "oO", 32: "uU", 33: "[{",
    34: "iI", 35: "pP", 37: "lL", 38: "jJ", 39: "'\"", 40: "kK", 41: ";:", 42: "\\|", 43: ",<", 44: "/?", 45: "nN", 46: "mM", 47: ".>", 50: "`~"
  ]

  private static let typed: [Character: KeyStroke] = {
    var strokes: [Character: KeyStroke] = [" ": KeyStroke(code: 49, characters: " "), "\n": KeyStroke(code: 36, characters: "\r"), "\t": KeyStroke(code: 48, characters: "\t")]

    for (code, pair) in printable {
      guard let plain = pair.first, let shifted = pair.last else { continue }

      strokes[plain] = KeyStroke(code: code, characters: String(plain))
      strokes[shifted] = KeyStroke(code: code, characters: String(shifted), modifiers: .shift)
    }

    return strokes
  }()

  /// Named keys by their DOM `key` name in lower case, with the arrows' short names too.
  private static let named: [String: KeyStroke] = {
    func function(_ code: UInt16, _ scalar: Int, _ extra: NSEvent.ModifierFlags = []) -> KeyStroke {
      KeyStroke(code: code, characters: String(UnicodeScalar(scalar).map(Character.init) ?? " "), modifiers: extra.union(.function))
    }

    var keys: [String: KeyStroke] = [
      "enter": KeyStroke(code: 36, characters: "\r"), "return": KeyStroke(code: 36, characters: "\r"), "tab": KeyStroke(code: 48, characters: "\t"),
      "space": KeyStroke(code: 49, characters: " "), "backspace": KeyStroke(code: 51, characters: "\u{7F}"), "escape": KeyStroke(code: 53, characters: "\u{1B}"),
      "esc": KeyStroke(code: 53, characters: "\u{1B}"), "delete": function(117, NSDeleteFunctionKey), "home": function(115, NSHomeFunctionKey),
      "end": function(119, NSEndFunctionKey), "pageup": function(116, NSPageUpFunctionKey), "pagedown": function(121, NSPageDownFunctionKey),
      "arrowleft": function(123, NSLeftArrowFunctionKey, .numericPad), "arrowright": function(124, NSRightArrowFunctionKey, .numericPad),
      "arrowdown": function(125, NSDownArrowFunctionKey, .numericPad), "arrowup": function(126, NSUpArrowFunctionKey, .numericPad)
    ]

    for direction in ["left", "right", "down", "up"] { keys[direction] = keys["arrow" + direction] }

    for (index, code) in ([122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111] as [UInt16]).enumerated() { keys["f\(index + 1)"] = function(code, NSF1FunctionKey + index) }

    return keys
  }()

  private static let modifiers: [String: NSEvent.ModifierFlags] = [
    "cmd": .command, "command": .command, "meta": .command, "ctrl": .control, "control": .control, "alt": .option, "option": .option, "shift": .shift
  ]

  /// The press that types `character`. One no US key types, such as an accented letter or an emoji, rides on the A key, as an input method would send it.
  static func stroke(typing character: Character) -> KeyStroke { typed[character] ?? KeyStroke(code: 0, characters: String(character)) }

  /// A press written as a key name or a character with modifiers in front, such as `Enter`, `cmd+a` or `shift+ArrowLeft`.
  static func stroke(named text: String) throws -> KeyStroke {
    // "cmd++" presses the plus key.
    let parts = text.hasSuffix("+") ? text.dropLast().split(separator: "+").map(String.init) + ["+"] : text.split(separator: "+").map(String.init)
    guard let key = parts.last else { throw UnknownKey(errorDescription: "No key was named.") }

    var stroke: KeyStroke

    if let known = named[key.lowercased()] {
      stroke = known
    } else if key.count == 1, let character = key.first, let known = typed[character] {
      stroke = known
    } else {
      throw UnknownKey(errorDescription: "Unknown key \(key). Name a key such as Enter, Tab, Escape, Backspace, Delete, ArrowLeft, Home, PageDown or F5, or give one character.")
    }

    for name in parts.dropLast() {
      guard let flag = modifiers[name.lowercased()] else { throw UnknownKey(errorDescription: "Unknown modifier \(name). Use cmd, ctrl, alt or shift.") }

      stroke.modifiers.insert(flag)
    }

    // With command or control held a key reports its unshifted character, as the keyboard does.
    if !stroke.modifiers.isDisjoint(with: [.command, .control]), let plain = printable[stroke.code]?.first { stroke.characters = String(plain) }

    return stroke
  }

  /// Modifier names as flags, for a click with keys held.
  static func flags(_ names: String) throws -> NSEvent.ModifierFlags {
    try names.split(separator: "+").reduce(into: []) { flags, name in
      guard let flag = modifiers[name.lowercased()] else { throw UnknownKey(errorDescription: "Unknown modifier \(name). Use cmd, ctrl, alt or shift.") }

      flags.insert(flag)
    }
  }
}
