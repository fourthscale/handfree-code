// The floating panel (a fixed size, or the halo alone when reduced) and full screen (the whole reply, the queue and
// the sessions in detail), with the pieces they share.
import AppKit
import SwiftUI

// MARK: - Shared pieces

func placeholder(_ activity: Activity) -> String {
  switch activity {
  case .off: return String(localized: "Voice mode is off.")
  case .dictating: return String(localized: "Listening…")
  case .question: return String(localized: "A question waits for your answer.")
  default: return String(localized: "Nothing being read.")
  }
}

let relativeFormatter: RelativeDateTimeFormatter = {
  let formatter = RelativeDateTimeFormatter()
  formatter.locale = Locale.current
  formatter.unitsStyle = .full
  return formatter
}()

struct VoiceButton: View {
  @ObservedObject var monitor: Monitor
  var size: CGFloat = 14

  var body: some View {
    let on = monitor.activity != .off
    Button { monitor.toggleVoice() } label: {
      HStack(spacing: 5) {
        Image(systemName: on ? "mic.fill" : "mic.slash.fill")
        Text(on ? String(localized: "Voice on") : String(localized: "Voice off"))
      }
      .font(.system(size: size, weight: .semibold))
      .padding(.horizontal, size * 0.7)
      .padding(.vertical, size * 0.35)
      .background(Capsule().fill(on ? Color.green.opacity(0.25) : Color.primary.opacity(0.1)))
      .foregroundStyle(on ? Color.green : Color.secondary)
      .opacity(monitor.switching ? 0.5 : 1)
    }
    .buttonStyle(.plain)
    .help(on ? String(localized: "Turn voice mode off") : String(localized: "Turn voice mode on"))
  }
}

// Shown while the plugin reads: stops it, as "Claude Quiet" does ("Claude Continue" or its shortcut resumes it).
struct QuietButton: View {
  @ObservedObject var monitor: Monitor
  var size: CGFloat = 14

  var body: some View {
    if monitor.activity == .speaking {
      Button { monitor.quiet() } label: {
        HStack(spacing: 5) {
          Image(systemName: "stop.fill")
          Text("Stop reading")
        }
        .font(.system(size: size, weight: .semibold))
        .padding(.horizontal, size * 0.7)
        .padding(.vertical, size * 0.35)
        .background(Capsule().fill(Color.red.opacity(0.22)))
        .foregroundStyle(Color.red)
      }
      .buttonStyle(.plain)
      .help("Stop the reading, as \"Claude Quiet\" does")
    }
  }
}

struct SessionRow: View {
  let session: Session
  let speaking: Bool
  var detailed = false

  var body: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(speaking ? Color.cyan : session.working ? Color.green : Color.secondary.opacity(0.4))
        .frame(width: detailed ? 9 : 7, height: detailed ? 9 : 7)
      VStack(alignment: .leading, spacing: 1) {
        Text(session.title).font(.system(size: detailed ? 15 : 12)).lineLimit(1)
        if detailed {
          Text("\(session.project) · \(speaking ? String(localized: "speaking") : session.working ? String(localized: "working") : String(localized: "idle")) · \(relativeFormatter.localizedString(for: session.lastActivity, relativeTo: Date()))")
            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      Spacer(minLength: 4)
      if !detailed {
        Text(session.project).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
      }
    }
  }
}

func sectionTitle(_ title: String, size: CGFloat = 10) -> some View {
  Text(title.uppercased()).font(.system(size: size, weight: .semibold)).foregroundStyle(.secondary)
}

// MARK: - The panel: always the same size, the halo alone when reduced

let panelSize = CGSize(width: 340, height: 330)
let compactSize = CGSize(width: 46, height: 46)
let restingSize = CGSize(width: 340, height: 92) // at rest: the halo, the state and the buttons only
let restDelaySeconds: TimeInterval = 4 // quiet this long before folding back, not between two lines
let panelListRows = 6

struct PanelView: View {
  @ObservedObject var monitor: Monitor
  let compact: Bool
  let resting: Bool
  let toggleCompact: () -> Void
  let openFullScreen: () -> Void
  let openSettings: () -> Void

