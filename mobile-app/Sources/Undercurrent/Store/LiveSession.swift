import Foundation
import Observation
import ElevenLabs

// The live agent's session: the ElevenLabs conversation (WebRTC, through their Swift SDK) behind
// the Call screen's states. The backend hands out the conversation token, so the app holds no key.
// The agent's tools are client tools: ElevenLabs hands each call to this object, which forwards it
// to the backend (POST /live/tools/<name>) and returns the string the agent speaks. The read-back
// rule is the backend's; the app shows the read-back and offers Yes / No. The flow is
// MOBILE_APP.md "The live conversation, end to end".
@Observable @MainActor
final class LiveSession {
    enum Status: String { case idle, connecting, listening, thinking, speaking, ended, unavailable }
    struct Line: Identifiable, Equatable { var id: String; var who: String; var text: String }

    private(set) var status: Status = .idle
    private(set) var transcript: [Line] = []
    private(set) var readBack: String?
    private(set) var reason: String?
    private(set) var muted = false
    private(set) var conversationID: String?
    // The last tool the agent called and what the backend answered, for the screen.
    private(set) var lastTool: String?

    // Called after every tool call has landed at the backend; the Call screen refreshes the board.
    @ObservationIgnored var onToolCall: (() -> Void)?

    @ObservationIgnored private var conversation: Conversation?
    @ObservationIgnored private var watchers: [Task<Void, Never>] = []
    @ObservationIgnored private var backend: Backend?
    @ObservationIgnored private var config: LiveConfig?
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var userLinesAtReadBack = 0
    @ObservationIgnored private var posted = false

    // MARK: Identity

    static let userIDKey = "liveUserID"

    // A stable per-install id, created once; the agent sees it as the user_id dynamic variable.
    static func userID(defaults: UserDefaults = .standard) -> String {
        if let s = defaults.string(forKey: userIDKey), !s.isEmpty { return s }
        let s = "ios-" + UUID().uuidString.lowercased()
        defaults.set(s, forKey: userIDKey)
        return s
    }

    // MARK: Connect

    func connect(using backend: Backend) async {
        status = .connecting
        reason = nil
        posted = false
        conversationID = nil
        lastTool = nil
        self.backend = backend
        do {
            let config = try await backend.liveConfig()
            guard config.configured else {
                status = .unavailable
                reason = "This backend has no live agent: it is missing ELEVENLABS_API_KEY, ELEVENLABS_AGENT_ID or LIVE_TOOL_SECRET. The board still works."
                return
            }
            self.config = config
            let creds = try await backend.live()
            guard let token = creds.token, !token.isEmpty else {
                throw BackendError.http(503, "The backend sent no conversation token.")
            }
            let conv = try await ElevenLabs.startConversation(
                conversationToken: token,
                config: ConversationConfig(dynamicVariables: ["user_id": Self.userID(), "board": config.board]),
                onDisconnect: { [weak self] _ in Task { @MainActor in await self?.postTranscript() } }
            )
            conversation = conv
            conversationID = conv.conversationMetadata?.conversationId
            watch(conv)
            if case .active = conv.state { status = .listening }
        } catch let e as BackendError where e.isNotBuilt {
            status = .unavailable
            reason = "The backend hasn't built the live agent yet. The board still works."
        } catch let e as BackendError {
            status = .unavailable
            reason = (e.errorDescription ?? "The backend refused the call.") + " Nothing on the board changed."
        } catch {
            status = .unavailable
            reason = "Couldn't start the call: \(error.localizedDescription). Nothing on the board changed."
        }
    }

    private func watch(_ conv: Conversation) {
        watchers.forEach { $0.cancel() }
        watchers = [
            Task { [weak self] in
                for await state in conv.$state.values { self?.apply(state) }
            },
            Task { [weak self] in
                for await agent in conv.$agentState.values { self?.apply(agent) }
            },
            Task { [weak self] in
                for await messages in conv.$messages.values { self?.apply(messages) }
            },
            Task { [weak self] in
                for await muted in conv.$isMuted.values { self?.muted = muted }
            },
            Task { [weak self] in
                for await meta in conv.$conversationMetadata.values {
                    if let id = meta?.conversationId { self?.conversationID = id }
                }
            },
            Task { [weak self] in
                for await calls in conv.$pendingToolCalls.values {
                    for call in calls { self?.handle(call, in: conv) }
                }
            },
        ]
    }

    // MARK: State

    private func apply(_ state: ConversationState) {
        switch state {
        case .idle: break
        case .connecting: status = .connecting
        case .active: if status == .connecting || status == .idle { status = .listening }
        case .ended:
            status = .ended
            readBack = nil
            Task { await postTranscript() }
        case .error(let e):
            status = .unavailable
            reason = "The call dropped: \(e). What the agent already did is on the board."
            Task { await postTranscript() }
        }
    }

