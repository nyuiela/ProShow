# companion-module-proshow

Bitfocus Companion contract for the ProShow Control API (`127.0.0.1:55076`).

## Actions

| Action | Endpoint |
| --- | --- |
| `trigger_slide_index` | `POST /v1/slides/trigger` `{presentation_id, index}` |
| `clear_layer` | `GET /v1/clear/layer/{layer}` |
| `switch_scene` | `POST /v1/scenes/{scene_id}/trigger` |
| `trigger_macro` | `GET /v1/macro/{macro_id}/trigger` |
| `slide_next` | `POST /v1/slide/next` |
| `mute_audio` | `POST /v1/audio/mute` `{channel, muted}` |
| `switch_camera` | `POST /v1/camera/switch` `{source_id}` |
| `preflight` | `GET /v1/preflight` |

## Feedback

`GET /v1/status` and `GET /v1/telemetry` expose `is_streaming`, `is_recording`, and `active_slide_index`.
