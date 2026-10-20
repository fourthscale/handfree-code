// What the plugin is doing, read from its shared state four times a second (never written here), and the Claude
// sessions seen lately: the panel and full screen show it.
import AppKit
import SwiftUI

enum Activity: Equatable {
  case off, idle, speaking, dictating, question

  var label: String {
    switch self {
    case .off: return String(localized: "Voice mode off")
    case .idle: return String(localized: "Standing by")
    case .speaking: return String(localized: "Reading")
    case .dictating: return String(localized: "Listening")
    case .question: return String(localized: "Question waiting")
    }
  }

  var colors: [Color] {
    switch self {
    case .off: return [Color(white: 0.55), Color(white: 0.35), Color(white: 0.5)]
    case .idle: return [Color(red: 0.35, green: 0.45, blue: 1.0), Color(red: 0.55, green: 0.35, blue: 0.95), Color(red: 0.2, green: 0.7, blue: 0.95)]
    case .speaking: return [Color(red: 0.2, green: 0.85, blue: 1.0), Color(red: 0.6, green: 0.35, blue: 1.0), Color(red: 1.0, green: 0.4, blue: 0.75)]
    case .dictating: return [Color(red: 1.0, green: 0.35, blue: 0.4), Color(red: 1.0, green: 0.6, blue: 0.2), Color(red: 1.0, green: 0.3, blue: 0.7)]
    case .question: return [Color(red: 1.0, green: 0.75, blue: 0.2), Color(red: 1.0, green: 0.5, blue: 0.2), Color(red: 0.95, green: 0.85, blue: 0.4)]
    }
  }

  // How much the halo moves: 0 calm, 1 lively.
  var energy: Double {
    switch self {
    case .off: return 0
    case .idle: return 0.15
    case .speaking: return 1
    case .dictating: return 0.7
    case .question: return 0.4
    }
  }
}

struct Waiting: Identifiable {
  let id: Int
  let title: String
}

struct Session: Identifiable {
  let id: String // the CLI session id, as the plugin knows it
  let title: String
  let project: String
  let lastActivity: Date
  let working: Bool
}

final class Monitor: ObservableObject {
  @Published var activity: Activity = .idle
  @Published var speakerTitle: String?
  @Published var speakerSession: String?
  @Published var line: String?
  @Published var lineIndex = 0
  @Published var lineCount = 0
  @Published var lines: [String] = [] // the reply being read, else the last one read
  @Published var linesTitle: String?
  @Published var switching = false
  @Published var waiting: [Waiting] = []
  @Published var sessions: [Session] = []

  private var transcriptPaths: [String: String] = [:]
  private var lastSessionScan = Date.distantPast

  func refresh() {
    readState()
    if Date().timeIntervalSince(lastSessionScan) > 3 {
      lastSessionScan = Date()
      scanSessions()
    }
  }

  // Tolerant on purpose: a field missing or shaped differently leaves the panel calm, never stuck.
  private func readState() {
    guard let data = FileManager.default.contents(atPath: statePath),
      let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
      activity = .idle
      return
    }
    let current = state["current"] as? [String: Any]
    let speaking = processAlive(state["speaker_pid"]) || processAlive(state["reader_pid"]) && speechLockFresh()
    // As the plugin judges it (isHeld): a hold older than max_dictation_seconds was abandoned and holds nothing.
    let since = (state["dictating_since"] as? NSNumber)?.doubleValue
    let maxDictation = (pluginConfig()["max_dictation_seconds"] as? NSNumber)?.doubleValue ?? defaultMaxDictationSeconds
    let dictating = since.map { Date().timeIntervalSince1970 - $0 < maxDictation } ?? false
    let asking = dictating && (state["dictating_session"] as? String) != nil

    if (state["voice_off"] as? Bool) == true {
      activity = .off
    } else if speaking {
      activity = .speaking
    } else if asking {
      activity = .question
    } else if dictating {
      activity = .dictating
    } else {
      activity = .idle
    }

