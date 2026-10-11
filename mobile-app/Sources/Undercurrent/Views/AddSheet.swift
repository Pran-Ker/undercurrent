import SwiftUI

// Add: one text field, lands unstaged. Tags and a due date are optional and folded away.
struct AddSheet: View {
    @Environment(Board.self) private var board
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var tags = ""
    @State private var priority = ""
    @State private var due: Date? = nil
    @State private var more = false
    @State private var busy = false
    @State private var notice: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Eyebrow(text: "Write it down")
                TextField("What has to happen", text: $text, axis: .vertical)
                    .font(Theme.display(24)).foregroundStyle(Theme.inkDeep)
                    .lineLimit(1...5)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { Task { await add() } }
                    .accessibilityIdentifier("add.text")
                Text("It lands unstaged. Decide later.").font(Theme.small(14)).foregroundStyle(Theme.muted)

                DisclosureGroup(isExpanded: $more) {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("tags, space separated", text: $tags)
                            .font(Theme.body(15)).autocorrectionDisabled().textInputAutocapitalization(.never)
                            .accessibilityIdentifier("add.tags")
                        HStack(spacing: 8) {
                            Text("PRIORITY").font(Theme.mono(10)).tracking(1).foregroundStyle(Theme.muted)
                            ForEach(["H", "M", "L"], id: \.self) { p in
                                Button {
                                    priority = priority == p ? "" : p
                                } label: {
                                    Text(p).font(Theme.mono(12))
                                        .foregroundStyle(priority == p ? Theme.canvas : Theme.ink)
                                        .frame(width: 34, height: 30)
                                        .background(priority == p ? Theme.inkDeep : Theme.canvasDeep)
                                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusChip, style: .continuous))
                                }
                                .buttonStyle(.pressable)
                                .accessibilityLabel("Priority \(p)")
                            }
                        }
                        HStack {
                            Text("DUE").font(Theme.mono(10)).tracking(1).foregroundStyle(Theme.muted)
                            if let d = due {
                                DatePicker("", selection: Binding(get: { d }, set: { due = $0 }), displayedComponents: .date).labelsHidden()
                                Button("clear") { due = nil }.font(Theme.small(13))
                            } else {
                                Button("set a date") { due = .now }.font(Theme.small(13))
                            }
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("More").font(Theme.small(14)).foregroundStyle(Theme.muted)
                }
                .tint(Theme.muted)

                if let notice { ErrorBanner(message: notice) { self.notice = nil } }
                Spacer()
                Button { Task { await add() } } label: { Text(busy ? "Adding…" : "Add") }
                    .buttonStyle(.pill)
                    .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("add.confirm")
            }
            .padding(Theme.gutter)
            .background(Theme.canvas.ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { focused = true }
        }
        .presentationDetents([.large])
    }

    private func add() async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !busy else { return }
        busy = true; defer { busy = false }
        do {
            try await board.add(text: t, tags: tags.split(separator: " ").map(String.init), priority: priority,
                                due: due.map(Dates.dayString) ?? "")
            Haptics.success()
            dismiss()
        } catch {
            notice = error.localizedDescription
            Haptics.error()
        }
    }
}

// Closed: the sheet pulled up from the bottom of the board.
struct ClosedSheet: View {
    @Environment(Board.self) private var board
    @Environment(\.dismiss) private var dismiss
    @Binding var path: NavigationPath

    var body: some View {
        NavigationStack {
            ScrollView {
                let tasks = board.tasks(in: .closed).sorted { $0.done > $1.done }
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        Eyebrow(text: "Closed")
                        Spacer()
                        Text("\(tasks.count)").font(Theme.mono(12)).foregroundStyle(Theme.muted)
                    }
                    if tasks.isEmpty {
                        EmptyLine(text: "Nothing closed yet.")
                    } else {
                        Card(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(tasks.enumerated()), id: \.element.id) { i, task in
                                    Button {
                                        dismiss()
                                        path.append(Route.task(task.id))
                                    } label: { TaskRow(task: task, index: i + 1) }
                                    .buttonStyle(.pressable)
                                    .accessibilityIdentifier("row.\(task.id)")
                                    if i < tasks.count - 1 { Hairline().padding(.leading, Theme.cardPadding) }
                                }
                            }
                        }
                    }
                }
                .padding(Theme.gutter)
            }
            .scrollIndicators(.hidden)
            .background(Theme.canvas.ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
