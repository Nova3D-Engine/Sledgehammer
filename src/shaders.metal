#include <metal_stdlib>

using namespace metal;

struct ViewerVertex {
    packed_float3 position;
    packed_float3 normal;
    packed_float3 color;
    float u;
    float v;
};

struct Uniforms {
    float4x4 viewProjection;
    float4 cameraPosition;
    float4 lightDirectionIntensity;
    float4 lightPositionRange;
    float4 lightColor;
    float4 colorTint;
    uint4 flags;
};

struct RasterData {
    float4 position [[position]];
    float3 worldPosition;
    float3 normal;
    float3 color;
    float2 uv;
};

vertex RasterData viewerVertex(uint vertexID [[vertex_id]],
                               const device ViewerVertex* vertices [[buffer(0)]],
                               constant Uniforms& uniforms [[buffer(1)]]) {
    ViewerVertex inVertex = vertices[vertexID];
    RasterData out;
    float3 position = float3(inVertex.position);
    float3 normal = float3(inVertex.normal);
    float3 color = float3(inVertex.color);
    out.position = uniforms.viewProjection * float4(position, 1.0);
    out.worldPosition = position;
    out.normal = normalize(normal);
    out.color = color;
    out.uv = float2(inVertex.u, inVertex.v);
    return out;
}

fragment float4 viewerFragment(RasterData in [[stage_in]],
                               constant Uniforms& uniforms [[buffer(0)]],
                               texture2d<float> colorTexture [[texture(0)]],
                               sampler textureSampler [[sampler(0)]]) {
    const uint lightEnabled = uniforms.flags.x;
    const uint useTint = uniforms.flags.y;
    const uint lightingEnabled = uniforms.flags.z;
    const uint useTexture = uniforms.flags.w;
    float3 baseColor;
    float alpha;
    if (useTint != 0) {
        baseColor = uniforms.colorTint.rgb;
        alpha = uniforms.colorTint.a;
    } else if (useTexture != 0) {
        /* UV is in texel space — normalise by texture dimensions so the
           repeat sampler tiles correctly regardless of texture resolution. */
        float2 texDims = float2(colorTexture.get_width(), colorTexture.get_height());
        float4 texSample = colorTexture.sample(textureSampler, in.uv / texDims);
        baseColor = texSample.rgb;
        alpha = texSample.a;
    } else {
        /* Checkerboard UV preview.  UV is in texel space; treat 64 texels as
           one checker square.  Use fract() — unlike fmod it is always [0,1)
           even for negative coords, so no diagonal seam at UV origin. */
        float2 grid  = in.uv / 64.0;
        float2 f     = fract(grid);
        float pattern = float((f.x >= 0.5) != (f.y >= 0.5));
        float3 col = in.color;
        baseColor = mix(col, col * 0.72f, pattern * 0.35f);
        alpha = 1.0;
    }
    if (lightingEnabled == 0) {
        return float4(baseColor, alpha);
    }
    float diffuse = 0.15;
    float3 litColor = float3(1.0, 1.0, 1.0);
    if (lightEnabled != 0 && uniforms.lightPositionRange.w > 0.0) {
        float3 toLight = uniforms.lightPositionRange.xyz - in.worldPosition;
        float distanceToLight = max(length(toLight), 0.001);
        float3 lightDir = toLight / distanceToLight;
        float attenuation = saturate(1.0 - (distanceToLight / uniforms.lightPositionRange.w));
        diffuse = max(dot(normalize(in.normal), lightDir), 0.08) * attenuation * max(uniforms.lightDirectionIntensity.w, 0.1);
        litColor = uniforms.lightColor.rgb;
    } else {
        float3 lightDir = normalize(uniforms.lightDirectionIntensity.xyz);
        diffuse = max(dot(normalize(in.normal), lightDir), 0.15);
    }
    return float4(baseColor * litColor * diffuse, alpha);
}