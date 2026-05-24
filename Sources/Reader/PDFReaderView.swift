import SwiftUI

struct PDFReaderView: UIViewControllerRepresentable {
    let pdfURL: URL
    @ObservedObject var controller: PDFReaderController

    func makeUIViewController(context: Context) -> PDFReaderViewController {
        let vc = PDFReaderViewController()
        vc.load(url: pdfURL)
        controller.attach(vc)
        return vc
    }

    func updateUIViewController(_ vc: PDFReaderViewController, context: Context) {
        controller.attach(vc)
    }
}
