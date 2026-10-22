import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - The spoken commands and their keyboard shortcuts
// What each command runs and its default phrases come from voice-commands.json, shared with the listener. The user's
// phrases go to the plugin's `voice_commands` (the listener reads them when it starts), the shortcuts to the app's defaults.

struct VoiceCommand: Identifiable {
  let id: String
  let title: String
  let about: String
  // "Stop" and "Cancel" are Return and Escape on the keyboard.
  var hasShortcut: Bool { id != "stop" && id != "cancel" }
  // Voice mode off stops the listener: nothing would hear "voice mode on", which is a shortcut only.
  var hasPhrases: Bool { id != "voice_on" }
  var argument: String { VoiceCommands.arguments[id] ?? "" }
}

enum VoiceCommands {
  private static let file: [String: Any] = Bundle.main.url(forResource: "voice-commands", withExtension: "json")
    .flatMap { try? Data(contentsOf: $0) }
    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
  static let arguments = file["commands"] as? [String: String] ?? [:]
  private static let defaultPhrases = file["phrases"] as? [String: [String: [String]]] ?? [:]

  // The order of the settings, and of the hotkey ids: "listen" 1 and "reply" 2, as before.
  static let all = [
    VoiceCommand(id: "listen", title: String(localized: "command.listen", defaultValue: "Listen"), about: String(localized: "Dictate to the session on screen")),
    VoiceCommand(id: "reply", title: String(localized: "command.reply", defaultValue: "Reply"), about: String(localized: "Dictate to the session that spoke last")),
    VoiceCommand(id: "session", title: String(localized: "command.session", defaultValue: "Session"), about: String(localized: "Find a session by its name")),
    VoiceCommand(id: "stop", title: String(localized: "command.stop", defaultValue: "Stop"), about: String(localized: "Send the dictation")),
    VoiceCommand(id: "cancel", title: String(localized: "command.cancel", defaultValue: "Cancel"), about: String(localized: "Cancel the dictation")),
    VoiceCommand(id: "quiet", title: String(localized: "command.quiet", defaultValue: "Quiet"), about: String(localized: "Cut the reading")),
    VoiceCommand(id: "continue", title: String(localized: "command.continue", defaultValue: "Continue"), about: String(localized: "Read the rest of the reply")),
    VoiceCommand(id: "restart", title: String(localized: "command.restart", defaultValue: "Restart"), about: String(localized: "Read the reply again from the start")),
    VoiceCommand(id: "voice_on", title: String(localized: "command.voice_on", defaultValue: "Voice mode on"), about: String(localized: "Turn voice mode on")),
    VoiceCommand(id: "voice_off", title: String(localized: "command.voice_off", defaultValue: "Voice mode off"), about: String(localized: "Turn everything off, listening included")),
    VoiceCommand(id: "session_on", title: String(localized: "command.session_on", defaultValue: "Voice this session"), about: String(localized: "Voice mode for the session on screen only")),
    VoiceCommand(id: "session_off", title: String(localized: "command.session_off", defaultValue: "Mute this session"), about: String(localized: "No voice for the session on screen")),
  ]

  // The names the Voice Control setup used in `voice_commands`, still read by the listener.
  static let oldNames = file["old_names"] as? [String: String] ?? [:]

  // The listener's language: the plugin's, else the Mac's, else English.
  static var language: String {
    let chosen = String(DictationPrefs.language.prefix(2))
    return defaultPhrases[chosen] != nil ? chosen : "en"
  }

  static func defaults(_ id: String) -> [String] { defaultPhrases[language]?[id] ?? [] }

  // The user's own phrases for a command, nil when it keeps the defaults.
  static func chosen(_ id: String, _ values: [String: Any]) -> [String]? {
    let table = values["voice_commands"] as? [String: Any] ?? [:]
    let found = table.first { $0.key == id } ?? table.first { oldNames[$0.key] == id }
    if let one = found?.value as? String { return [one] }
    return found?.value as? [String]
  }

