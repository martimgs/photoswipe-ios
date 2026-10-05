import SwiftUI
import Photos

/// Shows the splash, asks for photo access once, then shows the Library.
struct RootView: View {
    @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var showSplash = true

    var body: some View {
        Group {
            switch status {
            case .authorized, .limited:
                LibraryView()
            case .notDetermined:
                Theme.paper.ignoresSafeArea()
                    .task {
                        status = await PhotoLibraryService().requestAuthorization()
                    }
            default:
                MessageView(
                    icon: "lock",
                    title: "Photo access needed",
                    message: "Pickory needs access to your photos so you can rate them. It never deletes anything.",
                    button: "Open Settings"
                ) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper.ignoresSafeArea())
        .overlay {
            if showSplash {
                SplashView().transition(.opacity)
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(.easeOut(duration: 0.35)) { showSplash = false }
        }
    }
}

/// Centered icon + title + message, with an optional button.
struct MessageView: View {
    let icon: String
    let title: String
    let message: String
    var button: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.largeTitle.weight(.ultraLight))
                .foregroundStyle(Theme.inkSecondary)
            Text(title)
                .font(.title3)
                .foregroundStyle(Theme.ink)
            Text(message)
                .font(.metadata)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.inkSecondary)
                .padding(.horizontal, 40)
            if let button, let action {
                Button(button) { Haptics.tap(); action() }
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.paper)
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .buttonStyle(PressableStyle())
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
