import Foundation

/// Factory contract for newly created canvas objects.
enum ShapeDefaults {
    static let fillAccent = "#2F6FED"
    static let fillWhite = "#FFFFFF"
    static let textColor = "#FFFFFF"
    static let textSize = 48.0
    static let systemFontFamily = ""
    static let clearStroke = "#00000000"
    static let textShadowColor = "#80000000"

    static func apply(_ object: inout CanvasObject) {
        if object.isTextLike {
            applyText(&object)
        } else {
            applyShape(&object)
        }
    }

    static func applyShape(_ object: inout CanvasObject) {
        object.stroke.style = .none
        object.stroke.width = 0
        object.stroke.color = clearStroke
        object.shadow.enabled = false
        switch object.kind {
        case .image, .videoInput, .webView, .browser:
            if object.fill.imageURI.isEmpty {
                object.fill.type = .none
            }
            object.transform.lockAspectRatio = true
        case .ellipse, .cutout:
            object.fill.type = .color
            object.fill.color = fillAccent
            object.fill.opacity = 1
            object.transform.lockAspectRatio = true
            applyEllipseRadius(&object)
        case .rectangle, .roundedRectangle, .maskShape:
            object.fill.type = .color
            object.fill.color = fillAccent
            object.fill.opacity = 1
            object.stroke.cornerRadius = 0
            object.stroke.corners = .uniform(0)
            object.transform.lockAspectRatio = false
        default:
            object.fill.type = .color
            object.fill.color = fillAccent
            object.fill.opacity = 1
            object.transform.lockAspectRatio = false
        }
    }

    static func applyText(_ object: inout CanvasObject) {
        object.fill.type = .none
        object.stroke.style = .none
        object.stroke.width = 0
        object.stroke.color = clearStroke
        object.shadow.enabled = false
        object.transform.lockAspectRatio = false
        object.typography.fontFamily = systemFontFamily
        if object.kind == .text {
            object.typography.fontSize = textSize
        }
        object.typography.fontWeight = .bold
        object.typography.isBold = true
        object.typography.color = textColor
        object.textLayout.horizontalAlign = .center
        object.textLayout.verticalAlign = .middle
        object.textShadow.enabled = true
        object.textShadow.color = textShadowColor
        object.textShadow.angle = 90
        object.textShadow.offset = 2
        object.textShadow.blur = 4
    }

    static func applyEllipseRadius(_ object: inout CanvasObject) {
        let radius = min(object.bounds.width, object.bounds.height) / 2
        object.stroke.cornerRadius = radius
        object.stroke.corners = .uniform(radius)
    }
}
