import PDFKit
import PencilKit
import PumiceCore
import UIKit

/// `PKCanvasView` subclass with an "Apple Pencil only" hit-test mode.
///
/// When `requirePencilForHit == true`, the canvas claims a touch only when
/// the current event contains an Apple Pencil touch — finger touches fall
/// through to the view underneath (PDFView's scroll gesture). Otherwise
/// the canvas claims everything in its bounds.
private final class ModalCanvasView: PKCanvasView {
    var requirePencilForHit: Bool = false

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if requirePencilForHit {
            guard let event,
                  let touches = event.allTouches,
                  touches.contains(where: { $0.type == .pencil })
            else { return nil }
        }
        return super.hitTest(point, with: event)
    }
}

/// Hosts a `PDFView` for browsing and a `PKCanvasView` overlay for
/// annotation. Commits each completed stroke as a `/Subtype /Ink` (or
/// `/Subtype /Highlight` when it snaps to text) on the underlying page via
/// PumiceCore.
///
/// Input model (no mode switch — finger always scrolls, pencil always draws):
///   * Default: canvas is interactive with `drawingPolicy = .pencilOnly`
///     and `requirePencilForHit = true`. The Pencil draws and snaps to
///     text; finger touches pass through the canvas to PDFView for scroll
///     and annotation taps. This is the PRD's headline UX.
///   * `allowFingerDrawing = true` (for users without a Pencil): canvas
///     claims all touches with `drawingPolicy = .anyInput`. Finger draws,
///     PDFView doesn't get touches and doesn't scroll while this is on.
///
/// Commit model: PencilKit hates having its drawing mutated while a
/// stroke is still being finalized or while the user might already be
/// starting the next one. So commit happens at every
/// `canvasViewDidEndUsingTool`, but the canvas is cleared lazily —
/// `scheduleCanvasClear()` queues a `DispatchWorkItem` 300 ms in the
/// future, and the canvas's `onTouchStarted` callback cancels that
/// queued item the moment the user begins another stroke. When the user
/// pauses, the work item fires, the canvas empties, and PDFKit's
/// rendering of the just-committed `/Ink` (or `/Highlight`) annotations
/// takes over — those scroll naturally with their pages.
///
/// Editing toolbar (driven by `PDFReaderController`): undo / redo / delete
/// the currently selected annotation. All mutations go through
/// `addAnnotation` / `removeAnnotation` so the undo stack stays in sync.
///
/// Save lifecycle: dirty state is set on each commit; `saveIfNeeded()` is
/// invoked from `viewWillDisappear` and from SwiftUI's `scenePhase`
/// observer (app backgrounding). F06's `.bak` + hash-guarded atomic swap
/// will replace the direct `PDFDocument.write`.
final class PDFReaderViewController: UIViewController {
    private let pdfView = PDFView()
    private let canvasView = ModalCanvasView()
    private let toolPicker = PKToolPicker()
    private var pdfURL: URL?
    private var needsSave = false
    private var committedStrokeCount = 0
    private var clearWorkItem: DispatchWorkItem?

    private let _undoManager = UndoManager()
    private var selectedAnnotation: PDFAnnotation?
    private var selectedAnnotationPage: PDFPage?
    private var pendingAnnotationsSinceLastRender = false

    weak var controller: PDFReaderController?

    override var undoManager: UndoManager? { _undoManager }

    var canUndoChange: Bool { _undoManager.canUndo }
    var canRedoChange: Bool { _undoManager.canRedo }
    var hasSelectedAnnotation: Bool { selectedAnnotation != nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        configurePDFView()
        configureCanvas()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(annotationWasHit(_:)),
            name: .PDFViewAnnotationHit,
            object: pdfView
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        toolPicker.addObserver(canvasView)
        updateToolPickerVisibility()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        toolPicker.setVisible(false, forFirstResponder: canvasView)
        toolPicker.removeObserver(canvasView)
        saveIfNeeded()
    }

    func load(url: URL) {
        pdfURL = url
        needsSave = false
        _undoManager.removeAllActions()
        selectedAnnotation = nil
        selectedAnnotationPage = nil
        controller?.refreshState()

        // Reset the canvas. This is safe at load time because no stroke
        // is in progress — `load` runs from the SwiftUI representable's
        // make/update path, not from within PencilKit delegate callbacks.
        clearWorkItem?.cancel()
        clearWorkItem = nil
        canvasView.drawing = PKDrawing()
        committedStrokeCount = 0

        guard let document = PDFDocument(url: url) else { return }
        pdfView.document = document
    }

