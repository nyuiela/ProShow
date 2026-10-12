# ProShow Integrations

Localhost Control API: `http://127.0.0.1:55076/docs` · spec `http://127.0.0.1:55076/openapi.json`

Aliases: `POST /v1/slide/next`, `GET /v1/preflight`, `GET /v1/telemetry`, `POST /v1/audio/mute`, `POST /v1/camera/switch`. OSC UDP `127.0.0.1:8000` `/proshow/slide/next`. MIDI note 60/61 and CC7. WebSocket `ws://127.0.0.1:55076/v1/telemetry` when enabled.

- `com.proshow.streamdeck.sdPlugin` — Elgato Stream Deck plugin. Copy the folder into `~/Library/Application Support/com.elgato.StreamDeck/Plugins/`.
- `companion-module-proshow` — Bitfocus Companion module contract for the same REST surface.
