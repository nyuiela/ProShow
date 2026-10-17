import CoreGraphics
import CoreText
import Foundation
#if canImport(CoreVideo)
import CoreVideo
#endif
#if canImport(CoreMedia)
import CoreMedia
#endif

/// One hardware encode. Bitrate is not part of the key.
struct EncodeLaneKey: Hashable, Sendable {
    var width: Int
    var height: Int
    var frameRate: Int
    var codec: String
    var highProfile: Bool
    var keyframeIntervalSeconds: Double

    static func make(width: Int, height: Int, frameRate: Int, keyframeIntervalSeconds: Double) -> EncodeLaneKey {
        EncodeLaneKey(
            width: max(16, width),
            height: max(16, height),
            frameRate: max(1, frameRate),
            codec: "H264",
            highProfile: height >= 720,
            keyframeIntervalSeconds: keyframeIntervalSeconds
        )
    }
}

enum EncodeLaneRole: String, Sendable, Equatable {
    case stream
    case phone
    case custom
}

struct LaneMember: Equatable, Sendable, Identifiable {
    var id: UUID
    var screen: DestinationScreenKind
    var scaleMode: DestinationScaleMode
    var bitrateBps: Int
    var ceilingBps: Int
    /// Set only when this destination must leave the project preset. Nil keeps old shows on one Stream lane.
    var frameRate: Int? = nil
    var width: Int? = nil
    var height: Int? = nil

    var role: EncodeLaneRole {
        switch screen {
        case .stream: .stream
        case .phone: .phone
        case .custom: .custom
        case .wall: .stream
        }
    }
}

struct EncodeLane: Equatable, Sendable, Identifiable {
    var id: EncodeLaneKey { key }
    var role: EncodeLaneRole
    var key: EncodeLaneKey
    var members: [LaneMember]
    var scaleMode: DestinationScaleMode
    var targetBitrateBps: Int
    var ceilingBitrateBps: Int
}

struct EncodeLanePlan: Equatable, Sendable {
    var lanes: [EncodeLane]
    var displayOnlyIDs: [UUID]
    var refusedIDs: [UUID]

    var encodesStream: Bool { lanes.contains { $0.role == .stream } }
    var phoneLane: EncodeLane? { lanes.first { $0.role == .phone } }
    static let maxEncodeLanes = 2
}

enum PhoneEncodeTemplate {
    static let width = 1080
    static let height = 1920
    static let frameRate = 30
    static let keyframeIntervalSeconds = 2.0
    static let targetBitrateBps = 4_500_000
    static let ceilingBitrateBps = 6_000_000

    static var key: EncodeLaneKey {
        .make(width: width, height: height, frameRate: frameRate, keyframeIntervalSeconds: keyframeIntervalSeconds)
    }
}

enum PhoneBoardState: Equatable, Sendable {
    case absent
    case linked
    case present
}

enum PhoneSlideRouting {
    static func state(boards: [EditorCanvasFrame]) -> PhoneBoardState {
        let phone = boards.contains { $0.isPhoneArtboard }
        return phone ? .present : .absent
    }

    static func followsStream(_ state: PhoneBoardState) -> Bool {
        state != .present
    }

    /// Missing and linked boards always Fit. Fill applies only on a present canvas.
    static func scaleMode(requested: DestinationScaleMode, state: PhoneBoardState) -> DestinationScaleMode {
        state == .present ? requested : .fit
    }
}

struct FramePlacement: Equatable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var upscaled: Bool
}

enum FrameScale {
    static func placement(
        sourceWidth: Int,
        sourceHeight: Int,
        destWidth: Int,
        destHeight: Int,
        mode: DestinationScaleMode
    ) -> FramePlacement {
        let srcW = max(1, sourceWidth)
        let srcH = max(1, sourceHeight)
        let dstW = max(1, destWidth)
        let dstH = max(1, destHeight)
        let scale: Double
        if mode == .fill {
            scale = max(Double(dstW) / Double(srcW), Double(dstH) / Double(srcH))
        } else {
            scale = min(Double(dstW) / Double(srcW), Double(dstH) / Double(srcH))
        }
        var width = max(1, Int((Double(srcW) * scale).rounded()))
        var height = max(1, Int((Double(srcH) * scale).rounded()))
        if mode == .fit {
            width = min(dstW, width)
            height = min(dstH, height)
        }
        let x = (dstW - width) / 2
        let y = (dstH - height) / 2
        return FramePlacement(x: x, y: y, width: width, height: height, upscaled: scale > 1.001)
    }
}

