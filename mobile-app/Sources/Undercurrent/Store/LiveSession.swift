import Foundation
import Observation
import ElevenLabs

// The live agent's session: the ElevenLabs conversation (WebRTC, through their Swift SDK) behind
// the Call screen's states. The backend hands out the conversation token, so the app holds no key.
// The read-back rule is the backend's; the app shows the agent's question and offers Yes / No.
@Observable @MainActor
final class LiveSession {
    enum Status: String { case idle, connecting, listening, thinking, speaking, ended, unavailable }
    struct Line: Identifiable, Equatable { var id: String; var who: String; var text: String }

    private(set) var status: Status = .idle
    private(set) var transcript: [Line] = []
    private(set) var readBack: String?
    private(set) var reason: String?
    private(set) var muted = false

    @ObservationIgnored private var conversation: Conversation?
    @ObservationIgnored private var watchers: [Task<Void, Never>] = []

    func connect(using backend: Backend) async {
        status = .connecting
        reason = nil
        do {
            let creds = try await backend.live()
            guard let token = creds.token, !token.isEmpty else {
                throw BackendError.http(503, "The backend sent no conversation token.")
            }
            let conv = try await ElevenLabs.startConversation(conversationToken: token)
            conversation = conv
            watch(conv)
            if case .active = conv.state { status = .listening }
        } catch let e as BackendError where e.isNotBuilt {
            status = .unavailable
            reason = "The backend hasn't built the live agent yet (GET /live/signed-url is 501)."
        } catch let e as BackendError {
            status = .unavailable
            reason = e.errorDescription
        } catch {
            status = .unavailable
            reason = "Couldn't start the call: \(error.localizedDescription)"
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
        ]
    }

    private func apply(_ state: ConversationState) {
        switch state {
        case .idle: break
        case .connecting: status = .connecting
        case .active: if status == .connecting || status == .idle { status = .listening }
        case .ended: status = .ended; readBack = nil
        case .error(let e):
            status = .unavailable
            reason = "The call dropped: \(e)"
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
        transcript = messages.map { Line(id: $0.id, who: $0.role == .agent ? "agent" : "you", text: Self.spoken($0.content)) }
        // A read-back is the agent's last line when it asks about a key action; it clears when anyone speaks again.
        if let last = messages.last, last.role == .agent, Self.isReadBack(Self.spoken(last.content)) {
            readBack = Self.spoken(last.content)
        } else {
            readBack = nil
        }
    }

    // The voice model's delivery tags ("[sad]", "[slow]") are for the ear, not the eye.
    static func spoken(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[[A-Za-z ,-]{1,24}\]\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // The backend's read-backs: "Commit …?", "Close …?", "Change …?", "Retransform …?". The agent
    // says them in its own words, so this looks for the action and the question mark.
    static func isReadBack(_ text: String) -> Bool {
        let t = text.lowercased()
        guard t.hasSuffix("?") else { return false }
        return ["commit", "close", "change", "retransform", "rewrite", "split", "edit", "mark"].contains { t.contains($0) }
    }

    func answerReadBack(_ yes: Bool) async {
        readBack = nil
        try? await conversation?.sendMessage(yes ? "Yes" : "No")
    }

    func toggleMute() async {
        try? await conversation?.toggleMute()
    }

    func hangUp() async {
        watchers.forEach { $0.cancel() }
        watchers = []
        if let conv = conversation, conv.state.isActive { await conv.endConversation() }
        conversation = nil
        if status != .unavailable { status = .ended }
        readBack = nil
    }

    func reset() {
        status = .idle
        transcript = []
        readBack = nil
        reason = nil
    }
}
