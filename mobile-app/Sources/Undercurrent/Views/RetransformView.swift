import SwiftUI

// Retransform: describe the change in words; the result shows as the board changing.
struct RetransformView: View {
    @Environment(Board.self) private var board
    @Environment(\.dismiss) private var dismiss
    var task: BoardTask
    @State private var instruction = ""
    @State private var busy = false
    @State private var notice: String?
    @State private var notBuilt = false
    @FocusState private var focused: Bool

    private let examples = [
        "The first half is done, the rest is calling the clinic.",
        "Split this into three.",
        "Add that the landlord prefers mornings.",
    ]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Eyebrow(text: "Retransform")
                Text(task.text).font(Theme.display(24)).foregroundStyle(Theme.inkDeep)
                Text("Rewrite, enrich, split, or mark part of it done. Say it the way you'd say it.")
                    .font(Theme.small(14)).foregroundStyle(Theme.muted)
                TextField("The change", text: $instruction, axis: .vertical)
                    .font(Theme.body(16)).foregroundStyle(Theme.ink)
                    .lineLimit(3...10)
                    .padding(14)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusInset, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusInset, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
                    .focused($focused)
                    .accessibilityIdentifier("retransform.instruction")
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(examples.enumerated()), id: \.offset) { i, e in
                        Button { instruction = e } label: {
                            NumberedRow(index: i + 1) {
                                Text(e).font(Theme.small(14)).foregroundStyle(Theme.muted).multilineTextAlignment(.leading)
                            }
                        }
                        .buttonStyle(.pressable)
                    }
                }
                if notBuilt {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("NOT BUILT YET").font(Theme.mono(10)).tracking(1).foregroundStyle(Theme.muted)
                            Text("The backend answers 501 for retransform today. The task stays as it is.")
                                .font(Theme.body(15)).foregroundStyle(Theme.ink)
                        }
                    }
                    .accessibilityIdentifier("retransform.notbuilt")
                } else if let notice {
                    ErrorBanner(message: notice) { self.notice = nil }
                }
                Spacer()
                Button { Task { await send() } } label: { Text(busy ? "Sending…" : "Retransform") }
                    .buttonStyle(.pill)
                    .disabled(busy || instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("retransform.send")
            }
            .padding(Theme.gutter)
            .background(Theme.canvas.ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { focused = true }
        }
        .presentationDetents([.large])
    }

    private func send() async {
        busy = true; defer { busy = false }
        do {
            try await board.retransform(task.id, instruction: instruction.trimmingCharacters(in: .whitespacesAndNewlines))
            Haptics.success()
            dismiss()
        } catch let e as BackendError where e.isNotBuilt {
            notBuilt = true
        } catch {
            notice = error.localizedDescription
            Haptics.error()
        }
    }
}
