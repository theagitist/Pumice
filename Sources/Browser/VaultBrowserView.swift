import SwiftUI

struct VaultBrowserView: View {
    let vaultURL: URL

    @EnvironmentObject private var vault: VaultStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var readerController = PDFReaderController()

    @State private var scanResult: VaultScanner.Result?
    @State private var selection: URL?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detail
        }
        .task(id: vaultURL) { await loadTree() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                readerController.saveIfNeeded()
            }
        }
        .onChange(of: selection) { _, newSelection in
            if let url = newSelection, url.pathExtension.lowercased() == "pdf" {
                vault.rememberOpenedPDF(url)
            }
        }
    }

    private var sidebar: some View {
        Group {
            if let scanResult {
                List(selection: $selection) {
                    OutlineGroup(scanResult.root.children ?? [], children: \.children) { node in
                        row(for: node)
                    }
                }
                .listStyle(.sidebar)
                .overlay { overlay(for: scanResult) }
                .safeAreaInset(edge: .bottom) { footer(for: scanResult) }
            } else {
                ProgressView("Scanning vault…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(vaultURL.lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Rescan", systemImage: "arrow.clockwise") {
                        Task { await loadTree() }
                    }
                    Button("Change vault…", systemImage: "folder.badge.gear") {
                        vault.forget()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    @ViewBuilder
    private func row(for node: VaultNode) -> some View {
        switch node.kind {
        case .folder:
            Label(node.displayName, systemImage: "folder")
                .selectionDisabled()
        case .pdf:
            NavigationLink(value: node.url) {
                Label(node.displayName, systemImage: "doc.richtext")
            }
        }
    }

    @ViewBuilder
    private func overlay(for result: VaultScanner.Result) -> some View {
        if result.pdfsFound == 0 {
            ContentUnavailableView {
                Label("No PDFs in vault", systemImage: "tray")
            } description: {
                VStack(spacing: 8) {
                    Text("Pumice walked \(result.foldersScanned) folder\(result.foldersScanned == 1 ? "" : "s") and didn't find any `.pdf` files.")
                    if !result.directoryErrors.isEmpty {
                        Text("Some folders couldn't be read — see below.")
                            .foregroundStyle(.orange)
                    }
                }
            } actions: {
                Button {
                    vault.forget()
                } label: {
                    Label("Choose a different vault…", systemImage: "folder.badge.gear")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    @ViewBuilder
    private func footer(for result: VaultScanner.Result) -> some View {
        if !result.directoryErrors.isEmpty || result.pdfsFound > 0 {
            VStack(alignment: .leading, spacing: 4) {
                if result.pdfsFound > 0 {
                    Text("\(result.pdfsFound) PDF\(result.pdfsFound == 1 ? "" : "s") across \(result.foldersScanned) folder\(result.foldersScanned == 1 ? "" : "s").")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ForEach(result.directoryErrors.prefix(3), id: \.self) { err in
                    Text("⚠︎ \(err.url.lastPathComponent): \(err.message)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                if result.directoryErrors.count > 3 {
                    Text("+ \(result.directoryErrors.count - 3) more error\(result.directoryErrors.count - 3 == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let url = selection, url.pathExtension.lowercased() == "pdf" {
            PDFReaderView(pdfURL: url, controller: readerController)
                .id(url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(url.deletingPathExtension().lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { readerToolbar }
        } else {
            ContentUnavailableView(
                "Pick a PDF",
                systemImage: "doc.text",
                description: Text("Browse folders on the left and tap a PDF to read it. Tap an annotation to select it, then use the toolbar to delete or undo.")
            )
        }
    }

    @ToolbarContentBuilder
    private var readerToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Toggle(isOn: $readerController.allowFingerDrawing) {
                Image(systemName: readerController.allowFingerDrawing
                      ? "hand.draw.fill"
                      : "hand.draw")
            }
            .toggleStyle(.button)
            .help("Off: pencil draws, finger scrolls. On: finger draws too (for when you don't have a Pencil).")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                readerController.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!readerController.canUndo)
            .help("Undo")

            Button {
                readerController.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!readerController.canRedo)
            .help("Redo")

            Button(role: .destructive) {
                readerController.deleteSelectedAnnotation()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(!readerController.hasSelectedAnnotation)
            .help("Delete selected annotation")
        }
    }

    private func loadTree() async {
        let url = vaultURL
        let result = await Task.detached(priority: .userInitiated) {
            VaultScanner.scan(rootURL: url)
        }.value
        scanResult = result

        // After the tree is loaded, jump back to whatever PDF was open
        // last session — but only if the user hasn't already picked
        // something in this session. When we do restore, collapse the
        // sidebar so the user lands straight in the reader.
        if selection == nil, let restored = vault.resolveLastOpened() {
            selection = restored
            columnVisibility = .detailOnly
        }
    }
}
