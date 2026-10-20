// Dictation: who asks for one (a question, a dictation into the app in front) and what happens with its text, then
// the Dictation settings tab. One dictation is DictationSession.swift's, its window DictationPill.swift's.
import AppKit
import AVFoundation
import SwiftUI

// The app the dictations are for: the plugin's `target_app` (Claude unless set otherwise), when it runs.
func targetApp() -> NSRunningApplication? {
  let config = pluginConfig()
  let name = config["target_app"] as? String ?? "Claude"
  return NSWorkspace.shared.runningApplications.first { $0.localizedName == name }
}

@MainActor
final class DictationController {
  static let shared = DictationController()
  private var panel: DictationPanel?
  private var session: DictationSession?
  private var previousApp: NSRunningApplication?

  // A dictation under way (getting ready, recording, or its text being finished): a new one would cancel it and take
  // the user's words away from whoever waits for them.
  var isBusy: Bool {
    guard panel != nil, let phase = session?.phase else { return false }
    return phase == .starting || phase == .recording || phase == .finishing
  }

  // A question, or a dictation Claude stays behind for: the pill comes forward (the keys "stop" and "cancel" press
  // reach it), the answer goes back, and so does the app that was in front.
  func ask(_ question: String) async -> String? {
    await withCheckedContinuation { continuation in
      previousApp = NSWorkspace.shared.frontmostApplication
      start(question: question, target: targetApp()) { [weak self] text in
        continuation.resume(returning: text)
        let finished = self?.session
        // A late Return from "stop" must reach the pill, not the app behind: wait a little before leaving.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
          guard self?.closeIfStill(finished) == true else { return }
          if let app = self?.previousApp, app.bundleIdentifier != Bundle.main.bundleIdentifier { app.activate() }
          self?.previousApp = nil
        }
      }
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  // Claude's field out of reach (full screen…): dictate here, then paste the text into the field of the app in front.
  func dictateIntoFront(send: Bool) {
    guard !isBusy else { return }
    let target = NSWorkspace.shared.frontmostApplication
    start(target: target) { [weak self] text in
      let finished = self?.session
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self?.closeIfStill(finished)
        target?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
          if let text, !text.isEmpty { paste(text, send: send) } else { tellPlugin("--cancel") }
        }
      }
    }
    NSApp.activate(ignoringOtherApps: true)
  }

  func start(question: String? = nil, target: NSRunningApplication? = nil, finished: ((String?) -> Void)? = nil) {
    close()
    let session = DictationSession()
    session.question = question
    session.target = target
    session.onFinished = finished
    let hosting = FirstClickHostingView(rootView: DictationView(session: session))
    hosting.sizingOptions = [.preferredContentSize]
    let panel = DictationPanel(content: hosting)
    // Grows upwards from where it sits, near the bottom of the screen.
    session.onSize = { [weak panel] size in
      guard let panel, size.height > 0, panel.frame.size != size else { return }
      panel.setFrame(NSRect(origin: panel.frame.origin, size: size), display: true)
    }
    panel.onReturn = { [weak self, weak session] in
      guard let session else { return }
      if session.phase == .recording { session.finish() } else if session.phase != .finishing { self?.close() }
    }
    panel.onEscape = { [weak self, weak session] in
      if let session, session.phase == .recording || session.phase == .starting { session.cancel() }
      self?.close()
    }
    if let screen = NSScreen.main {
      let frame = screen.visibleFrame
      panel.setFrameOrigin(NSPoint(x: frame.midX - 214, y: frame.minY + 60))
    }
    panel.makeKeyAndOrderFront(nil)
    self.panel = panel
    self.session = session
    session.start()
  }

  // A session still getting ready, recording, or failed is cancelled: whoever waits for its answer gets one.
  func close() {
    session?.cancel()
    panel?.orderOut(nil)
    panel = nil
    session = nil
  }

  // The session that just finished, unless another one has replaced it meanwhile (a question asked at once after).
  @discardableResult
  func closeIfStill(_ finished: DictationSession?) -> Bool {
    guard let finished, finished === session || session == nil else { return false }
    if finished === session { close() }
    return true
  }
}

// MARK: - Settings tab

struct DictationSettingsView: View {
  @ObservedObject var models = WhisperModels.shared
  @ObservedObject var server = DictationServer.shared
  @AppStorage("engine") private var engine = Engine.whisper.rawValue
  @AppStorage("whisperModel") private var model = whisperModels[3].id
  @AppStorage("silenceSeconds") private var silence = 2.5
  @State private var microphoneChanged = 0

