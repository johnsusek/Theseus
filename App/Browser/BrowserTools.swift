import AppKit
import ClaudeEngine
import ClaudeWorkspace

/// The browser's tools, served under the names the Claude desktop app gives its own browser's, which the model has used before and
/// `ToolPhrases` already words.
@MainActor
enum BrowserTools {
  static let serverName = "Claude_Browser"

  static let instructions = """
    Theseus has a browser of its own beside the conversation: a pane of the conversation window, or a window when the user detaches it. It is apart from the user's Safari and keeps its own logins. Use it to show the user a page, to preview this project's dev servers, and to check web work you did.
    - preview_start with a name runs that configuration from .claude/launch.json, waits for it to answer and opens it. The file reads {"version": "0.0.1", "configurations": [{"name": "dev", "runtimeExecutable": "npm", "runtimeArgs": ["run", "dev"], "port": 5173}]}; write it when the project has none. Start dev servers this way and not with Bash, so they show in the browser and stop with the app. preview_start with a url opens a page that needs no server.
    - read_page and find print a [ref=N] for each element; pass N as ref to computer and form_input. Refs last until the page loads another document.
    - Read with read_page, find and get_page_text before reaching for a screenshot. Coordinates are page px, which are a screenshot's pixels unless its reply says it was scaled.
    - Clicks and keys reach the page as real input. Every action replies with what it changed on the page, so read the page again only when that is not enough.
    - There is no hover. An alert, confirm or prompt the page raises during a tool call is dismissed and named in the reply.
    - Put steps you can predict into one browser_batch.
    """

  private struct Definition {
    var name: String
    var description: String
    var properties: [String: JSONValue] = [:]
    var optional: Set<String> = []
  }

  private static let tabId: JSONValue = ["type": "string", "description": "The tab to use, an id from tabs_context; the tab in front when left out."]
  private static let ref: JSONValue = ["type": "string", "description": "An element's ref from read_page or find, such as 12."]
  private static let coordinate: JSONValue = ["type": "array", "items": ["type": "number"], "description": "[x, y] in page px from the page's top left corner as shown."]

