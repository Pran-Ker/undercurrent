import Foundation

// A task on the board, as the backend sends it (backend/API.md). Fields the backend omits when
// empty decode as "".
enum Stage: String, Codable, CaseIterable, Identifiable {
    case unstaged, staged, committed, closed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unstaged: "Unstaged"
        case .staged: "Staged"
        case .committed: "Running"
        case .closed: "Closed"
        }
    }

    var blurb: String {
        switch self {
        case .unstaged: "Written down, nothing decided."
        case .staged: "Context added, ready."
        case .committed: "An agent is on it."
        case .closed: "Done. Closed is closed."
        }
    }
}

struct BoardTask: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var stage: Stage
    var text: String
    var context: String = ""
    var priority: String = ""
    var due: String = ""
    var tags: [String] = []
    var note: String = ""
    var parentID: String = ""
    var createdBy: String = "user"
    var entry: String = ""
    var done: String = ""
    var updatedAt: String = ""

    enum CodingKeys: String, CodingKey {
        case id, stage, text, context, priority, due, tags, note, entry, done
        case parentID = "parent_id"
        case createdBy = "created_by"
        case updatedAt = "updated_at"
    }

    init(id: String, stage: Stage, text: String, context: String = "", priority: String = "",
         due: String = "", tags: [String] = [], note: String = "", parentID: String = "",
         createdBy: String = "user", entry: String = "", done: String = "", updatedAt: String = "") {
        self.id = id; self.stage = stage; self.text = text; self.context = context
        self.priority = priority; self.due = due; self.tags = tags; self.note = note
        self.parentID = parentID; self.createdBy = createdBy; self.entry = entry
        self.done = done; self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        stage = Stage(rawValue: try c.decodeIfPresent(String.self, forKey: .stage) ?? "") ?? .unstaged
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        context = try c.decodeIfPresent(String.self, forKey: .context) ?? ""
        priority = try c.decodeIfPresent(String.self, forKey: .priority) ?? ""
        due = try c.decodeIfPresent(String.self, forKey: .due) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        parentID = try c.decodeIfPresent(String.self, forKey: .parentID) ?? ""
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy) ?? "user"
        entry = try c.decodeIfPresent(String.self, forKey: .entry) ?? ""
        done = try c.decodeIfPresent(String.self, forKey: .done) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }

    var isOpen: Bool { stage != .closed }
    var entryDate: Date? { Dates.day(entry) }
    var dueDate: Date? { Dates.day(due) }
    var doneDate: Date? { Dates.day(done) }

    var priorityLabel: String {
        switch priority {
        case "H": "High"
        case "M": "Medium"
        case "L": "Low"
        default: ""
        }
    }
}

// An event: who did what to which task, with the task before and after.
struct Event: Codable, Identifiable, Equatable {
    var id: Int
    var at: String
    var actor: String
    var action: String
    var taskID: String = ""
    var runID: String = ""
    var before: BoardTask?
    var after: BoardTask?
    var note: String = ""

    enum CodingKeys: String, CodingKey {
        case id, at, actor, action, before, after, note
        case taskID = "task_id"
        case runID = "run_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        at = try c.decodeIfPresent(String.self, forKey: .at) ?? ""
        actor = try c.decodeIfPresent(String.self, forKey: .actor) ?? ""
        action = try c.decodeIfPresent(String.self, forKey: .action) ?? ""
        taskID = try c.decodeIfPresent(String.self, forKey: .taskID) ?? ""
        runID = try c.decodeIfPresent(String.self, forKey: .runID) ?? ""
        before = try? c.decodeIfPresent(BoardTask.self, forKey: .before)
        after = try? c.decodeIfPresent(BoardTask.self, forKey: .after)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }

    init(id: Int, at: String, actor: String, action: String, taskID: String = "", runID: String = "",
         before: BoardTask? = nil, after: BoardTask? = nil, note: String = "") {
        self.id = id; self.at = at; self.actor = actor; self.action = action; self.taskID = taskID
        self.runID = runID; self.before = before; self.after = after; self.note = note
    }

    var atDate: Date? { Dates.timestamp(at) }

    // "user", "agent:<run>", "live:<conversation>" → a word.
    var actorKind: String {
        if actor.hasPrefix("agent") { return "agent" }
        if actor.hasPrefix("live") { return "live" }
        return actor.isEmpty ? "user" : actor
    }
}

