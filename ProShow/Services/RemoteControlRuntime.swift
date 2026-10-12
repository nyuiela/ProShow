import CoreMIDI
import Foundation
import Network

/// Localhost OSC UDP and CoreMIDI input. Does not scan cameras or load NDI.
final class RemoteControlRuntime: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.kaleel.proshow.remote-input")
    private var loopback: LoopbackListener?
    private var apply: (@Sendable (RemoteControlCommand) -> Void)?
    private var midiClient: MIDIClientRef = 0
    private var midiPort: MIDIPortRef = 0
    private var midiBox: MIDIApplyBox?
    private(set) var boundPort: UInt16 = 0

    func start(
        oscPort: UInt16 = 8000,
        oscEnabled: Bool,
        midiEnabled: Bool,
        apply: @escaping @Sendable (RemoteControlCommand) -> Void
    ) {
        stop()
        self.apply = apply
        if oscEnabled {
            startOSC(port: oscPort)
        }
        if midiEnabled {
            startMIDI()
        }
    }

    func stop() {
        loopback?.cancel()
        loopback = nil
        boundPort = 0
        apply = nil
        if midiPort != 0 {
            MIDIPortDispose(midiPort)
            midiPort = 0
        }
        if midiClient != 0 {
            MIDIClientDispose(midiClient)
            midiClient = 0
        }
        midiBox = nil
    }

    func waitUntilReady(timeoutNanoseconds: UInt64 = 2_000_000_000) async -> UInt16 {
        let steps = max(1, Int(timeoutNanoseconds / 40_000_000))
        for _ in 0..<steps {
            if boundPort != 0 { return boundPort }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return boundPort
    }

    private func startOSC(port: UInt16) {
        let box = LoopbackListener(
            queue: queue,
            udp: true,
            portFileName: "osc-port",
            onConnection: { [weak self] connection in
                self?.acceptOSC(connection)
            },
            onReady: { [weak self] bound in
                self?.boundPort = bound
            }
        )
        loopback = box
        box.start(preferredPort: port)
    }

    private func acceptOSC(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receiveMessage { [weak self] data, _, _, _ in
            defer { connection.cancel() }
            guard let self, let data,
                  let packet = OSCPacketCodec.parse(data),
                  let command = RemoteControlBridge.parseOSC(packet.address, arguments: packet.arguments)
            else { return }
            self.apply?(command)
        }
    }

    private func startMIDI() {
        let box = MIDIApplyBox { [weak self] status, data1, data2 in
            guard let command = RemoteControlBridge.parseMIDI(status: status, data1: data1, data2: data2) else {
                return
            }
            self?.apply?(command)
        }
        midiBox = box
        var client = MIDIClientRef()
        guard MIDIClientCreate("ProShow Remote" as CFString, nil, nil, &client) == noErr else {
            midiBox = nil
            return
        }
        midiClient = client
        var port = MIDIPortRef()
        let context = Unmanaged.passUnretained(box).toOpaque()
        guard MIDIInputPortCreate(client, "ProShow MIDI In" as CFString, midiReadProc, context, &port) == noErr else {
            MIDIClientDispose(client)
            midiClient = 0
            midiBox = nil
            return
        }
        midiPort = port
        let count = MIDIGetNumberOfSources()
        guard count > 0 else { return }
        for index in 0..<count {
            MIDIPortConnectSource(port, MIDIGetSource(index), nil)
        }
    }
}

private final class MIDIApplyBox: @unchecked Sendable {
    let handle: @Sendable (UInt8, UInt8, UInt8) -> Void

    init(_ handle: @escaping @Sendable (UInt8, UInt8, UInt8) -> Void) {
        self.handle = handle
    }
}

private let midiReadProc: MIDIReadProc = { packetList, refCon, _ in
    guard let refCon else { return }
    let box = Unmanaged<MIDIApplyBox>.fromOpaque(refCon).takeUnretainedValue()
    forEachMIDIMessage(in: packetList) { status, data1, data2 in
        box.handle(status, data1, data2)
    }
}

private func forEachMIDIMessage(
    in packetList: UnsafePointer<MIDIPacketList>,
    _ body: (UInt8, UInt8, UInt8) -> Void
) {
    var packetPtr = UnsafeMutableRawPointer(mutating: UnsafeRawPointer(packetList))
        .advanced(by: MemoryLayout<UInt32>.size)
        .assumingMemoryBound(to: MIDIPacket.self)
    for _ in 0..<packetList.pointee.numPackets {
        let length = Int(packetPtr.pointee.length)
        withUnsafeBytes(of: packetPtr.pointee.data) { raw in
            let buffer = raw.bindMemory(to: UInt8.self)
            var index = 0
            while index < length {
                let status = buffer[index]
                let size = midiMessageLength(status)
                if status & 0x80 != 0, index + size <= length {
                    let data1 = size > 1 ? buffer[index + 1] : 0
                    let data2 = size > 2 ? buffer[index + 2] : 0
                    body(status, data1, data2)
                    index += size
                } else {
                    index += 1
                }
            }
        }
        packetPtr = MIDIPacketNext(packetPtr)
    }
}

private func midiMessageLength(_ status: UInt8) -> Int {
    switch status & 0xF0 {
    case 0xC0, 0xD0: return 2
    default: return 3
    }
}
