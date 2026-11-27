import Foundation
import UniformTypeIdentifiers
import WebKit
import cmark_gfm
import cmark_gfm_extensions

/// Markdown drawn the way GitHub draws it: cmark-gfm's HTML in GitHub's stylesheet, with markdown-page.js adding the rest.
@MainActor
enum MarkdownPage {
  static let scheme = "theseus-preview"

  /// Raw HTML stays, as on GitHub, and `tagfilter` escapes the tags GitHub escapes, such as script and iframe.
  private static let options = CMARK_OPT_UNSAFE | CMARK_OPT_FOOTNOTES
  private static let extensions = ["table", "strikethrough", "autolink", "tagfilter", "tasklist"]

  private static let styles = ["github-markdown.css", "markdown-page.css"].map { resource($0) }.joined(separator: "\n")
    + "@media (prefers-color-scheme: light) {\(resource("hljs-light.css"))}\n@media (prefers-color-scheme: dark) {\(resource("hljs-dark.css"))}"

  /// The scripts run in the app's own world, since the page's scripts are off.
  static let scripts = ["highlight.min.js", "markdown-page.js"].map { WKUserScript(source: resource($0), injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient) }

  /// The page's address, which the scheme handler serves at the file's own path so relative images and links resolve beside it.
  static func address(of file: URL) -> URL { URL(string: "\(scheme)://file\(file.path(percentEncoded: true))")! }

  static func body(_ source: String) -> String {
    cmark_gfm_core_extensions_ensure_registered()
    guard let parser = cmark_parser_new(options) else { return failure("cmark-gfm made no parser") }
    defer { cmark_parser_free(parser) }

    for name in extensions {
      guard let syntax = cmark_find_syntax_extension(name) else { return failure("cmark-gfm has no \(name) extension") }

      cmark_parser_attach_syntax_extension(parser, syntax)
    }

    cmark_parser_feed(parser, source, source.utf8.count)
    guard let document = cmark_parser_finish(parser) else { return failure("cmark-gfm parsed nothing") }
    defer { cmark_node_free(document) }

    guard let html = cmark_render_html(document, options, cmark_parser_get_syntax_extensions(parser)) else { return failure("cmark-gfm rendered nothing") }
    defer { free(html) }

    return String(cString: html)
  }

  static func page(of file: URL) -> String {
    let body = (try? String(contentsOf: file, encoding: .utf8)).map(body) ?? failure("Could not read \(file.path)")

    return "<!doctype html><html><head><meta charset=\"utf-8\"><style>\(styles)</style></head><body><article class=\"markdown-body\">\(body)</article></body></html>"
  }

  private static func failure(_ message: String) -> String {
    log.error("\(message, privacy: .public)")

    let escaped = message.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    return "<p style=\"color: #d1242f\">\(escaped)</p>"
  }

  private static func resource(_ name: String) -> String {
    guard let url = Bundle.main.url(forResource: name, withExtension: nil), let text = try? String(contentsOf: url, encoding: .utf8) else {
      log.error("The markdown preview is missing \(name, privacy: .public)")
      return ""
    }

    return text
  }
}

/// Serves the previewed file's address as its page, and any other path as that file from disk.
final class MarkdownSchemeHandler: NSObject, WKURLSchemeHandler {
  var document: URL?

  func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
    guard let address = task.request.url else { return }

    let file = URL(filePath: address.path(percentEncoded: false))

    do {
      let isPage = file.standardizedFileURL == document?.standardizedFileURL
      let data = isPage ? Data(MarkdownPage.page(of: file).utf8) : try Data(contentsOf: file)
      let type = isPage ? "text/html" : UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"

      task.didReceive(URLResponse(url: address, mimeType: type, expectedContentLength: data.count, textEncodingName: isPage ? "utf-8" : nil))
      task.didReceive(data)
      task.didFinish()
    } catch {
      task.didFailWithError(error)
    }
  }

  func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
