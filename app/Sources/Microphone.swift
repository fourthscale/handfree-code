// The microphone the app records from, for the dictation and for the listener: the system's default, or one chosen in
// Settings > Dictation (the plugin's `microphone`, part of a device's name; `listener_device` before 0.3.2).
import AVFoundation
import CoreAudio

enum Microphone {
  // The name chosen, nil for the system's default.
  static var chosen: String? {
    let config = pluginConfig()
    let name = (config["microphone"] as? String) ?? (config["listener_device"] as? String)
    return name.flatMap { $0.isEmpty ? nil : $0 }
  }

  // The inputs plugged in now, by name.
  static func inputs() -> [(id: AudioDeviceID, name: String)] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
      var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
      var count: UInt32 = 0
      guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &count) == noErr, count > 0 else { return nil }
      var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
      var name: Unmanaged<CFString>?
      var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
      guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr, let name else { return nil }
      return (id, name.takeRetainedValue() as String)
    }
  }

  // The input chosen, when it is plugged in; the default otherwise.
  static var current: AudioDeviceID? {
    if let chosen, let device = inputs().first(where: { $0.name.localizedCaseInsensitiveContains(chosen) }) { return device.id }
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
    return id
  }

  static func uid(_ id: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var uid: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
    return uid.takeRetainedValue() as String
  }

  static func sampleRate(_ id: AudioDeviceID) -> Double {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var rate = Float64(0)
    var size = UInt32(MemoryLayout<Float64>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr else { return 0 }
    return rate
  }
}

// The microphone alone, through an audio queue. AVAudioEngine records through an aggregate device that holds the
// speakers too, and while it runs, opening a dictation makes macOS play the end of the last sound again
// ("…cro, cro, cro" after a question read aloud).
final class MicrophoneQueue {
  private var queue: AudioQueueRef?
  let format: AVAudioFormat

  // The buffers come on a queue of their own: first channel, Float32, at the microphone's own rate.
  init?(_ handler: @escaping (AVAudioPCMBuffer) -> Void) {
    guard let device = Microphone.current, let uid = Microphone.uid(device) else { return nil }
    let rate = Microphone.sampleRate(device)
    guard rate > 0, let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: true) else { return nil }
    var description = format.streamDescription.pointee
    var queue: AudioQueueRef?
    let status = AudioQueueNewInputWithDispatchQueue(&queue, &description, 0, DispatchQueue(label: "handfree-code.microphone")) { queue, buffer, _, _, _ in
      let bytes = buffer.pointee.mAudioDataByteSize
      let frames = bytes / UInt32(MemoryLayout<Float>.size)
      if frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let samples = pcm.floatChannelData?[0] {
        pcm.frameLength = frames
        memcpy(samples, buffer.pointee.mAudioData, Int(bytes))
        handler(pcm)
      }
      AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }
    guard status == noErr, let queue else { return nil }
    var deviceUID = uid as CFString
    AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, &deviceUID, UInt32(MemoryLayout<CFString>.size))
    // About a tenth of a second each.
    let size = UInt32(rate / 10) * UInt32(MemoryLayout<Float>.size)
    for _ in 0..<3 {
      var buffer: AudioQueueBufferRef?
      if AudioQueueAllocateBuffer(queue, size, &buffer) == noErr, let buffer { AudioQueueEnqueueBuffer(queue, buffer, 0, nil) }
    }
    guard AudioQueueStart(queue, nil) == noErr else {
      AudioQueueDispose(queue, true)
      return nil
    }
    self.queue = queue
    self.format = format
  }

  func stop() {
    guard let queue else { return }
    AudioQueueStop(queue, true)
    AudioQueueDispose(queue, true)
    self.queue = nil
  }

  deinit { stop() }
}
