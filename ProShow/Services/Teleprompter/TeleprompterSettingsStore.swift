import Foundation
import Observation

/// CueLog look-and-feel for the rundown teleprompter. Persists on this Mac.
@MainActor
@Observable
final class TeleprompterSettingsStore {
    static let shared = TeleprompterSettingsStore()

    private static let storageKey = "proshow.teleprompter.settings"

    var promptEngine: PromptEngineKind {
        didSet { save() }
    }
    var baseWPM: Int {
        didSet { save() }
    }
    var fontSize: Double {
        didSet { save() }
    }
    var scrollSpeed: Double {
        didSet { save() }
    }
    var eyeLinePosition: Double {
        didSet { save() }
    }
    var mirrorHorizontal: Bool {
        didSet { save() }
    }
    /// CueLog name for a beam-splitter glass that needs a horizontal flip.
    var isBeamSplitterMirrored: Bool {
        get { mirrorHorizontal }
        set { mirrorHorizontal = newValue }
    }
    var style: KineticStyle {
        didSet { save() }
    }
    /// Compact island chrome. Liquid glass, or clear so the desktop shows through.
    var compactLiquidGlass: Bool {
        didSet { saveCompactChrome() }
    }

    private var isLoading = false

    private init() {
        let stored = Self.load()
        promptEngine = stored.promptEngine
        baseWPM = stored.baseWPM
        fontSize = stored.fontSize
        scrollSpeed = stored.scrollSpeed
        eyeLinePosition = stored.eyeLinePosition
        mirrorHorizontal = stored.mirrorHorizontal
        style = stored.style
        compactLiquidGlass = UserDefaults.standard.object(forKey: Self.compactChromeKey) as? Bool ?? true
    }

    /// Isolated copy. Does not read or write the shared UserDefaults profile.
    static func isolatedPreview() -> TeleprompterSettingsStore {
        TeleprompterSettingsStore(preview: Snapshot())
    }

    private init(preview: Snapshot) {
        isLoading = true
        promptEngine = preview.promptEngine
        baseWPM = preview.baseWPM
        fontSize = preview.fontSize
        scrollSpeed = preview.scrollSpeed
        eyeLinePosition = preview.eyeLinePosition
        mirrorHorizontal = preview.mirrorHorizontal
        style = preview.style
        compactLiquidGlass = true
    }

    func applyPreset(_ preset: KineticStyle) {
        var next = preset
        next.lineBreakPause = style.lineBreakPause
        next.tagPause = style.tagPause
        next.longTagPause = style.longTagPause
        next.punctuationHolds = style.punctuationHolds
        style = next
    }

    private static let compactChromeKey = "proshow.teleprompter.compactLiquidGlass"

    private func saveCompactChrome() {
        guard !isLoading else { return }
        UserDefaults.standard.set(compactLiquidGlass, forKey: Self.compactChromeKey)
    }

    private func save() {
        guard !isLoading else { return }
        let snapshot = Snapshot(
            promptEngine: promptEngine,
            baseWPM: baseWPM,
            fontSize: fontSize,
            scrollSpeed: scrollSpeed,
            eyeLinePosition: eyeLinePosition,
            mirrorHorizontal: mirrorHorizontal,
            style: style
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private static func load() -> Snapshot {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return Snapshot()
        }
        return snapshot
    }

    private struct Snapshot: Codable {
        var promptEngine: PromptEngineKind = .kinetic
        var baseWPM: Int = 150
        var fontSize: Double = 42
        var scrollSpeed: Double = 40
        var eyeLinePosition: Double = 0.33
        var mirrorHorizontal: Bool = false
        var style: KineticStyle = .default
    }
}

enum PromptEngineKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case scroll
    case kinetic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scroll: "Scroll"
        case .kinetic: "Kinetic"
        }
    }
}