enum EncodeLaneGrouper {
    static func group(members: [LaneMember], streamPreset: StreamEncoderConfig) -> EncodeLanePlan {
        var display: [UUID] = []
        var buckets: [(role: EncodeLaneRole, key: EncodeLaneKey, members: [LaneMember])] = []
        for member in members {
            if member.screen == .wall {
                display.append(member.id)
                continue
            }
            let role = member.role
            let key = key(for: member, role: role, streamPreset: streamPreset)
            if let index = buckets.firstIndex(where: { $0.role == role && $0.key == key }) {
                buckets[index].members.append(member)
            } else {
                buckets.append((role, key, [member]))
            }
        }
        let order: [EncodeLaneRole] = [.stream, .phone, .custom]
        buckets.sort { lhs, rhs in
            let left = order.firstIndex(of: lhs.role) ?? 0
            let right = order.firstIndex(of: rhs.role) ?? 0
            if left != right { return left < right }
            return lhs.members.count > rhs.members.count
        }
        var lanes: [EncodeLane] = []
        var refused: [UUID] = []
        for bucket in buckets {
            if lanes.count >= EncodeLanePlan.maxEncodeLanes {
                refused.append(contentsOf: bucket.members.map(\.id))
                continue
            }
            let target = bucket.members.map(\.bitrateBps).min() ?? PhoneEncodeTemplate.targetBitrateBps
            let ceiling = max(target, bucket.members.map(\.ceilingBps).min() ?? target)
            let scale: DestinationScaleMode = bucket.members.contains { $0.scaleMode == .fit } ? .fit : .fill
            lanes.append(EncodeLane(
                role: bucket.role,
                key: bucket.key,
                members: bucket.members,
                scaleMode: scale,
                targetBitrateBps: target,
                ceilingBitrateBps: ceiling
            ))
        }
        return EncodeLanePlan(lanes: lanes, displayOnlyIDs: display, refusedIDs: refused)
    }

    static func key(for member: LaneMember, role: EncodeLaneRole, streamPreset: StreamEncoderConfig) -> EncodeLaneKey {
        switch role {
        case .phone:
            return .make(
                width: member.width ?? PhoneEncodeTemplate.width,
                height: member.height ?? PhoneEncodeTemplate.height,
                frameRate: member.frameRate ?? PhoneEncodeTemplate.frameRate,
                keyframeIntervalSeconds: PhoneEncodeTemplate.keyframeIntervalSeconds
            )
        case .stream, .custom:
            return .make(
                width: member.width ?? streamPreset.width,
                height: member.height ?? streamPreset.height,
                frameRate: member.frameRate ?? streamPreset.frameRate,
                keyframeIntervalSeconds: streamPreset.keyframeIntervalSeconds
            )
        }
    }
}

/// Latest Phone composite. The encode ticker repeats it between program frames.
final class PhoneComposedFrame: @unchecked Sendable {
    static let shared = PhoneComposedFrame()
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var storedAt: Date = .distantPast

    func store(_ buffer: CVPixelBuffer) {
        let owned = ProgramOutputComposer.snapshot(buffer)
        lock.lock()
        self.buffer = owned
        storedAt = Date()
        lock.unlock()
    }

    /// The composed Phone frame only while the program keeps producing it; a stale frame (old timer text) is ignored.
    func fresh(maxAge: TimeInterval = 0.75) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(storedAt) <= maxAge ? buffer : nil
    }

    func current() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func clear() {
        lock.lock()
        buffer = nil
        lock.unlock()
    }
}

/// Live program frames for the Phone encode. The Stream ticker does not see this lane.
final class PhoneFrameIngress: @unchecked Sendable {
    static let shared = PhoneFrameIngress()
    private let lock = NSLock()
    private var consumer: (@Sendable (CVPixelBuffer) -> Void)?

    func setConsumer(_ consumer: (@Sendable (CVPixelBuffer) -> Void)?) {
        lock.lock()
        self.consumer = consumer
        lock.unlock()
    }

