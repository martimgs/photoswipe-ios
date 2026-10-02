import SwiftUI

// MARK: - Palette
// Warm neutrals, defined in Assets.xcassets with dark variants. The photos
// supply the colour; the interface stays quiet.

enum Theme {
    static let paper = Color(.background)            // screen background
    static let surface = Color(.surface)             // image placeholders
    static let ink = Color(.textPrimary)             // text, filled stars, selection
    static let inkSecondary = Color(.textSecondary)  // metadata
    static let inkTertiary = Color(.textTertiary)    // empty stars, quiet icons
    static let hairline = Color(.hairline)           // borders, dividers

    /// Widest the main column gets on iPad, so lists and the swipe card
    /// don't stretch across a 13-inch screen.
    static let readableWidth: CGFloat = 760
    static let swipeThreshold: CGFloat = 105
}

// MARK: - Spacing (8 pt system)

enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 40
    /// Horizontal screen margin.
    static let margin: CGFloat = l
}

// MARK: - Corner radii

enum Radius {
    static let photo: CGFloat = 8
    static let thumbnail: CGFloat = 4
    /// Filled text buttons.
    static let control: CGFloat = 8
}

// MARK: - Type
// Built-in text styles so Dynamic Type keeps working; weights kept light.

extension Font {
    /// Home screen title (~34 pt).
    static let screenTitle = Font.largeTitle.weight(.regular)
    /// Navigation and row titles (~17 pt).
    static let rowTitle = Font.body
    /// Metadata under a title (~15 pt).
    static let metadata = Font.subheadline
    /// Small metadata (~13 pt).
    static let smallMetadata = Font.footnote
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
