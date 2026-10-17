import Foundation

/// Fresh starter libraries, playlist, 4K themes, props, and generated preview assets.
enum DefaultSeedData {
    static let bundledSeedShowNames: Set<String> = [
        "Hold",
        "Talk",
        "Lyrics",
        "Lower Thirds",
        "End Card",
    ]

    static func isBundledSeedLibrary(_ shows: [Show]) -> Bool {
        guard !shows.isEmpty else { return false }
        return Set(shows.map(\.name)).isSubset(of: bundledSeedShowNames.union(legacyChurchDemoShowNames))
    }

    static func clearLibrary(_ store: LibraryStore) {
        for show in store.loadAll() {
            try? store.delete(id: show.id)
        }
    }

    static func blankShow(name: String = "Untitled") -> Show {
        Show(
            name: name,
            groups: [
                SlideGroup(
                    name: "Main",
                    slides: [Slide(title: "Slide 1")]
                ),
            ]
        )
    }

    static let defaultContentLibraryID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    static func emptyPlaylist(name: String = "Program", id: UUID = DeskSampleData.defaultPlaylistID) -> Playlist {
        Playlist(id: id, name: name, items: [])
    }

    static func defaultContentLibrary(playlistIDs: [UUID]) -> ContentLibrary {
        ContentLibrary(id: defaultContentLibraryID, name: "Library", playlistIDs: playlistIDs)
    }

    static func defaultLibraryHierarchy() -> (library: ContentLibrary, playlist: Playlist) {
        let playlist = emptyPlaylist()
        let library = defaultContentLibrary(playlistIDs: [playlist.id])
        return (library, playlist)
    }

    static func emptyStudioManifest() -> StudioManifest {
        StudioManifest(
            scenes: [],
            soundboard: [],
            videoSources: [],
            audioChannels: [],
            activeSceneID: nil,
            inspector: .empty
        )
    }

    static func starterProgram() -> (show: Show, playlist: Playlist) {
        let shows = allLibraryShows()
        let hold = shows.first(where: { $0.name == "Hold" }) ?? shows[0]
        return (hold, starterPlaylist(shows: shows))
    }

    static func sundayMorningService() -> (show: Show, playlist: Playlist) {
        starterProgram()
    }

    static func allLibraryShows() -> [Show] {
        [holdShow(), lowerThirdsShow(), talkShow(), lyricsShow(), endCardShow()]
    }

    static func starterPlaylist(shows: [Show]) -> Playlist {
        let hold = shows.first(where: { $0.name == "Hold" })
        let talk = shows.first(where: { $0.name == "Talk" })
        let lyrics = shows.first(where: { $0.name == "Lyrics" })
        let end = shows.first(where: { $0.name == "End Card" })
        return Playlist(
            name: "Program",
            items: [
                PlaylistItem(kind: .note, title: "Starting Soon", detail: "Countdown"),
                PlaylistItem(kind: .show, title: hold?.name ?? "Hold", showID: hold?.id),
                PlaylistItem(kind: .show, title: talk?.name ?? "Talk", showID: talk?.id),
                PlaylistItem(kind: .show, title: lyrics?.name ?? "Lyrics", showID: lyrics?.id),
                PlaylistItem(kind: .show, title: end?.name ?? "End Card", showID: end?.id),
            ]
        )
    }

    static func sundayMorningPlaylist(shows: [Show]) -> Playlist {
        starterPlaylist(shows: shows)
    }

    /// Leftover church-demo titles from the first seed kit. A library that is only these names is replaced.
    static let legacyChurchDemoShowNames: Set<String> = [
        "Sunday Morning",
        "Amazing Grace",
        "Welcome & Announcements",
        "Vision Sunday",
        "Church Hymns",
        "Hymns",
        "Nursery",
        "Pre-Service",
        "Stellar Library",
    ]