    func saveIfNeeded() {
        guard needsSave, let url = pdfURL, let document = pdfView.document else { return }
        if document.write(to: url) {
            needsSave = false
        }
    }

    func applyAllowFingerDrawing(_ allow: Bool) {
        canvasView.isUserInteractionEnabled = true
        canvasView.requirePencilForHit = !allow
        canvasView.drawingPolicy = allow ? .anyInput : .pencilOnly
        updateToolPickerVisibility()
    }

    private func updateToolPickerVisibility() {
        if canvasView.isUserInteractionEnabled {
            canvasView.becomeFirstResponder()
            toolPicker.setVisible(true, forFirstResponder: canvasView)
        } else {
            toolPicker.setVisible(false, forFirstResponder: canvasView)
        }
    }

    // MARK: - Annotation mutations (registered with UndoManager)

    func addAnnotation(_ annotation: PDFAnnotation, to page: PDFPage) {
        page.addAnnotation(annotation)
        needsSave = true
        pendingAnnotationsSinceLastRender = true
        _undoManager.registerUndo(withTarget: self) { target in
            target.removeAnnotation(annotation, from: page)
        }
        controller?.refreshState()
    }

    func removeAnnotation(_ annotation: PDFAnnotation, from page: PDFPage) {
        page.removeAnnotation(annotation)
        needsSave = true
        pendingAnnotationsSinceLastRender = true
        if selectedAnnotation === annotation {
            selectedAnnotation = nil
            selectedAnnotationPage = nil
        }
        _undoManager.registerUndo(withTarget: self) { target in
            target.addAnnotation(annotation, to: page)
        }
        controller?.refreshState()
    }

    /// Force PDFKit to render the annotations we just added. iOS 26
    /// PDFKit only synthesizes the `/AP` appearance stream PDFKit
    /// itself needs to render `/Ink` and `/Highlight` annotations
    /// when the document is **written to disk**. The in-memory
    /// `dataRepresentation()` path does NOT generate `/AP`, even
    /// though it does preserve the annotation data — so the reloaded
    /// document parses cleanly but stays invisible.
    ///
    /// Workaround: write the current document to a temp file (forces
    /// `/AP` generation), then reload from that file. The user's
    /// vault PDF is left untouched — that's F06's job, with its own
    /// `.bak` + hash-guarded atomic rename. The temp file is cleaned
    /// up immediately.
    ///
    /// Viewport state (page index, top-left page point, scaleFactor)
    /// is captured before the swap and restored after, with
    /// `autoScales` disabled so PDFKit doesn't snap to a fit scale.
    ///
    /// Cost: undo stack resets because the old `PDFPage` and
    /// `PDFAnnotation` references no longer belong to the document.
    /// This is acceptable — undo is per-drawing-session, and the
    /// roundtrip only fires after 2 s of pen-idle (via the canvas
    /// idle clear).
    private func reloadDocumentInMemoryToRender() {
        guard pendingAnnotationsSinceLastRender,
              let document = pdfView.document
        else { return }
        print("[Pumice] reloadDocumentInMemoryToRender: starting")

        // Capture viewport state BEFORE swapping documents.
        let visiblePage = pdfView.currentPage
        let visiblePageIndex = visiblePage.map { document.index(for: $0) } ?? 0
        let viewportTopLeftInPage: CGPoint? = visiblePage.map { page in
            pdfView.convert(CGPoint(x: pdfView.bounds.minX, y: pdfView.bounds.minY),
                            to: page)
        }
        let savedScale = pdfView.scaleFactor

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pumice-roundtrip-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        guard document.write(to: tmpURL) else {
            print("[Pumice] reloadDocumentInMemoryToRender: write to tmp failed")
            return
        }
        guard let reloaded = PDFDocument(url: tmpURL) else {
            print("[Pumice] reloadDocumentInMemoryToRender: reload from tmp failed")
            return
        }

        pdfView.autoScales = false
        pdfView.document = reloaded
        pdfView.scaleFactor = savedScale

        if visiblePageIndex < reloaded.pageCount,
           let newPage = reloaded.page(at: visiblePageIndex),
           let topLeft = viewportTopLeftInPage {
            pdfView.go(to: PDFDestination(page: newPage, at: topLeft))
        }

        var totalInk = 0
        var totalHighlight = 0
        for i in 0..<reloaded.pageCount {
            if let p = reloaded.page(at: i) {
                for a in p.annotations {
                    switch a.type {
                    case "Ink": totalInk += 1
                    case "Highlight": totalHighlight += 1
                    default: break
                    }
                }
            }
        }
        let tmpSize = (try? FileManager.default.attributesOfItem(atPath: tmpURL.path)[.size] as? Int) ?? -1
        print("[Pumice] reloadDocumentInMemoryToRender: done via tmp \(tmpSize) bytes, post-reload counts ink=\(totalInk) highlight=\(totalHighlight)")

        _undoManager.removeAllActions()
        selectedAnnotation = nil
        selectedAnnotationPage = nil
        controller?.refreshState()
        pendingAnnotationsSinceLastRender = false
    }

