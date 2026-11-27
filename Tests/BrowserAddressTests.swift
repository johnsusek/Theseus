import Foundation
import Testing

struct BrowserAddressTests {
  func address(_ text: String, in folder: URL? = nil) -> String? { BrowserAddress.url(from: text, in: folder)?.absoluteString }

  @Test func keepsWrittenURLs() {
    #expect(address("https://example.com/a?b=1#c") == "https://example.com/a?b=1#c")
    #expect(address("  http://localhost:8770/perspective.html ") == "http://localhost:8770/perspective.html")
    #expect(address("about:blank") == "about:blank")
    #expect(address("") == nil)
  }

  @Test func localHostsGetHTTPAndOthersHTTPS() {
    #expect(address("localhost:8770/perspective.html") == "http://localhost:8770/perspective.html")
    #expect(address("127.0.0.1:3000") == "http://127.0.0.1:3000")
    #expect(address("devbox:5173/app") == "http://devbox:5173/app")
    #expect(address("printer.local") == "http://printer.local")
    #expect(address("example.com/docs") == "https://example.com/docs")
  }

  @Test func pathsBecomeFileURLs() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "browser-address-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder.appending(path: "Design"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data().write(to: folder.appending(path: "Design/logo.html"))

    #expect(address("/tmp/a.html") == "file:///tmp/a.html")
    #expect(address("~/a.html") == URL(filePath: NSHomeDirectory() + "/a.html").absoluteString)
    #expect(address("Design/logo.html", in: folder) == folder.appending(path: "Design/logo.html").absoluteString)
  }

  @Test func otherTextIsSearched() {
    #expect(address("swift testing docs") == "https://duckduckgo.com/?q=swift%20testing%20docs")
    #expect(address("webkit") == "https://duckduckgo.com/?q=webkit")
  }
}