    static func isLegacyChurchDemoLibrary(_ shows: [Show]) -> Bool {
        guard !shows.isEmpty else { return false }
        return Set(shows.map(\.name)).isSubset(of: legacyChurchDemoShowNames)
    }

    static func isLegacyChurchDemoStudio(_ studio: StudioManifest) -> Bool {
        !Set(studio.scenes.map(\.name)).isDisjoint(with: [
            "Solo Presenter",
            "Presenter + Deck",
            "Presenter + Lyrics",
        ])
    }

    @discardableResult
    static func installFreshShows(into store: LibraryStore) -> [Show] {
        for show in store.loadAll() {
            try? store.delete(id: show.id)
        }
        let shows = allLibraryShows()
        for show in shows {
            try? store.save(show)
        }
        return shows
    }

    static func holdShow() -> Show {
        Show(
            name: "Hold",
            groups: [
                SlideGroup(name: "Open", colorHex: "#1B3A4B", slides: [
                    lyricSlide(title: "Starting Soon", lines: ["Starting soon", "Program begins shortly"], notes: "Walk-in / pre-roll"),
                ]),
                SlideGroup(name: "Break", colorHex: "#3D7EA6", slides: [
                    lyricSlide(title: "Hold", lines: ["We'll be right back"], notes: "Keep on program during a break"),
                ]),
            ],
            notes: "Hold screens · Templates"
        )
    }

    static func lowerThirdsShow() -> Show {
        Show(
            name: "Lower Thirds",
            groups: [
                SlideGroup(name: "Talent", colorHex: "#2A2A2A", slides: [
                    lowerThirdSlide(title: "Host", lines: ["On camera"]),
                    lowerThirdSlide(title: "Guest", lines: ["Remote"]),
                ]),
            ],
            notes: "Name plates · Looks"
        )
    }

    static func talkShow() -> Show {
        Show(
            name: "Talk",
            groups: [
                SlideGroup(name: "Open", colorHex: "#1B3A4B", slides: [
                    talkSlide(header: "Open", body: "What this program is about."),
                ]),
                SlideGroup(name: "Points", colorHex: "#2F6FED", slides: [
                    talkSlide(header: "01", body: "The first idea."),
                    talkSlide(header: "02", body: "The supporting point."),
                    talkSlide(header: "03", body: "What to do with it."),
                ]),
                SlideGroup(name: "Close", colorHex: "#6B4C9A", slides: [
                    talkSlide(header: "Close", body: "One sentence people can take with them."),
                ]),
            ],
            notes: "Talking-point deck · 4K"
        )
    }

    static func lyricsShow() -> Show {
        Show(
            name: "Lyrics",
            groups: [
                SlideGroup(name: "Verse", colorHex: "#3D7EA6", slides: [
                    lyricSlide(lines: ["First line of the lyric", "Second line of the lyric"]),
                    lyricSlide(lines: ["Third line of the lyric", "Fourth line of the lyric"]),
                ]),
                SlideGroup(name: "Chorus", colorHex: "#C45C26", slides: [
                    lyricSlide(lines: ["Chorus line one", "Chorus line two"]),
                ]),
                SlideGroup(name: "Bridge", colorHex: "#8B7355", slides: [
                    lyricSlide(lines: ["Bridge line one", "Bridge line two"]),
                ]),
            ],
            notes: "Lyric layout · 3840×2160"
        )
    }

    static func endCardShow() -> Show {
        Show(
            name: "End Card",
            groups: [
                SlideGroup(name: "Close", colorHex: "#1B3A4B", slides: [
                    lyricSlide(title: "Thanks", lines: ["Thanks for watching", "See you next time"], notes: "Outro"),
                ]),
            ],
            notes: "End card · Hold Screens"
        )
    }

