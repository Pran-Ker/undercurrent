import XCTest
@testable import Undercurrent

final class ModelTests: XCTestCase {
    func testTaskDecodesTheContractExample() throws {
        let json = """
        {"id": "k79l", "stage": "staged", "text": "Book the dentist", "context": "mornings only, Elm street",
         "priority": "M", "due": "2026-10-20", "tags": ["health"], "note": "",
         "parent_id": "", "created_by": "user", "entry": "2026-10-11", "done": "", "updated_at": "2026-10-11T19:02:11Z"}
        """
        let t = try JSONDecoder().decode(BoardTask.self, from: Data(json.utf8))
        XCTAssertEqual(t.id, "k79l")
        XCTAssertEqual(t.stage, .staged)
        XCTAssertEqual(t.tags, ["health"])
        XCTAssertEqual(t.priorityLabel, "Medium")
        XCTAssertEqual(t.dueDate, Dates.day("2026-10-20"))
        XCTAssertTrue(t.isOpen)
    }

    func testTaskDecodesWithOmittedFields() throws {
        let json = #"{"id": "a1b2", "stage": "closed", "text": "x", "tags": [], "note": "", "created_by": "user", "entry": "2026-10-01"}"#
        let t = try JSONDecoder().decode(BoardTask.self, from: Data(json.utf8))
        XCTAssertEqual(t.priority, "")
        XCTAssertEqual(t.due, "")
        XCTAssertEqual(t.parentID, "")
        XCTAssertFalse(t.isOpen)
    }

