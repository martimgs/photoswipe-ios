import SwiftUI

// MARK: - Palette
// Light, warm, minimal (see docs/mockup.png).

enum Theme {
    static let paper = Color(red: 0.965, green: 0.957, blue: 0.937)     // background
    static let surface = Color(red: 0.925, green: 0.914, blue: 0.890)   // tiles, selected tab
    static let ink = Color(red: 0.10, green: 0.10, blue: 0.10)          // text, stars
    static let inkSecondary = Color(red: 0.46, green: 0.45, blue: 0.43)
    static let hairline = Color.black.opacity(0.08)

    static let cardCorner: CGFloat = 20
    static let swipeThreshold: CGFloat = 105
}

// MARK: - Motion tokens

extension Animation {
    /// Card settle / return — snappy with a touch of life.
    static let cardSpring = Animation.spring(response: 0.34, dampingFraction: 0.78)
    /// Fling-off easing (exit). Fast accelerate.
    static let fling = Animation.easeIn(duration: 0.26)
    /// Press micro-interaction.
    static let press = Animation.spring(response: 0.22, dampingFraction: 0.6)
}

// MARK: - Pressable button style (scale + soft press)

struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.9
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.press, value: configuration.isPressed)
    }
}

// MARK: - Haptics

enum Haptics {
    static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
    static func soft() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}
