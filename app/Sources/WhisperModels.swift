// The dictation engines and Whisper's models: which one is chosen, downloaded, kept and loaded once.
import AppKit
import SwiftUI
import WhisperKit

enum Engine: String, CaseIterable, Identifiable {
  case apple, whisper
  var id: String { rawValue }
  var label: String { self == .apple ? String(localized: "Apple (on this Mac)") : String(localized: "Whisper (on this Mac)") }
}

struct WhisperModel: Identifiable {
  let id: String // WhisperKit's variant name
  let label: String
}

let whisperModels = [
  WhisperModel(id: "openai_whisper-base", label: String(localized: "Base: fast, less accurate (~150 MB)")),
  WhisperModel(id: "openai_whisper-small_216MB", label: String(localized: "Small: balanced (~220 MB)")),
  WhisperModel(id: "openai_whisper-large-v3-v20240930_turbo_632MB", label: String(localized: "Large v3 Turbo, compressed: accurate (~630 MB)")),
  WhisperModel(id: "openai_whisper-large-v3-v20240930_turbo", label: String(localized: "Large v3 Turbo, full: the most accurate (~1.6 GB)")),
]

let modelsBase = URL(fileURLWithPath: "\(supportDir)/whisper")

// The dictation's choices, kept in the app's own defaults: the plugin only asks for a dictation.
enum DictationPrefs {
  static var engine: Engine { Engine(rawValue: UserDefaults.standard.string(forKey: "engine") ?? "") ?? .whisper }
  static var model: String { UserDefaults.standard.string(forKey: "whisperModel") ?? whisperModels[3].id }
  static var silenceSeconds: Double { UserDefaults.standard.object(forKey: "silenceSeconds") as? Double ?? 2.5 } // 0: never
  static var language: String {
    let plugin = pluginConfig()
    return (plugin["language"] as? String) ?? String((Locale.preferredLanguages.first ?? "fr").prefix(2))
  }
  static func modelFolder(_ variant: String) -> String? {
    guard let path = UserDefaults.standard.string(forKey: "modelPath.\(variant)"), FileManager.default.fileExists(atPath: path) else { return nil }
    return path
  }
}

// MARK: - Whisper models: download, keep, load once

@MainActor
final class WhisperModels: ObservableObject {
  static let shared = WhisperModels()
  @Published var progress: [String: Double] = [:]
  @Published var errors: [String: String] = [:]
  @Published var ready: String? // the variant loaded and kept in memory
  @Published var loading: String?
  private var loaded: (variant: String, kit: WhisperKit)?
  private var loadTask: (variant: String, task: Task<WhisperKit, Error>)?

  // Loaded once, kept: at launch, after a download, when another model is chosen. Whisper chosen only; its model
  // not there yet (a first launch): downloaded first, so the first dictation does not wait for it.
  func preload() {
    guard DictationPrefs.engine == .whisper else { return }
    let variant = DictationPrefs.model
    guard DictationPrefs.modelFolder(variant) != nil else { return download(variant) }
    Task { _ = try? await kit(variant) }
  }

  func download(_ variant: String) {
    guard progress[variant] == nil, DictationPrefs.modelFolder(variant) == nil else { return }
    progress[variant] = 0
    errors[variant] = nil
    Task {
      do {
        let folder = try await WhisperKit.download(variant: variant, downloadBase: modelsBase) { value in
          Task { @MainActor in self.progress[variant] = value.fractionCompleted }
        }
        UserDefaults.standard.set(folder.path, forKey: "modelPath.\(variant)")
        progress[variant] = nil
        preload()
      } catch {
        errors[variant] = error.localizedDescription
      }
      progress[variant] = nil
      objectWillChange.send()
    }
  }

  func remove(_ variant: String) {
    if let folder = DictationPrefs.modelFolder(variant) { try? FileManager.default.removeItem(atPath: folder) }
    UserDefaults.standard.removeObject(forKey: "modelPath.\(variant)")
    if loaded?.variant == variant { loaded = nil; ready = nil }
    objectWillChange.send()
  }

  func kit(_ variant: String) async throws -> WhisperKit {
    if let loaded, loaded.variant == variant { return loaded.kit }
    if let loadTask, loadTask.variant == variant { return try await loadTask.task.value } // one load at a time
    guard let folder = DictationPrefs.modelFolder(variant) else { throw DictationError.noModel }
    loaded = nil // one model in memory: the previous one goes
    ready = nil
    loading = variant
    let task = Task { try await WhisperKit(WhisperKitConfig(modelFolder: folder, verbose: false, load: true, download: false)) }
    loadTask = (variant, task)
    defer {
      if loadTask?.variant == variant { loadTask = nil }
      if loading == variant { loading = nil }
    }
    let kit = try await task.value
    loaded = (variant, kit)
    ready = variant
    return kit
  }
}

enum DictationError: LocalizedError {
  case noModel, noMicrophone, noRecognizer
  var errorDescription: String? {
    switch self {
    case .noModel: return String(localized: "No Whisper model downloaded: choose one in Settings > Dictation.")
    case .noMicrophone: return String(localized: "Handfree Code may not use the microphone (System Settings > Privacy & Security > Microphone).")
    case .noRecognizer: return String(localized: "Apple's speech recognition is not available for this language.")
    }
  }
}
