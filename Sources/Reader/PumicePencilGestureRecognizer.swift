import UIKit

/// Delegate that receives live and committed stroke paths in the
/// canvas's coordinate system.
protocol PumicePencilGestureDelegate: AnyObject {
    func pencilGestureDidUpdate(path: UIBezierPath)
    func pencilGestureDidFinish(path: UIBezierPath)
}

/// Custom drawing gesture recognizer that fires only for Apple Pencil
/// touches. Finger touches (`.direct`) and indirect inputs are
/// rejected so they fall through to PDFView's scroll gesture.
///
/// PencilKit's `PKCanvasView` with `drawingPolicy = .pencilOnly` was
/// supposed to do this for us, but on iPadOS 26 inside PDFKit's
/// per-page overlay it never activates — the pen falls through to
/// PDFView's scroll regardless of how the canvas is set up. Multiple
/// iterations (markup mode, becomeFirstResponder timing, tool-picker
/// observation, PDFPageView userInteractionEnabled) didn't help.
/// Going back to plain UIGestureRecognizer subclass gives us
/// deterministic control over which touches start a stroke.
final class PumicePencilGestureRecognizer: UIGestureRecognizer {
    weak var pencilDelegate: PumicePencilGestureDelegate?
    private var currentPath: UIBezierPath?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        // Explicitly tell iOS this gesture only fires for pencil
        // touches. Without this, the gesture competes against PDFView's
        // pan gesture for finger touches too and may lose priority.
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard let touch = touches.first,
              touch.type == .pencil,
              event.allTouches?.count == 1
        else {
            state = .failed
            return
        }
        let path = UIBezierPath()
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.move(to: touch.location(in: view))
        currentPath = path
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let path = currentPath,
              let touch = touches.first,
              touch.type == .pencil
        else { return }
        // Use UIEvent.coalescedTouches to pull every sub-touch event
        // the system collected since the last call. Apple Pencil 2/Pro
        // emits up to ~240Hz of touch samples, but UIKit batches them
        // into one touchesMoved call per refresh — without coalescing
        // we'd drop most of them and the resulting path is jagged at
        // anything above a slow pen speed.
        for sub in event.coalescedTouches(for: touch) ?? [touch] {
            path.addLine(to: sub.location(in: view))
        }
        pencilDelegate?.pencilGestureDidUpdate(path: path)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard let path = currentPath,
              let touch = touches.first,
              touch.type == .pencil
        else {
            state = .ended
            return
        }
        for sub in event.coalescedTouches(for: touch) ?? [touch] {
            path.addLine(to: sub.location(in: view))
        }
        pencilDelegate?.pencilGestureDidFinish(path: path)
        currentPath = nil
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        currentPath = nil
        state = .cancelled
    }
}