    static func lyricSlide(title: String = "", lines: [String], notes: String = "") -> Slide {
        var object = CanvasObject(
            name: "Lyrics",
            kind: .text,
            bounds: CanvasBounds(x: 320, y: 1400, width: 3200, height: 640),
            zIndex: 1,
            text: lines.joined(separator: "\n"),
            fontSize: CanvasConfig.lyricFontSize
        )
        object.fill.type = .none
        object.stroke.style = .none
        object.typography.fontFamily = "Inter"
        object.typography.fontWeight = .bold
        object.typography.isBold = true
        object.typography.fontSize = CanvasConfig.lyricFontSize
        object.typography.color = "#FFFFFF"
        object.textOutline = TextOutline(enabled: true, color: "#000000", width: 3)
        object.textShadow = TextDropShadow(enabled: true, color: "#CC000000", angle: 315, offset: 8, blur: 12)
        object.textLayout.horizontalAlign = .center
        object.textLayout.verticalAlign = .bottom
        object.transform.lockAspectRatio = false
        return Slide(
            title: title,
            lines: lines,
            notes: notes,
            alignment: "center",
            elements: [object.asSlideElement(canvasWidth: CanvasConfig.width, canvasHeight: CanvasConfig.height)],
            canvas: [object]
        )
    }

    static func lowerThirdSlide(title: String, lines: [String]) -> Slide {
        var plate = CanvasObject(
            name: "Lower Third Plate",
            kind: .rectangle,
            bounds: CanvasBounds(x: 120, y: 1560, width: 2600, height: 480),
            zIndex: 0,
            fillHex: "#80000000"
        )
        plate.fill.type = .gradient
        plate.fill.gradientStops = [
            GradientStop(offset: 0, color: "#CC000000"),
            GradientStop(offset: 1, color: "#00000000"),
        ]
        plate.stroke.style = .none
        var text = CanvasObject(
            name: "Lower Third",
            kind: .text,
            bounds: CanvasBounds(x: 200, y: 1600, width: 2400, height: 400),
            zIndex: 1,
            text: ([title] + lines).joined(separator: "\n"),
            fontSize: 64
        )
        text.fill.type = .none
        text.typography.fontFamily = "Inter"
        text.typography.fontWeight = .semibold
        text.typography.fontSize = 64
        text.typography.color = "#FFFFFF"
        text.textLayout.horizontalAlign = .left
        text.textLayout.verticalAlign = .middle
        text.transform.lockAspectRatio = false
        return Slide(
            title: title,
            lines: [title] + lines,
            alignment: "left",
            elements: [text.asSlideElement(canvasWidth: CanvasConfig.width, canvasHeight: CanvasConfig.height)],
            canvas: [plate, text]
        )
    }

    static func talkSlide(header: String, body: String) -> Slide {
        var heading = CanvasObject(
            name: "Header",
            kind: .title,
            bounds: CanvasBounds(x: 200, y: 220, width: 3400, height: 220),
            zIndex: 2,
            text: header,
            fontSize: CanvasConfig.sermonHeaderSize,
            fontColor: "#4C8DFF"
        )
        heading.fill.type = .none
        heading.typography.fontFamily = "Inter"
        heading.typography.fontWeight = .bold
        heading.typography.fontSize = CanvasConfig.sermonHeaderSize
        heading.typography.color = "#4C8DFF"
        heading.textLayout.horizontalAlign = .left
        heading.textLayout.verticalAlign = .top
        heading.transform.lockAspectRatio = false
        var point = CanvasObject(
            name: "Body",
            kind: .text,
            bounds: CanvasBounds(x: 200, y: 520, width: 3400, height: 800),
            zIndex: 1,
            text: body,
            fontSize: CanvasConfig.sermonBodySize
        )
        point.fill.type = .none
        point.typography.fontFamily = "Inter"
        point.typography.fontWeight = .regular
        point.typography.isBold = false
        point.typography.fontSize = CanvasConfig.sermonBodySize
        point.typography.color = "#FFFFFF"
        point.textLayout.horizontalAlign = .left
        point.textLayout.verticalAlign = .top
        point.transform.lockAspectRatio = false
        return Slide(
            title: header,
            lines: [header, body],
            alignment: "left",
            elements: [
                heading.asSlideElement(canvasWidth: CanvasConfig.width, canvasHeight: CanvasConfig.height),
                point.asSlideElement(canvasWidth: CanvasConfig.width, canvasHeight: CanvasConfig.height),
            ],
            canvas: [heading, point]
        )
    }

