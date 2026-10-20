// One dictation: records, transcribes on this Mac (Apple's recognizer or Whisper), ends on "stop", Return, or a
// silence after speech; Escape cancels. With the filters of its text (Whisper's phantom phrases, the Stop phrase) and
// the sound's helpers.
import AppKit
import AVFoundation
import Speech
import SwiftUI
import WhisperKit

// MARK: - One dictation

@MainActor
final class DictationSession: ObservableObject {
  enum Phase: Equatable { case starting, recording, finishing, done, cancelled, failed(String) }

  @Published var phase: Phase = .starting
  @Published var text = ""
  @Published var levels: [Float] = Array(repeating: 0, count: 32)
  @Published var finishSeconds: Double?
  @Published var loadingModel = false
  let engine = DictationPrefs.engine
  let modelLabel: String

  private var microphone: MicrophoneQueue?
  private var borrowed = false // the listener's sound (AudioFeed), rather than a microphone of its own
  private var raw: [Float] = [] // the recording as it comes (first channel, the input's rate), for Whisper
  private var rawRate: Double = 48_000
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var liveTask: Task<Void, Never>?
  private var heardSpeech = false
  private var lastVoice = Date()
  private var stopAsked: Date?
  var onClose: (() -> Void)?
  var onFinished: ((String?) -> Void)? // the text, or nil when cancelled
  var onSize: ((CGSize) -> Void)? // the pill's size, which its window follows
  var question: String?
  var target: NSRunningApplication? // the app the text is for, shown in the window

  init() {
    modelLabel = engine == .apple ? "Apple" : (whisperModels.first { $0.id == DictationPrefs.model }?.label.components(separatedBy: ":").first ?? "Whisper")
  }

  // Each wait (the permission, a model downloaded or loaded) may end on a dictation already cancelled or closed: it
  // then goes no further.
  func start() {
    Task {
      let allowed = await AVCaptureDevice.requestAccess(for: .audio)
      guard phase == .starting else { return }
      guard allowed else { return fail(DictationError.noMicrophone) }
      do {
        if engine == .apple { try startApple() } else { try await startWhisper() }
        guard phase == .starting else { return }
        try startAudio()
        phase = .recording
        // The microphone is really open now: a sound says so (the listener's Tink only said the command was taken).
        Chime.play(UserDefaults.standard.string(forKey: "openSoundName") ?? defaultOpenSound)
      } catch {
        fail(error)
      }
    }
  }

  private func fail(_ error: Error) {
    guard phase == .starting else { return }
    stopAudio()
    phase = .failed(error.localizedDescription)
  }

  private func startApple() throws {
    let status = SFSpeechRecognizer.authorizationStatus()
    if status == .notDetermined { SFSpeechRecognizer.requestAuthorization { _ in } }
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: DictationPrefs.language)), recognizer.isAvailable else {
      throw DictationError.noRecognizer
    }
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.addsPunctuation = true
    if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
    self.request = request
    task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
      guard let result else { return }
      let value = result.bestTranscription.formattedString
      Task { @MainActor in self?.heard(value, final: result.isFinal) }
    }
  }

  @Published var downloading: Double?

  private func startWhisper() async throws {
    let variant = DictationPrefs.model
    // No model yet: fetch the chosen one first, its progress shown in the window.
    if DictationPrefs.modelFolder(variant) == nil {
      let models = WhisperModels.shared
      models.download(variant)
      while models.progress[variant] != nil {
        downloading = models.progress[variant]
        try? await Task.sleep(nanoseconds: 300_000_000)
        if phase != .starting { return }
      }
      downloading = nil
      if let error = models.errors[variant] { throw NSError(domain: "Whisper", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "The model could not be downloaded: \(error)")]) }
    }
    loadingModel = true
    let kit = try await WhisperModels.shared.kit(variant)
    loadingModel = false
    guard phase == .starting else { return }
    // A rough text while speaking, the full one at the end.
    liveTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard let self, self.phase == .starting || self.phase == .recording else { return }
        guard self.phase == .recording, Double(self.raw.count) > self.rawRate else { continue }
        let text = await self.transcribe(kit, resampled(self.raw, from: self.rawRate))
        if self.phase == .recording { self.heard(text, final: false) }
      }
    }
  }

  private func transcribe(_ kit: WhisperKit, _ audio: [Float]) async -> String {
    let audio = normalized(audio)
    let options = DecodingOptions(language: DictationPrefs.language, skipSpecialTokens: true, withoutTimestamps: true)
    let results = (try? await kit.transcribe(audioArray: audio, decodeOptions: options)) ?? []
    return withoutPhantoms(results.map(\.text).joined(separator: " "))
  }

  private func startAudio() throws {
    let request = request
    let handle: (AVAudioPCMBuffer) -> Void = { [weak self] buffer in
      request?.append(buffer)
      let level = rms(buffer)
      let rate = buffer.format.sampleRate
      // Kept untouched: converting piece by piece leaves small clicks at each joint, which Whisper mishears.
      let copy = firstChannel(buffer) // kept for Whisper, and saved at the end to compare engines
      Task { @MainActor in self?.received(level: level, samples: copy, rate: rate) }
    }
    // The listener's microphone already open: its sound, rather than opening it a second time.
    if AudioFeed.shared.borrow(handle) {
      borrowed = true
      return
    }
    guard let microphone = MicrophoneQueue(handle) else { throw DictationError.noMicrophone }
    self.microphone = microphone
  }

  private func stopAudio() {
    if borrowed { AudioFeed.shared.giveBack() }
    borrowed = false
    microphone?.stop()
    microphone = nil
  }

  private func received(level: Float, samples new: [Float], rate: Double) {
    guard phase == .recording else { return }
    // Another microphone mid-way (one unplugged) may record at another rate: what came before is brought to it.
    if !raw.isEmpty, rate != rawRate { raw = resampled(raw, from: rawRate, to: rate) }
    rawRate = rate
    raw += new
    levels = Array((levels + [min(level * 12, 1)]).suffix(32))
    // Auto end: a silence after speech, as long as chosen.
    if level > 0.015 { heardSpeech = true; lastVoice = Date() }
    let silence = DictationPrefs.silenceSeconds
    if silence > 0, heardSpeech, Date().timeIntervalSince(lastVoice) > silence { finish() }
  }

  private func heard(_ value: String, final: Bool) {
    if phase == .recording || phase == .finishing { text = value }
    if phase == .recording, endsWithStop(value) { finish() }
    if final, phase == .finishing { done() }
  }

  func finish() {
    guard phase == .recording else { return }
    phase = .finishing
    stopAsked = Date()
    stopAudio()
    liveTask?.cancel()
    if engine == .apple {
      request?.endAudio()
      // The final result usually comes at once; never wait more than two seconds for it.
      Task {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if self.phase == .finishing { self.done() }
      }
    } else {
      Task {
        if let kit = try? await WhisperModels.shared.kit(DictationPrefs.model) { text = await transcribe(kit, resampled(raw, from: rawRate)) }
        done()
      }
    }
  }

  private func done() {
    guard phase == .finishing else { return }
    task?.cancel()
    text = withoutStop(text)
    finishSeconds = stopAsked.map { Date().timeIntervalSince($0) }
    saveLastDictation(resampled(raw, from: rawRate), text: text, engine: modelLabel)
    Chime.play(UserDefaults.standard.string(forKey: "endSoundName") ?? "")
    phase = .done
    onFinished?(text)
    onFinished = nil
  }

  // Whatever it was doing but transcribing what was said: the answer it waited for comes back empty.
  func cancel() {
    guard phase != .done, phase != .cancelled, phase != .finishing else { return }
    liveTask?.cancel()
    task?.cancel()
    stopAudio()
    phase = .cancelled
    onFinished?(nil)
    onFinished = nil
    onClose?()
  }
}

