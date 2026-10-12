import Foundation
import Testing
@testable import ProShowCore

struct QRCodeGeneratorTests {
    @Test
    func generatesImageForURL() {
        let image = QRCodeGenerator.cgImage(payload: "https://example.com/live", dimension: 256)
        #expect(image != nil)
        #expect((image?.width ?? 0) > 0)
    }

    @Test
    func emptyPayloadReturnsNil() {
        #expect(QRCodeGenerator.cgImage(payload: "   ", dimension: 128) == nil)
    }

    @Test
    func interpolatesBraceTokensWhenContextProvided() {
        var object = CanvasObject(name: "QR", kind: .qrCode, bounds: .centered(width: 400, height: 400))
        object.text = "https://example.com/{Speaker}"
        var context = DynamicTextContext.empty
        context.fields["Speaker"] = "Alex"
        let payload = QRCodeGenerator.payload(for: object, context: context)
        #expect(payload.contains("Alex"))
        #expect(!payload.contains("{Speaker}"))
    }

    @Test
    func resolvesSegmentURLToken() {
        var object = CanvasObject(name: "QR", kind: .qrCode, bounds: .centered(width: 400, height: 400))
        object.text = "{segment.url}"
        var context = DynamicTextContext.empty
        context.outline.segmentLink = "https://example.com/segment"
        let payload = QRCodeGenerator.payload(for: object, context: context)
        #expect(payload == "https://example.com/segment")
    }
}
