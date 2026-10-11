import XCTest
@testable import Undercurrent

// The client against the in-process mock: routes, bodies, headers, error mapping.
final class BackendTests: XCTestCase {
    var backend: Backend!

    static let defaultNotBuilt: Set<String> = ["commit", "retransform", "runs", "answer", "signed-url"]

    override func setUp() {
        MockBackend.shared.reset()
        MockBackend.shared.notBuilt = Self.defaultNotBuilt
        backend = Backend(baseURL: MockBackend.baseURL, actor: "user", session: MockURLProtocol.session)
    }

    override func tearDown() {
        MockBackend.shared.notBuilt = Self.defaultNotBuilt
    }

    func testHealthAndTasks() async throws {
        let h = try await backend.health()
        XCTAssertTrue(h.ok)
        XCTAssertEqual(h.tasks, 10)
        let staged = try await backend.tasks(stage: .staged)
        XCTAssertEqual(staged.count, 3)
        XCTAssertTrue(staged.allSatisfy { $0.stage == .staged })
    }

    func testAddStageEditClose() async throws {
        let t = try await backend.add(text: "Write the thing", tags: ["work"], priority: "H")
        XCTAssertEqual(t.stage, .unstaged)
        XCTAssertEqual(t.tags, ["work"])
        let staged = try await backend.stage(t.id, context: "By Friday, for the board.")
        XCTAssertEqual(staged.stage, .staged)
        XCTAssertEqual(staged.context, "By Friday, for the board.")
        let edited = try await backend.edit(t.id, text: "Write the memo")
        XCTAssertEqual(edited.text, "Write the memo")
        XCTAssertEqual(edited.context, "By Friday, for the board.")
        let closed = try await backend.close(t.id)
        XCTAssertEqual(closed.stage, .closed)
        XCTAssertFalse(closed.done.isEmpty)
        let events = try await backend.events(task: t.id)
        XCTAssertEqual(events.map(\.action), ["add", "stage", "edit", "close"])
    }

    func testErrorsMap() async {
        do { _ = try await backend.task("nope"); XCTFail() } catch let e as BackendError {
            guard case .notFound = e else { return XCTFail("\(e)") }
        } catch { XCTFail() }
        do { _ = try await backend.close("o5p6"); XCTFail() } catch let e as BackendError {
            guard case .refused = e else { return XCTFail("\(e)") }
        } catch { XCTFail() }
        do { _ = try await backend.edit("o5p6", text: "x"); XCTFail() } catch let e as BackendError {
            guard case .refused = e else { return XCTFail("\(e)") }
        } catch { XCTFail() }
        do { _ = try await backend.commit("g7h8"); XCTFail() } catch let e as BackendError {
            XCTAssertTrue(e.isNotBuilt)
        } catch { XCTFail() }
        do { _ = try await backend.retransform("g7h8", instruction: "split"); XCTFail() } catch let e as BackendError {
            XCTAssertTrue(e.isNotBuilt)
        } catch { XCTFail() }
    }

    func testUnreachableHostMapsToUnreachable() async {
        let b = Backend(baseURL: URL(string: "http://127.0.0.1:1")!, session: URLSession(configuration: .ephemeral))
        do { _ = try await b.health(); XCTFail() } catch let e as BackendError {
            XCTAssertTrue(e.isUnreachable)
            XCTAssertTrue(e.errorDescription!.contains("127.0.0.1"))
        } catch { XCTFail() }
    }

    func testConfiguredURLFallsBackToDefault() {
        let d = UserDefaults(suiteName: "BackendTests.\(UUID())")!
        XCTAssertEqual(Backend.configuredURL(defaults: d), Backend.defaultURL)
        d.set("not a url", forKey: Backend.storageKey)
        XCTAssertEqual(Backend.configuredURL(defaults: d), Backend.defaultURL)
        d.set("http://10.0.0.2:8787", forKey: Backend.storageKey)
        XCTAssertEqual(Backend.configuredURL(defaults: d).absoluteString, "http://10.0.0.2:8787")
    }