    static func themeObjects(for variant: String) -> [CanvasObject] {
        switch variant {
        case "Lyric Standard":
            return lyricSlide(lines: ["Lyric Standard"]).canvas
        case "Lower Third":
            return lowerThirdSlide(title: "Speaker Name", lines: ["Role · Campus"]).canvas
        case "Sermon Point", "Talk Point":
            return talkSlide(header: "Talk Point", body: "Write the main idea here.").canvas
        case "Title & Subtitle":
            return [
                lyricSlide(lines: ["Title"]).canvas[0],
                {
                    var sub = lyricSlide(lines: ["Subtitle"]).canvas[0]
                    sub.name = "Subtitle"
                    sub.kind = .subtitle
                    sub.bounds.y = 1100
                    sub.typography.fontSize = 56
                    return sub
                }(),
            ]
        case "Picture Slide":
            return [
                CanvasObject(name: "Frame", kind: .rectangle, bounds: CanvasBounds(x: 240, y: 180, width: 3360, height: 1800), zIndex: 0, fillHex: "#111111"),
            ]
        case "Scripture":
            return talkSlide(header: "Reference", body: "Scripture body").canvas
        default:
            return lyricSlide(lines: [variant]).canvas
        }
    }

    static func stageLayoutObjects(for preset: StageLayoutPreset) -> [CanvasObject] {
        let document: EditorDocument
        if preset.id == ActionSeedID.layoutGrid {
            document = StageDisplayEngine.document(from: preset.look, layout: .standard, name: preset.name)
        } else {
            document = StageLiveBinder.document(from: preset.look, name: preset.name)
        }
        return document.objects
    }

    static func propDocuments() -> [EditorDocument] {
        var logo = CanvasObject(
            name: "Logo Bug",
            kind: .prop,
            bounds: CanvasBounds(x: 3400, y: 100, width: 340, height: 180),
            zIndex: 1,
            fillHex: "#FFFFFF"
        )
        logo.opacity = 0.85
        var alert = CanvasObject(
            name: "Emergency Alert",
            kind: .prop,
            bounds: CanvasBounds(x: 0, y: 0, width: 3840, height: 200),
            zIndex: 1,
            text: "EMERGENCY ALERT",
            fillHex: "#C62828",
            fontSize: 64
        )
        alert.typography.fontWeight = .bold
        alert.typography.color = "#FFFFFF"
        alert.textLayout.horizontalAlign = .center
        alert.textLayout.verticalAlign = .middle
        return [
            EditorDocument(name: "Logo Bug", kind: .props, canvasWidth: CanvasConfig.width, canvasHeight: CanvasConfig.height, backgroundEnabled: false, objects: [logo], autoClear: "Never"),
            EditorDocument(name: "Emergency Alert Message", kind: .props, canvasWidth: CanvasConfig.width, canvasHeight: CanvasConfig.height, backgroundEnabled: false, objects: [alert], autoClear: "On Next Slide"),
        ]
    }

    static func libraryFolders() -> [LibraryFolder] {
        [
            LibraryFolder(name: "Templates", systemImage: "folder.fill", children: []),
            LibraryFolder(name: "Looks", systemImage: "folder.fill", children: []),
            LibraryFolder(name: "Hold Screens", systemImage: "folder.fill", children: []),
        ]
    }

