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
    // The key this mock was "started with" (UNDERCURRENT_API_KEY); empty means open, like a local backend.
    static var requiredKey = ""

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
                    steps: ["Searched plumbers within 3 miles", "Checked Tuesday morning availability", "Compared quotes"],
                    costCents: 4, startedAt: Dates.timestampFormatter.string(from: .now))]
        events = []
        nextEvent = 1
        record("add", before: nil, after: tasks[0], actor: "user")
        record("stage", before: BoardTask(id: "g7h8", stage: .unstaged, text: "File the Q3 taxes"), after: tasks[3], actor: "user")
    }

    private func record(_ action: String, before: BoardTask?, after: BoardTask?, actor: String, runID: String = "", note: String = "") {
        events.append(Event(id: nextEvent, at: Dates.timestampFormatter.string(from: .now), actor: actor, action: action,
                            taskID: after?.id ?? before?.id ?? "", runID: runID, before: before, after: after, note: note))
        nextEvent += 1
    }

    // MARK: The simulated agent. It moves one step every time the runs are read, the way the real
    // one moves between two polls: queued → needs_you with a question; answered → done, the task
    // closed with a note and the next step landed unstaged with parent_id.

    private func advance() {
        for i in runs.indices {
            let run = runs[i]
            guard let t = tasks.firstIndex(where: { $0.id == run.taskID }) else { continue }
            let actor = "agent:" + run.id
            switch run.status {
            case .queued:
                runs[i].status = .needsYou
                runs[i].question = "Before I go on with “\(tasks[t].text)”: should I favour the cheapest option or the fastest?"
                runs[i].steps.append("Read the task and its context")
                runs[i].costCents += 3
                record("ask", before: tasks[t], after: tasks[t], actor: actor, runID: run.id, note: runs[i].question)
            case .running:
                let before = tasks[t]
                let note = "Done. Went with your answer: “\(run.answer)”."
                tasks[t].stage = .closed
                tasks[t].done = Dates.dayString(.now)
                tasks[t].note = tasks[t].note.isEmpty ? note : tasks[t].note + "\n" + note
                tasks[t].updatedAt = Dates.timestampFormatter.string(from: .now)
                record("close", before: before, after: tasks[t], actor: actor, runID: run.id, note: note)
                let child = BoardTask(id: newID(), stage: .unstaged, text: "Follow up on: \(before.text)", tags: before.tags,
                                      parentID: before.id, createdBy: "agent", entry: Dates.dayString(.now),
                                      updatedAt: Dates.timestampFormatter.string(from: .now))
                tasks.append(child)
                record("add", before: nil, after: child, actor: actor, runID: run.id, note: "the next step")
                runs[i].status = .done
                runs[i].result = note
                runs[i].steps.append("Finished with the answer")
                runs[i].costCents += 5
                runs[i].endedAt = Dates.timestampFormatter.string(from: .now)
            default: break
            }
        }
    }

    // A run as the backend sends it: steps are {at, kind, cmd, exit, ms, output} objects.
    private func wire(_ r: Run) -> [String: Any] {
        ["id": r.id, "task_id": r.taskID, "kind": r.kind, "status": r.status.rawValue,
         "question": r.question, "answer": r.answer, "result": r.result, "cost_cents": r.costCents,
         "started_at": r.startedAt, "ended_at": r.endedAt,
         "steps": r.steps.enumerated().map { i, s in
             ["at": r.startedAt, "kind": "agent", "cmd": "claude -p --output-format json", "exit": 0, "ms": 1200 * (i + 1), "output": s] as [String: Any]
         }]
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
        if !Self.requiredKey.isEmpty {
            let bearer = req.value(forHTTPHeaderField: "Authorization") ?? ""
            let given = bearer.hasPrefix("Bearer ") ? String(bearer.dropFirst(7)) : (req.value(forHTTPHeaderField: "X-Api-Key") ?? "")
            if given != Self.requiredKey {
                return error(401, "this backend needs its key: Authorization: Bearer <UNDERCURRENT_API_KEY>")
            }
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
            guard let i = tasks.firstIndex(where: { $0.id == c[0] }) else { return error(404, "no such task") }
            guard tasks[i].stage == .staged else { return error(409, "only a staged task can be committed") }
            let before = tasks[i]
            tasks[i].stage = .committed
            tasks[i].updatedAt = Dates.timestampFormatter.string(from: .now)
            let run = Run(id: newID(), taskID: c[0], kind: "commit", status: .queued, startedAt: Dates.timestampFormatter.string(from: .now))
            runs.append(run)
            record("commit", before: before, after: tasks[i], actor: actor, runID: run.id)
            return json(wire(run), status: 202)
        }
        if let c = at("POST", "tasks", "*", "retransform") {
            guard let instruction = (body["instruction"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !instruction.isEmpty else {
                return error(400, "instruction is required")
            }
            guard let i = tasks.firstIndex(where: { $0.id == c[0] }) else { return error(404, "no such task") }
            guard tasks[i].stage == .staged else { return error(409, "only a staged task can be retransformed") }
            let now = Dates.timestampFormatter.string(from: .now)
            let say = "Added to the context: \(instruction)"
            let run = Run(id: newID(), taskID: c[0], kind: "retransform", status: .done,
                          steps: ["Read the instruction", "Enriched the context"], result: say, costCents: 2, startedAt: now, endedAt: now)
            runs.append(run)
            let before = tasks[i]
            tasks[i].context = before.context.isEmpty ? instruction : before.context + "\n" + instruction
            tasks[i].updatedAt = now
            record("retransform", before: before, after: tasks[i], actor: "agent:" + run.id, runID: run.id, note: instruction)
            return json(["run": wire(run), "say": say])
        }
        if at("GET", "runs") != nil {
            advance()
            let task = query.first { $0.name == "task" }?.value
            return json(runs.reversed().filter { task == nil || $0.taskID == task }.map(wire))
        }
        if let c = at("GET", "runs", "*") {
            guard let r = runs.first(where: { $0.id == c[0] }) else { return error(404, "no such run") }
            return json(wire(r))
        }
        if let c = at("POST", "runs", "*", "answer") {
            guard let answer = (body["answer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty else {
                return error(400, "answer is required")
            }
            guard let i = runs.firstIndex(where: { $0.id == c[0] }) else { return error(404, "no such run") }
            guard runs[i].status == .needsYou else { return error(409, "this run is not waiting for an answer") }
            runs[i].answer = answer
            runs[i].status = .running
            runs[i].steps.append("You answered: \(answer)")
            if let t = tasks.first(where: { $0.id == runs[i].taskID }) {
                record("answer", before: t, after: t, actor: actor, runID: runs[i].id, note: answer)
            }
            return json(wire(runs[i]), status: 202)
        }
        if at("GET", "events") != nil {
            let task = query.first { $0.name == "task" }?.value
            let actorQ = query.first { $0.name == "actor" }?.value
            var out = events.filter { (task == nil || $0.taskID == task) && (actorQ == nil || $0.actor == actorQ) }
            if let n = Int(query.first { $0.name == "limit" }?.value ?? ""), n > 0, out.count > n { out = Array(out.suffix(n)) }
            return encode(out)
        }
        if at("GET", "state") != nil {
            guard let atQ = query.first(where: { $0.name == "at" })?.value, !atQ.isEmpty else { return error(400, "at is required") }
            struct State: Encodable { var at: String; var tasks: [BoardTask] }
            var latest: [String: BoardTask] = [:]
            var order: [String] = []
            for e in events where e.at <= atQ {
                guard let t = e.after else { continue }
                if latest[t.id] == nil { order.append(t.id) }
                latest[t.id] = t
            }
            return encode(State(at: atQ, tasks: order.compactMap { latest[$0] }))
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
            if id.contains(where: \.isNumber), !tasks.contains(where: { $0.id == id }), !runs.contains(where: { $0.id == id }) { return id }
        }
    }

    private func encode<T: Encodable>(_ v: T, status: Int = 200) -> Reply {
        Reply(status: status, body: (try? JSONEncoder().encode(v)) ?? Data("null".utf8))
    }
    private func json(_ v: Any, status: Int = 200) -> Reply {
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
