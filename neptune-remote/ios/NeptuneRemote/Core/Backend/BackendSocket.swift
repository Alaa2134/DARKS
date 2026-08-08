import Foundation

/// Realtime channel to the Raspberry Pi backend (`/ws`).
///
/// Carries printer status, power state, slicing progress, Pi metrics and the
/// discrete events the app turns into local notifications.
@MainActor
final class BackendSocket {

    enum Event {
        case hello(engine: String, powerProvider: String, slicerAvailable: Bool)
        case printer(BackendPrinterStatus)
        case summary(BackendSummary)
        case power(BackendPowerStatus)
        case slice(SliceProgress)
        case system(BackendSystem)
        case printerEvent(BackendPrinterEvent)
        case connected
        case disconnected(String?)
    }

    struct SliceProgress: Decodable, Equatable {
        let id: String
        let status: String
        let progress: Double
        let stage: String
        let outputFilename: String
        let error: String?
        let logTail: [String]

        enum CodingKeys: String, CodingKey {
            case id, status, progress, stage, error
            case outputFilename = "output_filename"
            case logTail = "log_tail"
        }
    }

    private(set) var isConnected = false
    var onEvent: ((Event) -> Void)?

    private var config: ConnectionConfig
    private var token: String
    private var task: URLSessionWebSocketTask?
    private let session: URLSession
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var shouldReconnect = false

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    init(config: ConnectionConfig, token: String = "") {
        self.config = config
        self.token = token
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    func update(config: ConnectionConfig, token: String) {
        let changed = config != self.config || token != self.token
        self.config = config
        self.token = token
        if changed, shouldReconnect { restart() }
    }

    func connect() {
        shouldReconnect = true
        open()
    }

    func disconnect() {
        shouldReconnect = false
        cancelTasks()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
    }

    func restart() {
        cancelTasks()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        reconnectAttempt = 0
        if shouldReconnect { open() }
    }

    private func cancelTasks() {
        receiveTask?.cancel()
        receiveTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private func open() {
        cancelTasks()
        guard let url = config.backendWebSocketURL else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: BackendClient.apiKeyHeader)
        }

        let socket = session.webSocketTask(with: request)
        task = socket
        socket.resume()

        receiveTask = Task { [weak self] in
            await self?.receiveLoop(socket)
        }
    }

    func requestSystemUpdate() {
        Task { [weak self] in
            await self?.send(["type": "system"])
        }
    }

    /// Ask for a fresh Home payload (camera / recording / vision / queue / …).
    func requestSummary() {
        Task { [weak self] in
            await self?.send(["type": "summary"])
        }
    }

    private func send(_ payload: [String: Any]) async {
        guard let task,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8)
        else { return }
        try? await task.send(.string(text))
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                if !isConnected {
                    isConnected = true
                    reconnectAttempt = 0
                    onEvent?(.connected)
                }
                switch message {
                case .string(let text):
                    handle(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { handle(text) }
                @unknown default:
                    break
                }
            } catch {
                if Task.isCancelled { return }
                isConnected = false
                let message = APIError.from(error, host: config.host).localizedDescription
                onEvent?(.disconnected(message))
                task = nil
                scheduleReconnect()
                return
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return }

        let payload = object["payload"]
        func decodePayload<T: Decodable>(_ type: T.Type) -> T? {
            guard let payload, JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(withJSONObject: payload)
            else { return nil }
            return try? decoder.decode(T.self, from: data)
        }

        switch type {
        case "hello":
            let dictionary = payload as? [String: Any] ?? [:]
            onEvent?(.hello(
                engine: dictionary["slicer_engine"] as? String ?? "",
                powerProvider: dictionary["power_provider"] as? String ?? "",
                slicerAvailable: dictionary["slicer_available"] as? Bool ?? false
            ))
        case "printer":
            if let status = decodePayload(BackendPrinterStatus.self) { onEvent?(.printer(status)) }
        case "summary":
            // The summary frame also carries the printer status, so forward both:
            // stores that only care about temperatures keep working unchanged.
            if let summary = decodePayload(BackendSummary.self) {
                onEvent?(.printer(summary.printer))
                onEvent?(.summary(summary))
            }
        case "power":
            if let status = decodePayload(BackendPowerStatus.self) { onEvent?(.power(status)) }
        case "slice":
            if let progress = decodePayload(SliceProgress.self) { onEvent?(.slice(progress)) }
        case "system":
            if let system = decodePayload(BackendSystem.self) { onEvent?(.system(system)) }
        case "event":
            if let event = decodePayload(BackendPrinterEvent.self) { onEvent?(.printerEvent(event)) }
        default:
            break
        }
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
                self.open()
            }
        }
    }
}
