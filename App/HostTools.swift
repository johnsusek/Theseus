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
    - Theseus has a preview that renders files, a pane of the conversation window or a window of its own. When the user asks to see, show, open, view or read a file, call show_file with its path and do not paste the file's contents into your reply; a one-line pointer to the file is enough. Do the same for a file you wrote for the user to read, such as a report or a plan.
    - End every turn in which you changed files, ran commands or did multi-step work with a call to wrap_up, made as soon as the work is done and before you write any summary. Theseus draws its recap as a card under the turn, with the question and reply buttons when the user has a decision to make, so the recap is the turn's summary. Text written just before the call shows right above the card and repeats it, so write none. After the call, write a closing message only for what the recap leaves out, such as details or findings the user needs; if the recap says it all, end the turn without one. Skip wrap_up for short answers and conversation.
    - Theseus has a browser of its own, which the Claude_Browser tools drive. When the user asks to see, open or preview a web page, a local HTML file or the project's dev server, open it there with preview_start, not in their own browser and not with show_file.
    - Call notify only when a task that ran for several minutes finishes or when you are blocked on the user's answer, since they may have switched to another app.
    """

  static let serverName = "theseus"

  static func servers(for session: Session, app: AppDelegate) -> [HostServer] {
    func tool(_ name: String, _ description: String, _ properties: [String: JSONValue] = [:], optional: Set<String> = [], asksPermission: Bool = false, _ body: @escaping @MainActor @Sendable (HostToolCall, Session) async throws -> HostToolResult) -> HostTool {
      hostTool(name, description, properties, optional: optional, asksPermission: asksPermission, for: session, body)
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
      tool("show_file", "Shows a file to the user in Theseus's preview; call it whenever the user wants to see a file, instead of quoting the file in your reply.", path) { [weak app] call, session in
        let url = try existingFile(call, session)
        guard let conversation = app?.conversation(for: session) else { throw ToolFailure("This conversation's window is closed.") }

        conversation.preview.show(url)
        return "Shown \(url.path) in the preview."
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
      tool("set_permission_mode", "Asks the user to switch this session's permission mode.", ["mode": ["type": "string", "enum": ["default", "acceptEdits", "plan", "auto"]], "reason": ["type": "string", "description": "One sentence the user reads before approving."]], optional: ["reason"], asksPermission: true) { call, session in
        let live = try live(session)
        let mode = PermissionMode(rawValue: try call.string("mode"))
        guard [.default, .acceptEdits, .plan, .auto].contains(mode) else { throw ToolFailure("Choose default, acceptEdits, plan or auto.") }
        guard mode != .auto || live.modelInfo?.supportsAutoMode == true else { throw ToolFailure("This model does not support auto mode.") }

        try await live.setPermissionMode(mode)
        return "Permission mode set to \(modeName(mode))."
      },
      tool("wrap_up", "Puts a recap of this turn's work under the turn, with one question and reply buttons when the user has a decision to make.", ["recap": ["type": "string", "description": "Two or three sentences to the user: what is now true or changed, and what is not done or not verified."], "ask": ["type": "string", "description": "One short question the user must answer, if any."], "actions": ["type": "array", "items": ["type": "string"], "maxItems": 2, "description": "With ask: one to three word answers the user can click, your recommendation first."]], optional: ["ask", "actions"]) { _, _ in
        "Shown. Add a closing message only for what the recap leaves out; otherwise end the turn."
      },
      tool("set_title", "Renames this conversation in Theseus's tabs and session lists.", ["title": ["type": "string"]]) { [weak app] call, session in
        let title = try call.string("title").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let app else { throw ToolFailure("Theseus is quitting.") }

        try app.workspace.rename(session, to: title.isEmpty ? nil : title)
        return title.isEmpty ? "Title cleared." : "Title set to \(title)."
      }
    ]

    return [HostServer(name: serverName, tools: tools + DesktopTools.tools(for: session, app: app)), BrowserTools.server(for: session, app: app)]
  }
}

/// A tool whose body runs on the main actor with its session. The session can close while the CLI still holds the tool.
@MainActor
func hostTool(_ name: String, _ description: String, _ properties: [String: JSONValue] = [:], optional: Set<String> = [], asksPermission: Bool = false, for session: Session, _ body: @escaping @MainActor @Sendable (HostToolCall, Session) async throws -> HostToolResult) -> HostTool {
  let schema: JSONValue = ["type": "object", "properties": .object(properties), "required": .array(properties.keys.filter { !optional.contains($0) }.sorted().map(JSONValue.string))]

  return HostTool(name: name, description: description, inputSchema: schema, asksPermission: asksPermission) { [weak session] call in
    guard let session else { throw ToolFailure("The session has closed.") }
    return try await body(call, session)
  }
}

struct ToolFailure: LocalizedError {
  let errorDescription: String?

  init(_ message: String) { errorDescription = message }
}
