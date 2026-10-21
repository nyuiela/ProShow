import Foundation

extension ShowController {
    var streamEncoderConfig: StreamEncoderConfig {
        streaming.streamEncoderConfig
    }

    func applyStreamEncoderConfig(_ config: StreamEncoderConfig) {
        streaming.applyStreamEncoderConfig(config)
    }

    func armedStreamAccounts() -> [StreamAccount] {
        deviceSettings.document.accounts.filter { streamMatrix.isActive($0.id) }
    }

    func openGoLiveSetup() {
        dismissDeskWorkspaceSheets()
        if broadcastMetadata.trimmedTitle.isEmpty {
            broadcastMetadata.title = show.name
        }
        isGoLiveSetupPresented = true
    }

    func stopBroadcast() {
        streaming.stop()
        chatIngest?.stopAutoStarted()
        isProvisioningStreams = false
        lastBroadcastError = nil
        evaluateProgramClockState()
        resetStreamCapturePrivacy()
    }

    var displayProjectName: String {
        projectDisplayName
    }

    /// Dimensions written to program / ISO files — must match `submitProgramOutput` delivery.
    func programOutputEncodeDimensions() -> (width: Int, height: Int) {
        let contract = currentProgramRenderContract()
        return (contract.width, contract.height)
    }

    @discardableResult
    func startProgramRecording(startedAt: Date = Date()) -> Bool {
        guard !isoRecorder.isRecording else { return true }
        let outputDirectory = StreamRecordingPaths.moviesStreamDirectory
        guard StreamRecordingPaths.ensureWritableDirectory(outputDirectory) else {
            isoRecorder.reportRecordingSetupFailure(StreamRecordingPaths.writeAccessError(for: outputDirectory))
            return false
        }
        let dims: (width: Int, height: Int)
        if streaming.isLive {
            dims = (max(16, streaming.config.width), max(16, streaming.config.height))
        } else {
            dims = StreamRecordingPaths.cappedForRecording(
                width: compositor.outputWidth,
                height: compositor.outputHeight
            )
        }
        var filename = StreamRecordingPaths.filename(projectName: displayProjectName, startedAt: startedAt)
        if filename.hasSuffix(".mp4") {
            filename = String(filename.dropLast(4)) + ".mov"
        }
        let fileURL = outputDirectory.appendingPathComponent(filename)
        #if canImport(AVFoundation)
        let recordFPS: Int = {
            if streaming.isLive {
                return max(1, streaming.config.framerate)
            }
            return min(30, projectSettings.frameRate.encoderFPS)
        }()
        let writerResult: Result<ProgramVideoFileRecorder, ProgramRecordingSetupFailure> = streaming.isLive
            ? ProgramVideoFileRecorder.makePassthrough(
                url: fileURL,
                width: dims.width,
                height: dims.height,
                fps: recordFPS
            )
            : ProgramVideoFileRecorder.make(
                url: fileURL,
                codec: .h264,
                width: dims.width,
                height: dims.height,
                fps: recordFPS
            )
        switch writerResult {
        case let .success(writer):
            if !streaming.isLive {
                ProgramAACEncoder.prepare(audioBitrateBps: streamEncoderConfig.audioBitrateBps)
            }
            isoRecorder.outputDirectory = outputDirectory
            isoRecorder.attachProgramWriter(writer, useLocalAudioPump: !streaming.isLive)
            _ = isoRecorder.start(
                program: true,
                codec: .h264,
                width: dims.width,
                height: dims.height,
                fps: recordFPS,
                programFilename: filename
            )
        case let .failure(error):
            isoRecorder.reportRecordingSetupFailure(error.localizedDescription)
            return false
        }
        #else
        return false
        #endif
        evaluateProgramClockState()
        #if os(macOS)
        prefetchUpcomingRundownBrowserPages()
        #endif
        return isoRecorder.isRecording
    }

    func stopProgramRecording() {
        isoRecorder.stop()
        if !streaming.isLive {
            streaming.releaseEncoderIfIdle()
        }
        evaluateProgramClockState()
    }

    func toggleProgramRecording() {
        if isoRecorder.isRecording {
            stopProgramRecording()
        } else {
            _ = startProgramRecording()
        }
    }

    @discardableResult
    func startIsoChannelRecording(startedAt: Date = Date()) -> Bool {
        let channels = videoInputs.ingest.activeIsoChannelConfigs()
        guard !channels.isEmpty else { return false }
        let root = StreamRecordingPaths.moviesStreamDirectory
            .appendingPathComponent("ISO", isDirectory: true)
        if !isoRecorder.isRecording {
            _ = startProgramRecording(startedAt: startedAt)
        }
        isoRecorder.startIsolatedChannels(channels, outputDirectory: root)
        evaluateProgramClockState()
        return isoRecorder.isIsoMultiChannelRecording
    }

    func stopIsoChannelRecording() {
        isoRecorder.stopIsolatedChannelsOnly()
        evaluateProgramClockState()
    }

    func toggleIsoChannelRecording() {
        if isoRecorder.isIsoMultiChannelRecording {
            stopIsoChannelRecording()
        } else {
            _ = startIsoChannelRecording()
        }
    }