  @MainActor static func setChosen(_ id: String, _ phrases: [String]?, _ settings: PluginSettings) {
    var table = settings.values["voice_commands"] as? [String: Any] ?? [:]
    for key in table.keys where key == id || oldNames[key] == id { table.removeValue(forKey: key) }
    if let phrases, !phrases.isEmpty, phrases != defaults(id) { table[id] = phrases }
    settings.set("voice_commands", table.isEmpty ? nil : table)
    // The plugin strips the word that sends a dictation from the answers, and the app ends a dictation on it.
    if id == "stop" { settings.set("validation_word", table["stop"] == nil ? nil : phrases?.first) }
  }

  static func restartListener() {
    DispatchQueue.global().async { run("/bin/launchctl", ["kickstart", "-k", "gui/\(uid)/com.handfree-code.listener"]) }
  }
}

// MARK: - Keyboard shortcuts: a command from anywhere on the Mac, as if spoken

struct Shortcut: Codable, Equatable {
  let keyCode: UInt32
  let modifiers: UInt32 // Carbon's
  let display: String
  var double: Bool? = nil // a modifier key pressed twice alone (keyCode is that key's): not a Carbon hot key

  private static func key(_ id: String) -> String { "shortcut.\(id)" }

  // Given until the user sets or clears them: Listen, Reply, Quiet, and Voice mode on, which has no phrase.
  private static let defaults: [String: Shortcut] = [
    "listen": Shortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥L"),
    "reply": Shortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥R"),
    "quiet": Shortcut(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥Q"),
    "voice_on": Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥V"),
  ]

  static func load(_ id: String) -> Shortcut? {
    guard let data = UserDefaults.standard.data(forKey: key(id)) else { return defaults[id] }
    return try? JSONDecoder().decode(Shortcut.self, from: data) // cleared: an empty value, so not the default
  }

  // nil clears it. A shortcut taken by another command is taken from it.
  @MainActor static func save(_ shortcut: Shortcut?, _ id: String) {
    if let shortcut {
      for other in VoiceCommands.all where other.id != id && load(other.id).map({ $0.keyCode == shortcut.keyCode && $0.modifiers == shortcut.modifiers && $0.double == shortcut.double }) == true {
        UserDefaults.standard.set(Data(), forKey: key(other.id))
      }
    }
    UserDefaults.standard.set(shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: key(id))
    HotKeys.shared.register()
  }

  @MainActor static func reset() {
    VoiceCommands.all.forEach { UserDefaults.standard.removeObject(forKey: key($0.id)) }
    HotKeys.shared.register()
  }

  init(keyCode: UInt32, modifiers: UInt32, display: String, double: Bool? = nil) {
    self.keyCode = keyCode
    self.modifiers = modifiers
    self.display = display
    self.double = double
  }

  static func doubleTap(_ keyCode: UInt16) -> Shortcut {
    Shortcut(keyCode: UInt32(keyCode), modifiers: 0, display: (ModifierTaps.names[keyCode] ?? "?") + " ×2", double: true)
  }

  static let functionKeys: [UInt16: String] = [
    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
    103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
  ]

  static func symbols(_ flags: NSEvent.ModifierFlags) -> String {
    (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
  }

  // A key with ⌘, ⌥ or ⌃, or a function key alone; nil otherwise (a plain letter would fire while typing).
  init?(event: NSEvent) {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let function = Shortcut.functionKeys[event.keyCode]
    guard !flags.intersection([.command, .option, .control]).isEmpty || function != nil else { return nil }
    var carbon: UInt32 = 0
    if flags.contains(.control) { carbon |= UInt32(controlKey) }
    if flags.contains(.option) { carbon |= UInt32(optionKey) }
    if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
    if flags.contains(.command) { carbon |= UInt32(cmdKey) }
    let names: [UInt16: String] = [49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑"]
    let key = function ?? names[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
    self.init(keyCode: UInt32(event.keyCode), modifiers: carbon, display: Shortcut.symbols(flags) + key)
  }
}

@MainActor
final class HotKeys {
  static let shared = HotKeys()
  private var refs: [EventHotKeyRef] = []
  private var installed = false
  private(set) var refused: Set<String> = [] // shortcuts macOS would not register: taken by the system or another app

  func register() {
    if !installed {
      installed = true
      var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
      InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
        var id = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                          MemoryLayout<EventHotKeyID>.size, nil, &id)
        DispatchQueue.main.async { HotKeys.fire(id.id) }
        return noErr
      }, 1, &spec, nil, nil)
    }
    pause()
    refused = []
    ModifierTaps.shared.start()
    for (index, command) in VoiceCommands.all.enumerated() where command.hasShortcut {
      guard let shortcut = Shortcut.load(command.id), shortcut.double != true else { continue }
      var ref: EventHotKeyRef?
      let id = EventHotKeyID(signature: OSType(0x4846_4344), id: UInt32(index + 1)) // "HFCD"
      if RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
        refs.append(ref)
      } else {
        refused.insert(command.id)
      }
    }
  }

