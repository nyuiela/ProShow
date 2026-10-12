import Foundation

/// Published OpenAPI 3 document for the localhost Control API.
enum ControlAPIOpenAPI {
    static let version = "1.0.0"
    static let title = "ProShow Control API"

    static func document(port: UInt16 = ControlAPIServer.defaultPort) -> [String: Any] {
        [
            "openapi": "3.0.3",
            "info": [
                "title": title,
                "version": version,
                "description": "Localhost-only operator API for Stream Deck, Bitfocus Companion, and automation. Bound to 127.0.0.1.",
            ],
            "servers": [
                ["url": "http://127.0.0.1:\(port)", "description": "ProShow Control API"],
            ],
            "paths": paths,
            "components": [
                "schemas": [
                    "Ok": [
                        "type": "object",
                        "properties": [
                            "ok": ["type": "boolean"],
                        ],
                    ],
                    "Status": [
                        "type": "object",
                        "properties": [
                            "ok": ["type": "boolean"],
                            "is_streaming": ["type": "boolean"],
                            "is_recording": ["type": "boolean"],
                            "active_slide_index": ["type": "integer", "nullable": true],
                            "live_slide_id": ["type": "string", "nullable": true],
                            "show_id": ["type": "string"],
                            "ndi_available": ["type": "boolean"],
                        ],
                    ],
                    "TriggerSlide": [
                        "type": "object",
                        "required": ["index"],
                        "properties": [
                            "presentation_id": ["type": "string", "format": "uuid"],
                            "index": ["type": "integer", "minimum": 0],
                        ],
                    ],
                    "ClearLayer": [
                        "type": "object",
                        "required": ["layer"],
                        "properties": [
                            "layer": [
                                "type": "string",
                                "enum": ["slide", "media", "props", "messages", "video_input", "announcements", "mask", "audio", "all"],
                            ],
                        ],
                    ],
                ],
            ],
        ]
    }

    static func json(port: UInt16 = ControlAPIServer.defaultPort) -> String {
        ControlJSON.encode(document(port: port))
    }

