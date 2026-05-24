import Foundation

/// Thin SwiftUI <-> UIKit bridge for the reader. Keeps a weak reference to
/// the live `PDFReaderViewController` so SwiftUI parents can trigger save
/// lifecycle hooks (e.g. on `scenePhase` transitions) without coupling
/// directly to the UIKit view controller's lifetime.
@MainActor
final class PDFReaderController: ObservableObject {
    fileprivate weak var viewController: PDFReaderViewController?

    func saveIfNeeded() {
        viewController?.saveIfNeeded()
    }
}

@MainActor
extension PDFReaderController {
    func attach(_ vc: PDFReaderViewController) {
        viewController = vc
    }
}
