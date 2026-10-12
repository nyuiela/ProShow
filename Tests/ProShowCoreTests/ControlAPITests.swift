#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct ControlAPITests {
    @Test @MainActor
    func health_trigger_clear_capture_macro() throws {
        let controller = TestSupport.sampleController()
        let health = controller.handleControl(method: "GET", path: "/v1/health")
        #expect(health.0 == 200)

        let trigger = controller.handleControl(method: "GET", path: "/v1/presentation/active/0/trigger")
        #expect(trigger.0 == 200)
        #expect(controller.liveIndex == 0)

        controller.triggerMedia(DeskSampleData.mediaBin[0])
        let clear = controller.handleControl(method: "GET", path: "/v1/clear/layer/media")
        #expect(clear.0 == 200)
        #expect(controller.compositor.stack.isCleared(.media))

        let missing = controller.handleControl(method: "GET", path: "/v1/clear/layer/not_a_layer")
        #expect(missing.0 == 404)

        let start = controller.handleControl(method: "POST", path: "/v1/capture/start")
        #expect(start.0 == 200)
        let stop = controller.handleControl(method: "POST", path: "/v1/capture/stop")
        #expect(stop.0 == 200)

        let macroID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB1"
        let macro = controller.handleControl(method: "GET", path: "/v1/macro/\(macroID)/trigger")
        #expect(macro.0 == 200)

        let wrong = controller.handleControl(method: "GET", path: "/v1/capture/start")
        #expect(wrong.0 == 405)

        let docs = controller.handleControl(method: "GET", path: "/docs")
        #expect(docs.0 == 200)
        #expect(docs.1.contains("ProShow Control API"))

        let spec = controller.handleControl(method: "GET", path: "/openapi.json")
        #expect(spec.0 == 200)
        let object = try #require(JSONSerialization.jsonObject(with: Data(spec.1.utf8)) as? [String: Any])
        let paths = try #require(object["paths"] as? [String: Any])
        #expect(paths["/v1/slides/trigger"] != nil)
        #expect(paths["/v1/status"] != nil)
        #expect(paths["/v1/stream/start"] != nil)
        #expect(paths["/v1/record/start"] != nil)

        _ = controller.handleControl(method: "GET", path: "/v1/presentation/active/0/trigger")
        let status = controller.handleControl(method: "GET", path: "/v1/status")
        #expect(status.0 == 200)
        #expect(status.1.contains("is_streaming"))
        #expect(status.1.contains("is_recording"))
        #expect(status.1.contains("active_slide_index"))

        let next = controller.handleControl(method: "GET", path: "/v1/presentation/active/next/trigger")
        #expect(next.0 == 200)
        let prev = controller.handleControl(method: "GET", path: "/v1/presentation/active/prev/trigger")
        #expect(prev.0 == 200)

        let slide = controller.handleControl(
            method: "POST",
            path: "/v1/slides/trigger",
            body: #"{"presentation_id":"\#(controller.show.id.uuidString)","index":0}"#.data(using: .utf8)
        )
        #expect(slide.0 == 200)

        let record = controller.handleControl(method: "POST", path: "/v1/record/start")
        #expect(record.0 == 200)
        #expect(controller.isoRecorder.isRecording)
        _ = controller.handleControl(method: "POST", path: "/v1/record/stop")
        #expect(!controller.isoRecorder.isRecording)
    }

    @Test
    func parse_respectsContentLength() {
        let raw = "POST /v1/capture/start HTTP/1.1\r\nContent-Length: 2\r\n\r\nOKEXTRA"
        let parsed = ControlHTTP.parse(raw)
        #expect(parsed.method == "POST")
        #expect(parsed.path == "/v1/capture/start")
        #expect(parsed.body?.count == 2)
    }

    @Test
    func httpServer_sixRoutesOnLoopback() async throws {
        let controller = await MainActor.run { TestSupport.sampleController() }
        let server = ControlAPIServer(port: 0)
        server.start { method, path, _ in
            await MainActor.run {
                controller.handleControl(method: method, path: path)
            }
        }
        let port = await server.waitUntilReady()
        #expect(port != 0)

        func request(_ method: String, _ path: String) async throws -> (Int, String) {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            req.httpMethod = method
            req.timeoutInterval = 2
            let (data, response) = try await URLSession.shared.data(for: req)
            let http = try #require(response as? HTTPURLResponse)
            return (http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        let health = try await request("GET", "/v1/health")
        #expect(health.0 == 200)
        let trigger = try await request("GET", "/v1/presentation/active/0/trigger")
        #expect(trigger.0 == 200)
        let live = await MainActor.run { controller.liveIndex }
        #expect(live == 0)
        _ = await MainActor.run { controller.triggerMedia(DeskSampleData.mediaBin[0]) }
        let clear = try await request("GET", "/v1/clear/layer/media")
        #expect(clear.0 == 200)
        let missing = try await request("GET", "/v1/clear/layer/not_a_layer")
        #expect(missing.0 == 404)
        let start = try await request("POST", "/v1/capture/start")
        #expect(start.0 == 200)
        let stop = try await request("POST", "/v1/capture/stop")
        #expect(stop.0 == 200)
        let macro = try await request("GET", "/v1/macro/BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB1/trigger")
        #expect(macro.0 == 200)
        let wrong = try await request("GET", "/v1/capture/start")
        #expect(wrong.0 == 405)
        server.stop()
    }

    @Test
    func websocket_sendsTelemetrySnapshot() async throws {
        let controller = await MainActor.run { TestSupport.sampleController() }
        let server = ControlAPIServer(port: 0)
        server.start(
            webSocketEnabled: true,
            telemetry: {
                await MainActor.run {
                    ControlJSON.encode(RemoteControlBridge.telemetryJSON(controller))
                }
            }
        ) { method, path, _ in
            await MainActor.run {
                controller.handleControl(method: method, path: path)
            }
        }
        let port = await server.waitUntilReady()
        #expect(port != 0)
        let url = URL(string: "ws://127.0.0.1:\(port)/v1/telemetry")!
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        let message = try await task.receive()
        if case .string(let text) = message {
            #expect(text.contains("is_streaming"))
            #expect(text.contains("ok"))
        } else {
            Issue.record("expected a text telemetry frame")
        }
        task.cancel(with: .goingAway, reason: nil)
        server.stop()
    }
}
