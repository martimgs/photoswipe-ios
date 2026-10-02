import SwiftUI

/// Top-level router across the view-model phases, over a living aurora backdrop.
struct RootView: View {
    @StateObject private var vm = SwipeDeckViewModel()

    var body: some View {
        content
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AuroraBackground())
            .animation(.phase, value: phaseKey)
            .task { await vm.bootstrap() }
    }

    // String key so the cross-phase transition fires cleanly.
    private var phaseKey: String {
        switch vm.phase {
        case .loading: return "loading"
        case .permissionDenied: return "denied"
        case .empty: return "empty"
        case .swiping: return "swiping"
        case .done: return "done"
        }
    }

    @ViewBuilder private var content: some View {
        switch vm.phase {
        case .loading:
            LoadingView()
        case .permissionDenied:
            MessageView(
                icon: "lock.fill",
                title: "Photo access needed",
                message: "PhotoSwipe needs access to your photos so you can rate them. Enable it in Settings › Privacy › Photos.",
                button: "Open Settings",
                tint: Theme.album
            ) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        case .empty:
            EmptyLibraryView()
        case .swiping:
            SwipeDeckView(vm: vm)
        case .done:
            MessageView(icon: "checkmark.circle", title: "All rated",
                        message: "You've been through every photo.")
        }
    }
}

// MARK: - Loading

private struct LoadingView: View {
    @State private var spin = false
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "photo.stack.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.gradient(Theme.album, Theme.keep))
                .scaleEffect(spin ? 1.05 : 0.95)
            Text("Loading your photos…")
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundStyle(Theme.textDim)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { spin = true }
        }
    }
}

// MARK: - Empty (delightful first impression)

private struct EmptyLibraryView: View {
    @State private var float = false
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 56))
                .foregroundStyle(Theme.gradient(Theme.favorite, Theme.favorite2))
                .offset(y: float ? -8 : 8)
            Text("No photos yet")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("Your library looks empty. Add some photos and come back to rate them.")
                .font(.system(.subheadline, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textDim)
                .padding(.horizontal, 44)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { float = true }
        }
    }
}

// MARK: - Generic message

private struct MessageView: View {
    let icon: String
    let title: String
    let message: String
    var button: String? = nil
    var tint: Color = Theme.album
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 52))
                .foregroundStyle(Theme.textDim)
            Text(title)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(message)
                .font(.system(.subheadline, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textDim)
                .padding(.horizontal, 40)
            if let button, let action {
                Button(button) { Haptics.tap(); action() }
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22).padding(.vertical, 13)
                    .background(Theme.gradient(tint, tint.opacity(0.7)), in: Capsule())
                    .buttonStyle(PressableStyle())
                    .padding(.top, 8)
            }
        }
    }
}
