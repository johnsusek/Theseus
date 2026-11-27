import AppKit
import ClaudeEngine

/// What the browser tools do to a tab's page, each answering in text the model reads.
extension BrowserTab {
  /// Runs an input and says what it did to the page: the page it loaded, or the lines of the page that differ once it is still.
  func acting(_ input: () async throws -> String) async throws -> String {
    driving += 1
    defer { driving -= 1 }

    let address = url
    let isWatching = (try? await ask(["op": "diffStart"])) != nil
    let summary = try await input()
    let acted = ContinuousClock.now
    var lines = [summary]

    // A click that starts a load shows as loading a moment later.
    try await Task.sleep(for: .milliseconds(120))

    if webView.isLoading {
      try await loaded()
      lines.append("The page loaded \(url?.absoluteString ?? "") (\(title)).")
    } else {
      if isWatching { lines.append(await changes(since: acted)) }
      if url != address { lines.append("The address is now \(url?.absoluteString ?? "").") }
    }

    return (lines + takeDialogNotes()).joined(separator: "\n")
  }

  /// What differs on the page since `diffStart`, read once it is still and its requests are done, or 2 s after the input.
  private func changes(since acted: ContinuousClock.Instant) async -> String {
    let waitMs = max(0, Int((Duration.seconds(2) - (.now - acted)) / .milliseconds(1)))
    let diff: JSONValue

    do {
      diff = try await ask(["op": "diff", "prefix": "", "waitMs": waitMs, "maxChars": 2000])
    } catch {
      return "Page changes not read: \(error.localizedDescription)"
    }

    if diff["started"]?.bool == false { return "The page was replaced, so read_page shows the new document." }

    if diff["tooLarge"]?.bool == true { return "The page is too large to diff; read_page shows it." }

    let counts = ["added", "changed", "removed"].compactMap { name in diff[name]?.int.flatMap { $0 > 0 ? "\($0) \(name)" : nil } }
    var lines = counts.isEmpty ? ["Page unchanged."] : ["Page changed: \(counts.joined(separator: ", "))"] + (diff["lines"]?.array ?? []).compactMap(\.string)

    if let omitted = diff["omitted"]?.int, omitted > 0 { lines.append("(\(omitted) more changed lines left out; read_page shows them)") }

    if let pending = diff["pending"]?.int, pending > 0 {
      lines.append("(\(pending) fetch or XHR requests were still loading 2 s after the input)")
    } else if diff["settled"]?.bool == false {
      lines.append("(the page was still changing 2 s after the input)")
    }

    return lines.joined(separator: "\n")
  }

  /// Starts the page's log of input events, which `delivered` reads.
  private func watchInput() async { _ = try? await ask(["op": "events", "clear": true, "arm": false, "watch": NSNull()]) }

  /// Waits until the page has logged `count` events of `type` since `watchInput`. Input reaches the page a moment after it is sent, so what is
  /// read or sent next would otherwise get ahead of it. Input the page never logs, as when it loads another document, ends the wait.
  private func delivered(_ type: String, _ count: Int) async {
    let deadline = ContinuousClock.now + .seconds(1) + .milliseconds(10 * count)

    while ContinuousClock.now < deadline {
      guard let events = try? await ask(["op": "events", "clear": false, "arm": false, "watch": NSNull()])["events"]?.array else { return }

      if events.filter({ $0["type"]?.string == type }).reduce(0, { $0 + ($1["count"]?.int ?? 1) }) >= count { return }

      try? await Task.sleep(for: .milliseconds(15))
    }
  }

  /// Clicks a page point and waits for the page to have had the clicks.
  func click(at point: CGPoint, clicks: Int = 1, modifiers: NSEvent.ModifierFlags = []) async throws {
    await watchInput()
    try sendClick(at: point, clicks: clicks, modifiers: modifiers)
    await delivered("pointerup", clicks)
  }

  func drag(from start: CGPoint, to end: CGPoint) async throws {
    await watchInput()
    try await sendDrag(from: start, to: end)
    await delivered("pointerup", 1)
  }

  /// Presses keys in order and waits for the page to have had them. An editing command runs once the page has had the keys before it.
  func press(_ strokes: [KeyStroke]) async throws {
    await watchInput()

    for (index, stroke) in strokes.enumerated() {
      try send(stroke)
      guard let command = Self.editingCommand(for: stroke) else { continue }

      await delivered("keydown", index + 1)
      NSApp.sendAction(command, to: webView, from: nil)
    }

    await delivered("keydown", strokes.count)
  }

