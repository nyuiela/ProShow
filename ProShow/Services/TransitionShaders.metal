#include <metal_stdlib>
using namespace metal;

struct TransitionUniforms {
    float progress;
    float duration;
    float2 resolution;
    float intensity;
};

struct TransitionVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex TransitionVertexOut transition_vertex(uint vid [[vertex_id]]) {
    float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    float2 uvs[3] = { float2(0.0, 1.0), float2(2.0, 1.0), float2(0.0, -1.0) };
    TransitionVertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

static inline float4 sampleExact(
    texture2d<float> textureFrom,
    texture2d<float> textureTo,
    float2 uv,
    float progress,
    sampler textureSampler
) {
    if (progress <= 0.0) {
        return textureFrom.sample(textureSampler, uv);
    }
    if (progress >= 1.0) {
        return textureTo.sample(textureSampler, uv);
    }
    return float4(0.0);
}

fragment float4 whipPanTransition(
    TransitionVertexOut in [[stage_in]],
    texture2d<float> textureFrom [[texture(0)]],
    texture2d<float> textureTo [[texture(1)]],
    constant TransitionUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float4 exact = sampleExact(textureFrom, textureTo, in.uv, uniforms.progress, textureSampler);
    if (exact.a > 0.0 || uniforms.progress <= 0.0 || uniforms.progress >= 1.0) {
        if (uniforms.progress <= 0.0) { return textureFrom.sample(textureSampler, in.uv); }
        if (uniforms.progress >= 1.0) { return textureTo.sample(textureSampler, in.uv); }
    }

    float p = uniforms.progress;
    float blur = sin(p * 3.14159) * uniforms.intensity;
    float2 offset = float2(p, 0.0);
    float4 colA = textureFrom.sample(textureSampler, in.uv - offset * blur);
    float4 colB = textureTo.sample(textureSampler, in.uv + (float2(1.0, 0.0) - offset) * blur);
    return mix(colA, colB, step(1.0 - p, in.uv.x));
}

fragment float4 liquidRippleTransition(
    TransitionVertexOut in [[stage_in]],
    texture2d<float> textureFrom [[texture(0)]],
    texture2d<float> textureTo [[texture(1)]],
    constant TransitionUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    if (uniforms.progress <= 0.0) { return textureFrom.sample(textureSampler, in.uv); }
    if (uniforms.progress >= 1.0) { return textureTo.sample(textureSampler, in.uv); }

    float p = uniforms.progress;
    float2 center = float2(0.5, 0.5);
    float dist = distance(in.uv, center);
    float wave = sin((dist * 18.0 - p * 12.0)) * (1.0 - p) * 0.035 * uniforms.intensity;
    float2 displaced = in.uv + normalize(in.uv - center + 0.0001) * wave;
    float4 colA = textureFrom.sample(textureSampler, displaced);
    float4 colB = textureTo.sample(textureSampler, displaced);
    return mix(colA, colB, smoothstep(0.15, 0.85, p));
}

fragment float4 glitchTransition(
    TransitionVertexOut in [[stage_in]],
    texture2d<float> textureFrom [[texture(0)]],
    texture2d<float> textureTo [[texture(1)]],
    constant TransitionUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    if (uniforms.progress <= 0.0) { return textureFrom.sample(textureSampler, in.uv); }
    if (uniforms.progress >= 1.0) { return textureTo.sample(textureSampler, in.uv); }

    float p = uniforms.progress;
    float slice = step(0.92, fract(in.uv.y * 24.0 + p * 7.0));
    float shift = (slice * 0.04 + 0.02) * uniforms.intensity * sin(p * 18.0);
    float4 aR = textureFrom.sample(textureSampler, in.uv + float2(shift, 0.0));
    float4 aB = textureFrom.sample(textureSampler, in.uv - float2(shift, 0.0));
    float4 colA = float4(aR.r, textureFrom.sample(textureSampler, in.uv).g, aB.b, 1.0);
    float4 colB = textureTo.sample(textureSampler, in.uv);
    return mix(colA, colB, smoothstep(0.2, 0.8, p));
}

fragment float4 crossZoomTransition(
    TransitionVertexOut in [[stage_in]],
    texture2d<float> textureFrom [[texture(0)]],
    texture2d<float> textureTo [[texture(1)]],
    constant TransitionUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    if (uniforms.progress <= 0.0) { return textureFrom.sample(textureSampler, in.uv); }
    if (uniforms.progress >= 1.0) { return textureTo.sample(textureSampler, in.uv); }

    float p = uniforms.progress;
    float bounce = 1.0 + sin(p * 3.14159) * 0.18 * uniforms.intensity;
    float2 zoomA = (in.uv - 0.5) / bounce + 0.5;
    float2 zoomB = (in.uv - 0.5) * (2.0 - bounce) + 0.5;
    float4 colA = textureFrom.sample(textureSampler, zoomA);
    float4 colB = textureTo.sample(textureSampler, zoomB);
    return mix(colA, colB, smoothstep(0.25, 0.75, p));
}

fragment float4 lightLeakTransition(
    TransitionVertexOut in [[stage_in]],
    texture2d<float> textureFrom [[texture(0)]],
    texture2d<float> textureTo [[texture(1)]],
    constant TransitionUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    if (uniforms.progress <= 0.0) { return textureFrom.sample(textureSampler, in.uv); }
    if (uniforms.progress >= 1.0) { return textureTo.sample(textureSampler, in.uv); }

    float p = uniforms.progress;
    float burn = sin(p * 3.14159) * uniforms.intensity;
    float4 colA = textureFrom.sample(textureSampler, in.uv);
    float4 colB = textureTo.sample(textureSampler, in.uv);
    float4 flare = float4(1.0, 0.82, 0.55, 1.0) * burn * (1.0 - distance(in.uv, float2(0.7, 0.25)));
    return mix(colA, colB, smoothstep(0.2, 0.8, p)) + flare * 0.35;
}
