import Foundation

/// Turns the paths the model writes, in tool arguments and in markdown links, into file URLs.
enum FilePaths {
  /// An absolute path, a `~` path, or a path relative to `base`.
  static func resolve(_ path: String, in base: URL) -> URL {
    URL(filePath: (path as NSString).expandingTildeInPath, relativeTo: base).standardizedFileURL.absoluteURL
  }

  /// The file a transcript link points at, or nil for a web or mail link, which opens as usual.
  /// A `:line` or `:line:column` suffix and a `#L12` fragment are dropped.
  static func target(ofLink link: Any, in base: URL) -> URL? {
    guard let string = (link as? URL)?.absoluteString ?? (link as? String) else { return nil }

    // A code span such as `/Users/me/App/Foo.swift:42` arrives as a file URL whose path still carries the suffix.
    if let url = URL(string: string), url.isFileURL {
      let path = withoutLocation(url.path)
      return path.isEmpty ? nil : URL(filePath: path).standardizedFileURL
    }

    // `Package.swift:12` parses as a URL with the scheme `package.swift`, so only `scheme://` and `mailto:` links are web links.
    guard !string.contains("://"), !string.lowercased().hasPrefix("mailto:") else { return nil }

    let path = withoutLocation(string.removingPercentEncoding ?? string)
    return path.isEmpty ? nil : resolve(path, in: base)
  }

  /// The path without a `#L12` fragment or a `:line` or `:line:column` suffix.
  private static func withoutLocation(_ path: String) -> String {
    var path = path

    if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }

    while let colon = path.lastIndex(of: ":"), path[path.index(after: colon)...].allSatisfy(\.isNumber) {
      path = String(path[..<colon])
    }

    return path
  }
}