  // While a shortcut is typed in the settings: a registered one would never reach the window.
  func pause() {
    refs.forEach { UnregisterEventHotKey($0) }
    refs = []
    ModifierTaps.shared.paused = true
  }

  static func fire(_ id: UInt32) {
    guard id >= 1, Int(id) <= VoiceCommands.all.count else { return }
    run(VoiceCommands.all[Int(id) - 1])
  }

  static func run(_ command: VoiceCommand) {
    Chime.play(commandSound()) // the same sound as a spoken command
    // The shortcut that starts a dictation, pressed again while one is under way, ends it as "Stop" does: run again, it
    // would bring Claude forward over the pill, whose Return and Escape would then go to Claude.
    if startsDictation.contains(command.id), DictationController.shared.finishCurrent() {
      tellPlugin("--done")
      return
    }
    tellPlugin(command.argument)
  }

  private static let startsDictation: Set<String> = ["listen", "reply", "session"]
}

// A modifier key pressed and let go twice, quickly and alone (right ⌘ twice, say). Tight on purpose: a hand brushing
// the keyboard (a cough, a ⌘ held a little) must not start a dictation.
struct TapDetector {
  static let maxPressSeconds = 0.2 // each press, from down to up
  static let maxGapSeconds = 0.3 // from the first tap's release to the second tap's press
  private var down: (code: UInt16, at: Date)?
  private var released: (code: UInt16, at: Date)?

  // The key, when this event completes a double tap.
  mutating func feed(_ event: NSEvent) -> UInt16? {
    guard event.type == .flagsChanged else { return feed(code: nil, flags: [], at: Date()) }
    return feed(code: event.keyCode, flags: event.modifierFlags.intersection([.command, .option, .control, .shift]), at: Date())
  }

  // The same, from what the event says: the modifier key (nil: any other key or event), the modifiers held after it.
  mutating func feed(code: UInt16?, flags: NSEvent.ModifierFlags, at now: Date) -> UInt16? {
    guard let code, let flag = ModifierTaps.flags[code] else { down = nil; released = nil; return nil }
    if flags == flag { // pressed, alone
      // A second press comes soon after the first release, or it starts over as a first one.
      if let first = released, first.code != code || now.timeIntervalSince(first.at) > TapDetector.maxGapSeconds { released = nil }
      down = (code, now)
      return nil
    }
    defer { down = nil }
    guard flags.isEmpty, let pressed = down, pressed.code == code, now.timeIntervalSince(pressed.at) < TapDetector.maxPressSeconds else {
      released = nil
      return nil
    }
    if released?.code == code { released = nil; return code }
    released = (code, now)
    return nil
  }
}