    static func mediaItems(relativeAudio: String? = nil, relativeLogo: String? = nil, relativeVideo: String? = nil) -> [MediaBinItem] {
        [
            MediaBinItem(title: "Starting Soon", kind: .video(duration: "5:00.00"), tintHex: "#1B3A4B", source: .playlists, filePath: relativeVideo),
            MediaBinItem(title: "Hold Bed", kind: .placeholder, tintHex: "#2A3A2A", source: .sampleContent, filePath: relativeAudio),
            MediaBinItem(title: "Mark", kind: .image, tintHex: "#2A2A3A", source: .resources, filePath: relativeLogo),
            MediaBinItem(title: "Camera", kind: .camera(label: "Camera"), tintHex: "#1A1A1A", source: .videoInputs),
        ]
    }

    static func studioManifest() -> StudioManifest {
        let camera = StudioVideoSource(id: StudioSeedID.camera, label: "Presenter Camera", kind: .camera, chromaEnabled: true)
        let cameraB = StudioVideoSource(id: StudioSeedID.cameraB, label: "Guest Camera", kind: .continuity)
        let screen = StudioVideoSource(id: StudioSeedID.screen, label: "Display Capture", kind: .screenShare, endpoint: "sck://display/0")
        let mic = AudioMatrixChannel(id: StudioSeedID.mic, name: "Mic", role: .microphone, gainDb: 0)
        let desktop = AudioMatrixChannel(id: StudioSeedID.desktop, name: "Desktop", role: .desktop, gainDb: -6)
        let guest = AudioMatrixChannel(id: UUID(uuidString: "C11C0000-0000-4000-8000-000000000003")!, name: "Guest", role: .guest)
        let slide = AudioMatrixChannel(id: UUID(uuidString: "C11C0000-0000-4000-8000-000000000004")!, name: "Slide", role: .slide, gainDb: -3)
        let board = AudioMatrixChannel(id: UUID(uuidString: "C11C0000-0000-4000-8000-000000000005")!, name: "Soundboard", role: .soundboard)
        let applause = SoundboardPad(
            id: StudioSeedID.applause,
            name: "Applause",
            relativePath: "Assets/Audio/pre-service-bed.wav",
            volume: 0.9,
            ducksProgram: false,
            loopMode: .once,
            waveform: Array(repeating: 0.35, count: 32)
        )
        let scenes = [
            ProShowScene(
                id: StudioSeedID.solo,
                name: "Camera",
                layout: .soloPresenter,
                hotKey: "1",
                primarySourceID: camera.id,
                primaryBounds: .fullFrame,
                overlays: [SceneOverlay(kind: "lowerThird", enabled: true)],
                mix: [AudioMixLevel(channelID: mic.id, gainDb: 0)]
            ),
            ProShowScene(
                id: StudioSeedID.presenterDeck,
                name: "Camera + Deck",
                layout: .presenterPlusDeck,
                hotKey: "2",
                primarySourceID: nil,
                pipSourceID: camera.id,
                primaryBounds: .fullFrame,
                pipBounds: .pipLowerRight,
                linkedPresentationName: "Talk",
                overlays: [SceneOverlay(kind: "lowerThird", enabled: true)],
                mix: [
                    AudioMixLevel(channelID: mic.id, gainDb: 0),
                    AudioMixLevel(channelID: slide.id, gainDb: -6),
                ]
            ),
            ProShowScene(
                id: StudioSeedID.interview,
                name: "Interview",
                layout: .interviewSplit,
                hotKey: "3",
                primarySourceID: camera.id,
                pipSourceID: cameraB.id,
                primaryBounds: .leftHalf,
                pipBounds: .rightHalf,
                overlays: [SceneOverlay(kind: "liveChat", enabled: false)],
                mix: [
                    AudioMixLevel(channelID: mic.id, gainDb: 0),
                    AudioMixLevel(channelID: guest.id, gainDb: 0),
                ]
            ),
            ProShowScene(
                id: StudioSeedID.screenShare,
                name: "Display + Camera",
                layout: .screenShareMic,
                hotKey: "4",
                primarySourceID: screen.id,
                pipSourceID: camera.id,
                primaryBounds: .fullFrame,
                pipBounds: .pipLowerRight,
                overlays: [SceneOverlay(kind: "streamAlert", enabled: true)],
                mix: [
                    AudioMixLevel(channelID: mic.id, gainDb: 0),
                    AudioMixLevel(channelID: desktop.id, gainDb: -3),
                ],
                duckDesktopAudio: true
            ),
        ]
        return StudioManifest(
            scenes: scenes,
            soundboard: [applause],
            videoSources: [camera, cameraB, screen],
            audioChannels: [mic, desktop, guest, slide, board],
            activeSceneID: StudioSeedID.solo,
            inspector: inspectorCatalog()
        )
    }