    func push(_ buffer: CVPixelBuffer) {
        lock.lock()
        let consumer = self.consumer
        lock.unlock()
        consumer?(buffer)
    }
}

enum ProgramAudioAccessTap {
    private static let lock = NSLock()
    private static var handlers: [UUID: @Sendable (ProgramAudioAccessUnit) -> Void] = [:]
    private static var consumerCount = 0

    static var hasConsumers: Bool { consumerCount > 0 }

    @discardableResult
    static func add(_ handler: @escaping @Sendable (ProgramAudioAccessUnit) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        handlers[id] = handler
        consumerCount = handlers.count
        lock.unlock()
        return id
    }

    static func remove(_ id: UUID) {
        lock.lock()
        handlers[id] = nil
        consumerCount = handlers.count
        lock.unlock()
    }

    static func publish(_ unit: ProgramAudioAccessUnit) {
        guard consumerCount > 0 else { return }
        lock.lock()
        let current = Array(handlers.values)
        lock.unlock()
        for handler in current {
            handler(unit)
        }
    }
}

#if canImport(CoreVideo)
/// Phone encode beside the Stream session. Work stays off the program encoder queue.
final class PhoneEncodeLane: @unchecked Sendable {
    let encoder = HardwareVideoEncoder()
    let transport = MultiRTMPTransport()
    private let queue = DispatchQueue(label: "com.proshow.phone.lane", qos: .userInitiated)
    private var ticker: DispatchSourceTimer?
    private var audioTapID: UUID?
    private var busy = false
    private var state: PhoneBoardState = .absent
    private var presentBuffer: CVPixelBuffer?
    private var lastFitted: CVPixelBuffer?
    private var scaleMode: DestinationScaleMode = .fit
    private(set) var failed = false
    private(set) var pumpsAudio = false

    func start(ingests: [ResolvedIngest], lane: EncodeLane, pumpsAudio: Bool) -> Bool {
        guard !ingests.isEmpty else { return false }
        self.pumpsAudio = pumpsAudio
        self.scaleMode = lane.scaleMode
        var config = RtmpStreamConfig.default
        var encoderConfig = StreamEncoderConfig(
            presetName: "Phone",
            width: lane.key.width,
            height: lane.key.height,
            frameRate: lane.key.frameRate,
            targetBitrateBps: lane.targetBitrateBps,
            maxBitrateCeilingBps: lane.ceilingBitrateBps,
            keyframeIntervalSeconds: lane.key.keyframeIntervalSeconds
        )
        encoderConfig.apply(to: &config)
        if ingests.count >= 2 {
            config.useCloudRelay = true
            config.relayDestinations = ingests.map {
                RelayDestination(id: $0.accountID, name: $0.name, url: $0.publicURLString, streamKey: $0.streamKey)
            }
            config.destinationURL = ingests[0].publicURLString
            config.streamKey = ingests[0].streamKey
        } else {
            config.useCloudRelay = false
            config.relayDestinations = []
            config.destinationURL = ingests[0].publicURLString
            config.streamKey = ingests[0].streamKey
        }
        encoder.sessionQueue = queue
        encoder.setupStream(config: encoderConfig)
        guard encoder.isPrepared else {
            failed = true
            return false
        }
        transport.suppressSharedAudioPump = !pumpsAudio
        do {
            try transport.connect(config: config)
        } catch {
            failed = true
            encoder.teardown()
            return false
        }
        encoder.onEncoded = { [transport] packet in
            let message = RTMPClient.videoMessage(packet)
            let kind: RTMPOutboundTag
            switch packet {
            case .sequenceHeader:
                transport.rememberVideoSequenceHeader(message)
                kind = .video(keyframe: true)
            case .accessUnit(_, let keyframe, _):
                kind = .video(keyframe: keyframe)
            }
            transport.send(message, kind: kind)
        }
        if !pumpsAudio {
            audioTapID = ProgramAudioAccessTap.add { [transport] unit in
                transport.send(
                    RTMPClient.audioMessage(.accessUnit(timestampMs: unit.timestampMs, aac: unit.aac)),
                    kind: .audio
                )
            }
        }
        PhoneFrameIngress.shared.setConsumer { [weak self] buffer in
            self?.acceptStreamFrame(buffer)
        }
        startTicker()
        failed = false
        return true
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        PhoneFrameIngress.shared.setConsumer(nil)
        if let audioTapID {
            ProgramAudioAccessTap.remove(audioTapID)
            self.audioTapID = nil
        }
        encoder.onEncoded = nil
        encoder.teardown()
        transport.disconnect()
        presentBuffer = nil
        lastFitted = nil
        PhoneComposedFrame.shared.clear()
    }

