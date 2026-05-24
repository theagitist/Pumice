import CoreGraphics
import Foundation
import Testing
@testable import PumiceCore

@Suite("HighlightGeometry")
struct HighlightGeometryTests {
    private static let line1 = Quad(rect: CGRect(x: 0, y: 10, width: 5, height: 2))
    private static let line2 = Quad(rect: CGRect(x: 0, y: 5, width: 8, height: 2))

    @Test("quadPointsArray flattens line-by-line")
    func flatten() {
        let flat = HighlightGeometry.quadPointsArray([Self.line1, Self.line2])
        // line1: TL(0,12), TR(5,12), BL(0,10), BR(5,10)
        // line2: TL(0,7),  TR(8,7),  BL(0,5),  BR(8,5)
        #expect(flat.count == 16)
        #expect(Array(flat.prefix(8)) == [0, 12, 5, 12, 0, 10, 5, 10])
        #expect(Array(flat.suffix(8)) == [0, 7, 8, 7, 0, 5, 8, 5])
    }

    @Test("Empty quads list yields empty flat array")
    func emptyFlatten() {
        #expect(HighlightGeometry.quadPointsArray([]).isEmpty)
    }

    @Test("Bounding rect unions all quads")
    func bbUnion() {
        let bb = HighlightGeometry.boundingRect([Self.line1, Self.line2])
        // line1 covers (0,10)..(5,12); line2 covers (0,5)..(8,7);
        // union (0,5)..(8,12)
        #expect(bb == CGRect(x: 0, y: 5, width: 8, height: 7))
    }

    @Test("Bounding rect of empty quads list is .zero")
    func bbEmpty() {
        #expect(HighlightGeometry.boundingRect([]) == .zero)
    }

    @Test("Bounding rect of a single quad matches its boundingRect")
    func bbSingle() {
        #expect(HighlightGeometry.boundingRect([Self.line1]) == Self.line1.boundingRect)
    }
}

@Suite("HighlightColor rgba")
struct HighlightColorRGBATests {
    @Test("Every PRD colour produces a valid RGBA tuple")
    func allColorsValid() {
        for color in HighlightColor.allCases {
            let rgba = color.rgba
            #expect(rgba.alpha == 1.0)
            #expect((0...1).contains(rgba.red))
            #expect((0...1).contains(rgba.green))
            #expect((0...1).contains(rgba.blue))
        }
    }

    @Test("Yellow is bright and red-green dominant")
    func yellowIsYellow() {
        let yellow = HighlightColor.yellow.rgba
        #expect(yellow.red > 0.9)
        #expect(yellow.green > 0.85)
        #expect(yellow.blue < 0.5)
    }

    @Test("Five colours are all distinct")
    func distinctColors() {
        let rgbas = HighlightColor.allCases.map(\.rgba)
        #expect(Set(rgbas).count == rgbas.count)
    }
}

@Suite("HighlightColor closest match")
struct HighlightColorClosestTests {
    @Test("Each colour's own rgba round-trips to itself")
    func exactMatchSelf() {
        for color in HighlightColor.allCases {
            #expect(HighlightColor.closest(to: color.rgba) == color)
        }
    }

    @Test("Tiny RGB perturbations still resolve to the same colour", arguments: [
        HighlightColor.yellow,
        .green,
        .blue,
        .red,
        .purple
    ])
    func robustToPerturbation(_ color: HighlightColor) {
        let base = color.rgba
        let perturbed = StrokeColor(
            red: max(0, min(1, base.red + 0.02)),
            green: max(0, min(1, base.green - 0.02)),
            blue: max(0, min(1, base.blue + 0.01)),
            alpha: base.alpha
        )
        #expect(HighlightColor.closest(to: perturbed) == color)
    }

    @Test("Saturated red picks .red, not yellow")
    func saturatedRed() {
        let red = StrokeColor(red: 0.95, green: 0.10, blue: 0.10, alpha: 1.0)
        #expect(HighlightColor.closest(to: red) == .red)
    }

    @Test("Saturated blue picks .blue")
    func saturatedBlue() {
        let blue = StrokeColor(red: 0.05, green: 0.20, blue: 0.95, alpha: 1.0)
        #expect(HighlightColor.closest(to: blue) == .blue)
    }

    @Test("Alpha is ignored when matching")
    func alphaIgnored() {
        let yellow = HighlightColor.yellow.rgba
        let translucent = StrokeColor(red: yellow.red, green: yellow.green, blue: yellow.blue, alpha: 0.2)
        #expect(HighlightColor.closest(to: translucent) == .yellow)
    }
}

@Suite("Highlight bridge to Annotation")
struct HighlightAnnotationBridgeTests {
    @Test("annotation(uuid:) propagates text/colour/note and uses pageIndex from the highlight")
    func bridgeFields() {
        let uuid = UUID()
        let h = Highlight(
            quads: [Quad(rect: CGRect(x: 0, y: 0, width: 10, height: 10))],
            color: .green,
            pageIndex: 4,
            extractedText: "quoted",
            attachedNote: "thoughts"
        )
        let ann = h.annotation(uuid: uuid)
        #expect(ann.id.pageIndex == 4)
        #expect(ann.extractedText == "quoted")
        #expect(ann.color == .green)
        #expect(ann.attachedNote == "thoughts")
    }

    @Test("Same UUID + page index yields the same AnnotationID across calls")
    func deterministicBridge() {
        let uuid = UUID()
        let h = Highlight(
            quads: [Quad(rect: .zero)],
            color: .yellow,
            pageIndex: 1,
            extractedText: "x"
        )
        #expect(h.annotation(uuid: uuid).id == h.annotation(uuid: uuid).id)
    }
}
