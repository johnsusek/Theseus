import ClaudeEngine
import Foundation
import Subprocess
import System

/// Dev servers started from a project's `.claude/launch.json`, the file the Claude desktop app reads too. They are children of Theseus,
/// each in a session of its own so the whole tree can be signaled, and they stop when Theseus quits.
@MainActor
final class PreviewServers {
  struct Configuration: Decodable {
    var name: String
    var runtimeExecutable: String?
    var runtimeArgs: [String]?
    var port: Int?
    /// Where the server answers, when that is not `http://localhost:<port>`. A configuration with only this attaches to a server someone else runs.
    var url: String?
    /// Takes a free port when `port` is taken, and tells the server through `PORT`.
    var autoPort: Bool?
  }

  private struct LaunchFile: Decodable {
    var configurations: [Configuration]
  }

  final class Server {
    let id: String
    let name: String
    let project: URL
    let url: URL
    let log: URL
    fileprivate(set) var processId: pid_t?
    /// How the process ended; nil while it runs, and for a server Theseus only attached to.
    fileprivate(set) var ending: String?
    fileprivate var isStopping = false

    fileprivate init(id: String, name: String, project: URL, url: URL, log: URL) {
      self.id = id
      self.name = name
      self.project = project
      self.url = url
      self.log = log
    }
  }

  private(set) var servers: [Server] = []
  /// The login shell's PATH, read once: a GUI app's own has no node or python.
  private var searchPath: String?
  private var started = 0
  private let logs = FileManager.default.temporaryDirectory.appending(path: "Theseus-previews")

  static func configurations(in project: URL) throws -> [Configuration] {
    let file = project.appending(path: ".claude/launch.json")
    guard let data = try? Data(contentsOf: file) else {
      throw ToolFailure("\(file.path) does not exist. Write it as {\"version\": \"0.0.1\", \"configurations\": [{\"name\": \"dev\", \"runtimeExecutable\": \"npm\", \"runtimeArgs\": [\"run\", \"dev\"], \"port\": 5173}]}, then call preview_start with the name.")
    }

    do {
      return try JSONDecoder().decode(LaunchFile.self, from: data).configurations
    } catch {
      throw ToolFailure("\(file.path) could not be read: \(error.localizedDescription)")
    }
  }

  /// Starts the named configuration and returns once its URL answers. A server of that name already running for the project is returned as it is.
  func start(_ name: String, in project: URL) async throws -> Server {
    let configurations = try Self.configurations(in: project)
    guard let configuration = configurations.first(where: { $0.name == name }) else {
      throw ToolFailure("launch.json has no configuration named \(name). It has: \(configurations.map(\.name).joined(separator: ", ")).")
    }

    if let running = servers.first(where: { $0.project == project && $0.name == name && $0.ending == nil }) { return running }

    var port = configuration.port
    var address = configuration.url ?? port.map { "http://localhost:\($0)" }

    if configuration.runtimeExecutable != nil, let taken = address.flatMap(URL.init(string:)), await Self.answers(taken) {
      guard configuration.autoPort == true, let free = Self.freePort() else {
        throw ToolFailure("\(taken.absoluteString) already answers, so another process holds the port. Stop it, or open that address with navigate.")
      }

      port = free
      address = "http://localhost:\(free)"
    }

    guard let address, let url = URL(string: address) else { throw ToolFailure("Configuration \(name) needs a port or a url.") }

    started += 1
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

    let server = Server(id: "server-\(started)", name: name, project: project, url: url, log: logs.appending(path: "\(ProcessInfo.processInfo.processIdentifier)-\(started).log"))

    servers.append(server)

    if let executable = configuration.runtimeExecutable { try await launch(executable, configuration.runtimeArgs ?? [], port: configuration.autoPort == true ? port : nil, for: server) }

    let deadline = ContinuousClock.now + .seconds(60)

    while !(await Self.answers(url)) {
      if let ending = server.ending { throw ToolFailure("\(name) \(ending) before \(address) answered.\n\(logText(server, lines: 30, onlyErrors: false, search: nil))") }

      guard ContinuousClock.now < deadline else {
        stop(server)
        throw ToolFailure("\(name) did not answer at \(address) within 60 s, so it was stopped.\n\(logText(server, lines: 30, onlyErrors: false, search: nil))")
      }

      try await Task.sleep(for: .milliseconds(250))
    }

    return server
  }

  /// Runs the command through a shell that sends both of its outputs to the server's log file.
  private func launch(_ executable: String, _ arguments: [String], port: Int?, for server: Server) async throws {
    if searchPath == nil { searchPath = try await ClaudeInstallation.locate().searchPath }

    var environment: [Environment.Key: String?] = ["PATH": searchPath, "THESEUS_PREVIEW_LOG": server.log.path]
    var options = PlatformOptions()

    if let port { environment["PORT"] = String(port) }

    // A session of its own makes the server the leader of a process group, so stopping it reaches what it spawned.
    options.createSession = true

    let (launchStream, launched) = AsyncThrowingStream.makeStream(of: pid_t.self)

    Task {
      do {
        let outcome = try await run(.path("/bin/zsh"), arguments: Arguments(["-c", "exec \"$0\" \"$@\" >\"$THESEUS_PREVIEW_LOG\" 2>&1", executable] + arguments), environment: .inherit.updating(environment), workingDirectory: FilePath(server.project.path), platformOptions: options, input: .none, output: .discarded, error: .discarded) { execution in
          launched.yield(execution.processIdentifier.value)
          launched.finish()
        }

        server.ending = server.isStopping ? "stopped" : "exited (\(outcome.terminationStatus))"
      } catch {
        launched.finish(throwing: error)
        server.ending = "could not start: \(error.localizedDescription)"
      }
    }

    for try await processId in launchStream { server.processId = processId }
  }

  /// Signals the server's whole process group.
  func stop(_ server: Server) {
    guard server.ending == nil else { return }
    guard let processId = server.processId else { return server.ending = "detached" }

    server.isStopping = true
    kill(-processId, SIGTERM)
  }

  func stopAll() {
    for server in servers { stop(server) }
  }

  func server(_ id: String) throws -> Server {
    guard let server = servers.first(where: { $0.id == id }) else { throw ToolFailure("No server has id \(id); preview_list shows them.") }

    return server
  }

  /// The end of the server's output, optionally only the lines that look like errors or that contain `search`.
  func logText(_ server: Server, lines: Int, onlyErrors: Bool, search: String?) -> String {
    guard let data = try? Data(contentsOf: server.log) else { return "(no output yet)" }

    let errorWords = ["error", "exception", "failed", "fatal"]
    let kept = String(decoding: data.suffix(512 * 1024), as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { line in
      (!onlyErrors || errorWords.contains { line.localizedCaseInsensitiveContains($0) }) && (search.map { line.localizedCaseInsensitiveContains($0) } ?? true)
    }

    return kept.isEmpty ? "(no matching output)" : kept.suffix(lines).joined(separator: "\n").trimmingCharacters(in: .newlines)
  }

  /// Whether something answers HTTP there. A refused connection is the one sure no; a slow first build times out and is asked again.
  private static func answers(_ url: URL) async -> Bool {
    do {
      _ = try await URLSession.shared.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2))
      return true
    } catch {
      return ![NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost].contains((error as NSError).code)
    }
  }

  /// A port nothing listens on, found by letting the system pick one.
  private static func freePort() -> Int? {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }

    var address = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)

    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

    let isBound = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) == 0 && getsockname(descriptor, $0, &length) == 0 }
    }

    return isBound ? Int(UInt16(bigEndian: address.sin_port)) : nil
  }
}
