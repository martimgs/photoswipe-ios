import SwiftUI
import SwiftyDropbox

/// Dropbox sign-in state. OAuth PKCE with offline access: SwiftyDropbox keeps
/// the refresh token in the keychain, so the user signs in once.
@MainActor
final class DropboxAuth: ObservableObject {
    static let shared = DropboxAuth()

    @Published private(set) var isSignedIn = false
    @Published private(set) var accountName: String?
    @Published private(set) var accountEmail: String?
    @Published var lastError: String?

    private static var didSetUp = false

    private init() {}

    /// Call once at launch, before any other Dropbox call.
    static func setUp() {
        guard !didSetUp else { return }
        didSetUp = true
        // Includes a background-session client for offline downloads.
        DropboxClientsManager.setupWithAppKey(
            DropboxConfig.appKey,
            backgroundSessionIdentifier: OfflineDownloadManager.backgroundSessionIdentifier,
            requestsToReconnect: OfflineDownloadManager.reconnect)
    }

    var client: DropboxClient? { DropboxClientsManager.authorizedClient }

    func refresh() {
        isSignedIn = client != nil
        guard let client else {
            accountName = nil
            accountEmail = nil
            return
        }
        Task {
            do {
                let account = try await client.users.getCurrentAccount().response()
                accountName = account.name.displayName
                accountEmail = account.email
            } catch {
                // Offline or token issue: keep the signed-in state, details load later.
            }
        }
    }

    func signIn() {
        lastError = nil
        let scopes = ScopeRequest(scopeType: .user, scopes: DropboxConfig.scopes, includeGrantedScopes: false)
        DropboxClientsManager.authorizeFromControllerV2(
            UIApplication.shared,
            controller: Self.topViewController(),
            loadingStatusDelegate: nil,
            openURL: { UIApplication.shared.open($0) },
            scopeRequest: scopes
        )
    }

    /// Handles the `db-<appKey>://` redirect. Returns true if it was ours.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        DropboxClientsManager.handleRedirectURL(url, includeBackgroundClient: true) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success: self.lastError = nil
                case .cancel: break
                case .error(let error, let description):
                    // Show the OAuth error code too, e.g. "invalid_scope".
                    self.lastError = "Sign-in failed (\(error.rawValue))" + (description.map { ": \($0)" } ?? ".")
                case .none: break
                }
                self.refresh()
            }
        }
    }

    /// Forgets the tokens. Albums, ratings and downloaded files stay in the app.
    func signOut() {
        DropboxClientsManager.unlinkClients()
        refresh()
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
