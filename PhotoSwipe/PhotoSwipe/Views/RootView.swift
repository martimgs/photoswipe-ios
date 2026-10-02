import SwiftUI
import Photos

/// Asks for photo access once, then shows the Library.
struct RootView: View {
    @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)

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
                    message: "PhotoSwipe needs access to your photos so you can rate them. It never deletes anything.",
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
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.inkSecondary)
            Text(title)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Theme.ink)
            Text(message)
                .font(.system(size: 15))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.inkSecondary)
                .padding(.horizontal, 40)
            if let button, let action {
                Button(button) { Haptics.tap(); action() }
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.paper)
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .background(Theme.ink, in: Capsule())
                    .buttonStyle(PressableStyle())
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
