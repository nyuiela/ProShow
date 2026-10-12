#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct CaptureBudgetTests {
    @Test
    func compactMachinesDefaultTo720p() {
        #expect(CaptureBudget.prefersCompactOutput(physicalMemory: 8 * 1024 * 1024 * 1024))
        #expect(CaptureBudget.factoryResolution(physicalMemory: 4 * 1024 * 1024 * 1024) == .res720p)
        #expect(CaptureBudget.factoryFrameRate() == .fps30)
    }

    @Test
    func largerMachinesDefaultTo1080p() {
        let sixteen = 16 * 1024 * 1024 * 1024
        #expect(!CaptureBudget.prefersCompactOutput(physicalMemory: sixteen))
        #expect(CaptureBudget.factoryResolution(physicalMemory: sixteen) == .res1080p)
    }

    @Test
    func fourKNeedsSixteenGBOrHardwareHEVC() {
        let four = 4 * 1024 * 1024 * 1024
        let eight = 8 * 1024 * 1024 * 1024
        let sixteen = 16 * 1024 * 1024 * 1024
        #expect(!CaptureBudget.allows4KOutput(physicalMemory: four, hardwareHEVC: false))
        #expect(!CaptureBudget.allows4KOutput(physicalMemory: eight, hardwareHEVC: false))
        #expect(CaptureBudget.allows4KOutput(physicalMemory: eight, hardwareHEVC: true))
        #expect(CaptureBudget.allows4KOutput(physicalMemory: sixteen, hardwareHEVC: false))
        #expect(CaptureBudget.deliveryResolution(.res4K, physicalMemory: four, hardwareHEVC: false) == .res1080p)
        #expect(CaptureBudget.deliveryResolution(.res4K, physicalMemory: sixteen, hardwareHEVC: false) == .res4K)
        #expect(CaptureBudget.deliveryResolution(.res1080p, physicalMemory: four, hardwareHEVC: false) == .res1080p)
    }

    @Test
    func captureMatchesOutputUnlessCropZoomOptsIn() {
        #expect(CaptureBudget.captureLongSide(outputWidth: 1920, outputHeight: 1080, allowAboveOutput: false) == 1920)
        #expect(CaptureBudget.captureLongSide(outputWidth: 1280, outputHeight: 720, allowAboveOutput: false) == 1280)
        #expect(CaptureBudget.captureLongSide(outputWidth: 3840, outputHeight: 2160, allowAboveOutput: false) == 3840)
        #expect(CaptureBudget.captureLongSide(outputWidth: 1920, outputHeight: 1080, allowAboveOutput: true) == 3840)
        #expect(CaptureBudget.captureLongSide(outputWidth: 1280, outputHeight: 720, allowAboveOutput: true) == 1920)
        #expect(CaptureBudget.capturePresetSteps(outputWidth: 1920, outputHeight: 1080, allowAboveOutput: false) == [.hd1080, .hd720, .medium])
        #expect(CaptureBudget.capturePresetSteps(outputWidth: 1280, outputHeight: 720, allowAboveOutput: false) == [.hd720, .medium])
        #expect(CaptureBudget.capturePresetSteps(outputWidth: 3840, outputHeight: 2160, allowAboveOutput: false) == [.uhd4k, .hd1080, .hd720, .medium])
        #expect(CaptureBudget.capturePresetSteps(outputWidth: 1920, outputHeight: 1080, allowAboveOutput: true).first == .uhd4k)
    }
}
