import SwiftUI

// A task: text, context (editable), tags, note, lineage, events, and the buttons for its stage.
struct TaskDetailView: View {
    @Environment(Board.self) private var board
    var taskID: String
    @Binding var path: NavigationPath

    @State private var editing = false
    @State private var draftText = ""
    @State private var draftContext = ""
    @State private var draftTags = ""
    @State private var showStage = false
    @State private var showRetransform = false
    @State private var confirmClose = false
    @State private var busy = false
    @State private var notice: String?

    private var task: BoardTask? { board.task(taskID) }

    var body: some View {
        ScrollView {
            if let task {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Eyebrow(text: task.stage.title)
                            if !task.priorityLabel.isEmpty { Chip(text: task.priorityLabel, mono: true) }
                            if !task.due.isEmpty { Chip(text: "due " + Dates.short(task.due), tone: overdue(task) ? .warn : .neutral, mono: true) }
                        }
                        if editing {
                            TextField("What has to happen", text: $draftText, axis: .vertical)
                                .font(Theme.display(26)).foregroundStyle(Theme.inkDeep)
                                .accessibilityIdentifier("task.text.field")
                        } else {
                            Text(task.text).font(Theme.display(26)).foregroundStyle(Theme.inkDeep)
                                .accessibilityIdentifier("task.text")
                        }
                    }

                    if let notice {
                        ErrorBanner(message: notice) { self.notice = nil }
                    }

                    contextCard(task)
                    if task.stage == .committed { runCard(task) }
                    if !task.note.isEmpty { noteCard(task) }
                    lineageCard(task)
                    actions(task)
                    eventsCard(task)
                    Color.clear.frame(height: 20)
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 8)
            } else {
                VStack(spacing: 12) {
                    Text("This task isn't on the board.").font(Theme.body(15)).foregroundStyle(Theme.muted)
                    Button("Back to the board") { path = NavigationPath() }.buttonStyle(.pill(.secondary, expand: false))
                }
                .padding(40)
            }
        }
        .scrollIndicators(.hidden)
        .background(Theme.canvas.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.canvas, for: .navigationBar)
        .toolbar {
            if let task, task.stage != .closed, task.stage != .committed {
                ToolbarItem(placement: .topBarTrailing) {
                    if editing {
                        Button("Save") { Task { await save() } }.disabled(busy)
                            .font(Theme.bodyMedium(15)).accessibilityIdentifier("task.save")
                    } else {
                        Button("Edit") { startEditing(task) }.font(Theme.body(15)).accessibilityIdentifier("task.edit")
                    }
                }
            }
        }
        .sheet(isPresented: $showStage) {
            if let task { StageSheet(task: task) }
        }
        .sheet(isPresented: $showRetransform) {
            if let task { RetransformView(task: task) }
        }
        .confirmationDialog("Close this task?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Close it", role: .destructive) { Task { await close() } }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Closed is closed. There is no erase.")
        }
        .refreshable { await board.refresh() }
    }

    // MARK: Cards

    private func contextCard(_ task: BoardTask) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("CONTEXT").font(Theme.mono(10)).tracking(1).foregroundStyle(Theme.muted)
                if editing {
                    TextField("Add context: what, where, by when, what matters", text: $draftContext, axis: .vertical)
                        .font(Theme.body(15)).foregroundStyle(Theme.ink).lineLimit(3...10)
                        .accessibilityIdentifier("task.context.field")
                    Text("TAGS").font(Theme.mono(10)).tracking(1).foregroundStyle(Theme.muted).padding(.top, 4)
                    TextField("space separated", text: $draftTags)
                        .font(Theme.body(15)).foregroundStyle(Theme.ink).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .accessibilityIdentifier("task.tags.field")
                } else if task.context.isEmpty {
                    Text(task.stage == .unstaged ? "Nothing decided yet. Stage it to add context." : "No context.")
                        .font(Theme.body(15)).foregroundStyle(Theme.muted)
                } else {
                    Text(task.context).font(Theme.body(15)).foregroundStyle(Theme.ink)
                        .accessibilityIdentifier("task.context")
                }
                if !editing { TagRow(tags: task.tags) }
                HStack(spacing: 16) {
                    LabeledValue(label: "written", value: Dates.short(task.entry))
                    if !task.done.isEmpty { LabeledValue(label: "closed", value: Dates.short(task.done)) }
                    LabeledValue(label: "by", value: task.createdBy)
                    LabeledValue(label: "id", value: task.id)
                }
                .padding(.top, 4)
            }
        }
    }

    private func runCard(_ task: BoardTask) -> some View {
        let run = board.run(for: task.id)
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("RUN").font(Theme.mono(10)).tracking(1).foregroundStyle(Theme.muted)
                    Spacer()
                    if let run {
                        Chip(text: run.statusLabel, tone: run.status == .needsYou ? .warn : .neutral, mono: true)
                            .accessibilityIdentifier("task.run.status")
                    }
                }
                if let run {
                    if run.status == .needsYou, !run.question.isEmpty {
                        Text(run.question).font(Theme.body(15)).foregroundStyle(Theme.ink)
                            .accessibilityIdentifier("task.run.question")
                    }
                    Button("Open the run") { path.append(Route.run(run.id)) }
                        .buttonStyle(.pill(.secondary)).accessibilityIdentifier("task.run.open")
                } else {
                    Text(board.runsAvailable ? "The agent has it. No run recorded yet." : "The backend hasn't built runs yet; this task is committed.")
                        .font(Theme.body(15)).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private func noteCard(_ task: BoardTask) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("NOTE").font(Theme.mono(10)).tracking(1).foregroundStyle(Theme.muted)
                Text(task.note).font(Theme.body(15)).foregroundStyle(Theme.ink)
            }
        }
    }

    @ViewBuilder private func lineageCard(_ task: BoardTask) -> some View {
        let parent = task.parentID.isEmpty ? nil : board.task(task.parentID)
        let children = board.children(of: task.id)
        if parent != nil || !children.isEmpty || !task.parentID.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("LINEAGE").font(Theme.mono(10)).tracking(1).foregroundStyle(Theme.muted)
                    if let parent {
                        lineageRow(label: "from", task: parent)
                    } else if !task.parentID.isEmpty {
                        Text("from \(task.parentID) (not on the board)").font(Theme.small(13)).foregroundStyle(Theme.muted)
                    }
                    ForEach(children) { child in lineageRow(label: "yielded", task: child) }
                }
            }
        }
    }

    private func lineageRow(label: String, task: BoardTask) -> some View {
        Button { path.append(Route.task(task.id)) } label: {
            HStack(spacing: 10) {
                Text(label.uppercased()).font(Theme.mono(9)).tracking(1).foregroundStyle(Theme.muted).frame(width: 52, alignment: .leading)
                Text(task.text).font(Theme.body(15)).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer()
                Chip(text: task.stage.title, mono: true)
            }
        }
        .buttonStyle(.pressable)
    }

    @ViewBuilder private func actions(_ task: BoardTask) -> some View {
        VStack(spacing: 10) {
            switch task.stage {
            case .unstaged:
                Button { Haptics.tap(); showStage = true } label: { Text("Stage") }
                    .buttonStyle(.pill).accessibilityIdentifier("task.stage")
                Button { confirmClose = true } label: { Text("Close") }
                    .buttonStyle(.pill(.quiet)).accessibilityIdentifier("task.close")
            case .staged:
                Button { Task { await commit() } } label: { Text(busy ? "Committing…" : "Commit to agent") }
                    .buttonStyle(.pill).disabled(busy).accessibilityIdentifier("task.commit")
                HStack(spacing: 10) {
                    Button { showRetransform = true } label: { Text("Retransform") }
                        .buttonStyle(.pill(.secondary)).accessibilityIdentifier("task.retransform")
                    Button { confirmClose = true } label: { Text("Close") }
                        .buttonStyle(.pill(.quiet)).accessibilityIdentifier("task.close")
                }
                Button { showStage = true } label: { Text("Restage with new context") }
                    .buttonStyle(.pill(.quiet)).accessibilityIdentifier("task.restage")
            case .committed:
                Text("The agent has this one. Closing waits for the run.").font(Theme.small(13)).foregroundStyle(Theme.muted)
            case .closed:
                Text("Closed \(Dates.short(task.done)). Closed is closed.").font(Theme.small(13)).foregroundStyle(Theme.muted)
            }
        }
    }

    @ViewBuilder private func eventsCard(_ task: BoardTask) -> some View {
        let events = board.events(for: task.id)
        if !events.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("WHO DID WHAT").font(Theme.mono(10)).tracking(1).foregroundStyle(Theme.muted)
                    ForEach(Array(events.enumerated()), id: \.element.id) { i, e in
                        NumberedRow(index: i + 1) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(e.actorKind) · \(e.action)").font(Theme.body(15)).foregroundStyle(Theme.ink)
                                Text(Self.when(e.at)).font(Theme.mono(10)).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
            }
        }
    }

    static func when(_ ts: String) -> String {
        guard let d = Dates.timestamp(ts) else { return ts }
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        return f.string(from: d)
    }

    private func overdue(_ task: BoardTask) -> Bool {
        guard task.isOpen, let d = task.dueDate else { return false }
        return Calendar.current.startOfDay(for: d) < Calendar.current.startOfDay(for: .now)
    }

    // MARK: Actions

    private func startEditing(_ task: BoardTask) {
        draftText = task.text
        draftContext = task.context
        draftTags = task.tags.joined(separator: " ")
        editing = true
    }

    private func save() async {
        guard let task else { return }
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { notice = "A task needs text."; return }
        busy = true; defer { busy = false }
        do {
            let tags = draftTags.split(separator: " ").map(String.init)
            try await board.edit(task.id, text: text == task.text ? nil : text,
                                 context: draftContext == task.context ? nil : draftContext,
                                 tags: tags == task.tags ? nil : tags)
            editing = false
            notice = nil
            Haptics.tap()
        } catch {
            notice = error.localizedDescription
            Haptics.error()
        }
    }

    private func commit() async {
        guard let task else { return }
        busy = true; defer { busy = false }
        do {
            try await board.commit(task.id)
            Haptics.success()
        } catch {
            notice = error.localizedDescription
            Haptics.error()
        }
    }

    private func close() async {
        guard let task else { return }
        busy = true; defer { busy = false }
        do {
            try await board.close(task.id)
            Haptics.success()
        } catch {
            notice = error.localizedDescription
            Haptics.error()
        }
    }
}

