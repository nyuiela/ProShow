const API = process.env.PROSHOW_API || "http://127.0.0.1:55076";

const actions = {
  trigger_slide_index: {
    method: "POST",
    path: "/v1/slides/trigger",
    fields: ["presentation_id", "index"],
  },
  clear_layer: {
    method: "GET",
    pathFrom: (options) => `/v1/clear/layer/${options.layer || "all"}`,
  },
  switch_scene: {
    method: "POST",
    pathFrom: (options) => `/v1/scenes/${options.scene_id}/trigger`,
  },
  trigger_macro: {
    method: "GET",
    pathFrom: (options) => `/v1/macro/${options.macro_id}/trigger`,
  },
  slide_next: {
    method: "POST",
    path: "/v1/slide/next",
  },
  mute_audio: {
    method: "POST",
    path: "/v1/audio/mute",
    fields: ["channel", "muted"],
  },
  switch_camera: {
    method: "POST",
    path: "/v1/camera/switch",
    fields: ["source_id"],
  },
  preflight: {
    method: "GET",
    path: "/v1/preflight",
  },
};

const feedbacks = ["is_streaming", "is_recording", "active_slide_index"];

async function request(method, path, body) {
  const options = { method, headers: { "Content-Type": "application/json" } };
  if (body) options.body = JSON.stringify(body);
  const response = await fetch(API + path, options);
  return response.json();
}

async function runAction(id, options = {}) {
  const action = actions[id];
  if (!action) throw new Error(`unknown action ${id}`);
  const path = action.pathFrom ? action.pathFrom(options) : action.path;
  const body = action.fields
    ? Object.fromEntries(action.fields.map((key) => [key, options[key]]).filter((pair) => pair[1] !== undefined))
    : undefined;
  return request(action.method, path, body);
}

async function readFeedback() {
  const status = await request("GET", "/v1/status");
  return {
    is_streaming: Boolean(status.is_streaming),
    is_recording: Boolean(status.is_recording),
    active_slide_index: status.active_slide_index ?? null,
  };
}

if (typeof module !== "undefined") {
  module.exports = { API, actions, feedbacks, runAction, readFeedback };
}
