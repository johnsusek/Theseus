import AppKit
import ClaudeEngine
import ClaudeWorkspace
import UniformTypeIdentifiers
import UserNotifications

/// The tools Theseus serves to each session's CLI, and the system prompt that tells the model about them and the app.
@MainActor
enum HostTools {
  static let prompt = """
    You are running inside Theseus, a native macOS app that shows this conversation as a styled transcript.
    - When you mention a file, write it as a markdown link whose target is the path relative to the working directory, with an optional :line suffix, for example [Markdown.swift](App/Markdown.swift:42). The user can click it to open the file.
    - Theseus has a preview window that renders files. When the user asks to see, show, open, view or read a file, call show_file with its path and do not paste the file's contents into your reply; a one-line pointer to the file is enough. Do the same for a file you wrote for the user to read, such as a report or a plan.
    - Call notify only when a task that ran for several minutes finishes or when you are blocked on the user's answer, since they may have switched to another app.
    """

  static let serverName = "theseus"

  static func servers(for session: Session, app: AppDelegate) -> [HostServer] {
    /// A tool whose body runs on the main actor with the session. The session can close while the CLI still holds the tool.
    func tool(_ name: String, _ description: String, _ properties: [String: JSONValue] = [:], asksPermission: Bool = false, _ body: @escaping @MainActor @Sendable (HostToolCall, Session) async throws -> String) -> HostTool {
      let schema: JSONValue = ["type": "object", "properties": .object(properties), "required": .array(properties.keys.filter { $0 != "reason" }.sorted().map(JSONValue.string))]

      return HostTool(name: name, description: description, inputSchema: schema, asksPermission: asksPermission) { [weak session] call in
        guard let session else { throw ToolFailure("The session has closed.") }
        return try await body(call, session)
      }
    }

    func existingFile(_ call: HostToolCall, _ session: Session) throws -> URL {
      let url = FilePaths.resolve(try call.string("path"), in: session.workingDirectory)
      guard FileManager.default.fileExists(atPath: url.path) else { throw ToolFailure("No file at \(url.path).") }
      return url
    }

    func live(_ session: Session) throws -> LiveSession {
      guard let live = session.live, live.isRunning else { throw ToolFailure("The session is not running.") }
      return live
    }

    let path: [String: JSONValue] = ["path": ["type": "string", "description": "Absolute, or relative to the working directory."]]

    let tools = [
      tool("show_file", "Shows a file to the user in Theseus's preview window; call it whenever the user wants to see a file, instead of quoting the file in your reply.", path) { [weak app] call, session in
        let url = try existingFile(call, session)
        guard let conversation = app?.conversation(for: session) else { throw ToolFailure("This conversation's window is closed.") }

        conversation.showPreview(of: url)
        return "Shown \(url.path) in the preview window."
      },
      tool("reveal_in_finder", "Selects a file or folder in a Finder window.", path) { call, session in
        let url = try existingFile(call, session)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return "Revealed \(url.path) in Finder."
      },
      tool("open_file", "Opens a document or folder in its default app; it refuses apps and scripts, which you run with Bash instead.", path) { call, session in
        let url = try existingFile(call, session)
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        let isProgram = [UTType.application, .executable, .script].contains { type?.conforms(to: $0) == true }

        if isProgram || (!url.hasDirectoryPath && FileManager.default.isExecutableFile(atPath: url.path)) {
          throw ToolFailure("open_file does not open apps or scripts. Run them with Bash so the user can approve the command.")
        }

        guard NSWorkspace.shared.open(url) else { throw ToolFailure("No app opened \(url.path).") }
        return "Opened \(url.path)."
      },
      tool("notify", "Posts a macOS notification that brings the user back to this conversation when clicked.", ["title": ["type": "string"], "body": ["type": "string"]]) { call, session in
        let center = UNUserNotificationCenter.current()
        guard try await center.requestAuthorization(options: [.alert, .sound]) else { throw ToolFailure("Notifications are turned off for Theseus in System Settings.") }

        let content = UNMutableNotificationContent()
        content.title = try call.string("title")
        content.body = try call.string("body")
        content.sound = .default
        content.userInfo = ["session": session.id]
        try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        return "Notification posted."
      },
      tool("set_model", "Switches this session's model from the next request on.", ["model": ["type": "string", "description": "A model id or alias, such as opus or sonnet."]]) { call, session in
        let live = try live(session)
        let name = try call.string("model")
        let models = live.initializeInfo?.models ?? []
        guard let model = models.first(where: { [$0.value, $0.displayName].contains { $0.caseInsensitiveCompare(name) == .orderedSame } }) else {
          throw ToolFailure("Unknown model \(name). Choose one of: \(models.map(\.value).joined(separator: ", ")).")
        }

        try await live.setModel(model.value)
        return "Model set to \(model.displayName)."
      },
      tool("set_effort", "Changes this session's reasoning effort.", ["level": ["type": "string", "description": "low, medium, high, xhigh or max, as the model supports."]]) { call, session in
        let live = try live(session)
        let level = try call.string("level")
        let levels = live.modelInfo?.supportedEffortLevels ?? []
        guard levels.contains(level) else { throw ToolFailure("This model does not take effort \(level). Choose one of: \(levels.joined(separator: ", ")).") }

        try await live.setEffort(level)
        return "Effort set to \(effortName(level))."
      },
      tool("set_permission_mode", "Asks the user to switch this session's permission mode.", ["mode": ["type": "string", "enum": ["default", "acceptEdits", "plan", "auto"]], "reason": ["type": "string", "description": "One sentence the user reads before approving."]], asksPermission: true) { call, session in
        let live = try live(session)
        let mode = PermissionMode(rawValue: try call.string("mode"))
        guard [.default, .acceptEdits, .plan, .auto].contains(mode) else { throw ToolFailure("Choose default, acceptEdits, plan or auto.") }
        guard mode != .auto || live.modelInfo?.supportsAutoMode == true else { throw ToolFailure("This model does not support auto mode.") }

        try await live.setPermissionMode(mode)
        return "Permission mode set to \(modeName(mode))."
      },
      tool("set_title", "Renames this conversation in Theseus's tabs and session lists.", ["title": ["type": "string"]]) { [weak app] call, session in
        let title = try call.string("title").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let app else { throw ToolFailure("Theseus is quitting.") }

        try app.workspace.rename(session, to: title.isEmpty ? nil : title)
        return title.isEmpty ? "Title cleared." : "Title set to \(title)."
      }
    ]

    return [HostServer(name: serverName, tools: tools)]
  }
}

struct ToolFailure: LocalizedError {
  let errorDescription: String?

  init(_ message: String) { errorDescription = message }
}
