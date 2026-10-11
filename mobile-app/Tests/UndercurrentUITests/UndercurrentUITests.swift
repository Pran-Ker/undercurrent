import XCTest

// Smoke tests through the real UI against the in-process mock backend (-mockBackend). Screenshots
// are attached to the xcresult; nothing here reaches a database.
final class UndercurrentUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-mockBackend"]
        app.launch()
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func scrollTo(_ element: XCUIElement, maxSwipes: Int = 8) {
        var n = 0
        while !(element.exists && element.isHittable) && n < maxSwipes { app.swipeUp(); n += 1 }
    }

    // SwiftUI exposes identifiers on whatever element type it chose; match any.
    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func row(_ id: String) -> XCUIElement {
        let r = el("row.\(id)")
        scrollTo(r)
        return r
    }

    func testHomeShowsTheThreeCardsAndCounts() {
        XCTAssertTrue(el("card.unstaged").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Book the dentist"].exists)
        XCTAssertTrue(app.staticTexts["File the Q3 taxes"].exists)
        XCTAssertEqual(el("count.unstaged").label, "Unstaged: 3")
        XCTAssertEqual(el("count.staged").label, "Staged: 3")
        XCTAssertEqual(el("count.closed").label, "Closed: 3")
        snap("home")
    }

    func testAddLandsUnstaged() {
        app.buttons["add.open"].tap()
        let field = app.textViews["add.text"].firstMatch.exists ? app.textViews["add.text"].firstMatch : app.textFields["add.text"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("Call the bank about the card")
        snap("add-filled")
        app.buttons["add.confirm"].tap()
        XCTAssertTrue(app.staticTexts["Call the bank about the card"].waitForExistence(timeout: 5))
        XCTAssertEqual(el("count.unstaged").label, "Unstaged: 4")
        snap("home-after-add")
    }

    func testStageMovesATaskToStaged() {
        row("a1b2").tap()
        XCTAssertTrue(app.staticTexts["task.text"].waitForExistence(timeout: 3))
        snap("task-unstaged")
        scrollTo(app.buttons["task.stage"])
        app.buttons["task.stage"].tap()
        let ctx = app.textViews["stage.context"].firstMatch.exists ? app.textViews["stage.context"].firstMatch : app.textFields["stage.context"].firstMatch
        XCTAssertTrue(ctx.waitForExistence(timeout: 3))
        ctx.tap()
        ctx.typeText("Mornings only, the Elm street practice.")
        app.buttons["stage.confirm"].tap()
        XCTAssertTrue(app.staticTexts["Mornings only, the Elm street practice."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["task.commit"].waitForExistence(timeout: 3))
        snap("task-staged")
    }

    func testCloseFromStaged() {
        row("k1l2").tap()
        scrollTo(app.buttons["task.close"])
        app.buttons["task.close"].tap()
        app.buttons["Close it"].tap()
        XCTAssertTrue(app.staticTexts["Closed today. Closed is closed."].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(el("count.closed").waitForExistence(timeout: 3))
        XCTAssertEqual(el("count.closed").label, "Closed: 4")
    }

    func testCommitShowsNotBuiltAndKeepsStaged() {
        row("g7h8").tap()
        scrollTo(app.buttons["task.commit"])
        app.buttons["task.commit"].tap()
        XCTAssertTrue(el("error.banner").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["task.commit"].exists)
        snap("task-commit-not-built")
    }

    func testRetransformShowsNotBuilt() {
        row("i9j0").tap()
        scrollTo(app.buttons["task.retransform"])
        app.buttons["task.retransform"].tap()
        let field = app.textViews["retransform.instruction"].firstMatch.exists ? app.textViews["retransform.instruction"].firstMatch : app.textFields["retransform.instruction"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("Split this into three.")
        app.buttons["retransform.send"].tap()
        XCTAssertTrue(el("retransform.notbuilt").waitForExistence(timeout: 5) || app.staticTexts["NOT BUILT YET"].waitForExistence(timeout: 1))
        snap("retransform-not-built")
    }

    func testClosedSheetListsClosedTasks() {
        scrollTo(app.buttons["closed.open"])
        app.buttons["closed.open"].tap()
        XCTAssertTrue(app.staticTexts["Cancel the old gym membership"].waitForExistence(timeout: 3))
        snap("closed-sheet")
    }

    func testEditSavesTextAndContext() {
        row("i9j0").tap()
        app.buttons["task.edit"].tap()
        let text = app.textViews["task.text.field"].firstMatch.exists ? app.textViews["task.text.field"].firstMatch : app.textFields["task.text.field"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 3))
        text.tap()
        text.typeText(" in spring")
        app.buttons["task.save"].tap()
        XCTAssertTrue(app.staticTexts["Plan the trip to Lisbon in spring"].waitForExistence(timeout: 5))
        snap("task-edited")
    }

    func testInsightsRendersMeasures() {
        app.buttons["nav.insights"].tap()
        XCTAssertTrue(el("stat.Decided").waitForExistence(timeout: 5))
        XCTAssertTrue(el("stat.Unstaged load").exists)
        snap("insights")
        scrollTo(el("chart.weekly"))
        snap("insights-charts")
    }

    func testCallScreenSaysNotBuilt() {
        app.buttons["nav.call"].tap()
        XCTAssertTrue(app.staticTexts["No live agent yet"].waitForExistence(timeout: 5))
        snap("call-unavailable")
        app.buttons["call.hangup"].tap()
        XCTAssertTrue(el("card.unstaged").waitForExistence(timeout: 3))
    }

    func testSettingsChecksTheBackend() {
        app.buttons["nav.settings"].tap()
        XCTAssertTrue(app.buttons["settings.check"].waitForExistence(timeout: 3))
        app.buttons["settings.check"].tap()
        XCTAssertTrue(el("settings.result").waitForExistence(timeout: 8))
        snap("settings")
    }
}

// TEMPORARY probe tests (agent "task"); removed after the run.
final class TaskProbeUITests: XCTestCase {
    var app: XCUIApplication!
    static let real = "http://127.0.0.1:8805"
    var useReal: Bool { ProcessInfo.processInfo.environment["UC_REAL"] == "1" }

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = useReal ? ["-backendURL", Self.real] : ["-mockBackend"]
        app.launch()
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = (useReal ? "real-" : "mock-") + name
        a.lifetime = .keepAlways
        add(a)
    }
    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func scrollTo(_ e: XCUIElement, max: Int = 25) {
        var n = 0
        while !(e.exists && e.isHittable) && n < max { app.swipeUp(velocity: .fast); n += 1 }
    }
    private func scrollUpTo(_ e: XCUIElement, max: Int = 25) {
        var n = 0
        while !(e.exists && e.isHittable) && n < max { app.swipeDown(velocity: .fast); n += 1 }
    }
    private func openRow(_ id: String) {
        XCTAssertTrue(el("card.unstaged").waitForExistence(timeout: 30), "home")
        let r = el("row.\(id)")
        scrollTo(r)
        XCTAssertTrue(r.exists, "row \(id)")
        r.tap()
        XCTAssertTrue(el("task.text").waitForExistence(timeout: 20), "task \(id) opened")
    }
    private func field(_ id: String) -> XCUIElement {
        let tv = app.textViews[id].firstMatch
        return tv.exists ? tv : app.textFields[id].firstMatch
    }
    private func clear(_ f: XCUIElement, count: Int) {
        f.tap()
        f.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count))
    }
    private func eventRows() -> Int {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'user · ' OR label BEGINSWITH 'agent · '")).count
    }
    private func back() { app.navigationBars.buttons.element(boundBy: 0).tap() }

    @discardableResult
    private func http(_ method: String, _ path: String, _ body: String? = nil) -> (Int, String) {
        var req = URLRequest(url: URL(string: Self.real + path)!)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { req.httpBody = body.data(using: .utf8) }
        let sem = DispatchSemaphore(value: 0)
        var out = (0, "")
        URLSession.shared.dataTask(with: req) { d, r, _ in
            out = ((r as? HTTPURLResponse)?.statusCode ?? 0, String(data: d ?? Data(), encoding: .utf8) ?? "")
            sem.signal()
        }.resume()
        sem.wait()
        return out
    }

    var unstagedID: String { useReal ? "9sz9" : "c3d4" }       // Build the bookshelf / Renew the passport
    var unstagedText: String { useReal ? "Build the bookshelf" : "Renew the passport" }
    var stagedID: String { useReal ? "d0vn" : "i9j0" }         // Reply to the accountant / Plan the trip to Lisbon
    var closedID: String { useReal ? "gy4u" : "o5p6" }
    var closedText: String { useReal ? "Submit the expense report" : "Cancel the old gym membership" }

    // 1. Unstaged: buttons, edit text/context/tags (emoji, 500 chars, whitespace), clear tags, events grow.
    func test1UnstagedEdit() {
        openRow(unstagedID)
        snap("1-unstaged-open")
        XCTAssertTrue(app.buttons["task.edit"].exists, "Edit shown")
        scrollTo(app.buttons["task.stage"])
        XCTAssertTrue(app.buttons["task.stage"].exists, "Stage shown")
        XCTAssertTrue(app.buttons["task.close"].exists, "Close shown")
        XCTAssertFalse(app.buttons["task.commit"].exists, "no Commit")
        XCTAssertFalse(app.buttons["task.retransform"].exists, "no Retransform")
        XCTAssertFalse(app.buttons["task.restage"].exists, "no Restage")
        let before = eventRows()
        scrollUpTo(app.buttons["task.edit"])
        app.buttons["task.edit"].tap()
        let t = field("task.text.field")
        XCTAssertTrue(t.waitForExistence(timeout: 10))
        t.tap(); t.typeText(" 🚀 ok")
        let c = field("task.context.field")
        c.tap(); c.typeText("  Context with emoji 😀 and spaces  ")
        let g = field("task.tags.field")
        g.tap(); g.typeText(" new  😀tag   ")
        snap("1-editing")
        app.buttons["task.save"].tap()
        XCTAssertTrue(app.staticTexts[unstagedText + " 🚀 ok"].waitForExistence(timeout: 20), "text saved")
        snap("1-saved-emoji")
        let after1 = eventRows()
        XCTAssertEqual(after1, before + 1, "one edit event after save (before \(before), after \(after1))")
        // Save with nothing changed
        scrollUpTo(app.buttons["task.edit"])
        app.buttons["task.edit"].tap()
        XCTAssertTrue(app.buttons["task.save"].waitForExistence(timeout: 10))
        app.buttons["task.save"].tap()
        XCTAssertTrue(app.buttons["task.edit"].waitForExistence(timeout: 20))
        let after2 = eventRows()
        XCTAssertEqual(after2, after1, "no-op save must not add an event (was \(after1), now \(after2))")
        snap("1-after-noop-save")
        // 500 chars text, clear tags, whitespace-only context
        app.buttons["task.edit"].tap()
        let t2 = field("task.text.field")
        XCTAssertTrue(t2.waitForExistence(timeout: 10))
        clear(t2, count: 80)
        t2.typeText(String(repeating: "abcde fghij ", count: 42))  // 504 chars
        let c2 = field("task.context.field")
        clear(c2, count: 60)
        c2.typeText("   ")
        let g2 = field("task.tags.field")
        clear(g2, count: 40)
        app.buttons["task.save"].tap()
        XCTAssertTrue(app.buttons["task.edit"].waitForExistence(timeout: 20), "saved 500 chars")
        snap("1-saved-500-notags-wscontext")
        XCTAssertFalse(app.staticTexts["#home"].exists || app.staticTexts["#new"].exists, "tags cleared")
        if useReal {
            let (_, body) = http("GET", "/tasks/\(unstagedID)")
            XCTContext.runActivity(named: "real task after edits: \(body)") { _ in }
            XCTAssertTrue(body.contains("\"tags\":[]"), "tags cleared on the backend: \(body)")
        }
    }

    // 2. Stage: empty/whitespace context keeps the button disabled; stage; restage replaces context.
    func test2StageAndRestage() {
        openRow(unstagedID)
        scrollTo(app.buttons["task.stage"])
        app.buttons["task.stage"].tap()
        let ctx = field("stage.context")
        XCTAssertTrue(ctx.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["stage.confirm"].isEnabled, "disabled with empty context")
        ctx.tap(); ctx.typeText("   ")
        XCTAssertFalse(app.buttons["stage.confirm"].isEnabled, "disabled with whitespace context")
        snap("2-stage-disabled")
        ctx.typeText("First context 😀")
        XCTAssertTrue(app.buttons["stage.confirm"].isEnabled)
        app.buttons["stage.confirm"].tap()
        XCTAssertTrue(app.staticTexts["First context 😀"].waitForExistence(timeout: 20), "staged with context")
        XCTAssertTrue(app.buttons["task.commit"].waitForExistence(timeout: 10), "Commit shown after stage")
        XCTAssertTrue(app.buttons["task.retransform"].exists)
        XCTAssertTrue(app.buttons["task.close"].exists)
        XCTAssertTrue(app.buttons["task.restage"].exists)
        XCTAssertFalse(app.buttons["task.stage"].exists)
        snap("2-staged")
        let n1 = eventRows()
        scrollTo(app.buttons["task.restage"])
        app.buttons["task.restage"].tap()
        let ctx2 = field("stage.context")
        XCTAssertTrue(ctx2.waitForExistence(timeout: 10))
        XCTAssertEqual(ctx2.value as? String, "First context 😀", "restage prefilled")
        snap("2-restage-sheet")
        clear(ctx2, count: 30)
        ctx2.typeText("Second context replaces the first")
        app.buttons["stage.confirm"].tap()
        XCTAssertTrue(app.staticTexts["Second context replaces the first"].waitForExistence(timeout: 20), "context replaced")
        XCTAssertFalse(app.staticTexts["First context 😀"].exists, "old context gone")
        let n2 = eventRows()
        XCTAssertEqual(n2, n1 + 1, "restage added one event (\(n1) -> \(n2))")
        snap("2-restaged")
    }

    // 3. Staged: commit (501 banner), retransform (not built), close with Keep then Close, back after close.
    func test3StagedCommitRetransformClose() {
        openRow(stagedID)
        snap("3-staged-open")
        XCTAssertTrue(app.buttons["task.edit"].exists)
        scrollTo(app.buttons["task.commit"])
        app.buttons["task.commit"].tap()
        XCTAssertTrue(el("error.banner").waitForExistence(timeout: 20), "commit 501 banner")
        snap("3-commit-banner")
        XCTAssertTrue(app.buttons["task.commit"].exists, "still staged")
        app.buttons["task.retransform"].tap()
        let f = field("retransform.instruction")
        XCTAssertTrue(f.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["retransform.send"].isEnabled)
        f.tap(); f.typeText("Split this into three.")
        app.buttons["retransform.send"].tap()
        XCTAssertTrue(el("retransform.notbuilt").waitForExistence(timeout: 20), "retransform not built card")
        snap("3-retransform-notbuilt")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["task.close"].waitForExistence(timeout: 10))
        let n1 = eventRows()
        app.buttons["task.close"].tap()
        XCTAssertTrue(app.buttons["Keep it"].waitForExistence(timeout: 10))
        snap("3-close-confirm")
        app.buttons["Keep it"].tap()
        XCTAssertTrue(app.buttons["task.commit"].waitForExistence(timeout: 10), "kept: still staged")
        app.buttons["task.close"].tap()
        app.buttons["Close it"].tap()
        XCTAssertTrue(app.staticTexts["Closed today. Closed is closed."].waitForExistence(timeout: 20), "closed")
        XCTAssertFalse(app.buttons["task.edit"].exists, "no Edit on closed")
        XCTAssertFalse(app.buttons["task.commit"].exists)
        XCTAssertFalse(app.buttons["task.close"].exists)
        let n2 = eventRows()
        XCTAssertEqual(n2, n1 + 1, "close added an event (\(n1) -> \(n2))")
        snap("3-closed")
        back()
        XCTAssertTrue(el("card.unstaged").waitForExistence(timeout: 20), "back on home after close")
        snap("3-home-after-close")
    }

    // 4. Closed task from the Closed sheet; committed task (mock only).
    func test4ClosedAndCommitted() {
        XCTAssertTrue(el("card.unstaged").waitForExistence(timeout: 30))
        scrollTo(app.buttons["closed.open"])
        app.buttons["closed.open"].tap()
        let row = app.staticTexts[closedText].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(el("task.text").waitForExistence(timeout: 20), "closed task opened from sheet")
        snap("4-closed-open")
        XCTAssertFalse(app.buttons["task.edit"].exists)
        XCTAssertFalse(app.buttons["task.stage"].exists)
        XCTAssertFalse(app.buttons["task.close"].exists)
        XCTAssertFalse(app.buttons["task.commit"].exists)
        scrollTo(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Closed '")).firstMatch)
        snap("4-closed-bottom")
        back()
        if !useReal {
            XCTAssertTrue(el("card.unstaged").waitForExistence(timeout: 20))
            openRow("m3n4")
            snap("4-committed-open")
            XCTAssertFalse(app.buttons["task.edit"].exists, "no Edit on committed")
            XCTAssertTrue(app.staticTexts["The agent has this one. Closing waits for the run."].waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["task.close"].exists)
        }
    }

    // 5. Lineage (real backend only): parent 3zmu <-> child vyl3; orphan q4sf.
    func test5Lineage() throws {
        try XCTSkipUnless(useReal)
        openRow("3zmu")
        scrollTo(app.staticTexts["LINEAGE"])
        XCTAssertTrue(app.staticTexts["LINEAGE"].exists, "parent shows lineage")
        XCTAssertTrue(app.staticTexts["YIELDED"].exists, "yielded row")
        snap("5-parent-lineage")
        app.staticTexts["Child: add a retry to the nightly job"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Child: add a retry to the nightly job"].waitForExistence(timeout: 20))
        scrollTo(app.staticTexts["LINEAGE"])
        XCTAssertTrue(app.staticTexts["FROM"].exists, "from row on child")
        XCTAssertTrue(app.staticTexts["Fix the flaky nightly job"].exists, "parent text on child")
        snap("5-child-lineage")
        app.staticTexts["Fix the flaky nightly job"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["YIELDED"].waitForExistence(timeout: 20), "back to parent via lineage")
        back(); back()
        XCTAssertTrue(el("card.unstaged").waitForExistence(timeout: 20))
        openRow("q4sf")
        scrollTo(app.staticTexts["LINEAGE"])
        snap("5-orphan-lineage")
        XCTAssertTrue(app.staticTexts["from zzz9 (not on the board)"].exists, "orphan parent line")
    }

    // 6. 409s (real backend only): close a task out of band, then Close / Edit+Save in the app.
    func test6Conflicts() throws {
        try XCTSkipUnless(useReal)
        openRow("1jkl")  // Draft the talk abstract, unstaged
        scrollTo(app.buttons["task.close"])
        let (code, _) = http("POST", "/tasks/1jkl/close")
        XCTAssertEqual(code, 200)
        app.buttons["task.close"].tap()
        app.buttons["Close it"].tap()
        XCTAssertTrue(el("error.banner").waitForExistence(timeout: 20), "409 close banner")
        snap("6-close-409")
        XCTContext.runActivity(named: "banner: \(el("error.banner").label)") { _ in }
        back()
        XCTAssertTrue(el("card.unstaged").waitForExistence(timeout: 20))
        openRow("6xws")  // Try the new cafe, unstaged
        app.buttons["task.edit"].tap()
        let t = field("task.text.field")
        XCTAssertTrue(t.waitForExistence(timeout: 10))
        t.tap(); t.typeText(" edited")
        let (code2, _) = http("POST", "/tasks/6xws/close")
        XCTAssertEqual(code2, 200)
        app.buttons["task.save"].tap()
        XCTAssertTrue(el("error.banner").waitForExistence(timeout: 20), "409 edit banner")
        snap("6-edit-409")
        XCTContext.runActivity(named: "banner: \(el("error.banner").label); save exists=\(app.buttons["task.save"].exists) edit exists=\(app.buttons["task.edit"].exists) textfield exists=\(field("task.text.field").exists)") { _ in }
        XCTAssertFalse(field("task.text.field").exists, "edit fields must not be stuck after the task became closed")
    }

    // 7. Close while editing (both backends): is the user stuck in edit mode?
    func test7CloseWhileEditing() {
        openRow(useReal ? "kh3d" : "e5f6")
        app.buttons["task.edit"].tap()
        XCTAssertTrue(field("task.text.field").waitForExistence(timeout: 10))
        scrollTo(app.buttons["task.close"])
        app.buttons["task.close"].tap()
        app.buttons["Close it"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Closed '")).firstMatch.waitForExistence(timeout: 20))
        snap("7-closed-while-editing")
        XCTContext.runActivity(named: "after close: textfield=\(field("task.text.field").exists) save=\(app.buttons["task.save"].exists) edit=\(app.buttons["task.edit"].exists)") { _ in }
        XCTAssertFalse(field("task.text.field").exists, "edit fields linger after close with no Save/Cancel")
    }
}
