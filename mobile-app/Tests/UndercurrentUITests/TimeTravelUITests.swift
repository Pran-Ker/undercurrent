import XCTest

// Time travel against the in-process mock (-mockBackend): the list of actions, the board as it
// was after the newest one, and the way back. Screenshots are attached to the xcresult.
final class TimeTravelUITests: XCTestCase {
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

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func scrollTo(_ element: XCUIElement, maxSwipes: Int = 8) {
        var n = 0
        while !(element.exists && element.isHittable) && n < maxSwipes { app.swipeUp(); n += 1 }
    }

    func testListThenTheBoardAsItWasThenBackToNow() {
        XCTAssertTrue(el("card.unstaged").waitForExistence(timeout: 5))
        app.buttons["nav.time"].tap()
        XCTAssertTrue(el("time.list").waitForExistence(timeout: 5))
        let newest = el("time.row.1")
        XCTAssertTrue(newest.waitForExistence(timeout: 5))
        XCTAssertTrue(newest.label.contains("user · stage"), newest.label)
        XCTAssertTrue(newest.label.contains("File the Q3 taxes"), newest.label)
        XCTAssertTrue(el("time.row.2").label.contains("user · add"), el("time.row.2").label)
        snap("time-list")

        newest.tap()
        XCTAssertTrue(el("time.asof").waitForExistence(timeout: 5))
        XCTAssertTrue(el("time.asof").label.hasPrefix("AS OF "), el("time.asof").label)
        XCTAssertTrue(el("time.count.unstaged").waitForExistence(timeout: 5))
        XCTAssertEqual(el("time.count.unstaged").label, "Unstaged: 1")
        XCTAssertEqual(el("time.count.staged").label, "Staged: 1")
        XCTAssertEqual(el("time.count.committed").label, "Running: 0")
        XCTAssertEqual(el("time.count.closed").label, "Closed: 0")
        XCTAssertTrue(el("time.card.staged").exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'File the Q3 taxes'")).firstMatch.exists)
        XCTAssertFalse(el("time.list").exists)
        snap("time-asof")
        scrollTo(el("time.card.closed"))
        snap("time-asof-bottom")

        scrollTo(app.buttons["time.back"]) // a no-op when it is already on screen
        var n = 0
        while !app.buttons["time.back"].isHittable && n < 8 { app.swipeDown(); n += 1 }
        app.buttons["time.back"].tap()
        XCTAssertTrue(el("time.list").waitForExistence(timeout: 5))
        XCTAssertFalse(el("time.asof").exists)
        snap("time-back-to-now")
    }
}