    private func apply(_ agent: ElevenLabs.AgentState) {
        guard status == .listening || status == .speaking || status == .thinking else { return }
        switch agent {
        case .listening: status = .listening
        case .speaking: status = .speaking
        case .thinking: status = .thinking
        }
    }

    private func apply(_ messages: [Message]) {
        transcript = messages.map { Line(id: $0.id, who: $0.role == .agent ? "agent" : "you", text: Self.stripTags($0.content)) }
        // The read-back stays until the person answers (a new user line) or the agent's next tool call.
        if readBack != nil, Self.userLines(transcript) > userLinesAtReadBack { readBack = nil }
    }

    // MARK: Tools

    // Each pending call once: the SDK republishes the whole array as calls come and go.
    private func handle(_ call: ClientToolCallEvent, in conv: Conversation) {
        guard !inFlight.contains(call.toolCallId) else { return }
        inFlight.insert(call.toolCallId)
        Task { [weak self] in
            await self?.run(call, in: conv)
            self?.inFlight.remove(call.toolCallId)
        }
    }

    // One client tool call: its parameters plus conversation_id go to POST /live/tools/<name> with
    // the secret; the reply's spoken string goes back to the agent. isError is for transport only:
    // a backend "error" reply is still a result the agent should hear.
    private func run(_ call: ClientToolCallEvent, in conv: Conversation) async {
        lastTool = call.toolName
        var spoken: String
        var transportFailed = false
        if let backend, let config, config.tools.contains(call.toolName) {
            var args = (try? call.getParameters()) ?? [:]
            if let id = conversationID ?? conv.conversationMetadata?.conversationId { args["conversation_id"] = id }
            do {
                let reply = try await backend.liveTool(call.toolName, args: args, secret: config.secret)
                spoken = reply.spoken
                show(readBack: reply.needsConfirmation ? reply.readBack : nil)
            } catch {
                let what = (error as? BackendError)?.errorDescription ?? error.localizedDescription
                spoken = "ERROR: the app couldn't reach the backend (\(what)); nothing changed"
                transportFailed = true
                show(readBack: nil)
            }
        } else {
            spoken = "ERROR: the app doesn't know the tool \(call.toolName); nothing changed"
            transportFailed = true
        }
        lastTool = call.toolName + " → " + Self.short(spoken)
        if call.expectsResponse {
            try? await conv.sendToolResult(for: call.toolCallId, result: spoken, isError: transportFailed)
        } else {
            conv.markToolCallCompleted(call.toolCallId)
        }
        onToolCall?()
    }

    private func show(readBack text: String?) {
        readBack = text
        userLinesAtReadBack = Self.userLines(transcript)
    }

    // MARK: Pure

    // The voice model's delivery tags ("[sad]", "[slow]") are for the ear, not the eye.
    static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[[A-Za-z ,-]{1,24}\]\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // The transcript in the post-call webhook's shape: [{role: user|agent, message}], empty lines dropped.
    static func turns(_ transcript: [Line]) -> [[String: String]] {
        transcript.compactMap { line in
            line.text.isEmpty ? nil : ["role": line.who == "agent" ? "agent" : "user", "message": line.text]
        }
    }

    static func userLines(_ transcript: [Line]) -> Int { transcript.filter { $0.who != "agent" }.count }

    static func short(_ s: String, _ n: Int = 80) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "…"
    }

    // MARK: Actions

    func answerReadBack(_ yes: Bool) async {
        readBack = nil
        try? await conversation?.sendMessage(yes ? "Yes" : "No")
    }

    // A typed line to the agent, the same as saying it.
    func say(_ text: String) async {
        try? await conversation?.sendMessage(text)
    }

    func toggleMute() async {
        try? await conversation?.toggleMute()
    }

    func hangUp() async {
        if let conv = conversation, conv.state.isActive { await conv.endConversation() }
        await postTranscript()
        watchers.forEach { $0.cancel() }
        watchers = []
        conversation = nil
        if status != .unavailable { status = .ended }
        readBack = nil
    }

    // Once per call: the transcript becomes a live session and a `call` event on the backend.
    // A failure here changes nothing the person can see, so it is not reported.
    private func postTranscript() async {
        guard !posted, let backend, let id = conversationID else { return }
        let turns = Self.turns(transcript)
        guard !turns.isEmpty else { return }
        posted = true
        _ = try? await backend.postCall(conversationID: id, transcript: turns.map { $0 as [String: Any] })
    }

    func reset() {
        status = .idle
        transcript = []
        readBack = nil
        reason = nil
        conversationID = nil
        lastTool = nil
        posted = false
        inFlight = []
    }
}
