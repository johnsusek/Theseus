import AppKit
import ClaudeEngine
import WebKit

/// Reading a tab's page: requests to the page script, code run in the page, and pictures of it.
extension BrowserTab {
  /// The widest picture a tool hands the model; a wider page is scaled down to it.
  static let widestPicture = 1568.0

  /// Sends the page script a request, as SafariPilot's protocol.ts and webview/index.ts define them. A request the script refuses throws its reason.
  @discardableResult
  func ask(_ request: [String: Any]) async throws -> JSONValue {
    let name = request["op"] as? String ?? "the request"
    let reply: Any?

    do {
      reply = try await webView.callAsyncJavaScript("return await safaripilot(request)", arguments: ["request": request], in: nil, contentWorld: Self.world)
    } catch {
      throw ToolFailure("The page did not answer \(name): \(Self.scriptMessage(error))")
    }

    guard let reply, JSONSerialization.isValidJSONObject(reply) else { throw ToolFailure("The page answered \(name) with nothing.") }

    let value = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: reply))
    guard value["ok"]?.bool == true else { throw ToolFailure(value["error"]?.string ?? "The page refused \(name).") }

    return value
  }

  /// Runs code in the page's own world the way a console does: the last expression is the result, and `await` works at the top level.
  func run(_ code: String) async throws -> String {
    let body = try await ask(["op": "replBody", "code": code])["body"]?.string ?? code
    // A promise that never settles would hold the tool call for good.
    let wrapped = """
      let late = new Promise((resolve, reject) => setTimeout(() => reject(new Error("the code did not finish within 15 s")), 15000));
      let value = await Promise.race([(async function () {\n\(body)\n}).call(globalThis), late]);
      return typeof value === "string" ? value : JSON.stringify(value, null, 2) ?? String(value);
      """

    do {
      return try await webView.callAsyncJavaScript(wrapped, arguments: [:], in: nil, contentWorld: .page) as? String ?? "undefined"
    } catch {
      throw ToolFailure("The code threw: \(Self.scriptMessage(error))")
    }
  }

  private static func scriptMessage(_ error: any Error) -> String {
    (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
  }

  /// The page as shown, or `region` of it in page points, as a PNG one pixel per point times `scale`.
  func picture(of region: CGRect? = nil, scale: Double = 1) async throws -> (image: HostToolImage, size: NSSize, scale: Double) {
    let configuration = WKSnapshotConfiguration()

    if let region { configuration.rect = region }

    let snapshot = try await webView.takeSnapshot(configuration: configuration)
    let fitted = min(scale, Self.widestPicture / max(snapshot.size.width, 1))
    let size = NSSize(width: (snapshot.size.width * fitted).rounded(), height: (snapshot.size.height * fitted).rounded())

    guard size.width >= 1, size.height >= 1,
          let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw ToolFailure("The page has no size to draw.") }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    snapshot.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw ToolFailure("The picture could not be made a PNG.") }

    return (HostToolImage(data: data, mimeType: "image/png"), snapshot.size, fitted)
  }
}
