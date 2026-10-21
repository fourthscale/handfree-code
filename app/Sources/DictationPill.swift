// The dictation pill: the floating window a dictation records in, and the panel that takes Return and Escape.
import AppKit
import SwiftUI

// MARK: - The dictation pill: the app it is for on the left, this app on the right, a glow red while listening, blue
// while transcribing

struct DictationView: View {
  @ObservedObject var session: DictationSession

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        if let icon = session.target?.icon {
          Image(nsImage: icon).resizable().frame(width: 24, height: 24)
        }
        Text(session.target?.localizedName ?? "Handfree Code").font(.system(size: 15, weight: .semibold))
        Spacer(minLength: 12)
        Label("Handfree Code", systemImage: "waveform").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
      }
      if let question = session.question, !question.isEmpty {
        Text(question).font(.system(size: 13)).foregroundStyle(.primary).lineLimit(4).fixedSize(horizontal: false, vertical: true)
      }
      middle
      Text(hint).font(.system(size: 12)).foregroundStyle(.secondary)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(width: 380)
    .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)))
    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(glow.opacity(0.55), lineWidth: 1.5))
    .shadow(color: glow.opacity(0.55), radius: 14)
    .fixedSize(horizontal: false, vertical: true)
    .padding(24) // room for the glow
    // The window follows the pill: a long question, or a long text shown after a try, would be cut otherwise.
    .background(GeometryReader { proxy in
      Color.clear
        .onAppear { session.onSize?(proxy.size) }
        .onChange(of: proxy.size) { _, size in session.onSize?(size) }
    })
    .animation(.easeInOut(duration: 0.3), value: session.phase)
  }

  private var glow: Color {
    switch session.phase {
    case .recording: return .red
    case .finishing, .starting: return .blue
    case .done: return .green
    case .cancelled, .failed: return .gray
    }
  }

  @ViewBuilder private var middle: some View {
    switch session.phase {
    case .recording:
      Wave(levels: session.levels, color: .red).frame(height: 18)
    case .finishing:
      Shimmer(color: .blue).frame(height: 18)
    case .starting:
      Text(preparing).font(.system(size: 12)).foregroundStyle(.secondary).frame(height: 18)
    case .done:
      // Shown only for a try (a dictation for Claude closes at once).
      Text(session.text.isEmpty ? String(localized: "Nothing heard.") : session.text)
        .font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    case .cancelled:
      Text("Cancelled").font(.system(size: 12)).foregroundStyle(.secondary).frame(height: 18)
    case let .failed(message):
      Text(message).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
    }
  }

  private var preparing: String {
    if let value = session.downloading { return String(localized: "Downloading the model… \(Int(value * 100)) %") }
    return session.loadingModel ? String(localized: "Loading the model…") : String(localized: "Getting ready…")
  }

  private var hint: String {
    switch session.phase {
    case .done, .failed, .cancelled: return String(localized: "↩ or Esc to close")
    default: return String(localized: "Press ↩ to send · Esc to cancel")
    }
  }
}

// The level of the voice across the pill, newest on the right.
struct Wave: View {
  let levels: [Float]
  let color: Color

  var body: some View {
    GeometryReader { geometry in
      let count = max(Int(geometry.size.width / 6), 1)
      let shown = Array(levels.suffix(count))
      HStack(alignment: .center, spacing: 3) {
        ForEach(0..<count, id: \.self) { index in
          let level = index < count - shown.count ? 0 : shown[index - (count - shown.count)]
          Capsule().fill(color.opacity(0.85)).frame(width: 3, height: max(3, CGFloat(level) * geometry.size.height))
        }
      }
      .frame(maxHeight: .infinity)
    }
    .animation(.easeOut(duration: 0.08), value: levels)
  }
}

// Dashes running across while the text is being made.
struct Shimmer: View {
  let color: Color

  var body: some View {
    TimelineView(.animation) { timeline in
      let t = timeline.date.timeIntervalSinceReferenceDate
      GeometryReader { geometry in
        let count = max(Int(geometry.size.width / 6), 1)
        HStack(spacing: 3) {
          ForEach(0..<count, id: \.self) { index in
            let wave = (sin(Double(index) * 0.45 - t * 6) + 1) / 2
            Capsule().fill(color.opacity(0.3 + wave * 0.6)).frame(width: 3, height: 3 + wave * 6)
          }
        }
        .frame(maxHeight: .infinity)
      }
    }
  }
}

// Takes the keyboard (Return, Escape) without bringing the app forward.
final class DictationPanel: NSPanel {
  var onReturn: (() -> Void)?
  var onEscape: (() -> Void)?

  init(content: NSView) {
    super.init(contentRect: NSRect(x: 0, y: 0, width: 428, height: 160),
               styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
    isFloatingPanel = true
    level = .statusBar
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    isMovableByWindowBackground = true
    backgroundColor = .clear
    isOpaque = false
    hasShadow = false // the pill draws its own glow
    becomesKeyOnlyIfNeeded = false
    contentView = content
  }

  override var canBecomeKey: Bool { true }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 36, 76: onReturn?()
    case 53: onEscape?()
    default: super.keyDown(with: event)
    }
  }

  override func cancelOperation(_ sender: Any?) { onEscape?() }
}
