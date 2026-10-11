import SwiftUI

// Home: three stacked cards (Unstaged, Staged, Running), a Closed sheet, an Add button, a Call button.
struct HomeView: View {
    @Environment(Board.self) private var board
    @Binding var path: NavigationPath
    @State private var showAdd = false
    @State private var showClosed = false
    // -call opens the call screen at launch (for driving a real call from the command line).
    @State private var showCall = ProcessInfo.processInfo.arguments.contains("-call")

    private var insights: Insights { Insights.compute(tasks: board.tasks, events: board.events) }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if let error = board.error {
                        ErrorBanner(message: error.errorDescription ?? "Something went wrong.") {
                            Task { await board.refresh() }
                        }
                    }
                    countsStrip
                    stageCard(.unstaged, empty: "Nothing written down. Add one below.")
                    stageCard(.staged, empty: "Stage an unstaged task by adding context.")
                    runningCard
                    closedLink
                    Color.clear.frame(height: 80)
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 8)
            }
            .refreshable { await board.refresh() }
            .scrollIndicators(.hidden)

            addButton
        }
        .background(Theme.canvas.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.canvas, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { path.append(Route.time) } label: {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 15, weight: .regular))
                }
                .accessibilityLabel("Time travel")
                .accessibilityIdentifier("nav.time")
                Button { path.append(Route.insights) } label: {
                    Image(systemName: "chart.xyaxis.line").font(.system(size: 15, weight: .regular))
                }
                .accessibilityLabel("Insights")
                .accessibilityIdentifier("nav.insights")
                Button { path.append(Route.settings) } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 15, weight: .regular))
                }
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("nav.settings")
                Button { Haptics.medium(); showCall = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform").font(.system(size: 12, weight: .medium))
                        Text("Call").font(Theme.bodyMedium(14))
                    }
                    .foregroundStyle(Theme.canvas)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Theme.inkDeep)
                    .clipShape(Capsule())
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("nav.call")
            }
        }
        .sheet(isPresented: $showAdd) { AddSheet() }
        .sheet(isPresented: $showClosed) { ClosedSheet(path: $path) }
        .fullScreenCover(isPresented: $showCall) { CallView() }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "The board")
            TwoToneTitle(first: Self.dayLine(), second: subtitle)
        }
        .padding(.top, 8)
    }

    private var subtitle: String {
        let open = board.tasks.filter(\.isOpen).count
        if board.lastSync == nil && board.tasks.isEmpty { return board.loading ? "loading…" : "not synced yet" }
        let needs = board.needsYou.count
        if needs > 0 { return "\(needs) need\(needs == 1 ? "s" : "") you" }
        return "\(open) open"
    }

    static func dayLine(now: Date = .now) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM"
        return f.string(from: now)
    }

    private var countsStrip: some View {
        HStack(spacing: 10) {
            ForEach(Stage.allCases) { stage in
                let n = board.counts[stage] ?? 0
                VStack(alignment: .leading, spacing: 4) {
                    Text(stage.title.uppercased()).font(Theme.mono(9)).tracking(1).foregroundStyle(Theme.muted)
                    Text("\(n)").font(Theme.numeral(26)).foregroundStyle(Theme.inkDeep)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusInset, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusInset, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(stage.title): \(n)")
                .accessibilityIdentifier("count.\(stage.rawValue)")
            }
        }
    }

    private func stageCard(_ stage: Stage, empty: String) -> some View {
        let tasks = board.tasks(in: stage)
        return Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                cardHeader(stage.title, count: tasks.count, blurb: stage.blurb)
                if tasks.isEmpty {
                    EmptyLine(text: empty).padding(.horizontal, Theme.cardPadding).padding(.bottom, 12)
                } else {
                    ForEach(Array(tasks.enumerated()), id: \.element.id) { i, task in
                        Button { path.append(Route.task(task.id)) } label: {
                            TaskRow(task: task, index: i + 1)
                        }
                        .buttonStyle(.pressable)
                        .accessibilityIdentifier("row.\(task.id)")
                        if i < tasks.count - 1 { Hairline().padding(.leading, Theme.cardPadding) }
                    }
                }
            }
        }
        .accessibilityIdentifier("card.\(stage.rawValue)")
    }

    private var runningCard: some View {
        let tasks = board.tasks(in: .committed)
        return Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                cardHeader("Running", count: tasks.count, blurb: Stage.committed.blurb)
                if tasks.isEmpty {
                    EmptyLine(text: board.runsAvailable ? "No agent is on anything." : "Commit a staged task once the backend builds runs.")
                        .padding(.horizontal, Theme.cardPadding).padding(.bottom, 12)
                } else {
                    ForEach(Array(tasks.enumerated()), id: \.element.id) { i, task in
                        let run = board.run(for: task.id)
                        Button {
                            if let run { path.append(Route.run(run.id)) } else { path.append(Route.task(task.id)) }
                        } label: {
                            TaskRow(task: task, index: i + 1, run: run)
                        }
                        .buttonStyle(.pressable)
                        .accessibilityIdentifier("row.\(task.id)")
                        if i < tasks.count - 1 { Hairline().padding(.leading, Theme.cardPadding) }
                    }
                }
            }
        }
        .accessibilityIdentifier("card.committed")
    }

    private func cardHeader(_ title: String, count: Int, blurb: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Theme.title(20)).foregroundStyle(Theme.inkDeep)
                Spacer()
                Text("\(count)").font(Theme.mono(12)).foregroundStyle(Theme.muted)
            }
            Text(blurb).font(Theme.small(13)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, Theme.cardPadding)
        .padding(.top, Theme.cardPadding)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var closedLink: some View {
        let n = board.counts[.closed] ?? 0
        return Button { showClosed = true } label: {
            HStack {
                Text("Closed").font(Theme.body(15)).foregroundStyle(Theme.ink)
                Text("\(n)").font(Theme.mono(12)).foregroundStyle(Theme.muted)
                Spacer()
                Image(systemName: "chevron.up").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, Theme.cardPadding)
            .padding(.vertical, 14)
            .background(Theme.canvasDeep)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusInset, style: .continuous))
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("closed.open")
        .accessibilityLabel("Closed, \(n)")
    }

    private var addButton: some View {
        Button { Haptics.tap(); showAdd = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 14, weight: .medium))
                Text("Add").font(Theme.bodyMedium(15))
            }
            .foregroundStyle(Theme.canvas)
            .padding(.horizontal, 22).padding(.vertical, 14)
            .background(Theme.inkDeep)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        }
        .buttonStyle(.pressable)
        .padding(.bottom, 18)
        .accessibilityIdentifier("add.open")
        .accessibilityLabel("Add a task")
    }
}

