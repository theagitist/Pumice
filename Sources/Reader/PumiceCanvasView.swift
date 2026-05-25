import UIKit

/// One per PDF page, installed via `PDFPageOverlayViewProvider`.
/// PDFKit sizes the view to the page's bounds and parents it inside
/// the page's subview, so coordinates are page-local (UIKit Y-down).
///
/// Rendering:
///   * each committed pen stroke gets its own `CAShapeLayer` so per-
///     stroke color and width survive the round-trip (a single shared
///     shape layer would force every stroke on a page to share one
///     style);
///   * `liveLayer` shows the in-progress pen/highlighter stroke;
///   * `cursorLayer` shows an outlined circle at the pencil tip while
///     the eraser is engaged — the gesture doesn't leave a trail in
///     eraser mode, it just rubs strokes out as it passes over them.
///
/// Pen strokes are stored as `StrokeRecord` (path + color + width) in
/// the canvas's coordinate system. When committing to PDF (via the
/// owning view controller) we transform path coordinates to page space
/// (Y-flip) before building the standard `/Ink` annotation via
/// PumiceCore.
///
/// Highlighter strokes are NOT stored locally — they're routed to the
/// owning view controller via `onHighlightStrokeFinished`, which snaps
/// the first/last points to PDF text and adds a real `/Highlight`
/// annotation to the page. PDFKit renders the annotation natively.
final class PumiceCanvasView: UIView {
    enum Mode {
        case pen
        case highlighter
        case eraser
    }

    /// Pen style used for the NEXT pen stroke (and for the in-progress
    /// `liveLayer` preview while drawing in pen mode). Existing pen
    /// strokes keep whatever style they were drawn with.
    var penColor: UIColor = .systemBlue {
        didSet { applyLiveStyle() }
    }
    var penWidth: CGFloat = 3 {
        didSet { applyLiveStyle() }
    }

    /// Highlighter live-preview style. These never affect the final
    /// `/Highlight` annotation (the snap step uses the text bounds);
    /// they only style the in-progress band the user sees while
    /// dragging across text.
    var highlightColor: UIColor = UIColor(red: 1.0, green: 0.92, blue: 0.23, alpha: 1.0) {
        didSet { applyLiveStyle() }
    }
    var highlightWidth: CGFloat = 14 {
        didSet { applyLiveStyle() }
    }

    /// Live-preview alpha for the highlighter band. Translucent so
    /// the underlying PDF text reads through while dragging.
    private let highlightLiveAlpha: CGFloat = 0.35

    /// Current drawing mode. Setting it tears down any in-flight
    /// state from the previous mode (live trail, eraser cursor).
    var mode: Mode = .pen {
        didSet {
            guard oldValue != mode else { return }
            liveLayer.path = nil
            hideEraserCursor()
            applyLiveStyle()
        }
    }

    private(set) var strokes: [StrokeRecord] = []

    /// Fired once at the end of a successful pen stroke (mode == .pen).
    var onPathFinished: ((StrokeRecord) -> Void)?

    /// Fired during an eraser gesture (mode == .eraser) on every
    /// `touchesMoved`, carrying the freshly-traversed segment in
    /// canvas coords. The owning view controller uses this to remove
    /// `/Highlight` annotations the gesture crosses *in real time* —
    /// canvas strokes are erased here too, but they're rendered by
    /// the canvas and disappear immediately. Highlights are rendered
    /// by PDFKit on the page and need the VC to react per-segment.
    var onEraserSegment: ((_ from: CGPoint, _ to: CGPoint) -> Void)?

    /// Fired once at the end of an eraser gesture (mode == .eraser),
    /// carrying every canvas stroke the gesture erased. The VC pairs
    /// this with the highlights it removed via `onEraserSegment` into
    /// a single undo step.
    var onEraserStroke: ((_ removed: [StrokeRecord]) -> Void)?

    /// Fired once at the end of a successful highlighter stroke
    /// (mode == .highlighter). Carries the gesture's first and last
    /// canvas-space points so the controller can convert to PDF
    /// user space and ask PumiceCore for the snapped text selection.
    var onHighlightStrokeFinished: ((_ first: CGPoint, _ last: CGPoint) -> Void)?