  private static let definitions = [
    Definition(name: "preview_start", description: "Starts a dev server by its name in .claude/launch.json and opens it in the browser, or opens `url` when no server is needed.", properties: [
      "name": ["type": "string", "description": "A configuration's name in .claude/launch.json."],
      "url": ["type": "string", "description": "An address or a file path to open instead, absolute or relative to the working directory."]
    ], optional: ["name", "url"]),
    Definition(name: "preview_stop", description: "Stops a dev server that preview_start started.", properties: ["serverId": ["type": "string"]]),
    Definition(name: "preview_list", description: "Lists the dev servers preview_start started for this project and the configurations launch.json offers."),
    Definition(name: "preview_logs", description: "Returns the end of a dev server's output.", properties: [
      "serverId": ["type": "string"],
      "lines": ["type": "integer", "description": "How many lines, 50 when left out."],
      "level": ["type": "string", "enum": ["all", "error"], "description": "error keeps only lines containing error, exception, failed or fatal."],
      "search": ["type": "string", "description": "Keeps only lines containing this text."]
    ], optional: ["lines", "level", "search"]),
    Definition(name: "navigate", description: "Loads an address or a file path in a tab, or goes `back` or `forward` in its history, and opens the browser when it has no tab.", properties: [
      "url": ["type": "string", "description": "An address, a file path absolute or relative to the working directory, or back or forward."], "tabId": tabId
    ], optional: ["tabId"]),
    Definition(name: "read_page", description: "Returns the page as an indented tree of its elements, each with a [ref=N] the other tools act on.", properties: [
      "filter": ["type": "string", "enum": ["all", "interactive"], "description": "interactive keeps only what can be clicked or typed into; all, the default, keeps the whole tree."],
      "depth": ["type": "integer", "description": "How many levels to descend."],
      "ref_id": ["type": "string", "description": "Reads only this element and what is inside it."],
      "max_chars": ["type": "integer", "description": "Where to cut the text, 50000 when left out."], "tabId": tabId
    ], optional: ["filter", "depth", "ref_id", "max_chars", "tabId"]),
    Definition(name: "find", description: "Lists up to 20 visible elements whose accessible name contains the query, with their refs.", properties: ["query": ["type": "string"], "tabId": tabId], optional: ["tabId"]),
    Definition(name: "get_page_text", description: "Returns the page's readable text, its main content first.", properties: [
      "max_chars": ["type": "integer", "description": "Where to cut the text, 50000 when left out."], "tabId": tabId
    ], optional: ["max_chars", "tabId"]),
    Definition(name: "computer", description: "Clicks, types, presses keys, scrolls, drags, waits or takes a screenshot in a tab's page.", properties: [
      "action": ["type": "string", "enum": ["left_click", "right_click", "double_click", "triple_click", "type", "key", "scroll", "scroll_to", "left_click_drag", "screenshot", "zoom", "wait"]],
      "ref": ref,
      "coordinate": coordinate,
      "text": ["type": "string", "description": "For type, the text. For key, presses separated by spaces, each a key name or character with modifiers in front, such as Enter, cmd+a or shift+ArrowLeft."],
      "modifiers": ["type": "string", "description": "Keys held during a click, joined with +, from cmd, ctrl, alt and shift."],
      "repeat": ["type": "integer", "description": "For key, how many times to press the sequence."],
      "scroll_direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
      "scroll_amount": ["type": "integer", "description": "Wheel ticks of 100 px, 3 when left out."],
      "start_coordinate": ["type": "array", "items": ["type": "number"], "description": "For left_click_drag, where the drag starts; coordinate is where it ends."],
      "region": ["type": "array", "items": ["type": "number"], "description": "For zoom, [x0, y0, x1, y1] in page px."],
      "duration": ["type": "number", "description": "For wait, seconds, at most 10."], "tabId": tabId
    ], optional: ["ref", "coordinate", "text", "modifiers", "repeat", "scroll_direction", "scroll_amount", "start_coordinate", "region", "duration", "tabId"]),
    Definition(name: "form_input", description: "Sets a form control named by ref: text for a field, true or false for a checkbox or radio, an option's label or value for a select.", properties: [
      "ref": ref, "value": ["description": "A string, a number or a boolean."], "tabId": tabId
    ], optional: ["tabId"]),
    Definition(name: "javascript_tool", description: "Runs JavaScript in the page and returns the value of its last expression, with await allowed at the top level.", properties: [
      "text": ["type": "string", "description": "The code."], "action": ["type": "string", "enum": ["javascript_exec"]], "tabId": tabId
    ], optional: ["action", "tabId"]),
    Definition(name: "read_console_messages", description: "Returns the page's console messages and uncaught errors, oldest first.", properties: [
      "limit": ["type": "integer", "description": "The newest this many, 50 when left out."],
      "onlyErrors": ["type": "boolean"],
      "pattern": ["type": "string", "description": "A regular expression the text must match, ignoring case."], "tabId": tabId
    ], optional: ["limit", "onlyErrors", "pattern", "tabId"]),
    Definition(name: "read_network_requests", description: "Lists the requests the page made, or returns one fetch or XMLHttpRequest call's bodies when given its requestId.", properties: [
      "limit": ["type": "integer", "description": "The newest this many, 50 when left out."],
      "urlPattern": ["type": "string", "description": "Text the URL must contain."],
      "requestId": ["type": "string", "description": "A requestId from the list."], "tabId": tabId
    ], optional: ["limit", "urlPattern", "requestId", "tabId"]),
    Definition(name: "tabs_context", description: "Lists the browser's tabs with their ids, titles and addresses, and says whether the browser is on screen."),
    Definition(name: "tabs_create", description: "Opens a new tab in front, shows the browser and returns the tab's id.", properties: ["url": ["type": "string", "description": "An address to load in it."]], optional: ["url"]),
    Definition(name: "tabs_select", description: "Brings a tab to the front and shows the browser.", properties: ["tabId": ["type": "string"]]),
    Definition(name: "tabs_close", description: "Closes a tab.", properties: ["tabId": ["type": "string"]]),
    Definition(name: "browser_batch", description: "Runs several browser tool calls in order in one round trip and stops at the first that fails.", properties: [
      "actions": ["type": "array", "items": ["type": "object", "properties": ["name": ["type": "string", "description": "A browser tool's name, such as navigate or computer."], "input": ["type": "object", "description": "That tool's input."]], "required": ["name", "input"]]]
    ])
  ]

