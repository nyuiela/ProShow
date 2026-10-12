#include <metal_stdlib>
using namespace metal;

struct ChromaParams {
    float4 keyColor;
    float smoothness;
    float spillSuppression;
    float edgeCutoff;
};

struct GradeParams {
    float exposure;
    float contrast;
    float saturation;
    float sharpness;
    float backgroundBlur;
};

kernel void chroma_key(
    texture2d<float, access::read> inTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    constant ChromaParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= inTexture.get_width() || gid.y >= inTexture.get_height()) {
        return;
    }
    float4 color = inTexture.read(gid);
    float dist = distance(color.rgb, params.keyColor.rgb);
    float alpha = smoothstep(params.edgeCutoff, params.edgeCutoff + max(params.smoothness, 0.0001), dist);
    float spill = max(color.g - max(color.r, color.b), 0.0) * params.spillSuppression;
    color.g -= spill;
    color.a *= alpha;
    outTexture.write(color, gid);
}

kernel void color_grade(
    texture2d<float, access::read> inTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    constant GradeParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= inTexture.get_width() || gid.y >= inTexture.get_height()) {
        return;
    }
    float4 color = inTexture.read(gid);
    float exposure = pow(2.0, params.exposure);
    color.rgb = ((color.rgb - 0.5) * params.contrast + 0.5) * exposure;
    float luma = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
    color.rgb = mix(float3(luma), color.rgb, params.saturation);
    color.rgb += params.sharpness * 0.02;
    if (params.backgroundBlur > 0.0) {
        color.rgb = mix(color.rgb, float3(luma), params.backgroundBlur * 0.15);
    }
    outTexture.write(saturate(color), gid);
}
