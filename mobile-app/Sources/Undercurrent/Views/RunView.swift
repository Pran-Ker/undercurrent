import SwiftUI

// A run: the question if there is one, the answer box, the steps, the note, the task it yielded.
struct RunView: View {
    @Environment(Board.self) private var board
    var runID: String
    @State private var answer = ""
    @State private var busy = false
    @State private var notice: String?

    private var run: Run? { board.runs.first { $0.id == runID } }

    var body: some View {
        ScrollView {
            if let run {
                let task = board.task(run.taskID)
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Eyebrow(text: run.kind)
                            Chip(text: run.statusLabel, tone: run.status == .needsYou ? .warn : (run.status == .done ? .good : .neutral), mono: true)
                        }
                        Text(task?.text ?? run.taskID).font(Theme.display(26)).foregroundStyle(Theme.inkDeep)
                    }
                    if run.status == .needsYou {
                        Card {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("NEEDS YOU").font(Theme.mono(10)).tracking(1).foregroundStyle(Theme.warn)
                                Text(run.question).font(Theme.body(16)).foregroundStyle(Theme.ink)
                                    .accessibilityIdentifier("run.question")
                                TextField("Your answer", text: $answer, axis: .vertical)
                                    .font(Theme.body(15)).lineLimit(2...6)
                                    .padding(12)
                                    .background(Theme.canvasDeep)
                                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusInset, style: .continuous))
                                    .accessibilityIdentifier("run.answer")
                                Button { Task { await send(run) } } label: { Text(busy ? "Sending…" : "Answer") }
                                    .buttonStyle(.pill)
                                    .disabled(busy || answer.trimmingCharacters(in: .whitespaces).isEmpty)
                                    .accessibilityIdentifier("run.answer.send")
                            }
                        }
                    }
                    if let notice { ErrorBanner(message: notice) { self.notice = nil } }
                    if !run.steps.isEmpty {
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("STEPS").font(Theme.mono(10)).tracking(1).foregroundStyle(Theme.muted)
                                ForEach(Array(run.steps.enumerated()), id: \.offset) { i, s in
                                    NumberedRow(index: i + 1) { Text(s).font(Theme.body(15)).foregroundStyle(Theme.ink) }
                                }
                            }
                        }
                    }
                    if !run.result.isEmpty {
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("RESULT").font(Theme.mono(10)).tracking(1).foregroundStyle(Theme.muted)
                                Text(run.result).font(Theme.body(15)).foregroundStyle(Theme.ink)
                            }
                        }
                    }
                    if let task, !task.note.isEmpty {
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("NOTE").font(Theme.mono(10)).tracking(1).foregroundStyle(Theme.muted)
                                Text(task.note).font(Theme.body(15)).foregroundStyle(Theme.ink)
                            }
                        }
                    }
                    let yielded = board.children(of: run.taskID)
                    if !yielded.isEmpty {
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("YIELDED").font(Theme.mono(10)).tracking(1).foregroundStyle(Theme.muted)
                                ForEach(yielded) { t in
                                    HStack { Text(t.text).font(Theme.body(15)).foregroundStyle(Theme.ink); Spacer(); Chip(text: t.stage.title, mono: true) }
                                }
                            }
                        }
                    }
                    Color.clear.frame(height: 20)
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 8)
            } else {
                VStack(spacing: 8) {
                    Text(board.runsAvailable ? "No such run." : "The backend hasn't built runs yet.")
                        .font(Theme.body(15)).foregroundStyle(Theme.muted)
                }
                .padding(40)
            }
        }
        .scrollIndicators(.hidden)
        .background(Theme.canvas.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.canvas, for: .navigationBar)
        .refreshable { await board.refresh() }
    }

    private func send(_ run: Run) async {
        busy = true; defer { busy = false }
        do {
            try await board.answer(run: run.id, answer.trimmingCharacters(in: .whitespacesAndNewlines))
            answer = ""
            Haptics.success()
        } catch let e as BackendError where e.isNotBuilt {
            notice = "Answering isn't built on the backend yet."
        } catch {
            notice = error.localizedDescription
            Haptics.error()
        }
    }
}