  static func server(for session: Session, app: AppDelegate) -> HostServer {
    let toolbox = BrowserToolbox(session: session, app: app)

    return HostServer(name: serverName, instructions: instructions, tools: definitions.map { definition in
      hostTool(definition.name, definition.description, definition.properties, optional: definition.optional, for: session) { call, _ in try await toolbox.run(definition.name, call.arguments) }
    })
  }
}

/// Runs the browser tools for one session, against the browser of the conversation window that session is open in.
@MainActor
final class BrowserToolbox {
  private weak var session: Session?
  private weak var app: AppDelegate?

  init(session: Session, app: AppDelegate) {
    self.session = session
    self.app = app
  }

  func run(_ name: String, _ input: JSONValue) async throws -> HostToolResult {
    guard let session, let app, let conversation = app.conversation(for: session) else { throw ToolFailure("This conversation's window is closed, and its browser with it.") }

    let browser = conversation.browser
    let tabId = input["tabId"]?.string ?? input["tabId"]?.int.map(String.init)

    switch name {
    case "preview_start", "preview_stop", "preview_list", "preview_logs":
      return try await preview(name, input, browser: browser, servers: app.previewServers, project: conversation.browserFolder)
    case "browser_batch":
      return try await batch(input["actions"]?.array ?? [])
    case "tabs_context":
      let lines = browser.tabs.map { "\($0.id)\($0 === browser.active ? " (in front)" : "")  \($0.title)  \($0.url?.absoluteString ?? "")" }
      return HostToolResult("The browser is \(browser.isShown ? "on screen" : "hidden").\n" + (lines.isEmpty ? "No tabs." : "tabId  title  address\n" + lines.joined(separator: "\n")))
    case "tabs_create":
      let tab = browser.openTab()

      browser.show()
      guard let address = input["url"]?.string else { return "Opened tab \(tab.id)." }

      return HostToolResult("Opened tab \(tab.id). " + (try await load(address, in: tab, browser: browser)))
    case "tabs_select":
      browser.select(try browser.tab(tabId))
      browser.show()
      return "Tab \(tabId ?? "") is in front."
    case "tabs_close":
      browser.close(try browser.tab(tabId))
      return "Closed tab \(tabId ?? "")."
    case "navigate":
      // The browser comes on screen with its first tab; after that the user decides whether it shows.
      let isFirst = browser.tabs.isEmpty
      let tab = isFirst ? browser.openTab() : try browser.tab(tabId)

      if isFirst { browser.show() }

      return HostToolResult(try await load(try input.text("url"), in: tab, browser: browser))
    default:
      return try await page(name, input, in: try browser.tab(tabId))
    }
  }

  /// Loads an address, or moves through the tab's history, and waits for the page.
  private func load(_ address: String, in tab: BrowserTab, browser: Browser) async throws -> String {
    tab.driving += 1
    defer { tab.driving -= 1 }

    switch address {
    case "back":
      guard tab.webView.canGoBack else { throw ToolFailure("The tab has no page to go back to.") }
      tab.webView.goBack()
    case "forward":
      guard tab.webView.canGoForward else { throw ToolFailure("The tab has no page to go forward to.") }
      tab.webView.goForward()
    default:
      try browser.open(address, in: tab)
    }

    try await tab.loaded()
    return (["Loaded \(tab.url?.absoluteString ?? address) (\(tab.title))."] + tab.takeDialogNotes()).joined(separator: "\n")
  }