    func testUnknownStageFallsBackToUnstaged() throws {
        let t = try JSONDecoder().decode(BoardTask.self, from: Data(#"{"id":"z9z9","stage":"weird","text":"x"}"#.utf8))
        XCTAssertEqual(t.stage, .unstaged)
    }

    func testEventDecodesWithBeforeAndAfter() throws {
        let json = """
        {"id": 7, "at": "2026-10-11T19:02:11Z", "actor": "user", "action": "stage", "task_id": "k79l",
         "before": {"id":"k79l","stage":"unstaged","text":"Book the dentist"}, "after": {"id":"k79l","stage":"staged","text":"Book the dentist"}, "note": ""}
        """
        let e = try JSONDecoder().decode(Event.self, from: Data(json.utf8))
        XCTAssertEqual(e.taskID, "k79l")
        XCTAssertEqual(e.before?.stage, .unstaged)
        XCTAssertEqual(e.after?.stage, .staged)
        XCTAssertEqual(e.actorKind, "user")
        XCTAssertNotNil(e.atDate)
    }

    func testEventActorKinds() throws {
        func kind(_ actor: String) throws -> String {
            try JSONDecoder().decode(Event.self, from: Data(#"{"id":1,"actor":"\#(actor)","action":"add"}"#.utf8)).actorKind
        }
        XCTAssertEqual(try kind("agent:r1"), "agent")
        XCTAssertEqual(try kind("live:c1"), "live")
        XCTAssertEqual(try kind("user"), "user")
    }

    func testRunDecodesStepsInEveryShape() throws {
        let plain = try JSONDecoder().decode(Run.self, from: Data(#"{"id":"r1","task_id":"t","kind":"commit","status":"needs_you","steps":["a","b"]}"#.utf8))
        XCTAssertEqual(plain.steps, ["a", "b"])
        XCTAssertEqual(plain.status, .needsYou)
        XCTAssertEqual(plain.statusLabel, "needs you")
        let objects = try JSONDecoder().decode(Run.self, from: Data(#"{"id":"r2","task_id":"t","kind":"commit","status":"done","steps":[{"text":"x"}]}"#.utf8))
        XCTAssertEqual(objects.steps, ["x"])
        let string = try JSONDecoder().decode(Run.self, from: Data(#"{"id":"r3","task_id":"t","kind":"commit","status":"queued","steps":"[\"y\"]"}"#.utf8))
        XCTAssertEqual(string.steps, ["y"])
    }

    func testDatesShortWords() {
        let now = Dates.day("2026-10-11")!.addingTimeInterval(12 * 3600)
        XCTAssertEqual(Dates.short("2026-10-11", now: now), "today")
        XCTAssertEqual(Dates.short("2026-10-12", now: now), "tomorrow")
        XCTAssertEqual(Dates.short("2026-10-10", now: now), "yesterday")
        XCTAssertEqual(Dates.short("2026-10-20", now: now), "20 Oct")
        XCTAssertEqual(Dates.dayString(Dates.day("2026-10-20")!), "2026-10-20")
        XCTAssertEqual(Dates.short("", now: now), "")
        XCTAssertEqual(Dates.daysBetween(Dates.day("2026-10-01")!, Dates.day("2026-10-11")!), 10)
    }

    // MARK: Edge cases: null and missing fields, bad dates, unknown values

    func testTaskDecodesNullFieldsAsDefaults() throws {
        let json = #"{"id":"n1n1","stage":null,"text":null,"context":null,"priority":null,"due":null,"tags":null,"note":null,"parent_id":null,"created_by":null,"entry":null,"done":null,"updated_at":null}"#
        let t = try JSONDecoder().decode(BoardTask.self, from: Data(json.utf8))
        XCTAssertEqual(t.stage, .unstaged)
        XCTAssertEqual(t.text, "")
        XCTAssertEqual(t.tags, [])
        XCTAssertEqual(t.createdBy, "user")
        XCTAssertNil(t.entryDate)
        XCTAssertNil(t.dueDate)
        XCTAssertNil(t.doneDate)
        XCTAssertEqual(t.priorityLabel, "")
        XCTAssertTrue(t.isOpen)
    }

    func testTaskWithOnlyAnIDDecodes() throws {
        let t = try JSONDecoder().decode(BoardTask.self, from: Data(#"{"id":"m1m1"}"#.utf8))
        XCTAssertEqual(t, BoardTask(id: "m1m1", stage: .unstaged, text: ""))
    }

    func testTaskWithoutAStringIDFailsToDecode() {
        XCTAssertThrowsError(try JSONDecoder().decode(BoardTask.self, from: Data(#"{"stage":"staged","text":"x"}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(BoardTask.self, from: Data(#"{"id":null,"text":"x"}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(BoardTask.self, from: Data(#"{"id":7,"text":"x"}"#.utf8)))
    }

    func testTaskMalformedDatesReadAsNilButKeepTheirText() throws {
        let t = try JSONDecoder().decode(BoardTask.self, from: Data(#"{"id":"d1d1","entry":"2026-13-45","due":"tomorrow","priority":"X"}"#.utf8))
        XCTAssertNil(t.entryDate)
        XCTAssertNil(t.dueDate)
        XCTAssertEqual(t.due, "tomorrow")
        XCTAssertEqual(t.priorityLabel, "")
        XCTAssertEqual(Dates.short("tomorrow"), "tomorrow")
    }

    func testTaskRoundTripsThroughTheEncoderWithSnakeCaseKeys() throws {
        let t = BoardTask(id: "r1r1", stage: .committed, text: "x", context: "c", priority: "H", due: "2026-10-20",
                          tags: ["a", "b"], note: "n", parentID: "p1p1", createdBy: "agent", entry: "2026-10-01",
                          done: "", updatedAt: "2026-10-11T19:02:11Z")
        let data = try JSONEncoder().encode(t)
        let keys = Set(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys)
        XCTAssertTrue(keys.isSuperset(of: ["parent_id", "created_by", "updated_at", "tags"]))
        XCTAssertFalse(keys.contains("parentID"))
        XCTAssertEqual(try JSONDecoder().decode(BoardTask.self, from: data), t)
    }

    func testStageTitlesAndRawValues() {
        XCTAssertEqual(Stage.allCases.map(\.title), ["Unstaged", "Staged", "Running", "Closed"])
        XCTAssertEqual(Stage(rawValue: "committed"), .committed)
        XCTAssertNil(Stage(rawValue: "running"))
        XCTAssertNil(Stage(rawValue: "Staged"))
    }

    func testEventDecodesNullAndMalformedSnapshots() throws {
        let json = #"{"id":9,"at":"2026-10-11T19:02:11Z","actor":"user","action":"add","task_id":"k79l","before":null,"after":{"stage":"unstaged"}}"#
        let e = try JSONDecoder().decode(Event.self, from: Data(json.utf8))
        XCTAssertNil(e.before)
        XCTAssertNil(e.after)        // a snapshot without an id is dropped, not fatal
        XCTAssertEqual(e.taskID, "k79l")
        XCTAssertEqual(e.note, "")
        XCTAssertEqual(e.runID, "")
        XCTAssertEqual(e.atDate, Date(timeIntervalSince1970: 1791745331))
    }

    func testEventWithoutAnIDFailsToDecode() {
        XCTAssertThrowsError(try JSONDecoder().decode(Event.self, from: Data(#"{"actor":"user","action":"add"}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(Event.self, from: Data(#"{"id":"7","actor":"user","action":"add"}"#.utf8)))
    }

    func testEventActorKindEdgeCases() throws {
        func kind(_ actor: String) throws -> String {
            try JSONDecoder().decode(Event.self, from: Data(#"{"id":1,"actor":"\#(actor)","action":"add"}"#.utf8)).actorKind
        }
        XCTAssertEqual(try kind(""), "user")
        XCTAssertEqual(try kind("agent"), "agent")
        XCTAssertEqual(try kind("someone"), "someone")
        let missing = try JSONDecoder().decode(Event.self, from: Data(#"{"id":1,"action":"add"}"#.utf8))
        XCTAssertEqual(missing.actorKind, "user")
        XCTAssertEqual(missing.actor, "")
        XCTAssertNil(missing.atDate)
        let bad = try JSONDecoder().decode(Event.self, from: Data(#"{"id":1,"at":"not a time","actor":"user","action":"add"}"#.utf8))
        XCTAssertNil(bad.atDate)
    }

    func testRunDecodesUnknownAndMissingStatus() throws {
        let unknown = try JSONDecoder().decode(Run.self, from: Data(#"{"id":"r1","task_id":"t","kind":"commit","status":"exploded"}"#.utf8))
        XCTAssertEqual(unknown.status, .queued)
        let missing = try JSONDecoder().decode(Run.self, from: Data(#"{"id":"r2"}"#.utf8))
        XCTAssertEqual(missing.status, .queued)
        XCTAssertEqual(missing.taskID, "")
        XCTAssertEqual(missing.kind, "")
        XCTAssertEqual(missing.steps, [])
        XCTAssertEqual(missing.statusLabel, "queued")
        let null = try JSONDecoder().decode(Run.self, from: Data(#"{"id":"r3","status":null,"steps":null,"question":null,"task_id":null}"#.utf8))
        XCTAssertEqual(null.status, .queued)
        XCTAssertEqual(null.steps, [])
        XCTAssertEqual(null.question, "")
        XCTAssertEqual(null.taskID, "")
        XCTAssertThrowsError(try JSONDecoder().decode(Run.self, from: Data(#"{"status":"done"}"#.utf8)))
    }

    func testRunStepsInOddShapes() throws {
        let stepKey = try JSONDecoder().decode(Run.self, from: Data(#"{"id":"r1","steps":[{"step":"s1"},{"text":"t2"}]}"#.utf8))
        XCTAssertEqual(stepKey.steps, ["s1", "t2"])
        let numbers = try JSONDecoder().decode(Run.self, from: Data(#"{"id":"r2","steps":[1,2]}"#.utf8))
        XCTAssertEqual(numbers.steps, [])            // neither strings, objects, nor a JSON string
        let badString = try JSONDecoder().decode(Run.self, from: Data(#"{"id":"r3","steps":"not json"}"#.utf8))
        XCTAssertEqual(badString.steps, [])
        let empty = try JSONDecoder().decode(Run.self, from: Data(#"{"id":"r4","steps":[]}"#.utf8))
        XCTAssertEqual(empty.steps, [])
    }

    func testRunStatusRawValuesAndLabels() {
        XCTAssertEqual(Run.Status(rawValue: "needs_you"), .needsYou)
        XCTAssertNil(Run.Status(rawValue: "needsYou"))
        XCTAssertEqual(Run(id: "r", taskID: "t", kind: "commit", status: .failed).statusLabel, "failed")
        XCTAssertEqual(Run(id: "r", taskID: "t", kind: "commit", status: .running).statusLabel, "running")
        XCTAssertEqual(Run(id: "r", taskID: "t", kind: "commit", status: .done).statusLabel, "done")
    }

    func testDatesShortAcrossYearsAndBadInput() {
        let now = Dates.day("2026-10-11")!.addingTimeInterval(12 * 3600)
        XCTAssertEqual(Dates.short("2025-12-20", now: now), "20 Dec 2025")
        XCTAssertEqual(Dates.short("2026-01-02", now: now), "2 Jan")
        XCTAssertEqual(Dates.short("garbage", now: now), "garbage")
        XCTAssertNil(Dates.day(""))
        XCTAssertNil(Dates.day("2026-13-45"))
        XCTAssertNil(Dates.timestamp(""))
        XCTAssertNil(Dates.timestamp("2026-10-11"))
        XCTAssertEqual(Dates.timestamp("2026-10-11T19:02:11Z"), Date(timeIntervalSince1970: 1791745331))
        XCTAssertEqual(Dates.daysBetween(Dates.day("2026-10-11")!, Dates.day("2026-10-01")!), -10)
        XCTAssertEqual(Dates.daysBetween(now, now.addingTimeInterval(11 * 3600)), 0)   // same calendar day
    }

    func testHealthDecodes() throws {
        let h = try JSONDecoder().decode(Health.self, from: Data(#"{"ok":true,"tasks":12}"#.utf8))
        XCTAssertTrue(h.ok)
        XCTAssertEqual(h.tasks, 12)
        XCTAssertThrowsError(try JSONDecoder().decode(Health.self, from: Data(#"{"ok":true}"#.utf8)))
    }

    // The run the backend really sends (backend/internal/store/runs.go): steps are objects with
    // at/kind/cmd/exit/ms/output and no "text" key.
    func testRunDecodesTheBackendsRealShape() throws {
        let json = """
        {"id": "r1x9", "task_id": "k79l", "kind": "commit", "status": "needs_you", "question": "Which card should pay?",
         "steps": [{"at": "2026-10-11T19:02:11Z", "kind": "agent", "cmd": "claude -p --output-format json", "exit": 0, "ms": 41200, "output": "looked it up"}],
         "cost_cents": 0, "started_at": "2026-10-11T19:02:11Z"}
        """
        let r = try JSONDecoder().decode(Run.self, from: Data(json.utf8))
        XCTAssertEqual(r.status, .needsYou)
        XCTAssertEqual(r.question, "Which card should pay?")
        XCTAssertEqual(r.steps.count, 1)
        XCTAssertEqual(r.startedAt, "2026-10-11T19:02:11Z")
        let step = try XCTUnwrap(r.steps.first)
        XCTExpectFailure("BoardTask.swift Run.init(from:): a step object without a text/step key falls through to a dictionary dump") {
            XCTAssertFalse(step.hasPrefix("["), "the Run screen would show a Swift dictionary: \(step)")
        }
    }
}
