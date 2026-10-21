// The listener's sound: the app records the microphone (the default, or the one chosen: Microphone.swift) and sends it to the spoken-commands listener on
// localhost:51291, 16 kHz, 16-bit mono, raw. The microphone is then the app's (one permission, and macOS shows
// "Handfree Code" using it), not Python's. Recording runs only while a listener is connected.
import AVFoundation
import Network

let audioFeedPort: NWEndpoint.Port = 51291
private let feedFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

@MainActor
final class AudioFeed {
  static let shared = AudioFeed()
  private var listener: NWListener?
  private var clients: [ObjectIdentifier: NWConnection] = [:]
  private var microphone: MicrophoneQueue?
  private var timer: Timer?
  // The same sound, untouched, for a dictation under way (Dictation.swift): it keeps the microphone open.
  nonisolated let share = BufferShare()
  var isRecording: Bool { microphone != nil }
  private var wanted: Bool { !clients.isEmpty || share.inUse }

  func start() {
    open()
    // Taken by another program, or dropped: try again now and then. So with a microphone that failed to open.
    timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
      Task { @MainActor in
        let feed = AudioFeed.shared
        if feed.listener == nil { feed.open() }
        if feed.wanted, feed.microphone == nil { feed.startRecording() }
      }
    }
    // Headphones put on, AirPods, a microphone unplugged: record from the one to use now.
    for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
      var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
      AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
        Task { @MainActor in AudioFeed.shared.restart() }
      }
    }
  }

  private func open() {
    let parameters = NWParameters.tcp
    parameters.acceptLocalOnly = true
    parameters.allowLocalEndpointReuse = true
    guard let listener = try? NWListener(using: parameters, on: audioFeedPort) else { return }
    listener.newConnectionHandler = { connection in Task { @MainActor in AudioFeed.shared.add(connection) } }
    listener.stateUpdateHandler = { state in
      Task { @MainActor in
        switch state {
        case .failed, .cancelled:
          AudioFeed.shared.listener?.cancel()
          AudioFeed.shared.listener = nil
        default: break
        }
      }
    }
    self.listener = listener
    listener.start(queue: .main)
  }

  // The sound goes only to a program that gives the app's secret as its first line: not to any local process.
  private func add(_ connection: NWConnection) {
    connection.start(queue: .main)
    readSecret(connection, Data())
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
      if AudioFeed.shared.clients[ObjectIdentifier(connection)] == nil { connection.cancel() }
    }
  }

  private func readSecret(_ connection: NWConnection, _ received: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { data, _, complete, error in
      Task { @MainActor in
        let received = received + (data ?? Data())
        if let newline = received.firstIndex(of: UInt8(ascii: "\n")) {
          let line = String(decoding: received[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
          return isAppSecret(line) ? AudioFeed.shared.admit(connection) : connection.cancel()
        }
        if complete || error != nil || received.count > 256 { return connection.cancel() }
        AudioFeed.shared.readSecret(connection, received)
      }
    }
  }

  private func admit(_ connection: NWConnection) {
    let key = ObjectIdentifier(connection)
    connection.stateUpdateHandler = { state in
      switch state {
      case .failed, .cancelled: Task { @MainActor in AudioFeed.shared.remove(key) }
      default: break
      }
    }
    clients[key] = connection
    watchEnd(connection)
    if microphone == nil { startRecording() }
  }

  // Nothing more is read from the listener; its end tells it has gone.
  private func watchEnd(_ connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, complete, error in
      Task { @MainActor in
        if complete || error != nil { AudioFeed.shared.remove(ObjectIdentifier(connection)) } else { AudioFeed.shared.watchEnd(connection) }
      }
    }
  }

  private func remove(_ key: ObjectIdentifier) {
    clients.removeValue(forKey: key)?.cancel()
    if !wanted { stopRecording() }
  }

  // A dictation takes the sound already recorded for the listener, rather than opening the microphone a second time.
  // False when nothing is recorded.
  func borrow(_ handler: @escaping (AVAudioPCMBuffer) -> Void) -> Bool {
    guard isRecording else { return false }
    share.set(handler)
    return true
  }

  func giveBack() {
    share.set(nil)
    if !wanted { stopRecording() }
  }

  private func startRecording() {
    let share = share
    // One converter for the whole stream: a new one for each buffer leaves clicks at the joints.
    var converter: AVAudioConverter?
    microphone = MicrophoneQueue { buffer in
      share.send(buffer)
      if converter == nil { converter = AVAudioConverter(from: buffer.format, to: feedFormat) }
      guard let converter, let data = feedConvert(buffer, converter) else { return }
      Task { @MainActor in AudioFeed.shared.send(data) }
    }
  }

  // Another microphone chosen, or one unplugged: the listener hears the one to use now. One that failed to open is
  // tried again.
  func restart() {
    guard wanted else { return }
    stopRecording()
    startRecording()
  }

  private func stopRecording() {
    microphone?.stop()
    microphone = nil
  }

  private func send(_ data: Data) {
    for connection in clients.values { connection.send(content: data, completion: .idempotent) }
  }
}

private func feedConvert(_ buffer: AVAudioPCMBuffer, _ converter: AVAudioConverter) -> Data? {
  let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 64
  guard let output = AVAudioPCMBuffer(pcmFormat: feedFormat, frameCapacity: capacity) else { return nil }
  var given = false
  converter.convert(to: output, error: nil) { _, status in
    if given { status.pointee = .noDataNow; return nil }
    given = true
    status.pointee = .haveData
    return buffer
  }
  guard output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return nil }
  return Data(bytes: samples, count: Int(output.frameLength) * 2)
}

// Called from the audio thread, set from the main one.
final class BufferShare: @unchecked Sendable {
  private let lock = NSLock()
  private var handler: ((AVAudioPCMBuffer) -> Void)?

  func set(_ new: ((AVAudioPCMBuffer) -> Void)?) {
    lock.lock()
    handler = new
    lock.unlock()
  }

  var inUse: Bool {
    lock.lock()
    defer { lock.unlock() }
    return handler != nil
  }

  func send(_ buffer: AVAudioPCMBuffer) {
    lock.lock()
    let handler = handler
    lock.unlock()
    handler?(buffer)
  }
}
