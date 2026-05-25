import Foundation

/// One entry inside a vault folder — either a subfolder or a PDF leaf.
/// The browser lists these one directory at a time and renders folder
/// rows that lazily fetch their own children on expansion. The pre-V0
/// scanner that walked the entire vault upfront was scrapped because
/// vaults can be arbitrarily large and the user wants the sidebar
/// available immediately, with every folder visible — including ones
/// that contain no PDFs.
struct VaultEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let kind: Kind

    enum Kind: Sendable, Hashable {
        case folder
        case pdf
    }

    var id: URL { url }

    var displayName: String {
        switch kind {
        case .folder: url.lastPathComponent
        case .pdf: url.deletingPathExtension().lastPathComponent
        }
    }
}

/// Lists a single directory's immediate children (no recursion). Used
/// by `VaultFolderRow` on first expand to populate its child rows.
/// Errors are returned, not thrown, so the row can surface them inline
/// without bringing down the rest of the tree — same per-directory
/// error-tolerance the old recursive scanner had.
enum VaultDirectoryLister {
    struct Result: Sendable {
        let entries: [VaultEntry]
        let error: String?
    }

    static func list(_ folder: URL) -> Result {
        let fm = FileManager.default
        let items: [URL]
        do {
            items = try fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        } catch {
            return Result(entries: [], error: error.localizedDescription)
        }

        var entries: [VaultEntry] = []
        for item in items {
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                entries.append(VaultEntry(url: item, kind: .folder))
            } else if item.pathExtension.lowercased() == "pdf" {
                entries.append(VaultEntry(url: item, kind: .pdf))
            }
        }

        // Folders first, then alphabetical inside each kind.
        entries.sort { lhs, rhs in
            if lhs.kind != rhs.kind {
                return lhs.kind == .folder
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        return Result(entries: entries, error: nil)
    }
}
