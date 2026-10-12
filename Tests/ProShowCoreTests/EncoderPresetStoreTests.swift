#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct EncoderPresetStoreTests {
    @Test
    func presets_matchPlatformGuidelines() {
        let ultra = StreamEncoderPreset.ultra4k30.config
        #expect(ultra.width == 3840 && ultra.height == 2160 && ultra.frameRate == 30)
        #expect(ultra.targetBitrateBps == 15_000_000)
        #expect(ultra.maxBitrateCeilingBps == 18_000_000)
        #expect(ultra.audioBitrateBps == 256_000)
        #expect(ultra.keyframeIntervalSeconds == 2)

        let high = StreamEncoderPreset.high1080p60.config
        #expect(high.width == 1920 && high.height == 1080 && high.frameRate == 60)
        #expect(high.targetBitrateBps == 6_000_000)
        #expect(high.maxBitrateCeilingBps == 7_200_000)
        #expect(high.audioBitrateBps == 192_000)

        let standard = StreamEncoderPreset.standard1080p30.config
        #expect(standard.targetBitrateBps == 4_500_000)
        #expect(standard.maxBitrateCeilingBps == 5_400_000)
        #expect(standard.audioBitrateBps == 160_000)

        let saver = StreamEncoderPreset.saver720p30.config
        #expect(saver.targetBitrateBps == 2_500_000)
        #expect(saver.maxBitrateCeilingBps == 3_000_000)
        #expect(saver.keyframeIntervalSeconds == 2.0)

        let fallback = StreamEncoderPreset.fallback480p30.config
        #expect(fallback.width == 854 && fallback.height == 480)
        #expect(fallback.targetBitrateBps == 1_200_000)
        #expect(fallback.audioBitrateBps == 96_000)
        #expect(StreamEncoderPreset.named("480p30 Low-BW") == .fallback480p30)
        #expect(StreamEncoderConfig().presetName == StreamEncoderPreset.standard1080p30.rawValue)
    }

    @Test
    func ingestPolicies_capSharedEncodeToStrictestDestination() {
        let ultra = StreamEncoderPreset.ultra4k30.config
        let twitch = ultra.clamped(to: [.twitch])
        #expect(twitch.targetBitrateBps == 6_000_000)
        #expect(twitch.maxBitrateCeilingBps == 6_000_000)
        #expect(twitch.keyframeIntervalSeconds == 2)
        #expect(twitch.width == 3840)

        var hot = StreamEncoderPreset.high1080p60.config
        hot.targetBitrateBps = 10_000_000
        hot.maxBitrateCeilingBps = 12_000_000
        let kick = hot.clamped(to: [.kick])
        #expect(kick.targetBitrateBps == 8_000_000)
        #expect(kick.maxBitrateCeilingBps == 8_000_000)

        let facebook = StreamEncoderPreset.standard1080p30.config.clamped(to: [.facebook])
        #expect(facebook.targetBitrateBps == 4_500_000)
        #expect(facebook.audioBitrateBps == 128_000)

        let youtube = ultra.clamped(to: [.youtube])
        #expect(youtube.targetBitrateBps == 15_000_000)
        #expect(PlatformIngestPolicy.detect(platform: .customRtmp, ingestURL: "rtmp://live.twitch.tv/app") == .twitch)
    }

    @Test
    func ceilingNeverBelowTarget() {
        var custom = StreamEncoderConfig.preset720p30Saver()
        custom.applyCustomTargetKbps(3500, ceiling: 3000)
        #expect(custom.targetBitrateBps == 3_500_000)
        #expect(custom.maxBitrateCeilingBps >= custom.targetBitrateBps)
    }

    @Test @MainActor
    func applyStreamEncoderConfig_updatesRtmpConfig() {
        let engine = StreamingEngine()
        var preset = StreamEncoderPreset.standard1080p30.config
        engine.applyStreamEncoderConfig(preset)
        #expect(engine.config.width == 1920)
        #expect(engine.config.bitrateKbps == 4_500)
        #expect(engine.encoderSettings?.audioBitrateKbps == 160)
        preset.targetBitrateBps = 5_000_000
        preset.maxBitrateCeilingBps = 6_000_000
        engine.applyStreamEncoderConfig(preset)
        #expect(engine.config.bitrateKbps == 5_000)
    }
}
