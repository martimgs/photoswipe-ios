import UIKit
import SwiftyDropbox

/// Hands background URLSession events (finished offline downloads while the
/// app was suspended or terminated) back to SwiftyDropbox.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == OfflineDownloadManager.backgroundSessionIdentifier else {
            completionHandler()
            return
        }
        DropboxAuth.setUp()
        DropboxClientsManager.handleEventsForBackgroundURLSession(
            with: identifier,
            creationInfos: [],
            completionHandler: completionHandler,
            requestsToReconnect: OfflineDownloadManager.reconnect)
    }
}
