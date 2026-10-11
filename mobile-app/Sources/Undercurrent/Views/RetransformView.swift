import SwiftUI

// Retransform: describe the change in words; the model says what it did and the board changes.
struct RetransformView: View {
    @Environment(Board.self) private var board
    @Environment(\.dismiss) private var dismiss
    var task: BoardTask
    @State private var instruction = ""
    @State private var busy = false
    @State private var notice: String?
    @State private var say: String?
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
                    .disabled(say != nil)
                    .accessibilityIdentifier("retransform.instruction")
                if let say {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("THE MODEL SAID").font(Theme.mono(10)).tracking(1).foregroundStyle(Theme.muted)
                            Text(say).font(Theme.body(15)).foregroundStyle(Theme.ink)
                                .accessibilityIdentifier("retransform.say")
                            Text("The board has changed behind this sheet.").font(Theme.small(13)).foregroundStyle(Theme.muted)
                        }
                    }
                } else {
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
                }
                if let notice {
                    ErrorBanner(message: notice) { self.notice = nil }
                }
                Spacer()
                if say != nil {
                    Button { dismiss() } label: { Text("Done") }
                        .buttonStyle(.pill).accessibilityIdentifier("retransform.done")
                } else {
                    Button { Task { await send() } } label: { Text(busy ? "Sending…" : "Retransform") }
                        .buttonStyle(.pill)
                        .disabled(busy || instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("retransform.send")
                }
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
            let r = try await board.retransform(task.id, instruction: instruction.trimmingCharacters(in: .whitespacesAndNewlines))
            say = r.say.isEmpty ? "Done. The run \(r.run.id) is \(r.run.statusLabel)." : r.say
            focused = false
            Haptics.success()
        } catch {
            notice = error.localizedDescription
            Haptics.error()
        }
    }
}