// One row in a card: the text, then a mono meta line (priority · due · tags · run status).
struct TaskRow: View {
    var task: BoardTask
    var index: Int
    var run: Run? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("[\(index)]").font(Theme.mono(11)).foregroundStyle(Theme.muted).frame(width: 28, alignment: .leading).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(task.text).font(Theme.body(16)).foregroundStyle(Theme.ink).multilineTextAlignment(.leading)
                    .lineLimit(2)
                meta
            }
            Spacer(minLength: 0)
            if let run {
                Chip(text: run.statusLabel, tone: run.status == .needsYou ? .warn : (run.status == .done ? .good : .neutral), mono: true)
            } else {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.slate).padding(.top, 5)
            }
        }
        .padding(.horizontal, Theme.cardPadding)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var meta: some View {
        let parts = metaParts
        if !parts.isEmpty {
            Text(parts.joined(separator: "  ·  "))
                .font(Theme.mono(10)).tracking(0.3)
                .foregroundStyle(isOverdue ? Theme.warn : Theme.muted)
                .lineLimit(1)
        }
    }

    private var isOverdue: Bool {
        guard task.isOpen, let d = task.dueDate else { return false }
        return Calendar.current.startOfDay(for: d) < Calendar.current.startOfDay(for: .now)
    }

    private var metaParts: [String] {
        var p: [String] = []
        if !task.priorityLabel.isEmpty { p.append(task.priorityLabel.uppercased()) }
        if !task.due.isEmpty { p.append((isOverdue ? "OVERDUE " : "DUE ") + Dates.short(task.due).uppercased()) }
        if task.stage == .closed, !task.done.isEmpty { p.append("CLOSED " + Dates.short(task.done).uppercased()) }
        if !task.tags.isEmpty { p.append(task.tags.map { "#" + $0 }.joined(separator: " ")) }
        if task.stage == .unstaged, !task.entry.isEmpty { p.append("WRITTEN " + Dates.short(task.entry).uppercased()) }
        return p
    }
}