    /// Eraser hit-test radius in canvas points. Strokes whose sample
    /// points come within `eraserRadius + stroke.width/2` of the
    /// eraser path's sweep are removed.
    private let eraserRadius: CGFloat = 12

    private var strokeLayers: [CAShapeLayer] = []
    private let liveLayer = CAShapeLayer()
    private let cursorLayer = CAShapeLayer()

    // Per-gesture eraser state.
    private var eraserLastPoint: CGPoint?
    private var erasedDuringGesture: [StrokeRecord] = []

    // Per-gesture highlighter state — we only need the first/last
    // point for the snap, but tracking the first lets us report a
    // gesture that never moved (a tap on text) as a single-point
    // selection too.
    private var highlightFirstPoint: CGPoint?

    private lazy var gesture: PumicePencilGestureRecognizer = {
        let g = PumicePencilGestureRecognizer()
        g.pencilDelegate = self
        return g
    }()

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = true
        clipsToBounds = true

        liveLayer.fillColor = nil
        liveLayer.lineCap = .round
        liveLayer.lineJoin = .round
        layer.addSublayer(liveLayer)
        applyLiveStyle()

        cursorLayer.fillColor = nil
        cursorLayer.strokeColor = UIColor.systemGray.cgColor
        cursorLayer.lineWidth = 1.5
        cursorLayer.isHidden = true
        layer.addSublayer(cursorLayer)

        addGestureRecognizer(gesture)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        liveLayer.frame = bounds
        cursorLayer.frame = bounds
        for layer in strokeLayers { layer.frame = bounds }
    }

    /// Replace the entire pen-stroke list and rebuild the per-stroke
    /// layers. Used on document load and on undo/redo / external erase
    /// operations driven from the provider. Doesn't touch highlights —
    /// those live as native `PDFAnnotation`s on the page.
    func setStrokes(_ newStrokes: [StrokeRecord]) {
        strokes = newStrokes
        rebuildStrokeLayers()
    }

    func clear() {
        strokes.removeAll()
        rebuildStrokeLayers()
        liveLayer.path = nil
        hideEraserCursor()
    }

    private func applyLiveStyle() {
        switch mode {
        case .pen:
            liveLayer.strokeColor = penColor.cgColor
            liveLayer.lineWidth = penWidth
        case .highlighter:
            liveLayer.strokeColor = highlightColor.withAlphaComponent(highlightLiveAlpha).cgColor
            liveLayer.lineWidth = highlightWidth
        case .eraser:
            // No live trail in eraser mode.
            liveLayer.strokeColor = UIColor.clear.cgColor
            liveLayer.lineWidth = 0
        }
    }

    private func rebuildStrokeLayers() {
        for layer in strokeLayers { layer.removeFromSuperlayer() }
        strokeLayers.removeAll()
        for stroke in strokes {
            let layer = makeLayer(for: stroke)
            strokeLayers.append(layer)
            // Keep stroke layers BELOW the live + cursor layers so an
            // in-progress preview or eraser ring draws on top.
            self.layer.insertSublayer(layer, below: liveLayer)
        }
    }

    private func appendLayer(for stroke: StrokeRecord) {
        let layer = makeLayer(for: stroke)
        strokeLayers.append(layer)
        self.layer.insertSublayer(layer, below: liveLayer)
    }

    private func makeLayer(for stroke: StrokeRecord) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.frame = bounds
        l.fillColor = nil
        l.lineCap = .round
        l.lineJoin = .round
        l.strokeColor = stroke.color.cgColor
        l.lineWidth = stroke.width
        l.path = stroke.path.cgPath
        return l
    }

    // MARK: - Eraser

    private func showEraserCursor(at point: CGPoint) {
        let r = eraserRadius
        let rect = CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
        // Disable the implicit layer animation on path/frame changes so
        // the cursor sticks to the pencil tip instead of trailing it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.path = UIBezierPath(ovalIn: rect).cgPath
        cursorLayer.isHidden = false
        CATransaction.commit()
    }

    private func hideEraserCursor() {
        cursorLayer.isHidden = true
        cursorLayer.path = nil
    }

    /// Hit-test the freshly-traversed eraser segment against every
    /// committed stroke and remove the ones it crossed. Mutates
    /// `strokes` in place and appends the removed records to
    /// `erasedDuringGesture` so the gesture's onFinish callback can
    /// pass them up for an undo entry.
    private func eraseAlong(from: CGPoint, to: CGPoint) {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let dist = (dx * dx + dy * dy).squareRoot()
        // Sample one probe per ~4pt of eraser travel so a fast sweep
        // doesn't skip over a stroke it visually crossed.
        let steps = max(1, Int(dist / 4))

        var newStrokes: [StrokeRecord] = []
        var removed: [StrokeRecord] = []
        newStrokes.reserveCapacity(strokes.count)

        for stroke in strokes {
            let r = eraserRadius + stroke.width / 2
            let r2 = r * r
            let strokeSamples = Self.samples(of: stroke.path)
            var hit = false
            for step in 0...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let px = from.x + dx * t
                let py = from.y + dy * t
                for sample in strokeSamples {
                    let ddx = sample.x - px
                    let ddy = sample.y - py
                    if ddx * ddx + ddy * ddy <= r2 {
                        hit = true
                        break
                    }
                }
                if hit { break }
            }
            if hit {
                removed.append(stroke)
            } else {
                newStrokes.append(stroke)
            }
        }

        guard !removed.isEmpty else { return }
        strokes = newStrokes
        erasedDuringGesture.append(contentsOf: removed)
        rebuildStrokeLayers()
    }

    private static func samples(of path: UIBezierPath) -> [CGPoint] {
        var points: [CGPoint] = []
        path.cgPath.applyWithBlock { ptr in
            let elem = ptr.pointee
            switch elem.type {
            case .moveToPoint, .addLineToPoint:
                points.append(elem.points[0])
            default:
                break
            }
        }
        return points
    }
}