    func deleteSelectedAnnotation() {
        guard let annotation = selectedAnnotation,
              let page = selectedAnnotationPage else { return }
        removeAnnotation(annotation, from: page)
    }

    func undoLastChange() {
        _undoManager.undo()
        controller?.refreshState()
    }

    func redoLastChange() {
        _undoManager.redo()
        controller?.refreshState()
    }

    // MARK: - Annotation selection

    @objc private func annotationWasHit(_ notification: Notification) {
        guard let hit = notification.userInfo?["PDFAnnotationHit"] as? PDFAnnotation else {
            return
        }
        if selectedAnnotation === hit {
            clearSelection()
            return
        }
        selectedAnnotation = hit
        selectedAnnotationPage = hit.page
        controller?.refreshState()
    }

    private func clearSelection() {
        selectedAnnotation = nil
        selectedAnnotationPage = nil
        controller?.refreshState()
    }

    // MARK: - View setup

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

    private func configureCanvas() {
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.drawingPolicy = .anyInput
        canvasView.isScrollEnabled = false
        canvasView.minimumZoomScale = 1
        canvasView.maximumZoomScale = 1
        canvasView.delegate = self
        view.addSubview(canvasView)

        NSLayoutConstraint.activate([
            canvasView.topAnchor.constraint(equalTo: view.topAnchor),
            canvasView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            canvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    // MARK: - Stroke commit

    private func commitNewStrokes() {
        guard let document = pdfView.document else {
            print("[Pumice] commitNewStrokes: no document, bail")
            return
        }
        let allStrokes = canvasView.drawing.strokes
        let toolName = String(describing: type(of: canvasView.tool))
        print("[Pumice] commitNewStrokes: tool=\(toolName) strokes=\(allStrokes.count) committed=\(committedStrokeCount)")

        // The user might have used the eraser or lasso (whose tool-end
        // callbacks also reach us here). Re-syncing the counter to the
        // current stroke count covers all of "ink added", "strokes erased",
        // and "no change".
        defer { committedStrokeCount = allStrokes.count }

        guard canvasView.tool is PKInkingTool else {
            print("[Pumice] commitNewStrokes: tool is not PKInkingTool, skipping commit")
            return
        }
        guard allStrokes.count > committedStrokeCount else {
            print("[Pumice] commitNewStrokes: no new strokes since last commit")
            return
        }

        let newStrokes = Array(allStrokes.dropFirst(committedStrokeCount))
        for (i, pkStroke) in newStrokes.enumerated() {
            let ok = commit(pkStroke: pkStroke, document: document)
            print("[Pumice] commitNewStrokes: stroke[\(i)] committed=\(ok)")
        }
    }

    /// Schedule a canvas clear in the future. Cancelled by the next
    /// stroke if the user is mid-session; otherwise fires after the
    /// pause and PDFKit's `/Ink`/`/Highlight` annotations take over
    /// rendering — which then scroll with their pages instead of
    /// floating over the static canvas.
    ///
    /// Delay temporarily bumped to 2 s while we diagnose the
    /// "stroke vanishes right after pen lift" bug — long enough for the
    /// user to visually verify whether the PDF annotation appears
    /// underneath the live stroke before the clear happens.
    private func scheduleCanvasClear() {
        clearWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.clearCanvasIfIdle()
        }
        clearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func clearCanvasIfIdle() {
        print("[Pumice] clearCanvasIfIdle: wiping canvas after delay")
        // Reload the document in-memory FIRST so PDFKit gets the
        // appearance streams it needs to render the new annotations.
        // Then wipe the canvas so the live strokes hand off cleanly to
        // the now-rendered PDF annotations.
        reloadDocumentInMemoryToRender()
        canvasView.drawing = PKDrawing()
        committedStrokeCount = 0
    }

    private func commit(pkStroke: PKStroke, document: PDFDocument) -> Bool {
        // Convert via window coordinates instead of canvas→pdfView
        // directly: PKCanvasView is a UIScrollView subclass and its
        // bounds.origin == contentOffset, which can subtly shift the
        // direct conversion. Window coords are unambiguous.
        let canvasBounds = pkStroke.renderBounds
        let canvasCenter = CGPoint(x: canvasBounds.midX, y: canvasBounds.midY)
        let centerInWindow = canvasView.convert(canvasCenter, to: nil)
        let centerInPDFView = pdfView.convert(centerInWindow, from: nil)
        print("[Pumice] commit: canvasCenter=\(canvasCenter) inPDFView=\(centerInPDFView) canvasBounds.origin=\(canvasView.bounds.origin) pdfViewBounds=\(pdfView.bounds)")

        guard let page = pdfView.page(for: centerInPDFView, nearest: true) else {
            print("[Pumice] commit: no page at center, bail")
            return false
        }
        let pageIndex = document.index(for: page)

        var pagePoints: [CGPoint] = []
        pagePoints.reserveCapacity(pkStroke.path.count)
        var widthSum: CGFloat = 0
        var widthCount = 0
        for point in pkStroke.path {
            let inWindow = canvasView.convert(point.location, to: nil)
            let inPDFView = pdfView.convert(inWindow, from: nil)
            let inPage = pdfView.convert(inPDFView, to: page)
            pagePoints.append(inPage)
            widthSum += (point.size.width + point.size.height) / 2
            widthCount += 1
        }
        guard widthCount > 0,
              let first = pagePoints.first,
              let last = pagePoints.last
        else {
            print("[Pumice] commit: empty path, bail")
            return false
        }
        let width = widthSum / CGFloat(widthCount)
        let strokeColor = StrokeColor(uiColor: pkStroke.ink.color)

        // Only attempt snap-to-text when the gesture is clearly
        // horizontal — a highlight is a swipe along a line, not a
        // vertical scribble or a tight curl. Without this filter
        // PDFKit's `selection(from:to:)` happily returns text that
        // sits between any two arbitrary page points, so margin
        // doodles end up converted to single-line highlights at the
        // nearest text row.
        if isHorizontalDominant(pagePoints: pagePoints),
           let snapAnnotation = Self.buildSnapAnnotation(
               firstPagePoint: first,
               lastPagePoint: last,
               on: page,
               pageIndex: pageIndex,
               strokeColor: strokeColor
           ) {
            print("[Pumice] commit: snap-to-text highlight, page=\(pageIndex) bounds=\(snapAnnotation.bounds)")
            addAnnotation(snapAnnotation, to: page)
            return true
        }

        let inkAnnotation = InkAnnotationBuilder.makeAnnotation(
            pagePoints: pagePoints,
            pageStrokeWidth: width,
            color: strokeColor,
            pageIndex: pageIndex,
            uuid: UUID()
        )
        print("[Pumice] commit: ink annotation, page=\(pageIndex) bounds=\(inkAnnotation.bounds) width=\(width) first=\(first) last=\(last)")
        addAnnotation(inkAnnotation, to: page)
        return true
    }

    /// Returns true when the gesture is wide enough and shallow enough
    /// to plausibly be a highlight swipe across a single text line.
    /// Threshold: bounding-box width must be ≥ 2× height AND at least
    /// 30 pt wide. Empirically rejects vertical scribbles, tight curls,
    /// and tiny dots while accepting normal "underline this phrase"
    /// motions.
    private func isHorizontalDominant(pagePoints: [CGPoint]) -> Bool {
        guard pagePoints.count >= 2 else { return false }
        var minX = pagePoints[0].x
        var maxX = pagePoints[0].x
        var minY = pagePoints[0].y
        var maxY = pagePoints[0].y
        for p in pagePoints.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let width = maxX - minX
        let height = maxY - minY
        let horizontal = width >= max(30, height * 2)
        if !horizontal {
            print("[Pumice] snap rejected: width=\(width) height=\(height) (not horizontal-dominant)")
        }
        return horizontal
    }

    /// Pure builder for snap-to-text highlights: resolves the gesture's
    /// endpoints to a `PDFSelection` and returns the corresponding
    /// `PDFAnnotation`, or `nil` if no text is under the gesture. Doesn't
    /// mutate the page — the caller is responsible for adding the annotation
    /// (typically via `addAnnotation` so the undo stack records it).
    ///
    /// Exposed as static so iOS integration tests can drive it without
    /// instantiating a live view controller.
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

extension PDFReaderViewController: PKCanvasViewDelegate {
    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        // The user has started a new stroke. Cancel any pending canvas
        // clear so PencilKit's drawing isn't yanked out from under them.
        // PencilKit routes drawing touches through its own gesture
        // pipeline, so UIResponder's `touchesBegan` doesn't fire here —
        // this delegate method is the reliable signal.
        clearWorkItem?.cancel()
        clearWorkItem = nil
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        commitNewStrokes()
        scheduleCanvasClear()
    }
}
