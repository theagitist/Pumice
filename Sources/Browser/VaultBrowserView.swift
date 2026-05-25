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
                description: Text("Browse folders on the left and tap a PDF to read it. Draw with Apple Pencil; press the pencil to toggle the eraser.")
            )
        }
    }

    @ToolbarContentBuilder
    private var readerToolbar: some ToolbarContent {
        // Keep the tool menu in its OWN ToolbarItem rather than inside
        // a group. Grouped items render as a tight cluster on iPad and
        // the menu icon sat right next to the undo button, leading to
        // adjacent-button hit overlap. A standalone ToolbarItem gets
        // its own full-size hit target.
        ToolbarItem(placement: .topBarTrailing) {
            toolMenu
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

            if let url = selection, url.pathExtension.lowercased() == "pdf" {
                // ShareLink presents the iOS share sheet on tap. The
                // simultaneousGesture flushes any pending strokes to
                // disk first, so the file the share sheet hands off is
                // the latest version. PDFDocument.write is synchronous
                // and fast, so the save completes before the share
                // sheet finishes rendering.
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                }
                .simultaneousGesture(TapGesture().onEnded {
                    readerController.saveIfNeeded()
                })
                .help("Share")
            }
        }
    }

    private var toolMenu: some View {
        Menu {
            Picker("Tool", selection: $readerController.isEraserActive) {
                Label("Pen", systemImage: "pencil.tip").tag(false)
                Label("Eraser", systemImage: "eraser").tag(true)
            }

            // Don't `.disabled()` these pickers when eraser is active —
            // that conditional modifier forces SwiftUI to rebuild the
            // menu content on every eraser toggle, which collides with
            // the toolbar Menu's tap gesture (visible in logs as
            // `updateVisibleMenuWithBlock while no context menu is
            // visible`). Letting the user pick a color/width while in
            // eraser mode just queues those settings for the next pen
            // stroke; no harm in always allowing it.
            // Asset-catalog images for the swatch icons. SwiftUI Menu
            // bridges Pickers to UIMenu, which only knows how to carry
            // a title and a UIImage per option — Shape views and
            // SwiftUI modifiers don't survive the bridge. The Swatch*
            // imagesets bake the color into the PNG (rendering-intent
            // "original" so iOS doesn't tint them), and the Width*
            // imagesets are template-rendered so the menu tints the
            // line to match the row's foreground color.
            Picker("Color", selection: $readerController.penColor) {
                ForEach(PenColor.allCases) { color in
                    Label(color.displayName, image: color.swatchAssetName)
                        .tag(color)
                }
            }

            Picker("Width", selection: $readerController.penWidth) {
                ForEach(PenWidth.allCases) { width in
                    Label(width.displayName, image: width.iconAssetName)
                        .tag(width)
                }
            }
        } label: {
            // Explicit 44pt hit target (Apple HIG minimum) plus
            // `.contentShape(Rectangle())` so taps anywhere in the
            // frame count, not just on the symbol's filled pixels.
            // Without this the iPad toolbar would size the button to
            // the SF Symbol's tight bounds, which is part of why taps
            // landed only occasionally.
            Image(systemName: readerController.isEraserActive ? "eraser" : "pencil.tip")
                .font(.title3)
                .frame(width: 44, height: 44, alignment: .center)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Pen and eraser settings")
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
