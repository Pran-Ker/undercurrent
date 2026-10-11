import Foundation
import Observation

// The board as the app sees it: fetched on focus and after every action. The backend is the truth;
// nothing is cached across launches. While a task is committed the board polls (API.md "For the
// app"): there is no push.
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
    @ObservationIgnored var pollInterval: Duration = .seconds(3)
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var inflight: Task<Void, Never>?
    @ObservationIgnored private var again = false

    init(backend: Backend) { self.backend = backend }

    // The app's board: the mock when launched with -mockBackend, else the configured backend.
    static func live() -> Board {
        if MockBackend.isEnabled {
            return Board(backend: Backend(baseURL: MockBackend.baseURL, session: MockURLProtocol.session))
        }
        return Board(backend: Backend(baseURL: Backend.configuredURL(), apiKey: Backend.configuredKey()))
    }

    func use(url: URL, key: String? = nil) {
        backend = Backend(baseURL: url, actor: backend.actor, session: backend.session, apiKey: key ?? backend.apiKey)
        tasks = []; events = []; runs = []; lastSync = nil; error = nil
        stopPolling()
    }

    // MARK: Derived

    func tasks(in stage: Stage) -> [BoardTask] { tasks.filter { $0.stage == stage } }
    func task(_ id: String) -> BoardTask? { tasks.first { $0.id == id } }
    func children(of id: String) -> [BoardTask] { tasks.filter { $0.parentID == id } }
    // GET /runs is newest first, so the first match is the task's current run.
    func run(for taskID: String) -> Run? { runs.first { $0.taskID == taskID } }
    func events(for taskID: String) -> [Event] { events.filter { $0.taskID == taskID } }
    var counts: [Stage: Int] { Dictionary(grouping: tasks, by: \.stage).mapValues(\.count) }
    var needsYou: [Run] { runs.filter { $0.status == .needsYou } }
    var polling: Bool { poller != nil }

    // MARK: Sync

    // A refresh asked for while one is running makes it go round once more and waits for that, so
    // an action's refetch is never dropped under a poll.
    func refresh() async {
        if let inflight { again = true; await inflight.value; return }
        let t = Task { await cycle() }
        inflight = t
        await t.value
        inflight = nil
    }

    private func cycle() async {
        loading = true
        repeat { again = false; await sync() } while again
        loading = false
        poll()
    }

    private func sync() async {
        await refreshRuns()
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
    }

    // Runs come first so one refresh shows a run's outcome and the task it closed together.
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

    private func poll() {
        guard tasks.contains(where: { $0.stage == .committed }) else { return stopPolling() }
        guard poller == nil else { return }
        let interval = pollInterval
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    func stopPolling() {
        poller?.cancel()
        poller = nil
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
    func commit(_ id: String) async throws -> Run {
        try await perform { try await backend.commit(id) }
    }

    @discardableResult
    func retransform(_ id: String, instruction: String) async throws -> Retransform {
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
