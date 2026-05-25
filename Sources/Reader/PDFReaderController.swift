import Foundation

/// SwiftUI <-> UIKit bridge for the reader. Owns the @Published toolbar
/// state and forwards user actions to the underlying view controller.
@MainActor
final class PDFReaderController: ObservableObject {
    @Published private(set) var canUndo: Bool = false
    @Published private(set) var canRedo: Bool = false

    /// Currently active drawing tool. Each tool keeps its own color
    /// and width below — switching tools doesn't clobber the
    /// destination tool's last choice.
    @Published var activeTool: Tool = .pen {
        didSet {
            guard oldValue != activeTool else { return }
            viewController?.setActiveTool(activeTool)
            applyCurrentToolStyleToVC()
        }
    }

    @Published var penColor: PenColor = .blue {
        didSet {
            guard oldValue != penColor else { return }
            // Picking a pen color while the eraser is active clearly
            // means "I want to draw again." Switch tool back.
            if activeTool != .pen { activeTool = .pen }
            viewController?.setPenColor(penColor.uiColor)
        }
    }
    @Published var penWidth: PenWidth = .medium {
        didSet {
            guard oldValue != penWidth else { return }
            if activeTool != .pen { activeTool = .pen }
            viewController?.setPenWidth(penWidth.points)
        }
    }

    @Published var highlightColor: HighlightPenColor = .yellow {
        didSet {
            guard oldValue != highlightColor else { return }
            if activeTool != .highlighter { activeTool = .highlighter }
            viewController?.setHighlightColor(highlightColor)
        }
    }
    @Published var highlightWidth: HighlightWidth = .medium {
        didSet {
            guard oldValue != highlightWidth else { return }
            if activeTool != .highlighter { activeTool = .highlighter }
            viewController?.setHighlightWidth(highlightWidth.points)
        }
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

    /// Apple Pencil double-tap (Pencil 2 or Pencil Pro) alternates
    /// between pen and highlighter. The double-tap doesn't touch the
    /// eraser — eraser-via-Pencil is a separate held gesture handled
    /// below.
    func alternatePenAndHighlighter() {
        switch activeTool {
        case .pen:         activeTool = .highlighter
        case .highlighter: activeTool = .pen
        case .eraser:      activeTool = .pen
        }
    }

    /// Pencil Pro squeeze-and-hold sets the eraser while held. The
    /// tool the user was on before the squeeze is restored when the
    /// squeeze ends. Pencil 2 (no squeeze hardware) doesn't trigger
    /// this — those users use the toolbar to reach the eraser.
    private var preEraserTool: Tool = .pen

    func beginEraserHold() {
        if activeTool != .eraser {
            preEraserTool = activeTool
            activeTool = .eraser
        }
    }

    func endEraserHold() {
        if activeTool == .eraser {
            activeTool = preEraserTool
        }
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

    fileprivate func applyCurrentToolStyleToVC() {
        guard let vc = viewController else { return }
        vc.setPenColor(penColor.uiColor)
        vc.setPenWidth(penWidth.points)
        vc.setHighlightColor(highlightColor)
        vc.setHighlightWidth(highlightWidth.points)
    }
}

@MainActor
extension PDFReaderController {
    func attach(_ vc: PDFReaderViewController) {
        viewController = vc
        vc.controller = self
        // Sync current tool + per-tool styling so the provider applies
        // them to every canvas it builds for this document. These
        // don't mutate `@Published` state, so they're safe to invoke
        // synchronously.
        vc.setActiveTool(activeTool)
        applyCurrentToolStyleToVC()
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