  private func page(_ name: String, _ input: JSONValue, in tab: BrowserTab) async throws -> HostToolResult {
    switch name {
    case "read_page":
      let limit = input["max_chars"]?.int ?? 50000
      let result = try await tab.ask(["op": "readPage", "filter": input["filter"]?.string ?? "all", "maxChars": limit, "ref": try input["ref_id"].map { try BrowserTab.ref($0) } ?? NSNull(), "depth": input["depth"]?.int ?? NSNull(), "prefix": "", "viewport": false, "clip": NSNull()])

      return HostToolResult("\(tab.title)  \(tab.url?.absoluteString ?? "")\n\(result["text"]?.string ?? "")\(result["truncated"]?.bool == true ? "\n(cut at \(limit) characters; read a part with ref_id or raise max_chars)" : "")")
    case "find":
      let query = try input.text("query")
      let matches = try await tab.ask(["op": "find", "name": query, "role": ""])["matches"]?.array ?? []
      guard !matches.isEmpty else { return "Nothing visible is named \"\(query)\"." }

      return HostToolResult(matches.map { match in
        "[ref=\(match["ref"]?.int ?? 0)] \(match["role"]?.string ?? "") \"\(match["name"]?.string ?? "")\" <\(match["tag"]?.string ?? "")>\(match["inViewport"]?.bool == false ? " (offscreen)" : "")\(match["disabled"]?.bool == true ? " (disabled)" : "")"
      }.joined(separator: "\n"))
    case "get_page_text":
      let limit = input["max_chars"]?.int ?? 50000
      let result = try await tab.ask(["op": "pageText", "maxChars": limit, "format": "text", "ref": NSNull()])

      return HostToolResult("\(tab.title)  \(tab.url?.absoluteString ?? "")\n\(result["text"]?.string ?? "")\(result["truncated"]?.bool == true ? "\n(cut at \(limit) characters)" : "")")
    case "form_input":
      let ref = try BrowserTab.ref(input["ref"])
      guard let value = input["value"] else { throw ToolFailure("form_input needs a value.") }

      return HostToolResult(try await tab.acting { try await tab.setControl(ref, to: value) })
    case "javascript_tool":
      tab.driving += 1
      defer { tab.driving -= 1 }

      return HostToolResult(([try await tab.run(try input.text("text"))] + tab.takeDialogNotes()).joined(separator: "\n"))
    case "read_console_messages":
      return HostToolResult(try await tab.consoleText(limit: input["limit"]?.int ?? 50, onlyErrors: input["onlyErrors"]?.bool ?? false, pattern: input["pattern"]?.string))
    case "read_network_requests":
      let requestId = input["requestId"].map { $0.int ?? Int($0.string ?? "") ?? -1 }

      return HostToolResult(try await tab.requestsText(limit: input["limit"]?.int ?? 50, pattern: input["urlPattern"]?.string, id: requestId))
    case "computer":
      return try await computer(input, in: tab)
    default:
      throw ToolFailure("The browser has no tool named \(name).")
    }
  }

  private func computer(_ input: JSONValue, in tab: BrowserTab) async throws -> HostToolResult {
    let action = try input.text("action")

    switch action {
    case "left_click", "double_click", "triple_click", "right_click":
      let clicks = ["double_click": 2, "triple_click": 3][action] ?? 1

      return HostToolResult(try await tab.acting { try await tab.click(input, clicks: clicks, isRight: action == "right_click") })
    case "type":
      let text = try input.text("text")

      return HostToolResult(try await tab.acting {
        try await tab.press(text.map(BrowserKeys.stroke(typing:)))
        return "Typed \(text.count) characters."
      })
    case "key":
      let strokes = try input.text("text").split(separator: " ").map { try BrowserKeys.stroke(named: String($0)) }
      let times = max(1, min(input["repeat"]?.int ?? 1, 100))

      return HostToolResult(try await tab.acting {
        try await tab.press(Array(repeating: strokes, count: times).flatMap(\.self))
        return "Pressed \(input["text"]?.string ?? "")\(times > 1 ? " \(times) times" : "")."
      })
    case "left_click_drag":
      let start = try BrowserTab.point(input["start_coordinate"], "start_coordinate")
      let end = try BrowserTab.point(input["coordinate"])

      return HostToolResult(try await tab.acting {
        try await tab.drag(from: start, to: end)
        return "Dragged from (\(Int(start.x)), \(Int(start.y))) to (\(Int(end.x)), \(Int(end.y)))."
      })
    case "scroll":
      return HostToolResult(try await tab.scroll(input))
    case "scroll_to":
      let ref = try BrowserTab.ref(input["ref"])

      try await tab.ask(["op": "scrollIntoView", "ref": ref])
      return "Scrolled ref \(ref) into view."
    case "wait":
      try await Task.sleep(for: .seconds(max(0, min(input["duration"]?.number ?? 1, 10))))
      return "Waited."
    case "screenshot":
      let shot = try await tab.picture()
      let scaled = shot.scale < 1 ? "; shown at \(Int(shot.scale * 100))%, so multiply its pixels by \(String(format: "%.2f", 1 / shot.scale)) for page px" : ""

      return HostToolResult("Tab \(tab.id) as shown, \(Int(shot.size.width)) x \(Int(shot.size.height)) page px\(scaled).", images: [shot.image])
    case "zoom":
      guard let region = input["region"]?.array?.compactMap(\.number), region.count == 4, region[2] > region[0], region[3] > region[1] else { throw ToolFailure("region must be [x0, y0, x1, y1] in page px.") }

      let shot = try await tab.picture(of: CGRect(x: region[0], y: region[1], width: region[2] - region[0], height: region[3] - region[1]), scale: 2)

      return HostToolResult("That region at \(Int(shot.scale * 100))%.", images: [shot.image])
    default:
      throw ToolFailure(action == "hover" ? "The browser cannot hover; click the element, or read what it would show with read_page." : "computer has no action named \(action).")
    }
  }

