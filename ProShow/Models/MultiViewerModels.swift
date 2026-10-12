import CoreGraphics
import Foundation

enum MultiTileType: String, Codable, CaseIterable, Identifiable, Sendable {
    case program
    case preview
    case phoneProgram
    case phonePreview
    case cameraInput
    case displayShare
    case stageMonitor
    case audioMeterBridge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .program: "Program"
        case .preview: "Preview"
        case .phoneProgram: "Phone Live"
        case .phonePreview: "Phone Preview"
        case .cameraInput: "Camera"
        case .displayShare: "Display"
        case .stageMonitor: "Stage"
        case .audioMeterBridge: "Meters"
        }
    }

    var systemImage: String {
        switch self {
        case .program: "dot.radiowaves.left.and.right"
        case .preview: "rectangle.badge.plus"
        case .phoneProgram: "iphone"
        case .phonePreview: "iphone"
        case .cameraInput: "video"
        case .displayShare: "display"
        case .stageMonitor: "rectangle.split.2x1"
        case .audioMeterBridge: "waveform"
        }
    }
}

enum MultiViewerGrid: String, Codable, CaseIterable, Identifiable, Sendable {
    case twoByTwo
    case threeByThree
    case fourByFour
    case programPreviewTop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .twoByTwo: "2 × 2"
        case .threeByThree: "3 × 3"
        case .fourByFour: "4 × 4"
        case .programPreviewTop: "2 top + 6 bottom"
        }
    }

    var capacity: Int {
        switch self {
        case .twoByTwo: 4
        case .threeByThree: 9
        case .fourByFour: 16
        case .programPreviewTop: 8
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if raw == "twoByThree" {
            self = .programPreviewTop
            return
        }
        self = MultiViewerGrid(rawValue: raw) ?? .programPreviewTop
    }
}

enum MultiViewerTally: String, Sendable {
    case program
    case preview
    case standby

    var label: String {
        switch self {
        case .program: ProShowCopy.Status.live
        case .preview: ProShowCopy.Status.ready
        case .standby: ProShowCopy.Status.off
        }
    }

    var borderWidth: CGFloat {
        self == .standby ? 1.5 : 3
    }
}

struct MultiViewerTileConfig: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var type: MultiTileType
    var sourceId: String
    var customTitle: String
    var gridPositionIndex: Int
    var showAudioMeter: Bool

    init(
        id: UUID = UUID(),
        type: MultiTileType,
        sourceId: String = "",
        customTitle: String,
        gridPositionIndex: Int,
        showAudioMeter: Bool = true
    ) {
        self.id = id
        self.type = type
        self.sourceId = sourceId
        self.customTitle = customTitle
        self.gridPositionIndex = gridPositionIndex
        self.showAudioMeter = showAudioMeter
    }
}

struct MultiViewerLayout: Codable, Equatable, Hashable, Sendable {
    var grid: MultiViewerGrid
    var tiles: [MultiViewerTileConfig]

    static let empty = MultiViewerLayout(grid: .programPreviewTop, tiles: [])

    static func studioDefault(
        sources: [StudioVideoSource] = [],
        grid: MultiViewerGrid = .programPreviewTop,
        includePhone: Bool = false
    ) -> MultiViewerLayout {
        var tiles: [MultiViewerTileConfig] = [
            MultiViewerTileConfig(type: .program, customTitle: "Program", gridPositionIndex: 0),
            MultiViewerTileConfig(type: .preview, customTitle: "Preview", gridPositionIndex: 1),
        ]
        if includePhone {
            tiles.append(MultiViewerTileConfig(type: .phoneProgram, customTitle: "Phone Live", gridPositionIndex: tiles.count))
            tiles.append(MultiViewerTileConfig(type: .phonePreview, customTitle: "Phone Preview", gridPositionIndex: tiles.count))
        }
        tiles.append(
            MultiViewerTileConfig(
                type: .audioMeterBridge,
                customTitle: "Meters",
                gridPositionIndex: tiles.count,
                showAudioMeter: false
            )
        )
        var index = tiles.count
        let sourceSlots = max(0, grid.capacity - tiles.count - 1)
        for source in sources.prefix(sourceSlots) {
            let display = source.kind == .screenShare
            tiles.append(
                MultiViewerTileConfig(
                    type: display ? .displayShare : .cameraInput,
                    sourceId: source.id.uuidString,
                    customTitle: source.label,
                    gridPositionIndex: index
                )
            )
            index += 1
        }
        if tiles.count < grid.capacity {
            tiles.append(MultiViewerTileConfig(type: .stageMonitor, customTitle: "Stage", gridPositionIndex: index))
        }
        if tiles.count > grid.capacity {
            tiles = Array(tiles.prefix(grid.capacity))
        }
        return MultiViewerLayout(grid: grid, tiles: tiles)
    }

    var orderedTiles: [MultiViewerTileConfig] {
        tiles.sorted { $0.gridPositionIndex < $1.gridPositionIndex }
    }

    mutating func reindex() {
        for index in tiles.indices {
            tiles[index].gridPositionIndex = index
        }
    }
}

struct MultiViewerMeterChannel: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var db: Double
    var holdDb: Double
    var isMuted: Bool

    init(id: String, name: String, db: Double, holdDb: Double? = nil, isMuted: Bool = false) {
        self.id = id
        self.name = name
        self.db = db
        self.holdDb = holdDb ?? db
        self.isMuted = isMuted
    }
}
