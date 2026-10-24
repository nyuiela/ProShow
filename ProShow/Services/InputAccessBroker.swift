import Foundation
#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
import CoreMedia
#endif
#if os(macOS)
import AppKit
import CoreGraphics
#endif

enum ScreenShareTargetKind: String, Hashable, Sendable {
    case display
    case window
}

enum ScreenShareEndpoint {
    static func display(_ id: UInt32) -> String { "sck://display/\(id)" }
    static func window(_ id: UInt32) -> String { "sck://window/\(id)" }

    static func parse(_ raw: String?) -> (kind: ScreenShareTargetKind, id: UInt32)? {
        guard let raw else { return nil }
        if raw.hasPrefix("sck://window/"), let id = UInt32(raw.dropFirst("sck://window/".count)) {
            return (.window, id)
        }
        if raw.hasPrefix("sck://display/"), let id = UInt32(raw.dropFirst("sck://display/".count)) {
            return (.display, id)
        }
        return nil
    }
}

enum ScreenShareCatalog {
    #if os(macOS)
    static func cgDisplayID(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func displayName(for id: UInt32) -> String {
        NSScreen.screens.first { cgDisplayID(of: $0) == id }?.localizedName ?? "Display \(id)"
    }
    #endif

    static func displayItem(id: UInt32, name: String, width: Int? = nil, height: Int? = nil) -> DiscoveredSourceItem {
        let size = (width != nil && height != nil) ? " · \(width!)×\(height!)" : ""
        let heading = name.isEmpty ? "Entire Display \(id)" : name
        return DiscoveredSourceItem(
            id: "sck-display-\(id)",
            name: heading,
            category: .screenCapture,
            groupName: "Displays",
            sourceType: .systemDisplay,
            connectionString: ScreenShareEndpoint.display(id),
            isConnected: true,
            tintHex: "#C8E6FF"
        )
        .with(detail: size)
    }

    static func windowItem(id: UInt32, app: String, title: String) -> DiscoveredSourceItem {
        let heading = title.isEmpty ? app : "\(app) — \(title)"
        return DiscoveredSourceItem(
            id: "sck-window-\(id)",
            name: heading,
            category: .screenCapture,
            groupName: "Windows",
            sourceType: .systemWindow,
            connectionString: ScreenShareEndpoint.window(id),
            isConnected: true,
            tintHex: "#FFE9A8"
        )
    }
}

private extension DiscoveredSourceItem {
    func with(detail: String) -> DiscoveredSourceItem {
        guard !detail.isEmpty else { return self }
        var next = self
        next.name = name + detail
        return next
    }
}

protocol InputAccessRequesting: Sendable {
    func requestCameraAccess() async -> Bool
    func requestMicrophoneAccess() async -> Bool
    func screenShareTargets() async -> [DiscoveredSourceItem]
}

struct SystemInputAccess: InputAccessRequesting {
    func requestCameraAccess() async -> Bool {
        #if canImport(AVFoundation)
        await withCheckedContinuation { continuation in
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                continuation.resume(returning: true)
            case .denied, .restricted:
                continuation.resume(returning: false)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { continuation.resume(returning: $0) }
            @unknown default:
                continuation.resume(returning: false)
            }
        }
        #else
        return false
        #endif
    }

    func requestMicrophoneAccess() async -> Bool {
        #if canImport(AVFoundation)
        await withCheckedContinuation { continuation in
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                continuation.resume(returning: true)
            case .denied, .restricted:
                continuation.resume(returning: false)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            @unknown default:
                continuation.resume(returning: false)
            }
        }
        #else
        return false
        #endif
    }

    func screenShareTargets() async -> [DiscoveredSourceItem] {
        #if os(macOS)
        let granted = await MainActor.run {
            CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        }
        if !granted { return [] }
        #endif
        #if canImport(ScreenCaptureKit)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            var items: [DiscoveredSourceItem] = content.displays.map { display in
                #if os(macOS)
                let name = "Entire Display — \(ScreenShareCatalog.displayName(for: display.displayID))"
                #else
                let name = "Entire Display"
                #endif
                return ScreenShareCatalog.displayItem(
                    id: display.displayID,
                    name: name,
                    width: display.width,
                    height: display.height
                )
            }
            let windows = content.windows
                .filter { window in
                    let app = window.owningApplication?.applicationName ?? ""
                    return !app.isEmpty && app != "Window Server"
                }
                .prefix(48)
            items.append(contentsOf: windows.map { window in
                ScreenShareCatalog.windowItem(
                    id: window.windowID,
                    app: window.owningApplication?.applicationName ?? "App",
                    title: window.title ?? ""
                )
            })
            return items
        } catch {
            return []
        }
        #else
        return []
        #endif
    }
}

#if canImport(ScreenCaptureKit)
enum ScreenCaptureRouting {
    static func isFeedbackWindow(title: String) -> Bool {
        if title == "ProShow Stream" || title == "ProShow MultiViewer" || title == "ProShow Studio" { return true }
        return title.hasPrefix("ProShow Audience") || title.hasPrefix("ProShow Stage")
    }