  private func preview(_ name: String, _ input: JSONValue, browser: Browser, servers: PreviewServers, project: URL) async throws -> HostToolResult {
    switch name {
    case "preview_start":
      var started = ""
      let address: String

      if let configuration = input["name"]?.string {
        let server = try await servers.start(configuration, in: project)

        started = "\(configuration) is running as \(server.id). "
        address = server.url.absoluteString
      } else {
        address = try input.text("url")
      }

      // A page of the same site is reloaded where it is; anything else gets a tab of its own unless the one in front is blank.
      let target = BrowserAddress.url(from: address, in: project)
      let blank = browser.active.flatMap { $0.url == nil || $0.url?.absoluteString == "about:blank" ? $0 : nil }
      let tab = browser.tabs.first { $0.url?.host() == target?.host() && $0.url?.port == target?.port && target?.isFileURL == false } ?? blank ?? browser.openTab()

      browser.select(tab)
      browser.show()

      let loaded = try await load(address, in: tab, browser: browser)
      // Sharp at the width the transcript's card draws it.
      let thumbnail = try await tab.picture(scale: min(2, 840 / max(tab.webView.bounds.width, 1)))

      return HostToolResult("\(started)\(loaded)\nThe user sees it in the browser.", images: [thumbnail.image])
    case "preview_stop":
      let server = try servers.server(try input.text("serverId"))

      servers.stop(server)
      return "Stopped \(server.name)."
    case "preview_list":
      let lines = servers.servers.filter { $0.project == project }.map { "\($0.id)  \($0.name)  \($0.url.absoluteString)  \($0.ending ?? "running")" }
      let offered = (try? PreviewServers.configurations(in: project).map(\.name)) ?? []

      return HostToolResult((lines.isEmpty ? ["No servers started."] : ["serverId  name  address  state"] + lines).joined(separator: "\n") + "\nlaunch.json offers: \(offered.isEmpty ? "nothing" : offered.joined(separator: ", "))")
    default:
      let server = try servers.server(try input.text("serverId"))

      return HostToolResult(servers.logText(server, lines: input["lines"]?.int ?? 50, onlyErrors: input["level"]?.string == "error", search: input["search"]?.string))
    }
  }

  /// Runs each action in turn. A failure ends the batch there, and what the earlier actions returned still reaches the model.
  private func batch(_ actions: [JSONValue]) async throws -> HostToolResult {
    guard !actions.isEmpty else { throw ToolFailure("browser_batch needs actions, each {name, input}.") }

    var result = HostToolResult("")
    var lines: [String] = []

    for (index, action) in actions.enumerated() {
      let name = action["name"]?.string ?? ""

      do {
        guard name != "browser_batch" else { throw ToolFailure("A batch cannot hold another batch.") }

        let step = try await run(name, action["input"] ?? [:])

        lines.append("\(index + 1). \(name): \(step.text)")
        result.images += step.images
      } catch {
        lines.append("\(index + 1). \(name) failed: \(error.localizedDescription)")
        if index + 1 < actions.count { lines.append("The actions after it did not run.") }
        break
      }
    }

    result.text = lines.joined(separator: "\n")
    return result
  }
}

private extension JSONValue {
  /// A required string argument.
  func text(_ key: String) throws -> String {
    guard let value = self[key]?.string else { throw ToolFailure("\(key) is required.") }

    return value
  }
}
