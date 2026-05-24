import PDFKit
import PencilKit
import PumiceCore
import UIKit

/// `PKCanvasView` subclass that supports an "Apple Pencil only" hit-test
/// mode. In that mode the canvas claims a touch only when the current
/// event contains an Apple Pencil touch — finger touches fall through to
/// the view sitting underneath (PDFView's scroll gesture). In the
/// default mode the canvas claims everything in its bounds, like a stock
/// `PKCanvasView`.
private final class ModalCanvasView: PKCanvasView {
    /// When `true`, hit-test passes through any touch event that doesn't
    /// contain an Apple Pencil touch.
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
/// Input modes (`PDFReaderController.fingerMode`):
///   * Read: canvas is `userInteractionEnabled = false`. Every touch flows
///     to PDFView — finger and pencil both scroll, annotation taps select.
///   * Pencil: canvas is interactive with `drawingPolicy = .pencilOnly`
///     and `requirePencilForHit = true`. Pencil touches are routed to the
///     canvas for drawing; finger touches pass through the canvas to
///     PDFView for scrolling. This is the PRD's headline UX.
///   * Draw: canvas claims all touches with `drawingPolicy = .anyInput`.
///     Both finger and pencil draw / snap to text; PDFView doesn't get
///     touches and doesn't scroll.
///
/// Commit model: strokes are *not* removed from the canvas after they're
/// committed to PDFKit. Doing that synchronously breaks PencilKit's
/// internal stroke bookkeeping (drawing-count-mismatch faults, lost
/// strokes), and doing it asynchronously races with the next stroke that
/// the user may already be starting. Instead we track how many strokes
/// have been committed (`committedStrokeCount`) and only convert the new
/// ones each time `canvasViewDidEndUsingTool` fires. The committed strokes
/// stay rendered by the canvas and are also rendered by PDFKit from their
/// `/Ink` annotations underneath — visually the user just sees one stroke
/// at each location.
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

    func applyFingerMode(_ mode: FingerInputMode) {
        switch mode {
        case .scroll:
            canvasView.isUserInteractionEnabled = false
        case .pencil:
            canvasView.isUserInteractionEnabled = true
            canvasView.requirePencilForHit = true
            canvasView.drawingPolicy = .pencilOnly
        case .draw:
            canvasView.isUserInteractionEnabled = true
            canvasView.requirePencilForHit = false
            canvasView.drawingPolicy = .anyInput
        }
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
        canvasView.drawingPolicy = .anyInput
        canvasView.isScrollEnabled = false
        canvasView.minimumZoomScale = 1
        canvasView.maximumZoomScale = 1
        canvasView.delegate = self
        canvasView.isUserInteractionEnabled = false // Read is the default.
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
        guard let document = pdfView.document else { return }
        let allStrokes = canvasView.drawing.strokes
        // The user might have used the eraser or lasso (whose tool-end
        // callbacks also reach us here). Re-syncing the counter to the
        // current stroke count covers all of "ink added", "strokes erased",
        // and "no change".
        defer { committedStrokeCount = allStrokes.count }

        guard canvasView.tool is PKInkingTool,
              allStrokes.count > committedStrokeCount else { return }

        let newStrokes = Array(allStrokes.dropFirst(committedStrokeCount))
        for pkStroke in newStrokes {
            _ = commit(pkStroke: pkStroke, document: document)
        }
    }

    private func commit(pkStroke: PKStroke, document: PDFDocument) -> Bool {
        let canvasBounds = pkStroke.renderBounds
        let canvasCenter = CGPoint(x: canvasBounds.midX, y: canvasBounds.midY)
        let centerInPDFView = canvasView.convert(canvasCenter, to: pdfView)
        guard let page = pdfView.page(for: centerInPDFView, nearest: true) else {
            return false
        }
        let pageIndex = document.index(for: page)

        var pagePoints: [CGPoint] = []
        pagePoints.reserveCapacity(pkStroke.path.count)
        var widthSum: CGFloat = 0
        var widthCount = 0
        for point in pkStroke.path {
            let inPDFView = canvasView.convert(point.location, to: pdfView)
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
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        commitNewStrokes()
    }
}
