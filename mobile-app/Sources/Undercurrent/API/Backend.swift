import Foundation

// The HTTP client for backend/API.md. One instance per base URL; every write carries X-Actor.
// Endpoints the backend answers with 501 surface as BackendError.notBuilt so the UI can say so.
struct Backend: Sendable {
    var baseURL: URL
    var actor: String = "user"
    var session: URLSession = .shared
    // The key the backend was started with (UNDERCURRENT_API_KEY); empty for a local backend.
    var apiKey: String = ""

    static let defaultURL: URL = {
        let fromPlist = Bundle.main.object(forInfoDictionaryKey: "BackendURL") as? String
        return URL(string: fromPlist?.isEmpty == false ? fromPlist! : "http://127.0.0.1:8787")!
    }()

    static let storageKey = "backendURL"
    static let keyStorageKey = "backendKey"

    // The build default key (BACKEND_KEY in project.yml → BackendKey in Info.plist); empty for an open backend.
    static let defaultKey: String = (Bundle.main.object(forInfoDictionaryKey: "BackendKey") as? String) ?? ""

    // The key the user set in Settings (or passed as -backendKey), else the build default.
    static func configuredKey(defaults: UserDefaults = .standard) -> String {
        if let k = defaults.string(forKey: keyStorageKey), !k.isEmpty { return k }
        return defaultKey
    }

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

    func events(task: String? = nil, actor: String? = nil, limit: Int? = nil) async throws -> [Event] {
        var q: [String: String] = [:]
        if let task { q["task"] = task }
        if let actor { q["actor"] = actor }
        if let limit { q["limit"] = String(limit) }
        return try await get("/events", query: q)
    }

    // The board as it was at a moment: each task as its last event at or before `at` left it.
    func state(at: String) async throws -> BoardState { try await get("/state", query: ["at": at]) }

    // MARK: Runs

    // staged → committed; the run that was queued for it (202).
    func commit(_ id: String) async throws -> Run {
        try await send("POST", "/tasks/\(id)/commit", body: [:])
    }

    // The chat model turns the instruction into operations; `say` is the line to show or speak.
    func retransform(_ id: String, instruction: String) async throws -> Retransform {
        try await send("POST", "/tasks/\(id)/retransform", body: ["instruction": instruction])
    }

    func runs(task: String? = nil) async throws -> [Run] {
        try await get("/runs", query: task.map { ["task": $0] } ?? [:])
    }

    func run(_ id: String) async throws -> Run { try await get("/runs/\(id)") }

    func answer(run id: String, _ answer: String) async throws -> Run {
        try await send("POST", "/runs/\(id)/answer", body: ["answer": answer])
    }

    // MARK: Live

    // The credentials to start a call: a WebRTC conversation token for the Swift SDK, a signed
    // WebSocket URL for text-only clients. The backend answers 503 until it is configured.
    func live() async throws -> LiveCredentials { try await get("/live/signed-url") }

    // What a call needs before it starts: the agent, the tool secret, the tool names, the board as text.
    func liveConfig() async throws -> LiveConfig { try await get("/live/config") }

    // One client tool call, forwarded to the backend with the secret; the reply is what the agent hears.
    func liveTool(_ name: String, args: [String: Any], secret: String) async throws -> ToolReply {
        try await send("POST", "/live/tools/\(name)", body: args, headers: ["X-Live-Secret": secret])
    }

    // The transcript of a finished call, in the post-call webhook's shape.
    func postCall(conversationID: String, transcript: [[String: Any]]) async throws -> PostCallReply {
        try await send("POST", "/live/post-call", body: [
            "type": "post_call_transcription",
            "data": ["conversation_id": conversationID, "transcript": transcript, "analysis": [:]],
        ])
    }