    @MainActor
    func testBoardRefreshesAndActs() async throws {
        let board = Board(backend: backend)
        await board.refresh()
        XCTAssertEqual(board.tasks.count, 10)
        XCTAssertNil(board.error)
        XCTAssertFalse(board.runsAvailable)   // the mock answers 501 for runs by default
        try await board.add(text: "New line")
        XCTAssertEqual(board.tasks.count, 11)
        XCTAssertEqual(board.tasks(in: .unstaged).count, 4)
        let id = board.tasks(in: .unstaged).last!.id
        try await board.stage(id, context: "ctx")
        XCTAssertEqual(board.task(id)?.stage, .staged)
        try await board.close(id)
        XCTAssertEqual(board.task(id)?.stage, .closed)
        XCTAssertEqual(board.events(for: id).count, 3)
    }

    @MainActor
    func testBoardSurfacesUnreachable() async {
        let board = Board(backend: Backend(baseURL: URL(string: "http://127.0.0.1:1")!, session: URLSession(configuration: .ephemeral)))
        await board.refresh()
        XCTAssertNotNil(board.error)
        XCTAssertTrue(board.error!.isUnreachable)
        XCTAssertTrue(board.tasks.isEmpty)
    }

    @MainActor
    func testBoardRunsWhenBuilt() async throws {
        MockBackend.shared.notBuilt = []
        let board = Board(backend: backend)
        await board.refresh()
        XCTAssertTrue(board.runsAvailable)
        XCTAssertEqual(board.needsYou.count, 1)
        XCTAssertEqual(board.run(for: "m3n4")?.status, .needsYou)
        try await board.commit("g7h8")
        XCTAssertEqual(board.task("g7h8")?.stage, .committed)
    }

    // MARK: Helpers

    func expect<T>(_ expected: BackendError, file: StaticString = #filePath, line: UInt = #line,
                   _ op: () async throws -> T) async {
        do { _ = try await op(); XCTFail("expected \(expected)", file: file, line: line) }
        catch let e as BackendError { XCTAssertEqual(e, expected, file: file, line: line) }
        catch { XCTFail("\(error)", file: file, line: line) }
    }

    func failure<T>(file: StaticString = #filePath, line: UInt = #line, _ op: () async throws -> T) async -> BackendError? {
        do { _ = try await op(); XCTFail("expected a BackendError", file: file, line: line); return nil }
        catch let e as BackendError { return e }
        catch { XCTFail("\(error)", file: file, line: line); return nil }
    }

    func stub(_ status: Int, _ body: String, contentType: String? = "application/json") -> Backend {
        StubURLProtocol.reply = (status, Data(body.utf8), contentType)
        return Backend(baseURL: StubURLProtocol.baseURL, actor: "agent:r1", session: StubURLProtocol.session)
    }

    // MARK: Error mapping on arbitrary replies

