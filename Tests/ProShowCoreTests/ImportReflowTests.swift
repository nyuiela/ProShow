#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct ImportReflowTests {
    @Test
    func rejectsProPresenterPacks() {
        #expect(throws: ImportReflowError.unsupportedProPresenter) {
            try ImportReflowEngine.import(data: Data("not-a-pro-file".utf8), name: "Song", pathExtension: "pro")
        }
    }

    @Test
    func lyricReflow_wrapsVerseAndChorus() {
        let lyrics = """
        [Verse]
        Line one
        Line two
        Line three
        Line four
        Line five
        [Chorus]
        Lift it up
        Sing it out
        """
        let group = ImportReflowEngine.reflowLyrics(lyrics, linesPerSlide: 4)
        #expect(group.slides.count == 3)
        #expect(group.slides[0].label == "verse")
        #expect(group.slides[0].lines.count == 4)
        #expect(group.slides[1].lines == ["Line five"])
        #expect(group.slides[2].label == "chorus")
    }

    @Test
    func scriptureReflow_usesCanon() {
        let group = ImportReflowEngine.reflowScripture("John 3:16")
        #expect(group.slides.isEmpty == false)
        #expect(group.slides[0].title.contains("John"))
    }

    @Test
    func chords_stageKeepsTokens_audienceStrips() {
        let line = "Amazing [C]grace how [G]sweet"
        #expect(StageDisplayEngine.stripChordTokens(line) == "Amazing grace how sweet")
        #expect(StageDisplayEngine.overlayChords(in: line, semitones: 2) == "Amazing [D]grace how [A]sweet")
        #expect(StageDisplayEngine.shouldPublishNDI(
            layout: StageDisplayLayout(
                showCurrent: true,
                showNext: true,
                showClock: true,
                showCountdown: true,
                showAlertBanner: true,
                showChords: false,
                ndiOutputEnabled: true,
                chordSemitones: 0
            ),
            outputName: "PROSHOW-STAGE",
            runtimeAvailable: true
        ))
        #expect(!StageDisplayEngine.shouldPublishNDI(
            layout: .standard,
            outputName: "PROSHOW-STAGE",
            runtimeAvailable: true
        ))
    }
}
