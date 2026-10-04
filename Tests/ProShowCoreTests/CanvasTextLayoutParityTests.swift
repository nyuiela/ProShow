import Foundation
import Testing
@testable import ProShowCore

@Suite
struct CanvasTextLayoutParityTests {
    @Test
    func textBoxInsets_matchDocumentContentRect() {
        let bounds = CanvasBounds(x: 100, y: 200, width: 400, height: 120)
        var object = CanvasObject(name: "Title", kind: .text, bounds: bounds)
        object.textLayout.margins = TextBoxMargins(top: 12, bottom: 8, left: 16, right: 24)

        let content = CanvasTextBoxLayout.documentContentRect(in: bounds, margins: object.textLayout.margins)
        #expect(content.x == 116)
        #expect(content.y == 212)
        #expect(content.width == 360)
        #expect(content.height == 100)

        let insets = CanvasTextBoxLayout.edgeInsets(for: object, scale: 1)
        #expect(insets.top == 12)
        #expect(insets.leading == 16)
        #expect(insets.bottom == 8)
        #expect(insets.trailing == 24)
    }

    @Test
    func frameAlignment_baselineMatchesBottomLeading() {
        var object = CanvasObject(name: "T", kind: .text, bounds: .init(x: 0, y: 0, width: 200, height: 80))
        object.textLayout.verticalAlign = .baseline
        object.textLayout.horizontalAlign = .left
        #expect(CanvasTextBoxLayout.frameAlignment(for: object) == .bottomLeading)
    }

    @Test
    func frameAlignment_middleCenter() {
        var object = CanvasObject(name: "T", kind: .text, bounds: .init(x: 0, y: 0, width: 200, height: 80))
        object.textLayout.verticalAlign = .middle
        object.textLayout.horizontalAlign = .center
        #expect(CanvasTextBoxLayout.frameAlignment(for: object) == .center)
    }

    @Test
    func coreTextVerticalAlignment_baselineMatchesBottom() {
        var object = CanvasObject(name: "T", kind: .text, bounds: .init(x: 0, y: 0, width: 200, height: 80))
        object.textLayout.verticalAlign = .baseline
        #expect(CanvasTextBoxLayout.coreTextVerticalAlignment(for: object) == .bottom)
    }
}
