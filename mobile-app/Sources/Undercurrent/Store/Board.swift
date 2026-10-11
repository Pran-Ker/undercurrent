import Foundation
import Observation

// The board as the app sees it: fetched on focus and after every action. The backend is the truth;
// nothing is cached across launches.
@Observable @MainActor
final class Board {
    private(set) var tasks: [BoardTask] = []
    private(set) var events: [Event] = []
    private(set) var runs: [Run] = []
    private(set) var runsAvailable = true
    private(set) var loading = false
    private(set) var lastSync: Date?
    var error: BackendError?
    private(set) var backend: Backend

    init(backend: Backend) { self.backend = backend }

    // The app's board: the mock when launched with -mockBackend, else the configured backend.
    static func live() -> Board {
        if MockBackend.isEnabled {
            return Board(backend: Backend(baseURL: MockBackend.baseURL, session: MockURLProtocol.session))
        }
        return Board(backend: Backend(baseURL: Backend.configuredURL()))
    }

    func use(url: URL) {
        backend = Backend(baseURL: url, actor: backend.actor, session: backend.session)
        tasks = []; events = []; runs = []; lastSync = nil; error = nil
    }

    // MARK: Derived

    func tasks(in stage: Stage) -> [BoardTask] { tasks.filter { $0.stage == stage } }
    func task(_ id: String) -> BoardTask? { tasks.first { $0.id == id } }
    func children(of id: String) -> [BoardTask] { tasks.filter { $0.parentID == id } }
    func run(for taskID: String) -> Run? {
        runs.filter { $0.taskID == taskID }.sorted { $0.startedAt > $1.startedAt }.first
    }
    func events(for taskID: String) -> [Event] { events.filter { $0.taskID == taskID } }
    var counts: [Stage: Int] { Dictionary(grouping: tasks, by: \.stage).mapValues(\.count) }
    var needsYou: [Run] { runs.filter { $0.status == .needsYou } }

    // MARK: Sync

    func refresh() async {
        if loading { return }
        loading = true
        defer { loading = false }
        do {
            async let t = backend.tasks()
            async let e = backend.events()
            let (tasks, events) = try await (t, e)
            self.tasks = tasks
            self.events = events
            error = nil
            lastSync = .now
        } catch let e as BackendError {
            error = e
        } catch {
            self.error = .http(0, error.localizedDescription)
        }
        await refreshRuns()
    }

    private func refreshRuns() async {
        do {
            runs = try await backend.runs()
            runsAvailable = true
        } catch let e as BackendError where e.isNotBuilt {
            runs = []
            runsAvailable = false
        } catch {
            // Runs are secondary; a failure here leaves the last known set.
        }
    }

    // MARK: Actions. Each one calls the backend, then refetches; the board is never edited locally.

    @discardableResult
    func add(text: String, tags: [String] = [], priority: String = "", due: String = "") async throws -> BoardTask {
        try await perform { try await backend.add(text: text, tags: tags, priority: priority, due: due) }
    }

    @discardableResult
    func stage(_ id: String, context: String) async throws -> BoardTask {
        try await perform { try await backend.stage(id, context: context) }
    }

    @discardableResult
    func edit(_ id: String, text: String? = nil, context: String? = nil, tags: [String]? = nil) async throws -> BoardTask {
        try await perform { try await backend.edit(id, text: text, context: context, tags: tags) }
    }

    @discardableResult
    func close(_ id: String) async throws -> BoardTask {
        try await perform { try await backend.close(id) }
    }

    @discardableResult
    func commit(_ id: String) async throws -> BoardTask {
        try await perform { try await backend.commit(id) }
    }

    @discardableResult
    func retransform(_ id: String, instruction: String) async throws -> BoardTask {
        try await perform { try await backend.retransform(id, instruction: instruction) }
    }

    @discardableResult
    func answer(run id: String, _ answer: String) async throws -> Run {
        try await perform { try await backend.answer(run: id, answer) }
    }

    private func perform<T>(_ op: () async throws -> T) async throws -> T {
        do {
            let result = try await op()
            await refresh()
            return result
        } catch let e as BackendError {
            if !e.isNotBuilt && !e.isUnreachable { await refresh() }
            throw e
        }
    }
}
