import Foundation

final class APIClient: @unchecked Sendable {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        session = URLSession(configuration: config)
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
    }

    private func request(_ settings: ConnectionSettings, path: String, method: String = "GET", body: Data? = nil, timeout: TimeInterval = 30) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: settings.baseURL) else { throw ShareError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(settings.accessKey)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if !settings.cloudflareClientID.isEmpty { request.setValue(settings.cloudflareClientID, forHTTPHeaderField: "CF-Access-Client-Id") }
        if !settings.cloudflareClientSecret.isEmpty { request.setValue(settings.cloudflareClientSecret, forHTTPHeaderField: "CF-Access-Client-Secret") }
        return request
    }

    private func send<T: Decodable>(_ type: T.Type, request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(type, from: data)
    }

    private func sendEmpty(_ request: URLRequest) async throws {
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw ShareError.unauthorized }
            if let error = try? decoder.decode(ServerErrorBody.self, from: data) { throw ShareError.server(error.error, error.message, error.received) }
            throw URLError(.badServerResponse)
        }
    }

    private func queryValue(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

	func login(username: String, password: String, settings: ConnectionSettings) async throws -> String {
		struct Credentials: Encodable { let username: String; let password: String }
		struct Session: Decodable { let token: String }
		let body = try encoder.encode(Credentials(username: username, password: password))
		return try await send(Session.self, request: request(settings, path: "/api/v1/login", method: "POST", body: body)).token
	}

    func list(_ folder: String, settings: ConnectionSettings, timeout: TimeInterval = 30) async throws -> ListResponse {
        let escaped = queryValue(folder)
        return try await send(ListResponse.self, request: request(settings, path: "/api/v1/list?path=\(escaped)", timeout: timeout))
    }

    func link(_ file: String, settings: ConnectionSettings) async throws -> URL {
        let body = try encoder.encode(["path": file])
        let result = try await send(LinkResponse.self, request: request(settings, path: "/api/v1/link", method: "POST", body: body))
        guard let url = URL(string: result.url, relativeTo: settings.baseURL)?.absoluteURL else { throw ShareError.invalidURL }
        return url
    }

    func mkdir(_ folder: String, settings: ConnectionSettings) async throws {
        try await sendEmpty(request(settings, path: "/api/v1/mkdir", method: "POST", body: try encoder.encode(["path": folder])))
    }

    func move(from: String, to: String, overwrite: Bool = false, settings: ConnectionSettings) async throws {
        struct Move: Encodable { let from: String; let to: String; let overwrite: Bool }
        try await sendEmpty(request(settings, path: "/api/v1/move", method: "POST", body: try encoder.encode(Move(from: from, to: to, overwrite: overwrite))))
    }

    func delete(_ item: String, settings: ConnectionSettings) async throws {
        let escaped = queryValue(item)
        try await sendEmpty(request(settings, path: "/api/v1/entry?path=\(escaped)", method: "DELETE"))
    }

    func beginUpload(path: String, size: Int64, modified: Date, overwrite: Bool, settings: ConnectionSettings) async throws -> UploadCreated {
        struct Start: Encodable { let path: String; let size: Int64; let modified: Date; let overwrite: Bool }
        let body = try encoder.encode(Start(path: path, size: size, modified: modified, overwrite: overwrite))
        return try await send(UploadCreated.self, request: request(settings, path: "/api/v1/uploads", method: "POST", body: body))
    }

    func uploadStatus(id: String, settings: ConnectionSettings) async throws -> UploadStatus {
        try await send(UploadStatus.self, request: request(settings, path: "/api/v1/uploads/\(id)"))
    }

    func putChunk(id: String, offset: Int64, data: Data, settings: ConnectionSettings, progress: @escaping @Sendable (Int64) -> Void) async throws -> Int64 {
        var req = try request(settings, path: "/api/v1/uploads/\(id)?offset=\(offset)", method: "PUT", timeout: 600)
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        struct Received: Decodable { let received: Int64 }
        let delegate = ChunkProgressDelegate(progress)
        let (responseData, response) = try await session.upload(for: req, from: data, delegate: delegate)
        try validate(response, data: responseData)
        return try decoder.decode(Received.self, from: responseData).received
    }

    func completeUpload(id: String, settings: ConnectionSettings) async throws {
        try await sendEmpty(request(settings, path: "/api/v1/uploads/\(id)/complete", method: "POST", body: Data("{}".utf8)))
    }

    func abortUpload(id: String, settings: ConnectionSettings) async {
        try? await sendEmpty(request(settings, path: "/api/v1/uploads/\(id)", method: "DELETE"))
    }

    func download(_ file: String, to destination: URL, settings: ConnectionSettings) async throws {
        let escaped = queryValue(file)
        let req = try request(settings, path: "/api/v1/file?path=\(escaped)", timeout: 600)
        let (temporary, response) = try await session.download(for: req)
        try validate(response, data: Data())
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}

private final class ChunkProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let progress: @Sendable (Int64) -> Void

    init(_ progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress(totalBytesSent)
    }
}
