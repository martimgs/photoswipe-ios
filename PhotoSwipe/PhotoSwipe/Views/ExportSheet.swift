import SwiftUI
import SwiftData

/// Export the photos shown in the grid into a Dropbox folder. The folder
/// browser opens at the folder being viewed (Back walks up its parents),
/// so saving to a nearby or new folder takes a tap or two.
struct ExportSheet: View {
    let items: [PhotoItem]
    let album: ConnectedAlbum
    /// Subfolder being viewed (Dropbox), nil = album root.
    let folder: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var stack: [String] = []
    @State private var phase: Phase = .choosing
    @State private var resolvedStart = false

    enum Phase {
        case choosing
        case exporting(done: Int, total: Int, folder: String)
        case finished(ExportService.Result, folder: String)
        case failed(String)
    }

    var body: some View {
        NavigationStack(path: $stack) {
            ExportFolderLevel(path: "", count: items.count, onSave: export)
                .navigationDestination(for: String.self) { path in
                    ExportFolderLevel(path: path, count: items.count, onSave: export)
                }
        }
        .tint(Theme.ink)
        .overlay { if case .choosing = phase {} else { statusView } }
        .interactiveDismissDisabled(isExporting)
        .task { await openAtCurrentFolder() }
    }

    private var isExporting: Bool {
        if case .exporting = phase { return true }
        return false
    }

    /// Push every ancestor of the current folder so the browser starts there
    /// and Back goes up one level at a time.
    private func openAtCurrentFolder() async {
        guard !resolvedStart else { return }
        resolvedStart = true
        guard album.source == .dropbox,
              let root = await DropboxService.shared.displayPath(of: album.externalID) else { return }
        var full = root
        if let folder, !folder.isEmpty { full += "/" + folder }
        let parts = full.split(separator: "/").map(String.init)
        stack = parts.indices.map { "/" + parts[0...$0].joined(separator: "/") }
    }

    // MARK: Export

    private func export(to destination: String) {
        phase = .exporting(done: 0, total: items.count, folder: destination)
        Task {
            do {
                let update: (Int) -> Void = { done in
                    phase = .exporting(done: done, total: items.count, folder: destination)
                }
                let result: ExportService.Result
                switch album.source {
                case .dropbox:
                    result = try await ExportService.shared.copyDropboxFiles(dropboxFiles(), to: destination, progress: update)
                case .applePhotos:
                    result = try await ExportService.shared.uploadAssets(items.compactMap(\.asset), to: destination, progress: update)
                }
                Haptics.success()
                phase = .finished(result, folder: destination)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// File IDs with their names (names only label the copies).
    private func dropboxFiles() -> [(fileID: String, name: String)] {
        let albumID = album.externalID
        let records = (try? context.fetch(FetchDescriptor<DropboxFile>(
            predicate: #Predicate { $0.albumID == albumID }))) ?? []
        let names = Dictionary(records.map { ($0.fileID, $0.name) }, uniquingKeysWith: { a, _ in a })
        return items.map { (fileID: $0.id, name: names[$0.id] ?? "\($0.id).jpg") }
    }

    // MARK: Status

    private var statusView: some View {
        VStack(spacing: 16) {
            switch phase {
            case .choosing:
                EmptyView()
            case .exporting(let done, let total, let folder):
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .progressViewStyle(.circular)
                    .controlSize(.large)
                Text("Saving \(total) photo\(total == 1 ? "" : "s")…")
                    .font(.system(size: 17))
                Text(folder).font(.system(size: 13)).foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
            case .finished(let result, let folder):
                Image(systemName: "checkmark.circle").font(.system(size: 44, weight: .light))
                Text("Saved \(result.exported) photo\(result.exported == 1 ? "" : "s")")
                    .font(.system(size: 20))
                Text(folder).font(.system(size: 13)).foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                if result.failed > 0 {
                    Text("\(result.failed) couldn't be saved.").font(.system(size: 14)).foregroundStyle(Theme.inkSecondary)
                }
                doneButton("Done")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle").font(.system(size: 40, weight: .light))
                Text("Export failed").font(.system(size: 20))
                Text(message).font(.system(size: 14)).foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button("Back") { phase = .choosing }
                        .font(.system(size: 16, weight: .medium))
                    doneButton("Close")
                }
            }
        }
        .foregroundStyle(Theme.ink)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper)
    }

    private func doneButton(_ title: String) -> some View {
        Button(title) { dismiss() }
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Theme.paper)
            .padding(.horizontal, 22).padding(.vertical, 12)
            .background(Theme.ink, in: Capsule())
            .padding(.top, 6)
    }
}

/// One Dropbox folder in the export browser: its subfolders, New Folder,
/// and "Save N photos here".
private struct ExportFolderLevel: View {
    /// "" = Dropbox root.
    let path: String
    let count: Int
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var subfolders: [DropboxService.Folder] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var askName = false
    @State private var newName = ""
    @State private var created: String?

    private var title: String {
        path.isEmpty ? "Dropbox" : String(path.split(separator: "/").last ?? "Dropbox")
    }

    var body: some View {
        List {
            if let error {
                Text(error).font(.system(size: 15)).foregroundStyle(Theme.inkSecondary)
                    .listRowBackground(Color.clear)
            } else if loaded && subfolders.isEmpty {
                Text("No subfolders").font(.system(size: 15)).foregroundStyle(Theme.inkSecondary)
                    .listRowBackground(Color.clear)
            }
            ForEach(subfolders) { sub in
                NavigationLink(value: sub.pathDisplay) {
                    Label(sub.name, systemImage: "folder").foregroundStyle(Theme.ink)
                }
                .listRowBackground(Color.white.opacity(0.6))
            }
        }
        .overlay { if !loaded { ProgressView() } }
        .scrollContentBackground(.hidden)
        .background(Theme.paper)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { newName = ""; askName = true } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .accessibilityLabel("New Folder")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { onSave(path) } label: {
                Text("Save \(count) Photo\(count == 1 ? "" : "s") Here")
                    .font(.system(size: 17, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .foregroundStyle(Theme.paper)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(path.isEmpty || count == 0)
            .opacity(path.isEmpty ? 0.4 : 1)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Theme.paper)
        }
        .alert("New Folder", isPresented: $askName) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { Task { await createFolder() } }
        } message: {
            Text("Created inside “\(title)”.")
        }
        .navigationDestination(item: $created) { path in
            ExportFolderLevel(path: path, count: count, onSave: onSave)
        }
        .task { await load() }
    }

    private func load() async {
        guard !loaded else { return }
        do {
            subfolders = try await DropboxService.shared.subfolders(of: path)
        } catch {
            self.error = Connectivity.shared.isOnline
                ? "Couldn't load folders: \(error.localizedDescription)"
                : "You're offline. Connect to the internet to export."
        }
        loaded = true
    }

    /// Creates the folder, adds it to the list and opens it.
    private func createFolder() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let newPath = try await ExportService.shared.createFolder(named: name, in: path)
            subfolders.append(.init(id: newPath, name: (newPath as NSString).lastPathComponent, pathDisplay: newPath))
            subfolders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Haptics.success()
            created = newPath
        } catch {
            self.error = error.localizedDescription
        }
    }
}
