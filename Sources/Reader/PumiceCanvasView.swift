import UIKit

/// One per PDF page, installed via `PDFPageOverlayViewProvider`.
/// PDFKit sizes the view to the page's bounds and parents it inside
/// the page's subview, so coordinates are page-local (UIKit Y-down).
///
/// Rendering:
///   * each committed stroke gets its own `CAShapeLayer` so per-stroke
///     color and width survive the round-trip (a single shared shape
///     layer would force every stroke on a page to share one style);
///   * `liveLayer` shows the in-progress pen stroke;
///   * `cursorLayer` shows an outlined circle at the pencil tip while
///     the eraser is engaged — the gesture doesn't leave a trail in
///     eraser mode, it just rubs strokes out as it passes over them.
///
/// Strokes are stored as `StrokeRecord` (path + color + width) in the
/// canvas's coordinate system. When committing to PDF (via the owning
/// view controller) we transform path coordinates to page space
/// (Y-flip) before building the standard `/Ink` annotation via
/// PumiceCore.
final class PumiceCanvasView: UIView {
    /// Pen settings used for the NEXT stroke (and for the in-progress
    /// `liveLayer` preview). Existing strokes keep whatever style they
    /// were drawn with.
    var penColor: UIColor = .systemBlue {
        didSet { applyLiveStyle() }
    }
    var penWidth: CGFloat = 3 {
        didSet { applyLiveStyle() }
    }

    /// When true, finished pencil strokes are reported via
    /// `onEraserStroke` instead of being committed and drawn. The
    /// canvas hit-tests each pencil sub-move against existing strokes
    /// and removes them in-place so the eraser visibly works as it
    /// passes over them.
    var isEraserActive: Bool = false {
        didSet { if !isEraserActive { hideEraserCursor() } }
    }

    private(set) var strokes: [StrokeRecord] = []

    /// Fired once at the end of a successful pen stroke.
    var onPathFinished: ((StrokeRecord) -> Void)?

    /// Fired once at the end of an eraser gesture, carrying every
    /// stroke that the gesture erased. Empty batches are NOT reported
    /// — a gesture that hit nothing is a no-op.
    var onEraserStroke: (([StrokeRecord]) -> Void)?

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

    /// Replace the entire stroke list and rebuild the per-stroke
    /// layers. Used on document load and on undo/redo / external erase
    /// operations driven from the provider.
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
        liveLayer.strokeColor = penColor.cgColor
        liveLayer.lineWidth = penWidth
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
        if isEraserActive {
            // No live trail in eraser mode — only the circle cursor.
            liveLayer.path = nil
            showEraserCursor(at: currentPoint)
            let from = eraserLastPoint ?? currentPoint
            eraseAlong(from: from, to: currentPoint)
            eraserLastPoint = currentPoint
        } else {
            liveLayer.path = path.cgPath
        }
    }

    func pencilGestureDidFinish(path: UIBezierPath) {
        liveLayer.path = nil
        if isEraserActive {
            // Finish the last segment with the gesture's actual end
            // point in case `touchesEnded` carried sub-touches the
            // last `touchesMoved` didn't see.
            if let from = eraserLastPoint {
                eraseAlong(from: from, to: path.currentPoint)
            }
            hideEraserCursor()
            let batch = erasedDuringGesture
            erasedDuringGesture.removeAll()
            eraserLastPoint = nil
            if !batch.isEmpty { onEraserStroke?(batch) }
            return
        }
        let record = StrokeRecord(path: path, color: penColor, width: penWidth)
        strokes.append(record)
        appendLayer(for: record)
        onPathFinished?(record)
    }
}
