import Foundation
import Testing

@MainActor
struct MarkdownPageTests {
  @Test func rendersGitHubExtensions() {
    let html = MarkdownPage.body("| A | B |\n|---|---|\n| 1 | 2 |\n\n- [x] done\n\n~~gone~~ https://example.com\n\n<script>alert(1)</script>\n\n```swift\nlet value = 1\n```\n\nNote[^1]\n\n[^1]: Footnote.")

    #expect(html.contains("<table>"))
    #expect(html.contains("<input type=\"checkbox\" checked=\"\" disabled=\"\" />"))
    #expect(html.contains("<del>gone</del>"))
    #expect(html.contains("<a href=\"https://example.com\">"))
    #expect(html.contains("&lt;script>"))
    #expect(html.contains("<code class=\"language-swift\">"))
    #expect(html.contains("class=\"footnotes\""))
  }

  @Test func addressKeepsTheFilePath() {
    #expect(MarkdownPage.address(of: URL(filePath: "/Users/me/My Docs/README.md")).absoluteString == "theseus-preview://file/Users/me/My%20Docs/README.md")
  }
}
