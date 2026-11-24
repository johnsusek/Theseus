import AppKit
import ClaudeWorkspace

/// Puts up an error as a sheet on `window`, bringing the window forward, or logs it when there is no window to show it on.
@MainActor
func showError(_ error: any Error, as title: String, on window: NSWindow?) {
  guard let window else { return log.error("\(title): \(error.localizedDescription)") }

  let alert = NSAlert()
  alert.alertStyle = .warning
  alert.messageText = title
  alert.informativeText = error.localizedDescription
  // A sheet needs its window on screen, so a background tab comes forward.
  window.makeKeyAndOrderFront(nil)
  alert.beginSheetModal(for: window)
}

/// Stops the session's turn and hands a failure to `failed`.
@MainActor
func interrupt(_ live: LiveSession, failed: @escaping @MainActor (any Error) -> Void) {
  Task {
    do {
      try await live.interrupt()
    } catch {
      failed(error)
    }
  }
}
