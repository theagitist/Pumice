import Foundation

/// One node in the vault file tree — either a folder (with children) or a
/// PDF leaf. Folders with no PDF descendants are pruned by the scanner so
/// the tree never contains dead branches.
struct VaultNode: Identifiable, Hashable, Sendable {
    let url: URL
    let kind: Kind
    let children: [VaultNode]?

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

    var iconName: String {
        switch kind {
        case .folder: children?.isEmpty == false ? "folder" : "folder"
        case .pdf: "doc.richtext"
        }
    }
}

/// Recursive vault traversal using `contentsOfDirectory` per level rather
/// than `enumerator(at:)`. Two reasons:
///  1. `enumerator(at:)` returns `nil` on permission failures with no error
///     surface, which made the "No PDFs in vault" bug invisible.
///  2. Per-directory `contentsOfDirectory` lets us catch and report errors
///     for inaccessible subtrees while still returning whatever else
///     scanned successfully.
enum VaultScanner {
    struct Result: Sendable {
        let root: VaultNode
        let foldersScanned: Int
        let pdfsFound: Int
        let directoryErrors: [DirectoryError]
    }

    struct DirectoryError: Sendable, Hashable {
        let url: URL
        let message: String
    }

    static func scan(rootURL: URL) -> Result {
        var foldersScanned = 0
        var pdfsFound = 0
        var errors: [DirectoryError] = []

        let children = scanFolder(
            rootURL,
            foldersScanned: &foldersScanned,
            pdfsFound: &pdfsFound,
            errors: &errors
        )
        let root = VaultNode(url: rootURL, kind: .folder, children: children)
        return Result(
            root: root,
            foldersScanned: foldersScanned,
            pdfsFound: pdfsFound,
            directoryErrors: errors
        )
    }

    private static func scanFolder(
        _ folder: URL,
        foldersScanned: inout Int,
        pdfsFound: inout Int,
        errors: inout [DirectoryError]
    ) -> [VaultNode] {
        foldersScanned += 1
        let fm = FileManager.default
        let items: [URL]
        do {
            items = try fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        } catch {
            errors.append(DirectoryError(
                url: folder,
                message: error.localizedDescription
            ))
            return []
        }

        var nodes: [VaultNode] = []
        for item in items {
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                let kids = scanFolder(
                    item,
                    foldersScanned: &foldersScanned,
                    pdfsFound: &pdfsFound,
                    errors: &errors
                )
                if !kids.isEmpty {
                    nodes.append(VaultNode(url: item, kind: .folder, children: kids))
                }
            } else if item.pathExtension.lowercased() == "pdf" {
                pdfsFound += 1
                nodes.append(VaultNode(url: item, kind: .pdf, children: nil))
            }
        }

        nodes.sort { lhs, rhs in
            if lhs.kind != rhs.kind {
                return lhs.kind == .folder
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        return nodes
    }
}