    static func resolveDisplay(endpoint: String?, content: SCShareableContent) -> SCDisplay? {
        let parsed = ScreenShareEndpoint.parse(endpoint)
        if parsed?.kind == .display {
            if let match = content.displays.first(where: { $0.displayID == parsed?.id }) {
                return match
            }
            if let parsed, content.displays.indices.contains(Int(parsed.id)) {
                return content.displays[Int(parsed.id)]
            }
        }
        return content.displays.first
    }

    /// Built-in display capture goes blank if we exclude the whole ProShow application.
    /// Punch out each ProShow window instead, including the operator desk. `sharingType`
    /// hides panels, but the key window still composites into a same-process full-display share.
    static func filter(endpoint: String?, content: SCShareableContent) -> SCContentFilter? {
        let parsed = ScreenShareEndpoint.parse(endpoint)
        if parsed?.kind == .window, let window = content.windows.first(where: { $0.windowID == parsed?.id }) {
            return SCContentFilter(desktopIndependentWindow: window)
        }
        guard let display = resolveDisplay(endpoint: endpoint, content: content) else { return nil }
        let ours = ProShowStreamCapturePrivacy.applicationWindowNumbers()
        let excluded = content.windows.filter { window in
            if ours.contains(window.windowID) { return true }
            if isFeedbackWindow(title: window.title ?? "") { return true }
            return false
        }
        return SCContentFilter(display: display, excludingWindows: excluded)
    }

    static func shouldPublishFrame(status: SCFrameStatus?, hasPixelBuffer: Bool) -> Bool {
        guard hasPixelBuffer else { return false }
        guard let status else { return true }
        switch status {
        case .complete, .started, .idle:
            return true
        default:
            return false
        }
    }

    /// ScreenCaptureKit reports `.idle` while the captured content is unchanged.
    static func isIdleFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .idle
    }

    static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        let hasPixel = CMSampleBufferGetImageBuffer(sampleBuffer) != nil
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw)
        else {
            return hasPixel
        }
        return shouldPublishFrame(status: status, hasPixelBuffer: hasPixel)
    }
}
#endif

enum HardwareSourceIdentity {
    static func uuid(for token: String?) -> UUID {
        guard let token, !token.isEmpty else { return UUID() }
        if let parsed = UUID(uuidString: token) { return parsed }
        var bytes = [UInt8](repeating: 0, count: 16)
        let data = Array(token.utf8)
        for (index, byte) in data.enumerated() {
            bytes[index % 16] ^= byte
            bytes[(index &+ 5) % 16] &+= byte &* UInt8((index % 13) + 1)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

enum CameraIdentity {
    static func avfUniqueID(from endpoint: String?) -> String? {
        guard let endpoint, endpoint.hasPrefix("avf://") else { return nil }
        let uniqueID = String(endpoint.dropFirst("avf://".count))
        return uniqueID.isEmpty ? nil : uniqueID
    }

    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isSameCamera(
        endpointA: String?,
        nameA: String?,
        endpointB: String?,
        nameB: String?
    ) -> Bool {
        if let left = avfUniqueID(from: endpointA), let right = avfUniqueID(from: endpointB), left == right {
            return true
        }
        guard let nameA, let nameB, !nameA.isEmpty, !nameB.isEmpty else { return false }
        return normalizedName(nameA) == normalizedName(nameB)
    }
}

enum StudioDeviceIdentity {
    static func isSame(_ a: StudioVideoSource, _ b: StudioVideoSource) -> Bool {
        if a.id == b.id { return true }
        if let left = a.endpoint, let right = b.endpoint, !left.isEmpty, !right.isEmpty, left == right {
            return true
        }
        if isCameraFamily(a.kind), isCameraFamily(b.kind) {
            return CameraIdentity.isSameCamera(
                endpointA: a.endpoint,
                nameA: a.label,
                endpointB: b.endpoint,
                nameB: b.label
            )
        }
        if a.kind == .screenShare, b.kind == .screenShare {
            return sameScreen(a.endpoint, b.endpoint)
        }
        if a.kind == .ndi, b.kind == .ndi {
            if let left = a.endpoint, let right = b.endpoint, left == right { return true }
            return CameraIdentity.normalizedName(a.label) == CameraIdentity.normalizedName(b.label)
        }
        return false
    }

    static func canAbsorbPlaceholder(_ placeholder: StudioVideoSource, live: StudioVideoSource) -> Bool {
        guard placeholder.isHardwarePlaceholder else { return false }
        return placeholder.kind == live.kind
    }

    private static func isCameraFamily(_ kind: StudioVideoKind) -> Bool {
        kind == .camera || kind == .continuity || kind == .captureCard
    }

    private static func sameScreen(_ left: String?, _ right: String?) -> Bool {
        guard let leftKind = ScreenShareEndpoint.parse(left),
              let rightKind = ScreenShareEndpoint.parse(right) else {
            return left == right && left != nil
        }
        if leftKind.kind == .display, rightKind.kind == .display, leftKind.id == 0 || rightKind.id == 0 {
            return false
        }
        return leftKind == rightKind
    }
}

enum PrivacySettingsOpener {
    static func openCamera() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
    }

    static func openScreenRecording() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private static func open(_ raw: String) {
        #if os(macOS)
        if let url = URL(string: raw) {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}
