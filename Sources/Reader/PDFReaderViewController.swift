import PDFKit
import PencilKit
import PumiceCore
import UIKit

/// `PKCanvasView` subclass with an "Apple Pencil only" hit-test mode.
/// When `requirePencilForHit == true`, the canvas claims a touch only
/// when the current event contains an Apple Pencil touch — finger
/// touches fall through to PDFView's scroll gesture.
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

/// PDFView host that uses Apple's official per-page overlay API
/// (`PDFPageOverlayViewProvider`, iOS 16+, recommended by the PencilKit
/// team at WWDC22 "What's new in PDFKit"). Each visible PDF page gets
/// its own `PKCanvasView` installed by PDFKit, auto-sized to the page
/// and scrolling/zooming with the page.
///
/// Per-page drawing state lives in `drawingForPage` (keyed by `PDFPage`).
/// When a page scrolls out of view PDFKit calls
/// `willEndDisplayingOverlayView`; we stash the canvas's `PKDrawing`
/// there and let PDFKit release the view. When the page comes back in,
/// `overlayViewFor` creates a fresh canvas and we re-install the
/// stashed drawing.
///
/// Persistence: at save time we walk `drawingForPage`, replace any of
/// our previously-written `/Ink` annotations on the page with fresh
/// ones derived from the current `PKDrawing`, then `document.write(to:)`.
/// Other PDF readers (Preview, Acrobat) render the saved `/Ink`
/// correctly; iOS PDFView's annotation rendering is famously
/// unreliable, which is exactly why we use the live `PKCanvasView`
/// overlay instead of trusting PDFKit's annotation renderer.
/// On load, existing `/Ink` annotations are reconstituted as
/// `PKStroke`s and pushed into the per-page `PKDrawing`, then the
/// `/Ink` annotations are removed from the model — the canvas drawing
/// is the sole source of truth until the next save.
///
/// Input model: pencil always draws, finger always scrolls. The
/// per-page canvas uses `requirePencilForHit = true` so finger touches
/// pass through to PDFView's scroll/tap gestures. A single
/// `allowFingerDrawing` toggle (driven from the toolbar) flips the
/// canvases to `.anyInput` for users without a Pencil.
final class PDFReaderViewController: UIViewController {
    private let pdfView = PDFView()
    private let toolPicker = PKToolPicker()
    private var pdfURL: URL?
    private var needsSave = false

    private var drawingForPage: [PDFPage: PKDrawing] = [:]
    private var canvasByPage: [PDFPage: ModalCanvasView] = [:]

    private let _undoManager = UndoManager()
    private var selectedAnnotation: PDFAnnotation?
    private var selectedAnnotationPage: PDFPage?
    private var allowFingerDrawing = false

    weak var controller: PDFReaderController?

    override var undoManager: UndoManager? { _undoManager }