    @discardableResult
    func startMultiPlatformBroadcast(
        metadata: BroadcastMetadata,
        accounts: [StreamAccount],
        api: PlatformLiveApiService = .shared,
        skipPreflight: Bool = false
    ) async -> Bool {
        lastBroadcastError = nil
        if let invalid = metadata.validate() {
            lastBroadcastError = invalid
            return false
        }
        let selected = accounts
        guard !selected.isEmpty else {
            lastBroadcastError = "Select at least one destination."
            return false
        }
        for account in selected {
            streamMatrix.activeAccountIds.insert(account.id)
        }
        broadcastMetadata = metadata
        if !skipPreflight {
            let preflight = runPreFlight(intent: .startStream, handshake: nil)
            if !preflight.canProceed {
                isGoLiveSetupPresented = false
                isPreFlightPresented = true
                lastBroadcastError = "Pre-flight found blocking issues."
                return false
            }
        }
        isProvisioningStreams = true
        var readyAccounts = selected
        if api.tokenProvider == nil {
            for index in readyAccounts.indices where readyAccounts[index].supportsOAuth {
                do {
                    let tokens = try await StreamAccountManager.shared.ensureValidAccessToken(for: readyAccounts[index])
                    readyAccounts[index].tokenExpiresAt = tokens.expiresAt
                    readyAccounts[index].lastAuthenticated = Date()
                    deviceSettings.upsert(readyAccounts[index], secret: nil)
                } catch {
                    continue
                }
            }
        }
        var ingests: [ResolvedIngest] = []
        var provisionError: String?
        await withTaskGroup(of: (StreamPlatform, Result<ResolvedIngest, Error>).self) { group in
            for account in readyAccounts {
                group.addTask {
                    do {
                        return (account.platform, .success(try await api.provisionLiveBroadcast(for: account, metadata: metadata)))
                    } catch {
                        return (account.platform, .failure(error))
                    }
                }
            }
            for await (platform, result) in group {
                switch result {
                case .success(let ingest) where !ingest.streamKey.isEmpty:
                    ingests.append(ingest)
                case .success:
                    provisionError = provisionError ?? "\(platform.title) did not return a stream key."
                case .failure(let error):
                    provisionError = provisionError ?? Self.broadcastFailureMessage(error, platform: platform)
                }
            }
        }
        guard !ingests.isEmpty else {
            isProvisioningStreams = false
            lastBroadcastError = provisionError ?? "Could not create the live stream. Reconnect the selected destination and try again."
            return false
        }
        streaming.configureOutputs(ingests, accounts: readyAccounts)
        applyActiveStreamMatrixFromIngests(ingests)
        let ingestPolicies = PlatformIngestPolicy.policies(for: readyAccounts)
        if streaming.transport is MockStreamTransport == false {
            streaming.transport = RTMPClient.fanoutConfigs(from: streaming.config).count > 1
                ? MultiRTMPTransport()
                : RTMPStreamTransport()
        }
        let accepted = streaming.start(ingestPolicies: ingestPolicies)
        publishCurrentPhoneCanvas()
        if !accepted {
            isProvisioningStreams = false
            lastBroadcastError = streaming.lastError ?? "Encoder failed to start."
            return false
        }
        let live = await streaming.waitUntilLiveOrFailed()
        isProvisioningStreams = false
        if !live {
            lastBroadcastError = streaming.lastError ?? "Stream failed. Retry."
            return false
        }
        isGoLiveSetupPresented = false
        ProgramStreamAudioGates.sync(from: audioMatrix)
        evaluateProgramClockState()
        #if os(macOS)
        prefetchUpcomingRundownBrowserPages()
        #endif
        Task {
            let listingIngests = await prepareXBroadcasts(ingests, metadata: metadata, api: api)
            await transitionYouTubeBroadcasts(listingIngests, api: api)
            startYouTubeChatAfterGoLive(listingIngests)
            startXChatAfterGoLive(listingIngests)
            await finishXBroadcasts(listingIngests, metadata: metadata, api: api)
        }
        return true
    }

    private func accessToken(for account: StreamAccount, api: PlatformLiveApiService) async -> String? {
        if let provided = api.tokenProvider?(account), !provided.isEmpty {
            return provided
        }
        if let refreshed = try? await StreamAccountManager.shared.ensureValidAccessToken(for: account).accessToken,
           !refreshed.isEmpty {
            return refreshed
        }
        if let stored = KeychainStreamVault.load(identifier: account.oauthAccessIdentifier), !stored.isEmpty {
            return stored
        }
        return nil
    }

