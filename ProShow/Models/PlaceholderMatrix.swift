import Foundation
import CoreGraphics

public enum PlaceholderState: String, Codable, Sendable {
    case activeLive
    case activePreview
    case inactiveStandby
}

public enum TransitionPhysicsStyle: String, Codable, CaseIterable, Sendable {
    case cut
    case dissolve
    case pushLeft
    case pushRight
    case flyFromTop
    case flyFromBottom
    case springBounce
    case smoothZoomScale

    public var title: String {
        switch self {
        case .cut: "Cut"
        case .dissolve: "Dissolve"
        case .pushLeft: "Fly From Left"
        case .pushRight: "Fly From Right"
        case .flyFromTop: "Fly From Top"
        case .flyFromBottom: "Fly From Bottom"
        case .springBounce: "Spring Physics"
        case .smoothZoomScale: "Smooth Zoom Scale"
        }
    }
}

public enum MapInspectorTab: String, CaseIterable, Identifiable, Sendable {
    case source, geometry, transitions, macros

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .source: "Source"
        case .geometry: "Geometry"
        case .transitions: "Transitions"
        case .macros: "Macros & Events"
        }
    }

    public var shortTitle: String {
        switch self {
        case .source: "Source"
        case .geometry: "Layout"
        case .transitions: "Motion"
        case .macros: "Macros"
        }
    }
}

public struct PlaceholderConfiguration: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var state: PlaceholderState
    public var primarySourceId: String?
    public var failoverSourceId: String?
    public var autoFailoverEnabled: Bool
    public var failoverTimeoutSeconds: Double
    public var fallbackColorHex: String
    public var chromaKeyEnabled: Bool
    public var chromaKeyColorHex: String
    public var chromaKeySmoothness: Double
    public var backgroundBlurRadius: Double
    public var aspectRatio: String
    public var cropRect: CGRect
    public var rotationAngle: Double
    public var borderWidth: Double
    public var borderColorHex: String
    public var cornerRadius: Double
    public var squircleSmoothing: Double
    public var showTallyBorder: Bool
    public var entranceTransition: TransitionPhysicsStyle
    public var exitTransition: TransitionPhysicsStyle
    public var transitionPresetID: String?
    public var transitionDurationSec: Double
    public var springDampingRatio: Double
    public var springStiffness: Double
    public var onLiveMacroId: UUID?
    public var onClearMacroId: UUID?
    public var onFailoverMacroId: UUID?
    public var targetMasterLayerIndex: Int?
    public var audioMuted: Bool? = nil
    /// Theme variant applied when this map tile shows program slide content.
    public var themeVariantID: UUID? = nil

    public var letter: String {
        id.split(separator: " ").last.map(String.init) ?? id
    }

    public var isActive: Bool {
        state != .inactiveStandby
    }

    public init(
        id: String,
        label: String,
        state: PlaceholderState = .inactiveStandby,
        primarySourceId: String? = nil,
        failoverSourceId: String? = nil,
        autoFailoverEnabled: Bool = true,
        failoverTimeoutSeconds: Double = 2,
        fallbackColorHex: String = "#1B3A4B",
        chromaKeyEnabled: Bool = false,
        chromaKeyColorHex: String = "#00FF00",
        chromaKeySmoothness: Double = 0.35,
        backgroundBlurRadius: Double = 0,
        aspectRatio: String = "16:9",
        cropRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
        rotationAngle: Double = 0,
        borderWidth: Double = 0,
        borderColorHex: String = "#FFFFFF",
        cornerRadius: Double = 12,
        squircleSmoothing: Double = 0.6,
        showTallyBorder: Bool = true,
        entranceTransition: TransitionPhysicsStyle = .dissolve,
        exitTransition: TransitionPhysicsStyle = .dissolve,
        transitionPresetID: String? = nil,
        transitionDurationSec: Double = 0.45,
        springDampingRatio: Double = 0.72,
        springStiffness: Double = 180,
        onLiveMacroId: UUID? = nil,
        onClearMacroId: UUID? = nil,
        onFailoverMacroId: UUID? = nil,
        targetMasterLayerIndex: Int? = nil,
        audioMuted: Bool? = nil,
        themeVariantID: UUID? = nil
    ) {
        self.id = id
        self.label = label
        self.state = state
        self.primarySourceId = primarySourceId
        self.failoverSourceId = failoverSourceId
        self.autoFailoverEnabled = autoFailoverEnabled
        self.failoverTimeoutSeconds = failoverTimeoutSeconds
        self.fallbackColorHex = fallbackColorHex
        self.chromaKeyEnabled = chromaKeyEnabled
        self.chromaKeyColorHex = chromaKeyColorHex
        self.chromaKeySmoothness = chromaKeySmoothness
        self.backgroundBlurRadius = backgroundBlurRadius
        self.aspectRatio = aspectRatio
        self.cropRect = cropRect
        self.rotationAngle = rotationAngle
        self.borderWidth = borderWidth
        self.borderColorHex = borderColorHex
        self.cornerRadius = cornerRadius
        self.squircleSmoothing = squircleSmoothing
        self.showTallyBorder = showTallyBorder
        self.entranceTransition = entranceTransition
        self.exitTransition = exitTransition
        self.transitionPresetID = transitionPresetID
        self.transitionDurationSec = transitionDurationSec
        self.springDampingRatio = springDampingRatio
        self.springStiffness = springStiffness
        self.onLiveMacroId = onLiveMacroId
        self.onClearMacroId = onClearMacroId
        self.onFailoverMacroId = onFailoverMacroId
        self.targetMasterLayerIndex = targetMasterLayerIndex
        self.audioMuted = audioMuted
        self.themeVariantID = themeVariantID
    }

    public var isAudioMuted: Bool {
        get { audioMuted == true }
        set { audioMuted = newValue }
    }

    public static func catalog() -> [PlaceholderConfiguration] {
        let labels = [
            "A": "Host Cam",
            "B": "Screen Share",
            "C": "Guest 1",
            "D": "Guest 2",
            "E": "Lower Third",
            "F": "Stage Wide",
            "G": "Audience",
            "H": "Overflow",
            "I": "Utility",
        ]
        return ["A", "B", "C", "D", "E", "F", "G", "H", "I"].enumerated().map { index, letter in
            PlaceholderConfiguration(
                id: "Placeholder \(letter)",
                label: labels[letter] ?? letter,
                state: index < 2 ? .activeLive : .inactiveStandby,
                targetMasterLayerIndex: index < 2 ? (index == 0 ? 3 : 2) : nil
            )
        }
    }
}

