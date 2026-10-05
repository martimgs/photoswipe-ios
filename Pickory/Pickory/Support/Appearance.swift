import UIKit

/// Light / dark choice from Settings. Automatic follows the iOS setting.
enum Appearance: String, CaseIterable {
    case automatic, light, dark

    static let key = "appearance"

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    private var style: UIUserInterfaceStyle {
        switch self {
        case .automatic: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }

    static var current: Appearance {
        Appearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .automatic
    }

    /// Overrides the style on every window, so sheets and full-screen covers
    /// switch too, and `.unspecified` cleanly hands control back to iOS.
    @MainActor
    func apply() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}