    var canUndoChange: Bool { _undoManager.canUndo }
    var canRedoChange: Bool { _undoManager.canRedo }
    var hasSelectedAnnotation: Bool { selectedAnnotation != nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configurePDFView()
        pdfView.pageOverlayViewProvider = self

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(annotationWasHit(_:)),
            name: .PDFViewAnnotationHit,
            object: pdfView
        )
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Drain any visible canvases into our per-page store BEFORE save —
        // willEndDisplayingOverlayView only fires when a page scrolls out
        // of view, not when the reader is closed mid-stream.
        syncActiveCanvases()
        saveIfNeeded()
    }

    func load(url: URL) {
        pdfURL = url
        needsSave = false
        _undoManager.removeAllActions()
        selectedAnnotation = nil
        selectedAnnotationPage = nil
        drawingForPage.removeAll()
        canvasByPage.removeAll()
        controller?.refreshState()

        guard let document = PDFDocument(url: url) else { return }
        pdfView.document = document

        // Hydrate per-page PKDrawing from existing /Ink annotations and
        // strip those /Ink annotations from the model — the canvas
        // drawing is the source of truth until next save.
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let inkAnnotations = page.annotations.filter { $0.type == "Ink" }
            let strokes = inkAnnotations.compactMap { Self.pkStroke(from: $0) }
            if !strokes.isEmpty {
                drawingForPage[page] = PKDrawing(strokes: strokes)
            }
            for ann in inkAnnotations {
                page.removeAnnotation(ann)
            }
        }
        print("[Pumice] load: \(drawingForPage.count) pages with prior strokes")
    }

    func saveIfNeeded() {
        guard needsSave, let url = pdfURL, let document = pdfView.document else { return }
        syncActiveCanvases()
        for (page, drawing) in drawingForPage {
            for ann in page.annotations where ann.type == "Ink" {
                page.removeAnnotation(ann)
            }
            let pageIndex = document.index(for: page)
            for stroke in drawing.strokes {
                if let annotation = Self.inkAnnotation(from: stroke, pageIndex: pageIndex) {
                    page.addAnnotation(annotation)
                }
            }
        }
        if document.write(to: url) {
            needsSave = false
            print("[Pumice] save: wrote \(drawingForPage.count) page-drawings to \(url.lastPathComponent)")
        }
    }

    func applyAllowFingerDrawing(_ allow: Bool) {
        allowFingerDrawing = allow
        let policy: PKCanvasViewDrawingPolicy = allow ? .anyInput : .pencilOnly
        for canvas in canvasByPage.values {
            canvas.drawingPolicy = policy
            canvas.requirePencilForHit = !allow
        }
    }

    // MARK: - Annotation toolbar actions

    func deleteSelectedAnnotation() {
        guard let annotation = selectedAnnotation,
              let page = selectedAnnotationPage else { return }
        page.removeAnnotation(annotation)
        selectedAnnotation = nil
        selectedAnnotationPage = nil
        needsSave = true
        controller?.refreshState()
    }

    func undoLastChange() {
        _undoManager.undo()
        controller?.refreshState()
    }

    func redoLastChange() {
        _undoManager.redo()
        controller?.refreshState()
    }

    @objc private func annotationWasHit(_ notification: Notification) {
        guard let hit = notification.userInfo?["PDFAnnotationHit"] as? PDFAnnotation else {
            return
        }
        if selectedAnnotation === hit {
            selectedAnnotation = nil
            selectedAnnotationPage = nil
        } else {
            selectedAnnotation = hit
            selectedAnnotationPage = hit.page
        }
        controller?.refreshState()
    }

    // MARK: - Plumbing

    private func syncActiveCanvases() {
        for (page, canvas) in canvasByPage {
            drawingForPage[page] = canvas.drawing
        }
    }

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

    // MARK: - PKStroke <-> /Ink conversion

    /// Reconstitute a `PKStroke` from a `/Ink` annotation by extracting
    /// every move/line control point from each subpath of the bezier
    /// path. Pressure / tilt / azimuth aren't stored in `/Ink` and are
    /// reconstructed as constants — the PRD accepts this loss to keep
    /// round-trip editability.
    static func pkStroke(from annotation: PDFAnnotation) -> PKStroke? {
        guard let paths = annotation.paths, !paths.isEmpty else { return nil }
        let color = annotation.color
        let strokeWidth = annotation.border?.lineWidth ?? 2

        var controlPoints: [PKStrokePoint] = []
        for bezier in paths {
            bezier.cgPath.applyWithBlock { elementPtr in
                let elem = elementPtr.pointee
                switch elem.type {
                case .moveToPoint, .addLineToPoint:
                    let location = elem.points[0]
                    let point = PKStrokePoint(
                        location: location,
                        timeOffset: 0,
                        size: CGSize(width: strokeWidth, height: strokeWidth),
                        opacity: 1,
                        force: 1,
                        azimuth: 0,
                        altitude: 0
                    )
                    controlPoints.append(point)
                default:
                    break
                }
            }
        }
        guard controlPoints.count >= 2 else { return nil }
        let path = PKStrokePath(controlPoints: controlPoints, creationDate: Date())
        let ink = PKInk(.pen, color: color)
        return PKStroke(ink: ink, path: path)
    }

    /// Pure builder for snap-to-text highlights: resolves a gesture's
    /// endpoints to a `PDFSelection` and returns the corresponding
    /// `/Highlight` `PDFAnnotation`, or `nil` if no text lies between
    /// the points. Doesn't mutate the page — exposed as static so the
    /// iOS integration tests can drive it without a live view
    /// controller, and so the future snap-to-text re-integration has a
    /// single shared implementation.
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

    /// Convert a `PKStroke` into a standard `/Ink` PDFAnnotation. The
    /// canvas's bounds equal the page's bounds (PDFKit's overlay API
    /// sizes the canvas to the page), so stroke point locations are
    /// already in page coordinates — no conversion needed.
    static func inkAnnotation(from stroke: PKStroke, pageIndex: Int) -> PDFAnnotation? {
        var pagePoints: [CGPoint] = []
        var widthSum: CGFloat = 0
        var widthCount = 0
        for point in stroke.path {
            pagePoints.append(point.location)
            widthSum += (point.size.width + point.size.height) / 2
            widthCount += 1
        }
        guard widthCount > 0 else { return nil }
        let width = widthSum / CGFloat(widthCount)
        let color = StrokeColor(uiColor: stroke.ink.color)
        return InkAnnotationBuilder.makeAnnotation(
            pagePoints: pagePoints,
            pageStrokeWidth: width,
            color: color,
            pageIndex: pageIndex,
            uuid: UUID()
        )
    }
}

extension PDFReaderViewController: @preconcurrency PDFPageOverlayViewProvider {
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        let canvas = ModalCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = allowFingerDrawing ? .anyInput : .pencilOnly
        canvas.requirePencilForHit = !allowFingerDrawing
        canvas.isScrollEnabled = false
        canvas.delegate = self
        canvas.tool = PKInkingTool(.pen, color: .label, width: 2)
        if let drawing = drawingForPage[page] {
            canvas.drawing = drawing
        }
        canvasByPage[page] = canvas
        print("[Pumice] overlay created for page \(view.document?.index(for: page) ?? -1)")
        return canvas
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
        // PDFKit has just installed the canvas in the view hierarchy.
        // becomeFirstResponder and tool-picker setVisible only work once
        // the view is in a window, so they belong here — not in
        // overlayViewFor where the canvas is still detached.
        guard let canvas = overlayView as? PKCanvasView else { return }
        toolPicker.addObserver(canvas)
        toolPicker.setVisible(true, forFirstResponder: canvas)
        let became = canvas.becomeFirstResponder()
        print("[Pumice] overlay willDisplay page=\(pdfView.document?.index(for: page) ?? -1) becameFirstResponder=\(became)")
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let canvas = overlayView as? PKCanvasView else { return }
        drawingForPage[page] = canvas.drawing
        canvasByPage.removeValue(forKey: page)
        toolPicker.setVisible(false, forFirstResponder: canvas)
        toolPicker.removeObserver(canvas)
        print("[Pumice] overlay released for page \(pdfView.document?.index(for: page) ?? -1), strokes=\(canvas.drawing.strokes.count)")
    }
}

extension PDFReaderViewController: PKCanvasViewDelegate {
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        needsSave = true
        controller?.refreshState()
    }
}
