import SwiftUI

// The reusable pieces of the qoves-style language. Views compose these; they never restyle them.

// "THE BOARD" — a mono uppercase label in a hairline pill.
struct Eyebrow: View {
    var text: String
    var body: some View {
        Text(text.uppercased())
            .font(Theme.mono(11))
            .tracking(1.2)
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
            .accessibilityAddTraits(.isHeader)
    }
}

// Two-tone heading: the first line in ink, the second in slate.
struct TwoToneTitle: View {
    var first: String
    var second: String
    var size: CGFloat = 32
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(first).foregroundStyle(Theme.inkDeep)
            Text(second).foregroundStyle(Theme.slate)
        }
        .font(Theme.display(size))
        .lineSpacing(-2)
        .accessibilityElement(children: .combine)
    }
}

// A white card with a hairline border and a soft shadow.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.cardPadding
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.04), radius: 12, y: 4)
    }
}

// A small rounded label: a tag, a count, a status.
struct Chip: View {
    enum Tone { case neutral, good, warn, bad, accent }
    var text: String
    var tone: Tone = .neutral
    var mono = false

    var color: Color {
        switch tone {
        case .neutral: Theme.muted
        case .good: Theme.good
        case .warn: Theme.warn
        case .bad: Theme.bad
        case .accent: Theme.ink
        }
    }
    var body: some View {
        Text(mono ? text.uppercased() : text)
            .font(mono ? Theme.mono(10) : Theme.small(12))
            .tracking(mono ? 0.8 : 0)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tone == .accent ? Theme.accent : Theme.canvasDeep)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusChip, style: .continuous))
    }
}

// The pill button. Dark on light surfaces; light on dark ones.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet, destructive }
    var kind: Kind = .primary
    var expand = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.bodyMedium(15))
            .foregroundStyle(foreground)
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .frame(maxWidth: expand ? .infinity : nil)
            .background(background)
            .overlay(Capsule().stroke(kind == .secondary ? Theme.hairline : .clear, lineWidth: 1))
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: Theme.canvas
        case .secondary, .quiet: Theme.ink
        case .destructive: Theme.bad
        }
    }
    private var background: Color {
        switch kind {
        case .primary: Theme.inkDeep
        case .secondary: Theme.surface
        case .quiet: Theme.canvasDeep
        case .destructive: Theme.canvasDeep
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static func pill(_ kind: PillButtonStyle.Kind, expand: Bool = true) -> PillButtonStyle { PillButtonStyle(kind: kind, expand: expand) }
}

// [1]  Get more career opportunities — a numbered row in mono.
struct NumberedRow<Content: View>: View {
    var index: Int
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("[\(index)]")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.muted)
                .frame(width: 28, alignment: .leading)
            content
        }
    }
}

// The track with a YOU marker and an IDEAL band, under a stat.
struct TrackBar: View {
    var fraction: Double          // where the marker sits, 0…1
    var idealFraction: Double     // where the ideal band starts, 0…1
    var higherIsBetter: Bool
    var minLabel = "0"
    var maxLabel: String
    var idealLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.slateLight).frame(height: 4)
                    Capsule().fill(Theme.slateFill)
                        .frame(width: higherIsBetter ? max(0, w * (1 - idealFraction)) : max(0, w * idealFraction), height: 4)
                        .offset(x: higherIsBetter ? w * idealFraction : 0)
                    VStack(spacing: 2) {
                        Text("YOU").font(Theme.mono(8)).foregroundStyle(Theme.ink)
                        Rectangle().fill(Theme.inkDeep).frame(width: 2, height: 10)
                    }
                    .offset(x: max(0, min(w - 2, w * fraction)) - 10, y: -12)
                }
            }
            .frame(height: 18)
            HStack {
                Text(minLabel)
                Spacer()
                Text(higherIsBetter ? idealLabel : maxLabel)
            }
            .font(Theme.mono(9))
            .foregroundStyle(Theme.muted)
        }
        .accessibilityHidden(true)
    }
}

// The qoves stat tile: title, verdict chip, a big thin number, the YOU track.
struct StatTile: View {
    var measure: Insights.Measure

    var tone: Chip.Tone {
        switch measure.verdict {
        case .ideal: .good
        case .improving: .neutral
        case .attention: .warn
        case .empty: .neutral
        }
    }

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Text(measure.title).font(Theme.small(13)).foregroundStyle(Theme.ink)
                    Spacer(minLength: 6)
                    Chip(text: measure.verdict.rawValue, tone: tone)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(measure.display).font(Theme.numeral(40)).foregroundStyle(Theme.inkDeep)
                    Text(measure.unit.uppercased()).font(Theme.mono(9)).foregroundStyle(Theme.muted).baselineOffset(14)
                }
                TrackBar(fraction: measure.fraction, idealFraction: measure.idealFraction, higherIsBetter: measure.higherIsBetter,
                         maxLabel: measure.idealLabel, idealLabel: measure.idealLabel)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(measure.title): \(measure.display) \(measure.unit), \(measure.verdict.rawValue)")
        .accessibilityIdentifier("stat.\(measure.title)")
    }
}

// A count in a thin ring, like the "78" biometric badge.
struct RingGauge: View {
    var fraction: Double
    var label: String
    var size: CGFloat = 64
    var body: some View {
        ZStack {
            Circle().stroke(Theme.slateLight, lineWidth: 3)
            Circle().trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(Theme.inkDeep, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Theme.spring, value: fraction)
            Text(label).font(Theme.numeral(size * 0.34)).foregroundStyle(Theme.inkDeep)
        }
        .frame(width: size, height: size)
    }
}

// A thin hairline between rows.
struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.hairline).frame(height: 1) }
}

// The in-card empty state: one quiet line.
struct EmptyLine: View {
    var text: String
    var body: some View {
        Text(text)
            .font(Theme.small(14))
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }
}

// A banner across the top for backend trouble; tap retries.
struct ErrorBanner: View {
    var message: String
    var retry: () -> Void
    var body: some View {
        Button(action: retry) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle").font(.system(size: 14, weight: .regular))
                Text(message).font(Theme.small(13)).multilineTextAlignment(.leading)
                Spacer()
                Text("RETRY").font(Theme.mono(10)).tracking(1)
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.accent)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusInset, style: .continuous))
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("error.banner")
    }
}

struct TagRow: View {
    var tags: [String]
    var body: some View {
        if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { ForEach(tags, id: \.self) { Chip(text: $0) } }
            }
        }
    }
}

// Text that shows a mono label above a value, like "1-2 / MONTHS".
struct LabeledValue: View {
    var label: String
    var value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(Theme.mono(9)).tracking(1).foregroundStyle(Theme.muted)
            Text(value).font(Theme.body(15)).foregroundStyle(Theme.ink)
        }
    }
}
