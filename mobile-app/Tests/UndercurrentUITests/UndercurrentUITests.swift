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

    private func field(_ id: String) -> XCUIElement {
        let tv = app.textViews[id].firstMatch
        return tv.exists ? tv : app.textFields[id].firstMatch
    }

    private func row(_ id: String) -> XCUIElement {
        let r = el("row.\(id)")
        scrollTo(r)
        return r
    }

    private func textContaining(_ s: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
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
        let field = field("add.text")
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
        let ctx = field("stage.context")
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

    // Commit: the task moves to Running, the run card shows the agent's question at once, and the
    // run can be answered; the agent closes the task with a note and yields the next step.
    func testCommitMovesTheTaskToRunningAndTheRunCanBeAnswered() {
        row("g7h8").tap()
        scrollTo(app.buttons["task.commit"])
        app.buttons["task.commit"].tap()
        XCTAssertTrue(app.buttons["task.run.open"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["task.commit"].exists)
        XCTAssertTrue(app.staticTexts["RUNNING"].exists)
        XCTAssertTrue(el("task.run.status").exists)
        XCTAssertTrue(textContaining("File the Q3 taxes").exists)
        snap("task-committed")
        app.buttons["task.run.open"].tap()
        XCTAssertTrue(el("run.question").waitForExistence(timeout: 5))
        let answer = field("run.answer")
        answer.tap()
        answer.typeText("The cheapest.")
        snap("run-needs-you")
        app.buttons["run.answer.send"].tap()
        XCTAssertTrue(el("run.yielded").waitForExistence(timeout: 8))
        XCTAssertTrue(el("run.note").exists)
        XCTAssertTrue(textContaining("The cheapest.").exists)
        XCTAssertTrue(app.staticTexts["Follow up on: File the Q3 taxes"].exists)
        XCTAssertTrue(el("run.cost").exists)
        XCTAssertFalse(el("run.question").exists)
        snap("run-done")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(el("count.closed").waitForExistence(timeout: 5))
        XCTAssertEqual(el("count.closed").label, "Closed: 4")
        XCTAssertEqual(el("count.unstaged").label, "Unstaged: 4")
    }

    // Retransform: the sheet shows what the model said, and the task's context has changed behind it.
    func testRetransformShowsWhatTheModelSaidAndTheBoardChanges() {
        row("i9j0").tap()
        scrollTo(app.buttons["task.retransform"])
        app.buttons["task.retransform"].tap()
        let field = field("retransform.instruction")
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("Add that the landlord prefers mornings.")
        app.buttons["retransform.send"].tap()
        XCTAssertTrue(el("retransform.say").waitForExistence(timeout: 8))
        XCTAssertTrue(textContaining("Added to the context: Add that the landlord prefers mornings.").exists)
        snap("retransform-said")
        app.buttons["retransform.done"].tap()
        XCTAssertTrue(app.buttons["task.retransform"].waitForExistence(timeout: 5))
        let context = el("task.context")
        XCTAssertTrue(context.waitForExistence(timeout: 5))
        XCTAssertTrue(context.label.contains("Mid-November, four nights, near Alfama."))
        XCTAssertTrue(context.label.contains("Add that the landlord prefers mornings."))
        XCTAssertTrue(textContaining("agent · retransform").exists)
        snap("task-retransformed")
    }

    // A needs-you row on Home opens the run; the answer resumes it; the child it yields shows the
    // parent in its lineage.
    func testNeedsYouRunAnswersAndTheChildShowsItsLineage() {
        XCTAssertTrue(el("card.committed").waitForExistence(timeout: 5))
        row("m3n4").tap()
        XCTAssertTrue(el("run.question").waitForExistence(timeout: 5))
        XCTAssertTrue(textContaining("Two plumbers can come Tuesday 9am").exists)
        XCTAssertTrue(app.staticTexts["NEEDS YOU"].exists)
        snap("run-needs-you-fixture")
        let answer = field("run.answer")
        answer.tap()
        answer.typeText("Flow")
        app.buttons["run.answer.send"].tap()
        XCTAssertTrue(el("run.yielded").waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Follow up on: Find a plumber for the leak"].exists)
        XCTAssertTrue(textContaining("Flow").exists)
        snap("run-answered")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(el("card.unstaged").waitForExistence(timeout: 5))
        XCTAssertEqual(el("count.committed").label, "Running: 0")
        let child = app.staticTexts["Follow up on: Find a plumber for the leak"]
        scrollTo(child)
        child.tap()
        XCTAssertTrue(app.staticTexts["task.text"].waitForExistence(timeout: 5))
        scrollTo(app.staticTexts["LINEAGE"])
        XCTAssertTrue(app.staticTexts["FROM"].exists)
        XCTAssertTrue(app.staticTexts["Find a plumber for the leak"].exists)
        XCTAssertTrue(app.staticTexts["agent · add"].exists)
        snap("child-lineage")
        app.staticTexts["Find a plumber for the leak"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["YIELDED"].waitForExistence(timeout: 5))
        XCTAssertTrue(textContaining("Closed today").exists)
        snap("parent-closed-with-lineage")
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
        let text = field("task.text.field")
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
        XCTAssertTrue(app.secureTextFields["settings.key"].exists)
        app.buttons["settings.check"].tap()
        XCTAssertTrue(el("settings.result").waitForExistence(timeout: 8))
        snap("settings")
    }
}
