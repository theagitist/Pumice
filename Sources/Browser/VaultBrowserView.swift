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
                description: Text("Browse folders on the left and tap a PDF to read it. Draw with Apple Pencil; double-tap the pencil to alternate pen and highlighter; squeeze and hold for the eraser.")
            )
        }
    }

    @ToolbarContentBuilder
    private var readerToolbar: some ToolbarContent {
        // Keep each menu in its OWN ToolbarItem rather than grouped.
        // Grouped items render as a tight cluster on iPad and adjacent
        // icons can get hit-test overlap. Separate ToolbarItems each
        // get a full-size 44pt hit target.
        ToolbarItem(placement: .topBarTrailing) {
            toolMenu
        }

        ToolbarItem(placement: .topBarTrailing) {
            colorMenu
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
            Picker("Tool", selection: $readerController.activeTool) {
                ForEach(Tool.allCases) { tool in
                    Label(tool.displayName, systemImage: tool.symbolName)
                        .tag(tool)
                }
            }
        } label: {
            // Explicit 44pt hit target (Apple HIG minimum) plus
            // `.contentShape(Rectangle())` so taps anywhere in the
            // frame count, not just on the symbol's filled pixels.
            Image(systemName: readerController.activeTool.symbolName)
                .font(.title3)
                .frame(width: 44, height: 44, alignment: .center)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Tool picker")
    }

    /// Color + width menu. The menu body always renders the SAME four
    /// pickers (pen color, pen width, highlight color, highlight width)
    /// regardless of active tool — conditional menu content collides
    /// with the toolbar Menu's tap recognizer on iPad (visible in logs
    /// as `updateVisibleMenuWithBlock while no context menu is
    /// visible`).
    ///
    /// The menu label shows the swatch of the currently active tool's
    /// selected color so the toolbar reflects what you'd be drawing
    /// with. For eraser, falls back to a generic palette glyph.
    ///
    /// Asset-catalog images: SwiftUI Menu bridges Pickers to UIMenu,
    /// which only carries a title + UIImage per option — Shape views
    /// and SwiftUI modifiers don't survive the bridge. The pen
    /// `Swatch*` PNGs are rendering-intent "original" so iOS doesn't
    /// tint them; the `Width*` PNGs are template-rendered so menu
    /// rows tint them to match the foreground color.
    private var colorMenu: some View {
        Menu {
            Section("Pen") {
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
            }
            Section("Highlighter") {
                Picker("Color", selection: $readerController.highlightColor) {
                    ForEach(HighlightPenColor.allCases) { color in
                        Label(color.displayName, image: color.swatchAssetName)
                            .tag(color)
                    }
                }
                Picker("Width", selection: $readerController.highlightWidth) {
                    ForEach(HighlightWidth.allCases) { width in
                        Label(width.displayName, image: width.iconAssetName)
                            .tag(width)
                    }
                }
            }
        } label: {
            colorMenuLabel
                .font(.title3)
                .frame(width: 44, height: 44, alignment: .center)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Color and width picker")
    }

    @ViewBuilder
    private var colorMenuLabel: some View {
        switch readerController.activeTool {
        case .pen:
            Image(readerController.penColor.swatchAssetName)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
        case .highlighter:
            Image(readerController.highlightColor.swatchAssetName)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
        case .eraser:
            Image(systemName: "paintpalette")
                .opacity(0.4)
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
