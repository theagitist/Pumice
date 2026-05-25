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

    private var canvasByPage: [PDFPage: PumiceCanvasView] = [:]
    private var pathsForPage: [PDFPage: [UIBezierPath]] = [:]

    private let _undoManager = UndoManager()
    private let documentDelegate = PumicePDFDocumentDelegate()
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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(annotationWasHit(_:)),
            name: .PDFViewAnnotationHit,
            object: pdfView
        )
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        syncActiveCanvases()
        saveIfNeeded()
    }

    func load(url: URL) {
        pdfURL = url
        needsSave = false
        _undoManager.removeAllActions()
        selectedAnnotation = nil
        selectedAnnotationPage = nil
        canvasByPage.removeAll()
        pathsForPage.removeAll()
        controller?.refreshState()

        guard let document = PDFDocument(url: url) else { return }
        // Wire the document delegate BEFORE assigning to PDFView so
        // PDFKit uses our custom PDFPage subclass from the very first
        // page-load. The delegate is a separate, non-MainActor type:
        // PDFKit invokes classForPage() from background queues during
        // parsing, which triggers Swift 6's MainActor concurrency
        // assert if the delegate is on a UIViewController (which is
        // implicitly @MainActor).
        document.delegate = documentDelegate
        pdfView.document = document

        pdfView.pageOverlayViewProvider = self
        pdfView.isInMarkupMode = true

        // DIAGNOSTIC: disable PDFView's internal scroll. Cookiezby's
        // working reference does this; their app has explicit
        // start/end-edit modes that toggle it. We want to find out
        // whether scroll-enabled is what's blocking overlayViewFor:
        // from being called at all. If overlays start appearing with
        // scroll off, we know the gesture priority is the blocker and
        // can design a real fix. If overlays still don't appear with
        // scroll off, the cause is elsewhere.
        pdfView.privateScrollView?.isScrollEnabled = false
        print("[Pumice] load: doc.delegate set, markup=\(pdfView.isInMarkupMode) provider=\(pdfView.pageOverlayViewProvider != nil) pages=\(document.pageCount) innerScrollEnabled=\(pdfView.privateScrollView?.isScrollEnabled ?? true)")

        // Nudge PDFView into a layout pass — overlayViewFor: is only
        // queried when a page actually has to be laid out, and an
        // off-screen pre-load might not count.
        pdfView.setNeedsLayout()
        pdfView.layoutIfNeeded()

        // Hydrate per-page paths from any /Ink annotations already in
        // the file. We strip them from the model so they don't double-
        // up with what the canvas renders.
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let inkAnnotations = page.annotations.filter { $0.type == "Ink" }
            let pageHeight = page.bounds(for: .mediaBox).height
            var canvasPaths: [UIBezierPath] = []
            for ann in inkAnnotations {
                for pathInPage in ann.paths ?? [] {
                    canvasPaths.append(Self.canvasPath(fromPagePath: pathInPage, pageHeight: pageHeight))
                }
            }
            if !canvasPaths.isEmpty {
                pathsForPage[page] = canvasPaths
            }
            for ann in inkAnnotations {
                page.removeAnnotation(ann)
            }
        }
        print("[Pumice] load: \(pathsForPage.count) pages with prior strokes")
    }

    func saveIfNeeded() {
        guard needsSave, let url = pdfURL, let document = pdfView.document else { return }
        syncActiveCanvases()
        for (page, paths) in pathsForPage {
            for ann in page.annotations where ann.type == "Ink" {
                page.removeAnnotation(ann)
            }
            let pageIndex = document.index(for: page)
            let pageHeight = page.bounds(for: .mediaBox).height
            for canvasPath in paths {
                guard let annotation = Self.inkAnnotation(
                    fromCanvasPath: canvasPath,
                    pageIndex: pageIndex,
                    pageHeight: pageHeight
                ) else { continue }
                page.addAnnotation(annotation)
            }
        }
        if document.write(to: url) {
            needsSave = false
            print("[Pumice] save: wrote \(pathsForPage.count) page-strokes to \(url.lastPathComponent)")
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
            pathsForPage[page] = canvas.paths
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
        print("[Pumice] configurePDFView: pdfView added to view hierarchy")

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

    /// Convert a canvas-coord bezier path into a standard `/Ink`
    /// PDFAnnotation via PumiceCore's builder. Flattens the path's
    /// move/line elements into a point list — the builder smooths
    /// them into a curve internally.
    static func inkAnnotation(
        fromCanvasPath canvasPath: UIBezierPath,
        pageIndex: Int,
        pageHeight: CGFloat
    ) -> PDFAnnotation? {
        let pagePath = self.pagePath(fromCanvasPath: canvasPath, pageHeight: pageHeight)
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
            pageStrokeWidth: 2,
            color: StrokeColor(uiColor: .label),
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

extension PDFReaderViewController: @preconcurrency PDFPageOverlayViewProvider {
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        let canvas = PumiceCanvasView()
        if let paths = pathsForPage[page] {
            canvas.setPaths(paths)
        }
        canvas.onPathFinished = { [weak self, weak page] _ in
            guard let self, let page else { return }
            self.pathsForPage[page] = self.canvasByPage[page]?.paths
            self.needsSave = true
            self.controller?.refreshState()
        }
        canvasByPage[page] = canvas

        // PDFKit's internal `PDFPageView` (per-page subview inside
        // documentView) defaults to isUserInteractionEnabled = false,
        // so without this every touch to our overlay is silently
        // swallowed by the parent. Class lookup is by name because
        // the symbol isn't public. Workaround documented in
        // Cookiezby/ios-pdf-edit-example; nowhere in Apple's docs.
        for subview in view.documentView?.subviews ?? [] {
            if NSStringFromClass(type(of: subview)) == "PDFPageView" {
                subview.isUserInteractionEnabled = true
            }
        }
        print("[Pumice] overlay created for page \(view.document?.index(for: page) ?? -1)")
        return canvas
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let canvas = overlayView as? PumiceCanvasView else { return }
        pathsForPage[page] = canvas.paths
        canvasByPage.removeValue(forKey: page)
        print("[Pumice] overlay released for page \(pdfView.document?.index(for: page) ?? -1), strokes=\(canvas.paths.count)")
    }
}
