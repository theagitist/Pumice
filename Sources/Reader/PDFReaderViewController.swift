import UIKit
import PDFKit
import PencilKit

/// Hosts a `PDFView` for browsing and a `PKCanvasView` overlay for Apple
/// Pencil annotation.
///
/// First-slice scope: validates the F02 input-routing assumption — finger
/// touches scroll the PDF, Apple Pencil touches draw on the canvas, with no
/// explicit tool toggle in between. Persistence of the ink (serialising
/// `PKDrawing` strokes back into the PDF as `/Subtype /Ink` annotations) is
/// out of scope for this slice and will land alongside the autosave loop.
final class PDFReaderViewController: UIViewController {
    private let pdfView = PDFView()
    private let canvasView = PKCanvasView()
    private let toolPicker = PKToolPicker()

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
    }

    func load(url: URL) {
        guard let document = PDFDocument(url: url) else {
            // Surfacing a load failure to SwiftUI will land with the autosave
            // error model in a later slice.
            return
        }
        pdfView.document = document
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
        view.addSubview(canvasView)

        NSLayoutConstraint.activate([
            canvasView.topAnchor.constraint(equalTo: view.topAnchor),
            canvasView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            canvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }
}
