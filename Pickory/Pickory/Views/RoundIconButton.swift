import SwiftUI

/// A quiet circular action: hairline ring, no fill, no shadow, light symbol.
struct RoundIconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    @ScaledMetric(relativeTo: .title2) private var diameter: CGFloat = 54
    @ScaledMetric(relativeTo: .title2) private var symbol: CGFloat = 20

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: symbol, weight: .light))
                .foregroundStyle(Theme.ink)
                .frame(width: diameter, height: diameter)
                .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(scale: 0.92))
        .accessibilityLabel(label)
    }
}
