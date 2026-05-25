import SwiftUI
import UIKit

/// One drawn stroke. Carries enough information to render itself
/// faithfully (path, color, width) and to be hit-tested for erasing.
///
/// The path is held by reference (`UIBezierPath` is `NSObject`-rooted)
/// so we can use `===` for undo/redo identity and for "which stroke
/// did the eraser cross."
struct StrokeRecord {
    let path: UIBezierPath
    let color: UIColor
    let width: CGFloat
}

/// Fixed palette of pen colors offered in the reader toolbar.
///
/// Every entry resolves to a non-dynamic `UIColor`. Dynamic colors
/// (like `.label`) would cause `CAShapeLayer` to capture a wrong-or-
/// transparent CGColor at assignment time and never re-resolve when
/// the trait collection changes — see `PDFKit gotchas.md` in the
/// vault for the full writeup.
enum PenColor: String, CaseIterable, Identifiable, Hashable {
    case blue
    case red
    case green
    case orange
    case yellow
    case black

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blue:   return "Blue"
        case .red:    return "Red"
        case .green:  return "Green"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .black:  return "Black"
        }
    }

    var uiColor: UIColor {
        switch self {
        case .blue:   return .systemBlue
        case .red:    return .systemRed
        case .green:  return .systemGreen
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .black:  return .black
        }
    }

    var swiftUIColor: Color { Color(uiColor: uiColor) }

    /// Asset-catalog image of a filled circle in this pen color.
    /// SwiftUI's `Menu` bridges to UIKit's `UIMenu` and drops custom
    /// SwiftUI modifiers (`.foregroundStyle`, `.tint`) and Shape views
    /// off Picker option labels — only the title text and the
    /// asset-resolved UIImage survive. We bake the color into the PNG
    /// so the swatches render the way they're drawn.
    var swatchAssetName: String {
        switch self {
        case .blue:   return "SwatchBlue"
        case .red:    return "SwatchRed"
        case .green:  return "SwatchGreen"
        case .orange: return "SwatchOrange"
        case .yellow: return "SwatchYellow"
        case .black:  return "SwatchBlack"
        }
    }
}

/// Fixed list of stroke widths. Keeping it discrete instead of a
/// continuous slider avoids fat-finger jitter inside a popover menu.
enum PenWidth: String, CaseIterable, Identifiable, Hashable {
    case thin
    case medium
    case thick

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .thin:   return "Thin"
        case .medium: return "Medium"
        case .thick:  return "Thick"
        }
    }

    var points: CGFloat {
        switch self {
        case .thin:   return 1.5
        case .medium: return 3
        case .thick:  return 6
        }
    }

    /// Asset-catalog image of a horizontal line at this width's
    /// pen-point thickness. Rendered as a template image so the menu
    /// tints it with the row's foreground color (visible in both
    /// light and dark mode). Same UIMenu-bridge constraint as the
    /// `PenColor.swatchAssetName` rationale.
    var iconAssetName: String {
        switch self {
        case .thin:   return "WidthThin"
        case .medium: return "WidthMedium"
        case .thick:  return "WidthThick"
        }
    }
}
