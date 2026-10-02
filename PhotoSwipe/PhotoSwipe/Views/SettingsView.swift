import SwiftUI
import Photos

/// Opened from the gear on the Library screen.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @EnvironmentObject private var dropbox: DropboxAuth
    @EnvironmentObject private var sync: DropboxSyncEngine
    @ObservedObject private var connectivity = Connectivity.shared
    @State private var confirmSignOut = false
    @AppStorage(OfflineDownloadManager.qualityKey) private var quality = DownloadQuality.optimized.rawValue
    @State private var estimates: (optimized: Int64, originals: Int64, photos: Int) = (0, 0, 0)

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Access", value: statusText)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                } header: {
                    Text("Apple Photos")
                } footer: {
                    Text(footer)
                }
                .listRowBackground(Theme.surface)

                Section {
                    if dropbox.isSignedIn {
                        LabeledContent("Signed in as") {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(dropbox.accountName ?? "Dropbox user")
                                if let email = dropbox.accountEmail {
                                    Text(email).font(.footnote).foregroundStyle(Theme.inkSecondary)
                                }
                            }
                        }
                        LabeledContent("Ratings to sync", value: sync.pendingCount == 0 ? "None" : "\(sync.pendingCount)")
                        Button("Sign Out", role: .destructive) { confirmSignOut = true }
                    } else {
                        Button("Sign In to Dropbox") { dropbox.signIn() }
                    }
                } header: {
                    Text("Dropbox account")
                } footer: {
                    if let error = dropbox.lastError {
                        Text(error)
                    } else if let reason = sync.tagsUnavailableReason {
                        Text("Ratings can't be saved to Dropbox as tags: \(reason)")
                    } else {
                        Text(dropbox.isSignedIn
                             ? "Signing out keeps your albums, ratings and downloaded photos in PhotoSwipe."
                             : "Sign in once to connect Dropbox folders.")
                    }
                }
                .listRowBackground(Theme.surface)

                Section {
                    Picker("Quality", selection: $quality) {
                        ForEach(DownloadQuality.allCases, id: \.self) { q in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(q.title)
                                Text(estimateText(q)).font(.footnote).foregroundStyle(Theme.inkSecondary)
                            }
                            .tag(q.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Offline downloads")
                } footer: {
                    Text("Used when you make a Dropbox album available offline. Optimized saves Dropbox-rendered copies up to 2048 px; Originals saves the full files. Sizes are for all \(estimates.photos) photos in your Dropbox albums; the Optimized size is an estimate.")
                }
                .listRowBackground(Theme.surface)

                #if DEBUG
                Section {
                    Toggle("Simulate Offline", isOn: $connectivity.simulateOffline)
                } header: {
                    Text("Developer")
                } footer: {
                    Text("Debug builds only. Acts as if there's no internet: no Dropbox syncing, downloads or online thumbnails. Rating changes queue up and show the arrow-up icon.")
                }
                .listRowBackground(Theme.surface)
                #endif

                Section {
                    LabeledContent("Version", value: version)
                } footer: {
                    Text("PhotoSwipe never deletes photos. Rejecting only hides a photo inside this app.")
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.paper)
            .confirmationDialog("Sign out of Dropbox?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { dropbox.signOut() }
            } message: {
                Text(sync.pendingCount > 0
                     ? "\(sync.pendingCount) rating changes haven't synced yet. They stay in PhotoSwipe and sync after you sign in again."
                     : "Your Dropbox albums, ratings and downloaded photos stay in PhotoSwipe.")
            }
            .task { estimates = OfflineDownloadManager.shared.estimatedSizes() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Theme.ink)
    }

    private var statusText: String {
        switch status {
        case .authorized: return "Full"
        case .limited: return "Limited"
        case .denied, .restricted: return "Off"
        case .notDetermined: return "Not asked"
        @unknown default: return "Unknown"
        }
    }

    private var footer: String {
        switch status {
        case .authorized:
            return "Star ratings are saved to your Photos library."
        case .limited:
            return "With limited access, albums may be missing and ratings may not save. Choose Full Access in Settings."
        default:
            return "Allow photo access in Settings to connect albums."
        }
    }

    private func estimateText(_ q: DownloadQuality) -> String {
        let bytes = q == .optimized ? estimates.optimized : estimates.originals
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return q == .optimized ? "About \(size)" : size
    }

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
        return "\(v) (\(b))"
    }
}