  /// A ref as the tools write it: 12, "12", "ref_12" or "[ref=12]".
  static func ref(_ value: JSONValue?) throws -> Int {
    if let number = value?.int { return number }

    guard let text = value?.string, let number = Int(text.filter(\.isNumber)) else { throw ToolFailure("Give a ref from read_page or find, such as 12.") }

    return number
  }

  static func point(_ value: JSONValue?, _ name: String = "coordinate") throws -> CGPoint {
    guard let pair = value?.array, pair.count == 2, let left = pair[0].number, let top = pair[1].number else { throw ToolFailure("\(name) must be [x, y] in page px.") }

    return CGPoint(x: left, y: top)
  }

  /// Clicks what `input` names by ref or by coordinate. A ref is scrolled into view first and pressed where the press lands on it.
  func click(_ input: JSONValue, clicks: Int, isRight: Bool) async throws -> String {
    let named = input["ref"].map { $0 != .null } == true
    let spot = named ? CGPoint.zero : try Self.point(input["coordinate"])
    let ref = named ? try Self.ref(input["ref"]) : try await ask(["op": "refAt", "left": spot.x, "top": spot.y])["ref"]?.int ?? 0
    let located = try await ask(["op": "locate", "ref": ref, "clip": NSNull(), "scroll": named])
    let target = located["hitDescription"]?.string ?? "ref \(ref)"

    if named, located["hitsTarget"]?.bool != true {
      throw ToolFailure(located["covered"]?.bool == true ? "ref \(ref) is under \(target); close what covers it, or click that." : "ref \(ref) has no point in view to click; read_page shows whether it is still there.")
    }

    // A pop-up select opens a menu that holds the app until someone picks from it.
    if !isRight, try await ask(["op": "inspect", "ref": ref])["kind"]?.string == "select" { throw ToolFailure("ref \(ref) is a pop-up menu; pick its option with form_input.") }

    // A real right click opens the web view's context menu, which holds the app the same way, so the page gets the events alone.
    if isRight {
      try await ask(["op": "syntheticClick", "ref": ref, "action": "right_click", "modifiers": [String]()])
      return "Right-clicked \(target) with untrusted events."
    }

    let point = named ? CGPoint(x: located["point"]?["left"]?.number ?? 0, y: located["point"]?["top"]?.number ?? 0) : spot

    try await click(at: point, clicks: clicks, modifiers: try BrowserKeys.flags(input["modifiers"]?.string ?? ""))
    return "\(["Clicked", "Double-clicked", "Triple-clicked"][clicks - 1]) \(target)."
  }

  /// Scrolls the box under a point, or the page, by wheel ticks of 100 px.
  func scroll(_ input: JSONValue) async throws -> String {
    let distance = Double(input["scroll_amount"]?.int ?? 3) * 100
    let offsets: [String: (left: Double, top: Double)] = ["up": (0, -distance), "down": (0, distance), "left": (-distance, 0), "right": (distance, 0)]
    guard let offset = offsets[input["scroll_direction"]?.string ?? ""] else { throw ToolFailure("scroll_direction must be up, down, left or right.") }

    var request: [String: Any] = ["op": "scroll", "ref": NSNull(), "left": offset.left, "top": offset.top]

    if input["coordinate"] != nil {
      let point = try Self.point(input["coordinate"])
      request["ref"] = try await ask(["op": "refAt", "left": point.x, "top": point.y])["ref"]?.int ?? NSNull()
    }

    let result = try await ask(request)
    guard result["moved"]?.bool == true else { return "Nothing scrolled; that edge is already reached." }

    return "Scrolled. The page is at \(result["viewport"]?["scrollX"]?.int ?? 0), \(result["viewport"]?["scrollY"]?.int ?? 0)."
  }

