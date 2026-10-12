import Foundation
#if os(macOS)
import AppKit
#endif

/// Builds Adobe-style layer rows for everything currently on the live program stack.
enum ProgramLayersEngine {
    @MainActor
    static func rows(controller: ShowController) -> [ProgramLayerRow] {
        let stack = controller.compositor.stack
        var output: [ProgramLayerRow] = []

        for canvas in controller.compositor.propCanvases where stack.activeProps.contains(canvas.name) {
            let prop = controller.inspector.props.first(where: { $0.id == canvas.id || $0.name == canvas.name })
            let propID = prop?.id ?? canvas.id
            let slotHidden = stack.isCleared(.props)
            let objects = canvas.objects.sorted { $0.zIndex > $1.zIndex }
            if objects.isEmpty, let prop {
                output.append(row(
                    id: ProgramLayerSyntheticID.propShell(propID),
                    name: prop.name,
                    kind: .shape,
                    detail: "Prop",
                    visible: !slotHidden,
                    locked: controller.compositor.isLayerLocked(.props),
                    zIndex: 6000,
                    target: .activeProp(id: propID)
                ))
            }
            for object in objects {
                var item = CanvasLayerStore.layerItem(from: object)
                item.kindDetail = "Prop · \(canvas.name)"
                if slotHidden { item.isVisible = false }
                output.append(ProgramLayerRow(
                    id: object.id,
                    item: item,
                    target: .propCanvasObject(propID: propID, objectID: object.id)
                ))
            }
        }

        let slideSlotHidden = stack.isCleared(.slide)
        for object in stack.slideCanvas.sorted(by: { $0.zIndex > $1.zIndex }) {
            var item = CanvasLayerStore.layerItem(from: object)
            item.kindDetail = "Slide canvas"
            item.zIndex = 4000 + object.zIndex
            if slideSlotHidden { item.isVisible = false }
            output.append(ProgramLayerRow(
                id: object.id,
                item: item,
                target: .slideCanvasObject(objectID: object.id)
            ))
        }

        if !stack.slideElements.isEmpty {
            for (index, element) in stack.slideElements.enumerated() {
                let snippet = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = snippet.isEmpty ? "Slide text \(index + 1)" : String(snippet.prefix(48))
                output.append(row(
                    id: ProgramLayerSyntheticID.slideLyric(index),
                    name: name,
                    kind: .text,
                    detail: "Slide lyrics",
                    visible: !slideSlotHidden,
                    locked: controller.compositor.isLayerLocked(.slide),
                    zIndex: 4100 - index,
                    target: .slideLyric(index: index)
                ))
            }
        }

        if let media = stack.media {
            let kind: LayerKind = media.isImage ? .image : .video
            #if os(macOS)
            let path = media.filePath ?? ""
            let thumb = media.isImage && !path.isEmpty ? CanvasLayerStore.thumbnailForFilePath(path) : nil
            #else
            let thumb: NSImage? = nil
            #endif
            output.append(row(
                id: ProgramLayerSyntheticID.media,
                name: media.title,
                kind: kind,
                detail: "Program media",
                visible: !stack.isCleared(.media),
                locked: controller.compositor.isLayerLocked(.media),
                zIndex: 3000,
                target: .programMedia,
                thumbnail: thumb
            ))
        }

        if let input = stack.videoInput {
            output.append(row(
                id: ProgramLayerSyntheticID.videoInput,
                name: input.label,
                kind: .camera,
                detail: "Video input",
                visible: !stack.isCleared(.videoInput),
                locked: controller.compositor.isLayerLocked(.videoInput),
                zIndex: 2000,
                target: .programVideoInput
            ))
        }

        for message in stack.messages {
            output.append(row(
                id: message.id,
                name: message.text,
                kind: .text,
                detail: "Message",
                visible: !stack.isCleared(.messages),
                locked: controller.compositor.isLayerLocked(.messages),
                zIndex: 7000,
                target: .outputMessage(id: message.id)
            ))
        }

        if let announcement = stack.announcement, !announcement.isEmpty {
            output.append(row(
                id: ProgramLayerSyntheticID.announcement,
                name: announcement,
                kind: .text,
                detail: "Announcement",
                visible: !stack.isCleared(.announcements),
                locked: controller.compositor.isLayerLocked(.announcements),
                zIndex: 5000,
                target: .outputMessage(id: ProgramLayerSyntheticID.announcement)
            ))
        }

        return output.sorted { $0.item.zIndex > $1.item.zIndex }
    }

    private static func row(
        id: UUID,
        name: String,
        kind: LayerKind,
        detail: String,
        visible: Bool,
        locked: Bool,
        zIndex: Int,
        target: ProgramLayerTarget,
        thumbnail: NSImage? = nil
    ) -> ProgramLayerRow {
        ProgramLayerRow(
            id: id,
            item: CanvasLayerItem(
                id: id,
                name: name,
                kind: kind,
                kindDetail: detail,
                isVisible: visible,
                isLocked: locked,
                zIndex: zIndex,
                thumbnailImage: thumbnail
            ),
            target: target
        )
    }
}