// Watches the keyboard for the double taps chosen: in other apps (needs Accessibility, which the app asks for) and in its own.
@MainActor
final class ModifierTaps {
  static let shared = ModifierTaps()
  static let flags: [UInt16: NSEvent.ModifierFlags] = [54: .command, 55: .command, 58: .option, 61: .option, 59: .control, 62: .control, 56: .shift, 60: .shift]
  static let names: [UInt16: String] = [
    54: String(localized: "Right ⌘"), 55: String(localized: "Left ⌘"), 61: String(localized: "Right ⌥"), 58: String(localized: "Left ⌥"),
    62: String(localized: "Right ⌃"), 59: String(localized: "Left ⌃"), 60: String(localized: "Right ⇧"), 56: String(localized: "Left ⇧"),
  ]
  var paused = false
  private var detector = TapDetector()
  private var monitors: [Any] = []

  func start() {
    paused = false
    guard monitors.isEmpty else { return }
    let handle: (NSEvent) -> Void = { event in MainActor.assumeIsolated { ModifierTaps.shared.feed(event) } }
    if let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: handle) { monitors.append(global) }
    if let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { handle($0); return $0 }) { monitors.append(local) }
  }

  private func feed(_ event: NSEvent) {
    guard !paused, let code = detector.feed(event) else { return }
    if let command = VoiceCommands.all.first(where: { $0.hasShortcut && Shortcut.load($0.id).map { $0.double == true && $0.keyCode == UInt32(code) } == true }) {
      HotKeys.run(command)
    }
  }
}

struct ShortcutField: View {
  let id: String
  @State private var shortcut: Shortcut?
  @State private var recording = false
  @State private var held = ""
  @State private var refused = false
  @State private var monitor: Any?
  @State private var taps = TapDetector()

  var body: some View {
    HStack(spacing: 6) {
      Button(label) { recording ? stop() : record() }
        .frame(minWidth: 110)
      if let warning, !recording {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(warning)
      }
      if shortcut != nil, !recording {
        Button { Shortcut.save(nil, id); shortcut = nil } label: { Image(systemName: "xmark.circle.fill") }
          .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove the shortcut")
      }
    }
    .onAppear { shortcut = Shortcut.load(id) }
    .onDisappear { stop() }
  }

  // Why the shortcut set cannot work, if it cannot.
  @MainActor private var warning: String? {
    guard let shortcut else { return nil }
    if shortcut.double == true { return AXIsProcessTrusted() ? nil : String(localized: "Needs the Accessibility permission (System Settings > Privacy & Security > Accessibility).") }
    return HotKeys.shared.refused.contains(id) ? String(localized: "Already taken by macOS or another app: choose another.") : nil
  }

  private var label: String {
    guard recording else { return shortcut?.display ?? String(localized: "Set") }
    if refused { return String(localized: "Add ⌘, ⌥ or ⌃, or tap one twice") }
    return held.isEmpty ? String(localized: "Type the shortcut…") : held + "…"
  }

  @MainActor private func record() {
    // The window must have the keyboard: an app without a Dock icon may not have been made active by the click.
    NSApp.activate(ignoringOtherApps: true)
    NSApp.windows.first { $0.isVisible && $0.canBecomeKey && $0.styleMask.contains(.titled) }?.makeKey()
    HotKeys.shared.pause()
    recording = true
    held = ""
    refused = false
    taps = TapDetector()
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
      if let code = taps.feed(event) {
        let value = Shortcut.doubleTap(code)
        Shortcut.save(value, id)
        shortcut = value
        stop()
        return nil
      }
      if event.type == .flagsChanged {
        held = Shortcut.symbols(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        if !held.isEmpty { refused = false }
        return event
      }
      if event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control]).isEmpty { stop(); return nil } // Esc alone: keep it
      if let value = Shortcut(event: event) {
        Shortcut.save(value, id)
        shortcut = value
        stop()
      } else {
        refused = true
      }
      return nil
    }
  }

  @MainActor private func stop() {
    guard recording || monitor != nil else { return }
    recording = false
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    HotKeys.shared.register()
  }
}

