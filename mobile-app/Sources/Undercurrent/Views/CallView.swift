import SwiftUI

// The call screen: status, the last lines of the transcript, the agent's read-back with Yes / No,
// mute, hang up. The session itself lives in Store/LiveSession.swift.
struct CallView: View {
    @Environment(Board.self) private var board
    @Environment(LiveSession.self) private var live
    @Environment(\.dismiss) private var dismiss
    // -say "<text>" types that line to the agent once it has greeted (for driving a real call from
    // the command line, where the Mac's microphone is not the person's).
    @State private var lineToSay: String? = {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-say"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }()

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Eyebrow(text: "Live")
                Spacer()
                Chip(text: live.status.rawValue, tone: tone, mono: true).accessibilityIdentifier("call.status")
            }
            Spacer()
            ZStack {
                Circle().stroke(Theme.slateLight, lineWidth: 2).frame(width: 160, height: 160)
                Circle().fill(Theme.surface).frame(width: 140, height: 140)
                    .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
                Image(systemName: icon).font(.system(size: 36, weight: .light)).foregroundStyle(Theme.inkDeep)
            }
            Text(headline).font(Theme.display(24)).foregroundStyle(Theme.inkDeep).multilineTextAlignment(.center)
            if let reason = live.reason {
                Text(reason).font(Theme.small(14)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    .accessibilityIdentifier("call.reason")
            }
            if let tool = live.lastTool {
                Text(tool).font(Theme.mono(11)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).lineLimit(2)
                    .accessibilityIdentifier("call.tool")
            }
            Spacer()
            if !live.transcript.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(live.transcript.suffix(4)) { line in
                        HStack(alignment: .top, spacing: 10) {
                            Text(line.who.uppercased()).font(Theme.mono(9)).tracking(1).foregroundStyle(Theme.muted).frame(width: 44, alignment: .leading)
                            Text(line.text).font(Theme.small(14)).foregroundStyle(Theme.ink)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let readBack = live.readBack {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("READ-BACK").font(Theme.mono(10)).tracking(1).foregroundStyle(Theme.muted)
                        Text(readBack).font(Theme.body(16)).foregroundStyle(Theme.ink)
                        HStack(spacing: 10) {
                            Button("Yes") { Task { await live.answerReadBack(true) } }.buttonStyle(.pill).accessibilityIdentifier("call.yes")
                            Button("No") { Task { await live.answerReadBack(false) } }.buttonStyle(.pill(.secondary)).accessibilityIdentifier("call.no")
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                if live.status == .listening || live.status == .speaking || live.status == .thinking {
                    Button { Task { await live.toggleMute() } } label: {
                        HStack(spacing: 8) { Image(systemName: live.muted ? "mic.slash" : "mic"); Text(live.muted ? "Unmute" : "Mute") }
                    }
                    .buttonStyle(.pill(.secondary))
                    .accessibilityIdentifier("call.mute")
                }
                Button {
                    Task { await live.hangUp() }
                    dismiss()
                } label: {
                    HStack(spacing: 8) { Image(systemName: "phone.down"); Text("Hang up") }
                }
                .buttonStyle(.pill(.destructive))
                .accessibilityIdentifier("call.hangup")
            }
        }
        .padding(Theme.gutter)
        .padding(.top, 8)
        .background(Theme.canvas.ignoresSafeArea())
        .task {
            live.reset()
            live.onToolCall = { Task { await board.refresh() } }
            await live.connect(using: board.backend)
        }
        .onDisappear {
            Task {
                await live.hangUp()
                await board.refresh()
            }
        }
        .onChange(of: live.status) { _, status in
            // The agent has greeted and gone quiet: say the command-line line, once.
            guard status == .listening, let line = lineToSay, live.transcript.contains(where: { $0.who == "agent" }) else { return }
            lineToSay = nil
            Task { await live.say(line) }
        }
    }

    private var tone: Chip.Tone {
        switch live.status {
        case .listening, .speaking, .thinking: .good
        case .unavailable: .warn
        default: .neutral
        }
    }

    private var icon: String {
        switch live.status {
        case .connecting: "ellipsis"
        case .listening: live.muted ? "mic.slash" : "waveform"
        case .thinking: "ellipsis.circle"
        case .speaking: "speaker.wave.2"
        case .unavailable: "phone.badge.waveform"
        case .ended: "phone.down"
        case .idle: "phone"
        }
    }

    private var headline: String {
        switch live.status {
        case .idle, .connecting: "Connecting…"
        case .listening: live.muted ? "Muted" : "Listening"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        case .unavailable: "No live agent yet"
        case .ended: "Call ended"
        }
    }
}
