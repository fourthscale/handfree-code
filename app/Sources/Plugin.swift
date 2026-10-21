// Where the plugin keeps its files, and its settings: read by every part of the app, edited by the settings window.
import AppKit
import SwiftUI

// MARK: - What the plugin and the app write

let home = FileManager.default.homeDirectoryForCurrentUser.path
// The second of each: its name before 0.3.2, until the plugin moves it (and leaves a link).
let stateDir = ["\(home)/Library/Caches/handfree-code", "\(home)/Library/Caches/claude-speak"]
  .first { FileManager.default.fileExists(atPath: "\($0)/state.json") } ?? "\(home)/Library/Caches/handfree-code"
let statePath = "\(stateDir)/state.json"
let speechLockPath = "\(stateDir)/speech.lock"
let appSessionsDir = "\(home)/Library/Application Support/Claude/claude-code-sessions"
let projectsDir = "\(home)/.claude/projects"
let speechLockStaleSeconds: TimeInterval = 20 // the speaker touches its lock every 5 s
let recentSessionsSeconds: TimeInterval = 3 * 3600
let workingSeconds: TimeInterval = 10 // a transcript written this recently: the session is working

// The plugin's stable copy (its scripts, the app's secret, the Whisper models): the same path across plugin versions.
let supportDir = "\(home)/Library/Application Support/handfree-code"

// MARK: - The plugin's settings

let configPath = ["\(home)/.config/handfree-code.json", "\(home)/.config/claude-speak.json"]
  .first { FileManager.default.fileExists(atPath: $0) } ?? "\(home)/.config/handfree-code.json"
// The plugin's default (DEFAULTS.max_dictation_seconds in handfree.js): a dictation older than this holds nothing.
let defaultMaxDictationSeconds: TimeInterval = 180

// The plugin's settings as they are now; empty when the file is missing or not JSON.
func pluginConfig() -> [String: Any] {
  guard let data = FileManager.default.contents(atPath: configPath) else { return [:] }
  return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

// Where the bridge listens on this Mac, for the tunnel to point at (`bridge_port`, as install-bridge.sh reads it).
func bridgeAddress() -> String {
  "127.0.0.1:\((pluginConfig()["bridge_port"] as? NSNumber)?.intValue ?? 8765)"
}

// MARK: - Settings: the plugin's own file, edited in place (other keys untouched, a default removes its key)

final class PluginSettings: ObservableObject {
  @Published private(set) var values: [String: Any] = [:]

  init() { load() }

  func load() {
    values = pluginConfig()
  }

  // Read again just before writing: a script may have changed the file meanwhile.
  func set(_ key: String, _ value: Any?) {
    load()
    if let value { values[key] = value } else { values.removeValue(forKey: key) }
    guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
    try? FileManager.default.createDirectory(atPath: (configPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: configPath, contents: data, attributes: [.posixPermissions: 0o600])
    objectWillChange.send()
  }

  func bool(_ key: String, _ fallback: Bool) -> Binding<Bool> {
    Binding(get: { self.values[key] as? Bool ?? fallback }, set: { self.set(key, $0 == fallback ? nil : $0) })
  }

  func text(_ key: String) -> Binding<String> {
    Binding(get: { self.values[key] as? String ?? "" }, set: { self.set(key, $0.isEmpty ? nil : $0) })
  }

  func number(_ key: String, _ fallback: Double) -> Binding<Double> {
    Binding(get: { (self.values[key] as? NSNumber)?.doubleValue ?? fallback }, set: {
      let value = ($0 * 10).rounded() / 10
      self.set(key, value == fallback ? nil : value)
    })
  }
}
