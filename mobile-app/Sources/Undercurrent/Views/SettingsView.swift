import SwiftUI

// Settings: where the backend is and the key it was started with. Checked live; the board
// refetches when it changes.
struct SettingsView: View {
    @Environment(Board.self) private var board
    @AppStorage(Backend.storageKey) private var backendURL = ""
    @AppStorage(Backend.keyStorageKey) private var backendKey = ""
    @State private var draft = ""
    @State private var keyDraft = ""
    @State private var checking = false
    @State private var result: String?
    @State private var resultOK = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Eyebrow(text: "Settings")
                TwoToneTitle(first: "Backend", second: "where the board lives", size: 26)
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("URL").font(Theme.mono(10)).tracking(1).foregroundStyle(Theme.muted)
                        TextField(Backend.defaultURL.absoluteString, text: $draft)
                            .font(Theme.mono(14)).foregroundStyle(Theme.ink)
                            .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                            .accessibilityIdentifier("settings.url")
                        Text("The Go backend on your Mac, or a tunnel to it. Leave empty for the build default.")
                            .font(Theme.small(13)).foregroundStyle(Theme.muted)
                        Text("KEY").font(Theme.mono(10)).tracking(1).foregroundStyle(Theme.muted).padding(.top, 4)
                        SecureField(Backend.defaultKey.isEmpty ? "none" : "the build default", text: $keyDraft)
                            .font(Theme.mono(14)).foregroundStyle(Theme.ink)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .accessibilityIdentifier("settings.key")
                        Text("The UNDERCURRENT_API_KEY that backend was started with. Leave empty for an open local backend or the build default.")
                            .font(Theme.small(13)).foregroundStyle(Theme.muted)
                        HStack(spacing: 10) {
                            Button { Task { await check() } } label: { Text(checking ? "Checking…" : "Check") }
                                .buttonStyle(.pill(.secondary)).disabled(checking)
                                .accessibilityIdentifier("settings.check")
                            Button { save() } label: { Text("Use this") }
                                .buttonStyle(.pill).accessibilityIdentifier("settings.save")
                        }
                        if let result {
                            HStack(spacing: 8) {
                                Circle().fill(resultOK ? Theme.good : Theme.bad).frame(width: 6, height: 6)
                                Text(result).font(Theme.small(13)).foregroundStyle(Theme.ink)
                            }
                            .accessibilityIdentifier("settings.result")
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("THIS INSTALL").font(Theme.mono(10)).tracking(1).foregroundStyle(Theme.muted)
                        row("Actor", board.backend.actor)
                        row("Using", board.backend.baseURL.absoluteString)
                        row("Key", board.backend.apiKey.isEmpty ? "none" : "set")
                        row("Last sync", board.lastSync.map { Self.time($0) } ?? "never")
                        row("Version", Self.version)
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("HOW IT WORKS").font(Theme.mono(10)).tracking(1).foregroundStyle(Theme.muted)
                        NumberedRow(index: 1) { Text("Write a task down. It lands unstaged.").font(Theme.body(15)).foregroundStyle(Theme.ink) }
                        NumberedRow(index: 2) { Text("Stage the ones you mean by adding context.").font(Theme.body(15)).foregroundStyle(Theme.ink) }
                        NumberedRow(index: 3) { Text("Commit a staged task to an agent, retransform it, or close it yourself.").font(Theme.body(15)).foregroundStyle(Theme.ink) }
                        NumberedRow(index: 4) { Text("Every move is an event. The board can be read as who did what.").font(Theme.body(15)).foregroundStyle(Theme.ink) }
                    }
                }
            }
            .padding(Theme.gutter)
        }
        .scrollIndicators(.hidden)
        .background(Theme.canvas.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.canvas, for: .navigationBar)
        .onAppear { draft = backendURL; keyDraft = backendKey }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(Theme.small(13)).foregroundStyle(Theme.muted).frame(width: 80, alignment: .leading)
            Text(value).font(Theme.mono(12)).foregroundStyle(Theme.ink).lineLimit(2)
        }
    }

    private var candidate: URL? {
        let s = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return Backend.defaultURL }
        guard let u = URL(string: s), u.scheme != nil, u.host != nil else { return nil }
        return u
    }

    private var candidateKey: String {
        let k = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return k.isEmpty ? Backend.defaultKey : k
    }

    // /health is open; /tasks proves the key.
    private func check() async {
        guard let url = candidate else { result = "That isn't a URL."; resultOK = false; return }
        checking = true; defer { checking = false }
        let b = Backend(baseURL: url, session: board.backend.session, apiKey: candidateKey)
        do {
            let h = try await b.health()
            _ = try await b.tasks()
            result = h.ok ? "Reachable. \(h.tasks) tasks on the board." : "Replied, but not ok."
            resultOK = h.ok
        } catch BackendError.unauthorized(let m) {
            result = "Key refused (401): " + (m.isEmpty ? "this backend needs its key." : m)
            resultOK = false
        } catch {
            result = error.localizedDescription
            resultOK = false
        }
    }

    private func save() {
        guard let url = candidate else { result = "That isn't a URL."; resultOK = false; return }
        backendURL = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        backendKey = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !MockBackend.isEnabled { board.use(url: url, key: candidateKey) }
        Task { await board.refresh() }
        Haptics.tap()
        result = "Using \(url.absoluteString)" + (candidateKey.isEmpty ? "" : " with a key")
        resultOK = true
    }

    static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}
