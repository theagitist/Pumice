import PDFKit
import PumiceCore
import UIKit

/// PDFView's inner scrollview isn't part of its public API. The
/// Cookiezby working reference exposes it via subview enumeration so
/// it can disable scrolling while editing. We use the same trick.
private extension PDFView {
    var privateScrollView: UIScrollView? {
        subviews.first as? UIScrollView
    }
}

/// PDFPage subclass returned by `PDFDocumentDelegate.classForPage()`.
/// Cookiezby's working `PDFPageOverlayViewProvider` reference uses a
/// custom subclass; we mirror that pattern in case PDFKit requires
/// it (currently empty, just a marker class).
final class PumicePDFPage: PDFPage {}

/// Standalone `PDFDocumentDelegate` so PDFKit can call `classForPage()`
/// from background queues without tripping Swift 6's MainActor
/// concurrency assertion. The view controller is implicitly
/// `@MainActor` (it's a UIViewController); routing the delegate
/// through `self` crashed in `_dispatch_assert_queue_fail`.
final class PumicePDFDocumentDelegate: NSObject, @unchecked Sendable, PDFDocumentDelegate {
    func classForPage() -> AnyClass {
        return PumicePDFPage.self
    }
}

/// Standalone `PDFPageOverlayViewProvider`. Same motivation as
/// `PumicePDFDocumentDelegate`: PDFKit may invoke the provider's
/// methods from a non-main queue, and a `@MainActor` view controller
/// would silently get its calls dropped (or trip a concurrency
/// assert). The working Cookiezby reference uses a separate provider
/// object too; we mirror that pattern.
///
/// The provider owns the per-page canvas/path state. The view
/// controller pulls from it on save and pushes hydrated paths into
/// it on load.
final class PumiceOverlayProvider: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var strokesForPage: [PDFPage: [StrokeRecord]] = [:]
    private var canvasByPage: [PDFPage: PumiceCanvasView] = [:]

    /// Current tool settings. Applied to every new canvas as it is
    /// created, and pushed onto live canvases via the setters below
    /// when the user changes them from the toolbar. Pen + highlighter
    /// styles are tracked separately so switching tools restores each
    /// tool's last choice.
    @MainActor private var mode: PumiceCanvasView.Mode = .pen
    @MainActor private var penColor: UIColor = .systemBlue
    @MainActor private var penWidth: CGFloat = 3
    @MainActor private var highlightColor: UIColor = UIColor(red: 1.0, green: 0.92, blue: 0.23, alpha: 1.0)
    @MainActor private var highlightWidth: CGFloat = 14

    /// Called whenever a new pen stroke is finished on any canvas.
    /// Receives the page and the freshly committed record so the
    /// controller can register an undo action for it.
    var onPathFinished: (@MainActor (PDFPage, StrokeRecord) -> Void)?

    /// Called when an eraser gesture finishes on a canvas, carrying
    /// every stroke the gesture rubbed out. The canvas has already
    /// removed them from its own state; the provider mirrors that into
    /// `strokesForPage` and the controller registers the undo batch.
    var onEraserStroke: (@MainActor (PDFPage, [StrokeRecord]) -> Void)?

    /// Called when a highlighter gesture finishes on a canvas, carrying
    /// the page and the first/last canvas-space points. The controller
    /// converts to PDF user space and asks PumiceCore to snap to the
    /// underlying text.
    var onHighlightStrokeFinished: (@MainActor (PDFPage, CGPoint, CGPoint) -> Void)?

    func setStrokes(_ strokes: [StrokeRecord], for page: PDFPage) {
        lock.lock(); defer { lock.unlock() }
        strokesForPage[page] = strokes
    }

    func strokes(for page: PDFPage) -> [StrokeRecord]? {
        lock.lock(); defer { lock.unlock() }
        return strokesForPage[page]
    }

    func allStrokes() -> [PDFPage: [StrokeRecord]] {
        lock.lock(); defer { lock.unlock() }
        return strokesForPage
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        strokesForPage.removeAll()
        canvasByPage.removeAll()
    }

    /// Sync any currently-active canvases' drawings back into the
    /// stroke store. Call from save() before writing the document, to
    /// capture drawings on pages that haven't scrolled out of view.
    @MainActor func syncActiveCanvases() {
        lock.lock(); defer { lock.unlock() }
        for (page, canvas) in canvasByPage {
            strokesForPage[page] = canvas.strokes
        }
    }

    /// Append a stroke to a page's list and mirror the update on the
    /// active canvas if one is on-screen. Used by undo/redo — stroke
    /// creation goes through the canvas's own gesture path.
    @MainActor func appendStroke(_ stroke: StrokeRecord, to page: PDFPage) {
        lock.lock()
        var existing = strokesForPage[page] ?? []
        existing.append(stroke)
        strokesForPage[page] = existing
        let activeCanvas = canvasByPage[page]
        lock.unlock()
        activeCanvas?.setStrokes(existing)
    }

    /// Remove a specific stroke (matched by path object identity) from
    /// a page's list and refresh the active canvas if it's on-screen.
    @MainActor func removeStroke(_ stroke: StrokeRecord, from page: PDFPage) {
        lock.lock()
        var existing = strokesForPage[page] ?? []
        existing.removeAll { $0.path === stroke.path }
        strokesForPage[page] = existing
        let activeCanvas = canvasByPage[page]
        lock.unlock()
        activeCanvas?.setStrokes(existing)
    }

    @MainActor func setPenColor(_ color: UIColor) {
        penColor = color
        lock.lock()
        let canvases = Array(canvasByPage.values)
        lock.unlock()
        for canvas in canvases { canvas.penColor = color }
    }

    @MainActor func setPenWidth(_ width: CGFloat) {
        penWidth = width
        lock.lock()
        let canvases = Array(canvasByPage.values)
        lock.unlock()
        for canvas in canvases { canvas.penWidth = width }
    }

    @MainActor func setMode(_ newMode: PumiceCanvasView.Mode) {
        mode = newMode
        lock.lock()
        let canvases = Array(canvasByPage.values)
        lock.unlock()
        for canvas in canvases { canvas.mode = newMode }
    }

    @MainActor func setHighlightColor(_ color: UIColor) {
        highlightColor = color
        lock.lock()
        let canvases = Array(canvasByPage.values)
        lock.unlock()
        for canvas in canvases { canvas.highlightColor = color }
    }

    @MainActor func setHighlightWidth(_ width: CGFloat) {
        highlightWidth = width
        lock.lock()
        let canvases = Array(canvasByPage.values)
        lock.unlock()
        for canvas in canvases { canvas.highlightWidth = width }
    }

    @MainActor var currentPenColor: UIColor { penColor }
    @MainActor var currentPenWidth: CGFloat { penWidth }
    @MainActor var currentMode: PumiceCanvasView.Mode { mode }
}

