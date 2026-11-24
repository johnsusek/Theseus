import ClaudeEngine
import Foundation

/// What the status row under the prompt shows, as plain values.
struct StatusRowState: Equatable {
  var runningAgents = 0
  /// The badge also stays while its popover is open, where it can read zero.
  var showsAgents = false
  var changedFiles = 0
  var added = 0
  var removed = 0
  /// The model and mode menus appear once the process has answered `initialize`.
  var hasSession = false
  var model = ""
  var effort = ""
  var mode = ""
  var contextUsed = 0
  var contextMax = 0

  var agentsTooltip: String { runningAgents == 1 ? "1 Agent Running" : "\(runningAgents) Agents Running" }
  var changesTooltip: String { changedFiles == 1 ? "1 Changed File" : "\(changedFiles) Changed Files" }
  var contextFraction: Double { contextMax > 0 ? min(Double(contextUsed) / Double(contextMax), 1) : 0 }

  /// "Context: 54.8k of 200k tokens (27%)"
  func contextTooltip(locale: Locale = .current) -> String {
    "Context: \(shortCount(contextUsed, locale: locale)) of \(shortCount(contextMax, locale: locale)) tokens (\(Int((contextFraction * 100).rounded()))%)"
  }
}

/// One agent in the agents list.
struct AgentRow: Equatable, Identifiable {
  enum State: Equatable {
    case running, done, failed, stopped
  }

  let id: String
  /// What `stopTask` takes, once the CLI has given the agent one.
  let taskId: String?
  let title: String
  /// The agent's type and what it is doing: "Explore · Reading TerminalView.swift".
  let detail: String
  let state: State
  let startedAt: Date?
  /// How long a finished agent ran.
  let duration: Duration?
  let tokens: String
}

/// One changed file in the changes list.
struct ChangeRow: Equatable, Identifiable {
  let path: String
  let name: String
  /// The file's folder below the session's working directory. Empty for a file at its top.
  let folder: String
  let added: Int
  let removed: Int

  var id: String { path }
}

/// Every agent of the session, running ones first.
func agentRows(_ transcript: Transcript, locale: Locale = .current) -> [AgentRow] {
  let rows = transcript.tasks.filter { $0.kind == .agent }.map { task in
    var state = AgentRow.State.stopped
    var doing = "Stopped"

    // "Finished: <first line of the report>", or the bare word for an agent that reported nothing.
    func outcome(_ word: String, _ report: String?) -> String {
      [word, oneLine(report ?? "", limit: 120)].filter { !$0.isEmpty }.joined(separator: ": ")
    }

    if task.status.isActive {
      let running = transcript.toolCalls.last { $0.parentToolUseId == task.id && $0.status == .running }
      state = .running
      doing = running.map { toolActivity($0.name, input: $0.input) } ?? "Thinking"
    } else if task.status == .completed {
      state = .done
      doing = outcome("Finished", task.summary)
    } else if task.status == .failed {
      state = .failed
      doing = outcome("Failed", task.error ?? task.summary)
    }

    // Progress frames replace a task's description with what it is doing, so the title comes from the Agent call.
    let title = transcript.toolCall(task.id)?.input["description"]?.string ?? task.description

    return AgentRow(
      id: task.id,
      taskId: task.taskId,
      title: title.isEmpty ? "Agent" : title,
      detail: [task.subagentType, doing].compactMap { $0 }.joined(separator: " \u{B7} "),
      state: state,
      startedAt: task.startedAt,
      duration: state == .running ? nil : task.duration ?? task.usage.map { .milliseconds($0.durationMs) },
      tokens: task.usage.map { tokenCount($0.totalTokens, locale: locale) } ?? ""
    )
  }

  return rows.filter { $0.state == .running } + rows.filter { $0.state != .running }
}

/// The changed files in the order they were first changed, with each folder relative to `base`.
func changeRows(_ files: [ChangedFile], base: URL) -> [ChangeRow] {
  let root = base.standardizedFileURL.path

  return files.map { file in
    let url = URL(filePath: file.path)
    var folder = url.deletingLastPathComponent().standardizedFileURL.path

    if folder == root {
      folder = ""
    } else if folder.hasPrefix(root + "/") {
      folder = String(folder.dropFirst(root.count + 1))
    } else {
      folder = (folder as NSString).abbreviatingWithTildeInPath
    }

    return ChangeRow(path: file.path, name: url.lastPathComponent, folder: folder, added: file.lineDelta.added, removed: file.lineDelta.removed)
  }
}

/// What the running turn is doing: waiting on a permission request, else the CLI's own summary, else the running tool call, else "Thinking".
func activityLine(summary: String?, isWaiting: Bool, transcript: Transcript) -> String {
  if isWaiting { return "Waiting for approval" }

  if let summary, !summary.isEmpty { return summary }

  let running = transcript.turns.last?.toolCallIds.reversed().lazy.compactMap { transcript.toolCall($0) }.first { $0.status == .running }
  return running.map { toolActivity($0.name, input: $0.input) } ?? "Thinking"
}

/// The app another process that has a session open runs in, from the CLI's entrypoint.
func ownerName(entrypoint: String?) -> String {
  switch entrypoint {
  case "cli": "a terminal"
  case "claude-desktop": "the Claude app"
  case "claude-vscode": "VS Code"
  default: "another app"
  }
}

/// The name a model goes by in the row. The CLI's default entry is "Default (recommended)", so it takes the name of the model it resolves to.
func modelName(_ model: InitializeInfo.Model?, id: String?, among models: [InitializeInfo.Model]) -> String {
  guard let model else { return id ?? "Unknown Model" }

  guard model.value == "default" else { return model.displayName }

  return models.first { $0.value != "default" && $0.resolvedModel == model.resolvedModel }?.displayName ?? model.displayName
}

func effortName(_ level: String) -> String {
  level == "xhigh" ? "Extra High" : level.capitalized
}

func modeName(_ mode: PermissionMode) -> String {
  switch mode {
  case .default: "Ask"
  case .acceptEdits: "Accept Edits"
  case .plan: "Plan"
  case .auto: "Auto"
  case .bypassPermissions: "Bypass Permissions"
  case .dontAsk: "Don't Ask"
  default: mode.rawValue
  }
}

/// "18.2k tokens", or the bare count under a thousand.
func tokenCount(_ tokens: Int, locale: Locale) -> String {
  shortCount(tokens, locale: locale) + " tokens"
}

/// "999", "54.8k", "200k", "1M": a count to at most one decimal.
func shortCount(_ count: Int, locale: Locale) -> String {
  let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1)).locale(locale)

  if count < 1000 { return "\(count)" }

  if count < 1_000_000 { return (Double(count) / 1000).formatted(style) + "k" }

  return (Double(count) / 1_000_000).formatted(style) + "M"
}

/// How long an agent has run: "48s", "2m 04s", "1h 02m".
func elapsedText(_ seconds: Int) -> String {
  let minutes = seconds / 60

  if minutes == 0 { return "\(seconds)s" }

  if minutes < 60 { return "\(minutes)m " + String(format: "%02ds", seconds % 60) }

  return "\(minutes / 60)h " + String(format: "%02dm", minutes % 60)
}

/// A counting timer: "0:07", "3:19", "1:02:03".
func timerText(_ seconds: Int) -> String {
  let tail = String(format: "%02d", seconds % 60)

  if seconds < 3600 { return "\(seconds / 60):\(tail)" }

  return "\(seconds / 3600):" + String(format: "%02d", seconds / 60 % 60) + ":\(tail)"
}
