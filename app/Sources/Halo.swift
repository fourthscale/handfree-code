// The halo: the animated circle that shows the plugin's activity, and the app's icon drawn from it.
import AppKit
import SwiftUI

// MARK: - The halo

// A "fake" halo: blurred blobs turning and breathing, livelier as the state asks for more energy.
struct Halo: View {
  let activity: Activity
  @State private var energy: Double = 0.15

  var body: some View {
    TimelineView(.animation) { timeline in
      let t = timeline.date.timeIntervalSinceReferenceDate
      Canvas { context, size in Halo.draw(&context, size, t: t, energy: energy, colors: activity.colors) }
      .overlay(
        Circle()
          .fill(.white.opacity(activity == .off ? 0.15 : 0.35))
          .frame(width: 10 + energy * 6, height: 10 + energy * 6)
          .blur(radius: 3)
      )
    }
    .onAppear { energy = activity.energy }
    .onChange(of: activity) { _, value in
      withAnimation(.easeInOut(duration: 0.8)) { energy = value.energy }
    }
  }

  static func draw(_ context: inout GraphicsContext, _ size: CGSize, t: Double, energy: Double, colors: [Color]) {
    let center = CGPoint(x: size.width / 2, y: size.height / 2)
    let base = min(size.width, size.height) * 0.26
    // A voice-like flutter: several sines at unrelated speeds.
    let flutter = (sin(t * 7.3) + sin(t * 11.1 + 1.3) * 0.6 + sin(t * 17.7 + 0.4) * 0.35) / 1.95
    let breath = sin(t * 1.6) * 0.5 + 0.5
    context.addFilter(.blur(radius: base * 0.35))
    for (index, color) in colors.enumerated() {
      let phase = Double(index) * 2.1
      let angle = t * (0.6 + energy * 1.4) + phase
      let wobble = base * (0.18 + energy * 0.22) * (1 + sin(t * 2.3 + phase) * 0.5)
      let radius = base * (0.85 + breath * 0.12 + energy * 0.25 * (0.6 + flutter * 0.8) + Double(index) * 0.05)
      let point = CGPoint(x: center.x + cos(angle) * wobble, y: center.y + sin(angle * 1.2) * wobble)
      let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
      context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.75)))
    }
  }
}

// The app's icon: the halo of a reading, still, on a dark tile. Drawn by the app itself at build (`--render-icon`).
struct AppIcon: View {
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 185, style: .continuous)
        .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.05)], startPoint: .top, endPoint: .bottom))
        .frame(width: 824, height: 824)
      Canvas { context, size in Halo.draw(&context, size, t: 2.2, energy: 0.8, colors: Activity.speaking.colors) }
        .frame(width: 620, height: 620)
      Circle().fill(.white.opacity(0.5)).frame(width: 110, height: 110).blur(radius: 30)
    }
    .frame(width: 1024, height: 1024)
  }
}

@MainActor func renderIcon(to path: String) -> Bool {
  let renderer = ImageRenderer(content: AppIcon())
  renderer.scale = 1
  guard let image = renderer.cgImage else { return false }
  let rep = NSBitmapImageRep(cgImage: image)
  guard let data = rep.representation(using: .png, properties: [:]) else { return false }
  return FileManager.default.createFile(atPath: path, contents: data)
}
