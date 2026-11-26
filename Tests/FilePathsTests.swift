import Foundation
import Testing

struct FilePathsTests {
  let base = URL(filePath: "/Users/me/project/", directoryHint: .isDirectory)

  func target(_ link: Any) -> String? { FilePaths.target(ofLink: link, in: base)?.path }

  @Test func resolvesRelativeAbsoluteAndHomePaths() {
    #expect(FilePaths.resolve("App/Markdown.swift", in: base).path == "/Users/me/project/App/Markdown.swift")
    #expect(FilePaths.resolve("../other/a.md", in: base).path == "/Users/me/other/a.md")
    #expect(FilePaths.resolve("/tmp/a.md", in: base).path == "/tmp/a.md")
    #expect(FilePaths.resolve("~/a.md", in: base).path == NSHomeDirectory() + "/a.md")
  }

  @Test func linksDropLineSuffixesAndFragments() {
    #expect(target(URL(string: "App/Markdown.swift:42")!) == "/Users/me/project/App/Markdown.swift")
    #expect(target(URL(string: "Package.swift:12:3")!) == "/Users/me/project/Package.swift")
    #expect(target(URL(string: "notes/plan.md#L7")!) == "/Users/me/project/notes/plan.md")
    #expect(target(URL(string: "notes/my%20plan.md")!) == "/Users/me/project/notes/my plan.md")
    #expect(target("README.md") == "/Users/me/project/README.md")
    #expect(target(URL(filePath: "/tmp/a.md")) == "/tmp/a.md")
    #expect(target(URL(filePath: "/tmp/a.swift:42")) == "/tmp/a.swift")
    #expect(target(URL(filePath: "/tmp/a.swift#L12")) == "/tmp/a.swift")
  }

  @Test func webAndMailLinksAreLeftAlone() {
    #expect(target(URL(string: "https://example.com/a.md")!) == nil)
    #expect(target(URL(string: "mailto:someone@example.com")!) == nil)
    #expect(target(URL(string: "#L7")!) == nil)
  }
}
