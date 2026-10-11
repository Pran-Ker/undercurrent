import Foundation

// An in-process stand-in for the backend, used by UI tests and previews (launch with
// -mockBackend). It implements API.md over an in-memory board so tests never touch a database.
// The fixture is test data that lives only in this process.
final class MockBackend: @unchecked Sendable {
    static let shared = MockBackend()

    private let lock = NSLock()
    private(set) var tasks: [BoardTask] = []
    private(set) var events: [Event] = []
    private var runs: [Run] = []
    private var nextEvent = 1
    var notBuilt: Set<String> = ["commit", "retransform", "runs", "answer", "signed-url"]

    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-mockBackend") }
    static let baseURL = URL(string: "http://mock.undercurrent.test")!

    init() { reset() }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        let today = Dates.dayString(.now)
        let cal = Calendar(identifier: .gregorian)
        func daysAgo(_ n: Int) -> String { Dates.dayString(cal.date(byAdding: .day, value: -n, to: .now)!) }
        func daysAhead(_ n: Int) -> String { Dates.dayString(cal.date(byAdding: .day, value: n, to: .now)!) }
        tasks = [
            BoardTask(id: "a1b2", stage: .unstaged, text: "Book the dentist", tags: ["health"], entry: daysAgo(3), updatedAt: Dates.timestampFormatter.string(from: .now)),
            BoardTask(id: "c3d4", stage: .unstaged, text: "Renew the passport", entry: daysAgo(20)),
            BoardTask(id: "e5f6", stage: .unstaged, text: "Reply to the landlord about the lease", tags: ["home"], entry: daysAgo(1)),
            BoardTask(id: "g7h8", stage: .staged, text: "File the Q3 taxes", context: "Use the accountant's checklist; receipts are in Drive.", priority: "H", due: daysAhead(5), tags: ["money"], entry: daysAgo(10)),
            BoardTask(id: "i9j0", stage: .staged, text: "Plan the trip to Lisbon", context: "Mid-November, four nights, near Alfama.", priority: "M", due: daysAhead(30), tags: ["travel"], entry: daysAgo(6)),
            BoardTask(id: "k1l2", stage: .staged, text: "Fix the kitchen tap", context: "Landlord prefers mornings.", priority: "L", due: daysAgo(2), tags: ["home"], entry: daysAgo(14)),
            BoardTask(id: "m3n4", stage: .committed, text: "Find a plumber for the leak", context: "Under the sink, slow drip, weekday mornings.", priority: "H", tags: ["home"], entry: daysAgo(2)),
            BoardTask(id: "o5p6", stage: .closed, text: "Cancel the old gym membership", context: "Called, confirmed by email.", tags: ["money"], entry: daysAgo(30), done: daysAgo(9)),
            BoardTask(id: "q7r8", stage: .closed, text: "Send the signed contract", priority: "H", tags: ["work"], entry: daysAgo(12), done: daysAgo(2)),
            BoardTask(id: "s9t0", stage: .closed, text: "Order a new charger", entry: daysAgo(5), done: today),
        ]
        runs = [Run(id: "r001", taskID: "m3n4", kind: "commit", status: .needsYou,
                    question: "Two plumbers can come Tuesday 9am: Ace (£80) or Flow (£65, 4.8★). Which one?",
                    steps: ["Searched plumbers within 3 miles", "Checked Tuesday morning availability", "Compared quotes"])]
        events = []
        nextEvent = 1
        record("add", before: nil, after: tasks[0], actor: "user")
        record("stage", before: BoardTask(id: "g7h8", stage: .unstaged, text: "File the Q3 taxes"), after: tasks[3], actor: "user")
    }

    private func record(_ action: String, before: BoardTask?, after: BoardTask?, actor: String, note: String = "") {
        events.append(Event(id: nextEvent, at: Dates.timestampFormatter.string(from: .now), actor: actor, action: action,
                            taskID: after?.id ?? before?.id ?? "", before: before, after: after, note: note))
        nextEvent += 1
    }

    // MARK: Routing

    struct Reply { var status: Int; var body: Data }

    func handle(_ req: URLRequest) -> Reply {
        lock.lock(); defer { lock.unlock() }
        let path = req.url?.path ?? "/"
        let method = req.httpMethod ?? "GET"
        let query = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let actor = req.value(forHTTPHeaderField: "X-Actor") ?? "user"
        let body = (req.httpBody ?? Self.bodyStream(req)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let parts = path.split(separator: "/").map(String.init)

        // Route on method and a path shape: a literal segment matches itself, "*" captures.
        func at(_ m: String, _ shape: String...) -> [String]? {
            guard method == m, shape.count == parts.count else { return nil }
            var captured: [String] = []
            for (want, got) in zip(shape, parts) {
                if want == "*" { captured.append(got) } else if want != got { return nil }
            }
            return captured
        }

        if at("GET", "health") != nil {
            return json(["ok": true, "tasks": tasks.count])
        }
        if at("GET", "tasks") != nil {
            let stage = query.first { $0.name == "stage" }?.value
            return encode(tasks.filter { stage == nil || $0.stage.rawValue == stage })
        }
        if let c = at("GET", "tasks", "*") {
            guard let t = tasks.first(where: { $0.id == c[0] }) else { return error(404, "no such task") }
            return encode(t)
        }
        if at("POST", "tasks") != nil {
            guard let text = (body["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return error(400, "text is required")
            }
            var t = BoardTask(id: newID(), stage: .unstaged, text: text, entry: Dates.dayString(.now),
                              updatedAt: Dates.timestampFormatter.string(from: .now))
            t.tags = body["tags"] as? [String] ?? []
            t.priority = body["priority"] as? String ?? ""
            t.due = body["due"] as? String ?? ""
            t.context = body["context"] as? String ?? ""
            t.parentID = body["parent_id"] as? String ?? ""
            t.createdBy = actor
            if body["stage"] as? String == "staged", !t.context.isEmpty { t.stage = .staged }
            tasks.append(t)
            record("add", before: nil, after: t, actor: actor)
            return encode(t, status: 201)
        }
        if let c = at("PATCH", "tasks", "*") {
            guard let i = tasks.firstIndex(where: { $0.id == c[0] }) else { return error(404, "no such task") }
            guard tasks[i].stage != .closed else { return error(409, "closed tasks are not edited") }
            let before = tasks[i]
            if let text = body["text"] as? String { tasks[i].text = text }
            if let context = body["context"] as? String { tasks[i].context = context }
            if let tags = body["tags"] as? [String] { tasks[i].tags = tags }
            tasks[i].updatedAt = Dates.timestampFormatter.string(from: .now)
            record("edit", before: before, after: tasks[i], actor: actor)
            return encode(tasks[i])
        }
        if let c = at("POST", "tasks", "*", "stage") {
            guard let i = tasks.firstIndex(where: { $0.id == c[0] }) else { return error(404, "no such task") }
            guard tasks[i].stage == .unstaged || tasks[i].stage == .staged else { return error(409, "only an unstaged or staged task can be staged") }
            guard let context = body["context"] as? String, !context.isEmpty else { return error(400, "context is required") }
            let before = tasks[i]
            tasks[i].stage = .staged
            tasks[i].context = context
            tasks[i].updatedAt = Dates.timestampFormatter.string(from: .now)
            record("stage", before: before, after: tasks[i], actor: actor)
            return encode(tasks[i])
        }
        if let c = at("POST", "tasks", "*", "close") {
            guard let i = tasks.firstIndex(where: { $0.id == c[0] }) else { return error(404, "no such task") }
            guard tasks[i].stage != .closed else { return error(409, "already closed") }
            guard tasks[i].stage != .committed else { return error(409, "the agent has it; wait for the run") }
            let before = tasks[i]
            tasks[i].stage = .closed
            tasks[i].done = Dates.dayString(.now)
            tasks[i].updatedAt = Dates.timestampFormatter.string(from: .now)
            record("close", before: before, after: tasks[i], actor: actor)
            return encode(tasks[i])
        }
        if let c = at("POST", "tasks", "*", "commit") {
            if notBuilt.contains("commit") { return error(501, "not built yet") }
            guard let i = tasks.firstIndex(where: { $0.id == c[0] }) else { return error(404, "no such task") }
            guard tasks[i].stage == .staged else { return error(409, "only a staged task can be committed") }
            let before = tasks[i]
            tasks[i].stage = .committed
            runs.append(Run(id: newID(), taskID: c[0], kind: "commit", status: .queued))
            record("commit", before: before, after: tasks[i], actor: actor)
            return encode(tasks[i])
        }
        if at("POST", "tasks", "*", "retransform") != nil {
            return error(501, "not built yet")
        }
        if at("GET", "runs") != nil {
            if notBuilt.contains("runs") { return error(501, "not built yet") }
            let task = query.first { $0.name == "task" }?.value
            return encode(runs.filter { task == nil || $0.taskID == task })
        }
        if let c = at("GET", "runs", "*") {
            if notBuilt.contains("runs") { return error(501, "not built yet") }
            guard let r = runs.first(where: { $0.id == c[0] }) else { return error(404, "no such run") }
            return encode(r)
        }
        if let c = at("POST", "runs", "*", "answer") {
            if notBuilt.contains("answer") { return error(501, "not built yet") }
            guard let i = runs.firstIndex(where: { $0.id == c[0] }) else { return error(404, "no such run") }
            runs[i].answer = body["answer"] as? String ?? ""
            runs[i].status = .running
            return encode(runs[i])
        }
        if at("GET", "events") != nil {
            let task = query.first { $0.name == "task" }?.value
            let actorQ = query.first { $0.name == "actor" }?.value
            return encode(events.filter { (task == nil || $0.taskID == task) && (actorQ == nil || $0.actor == actorQ) })
        }
        if at("GET", "live", "signed-url") != nil {
            return error(501, "not built yet")
        }
        return error(404, "no route")
    }

    private static func bodyStream(_ req: URLRequest) -> Data? {
        guard let stream = req.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        let size = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: size)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }

    private func newID() -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        while true {
            let id = String((0..<4).map { _ in alphabet.randomElement()! })
            if id.contains(where: \.isNumber), !tasks.contains(where: { $0.id == id }) { return id }
        }
    }

    private func encode<T: Encodable>(_ v: T, status: Int = 200) -> Reply {
        Reply(status: status, body: (try? JSONEncoder().encode(v)) ?? Data("null".utf8))
    }
    private func json(_ v: [String: Any], status: Int = 200) -> Reply {
        Reply(status: status, body: (try? JSONSerialization.data(withJSONObject: v)) ?? Data())
    }
    private func error(_ status: Int, _ message: String) -> Reply { json(["error": message], status: status) }
}

// Routes every request for MockBackend.baseURL into MockBackend.shared.
final class MockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == MockBackend.baseURL.host
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = MockBackend.shared.handle(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }()
}
