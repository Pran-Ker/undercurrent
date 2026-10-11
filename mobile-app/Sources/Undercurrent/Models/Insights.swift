import Foundation

// The board's biometrics: pure functions over the tasks and events, nothing fetched here. Every
// measure is computed from real rows; there is no placeholder data anywhere in the app.
struct Insights: Equatable {
    struct Measure: Equatable, Identifiable {
        var id: String { title }
        var title: String
        var value: Double
        var unit: String
        var max: Double
        var ideal: Double          // the threshold the track marks as IDEAL
        var higherIsBetter: Bool
        var verdict: Verdict
        var detail: String

        var display: String {
            if unit == "%" { return "\(Int(value.rounded()))" }
            if value == value.rounded() { return "\(Int(value))" }
            return String(format: "%.1f", value)
        }
        var fraction: Double { max > 0 ? min(1, Swift.max(0, value / max)) : 0 }
        var idealFraction: Double { max > 0 ? min(1, Swift.max(0, ideal / max)) : 0 }
        var idealLabel: String {
            let n = ideal == ideal.rounded() ? "\(Int(ideal))" : String(format: "%.1f", ideal)
            return (higherIsBetter ? ">" : "<") + n + " IDEAL"
        }
    }

    enum Verdict: String, Equatable {
        case ideal = "Ideal", improving = "Steady", attention = "Attention", empty = "No data"
    }

    struct Point: Equatable, Identifiable {
        var id: Date { day }
        var day: Date
        var open: Int
        var closed: Int
    }

    struct TagCount: Equatable, Identifiable {
        var id: String { tag }
        var tag: String
        var count: Int
    }

    var counts: [Stage: Int]
    var measures: [Measure]
    var series: [Point]           // open and cumulative-closed per day, last 30 days
    var closedPerWeek: [Point]    // closed per week, last 8 weeks (closed field = that week's count)
    var tags: [TagCount]
    var dueSoon: [BoardTask]
    var overdue: [BoardTask]
    var actors: [(actor: String, count: Int)]

    static func == (a: Insights, b: Insights) -> Bool {
        a.counts == b.counts && a.measures == b.measures && a.series == b.series && a.tags == b.tags
    }

    static func compute(tasks: [BoardTask], events: [Event], now: Date = .now, calendar: Calendar = .current) -> Insights {
        let counts = Dictionary(grouping: tasks, by: \.stage).mapValues(\.count)
        let open = tasks.filter(\.isOpen)
        let unstaged = tasks.filter { $0.stage == .unstaged }
        let decided = tasks.filter { $0.stage != .unstaged }
        let closed = tasks.filter { $0.stage == .closed }
        let today = calendar.startOfDay(for: now)

        // Decided share: how much of the board has had a decision made about it.
        let decidedShare = tasks.isEmpty ? 0 : Double(decided.count) / Double(tasks.count) * 100
        // Unstaged load: lines written down with nothing decided.
        let unstagedCount = Double(unstaged.count)
        // Oldest unstaged line, in days.
        let oldestUnstaged = unstaged.compactMap(\.entryDate).map { Dates.daysBetween($0, now, calendar: calendar) }.max() ?? 0
        // Closed in the last 7 days.
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: today)!
        let closedThisWeek = closed.compactMap(\.doneDate).filter { $0 >= weekAgo }.count
        // Median days from entry to done, over closed tasks.
        let cycle = closed.compactMap { t -> Int? in
            guard let e = t.entryDate, let d = t.doneDate else { return nil }
            return Dates.daysBetween(e, d, calendar: calendar)
        }.sorted()
        let medianCycle: Double = cycle.isEmpty ? 0 : (cycle.count % 2 == 1 ? Double(cycle[cycle.count / 2])
            : Double(cycle[cycle.count / 2 - 1] + cycle[cycle.count / 2]) / 2)
        // Staged with a due date that has passed.
        let overdue = open.filter { $0.stage != .closed }.filter { t in
            guard let d = t.dueDate else { return false }
            return calendar.startOfDay(for: d) < today
        }
        let in7 = calendar.date(byAdding: .day, value: 7, to: today)!
        let dueSoon = open.filter { t in
            guard let d = t.dueDate else { return false }
            let day = calendar.startOfDay(for: d)
            return day >= today && day <= in7
        }.sorted { $0.due < $1.due }

        func verdict(_ value: Double, ideal: Double, higherIsBetter: Bool, empty: Bool) -> Verdict {
            if empty { return .empty }
            if higherIsBetter { return value >= ideal ? .ideal : (value >= ideal * 0.6 ? .improving : .attention) }
            return value <= ideal ? .ideal : (value <= ideal * 1.5 ? .improving : .attention)
        }

