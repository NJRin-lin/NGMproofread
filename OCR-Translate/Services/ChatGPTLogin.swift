import AppKit
import Network

@MainActor
final class ChatGPTLogin {
    private var listener: NWListener?
    private var ready: CheckedContinuation<String, Error>?
    private var callback: CheckedContinuation<URL, Error>?
    private var timeout: Task<Void, Never>?
    private var connections: [NWConnection] = []
    private var redirect = ""
    private var state = ""

    func start() async throws -> String {
        try Task.checkCancellation()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                listener.stateUpdateHandler = { [weak self] status in
                    Task { @MainActor in
                        guard let self else { return }
                        switch status {
                        case .ready:
                            guard let port = listener.port else { self.fail(ChatGPTError.message("无法启动本机登录回调")); return }
                            self.redirect = "http://127.0.0.1:\(port.rawValue)/auth/callback"
                            self.ready?.resume(returning: self.redirect); self.ready = nil
                        case .failed: self.fail(ChatGPTError.message("无法启动本机登录回调，请重试"))
                        default: break
                        }
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor in self?.accept(connection) }
                }
                listener.start(queue: .main)
            }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }

    func authorize(at url: URL, state: String) async throws -> URL {
        self.state = state
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                callback = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(180)) } catch { return }
                    self?.fail(ChatGPTError.message("登录等待超时，请重新连接 ChatGPT"))
                }
                if !NSWorkspace.shared.open(url) { fail(ChatGPTError.message("无法打开登录页面，请检查默认浏览器")) }
            }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }

    func cancel() { fail(CancellationError()) }

    private func fail(_ error: Error) {
        ready?.resume(throwing: error); ready = nil
        callback?.resume(throwing: error); callback = nil
        stop()
    }

    private func stop() {
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        connections.forEach { $0.cancel() }; connections = []
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 8 else { connection.cancel(); return }
        connections.append(connection)
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if buffer.count > 16384 || error != nil { self.close(connection); return }
                guard let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") else {
                    if complete { self.close(connection) } else { self.receive(connection, buffer: buffer) }
                    return
                }
                let firstLine = request.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
                guard firstLine.count == 3, firstLine[0] == "GET",
                      let url = URL(string: "http://127.0.0.1" + firstLine[1]),
                      url.path == "/auth/callback",
                      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                      items.filter({ $0.name == "state" }).count == 1,
                      items.first(where: { $0.name == "state" })?.value == self.state,
                      self.callback != nil else {
                    self.reply(connection, accepted: false); return
                }
                // No auth code or token is reflected into the browser response.
                self.reply(connection, accepted: true)
                self.callback?.resume(returning: url); self.callback = nil
                self.timeout?.cancel(); self.timeout = nil
                self.listener?.cancel(); self.listener = nil
            }
        }
    }

    private func reply(_ connection: NWConnection, accepted: Bool) {
        let message = accepted ? "Login response received. Return to NGM proofread to see the result." : "Invalid callback. Continue signing in from NGM proofread."
        let response = "HTTP/1.1 \(accepted ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(message.utf8.count)\r\n\r\n\(message)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(connection) }
        })
    }

    private func close(_ connection: NWConnection) {
        connection.cancel()
        connections.removeAll { $0 === connection }
    }
}