// MARK: - Settings tab: Voice commands

struct VoiceCommandsView: View {
  @ObservedObject var settings: PluginSettings
  @State private var refresh = 0 // redraws the shortcuts after a reset

  var body: some View {
    Form {
      Section {
        ForEach(VoiceCommands.all) { command in
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(command.title)
                Text(command.about).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              if command.hasShortcut {
                ShortcutField(id: command.id).id("\(command.id)-\(refresh)")
              } else {
                Text(command.id == "stop" ? "↩" : "⎋").foregroundStyle(.secondary).help("Its key while you dictate")
              }
            }
            if command.hasPhrases {
              PhraseField(id: command.id, settings: settings)
            } else {
              Text("No phrase: with voice mode off, nothing listens. Use its shortcut, or the app's menu.").font(.caption).foregroundStyle(.secondary)
            }
          }
          .padding(.vertical, 2)
        }
      } header: {
        Text("Spoken phrases and keyboard shortcuts")
      } footer: {
        Text("Several phrases for one command: separate them with commas. Empty: the default ones. Say a command on its own, between two short pauses; “claude” in front keeps a word said in conversation from triggering it. The phrases must be made of words the listener's speech model knows. A shortcut works anywhere on the Mac, like the spoken command. The listener restarts to take a new phrase.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section {
        HStack {
          Button("Restore the defaults") {
            settings.set("voice_commands", nil)
            settings.set("validation_word", nil)
            Shortcut.reset()
            refresh += 1
            VoiceCommands.restartListener()
          }
          Spacer()
        }
      }
    }
    .formStyle(.grouped)
    .onAppear { settings.load() }
  }
}

// The phrases of one command, written when Return is pressed or the field is left: not at each key, which would undo a comma.
struct PhraseField: View {
  let id: String
  @ObservedObject var settings: PluginSettings
  @State private var text = ""
  @FocusState private var focused: Bool

  var body: some View {
    TextField("", text: $text, prompt: Text(VoiceCommands.defaults(id).joined(separator: ", ")))
      .textFieldStyle(.roundedBorder)
      .focused($focused)
      .onSubmit(save)
      .onChange(of: focused) { _, now in if !now { save() } }
      .onAppear(perform: show)
      .onDisappear(perform: save)
      .onReceive(settings.objectWillChange) { _ in DispatchQueue.main.async { if !focused { show() } } }
  }

  private func show() { text = VoiceCommands.chosen(id, settings.values)?.joined(separator: ", ") ?? "" }

  private func save() {
    let list = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    let before = VoiceCommands.chosen(id, settings.values)
    let after: [String]? = list.isEmpty || list == VoiceCommands.defaults(id) ? nil : list
    guard before != after else { return }
    VoiceCommands.setChosen(id, after, settings)
    VoiceCommands.restartListener() // it reads its phrases when it starts
  }
}

// MARK: - Settings tab: Sounds

struct SoundsView: View {
  @AppStorage("openSoundName") private var openSound = defaultOpenSound
  @AppStorage("endSoundName") private var endSound = ""

  @ViewBuilder private var soundChoices: some View {
    Text("None").tag("")
    ForEach(appleSounds, id: \.path) { Text($0.name).tag($0.path) }
  }

  var body: some View {
    Form {
      Section {
        Picker("Command taken", selection: Binding(
          get: { commandSound() },
          set: { setCommandSound($0); Chime.play($0) })) {
          Text("None").tag("")
          ForEach(classicSounds, id: \.self) { Text($0).tag($0) }
        }
        Picker("Microphone open", selection: Binding(get: { openSound }, set: { openSound = $0; Chime.play($0) })) {
          soundChoices
        }
        Picker("Dictation done", selection: Binding(get: { endSound }, set: { endSound = $0; Chime.play($0) })) {
          soundChoices
        }
      } footer: {
        Text("The command sound is played for a spoken command or a shortcut. The listener restarts to take it.").font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}
