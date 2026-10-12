import Foundation

/// Stage confidence layouts stored as theme-pack variants (`layoutKind: .stage`).
enum StageThemeBridge {
    static func inferLook(from objects: [CanvasObject]) -> StageLookConfig {
        StageLookConfig(
            showCurrent: objects.contains { $0.kind == .currentSlide },
            showNext: objects.contains { $0.kind == .nextSlide },
            showNotes: objects.contains { $0.kind == .stageNotes },
            showClock: objects.contains { $0.kind == .systemClock || $0.kind == .systemDate }
        )
    }

    static func editorDocument(
        from record: ThemeVariantRecord,
        collectionName: String
    ) -> EditorDocument {
        EditorDocument(
            id: record.id,
            name: record.name,
            kind: .stage,
            canvasWidth: CanvasConfig.width,
            canvasHeight: CanvasConfig.height,
            backgroundEnabled: true,
            backgroundHex: "#000000",
            objects: record.objects,
            collectionName: collectionName,
            variantName: record.name
        )
    }

    static func editorDocument(from variant: ThemeVariantDefinition) -> EditorDocument {
        EditorDocument(
            id: variant.id,
            name: variant.name,
            kind: .stage,
            canvasWidth: CanvasConfig.width,
            canvasHeight: CanvasConfig.height,
            backgroundEnabled: true,
            backgroundHex: "#000000",
            objects: variant.blueprint,
            collectionName: "Stage",
            variantName: variant.name
        )
    }

    /// Runtime extras (segment countdown) that are toggled outside the pack blueprint.
    static func applyRuntimeLayout(to document: inout EditorDocument, layout: StageDisplayLayout) {
        document.objects.removeAll { $0.kind == .timerCountdown && $0.timerID == ActionSeedID.serviceTimer }
        guard layout.showCountdown else { return }
        var countdown = CanvasObject(
            name: CanvasObjectKind.timerCountdown.defaultName,
            kind: .timerCountdown,
            bounds: CanvasBounds(x: 160, y: 80, width: 720, height: 140),
            zIndex: 6,
            text: "00:00",
            token: CountdownFormatCatalog.default,
            timerID: ActionSeedID.serviceTimer
        )
        countdown.fill.type = .none
        countdown.stroke.style = .none
        countdown.fontSize = 56
        document.objects.append(countdown)
    }

    static func resolvedLiveDocument(
        variant: ThemeVariantDefinition?,
        stored: EditorDocument?,
        layout: StageDisplayLayout,
        fallbackLook: StageLookConfig
    ) -> EditorDocument {
        if let stored, stored.kind == .stage {
            var copy = stored
            applyRuntimeLayout(to: &copy, layout: layout)
            return copy
        }
        if let variant {
            var document = editorDocument(from: variant)
            applyRuntimeLayout(to: &document, layout: layout)
            return document
        }
        return StageDisplayEngine.document(from: fallbackLook, layout: layout)
    }
}
