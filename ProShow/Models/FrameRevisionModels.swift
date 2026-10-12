import Foundation

struct RenderStateHash: Equatable, Sendable {
    var slideID: UUID
    var slideRevision: UInt64
    var propRevision: UInt64
    var dynamicTokenHash: Int

    var combinedHashKey: String {
        "\(slideID.uuidString)-\(slideRevision)-\(propRevision)-\(dynamicTokenHash)"
    }
}

struct ProgramRenderSnapshot: Sendable {
    var revision: UInt64
    var stateHash: RenderStateHash
    var dynamicText: DynamicTextContext
    var capturedAt: Date

    static let empty = ProgramRenderSnapshot(
        revision: 0,
        stateHash: RenderStateHash(
            slideID: UUID(),
            slideRevision: 0,
            propRevision: 0,
            dynamicTokenHash: 0
        ),
        dynamicText: .empty,
        capturedAt: .distantPast
    )
}

extension Notification.Name {
    static let proShowVideoFrameInvalidated = Notification.Name("proshow.video.frame.invalidated")
}
