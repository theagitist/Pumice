import UIKit

/// One per PDF page, installed via `PDFPageOverlayViewProvider`.
/// PDFKit sizes the view to the page's bounds and parents it inside
/// the page's subview, so coordinates are page-local (UIKit Y-down).
///
/// Renders two layers:
///   * `committedLayer` — the union of every stroke we've already
///     finished. Built once when paths change, then static until the
///     next change.
///   * `liveLayer` — the in-progress stroke being drawn right now.
///     Cleared when the stroke finishes and folded into the committed
///     layer.
///
/// Strokes are stored as `UIBezierPath` in the canvas's coordinate
/// system. When committing to PDF (via the owning view controller)
/// we transform to page coordinates (Y-flip) before building the
/// standard `/Ink` annotation via PumiceCore.
final class PumiceCanvasView: UIView {
    var strokeColor: UIColor = .label {
        didSet { applyStrokeStyle() }
    }
    var strokeWidth: CGFloat = 2 {
        didSet { applyStrokeStyle() }
    }

    private(set) var paths: [UIBezierPath] = []
    var onPathFinished: ((UIBezierPath) -> Void)?

    private let committedLayer = CAShapeLayer()
    private let liveLayer = CAShapeLayer()
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

        committedLayer.fillColor = nil
        committedLayer.lineCap = .round
        committedLayer.lineJoin = .round
        layer.addSublayer(committedLayer)

        liveLayer.fillColor = nil
        liveLayer.lineCap = .round
        liveLayer.lineJoin = .round
        layer.addSublayer(liveLayer)

        applyStrokeStyle()
        addGestureRecognizer(gesture)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        committedLayer.frame = bounds
        liveLayer.frame = bounds
    }

    /// Replace the stored paths and rebuild the committed layer.
    /// Called on document load to hydrate the canvas from saved
    /// `/Ink` annotations.
    func setPaths(_ newPaths: [UIBezierPath]) {
        paths = newPaths
        rebuildCommittedLayer()
    }

    func clear() {
        paths.removeAll()
        rebuildCommittedLayer()
        liveLayer.path = nil
    }

    private func applyStrokeStyle() {
        committedLayer.strokeColor = strokeColor.cgColor
        committedLayer.lineWidth = strokeWidth
        liveLayer.strokeColor = strokeColor.cgColor
        liveLayer.lineWidth = strokeWidth
    }

    private func rebuildCommittedLayer() {
        guard !paths.isEmpty else {
            committedLayer.path = nil
            return
        }
        let combined = UIBezierPath()
        for p in paths { combined.append(p) }
        committedLayer.path = combined.cgPath
    }
}

extension PumiceCanvasView: @preconcurrency PumicePencilGestureDelegate {
    func pencilGestureDidUpdate(path: UIBezierPath) {
        liveLayer.path = path.cgPath
    }

    func pencilGestureDidFinish(path: UIBezierPath) {
        paths.append(path)
        liveLayer.path = nil
        rebuildCommittedLayer()
        onPathFinished?(path)
    }
}
