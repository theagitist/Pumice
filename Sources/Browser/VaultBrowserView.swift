import SwiftUI

struct VaultBrowserView: View {
    let vaultURL: URL

    @EnvironmentObject private var vault: VaultStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var readerController = PDFReaderController()
    @State private var pdfs: [PDFEntry] = []
    @State private var selection: PDFEntry?
    @State private var loadError: String?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .task(id: vaultURL) { await loadPDFs() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                readerController.saveIfNeeded()
            }
        }
    }

    private var sidebar: some View {
        List(pdfs, selection: $selection) { entry in
            NavigationLink(value: entry) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.url.lastPathComponent)
                            .lineLimit(1)
                        if !entry.relativeParent.isEmpty {
                            Text(entry.relativeParent)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } icon: {
                    Image(systemName: "doc.richtext")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(vaultURL.lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Change vault…", systemImage: "folder.badge.gear") {
                        vault.forget()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .overlay {
            if let loadError {
                ContentUnavailableView("Could not read vault",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else if pdfs.isEmpty {
                ContentUnavailableView("No PDFs in vault",
                                       systemImage: "tray",
                                       description: Text("Drop a PDF anywhere inside \(vaultURL.lastPathComponent) and it will appear here."))
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let entry = selection {
            PDFReaderView(pdfURL: entry.url, controller: readerController)
                .id(entry.url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(entry.url.deletingPathExtension().lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Pick a PDF",
                                   systemImage: "doc.text",
                                   description: Text("Choose a PDF on the left to start reading. Use your finger to scroll, Apple Pencil to annotate."))
        }
    }

    private func loadPDFs() async {
        loadError = nil
        let url = vaultURL
        let list = await Task.detached(priority: .userInitiated) {
            PDFEntry.scan(vaultURL: url)
        }.value
        pdfs = list
    }
}

struct PDFEntry: Hashable, Identifiable, Sendable {
    let url: URL
    let relativeParent: String
    var id: URL { url }

    static func scan(vaultURL: URL) -> [PDFEntry] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var found: [PDFEntry] = []
        let basePath = vaultURL.path
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "pdf" else { continue }
            let parentPath = fileURL.deletingLastPathComponent().path
            let relative: String
            if parentPath == basePath {
                relative = ""
            } else if parentPath.hasPrefix(basePath) {
                relative = String(parentPath.dropFirst(basePath.count).drop(while: { $0 == "/" }))
            } else {
                relative = parentPath
            }
            found.append(PDFEntry(url: fileURL, relativeParent: relative))
        }
        found.sort { lhs, rhs in
            lhs.url.lastPathComponent.localizedCaseInsensitiveCompare(rhs.url.lastPathComponent) == .orderedAscending
        }
        return found
    }
}
