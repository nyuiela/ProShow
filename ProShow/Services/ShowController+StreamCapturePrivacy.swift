import Foundation

#if os(macOS)
import AppKit
#endif

extension ShowController {
    /// Display (not single-window) ScreenCaptureKit feed — the operator desk must not appear in the share.
    var concealsDeskFromDisplayScreenCapture: Bool {
        hasActiveDisplayScreenCapture()
    }

    func hasActiveDisplayScreenCapture() -> Bool {
        if let input = compositor.stack.videoInput {
            let endpoint = (input.endpoint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if endpoint.hasPrefix("sck://display/"),
               videoInputs.isRunning(endpoint: endpoint, sourceID: input.id.uuidString) {
                return true
            }
        }
        for key in videoInputs.ingest.liveCaptureLaneKeys() where key.hasPrefix("sck://display/") {
            return true
        }
        if canvasUsesLiveDisplayScreenCapture() {
            return true
        }
        return false
    }

    func syncStreamCapturePrivacyIfNeeded() {
        if streaming.isLive {
            videoInputs.applyLiveStreamScreenCaptureContract(
                width: streaming.config.width,
                height: streaming.config.height,
                fps: streaming.config.framerate
            )
        }
        #if os(macOS)
        ProShowStreamCapturePrivacy.pinFeedbackWindowsOutOfCapture()
        let active = concealsDeskFromDisplayScreenCapture
        if active {
            // Re-apply every tick. A Space change restores sharingType after the stream restarts,
            // which put the operator desk back into the capture.
            ProShowStreamCapturePrivacy.applyOperatorDeskConcealment(active: true)
        }
        if active != streamCapturePrivacyEngaged {
            streamCapturePrivacyEngaged = active
            if active {
                displayCaptureExclusionRefreshPending = true
            } else {
                ProShowStreamCapturePrivacy.applyOperatorDeskConcealment(active: false)
            }
        }
        if displayCaptureExclusionRefreshPending, active {
            displayCaptureExclusionRefreshPending = false
            videoInputs.refreshDisplayScreenCaptureExclusions()
        }
        videoInputs.ingest.reviveStalledScreenCaptures()
        #endif
    }

    func resetStreamCapturePrivacy() {
        videoInputs.clearLiveStreamScreenCaptureContract()
        #if os(macOS)
        streamCapturePrivacyEngaged = false
        displayCaptureExclusionRefreshPending = false
        ProShowStreamCapturePrivacy.applyOperatorDeskConcealment(active: false)
        ProShowStreamCapturePrivacy.pinFeedbackWindowsOutOfCapture()
        #endif
    }

    private func canvasUsesLiveDisplayScreenCapture() -> Bool {
        func usesDisplay(_ object: CanvasObject) -> Bool {
            guard object.visibleOnAudience else { return false }
            let endpoint = object.assignedSource?.connectionString
                ?? (object.kind.isBrowserLike ? nil : object.fill.imageURI)
            let trimmed = endpoint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard trimmed.hasPrefix("sck://display/") else { return false }
            return videoInputs.isRunning(endpoint: trimmed, sourceID: object.assignedSource?.sourceID)
        }
        if compositor.stack.slideCanvas.contains(where: usesDisplay) { return true }
        for canvas in compositor.propCanvases where compositor.stack.activeProps.contains(canvas.name) {
            if canvas.objects.contains(where: usesDisplay) { return true }
        }
        return false
    }
}
