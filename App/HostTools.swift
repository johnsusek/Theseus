import AppKit
import ClaudeEngine
import ClaudeWorkspace

/// The tools Theseus serves to each session's CLI, and the system prompt that tells the model about them and the app.
@MainActor
enum HostTools {
  static let prompt = """
    You are running inside Theseus, a native macOS app that shows this conversation as a styled transcript.
    - When you mention a file, write it as a markdown link whose target is the path relative to the working directory, with an optional :line suffix, for example [Markdown.swift](App/Markdown.swift:42). The user can click it to open the file.
    - Theseus has a preview window that renders files. When the user asks to see, show, open, view or read a file, call show_file with its path and do not paste the file's contents into your reply; a one-line pointer to the file is enough. Do the same for a file you wrote for the user to read, such as a report or a plan.
    """

  static func servers(for session: Session, app: AppDelegate) -> [HostServer] {
    let showFile = HostTool(name: "show_file", description: "Shows a file to the user in Theseus's preview window; call it whenever the user wants to see a file, instead of quoting the file in your reply.", inputSchema: ["type": "object", "properties": ["path": ["type": "string", "description": "Absolute, or relative to the working directory."]], "required": ["path"]]) { [weak session, weak app] call in
      let path = try call.string("path")

      return try await MainActor.run {
        guard let session, let conversation = app?.conversation(for: session) else { throw ToolFailure("This conversation's window is closed.") }

        let url = FilePaths.resolve(path, in: session.workingDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolFailure("No file at \(url.path).") }

        conversation.showPreview(of: url)
        return "Shown \(url.path) in the preview window."
      }
    }

    return [HostServer(name: "theseus_view", tools: [showFile])]
  }
}

struct ToolFailure: LocalizedError {
  let errorDescription: String?

  init(_ message: String) { errorDescription = message }
}
