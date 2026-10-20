// The sounds: the microphone opening, and the listener's "command taken" sound.
import AppKit
import AVFoundation
import SwiftUI

let classicSounds = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]
private let systemSounds = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds"
let appleSounds: [(name: String, path: String)] = [
  (String(localized: "Siri: begin"), "\(systemSounds)/siri/jbl_begin.caf"),
  (String(localized: "Siri: short begin"), "\(systemSounds)/siri/jbl_begin_short.caf"),
  (String(localized: "Siri: confirm"), "\(systemSounds)/siri/jbl_confirm.caf"),
  (String(localized: "Siri: cancel"), "\(systemSounds)/siri/jbl_cancel.caf"),
  (String(localized: "Dictation: begin"), "\(systemSounds)/system/begin_record.caf"),
  (String(localized: "Dictation: end"), "\(systemSounds)/system/end_record.caf"),
  (String(localized: "Microphone on"), "\(systemSounds)/system/mic_unmute.caf"),
  (String(localized: "Message sent"), "\(systemSounds)/system/SentMessage.caf"),
  (String(localized: "Acknowledgment"), "\(systemSounds)/system/acknowledgment_sent.caf"),
].filter { FileManager.default.fileExists(atPath: $0.path) }
  + classicSounds.map { ($0, "/System/Library/Sounds/\($0).aiff") }
let defaultOpenSound = appleSounds.first?.path ?? ""

@MainActor
enum Chime {
  private static var players: [String: AVAudioPlayer] = [:]

  // A sound's path, or a classic sound's name; empty: none.
  static func play(_ sound: String) {
    guard !sound.isEmpty else { return }
    let path = sound.hasPrefix("/") ? sound : "/System/Library/Sounds/\(sound).aiff"
    if players[path] == nil { players[path] = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) }
    players[path]?.currentTime = 0
    players[path]?.play()
  }
}

// The command sound belongs to the plugin's listener: its `listener_sound` setting (a classic sound, or false).
func commandSound() -> String {
  let config = pluginConfig()
  if (config["listener_sound"] as? Bool) == false { return "" }
  return config["listener_sound"] as? String ?? "Tink"
}

func setCommandSound(_ name: String) {
  let settings = PluginSettings()
  settings.set("listener_sound", name.isEmpty ? false : name == "Tink" ? nil : name)
  DispatchQueue.global().async { run("/bin/launchctl", ["kickstart", "-k", "gui/\(uid)/com.handfree-code.listener"]) }
}