extension PumiceCanvasView: @preconcurrency PumicePencilGestureDelegate {
    func pencilGestureDidUpdate(path: UIBezierPath) {
        let currentPoint = path.currentPoint
        switch mode {
        case .pen, .highlighter:
            liveLayer.path = path.cgPath
            if mode == .highlighter && highlightFirstPoint == nil {
                // The recognizer's path always starts with a moveTo
                // at the first touchesBegan point — capture it for
                // the snap so we don't need to walk the path later.
                highlightFirstPoint = path.cgPath.firstPoint ?? currentPoint
            }
        case .eraser:
            // No live trail in eraser mode — only the circle cursor.
            liveLayer.path = nil
            showEraserCursor(at: currentPoint)
            let from = eraserLastPoint ?? currentPoint
            eraseAlong(from: from, to: currentPoint)
            onEraserSegment?(from, currentPoint)
            eraserLastPoint = currentPoint
        }
    }

    func pencilGestureDidFinish(path: UIBezierPath) {
        liveLayer.path = nil

        switch mode {
        case .eraser:
            // Finish the last segment with the gesture's actual end
            // point in case `touchesEnded` carried sub-touches the
            // last `touchesMoved` didn't see. Mirror the per-segment
            // callback so the VC sees the closing slice for highlight
            // hit-tests too.
            if let from = eraserLastPoint {
                eraseAlong(from: from, to: path.currentPoint)
                onEraserSegment?(from, path.currentPoint)
            }
            hideEraserCursor()
            let batch = erasedDuringGesture
            erasedDuringGesture.removeAll()
            eraserLastPoint = nil
            // Fire even on an empty stroke batch — highlights removed
            // via `onEraserSegment` may still need to be folded into
            // an undo step at gesture-end.
            onEraserStroke?(batch)

        case .highlighter:
            let first = highlightFirstPoint ?? path.cgPath.firstPoint ?? path.currentPoint
            highlightFirstPoint = nil
            onHighlightStrokeFinished?(first, path.currentPoint)

        case .pen:
            let record = StrokeRecord(path: path, color: penColor, width: penWidth)
            strokes.append(record)
            appendLayer(for: record)
            onPathFinished?(record)
        }
    }
}

private extension CGPath {
    /// Returns the first `moveTo` point in the path, if any.
    /// The pencil gesture recognizer always begins its path with a
    /// `moveTo` at the first touch, so this is the gesture's origin.
    var firstPoint: CGPoint? {
        var found: CGPoint?
        applyWithBlock { ptr in
            if found != nil { return }
            let elem = ptr.pointee
            if elem.type == .moveToPoint {
                found = elem.points[0]
            }
        }
        return found
    }
}
