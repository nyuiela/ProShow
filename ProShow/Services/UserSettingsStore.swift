import Foundation
import Observation

extension Notification.Name {
    static let didResetSettings = Notification.Name("didResetSettings")
    static let proShowLibrarySidebarChanged = Notification.Name("proShowLibrarySidebarChanged")
}

/// UserDefaults-backed desk / stream prefs with atomic reset and cache flush.
@MainActor
@Observable
final class UserSettingsStore {
    static let shared = UserSettingsStore()

    private let defaults = UserDefaults.standard

    var streamPreset: String {
        didSet { defaults.set(streamPreset, forKey: Keys.streamPreset) }
    }

    var canvasBgColorHex: String {
        didSet { defaults.set(canvasBgColorHex, forKey: Keys.canvasBgColorHex) }
    }

    var libraryWidth: Double {
        didSet { defaults.set(libraryWidth, forKey: Keys.libraryWidth) }
    }

    var librarySidebarHidden: Bool {
        didSet {
            defaults.set(librarySidebarHidden, forKey: Keys.librarySidebarHidden)
            NotificationCenter.default.post(name: .proShowLibrarySidebarChanged, object: nil)
        }
    }

    var inspectorWidth: Double {
        didSet { defaults.set(inspectorWidth, forKey: Keys.inspectorWidth) }
    }

    var mediaDrawerHeight: Double {
        didSet { defaults.set(mediaDrawerHeight, forKey: Keys.mediaDrawerHeight) }
    }

    var inspectorMasterExpanded: Bool {
        didSet { defaults.set(inspectorMasterExpanded, forKey: Keys.inspectorMasterExpanded) }
    }

    var inspectorPaneHeight: Double {
        didSet { defaults.set(inspectorPaneHeight, forKey: Keys.inspectorPaneHeight) }
    }

    /// Operator-desk program composite resolution (% of project output). Does not affect stream / record / audience.
    var localPreviewRenderPercent: Double {
        didSet {
            let clamped = Self.clampPreviewPercent(localPreviewRenderPercent)
            if clamped != localPreviewRenderPercent {
                localPreviewRenderPercent = clamped
                return
            }
            defaults.set(clamped, forKey: Keys.localPreviewRenderPercent)
        }
    }

    static let defaultLocalPreviewRenderPercent: Double = 50
    static let minLocalPreviewRenderPercent: Double = 25
    static let maxLocalPreviewRenderPercent: Double = 100

    static func clampPreviewPercent(_ value: Double) -> Double {
        min(maxLocalPreviewRenderPercent, max(minLocalPreviewRenderPercent, value.rounded()))
    }

    private enum Keys {
        static let streamPreset = "proshow.settings.streamPreset"
        static let canvasBgColorHex = "proshow.settings.canvasBgColorHex"
        static let libraryWidth = "proshow.layout.libraryWidth"
        static let librarySidebarHidden = "proshow.layout.librarySidebarHidden"
        static let inspectorWidth = "proshow.layout.inspectorWidth"
        static let mediaDrawerHeight = "proshow.layout.mediaDrawerHeight"
        static let inspectorMasterExpanded = "proshow.inspector.masterExpanded"
        static let inspectorPaneHeight = "proshow.layout.inspectorPaneHeight"
        static let localPreviewRenderPercent = "proshow.preview.localRenderPercent"
        static let streamConfig = EncoderPresetStore.userDefaultsKey
        static let layerSwipeDeleteDirection = "proshow.layers.swipeDeleteDirection"
    }

    private init() {
        streamPreset = defaults.string(forKey: Keys.streamPreset) ?? "1080p30 Standard"
        canvasBgColorHex = defaults.string(forKey: Keys.canvasBgColorHex) ?? "#000000"
        libraryWidth = defaults.object(forKey: Keys.libraryWidth) as? Double ?? 240
        librarySidebarHidden = defaults.bool(forKey: Keys.librarySidebarHidden)
        inspectorWidth = defaults.object(forKey: Keys.inspectorWidth) as? Double ?? 300
        mediaDrawerHeight = defaults.object(forKey: Keys.mediaDrawerHeight) as? Double ?? 248
        inspectorMasterExpanded = defaults.object(forKey: Keys.inspectorMasterExpanded) as? Bool ?? false
        inspectorPaneHeight = defaults.object(forKey: Keys.inspectorPaneHeight) as? Double ?? DeskLayout.inspectorPaneDefaultHeight
        let storedPreview = defaults.object(forKey: Keys.localPreviewRenderPercent) as? Double
        localPreviewRenderPercent = Self.clampPreviewPercent(storedPreview ?? Self.defaultLocalPreviewRenderPercent)
    }

    func resetToDefaults() {
        for key in [
            Keys.streamPreset,
            Keys.canvasBgColorHex,
            Keys.libraryWidth,
            Keys.librarySidebarHidden,
            Keys.inspectorWidth,
            Keys.mediaDrawerHeight,
            Keys.inspectorMasterExpanded,
            Keys.inspectorPaneHeight,
            Keys.localPreviewRenderPercent,
            Keys.streamConfig,
            Keys.layerSwipeDeleteDirection,
        ] {
            defaults.removeObject(forKey: key)
        }
        defaults.synchronize()

        streamPreset = "1080p30 Standard"
        canvasBgColorHex = "#000000"
        libraryWidth = 240
        librarySidebarHidden = false
        inspectorWidth = 300
        mediaDrawerHeight = 248
        inspectorMasterExpanded = false
        inspectorPaneHeight = DeskLayout.inspectorPaneDefaultHeight
        localPreviewRenderPercent = Self.defaultLocalPreviewRenderPercent

        EncoderPresetStore.save(StreamEncoderPreset.standard1080p30.config)
        UnifiedCacheRegistry.shared.flushAll()
        NotificationCenter.default.post(name: .didResetSettings, object: nil)
    }
}
