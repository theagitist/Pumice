import SwiftUI

/// Sidebar row for a vault folder. Wraps its children in a
/// `DisclosureGroup` that lists the folder's contents on first
/// expand, so the browser never enumerates more of the filesystem
/// than the user is currently looking at. Recursive: each child
/// folder is itself a `VaultFolderRow` with its own expansion state.
struct VaultFolderRow: View {
    let folder: URL

    @State private var entries: [VaultEntry] = []
    @State private var loadError: String?
    @State private var isLoaded = false
    @State private var isLoading = false
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
        } label: {
            Label(folder.lastPathComponent, systemImage: "folder")
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded && !isLoaded && !isLoading {
                load()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            Label(loadError, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.caption)
        } else if isLoading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
        } else if isLoaded && entries.isEmpty {
            Text("Empty folder")
                .foregroundStyle(.secondary)
                .font(.caption)
        } else {
            ForEach(entries) { entry in
                switch entry.kind {
                case .folder:
                    VaultFolderRow(folder: entry.url)
                        .selectionDisabled()
                case .pdf:
                    NavigationLink(value: entry.url) {
                        Label(entry.displayName, systemImage: "doc.richtext")
                    }
                }
            }
        }
    }

    private func load() {
        isLoading = true
        let url = folder
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                VaultDirectoryLister.list(url)
            }.value
            entries = result.entries
            loadError = result.error
            isLoaded = true
            isLoading = false
        }
    }
}
