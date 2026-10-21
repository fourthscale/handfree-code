// The app's local address (localhost:51290), where the plugin, the cloud bridge and Claude's `handfree` MCP server
// (bin/mcp-relay.sh) reach the dictation: questions (`ask_user_dictation`), and text dictated into the field in front
// (`dictation/insert`, when Claude's field cannot be reached through accessibility).
import AppKit
import Network
import Security

let serverPort: NWEndpoint.Port = 51290
let skipped = "(skipped by user)"

@MainActor
final class DictationServer: ObservableObject {
  static let shared = DictationServer()
  @Published var serving = false
  private var listener: NWListener?
  private var timer: Timer?

  func start() {
    open()
    // Taken by another program, or dropped: try again now and then.
    timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
      Task { @MainActor in if DictationServer.shared.listener == nil { DictationServer.shared.open() } }
    }
  }

  private func open() {
    let parameters = NWParameters.tcp
    parameters.acceptLocalOnly = true
    parameters.allowLocalEndpointReuse = true
    guard let listener = try? NWListener(using: parameters, on: serverPort) else { return }
    listener.newConnectionHandler = { connection in Task { @MainActor in Exchange(connection).start() } }
    listener.stateUpdateHandler = { state in
      Task { @MainActor in
        switch state {
        case .ready: DictationServer.shared.serving = true
        case .failed, .cancelled:
          DictationServer.shared.listener?.cancel()
          DictationServer.shared.listener = nil
          DictationServer.shared.serving = false
        default: break
        }
      }
    }
    self.listener = listener
    listener.start(queue: .main)
  }
}

// One HTTP request, JSON-RPC inside (MCP for the tools, and the plugin's own `dictation/insert`).
// Only local programs reach it, but a web page may send it a request too: one with an Origin header, or a Host other
// than this address, is refused; `keys/press` and `dictation/insert` need the app's secret as well.
@MainActor
final class Exchange {
  private let connection: NWConnection
  private var received = Data()
  private var secretGiven = false
  private static var open: [ObjectIdentifier: Exchange] = [:]
  private static let maxBody = 1_000_000
  private static let hosts: Set<String> = ["localhost:\(serverPort)", "127.0.0.1:\(serverPort)", "[::1]:\(serverPort)"]

  init(_ connection: NWConnection) { self.connection = connection }

  func start() {
    Exchange.open[ObjectIdentifier(self)] = self
    connection.start(queue: .main)
    read()
  }

  private func read() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
      let exchange = self
      Task { @MainActor in
        guard let self = exchange else { return }
        if let data { self.received += data }
        switch self.parsed() {
        case let .refused(status): return self.respond(status: status, json: nil)
        case let .request(body): return self.handle(body)
        case .incomplete:
          if complete || error != nil { return self.finish() }
          self.read()
        }
      }
    }
  }

  private enum Parsed { case incomplete, request(Data), refused(String) }

  // The request once it has all arrived (by Content-Length), or why it is refused.
  private func parsed() -> Parsed {
    guard let end = received.range(of: Data("\r\n\r\n".utf8)) else {
      return received.count > 65_536 ? .refused("431 Request Header Fields Too Large") : .incomplete
    }
    var headers: [String: String] = [:]
    for line in String(decoding: received[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n").dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    guard headers["origin"] == nil, let host = headers["host"], Exchange.hosts.contains(host.lowercased()) else { return .refused("403 Forbidden") }
    guard let length = Int(headers["content-length"] ?? "0"), (0...Exchange.maxBody).contains(length) else { return .refused("413 Content Too Large") }
    secretGiven = headers["x-handfree-secret"].map(isAppSecret) ?? false
    let body = received[end.upperBound...]
    return body.count >= length ? .request(Data(body.prefix(length))) : .incomplete
  }

  private func handle(_ body: Data) {
    Task { @MainActor in
      guard let message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
        return self.respond(status: "400 Bad Request", json: nil)
      }
      guard let id = message["id"] else { return self.respond(status: "202 Accepted", json: nil) } // a notification
      let method = message["method"] as? String ?? ""
      if ["keys/press", "dictation/insert"].contains(method), !self.secretGiven { return self.respond(status: "403 Forbidden", json: nil) }
      let params = message["params"] as? [String: Any] ?? [:]
      var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
      switch method {
      case "initialize":
        reply["result"] = ["serverInfo": ["name": "handfree", "version": appVersion], "protocolVersion": "2025-11-25", "capabilities": ["tools": [:]]]
      case "tools/list":
        reply["result"] = ["tools": [askTool]]
      case "tools/call" where params["name"] as? String == "ask_user_dictation" && DictationController.shared.isBusy:
        // Another question (another session, a cloud one) or a dictation is being spoken: refused, never cut short.
        reply["error"] = ["code": -32002, "message": "Another dictation is under way: ask again once it is over."]
      case "tools/call" where params["name"] as? String == "ask_user_dictation":
        let questions = ((params["arguments"] as? [String: Any])?["questions"] as? [String]) ?? []
        var parts: [String] = []
        for question in questions.isEmpty ? [""] : questions {
          let answer = await DictationController.shared.ask(question)
          parts.append("Q: \(question)\nA: \(answer.flatMap { $0.isEmpty ? nil : $0 } ?? skipped)")
        }
        reply["result"] = ["content": [["type": "text", "text": parts.joined(separator: "\n\n")]]]
      case "dictation/insert":
        // Answered at once: the plugin goes on while the user speaks.
        DictationController.shared.dictateIntoFront(send: params["send"] as? Bool ?? true)
        reply["result"] = ["started": true]
      case "keys/press":
        // The listener's "Stop" and "Cancel": Return or Escape to the app in front, with this app's Accessibility.
        guard AXIsProcessTrusted() else { reply["error"] = ["code": -32001, "message": "No Accessibility permission"]; break }
        pressKey(params["key"] as? String == "escape" ? 53 : 36)
        reply["result"] = ["pressed": true]
      default:
        reply["error"] = ["code": -32000, "message": "Unknown method: \(method)"]
      }
      self.respond(status: "200 OK", json: reply)
    }
  }

  private func respond(status: String, json: [String: Any]?) {
    let body = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
    var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
    if json != nil { head += "Content-Type: application/json\r\n" }
    connection.send(content: Data((head + "\r\n").utf8) + body, completion: .contentProcessed { [weak self] _ in
      let exchange = self
      Task { @MainActor in exchange?.finish() }
    })
  }

  private func finish() {
    connection.cancel()
    Exchange.open[ObjectIdentifier(self)] = nil
  }
}

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

