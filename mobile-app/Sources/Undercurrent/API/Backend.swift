import Foundation

// The HTTP client for backend/API.md. One instance per base URL; every write carries X-Actor.
// Endpoints the backend answers with 501 surface as BackendError.notBuilt so the UI can say so.
struct Backend: Sendable {
    var baseURL: URL
    var actor: String = "user"
    var session: URLSession = .shared

    static let defaultURL: URL = {
        let fromPlist = Bundle.main.object(forInfoDictionaryKey: "BackendURL") as? String
        return URL(string: fromPlist?.isEmpty == false ? fromPlist! : "http://127.0.0.1:8787")!
    }()

    static let storageKey = "backendURL"

    // The URL the user set in Settings, else the build default.
    static func configuredURL(defaults: UserDefaults = .standard) -> URL {
        if let s = defaults.string(forKey: storageKey), let u = URL(string: s), u.host != nil { return u }
        return defaultURL
    }

    // MARK: Built

    func health() async throws -> Health { try await get("/health") }

    func tasks(stage: Stage? = nil) async throws -> [BoardTask] {
        try await get("/tasks", query: stage.map { ["stage": $0.rawValue] } ?? [:])
    }

    func task(_ id: String) async throws -> BoardTask { try await get("/tasks/\(id)") }

    func add(text: String, tags: [String] = [], priority: String = "", due: String = "",
             context: String = "", stage: Stage? = nil, parentID: String = "") async throws -> BoardTask {
        var body: [String: Any] = ["text": text]
        if !tags.isEmpty { body["tags"] = tags }
        if !priority.isEmpty { body["priority"] = priority }
        if !due.isEmpty { body["due"] = due }
        if !context.isEmpty { body["context"] = context }
        if let stage { body["stage"] = stage.rawValue }
        if !parentID.isEmpty { body["parent_id"] = parentID }
        return try await send("POST", "/tasks", body: body)
    }

    func edit(_ id: String, text: String? = nil, context: String? = nil, tags: [String]? = nil) async throws -> BoardTask {
        var body: [String: Any] = [:]
        if let text { body["text"] = text }
        if let context { body["context"] = context }
        if let tags { body["tags"] = tags }
        return try await send("PATCH", "/tasks/\(id)", body: body)
    }

    func stage(_ id: String, context: String) async throws -> BoardTask {
        try await send("POST", "/tasks/\(id)/stage", body: ["context": context])
    }

    func close(_ id: String) async throws -> BoardTask {
        try await send("POST", "/tasks/\(id)/close", body: [:])
    }

    func events(task: String? = nil, actor: String? = nil) async throws -> [Event] {
        var q: [String: String] = [:]
        if let task { q["task"] = task }
        if let actor { q["actor"] = actor }
        return try await get("/events", query: q)
    }

    // MARK: Written against the contract; the backend answers 501 until they exist

    func commit(_ id: String) async throws -> BoardTask {
        try await send("POST", "/tasks/\(id)/commit", body: [:])
    }

    func retransform(_ id: String, instruction: String) async throws -> BoardTask {
        try await send("POST", "/tasks/\(id)/retransform", body: ["instruction": instruction])
    }

    func runs(task: String? = nil) async throws -> [Run] {
        try await get("/runs", query: task.map { ["task": $0] } ?? [:])
    }

    func run(_ id: String) async throws -> Run { try await get("/runs/\(id)") }

    func answer(run id: String, _ answer: String) async throws -> Run {
        try await send("POST", "/runs/\(id)/answer", body: ["answer": answer])
    }

    // The credentials to start a call: a WebRTC conversation token for the Swift SDK, a signed
    // WebSocket URL for text-only clients. The backend answers 503 until it is configured.
    func live() async throws -> LiveCredentials { try await get("/live/signed-url") }

    // MARK: Transport

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        var comps = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        return try await perform(req)
    }

    private func send<T: Decodable>(_ method: String, _ path: String, body: [String: Any]) async throws -> T {
        var req = URLRequest(url: baseURL.appending(path: path))
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(actor, forHTTPHeaderField: "X-Actor")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await perform(req)
    }

    private func perform<T: Decodable>(_ req: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw BackendError.unreachable(baseURL, error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw BackendError.unreachable(baseURL, "no response") }
        let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            ?? String(data: data, encoding: .utf8) ?? ""
        switch http.statusCode {
        case 200..<300:
            do { return try JSONDecoder().decode(T.self, from: data) }
            catch { throw BackendError.decoding(error.localizedDescription) }
        case 501: throw BackendError.notBuilt(req.url?.path ?? "")
        case 404: throw BackendError.notFound(message)
        case 409: throw BackendError.refused(message)
        default: throw BackendError.http(http.statusCode, message)
        }
    }

    private struct ErrorBody: Decodable { var error: String }
}

struct LiveCredentials: Decodable, Equatable {
    var signedURL: String?
    var token: String?
    var agentID: String?
    var conversationID: String?
    enum CodingKeys: String, CodingKey { case signedURL = "signed_url", token, agentID = "agent_id", conversationID = "conversation_id" }
}

enum BackendError: LocalizedError, Equatable {
    case unreachable(URL, String)
    case notBuilt(String)
    case notFound(String)
    case refused(String)
    case http(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let url, _): "Can't reach the backend at \(url.absoluteString)."
        case .notBuilt: "The backend hasn't built this yet."
        case .notFound(let m): m.isEmpty ? "Not found." : m
        case .refused(let m): m.isEmpty ? "The backend refused that." : m
        case .http(let code, let m): m.isEmpty ? "HTTP \(code)." : "\(m) (\(code))"
        case .decoding(let m): "Couldn't read the reply: \(m)"
        }
    }

    var isNotBuilt: Bool { if case .notBuilt = self { return true } else { return false } }
    var isUnreachable: Bool { if case .unreachable = self { return true } else { return false } }
}
