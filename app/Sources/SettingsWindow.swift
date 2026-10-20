// The settings window: the plugin's reading settings and the control centre that holds every tab.
import AppKit
import SwiftUI

let systemVoices: [(name: String, language: String)] = NSSpeechSynthesizer.availableVoices.compactMap { voice in
  let attributes = NSSpeechSynthesizer.attributes(forVoice: voice)
  guard let name = attributes[.name] as? String else { return nil }
  return (name, attributes[.localeIdentifier] as? String ?? "")
}.sorted { $0.name < $1.name }

struct SettingsView: View {
  @ObservedObject var settings: PluginSettings
  @State private var interfaceChanged = false

  var body: some View {
    Form {
      Section("Interface") {
        HStack {
          Picker("Interface language", selection: Binding(
            get: { (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first.flatMap { ["fr", "en", "de"].contains($0) ? $0 : nil } ?? "" },
            set: { value in
              if value.isEmpty { UserDefaults.standard.removeObject(forKey: "AppleLanguages") } else { UserDefaults.standard.set([value], forKey: "AppleLanguages") }
              interfaceChanged = true
            })) {
            Text("The Mac's").tag("")
            Text("Français").tag("fr")
            Text("English").tag("en")
            Text("Deutsch").tag("de")
          }
          if interfaceChanged {
            // The app's texts are chosen when it starts: launchd starts it again.
            Button("Restart the app") { _ = run("/bin/launchctl", ["kickstart", "-k", "gui/\(uid)/com.handfree-code.app"]) }
          }
        }
      }
      Section("Reading") {
        Picker("Language", selection: settings.text("language")) {
          Text("The Mac's").tag("")
          Text("Français").tag("fr")
          Text("English").tag("en")
          Text("Deutsch").tag("de")
        }
        Picker("Voice", selection: settings.text("voice")) {
          Text("The system's").tag("")
          ForEach(voiceChoices, id: \.name) { Text("\($0.name) (\($0.language))").tag($0.name) }
        }
        Toggle("Read the first paragraph only", isOn: settings.bool("first_paragraph_only", true))
        Toggle("Sum up the rest of a long reply", isOn: settings.bool("summarize_rest", true))
        Picker("Say the session's name", selection: Binding(
          get: { settings.values["announce_session"] as? String ?? "on_change" },
          set: { settings.set("announce_session", $0 == "on_change" ? nil : $0) })) {
          Text("When it changes").tag("on_change")
          Text("Always").tag("always")
        }
        Stepper(value: settings.number("pause_between_lines_seconds", 1.2), in: 0.2...3, step: 0.1) {
          Text("Pause between lines: \(String(format: "%.1f", settings.number("pause_between_lines_seconds", 1.2).wrappedValue)) s")
        }
        Toggle("Pause music and videos", isOn: settings.bool("pause_media", true))
      }
      Section("Dictation and commands") {
        Toggle("Dictate without bringing Claude forward", isOn: settings.bool("dictate_behind", true))
        Toggle("Back to the previous app after “Stop”", isOn: settings.bool("return_to_previous_app", true))
        Toggle("Answer permission prompts by voice", isOn: settings.bool("voice_permissions", false))
        // The listener reads its settings when it starts.
        Toggle("Detailed listener log", isOn: Binding(
          get: { settings.bool("listener_log", false).wrappedValue },
          set: { settings.bool("listener_log", false).wrappedValue = $0; VoiceCommands.restartListener() }))
      }
    }
    .formStyle(.grouped)
    .onAppear { settings.load() }
  }

  private var voiceChoices: [(name: String, language: String)] {
    let language = settings.values["language"] as? String ?? Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "fr"
    let chosen = settings.values["voice"] as? String
    return systemVoices.filter { $0.language.hasPrefix(language) || $0.name == chosen }
  }
}

struct ControlCenterView: View {
  @ObservedObject var services: Services
  @ObservedObject var monitor: Monitor
  @ObservedObject var settings: PluginSettings

  var body: some View {
    TabView {
      ServicesView(services: services, monitor: monitor).tabItem { Text("Services") }
      SettingsView(settings: settings).tabItem { Text("Settings") }
      DictationSettingsView().tabItem { Text("Dictation") }
      VoiceCommandsView(settings: settings).tabItem { Text("Voice commands") }
      SoundsView().tabItem { Text("Sounds") }
      CloudView(services: services, settings: settings).tabItem { Text("Cloud sessions") }
    }
    .padding(12)
    .frame(minWidth: 540, minHeight: 600)
  }
}
