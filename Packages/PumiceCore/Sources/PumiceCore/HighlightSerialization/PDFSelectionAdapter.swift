#if canImport(PDFKit) && canImport(UIKit)
import CoreGraphics
import PDFKit

/// Converts a `PDFSelection` (the snap-to-text result of routing a pencil
/// gesture through `PDFPage`) into `Quad` values ready for the highlight
/// builder.
public enum PDFSelectionAdapter {
    /// One quad per visible line in `selection`, each covering that line's
    /// per-page text bounds. Lines with empty bounds (e.g. trailing newline
    /// selections) are skipped so the resulting `/QuadPoints` array always
    /// contains rendered geometry.
    public static func quads(
        from selection: PDFSelection,
        on page: PDFPage
    ) -> [Quad] {
        var out: [Quad] = []
        for line in selection.selectionsByLine() {
            let rect = line.bounds(for: page)
            guard rect.width > 0, rect.height > 0 else { continue }
            out.append(Quad(rect: rect))
        }
        return out
    }
}
#endif
