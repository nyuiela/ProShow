import Foundation
import Observation
#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif
#if os(macOS)
import AppKit
#endif

protocol SourceEnumerating: Sendable {
    func videoDevices() -> [DiscoveredSourceItem]
    func audioDevices() -> [DiscoveredSourceItem]
    func screens() -> [DiscoveredSourceItem]
    func ndiSources() -> [DiscoveredSourceItem]
}

/// Hardware / network scan used only when the Add Shot modal opens — never at process launch.
final class LiveSourceEnumerator: SourceEnumerating, @unchecked Sendable {
    var includeExternalCameras = false
    var liveScreens: [DiscoveredSourceItem] = []
    private let lock = NSLock()
    private var cachedVideo: [DiscoveredSourceItem]?
    private var cachedAudio: [DiscoveredSourceItem]?

    func invalidateHardwareCache() {
        lock.lock()
        cachedVideo = nil
        cachedAudio = nil
        lock.unlock()
    }

    func videoDevices() -> [DiscoveredSourceItem] {
        lock.lock()
        if let cachedVideo {
            lock.unlock()
            return cachedVideo
        }
        lock.unlock()
        let next = scanVideoDevices()
        lock.lock()
        cachedVideo = next
        lock.unlock()
        return next
    }

    func audioDevices() -> [DiscoveredSourceItem] {
        lock.lock()
        if let cachedAudio {
            lock.unlock()
            return cachedAudio
        }
        lock.unlock()
        let next = scanAudioDevices()
        lock.lock()
        cachedAudio = next
        lock.unlock()
        return next
    }

    private func scanVideoDevices() -> [DiscoveredSourceItem] {
        #if canImport(AVFoundation)
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if includeExternalCameras {
            if #available(macOS 14.0, iOS 17.0, *) {
                types.append(.external)
            }
        }
        // Desk View / Continuity load CMIO extensions. Only on this user-initiated scan.
        // Opening a capture session on those devices is what prompts the phone — never do that here.
        if includeExternalCameras {
            if #available(macOS 13.0, iOS 17.0, *) {
                types.append(.deskViewCamera)
            }
            if #available(macOS 14.0, iOS 17.0, *) {
                types.append(.continuityCamera)
            }
        }
        var seen = Set<String>()
        return PersistentCaptureDiscovery.devices(types: types, mediaType: .video).compactMap { device in
            guard seen.insert(device.uniqueID).inserted else { return nil }
            guard !SystemVideoDeviceCatalog.isUnsafeCaptureDevice(name: device.localizedName, uniqueID: device.uniqueID) else {
                return nil
            }
            return DiscoveredSourceItem(
                id: "avf-video-\(device.uniqueID)",
                name: device.localizedName,
                category: .videoCapture,
                groupName: "System Device",
                sourceType: .systemCamera,
                connectionString: "avf://\(device.uniqueID)",
                isConnected: true
            )
        }
        #else
        return []
        #endif
    }

    private func scanAudioDevices() -> [DiscoveredSourceItem] {
        #if canImport(AVFoundation)
        var types: [AVCaptureDevice.DeviceType] = [.builtInMicrophone]
        if #available(macOS 14.0, iOS 17.0, *) {
            types.append(.microphone)
        }
        var seen = Set<String>()
        return PersistentCaptureDiscovery.devices(types: types, mediaType: .audio).compactMap { device in
            guard seen.insert(device.uniqueID).inserted else { return nil }
            return DiscoveredSourceItem(
                id: "avf-audio-\(device.uniqueID)",
                name: device.localizedName,
                category: .audioCapture,
                groupName: "System Device",
                sourceType: .systemMicrophone,
                connectionString: "avf://\(device.uniqueID)",
                isConnected: true
            )
        }
        #else
        return []
        #endif
    }

    func screens() -> [DiscoveredSourceItem] {
        if !liveScreens.isEmpty { return liveScreens }
        #if os(macOS)
        return NSScreen.screens.compactMap { screen in
            guard let id = ScreenShareCatalog.cgDisplayID(of: screen) else { return nil }
            return ScreenShareCatalog.displayItem(
                id: id,
                name: "Entire Display — \(screen.localizedName)",
                width: Int(screen.frame.width),
                height: Int(screen.frame.height)
            )
        }
        #else
        return [
            DiscoveredSourceItem(
                id: "sck-display-0",
                name: "Device Screen",
                category: .screenCapture,
                groupName: "Screen Capture",
                sourceType: .systemDisplay,
                connectionString: "sck://display/0"
            )
        ]
        #endif
    }

    func ndiSources() -> [DiscoveredSourceItem] {
        guard NDIRuntime.isAvailable else { return [] }
        NDIRuntime.hardwareEnabled = true
        return NDIRuntime.findSources(timeoutMs: 800).map { source in
            DiscoveredSourceItem(
                id: "ndi-\(source.name)",
                name: source.name,
                category: .network,
                groupName: "NDI™ Source",
                sourceType: .ndiSource,
                connectionString: source.url.isEmpty ? "ndi://\(source.name)" : source.url,
                isConnected: true
            )
        }
    }
}