extension PumiceOverlayProvider: @preconcurrency PDFPageOverlayViewProvider {
    @MainActor
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        let canvas = PumiceCanvasView()
        canvas.penColor = penColor
        canvas.penWidth = penWidth
        canvas.highlightColor = highlightColor
        canvas.highlightWidth = highlightWidth
        canvas.mode = mode
        let existing: [StrokeRecord]? = {
            lock.lock(); defer { lock.unlock() }
            return strokesForPage[page]
        }()
        if let existing { canvas.setStrokes(existing) }
        canvas.onPathFinished = { [weak self, weak page] stroke in
            guard let self, let page else { return }
            self.lock.lock()
            self.strokesForPage[page] = canvas.strokes
            self.lock.unlock()
            DispatchQueue.main.async { [weak self] in
                self?.onPathFinished?(page, stroke)
            }
        }
        canvas.onEraserStroke = { [weak self, weak page] removedBatch in
            guard let self, let page else { return }
            // Canvas has already removed these strokes from its own
            // list. Mirror that into our authoritative store so save
            // and re-display stay in sync.
            self.lock.lock()
            self.strokesForPage[page] = canvas.strokes
            self.lock.unlock()
            DispatchQueue.main.async { [weak self] in
                self?.onEraserStroke?(page, removedBatch)
            }
        }
        canvas.onHighlightStrokeFinished = { [weak self, weak page] first, last in
            guard let self, let page else { return }
            DispatchQueue.main.async { [weak self] in
                self?.onHighlightStrokeFinished?(page, first, last)
            }
        }
        lock.lock()
        canvasByPage[page] = canvas
        lock.unlock()

