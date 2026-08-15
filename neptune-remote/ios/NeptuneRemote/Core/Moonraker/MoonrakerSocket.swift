import Foundation

/// Moonraker's realtime channel is JSON-RPC 2.0 over a WebSocket at `/websocket`.
///
/// After connecting we identify the client and subscribe to the printer objects
/// the dashboard needs; Moonraker then pushes `notify_status_update` deltas.
@MainActor
final class MoonrakerSocket {

    enum Event {
        case connected
        case disconnected(String?)
        case status(PrinterObjects)
        case gcodeResponse(String)
        case klippyReady
        case klippyShutdown
        case klippyDisconnected
        case printerError(String)
    }

    enum ConnectionState: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    private(set) var state: ConnectionState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    var onEvent: ((Event) -> Void)?
    var onStateChange: ((ConnectionState) -> Void)?

    private var config: ConnectionConfig
    private var apiKey: String
    private var task: URLSessionWebSocketTask?
    private var session: URLSession
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var requestID = 0
    private var reconnectAttempt = 0
    private var shouldReconnect = false

    init(config: ConnectionConfig, apiKey: String = "") {
        self.config = config
        self.apiKey = apiKey
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    // MARK: - Lifecycle

    func update(config: ConnectionConfig, apiKey: String) {
        let changed = config != self.config || apiKey != self.apiKey
        self.config = config
        self.apiKey = apiKey
        if changed {
            // New coordinates invalidate whichever endpoint had been chosen.
            candidateIndex = 0
            if shouldReconnect { restart() }
        }
    }

    /// Opens the socket if one is not already open or on its way.
    ///
    /// Idempotent on purpose. `PrinterStore.reconfigure()` runs behind every
    /// settings change - and there is one behind every jog step, every toggle,
    /// every slider - and it calls this each time. When this method reopened
    /// unconditionally, each of those taps left the previous socket connected
    /// and unread: Moonraker held a client slot and kept pushing status into a
    /// connection nothing was listening to, one more for every interaction.
    func connect() {
        shouldReconnect = true
        // A pending reconnect counts as "on its way" - opening alongside it
        // would produce exactly the pair of sockets this guard exists to stop.
        guard task == nil, reconnectTask == nil else { return }
        openConnection()
    }

    func disconnect() {
        shouldReconnect = false
        cancelTasks()
        closeSocket()
        state = .idle
    }

    func restart() {
        cancelTasks()
        closeSocket()
        reconnectAttempt = 0
        if shouldReconnect { openConnection() }
    }

    private func cancelTasks() {
        receiveTask?.cancel()
        receiveTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        pingTask?.cancel()
        pingTask = nil
    }

    /// Closes the socket rather than dropping the reference to it.
    ///
    /// URLSession keeps a task alive until it completes or is cancelled, so
    /// simply overwriting `task` left the old connection established at both
    /// ends with nobody reading it.
    private func closeSocket() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    /// Index into `config.moonrakerWebSocketURLCandidates`. A socket that never
    /// reaches `connected` advances this, so a missing or misconfigured nginx
    /// vhost falls through to Moonraker's own port instead of retrying a dead
    /// endpoint forever.
    private var candidateIndex = 0

    /// The endpoint the current attempt is using, for diagnostics.
    private(set) var activeURL: URL?

    /// True once this attempt has reported a failure, so a socket that fails on
    /// both the read side and the ping side is only counted once - otherwise the
    /// candidate index advances twice and a working endpoint gets skipped.
    private var hasFailedThisAttempt = false

    private func openConnection() {
        cancelTasks()
        closeSocket()
        hasFailedThisAttempt = false
        let candidates = config.moonrakerWebSocketURLCandidates
        guard !candidates.isEmpty else {
            state = .failed(L.t("error.invalid_url"))
            return
        }
        let url = candidates[candidateIndex % candidates.count]
        activeURL = url

        state = .connecting
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        }

        let socket = session.webSocketTask(with: request)
        task = socket
        socket.resume()

        receiveTask = Task { [weak self] in
            await self?.receiveLoop(socket)
        }

        Task { [weak self] in
            await self?.handshake()
        }

        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.sendPing()
            }
        }
    }

    // MARK: - Sending

    private func nextID() -> Int {
        requestID += 1
        return requestID
    }

    private func send(method: String, params: Any?) async {
        guard let task else { return }
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "id": nextID()
        ]
        if let params { payload["params"] = params }

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8)
        else { return }

        do {
            try await task.send(.string(text))
        } catch {
            handleFailure(error)
        }
    }

    private func sendPing() async {
        guard let task else { return }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                task.sendPing { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        } catch {
            handleFailure(error)
        }
    }

    private func handshake() async {
        await send(
            method: "server.connection.identify",
            params: [
                "client_name": "Neptune 3 Plus Remote",
                "version": Bundle.main.appVersion,
                "type": "mobile",
                "url": "https://github.com/alaa2134/darks"
            ]
        )
        await subscribe()
    }

    /// Objects this socket subscribes to. Set from the discovered capabilities
    /// so a machine with extra fans or sensors streams those too; falls back to
    /// the standard set before discovery has run.
    private var subscribedObjects = PrinterObjects.queryObjects

    func subscribe(objects names: [String]? = nil) async {
        if let names, !names.isEmpty { subscribedObjects = names }
        // Moonraker expects {"objects": {"print_stats": null, ...}} where null
        // means "send every field of this object".
        var objects: [String: Any] = [:]
        for name in subscribedObjects {
            objects[name] = NSNull()
        }
        await send(method: "printer.objects.subscribe", params: ["objects": objects])
    }

    /// Fire-and-forget G-code over the socket (used by the terminal for speed).
    func sendGCode(_ script: String) async {
        await send(method: "printer.gcode.script", params: ["script": script])
    }

    // MARK: - Receiving

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                if state != .connected {
                    state = .connected
                    reconnectAttempt = 0
                    // This endpoint works. Fold the index back into range so it
                    // keeps selecting this same candidate without growing
                    // without bound across a long-lived session.
                    candidateIndex %= max(config.moonrakerWebSocketURLCandidates.count, 1)
                    onEvent?(.connected)
                }
                switch message {
                case .string(let text):
                    handle(text: text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { handle(text: text) }
                @unknown default:
                    break
                }
            } catch {
                if Task.isCancelled { return }
                // A socket that has already been replaced dying is not news, and
                // acting on it here would tear down its healthy successor.
                guard task === socket else { return }
                handleFailure(error)
                return
            }
        }
    }

    private func handle(text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        // Subscribe/query replies carry the full status under result.status.
        if let result = object["result"] as? [String: Any] {
            if let status = result["status"] {
                decodeObjects(status)
            }
            return
        }

        guard let method = object["method"] as? String else { return }
        let params = object["params"]

        switch method {
        case "notify_status_update":
            if let array = params as? [Any], let first = array.first {
                decodeObjects(first)
            }
        case "notify_gcode_response":
            if let array = params as? [Any] {
                for entry in array {
                    if let line = entry as? String {
                        onEvent?(.gcodeResponse(line))
                        if line.lowercased().hasPrefix("!!") {
                            onEvent?(.printerError(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
                        }
                    }
                }
            }
        case "notify_klippy_ready":
            onEvent?(.klippyReady)
            Task { await subscribe() }
        case "notify_klippy_shutdown":
            onEvent?(.klippyShutdown)
        case "notify_klippy_disconnected":
            onEvent?(.klippyDisconnected)
        default:
            break
        }
    }

    private func decodeObjects(_ raw: Any) {
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let objects = try? JSONDecoder().decode(PrinterObjects.self, from: data)
        else { return }
        onEvent?(.status(objects))
    }

    // MARK: - Failure handling

    private func handleFailure(_ error: Error) {
        // Both the receive loop and the ping timer report the same dead socket,
        // and the first one to arrive is the one that counts.
        guard !hasFailedThisAttempt else { return }
        hasFailedThisAttempt = true

        // A socket that never got a single frame through was pointed at the
        // wrong endpoint; try the next candidate. One that had been connected
        // stays where it is - that endpoint is known good and simply dropped.
        if state != .connected {
            candidateIndex += 1
        }
        let message = APIError.from(error, host: config.host).localizedDescription
        state = .failed(message)
        onEvent?(.disconnected(message))
        // The heartbeat belongs to the socket that just died. Left running, it
        // would keep firing every twenty seconds against a nil task for as long
        // as the reconnect backoff lasts.
        pingTask?.cancel()
        pingTask = nil
        closeSocket()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard shouldReconnect, reconnectTask == nil else { return }
        reconnectAttempt = min(reconnectAttempt + 1, 6)
        let delay = min(pow(2.0, Double(reconnectAttempt)), 30.0)

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.shouldReconnect else { return }
                self.reconnectTask = nil
                self.openConnection()
            }
        }
    }
}

extension Bundle {
    var appVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }

    var buildNumber: String {
        (infoDictionary?["CFBundleVersion"] as? String) ?? "1"
    }
}