public struct PlaceholderSourceChoice: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var subtitle: String
    public var symbolName: String
    public var tintHex: String
    public var filePath: String?
    public var previewKind: PreviewKind
    public var group: Group

    public enum Group: String, Hashable, Sendable {
        case device
        case media
    }

    public enum PreviewKind: String, Hashable, Sendable {
        case video
        case image
        case camera
        case placeholder
    }

    public init(
        id: String,
        name: String,
        subtitle: String = "Source",
        symbolName: String = "video.fill",
        tintHex: String = "#1B3A4B",
        filePath: String? = nil,
        previewKind: PreviewKind = .camera,
        group: Group = .device
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.tintHex = tintHex
        self.filePath = filePath
        self.previewKind = previewKind
        self.group = group
    }
}

public struct PlaceholderRoute: Identifiable, Hashable, Sendable {
    public var placeholderID: String
    public var sourceID: String?
    public var sourceName: String
    public var layerIndex: Int?
    public var layerName: String
    public var isLive: Bool
    public var usingFailover: Bool

    public var id: String { placeholderID }
}

public enum PlaceholderMacroEvent: String, Codable, Sendable {
    case onLive
    case onClear
    case onFailover
}

enum PlaceholderMatrix {
    static func remap(_ placeholder: PlaceholderConfiguration, primarySourceId: String?) -> PlaceholderConfiguration {
        var next = placeholder
        next.primarySourceId = primarySourceId
        return next
    }

    static func route(to placeholder: PlaceholderConfiguration, layerIndex: Int?) -> PlaceholderConfiguration {
        var next = placeholder
        next.targetMasterLayerIndex = layerIndex
        return next
    }

    static func shouldFailover(
        _ placeholder: PlaceholderConfiguration,
        lastFrameAt: Date?,
        now: Date,
        alreadyFailed: Bool
    ) -> Bool {
        guard placeholder.autoFailoverEnabled, placeholder.failoverSourceId != nil, !alreadyFailed else { return false }
        guard let lastFrameAt else { return true }
        return now.timeIntervalSince(lastFrameAt) >= placeholder.failoverTimeoutSeconds
    }

    static func macroID(for placeholder: PlaceholderConfiguration, event: PlaceholderMacroEvent) -> UUID? {
        switch event {
        case .onLive: placeholder.onLiveMacroId
        case .onClear: placeholder.onClearMacroId
        case .onFailover: placeholder.onFailoverMacroId
        }
    }

    static func applyState(_ placeholder: PlaceholderConfiguration, _ state: PlaceholderState) -> (PlaceholderConfiguration, PlaceholderMacroEvent?) {
        var next = placeholder
        let previous = placeholder.state
        next.state = state
        if previous != .activeLive, state == .activeLive {
            return (next, .onLive)
        }
        if previous == .activeLive, state != .activeLive {
            return (next, .onClear)
        }
        return (next, nil)
    }
}
