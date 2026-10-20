// Handfree Code: the app's entry point and its windows (the floating panel, full screen, the settings), with the
// startup and the menu-bar icon. What it shows comes from StateMonitor.swift; the dictation is Dictation.swift's.
import AppKit
import SwiftUI

// MARK: - The app

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  let monitor = Monitor()
  var panel: FloatingPanel!
  var hosting: FirstClickHostingView<PanelView>!
  var fullWindow: NSWindow?
  var settingsWindow: NSWindow?
  let services = Services()
  let settings = PluginSettings()
  var statusItem: NSStatusItem!
  var timer: Timer?
  // The panel shows one of three sizes: the whole panel (the plugin active: reading, a dictation, a question), resting
  // (only the halo, the state and the buttons, once quiet for restDelaySeconds), or the circle alone (`compact`, the
  // discreet mode, folded whenever at rest and unfolded while active). Activity unfolds it, quiet folds it back; a
  // click on the unfolded circle folds it at once (`dismissed`) until the next rest.
  var topRight = NSPoint.zero // the corner that stays put: the circle sits where the panel's top right corner is
  var compact = UserDefaults.standard.bool(forKey: "compact") // the discreet mode: the circle, unfolded only while active
  var resting = true
  var dismissed = false // the circle was clicked while unfolded: it stays folded until the next rest
  var placing = false // the app is moving the panel itself: not a move by hand, which sets the corner
  var lastActive = Date.distantPast

  func applicationDidFinishLaunching(_ notification: Notification) {
    hosting = FirstClickHostingView(rootView: panelView())
    hosting.sizingOptions = []
    panel = FloatingPanel(content: hosting)
    if let saved = UserDefaults.standard.string(forKey: "topRight") {
      topRight = NSPointFromString(saved)
    } else if let screen = NSScreen.main {
      topRight = NSPoint(x: screen.visibleFrame.maxX - 16, y: screen.visibleFrame.maxY - 12)
    }
    placePanel()
    NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
      guard let self, !self.placing else { return } // only a move by hand sets the corner
      self.topRight = NSPoint(x: self.panel.frame.maxX, y: self.panel.frame.maxY)
      UserDefaults.standard.set(NSStringFromPoint(self.topRight), forKey: "topRight")
    }
    if !UserDefaults.standard.bool(forKey: "hidden") { panel.orderFrontRegardless() }

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    updateStatusIcon()
    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: String(localized: "Show / hide"), action: #selector(toggle), keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: String(localized: "Full screen"), action: #selector(openFullScreen), keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: String(localized: "Voice mode on / off"), action: #selector(toggleVoice), keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: String(localized: "Stop reading"), action: #selector(quiet), keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: String(localized: "Settings and services…"), action: #selector(openSettings), keyEquivalent: ","))
    menu.addItem(NSMenuItem(title: String(localized: "Try a dictation"), action: #selector(tryDictation), keyEquivalent: ""))
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: String(localized: "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    statusItem.menu = menu

    NSApp.mainMenu = mainMenu()

    WhisperModels.shared.preload()
    _ = appSecret // made before anyone may ask for it
    DictationServer.shared.start()
    AudioFeed.shared.start()
    HotKeys.shared.register()
    askAccessibility() // to paste into Claude when its field is out of reach
    monitor.refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      guard let self else { return }
      self.monitor.refresh()
      self.updateResting()
      self.updateStatusIcon()
    }
    checkListener()
    Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.checkListener() }
  }

  var showsCircle: Bool { compact && (resting || dismissed) }

  func panelView() -> PanelView {
    PanelView(monitor: monitor, compact: showsCircle, resting: !compact && resting,
              toggleCompact: { [weak self] in self?.toggleCompact() },
              openFullScreen: { [weak self] in self?.openFullScreen() },
              openSettings: { [weak self] in self?.openSettings() })
  }

  func currentSize() -> CGSize {
    showsCircle ? compactSize : resting && !compact ? restingSize : panelSize
  }

  // Speaking, listening or asking: unfolded; quiet for a few seconds: folded again (the circle, or the panel's header).
  func updateResting() {
    let active = [.speaking, .dictating, .question].contains(monitor.activity)
    if active { lastActive = Date() }
    let value = !active && Date().timeIntervalSince(lastActive) > restDelaySeconds
    guard value != resting else { return }
    let before = currentSize()
    resting = value
    if resting { dismissed = false }
    guard currentSize() != before else { return }
    refreshPanel()
  }

  func refreshPanel() {
    let growing = currentSize().height > panel.frame.height
    if growing { placePanel(animated: true) }
    withAnimation(.easeInOut(duration: 0.3)) { hosting.rootView = panelView() }
    if !growing { placePanel(animated: true) }
  }

  // Anchored at its top right corner, and always whole on the screen it is on.
  func placePanel(animated: Bool = false) {
    let size = currentSize()
    let screen = NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(topRight) } ?? NSScreen.main
    var frame = NSRect(x: topRight.x - size.width, y: topRight.y - size.height, width: size.width, height: size.height)
    if let visible = screen?.visibleFrame {
      frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - size.width)
      frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - size.height)
    }
    placing = true
    if animated {
      NSAnimationContext.runAnimationGroup({ context in
        context.duration = 0.3
        panel.animator().setFrame(frame, display: true)
      }, completionHandler: { [weak self] in self?.placing = false })
    } else {
      panel.setFrame(frame, display: true)
      placing = false
    }
  }

  // A click on the halo: the circle opens to the panel; the panel, or a circle unfolded while active, goes back to the circle.
  func toggleCompact() {
    if compact && !showsCircle {
      dismissed = true
    } else {
      compact.toggle()
      dismissed = false
      UserDefaults.standard.set(compact, forKey: "compact")
    }
    refreshPanel()
  }

  @objc func toggle() {
    if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    UserDefaults.standard.set(!panel.isVisible, forKey: "hidden")
  }

  @objc func toggleVoice() { monitor.toggleVoice() }

  @objc func quiet() { monitor.quiet() }

  @objc func tryDictation() { DictationController.shared.start() }

  // MARK: The menu bar icon, a status light: the symbol says what happens, the dot that someone waits.

  var listenerRunning = false
  var iconKey = ""

  func checkListener() {
    DispatchQueue.global().async {
      let listed = run("/bin/launchctl", ["list", "com.handfree-code.listener"])
      let running = listed.status == 0 && listed.output.contains("\"PID\" =")
      DispatchQueue.main.async { self.listenerRunning = running }
    }
  }

  func updateStatusIcon() {
    let (symbol, dot): (String, NSColor?) = {
      switch monitor.activity {
      case .off: return ("mic.slash", nil)
      case .speaking: return ("waveform", nil)
      case .dictating: return ("mic.fill", .systemRed)
      case .question: return ("mic.fill", .systemOrange)
      case .idle: return ("mic", listenerRunning ? .systemGreen : nil)
      }
    }()
    let key = "\(symbol)-\(dot?.description ?? "")"
    guard key != iconKey, let button = statusItem?.button else { return }
    iconKey = key
    button.image = statusImage(symbol: symbol, dot: dot)
    button.toolTip = "Handfree Code: \(monitor.activity.label)"
  }

  func statusImage(symbol: String, dot: NSColor?) -> NSImage {
    let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
    let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "Handfree Code")?.withSymbolConfiguration(configuration) ?? NSImage()
    guard let dot else {
      base.isTemplate = true // follows the menu bar's light or dark look
      return base
    }
    let size = NSSize(width: base.size.width + 4, height: max(base.size.height, 16))
    // Drawn when shown, so the symbol takes the menu bar's text color; the dot keeps its own.
    return NSImage(size: size, flipped: false) { rect in
      let symbolRect = NSRect(x: 0, y: (rect.height - base.size.height) / 2, width: base.size.width, height: base.size.height)
      let tinted = NSImage(size: base.size, flipped: false) { inner in
        base.draw(in: inner)
        NSColor.labelColor.set()
        inner.fill(using: .sourceAtop)
        return true
      }
      tinted.draw(in: symbolRect)
      let diameter: CGFloat = 6
      let dotRect = NSRect(x: rect.width - diameter, y: rect.height - diameter - 1, width: diameter, height: diameter)
      dot.setFill()
      NSBezierPath(ovalIn: dotRect).fill()
      return true
    }
  }

  // Shown while the settings are open: closing the window, and the editing keys of the text fields (⌘V for a key).
  private func mainMenu() -> NSMenu {
    let main = NSMenu()
    let appMenu = NSMenu()
    appMenu.addItem(NSMenuItem(title: String(localized: "Hide Handfree Code"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
    appMenu.addItem(NSMenuItem(title: String(localized: "Close the window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
    let edit = NSMenu(title: String(localized: "Edit"))
    edit.addItem(NSMenuItem(title: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z"))
    edit.addItem(NSMenuItem(title: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "Z"))
    edit.addItem(.separator())
    edit.addItem(NSMenuItem(title: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
    edit.addItem(NSMenuItem(title: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
    edit.addItem(NSMenuItem(title: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
    edit.addItem(NSMenuItem(title: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
    for (title, menu) in [("Handfree Code", appMenu), (String(localized: "Edit"), edit)] {
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      item.submenu = menu
      main.addItem(item)
    }
    return main
  }

  @objc func openSettings() {
    if settingsWindow == nil {
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
      window.title = "Handfree Code"
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: ControlCenterView(services: services, monitor: monitor, settings: settings))
      window.center()
      window.delegate = self
      settingsWindow = window
    }
    // A Dock icon while the settings are open: the window is then a real one, given the keyboard, in ⌘Tab.
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    settingsWindow?.makeKeyAndOrderFront(nil)
  }

  @objc func openFullScreen() {
    if let fullWindow { fullWindow.makeKeyAndOrderFront(nil); return }
    let window = NSWindow(contentRect: NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1200, height: 800),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.collectionBehavior = [.fullScreenPrimary]
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: FullView(monitor: monitor, close: { [weak self] in self?.closeFullScreen() },
                                                            openSettings: { [weak self] in self?.closeFullScreen(); self?.openSettings() }))
    window.delegate = self
    fullWindow = window
    panel.orderOut(nil)
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.toggleFullScreen(nil)
  }

  func closeFullScreen() {
    guard let window = fullWindow else { return }
    if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) } else { window.close() }
  }

  func windowDidExitFullScreen(_ notification: Notification) { fullWindow?.close() }

  func windowWillClose(_ notification: Notification) {
    if (notification.object as? NSWindow) === settingsWindow { NSApp.setActivationPolicy(.accessory); return }
    fullWindow = nil
    if !UserDefaults.standard.bool(forKey: "hidden") { panel.orderFrontRegardless() }
  }
}

MainActor.assumeIsolated {
  if let index = CommandLine.arguments.firstIndex(of: "--render-icon"), index + 1 < CommandLine.arguments.count {
    exit(renderIcon(to: CommandLine.arguments[index + 1]) ? 0 : 1)
  }
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  app.setActivationPolicy(.accessory)
  app.run()
}
