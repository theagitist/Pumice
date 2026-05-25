import SwiftUI

struct VaultBrowserView: View {
    let vaultURL: URL

    @EnvironmentObject private var vault: VaultStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var readerController = PDFReaderController()

    @State private var rootEntries: [VaultEntry] = []
    @State private var rootError: String?
    @State private var rootLoaded = false
    @State private var selection: URL?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Bumped to reset the entire sidebar tree (collapses every
    /// `DisclosureGroup`, drops every cached folder listing) when the
    /// user asks for a refresh.
    @State private var sidebarReloadToken = UUID()

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detail
        }
        .task(id: vaultURL) { await loadRoot() }
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
            if rootLoaded {
                List(selection: $selection) {
                    if let rootError {
                        Label(rootError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    } else if rootEntries.isEmpty {
                        Text("Vault is empty")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    ForEach(rootEntries) { entry in
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
                .listStyle(.sidebar)
                .id(sidebarReloadToken)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(vaultURL.lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task {
                            sidebarReloadToken = UUID()
                            await loadRoot()
                        }
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

    /// Color + width menu. Contents are contextual to the currently
    /// active tool — only the pen pickers when the pen is active,
    /// only the highlighter pickers when the highlighter is active.
    ///
    /// The menu label shows the swatch of the active tool's selected
    /// color so the toolbar reflects what you'd be drawing with. For
    /// the eraser the menu has nothing to configure; the label dims
    /// and the menu is hidden by the toolbar (the ToolbarItem is
    /// gated on `activeTool != .eraser`).
    ///
    /// Asset-catalog images: SwiftUI Menu bridges Pickers to UIMenu,
    /// which only carries a title + UIImage per option — Shape views
    /// and SwiftUI modifiers don't survive the bridge. The pen
    /// `Swatch*` PNGs are rendering-intent "original" so iOS doesn't
    /// tint them; the `Width*` PNGs are template-rendered so menu
    /// rows tint them to match the foreground color.
    @ViewBuilder
    private var colorMenu: some View {
        Menu {
            switch readerController.activeTool {
            case .pen:
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
            case .highlighter:
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
            case .eraser:
                EmptyView()
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

    private func loadRoot() async {
        let url = vaultURL
        let result = await Task.detached(priority: .userInitiated) {
            VaultDirectoryLister.list(url)
        }.value
        rootEntries = result.entries
        rootError = result.error
        rootLoaded = true

        // Restore whatever PDF was open last session — only if the user
        // hasn't already picked something in this session. Collapsing
        // the sidebar puts the user straight in the reader; they can
        // re-open the sidebar to browse. The PDF doesn't have to be
        // visible in the (lazy) sidebar tree for the detail view to
        // render — `selection` drives the detail independent of which
        // folders are currently expanded.
        if selection == nil, let restored = vault.resolveLastOpened() {
            selection = restored
            columnVisibility = .detailOnly
        }
    }
}