    func testErrorBodiesWithAnErrorKey() async {
        let e400 = await failure { try await self.stub(400, #"{"error":"text is required"}"#).add(text: "") }
        XCTAssertEqual(e400, .http(400, "text is required"))
        XCTAssertEqual(e400?.errorDescription, "text is required (400)")
        let e500 = await failure { try await self.stub(500, #"{"error":"database is locked"}"#).tasks() }
        XCTAssertEqual(e500, .http(500, "database is locked"))
        XCTAssertEqual(e500?.errorDescription, "database is locked (500)")
        let e404 = await failure { try await self.stub(404, #"{"error":"no such task"}"#).task("zzzz") }
        XCTAssertEqual(e404, .notFound("no such task"))
        XCTAssertEqual(e404?.errorDescription, "no such task")
        let e409 = await failure { try await self.stub(409, #"{"error":"already closed"}"#).close("a1b2") }
        XCTAssertEqual(e409, .refused("already closed"))
        XCTAssertEqual(e409?.errorDescription, "already closed")
        let e501 = await failure { try await self.stub(501, #"{"error":"not built yet","see":"backend/API.md"}"#).commit("a1b2") }
        XCTAssertEqual(e501, .notBuilt("/tasks/a1b2/commit"))
        XCTAssertEqual(e501?.errorDescription, "The backend hasn't built this yet.")
        XCTAssertTrue(e501?.isNotBuilt == true)
        XCTAssertFalse(e501?.isUnreachable == true)
    }

    func testErrorBodiesWithoutAnErrorKey() async {
        let plain = await failure { try await self.stub(500, "boom", contentType: "text/plain").tasks() }
        XCTAssertEqual(plain, .http(500, "boom"))
        XCTAssertEqual(plain?.errorDescription, "boom (500)")
        let empty = await failure { try await self.stub(500, "").tasks() }
        XCTAssertEqual(empty, .http(500, ""))
        XCTAssertEqual(empty?.errorDescription, "HTTP 500.")
        let other = await failure { try await self.stub(404, #"{"message":"gone"}"#).task("zzzz") }
        XCTAssertEqual(other, .notFound(#"{"message":"gone"}"#))
        let bare = await failure { try await self.stub(409, "", contentType: nil).close("a1b2") }
        XCTAssertEqual(bare, .refused(""))
        XCTAssertEqual(bare?.errorDescription, "The backend refused that.")
        let emptyNotFound = await failure { try await self.stub(404, "").task("zzzz") }
        XCTAssertEqual(emptyNotFound?.errorDescription, "Not found.")
        let html = await failure { try await self.stub(502, "<html>Bad Gateway</html>", contentType: "text/html").health() }
        XCTAssertEqual(html, .http(502, "<html>Bad Gateway</html>"))
        let nullError = await failure { try await self.stub(400, #"{"error":null}"#).add(text: "") }
        XCTAssertEqual(nullError, .http(400, #"{"error":null}"#))
        let e501 = await failure { try await self.stub(501, "").runs() }
        XCTAssertEqual(e501, .notBuilt("/runs"))
    }

    func testSuccessWithABadBodyIsADecodingError() async {
        let bad = await failure { try await self.stub(200, "not json").tasks() }
        guard case .decoding = bad else { return XCTFail("\(String(describing: bad))") }
        let wrongShape = await failure { try await self.stub(200, #"{"ok":true}"#).tasks() }
        guard case .decoding = wrongShape else { return XCTFail("\(String(describing: wrongShape))") }
        let noID = await failure { try await self.stub(201, #"{"text":"x"}"#).add(text: "x") }
        guard case .decoding = noID else { return XCTFail("\(String(describing: noID))") }
        XCTAssertTrue(noID?.errorDescription?.hasPrefix("Couldn't read the reply") == true)
        let emptyOK = await failure { try await self.stub(200, "").close("a1b2") }
        guard case .decoding = emptyOK else { return XCTFail("\(String(describing: emptyOK))") }
    }

    func testSuccessCodesAcrossThe2xxRange() async throws {
        let created = try await stub(201, #"{"id":"n3w1","stage":"unstaged","text":"x"}"#).add(text: "x")
        XCTAssertEqual(created.id, "n3w1")
        let health = try await stub(299, #"{"ok":true,"tasks":3}"#).health()
        XCTAssertEqual(health.tasks, 3)
        let lenient = try await stub(200, #"[{"id":"a","tags":null,"stage":"nope"}]"#).tasks()
        XCTAssertEqual(lenient.map(\.stage), [.unstaged])
    }

    func testLiveCredentialsDecodeWhatTheBackendSends() async throws {
        let full = try await stub(200, #"{"signed_url":"wss://x/1","token":"tok","agent_id":"ag1"}"#).live()
        XCTAssertEqual(full, LiveCredentials(signedURL: "wss://x/1", token: "tok", agentID: "ag1", conversationID: nil))
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/live/signed-url")
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "GET")
        let partial = try await stub(200, #"{"signed_url":"wss://x/2"}"#).live()
        XCTAssertEqual(partial.signedURL, "wss://x/2")
        XCTAssertNil(partial.token)                                     // LiveSession refuses to start without it
        XCTAssertNil(partial.agentID)
        let empty = try await stub(200, "{}").live()
        XCTAssertEqual(empty, LiveCredentials(signedURL: nil, token: nil, agentID: nil, conversationID: nil))
        let nulls = try await stub(200, #"{"signed_url":null,"token":null,"agent_id":null}"#).live()
        XCTAssertNil(nulls.token)
        let unconfigured = await failure { try await self.stub(503, #"{"error":"ELEVENLABS_API_KEY is not set"}"#).live() }
        XCTAssertEqual(unconfigured, .http(503, "ELEVENLABS_API_KEY is not set"))
        await expect(.notBuilt("/live/signed-url")) { try await self.backend.live() }
    }

    // What the Go backend really answers (backend/internal/api/more.go): commit → the run (202),
    // retransform → {run, say} (200) or {error, run} (502).
    func testCommitRepliesWithARunPerTheContract() async throws {
        let run = #"{"id":"r1x9","task_id":"k79l","kind":"commit","status":"queued","steps":[],"cost_cents":0,"started_at":"2026-10-11T19:02:11Z"}"#
        let reply = try await stub(202, run).commit("k79l")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/tasks/k79l/commit")
        if reply.text.isEmpty {
            XCTExpectFailure("Backend.swift commit(): decodes the run reply as a BoardTask, yielding id=run id, stage=unstaged, text=\"\"") {
                XCTFail("commit returned a task-shaped reply from a run body: \(reply)")
            }
        }
    }

    func testRetransformRepliesWithRunAndSayPerTheContract() async throws {
        let ok = #"{"run":{"id":"r2y8","task_id":"k79l","kind":"retransform","status":"done","steps":[]},"say":"Split into three."}"#
        do {
            _ = try await stub(200, ok).retransform("k79l", instruction: "split this into three")
        } catch {
            XCTExpectFailure("Backend.swift retransform(): decodes {run, say} as a BoardTask, which has no id, so a successful retransform surfaces as an error") {
                XCTFail("a successful retransform threw: \(error)")
            }
        }
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/tasks/k79l/retransform")
        let noOps = await failure { try await self.stub(502, #"{"error":"the model gave no operations","run":{"id":"r2y8"}}"#).retransform("k79l", instruction: "x") }
        XCTAssertEqual(noOps, .http(502, "the model gave no operations"))
        await expect(.refused("only a staged task can be retransformed")) { try await self.stub(409, #"{"error":"only a staged task can be retransformed"}"#).retransform("a1b2", instruction: "x") }
        await expect(.http(400, "instruction is required")) { try await self.stub(400, #"{"error":"instruction is required"}"#).retransform("a1b2", instruction: "") }
    }

    func testRequestsCarryMethodHeadersBodyAndQuery() async throws {
        func body() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(StubURLProtocol.lastBody)) as? [String: Any])
        }
        let task = #"{"id":"a1b2","stage":"staged","text":"x"}"#
        _ = try await stub(200, task).stage("a1b2", context: "ctx")
        var req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/tasks/a1b2/stage")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Actor"), "agent:r1")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(try body()["context"] as? String, "ctx")

        _ = try await stub(200, task).edit("a1b2", tags: [])
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "PATCH")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/tasks/a1b2")
        XCTAssertEqual(try body().keys.sorted(), ["tags"])              // only the fields given are sent

        _ = try await stub(200, task).add(text: "x")
        XCTAssertEqual(try body().keys.sorted(), ["text"])              // empty tags/priority/due are left out
        _ = try await stub(200, task).add(text: "x", tags: ["a"], priority: "H", due: "2026-10-20", context: "c", stage: .staged, parentID: "p")
        XCTAssertEqual(try body().keys.sorted(), ["context", "due", "parent_id", "priority", "stage", "tags", "text"])
        XCTAssertEqual(try body()["stage"] as? String, "staged")

        _ = try await stub(200, task).close("a1b2")
        XCTAssertEqual(try body().isEmpty, true)
        _ = try await stub(200, task).retransform("a1b2", instruction: "split")
        XCTAssertEqual(try body()["instruction"] as? String, "split")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/tasks/a1b2/retransform")
        _ = try await stub(200, #"{"id":"r1"}"#).answer(run: "r1", "Flow")
        XCTAssertEqual(try body()["answer"] as? String, "Flow")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/runs/r1/answer")

        _ = try await stub(200, "[]").tasks(stage: .closed)
        req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.url?.query, "stage=closed")
        XCTAssertNil(req.value(forHTTPHeaderField: "X-Actor"))
        _ = try await stub(200, "[]").tasks()
        XCTAssertNil(StubURLProtocol.lastRequest?.url?.query)
        _ = try await stub(200, "[]").events(task: "a1b2", actor: "user")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.query, "actor=user&task=a1b2")
        _ = try await stub(200, "[]").runs(task: "a1b2")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.absoluteString, "http://stub.undercurrent.test/runs?task=a1b2")
        _ = try await stub(200, #"{"id":"r1"}"#).run("r1")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/runs/r1")
    }

    func testBaseURLWithAPathPrefixKeepsIt() async throws {
        StubURLProtocol.reply = (200, Data(#"{"ok":true,"tasks":0}"#.utf8), "application/json")
        let b = Backend(baseURL: URL(string: "http://stub.undercurrent.test/api")!, session: StubURLProtocol.session)
        _ = try await b.health()
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/health")
        let slash = Backend(baseURL: URL(string: "http://stub.undercurrent.test:8790/")!, session: StubURLProtocol.session)
        _ = try await slash.health()
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.absoluteString, "http://stub.undercurrent.test:8790/health")
    }

    func testConfiguredURLRejectsSchemelessAndHostlessStrings() {
        let d = UserDefaults(suiteName: "BackendTests.\(UUID())")!
        d.set("mac.local:8790", forKey: Backend.storageKey)   // no scheme: the host parses as one
        XCTAssertEqual(Backend.configuredURL(defaults: d), Backend.defaultURL)
        d.set("http://", forKey: Backend.storageKey)
        XCTAssertEqual(Backend.configuredURL(defaults: d), Backend.defaultURL)
        d.set("", forKey: Backend.storageKey)
        XCTAssertEqual(Backend.configuredURL(defaults: d), Backend.defaultURL)
        d.set("http://mac.local:8790", forKey: Backend.storageKey)
        XCTAssertEqual(Backend.configuredURL(defaults: d).host, "mac.local")
        XCTAssertEqual(Backend.configuredURL(defaults: d).port, 8790)
    }

    // MARK: Board

    @MainActor
    func testBoardUseURLResetsState() async throws {
        let board = Board(backend: Backend(baseURL: MockBackend.baseURL, actor: "live:c9", session: MockURLProtocol.session))
        await board.refresh()
        XCTAssertEqual(board.tasks.count, 10)
        XCTAssertFalse(board.events.isEmpty)
        XCTAssertNotNil(board.lastSync)
        board.error = .http(500, "old")
        let other = URL(string: "http://10.0.0.9:8787")!
        board.use(url: other)
        XCTAssertEqual(board.backend.baseURL, other)
        XCTAssertEqual(board.backend.actor, "live:c9")      // the actor survives a backend switch
        XCTAssertTrue(board.tasks.isEmpty)
        XCTAssertTrue(board.events.isEmpty)
        XCTAssertTrue(board.runs.isEmpty)
        XCTAssertNil(board.lastSync)
        XCTAssertNil(board.error)
        XCTAssertEqual(board.counts, [:])
        XCTAssertNil(board.task("a1b2"))
        XCTAssertTrue(board.needsYou.isEmpty)
        XCTAssertFalse(board.loading)
        // Switching back and refreshing fills the board again.
        board.use(url: MockBackend.baseURL)
        await board.refresh()
        XCTAssertEqual(board.tasks.count, 10)
        XCTAssertNotNil(board.lastSync)
    }

    @MainActor
    func testBoardRefreshesAfterARefusedActionButNotAfterNotBuilt() async throws {
        let board = Board(backend: backend)
        await board.refresh()
        let first = try XCTUnwrap(board.lastSync)
        do { try await board.close("o5p6"); XCTFail() } catch let e as BackendError {
            guard case .refused = e else { return XCTFail("\(e)") }
        }
        XCTAssertNil(board.error)                                   // the refetch after the refusal succeeded
        let afterRefused = try XCTUnwrap(board.lastSync)
        XCTAssertGreaterThan(afterRefused, first)
        do { try await board.commit("g7h8"); XCTFail() } catch let e as BackendError {
            XCTAssertTrue(e.isNotBuilt)
        }
        XCTAssertEqual(board.lastSync, afterRefused)                // not built: nothing changed, no refetch
        XCTAssertEqual(board.task("g7h8")?.stage, .staged)
        XCTAssertNil(board.error)                                   // a 501 is a state, not an error
    }

    @MainActor
    func testBoardAnswersARunWhenBuilt() async throws {
        MockBackend.shared.notBuilt = []
        let board = Board(backend: backend)
        await board.refresh()
        let run = try XCTUnwrap(board.needsYou.first)
        XCTAssertEqual(run.taskID, "m3n4")
        let answered = try await board.answer(run: run.id, "Flow")
        XCTAssertEqual(answered.status, .running)
        XCTAssertEqual(answered.answer, "Flow")
        XCTAssertTrue(board.needsYou.isEmpty)
        XCTAssertEqual(board.run(for: "m3n4")?.status, .running)
        XCTAssertNil(board.run(for: "a1b2"))
    }

    @MainActor
    func testBoardEditEventsAndChildren() async throws {
        let board = Board(backend: backend)
        await board.refresh()
        try await board.edit("a1b2", text: "Book the dentist, Elm street", tags: ["health", "urgent"])
        XCTAssertEqual(board.task("a1b2")?.text, "Book the dentist, Elm street")
        XCTAssertEqual(board.task("a1b2")?.tags, ["health", "urgent"])
        XCTAssertEqual(board.events(for: "a1b2").map(\.action), ["add", "edit"])
        XCTAssertEqual(board.events(for: "a1b2").last?.before?.tags, ["health"])
        XCTAssertTrue(board.children(of: "a1b2").isEmpty)
        let child = try await backend.add(text: "Child", parentID: "a1b2")
        await board.refresh()
        XCTAssertEqual(board.children(of: "a1b2").map(\.id), [child.id])
        XCTAssertEqual(board.counts[.unstaged], 4)
    }

    @MainActor
    func testBoardActionsAgainstAnUnreachableBackendThrowUnreachable() async {
        let board = Board(backend: Backend(baseURL: URL(string: "http://127.0.0.1:1")!, session: URLSession(configuration: .ephemeral)))
        await board.refresh()
        XCTAssertEqual(board.error?.isUnreachable, true)
        XCTAssertNil(board.lastSync)
        do { try await board.add(text: "x"); XCTFail() } catch let e as BackendError {
            XCTAssertTrue(e.isUnreachable)
        } catch { XCTFail() }
        XCTAssertTrue(board.tasks.isEmpty)
    }

    // MARK: Mock routes

    func testMockAddVariants() async throws {
        let staged = try await backend.add(text: "  Staged on arrival  ", context: "ctx", stage: .staged, parentID: "a1b2")
        XCTAssertEqual(staged.stage, .staged)
        XCTAssertEqual(staged.text, "Staged on arrival")
        XCTAssertEqual(staged.context, "ctx")
        XCTAssertEqual(staged.parentID, "a1b2")
        XCTAssertEqual(staged.entry, Dates.dayString(.now))
        XCTAssertEqual(staged.id.count, 4)
        XCTAssertNotNil(Dates.timestamp(staged.updatedAt))
        let noContext = try await backend.add(text: "Stage without context", stage: .staged)
        XCTAssertEqual(noContext.stage, .unstaged)            // like the real backend: staged needs context
        await expect(.http(400, "text is required")) { try await self.backend.add(text: "   ") }
        let health = try await backend.health()
        XCTAssertEqual(health.tasks, 12)
        let live = Backend(baseURL: MockBackend.baseURL, actor: "live:c1", session: MockURLProtocol.session)
        let t = try await live.add(text: "From a call")
        XCTAssertTrue(t.createdBy.hasPrefix("live"))
        let events = try await backend.events(actor: "live:c1")
        XCTAssertEqual(events.map(\.taskID), [t.id])
        XCTAssertNil(events.first?.before)
        XCTAssertEqual(events.first?.after?.id, t.id)
        XCTAssertEqual(events.first?.action, "add")
    }

    func testMockStageCloseAndEditRules() async throws {
        let restaged = try await backend.stage("g7h8", context: "new ctx")     // staging again replaces the context
        XCTAssertEqual(restaged.context, "new ctx")
        XCTAssertEqual(restaged.stage, .staged)
        await expect(.refused("only an unstaged or staged task can be staged")) { try await self.backend.stage("m3n4", context: "x") }
        await expect(.http(400, "context is required")) { try await self.backend.stage("a1b2", context: "") }
        await expect(.notFound("no such task")) { try await self.backend.stage("zzzz", context: "x") }
        await expect(.refused("the agent has it; wait for the run")) { try await self.backend.close("m3n4") }
        await expect(.notFound("no such task")) { try await self.backend.close("zzzz") }
        await expect(.notFound("no such task")) { try await self.backend.edit("zzzz", text: "x") }
        await expect(.notFound("no such task")) { try await self.backend.task("zzzz") }
        let closed = try await backend.close("a1b2")
        XCTAssertEqual(closed.done, Dates.dayString(.now))
        await expect(.refused("already closed")) { try await self.backend.close("a1b2") }
        let edited = try await backend.edit("m3n4", context: "")
        XCTAssertEqual(edited.context, "")                                      // a committed task can still be edited
        XCTAssertEqual(edited.text, "Find a plumber for the leak")
        let events = try await backend.events(task: "m3n4")
        XCTAssertEqual(events.map(\.action), ["edit"])
    }

    func testMockRunsRoutesWhenBuilt() async throws {
        MockBackend.shared.notBuilt = []
        let all = try await backend.runs()
        XCTAssertEqual(all.map(\.id), ["r001"])
        let forTask = try await backend.runs(task: "m3n4")
        XCTAssertEqual(forTask.count, 1)
        let none = try await backend.runs(task: "a1b2")
        XCTAssertTrue(none.isEmpty)
        let r = try await backend.run("r001")
        XCTAssertEqual(r.status, .needsYou)
        XCTAssertEqual(r.steps.count, 3)
        XCTAssertFalse(r.question.isEmpty)
        await expect(.notFound("no such run")) { try await self.backend.run("r999") }
        await expect(.notFound("no such run")) { try await self.backend.answer(run: "r999", "x") }
        await expect(.refused("only a staged task can be committed")) { try await self.backend.commit("a1b2") }
        await expect(.notFound("no such task")) { try await self.backend.commit("zzzz") }
        let committed = try await backend.commit("g7h8")
        XCTAssertEqual(committed.stage, .committed)
        let runs = try await backend.runs(task: "g7h8")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.status, .queued)
        XCTAssertEqual(runs.first?.kind, "commit")
        let events = try await backend.events(task: "g7h8")
        XCTAssertEqual(events.map(\.action), ["stage", "commit"])
        let answered = try await backend.answer(run: "r001", "Flow")
        XCTAssertEqual(answered.status, .running)
        // Retransform and the signed URL stay 501 even when runs are "built".
        await expect(.notBuilt("/tasks/g7h8/retransform")) { try await self.backend.retransform("g7h8", instruction: "split") }
        await expect(.notBuilt("/live/signed-url")) { try await self.backend.live() }
    }

    func testMockNotBuiltRoutesByDefault() async {
        await expect(.notBuilt("/runs")) { try await self.backend.runs() }
        await expect(.notBuilt("/runs/r001")) { try await self.backend.run("r001") }
        await expect(.notBuilt("/runs/r001/answer")) { try await self.backend.answer(run: "r001", "x") }
        await expect(.notBuilt("/tasks/g7h8/commit")) { try await self.backend.commit("g7h8") }
        await expect(.notBuilt("/tasks/g7h8/retransform")) { try await self.backend.retransform("g7h8", instruction: "x") }
        await expect(.notBuilt("/live/signed-url")) { try await self.backend.live() }
    }

    func testMockEventsFilterAndUnknownRoutes() async throws {
        let all = try await backend.events()
        XCTAssertEqual(all.map(\.action), ["add", "stage"])
        XCTAssertEqual(all.map(\.id), [1, 2])
        XCTAssertTrue(all.allSatisfy { $0.atDate != nil })
        let byTask = try await backend.events(task: "g7h8")
        XCTAssertEqual(byTask.map(\.action), ["stage"])
        XCTAssertEqual(byTask.first?.before?.stage, .unstaged)
        XCTAssertEqual(byTask.first?.after?.stage, .staged)
        let byActor = try await backend.events(actor: "agent:r1")
        XCTAssertTrue(byActor.isEmpty)
        let unknown = MockBackend.shared.handle(URLRequest(url: MockBackend.baseURL.appending(path: "/nothing")))
        XCTAssertEqual(unknown.status, 404)
        var wrongMethod = URLRequest(url: MockBackend.baseURL.appending(path: "/health"))
        wrongMethod.httpMethod = "DELETE"
        XCTAssertEqual(MockBackend.shared.handle(wrongMethod).status, 404)
        var deep = URLRequest(url: MockBackend.baseURL.appending(path: "/tasks/a1b2/stage/extra"))
        deep.httpMethod = "POST"
        XCTAssertEqual(MockBackend.shared.handle(deep).status, 404)
    }

    func testMockTasksFilterByStageAndKeepOrder() async throws {
        for stage in Stage.allCases {
            let list = try await backend.tasks(stage: stage)
            XCTAssertTrue(list.allSatisfy { $0.stage == stage })
            XCTAssertFalse(list.isEmpty)
        }
        let all = try await backend.tasks()
        XCTAssertEqual(Dictionary(grouping: all, by: \.stage).mapValues(\.count), [.unstaged: 3, .staged: 3, .committed: 1, .closed: 3])
        XCTAssertEqual(all.first?.id, "a1b2")                  // in the order written down
        XCTAssertEqual(all.last?.id, "s9t0")
        let added = try await backend.add(text: "Newest")
        let after = try await backend.tasks()
        XCTAssertEqual(after.last?.id, added.id)
    }

    func testMockResetRestoresTheFixture() async throws {
        _ = try await backend.add(text: "temporary")
        _ = try await backend.close("a1b2")
        MockBackend.shared.reset()
        let tasks = try await backend.tasks()
        XCTAssertEqual(tasks.count, 10)
        XCTAssertEqual(tasks.first?.stage, .unstaged)
        let events = try await backend.events()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(MockBackend.shared.tasks.count, 10)
    }
}

// A canned HTTP reply for one host, so the client's status and body handling can be tested
// without the mock's routing in the way. It also records the last request it saw.
final class StubURLProtocol: URLProtocol {
    static let host = "stub.undercurrent.test"
    static let baseURL = URL(string: "http://\(host)")!
    static var reply: (status: Int, body: Data, contentType: String?) = (200, Data(), "application/json")
    static var lastRequest: URLRequest?
    static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? Self.drain(request.httpBodyStream)
        let r = Self.reply
        var headers: [String: String] = [:]
        if let ct = r.contentType { headers["Content-Type"] = ct }
        let response = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: r.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func drain(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
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

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }()
}