    func note(state: PhoneBoardState, boards: [EditorCanvasFrame], scaleMode: DestinationScaleMode) {
        let boards = boards
        let requested = scaleMode
        queue.async { [weak self] in
            guard let self else { return }
            self.state = state
            self.scaleMode = PhoneSlideRouting.scaleMode(requested: requested, state: state)
            guard state == .present, let board = boards.first(where: {
                !$0.isPrimary && CanvasResolution.screenFamily(width: $0.width, height: $0.height) == .phone
            }) else {
                self.presentBuffer = nil
                PhoneComposedFrame.shared.clear()
                return
            }
            self.presentBuffer = PhoneBoardRaster.buffer(
                board: board,
                width: PhoneEncodeTemplate.width,
                height: PhoneEncodeTemplate.height
            )
            self.lastFitted = nil
        }
    }

    func acceptStreamFrame(_ pixelBuffer: CVPixelBuffer) {
        queue.async { [weak self] in
            self?.latestSource = pixelBuffer
        }
    }

    private var latestSource: CVPixelBuffer?
    private var frameIndex: Int64 = 0
    private var sentWhileReady = false

    private func startTicker() {
        ticker?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = 1.0 / Double(PhoneEncodeTemplate.frameRate)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.emitTick()
        }
        timer.resume()
        ticker = timer
    }

    private func emitTick() {
        guard transport.isReady, !busy else { return }
        busy = true
        defer { busy = false }
        let frame: CVPixelBuffer
        if state == .present {
            if let live = PhoneComposedFrame.shared.current() {
                frame = live
            } else if let presentBuffer {
                frame = presentBuffer
            } else {
                return
            }
        } else if let latestSource {
            let fitted = PhoneFrameFit.letterbox(
                latestSource,
                destWidth: PhoneEncodeTemplate.width,
                destHeight: PhoneEncodeTemplate.height,
                mode: scaleMode
            )
            guard let fitted = fitted ?? lastFitted else { return }
            frame = fitted
            lastFitted = fitted
        } else if let lastFitted {
            frame = lastFitted
        } else {
            return
        }
        let index = frameIndex
        frameIndex += 1
        let force = !sentWhileReady
            || transport.clientNeedsVideoConfig()
            || index % Int64(PhoneEncodeTemplate.frameRate * 2) == 0
        sentWhileReady = true
        let pts = CMTime(value: index, timescale: CMTimeScale(PhoneEncodeTemplate.frameRate))
        encoder.encodeOnMasterClock(pixelBuffer: frame, presentationTime: pts, forceKeyframe: force)
    }
}

enum PhoneFrameFit {
    static func letterbox(
        _ source: CVPixelBuffer,
        destWidth: Int,
        destHeight: Int,
        mode: DestinationScaleMode
    ) -> CVPixelBuffer? {
        let srcW = CVPixelBufferGetWidth(source)
        let srcH = CVPixelBufferGetHeight(source)
        guard srcW > 0, srcH > 0, destWidth > 0, destHeight > 0 else { return nil }
        let place = FrameScale.placement(
            sourceWidth: srcW,
            sourceHeight: srcH,
            destWidth: destWidth,
            destHeight: destHeight,
            mode: mode
        )
        guard let dest = makeBuffer(width: destWidth, height: destHeight) else { return nil }
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return nil }
        guard CVPixelBufferLockBaseAddress(dest, []) == kCVReturnSuccess else {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            return nil
        }
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(dest, [])
        }
        guard let srcBase = CVPixelBufferGetBaseAddress(source),
              let dstBase = CVPixelBufferGetBaseAddress(dest) else { return nil }
        let srcStride = CVPixelBufferGetBytesPerRow(source)
        let dstStride = CVPixelBufferGetBytesPerRow(dest)
        memset(dstBase, 0, dstStride * destHeight)
        guard place.width > 0, place.height > 0 else { return dest }
        for y in 0..<place.height {
            let srcY = min(srcH - 1, y * srcH / place.height)
            let dstRow = dstBase.advanced(by: (place.y + y) * dstStride).assumingMemoryBound(to: UInt8.self)
            let srcRow = srcBase.advanced(by: srcY * srcStride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<place.width {
                let srcX = min(srcW - 1, x * srcW / place.width)
                let dst = (place.x + x) * 4
                let src = srcX * 4
                dstRow[dst] = srcRow[src]
                dstRow[dst + 1] = srcRow[src + 1]
                dstRow[dst + 2] = srcRow[src + 2]
                dstRow[dst + 3] = srcRow[src + 3]
            }
        }
        return dest
    }

    static func makeBuffer(width: Int, height: Int, fill: UInt8 = 0) -> CVPixelBuffer? {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }
        if fill != 0, CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess {
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(fill), CVPixelBufferGetBytesPerRow(buffer) * height)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
        }
        return buffer
    }
}

