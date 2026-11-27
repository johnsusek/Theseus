import AppKit

/// The Private Desktop's setup checklist, in the order each item depends on the one before.
enum DesktopItem: CaseIterable {
  case account, loggedIn, agent, accessibility, screenRecording, input

  var title: String {
    switch self {
    case .account: "Second account"
    case .loggedIn: "Logged in"
    case .agent: "Agent answering"
    case .accessibility: "Accessibility"
    case .screenRecording: "Screen Recording"
    case .input: "Input reaches it"
    }
  }

  /// What to do when the item fails, for the account named `user`.
  func fix(user: String?, agentPublished: Bool) -> String {
    let account = user ?? "the second account"

    switch self {
    case .account: return "Create a second macOS account in System Settings > Users & Groups."
    case .loggedIn: return "Log into \(account) with fast user switching, then switch back."
    case .agent where agentPublished: return "In \(account), run /Users/Shared/stagehand/install.sh in Terminal."
    case .agent: return "Run ./build.sh in the stagehand folder, then in \(account) run /Users/Shared/stagehand/install.sh."
    case .accessibility: return "In \(account), allow StagehandAgent in System Settings > Privacy & Security > Accessibility."
    case .screenRecording: return "In \(account), allow StagehandAgent in System Settings > Privacy & Security > Screen Recording."
    case .input: return "Events from StagehandAgent don't reach \(account)'s session. Log out of \(account) and back in."
    }
  }
}

/// Local accounts besides this one, and which of them are logged in.
struct StageAccounts: Equatable {
  var users: [String] = []
  var loggedIn: [String] = []

  /// `dscl` is `dscl . -list /Users UniqueID`, `ps` is `ps -axo uid=,comm=`. A logged-in account runs its own Dock.
  init(dscl: String, ps: String, me: uid_t) {
    var uids: [uid_t: String] = [:]

    for line in dscl.split(separator: "\n") {
      let fields = line.split(separator: " ", omittingEmptySubsequences: true)
      guard fields.count == 2, let uid = uid_t(fields[1]), uid >= 501, uid != me, !fields[0].hasPrefix("_") else { continue }

      uids[uid] = String(fields[0])
    }

    users = uids.keys.sorted().compactMap { uids[$0] }

    let docks = Set(ps.split(separator: "\n").compactMap { line -> uid_t? in
      let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
      guard fields.count == 2, fields[1].hasSuffix("/Dock") else { return nil }

      return uid_t(fields[0])
    })

    loggedIn = uids.keys.sorted().filter(docks.contains).compactMap { uids[$0] }
  }

  init(users: [String], loggedIn: [String]) {
    self.users = users
    self.loggedIn = loggedIn
  }
}

/// The agent's answer to `display`.
struct DisplayReport: Equatable {
  var user: String
  var accessibility: Bool
  var screenRecording: Bool
  /// The main display in points.
  var screen: CGSize

  init?(_ output: String) {
    var fields: [String: String] = [:]

    for line in output.split(separator: "\n") {
      guard let colon = line.range(of: ": ") else { continue }

      fields[line[..<colon.lowerBound].trimmingCharacters(in: .whitespaces)] = String(line[colon.upperBound...])
    }

    let main = output.split(separator: "\n").first { $0.contains(" main: ") }
    guard let user = fields["user"], let size = main?.firstMatch(of: /(\d+)x(\d+) pt/), let width = Double(size.1), let height = Double(size.2) else { return nil }

    self.user = user
    accessibility = fields["accessibility (post events)"] == "true"
    screenRecording = fields["screen recording"] == "true"
    screen = CGSize(width: width, height: height)
  }
}

enum DesktopChecks {
  /// A capture without Screen Recording shows no windows, only one flat color.
  static func isUniform(_ image: Data) -> Bool {
    guard let source = CGImageSourceCreateWithData(image as CFData, nil), let picture = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return true }

    let side = 32
    var pixels = [UInt32](repeating: 0, count: side * side)
    let drawn = pixels.withUnsafeMutableBytes { raw in
      guard let context = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }

      context.interpolationQuality = .none
      context.draw(picture, in: CGRect(x: 0, y: 0, width: side, height: side))
      return true
    }

    return !drawn || Set(pixels).count == 1
  }

  /// The agent's `pointer` answer, "requested 400,300 read 400,300", read back where it was sent.
  static func pointerReadsBack(_ output: String) -> Bool {
    let numbers = output.matches(of: /-?\d+(\.\d+)?/).compactMap { Double($0.output.0) }
    guard numbers.count == 4 else { return false }

    return abs(numbers[0] - numbers[2]) <= 1 && abs(numbers[1] - numbers[3]) <= 1
  }
}
