import Foundation

extension ShowController {
    var themePackStore: ThemePackStore? {
        guard let root = projectAutosave?.bundle.root else { return nil }
        return ThemePackStore(root: ThemePackStore.themesDirectory(in: root))
    }

    var themeProjectSettings: ThemeProjectSettings {
        get { themeSettingsStorage }
        set {
            themeSettingsStorage = newValue
            syncThemeCatalog()
        }
    }

    var themeMenuVariants: [ThemeVariantDefinition] {
        ThemeVariantRegistry.programVariants
    }

    var stageMenuVariants: [ThemeVariantDefinition] {
        ThemeVariantRegistry.stageVariants
    }

    func activeStageVariant() -> ThemeVariantDefinition? {
        if let id = themeProjectSettings.activeStageVariantID {
            return ThemeVariantRegistry.stageVariant(id: id)
        }
        return ThemeVariantRegistry.defaultStageVariant()
    }

    func reloadThemeLibrary(seedIfEmpty: Bool = true) {
        if let store = themePackStore {
            var loaded = store.loadAll()
            if loaded.isEmpty, seedIfEmpty {
                loaded = [((try? store.ensureBuiltInSeed()) ?? ProShowThemePack.builtIn)]
            }
            themePacksStorage = loaded.isEmpty ? [ProShowThemePack.builtIn] : loaded
        } else {
            themePacksStorage = [ProShowThemePack.builtIn]
        }
        syncThemeCatalog()
    }

    func syncThemeCatalog() {
        let defaults = Dictionary(
            uniqueKeysWithValues: themeProjectSettings.profileDefaults.compactMap { key, value -> (ContentProfile, UUID)? in
                guard let profile = ContentProfile(rawValue: key) else { return nil }
                return (profile, value)
            }
        )
        ThemeVariantRegistry.configure(packs: themePacksStorage, profileDefaults: defaults)
    }

    func activeThemePack() -> ProShowThemePack {
        if let id = themeProjectSettings.activePackID,
           let pack = themePacksStorage.first(where: { $0.id == id }) {
            return pack
        }
        return themePacksStorage.first ?? ProShowThemePack.builtIn
    }

    func themeEditorDocuments(for pack: ProShowThemePack) -> [EditorDocument] {
        pack.variants.filter { $0.layoutKind == .program }.map { variant in
            EditorDocument(
                id: variant.id,
                name: variant.name,
                kind: .theme,
                canvasWidth: CanvasConfig.width,
                canvasHeight: CanvasConfig.height,
                objects: variant.objects,
                collectionName: pack.collectionName,
                variantName: variant.name
            )
        }
    }

    func openThemeEditor() {
        reloadThemeLibrary()
        let pack = activeThemePack()
        editors.openTheme(pack: pack, documents: themeEditorDocuments(for: pack))
    }

    func stageEditorDocuments(for pack: ProShowThemePack) -> [EditorDocument] {
        pack.variants
            .filter { $0.layoutKind == .stage }
            .map { StageThemeBridge.editorDocument(from: $0, collectionName: pack.collectionName) }
    }

    func openStageEditor() {
        reloadThemeLibrary()
        let pack = activeThemePack()
        editors.openStagePack(
            pack: pack,
            documents: stageEditorDocuments(for: pack),
            selectedVariantID: themeProjectSettings.activeStageVariantID
        )
    }

    func syncStagePackFromEditor(persist: Bool = true) {
        guard editors.kind == .stage else { return }
        let packID = themeProjectSettings.activePackID ?? activeThemePack().id
        guard var pack = themePacksStorage.first(where: { $0.id == packID }) else { return }

        var records: [ThemeVariantRecord] = []
        for document in editors.documents where document.kind == .stage {
            let existing = pack.variants.first { $0.id == document.id }
            records.append(
                ThemeVariantRecord(
                    id: document.id,
                    name: document.variantName.isEmpty ? document.name : document.variantName,
                    profile: existing?.profile ?? .generic,
                    layoutKind: .stage,
                    objects: document.objects,
                    audienceLookName: existing?.audienceLookName
                )
            )
        }
        let programRecords = pack.variants.filter { $0.layoutKind == .program }
        pack.variants = programRecords + records
        pack.collectionName = editors.themeCollection
        pack.name = pack.collectionName

        if let index = themePacksStorage.firstIndex(where: { $0.id == pack.id }) {
            themePacksStorage[index] = pack
        } else {
            themePacksStorage.append(pack)
        }
        syncThemeCatalog()

        guard persist, let store = themePackStore else { return }
        try? store.save(pack)
        projectAutosave?.bundle.manifest.themeSettings = themeProjectSettings
        projectAutosave?.markDirty()
    }