        let unstagedMax = Swift.max(20.0, unstagedCount)
        let oldest = Double(oldestUnstaged)
        let oldestMax = Swift.max(30.0, oldest)
        let closedWeek = Double(closedThisWeek)
        let closedWeekMax = Swift.max(10.0, closedWeek)
        let cycleMax = Swift.max(30.0, medianCycle)
        let overdueCount = Double(overdue.count)
        let overdueMax = Swift.max(5.0, overdueCount)

        var measures: [Measure] = []
        measures.append(Measure(title: "Decided", value: decidedShare, unit: "%", max: 100, ideal: 60, higherIsBetter: true,
                                verdict: verdict(decidedShare, ideal: 60, higherIsBetter: true, empty: tasks.isEmpty),
                                detail: "Share of the board that is staged, running or closed."))
        measures.append(Measure(title: "Unstaged load", value: unstagedCount, unit: "lines", max: unstagedMax, ideal: 10, higherIsBetter: false,
                                verdict: verdict(unstagedCount, ideal: 10, higherIsBetter: false, empty: tasks.isEmpty),
                                detail: "Lines written down with nothing decided yet."))
        measures.append(Measure(title: "Oldest unstaged", value: oldest, unit: "days", max: oldestMax, ideal: 14, higherIsBetter: false,
                                verdict: verdict(oldest, ideal: 14, higherIsBetter: false, empty: unstaged.isEmpty),
                                detail: "How long the oldest undecided line has sat."))
        measures.append(Measure(title: "Closed this week", value: closedWeek, unit: "tasks", max: closedWeekMax, ideal: 3, higherIsBetter: true,
                                verdict: verdict(closedWeek, ideal: 3, higherIsBetter: true, empty: tasks.isEmpty),
                                detail: "Tasks closed in the last seven days."))
        measures.append(Measure(title: "Cycle time", value: medianCycle, unit: "days", max: cycleMax, ideal: 7, higherIsBetter: false,
                                verdict: verdict(medianCycle, ideal: 7, higherIsBetter: false, empty: cycle.isEmpty),
                                detail: "Median days from written down to closed."))
        measures.append(Measure(title: "Overdue", value: overdueCount, unit: "tasks", max: overdueMax, ideal: 0, higherIsBetter: false,
                                verdict: verdict(overdueCount, ideal: 0, higherIsBetter: false, empty: open.isEmpty),
                                detail: "Open tasks whose due date has passed."))

        // Daily series: open tasks on that day, and cumulative closed, from entry/done dates.
        var series: [Point] = []
        for offset in stride(from: 29, through: 0, by: -1) {
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: day)!
            let openThen = tasks.filter { t in
                guard let e = t.entryDate, e < dayEnd else { return false }
                if let d = t.doneDate { return d >= dayEnd }
                return t.stage != .closed
            }.count
            let closedBy = closed.compactMap(\.doneDate).filter { $0 < dayEnd }.count
            series.append(Point(day: day, open: openThen, closed: closedBy))
        }

        var weekly: [Point] = []
        for w in stride(from: 7, through: 0, by: -1) {
            let start = calendar.date(byAdding: .day, value: -7 * w, to: weekAgo)!
            let end = calendar.date(byAdding: .day, value: 7, to: start)!
            let n = closed.compactMap(\.doneDate).filter { $0 >= start && $0 < end }.count
            let o = tasks.filter { t in
                guard let e = t.entryDate else { return false }
                return e >= start && e < end
            }.count
            weekly.append(Point(day: start, open: o, closed: n))
        }

        var tagTally: [String: Int] = [:]
        for t in open { for tag in t.tags { tagTally[tag, default: 0] += 1 } }
        var tagCounts: [TagCount] = tagTally.map { TagCount(tag: $0.key, count: $0.value) }
        tagCounts.sort { a, b in a.count == b.count ? a.tag < b.tag : a.count > b.count }

        var actorTally: [String: Int] = [:]
        for e in events { actorTally[e.actorKind, default: 0] += 1 }
        var actorCounts: [(actor: String, count: Int)] = actorTally.map { (actor: $0.key, count: $0.value) }
        actorCounts.sort { a, b in a.count == b.count ? a.actor < b.actor : a.count > b.count }

        return Insights(counts: counts, measures: measures, series: series, closedPerWeek: weekly,
                        tags: Array(tagCounts.prefix(6)), dueSoon: dueSoon, overdue: overdue, actors: actorCounts)
    }
}
