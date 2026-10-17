import Foundation
import SwiftUI

extension ShowController {
    /// Title bar program output line (preview, on air, recording, standby).
    var deskProgramOutputStatusTitle: String {
        if streaming.isLive, isoRecorder.isRecording {
            return ProShowCopy.meta([ProShowCopy.Status.live, ProShowCopy.Status.recording])
        }
        if streaming.isLive {
            return ProShowCopy.Status.live
        }
        if isoRecorder.isRecording {
            return ProShowCopy.Status.recording
        }
        switch evaluateOutputMode() {
        case .live, .liveAndRecording:
            return ProShowCopy.Status.live
        case .recording:
            return ProShowCopy.Status.recording
        case .preview:
            return ProShowCopy.Status.ready
        case .idle:
            if isBroadcasting {
                return ProShowCopy.Status.live
            }
            return ProShowCopy.Status.off
        }
    }

    var deskProgramOutputStatusColor: Color {
        if streaming.isLive || isoRecorder.isRecording {
            return ProShowTheme.liveRed
        }
        if isBroadcasting || wantsEncodedPreview {
            return ProShowTheme.statusOn
        }
        return ProShowTheme.secondaryLabel
    }
    /// Operator / audience SwiftUI surfaces read this revision to avoid stale dynamic text.
    var programFrameRevision: UInt64 {
        FrameRevisionClock.shared.currentRevision
    }

    /// When true, monitors show `program.encode` from `LivePixelHub` (same frame as RTMP / ISO).
    /// Guest return still composites that frame, but the right pane stays on the SwiftUI picture.
    var usesCanonicalProgramMonitor: Bool {
        if liveKitGuestReturnActive, !streaming.isLive, !isoRecorder.isRecording, !streamEncodePreviewEnabled {
            return false
        }
        // Operator-desk preview alone keeps the SwiftUI program picture (same path Backstage uses),
        // so Live paints canvas images without a guest room or encoder session.
        return streamEncodePreviewEnabled || streaming.isLive || isoRecorder.isRecording
    }

    /// Single dynamic-text evaluation per program tick — shared by compositor and SwiftUI fallback.
    @discardableResult
    func prepareAtomicProgramTick(now: Date = Date()) -> ProgramRenderSnapshot {
        let hash = computeRenderStateHash(now: now)
        let advanced = FrameRevisionClock.shared.advance(newHash: hash)
        if advanced {
            programFrameRevisionStamp &+= 1
        }
        let context = dynamicTextContext(now: now)
        let snapshot = ProgramRenderSnapshot(
            revision: FrameRevisionClock.shared.currentRevision,
            stateHash: hash,
            dynamicText: context,
            capturedAt: now
        )
        latestProgramRenderSnapshot = snapshot
        return snapshot
    }

    func computeRenderStateHash(now: Date) -> RenderStateHash {
        let slideID = liveSlideID ?? selectedSlideID ?? show.id
        let context = dynamicTextContext(now: now)
        var hasher = Hasher()
        hasher.combine(compositor.slideRevision)
        hasher.combine(compositor.stack.activeProps.sorted())
        hasher.combine(compositor.stack.generationStamp)
        hasher.combine(liveQuotePresentationStamp)
        for key in context.quotes.keys.sorted() {
            guard let quote = context.quotes[key] else { continue }
            hasher.combine(key)
            hasher.combine(quote.price)
            hasher.combine(quote.changePercent)
            hasher.combine(quote.updatedAt.timeIntervalSince1970)
        }
        for pair in context.fields.sorted(by: { $0.key < $1.key }) {
            hasher.combine(pair.key)
            hasher.combine(pair.value)
        }
        for timer in context.timers {
            hasher.combine(timer.id)
            hasher.combine(timer.displaySeconds)
            hasher.combine(timer.isRunning)
        }
        hasher.combine(context.mediaRemainingSeconds)
        hasher.combine(context.currentSlide)
        hasher.combine(context.nextSlide)
        return RenderStateHash(
            slideID: slideID,
            slideRevision: UInt64(bitPattern: Int64(compositor.slideRevision)),
            propRevision: UInt64(bitPattern: Int64(activePropsRevisionFingerprint())),
            dynamicTokenHash: hasher.finalize()
        )
    }

    private func activePropsRevisionFingerprint() -> Int {
        var hasher = Hasher()
        for name in compositor.stack.activeProps.sorted() {
            hasher.combine(name)
        }
        for prop in inspector.props where prop.isActive {
            hasher.combine(prop.id)
            hasher.combine(prop.elements.count)
        }
        return hasher.finalize()
    }

    func canonicalProgramDynamicText(now: Date = Date()) -> DynamicTextContext {
        latestProgramRenderSnapshot?.dynamicText ?? dynamicTextContext(now: now)
    }
}

private extension RenderStack {
    /// Bumps when layer visibility / clears / media bindings change (compositor `apply` paths).
    var generationStamp: Int {
        var hasher = Hasher()
        for layer in RenderLayer.allCases {
            hasher.combine(isVisible(layer, onStage: false))
            hasher.combine(isCleared(layer))
        }
        hasher.combine(media?.id)
        hasher.combine(videoInput?.id)
        hasher.combine(slideCanvas.count)
        hasher.combine(slideElements.count)
        return hasher.finalize()
    }
}
