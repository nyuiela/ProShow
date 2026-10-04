import SwiftUI

/// Shared text box inset + frame alignment for editor, program output, and Core Text encode.
enum CanvasTextBoxLayout {
    static func edgeInsets(for object: CanvasObject, scale: CGFloat) -> EdgeInsets {
        let margins = object.textLayout.margins
        return EdgeInsets(
            top: margins.top * scale,
            leading: margins.left * scale,
            bottom: margins.bottom * scale,
            trailing: margins.right * scale
        )
    }

    /// Document-space content rect inside the element bounds (matches `CoreTextRasterizer` margin inset at scale 1).
    static func documentContentRect(in bounds: CanvasBounds, margins: TextBoxMargins) -> CanvasBounds {
        CanvasBounds(
            x: bounds.x + margins.left,
            y: bounds.y + margins.top,
            width: max(1, bounds.width - margins.left - margins.right),
            height: max(1, bounds.height - margins.top - margins.bottom)
        )
    }

    static let autoFitMaxLines = 20

    /// Frame alignment for text inside the box (editor, program, marquees, static attributed).
    static func frameAlignment(for object: CanvasObject) -> Alignment {
        switch object.textLayout.verticalAlign {
        case .top:
            switch object.textLayout.horizontalAlign {
            case .right: .topTrailing
            case .center: .top
            default: .topLeading
            }
        case .middle:
            switch object.textLayout.horizontalAlign {
            case .right: .trailing
            case .center: .center
            default: .leading
            }
        case .bottom, .baseline:
            switch object.textLayout.horizontalAlign {
            case .right: .bottomTrailing
            case .center: .bottom
            default: .bottomLeading
            }
        }
    }

    /// Vertical box placement for Core Text encode / RTMP (matches `frameAlignment` cross-axis).
    static func coreTextVerticalAlignment(for object: CanvasObject) -> TextVerticalAlign {
        switch object.textLayout.verticalAlign {
        case .top: .top
        case .middle: .middle
        case .bottom, .baseline: .bottom
        }
    }
}

extension View {
    func canvasTextBoxFrame(
        object: CanvasObject,
        width: CGFloat,
        height: CGFloat,
        scale: CGFloat
    ) -> some View {
        padding(CanvasTextBoxLayout.edgeInsets(for: object, scale: scale))
            .frame(width: width, height: height, alignment: CanvasTextBoxLayout.frameAlignment(for: object))
            .clipped()
    }
}