  /// Sets a form control: text for a field, true or false for a checkbox or radio, an option's label or value for a select, a value for a date, time, color or slider.
  func setControl(_ ref: Int, to value: JSONValue) async throws -> String {
    let control = try await ask(["op": "inspect", "ref": ref])
    let kind = control["kind"]?.string ?? "other"
    let text = value.string ?? value.number.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? value.bool.map(String.init) ?? ""

    switch kind {
    case "checkbox", "radio":
      guard let wanted = value.bool ?? ["true": true, "false": false][text.lowercased()] else { throw ToolFailure("A \(kind) takes true or false.") }

      if control["checked"]?.bool != wanted {
        let located = try await ask(["op": "locate", "ref": ref, "clip": NSNull(), "scroll": true])
        try await click(at: CGPoint(x: located["point"]?["left"]?.number ?? 0, y: located["point"]?["top"]?.number ?? 0))
      }
    case "select", "listbox":
      let options = control["options"]?.array ?? []
      let matches = { (option: JSONValue) in [option["label"]?.string, option["value"]?.string].contains { $0?.caseInsensitiveCompare(text) == .orderedSame } }
      guard let index = options.firstIndex(where: matches) else {
        throw ToolFailure("No option is \(text). The options are: \(options.compactMap { $0["label"]?.string }.joined(separator: ", ")).")
      }

      try await ask(["op": "selectOption", "ref": ref, "index": index])
    case "text":
      try await ask(["op": "focus", "ref": ref])
      replaceFocusedText(with: text)
    case "date", "time", "datetime-local", "color", "slider":
      try await ask(["op": "setValue", "ref": ref, "value": text])
    default:
      throw ToolFailure("ref \(ref) is not a form control; click it or type into it with computer.")
    }

    // The page answers after it has taken the input, so this reads what the control holds now.
    let after = try await ask(["op": "inspect", "ref": ref])

    if after["secure"]?.bool == true { return "Set the password field." }

    if let checked = after["checked"]?.bool { return "The \(kind) is now \(checked ? "checked" : "unchecked")." }

    if let index = after["selectedIndex"]?.int, let label = after["options"]?.array?[index]["label"]?.string { return "Selected \(label)." }

    return "The control now holds \"\(after["value"]?.string ?? "")\"."
  }

  /// One line per message: level, text, and where it was logged.
  func consoleText(limit: Int, onlyErrors: Bool, pattern: String?) async throws -> String {
    let result = try await ask(["op": "console", "onlyErrors": onlyErrors, "pattern": pattern ?? NSNull(), "limit": limit, "clear": false])
    guard result["capturing"]?.bool == true else { return "This page loaded without the console capture; reload it to read its console." }

    let entries = result["entries"]?.array ?? []
    guard !entries.isEmpty else { return onlyErrors ? "No errors in the console." : "The console is empty." }

    let lines = entries.map { entry in "[\(entry["level"]?.string ?? "log")] \(entry["text"]?.string ?? "")\(entry["source"]?.string.map { " (\($0))" } ?? "")" }
    let left = (result["matched"]?.int ?? entries.count) - entries.count

    return (lines + (left > 0 ? ["(\(left) earlier messages left out; raise limit to see them)"] : [])).joined(separator: "\n")
  }

  /// The page's loads, or with `id` the bodies of one fetch or XMLHttpRequest call.
  func requestsText(limit: Int, pattern: String?, id: Int?) async throws -> String {
    if let id {
      let result = try await ask(["op": "resourceBody", "id": id])
      guard let record = result["record"], record != .null else {
        return result["capturing"]?.bool == true ? "No body was kept for request \(id): only fetch and XMLHttpRequest calls have one." : "This page loaded without the request capture; reload it to read bodies."
      }

      let sent = record["requestBody"]?.string.map { "\nRequest body:\n\($0)" } ?? ""
      let body = record["responseBody"]?.string ?? "(\(record["note"]?.string ?? "no body"))"

      return "\(record["method"]?.string ?? "") \(record["url"]?.string ?? "") \(record["status"]?.int.map(String.init) ?? "")\nContent-Type: \(record["contentType"]?.string ?? "")\(sent)\nResponse body\(record["truncated"]?.bool == true ? " (cut)" : ""):\n\(body)"
    }

    let result = try await ask(["op": "resources", "pattern": pattern ?? NSNull(), "limit": limit])
    let resources = result["resources"]?.array ?? []
    guard !resources.isEmpty else { return "No requests\(pattern.map { " matching \($0)" } ?? "")." }

    let lines = resources.map { resource in
      "\(resource["id"]?.int ?? 0)  \(resource["status"]?.int.map(String.init) ?? "-")  \(resource["kind"]?.string ?? "")  \(resource["durationMs"]?.int ?? 0) ms  \(resource["url"]?.string ?? "")"
    }
    let left = (result["matched"]?.int ?? resources.count) - resources.count

    return (["requestId  status  kind  time  url"] + lines + (left > 0 ? ["(\(left) earlier requests left out; raise limit or give urlPattern)"] : [])).joined(separator: "\n")
  }
}
