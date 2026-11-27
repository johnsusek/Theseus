import AppKit
import ClaudeEngine
import ClaudeWorkspace
import StagehandShared
import Subprocess

/// The desktop_* tools on the theseus server, given to sessions launched while the Private Desktop is on.
@MainActor
enum DesktopTools {
  static func prompt(user: String?) -> String {
    """
    - Theseus has a Private Desktop: a second macOS account\(user.map { " (\($0))" } ?? "") logged in on this Mac, with a screen of its own that the desktop_* tools drive while the user keeps working on theirs. For GUI checks, screenshots and tasks in native apps, use the desktop_* tools, not computer use and not events or screen captures on the user's own screen. Take a desktop_screenshot before you click, and another to check what changed. Its files are separate from the user's: hand files across through /Users/Shared/stagehand/.
    """
  }

  private static let point: JSONValue = ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2, "description": "[x, y] in points from the screen's top left."]
  private static let left: JSONValue = ["type": "number", "description": "Points from the screen's left edge."]
  private static let top: JSONValue = ["type": "number", "description": "Points from the screen's top edge."]
  private static let app: JSONValue = ["type": "string", "description": "An app's name as it shows in the menu bar, or its bundle id."]

  static func tools(for session: Session, app delegate: AppDelegate) -> [HostTool] {
    let desktop = delegate.privateDesktop
    guard desktop.isOn else { return [] }

    func tool(_ name: String, _ description: String, _ properties: [String: JSONValue] = [:], optional: Set<String> = [], asksPermission: Bool = false, _ body: @escaping @MainActor @Sendable (HostToolCall, Session) async throws -> HostToolResult) -> HostTool {
      hostTool(name, description, properties, optional: optional, asksPermission: asksPermission, for: session, body)
    }

    func send(_ command: String, _ args: [String] = [], _ session: Session) async throws -> String {
      try await desktop.send(command, args, for: session).output
    }

    func coordinates(_ call: HostToolCall, _ key: String) throws -> String {
      let values = call.arguments[key]?.array?.compactMap(\.number) ?? []
      guard values.count == 2 else { throw DesktopFailure("\(key) must be [x, y].") }

      return "\(Int(values[0])),\(Int(values[1]))"
    }

    func number(_ call: HostToolCall, _ key: String) throws -> Int {
      guard let value = call.arguments[key]?.number else { throw DesktopFailure("\(key) must be a number.") }

      return Int(value)
    }

    return [
      tool("desktop_screenshot", "Captures the Private Desktop's screen, or a region of it, at one pixel per point.", ["region": ["type": "array", "items": ["type": "number"], "minItems": 4, "maxItems": 4, "description": "[x, y, width, height] in points."]], optional: ["region"]) { call, session in
        let region = call.arguments["region"]?.array?.compactMap(\.number).map { String(Int($0)) } ?? []
        guard region.isEmpty || region.count == 4 else { throw DesktopFailure("region must be [x, y, width, height].") }

        let args = region.isEmpty ? ["--1x"] : [region.joined(separator: ","), "--1x"]
        let response = try await desktop.send("shot", args, for: session)
        guard let image = response.image else { throw DesktopFailure("The agent sent no image.") }

        if region.isEmpty {
          let size = desktop.screen.map { "\(Int($0.width)) x \(Int($0.height)) points" } ?? "the whole screen"
          return HostToolResult("The Private Desktop's screen, \(size); a pixel is a point.", images: [HostToolImage(data: image, mimeType: "image/png")])
        }

        return HostToolResult("The region at \(region[0]),\(region[1]), \(region[2]) x \(region[3]) points; add \(region[0]),\(region[1]) to a pixel's position for screen points.", images: [HostToolImage(data: image, mimeType: "image/png")])
      },
      tool("desktop_click", "Clicks at a point on the Private Desktop's screen.", ["x": left, "y": top, "button": ["type": "string", "enum": ["left", "right"]], "count": ["type": "integer", "enum": [1, 2, 3], "description": "2 double-clicks, 3 triple-clicks."]], optional: ["button", "count"]) { call, session in
        let command = call.arguments["button"]?.string == "right" ? "rightclick" : "click"
        let count = call.arguments["count"]?.number.map { Int($0) } ?? 1
        let at = "\(try number(call, "x")),\(try number(call, "y"))"
        _ = try await send(command, [at, String(count)], session)
        return "Clicked at \(at)."
      },
      tool("desktop_move", "Moves the Private Desktop's pointer to a point.", ["x": left, "y": top]) { call, session in
        let at = "\(try number(call, "x")),\(try number(call, "y"))"
        _ = try await send("move", [at], session)
        return "Moved to \(at)."
      },
      tool("desktop_glide", "Moves the pointer along an eased path, so hover menus and submenus open on the way.", ["from": point, "to": point]) { call, session in
        _ = try await send("glide", [try coordinates(call, "from"), try coordinates(call, "to")], session)
        return "Glided to \(try coordinates(call, "to"))."
      },
      tool("desktop_drag", "Drags with the left button held from one point to another, to move windows or items.", ["from": point, "to": point]) { call, session in
        _ = try await send("drag", [try coordinates(call, "from"), try coordinates(call, "to")], session)
        return "Dragged to \(try coordinates(call, "to"))."
      },
      tool("desktop_scroll", "Scrolls the view under a point by lines; negative lines scroll the content down.", ["x": left, "y": top, "lines": ["type": "integer"]]) { call, session in
        _ = try await send("scroll", ["\(try number(call, "x")),\(try number(call, "y"))", String(try number(call, "lines"))], session)
        return "Scrolled."
      },
      tool("desktop_key", "Presses a key with modifiers, written like return, escape, tab, f5, cmd+w or cmd+shift+z.", ["key": ["type": "string"]]) { call, session in
        let stroke = try BrowserKeys.stroke(named: try call.string("key"))
        let names: [(NSEvent.ModifierFlags, String)] = [(.command, "cmd"), (.shift, "shift"), (.option, "option"), (.control, "ctrl")]
        _ = try await send("key", [String(stroke.code)] + names.filter { stroke.modifiers.contains($0.0) }.map(\.1), session)
        return "Pressed \(try call.string("key"))."
      },
      tool("desktop_type", "Types text into whatever has focus on the Private Desktop.", ["text": ["type": "string"]]) { call, session in
        _ = try await send("type", [try call.string("text")], session)
        return "Typed."
      },
      tool("desktop_windows", "Lists the Private Desktop's windows with their frames in points, for all regular apps or one.", ["app": app], optional: ["app"]) { call, session in
        let output = try await send("windows", call.arguments["app"]?.string.map { [$0] } ?? [], session)
        return HostToolResult(output.isEmpty ? "No windows." : output)
      },
      tool("desktop_place", "Moves and resizes one of an app's windows on the Private Desktop.", ["app": app, "frame": ["type": "array", "items": ["type": "number"], "minItems": 4, "maxItems": 4, "description": "[x, y, width, height] in points."], "index": ["type": "integer", "description": "Which window, as desktop_windows numbers them; 0 when left out."]], optional: ["index"]) { call, session in
        let frame = call.arguments["frame"]?.array?.compactMap(\.number).map { String(Int($0)) } ?? []
        guard frame.count == 4 else { throw DesktopFailure("frame must be [x, y, width, height].") }

        let index = call.arguments["index"]?.number.map { [String(Int($0))] } ?? []
        _ = try await send("place", [try call.string("app"), frame.joined(separator: ",")] + index, session)
        return "Placed."
      },
      tool("desktop_activate", "Brings an app on the Private Desktop to the front.", ["app": app]) { call, session in
        _ = try await send("activate", [try call.string("app")], session)
        return "Activated."
      },
      tool("desktop_open", "Opens an app, a document or a URL on the Private Desktop; give an app's name or bundle id, a path the second account can read, or a URL.", ["target": ["type": "string"]]) { call, session in
        "Opened \(try await send("open", [try call.string("target")], session))."
      },
      tool("desktop_install", "Copies an .app from the user's account into the Private Desktop's ~/Applications and launches it there, replacing an older copy.", ["path": ["type": "string", "description": "The .app bundle, absolute or relative to the working directory."]]) { call, session in
        let source = FilePaths.resolve(try call.string("path"), in: session.workingDirectory)
        guard source.pathExtension == "app", FileManager.default.fileExists(atPath: source.path) else { throw DesktopFailure("No app at \(source.path).") }

        // The second account can read the shared folder but not this account's home.
        let drop = URL(filePath: sharedRoot).appending(path: "drop")
        let copy = drop.appending(path: source.lastPathComponent)
        try FileManager.default.createDirectory(at: drop, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: source, to: copy)
        return "Installed and launched \(try await send("install", [copy.path], session))."
      },
      tool("desktop_run", "Runs a zsh command as the Private Desktop's account and returns its output; never send Apple events (osascript, tell application) to other apps, since nobody there can answer the Automation prompt and each one is saved as a denial.", ["command": ["type": "string"]], asksPermission: true) { call, session in
        let output = try await send("run", [try call.string("command")], session)
        return HostToolResult(output.isEmpty ? "Done, no output." : output)
      }
    ]
  }

  /// Local accounts besides this one, and which of them run a Dock.
  static func readAccounts() async -> StageAccounts {
    let dscl = try? await run(.path("/usr/bin/dscl"), arguments: [".", "-list", "/Users", "UniqueID"], output: .string(limit: 1 << 20))
    let processes = try? await run(.path("/bin/ps"), arguments: ["-axo", "uid=,comm="], output: .string(limit: 1 << 24))
    return StageAccounts(dscl: dscl?.standardOutput ?? "", ps: processes?.standardOutput ?? "", me: getuid())
  }
}
