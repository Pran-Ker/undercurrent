import XCTest
@testable import Undercurrent

final class InsightsTests: XCTestCase {
    let now = Dates.day("2026-10-11")!.addingTimeInterval(10 * 3600)
    var cal: Calendar { Calendar(identifier: .gregorian) }   // the device's timezone, like Dates

    func board() -> [BoardTask] {
        [
            BoardTask(id: "u001", stage: .unstaged, text: "a", entry: "2026-09-01"),
            BoardTask(id: "u002", stage: .unstaged, text: "b", tags: ["home"], entry: "2026-10-09"),
            BoardTask(id: "s001", stage: .staged, text: "c", context: "x", due: "2026-10-05", tags: ["home", "money"], entry: "2026-10-01"),
            BoardTask(id: "s002", stage: .staged, text: "d", context: "x", due: "2026-10-14", entry: "2026-10-01"),
            BoardTask(id: "c001", stage: .committed, text: "e", context: "x", entry: "2026-10-08"),
            BoardTask(id: "x001", stage: .closed, text: "f", entry: "2026-10-01", done: "2026-10-08"),
            BoardTask(id: "x002", stage: .closed, text: "g", entry: "2026-09-20", done: "2026-09-25"),
        ]
    }

    func testCountsAndMeasures() {
        let i = Insights.compute(tasks: board(), events: [], now: now, calendar: cal)
        XCTAssertEqual(i.counts[.unstaged], 2)
        XCTAssertEqual(i.counts[.staged], 2)
        XCTAssertEqual(i.counts[.committed], 1)
        XCTAssertEqual(i.counts[.closed], 2)

        func m(_ title: String) -> Insights.Measure { i.measures.first { $0.title == title }! }
        XCTAssertEqual(m("Decided").value, 5.0 / 7.0 * 100, accuracy: 0.01)
        XCTAssertEqual(m("Decided").verdict, .ideal)
        XCTAssertEqual(m("Unstaged load").value, 2)
        XCTAssertEqual(m("Unstaged load").verdict, .ideal)
        XCTAssertEqual(m("Oldest unstaged").value, 40)
        XCTAssertEqual(m("Oldest unstaged").verdict, .attention)
        XCTAssertEqual(m("Closed this week").value, 1)        // 2026-10-08 is within 7 days of 10-11
        XCTAssertEqual(m("Cycle time").value, 6)              // (7 + 5) / 2
        XCTAssertEqual(m("Overdue").value, 1)                 // s001 due 10-05
        XCTAssertEqual(m("Overdue").verdict, .attention)
        XCTAssertEqual(m("Overdue").idealLabel, "<0 IDEAL")
        XCTAssertEqual(m("Decided").idealLabel, ">60 IDEAL")
    }

    func testEmptyBoardIsAllEmptyVerdicts() {
        let i = Insights.compute(tasks: [], events: [], now: now, calendar: cal)
        XCTAssertTrue(i.measures.allSatisfy { $0.verdict == .empty })
        XCTAssertEqual(i.series.count, 30)
        XCTAssertTrue(i.series.allSatisfy { $0.open == 0 && $0.closed == 0 })
        XCTAssertTrue(i.tags.isEmpty)
    }

    func testSeriesCountsOpenOnEachDay() {
        let i = Insights.compute(tasks: board(), events: [], now: now, calendar: cal)
        XCTAssertEqual(i.series.count, 30)
        let last = i.series.last!
        XCTAssertEqual(last.open, 5)      // everything not closed
        XCTAssertEqual(last.closed, 2)
        // On 2026-10-07, x001 was still open and x002 was closed.
        let oct7 = i.series.first { cal.isDate($0.day, inSameDayAs: Dates.day("2026-10-07")!) }!
        XCTAssertEqual(oct7.closed, 1)
        XCTAssertEqual(oct7.open, 4)      // u001, s001, s002, x001 (u002 and c001 not yet written)
    }