// A run: an agent working a committed task, or retransforming a staged one (API.md, not built
// yet on the backend; the app is written against the contract).
struct Run: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case queued, running, needsYou = "needs_you", done, failed }
    var id: String
    var taskID: String
    var kind: String
    var status: Status
    var question: String = ""
    var answer: String = ""
    var steps: [String] = []
    var result: String = ""
    var startedAt: String = ""
    var endedAt: String = ""

    enum CodingKeys: String, CodingKey {
        case id, kind, status, question, answer, steps, result
        case taskID = "task_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }

    init(id: String, taskID: String, kind: String, status: Status, question: String = "", answer: String = "",
         steps: [String] = [], result: String = "", startedAt: String = "", endedAt: String = "") {
        self.id = id; self.taskID = taskID; self.kind = kind; self.status = status; self.question = question
        self.answer = answer; self.steps = steps; self.result = result; self.startedAt = startedAt; self.endedAt = endedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        taskID = try c.decodeIfPresent(String.self, forKey: .taskID) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        status = Status(rawValue: try c.decodeIfPresent(String.self, forKey: .status) ?? "") ?? .queued
        question = try c.decodeIfPresent(String.self, forKey: .question) ?? ""
        answer = try c.decodeIfPresent(String.self, forKey: .answer) ?? ""
        result = try c.decodeIfPresent(String.self, forKey: .result) ?? ""
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt) ?? ""
        endedAt = try c.decodeIfPresent(String.self, forKey: .endedAt) ?? ""
        // Steps may arrive as strings, as objects with a "text", or as a JSON string.
        if let s = try? c.decodeIfPresent([String].self, forKey: .steps) {
            steps = s
        } else if let objs = try? c.decodeIfPresent([[String: AnyCodable]].self, forKey: .steps) {
            steps = objs.map { $0["text"]?.string ?? $0["step"]?.string ?? $0.description }
        } else if let raw = try? c.decodeIfPresent(String.self, forKey: .steps),
                  let data = raw.data(using: .utf8),
                  let s = try? JSONDecoder().decode([String].self, from: data) {
            steps = s
        } else {
            steps = []
        }
    }

    var statusLabel: String {
        switch status {
        case .queued: "queued"
        case .running: "running"
        case .needsYou: "needs you"
        case .done: "done"
        case .failed: "failed"
        }
    }
}

// Just enough dynamic JSON to read a run step whose shape is not fixed yet.
struct AnyCodable: Codable, CustomStringConvertible {
    let value: Any
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = i }
        else if let d = try? c.decode(Double.self) { value = d }
        else if let b = try? c.decode(Bool.self) { value = b }
        else if let a = try? c.decode([AnyCodable].self) { value = a.map(\.value) }
        else if let o = try? c.decode([String: AnyCodable].self) { value = o.mapValues(\.value) }
        else { value = NSNull() }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let s = value as? String { try c.encode(s) }
        else if let i = value as? Int { try c.encode(i) }
        else if let d = value as? Double { try c.encode(d) }
        else if let b = value as? Bool { try c.encode(b) }
        else { try c.encodeNil() }
    }
    var string: String? { value as? String }
    var description: String { "\(value)" }
}

struct Health: Codable { var ok: Bool; var tasks: Int }

// Calendar days ("2026-10-20") are read in the device's own timezone: the backend's dates carry
// no time, and a due date must mean that day where the user is. Timestamps are UTC RFC 3339.
enum Dates {
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func day(_ s: String) -> Date? { s.isEmpty ? nil : dayFormatter.date(from: s) }
    static func timestamp(_ s: String) -> Date? { s.isEmpty ? nil : timestampFormatter.date(from: s) }
    static func dayString(_ d: Date) -> String { dayFormatter.string(from: d) }

    // "2026-10-20" → "20 Oct"; today/tomorrow/yesterday in words.
    static func short(_ s: String, now: Date = .now) -> String {
        guard let d = day(s) else { return s }
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return "today" }
        if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: t) { return "tomorrow" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "yesterday" }
        let f = DateFormatter()
        f.dateFormat = cal.component(.year, from: d) == cal.component(.year, from: now) ? "d MMM" : "d MMM yyyy"
        return f.string(from: d)
    }

    static func daysBetween(_ a: Date, _ b: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: a), to: calendar.startOfDay(for: b)).day ?? 0
    }
}
