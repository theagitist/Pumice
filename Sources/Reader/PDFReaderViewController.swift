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
    private var pathsForPage: [PDFPage: [UIBezierPath]] = [:]
    private var canvasByPage: [PDFPage: PumiceCanvasView] = [:]

    /// Called whenever a new stroke is finished on any canvas. Runs
    /// on the main queue (canvases live on main).
    var onPathFinished: (@MainActor () -> Void)?

    func setPaths(_ paths: [UIBezierPath], for page: PDFPage) {
        lock.lock(); defer { lock.unlock() }
        pathsForPage[page] = paths
    }

    func paths(for page: PDFPage) -> [UIBezierPath]? {
        lock.lock(); defer { lock.unlock() }
        return pathsForPage[page]
    }

    func allPaths() -> [PDFPage: [UIBezierPath]] {
        lock.lock(); defer { lock.unlock() }
        return pathsForPage
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        pathsForPage.removeAll()
        canvasByPage.removeAll()
    }

    /// Sync any currently-active canvases' drawings back into the
    /// path store. Call from save() before writing the document, to
    /// capture drawings on pages that haven't scrolled out of view.
    @MainActor func syncActiveCanvases() {
        lock.lock(); defer { lock.unlock() }
        for (page, canvas) in canvasByPage {
            pathsForPage[page] = canvas.paths
        }
    }
}

extension PumiceOverlayProvider: @preconcurrency PDFPageOverlayViewProvider {
    @MainActor
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        print("[Pumice] (provider) overlayViewFor page=\(view.document?.index(for: page) ?? -1)")
        let canvas = PumiceCanvasView()
        let existing: [UIBezierPath]? = {
            lock.lock(); defer { lock.unlock() }
            return pathsForPage[page]
        }()
        if let existing { canvas.setPaths(existing) }
        canvas.onPathFinished = { [weak self, weak page] _ in
            guard let self, let page else { return }
            self.lock.lock()
            self.pathsForPage[page] = canvas.paths
            self.lock.unlock()
            DispatchQueue.main.async { [weak self] in
                self?.onPathFinished?()
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
        print("[Pumice] (provider) willEnd page=\(pdfView.document?.index(for: page) ?? -1) strokes=\(canvas.paths.count)")
        lock.lock()
        pathsForPage[page] = canvas.paths
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

        // Wire the overlay provider BEFORE any document is loaded.
        // Matches the working Cookiezby reference; setting it after
        // pdfView.document had no effect in past iterations.
        pdfView.pageOverlayViewProvider = overlayProvider
        pdfView.isInMarkupMode = true
        overlayProvider.onPathFinished = { [weak self] in
            self?.needsSave = true
            self?.controller?.refreshState()
        }
        print("[Pumice] viewDidLoad: provider wired (separate object), markup=\(pdfView.isInMarkupMode)")

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(annotationWasHit(_:)),
            name: .PDFViewAnnotationHit,
            object: pdfView
        )
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
        selectedAnnotation = nil
        selectedAnnotationPage = nil
        overlayProvider.reset()
        controller?.refreshState()

        guard let document = PDFDocument(url: url) else { return }
        document.delegate = documentDelegate
        pdfView.document = document
        let providerKind = pdfView.pageOverlayViewProvider.map { String(describing: type(of: $0)) } ?? "nil"
        print("[Pumice] load: pages=\(document.pageCount) markup=\(pdfView.isInMarkupMode) providerKind=\(providerKind)")

        // Hydrate per-page paths from any /Ink annotations already in
        // the file. We strip them from the model so they don't double-
        // up with what the canvas renders.
        var hydratedPages = 0
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
                overlayProvider.setPaths(canvasPaths, for: page)
                hydratedPages += 1
            }
            for ann in inkAnnotations {
                page.removeAnnotation(ann)
            }
        }
        print("[Pumice] load: \(hydratedPages) pages with prior strokes")
    }

    func saveIfNeeded() {
        guard needsSave, let url = pdfURL, let document = pdfView.document else { return }
        overlayProvider.syncActiveCanvases()
        let snapshot = overlayProvider.allPaths()
        for (page, paths) in snapshot {
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
            print("[Pumice] save: wrote \(snapshot.count) page-strokes to \(url.lastPathComponent)")
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

