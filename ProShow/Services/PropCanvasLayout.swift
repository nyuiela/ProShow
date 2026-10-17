import Foundation
import CoreGraphics

/// How a prop's Phone (9:16) canvas is produced.
enum PropPhoneMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Derived from the Stream layout with anchors, inside the Phone safe area.
    case linked
    /// Its own Phone elements (`ProShowProp.phoneElements`).
    case custom
    /// Not drawn on Phone.
    case hidden

    var id: String { rawValue }
    var title: String {
        switch self {
        case .linked: "Linked"
        case .custom: "Custom"
        case .hidden: "Hidden"
        }
    }
}

/// Which outputs draw a prop when it is on.
enum PropOutputTarget: String, Codable, Sendable, CaseIterable, Identifiable {
    case both, stream, phone

    var id: String { rawValue }
    var title: String {
        switch self {
        case .both: "Stream and Phone"
        case .stream: "Stream only"
        case .phone: "Phone only"
        }
    }
    /// Short badge for the Props panel.
    var badge: String {
        switch self {
        case .both: "S P"
        case .stream: "S"
        case .phone: "P"
        }
    }
    var next: PropOutputTarget {
        switch self {
        case .both: .stream
        case .stream: .phone
        case .phone: .both
        }
    }
}

/// Where an element hangs inside the safe area so it adapts to other aspect ratios.
enum PropAnchor: String, Codable, Sendable, CaseIterable, Identifiable {
    case topLeft, top, topRight
    case left, center, right
    case bottomLeft, bottom, bottomRight
    case stretchAcross, stretchDown

    var id: String { rawValue }
    var title: String {
        switch self {
        case .topLeft: "Top left"
        case .top: "Top"
        case .topRight: "Top right"
        case .left: "Left"
        case .center: "Center"
        case .right: "Right"
        case .bottomLeft: "Bottom left"
        case .bottom: "Bottom"
        case .bottomRight: "Bottom right"
        case .stretchAcross: "Stretch across"
        case .stretchDown: "Stretch down"
        }
    }
    /// Anchor point as fractions of the safe area (0 = left/top, 1 = right/bottom).
    var unit: (x: Double, y: Double) {
        switch self {
        case .topLeft: (0, 0)
        case .top: (0.5, 0)
        case .topRight: (1, 0)
        case .left: (0, 0.5)
        case .center: (0.5, 0.5)
        case .right: (1, 0.5)
        case .bottomLeft: (0, 1)
        case .bottom: (0.5, 1)
        case .bottomRight: (1, 1)
        case .stretchAcross: (0.5, 0.5)
        case .stretchDown: (0.5, 0.5)
        }
    }
}

enum PropOutput: Sendable { case stream, phone }

extension ProShowFeatureFlags {
    static let propPhoneAutoFitKey = "proshow.propPhoneAutoFit"
    /// Linked props auto-fit onto Phone. On unless turned off in defaults.
    static var propPhoneAutoFit: Bool {
        get { UserDefaults.standard.object(forKey: propPhoneAutoFitKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: propPhoneAutoFitKey) }
    }
}

/// One place that decides what each output draws for a prop. Program, Phone, the editor and renders all use it.
enum PropCanvasLayout {
    static let streamSize = CGSize(width: 3840, height: 2160)
    static let phoneSize = CGSize(width: 2160, height: 3840)

    static func shows(_ prop: ProShowProp, on output: PropOutput) -> Bool {
        switch output {
        case .stream: return prop.showOn != .phone
        case .phone: return prop.showOn != .stream && phoneObjects(for: prop) != nil
        }
    }

    /// Phone elements for a prop, or nil when Phone draws nothing.
    static func phoneObjects(for prop: ProShowProp) -> [CanvasObject]? {
        switch prop.phoneMode {
        case .hidden:
            return nil
        case .custom:
            guard let phone = prop.phoneElements, !phone.isEmpty else { return nil }
            return phone
        case .linked:
            guard ProShowFeatureFlags.propPhoneAutoFit, !prop.elements.isEmpty else { return nil }
            return autoFit(prop.elements, from: streamSize, to: phoneSize)
        }
    }

    /// Title-safe area: 5% inset, plus room for app chrome at the top and bottom of a tall screen.
    static func safeArea(_ size: CGSize) -> CGRect {
        let tall = size.height > size.width
        let insetX = size.width * 0.05
        let insetY = size.height * (tall ? 0.08 : 0.05)
        return CGRect(x: insetX, y: insetY, width: size.width - insetX * 2, height: size.height - insetY * 2)
    }