    if let current, speaking {
      let lines = (current["lines"] as? [Any])?.compactMap { $0 as? String } ?? []
      let position = current["position"] as? Int ?? 0
      speakerTitle = current["title"] as? String
      speakerSession = current["session"] as? String
      lineCount = lines.count
      self.lines = lines
      linesTitle = speakerTitle
      lineIndex = min(position, max(lines.count - 1, 0))
      line = lines.indices.contains(lineIndex) ? lines[lineIndex] : nil
    } else if asking {
      speakerSession = state["dictating_session"] as? String
      speakerTitle = sessions.first { $0.id == speakerSession }?.title
      // The question sent back to that session, kept per session (`sent_backs`).
      line = ((state["sent_backs"] as? [String: Any])?[speakerSession ?? ""] as? [String: Any])?["question"] as? String
      lineCount = 0
    } else {
      speakerTitle = nil
      speakerSession = nil
      line = nil
      lineCount = 0
    }

    waiting = ((state["queue"] as? [[String: Any]]) ?? []).enumerated().map { index, item in
      Waiting(id: item["id"] as? Int ?? index, title: item["title"] as? String ?? "?")
    }
  }

  // Voice mode on or off, through the plugin's own command (it also starts or stops its listener).
  func toggleVoice() {
    guard !switching else { return }
    switching = true
    runPlugin(activity == .off ? "--on" : "--off") { self.switching = false }
  }

  // "Claude Quiet" by a click: the spoken command is not always heard over the reading itself.
  func quiet() {
    runPlugin("--quiet") {}
  }

  // One of the plugin's commands, in the background; the panel is refreshed once it has run.
  private func runPlugin(_ flag: String, then done: @escaping () -> Void) {
    DispatchQueue.global().async {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
      process.arguments = ["-l", "JavaScript", pluginScript, flag]
      try? process.run()
      process.waitUntilExit()
      DispatchQueue.main.async {
        done()
        self.refresh()
      }
    }
  }

  private func processAlive(_ value: Any?) -> Bool {
    guard let pid = value as? Int, pid > 0 else { return false }
    return kill(pid_t(pid), 0) == 0
  }

  private func speechLockFresh() -> Bool {
    guard let date = modified(speechLockPath) else { return false }
    return Date().timeIntervalSince(date) < speechLockStaleSeconds
  }

  private func scanSessions() {
    let fm = FileManager.default
    var found: [Session] = []
    let now = Date()
    for group in (try? fm.contentsOfDirectory(atPath: appSessionsDir)) ?? [] {
      let groupPath = "\(appSessionsDir)/\(group)"
      for sub in (try? fm.contentsOfDirectory(atPath: groupPath)) ?? [] {
        let subPath = "\(groupPath)/\(sub)"
        for file in (try? fm.contentsOfDirectory(atPath: subPath)) ?? [] where file.hasPrefix("local_") && file.hasSuffix(".json") {
          guard let data = fm.contents(atPath: "\(subPath)/\(file)"),
            let s = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            (s["isArchived"] as? Bool) != true,
            let cli = s["cliSessionId"] as? String
          else { continue }
          let activity = Date(timeIntervalSince1970: ((s["lastActivityAt"] as? Double) ?? 0) / 1000)
          guard now.timeIntervalSince(activity) < recentSessionsSeconds else { continue }
          let transcript = transcriptModified(cli)
          let working = transcript.map { now.timeIntervalSince($0) < workingSeconds } ?? false
          let cwd = s["cwd"] as? String ?? ""
          found.append(Session(id: cli, title: s["title"] as? String ?? String(localized: "Untitled"),
                               project: (cwd as NSString).lastPathComponent,
                               lastActivity: max(activity, transcript ?? activity), working: working))
        }
      }
    }
    sessions = found.sorted { $0.lastActivity > $1.lastActivity }
  }

  private func transcriptModified(_ cli: String) -> Date? {
    if let path = transcriptPaths[cli], let date = modified(path) { return date }
    for folder in (try? FileManager.default.contentsOfDirectory(atPath: projectsDir)) ?? [] {
      let path = "\(projectsDir)/\(folder)/\(cli).jsonl"
      if let date = modified(path) {
        transcriptPaths[cli] = path
        return date
      }
    }
    return nil
  }

  private func modified(_ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
  }
}
