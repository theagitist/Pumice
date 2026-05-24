import PDFKit
import PencilKit
import PumiceCore
import UIKit

/// Hosts a `PDFView` for browsing and a `PKCanvasView` overlay for Apple
/// Pencil annotation. Commits each completed stroke as a `/Subtype /Ink`
/// (or `/Subtype /Highlight` when it snaps to text) on the underlying page
/// via PumiceCore, then clears the canvas so PDFKit re-renders the
/// committed annotation from the document itself.
///
/// Canvas placement: the canvas is parented inside `PDFView.documentView`
/// rather than overlaid as a sibling. That way PDFView's own scroll gesture
/// handles finger pans without us needing any hitTest gymnastics — the
/// canvas just sets `drawingPolicy` to gate pencil vs. any-input drawing.
///
/// Editing toolbar (driven by `PDFReaderController`): undo / redo / delete
/// the currently selected annotation. All mutations go through
/// `addAnnotation` / `removeAnnotation` so the undo stack stays in sync.
///
/// Save lifecycle: dirty state is set on each commit; `saveIfNeeded()` is
/// invoked from `viewWillDisappear` (selection change, nav away) and from
/// SwiftUI's `scenePhase` observer (app backgrounding). F06's `.bak` +
/// hash-guarded atomic swap will replace the direct `PDFDocument.write`.
final class PDFReaderViewController: UIViewController {
    private let pdfView = PDFView()
    private let canvasView = PKCanvasView()
    private let toolPicker = PKToolPicker()
    private var pdfURL: URL?
    private var needsSave = false
    private var canvasAttached = false

    private let _undoManager = UndoManager()
    private var selectedAnnotation: PDFAnnotation?
    private var selectedAnnotationPage: PDFPage?

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
        toolPicker.setVisible(true, forFirstResponder: canvasView)
        toolPicker.addObserver(canvasView)
        canvasView.becomeFirstResponder()
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

        guard let document = PDFDocument(url: url) else { return }
        pdfView.document = document
        attachCanvasToDocumentViewIfNeeded()
    }

    func saveIfNeeded() {
        guard needsSave, let url = pdfURL, let document = pdfView.document else { return }
        if document.write(to: url) {
            needsSave = false
        }
    }

    func applyFingerMode(_ mode: FingerInputMode) {
        switch mode {
        case .scroll:
            canvasView.drawingPolicy = .pencilOnly
        case .draw:
            canvasView.drawingPolicy = .anyInput
        }
    }

    // MARK: - Annotation mutations (registered with UndoManager)

    func addAnnotation(_ annotation: PDFAnnotation, to page: PDFPage) {
        page.addAnnotation(annotation)
        needsSave = true
        _undoManager.registerUndo(withTarget: self) { target in
            target.removeAnnotation(annotation, from: page)
        }
        controller?.refreshState()
    }

    func removeAnnotation(_ annotation: PDFAnnotation, from page: PDFPage) {
        page.removeAnnotation(annotation)
        needsSave = true
        if selectedAnnotation === annotation {
            selectedAnnotation = nil
            selectedAnnotationPage = nil
        }
        _undoManager.registerUndo(withTarget: self) { target in
            target.addAnnotation(annotation, to: page)
        }
        controller?.refreshState()
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
        canvasView.drawingPolicy = .pencilOnly
        // The canvas lives inside PDFView's documentView, which is itself
        // inside the PDFView's scroll view. Disable the canvas's own
        // scroll/zoom so the parent's scrolling drives motion.
        canvasView.isScrollEnabled = false
        canvasView.minimumZoomScale = 1
        canvasView.maximumZoomScale = 1
        canvasView.delegate = self
    }

    /// Add `canvasView` as a subview of `pdfView.documentView` so finger
    /// touches naturally reach PDFView's scroll gesture and the canvas only
    /// intercepts pencil input (per `drawingPolicy`).
    private func attachCanvasToDocumentViewIfNeeded() {
        // documentView isn't always available immediately after setting
        // pdfView.document — PDFView lays it out on the next runloop tick.
        // Retry until it's ready.
        guard let docView = pdfView.documentView else {
            DispatchQueue.main.async { [weak self] in
                self?.attachCanvasToDocumentViewIfNeeded()
            }
            return
        }
        canvasView.removeFromSuperview()
        docView.addSubview(canvasView)
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            canvasView.topAnchor.constraint(equalTo: docView.topAnchor),
            canvasView.bottomAnchor.constraint(equalTo: docView.bottomAnchor),
            canvasView.leadingAnchor.constraint(equalTo: docView.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: docView.trailingAnchor)
        ])
        canvasAttached = true
    }

    // MARK: - Stroke commit

    private func commitStrokesAndClear() {
        guard let documentView = pdfView.documentView,
              let document = pdfView.document else { return }

        let strokes = canvasView.drawing.strokes
        guard !strokes.isEmpty else { return }

        var committed = false
        for pkStroke in strokes {
            if commit(pkStroke: pkStroke, documentView: documentView, document: document) {
                committed = true
            }
        }

        // Clear on the next runloop tick. Mutating PKCanvasView.drawing
        // synchronously inside the delegate callback trips PencilKit's
        // "Drawing count mismatch!" internal invariant (and corrupts
        // subsequent strokes — the symptom we saw on hardware was that
        // earlier annotations got dropped after a couple of strokes).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.canvasView.drawing = PKDrawing()
            if committed {
                self.pdfView.setNeedsDisplay()
            }
        }
    }

    private func commit(
        pkStroke: PKStroke,
        documentView: UIView,
        document: PDFDocument
    ) -> Bool {
        let canvasBounds = pkStroke.renderBounds
        let canvasCenter = CGPoint(x: canvasBounds.midX, y: canvasBounds.midY)
        let centerInPDFView = documentView.convert(canvasCenter, to: pdfView)
        guard let page = pdfView.page(for: centerInPDFView, nearest: true) else {
            return false
        }
        let pageIndex = document.index(for: page)

        var pagePoints: [CGPoint] = []
        pagePoints.reserveCapacity(pkStroke.path.count)
        var widthSum: CGFloat = 0
        var widthCount = 0
        for point in pkStroke.path {
            let inPDFView = documentView.convert(point.location, to: pdfView)
            let inPage = pdfView.convert(inPDFView, to: page)
            pagePoints.append(inPage)
            widthSum += (point.size.width + point.size.height) / 2
            widthCount += 1
        }
        guard widthCount > 0,
              let first = pagePoints.first,
              let last = pagePoints.last
        else { return false }
        let width = widthSum / CGFloat(widthCount)
        let strokeColor = StrokeColor(uiColor: pkStroke.ink.color)

        if let snapAnnotation = Self.buildSnapAnnotation(
            firstPagePoint: first,
            lastPagePoint: last,
            on: page,
            pageIndex: pageIndex,
            strokeColor: strokeColor
        ) {
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
        addAnnotation(inkAnnotation, to: page)
        return true
    }

    /// Pure builder for snap-to-text highlights: resolves the pencil
    /// gesture's endpoints to a `PDFSelection` and returns the corresponding
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
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        guard canvasView.tool is PKInkingTool else {
            DispatchQueue.main.async { [weak self] in
                self?.canvasView.drawing = PKDrawing()
            }
            return
        }
        commitStrokesAndClear()
    }
}
