import AppKit
import ClaudeEngine
import ClaudeWorkspace

/// Temporary: asks about each pending permission request in an alert sheet, one at a time.
/// The transcript's permission card replaces this file.
@MainActor
final class PermissionSheet {
  private var shown: (requestId: String, alert: NSAlert)?

  /// Shows the oldest pending request on `window`, and takes down a sheet whose request the CLI withdrew.
  func update(_ live: LiveSession, on window: NSWindow) {
    // Cleared first: ending the sheet may run its handler, which calls back in here, before it returns.
    if let withdrawn = shown, !live.pendingPermissions.contains(where: { $0.requestId == withdrawn.requestId }) {
      shown = nil
      window.endSheet(withdrawn.alert.window)
    }

    // A sheet on a background tab would have nowhere to appear; the tab's dot says it is waiting.
    guard shown == nil, window.isVisible, let request = live.pendingPermissions.first else { return }

    let alert = NSAlert()
    let allow = alert.addButton(withTitle: "Allow")
    let detail = [request.description, request.input["command"]?.string ?? request.input["file_path"]?.string].compactMap { $0 }

    alert.messageText = "Allow \(request.displayName ?? request.toolName)?"
    alert.informativeText = detail.joined(separator: "\n\n")
    alert.addButton(withTitle: "Deny").keyEquivalent = "\u{1b}"
    shown = (request.requestId, alert)

    // Return also sends a prompt, so one typed as the sheet appears must not allow the tool call.
    allow.isEnabled = false

    Task {
      try? await Task.sleep(for: .seconds(1))
      allow.isEnabled = true
    }

    alert.beginSheetModal(for: window) { [weak self, weak live, weak window] response in
      if response == .alertFirstButtonReturn { live?.respond(to: request, with: .allow()) }

      if response == .alertSecondButtonReturn { live?.respond(to: request, with: .deny(message: "The user denied this request.")) }

      guard let self, let live, let window else { return }

      if shown?.requestId == request.requestId { shown = nil }

      update(live, on: window)
    }
  }
}
