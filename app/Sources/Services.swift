// The Services tab: what runs in the background (the listener, the bridge, the tunnel), through launchd as the
// plugin's installers set it up, started and stopped from here.
import AppKit
import SwiftUI

let uid = getuid()

@discardableResult
func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: path)
  process.arguments = arguments
  // One pipe for both: an error shows what went wrong, and an unread stderr cannot fill up and block the program.
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = pipe
  do { try process.run() } catch { return (-1, "") }
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

struct Agent {
  let name: String
  let label: String
  let log: String
  let about: String
  var plist: String { "\(home)/Library/LaunchAgents/\(label).plist" }
}

let pluginAgents = [
  Agent(name: String(localized: "Listener"), label: "com.handfree-code.listener", log: "\(home)/Library/Logs/handfree-listener.log",
        about: String(localized: "The spoken commands (“claude listen”…). Voice mode off stops it.")),
  Agent(name: String(localized: "Bridge"), label: "com.handfree-code.bridge", log: "\(home)/Library/Logs/handfree-bridge.log",
        about: String(localized: "Receives the cloud sessions through the tunnel.")),
  Agent(name: String(localized: "Tunnel"), label: "com.handfree-code.tunnel", log: "\(home)/Library/Logs/handfree-tunnel.log",
        about: String(localized: "Runs the tunnel's command (Cloud sessions), when one is set; otherwise the tunnel runs on its own.")),
]

struct ServiceState: Equatable {
  var installed = false
  var pid: Int?
}

final class Services: ObservableObject {
  @Published var agents: [String: ServiceState] = [:]
  @Published var dictationServing = false
  @Published var relayDeclared = false
  @Published var busy: String?

  func declareRelay() {
    busy = "relay"
    DispatchQueue.global().async {
      declareMCPServer()
      DispatchQueue.main.async {
        self.busy = nil
        self.refresh()
      }
    }
  }

  func refresh() {
    DispatchQueue.global().async {
      var found: [String: ServiceState] = [:]
      for agent in pluginAgents {
        var state = ServiceState(installed: FileManager.default.fileExists(atPath: agent.plist))
        let listed = run("/bin/launchctl", ["list", agent.label])
        if listed.status == 0, let match = listed.output.range(of: #""PID" = (\d+);"#, options: .regularExpression) {
          state.pid = Int(listed.output[match].filter(\.isNumber))
        }
        found[agent.label] = state
      }
      DispatchQueue.main.async {
        self.agents = found
        self.dictationServing = DictationServer.shared.serving
        self.relayDeclared = relayIsDeclared()
      }
    }
  }

  func act(_ agent: Agent, _ action: String) {
    busy = agent.label
    DispatchQueue.global().async {
      let domain = "gui/\(uid)"
      let loaded = run("/bin/launchctl", ["list", agent.label]).status == 0
      switch action {
      case "stop": run("/bin/launchctl", ["bootout", "\(domain)/\(agent.label)"])
      case "restart" where loaded: run("/bin/launchctl", ["kickstart", "-k", "\(domain)/\(agent.label)"])
      default:
        if loaded { run("/bin/launchctl", ["kickstart", "\(domain)/\(agent.label)"]) } else { run("/bin/launchctl", ["bootstrap", domain, agent.plist]) }
      }
      Thread.sleep(forTimeInterval: 0.8)
      DispatchQueue.main.async {
        self.busy = nil
        self.refresh()
      }
    }
  }
}


struct StatusDot: View {
  let on: Bool
  var body: some View { Circle().fill(on ? Color.green : Color.red.opacity(0.8)).frame(width: 9, height: 9) }
}

struct ServicesView: View {
  @ObservedObject var services: Services
  @ObservedObject var monitor: Monitor

  var body: some View {
    Form {
      Section {
        HStack {
          StatusDot(on: monitor.activity != .off)
          Text("Voice mode").font(.headline)
          Spacer()
          VoiceButton(monitor: monitor, size: 12)
        }
      }
      Section("Services") {
        ForEach(pluginAgents, id: \.label) { agent in
          let state = services.agents[agent.label] ?? ServiceState()
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              StatusDot(on: state.pid != nil)
              Text(agent.name).font(.headline)
              Text(state.pid != nil ? String(localized: "running") : state.installed ? String(localized: "stopped") : String(localized: "not installed")).foregroundStyle(.secondary)
              Spacer()
              if state.installed {
                if state.pid == nil {
                  Button("Start") { services.act(agent, "start") }
                } else {
                  Button("Restart") { services.act(agent, "restart") }
                  Button("Stop") { services.act(agent, "stop") }
                }
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: agent.log)) } label: { Image(systemName: "doc.text") }.help("Log")
              }
            }
            .disabled(services.busy == agent.label)
            Text(agent.about).font(.caption).foregroundStyle(.secondary)
          }
          .padding(.vertical, 2)
        }
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            StatusDot(on: services.dictationServing)
            Text("Dictation and questions").font(.headline)
            Text(services.dictationServing ? String(localized: "ready") : String(localized: "port 51290 taken by another program")).foregroundStyle(.secondary)
          }
          HStack {
            StatusDot(on: services.relayDeclared)
            Text("Claude's questions (MCP)").font(.headline)
            Text(services.relayDeclared ? String(localized: "declared") : String(localized: "not declared")).foregroundStyle(.secondary)
            Spacer()
            if !services.relayDeclared {
              Button("Declare") { services.declareRelay() }
            }
          }
          Text("Sessions opened after the change use it.").font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .task {
      while !Task.isCancelled {
        services.refresh()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
      }
    }
  }
}