    func testDueListsAndTags() {
        let i = Insights.compute(tasks: board(), events: [], now: now, calendar: cal)
        XCTAssertEqual(i.overdue.map(\.id), ["s001"])
        XCTAssertEqual(i.dueSoon.map(\.id), ["s002"])
        XCTAssertEqual(i.tags.first?.tag, "home")
        XCTAssertEqual(i.tags.first?.count, 2)
        XCTAssertEqual(i.closedPerWeek.count, 8)
    }

    func testActorsFromEvents() throws {
        let events = [
            try JSONDecoder().decode(Event.self, from: Data(#"{"id":1,"actor":"user","action":"add"}"#.utf8)),
            try JSONDecoder().decode(Event.self, from: Data(#"{"id":2,"actor":"agent:r1","action":"close"}"#.utf8)),
            try JSONDecoder().decode(Event.self, from: Data(#"{"id":3,"actor":"user","action":"stage"}"#.utf8)),
        ]
        let i = Insights.compute(tasks: board(), events: events, now: now, calendar: cal)
        XCTAssertEqual(i.actors.first?.actor, "user")
        XCTAssertEqual(i.actors.first?.count, 2)
    }

    // MARK: Edge cases: week boundaries, overdue vs due today, missing dates

    func task(_ id: String, _ stage: Stage, entry: String = "", due: String = "", done: String = "", tags: [String] = []) -> BoardTask {
        BoardTask(id: id, stage: stage, text: id, due: due, tags: tags, entry: entry, done: done)
    }

    func metric(_ i: Insights, _ title: String) -> Insights.Measure { i.measures.first { $0.title == title }! }

    func testClosedThisWeekBoundaries() {
        // now is 2026-10-11: today and six days ago count, eight days ago does not.
        let tasks = [
            task("x1", .closed, entry: "2026-10-01", done: "2026-10-11"),
            task("x2", .closed, entry: "2026-10-01", done: "2026-10-05"),
            task("x3", .closed, entry: "2026-10-01", done: "2026-10-03"),
        ]
        let i = Insights.compute(tasks: tasks, events: [], now: now, calendar: cal)
        XCTAssertEqual(metric(i, "Closed this week").value, 2)
        XCTAssertEqual(metric(i, "Closed this week").verdict, .improving)   // 2 of the ideal 3
        XCTAssertEqual(metric(i, "Closed this week").max, 10)
    }

    func testClosedPerWeekBuckets() {
        let tasks = [
            task("x1", .closed, entry: "2026-10-10", done: "2026-10-10"),
            task("x2", .closed, entry: "2026-08-01", done: "2026-08-10"),   // more than eight weeks ago
            task("u1", .unstaged, entry: "2026-10-09"),
        ]
        let i = Insights.compute(tasks: tasks, events: [], now: now, calendar: cal)
        XCTAssertEqual(i.closedPerWeek.count, 8)
        XCTAssertEqual(i.closedPerWeek.last?.closed, 1)
        XCTAssertEqual(i.closedPerWeek.last?.open, 2)      // entries that week: x1 and u1
        XCTAssertEqual(i.closedPerWeek.map(\.closed).reduce(0, +), 1)
        XCTAssertEqual(i.closedPerWeek.map(\.open).reduce(0, +), 2)
        for (a, b) in zip(i.closedPerWeek, i.closedPerWeek.dropFirst()) {
            XCTAssertEqual(Dates.daysBetween(a.day, b.day, calendar: cal), 7)
        }
        XCTAssertLessThan(Dates.daysBetween(i.closedPerWeek.last!.day, now, calendar: cal), 8)
    }

    func testClosedPerWeekCountsATaskClosedToday() {
        // The "Closed this week" measure counts a task closed today; the weekly chart should agree.
        let tasks = [task("x1", .closed, entry: "2026-10-01", done: "2026-10-11")]
        let i = Insights.compute(tasks: tasks, events: [], now: now, calendar: cal)
        XCTAssertEqual(metric(i, "Closed this week").value, 1)
        XCTAssertEqual(i.closedPerWeek.map(\.closed).reduce(0, +), 1)
    }

    func testOverdueVersusDueToday() {
        let tasks = [
            task("y", .staged, entry: "2026-10-01", due: "2026-10-10"),       // yesterday: overdue
            task("t", .staged, entry: "2026-10-01", due: "2026-10-11"),       // today: due soon, not overdue
            task("w", .unstaged, entry: "2026-10-01", due: "2026-10-18"),     // in 7 days: due soon
            task("l", .staged, entry: "2026-10-01", due: "2026-10-19"),       // in 8 days: neither
            task("c", .committed, entry: "2026-10-01", due: "2026-09-01"),    // the agent's, still overdue
            task("z", .closed, entry: "2026-10-01", due: "2026-09-01", done: "2026-10-02"),   // closed: neither
            task("n", .staged, entry: "2026-10-01"),                          // no due date: neither
            task("b", .staged, entry: "2026-10-01", due: "not a date"),       // unreadable: neither
        ]
        let i = Insights.compute(tasks: tasks, events: [], now: now, calendar: cal)
        XCTAssertEqual(Set(i.overdue.map(\.id)), ["y", "c"])
        XCTAssertEqual(i.dueSoon.map(\.id), ["t", "w"])
        XCTAssertEqual(metric(i, "Overdue").value, 2)
        XCTAssertEqual(metric(i, "Overdue").verdict, .attention)
        XCTAssertEqual(metric(i, "Overdue").max, 5)
    }

    func testOverdueLateInTheDayStillUsesCalendarDays() {
        // 23:30 local on 10-11: a task due 10-11 is not overdue yet; at 00:30 on 10-12 it is.
        let late = Dates.day("2026-10-11")!.addingTimeInterval(23 * 3600 + 1800)
        let tasks = [task("t", .staged, entry: "2026-10-01", due: "2026-10-11")]
        let i = Insights.compute(tasks: tasks, events: [], now: late, calendar: cal)
        XCTAssertTrue(i.overdue.isEmpty)
        XCTAssertEqual(i.dueSoon.map(\.id), ["t"])
        let justAfter = Dates.day("2026-10-12")!.addingTimeInterval(1800)
        let j = Insights.compute(tasks: tasks, events: [], now: justAfter, calendar: cal)
        XCTAssertEqual(j.overdue.map(\.id), ["t"])
        XCTAssertTrue(j.dueSoon.isEmpty)
    }

    func testOverdueIsEmptyVerdictWithNothingOpen() {
        let tasks = [task("z", .closed, entry: "2026-10-01", due: "2026-09-01", done: "2026-10-02")]
        let i = Insights.compute(tasks: tasks, events: [], now: now, calendar: cal)
        XCTAssertEqual(metric(i, "Overdue").verdict, .empty)
        XCTAssertEqual(metric(i, "Decided").verdict, .ideal)
        XCTAssertEqual(metric(i, "Oldest unstaged").verdict, .empty)
    }

    func testTasksWithNoEntryDate() {
        let tasks = [
            task("u1", .unstaged),                                // never dated
            task("u2", .unstaged, entry: "2026-10-09"),
            task("x1", .closed, done: "2026-10-10"),              // closed, no entry: no cycle time
        ]
        let i = Insights.compute(tasks: tasks, events: [], now: now, calendar: cal)
        XCTAssertEqual(metric(i, "Oldest unstaged").value, 2)
        XCTAssertEqual(metric(i, "Cycle time").verdict, .empty)
        XCTAssertEqual(metric(i, "Closed this week").value, 1)
        XCTAssertEqual(i.counts[.unstaged], 2)
        XCTAssertEqual(metric(i, "Unstaged load").value, 2)
        // The series only knows tasks with an entry date; the undated closed one still counts as closed.
        XCTAssertEqual(i.series.last?.open, 1)
        XCTAssertEqual(i.series.last?.closed, 1)
        XCTAssertEqual(i.closedPerWeek.map(\.open).reduce(0, +), 1)
        let undatedOnly = Insights.compute(tasks: [task("u1", .unstaged)], events: [], now: now, calendar: cal)
        XCTAssertEqual(metric(undatedOnly, "Oldest unstaged").value, 0)
        XCTAssertTrue(undatedOnly.series.allSatisfy { $0.open == 0 })
    }

    func testClosedTasksWithoutDone() {
        let tasks = [
            task("x1", .closed, entry: "2026-10-01"),                        // closed, no done date
            task("x2", .closed, entry: "2026-10-01", done: "2026-10-09"),
            task("u1", .unstaged, entry: "2026-10-01"),
        ]
        let i = Insights.compute(tasks: tasks, events: [], now: now, calendar: cal)
        XCTAssertEqual(i.counts[.closed], 2)
        XCTAssertEqual(metric(i, "Closed this week").value, 1)
        XCTAssertEqual(metric(i, "Cycle time").value, 8)
        XCTAssertEqual(metric(i, "Decided").value, 2.0 / 3.0 * 100, accuracy: 0.01)
        // x1 is not open on any day and, without a date, is not on the closed line either.
        XCTAssertEqual(i.series.last?.open, 1)
        XCTAssertEqual(i.series.last?.closed, 1)
        XCTAssertEqual(i.closedPerWeek.map(\.closed).reduce(0, +), 1)
    }

    func testMedianCycleWithOddCount() {
        let tasks = [
            task("a", .closed, entry: "2026-10-01", done: "2026-10-02"),   // 1
            task("b", .closed, entry: "2026-10-01", done: "2026-10-11"),   // 10
            task("c", .closed, entry: "2026-10-01", done: "2026-10-04"),   // 3
        ]
        let i = Insights.compute(tasks: tasks, events: [], now: now, calendar: cal)
        XCTAssertEqual(metric(i, "Cycle time").value, 3)
        XCTAssertEqual(metric(i, "Cycle time").verdict, .ideal)
        XCTAssertEqual(metric(i, "Cycle time").display, "3")
        XCTAssertEqual(metric(i, "Cycle time").max, 30)
    }

    func testVerdictBands() {
        // Decided: 4 of 10 = 40%, under 60 but at least 36 → Steady.
        var tasks = (0..<6).map { task("u\($0)", .unstaged, entry: "2026-10-10") }
        tasks += (0..<4).map { task("s\($0)", .staged, entry: "2026-10-10") }
        var i = Insights.compute(tasks: tasks, events: [], now: now, calendar: cal)
        XCTAssertEqual(metric(i, "Decided").verdict, .improving)
        XCTAssertEqual(metric(i, "Decided").display, "40")
        // Unstaged load: 12 lines is over 10 but under 15 → Steady; 16 → Attention.
        tasks = (0..<12).map { task("u\($0)", .unstaged, entry: "2026-10-10") }
        i = Insights.compute(tasks: tasks, events: [], now: now, calendar: cal)
        XCTAssertEqual(metric(i, "Unstaged load").verdict, .improving)
        XCTAssertEqual(metric(i, "Unstaged load").max, 20)
        tasks = (0..<16).map { task("u\($0)", .unstaged, entry: "2026-10-10") }
        i = Insights.compute(tasks: tasks, events: [], now: now, calendar: cal)
        XCTAssertEqual(metric(i, "Unstaged load").verdict, .attention)
        XCTAssertEqual(metric(i, "Decided").verdict, .attention)
        // Twenty-five lines: the track grows so the marker stays on it.
        tasks = (0..<25).map { task("u\($0)", .unstaged, entry: "2026-10-10") }
        i = Insights.compute(tasks: tasks, events: [], now: now, calendar: cal)
        XCTAssertEqual(metric(i, "Unstaged load").max, 25)
        XCTAssertEqual(metric(i, "Unstaged load").fraction, 1)
        XCTAssertEqual(metric(i, "Unstaged load").idealFraction, 10.0 / 25.0, accuracy: 0.0001)
    }

    func testTagsCountOpenTasksOnlyAndCapAtSix() {
        var tasks = [
            task("c1", .closed, entry: "2026-10-01", done: "2026-10-02", tags: ["gone", "gone2"]),
            task("o1", .staged, entry: "2026-10-01", tags: ["b", "a"]),
            task("o2", .staged, entry: "2026-10-01", tags: ["b"]),
        ]
        tasks += (0..<7).map { task("t\($0)", .unstaged, entry: "2026-10-01", tags: ["z\($0)"]) }
        let i = Insights.compute(tasks: tasks, events: [], now: now, calendar: cal)
        XCTAssertEqual(i.tags.count, 6)
        XCTAssertEqual(i.tags.first?.tag, "b")
        XCTAssertEqual(i.tags.first?.count, 2)
        XCTAssertEqual(i.tags[1].tag, "a")                 // ties break alphabetically
        XCTAssertFalse(i.tags.contains { $0.tag.hasPrefix("gone") })
    }

    func testSeriesSpansThirtyDaysEndingToday() {
        let i = Insights.compute(tasks: board(), events: [], now: now, calendar: cal)
        XCTAssertTrue(cal.isDate(i.series.last!.day, inSameDayAs: now))
        XCTAssertEqual(Dates.daysBetween(i.series.first!.day, i.series.last!.day, calendar: cal), 29)
        let fresh = Insights.compute(tasks: [task("u1", .unstaged, entry: "2026-10-11")], events: [], now: now, calendar: cal)
        XCTAssertEqual(fresh.series.map(\.open), Array(repeating: 0, count: 29) + [1])
        // Closed the day it was written down: open on no day, closed from that day on.
        let sameDay = Insights.compute(tasks: [task("x1", .closed, entry: "2026-10-10", done: "2026-10-10")], events: [], now: now, calendar: cal)
        XCTAssertTrue(sameDay.series.allSatisfy { $0.open == 0 })
        XCTAssertEqual(Array(sameDay.series.map(\.closed).suffix(3)), [0, 1, 1])
    }

    func testActorsCountKindsAndSortByCountThenName() {
        let events = [
            Event(id: 1, at: "", actor: "live:c1", action: "add"),
            Event(id: 2, at: "", actor: "agent:r1", action: "close"),
            Event(id: 3, at: "", actor: "agent:r2", action: "close"),
            Event(id: 4, at: "", actor: "", action: "edit"),
        ]
        let i = Insights.compute(tasks: [], events: events, now: now, calendar: cal)
        XCTAssertEqual(i.actors.map(\.actor), ["agent", "live", "user"])
        XCTAssertEqual(i.actors.map(\.count), [2, 1, 1])
        XCTAssertTrue(Insights.compute(tasks: [], events: [], now: now, calendar: cal).actors.isEmpty)
    }

    func testMeasureDisplayFormats() {
        var m = Insights.Measure(title: "x", value: 71.6, unit: "%", max: 100, ideal: 60, higherIsBetter: true, verdict: .ideal, detail: "")
        XCTAssertEqual(m.display, "72")
        m.unit = "days"; m.value = 2.5
        XCTAssertEqual(m.display, "2.5")
        m.max = 0
        XCTAssertEqual(m.fraction, 0)
        XCTAssertEqual(m.idealFraction, 0)
        m.ideal = 7.5; m.max = 10; m.higherIsBetter = false
        XCTAssertEqual(m.idealLabel, "<7.5 IDEAL")
        XCTAssertEqual(m.idealFraction, 0.75)
        m.value = 40
        XCTAssertEqual(m.fraction, 1)
    }
}