enum PhoneBoardRaster {
    static func buffer(board: EditorCanvasFrame, width: Int, height: Int) -> CVPixelBuffer? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        let background = board.backgroundEnabled ? cgColor(hex: board.backgroundHex) : CGColor(gray: 0, alpha: 1)
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scaleX = CGFloat(width) / CGFloat(max(board.width, 1))
        let scaleY = CGFloat(height) / CGFloat(max(board.height, 1))
        let ordered = board.objects.sorted { $0.zIndex < $1.zIndex }
        for object in ordered where object.visibleOnAudience {
            let rect = CGRect(
                x: object.transform.x * scaleX,
                y: CGFloat(height) - CGFloat(object.transform.y + object.transform.height) * scaleY,
                width: object.transform.width * scaleX,
                height: object.transform.height * scaleY
            )
            let path = shapePath(object, rect: rect, scale: scaleY)
            context.saveGState()
            context.setAlpha(CGFloat(min(1, max(0, object.opacity))))
            if object.fill.type != .none {
                context.setFillColor(cgColor(hex: object.fill.color, alpha: object.fill.opacity))
                context.addPath(path)
                context.fillPath()
            }
            if object.stroke.style != .none, object.stroke.width > 0 {
                context.setStrokeColor(cgColor(hex: object.stroke.color))
                context.setLineWidth(max(1, object.stroke.width * scaleY))
                context.addPath(path)
                context.strokePath()
            }
            context.restoreGState()
            let text = object.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if object.isTextLike, !text.isEmpty {
                let fontSize = max(8, object.typography.fontSize * Double(scaleY))
                let font = CTFontCreateWithName(object.typography.fontFamily as CFString, fontSize, nil)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: cgColor(hex: object.typography.color),
                ]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
                context.textPosition = CGPoint(x: rect.minX + 8, y: rect.midY)
                CTLineDraw(line, context)
            }
        }
        guard let image = context.makeImage(), let dest = PhoneFrameFit.makeBuffer(width: width, height: height) else { return nil }
        guard CVPixelBufferLockBaseAddress(dest, []) == kCVReturnSuccess,
              let base = CVPixelBufferGetBaseAddress(dest) else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(dest, []) }
        guard let drawn = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(dest),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        drawn.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return dest
    }

    private static func shapePath(_ object: CanvasObject, rect: CGRect, scale: CGFloat) -> CGPath {
        switch object.kind {
        case .ellipse:
            return CGPath(ellipseIn: rect, transform: nil)
        case .line:
            let path = CGMutablePath()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        default:
            let limit = min(rect.width, rect.height) / 2
            let radius = min(CGFloat(object.stroke.cornerRadius) * scale, limit)
            if object.kind == .roundedRectangle || radius > 0.5 {
                return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            }
            return CGPath(rect: rect, transform: nil)
        }
    }

    private static func cgColor(hex: String, alpha: Double = 1) -> CGColor {
        var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") { raw.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: raw).scanHexInt64(&value)
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        return CGColor(red: r, green: g, blue: b, alpha: CGFloat(min(1, max(0, alpha))))
    }
}
#endif