    static func installAssets(into bundle: ProjectBundle) throws -> (audio: String, logo: String, video: String, peaks: [Double]) {
        try FileManager.default.createDirectory(at: bundle.audioURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle.imagesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle.mediaURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle.videosURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle.waveformsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle.thumbnailsURL, withIntermediateDirectories: true)
        let audioURL = bundle.audioURL.appendingPathComponent("pre-service-bed.wav")
        try writeToneWAV(to: audioURL)
        let logoURL = bundle.imagesURL.appendingPathComponent("logo-bug.png")
        try writeLogoPNG(to: logoURL)
        let videoURL = bundle.videosURL.appendingPathComponent("countdown.mp4")
        try writeCountdownVideo(to: videoURL)
        let poster = bundle.thumbnailsURL.appendingPathComponent("countdown.png")
        _ = try? AssetPreview.writeVideoPoster(from: videoURL, to: poster)
        let peaks = (try? AssetPreview.waveformPeaks(fromAudioFile: audioURL, bucketCount: 64).map(Double.init))
            ?? waveformPeaks(from: audioURL, buckets: 64)
        let peakURL = bundle.waveformsURL.appendingPathComponent("pre-service-bed.json")
        try ProjectJSON.encoder.encode(peaks).write(to: peakURL, options: .atomic)
        return (
            audio: bundle.relativePath(for: audioURL),
            logo: bundle.relativePath(for: logoURL),
            video: bundle.relativePath(for: videoURL),
            peaks: peaks
        )
    }

    static func writeCountdownVideo(to url: URL) throws {
        _ = try AssetPreview.writeSolidVideo(to: url, width: 640, height: 360, seconds: 3, color: (27, 58, 75))
    }

