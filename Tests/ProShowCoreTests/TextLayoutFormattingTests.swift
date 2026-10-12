import XCTest
@testable import ProShowCore
#if os(macOS)
final class TextLayoutFormattingTests: XCTestCase {
    func testAttributedStringAppliesParagraphAndWordSpacing() {
        var object = CanvasObject(
            name: "Body",
            kind: .text,
            bounds: .init(x: 0, y: 0, width: 400, height: 200)
        )
        object.text = "Line one\nLine two"
        object.textLayout.lineHeight = 1.5
        object.textLayout.characterSpacing = 2
        object.textLayout.wordSpacing = 6
        object.textLayout.paragraphSpacingBefore = 4
        object.textLayout.paragraphSpacingAfter = 8
        object.textLayout.firstLineIndent = 12

        let attributed = TextAttributeConverter.makeAttributedString(
            object: object,
            text: object.text,
            scale: 1
        )
        let paragraph = attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(paragraph?.lineHeightMultiple ?? 0, 1.5, accuracy: 0.001)
        XCTAssertEqual(paragraph?.paragraphSpacingBefore ?? 0, 4, accuracy: 0.001)
        XCTAssertEqual(paragraph?.paragraphSpacing ?? 0, 8, accuracy: 0.001)
        XCTAssertEqual(paragraph?.firstLineHeadIndent ?? 0, 12, accuracy: 0.001)

        let kern = attributed.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat
        XCTAssertEqual(kern ?? 0, 2, accuracy: 0.001)

        let spaceIndex = (object.text as NSString).range(of: " ").location
        XCTAssertGreaterThan(spaceIndex, 0)
        let spaceKern = attributed.attribute(.kern, at: spaceIndex, effectiveRange: nil) as? CGFloat
        XCTAssertEqual(spaceKern ?? 0, 6, accuracy: 0.001)
    }
}
#endif