// Whisper's phantoms: on silence or noise it writes the credits of the subtitled videos it learnt from. Dropped
// wherever they come, so a silent dictation is empty (skipped) and a "stop" before one still ends it.
private let phantomPattern = try! NSRegularExpression(pattern: #"\s*(?:"# + [
  #"sous-titr\w*(?: \w+)* (?:soci[ée]t[ée] )?radio-canada"#,
  #"sous-titr\w* (?:r[ée]alis[ée]s? )?par\w* (?:la )?communaut[ée] d'amara\.org"#,
  #"sous-titrage st' ?\d+"#,
  #"merci d'avoir regard[ée](?: cette vid[ée]o)?"#,
  #"(?:subtitles|captions) by the amara\.org community"#,
  #"thanks? (?:you )?for watching"#,
  #"untertitel(?:ung)? (?:im auftrag )?(?:de[rs] )?(?:zdf|amara\.org-community)(?:,? (?:für funk,? )?\d{4})?"#,
  #"vielen dank fürs zuschauen"#,
].joined(separator: "|") + #")[\s.!?…]*"#, options: [.caseInsensitive])

func withoutPhantoms(_ text: String) -> String {
  phantomPattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

// "stop" said last: the dictation is sent, and the word is not part of it. The word is the plugin's `validation_word`,
// which the Voice commands settings set with the phrase chosen for Stop; else the language's ("stopp" in German).
private var stopPatterns: [String: NSRegularExpression] = [:]
private var stopPattern: NSRegularExpression {
  let config = pluginConfig()
  let word = (config["validation_word"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? VoiceCommands.defaults("stop").first ?? "stop"
  if let known = stopPatterns[word] { return known }
  let pattern = try! NSRegularExpression(pattern: #"(?:[\s,.!?…]*\b"# + NSRegularExpression.escapedPattern(for: word) + #")+[\s.!?…]*$"#, options: [.caseInsensitive])
  stopPatterns[word] = pattern
  return pattern
}

func endsWithStop(_ text: String) -> Bool {
  stopPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
}

func withoutStop(_ text: String) -> String {
  stopPattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func rms(_ buffer: AVAudioPCMBuffer) -> Float {
  guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
  var sum: Float = 0
  for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
  return sqrt(sum / Float(buffer.frameLength))
}

private func firstChannel(_ buffer: AVAudioPCMBuffer) -> [Float] {
  guard let data = buffer.floatChannelData?[0] else { return [] }
  return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
}

// The whole recording to 16 kHz mono in one pass, as Whisper expects (or to another rate).
func resampled(_ samples: [Float], from rate: Double, to targetRate: Double = 16_000) -> [Float] {
  guard !samples.isEmpty,
    let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate, channels: 1, interleaved: false),
    let converter = AVAudioConverter(from: source, to: target),
    let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
    let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(samples.count) * targetRate / rate) + 1024)
  else { return [] }
  input.frameLength = AVAudioFrameCount(samples.count)
  samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
  var given = false
  converter.convert(to: output, error: nil) { _, status in
    if given { status.pointee = .endOfStream; return nil }
    given = true
    status.pointee = .haveData
    return input
  }
  guard let data = output.floatChannelData?[0] else { return [] }
  return Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
}
