import Foundation

/// SwiftUI <-> UIKit bridge for the reader. Owns the @Published toolbar
/// state and forwards user actions to the underlying view controller.
@MainActor
final class PDFReaderController: ObservableObject {
    /// When true, the canvas accepts finger drawing as well as Pencil.
    /// Default false: pencil draws, finger scrolls. Users without a Pencil
    /// can flip this on from the toolbar to draw with a finger instead.
    @Published var allowFingerDrawing: Bool = false {
        didSet { viewController?.applyAllowFingerDrawing(allowFingerDrawing) }
    }
    @Published private(set) var canUndo: Bool = false
    @Published private(set) var canRedo: Bool = false
    @Published private(set) var hasSelectedAnnotation: Bool = false

    fileprivate weak var viewController: PDFReaderViewController?

    func saveIfNeeded() {
        viewController?.saveIfNeeded()
    }

    func undo() {
        viewController?.undoLastChange()
    }

    func redo() {
        viewController?.redoLastChange()
    }

    func deleteSelectedAnnotation() {
        viewController?.deleteSelectedAnnotation()
    }

    /// Called by the view controller whenever the undo stack or the
    /// current annotation selection changes. Updates the published
    /// bindings the SwiftUI toolbar reads.
    func refreshState() {
        guard let vc = viewController else {
            canUndo = false
            canRedo = false
            hasSelectedAnnotation = false
            return
        }
        canUndo = vc.canUndoChange
        canRedo = vc.canRedoChange
        hasSelectedAnnotation = vc.hasSelectedAnnotation
    }
}

@MainActor
extension PDFReaderController {
    func attach(_ vc: PDFReaderViewController) {
        viewController = vc
        vc.controller = self
        vc.applyAllowFingerDrawing(allowFingerDrawing)
        // `attach` is called from `make/updateUIViewController`, which runs
        // mid-view-update. Mutating `@Published` state here would trigger
        // SwiftUI's "publishing during view updates" fault and cause taps
        // (selection, toolbar buttons) to be dropped on the next render
        // pass. Defer the refresh to the next main-actor turn.
        Task { @MainActor [weak self] in
            self?.refreshState()
        }
    }
}