        // Same PDFPageView.userInteractionEnabled trick as before;
        // the overlay won't see touches without it.
        for subview in view.documentView?.subviews ?? [] {
            if NSStringFromClass(type(of: subview)) == "PDFPageView" {
                subview.isUserInteractionEnabled = true
            }
        }
        return canvas
    }

    @MainActor
    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let canvas = overlayView as? PumiceCanvasView else { return }
        lock.lock()
        strokesForPage[page] = canvas.strokes
        canvasByPage.removeValue(forKey: page)
        lock.unlock()
    }
}

/// PDFView host that uses Apple's `PDFPageOverlayViewProvider` (iOS 16+)
/// to install a `PumiceCanvasView` per PDF page. Each canvas owns its
/// own stroke list (in canvas coords, UIKit Y-down). PDFKit auto-sizes
/// the overlay to the page, so canvas coordinates ARE page-local
/// pixels and the strokes scroll/zoom with their page for free.
///
/// We deliberately do NOT use PencilKit. Multiple iterations against
/// iPadOS 26 hardware showed that `PKCanvasView` with
/// `drawingPolicy = .pencilOnly` never activates its gesture pipeline
/// inside PDFKit's overlay — the pen falls through to PDFView's
/// scroll regardless of markup mode, first responder, or
/// `userInteractionEnabled` on the underlying `PDFPageView`. Going
/// to a plain `UIGestureRecognizer` subclass that explicitly accepts
/// only `.pencil` touches gives deterministic behavior.
///
/// Persistence:
///   * On save we walk each per-page canvas, transform every stored
///     path from canvas coords to page coords (Y-flip relative to the
///     page height), then build a standard `/Ink` PDFAnnotation via
///     PumiceCore's `InkAnnotationBuilder`. Replaces any previously-
///     written `/Ink` on each page so re-saves don't accumulate.
///   * On load we read each page's existing `/Ink` annotations, pull
///     the bezier path out, transform back from page coords to canvas
///     coords, and seed the per-page canvas via `setPaths(_:)`.
///     The `/Ink` annotations are then removed from the in-memory
///     document — the canvas is the sole source of truth until the
///     next save.
final class PDFReaderViewController: UIViewController {
    private let pdfView = PDFView()
    private var pdfURL: URL?
    private var needsSave = false

    private let overlayProvider = PumiceOverlayProvider()

    private let _undoManager = UndoManager()
    private let documentDelegate = PumicePDFDocumentDelegate()

    weak var controller: PDFReaderController?

    override var undoManager: UndoManager? { _undoManager }

    var canUndoChange: Bool { _undoManager.canUndo }
    var canRedoChange: Bool { _undoManager.canRedo }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configurePDFView()

        // Wire the overlay provider BEFORE any document is loaded.
        // Matches the working Cookiezby reference; setting it after
        // pdfView.document had no effect in past iterations.
        pdfView.pageOverlayViewProvider = overlayProvider
        pdfView.isInMarkupMode = true
        overlayProvider.onPathFinished = { [weak self] page, stroke in
            guard let self else { return }
            self.registerUndoForAddedStroke(stroke: stroke, on: page)
            self.needsSave = true
            self.controller?.refreshState()
            self.scheduleDebouncedSave()
        }
        overlayProvider.onEraserStroke = { [weak self] page, removedBatch in
            guard let self else { return }
            self.handleEraserBatch(removed: removedBatch, on: page)
            self.scheduleDebouncedSave()
        }
        overlayProvider.onHighlightStrokeFinished = { [weak self] page, first, last in
            guard let self else { return }
            self.handleHighlightStrokeFinished(first: first, last: last, on: page)
        }

