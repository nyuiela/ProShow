#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Network
import Testing

@Suite
struct RemoteControlTests {
    @Test
    func osc_slideNext() {
        #expect(RemoteControlBridge.parseOSC("/proshow/slide/next") == .nextSlide)
        #expect(RemoteControlBridge.parseOSC("/proshow/macro/trigger", arguments: ["BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB1"]) != nil)
        #expect(RemoteControlBridge.parseOSC("/other/slide/next") == nil)
    }

    @Test
    func midi_noteMapsToNext() {
        #expect(RemoteControlBridge.parseMIDI(status: 0x90, data1: 60, data2: 127) == .nextSlide)
        #expect(RemoteControlBridge.parseMIDI(status: 0xB0, data1: 7, data2: 10) == .muteAudio(channel: nil, muted: true))
    }

    @Test
    func restAliases_parse() {
        #expect(RemoteControlBridge.parseREST(method: "POST", path: "/v1/slide/next", body: [:]) == .nextSlide)
        #expect(RemoteControlBridge.parseREST(method: "GET", path: "/v1/preflight", body: [:]) == .preflight)
        #expect(RemoteControlBridge.parseREST(method: "POST", path: "/v1/camera/switch", body: ["source_id": "cam-1"]) == .switchCamera(sourceID: "cam-1"))
    }

    @Test @MainActor
    func postSlideNext_advances() {
        let controller = TestSupport.sampleController()
        _ = controller.handleControl(method: "GET", path: "/v1/presentation/active/0/trigger")
        let next = controller.handleControl(method: "POST", path: "/v1/slide/next")
        #expect(next.0 == 200)
        #expect(controller.liveIndex == 1)
        let preflight = controller.handleControl(method: "GET", path: "/v1/preflight")
        #expect(preflight.0 == 200)
        #expect(preflight.1.contains("fail_count"))
        let telemetry = controller.handleControl(method: "GET", path: "/v1/telemetry")
        #expect(telemetry.0 == 200)
        #expect(telemetry.1.contains("is_streaming"))
    }

    @Test
    func oscPacket_roundtripAndParse() {
        let packet = OSCPacketCodec.encode(address: "/proshow/slide/next")
        let parsed = OSCPacketCodec.parse(packet)
        #expect(parsed?.address == "/proshow/slide/next")
        #expect(RemoteControlBridge.parseOSC(parsed?.address ?? "") == .nextSlide)
        let withArg = OSCPacketCodec.encode(
            address: "/proshow/macro/trigger",
            arguments: ["BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB1"]
        )
        let macro = OSCPacketCodec.parse(withArg)
        #expect(RemoteControlBridge.parseOSC(macro?.address ?? "", arguments: macro?.arguments ?? []) != nil)
    }

    @Test
    func websocketAcceptKey_matchesRFC6455Example() {
        #expect(ControlWebSocket.acceptKey("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    @Test
    func oscListener_appliesSlideNext() async throws {
        let controller = await MainActor.run { TestSupport.sampleController() }
        await MainActor.run {
            _ = controller.handleControl(method: "GET", path: "/v1/presentation/active/0/trigger")
        }
        let runtime = RemoteControlRuntime()
        runtime.start(oscPort: 0, oscEnabled: true, midiEnabled: false) { command in
            Task { @MainActor in
                _ = RemoteControlBridge.apply(command, to: controller)
            }
        }
        let port = await runtime.waitUntilReady()
        #expect(port != 0)
        try await sendUDP(OSCPacketCodec.encode(address: "/proshow/slide/next"), port: port)
        try await Task.sleep(nanoseconds: 250_000_000)
        let index = await MainActor.run { controller.liveIndex }
        #expect(index == 1)
        runtime.stop()
    }

    @Test @MainActor
    func muteAndClearLayerIndex() {
        let controller = TestSupport.sampleController()
        let mute = controller.handleControl(
            method: "POST",
            path: "/v1/audio/mute",
            body: #"{"muted":true}"#.data(using: .utf8)
        )
        #expect(mute.0 == 200)
        #expect(controller.audioMatrix.programMuted || controller.audioIO.programMuted)
        let clear = controller.handleControl(method: "GET", path: "/v1/clear/layer/4")
        #expect(clear.0 == 200)
        #expect(controller.compositor.stack.isCleared(.slide))
    }
}

private func sendUDP(_ payload: Data, port: UInt16) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        connection.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                continuation.resume(throwing: error)
            }
        }
        connection.start(queue: .global())
        connection.send(content: payload, completion: .contentProcessed { error in
            connection.cancel()
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        })
    }
}