  var body: some View {
    Group {
      if compact {
        Halo(activity: monitor.activity).frame(width: 38, height: 38)
          .contentShape(Rectangle()).onTapGesture(perform: toggleCompact).help("Show the panel")
      } else {
        expanded
      }
    }
    .frame(width: compact ? compactSize.width : panelSize.width, height: compact ? compactSize.height : resting ? restingSize.height : panelSize.height, alignment: compact ? .center : .top)
    .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: compact ? 23 : 18, style: .continuous)))
  }

  private var expanded: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        Halo(activity: monitor.activity).frame(width: 64, height: 64)
          .contentShape(Rectangle()).onTapGesture(perform: toggleCompact).help("Reduce")
        VStack(alignment: .leading, spacing: 2) {
          Text(monitor.activity.label).font(.system(size: 13, weight: .semibold))
          Text(monitor.speakerTitle ?? " ").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 0)
        VStack(alignment: .trailing, spacing: 8) {
          HStack(spacing: 6) {
            QuietButton(monitor: monitor, size: 11)
            VoiceButton(monitor: monitor, size: 11)
          }
          HStack(spacing: 10) {
            Button(action: openSettings) { Image(systemName: "gearshape").font(.system(size: 12)) }
              .buttonStyle(.plain).foregroundStyle(.secondary).help("Settings and services")
            Button(action: toggleCompact) { Image(systemName: "circle.circle").font(.system(size: 12)) }
              .buttonStyle(.plain).foregroundStyle(.secondary).help("Reduce to the circle")
            Button(action: openFullScreen) { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 12)) }
              .buttonStyle(.plain).foregroundStyle(.secondary).help("Full screen")
          }
        }
      }
      if !resting { activePart.transition(.opacity) }
    }
    .padding(14)
  }

  @ViewBuilder private var activePart: some View {
    VStack(alignment: .leading, spacing: 12) {
      ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06))
        Text(monitor.line ?? placeholder(monitor.activity))
          .font(.system(size: 13))
          .foregroundStyle(monitor.line == nil ? .secondary : .primary)
          .lineLimit(5)
          .padding(10)
          .id(monitor.line ?? "")
          .transition(.opacity)
        if monitor.lineCount > 1 {
          Text("\(monitor.lineIndex + 1) / \(monitor.lineCount)").font(.system(size: 10)).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(6)
        }
      }
      .frame(height: 104)
      .animation(.easeInOut(duration: 0.3), value: monitor.line)

      VStack(alignment: .leading, spacing: 5) {
        let waiting = Array(monitor.waiting.prefix(2))
        if !waiting.isEmpty {
          sectionTitle(String(localized: "Waiting"))
          ForEach(waiting) { Label($0.title, systemImage: "hourglass").font(.system(size: 12)).lineLimit(1) }
        }
        sectionTitle(String(localized: "Sessions"))
        if monitor.sessions.isEmpty {
          Text("No recent session.").font(.system(size: 12)).foregroundStyle(.tertiary)
        }
        ForEach(monitor.sessions.prefix(max(panelListRows - waiting.count * 2, 2))) {
          SessionRow(session: $0, speaking: $0.id == monitor.speakerSession)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .clipped()
    }
  }
}

// MARK: - Full screen: the whole reply, the queue and the sessions in detail

struct FullView: View {
  @ObservedObject var monitor: Monitor
  let close: () -> Void
  let openSettings: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 48) {
      VStack(spacing: 18) {
        Halo(activity: monitor.activity).frame(width: 300, height: 300)
        Text(monitor.activity.label).font(.system(size: 30, weight: .semibold))
        Text(monitor.speakerTitle ?? monitor.linesTitle ?? " ").font(.system(size: 18)).foregroundStyle(.secondary).lineLimit(1)
        reply
      }
      .frame(maxWidth: .infinity)

      VStack(alignment: .leading, spacing: 14) {
        HStack {
          VoiceButton(monitor: monitor, size: 15)
          QuietButton(monitor: monitor, size: 15)
          Spacer()
          Button(action: openSettings) { Image(systemName: "gearshape").font(.system(size: 20)) }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Settings and services")
          Button(action: close) { Image(systemName: "xmark.circle.fill").font(.system(size: 22)) }
            .buttonStyle(.plain).foregroundStyle(.secondary).keyboardShortcut(.cancelAction).help("Leave full screen (Esc)")
        }
        if !monitor.waiting.isEmpty {
          sectionTitle(String(localized: "Waiting"), size: 12).padding(.top, 8)
          ForEach(monitor.waiting) { Label($0.title, systemImage: "hourglass").font(.system(size: 15)).lineLimit(1) }
        }
        sectionTitle(String(localized: "Sessions"), size: 12).padding(.top, 8)
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(monitor.sessions) { SessionRow(session: $0, speaking: $0.id == monitor.speakerSession, detailed: true) }
          }
        }
      }
      .frame(width: 380)
    }
    .padding(48)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(white: 0.06))
    .environment(\.colorScheme, .dark)
  }

  private var reply: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if monitor.lines.isEmpty {
            Text(monitor.line ?? placeholder(monitor.activity)).font(.system(size: 22)).foregroundStyle(.secondary)
          }
          ForEach(Array(monitor.lines.enumerated()), id: \.offset) { index, text in
            Text(text)
              .font(.system(size: 22))
              .foregroundStyle(.primary)
              .opacity(monitor.activity == .speaking && index == monitor.lineIndex ? 1 : 0.35)
              .id(index)
          }
        }
        .frame(maxWidth: 820, alignment: .leading)
        .padding(.vertical, 8)
      }
      .onChange(of: monitor.lineIndex) { _, index in
        withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(index, anchor: .center) }
      }
    }
  }
}

struct VisualEffect: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .hudWindow
    view.blendingMode = .behindWindow
    view.state = .active
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// The panel is never the key window: its buttons must answer the first click.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// A panel that floats over everything, full-screen apps included, and never takes the focus.
final class FloatingPanel: NSPanel {
  init(content: NSView) {
    super.init(contentRect: NSRect(origin: .zero, size: panelSize),
               styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
    isFloatingPanel = true
    level = .statusBar
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    isMovableByWindowBackground = true
    backgroundColor = .clear
    isOpaque = false
    hasShadow = true
    hidesOnDeactivate = false
    contentView = content
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}
