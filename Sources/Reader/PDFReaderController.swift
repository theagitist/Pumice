import Foundation

/// Which input the finger drives in the current reader. Apple Pencil
/// always draws/snaps regardless of mode; this just controls what happens
/// when the user touches the screen with a finger.
enum FingerInputMode: String, CaseIterable, Identifiable, Sendable {
    case scroll
    case draw

    var id: String { rawValue }

    var label: String {
        switch self {
        case .scroll: "Scroll"
        case .draw: "Draw"
        }
    }

    var systemImage: String {
        switch self {
        case .scroll: "hand.draw"
        case .draw: "pencil.tip"
        }
    }
}

/// SwiftUI <-> UIKit bridge for the reader. Owns the @Published toolbar
/// state and forwards user actions to the underlying view controller.
@MainActor
final class PDFReaderController: ObservableObject {
    @Published var fingerMode: FingerInputMode = .scroll {
        didSet { viewController?.applyFingerMode(fingerMode) }
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
        vc.applyFingerMode(fingerMode)
        refreshState()
    }
}
