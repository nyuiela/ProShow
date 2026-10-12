import Foundation

/// Figma / Keynote transform-handle physics.
enum TransformHandleEngine {
    static let minSize = 1.0
    static let rotationSnapDegrees = 15.0

    static func shouldLockAspect(
        handle: TransformHandle,
        elementLocked: Bool,
        shiftHeld: Bool
    ) -> Bool {
        handle.isCorner && (elementLocked || shiftHeld)
    }

    static func constrainAspect(_ lockAspect: Bool, shiftHeld: Bool) -> Bool {
        lockAspect || shiftHeld
    }

    static func resize(
        _ bounds: CanvasBounds,
        handle: TransformHandle,
        deltaX: Double,
        deltaY: Double,
        lockAspect: Bool,
        fromCenter: Bool
    ) -> CanvasBounds {
        var x = bounds.x
        var y = bounds.y
        var width = bounds.width
        var height = bounds.height
        let aspect = bounds.width / max(bounds.height, minSize)

        switch handle {
        case .right:
            width = bounds.width + deltaX
        case .left:
            width = bounds.width - deltaX
            x = bounds.x + deltaX
        case .bottom:
            height = bounds.height + deltaY
        case .top:
            height = bounds.height - deltaY
            y = bounds.y + deltaY
        case .bottomRight:
            width = bounds.width + deltaX
            height = bounds.height + deltaY
        case .topRight:
            width = bounds.width + deltaX
            height = bounds.height - deltaY
            y = bounds.y + deltaY
        case .bottomLeft:
            width = bounds.width - deltaX
            height = bounds.height + deltaY
            x = bounds.x + deltaX
        case .topLeft:
            width = bounds.width - deltaX
            height = bounds.height - deltaY
            x = bounds.x + deltaX
            y = bounds.y + deltaY
        default:
            break
        }

        if handle.isMidpoint {
            if handle == .left || handle == .right {
                height = bounds.height
                y = bounds.y
            } else {
                width = bounds.width
                x = bounds.x
            }
        } else if lockAspect, handle.isCorner {
            let scaleX = width / max(bounds.width, minSize)
            let scaleY = height / max(bounds.height, minSize)
            if abs(scaleX - 1) >= abs(scaleY - 1) {
                height = width / max(aspect, 0.0001)
            } else {
                width = height * aspect
            }
            pinOppositeCorner(handle, origin: bounds, width: width, height: height, x: &x, y: &y)
        }

        if fromCenter {
            let dw = width - bounds.width
            let dh = height - bounds.height
            width = bounds.width + dw * 2
            height = bounds.height + dh * 2
            x = bounds.x + bounds.width / 2 - width / 2
            y = bounds.y + bounds.height / 2 - height / 2
        }

        if width < minSize {
            if !fromCenter, handle == .left || handle == .topLeft || handle == .bottomLeft {
                x = bounds.x + bounds.width - minSize
            } else if fromCenter {
                x = bounds.x + bounds.width / 2 - minSize / 2
            }
            width = minSize
        }
        if height < minSize {
            if !fromCenter, handle == .top || handle == .topLeft || handle == .topRight {
                y = bounds.y + bounds.height - minSize
            } else if fromCenter {
                y = bounds.y + bounds.height / 2 - minSize / 2
            }
            height = minSize
        }

        return CanvasBounds(x: x, y: y, width: width, height: height)
    }

    /// Scales a child frame relative to a compound box: Sx = Wnew/Wold, Sy = Hnew/Hold.
    static func scaleChild(
        _ child: CanvasBounds,
        from oldCompound: CanvasBounds,
        to newCompound: CanvasBounds
    ) -> CanvasBounds {
        let scaleX = newCompound.width / max(oldCompound.width, minSize)
        let scaleY = newCompound.height / max(oldCompound.height, minSize)
        return CanvasBounds(
            x: newCompound.x + (child.x - oldCompound.x) * scaleX,
            y: newCompound.y + (child.y - oldCompound.y) * scaleY,
            width: max(minSize, child.width * scaleX),
            height: max(minSize, child.height * scaleY)
        )
    }

    static func rotateChild(
        _ child: CanvasBounds,
        aroundX centerX: Double,
        aroundY centerY: Double,
        degrees: Double
    ) -> CanvasBounds {
        let radians = degrees * .pi / 180
        let dx = child.midX - centerX
        let dy = child.midY - centerY
        let cosA = cos(radians)
        let sinA = sin(radians)
        let midX = centerX + dx * cosA - dy * sinA
        let midY = centerY + dx * sinA + dy * cosA
        return CanvasBounds(
            x: midX - child.width / 2,
            y: midY - child.height / 2,
            width: child.width,
            height: child.height
        )
    }

    static func rotate(
        from startAngle: Double,
        to currentAngle: Double,
        baseRotation: Double,
        snap15: Bool
    ) -> Double {
        var next = baseRotation + (currentAngle - startAngle)
        next = next.truncatingRemainder(dividingBy: 360)
        if next < 0 { next += 360 }
        if snap15 {
            next = (next / rotationSnapDegrees).rounded() * rotationSnapDegrees
        }
        return next
    }

    private static func pinOppositeCorner(
        _ handle: TransformHandle,
        origin: CanvasBounds,
        width: Double,
        height: Double,
        x: inout Double,
        y: inout Double
    ) {
        switch handle {
        case .topLeft:
            x = origin.x + origin.width - width
            y = origin.y + origin.height - height
        case .topRight:
            x = origin.x
            y = origin.y + origin.height - height
        case .bottomLeft:
            x = origin.x + origin.width - width
            y = origin.y
        case .bottomRight:
            x = origin.x
            y = origin.y
        default:
            break
        }
    }
}
