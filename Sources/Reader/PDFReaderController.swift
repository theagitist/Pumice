import Foundation

/// The reader's current input mode. Applies uniformly to finger and
/// Apple Pencil — switching modes is the explicit way to alternate
/// between navigating and annotating. Earlier attempts to differentiate
/// pencil vs finger automatically broke on real hardware (PencilKit
/// drawing-count-mismatch faults, PDFKit hit-test hierarchy errors).
enum FingerInputMode: String, CaseIterable, Identifiable, Sendable {
    case scroll
    case draw

    var id: String { rawValue }

    var label: String {
        switch self {
        case .scroll: "Read"
        case .draw: "Annotate"
        }
    }

    var systemImage: String {
        switch self {
        case .scroll: "book"
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
