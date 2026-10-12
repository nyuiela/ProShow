import CoreGraphics
#if canImport(CoreImage)
import CoreImage
import CoreImage.CIFilterBuiltins
#endif

enum QRCodeGenerator {
    static func payload(for object: CanvasObject, context: DynamicTextContext?) -> String {
        let seed = object.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? object.token.trimmingCharacters(in: .whitespacesAndNewlines)
            : object.text
        guard let context else { return seed }
        return DynamicTextEngine.interpolate(seed, context: context)
    }

    static func cgImage(payload: String, dimension: Int = 512) -> CGImage? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        #if canImport(CoreImage)
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(trimmed.utf8)
        filter.correctionLevel = "M"
        guard var output = filter.outputImage else { return nil }
        let target = max(64, dimension)
        let scale = CGFloat(target) / max(output.extent.width, 1)
        output = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let color = CIFilter.falseColor()
        color.inputImage = output
        color.color0 = CIColor.white
        color.color1 = CIColor.black
        guard let colored = color.outputImage else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(colored, from: colored.extent)
        #else
        return nil
        #endif
    }
}

#if canImport(SwiftUI)
import SwiftUI

struct QRCodeCanvasView: View {
    var payload: String
    @Environment(\.dynamicText) private var dynamicText

    private var encodedPayload: String {
        DynamicTextEngine.interpolate(payload, context: dynamicText)
    }

    var body: some View {
        if let image = QRCodeGenerator.cgImage(payload: encodedPayload, dimension: 512) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.none)
                .aspectRatio(1, contentMode: .fit)
        } else {
            ZStack {
                Color.white
                VStack(spacing: 6) {
                    Image(systemName: "qrcode")
                        .font(.title2)
                    Text("QR Code")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.black.opacity(0.45))
            }
        }
    }
}
#endif
