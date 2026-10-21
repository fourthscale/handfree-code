// Cloud sessions: the bridge, the tunnel (any provider: the app only runs the command it is given, and checks the public
// address end to end), and the values to give claude.ai, shown only after Touch ID or the session's password.
// The work is install-bridge.sh's, from the stable copy: /handfree-code:bridge runs the same script.
import LocalAuthentication
import SwiftUI

let bridgeScript = "\(supportDir)/install-bridge.sh"
let cloudSetupLine = "curl -fsSL https://raw.githubusercontent.com/fourthscale/handfree-code/main/bin/cloud-setup.sh | bash"

final class Cloud: ObservableObject {
  @Published var busy = false
  @Published var message: String?
  @Published var check: Int32?
  @Published var revealed = false
  private var hideLater: DispatchWorkItem?

  var scriptInstalled: Bool { FileManager.default.fileExists(atPath: bridgeScript) }

  // install-bridge.sh with its options; then the services' state and the address are checked again.
  func runScript(_ arguments: [String], services: Services, then: (() -> Void)? = nil) {
    busy = true
    message = nil
    DispatchQueue.global().async {
      let result = run("/bin/sh", [bridgeScript] + arguments)
      DispatchQueue.main.async {
        self.busy = false
        if result.status != 0 { self.message = result.output.trimmingCharacters(in: .whitespacesAndNewlines) }
        services.refresh()
        then?()
      }
    }
  }

  func checkAddress() {
    check = nil
    busy = true
    DispatchQueue.global().async {
      let status = run("/bin/sh", [bridgeScript, "--check"]).status
      DispatchQueue.main.async {
        self.busy = false
        self.check = status
      }
    }
  }

  // The keys are the user's alone: Touch ID or the session's password first, as for a saved password.
  func unlock(_ reason: String, then: @escaping () -> Void) {
    let context = LAContext()
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
      message = String(localized: "This Mac cannot ask for Touch ID or your password now: the keys stay hidden.") + (error.map { " (\($0.localizedDescription))" } ?? "")
      return
    }
    context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { granted, _ in
      if granted { DispatchQueue.main.async(execute: then) }
    }
  }

  func reveal() {
    unlock(String(localized: "show the keys of the bridge for cloud sessions")) {
      self.revealed = true
      // Hidden again after a minute (from the last time shown).
      self.hideLater?.cancel()
      let hide = DispatchWorkItem { self.revealed = false }
      self.hideLater = hide
      DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: hide)
    }
  }

  // Marked concealed, so clipboard managers do not keep it, and taken off the clipboard after a minute unless
  // something else was copied since.
  func copy(_ text: String) {
    unlock(String(localized: "copy a key of the bridge for cloud sessions")) {
      let board = NSPasteboard.general
      board.clearContents()
      board.setString(text, forType: .string)
      board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
      let copied = board.changeCount
      DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
        if board.changeCount == copied { board.clearContents() }
      }
    }
  }
}

// install-bridge.sh --check's exit codes, in the interface's language.
func checkVerdict(_ status: Int32) -> String {
  switch status {
  case 0: return String(localized: "The public address reaches this Mac's bridge.")
  case 2: return String(localized: "Set up the bridge and the public address first.")
  case 3: return String(localized: "The public address cannot be reached: is the tunnel running, and the address right?")
  case 4: return String(localized: "The tunnel provider refuses the request: check its rule on the X-Handfree-Key header.")
  case 5: return String(localized: "A bridge answered but refused the token: another Mac's, or this one not restarted since new keys.")
  default: return String(format: String(localized: "The address answers, but not as this bridge: is the tunnel pointed at %@?"), bridgeAddress())
  }
}

struct CloudView: View {
  @ObservedObject var services: Services
  @ObservedObject var settings: PluginSettings
  @StateObject private var cloud = Cloud()
  @State private var tunnelCommand = ""
  @State private var confirmNewKeys = false

  private var bridge: ServiceState { services.agents["com.handfree-code.bridge"] ?? ServiceState() }
  private var token: String { settings.values["bridge_token"] as? String ?? "" }
  private var edgeKey: String { settings.values["bridge_edge_key"] as? String ?? "" }
  private var address: String { settings.values["bridge_url"] as? String ?? "" }

