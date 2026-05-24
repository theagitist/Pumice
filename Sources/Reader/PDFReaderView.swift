import SwiftUI

struct PDFReaderView: UIViewControllerRepresentable {
    let pdfURL: URL

    func makeUIViewController(context: Context) -> PDFReaderViewController {
        let vc = PDFReaderViewController()
        vc.load(url: pdfURL)
        return vc
    }

    func updateUIViewController(_ vc: PDFReaderViewController, context: Context) {
        // The view is rebuilt via .id(url) when the selection changes, so no
        // diffing is needed here.
    }
}