    func applyStageVariant(_ variantID: UUID) {
        guard let variant = ThemeVariantRegistry.stageVariant(id: variantID) else { return }
        themeProjectSettings.activeStageVariantID = variantID
        compositor.setStageLook(StageThemeBridge.inferLook(from: variant.blueprint))
        stageDocument = StageThemeBridge.editorDocument(from: variant)
        projectAutosave?.bundle.manifest.themeSettings = themeProjectSettings
        projectAutosave?.markDirty()
    }

    func importThemePack(from url: URL) throws {
        let data = try Data(contentsOf: url)
        var pack = try ProjectJSON.decoder.decode(ProShowThemePack.self, from: data)
        if pack.id == ProShowThemePack.builtInID {
            pack.id = UUID()
        }
        guard let store = themePackStore else { return }
        try store.save(pack)
        reloadThemeLibrary()
        themeProjectSettings.activePackID = pack.id
        projectAutosave?.bundle.manifest.themeSettings = themeProjectSettings
        projectAutosave?.markDirty()
    }

    func exportThemePack(id: UUID, to url: URL) throws {
        guard let pack = themePacksStorage.first(where: { $0.id == id }) ?? ThemeVariantRegistry.pack(id: id) else {
            return
        }
        let data = try ProjectJSON.encoder.encode(pack)
        try data.write(to: url, options: .atomic)
    }

    func exportActiveThemePack(to url: URL) throws {
        try exportThemePack(id: activeThemePack().id, to: url)
    }

    func syncThemePackFromEditor(persist: Bool = true) {
        guard editors.kind == .theme else { return }
        let packID = themeProjectSettings.activePackID ?? activeThemePack().id
        guard var pack = themePacksStorage.first(where: { $0.id == packID }) else { return }

        var records: [ThemeVariantRecord] = []
        for document in editors.documents where document.kind == .theme {
            let profile = ContentProfile.infer(from: Slide(lines: [document.name]), variantName: document.variantName)
            let existing = pack.variants.first { $0.id == document.id }
            records.append(
                ThemeVariantRecord(
                    id: document.id,
                    name: document.variantName.isEmpty ? document.name : document.variantName,
                    profile: existing?.profile ?? profile,
                    layoutKind: .program,
                    objects: document.objects,
                    audienceLookName: existing?.audienceLookName
                )
            )
        }
        let stageRecords = pack.variants.filter { $0.layoutKind == .stage }
        pack.variants = records + stageRecords
        pack.collectionName = editors.themeCollection
        pack.name = pack.collectionName

        if let index = themePacksStorage.firstIndex(where: { $0.id == pack.id }) {
            themePacksStorage[index] = pack
        } else {
            themePacksStorage.append(pack)
        }
        syncThemeCatalog()

        guard persist, let store = themePackStore else { return }
        try? store.save(pack)
        projectAutosave?.bundle.manifest.themeSettings = themeProjectSettings
        projectAutosave?.markDirty()
    }

    func addThemeVariant(named name: String) {
        guard editors.kind == .theme else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let id = UUID()
        let objects = EditorEngine.themeObjects(for: "Lyric Standard")
        editors.insertThemeVariant(
            id: id,
            name: trimmed,
            collectionName: editors.themeCollection,
            objects: objects
        )
        syncThemePackFromEditor(persist: true)
    }

    func applyThemeVariant(_ variant: ThemeVariantDefinition, to slideID: SlideID) {
        applyThemeVariant(variant, toSlideIDs: [slideID])
    }

    func applyThemeVariant(_ variant: ThemeVariantDefinition, toSlideIDs slideIDs: [SlideID]) {
        for slideID in slideIDs {
            mutateSlide(id: slideID) { slide in
                slide.theme = variant.name
                slide.themeVariantID = variant.id
                if slide.themeApplication == .auto {
                    slide.themeApplication = slide.canvas.isEmpty ? .auto : .replace
                }
            }
        }
        applyTheme(variant.name)
        if let liveSlideID, slideIDs.contains(liveSlideID) {
            refreshLiveStack()
        }
    }

    func applyThemeVariantToAllSlidesInShow(_ variant: ThemeVariantDefinition) {
        let ids = show.allSlides.map(\.id)
        applyThemeVariant(variant, toSlideIDs: ids)
    }