let askTool: [String: Any] = [
  "name": "ask_user_dictation",
  "description": "Voice dictation on the user's Mac (Handfree Code). This is the user's PREFERRED default way to communicate. Call this tool by default whenever awaiting any user input. Each question starts a separate recording session. The user presses Enter after speaking, or Escape to skip.",
  "inputSchema": [
    "type": "object",
    "required": ["questions"],
    "properties": ["questions": ["type": "array", "items": ["type": "string"], "description": "Questions to display to the user so they know what to say"]],
  ],
]

// MARK: - Keys and text sent to the app in front (both need Accessibility)

func pressKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
  for down in [true, false] {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
    event?.flags = flags
    event?.post(tap: .cghidEventTap)
  }
}

// The text in the field in front, through the clipboard, which gets its contents back afterwards.
func paste(_ text: String, send: Bool) {
  let board = NSPasteboard.general
  let saved = (board.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
  board.clearContents()
  board.setString(text, forType: .string)
  pressKey(9, flags: .maskCommand) // V
  DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
    if send { pressKey(36) } // Return
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
      board.clearContents()
      let items = saved.map { pairs -> NSPasteboardItem in
        let item = NSPasteboardItem()
        for (type, data) in pairs { item.setData(data, forType: type) }
        return item
      }
      if !items.isEmpty { board.writeObjects(items) }
    }
  }
}

// The plugin's own command line (its copy that survives updates).
let pluginScript = "\(supportDir)/handfree.js"

func tellPlugin(_ flag: String) {
  DispatchQueue.global().async { run("/usr/bin/osascript", ["-l", "JavaScript", pluginScript, flag]) }
}

func askAccessibility() {
  let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
  _ = AXIsProcessTrustedWithOptions(prompt)
}

// MARK: - Claude's `handfree` MCP server: the plugin's relay, declared for the user's sessions

let relayPath = "\(supportDir)/mcp-relay.sh"

func relayIsDeclared() -> Bool {
  guard let data = FileManager.default.contents(atPath: "\(home)/.claude.json"),
    let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
    let server = (config["mcpServers"] as? [String: Any])?["handfree"] as? [String: Any]
  else { return false }
  return (server["args"] as? [String])?.contains(relayPath) == true || server["command"] as? String == relayPath
}

// The relay is the plugin's, in its stable copy. The app brings one too (copied from the plugin when it was built), put
// there only when none is: the plugin's own copy may be newer than the app's build.
func declareMCPServer() {
  if !FileManager.default.fileExists(atPath: relayPath), let bundled = Bundle.main.path(forResource: "mcp-relay", ofType: "sh") {
    try? FileManager.default.createDirectory(atPath: (relayPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? FileManager.default.copyItem(atPath: bundled, toPath: relayPath)
  }
  // The last line: a login shell's profile may print something first.
  let claude = run("/bin/zsh", ["-lc", "command -v claude"]).output.split(separator: "\n").last.map(String.init) ?? ""
  guard claude.hasPrefix("/") else { return }
  run(claude, ["mcp", "remove", "--scope", "user", "handfree"])
  let server: [String: Any] = ["type": "stdio", "command": "/bin/sh", "args": [relayPath], "timeout": 120000]
  guard let data = try? JSONSerialization.data(withJSONObject: server, options: [.withoutEscapingSlashes]) else { return }
  run(claude, ["mcp", "add-json", "--scope", "user", "handfree", String(decoding: data, as: UTF8.self)])
}

// MARK: - The app's secret: the listener and the plugin show it to be heard (the microphone's sound, keys pressed, text
// pasted). Any program of this user may read it, as it may read the user's files; a web page may not.

let appSecretPath = ProcessInfo.processInfo.environment["HANDFREE_APP_SECRET_FILE"] ?? "\(supportDir)/app-secret"

// Read once, made at the first launch.
let appSecret: String = {
  let existing = (try? String(contentsOfFile: appSecretPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  if !existing.isEmpty {
    chmod(appSecretPath, 0o600)
    return existing
  }
  var bytes = [UInt8](repeating: 0, count: 32)
  _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
  let secret = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
  try? FileManager.default.createDirectory(atPath: (appSecretPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  FileManager.default.createFile(atPath: appSecretPath, contents: Data(secret.utf8), attributes: [.posixPermissions: 0o600])
  return secret
}()

// In constant time: how much of it matches tells nothing.
func isAppSecret(_ given: String) -> Bool {
  let a = Array(given.utf8), b = Array(appSecret.utf8)
  guard a.count == b.count else { return false }
  return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
}
