import AppKit
import Highlightr

/// Colors code with highlight.js, in colors that follow light and dark mode.
@MainActor
enum CodeHighlighter {
  private struct Key: Hashable {
    var code: String
    var language: String
  }

  private static let light = highlightr(theme: "atom-one-light")
  private static let dark = highlightr(theme: "atom-one-dark")
  private static var cache: [Key: [(range: NSRange, color: NSColor)]] = [:]
  private static var cachedBytes = 0

  /// File extensions highlight.js does not take as language names.
  private static let extensions = ["h": "objectivec", "m": "objectivec", "mm": "objectivec", "hpp": "cpp", "cc": "cpp", "zsh": "bash", "command": "bash", "yml": "yaml", "htm": "html", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript", "tsx": "typescript", "plist": "xml", "svg": "xml", "entitlements": "xml"]

  private static func highlightr(theme: String) -> Highlightr? {
    let highlightr = Highlightr()

    if highlightr == nil { log.error("Highlightr did not load; code shows without colors") }

    _ = highlightr?.setTheme(to: theme)
    return highlightr
  }

  /// The language highlight.js knows a file by, from its extension.
  static func language(ofFile path: String) -> String? {
    let ext = URL(filePath: path).pathExtension.lowercased()

    if let name = extensions[ext] { return name }

    return light?.supportedLanguages().contains(ext) == true ? ext : nil
  }

  /// `lines` as text in `font`, colored as `language`, which highlight.js reads as a name or an alias. Without a language the lines are plain.
  static func lines(_ lines: [String], language: String?, font: NSFont, color: NSColor) -> [NSMutableAttributedString] {
    let colored = lines.map { NSMutableAttributedString(string: $0, attributes: [.font: font, .foregroundColor: color]) }
    guard let language, !language.isEmpty else { return colored }

    let runs = runs(lines.joined(separator: "\n"), language: language)
    var start = 0

    for line in colored {
      let range = NSRange(location: start, length: line.length)

      for run in runs {
        let overlap = NSIntersectionRange(run.range, range)

        if overlap.length > 0 { line.addAttribute(.foregroundColor, value: run.color, range: NSRange(location: overlap.location - start, length: overlap.length)) }
      }

      start += line.length + 1
    }

    return colored
  }

  /// The colored stretches of `code`. The theme's plain text color is left out, so plain text keeps the transcript's color.
  private static func runs(_ code: String, language: String) -> [(range: NSRange, color: NSColor)] {
    let key = Key(code: code, language: language)

    if let cached = cache[key] { return cached }

    guard let light = light?.highlight(code, as: language), let dark = dark?.highlight(code, as: language), light.string == code, dark.string == code else { return [] }

    let plain = (mostUsedColor(in: light), mostUsedColor(in: dark))
    var runs: [(range: NSRange, color: NSColor)] = []

    light.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: light.length)) { lightColor, lightRange, _ in
      dark.enumerateAttribute(.foregroundColor, in: lightRange) { darkColor, range, _ in
        guard let lightColor = lightColor as? NSColor, let darkColor = darkColor as? NSColor, lightColor != plain.0 || darkColor != plain.1 else { return }

        runs.append((range, NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor }))
      }
    }

    if cachedBytes > 2_000_000 {
      cache = [:]
      cachedBytes = 0
    }

    cache[key] = runs
    cachedBytes += code.utf8.count
    return runs
  }

  private static func mostUsedColor(in text: NSAttributedString) -> NSColor? {
    var lengths: [NSColor: Int] = [:]

    text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { color, range, _ in
      if let color = color as? NSColor { lengths[color, default: 0] += range.length }
    }

    return lengths.max { $0.value < $1.value }?.key
  }
}
