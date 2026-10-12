import Foundation
import Testing
@testable import ProShowCore

struct CanvasShimmerTests {
    @Test
    func shimmer_defaultsOffAndDecodesMissingKey() throws {
        let object = CanvasObject(name: "T", kind: .text, bounds: .centered(width: 100, height: 40))
        #expect(object.resolvedShimmer.enabled == false)

        let json = """
        {"id":"\(object.id.uuidString)","name":"T","kind":"text","zIndex":0,"text":"","token":"","warningThresholds":[],"transform":{"x":0,"y":0,"width":100,"height":40,"rotation":0,"flipHorizontal":false,"flipVertical":false},"fill":{"type":"color","color":"#FFFFFF"},"stroke":{"style":"none","color":"#FFFFFF","width":2,"position":"outside","cornerRadius":0},"shadow":{"enabled":false,"color":"#80000000","angle":315,"offset":5,"blur":10,"feather":0},"typography":{"fontFamily":"Inter","fontWeight":"bold","fontSize":48,"color":"#FFFFFF","isBold":true,"isItalic":false,"isUnderline":false,"isStrikethrough":false,"isSuperscript":false,"isSubscript":false,"textTransform":"none"},"textLayout":{"horizontalAlign":"left","verticalAlign":"top","lineHeight":1.2,"characterSpacing":0,"wordSpacing":0,"paragraphSpacingBefore":0,"paragraphSpacingAfter":0,"margins":{"top":10,"bottom":10,"left":15,"right":15},"listType":"none","autoFitMode":"shrink"},"textOutline":{"enabled":false,"color":"#000000","width":0},"textShadow":{"enabled":false,"color":"#80000000","angle":315,"offset":0,"blur":0},"build":{"buildIn":"Dissolve","buildOut":"Dissolve","buildOrder":0},"opacity":1,"visibleOnAudience":true,"visibleOnStage":true,"isCanvasLocked":false}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CanvasObject.self, from: json)
        #expect(decoded.shimmer == nil)
        #expect(decoded.resolvedShimmer.enabled == false)
    }

    @Test
    func shimmer_phaseWraps() {
        let phase = CanvasShimmerMath.phase(at: Date(timeIntervalSinceReferenceDate: 5.5), cycleDuration: 2)
        #expect(phase >= 0 && phase < 1)
    }
}