@MainActor
@Observable
final class SourceDiscoveryManager {
    var items: [DiscoveredSourceItem] = []
    var showDisconnected = false
    var ndiDiscoveryHosts: [String] = []
    var srtListenerPort = 9000
    var accessMessage: String?
    var isRefreshingHardware = false
    private var enumerator: SourceEnumerating
    private var access: InputAccessRequesting

    init(
        enumerator: SourceEnumerating = LiveSourceEnumerator(),
        access: InputAccessRequesting = SystemInputAccess()
    ) {
        self.enumerator = enumerator
        self.access = access
    }

    /// Tests and callers that only swap the enumerator.
    convenience init(enumerator: SourceEnumerating) {
        self.init(enumerator: enumerator, access: SystemInputAccess())
    }

    func refreshLiveHardware(
        media: [MediaBinItem] = [],
        mediaCollections: [MediaCollection] = [],
        libraryShows: [Show] = [],
        playlistItems: [LibraryShowItem] = [],
        overlays: [String] = [],
        customColors: [SolidColorSwatch] = [],
        templates: [String] = [],
        existingShots: [LayerShot] = [],
        favoriteIDs: Set<String> = []
    ) async {
        isRefreshingHardware = true
        let cameraOK = await access.requestCameraAccess()
        _ = await access.requestMicrophoneAccess()
        let screens = await access.screenShareTargets()
        if let live = enumerator as? LiveSourceEnumerator {
            live.invalidateHardwareCache()
            live.includeExternalCameras = cameraOK
            if !screens.isEmpty {
                live.liveScreens = screens
            }
        }
        var notes: [String] = []
        if !cameraOK {
            notes.append("Allow Camera to list Mac and USB cameras.")
        }
        if screens.isEmpty {
            notes.append("Allow Screen Recording to list displays and windows.")
        }
        if !NDIRuntime.isAvailable {
            notes.append("NDI runtime not installed.")
        }
        accessMessage = notes.isEmpty ? nil : notes.joined(separator: " ")
        refresh(
            media: media,
            mediaCollections: mediaCollections,
            libraryShows: libraryShows,
            playlistItems: playlistItems,
            overlays: overlays,
            customColors: customColors,
            templates: templates,
            existingShots: existingShots,
            favoriteIDs: favoriteIDs
        )
        isRefreshingHardware = false
    }

