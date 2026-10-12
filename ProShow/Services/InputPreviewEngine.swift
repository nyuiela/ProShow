import Foundation
import Observation
#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif
#if canImport(CoreImage)
import CoreImage
#endif
#if canImport(CoreVideo)
import CoreVideo
#endif
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
enum InputPreviewMatch {
    static func isProgramLive(endpoint: String?, sourceID: String?, engine: VideoInputEngine) -> Bool {
        engine.isRunning(endpoint: endpoint, sourceID: sourceID)
    }

    static func isProgramLive(_ input: VideoInputSource, engine: VideoInputEngine) -> Bool {
        engine.isRunning(endpoint: input.endpoint, sourceID: input.id.uuidString)
    }
}

#if canImport(AVFoundation)
private final class PreviewSessionBox: @unchecked Sendable {
    var session: AVCaptureSession?
}
#endif

@MainActor
@Observable
final class InputPreviewStore {
    var images: [String: PlatformPreviewImage] = [:]
    var previewSession: AVCaptureSession? {
        get { sessionBox.session }
        set { sessionBox.session = newValue }
    }
    nonisolated(unsafe) private let sessionBox = PreviewSessionBox()
    private var selectedKey: String?

    func image(for item: DiscoveredSourceItem) -> PlatformPreviewImage? {
        images[item.previewKey]
    }

    private var previewEndpoint: String?

    func attachSelection(_ item: DiscoveredSourceItem?, program: VideoInputEngine?) {
        guard let item, item.sourceType == .systemCamera else {
            stopPreviewSession()
            previewEndpoint = nil
            selectedKey = item?.previewKey
            return
        }
        if previewEndpoint == item.connectionString, previewSession?.isRunning == true {
            selectedKey = item.previewKey
            return
        }
        stopPreviewSession()
        selectedKey = item.previewKey
        #if canImport(AVFoundation)
        if Self.isContinuityEndpoint(item.connectionString) { return }
        #endif
        if let program, program.hasLiveCamera(endpoint: item.connectionString, sourceID: item.id, name: item.name) {
            return
        }
        previewEndpoint = item.connectionString
        previewSession = Self.makeCameraSession(endpoint: item.connectionString)
    }

    func shutdown() {
        stopPreviewSession()
    }

    deinit {
        let session = sessionBox.session
        sessionBox.session = nil
        CaptureSessionLifetime.stop(session)
    }

    func refresh(items: [DiscoveredSourceItem], program: VideoInputEngine?) async {
        let targets = items.filter(\.sourceType.showsDevicePreview)
        guard !targets.isEmpty else { return }
        #if canImport(ScreenCaptureKit)
        let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        #else
        let content: Any? = nil
        #endif
        for item in targets {
            if item.sourceType == .systemCamera { continue }
            if let grabbed = await snapshot(item, content: content, program: program) {
                images[item.previewKey] = grabbed
            }
        }
    }

    private func snapshot(
        _ item: DiscoveredSourceItem,
        content: Any?,
        program: VideoInputEngine?
    ) async -> PlatformPreviewImage? {
        if let program,
           InputPreviewMatch.isProgramLive(endpoint: item.connectionString, sourceID: item.id, engine: program),
           let pixel = program.lastPixelBuffer,
           let image = InputPreviewImaging.image(from: pixel) {
            return image
        }
        switch item.sourceType {
        case .systemDisplay, .systemWindow:
            return await screenStill(endpoint: item.connectionString, content: content)
        default:
            return nil
        }
    }

    private func screenStill(endpoint: String?, content: Any?) async -> PlatformPreviewImage? {
        #if canImport(ScreenCaptureKit)
        guard let content = content as? SCShareableContent,
              let filter = ScreenCaptureRouting.filter(endpoint: endpoint, content: content)
        else {
            return legacyScreenStill(endpoint: endpoint)
        }
        let configuration = SCStreamConfiguration()
        configuration.width = 640
        configuration.height = 360
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        do {
            let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return InputPreviewImaging.image(from: cg)
        } catch {
            return legacyScreenStill(endpoint: endpoint)
        }
        #else
        return legacyScreenStill(endpoint: endpoint)
        #endif
    }

    private func legacyScreenStill(endpoint: String?) -> PlatformPreviewImage? {
        #if os(macOS)
        guard let parsed = ScreenShareEndpoint.parse(endpoint) else { return nil }
        if parsed.kind == .display, let cg = CGDisplayCreateImage(CGDirectDisplayID(parsed.id)) {
            return InputPreviewImaging.image(from: cg)
        }
        if parsed.kind == .window {
            let bounds = CGRect.null
            if let cg = CGWindowListCreateImage(bounds, .optionIncludingWindow, parsed.id, [.boundsIgnoreFraming, .bestResolution]) {
                return InputPreviewImaging.image(from: cg)
            }
        }
        #endif
        return nil
    }

    private func stopPreviewSession() {
        #if canImport(AVFoundation)
        let session = previewSession
        previewSession = nil
        previewEndpoint = nil
        CaptureSessionLifetime.stop(session)
        #else
        previewSession = nil
        #endif
    }

    #if canImport(AVFoundation)
    private static func makeCameraSession(endpoint: String?) -> AVCaptureSession? {
        guard let endpoint, endpoint.hasPrefix("avf://") else { return nil }
        let uniqueID = String(endpoint.dropFirst("avf://".count))
        guard let device = AVCaptureDevice(uniqueID: uniqueID),
              !SystemVideoDeviceCatalog.isUnsafeCaptureDevice(name: device.localizedName, uniqueID: device.uniqueID)
        else { return nil }
        let session = AVCaptureSession()
        session.sessionPreset = .medium
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return nil }
        session.addInput(input)
        CaptureSessionLifetime.start(session)
        return session
    }

    static func isContinuityEndpoint(_ endpoint: String?) -> Bool {
        guard let endpoint, endpoint.hasPrefix("avf://") else { return false }
        let uniqueID = String(endpoint.dropFirst("avf://".count))
        guard let device = AVCaptureDevice(uniqueID: uniqueID) else {
            return uniqueID.localizedCaseInsensitiveContains("iphone")
                || uniqueID.localizedCaseInsensitiveContains("continuity")
        }
        return SystemVideoDeviceCatalog.isContinuity(device)
    }
    #endif
}

#if os(macOS)
typealias PlatformPreviewImage = NSImage
#else
typealias PlatformPreviewImage = UIImage
#endif

enum InputPreviewImaging {
    #if canImport(CoreImage)
    private static let context = CIContext(options: [.useSoftwareRenderer: false])
    #endif

    static func image(from pixel: CVPixelBuffer) -> PlatformPreviewImage? {
        guard let cg = cgImage(from: pixel) else { return nil }
        return image(from: cg)
    }

    static func image(from cg: CGImage) -> PlatformPreviewImage {
        #if os(macOS)
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #else
        UIImage(cgImage: cg)
        #endif
    }

    static func cgImage(from pixel: CVPixelBuffer) -> CGImage? {
        #if canImport(CoreImage)
        let ci = CIImage(cvPixelBuffer: pixel)
        return context.createCGImage(ci, from: ci.extent)
        #else
        return nil
        #endif
    }
}

extension DiscoveredSourceItem {
    var previewKey: String {
        connectionString ?? id
    }
}
