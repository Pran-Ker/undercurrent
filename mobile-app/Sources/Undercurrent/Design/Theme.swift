import SwiftUI

// The design language, borrowed from qoves.com: a slate palette, thin large numerals, mono
// uppercase eyebrow labels, white cards with hairline borders and generous radii, pill buttons.
// Every color is a pair (light, dark). Nothing in the views names a raw color.
enum Theme {
    // Palette
    static let ink = Color(light: 0x233137, dark: 0xF2F5F5)          // primary text
    static let inkDeep = Color(light: 0x0B1315, dark: 0xFFFFFF)      // display headings, dark buttons
    static let muted = Color(light: 0x758084, dark: 0x9AAEB5)        // secondary text
    static let slate = Color(light: 0x9AAEB5, dark: 0x758084)        // second line of a two-tone title
    static let slateLight = Color(light: 0xCDDBE1, dark: 0x2D3B41)   // tracks, dividers
    static let slateFill = Color(light: 0xAEC2C9, dark: 0x5D767E)    // filled portion of a track
    static let hairline = Color(light: 0xE8E8E8, dark: 0x233137)     // card borders
    static let canvas = Color(light: 0xF9FBFB, dark: 0x0B1315)       // page background
    static let canvasDeep = Color(light: 0xF2F5F5, dark: 0x111B1E)   // inset surfaces
    static let surface = Color(light: 0xFFFFFF, dark: 0x16222A)      // cards
    static let accent = Color(light: 0xDEFFFF, dark: 0x1E3A3F)       // the one pale-cyan highlight
    static let good = Color(light: 0x3E8E5A, dark: 0x6FCF97)
    static let warn = Color(light: 0xD98B2B, dark: 0xF2B266)
    static let bad = Color(light: 0xC94F3D, dark: 0xF07B6A)

    // Type. PP Neue Montreal on the web; SF Pro at light weights reads the same. Mono for labels.
    static func display(_ size: CGFloat = 34) -> Font { .system(size: size, weight: .light, design: .default) }
    static func title(_ size: CGFloat = 20) -> Font { .system(size: size, weight: .regular) }
    static func body(_ size: CGFloat = 16) -> Font { .system(size: size, weight: .regular) }
    static func bodyMedium(_ size: CGFloat = 16) -> Font { .system(size: size, weight: .medium) }
    static func small(_ size: CGFloat = 13) -> Font { .system(size: size, weight: .regular) }
    static func mono(_ size: CGFloat = 11) -> Font { .system(size: size, weight: .regular, design: .monospaced) }
    static func numeral(_ size: CGFloat = 44) -> Font { .system(size: size, weight: .light).monospacedDigit() }

    // Shape and rhythm
    static let radiusCard: CGFloat = 16
    static let radiusInset: CGFloat = 10
    static let radiusChip: CGFloat = 6
    static let gutter: CGFloat = 16
    static let cardPadding: CGFloat = 16

    static let spring = Animation.snappy(duration: 0.3, extraBounce: 0.06)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// Press feedback under the 160ms threshold where it starts to read as lag.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}