    static func html(port: UInt16 = ControlAPIServer.defaultPort) -> String {
        let spec = json(port: port)
        let escaped = spec
            .replacingOccurrences(of: "</", with: "<\\/")
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8"/>
        <title>ProShow Control API</title>
        <style>
        :root { color-scheme: dark; }
        body { margin: 0; font: 15px/1.45 ui-sans-serif, system-ui; background: #111114; color: #ececf1; }
        main { max-width: 880px; margin: 0 auto; padding: 32px 24px 64px; }
        h1 { font-size: 28px; letter-spacing: -0.03em; margin: 0 0 8px; }
        p, li { color: #b4b4c0; }
        a { color: #6ea8ff; }
        code { font-family: ui-monospace, Menlo, monospace; font-size: 13px; }
        .card { background: #1a1a20; border: 1px solid #2a2a33; border-radius: 12px; padding: 16px 18px; margin: 12px 0; }
        pre { overflow: auto; background: #0c0c10; border-radius: 10px; padding: 16px; font-size: 12px; }
        </style>
        </head>
        <body>
        <main>
        <h1>ProShow Control API</h1>
        <p>Localhost OpenAPI 3 surface for Stream Deck and Bitfocus Companion. Bound to <code>127.0.0.1:\(port)</code>.</p>
        <div class="card">
        <strong>Spec</strong>
        <p><a href="/openapi.json">/openapi.json</a> · <a href="/v1/health">/v1/health</a> · <a href="/v1/status">/v1/status</a></p>
        </div>
        <div class="card">
        <strong>Companion actions</strong>
        <ul>
        <li><code>trigger_slide_index</code> — POST /v1/slides/trigger</li>
        <li><code>clear_layer</code> — GET /v1/clear/layer/{layer}</li>
        <li><code>switch_scene</code> — POST /v1/scenes/{id}/trigger</li>
        <li><code>trigger_macro</code> — GET /v1/macro/{id}/trigger</li>
        </ul>
        <strong>Feedback</strong>
        <ul>
        <li><code>is_streaming</code> · <code>is_recording</code> · <code>active_slide_index</code> via GET /v1/status</li>
        <li><code>preflight</code> — GET /v1/preflight · <code>slide_next</code> — POST /v1/slide/next</li>
        </ul>
        </div>
        <pre id="spec"></pre>
        </main>
        <script>
        const spec = \(escaped);
        document.getElementById('spec').textContent = JSON.stringify(spec, null, 2);
        </script>
        </body>
        </html>
        """
    }

    private static var paths: [String: Any] {
        [
            "/docs": get("HTML documentation for this API."),
            "/openapi.json": get("OpenAPI 3 document."),
            "/v1/health": get("Liveness probe."),
            "/v1/status": get("Streaming, ISO, and active slide feedback."),
            "/v1/presentation/active/{index}/trigger": get("Go live at slide index."),
            "/v1/presentation/active/next/trigger": get("Advance to the next slide."),
            "/v1/presentation/active/prev/trigger": get("Go to the previous slide."),
            "/v1/slides/trigger": post("trigger_slide_index — body {presentation_id, index}", "TriggerSlide"),
            "/v1/clear/layer/{layer}": get("clear_layer — slide, media, props, all, …"),
            "/v1/scenes": get("List scenes."),
            "/v1/scenes/{scene_id}/trigger": [
                "get": op("switch_scene"),
                "post": op("switch_scene"),
            ],
            "/v1/macro/{macro_id}/trigger": get("trigger_macro"),
            "/v1/capture/start": post("Start the primary RTMP encode (legacy path)."),
            "/v1/capture/stop": post("Stop the primary RTMP encode."),
            "/v1/stream/start": post("Start streaming."),
            "/v1/stream/stop": post("Stop streaming."),
            "/v1/record/start": post("Start ISO / program recording."),
            "/v1/record/stop": post("Stop ISO / program recording."),
            "/v1/library/{library_id}/{presentation_id}/trigger": get("Load a library presentation and go live."),
            "/v1/soundboard/{pad_id}/play": post("Fire a soundboard pad."),
            "/v1/chat/overlay": post("Push a chat overlay card."),
            "/v1/chat/ingest/{platform}": post("Zoom / Meet / YouTube / Twitch webhook ingest."),
            "/v1/backstage/{room_slug}/signal": [
                "post": op("WebRTC signaling relay (join, offer, answer, ice, mediaFrame)."),
                "get": op("Upgrade to WebSocket for the same signaling envelope."),
            ],
            "/v1/audio/meters": get("Audio matrix meters."),
            "/v1/slide/next": post("Advance to the next slide."),
            "/v1/slide/prev": post("Go to the previous slide."),
            "/v1/preflight": get("Run the pre-flight health scan."),
            "/v1/telemetry": get("Status snapshot. Upgrade this GET to WebSocket for 16 ms telemetry."),
            "/v1/ws": get("WebSocket telemetry alias. Localhost only."),
            "/v1/audio/mute": post("Mute or unmute a mixer channel or program."),
            "/v1/camera/switch": post("Take a camera shot live by source_id."),
        ]
    }

    private static func op(_ summary: String) -> [String: Any] {
        [
            "summary": summary,
            "responses": ["200": ["description": "OK"]],
        ]
    }

    private static func get(_ summary: String) -> [String: Any] {
        ["get": op(summary)]
    }

    private static func post(_ summary: String, _ schema: String? = nil) -> [String: Any] {
        var item = op(summary)
        if let schema {
            item["requestBody"] = [
                "required": true,
                "content": [
                    "application/json": [
                        "schema": ["$ref": "#/components/schemas/\(schema)"],
                    ],
                ],
            ]
        }
        return ["post": item]
    }
}

enum ControlJSON {
    static func encode(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return #"{"ok":false}"#
        }
        return text
    }
}