    func refresh(
        media: [MediaBinItem] = [],
        mediaCollections: [MediaCollection] = [],
        libraryShows: [Show] = [],
        playlistItems: [LibraryShowItem] = [],
        overlays: [String] = [],
        customColors: [SolidColorSwatch] = [],
        templates: [String] = [],
        existingShots: [LayerShot] = [],
        favoriteIDs: Set<String> = []
    ) {
        var next: [DiscoveredSourceItem] = []
        next.append(contentsOf: Self.placeholderItems())
        next.append(contentsOf: SolidColorSwatch.factory.map(Self.colorItem))
        next.append(contentsOf: customColors.map(Self.colorItem))
        next.append(contentsOf: enumerator.videoDevices())
        next.append(contentsOf: enumerator.audioDevices())
        next.append(contentsOf: enumerator.screens())
        next.append(contentsOf: enumerator.ndiSources())
        next.append(contentsOf: Self.systemAudioGroup())
        next.append(contentsOf: Self.networkActions(srtPort: srtListenerPort))
        next.append(contentsOf: media.map { Self.mediaItem($0, groupName: "Media Files") })
        next.append(contentsOf: mediaCollections.flatMap { collection in
            collection.items.map { Self.mediaItem($0, groupName: Self.collectionGroup(collection)) }
        })
        next.append(contentsOf: libraryShows.map(Self.libraryShowItem))
        next.append(contentsOf: playlistItems.map(Self.playlistShowItem))
        next.append(contentsOf: Self.presentationSlideItems(libraryShows: libraryShows, playlistItems: playlistItems))
        next.append(contentsOf: overlays.enumerated().map { index, name in
            DiscoveredSourceItem(
                id: "overlay-\(index)-\(name)",
                name: name,
                category: .overlays,
                groupName: "Overlays",
                sourceType: .placeholderSlot
            )
        })
        next.append(contentsOf: templates.enumerated().map { index, name in
            DiscoveredSourceItem(
                id: "template-\(index)-\(name)",
                name: name,
                category: .templates,
                groupName: "Templates",
                sourceType: .templateLayout
            )
        })
        next.append(contentsOf: existingShots.map { shot in
            var item = shot.source
            item.id = "shot-\(shot.id.uuidString)"
            item.category = .shots
            item.groupName = "Shots"
            return item
        })
        var seen = Set<String>()
        next = next.filter { seen.insert($0.id).inserted }
        for index in next.indices {
            next[index].isFavorite = favoriteIDs.contains(next[index].id)
        }
        items = next
    }

    func groups(category: AddShotCategory, query: String) -> [SourceGroup] {
        let filtered = items.filter { item in
            if !showDisconnected, !item.isConnected { return false }
            switch category {
            case .all: break
            case .favorites: if !item.isFavorite { return false }
            default: if item.category != category { return false }
            }
            return AddShotSearch.matches(item, query: query)
        }
        let order = [
            "Placeholders",
            "Solid Colors",
            "System Device",
            "Displays",
            "Windows",
            "System Audio Capture",
            "NDI™ Source",
            "Rendezvous / Remote Stream",
            "Screen Capture",
            "Library",
            "Playlists",
            "Media Files",
            "Overlays",
            "Templates",
            "Shots",
        ]
        var buckets: [String: [DiscoveredSourceItem]] = [:]
        for item in filtered {
            buckets[item.groupName, default: []].append(item)
        }
        return order.compactMap { name in
            guard let items = buckets[name], !items.isEmpty else { return nil }
            return SourceGroup(groupName: name, items: items)
        } + buckets.keys
            .filter { !order.contains($0) }
            .sorted()
            .compactMap { name in
                guard let items = buckets[name], !items.isEmpty else { return nil }
                return SourceGroup(groupName: name, items: items)
            }
    }

    func toggleFavorite(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isFavorite.toggle()
    }

    func appendMediaFile(name: String, path: String) -> DiscoveredSourceItem {
        let item = DiscoveredSourceItem(
            id: "media-\(path)",
            name: name,
            category: .mediaFiles,
            groupName: "Media Files",
            sourceType: .mediaFile,
            connectionString: path
        )
        if !items.contains(where: { $0.id == item.id }) {
            items.append(item)
        }
        return item
    }

    func appendSolidColor(_ swatch: SolidColorSwatch) -> DiscoveredSourceItem {
        let item = Self.colorItem(swatch)
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
        return item
    }

    private static func systemAudioGroup() -> [DiscoveredSourceItem] {
        [
            DiscoveredSourceItem(
                id: "system-audio-capture",
                name: "System Audio Capture",
                category: .audioCapture,
                groupName: "System Audio Capture",
                sourceType: .systemAudioCapture,
                connectionString: "sck://audio/system"
            ),
            DiscoveredSourceItem(
                id: "ios-cam-wireless",
                name: "iOS Cam",
                category: .videoCapture,
                groupName: "System Audio Capture",
                sourceType: .rendezvousGuest,
                connectionString: "webrtc://guest",
                isConnected: false
            ),
        ]
    }

