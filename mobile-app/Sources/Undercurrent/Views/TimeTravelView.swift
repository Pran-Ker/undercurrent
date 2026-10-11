import SwiftUI

// Time travel: the last 20 actions, each a moment the board can be shown at. Read-only; the
// backend's event log is the only source, and nothing here writes.
struct TimeTravelView: View {
    @Environment(Board.self) private var board
    @State private var events: [Event] = []
    @State private var loading = false
    @State private var error: BackendError?
    @State private var moment: Event?
    @State private var past: BoardState?
    @State private var pastLoading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let error {
                    ErrorBanner(message: error.errorDescription ?? "Something went wrong.") {
                        Task { if let moment { await show(moment) } else { await load() } }
                    }
                }
                if let moment {
                    asOf(moment)
                    if let past { boardCards(past) } else if pastLoading { Card { EmptyLine(text: "Rewinding…") } }
                } else {
                    list
                }
                Color.clear.frame(height: 24)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
        .background(Theme.canvas.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.canvas, for: .navigationBar)
        .task { await load() }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Time travel")
            if moment == nil {
                TwoToneTitle(first: "Rewind the board", second: "the last 20 actions", size: 28)
                Text("Tap one to see the board as it was right after it.")
                    .font(Theme.small(14)).foregroundStyle(Theme.muted)
            } else {
                TwoToneTitle(first: "The board", second: "as it was", size: 28)
            }
        }
        .padding(.top, 8)
    }

    private var list: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if loading && events.isEmpty {
                    EmptyLine(text: "Loading…").padding(Theme.cardPadding)
                } else if events.isEmpty {
                    EmptyLine(text: "Nothing has happened yet.").padding(Theme.cardPadding)
                } else {
                    ForEach(Array(events.enumerated()), id: \.element.id) { i, e in
                        Button { Haptics.tap(); Task { await show(e) } } label: { row(e, index: i + 1) }
                            .buttonStyle(.pressable)
                            .accessibilityIdentifier("time.row.\(i + 1)")
                        if i < events.count - 1 { Hairline().padding(.leading, Theme.cardPadding) }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("time.list")
    }

    private func row(_ e: Event, index: Int) -> some View {
        NumberedRow(index: index) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(e.actorKind) · \(e.action)").font(Theme.body(15)).foregroundStyle(Theme.ink)
                if let text = (e.after ?? e.before)?.text, !text.isEmpty {
                    Text(text).font(Theme.small(13)).foregroundStyle(Theme.muted).lineLimit(2).multilineTextAlignment(.leading)
                }
                Text(TaskDetailView.when(e.at)).font(Theme.mono(10)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.slate)
        }
        .padding(.horizontal, Theme.cardPadding)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func asOf(_ e: Event) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("AS OF \(TaskDetailView.when(e.at).uppercased())").font(Theme.mono(11)).tracking(1).foregroundStyle(Theme.ink)
                    .accessibilityIdentifier("time.asof")
                Text("right after \(e.actorKind) · \(e.action)").font(Theme.small(13)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Button { Haptics.tap(); withAnimation(Theme.spring) { moment = nil; past = nil; error = nil } } label: { Text("Back to now") }
                .buttonStyle(.pill(.secondary, expand: false))
                .accessibilityIdentifier("time.back")
        }
        .padding(.horizontal, Theme.cardPadding)
        .padding(.vertical, 12)
        .background(Theme.canvasDeep)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusInset, style: .continuous))
    }

    @ViewBuilder private func boardCards(_ state: BoardState) -> some View {
        let counts = Dictionary(grouping: state.tasks, by: \.stage).mapValues(\.count)
        HStack(spacing: 10) {
            ForEach(Stage.allCases) { stage in
                let n = counts[stage] ?? 0
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
                .accessibilityIdentifier("time.count.\(stage.rawValue)")
            }
        }
        ForEach(Stage.allCases) { stage in
            stageCard(stage, tasks: state.tasks.filter { $0.stage == stage })
        }
    }

    private func stageCard(_ stage: Stage, tasks: [BoardTask]) -> some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(stage.title).font(Theme.title(20)).foregroundStyle(Theme.inkDeep)
                        Spacer()
                        Text("\(tasks.count)").font(Theme.mono(12)).foregroundStyle(Theme.muted)
                    }
                    Text(stage.blurb).font(Theme.small(13)).foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, Theme.cardPadding)
                .padding(.top, Theme.cardPadding)
                .padding(.bottom, 10)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                if tasks.isEmpty {
                    EmptyLine(text: "Nothing here then.").padding(.horizontal, Theme.cardPadding).padding(.bottom, 12)
                } else {
                    ForEach(Array(tasks.enumerated()), id: \.element.id) { i, task in
                        TaskRow(task: task, index: i + 1)
                        if i < tasks.count - 1 { Hairline().padding(.leading, Theme.cardPadding) }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("time.card.\(stage.rawValue)")
    }

    // MARK: Data

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            events = try await board.backend.events(limit: 20).reversed()
            error = nil
        } catch let e as BackendError {
            error = e
        } catch {
            self.error = .http(0, error.localizedDescription)
        }
    }

    private func show(_ e: Event) async {
        withAnimation(Theme.spring) { moment = e; past = nil; error = nil }
        pastLoading = true
        defer { pastLoading = false }
        do {
            let state = try await board.backend.state(at: e.at)
            withAnimation(Theme.spring) { past = state }
        } catch let e as BackendError {
            error = e
        } catch {
            self.error = .http(0, error.localizedDescription)
        }
    }
}
