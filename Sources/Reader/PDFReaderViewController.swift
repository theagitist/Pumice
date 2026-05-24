import PDFKit
import PencilKit
import PumiceCore
import UIKit

/// Hosts a `PDFView` for browsing and a `PKCanvasView` overlay for Apple
/// Pencil annotation, then commits each completed stroke as a standard
/// `/Subtype /Ink` annotation on the underlying page via PumiceCore.
///
/// Coordinate strategy: the `PKCanvasView` is pinned to `PDFView.documentView`,
/// so canvas-space points equal documentView-space points. On stroke end we
/// convert canvas → PDFView → page (PDF user space) via PDFView's coordinate
/// helpers, then hand the page-space points directly to
/// `InkAnnotationBuilder`. After committing, the canvas is cleared and the
/// committed stroke renders from PDFKit instead.
///
/// Save lifecycle: dirty state is set on each commit; `saveIfNeeded()` is
/// invoked from `viewWillDisappear` (selection change, nav away) and from
/// SwiftUI's `scenePhase` observer (app backgrounding). The current save is
/// a direct `PDFDocument.write(to:)` — F06's `.bak` + hash-guarded atomic
/// swap will replace it.
final class PDFReaderViewController: UIViewController {
    private let pdfView = PDFView()
    private let canvasView = PKCanvasView()
    private let toolPicker = PKToolPicker()
    private var pdfURL: URL?
    private var needsSave = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        configurePDFView()
        configureCanvasOverlay()
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
        guard let document = PDFDocument(url: url) else { return }
        pdfView.document = document
    }

    func saveIfNeeded() {
        guard needsSave, let url = pdfURL, let document = pdfView.document else { return }
        if document.write(to: url) {
            needsSave = false
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

    private func configureCanvasOverlay() {
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        // `.pencilOnly` is the key F02 hinge: PencilKit ignores finger touches
        // entirely, so they pass through to `PDFView` for scrolling/zooming.
        canvasView.drawingPolicy = .pencilOnly
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

        // Clear committed strokes from the live canvas; PDFKit re-renders
        // them from the freshly added annotations.
        canvasView.drawing = PKDrawing()

        if committed {
            needsSave = true
            pdfView.setNeedsDisplay()
        }
    }

    private func commit(
        pkStroke: PKStroke,
        documentView: UIView,
        document: PDFDocument
    ) -> Bool {
        // Find the page under the stroke's geometric centre.
        let canvasBounds = pkStroke.renderBounds
        let canvasCenter = CGPoint(x: canvasBounds.midX, y: canvasBounds.midY)
        let centerInPDFView = documentView.convert(canvasCenter, to: pdfView)
        guard let page = pdfView.page(for: centerInPDFView, nearest: true) else {
            return false
        }
        let pageIndex = document.index(for: page)

        // Convert every sample point: canvas → PDFView → page.
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
        guard widthCount > 0 else { return false }
        let width = widthSum / CGFloat(widthCount)

        let annotation = InkAnnotationBuilder.makeAnnotation(
            pagePoints: pagePoints,
            pageStrokeWidth: width,
            color: StrokeColor(uiColor: pkStroke.ink.color),
            pageIndex: pageIndex,
            uuid: UUID()
        )
        page.addAnnotation(annotation)
        return true
    }
}

extension PDFReaderViewController: PKCanvasViewDelegate {
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        commitStrokesAndClear()
    }
}
