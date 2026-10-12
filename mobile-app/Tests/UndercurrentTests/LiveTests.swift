import XCTest
@testable import Undercurrent

// The live call's pure parts: what the agent is told for each tool reply, the delivery tags
// stripped from the transcript, and the transcript in the post-call webhook's shape.
@MainActor
final class LiveTests: XCTestCase {
    private func reply(_ json: String) throws -> ToolReply {
        try JSONDecoder().decode(ToolReply.self, from: Data(json.utf8))
    }

    func testSpokenOK() throws {
        let r = try reply(#"{"ok": true, "result": "Added “buy milk” unstaged (t_42)."}"#)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.spoken, "Added “buy milk” unstaged (t_42).")
    }

    func testSpokenNeedsConfirmation() throws {
        let r = try reply(#"{"ok": false, "needs_confirmation": true, "read_back": "Commit “fix the bike”?"}"#)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.needsConfirmation)
        XCTAssertEqual(r.readBack, "Commit “fix the bike”?")
        XCTAssertEqual(r.spoken, "NEEDS CONFIRMATION, read this back and wait for a yes: Commit “fix the bike”?")
    }

    func testSpokenError() throws {
        let r = try reply(#"{"ok": false, "error": "no task matches “the bookshelf”"}"#)
        XCTAssertEqual(r.spoken, "ERROR: no task matches “the bookshelf”")
        let blank = try reply(#"{"ok": false}"#)
        XCTAssertEqual(blank.spoken, "ERROR: the backend refused that")
    }

    func testStripTags() {
        XCTAssertEqual(LiveSession.stripTags("[warm] Hi there. [slow] Ready when you are."), "Hi there. Ready when you are.")
        XCTAssertEqual(LiveSession.stripTags("  [sad, quiet]Okay.  "), "Okay.")
        XCTAssertEqual(LiveSession.stripTags("No tags here"), "No tags here")
        XCTAssertEqual(LiveSession.stripTags("[2024-01-01] dated"), "[2024-01-01] dated", "digits are not a tag")
        XCTAssertEqual(LiveSession.stripTags("[this is far too long to be a delivery tag] x"),
                       "[this is far too long to be a delivery tag] x", "a tag is at most 24 characters")
    }

    func testTurnsShape() {
        let lines = [
            LiveSession.Line(id: "1", who: "agent", text: "Hi. What should go on the board?"),
            LiveSession.Line(id: "2", who: "you", text: "Add buy milk"),
            LiveSession.Line(id: "3", who: "agent", text: ""),
            LiveSession.Line(id: "4", who: "agent", text: "Added buy milk, unstaged."),
        ]
        XCTAssertEqual(LiveSession.turns(lines), [
            ["role": "agent", "message": "Hi. What should go on the board?"],
            ["role": "user", "message": "Add buy milk"],
            ["role": "agent", "message": "Added buy milk, unstaged."],
        ])
        XCTAssertEqual(LiveSession.turns([]), [])
        XCTAssertEqual(LiveSession.userLines(lines), 1)
    }

    func testUserIDIsStablePerInstall() {
        let defaults = UserDefaults(suiteName: "LiveTests.\(UUID().uuidString)")!
        let a = LiveSession.userID(defaults: defaults)
        let b = LiveSession.userID(defaults: defaults)
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.hasPrefix("ios-"))
        XCTAssertNotEqual(a, LiveSession.userID(defaults: UserDefaults(suiteName: "LiveTests.other.\(UUID().uuidString)")!))
    }
}
