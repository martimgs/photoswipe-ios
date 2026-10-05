import SwiftUI

/// Logo, name and tagline shown briefly over the app at launch. The system
/// launch screen is plain `Background`, so this appears without a flash.
struct SplashView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            Image(.splashLogo)
                .resizable()
                .scaledToFit()
                .frame(width: 84, height: 84)
                // The dark square would vanish on the dark background.
                .colorInvert(colorScheme == .dark)
                .padding(.bottom, 32)
            Image(.splashName)
                .resizable()
                .scaledToFit()
                .frame(width: 186)
                .foregroundStyle(Theme.ink)
                .padding(.bottom, 32)
            Text("Sort your photos.\nKeep what matters.")
                .font(.callout)
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.inkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper.ignoresSafeArea())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pickory. Sort your photos. Keep what matters.")
    }
}

private extension View {
    @ViewBuilder func colorInvert(_ active: Bool) -> some View {
        if active { colorInvert() } else { self }
    }
}

#Preview { SplashView() }
