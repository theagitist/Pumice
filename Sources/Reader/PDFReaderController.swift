import Foundation

/// The reader's current input mode. Three discrete modes so the user
/// can switch between "just navigating", "annotating with the pencil
/// while the finger still scrolls" (the PRD's headline UX), and "draw
/// freely with finger or pencil".
enum FingerInputMode: String, CaseIterable, Identifiable, Sendable {
    case scroll
    case pencil
    case draw

    var id: String { rawValue }

    var label: String {
        switch self {
        case .scroll: "Read"
        case .pencil: "Pencil"
        case .draw: "Draw"
        }
    }

    var systemImage: String {
        switch self {
        case .scroll: "book"
        case .pencil: "applepencil"
        case .draw: "scribble"
        }
    }
}

/// SwiftUI <-> UIKit bridge for the reader. Owns the @Published toolbar
/// state and forwards user actions to the underlying view controller.
@MainActor
final class PDFReaderController: ObservableObject {
    // Default to Pencil mode so the PRD's headline UX — Apple Pencil draws,
    // finger scrolls — works the moment the user opens a PDF, with no
    // toolbar interaction required.
    @Published var fingerMode: FingerInputMode = .pencil {
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
