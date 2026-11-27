import AVFoundation
import AppKit
import Foundation
import StagehandShared
import Testing
@testable import ClaudeWorkspace

/// Answers stagehand requests on a Unix socket with canned responses, one connection at a time, like the agent.
final class FakeAgent: @unchecked Sendable {
  let path = "/tmp/theseus-\(UUID().uuidString.prefix(8)).sock"
  private let listener: Int32
  private let lock = NSLock()
  private var answers: [String: Response]
  private var received: [Request] = []

  var requests: [Request] { lock.withLock { received } }

  init(_ answers: [String: Response]) {
    self.answers = answers
    listener = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      for (index, byte) in path.utf8.enumerated() { raw[index] = byte }
    }
    _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    listen(listener, 8)

    Thread.detachNewThread { [self] in
      while true {
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else { return }

        serve(connection)
      }
    }
  }

  func answer(_ command: String, _ response: Response) { lock.withLock { answers[command] = response } }

  private func serve(_ connection: Int32) {
    defer { close(connection) }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)

    while true {
      let count = read(connection, &buffer, buffer.count)
      if count <= 0 { break }
      data.append(buffer, count: count)
    }

    guard let request = try? JSONDecoder().decode(Request.self, from: data) else { return }

    let response = lock.withLock {
      received.append(request)
      return answers[request.command] ?? Response(ok: false, output: "unknown command")
    }

    let reply = (try? JSONEncoder().encode(response)) ?? Data()
    reply.withUnsafeBytes { _ = write(connection, $0.baseAddress, $0.count) }
  }

  func stop() {
    shutdown(listener, SHUT_RDWR)
    close(listener)
    unlink(path)
  }
}

let benchDisplay = """
  user: bench
  accessibility (post events): true
  screen recording: true
  active displays: 1
    9 main: 0,0 1920x1080 pt @2.0x
  """

func stripes(colors: [NSColor]) -> Data {
  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

  for (index, color) in colors.enumerated() {
    color.setFill()
    NSRect(x: 0, y: index * 64 / colors.count, width: 64, height: 64 / colors.count).fill()
  }

  NSGraphicsContext.restoreGraphicsState()
  return bitmap.representation(using: .png, properties: [:])!
}

@MainActor
struct PrivateDesktopTests {
  let working: [String: Response] = [
    "display": Response(ok: true, output: benchDisplay),
    "shot": Response(ok: true, output: "", image: stripes(colors: [.white, .black])),
    "pointer": Response(ok: true, output: "requested 960,540 read 960,540"),
    "click": Response(ok: true, output: "")
  ]

  let present = StageAccounts(users: ["bench"], loggedIn: ["bench"])

  @Test func parsesAccountsAndLogins() {
    let dscl = "_www 70\nbench 502\njohn 501\nnobody -2\nguest 503\n"
    let ps = "  501 /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock\n  502 /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock\n  503 /usr/bin/login\n"
    let accounts = StageAccounts(dscl: dscl, ps: ps, me: 501)
    #expect(accounts.users == ["bench", "guest"])
    #expect(accounts.loggedIn == ["bench"])
  }

  @Test func parsesTheDisplayReport() throws {
    let report = try #require(DisplayReport(benchDisplay))
    #expect(report.user == "bench")
    #expect(report.accessibility && report.screenRecording)
    #expect(report.screen == CGSize(width: 1920, height: 1080))
    #expect(DisplayReport("no agent here") == nil)
  }

  @Test func readsImagesAndPointers() {
    #expect(DesktopChecks.isUniform(stripes(colors: [.systemBlue])))
    #expect(!DesktopChecks.isUniform(stripes(colors: [.white, .black])))
    #expect(DesktopChecks.pointerReadsBack("requested 400,300 read 400,300"))
    #expect(!DesktopChecks.pointerReadsBack("requested 400,300 read -1,-1"))
  }

