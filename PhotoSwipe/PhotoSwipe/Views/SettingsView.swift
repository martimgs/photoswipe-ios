import SwiftUI
import Photos

/// Opened from the gear on the Library screen.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @EnvironmentObject private var dropbox: DropboxAuth
    @State private var confirmSignOut = false

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
                .listRowBackground(Color.white.opacity(0.6))

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
                        Button("Sign Out", role: .destructive) { confirmSignOut = true }
                    } else {
                        Button("Sign In to Dropbox") { dropbox.signIn() }
                    }
                } header: {
                    Text("Dropbox account")
                } footer: {
                    if let error = dropbox.lastError {
                        Text(error)
                    } else {
                        Text(dropbox.isSignedIn
                             ? "Signing out keeps your albums, ratings and downloaded photos in PhotoSwipe."
                             : "Sign in once to connect Dropbox folders.")
                    }
                }
                .listRowBackground(Color.white.opacity(0.6))

                Section {
                    LabeledContent("Version", value: version)
                } footer: {
                    Text("PhotoSwipe never deletes photos. Rejecting only hides a photo inside this app.")
                }
                .listRowBackground(Color.white.opacity(0.6))
            }
            .scrollContentBackground(.hidden)
            .background(Theme.paper)
            .confirmationDialog("Sign out of Dropbox?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { dropbox.signOut() }
            } message: {
                Text("Your Dropbox albums, ratings and downloaded photos stay in PhotoSwipe.")
            }
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

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
        return "\(v) (\(b))"
    }
}