        installUndoRedoGestures()
        installPencilInteraction()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        overlayProvider.syncActiveCanvases()
        saveIfNeeded()
    }

    func load(url: URL) {
        // Force viewDidLoad to run BEFORE we set the document.
        // SwiftUI's PDFReaderView calls load(url:) inside
        // makeUIViewController, before the view is in a hierarchy —
        // so without this nudge, viewDidLoad runs LATER and the
        // pageOverlayViewProvider gets wired AFTER PDFKit has already
        // parsed the document and decided it doesn't need overlays.
        // Touching `view` triggers the view-loading lifecycle
        // synchronously and runs viewDidLoad in line.
        _ = view

        pdfURL = url
        needsSave = false
        _undoManager.removeAllActions()
        overlayProvider.reset()
        controller?.refreshState()
        saveDebounceTimer?.invalidate()
        saveDebounceTimer = nil

        guard let document = PDFDocument(url: url) else { return }
        document.delegate = documentDelegate
        pdfView.document = document

        // Hydrate per-page strokes from any /Ink annotations already in
        // the file. We strip them from the model so they don't double-
        // up with what the canvas renders. Each annotation's color and
        // border width are preserved so re-saves don't flatten styling
        // back to a single palette.
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let inkAnnotations = page.annotations.filter { $0.type == "Ink" }
            let pageHeight = page.bounds(for: .mediaBox).height
            var canvasStrokes: [StrokeRecord] = []
            for ann in inkAnnotations {
                let color = ann.color
                let width = ann.border?.lineWidth ?? 2
                for pathInPage in ann.paths ?? [] {
                    let canvasPath = Self.canvasPath(fromPagePath: pathInPage, pageHeight: pageHeight)
                    canvasStrokes.append(StrokeRecord(path: canvasPath, color: color, width: width))
                }
            }
            if !canvasStrokes.isEmpty {
                overlayProvider.setStrokes(canvasStrokes, for: page)
            }
            for ann in inkAnnotations {
                page.removeAnnotation(ann)
            }
        }
    }

    func saveIfNeeded() {
        guard needsSave, let url = pdfURL, let document = pdfView.document else { return }
        overlayProvider.syncActiveCanvases()
        let snapshot = overlayProvider.allStrokes()
        for (page, strokes) in snapshot {
            for ann in page.annotations where ann.type == "Ink" {
                page.removeAnnotation(ann)
            }
            let pageIndex = document.index(for: page)
            let pageHeight = page.bounds(for: .mediaBox).height
            for stroke in strokes {
                guard let annotation = Self.inkAnnotation(
                    fromStroke: stroke,
                    pageIndex: pageIndex,
                    pageHeight: pageHeight
                ) else { continue }
                page.addAnnotation(annotation)
            }
        }

        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var writeSucceeded = false
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            writeSucceeded = document.write(to: coordinatedURL)
        }
        if writeSucceeded {
            needsSave = false
        }

        // Strip the `/Ink` annotations we just stamped into each page.
        // The canvas is the in-memory source of truth between saves —
        // leaving the saved `/Ink` on the page would cause PDFKit to
        // double-render every stroke (once via our PumiceInkAnnotation
        // subclass, once via the canvas's CAShapeLayer). The user
        // wouldn't see the duplicate while the canvas's stroke layer
        // sits on top, but the eraser would appear delayed: erasing
        // a stroke removes only the canvas layer; the PumiceInkAnnotation
        // underneath stays visible until the next save's re-strip.
        for (page, _) in snapshot {
            for ann in page.annotations where ann.type == "Ink" {
                page.removeAnnotation(ann)
            }
        }

        saveDebounceTimer?.invalidate()
        saveDebounceTimer = nil
    }

    // MARK: - Debounced autosave

    /// Pending 2-second timer to autosave after the last stroke. Each
    /// new stroke restarts the timer so a flurry of strokes doesn't
    /// trigger a save in the middle of drawing — only ~2s of pen
    /// inactivity fires the save. Matches Nutrient/PSPDFKit's
    /// recommendation of "save at natural pauses, never on a fixed
    /// interval."
    private var saveDebounceTimer: Timer?

    private func scheduleDebouncedSave() {
        saveDebounceTimer?.invalidate()
        saveDebounceTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.saveIfNeeded()
            }
        }
    }

    // MARK: - Tool settings

    func setPenColor(_ color: UIColor) {
        overlayProvider.setPenColor(color)
    }

    func setPenWidth(_ width: CGFloat) {
        overlayProvider.setPenWidth(width)
    }

    func setActiveTool(_ tool: Tool) {
        let mode: PumiceCanvasView.Mode
        switch tool {
        case .pen:         mode = .pen
        case .highlighter: mode = .highlighter
        case .eraser:      mode = .eraser
        }
        overlayProvider.setMode(mode)
    }

    func setHighlightColor(_ color: HighlightPenColor) {
        overlayProvider.setHighlightColor(color.uiColor)
    }

    func setHighlightWidth(_ width: CGFloat) {
        overlayProvider.setHighlightWidth(width)
    }

    // MARK: - Toolbar actions

    func undoLastChange() {
        _undoManager.undo()
        controller?.refreshState()
    }

    func redoLastChange() {
        _undoManager.redo()
        controller?.refreshState()
    }

    // MARK: - Stroke undo/redo

    /// Called from the overlay provider's onPathFinished closure right
    /// after a brand-new stroke lands in the stroke store. Registers
    /// the inverse (remove) as an undoable action; that action in turn
    /// registers its own inverse (re-add) on invocation, so the user
    /// can step through the full undo/redo chain.
    private func registerUndoForAddedStroke(stroke: StrokeRecord, on page: PDFPage) {
        _undoManager.registerUndo(withTarget: self) { target in
            target.performUndoRemoveStroke(stroke: stroke, on: page)
        }
    }

    private func performUndoRemoveStroke(stroke: StrokeRecord, on page: PDFPage) {
        overlayProvider.removeStroke(stroke, from: page)
        _undoManager.registerUndo(withTarget: self) { target in
            target.performRedoAddStroke(stroke: stroke, on: page)
        }
        needsSave = true
        controller?.refreshState()
    }

    private func performRedoAddStroke(stroke: StrokeRecord, on page: PDFPage) {
        overlayProvider.appendStroke(stroke, to: page)
        _undoManager.registerUndo(withTarget: self) { target in
            target.performUndoRemoveStroke(stroke: stroke, on: page)
        }
        needsSave = true
        controller?.refreshState()
    }

    // MARK: - Eraser

    /// Called when the eraser gesture finishes on a page's canvas.
    /// The canvas erased strokes in real-time as the gesture passed
    /// over them; here we just register an undoable batch so a single
    /// Undo restores all of them at once.
    private func handleEraserBatch(removed: [StrokeRecord], on page: PDFPage) {
        guard !removed.isEmpty else { return }
        _undoManager.registerUndo(withTarget: self) { target in
            target.performUndoRestoreStrokes(removed, on: page)
        }
        needsSave = true
        controller?.refreshState()
    }

    private func performUndoRestoreStrokes(_ strokes: [StrokeRecord], on page: PDFPage) {
        for stroke in strokes {
            overlayProvider.appendStroke(stroke, to: page)
        }
        _undoManager.registerUndo(withTarget: self) { target in
            target.performRedoEraseStrokes(strokes, on: page)
        }
        needsSave = true
        controller?.refreshState()
    }

    private func performRedoEraseStrokes(_ strokes: [StrokeRecord], on page: PDFPage) {
        for stroke in strokes {
            overlayProvider.removeStroke(stroke, from: page)
        }
        _undoManager.registerUndo(withTarget: self) { target in
            target.performUndoRestoreStrokes(strokes, on: page)
        }
        needsSave = true
        controller?.refreshState()
    }

    // MARK: - Highlighter

    /// Called when a highlighter gesture finishes. Converts the gesture
    /// endpoints from canvas (UIKit Y-down) to PDF user space (Y-up),
    /// asks PumiceCore to snap to the underlying text, and adds the
    /// resulting `/Highlight` annotation to the page. Silent no-op if
    /// no text underlies the gesture — we'd rather drop the stroke
    /// than draw freehand ink in the wrong tool mode.
    private func handleHighlightStrokeFinished(first: CGPoint, last: CGPoint, on page: PDFPage) {
        guard let document = pdfView.document else { return }
        let pageHeight = page.bounds(for: .mediaBox).height
        let firstPage = CGPoint(x: first.x, y: pageHeight - first.y)
        let lastPage = CGPoint(x: last.x, y: pageHeight - last.y)
        let pageIndex = document.index(for: page)
        let strokeColor = (controller?.highlightColor ?? .yellow).highlightColor.rgba

        guard let annotation = Self.buildSnapAnnotation(
            firstPagePoint: firstPage,
            lastPagePoint: lastPage,
            on: page,
            pageIndex: pageIndex,
            strokeColor: strokeColor
        ) else { return }

        page.addAnnotation(annotation)
        // iOS 26 PDFKit caches each page's rendering in a PDFPageView
        // subview of pdfView.documentView. setNeedsDisplay on the PDFView
        // (or documentView) does NOT propagate to those page-level
        // caches, so a freshly-added annotation isn't drawn until the
        // page is scrolled off and back. Invalidate the per-page
        // subview directly.
        forcePDFPageRedraw()

        registerUndoForAddedHighlight(annotation, on: page)
        needsSave = true
        controller?.refreshState()
        scheduleDebouncedSave()
    }

    /// Invalidate each PDFPageView's cached rendering so PDFKit will
    /// invoke `draw(with:in:)` on the next display tick. Without this,
    /// freshly-added annotations don't draw until the page is scrolled
    /// off-screen and back (on iOS 26). Called from
    /// `handleHighlightStrokeFinished` and from the undo/redo paths
    /// that add or remove highlights.
    private func forcePDFPageRedraw() {
        for sv in pdfView.documentView?.subviews ?? [] {
            if NSStringFromClass(type(of: sv)) == "PDFPageView" {
                sv.setNeedsDisplay()
                sv.layer.setNeedsDisplay()
            }
        }
    }

    private func registerUndoForAddedHighlight(_ annotation: PDFAnnotation, on page: PDFPage) {
        _undoManager.registerUndo(withTarget: self) { target in
            target.performUndoRemoveHighlight(annotation, on: page)
        }
    }

    private func performUndoRemoveHighlight(_ annotation: PDFAnnotation, on page: PDFPage) {
        page.removeAnnotation(annotation)
        forcePDFPageRedraw()
        _undoManager.registerUndo(withTarget: self) { target in
            target.performRedoAddHighlight(annotation, on: page)
        }
        needsSave = true
        controller?.refreshState()
        scheduleDebouncedSave()
    }

    private func performRedoAddHighlight(_ annotation: PDFAnnotation, on page: PDFPage) {
        page.addAnnotation(annotation)
        forcePDFPageRedraw()
        _undoManager.registerUndo(withTarget: self) { target in
            target.performUndoRemoveHighlight(annotation, on: page)
        }
        needsSave = true
        controller?.refreshState()
        scheduleDebouncedSave()
    }

    // MARK: - Gesture shortcuts

    /// Two-finger double-tap → undo. The three-finger swipe-left/right
    /// gestures Apple ships system-wide work for free because we
    /// override `undoManager` above; iOS finds it via the responder
    /// chain and invokes undo/redo without us installing recognizers.
    /// Earlier we ALSO installed our own three-finger swipe gestures,
    /// but those raced the system pair, producing
    /// `System gesture gate timed out` errors and steady main-thread
    /// stalls that visibly jammed the toolbar Menu's tap response.
    private func installUndoRedoGestures() {
        let undoTap = UITapGestureRecognizer(target: self, action: #selector(undoGestureFired))
        undoTap.numberOfTapsRequired = 2
        undoTap.numberOfTouchesRequired = 2
        view.addGestureRecognizer(undoTap)
    }

    @objc private func undoGestureFired() {
        undoLastChange()
    }

    // MARK: - Apple Pencil gestures

    /// Two `UIPencilInteraction` events, two distinct behaviors:
    ///   * **double-tap** (Pencil 2 or Pencil Pro side tap) alternates
    ///     between pen and highlighter — a quick way to flip between
    ///     freehand and snap-to-text without going through the menu.
    ///   * **squeeze-and-hold** (Pencil Pro only) sets the eraser for
    ///     as long as the squeeze is held; releasing the squeeze
    ///     restores whichever tool was active before. Lets the user
    ///     rub out a stray stroke mid-annotation and pop straight back
    ///     to drawing without touching the toolbar.
    ///
    /// We ignore the user's system-wide preferred-tap action — the
    /// toolbar Menu is always there as a fallback, and we want
    /// Pumice's gestures to be predictable across users.
    private func installPencilInteraction() {
        let interaction = UIPencilInteraction()
        interaction.delegate = self
        view.addInteraction(interaction)
    }

    // MARK: - Plumbing

    private func configurePDFView() {
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.usePageViewController(false)
        pdfView.backgroundColor = .systemGroupedBackground
        view.addSubview(pdfView)

        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: view.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    // MARK: - Coordinate transforms

    /// Transform a `UIBezierPath` from canvas (UIKit, Y-down) to page
    /// (PDF user space, Y-up) coordinates. Mirrors the path vertically
    /// around the page's height.
    static func pagePath(fromCanvasPath canvasPath: UIBezierPath, pageHeight: CGFloat) -> UIBezierPath {
        let copy = canvasPath.copy() as! UIBezierPath
        var t = CGAffineTransform.identity
        t = t.translatedBy(x: 0, y: pageHeight)
        t = t.scaledBy(x: 1, y: -1)
        copy.apply(t)
        return copy
    }

    static func canvasPath(fromPagePath pagePath: UIBezierPath, pageHeight: CGFloat) -> UIBezierPath {
        // The same transform is its own inverse.
        return self.pagePath(fromCanvasPath: pagePath, pageHeight: pageHeight)
    }

    /// Convert a `StrokeRecord` into a standard `/Ink` PDFAnnotation
    /// via PumiceCore's builder. Flattens the canvas-coord path's
    /// move/line elements into page-coord points — the builder smooths
    /// them into a curve internally — and carries the stroke's own
    /// color and width onto the annotation so per-stroke styling
    /// survives the round-trip.
    static func inkAnnotation(
        fromStroke stroke: StrokeRecord,
        pageIndex: Int,
        pageHeight: CGFloat
    ) -> PDFAnnotation? {
        let pagePath = self.pagePath(fromCanvasPath: stroke.path, pageHeight: pageHeight)
        var pagePoints: [CGPoint] = []
        pagePath.cgPath.applyWithBlock { ptr in
            let elem = ptr.pointee
            switch elem.type {
            case .moveToPoint, .addLineToPoint:
                pagePoints.append(elem.points[0])
            default:
                break
            }
        }
        guard pagePoints.count >= 2 else { return nil }
        return InkAnnotationBuilder.makeAnnotation(
            pagePoints: pagePoints,
            pageStrokeWidth: stroke.width,
            color: StrokeColor(uiColor: stroke.color),
            pageIndex: pageIndex,
            uuid: UUID()
        )
    }

    /// Snap-to-text builder kept around for the F03 integration tests
    /// and for V2 wiring. Not called from the live path in V1.
    static func buildSnapAnnotation(
        firstPagePoint: CGPoint,
        lastPagePoint: CGPoint,
        on page: PDFPage,
        pageIndex: Int,
        strokeColor: StrokeColor
    ) -> PDFAnnotation? {
        guard let selection = page.selection(from: firstPagePoint, to: lastPagePoint),
              let text = selection.string,
              !text.isEmpty
        else { return nil }

        let quads = PDFSelectionAdapter.quads(from: selection, on: page)
        guard !quads.isEmpty else { return nil }

        let highlight = Highlight(
            quads: quads,
            color: HighlightColor.closest(to: strokeColor),
            pageIndex: pageIndex,
            extractedText: text,
            attachedNote: nil
        )
        return HighlightAnnotationBuilder.makeAnnotation(highlight: highlight, uuid: UUID())
    }
}

extension PDFReaderViewController: UIPencilInteractionDelegate {
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        // Both Pencil 2 and Pencil Pro report the side double-tap
        // through this method. Alternate between pen and highlighter.
        controller?.alternatePenAndHighlighter()
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        // Pencil Pro only. Hold = eraser; release = previous tool.
        switch squeeze.phase {
        case .began:
            controller?.beginEraserHold()
        case .ended, .cancelled:
            controller?.endEraserHold()
        case .changed:
            // The squeeze is still being held; we already entered the
            // eraser on `.began`. Re-entering would be idempotent but
            // would also re-set `preEraserTool` if the user had
            // somehow flipped tools mid-squeeze; safest to no-op.
            break
        @unknown default:
            controller?.endEraserHold()
        }
    }
}

