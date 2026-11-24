import Foundation
@testable import ClaudeEngine

/// Builds a transcript from stream-json frames, as a live session would.
func transcript(_ frames: [JSONValue]) throws -> Transcript {
  var transcript = Transcript()
  for frame in frames { transcript.apply(try Message.decode(frame, from: try frame.encoded())) }
  return transcript
}

func prompt(_ text: String, at time: String = "10:00:00", origin: String? = nil) -> JSONValue {
  var frame: [String: JSONValue] = ["type": "user", "isReplay": true, "uuid": .string("u-" + time), "timestamp": .string("2026-11-20T\(time).000Z"), "message": ["content": .string(text)], "parent_tool_use_id": nil]
  frame["turnOrigin"] = origin.map(JSONValue.string)
  return .object(frame)
}

func said(_ text: String, uuid: String = UUID().uuidString) -> JSONValue {
  ["type": "assistant", "uuid": .string(uuid), "message": ["id": "m", "model": "x", "content": [["type": "text", "text": .string(text)]]], "parent_tool_use_id": nil]
}

func thought(_ text: String) -> JSONValue {
  ["type": "assistant", "uuid": .string(UUID().uuidString), "message": ["id": "m", "model": "x", "content": [["type": "thinking", "thinking": .string(text), "signature": "s"]]], "parent_tool_use_id": nil]
}

func call(_ id: String, _ name: String, _ input: JSONValue = [:], at time: String = "10:00:01") -> JSONValue {
  ["type": "assistant", "uuid": .string("a-" + id), "timestamp": .string("2026-11-20T\(time).000Z"), "message": ["id": "m", "model": "x", "content": [["type": "tool_use", "id": .string(id), "name": .string(name), "input": input]]], "parent_tool_use_id": nil]
}

func returned(_ id: String, _ text: String, output: JSONValue = [:], isError: Bool = false, at time: String = "10:00:02") -> JSONValue {
  ["type": "user", "uuid": .string("r-" + id), "timestamp": .string("2026-11-20T\(time).000Z"), "message": ["content": [["type": "tool_result", "tool_use_id": .string(id), "content": .string(text), "is_error": .bool(isError)]]], "parent_tool_use_id": nil, "tool_use_result": output]
}

func finished(milliseconds: Int = 112_000) -> JSONValue {
  ["type": "result", "subtype": "success", "is_error": false, "num_turns": 1, "duration_ms": .number(Double(milliseconds)), "duration_api_ms": 4]
}

/// A builder whose dates and numbers read the same on every machine.
func makeBuilder() -> TranscriptBuilder {
  var builder = TranscriptBuilder()
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
  builder.calendar = calendar
  builder.locale = Locale(identifier: "en_US")
  return builder
}

extension TranscriptElement {
  /// A short name for the element's kind, for comparing a transcript's shape.
  var shape: String {
    switch kind {
    case .prompt(let text): "prompt(\(text))"
    case .notice(let symbol, let text, _): "notice(\(symbol), \(text))"
    case .reply(let text): "reply(\(text))"
    case .thought(let text): "thought(\(text))"
    case .activity(let text, _): "activity(\(text))"
    case .tool(let row): "tool(\([row.verb, row.target].filter { !$0.isEmpty }.joined(separator: " ")))"
    case .group(let group): "group(\(group.summary.map(\.text).joined()))"
    case .detail: "detail"
    case .tasks(let tasks): "tasks(\(tasks.count))"
    case .permission(let requestId): "permission(\(requestId))"
    case .nextStep(let step): "next(\(step.recap)\(step.isOpen ? " | \(step.ask ?? "") \(step.actions)" : ""))"
    // The date's wording follows the year the test runs in, so only the duration is compared here.
    case .footer(let text): "footer(\(text.components(separatedBy: " \u{B7} ").last ?? ""))"
    }
  }
}