    private func prepareXBroadcasts(
        _ ingests: [ResolvedIngest],
        metadata: BroadcastMetadata,
        api: PlatformLiveApiService
    ) async -> [ResolvedIngest] {
        guard metadata.publishesSocialListing else { return ingests }
        let jpeg = metadata.userChosenThumbnailJPEG
        var prepared = ingests
        for index in prepared.indices where prepared[index].platform == .twitter {
            guard let account = deviceSettings.document.accounts.first(where: { $0.id == prepared[index].accountID }),
                  let token = await accessToken(for: account, api: api)
            else { continue }
            if let broadcastID = await XLiveService.createScheduledBroadcast(
                ingest: prepared[index],
                metadata: metadata,
                thumbnailJPEG: jpeg,
                token: token,
                transport: api.transport
            ) {
                prepared[index].broadcastID = broadcastID
            }
        }
        return prepared
    }

    private func finishXBroadcasts(
        _ ingests: [ResolvedIngest],
        metadata: BroadcastMetadata,
        api: PlatformLiveApiService
    ) async {
        guard metadata.publishesSocialListing else { return }
        let jpeg = metadata.userChosenThumbnailJPEG
        var posted = false
        var failure: PlatformLiveError?
        for ingest in ingests where ingest.platform == .twitter {
            guard let account = deviceSettings.document.accounts.first(where: { $0.id == ingest.accountID }),
                  let token = await accessToken(for: account, api: api)
            else {
                failure = failure ?? .missingAccessToken
                continue
            }
            switch await XLiveService.publishGoLive(
                ingest: ingest,
                metadata: metadata,
                thumbnailJPEG: jpeg,
                token: token,
                transport: api.transport
            ) {
            case .success:
                posted = true
            case .failure(let error):
                failure = failure ?? error
            }
        }
        if !posted, let failure, ingests.contains(where: { $0.platform == .twitter }) {
            lastBroadcastError = XLiveService.userFacingGoLiveFailure(failure)
        }
    }

    private func transitionYouTubeBroadcasts(_ ingests: [ResolvedIngest], api: PlatformLiveApiService) async {
        for ingest in ingests where ingest.platform == .youtube && !ingest.broadcastID.isEmpty {
            guard let account = deviceSettings.document.accounts.first(where: { $0.id == ingest.accountID }) else { continue }
            guard let token = await accessToken(for: account, api: api) else { continue }
            if !ingest.streamID.isEmpty {
                _ = await YouTubeLiveService.waitUntilStreamActive(
                    streamID: ingest.streamID,
                    token: token,
                    transport: api.transport
                )
            } else {
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            await YouTubeLiveService.transitionToLive(
                broadcastID: ingest.broadcastID,
                token: token,
                transport: api.transport
            )
        }
    }

    private func applyActiveStreamMatrixFromIngests(_ ingests: [ResolvedIngest]) {
        if ingests.count >= 2 {
            streaming.setRelayDestinations(ingests.map {
                RelayDestination(id: $0.accountID, name: $0.name, url: $0.publicURLString, streamKey: $0.streamKey)
            })
        }
    }

    var liveBroadcastTimecode: String {
        StreamingEngine.broadcastTimecode(from: streaming.startedAt)
    }

    func startBroadcastForArmedAccounts() async -> Bool {
        if broadcastMetadata.trimmedTitle.isEmpty {
            broadcastMetadata.title = show.name
        }
        let accounts = deviceSettings.document.accounts.filter { streamMatrix.isActive($0.id) }
        if accounts.isEmpty {
            lastBroadcastError = "Select a destination in Broadcast Setup."
            openGoLiveSetup()
            return false
        }
        return await startMultiPlatformBroadcast(metadata: broadcastMetadata, accounts: accounts)
    }

    static func broadcastFailureMessage(_ error: Error, platform: StreamPlatform = .youtube) -> String {
        let name = platform.title
        if let live = error as? PlatformLiveError {
            switch live {
            case .missingAccessToken, .expiredSession:
                return "\(name) sign-in expired. Reconnect that destination, then go live again."
            case .missingIngest:
                return missingIngestMessage(for: platform)
            case .httpStatus(let code):
                return "\(name) returned HTTP \(code)."
            case .unsupportedPlatform:
                return "This destination cannot be provisioned."
            case .provider(let message):
                if PlatformLiveError.looksLikeInvalidCredentials(message) {
                    return "\(name) sign-in expired. Reconnect that destination, then go live again."
                }
                return message
            }
        }
        if let oauth = error as? StreamOAuthError {
            switch oauth {
            case .expiredSession:
                return "\(name) sign-in expired. Reconnect that destination, then go live again."
            case .providerRejected(let reason):
                return reason
            default:
                break
            }
        }
        return error.localizedDescription
    }

    private static func missingIngestMessage(for platform: StreamPlatform) -> String {
        switch platform {
        case .youtube:
            return "YouTube did not issue a stream key. Enable YouTube Live on this channel and try again."
        case .linkedin:
            return "LinkedIn does not mint a stream key from sign-in. Open Live Studio, click Get URL, paste the RTMP URL and key below, then start again."
        case .twitter:
            return "X does not mint a stream key from sign-in. Premium only unlocks studio.x.com. Create an RTMP source there, paste the URL and key below, then start again."
        case .facebook:
            return "Facebook did not issue a stream key. Confirm Page Live access, then try again."
        case .customRtmp, .srt:
            return "This destination has no stream key. Paste the key from the server, then try again."
        }
    }
}
