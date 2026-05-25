import Foundation

/// SwiftUI <-> UIKit bridge for the reader. Owns the @Published toolbar
/// state and forwards user actions to the underlying view controller.
@MainActor
final class PDFReaderController: ObservableObject {
    @Published private(set) var canUndo: Bool = false
    @Published private(set) var canRedo: Bool = false

    /// User-facing pen settings. The SwiftUI toolbar binds to these
    /// directly; `didSet` forwards the choice through to the underlying
    /// view controller so the active canvas picks up the change without
    /// the user having to lift their pen.
    ///
    /// Picking a color or width while the eraser is active also
    /// auto-switches back to the pen tool — the user clearly meant to
    /// resume drawing, not to configure the pen for later.
    @Published var penColor: PenColor = .blue {
        didSet {
            viewController?.setPenColor(penColor.uiColor)
            if isEraserActive { isEraserActive = false }
        }
    }
    @Published var penWidth: PenWidth = .medium {
        didSet {
            viewController?.setPenWidth(penWidth.points)
            if isEraserActive { isEraserActive = false }
        }
    }
    @Published var isEraserActive: Bool = false {
        didSet { viewController?.setEraserActive(isEraserActive) }
    }

    weak var viewController: PDFReaderViewController?

    func saveIfNeeded() {
        viewController?.saveIfNeeded()
    }

    func undo() {
        viewController?.undoLastChange()
    }

    func redo() {
        viewController?.redoLastChange()
    }

    /// Called by the view controller whenever the undo stack changes.
    /// Updates the published bindings the SwiftUI toolbar reads.
    ///
    /// **Equality guard** is critical: `@Published` emits on every
    /// assignment regardless of whether the value actually changed.
    /// `attach(_:)` runs from SwiftUI's `updateUIViewController`,
    /// which fires whenever this controller publishes — so blindly
    /// reassigning `canUndo = vc.canUndoChange` here when the value
    /// is unchanged creates a feedback loop (publish → attach →
    /// refreshState → publish). Compare-before-assign breaks the loop.
    func refreshState() {
        let newCanUndo: Bool
        let newCanRedo: Bool
        if let vc = viewController {
            newCanUndo = vc.canUndoChange
            newCanRedo = vc.canRedoChange
        } else {
            newCanUndo = false
            newCanRedo = false
        }
        if canUndo != newCanUndo { canUndo = newCanUndo }
        if canRedo != newCanRedo { canRedo = newCanRedo }
    }
}

@MainActor
extension PDFReaderController {
    func attach(_ vc: PDFReaderViewController) {
        viewController = vc
        vc.controller = self
        // Sync current pen settings to the freshly-attached view
        // controller so the provider applies them to every canvas it
        // builds for this document. These don't mutate `@Published`
        // state, so they're safe to invoke synchronously.
        vc.setPenColor(penColor.uiColor)
        vc.setPenWidth(penWidth.points)
        vc.setEraserActive(isEraserActive)
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
