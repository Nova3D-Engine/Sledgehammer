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

struct MaterialPreviewVertex {
    packed_float3 position;
    packed_float3 normal;
    packed_float2 uv;
};

struct ModelPreviewVertex {
    packed_float3 position;
    packed_float3 normal;
    packed_float2 uv;
};

struct MaterialPreviewUniforms {
    float4x4 modelViewProjection;
    float4x4 modelMatrix;
    float4 keyLightDirection;
    float4 rimLightDirection;
    float4 baseColorTint;
};

struct MaterialPreviewRasterData {
    float4 position [[position]];
    float3 worldPosition;
    float3 normal;
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
    const uint shadeMode = uniforms.flags.y;
    const uint useTint = shadeMode == 1u;
    const uint bakedLightingEnabled = shadeMode == 2u;
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
    if (bakedLightingEnabled != 0) {
        return float4(baseColor * in.color, alpha);
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

fragment float4 sledgehammerModelPreviewFragment(RasterData in [[stage_in]],
                                                 constant Uniforms& uniforms [[buffer(0)]],
                                                 texture2d<float> colorTexture [[texture(0)]],
                                                 sampler textureSampler [[sampler(0)]]) {
    const uint lightingEnabled = uniforms.flags.z;
    const uint useTexture = uniforms.flags.w;
    float4 texSample = useTexture != 0 ? colorTexture.sample(textureSampler, in.uv) : float4(1.0);
    float3 baseColor = texSample.rgb;
    float alpha = texSample.a;
    if (lightingEnabled == 0) {
        return float4(baseColor, alpha);
    }

    float3 normal = normalize(in.normal);
    float3 lightDir = normalize(uniforms.lightDirectionIntensity.xyz);
    float diffuse = max(dot(normal, lightDir), 0.15);
    float3 viewDir = normalize(uniforms.cameraPosition.xyz - in.worldPosition);
    float rim = pow(1.0 - max(dot(normal, viewDir), 0.0), 2.4) * 0.14;
    float3 color = baseColor * (diffuse + 0.18) + float3(rim);
    return float4(saturate(color), alpha);
}

vertex MaterialPreviewRasterData sledgehammerMaterialPreviewVertex(
    uint vertexID [[vertex_id]],
    const device MaterialPreviewVertex* vertices [[buffer(0)]],
    constant MaterialPreviewUniforms& uniforms [[buffer(1)]]) {
    MaterialPreviewVertex inVertex = vertices[vertexID];
    MaterialPreviewRasterData out;
    float4 localPosition = float4(float3(inVertex.position), 1.0);
    float4 worldPosition = uniforms.modelMatrix * localPosition;
    out.position = uniforms.modelViewProjection * localPosition;
    out.worldPosition = worldPosition.xyz;
    out.normal = normalize((uniforms.modelMatrix * float4(float3(inVertex.normal), 0.0)).xyz);
    out.uv = float2(inVertex.uv);
    return out;
}

vertex RasterData sledgehammerModelPreviewVertex(
    uint vertexID [[vertex_id]],
    const device ModelPreviewVertex* vertices [[buffer(0)]],
    constant Uniforms& uniforms [[buffer(1)]]) {
    ModelPreviewVertex inVertex = vertices[vertexID];
    RasterData out;
    float3 position = float3(inVertex.position);
    float3 normal = float3(inVertex.normal);
    out.position = uniforms.viewProjection * float4(position, 1.0);
    out.worldPosition = position;
    out.normal = normalize(normal);
    out.color = float3(1.0, 1.0, 1.0);
    out.uv = float2(inVertex.uv);
    return out;
}

fragment float4 sledgehammerMaterialPreviewFragment(
    MaterialPreviewRasterData in [[stage_in]],
    constant MaterialPreviewUniforms& uniforms [[buffer(0)]],
    texture2d<float> colorTexture [[texture(0)]],
    sampler textureSampler [[sampler(0)]]) {
    float4 texel = colorTexture.sample(textureSampler, in.uv);
    float3 baseColor = texel.rgb * uniforms.baseColorTint.rgb;
    float3 normal = normalize(in.normal);
    float3 keyLightDir = normalize(uniforms.keyLightDirection.xyz);
    float3 rimLightDir = normalize(uniforms.rimLightDirection.xyz);
    float3 viewDir = normalize(float3(0.0, 0.0, 1.0) - in.worldPosition * 0.15);
    float3 halfVector = normalize(keyLightDir + viewDir);

    float diffuse = max(dot(normal, keyLightDir), 0.0);
    float fill = pow(max(dot(normal, rimLightDir), 0.0), 2.0) * 0.35;
    float rim = pow(1.0 - max(dot(normal, viewDir), 0.0), 2.4) * 0.18;
    float specular = pow(max(dot(normal, halfVector), 0.0), 42.0) * 0.22;
    float ambient = 0.20;

    float3 color = baseColor * (ambient + diffuse * 0.82 + fill) + float3(specular) + float3(rim);
    return float4(saturate(color), texel.a * uniforms.baseColorTint.a);
}
