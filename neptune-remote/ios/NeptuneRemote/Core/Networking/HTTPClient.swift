import Foundation

/// Small async/await wrapper over URLSession used by both API clients.
actor HTTPClient {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(timeout: TimeInterval = 15, resourceTimeout: TimeInterval = 600) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.allowsCellularAccess = true
        session = URLSession(configuration: configuration)

        decoder = JSONDecoder()
        encoder = JSONEncoder()
    }

    // MARK: - Request building

    struct Request {
        var url: URL
        var method: String = "GET"
        var query: [URLQueryItem] = []
        var headers: [String: String] = [:]
        var body: Data?
        var contentType: String?
        var timeout: TimeInterval?
    }

    private func urlRequest(from request: Request) throws -> URLRequest {
        guard var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        if !request.query.isEmpty {
            // Read into a local first: mutating `components` while also reading
            // it is an exclusivity violation.
            let existing = components.queryItems ?? []
            components.queryItems = existing + request.query
            // URLComponents leaves "+" unescaped in query values, and a server
            // reads that as a space - so printing "bracket+v2.gcode" asks for
            // "bracket v2.gcode" and comes back 404 for a file that is there.
            if let encoded = components.percentEncodedQuery {
                components.percentEncodedQuery = encoded.replacingOccurrences(of: "+", with: "%2B")
            }
        }
        guard let url = components.url else { throw APIError.invalidURL }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        if let contentType = request.contentType {
            urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        if let timeout = request.timeout {
            urlRequest.timeoutInterval = timeout
        }
        return urlRequest
    }

    // MARK: - Execution

    @discardableResult
    func data(_ request: Request) async throws -> (Data, HTTPURLResponse) {
        let urlRequest = try urlRequest(from: request)
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.unknown("Malformed response")
            }
            try Self.validate(data: data, response: http, url: request.url)
            return (data, http)
        } catch {
            throw APIError.from(error, host: request.url.host ?? "")
        }
    }

    func decode<T: Decodable>(_ type: T.Type, from request: Request) async throws -> T {
        let (data, _) = try await data(request)
        do {
            return try decoder.decode(T.self, from: data)
        } catch let error as DecodingError {
            throw APIError.decoding(Self.describe(error))
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    func encodeBody<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try encoder.encode(value)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    /// Multipart upload used for models and G-code.
    func upload(
        url: URL,
        fieldName: String,
        filename: String,
        fileData: Data,
        mimeType: String = "application/octet-stream",
        fields: [String: String] = [:],
        headers: [String: String] = [:],
        query: [URLQueryItem] = [],
        timeout: TimeInterval = 600
    ) async throws -> (Data, HTTPURLResponse) {
        let boundary = "neptune-\(UUID().uuidString)"
        var body = Data()

        func append(_ string: String) {
            if let data = string.data(using: .utf8) { body.append(data) }
        }

        for (key, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")

        let request = Request(
            url: url,
            method: "POST",
            query: query,
            headers: headers,
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)",
            timeout: timeout
        )
        return try await data(request)
    }

    // MARK: - Helpers

    static func validate(data: Data, response: HTTPURLResponse, url: URL) throws {
        guard !(200...299).contains(response.statusCode) else { return }

        let message = extractMessage(from: data)
        switch response.statusCode {
        case 401, 403:
            throw APIError.unauthorized
        case 404:
            throw APIError.notFound(message.isEmpty ? url.lastPathComponent : message)
        case 409:
            if let blockers = extractBlockers(from: data), !blockers.isEmpty {
                throw APIError.unsafeOperation(blockers)
            }
            throw APIError.server(status: 409, message: message)
        case 502, 503:
            throw APIError.moonraker(message)
        default:
            throw APIError.server(status: response.statusCode, message: message)
        }
    }

    static func extractMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return String(data: data.prefix(400), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        guard let dictionary = object as? [String: Any] else { return "" }

        if let detail = dictionary["detail"] {
            if let text = detail as? String { return text }
            if let nested = detail as? [String: Any] {
                if let message = nested["message"] as? String { return message }
            }
        }
        if let error = dictionary["error"] {
            if let text = error as? String { return text }
            if let nested = error as? [String: Any], let message = nested["message"] as? String {
                return message
            }
        }
        if let message = dictionary["message"] as? String { return message }
        return ""
    }

    /// FastAPI returns `{"detail": {"message": ..., "safety": {"blockers": [...]}}}`
    /// when a power-off is refused.
    static func extractBlockers(from data: Data) -> [String]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = object["detail"] as? [String: Any],
              let safety = detail["safety"] as? [String: Any],
              let blockers = safety["blockers"] as? [String]
        else { return nil }
        return blockers
    }

    static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _):
            return "missing key '\(key.stringValue)'"
        case .typeMismatch(let type, let context):
            return "type mismatch for \(type) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case .valueNotFound(let type, _):
            return "missing value for \(type)"
        case .dataCorrupted(let context):
            return context.debugDescription
        @unknown default:
            return "unknown decoding error"
        }
    }
}