    func applyThemeVariantToGroup(containing slideID: SlideID, variant: ThemeVariantDefinition) {
        guard let group = show.groups.first(where: { $0.slides.contains(where: { $0.id == slideID }) }) else {
            applyThemeVariant(variant, to: slideID)
            return
        }
        applyThemeVariant(variant, toSlideIDs: group.slides.map(\.id))
    }

    func setThemeProfileDefault(_ variantID: UUID?, for profile: ContentProfile) {
        themeProjectSettings.setDefault(variantID, for: profile)
        syncThemeCatalog()
        projectAutosave?.bundle.manifest.themeSettings = themeProjectSettings
        projectAutosave?.markDirty()
    }

    func applyThemeProjectSettings(_ settings: ThemeProjectSettings) {
        themeSettingsStorage = settings
        syncThemeCatalog()
        syncOutputScreenThemeBindings()
        if let stageID = settings.activeStageVariantID {
            applyStageVariant(stageID)
        }
    }

    func profileDefaultVariants() -> [ContentProfile: UUID] {
        Dictionary(
            uniqueKeysWithValues: themeProjectSettings.profileDefaults.compactMap { key, value in
                guard let profile = ContentProfile(rawValue: key) else { return nil }
                return (profile, value)
            }
        )
    }

    func themeVariantID(forOutputScreen id: String) -> UUID? {
        if let screen = compositor.stack.outputScreens.first(where: { $0.id == id }),
           let variant = screen.themeVariantID {
            return variant
        }
        return themeProjectSettings.variantID(for: .outputScreen(id: id))
    }

    func themeVariantID(forStreamDestination id: String) -> UUID? {
        themeProjectSettings.variantID(for: .streamDestination(id: id))
    }

    func themeVariantID(forMapPlaceholder id: String) -> UUID? {
        if let tile = placeholderMatrix.placeholders.first(where: { $0.id == id }),
           let variant = tile.themeVariantID {
            return variant
        }
        return themeProjectSettings.variantID(for: .mapPlaceholder(id: id))
    }

    func activeStreamThemeVariantID() -> UUID? {
        themeVariantID(forStreamDestination: ThemeStreamBinding.programDestinationID)
    }

    func setThemeBinding(_ variantID: UUID?, for target: ThemeOutputTarget) {
        themeProjectSettings.setBinding(variantID, for: target)
        syncThemeCatalog()
        syncOutputScreenThemeBindings()
        projectAutosave?.bundle.manifest.themeSettings = themeProjectSettings
        projectAutosave?.markDirty()
    }

    func syncOutputScreenThemeBindings() {
        let settings = deviceSettings.document.screens
        for screen in compositor.stack.outputScreens {
            let config = settings.first(where: { "screen-\($0.displayIndex + 1)" == screen.id })
            let variant =
                config?.themeVariantID ?? themeProjectSettings.variantID(for: .outputScreen(id: screen.id))
            compositor.assignThemeVariant(variant, toScreenID: screen.id)
        }
    }

    func audienceCanvasForProgram(_ slide: Slide) -> [CanvasObject] {
        slide.audienceCanvas()
    }

    func prepareSlideForProgramCue(_ slide: Slide) -> Slide {
        let doc = rundownClock.program ?? programDocument
        let block = ThemeRundownBridge.block(forSlideID: slide.id, in: doc)
        return ThemeRundownBridge.prepareSlide(
            slide,
            block: block,
            profileDefaults: profileDefaultVariants()
        )
    }

    func liveSlideCanvas(variantOverrideID: UUID?) -> [CanvasObject] {
        guard let slide = liveSlide else { return compositor.stack.slideCanvas ?? [] }
        let prepared = prepareSlideForProgramCue(slide)
        let canvas = prepared.audienceCanvas(
            variantOverrideID: variantOverrideID,
            applicationOverride: prepared.themeApplication
        )
        return resolvedCanvasObjects(canvas)
    }

    func stackForProgramEncode(_ stack: RenderStack) -> RenderStack {
        guard let variantID = activeStreamThemeVariantID(), let slide = liveSlide else { return stack }
        var copy = stack
        let canvas = prepareSlideForProgramCue(slide).audienceCanvas(variantOverrideID: variantID)
        if !canvas.isEmpty {
            copy.slideCanvas = resolvedCanvasObjects(canvas)
        }
        return copy
    }
}
