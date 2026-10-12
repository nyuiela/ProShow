import Foundation
import Testing
@testable import ProShowCore

struct ThemePackStoreTests {
    @Test
    func roundTripsThemePackOnDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProShowThemeTests-\(UUID().uuidString)", isDirectory: true)
        let store = ThemePackStore(root: root)
        let pack = ProShowThemePack.builtIn
        try store.save(pack)
        let loaded = store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded.first?.variants.count == pack.variants.count)
        #expect(loaded.first?.variants.contains(where: { $0.name == "Lyric Standard" }) == true)
        #expect(loaded.first?.variants.contains(where: { $0.layoutKind == .stage }) == true)
    }

    @Test
    func registryLoadsConfiguredPack() {
        let custom = ProShowThemePack(
            id: UUID(),
            name: "Custom",
            collectionName: "Custom",
            variants: [
                ThemeVariantRecord(
                    id: UUID(),
                    name: "Custom Lyric",
                    profile: .lyricMultiLine,
                    objects: DefaultSeedData.themeObjects(for: "Lyric Standard")
                ),
            ]
        )
        ThemeVariantRegistry.configure(packs: [custom], profileDefaults: [:])
        #expect(ThemeVariantRegistry.programVariants.count == 1)
        #expect(ThemeVariantRegistry.variant(named: "Custom Lyric")?.name == "Custom Lyric")
        ThemeVariantRegistry.configure(packs: [ProShowThemePack.builtIn], profileDefaults: [:])
    }

    @Test
    func stageVariantInfersStageLook() {
        ThemeVariantRegistry.configure(packs: [ProShowThemePack.builtIn], profileDefaults: [:])
        let grid = ThemeVariantRegistry.stageVariant(id: ActionSeedID.layoutGrid)
        #expect(grid != nil)
        let look = StageThemeBridge.inferLook(from: grid!.blueprint)
        #expect(look.showCurrent && look.showNext && look.showNotes && look.showClock)
    }
}