  private var variables: String {
    "HANDFREE_BRIDGE_URL=\(address.isEmpty ? "https://…" : address)\nHANDFREE_BRIDGE_TOKEN=\(token)\nHANDFREE_BRIDGE_EDGE_KEY=\(edgeKey)"
  }

  var body: some View {
    Form {
      Section {
        Text("A cloud session runs far from this Mac. The bridge lets it speak and ask its questions here: it listens on this Mac only, and a tunnel, from the provider of your choice, gives it a public address.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if !cloud.scriptInstalled {
        Section {
          Text("Run /handfree-code:install in a Claude session first: it puts the bridge's script in place.").foregroundStyle(.orange)
        }
      }
      Section("1. The bridge") {
        HStack {
          StatusDot(on: bridge.pid != nil)
          Text(bridge.pid != nil ? String(localized: "running") : bridge.installed ? String(localized: "stopped") : String(localized: "not installed"))
          Spacer()
          if bridge.installed {
            Button("New keys") { confirmNewKeys = true }
          } else {
            Button("Set up the bridge") { cloud.runScript([], services: services) { settings.load() } }
          }
        }
        Text("Makes its two keys, and starts it with your session.").font(.caption).foregroundStyle(.secondary)
      }
      Section("2. The tunnel") {
        TextField("Command (optional)", text: $tunnelCommand, prompt: Text("cloudflared tunnel run handfree"))
        HStack {
          Text("Run with your session, whatever the provider. Empty: the tunnel runs on its own (its provider's service).").font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("Apply") {
            settings.set("tunnel_command", tunnelCommand.trimmingCharacters(in: .whitespaces).isEmpty ? nil : tunnelCommand.trimmingCharacters(in: .whitespaces))
            cloud.runScript([], services: services)
          }
          .disabled(!bridge.installed || tunnelCommand == (settings.values["tunnel_command"] as? String ?? ""))
        }
        TextField("Public address", text: settings.text("bridge_url"), prompt: Text("https://voice.example.com"))
        HStack {
          if let check = cloud.check {
            StatusDot(on: check == 0)
            Text(checkVerdict(check)).font(.caption)
          } else {
            Text("The tunnel's address, pointed at \(bridgeAddress()).").font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button("Check") { cloud.checkAddress() }.disabled(address.isEmpty || !bridge.installed)
        }
      }
      Section("3. claude.ai") {
        Text("In the cloud environment's settings: these environment variables, and this setup script.").font(.caption).foregroundStyle(.secondary)
        Text(cloud.revealed ? variables : "HANDFREE_BRIDGE_URL=\(address.isEmpty ? "https://…" : address)\nHANDFREE_BRIDGE_TOKEN=••••••••\nHANDFREE_BRIDGE_EDGE_KEY=••••••••")
          .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        HStack {
          Spacer()
          Button(cloud.revealed ? "Hide" : "Show") { if cloud.revealed { cloud.revealed = false } else { cloud.reveal() } }
          Button("Copy the variables") { cloud.copy(variables) }
        }
        .disabled(token.isEmpty)
        Text(cloudSetupLine).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        HStack {
          Spacer()
          Button("Copy the setup script") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cloudSetupLine, forType: .string)
          }
        }
        Text("If your provider can require a header before a request reaches this Mac (Cloudflare's WAF rules, say), make it require X-Handfree-Key with the edge key. README: Cloud sessions.")
          .font(.caption).foregroundStyle(.secondary)
        HStack {
          Spacer()
          Button("Copy the edge key") { cloud.copy(edgeKey) }.disabled(edgeKey.isEmpty)
        }
      }
      if cloud.busy { ProgressView().controlSize(.small) }
      if let message = cloud.message {
        Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
      }
    }
    .formStyle(.grouped)
    .disabled(!cloud.scriptInstalled)
    .onAppear {
      settings.load()
      tunnelCommand = settings.values["tunnel_command"] as? String ?? ""
      services.refresh()
    }
    .onDisappear { cloud.revealed = false }
    .alert("New keys?", isPresented: $confirmNewKeys) {
      Button("New keys", role: .destructive) { cloud.runScript(["--new-keys"], services: services) { settings.load(); cloud.revealed = false } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The bridge restarts with them. Give them again to claude.ai, and to your provider's rule: until then, cloud sessions stay silent.")
    }
  }
}