  var body: some View {
    Form {
      Section("Engine") {
        Picker("Recognition", selection: $engine) {
          ForEach(Engine.allCases) { Text($0.label).tag($0.rawValue) }
        }
        Picker("Microphone", selection: Binding(
          get: { Microphone.chosen ?? "" },
          set: { name in
            PluginSettings().set("microphone", name.isEmpty ? nil : name)
            PluginSettings().set("listener_device", nil)
            microphoneChanged += 1
            AudioFeed.shared.restart()
          })) {
          Text(String(localized: "microphone.system", defaultValue: "The system's")).tag("")
          ForEach(Microphone.inputs().map(\.name), id: \.self) { Text($0).tag($0) }
          if let chosen = Microphone.chosen, !Microphone.inputs().contains(where: { $0.name == chosen }) {
            Text("\(chosen) (not plugged in: the system's meanwhile)").tag(chosen)
          }
        }
        .id(microphoneChanged)
        Picker("Automatic end", selection: $silence) {
          Text("Never").tag(0.0)
          Text("1.5 s of silence").tag(1.5)
          Text("2.5 s of silence").tag(2.5)
          Text("4 s of silence").tag(4.0)
        }
        HStack {
          Circle().fill(server.serving ? Color.green : Color.red.opacity(0.8)).frame(width: 8, height: 8)
          Text(server.serving ? String(localized: "Ready: “claude listen”, “claude reply” and Claude's questions come here")
                              : String(localized: "Another program holds this app's local address (port 51290)")).font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("Try a dictation") { DictationController.shared.start() }
        }
      }
      Section("Whisper models") {
        ForEach(whisperModels) { item in
          HStack {
            Image(systemName: model == item.id ? "largecircle.fill.circle" : "circle")
              .foregroundStyle(model == item.id ? Color.accentColor : .secondary)
              .onTapGesture { model = item.id }
            Text(item.label)
            Spacer()
            if let value = models.progress[item.id] {
              ProgressView(value: value).frame(width: 90)
            } else if DictationPrefs.modelFolder(item.id) != nil {
              Text(models.ready == item.id ? String(localized: "ready") : models.loading == item.id ? String(localized: "loading…") : String(localized: "installed"))
                .foregroundStyle(models.ready == item.id ? Color.green : .secondary)
              Button("Delete") { models.remove(item.id) }
            } else {
              Button("Download") { models.download(item.id) }
            }
          }
          if let error = models.errors[item.id] { Text(error).font(.caption).foregroundStyle(.red) }
        }
        Text("Models are kept in ~/Library/Application Support/handfree-code/whisper. The first load of a model takes a few minutes: macOS prepares it for this Mac's chip.").font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .onChange(of: engine) { _, _ in downloadChosenIfNeeded() }
    .onChange(of: model) { _, _ in downloadChosenIfNeeded() }
  }

  private func downloadChosenIfNeeded() {
    guard engine == Engine.whisper.rawValue else { return }
    if DictationPrefs.modelFolder(model) == nil { models.download(model) } else { models.preload() }
  }
}

// The last dictation's sound and text, kept to compare engines on the same recording.
let lastDictationDir = "\(home)/Library/Caches/handfree-code"

func saveLastDictation(_ samples: [Float], text: String, engine: String) {
  guard !samples.isEmpty else { return }
  try? FileManager.default.createDirectory(atPath: lastDictationDir, withIntermediateDirectories: true)
  var pcm = Data(capacity: samples.count * 2)
  for sample in samples {
    var value = Int16(max(-1, min(1, sample)) * Float(Int16.max)).littleEndian
    withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
  }
  func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
  var wav = Data("RIFF".utf8) + le(UInt32(36 + pcm.count)) + Data("WAVEfmt ".utf8)
  wav += le(UInt32(16)) + le(UInt16(1)) + le(UInt16(1)) + le(UInt32(16_000)) + le(UInt32(32_000)) + le(UInt16(2)) + le(UInt16(16))
  wav += Data("data".utf8) + le(UInt32(pcm.count)) + pcm
  FileManager.default.createFile(atPath: "\(lastDictationDir)/last-dictation.wav", contents: wav)
  FileManager.default.createFile(atPath: "\(lastDictationDir)/last-dictation.txt", contents: Data("\(engine): \(text)\n".utf8))
}

// A quiet recording (the built-in microphone peaks low) brought up to a steady level, at most ten times louder.
func normalized(_ samples: [Float]) -> [Float] {
  let peak = samples.reduce(0) { max($0, abs($1)) }
  guard peak > 0.0001 else { return samples }
  let gain = min(0.9 / peak, 10)
  return gain > 1.05 ? samples.map { $0 * gain } : samples
}


// Apple's own sounds: the classic alerts, and those of Siri and dictation.
