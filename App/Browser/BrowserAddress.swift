import Foundation

/// Turns what was typed into the address field, or handed to a browser tool, into a URL.
enum BrowserAddress {
  private static let schemes: Set = ["http", "https", "file", "about", "data", "blob"]
  private static let localSuffixes = [".localhost", ".local", ".test"]

  /// A URL as written, a file path (absolute, or one that exists in `folder`), a host, or else a web search.
  static func url(from text: String, in folder: URL? = nil) -> URL? {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }

    if text.hasPrefix("/") || text.hasPrefix("~") { return URL(filePath: (text as NSString).expandingTildeInPath) }

    if let scheme = text.firstMatch(of: /^([A-Za-z][A-Za-z0-9+.-]*):/)?.1, schemes.contains(scheme.lowercased()) { return URL(string: text) }

    if let folder, FileManager.default.fileExists(atPath: folder.appending(path: text).path) { return folder.appending(path: text) }

    let authority = text.prefix { !"/?#".contains($0) }
    let host = authority.split(separator: ":").first.map(String.init) ?? ""
    let isHost = !text.contains(" ") && !host.isEmpty && (host.contains(".") || authority.contains(":") || host == "localhost")

    guard isHost else {
      var search = URLComponents(string: "https://duckduckgo.com/")
      search?.queryItems = [URLQueryItem(name: "q", value: text)]
      return search?.url
    }

    return URL(string: (isLocal(host) ? "http://" : "https://") + text)
  }

  /// A host that serves plain http: this Mac, a name with no dots, a development suffix, or an IPv4 address.
  static func isLocal(_ host: String) -> Bool {
    let host = host.lowercased()

    return host == "localhost" || !host.contains(".") || localSuffixes.contains { host.hasSuffix($0) } || host.allSatisfy { $0.isNumber || $0 == "." }
  }
}
