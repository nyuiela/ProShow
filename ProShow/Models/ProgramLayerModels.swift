import Foundation

/// Identifies a row in the program Layers panel for routing visibility, lock, rename, and delete.
enum ProgramLayerTarget: Hashable, Sendable {
    case slideCanvasObject(objectID: UUID)
    case propCanvasObject(propID: UUID, objectID: UUID)
    case programMedia
    case programVideoInput
    case slideLyric(index: Int)
    case outputMessage(id: UUID)
    case activeProp(id: UUID)
}

struct ProgramLayerRow: Identifiable, Sendable {
    var id: UUID
    var item: CanvasLayerItem
    var target: ProgramLayerTarget
}

enum ProgramLayerSyntheticID {
    static let media = UUID(uuidString: "A0000001-0001-4001-8001-000000000001")!
    static let videoInput = UUID(uuidString: "A0000001-0001-4001-8001-000000000002")!
    static let announcement = UUID(uuidString: "A0000001-0001-4001-8001-000000000003")!

    static func slideLyric(_ index: Int) -> UUID {
        let i = UInt32(truncatingIfNeeded: index)
        return UUID(uuid: (
            0xA0, 0x00, 0x01, 0x00, 0x40, 0x00, 0x80, 0x00,
            0, 0, 0, 0,
            UInt8(i >> 24), UInt8(i >> 16), UInt8(i >> 8), UInt8(i)
        ))
    }

    static func propShell(_ propID: UUID) -> UUID {
        let u = propID.uuid
        return UUID(uuid: (
            0xA0, 0x00, 0x02, 0x00, 0x40, 0x00, 0x80, 0x00,
            u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15
        ))
    }
}