    static func writeToneWAV(to url: URL, seconds: Double = 1.5, hz: Double = 440) throws {
        let sampleRate = 44100
        let samples = Int(seconds * Double(sampleRate))
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func u32(_ value: UInt32) {
            var little = value.littleEndian
            data.append(Data(bytes: &little, count: 4))
        }
        func u16(_ value: UInt16) {
            var little = value.littleEndian
            data.append(Data(bytes: &little, count: 2))
        }
        let dataSize = UInt32(samples * 2)
        ascii("RIFF")
        u32(36 + dataSize)
        ascii("WAVE")
        ascii("fmt ")
        u32(16)
        u16(1)
        u16(1)
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2))
        u16(2)
        u16(16)
        ascii("data")
        u32(dataSize)
        for index in 0..<samples {
            let sample = Int16((sin(2 * .pi * hz * Double(index) / Double(sampleRate)) * 0.28 * Double(Int16.max)).rounded())
            var little = sample.littleEndian
            data.append(Data(bytes: &little, count: 2))
        }
        try data.write(to: url, options: .atomic)
    }

    static func writeLogoPNG(to url: URL) throws {
        try AssetPreview.writeMarkPNG(to: url, size: 256)
    }

    static func inspectorCatalog() -> ActionInspectorCatalog {
        ActionInspectorCatalog(
            props: inspectorProps(),
            messages: inspectorMessages(),
            macros: inspectorMacros(),
            timers: inspectorTimers(),
            audioTracks: inspectorAudioTracks(),
            propCollections: ActionInspectorCatalog.defaultPropCollections,
            selectedPropCollection: "Default Collection"
        )
    }

    /// Template props carry explicit anchors so Phone auto-fit keeps them in their corner.
    static func anchored(_ objects: [CanvasObject]) -> [CanvasObject] {
        objects.map { var o = $0; if o.propAnchor == nil { o.propAnchor = PropCanvasLayout.inferAnchor(for: o) }; return o }
    }

    static func inspectorProps() -> [ProShowProp] {
        let documents = propDocuments()
        return [
            ProShowProp(
                id: ActionSeedID.logoProp,
                name: "Logo Bug",
                elements: anchored(documents.first?.objects ?? []),
                transitionDuration: 0.5,
                autoClearMode: .never,
                collectionName: "Default Collection",
                transition: "Dissolve"
            ),
            ProShowProp(
                id: ActionSeedID.alertProp,
                name: "Emergency Alert Message",
                elements: anchored(documents.dropFirst().first?.objects ?? []),
                transitionDuration: 0.5,
                autoClearMode: .onNextSlide,
                collectionName: "Default Collection",
                transition: "Cut"
            ),
        ]
    }

    static func inspectorMessages() -> [ProShowMessage] {
        [
            ProShowMessage(
                id: ActionSeedID.deskCallMessage,
                title: "Desk Call",
                templateText: "{Name} to the desk — {Custom Text}",
                dynamicValues: ["Number": "1", "Name": "Operator", "Custom Text": "stand by"],
                displayDuration: 10
            ),
        ]
    }

    static func inspectorTimers() -> [InspectorTimer] {
        [InspectorTimer(id: ActionSeedID.serviceTimer, name: "Program Timer", kind: .countdown, durationSeconds: 900)]
    }

    static func inspectorAudioTracks() -> [InspectorAudioTrack] {
        [InspectorAudioTrack(id: ActionSeedID.bedTrack, title: "Hold Bed", volume: 0.7, destination: .both)]
    }

    static func inspectorMacros() -> [ProShowMacro] {
        [
            ProShowMacro(
                id: ActionSeedID.showStartMacro,
                name: "Show Start",
                colorHex: "#22C55E",
                actions: [
                    .triggerScene(sceneId: StudioSeedID.solo),
                    .startTimer(timerId: ActionSeedID.serviceTimer),
                    .triggerProp(propId: ActionSeedID.logoProp),
                ]
            ),
            ProShowMacro(
                id: ActionSeedID.talkMacro,
                name: "Talk Mode",
                colorHex: "#3B82F6",
                actions: [
                    .clearLayer(layerName: "media"),
                    .setStageLayout(layoutId: ActionSeedID.layoutNotes),
                    .playAudioTrack(trackId: ActionSeedID.bedTrack),
                ]
            ),
            ProShowMacro(
                id: ActionSeedID.streamEndMacro,
                name: "Stream End",
                colorHex: "#EF4444",
                actions: [
                    .clearLayer(layerName: "all"),
                    .stopStream,
                    .muteAudio,
                ]
            ),
        ]
    }

    static func waveformPeaks(from url: URL, buckets: Int) -> [Double] {
        guard let data = try? Data(contentsOf: url), data.count > 44 else {
            return Array(repeating: 0.2, count: buckets)
        }
        let pcm = data.dropFirst(44)
        let sampleCount = pcm.count / 2
        guard sampleCount > 0 else { return Array(repeating: 0.2, count: buckets) }
        let window = max(1, sampleCount / buckets)
        return (0..<buckets).map { bucket in
            let start = bucket * window * 2
            var peak: Int16 = 0
            var offset = start
            while offset + 1 < pcm.count, offset < start + window * 2 {
                let value = Int16(truncatingIfNeeded: UInt16(pcm[pcm.startIndex + offset]) | UInt16(pcm[pcm.startIndex + offset + 1]) << 8)
                if abs(Int32(value)) > abs(Int32(peak)) { peak = value }
                offset += 2
            }
            return min(1, Double(abs(Int32(peak))) / Double(Int16.max))
        }
    }
}
