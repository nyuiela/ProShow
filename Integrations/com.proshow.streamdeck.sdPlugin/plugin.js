const API = "http://127.0.0.1:55076";

const routes = {
  "com.proshow.streamdeck.clear.slide": { method: "GET", path: "/v1/clear/layer/slide" },
  "com.proshow.streamdeck.clear.media": { method: "GET", path: "/v1/clear/layer/media" },
  "com.proshow.streamdeck.clear.props": { method: "GET", path: "/v1/clear/layer/props" },
  "com.proshow.streamdeck.clear.all": { method: "GET", path: "/v1/clear/layer/all" },
  "com.proshow.streamdeck.slide.prev": { method: "GET", path: "/v1/presentation/active/prev/trigger" },
  "com.proshow.streamdeck.slide.next": { method: "GET", path: "/v1/presentation/active/next/trigger" },
  "com.proshow.streamdeck.audio.mute": { method: "POST", path: "/v1/audio/mute", body: { muted: true } },
  "com.proshow.streamdeck.camera.switch": { method: "POST", path: "/v1/camera/switch" },
};

async function call(method, path, body) {
  const options = { method, headers: { "Content-Type": "application/json" } };
  if (body) options.body = JSON.stringify(body);
  const response = await fetch(API + path, options);
  return response.json().catch(() => ({ ok: false }));
}

async function handleKey(action, settings) {
  if (routes[action]) {
    const route = routes[action];
    const body = action === "com.proshow.streamdeck.camera.switch"
      ? { source_id: settings.source_id }
      : route.body;
    return call(route.method, route.path, body);
  }
  if (action === "com.proshow.streamdeck.scene.1" && settings.scene_id) {
    return call("POST", `/v1/scenes/${settings.scene_id}/trigger`);
  }
  if (action === "com.proshow.streamdeck.macro.1" && settings.macro_id) {
    return call("GET", `/v1/macro/${settings.macro_id}/trigger`);
  }
  if (action === "com.proshow.streamdeck.stream.toggle") {
    const status = await call("GET", "/v1/status");
    return call("POST", status.is_streaming ? "/v1/stream/stop" : "/v1/stream/start");
  }
  if (action === "com.proshow.streamdeck.record.toggle") {
    const status = await call("GET", "/v1/status");
    return call("POST", status.is_recording ? "/v1/record/stop" : "/v1/record/start");
  }
  return { ok: false, error: "unbound_action" };
}

if (typeof module !== "undefined") {
  module.exports = { API, routes, handleKey };
}