// Stage: ask for context, confirm. Staging again replaces the context.
struct StageSheet: View {
    @Environment(Board.self) private var board
    @Environment(\.dismiss) private var dismiss
    var task: BoardTask
    @State private var context = ""
    @State private var busy = false
    @State private var notice: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Eyebrow(text: task.stage == .staged ? "Restage" : "Stage")
                Text(task.text).font(Theme.display(24)).foregroundStyle(Theme.inkDeep)
                Text("What does doing this actually mean? Where, by when, who, what matters.")
                    .font(Theme.small(14)).foregroundStyle(Theme.muted)
                TextField("Context", text: $context, axis: .vertical)
                    .font(Theme.body(16)).foregroundStyle(Theme.ink)
                    .lineLimit(4...12)
                    .padding(14)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusInset, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusInset, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
                    .focused($focused)
                    .accessibilityIdentifier("stage.context")
                if let notice { ErrorBanner(message: notice) { self.notice = nil } }
                Spacer()
                Button { Task { await stage() } } label: { Text(busy ? "Staging…" : "Stage it") }
                    .buttonStyle(.pill)
                    .disabled(busy || context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("stage.confirm")
            }
            .padding(Theme.gutter)
            .background(Theme.canvas.ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { context = task.context; focused = true }
        }
        .presentationDetents([.large])
    }

    private func stage() async {
        busy = true; defer { busy = false }
        do {
            try await board.stage(task.id, context: context.trimmingCharacters(in: .whitespacesAndNewlines))
            Haptics.success()
            dismiss()
        } catch {
            notice = error.localizedDescription
            Haptics.error()
        }
    }
}