  @Test func framesBecomeSampleBuffersShownAtOnce() throws {
    let bitmap = NSBitmapImageRep(data: stripes(colors: [.white, .black]))!
    let jpeg = try #require(bitmap.representation(using: .jpeg, properties: [:]))
    let buffer = try #require(DesktopScreenView.sampleBuffer(jpeg))
    let dimensions = CMVideoFormatDescriptionGetDimensions(try #require(buffer.formatDescription))
    #expect(dimensions.width == 64 && dimensions.height == 64)

    let attachments = try #require(CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[CFString: Any]])
    #expect(attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] as? Bool == true)
    #expect(DesktopScreenView.sampleBuffer(Data("not a picture".utf8)) == nil)
  }

  @Test func turnsOnWhenEveryItemPasses() async {
    let agent = FakeAgent(working)
    defer { agent.stop() }
    let desktop = PrivateDesktop(socket: agent.path) { present }

    await desktop.check()
    #expect(desktop.isOn)
    #expect(desktop.failing == nil)
    #expect(desktop.user == "bench")
    #expect(agent.requests.map(\.command) == ["display", "shot", "pointer"])
  }

  @Test func stopsAtTheFirstFailingItem() async {
    let agent = FakeAgent(working)
    defer { agent.stop() }
    agent.answer("shot", Response(ok: true, output: "", image: stripes(colors: [.systemBlue])))
    let desktop = PrivateDesktop(socket: agent.path) { present }

    await desktop.check()
    #expect(!desktop.isOn)
    #expect(desktop.failing == .screenRecording)
    #expect(desktop.statuses[.accessibility] == .passed)
    #expect(desktop.statuses[.input] == .unchecked)
    #expect(!agent.requests.contains { $0.command == "pointer" })
  }

  @Test func failsWithoutAnAgent() async {
    let desktop = PrivateDesktop(socket: "/tmp/theseus-missing.sock") { present }

    await desktop.check()
    #expect(desktop.failing == .agent)
    #expect(desktop.statuses[.loggedIn] == .passed)
  }

  @Test func failsWhenTheAccountIsLoggedOut() async {
    let desktop = PrivateDesktop(socket: "/tmp/theseus-missing.sock") { StageAccounts(users: ["bench"], loggedIn: []) }

    await desktop.check()
    #expect(desktop.failing == .loggedIn)
    #expect(desktop.user == "bench")
  }

  @Test func leaseLastsOneTurn() async throws {
    let agent = FakeAgent(working)
    defer { agent.stop() }
    let desktop = PrivateDesktop(socket: agent.path) { present }
    await desktop.check()

    let first = Session(id: "first", workingDirectory: URL(filePath: "/tmp"), updatedAt: .now)
    first.appTitle = "Fix the toolbar"
    let second = Session(id: "second", workingDirectory: URL(filePath: "/tmp"), updatedAt: .now)

    _ = try await desktop.send("click", ["10,10"], for: first)
    #expect(desktop.holder === first)

    let refused = await #expect(throws: DesktopFailure.self) { _ = try await desktop.send("click", ["10,10"], for: second) }
    #expect(refused?.errorDescription == "Private Desktop is in use by Fix the toolbar.")

    first.turnEndedAt = .now
    #expect(desktop.holder == nil)
    _ = try await desktop.send("click", ["10,10"], for: second)
    #expect(desktop.holder === second)

    desktop.release(second)
    #expect(desktop.holder == nil)
  }

  @Test func refusesWhileTakenOrOff() async throws {
    let agent = FakeAgent(working)
    defer { agent.stop() }
    let desktop = PrivateDesktop(socket: agent.path) { present }
    let session = Session(id: "s", workingDirectory: URL(filePath: "/tmp"), updatedAt: .now)

    await #expect(throws: DesktopFailure.self) { _ = try await desktop.send("click", ["10,10"], for: session) }

    await desktop.check()
    desktop.isTakenByUser = true
    await #expect(throws: DesktopFailure.self) { _ = try await desktop.send("click", ["10,10"], for: session) }

    desktop.isTakenByUser = false
    agent.answer("click", Response(ok: false, output: "usage: click X,Y [COUNT 1-3]"))
    let failed = await #expect(throws: DesktopFailure.self) { _ = try await desktop.send("click", [], for: session) }
    #expect(failed?.errorDescription == "usage: click X,Y [COUNT 1-3]")
  }
}
