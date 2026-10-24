import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Producer talkback (intercom). Captures its own mic in its own session and hands 20 ms
/// packets of 16 kHz mono PCM to the room as targeted lossy data. It never touches the program
/// mix, the stream encoder or the mic lane: nothing here calls ProgramStreamAudioGates.
///
/// Packet: "PI" (2), version 1 (1), flags (1), seq UInt32 LE (4), rate/100 UInt16 LE (2),
/// reserved (2), then 320 Int16 LE samples (640 bytes). Fits one SCTP packet.
final class TalkbackEngine: NSObject, @unchecked Sendable {
    static let shared = TalkbackEngine()
    static let sampleRate = 16_000
    static let samplesPerPacket = 320
    static let headerBytes = 12

    private let queue = DispatchQueue(label: "proshow.talkback", qos: .userInteractive)
    private let lock = NSLock()
    private var pending = Data()
    private var seq: UInt32 = 0
    private var onPacket: (@Sendable (Data) -> Void)?
    private var peak: Float = 0
    private(set) var isRunning = false
    #if canImport(AVFoundation)
    private var session: AVCaptureSession?
    #endif
    private var toneTimer: DispatchSourceTimer?
    private var tonePhase = 0.0

    var sentPackets: UInt32 {
        lock.lock()
        defer { lock.unlock() }
        return seq
    }

    /// Peak of the last packets, 0...1. Read on main for the talk indicator.
    var level: Float {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }

    /// Talk mics, as (uniqueID, name).
    static func microphones() -> [(id: String, name: String)] {
        #if canImport(AVFoundation)
        var types: [AVCaptureDevice.DeviceType] = []
        if #available(macOS 14.0, iOS 17.0, *) { types.append(.microphone) } else { types.append(.builtInMicrophone) }
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .audio, position: .unspecified).devices
        return found.map { ($0.uniqueID, $0.localizedName) }
        #else
        return []
        #endif
    }

    /// `toneHz` replaces the mic with a test tone (QA only).
    func start(deviceID: String?, toneHz: Double? = nil, onPacket: @escaping @Sendable (Data) -> Void) {
        stop()
        lock.lock()
        self.onPacket = onPacket
        pending.removeAll(keepingCapacity: true)
        seq = 0
        lock.unlock()
        isRunning = true
        if let toneHz {
            startTone(hz: toneHz)
            return
        }
        #if canImport(AVFoundation)
        let device = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .audio)
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else {
            isRunning = false
            return
        }
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        #if os(macOS)
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        #endif
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        self.session = session
        queue.async { session.startRunning() }
        #endif
    }

    func stop() {
        toneTimer?.cancel()
        toneTimer = nil
        #if canImport(AVFoundation)
        if let session {
            self.session = nil
            queue.async { session.stopRunning() }
        }
        #endif
        lock.lock()
        onPacket = nil
        pending.removeAll()
        peak = 0
        lock.unlock()
        isRunning = false
    }

    /// Clock-driven: each tick emits the samples due since start, so a throttled timer
    /// (App Nap in the background) cannot slow the packet rate.
    private func startTone(hz: Double) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let start = DispatchTime.now().uptimeNanoseconds
        var emitted = 0
        let step = 2 * Double.pi * hz / Double(Self.sampleRate)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            let due = min(Int(elapsed * Double(Self.sampleRate)) - emitted, Self.sampleRate)
            guard due > 0 else { return }
            var bytes = Data(count: due * 2)
            bytes.withUnsafeMutableBytes { raw in
                let out = raw.bindMemory(to: Int16.self)
                for index in 0..<due {
                    out[index] = Int16(littleEndian: Int16(sin(self.tonePhase) * 8_000))
                    self.tonePhase += step
                }
            }
            emitted += due
            self.tonePhase.formTruncatingRemainder(dividingBy: 2 * Double.pi)
            self.append(bytes)
        }
        toneTimer = timer
        timer.resume()
    }

    fileprivate func append(_ pcm: Data) {
        var packets: [Data] = []
        lock.lock()
        pending.append(pcm)
        let size = Self.samplesPerPacket * 2
        while pending.count >= size {
            let chunk = pending.prefix(size)
            pending.removeFirst(size)
            var header = Data([0x50, 0x49, 1, 0])
            var s = seq.littleEndian
            header.append(Data(bytes: &s, count: 4))
            var rate = UInt16(Self.sampleRate / 100).littleEndian
            header.append(Data(bytes: &rate, count: 2))
            header.append(contentsOf: [0, 0])
            seq &+= 1
            var packetPeak: Int16 = 0
            chunk.withUnsafeBytes { raw in
                for sample in raw.bindMemory(to: Int16.self) {
                    let magnitude = sample == Int16.min ? Int16.max : abs(Int16(littleEndian: sample))
                    if magnitude > packetPeak { packetPeak = magnitude }
                }
            }
            peak = max(peak * 0.8, Float(packetPeak) / 32_767)
            packets.append(header + chunk)
        }
        let send = onPacket
        lock.unlock()
        for packet in packets { send?(packet) }
    }
}

#if canImport(AVFoundation)
extension TalkbackEngine: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw -> OSStatus in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard status == noErr else { return }
        append(data)
    }
}
#endif