    // MARK: Transport

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        var comps = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        return try await perform(req)
    }

    func send<T: Decodable>(_ method: String, _ path: String, body: [String: Any], headers: [String: String] = [:]) async throws -> T {
        var req = URLRequest(url: baseURL.appending(path: path))
        req.httpMethod = method
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(actor, forHTTPHeaderField: "X-Actor")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await perform(req)
    }

    private func perform<T: Decodable>(_ req: URLRequest) async throws -> T {
        var req = req
        if !apiKey.isEmpty { req.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
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
        case 401: throw BackendError.unauthorized(message)
        case 404: throw BackendError.notFound(message)
        case 409: throw BackendError.refused(message)
        default: throw BackendError.http(http.statusCode, message)
        }
    }

    private struct ErrorBody: Decodable { var error: String }
}

// GET /live/config: what a call needs before it starts.
struct LiveConfig: Decodable, Equatable {
    var agentID: String = ""
    var secret: String = ""
    var configured: Bool = false
    var tools: [String] = []
    var board: String = ""
    enum CodingKeys: String, CodingKey { case agentID = "agent_id", secret, configured, tools, board }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentID = try c.decodeIfPresent(String.self, forKey: .agentID) ?? ""
        secret = try c.decodeIfPresent(String.self, forKey: .secret) ?? ""
        configured = try c.decodeIfPresent(Bool.self, forKey: .configured) ?? false
        tools = try c.decodeIfPresent([String].self, forKey: .tools) ?? []
        board = try c.decodeIfPresent(String.self, forKey: .board) ?? ""
    }
}

// POST /live/tools/:name: {ok, result} · {ok: false, needs_confirmation, read_back} · {ok: false, error}.
struct ToolReply: Decodable, Equatable {
    var ok: Bool = false
    var result: String = ""
    var needsConfirmation: Bool = false
    var readBack: String = ""
    var error: String = ""
    enum CodingKeys: String, CodingKey { case ok, result, error, needsConfirmation = "needs_confirmation", readBack = "read_back" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        result = try c.decodeIfPresent(String.self, forKey: .result) ?? ""
        needsConfirmation = try c.decodeIfPresent(Bool.self, forKey: .needsConfirmation) ?? false
        readBack = try c.decodeIfPresent(String.self, forKey: .readBack) ?? ""
        error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
    }
    // What the agent is told, per MOBILE_APP.md.
    var spoken: String {
        if ok { return result }
        if needsConfirmation { return "NEEDS CONFIRMATION, read this back and wait for a yes: " + readBack }
        return "ERROR: " + (error.isEmpty ? "the backend refused that" : error)
    }
}

// POST /live/post-call answers {"ok": "stored"} (or true); either reads as ok.
struct PostCallReply: Decodable, Equatable {
    var ok: Bool
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let b = try? c.decode(Bool.self, forKey: .ok) { ok = b }
        else if let s = try? c.decode(String.self, forKey: .ok) { ok = !s.isEmpty && s != "false" }
        else { ok = false }
    }
    enum CodingKeys: String, CodingKey { case ok }
}

// POST /tasks/:id/retransform → {run, say}
struct Retransform: Decodable, Equatable {
    var run: Run
    var say: String
    enum CodingKeys: String, CodingKey { case run, say }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        run = try c.decode(Run.self, forKey: .run)
        say = try c.decodeIfPresent(String.self, forKey: .say) ?? ""
    }
}

// GET /state?at= → {at, tasks}
struct BoardState: Decodable, Equatable {
    var at: String
    var tasks: [BoardTask]
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
    case unauthorized(String)
    case notFound(String)
    case refused(String)
    case http(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let url, _): "Can't reach the backend at \(url.absoluteString)."
        case .notBuilt: "The backend hasn't built this yet."
        case .unauthorized: "This backend needs its key. Set it in Settings."
        case .notFound(let m): m.isEmpty ? "Not found." : m
        case .refused(let m): m.isEmpty ? "The backend refused that." : m
        case .http(let code, let m): m.isEmpty ? "HTTP \(code)." : "\(m) (\(code))"
        case .decoding(let m): "Couldn't read the reply: \(m)"
        }
    }

    var isNotBuilt: Bool { if case .notBuilt = self { return true } else { return false } }
    var isUnreachable: Bool { if case .unreachable = self { return true } else { return false } }
}