    /// Re-places each element by its anchor inside the destination safe area. Elements keep their size
    /// (scaled by the safe areas' shorter sides); only an element wider or taller than the safe area shrinks.
    /// The board as a whole is never scaled down.
    static func autoFit(_ objects: [CanvasObject], from src: CGSize, to dst: CGSize) -> [CanvasObject] {
        let s0 = safeArea(src), s1 = safeArea(dst)
        let scale = min(s1.width, s1.height) / max(1, min(s0.width, s0.height))
        return objects.map { object in
            var o = object
            let t = object.transform
            let x = t.x, y = t.y, w = t.width, h = t.height
            let fullFrame = w >= src.width * 0.9 && h >= src.height * 0.9
            if fullFrame {
                o.transform.x = 0; o.transform.y = 0
                o.transform.width = dst.width; o.transform.height = dst.height
                return o
            }
            let anchor = object.propAnchor ?? .topLeft
            var nw = w * scale, nh = h * scale
            var nx: Double, ny: Double
            func place(_ pos: Double, _ len: Double, _ newLen: Double, _ a: Double, _ from: (Double, Double), _ to: (Double, Double)) -> Double {
                let offset = (pos - from.0 - a * (from.1 - len)) / max(1, from.1)
                return to.0 + a * (to.1 - newLen) + offset * to.1
            }
            if anchor == .stretchAcross {
                let edgeToEdge = x <= src.width * 0.01 && x + w >= src.width * 0.99
                if edgeToEdge {
                    nx = 0; nw = dst.width
                } else {
                    nx = s1.minX + (x - s0.minX) / s0.width * s1.width
                    nw = w / s0.width * s1.width
                }
                ny = place(y, h, nh, 0.5, (s0.minY, s0.height), (s1.minY, s1.height))
            } else if anchor == .stretchDown {
                let edgeToEdge = y <= src.height * 0.01 && y + h >= src.height * 0.99
                if edgeToEdge {
                    ny = 0; nh = dst.height
                } else {
                    ny = s1.minY + (y - s0.minY) / s0.height * s1.height
                    nh = h / s0.height * s1.height
                }
                nx = place(x, w, nw, 0.5, (s0.minX, s0.width), (s1.minX, s1.width))
            } else {
                if nw > s1.width || nh > s1.height {
                    let fit = min(s1.width / nw, s1.height / nh)
                    nw *= fit; nh *= fit
                }
                let a = anchor.unit
                nx = place(x, w, nw, a.x, (s0.minX, s0.width), (s1.minX, s1.width))
                ny = place(y, h, nh, a.y, (s0.minY, s0.height), (s1.minY, s1.height))
                nx = min(max(nx, s1.minX), s1.maxX - nw)
                ny = min(max(ny, s1.minY), s1.maxY - nh)
            }
            let sizeScale = anchor == .stretchAcross || anchor == .stretchDown ? scale : nw / max(1, w)
            o.transform.x = nx; o.transform.y = ny
            o.transform.width = nw; o.transform.height = nh
            o.typography.fontSize = object.typography.fontSize * sizeScale
            return o
        }
    }

    /// Closest anchor for an element, for templates and the agent when none is given.
    static func inferAnchor(for object: CanvasObject, in size: CGSize = streamSize) -> PropAnchor {
        let t = object.transform
        if t.width >= size.width * 0.8 { return .stretchAcross }
        if t.height >= size.height * 0.8 { return .stretchDown }
        let cx = (t.x + t.width / 2) / size.width, cy = (t.y + t.height / 2) / size.height
        let col = cx < 0.34 ? 0 : (cx > 0.66 ? 2 : 1)
        let row = cy < 0.34 ? 0 : (cy > 0.66 ? 2 : 1)
        let grid: [[PropAnchor]] = [[.topLeft, .top, .topRight], [.left, .center, .right], [.bottomLeft, .bottom, .bottomRight]]
        return grid[row][col]
    }

    /// Fresh ids for a Phone copy so its elements can be edited on their own.
    static func freshCopies(_ objects: [CanvasObject]) -> [CanvasObject] {
        objects.map { var o = $0; o.id = UUID(); return o }
    }
}