    private static func networkActions(srtPort: Int) -> [DiscoveredSourceItem] {
        [
            DiscoveredSourceItem(
                id: "rendezvous-create",
                name: "Create Rendezvous Session",
                category: .network,
                groupName: "Rendezvous / Remote Stream",
                sourceType: .rendezvousGuest,
                connectionString: "webrtc://invite"
            ),
            DiscoveredSourceItem(
                id: "srt-stream",
                name: "SRT Stream",
                category: .network,
                groupName: "Rendezvous / Remote Stream",
                sourceType: .srtStream,
                connectionString: "srt://0.0.0.0:\(srtPort)"
            ),
            DiscoveredSourceItem(
                id: "web-page",
                name: "Web Page",
                category: .network,
                groupName: "Rendezvous / Remote Stream",
                sourceType: .webPage,
                connectionString: "https://"
            ),
        ]
    }

    private static func placeholderItems() -> [DiscoveredSourceItem] {
        PlaceholderSlotSpec.catalog.map { slot in
            DiscoveredSourceItem(
                id: "placeholder-\(slot.letter.rawValue)",
                name: slot.letter.rawValue,
                category: .placeholders,
                groupName: "Placeholders",
                sourceType: .placeholderSlot,
                connectionString: "placeholder://\(slot.letter.rawValue)",
                tintHex: slot.tintHex
            )
        }
    }

    private static func colorItem(_ swatch: SolidColorSwatch) -> DiscoveredSourceItem {
        DiscoveredSourceItem(
            id: swatch.id,
            name: swatch.name,
            category: .backgrounds,
            groupName: "Solid Colors",
            sourceType: .solidColor,
            connectionString: swatch.hex,
            tintHex: swatch.hex
        )
    }

    private static func collectionGroup(_ collection: MediaCollection) -> String {
        switch collection.source {
        case .playlists: return "Playlist · \(collection.name)"
        case .libraries: return "Library · \(collection.name)"
        default: return collection.name
        }
    }

    private static func mediaItem(_ media: MediaBinItem, groupName: String) -> DiscoveredSourceItem {
        DiscoveredSourceItem(
            id: "media-\(media.id.uuidString)",
            name: media.title,
            category: .mediaFiles,
            groupName: groupName,
            sourceType: .mediaFile,
            connectionString: media.filePath,
            tintHex: media.tintHex
        )
    }

    private static func libraryShowItem(_ show: Show) -> DiscoveredSourceItem {
        DiscoveredSourceItem(
            id: "library-show-\(show.id.uuidString)",
            name: show.name,
            category: .mediaFiles,
            groupName: "Library",
            sourceType: .libraryShow,
            connectionString: show.id.uuidString
        )
    }

    private static func playlistShowItem(_ item: LibraryShowItem) -> DiscoveredSourceItem {
        DiscoveredSourceItem(
            id: "playlist-item-\(item.id.uuidString)",
            name: item.title,
            category: .mediaFiles,
            groupName: "Playlists",
            sourceType: .libraryShow,
            connectionString: item.showID?.uuidString ?? item.title
        )
    }

    /// Individual slides from library shows and playlist-linked decks (runtime outline source picker).
    static func presentationSlideItems(
        libraryShows: [Show],
        playlistItems: [LibraryShowItem]
    ) -> [DiscoveredSourceItem] {
        var items: [DiscoveredSourceItem] = []
        func appendSlides(from show: Show, groupName: String, namePrefix: String) {
            guard show.id != ProgramOutlinePresentation.showID else { return }
            for (index, slide) in show.allSlides.enumerated() {
                let slideTitle = slide.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = slideTitle.isEmpty ? "Slide \(index + 1)" : slideTitle
                items.append(
                    DiscoveredSourceItem(
                        id: "presentation-slide-\(show.id.uuidString)-\(slide.id.uuidString)",
                        name: "\(namePrefix) · \(label)",
                        category: .mediaFiles,
                        groupName: groupName,
                        sourceType: .libraryShow,
                        connectionString: "\(show.id.uuidString)|\(slide.id.uuidString)"
                    )
                )
            }
        }
        for show in libraryShows {
            appendSlides(from: show, groupName: "Library", namePrefix: show.name)
        }
        for item in playlistItems {
            guard let showID = item.showID,
                  let show = libraryShows.first(where: { $0.id == showID })
            else { continue }
            appendSlides(from: show, groupName: "Playlists", namePrefix: item.title)
        }
        return items
    }
}
