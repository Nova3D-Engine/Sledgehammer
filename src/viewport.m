#import "viewport.h"

#import <QuartzCore/QuartzCore.h>
#import <Metal/MTLAccelerationStructure.h>
#import <simd/simd.h>
#import <stdint.h>

#include <stdio.h>

#include "nova_scene_data.h"
#include "nova_tool_metal.h"

#include <imgui.h>
#include <ImGuizmo.h>
#include <backends/imgui_impl_metal.h>
#include <backends/imgui_impl_osx.h>

#include "math3d.h"

typedef NovaToolMetalEditorViewportUniforms Uniforms;

typedef NS_OPTIONS(NSUInteger, CameraMovement) {
    CameraMovementForward = 1 << 0,
    CameraMovementBackward = 1 << 1,
    CameraMovementLeft = 1 << 2,
    CameraMovementRight = 1 << 3,
    CameraMovementUp = 1 << 4,
    CameraMovementDown = 1 << 5,
};

typedef NS_ENUM(NSUInteger, ViewportDragMode) {
    ViewportDragModeNone = 0,
    ViewportDragModePan,
    ViewportDragModeCreateBlock,
    ViewportDragModeMoveSelection,
    ViewportDragModeResizeSelection,
    ViewportDragModeMoveVertex,
    ViewportDragModeMoveEdge,
    ViewportDragModeDrawClipLine,
};

typedef NS_ENUM(NSUInteger, ViewportHandle) {
    ViewportHandleNone = 0,
    ViewportHandleBody,
    ViewportHandleMinUMinV,
    ViewportHandleMaxUMinV,
    ViewportHandleMaxUMaxV,
    ViewportHandleMinUMaxV,
    ViewportHandleMinUMidV,
    ViewportHandleMaxUMidV,
    ViewportHandleMidUMinV,
    ViewportHandleMidUMaxV,
};

static const float kViewportPerspectiveFovRadians = 0.87266463f; // 50 degrees; matches heavy renderer camera FOV.
static const CFTimeInterval kTextureMissLogThrottleSeconds = 10.0;
static const uint32_t kPreviewBakeGiSamples = 24u;
static const uint32_t kPreviewBakeRtSamplesPerTexelDefault = 64u;
static const uint32_t kPreviewBakeRtSamplesPerTexelMin = 4u;
static const uint32_t kPreviewBakeRtSamplesPerTexelMax = 256u;
static const uint32_t kPreviewBakeTargetSamplesPerTexelDefault = 8192u;
static const uint32_t kPreviewBakeTargetSamplesPerTexelMin = 64u;
static const uint32_t kPreviewBakeTargetSamplesPerTexelMax = 16384u;
static const uint32_t kPreviewBakeBounceCountDefault = 2u;
static const uint32_t kPreviewBakeBounceCountMin = 2u;
static const uint32_t kPreviewBakeBounceCountMax = 3u;
static const int kPreviewBakeLightmapWidth = 512;
static const int kPreviewBakeLightmapHeight = 512;
static const int kPreviewBakeMinResolution = 4;
static const int kPreviewBakeMaxResolution = 512;
static const int kPreviewBakeDensityDefault = 4;
static const int kPreviewBakeDensityMin = 1;
static const int kPreviewBakeDensityMax = 16;
static const int kChartBorderPadIterations = 8;
static const int kPreviewBakeAtlasChartPadding = 2;
static const float kPreviewBakeTexelSurfaceBias = 0.5f;
static const float kPreviewBakeDebugExposureDefault = 12.0f;
static const float kPreviewBakeDebugExposureMin = 0.125f;
static const float kPreviewBakeDebugExposureMax = 64.0f;
static const int kPreviewBakeDisplayModeCombined = 0;
static const int kPreviewBakeDisplayModeBakedOnly = 1;
static const int kPreviewBakeDisplayModeDynamicOnly = 2;

typedef struct HwrtBakeTexel {
    simd_float4 worldPosValid;
    simd_float4 normal;
    simd_float4 albedo;
} HwrtBakeTexel;

typedef struct HwrtBakeUniforms {
    simd_float4 lightPosRange;
    simd_float4 lightColorIntensity;
    uint32_t sampleCount;
    uint32_t bounceCount;
    uint32_t texelCount;
    uint32_t frameSeed;
    uint32_t lightCount;
    uint32_t importedMaterialCount;
    uint32_t importedTextureCount;
    uint32_t sceneTriangleCount;
} HwrtBakeUniforms;

typedef struct HwrtBakeLight {
    simd_float4 posType;
    simd_float4 dirRange;
    simd_float4 colorIntensity;
    simd_float4 params;
} HwrtBakeLight;

typedef struct HwrtBakeTexelAccum {
    simd_float4 worldPosWeight;
    simd_float4 normalSum;
    simd_float4 albedoSum;
} HwrtBakeTexelAccum;

typedef struct HwrtPathTraceVertex {
    simd_float4 position;
    simd_float4 normal;
    simd_float4 tangent;
    simd_float4 uv;
} HwrtPathTraceVertex;

@class VmfViewport;

@interface VmfViewport (Internal)

- (BOOL)handleViewportKeyDown:(NSEvent*)event;
- (BOOL)handleViewportKeyUp:(NSEvent*)event;
- (void)handleViewportMouseDownAtPoint:(NSPoint)point;
- (void)handleViewportMouseUpAtPoint:(NSPoint)point;
- (void)handleViewportPrimaryDragWithDelta:(NSPoint)delta alternate:(BOOL)alternate;
- (BOOL)handleViewportSecondaryMouseDown;
- (void)handleViewportSecondaryDragWithDelta:(NSPoint)delta;
- (void)handleViewportSecondaryMouseUp;
- (void)handleViewportScrollDelta:(CGFloat)deltaY;
- (void)handleViewportDroppedPath:(NSString*)path;
- (void)handleViewportMouseHoverAtPoint:(NSPoint)point;
- (void)handleViewportSecondaryClickAtPoint:(NSPoint)point modifierFlags:(NSEventModifierFlags)flags;
- (void)drawEditorOverlay;
- (Vec3)rayDirectionForViewPoint:(NSPoint)point;
- (nullable id<MTLTexture>)cachedTextureForMaterial:(NSString*)material;
- (nullable NSDictionary<NSString*, id>*)cachedTextureDataForMaterial:(NSString*)material;
- (nullable id<MTLTexture>)previewBakedDebugTextureForKey:(NSString*)key;
- (BOOL)shouldLogTextureMissAtPath:(NSString*)fullPath;
- (void)applyBakedVertexLighting:(const Vec3*)bakedLighting count:(size_t)count;
- (nullable id<MTLComputePipelineState>)hwrtBakePipelineState;
- (BOOL)encodeGizmoOverlayOnCommandBuffer:(id<MTLCommandBuffer>)commandBuffer drawable:(id<CAMetalDrawable>)drawable errorMessage:(char*)errorMessage capacity:(size_t)errorMessageCapacity;
- (BOOL)gizmoConsumesPrimaryMouse;
- (void)syncHeavyRendererSceneFromMesh:(const ViewerMesh*)mesh;
- (BOOL)initializeHeavyRenderer;

@end

@interface ViewportMetalView : MTKView

@property(nonatomic, weak) VmfViewport* owner;

@end


@interface ViewportOverlayView : NSView

@property(nonatomic, weak) VmfViewport* owner;

@end

static matrix_float4x4 matrix_from_mat4(Mat4 matrix) {
    matrix_float4x4 result;
    for (int column = 0; column < 4; ++column) {
        for (int row = 0; row < 4; ++row) {
            result.columns[column][row] = matrix.raw[column][row];
        }
    }
    return result;
}

static void copy_mat4_to_uniform(float destination[16], Mat4 matrix) {
    for (int column = 0; column < 4; ++column) {
        for (int row = 0; row < 4; ++row) {
            destination[column * 4 + row] = matrix.raw[column][row];
        }
    }
}

static void viewport_identity_matrix(float matrix[16]) {
    memset(matrix, 0, sizeof(float) * 16u);
    matrix[0] = 1.0f;
    matrix[5] = 1.0f;
    matrix[10] = 1.0f;
    matrix[15] = 1.0f;
}

static Bounds3 viewport_bounds_for_vertex_range(const ViewerVertex* vertices, size_t start, size_t count) {
    Bounds3 bounds = bounds3_empty();
    if (vertices == NULL) {
        return bounds;
    }
    for (size_t index = 0; index < count; ++index) {
        bounds3_expand(&bounds, vertices[start + index].position);
    }
    return bounds;
}

static void viewport_init_imported_material_gpu_defaults(NovaSceneGpuMaterial* material) {
    if (material == NULL) {
        return;
    }

    memset(material, 0, sizeof(*material));
    material->baseColor[3] = 1.0f;
    material->params[3] = 1.45f;
    material->texIndices[0] = -1.0f;
    material->texIndices[1] = -1.0f;
    material->texIndices[2] = -1.0f;
    material->texIndices[3] = -1.0f;
    material->extra[0] = 1.0f;
    material->extra[1] = -1.0f;
    material->extra[2] = 0.5f;
}

static Vec3 world_up(void) {
    return vec3_make(0.0f, 0.0f, 1.0f);
}

static float viewport_saturate(float value) {
    return fminf(1.0f, fmaxf(0.0f, value));
}

static Vec3 viewport_clamp_vec3(Vec3 value, float minValue, float maxValue) {
    Vec3 clamped = value;
    for (int axis = 0; axis < 3; ++axis) {
        clamped.raw[axis] = fminf(maxValue, fmaxf(minValue, clamped.raw[axis]));
    }
    return clamped;
}

static BOOL viewport_face_range_is_bake_excluded(const ViewerFaceRange* range) {
    if (range == NULL) {
        return YES;
    }
    return strcasecmp(range->material, "light_marker") == 0;
}

static uint32_t viewport_clamp_preview_bake_power_of_two(uint32_t value, uint32_t minValue, uint32_t maxValue) {
    uint32_t clamped = value;
    if (minValue == 0u || maxValue == 0u) {
        return value;
    }
    if (clamped < minValue) {
        clamped = minValue;
    }
    if (clamped > maxValue) {
        clamped = maxValue;
    }

    uint32_t pow2Value = minValue;
    while (pow2Value < clamped && pow2Value < maxValue) {
        pow2Value <<= 1u;
    }
    if (pow2Value > maxValue) {
        pow2Value = maxValue;
    }
    return pow2Value;
}

static int viewport_preview_bake_power_of_two_exponent(uint32_t value, uint32_t minValue, uint32_t maxValue) {
    uint32_t normalized = viewport_clamp_preview_bake_power_of_two(value, minValue, maxValue);
    int exponent = 0;
    while (normalized > 1u) {
        normalized >>= 1u;
        exponent += 1;
    }
    return exponent;
}

static uint32_t viewport_preview_bake_power_of_two_value(int exponent, uint32_t minValue, uint32_t maxValue) {
    if (exponent < 0) {
        exponent = 0;
    }
    uint32_t value = 1u;
    for (int index = 0; index < exponent; ++index) {
        value <<= 1u;
    }
    return viewport_clamp_preview_bake_power_of_two(value, minValue, maxValue);
}

static void viewport_preview_bake_face_world_extents(const ViewerVertex* vertices,
                                                     ViewerFaceRange range,
                                                     float* outExtentU,
                                                     float* outExtentV) {
    float extentU = 1.0f;
    float extentV = 1.0f;
    if (vertices == NULL || range.vertexCount < 3u) {
        if (outExtentU != NULL) *outExtentU = extentU;
        if (outExtentV != NULL) *outExtentV = extentV;
        return;
    }

    Vec3 origin = vertices[range.vertexStart].position;
    Vec3 faceNormal = vec3_make(0.0f, 0.0f, 0.0f);
    for (size_t triOffset = 0; triOffset + 2u < range.vertexCount; triOffset += 3u) {
        Vec3 p0 = vertices[range.vertexStart + triOffset + 0u].position;
        Vec3 p1 = vertices[range.vertexStart + triOffset + 1u].position;
        Vec3 p2 = vertices[range.vertexStart + triOffset + 2u].position;
        Vec3 triNormal = vec3_cross(vec3_sub(p1, p0), vec3_sub(p2, p0));
        if (vec3_length(triNormal) > 1e-4f) {
            faceNormal = vec3_normalize(triNormal);
            break;
        }
    }
    if (vec3_length(faceNormal) < 1e-4f) {
        faceNormal = vec3_make(0.0f, 0.0f, 1.0f);
    }

    Vec3 tangent = vec3_make(0.0f, 0.0f, 0.0f);
    for (size_t vertexOffset = 1u; vertexOffset < range.vertexCount; ++vertexOffset) {
        Vec3 edge = vec3_sub(vertices[range.vertexStart + vertexOffset].position, origin);
        Vec3 projected = vec3_sub(edge, vec3_scale(faceNormal, vec3_dot(edge, faceNormal)));
        if (vec3_length(projected) > 1e-4f) {
            tangent = vec3_normalize(projected);
            break;
        }
    }
    if (vec3_length(tangent) < 1e-4f) {
        tangent = fabsf(faceNormal.raw[2]) < 0.999f ? vec3_make(0.0f, 0.0f, 1.0f) : vec3_make(1.0f, 0.0f, 0.0f);
        tangent = vec3_normalize(vec3_cross(tangent, faceNormal));
    }
    Vec3 bitangent = vec3_normalize(vec3_cross(faceNormal, tangent));
    if (vec3_length(bitangent) < 1e-4f) {
        bitangent = fabsf(faceNormal.raw[0]) < 0.999f ? vec3_make(1.0f, 0.0f, 0.0f) : vec3_make(0.0f, 1.0f, 0.0f);
        bitangent = vec3_normalize(vec3_cross(faceNormal, bitangent));
    }

    float minU = FLT_MAX;
    float maxU = -FLT_MAX;
    float minV = FLT_MAX;
    float maxV = -FLT_MAX;
    for (size_t vertexOffset = 0u; vertexOffset < range.vertexCount; ++vertexOffset) {
        Vec3 delta = vec3_sub(vertices[range.vertexStart + vertexOffset].position, origin);
        float localU = vec3_dot(delta, tangent);
        float localV = vec3_dot(delta, bitangent);
        minU = fminf(minU, localU);
        maxU = fmaxf(maxU, localU);
        minV = fminf(minV, localV);
        maxV = fmaxf(maxV, localV);
    }

    extentU = fmaxf(maxU - minU, 1.0f);
    extentV = fmaxf(maxV - minV, 1.0f);
    if (outExtentU != NULL) *outExtentU = extentU;
    if (outExtentV != NULL) *outExtentV = extentV;
}

static void viewport_preview_bake_chart_size_for_range(const ViewerVertex* vertices,
                                                       ViewerFaceRange range,
                                                       int density,
                                                       int* outWidth,
                                                       int* outHeight) {
    float extentU = 1.0f;
    float extentV = 1.0f;
    int width;
    int height;

    viewport_preview_bake_face_world_extents(vertices, range, &extentU, &extentV);
    width = (int)ceilf(extentU * (float)density);
    height = (int)ceilf(extentV * (float)density);
    width = (int)fmin((double)kPreviewBakeMaxResolution, fmax((double)kPreviewBakeMinResolution, (double)width));
    height = (int)fmin((double)kPreviewBakeMaxResolution, fmax((double)kPreviewBakeMinResolution, (double)height));

    if (outWidth != NULL) *outWidth = width;
    if (outHeight != NULL) *outHeight = height;
}

static BOOL viewport_select_preview_bake_light(const UiGizmoState* uiState,
                                               Vec3 fallbackPosition,
                                               Vec3 fallbackColor,
                                               float fallbackIntensity,
                                               float fallbackRange,
                                               BOOL fallbackEnabled,
                                               Vec3* outPosition,
                                               Vec3* outColor,
                                               float* outIntensity,
                                               float* outRange,
                                               BOOL* outEnabled) {
    Vec3 selectedPosition = fallbackPosition;
    Vec3 selectedColor = fallbackColor;
    float selectedIntensity = fallbackIntensity;
    float selectedRange = fallbackRange;
    BOOL selectedEnabled = fallbackEnabled;
    float bestScore = -1.0f;
    BOOL found = NO;

    if (uiState != NULL) {
        uint32_t lightCount = uiState->lightCount;
        if (lightCount > UI_MAX_LIGHTS) {
            lightCount = UI_MAX_LIGHTS;
        }
        for (uint32_t lightIndex = 0u; lightIndex < lightCount; ++lightIndex) {
            if (uiState->dynLightEnabled[lightIndex] == 0) {
                continue;
            }
            float intensity = fmaxf(uiState->dynLightIntensity[lightIndex], 0.0f);
            float range = fmaxf(uiState->dynLightRange[lightIndex], 1.0f);
            float colorLuma = uiState->dynLightColor[lightIndex][0] * 0.2126f +
                              uiState->dynLightColor[lightIndex][1] * 0.7152f +
                              uiState->dynLightColor[lightIndex][2] * 0.0722f;
            float score = intensity * range * fmaxf(colorLuma, 0.0f);
            if (score <= bestScore) {
                continue;
            }

            selectedPosition = vec3_make(uiState->dynLightMatrix[lightIndex][12],
                                         uiState->dynLightMatrix[lightIndex][13],
                                         uiState->dynLightMatrix[lightIndex][14]);
            selectedColor = vec3_make(uiState->dynLightColor[lightIndex][0],
                                      uiState->dynLightColor[lightIndex][1],
                                      uiState->dynLightColor[lightIndex][2]);
            selectedIntensity = intensity;
            selectedRange = range;
            selectedEnabled = YES;
            bestScore = score;
            found = YES;
        }
    }

    if (outPosition != NULL) {
        *outPosition = selectedPosition;
    }
    if (outColor != NULL) {
        *outColor = selectedColor;
    }
    if (outIntensity != NULL) {
        *outIntensity = selectedIntensity;
    }
    if (outRange != NULL) {
        *outRange = selectedRange;
    }
    if (outEnabled != NULL) {
        *outEnabled = selectedEnabled;
    }
    return found;
}

static uint32_t viewport_build_preview_bake_lights(const UiGizmoState* uiState,
                                                   Vec3 fallbackPosition,
                                                   Vec3 fallbackColor,
                                                   float fallbackIntensity,
                                                   float fallbackRange,
                                                   BOOL fallbackEnabled,
                                                   HwrtBakeLight* outLights,
                                                   uint32_t maxLights) {
    uint32_t lightCount = 0u;

    if (uiState != NULL && outLights != NULL && maxLights > 0u) {
        uint32_t uiLightCount = uiState->lightCount;
        if (uiLightCount > UI_MAX_LIGHTS) {
            uiLightCount = UI_MAX_LIGHTS;
        }
        for (uint32_t i = 0u; i < uiLightCount && lightCount < maxLights; ++i) {
            if (uiState->dynLightEnabled[i] == 0) {
                continue;
            }

            const float* m = uiState->dynLightMatrix[i];
            Vec3 pos = vec3_make(m[12], m[13], m[14]);
            Vec3 dir = vec3_make(-m[8], -m[9], -m[10]);
            float dirLen = vec3_length(dir);
            if (dirLen > 1e-5f) {
                dir = vec3_scale(dir, 1.0f / dirLen);
            } else {
                dir = vec3_make(0.0f, -1.0f, 0.0f);
            }

            if (uiState->dynLightType[i] == UI_LIGHT_QUAD) {
                Vec3 axisX = vec3_make(m[0], m[1], m[2]);
                Vec3 axisZ = vec3_make(m[8], m[9], m[10]);
                float axisXLen = vec3_length(axisX);
                float axisZLen = vec3_length(axisZ);
                if (axisXLen > 1e-5f) {
                    axisX = vec3_scale(axisX, 1.0f / axisXLen);
                }
                if (axisZLen > 1e-5f) {
                    axisZ = vec3_scale(axisZ, 1.0f / axisZLen);
                }
                dir = vec3_cross(axisX, axisZ);
                float dirNorm = vec3_length(dir);
                if (dirNorm > 1e-5f) {
                    dir = vec3_scale(dir, 1.0f / dirNorm);
                } else {
                    dir = vec3_make(0.0f, -1.0f, 0.0f);
                }
            }

            HwrtBakeLight* light = &outLights[lightCount++];
            memset(light, 0, sizeof(*light));
            light->posType = simd_make_float4(pos.raw[0], pos.raw[1], pos.raw[2], (float)uiState->dynLightType[i]);
            light->dirRange = simd_make_float4(dir.raw[0], dir.raw[1], dir.raw[2], fmaxf(uiState->dynLightRange[i], 0.05f));
            light->colorIntensity = simd_make_float4(uiState->dynLightColor[i][0], uiState->dynLightColor[i][1], uiState->dynLightColor[i][2], fmaxf(uiState->dynLightIntensity[i], 0.0f));

            if (uiState->dynLightType[i] == UI_LIGHT_QUAD) {
                light->params = simd_make_float4(uiState->dynLightQuadHalfSize[i][0],
                                                 uiState->dynLightQuadHalfSize[i][1],
                                                 0.0f,
                                                 0.0f);
            } else if (uiState->dynLightType[i] == UI_LIGHT_SUN) {
                float angularDiameterDegrees = fmaxf(uiState->dynLightSourceSize[i], 0.53f);
                light->params = simd_make_float4((angularDiameterDegrees * (float)M_PI / 180.0f) * 0.5f,
                                                 (float)(uiState->dynLightCastShadows[i] != 0),
                                                 0.0f,
                                                 0.0f);
            } else {
                light->params = simd_make_float4(fmaxf(uiState->dynLightSourceSize[i], 0.25f),
                                                 (float)(uiState->dynLightCastShadows[i] != 0),
                                                 cosf(uiState->dynLightSpotInnerDegrees[i] * (float)M_PI / 180.0f),
                                                 cosf(uiState->dynLightSpotOuterDegrees[i] * (float)M_PI / 180.0f));
            }
        }
    }

    if (lightCount == 0u && fallbackEnabled && outLights != NULL && maxLights > 0u) {
        HwrtBakeLight* light = &outLights[0];
        memset(light, 0, sizeof(*light));
        light->posType = simd_make_float4(fallbackPosition.raw[0], fallbackPosition.raw[1], fallbackPosition.raw[2], (float)UI_LIGHT_POINT);
        light->dirRange = simd_make_float4(0.0f, -1.0f, 0.0f, fmaxf(fallbackRange, 0.05f));
        light->colorIntensity = simd_make_float4(fallbackColor.raw[0], fallbackColor.raw[1], fallbackColor.raw[2], fmaxf(fallbackIntensity, 0.0f));
        light->params = simd_make_float4(0.25f, 0.0f, -1.0f, -1.0f);
        lightCount = 1u;
    }

    return lightCount;
}

static NSDictionary<NSString*, id>* viewport_build_baked_lightmap_payload(const simd_float4* litSource,
                                                                          const HwrtBakeTexel* texels,
                                                                          size_t texelCount,
                                                                          int bakeWidth,
                                                                          int bakeHeight,
                                                                          uint32_t validTexelCount,
                                                                          NSDictionary<NSString*, NSNumber*>** outStats) {
    if (litSource == NULL || texels == NULL || texelCount == 0u || bakeWidth <= 0 || bakeHeight <= 0) {
        return nil;
    }

    float rawLumMin = 1e30f;
    float rawLumMax = 0.0f;
    double rawLumSum = 0.0;
    uint32_t rawLumCount = 0u;
    for (size_t texelIndex = 0; texelIndex < texelCount; ++texelIndex) {
        if (texels[texelIndex].worldPosValid.w <= 0.5f) {
            continue;
        }
        simd_float3 c = simd_make_float3(fmaxf(litSource[texelIndex].x, 0.0f),
                                         fmaxf(litSource[texelIndex].y, 0.0f),
                                         fmaxf(litSource[texelIndex].z, 0.0f));
        float lum = c.x * 0.2126f + c.y * 0.7152f + c.z * 0.0722f;
        rawLumMin = fminf(rawLumMin, lum);
        rawLumMax = fmaxf(rawLumMax, lum);
        rawLumSum += (double)lum;
        rawLumCount += 1u;
    }
    if (rawLumCount == 0u) {
        rawLumMin = 0.0f;
    }

    NSMutableData* dilatedA = [NSMutableData dataWithLength:texelCount * sizeof(simd_float4)];
    NSMutableData* dilatedB = [NSMutableData dataWithLength:texelCount * sizeof(simd_float4)];
    NSMutableData* validMaskA = [NSMutableData dataWithLength:texelCount];
    NSMutableData* validMaskB = [NSMutableData dataWithLength:texelCount];
    if (dilatedA.length != texelCount * sizeof(simd_float4) ||
        dilatedB.length != texelCount * sizeof(simd_float4) ||
        validMaskA.length != texelCount ||
        validMaskB.length != texelCount) {
        return nil;
    }

    memcpy(dilatedA.mutableBytes, litSource, texelCount * sizeof(simd_float4));
    uint8_t* maskA = (uint8_t*)validMaskA.mutableBytes;
    for (size_t texelIndex = 0; texelIndex < texelCount; ++texelIndex) {
        maskA[texelIndex] = texels[texelIndex].worldPosValid.w > 0.5f ? 1u : 0u;
    }

    for (int iter = 0; iter < kChartBorderPadIterations; ++iter) {
        simd_float4* src = (simd_float4*)dilatedA.mutableBytes;
        simd_float4* dst = (simd_float4*)dilatedB.mutableBytes;
        uint8_t* srcMask = (uint8_t*)validMaskA.mutableBytes;
        uint8_t* dstMask = (uint8_t*)validMaskB.mutableBytes;
        memcpy(dst, src, texelCount * sizeof(simd_float4));
        memcpy(dstMask, srcMask, texelCount);

        BOOL wroteAny = NO;
        for (int y = 0; y < bakeHeight; ++y) {
            for (int x = 0; x < bakeWidth; ++x) {
                size_t idx = (size_t)y * (size_t)bakeWidth + (size_t)x;
                if (srcMask[idx] != 0u) {
                    continue;
                }
                simd_float3 sum = simd_make_float3(0.0f, 0.0f, 0.0f);
                int neighborCount = 0;
                for (int oy = -1; oy <= 1; ++oy) {
                    int ny = y + oy;
                    if (ny < 0 || ny >= bakeHeight) {
                        continue;
                    }
                    for (int ox = -1; ox <= 1; ++ox) {
                        int nx = x + ox;
                        if (nx < 0 || nx >= bakeWidth || (ox == 0 && oy == 0)) {
                            continue;
                        }
                        size_t nIdx = (size_t)ny * (size_t)bakeWidth + (size_t)nx;
                        if (srcMask[nIdx] == 0u) {
                            continue;
                        }
                        sum += src[nIdx].xyz;
                        neighborCount += 1;
                    }
                }
                if (neighborCount > 0) {
                    simd_float3 fill = sum / (float)neighborCount;
                    dst[idx] = simd_make_float4(fill.x, fill.y, fill.z, 1.0f);
                    dstMask[idx] = 1u;
                    wroteAny = YES;
                }
            }
        }
        if (!wroteAny) {
            break;
        }
        NSMutableData* tmpData = dilatedA;
        dilatedA = dilatedB;
        dilatedB = tmpData;
        NSMutableData* tmpMask = validMaskA;
        validMaskA = validMaskB;
        validMaskB = tmpMask;
    }

    simd_float4* lit = (simd_float4*)dilatedA.mutableBytes;
    float finalLumMin = 1e30f;
    float finalLumMax = 0.0f;
    double finalLumSum = 0.0;
    for (size_t texelIndex = 0; texelIndex < texelCount; ++texelIndex) {
        lit[texelIndex].x = fmaxf(lit[texelIndex].x, 0.0f);
        lit[texelIndex].y = fmaxf(lit[texelIndex].y, 0.0f);
        lit[texelIndex].z = fmaxf(lit[texelIndex].z, 0.0f);
        simd_float3 c = simd_make_float3(lit[texelIndex].x, lit[texelIndex].y, lit[texelIndex].z);
        float lum = c.x * 0.2126f + c.y * 0.7152f + c.z * 0.0722f;
        finalLumMin = fminf(finalLumMin, lum);
        finalLumMax = fmaxf(finalLumMax, lum);
        finalLumSum += (double)lum;
    }
    if (texelCount == 0u) {
        finalLumMin = 0.0f;
    }

    if (outStats != NULL) {
        *outStats = @{
            @"validTexels": @(validTexelCount),
            @"rawLumMin": @(rawLumMin),
            @"rawLumAvg": @((float)(rawLumCount > 0u ? rawLumSum / (double)rawLumCount : 0.0)),
            @"rawLumMax": @(rawLumMax),
            @"finalLumMin": @(finalLumMin),
            @"finalLumAvg": @((float)(texelCount > 0u ? finalLumSum / (double)texelCount : 0.0)),
            @"finalLumMax": @(finalLumMax),
        };
    }

    NSMutableData* hdrPixels = [NSMutableData dataWithLength:(NSUInteger)bakeWidth * (NSUInteger)bakeHeight * sizeof(float) * 4u];
    if (hdrPixels.length == (NSUInteger)bakeWidth * (NSUInteger)bakeHeight * sizeof(float) * 4u) {
        memcpy(hdrPixels.mutableBytes, lit, texelCount * sizeof(simd_float4));
    }

    NSMutableData* pixels = [NSMutableData dataWithLength:(NSUInteger)bakeWidth * (NSUInteger)bakeHeight * 4u];
    uint8_t* rgba = (uint8_t*)pixels.mutableBytes;
    for (size_t texelIndex = 0; texelIndex < texelCount; ++texelIndex) {
        float litR = fmaxf(lit[texelIndex].x, 0.0f) * kPreviewBakeDebugExposureDefault;
        float litG = fmaxf(lit[texelIndex].y, 0.0f) * kPreviewBakeDebugExposureDefault;
        float litB = fmaxf(lit[texelIndex].z, 0.0f) * kPreviewBakeDebugExposureDefault;
        float mappedR = litR / (1.0f + litR);
        float mappedG = litG / (1.0f + litG);
        float mappedB = litB / (1.0f + litB);
        rgba[texelIndex * 4u + 0u] = (uint8_t)lrintf(fminf(mappedR, 1.0f) * 255.0f);
        rgba[texelIndex * 4u + 1u] = (uint8_t)lrintf(fminf(mappedG, 1.0f) * 255.0f);
        rgba[texelIndex * 4u + 2u] = (uint8_t)lrintf(fminf(mappedB, 1.0f) * 255.0f);
        rgba[texelIndex * 4u + 3u] = 255u;
    }

    return @{
        @"width": @(bakeWidth),
        @"height": @(bakeHeight),
        @"format": @(NOVA_SCENE_TEXTURE_FORMAT_RGBA32_FLOAT),
        @"rgba32f": hdrPixels,
        @"rgba8": pixels,
    };
}

static NSMutableArray<NSMutableDictionary<NSString*, id>*>*
viewport_build_lightmap_page_layout(NSArray<NSString*>* orderedKeys,
                                    NSArray<NSNumber*>* widths,
                                    NSArray<NSNumber*>* heights,
                                    int atlasMaxExtent) {
    NSMutableArray<NSMutableDictionary<NSString*, id>*>* pages = [NSMutableArray array];
    if (orderedKeys.count == 0 || widths.count != orderedKeys.count || heights.count != orderedKeys.count || atlasMaxExtent <= 0) {
        return pages;
    }

    NSMutableDictionary<NSString*, NSArray<NSNumber*>*>* currentCharts = [NSMutableDictionary dictionary];
    int cursorX = 0;
    int cursorY = 0;
    int rowMaxH = 0;
    int pageIndex = 0;

    for (NSUInteger index = 0; index < orderedKeys.count; ++index) {
        NSString* faceKey = orderedKeys[index];
        int chartW = widths[index].intValue;
        int chartH = heights[index].intValue;
        int paddedW = chartW + kPreviewBakeAtlasChartPadding * 2;
        int paddedH = chartH + kPreviewBakeAtlasChartPadding * 2;
        if (chartW <= 0 || chartH <= 0) {
            continue;
        }
        if (paddedW > atlasMaxExtent) {
            paddedW = atlasMaxExtent;
        }
        if (paddedH > atlasMaxExtent) {
            paddedH = atlasMaxExtent;
        }

        if (cursorX > 0 && cursorX + paddedW > atlasMaxExtent) {
            cursorY += rowMaxH;
            cursorX = 0;
            rowMaxH = 0;
        }
        if (cursorY > 0 && cursorY + paddedH > atlasMaxExtent && currentCharts.count > 0) {
            NSMutableDictionary<NSString*, id>* page = [NSMutableDictionary dictionary];
            page[@"key"] = [NSString stringWithFormat:@"lightmap_%d", pageIndex++];
            page[@"width"] = @(atlasMaxExtent);
            page[@"height"] = @(cursorY + rowMaxH);
            page[@"charts"] = [currentCharts mutableCopy];
            [pages addObject:page];

            currentCharts = [NSMutableDictionary dictionary];
            cursorX = 0;
            cursorY = 0;
            rowMaxH = 0;
        }

        currentCharts[faceKey] = @[@(cursorX + kPreviewBakeAtlasChartPadding),
                                   @(cursorY + kPreviewBakeAtlasChartPadding),
                                   @(chartW),
                                   @(chartH)];
        cursorX += paddedW;
        if (paddedH > rowMaxH) {
            rowMaxH = paddedH;
        }
    }

    if (currentCharts.count > 0) {
        NSMutableDictionary<NSString*, id>* page = [NSMutableDictionary dictionary];
        page[@"key"] = [NSString stringWithFormat:@"lightmap_%d", pageIndex++];
        page[@"width"] = @(atlasMaxExtent);
        page[@"height"] = @(cursorY + rowMaxH);
        page[@"charts"] = [currentCharts mutableCopy];
        [pages addObject:page];
    }

    return pages;
}

// Assemble per-face baked payloads into a small number of shared global lightmap pages.
static NSMutableDictionary<NSString*, NSMutableDictionary<NSString*, id>*>*
viewport_assemble_global_lightmap_atlases(NSDictionary<NSString*, NSDictionary<NSString*, id>*>* facePayloads,
                                          NSArray<NSString*>* orderedFaceKeys,
                                          int atlasMaxExtent) {
    NSMutableDictionary<NSString*, NSMutableDictionary<NSString*, id>*>* result = [NSMutableDictionary dictionary];
    NSMutableArray<NSNumber*>* widths = [NSMutableArray array];
    NSMutableArray<NSNumber*>* heights = [NSMutableArray array];
    NSMutableArray<NSString*>* packableKeys = [NSMutableArray array];
    if (facePayloads.count == 0) {
        return result;
    }

    for (NSString* faceKey in orderedFaceKeys) {
        NSDictionary<NSString*, id>* payload = facePayloads[faceKey];
        int width = [payload[@"width"] intValue];
        int height = [payload[@"height"] intValue];
        if (payload == nil || width <= 0 || height <= 0) {
            continue;
        }
        [packableKeys addObject:faceKey];
        [widths addObject:@(width)];
        [heights addObject:@(height)];
    }

    NSArray<NSMutableDictionary<NSString*, id>*>* pages = viewport_build_lightmap_page_layout(packableKeys, widths, heights, atlasMaxExtent);
    for (NSMutableDictionary<NSString*, id>* page in pages) {
        NSString* pageKey = page[@"key"];
        NSDictionary<NSString*, NSArray<NSNumber*>*>* charts = page[@"charts"];
        int atlasW = [page[@"width"] intValue];
        int atlasH = [page[@"height"] intValue];
        if (pageKey.length == 0 || charts.count == 0 || atlasW <= 0 || atlasH <= 0) {
            continue;
        }

        size_t atlasTexelCount = (size_t)atlasW * (size_t)atlasH;
        NSMutableData* atlasRgba32f = [NSMutableData dataWithLength:atlasTexelCount * sizeof(simd_float4)];
        NSMutableData* atlasRgba8 = [NSMutableData dataWithLength:atlasTexelCount * 4u];
        if (atlasRgba32f.length == 0 || atlasRgba8.length == 0) {
            continue;
        }
        simd_float4* atlasHdr = (simd_float4*)atlasRgba32f.mutableBytes;
        uint8_t* atlasLdr = (uint8_t*)atlasRgba8.mutableBytes;

        for (NSString* faceKey in packableKeys) {
            NSArray<NSNumber*>* chartInfo = charts[faceKey];
            NSDictionary<NSString*, id>* payload = facePayloads[faceKey];
            if (chartInfo == nil || payload == nil) {
                continue;
            }
            int chartX = chartInfo[0].intValue;
            int chartY = chartInfo[1].intValue;
            int chartW = chartInfo[2].intValue;
            int chartH = chartInfo[3].intValue;
            NSData* srcHdr32 = payload[@"rgba32f"];
            NSData* srcLdr8 = payload[@"rgba8"];
            const simd_float4* srcHdr = srcHdr32 != nil ? (const simd_float4*)srcHdr32.bytes : NULL;
            const uint8_t* srcLdr = srcLdr8 != nil ? (const uint8_t*)srcLdr8.bytes : NULL;
            for (int py = -kPreviewBakeAtlasChartPadding; py < chartH + kPreviewBakeAtlasChartPadding; ++py) {
                int dstRow = chartY + py;
                if (dstRow < 0 || dstRow >= atlasH) {
                    continue;
                }
                int srcY = py;
                if (srcY < 0) srcY = 0;
                if (srcY >= chartH) srcY = chartH - 1;
                for (int px = -kPreviewBakeAtlasChartPadding; px < chartW + kPreviewBakeAtlasChartPadding; ++px) {
                    int dstCol = chartX + px;
                    if (dstCol < 0 || dstCol >= atlasW) {
                        continue;
                    }
                    int srcX = px;
                    if (srcX < 0) srcX = 0;
                    if (srcX >= chartW) srcX = chartW - 1;
                    size_t si = (size_t)srcY * (size_t)chartW + (size_t)srcX;
                    size_t di = (size_t)dstRow * (size_t)atlasW + (size_t)dstCol;
                    if (srcHdr != NULL) {
                        atlasHdr[di] = srcHdr[si];
                    }
                    if (srcLdr != NULL) {
                        atlasLdr[di * 4u + 0u] = srcLdr[si * 4u + 0u];
                        atlasLdr[di * 4u + 1u] = srcLdr[si * 4u + 1u];
                        atlasLdr[di * 4u + 2u] = srcLdr[si * 4u + 2u];
                        atlasLdr[di * 4u + 3u] = srcLdr[si * 4u + 3u];
                    }
                }
            }
        }

        NSMutableDictionary<NSString*, id>* atlasDict = [NSMutableDictionary dictionary];
        atlasDict[@"rgba32f"] = atlasRgba32f;
        atlasDict[@"rgba8"] = atlasRgba8;
        atlasDict[@"width"] = @(atlasW);
        atlasDict[@"height"] = @(atlasH);
        atlasDict[@"format"] = @(NOVA_SCENE_TEXTURE_FORMAT_RGBA32_FLOAT);
        atlasDict[@"charts"] = [charts mutableCopy];
        result[pageKey] = atlasDict;
    }

    return result;
}

static void viewport_compute_preview_bake_lighting(const ViewerVertex* vertices,
                                                   const Vec3* baseColors,
                                                   size_t vertexCount,
                                                   Vec3 primaryLightPosition,
                                                   Vec3 primaryLightColor,
                                                   float primaryLightIntensity,
                                                   float primaryLightRange,
                                                   BOOL primaryLightEnabled,
                                                   Vec3* outLighting) {
    Vec3 boundsMin;
    Vec3 boundsMax;
    Vec3 boundsExtent;
    float sceneRadius;
    float sceneScaleTerm;
    uint32_t giSamples = kPreviewBakeGiSamples;

    if (vertices == NULL || baseColors == NULL || outLighting == NULL || vertexCount == 0) {
        return;
    }

    boundsMin = vertices[0].position;
    boundsMax = vertices[0].position;
    for (size_t index = 1; index < vertexCount; ++index) {
        for (int axis = 0; axis < 3; ++axis) {
            boundsMin.raw[axis] = fminf(boundsMin.raw[axis], vertices[index].position.raw[axis]);
            boundsMax.raw[axis] = fmaxf(boundsMax.raw[axis], vertices[index].position.raw[axis]);
        }
    }
    boundsExtent = vec3_sub(boundsMax, boundsMin);
    sceneRadius = fmaxf(vec3_length(boundsExtent) * 0.5f, 1.0f);
    sceneScaleTerm = sceneRadius * sceneRadius * 0.0015f;
    if (vertexCount > 250000u) {
        giSamples = 12u;
    }

    for (size_t vertexIndex = 0; vertexIndex < vertexCount; ++vertexIndex) {
        Vec3 position = vertices[vertexIndex].position;
        Vec3 normal = vec3_normalize(vertices[vertexIndex].normal);
        Vec3 directLighting = vec3_make(0.10f, 0.10f, 0.10f);
        Vec3 bouncedLighting = vec3_make(0.0f, 0.0f, 0.0f);
        float bouncedWeight = 0.0f;

        if (primaryLightEnabled && primaryLightRange > 0.001f) {
            Vec3 toLight = vec3_sub(primaryLightPosition, position);
            float lightDistance = vec3_length(toLight);
            if (lightDistance > 0.001f && lightDistance < primaryLightRange) {
                Vec3 lightDir = vec3_scale(toLight, 1.0f / lightDistance);
                float nDotL = viewport_saturate(vec3_dot(normal, lightDir));
                float attenuation = viewport_saturate(1.0f - (lightDistance / primaryLightRange));
                float intensity = fmaxf(primaryLightIntensity, 0.0f) * nDotL * attenuation;
                directLighting = vec3_add(directLighting, vec3_scale(primaryLightColor, intensity));
            }
        }

        for (uint32_t sampleIndex = 0u; sampleIndex < giSamples; ++sampleIndex) {
            uint32_t hashed = (uint32_t)(vertexIndex * 1315423911u + sampleIndex * 2654435761u);
            size_t bounceIndex = (size_t)(hashed % (uint32_t)vertexCount);
            Vec3 toBounce;
            float distanceSquared;
            float distance;
            Vec3 bounceDir;
            float nDotBounce;
            float bounceFacing;
            float weight;

            if (bounceIndex == vertexIndex) {
                continue;
            }

            toBounce = vec3_sub(vertices[bounceIndex].position, position);
            distanceSquared = vec3_dot(toBounce, toBounce);
            if (distanceSquared <= 1e-4f) {
                continue;
            }
            distance = sqrtf(distanceSquared);
            bounceDir = vec3_scale(toBounce, 1.0f / distance);
            nDotBounce = viewport_saturate(vec3_dot(normal, bounceDir));
            bounceFacing = viewport_saturate(vec3_dot(vec3_normalize(vertices[bounceIndex].normal), vec3_scale(bounceDir, -1.0f)));
            if (nDotBounce <= 0.001f || bounceFacing <= 0.001f) {
                continue;
            }

            weight = (nDotBounce * bounceFacing) / (distanceSquared + sceneScaleTerm);
            bouncedLighting = vec3_add(bouncedLighting, vec3_scale(baseColors[bounceIndex], weight));
            bouncedWeight += weight;
        }

        if (bouncedWeight > 1e-6f) {
            bouncedLighting = vec3_scale(bouncedLighting, 1.0f / bouncedWeight);
        }
        outLighting[vertexIndex] = viewport_clamp_vec3(vec3_add(directLighting, vec3_scale(bouncedLighting, 0.45f)), 0.05f, 2.5f);
    }
}

static Vec3 plane_right(VmfViewportPlane plane) {
    switch (plane) {
        case VmfViewportPlaneXY:
        case VmfViewportPlaneXZ:
            return vec3_make(1.0f, 0.0f, 0.0f);
        case VmfViewportPlaneZY:
            return vec3_make(0.0f, 1.0f, 0.0f);
    }
    return vec3_make(1.0f, 0.0f, 0.0f);
}

static Vec3 plane_up(VmfViewportPlane plane) {
    switch (plane) {
        case VmfViewportPlaneXY:
            return vec3_make(0.0f, 1.0f, 0.0f);
        case VmfViewportPlaneXZ:
        case VmfViewportPlaneZY:
            return vec3_make(0.0f, 0.0f, 1.0f);
    }
    return vec3_make(0.0f, 1.0f, 0.0f);
}

static Vec3 plane_forward(VmfViewportPlane plane) {
    switch (plane) {
        case VmfViewportPlaneXY:
            return vec3_make(0.0f, 0.0f, -1.0f);
        case VmfViewportPlaneXZ:
            return vec3_make(0.0f, 1.0f, 0.0f);
        case VmfViewportPlaneZY:
            return vec3_make(-1.0f, 0.0f, 0.0f);
    }
    return vec3_make(0.0f, 0.0f, -1.0f);
}

static float snap_to_grid(float value, float grid) {
    grid = fmaxf(grid, 1.0f);
    return roundf(value / grid) * grid;
}

static float plane_u_value(VmfViewportPlane plane, Vec3 point) {
    switch (plane) {
        case VmfViewportPlaneXY:
        case VmfViewportPlaneXZ:
            return point.raw[0];
        case VmfViewportPlaneZY:
            return point.raw[1];
    }
    return point.raw[0];
}

static float plane_v_value(VmfViewportPlane plane, Vec3 point) {
    switch (plane) {
        case VmfViewportPlaneXY:
            return point.raw[1];
        case VmfViewportPlaneXZ:
        case VmfViewportPlaneZY:
            return point.raw[2];
    }
    return point.raw[1];
}

static Bounds3 normalized_bounds(Bounds3 bounds) {
    Bounds3 normalized = bounds;
    for (int axis = 0; axis < 3; ++axis) {
        if (normalized.min.raw[axis] > normalized.max.raw[axis]) {
            float tmp = normalized.min.raw[axis];
            normalized.min.raw[axis] = normalized.max.raw[axis];
            normalized.max.raw[axis] = tmp;
        }
    }
    return normalized;
}

static float adjusted_dragged_edge(float draggedValue, float fixedValue, float minimumSpan, BOOL preservePositiveDirection) {
    if (fabsf(draggedValue - fixedValue) >= minimumSpan) {
        return draggedValue;
    }
    return fixedValue + (preservePositiveDirection ? minimumSpan : -minimumSpan);
}

static float ortho_grid_step(float visibleSpan, float baseStep) {
    float step = fmaxf(baseStep, 1.0f);
    float targetStep = fmaxf(visibleSpan / 24.0f, step);
    while (step < targetStep) {
        step *= 2.0f;
    }
    return step;
}

static CGFloat signed_distance_to_screen_line(NSPoint point, NSPoint lineStart, NSPoint lineEnd) {
    CGFloat dx = lineEnd.x - lineStart.x;
    CGFloat dy = lineEnd.y - lineStart.y;
    return (dx * (point.y - lineStart.y)) - (dy * (point.x - lineStart.x));
}

static NSUInteger clip_polygon_to_halfplane(NSPoint* points,
                                            NSUInteger count,
                                            NSPoint lineStart,
                                            NSPoint lineEnd,
                                            BOOL keepPositive,
                                            NSPoint* outPoints,
                                            NSUInteger maxOutPoints) {
    if (!points || !outPoints || count == 0 || maxOutPoints == 0) {
        return 0;
    }

    NSUInteger outCount = 0;
    for (NSUInteger index = 0; index < count; ++index) {
        NSPoint current = points[index];
        NSPoint previous = points[(index + count - 1) % count];
        CGFloat currentDistance = signed_distance_to_screen_line(current, lineStart, lineEnd);
        CGFloat previousDistance = signed_distance_to_screen_line(previous, lineStart, lineEnd);
        BOOL currentInside = keepPositive ? currentDistance >= 0.0 : currentDistance <= 0.0;
        BOOL previousInside = keepPositive ? previousDistance >= 0.0 : previousDistance <= 0.0;

        if (currentInside != previousInside) {
            CGFloat denominator = currentDistance - previousDistance;
            if (fabs(denominator) > 1e-6) {
                CGFloat t = currentDistance / denominator;
                NSPoint intersection = NSMakePoint(current.x + (previous.x - current.x) * t,
                                                   current.y + (previous.y - current.y) * t);
                if (outCount < maxOutPoints) {
                    outPoints[outCount++] = intersection;
                }
            }
        }
        if (currentInside && outCount < maxOutPoints) {
            outPoints[outCount++] = current;
        }
    }
    return outCount;
}

static NovaToolMetalEditorVertex viewport_metal_vertex_from_viewer_vertex(ViewerVertex vertex) {
    NovaToolMetalEditorVertex converted = {0};
    converted.position[0] = vertex.position.raw[0];
    converted.position[1] = vertex.position.raw[1];
    converted.position[2] = vertex.position.raw[2];
    converted.normal[0] = vertex.normal.raw[0];
    converted.normal[1] = vertex.normal.raw[1];
    converted.normal[2] = vertex.normal.raw[2];
    converted.color[0] = vertex.color.raw[0];
    converted.color[1] = vertex.color.raw[1];
    converted.color[2] = vertex.color.raw[2];
    converted.u = vertex.u;
    converted.v = vertex.v;
    return converted;
}

static void append_grid_line(NovaToolMetalEditorVertex* vertices,
                             NSUInteger capacity,
                             NSUInteger* count,
                             Vec3 start,
                             Vec3 end,
                             Vec3 color) {
    if (*count + 2 > capacity) {
        return;
    }

    ViewerVertex a = {
        .position = start,
        .normal = vec3_make(0.0f, 0.0f, 1.0f),
        .color = color,
    };
    ViewerVertex b = {
        .position = end,
        .normal = vec3_make(0.0f, 0.0f, 1.0f),
        .color = color,
    };
    vertices[*count] = viewport_metal_vertex_from_viewer_vertex(a);
    vertices[*count + 1] = viewport_metal_vertex_from_viewer_vertex(b);
    *count += 2;
}

static NovaToolMetalEditorFaceRange viewport_metal_face_range_from_viewer_face_range(ViewerFaceRange range) {
    NovaToolMetalEditorFaceRange converted = {0};
    converted.entityIndex = range.entityIndex;
    converted.solidIndex = range.solidIndex;
    converted.sideIndex = range.sideIndex;
    converted.vertexStart = range.vertexStart;
    converted.vertexCount = range.vertexCount;
    memcpy(converted.material, range.material, sizeof(converted.material));
    return converted;
}

static id<MTLBuffer> viewport_create_editor_vertex_buffer(id<MTLDevice> device, const ViewerVertex* vertices, size_t count) {
    if (device == nil || vertices == NULL || count == 0) {
        return nil;
    }

    NovaToolMetalEditorVertex* converted = (NovaToolMetalEditorVertex*)malloc(count * sizeof(NovaToolMetalEditorVertex));
    if (converted == NULL) {
        return nil;
    }
    for (size_t index = 0; index < count; ++index) {
        converted[index] = viewport_metal_vertex_from_viewer_vertex(vertices[index]);
    }
    id<MTLBuffer> buffer = [device newBufferWithBytes:converted
                                               length:count * sizeof(NovaToolMetalEditorVertex)
                                              options:MTLResourceStorageModeShared];
    free(converted);
    return buffer;
}

static NovaToolMetalEditorVertex* viewport_create_editor_vertex_array(const ViewerVertex* vertices, size_t count) {
    if (vertices == NULL || count == 0) {
        return NULL;
    }

    NovaToolMetalEditorVertex* converted = (NovaToolMetalEditorVertex*)malloc(count * sizeof(NovaToolMetalEditorVertex));
    if (converted == NULL) {
        return NULL;
    }
    for (size_t index = 0; index < count; ++index) {
        converted[index] = viewport_metal_vertex_from_viewer_vertex(vertices[index]);
    }
    return converted;
}

    static NovaToolMetalEditorFaceRange* viewport_create_editor_face_range_array(const ViewerFaceRange* ranges, size_t count) {
    if (ranges == NULL || count == 0) {
        return NULL;
    }

    NovaToolMetalEditorFaceRange* converted = (NovaToolMetalEditorFaceRange*)malloc(count * sizeof(NovaToolMetalEditorFaceRange));
    if (converted == NULL) {
        return NULL;
    }
    for (size_t index = 0; index < count; ++index) {
        converted[index] = viewport_metal_face_range_from_viewer_face_range(ranges[index]);
    }
    return converted;
}

static void* viewport_resolve_texture(const char* materialName, void* userData) {
    if (materialName == NULL || userData == NULL) {
        return NULL;
    }

    VmfViewport* viewport = (__bridge VmfViewport*)userData;
    NSString* material = [NSString stringWithUTF8String:materialName];
    id<MTLTexture> texture = [viewport cachedTextureForMaterial:material];
    return texture != nil ? (__bridge void*)texture : NULL;
}

static int viewport_encode_overlay(void* commandBufferHandle, void* drawableHandle, void* userData, char* errorMessage, size_t errorMessageCapacity) {
    if (commandBufferHandle == NULL || drawableHandle == NULL || userData == NULL) {
        return 1;
    }

    VmfViewport* viewport = (__bridge VmfViewport*)userData;
    return [viewport encodeGizmoOverlayOnCommandBuffer:(__bridge id<MTLCommandBuffer>)commandBufferHandle
                                             drawable:(__bridge id<CAMetalDrawable>)drawableHandle
                                         errorMessage:errorMessage
                                             capacity:errorMessageCapacity] ? 1 : 0;
}

@implementation ViewportMetalView {
    NSPoint _lastPoint;
    CGPoint _lockedCursorPoint;
    BOOL _cursorLocked;
    BOOL _hadFreeLookDrag;
    NSEventModifierFlags _clickModifierFlags;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    NSPasteboard* pasteboard = sender.draggingPasteboard;
    if ([pasteboard canReadObjectForClasses:@[[NSURL class]] options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }]) {
        return NSDragOperationCopy;
    }
    return NSDragOperationNone;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSPasteboard* pasteboard = sender.draggingPasteboard;
    NSArray<NSURL*>* urls = [pasteboard readObjectsForClasses:@[[NSURL class]] options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
    NSURL* firstURL = urls.firstObject;
    if (!firstURL) {
        return NO;
    }
    [self.owner handleViewportDroppedPath:firstURL.path];
    return YES;
}

- (void)keyDown:(NSEvent*)event {
    if (![self.owner handleViewportKeyDown:event]) {
        [super keyDown:event];
    }
}

- (void)keyUp:(NSEvent*)event {
    if (![self.owner handleViewportKeyUp:event]) {
        [super keyUp:event];
    }
}

- (void)mouseDown:(NSEvent*)event {
    [self.window makeFirstResponder:self];
    _lastPoint = [self convertPoint:event.locationInWindow fromView:nil];
    [self.owner handleViewportMouseDownAtPoint:_lastPoint];
}

- (void)mouseDragged:(NSEvent*)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSPoint delta = NSMakePoint(point.x - _lastPoint.x, point.y - _lastPoint.y);
    _lastPoint = point;
    [self.owner handleViewportPrimaryDragWithDelta:delta alternate:(event.modifierFlags & NSEventModifierFlagOption) != 0];
}

- (void)mouseUp:(NSEvent*)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    [self.owner handleViewportMouseUpAtPoint:point];
}

- (void)rightMouseDown:(NSEvent*)event {
    [self.window makeFirstResponder:self];
    _lastPoint = [self convertPoint:event.locationInWindow fromView:nil];
    _hadFreeLookDrag = NO;
    _clickModifierFlags = event.modifierFlags;  // capture here while all keys are definitely held
    [self.owner handleViewportMouseDownAtPoint:_lastPoint];
    if (![self.owner handleViewportSecondaryMouseDown]) {
        return;
    }

    CGEventRef currentEvent = CGEventCreate(NULL);
    if (currentEvent) {
        _lockedCursorPoint = CGEventGetLocation(currentEvent);
        CFRelease(currentEvent);
    }
    if (!_cursorLocked) {
        CGAssociateMouseAndMouseCursorPosition(false);
        [NSCursor hide];
        _cursorLocked = YES;
    }
}

- (void)rightMouseDragged:(NSEvent*)event {
    NSPoint delta = NSMakePoint(event.deltaX, event.deltaY);
    if (hypot(delta.x, delta.y) > 0.5) {
        _hadFreeLookDrag = YES;
    }
    [self.owner handleViewportSecondaryDragWithDelta:delta];
}

- (void)rightMouseUp:(NSEvent*)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (_cursorLocked) {
        CGWarpMouseCursorPosition(_lockedCursorPoint);
        CGAssociateMouseAndMouseCursorPosition(true);
        [NSCursor unhide];
        _cursorLocked = NO;
    }
    [self.owner handleViewportSecondaryMouseUp];
    if (!_hadFreeLookDrag) {
        [self.owner handleViewportSecondaryClickAtPoint:point modifierFlags:_clickModifierFlags];
    }
}

- (void)scrollWheel:(NSEvent*)event {
    [self.owner handleViewportScrollDelta:event.deltaY];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea* area in self.trackingAreas) {
        [self removeTrackingArea:area];
    }
    NSTrackingAreaOptions options = NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect;
    NSTrackingArea* area = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:options owner:self userInfo:nil];
    [self addTrackingArea:area];
}

- (void)mouseMoved:(NSEvent*)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    [self.owner handleViewportMouseHoverAtPoint:point];
}

- (void)viewWillMoveToWindow:(NSWindow*)newWindow {
    if (!newWindow && _cursorLocked) {
        CGAssociateMouseAndMouseCursorPosition(true);
        [NSCursor unhide];
        _cursorLocked = NO;
    }
    [super viewWillMoveToWindow:newWindow];
}

@end

@implementation ViewportOverlayView

- (BOOL)isOpaque {
    return NO;
}

- (NSView*)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [self.owner drawEditorOverlay];
}

@end

@interface VmfViewport () <MTKViewDelegate>

@property(nonatomic, copy) NSString* title;
@property(nonatomic, assign) VmfViewportDimension dimension;
@property(nonatomic, assign) VmfViewportPlane plane;
@property(nonatomic, strong) ViewportMetalView* metalView;
@property(nonatomic, strong) NSVisualEffectView* headerView;
@property(nonatomic, strong) ViewportOverlayView* overlayView;
@property(nonatomic, strong) NSTextField* titleLabel;
@property(nonatomic, strong) NSTextField* modeLabel;
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property(nonatomic, strong) id<MTLRenderPipelineState> pipelineState;
@property(nonatomic, strong) id<MTLDepthStencilState> depthState;
@property(nonatomic, strong) id<MTLDepthStencilState> disabledDepthState;
@property(nonatomic, strong) id<MTLDepthStencilState> readOnlyDepthState;
@property(nonatomic, strong) id<MTLBuffer> vertexBuffer;
@property(nonatomic, strong) id<MTLBuffer> edgeVertexBuffer;
@property(nonatomic, strong) id<MTLBuffer> selectedFaceBuffer;
@property(nonatomic, strong) id<MTLBuffer> highlightedFaceBuffer;
@property(nonatomic, assign) NSUInteger vertexCount;
@property(nonatomic, assign) NSUInteger edgeVertexCount;
@property(nonatomic, assign) NSUInteger selectedFaceVertexCount;
@property(nonatomic, assign) NSUInteger highlightedFaceVertexCount;
@property(nonatomic, assign) ViewerVertex* cpuVertices;
@property(nonatomic, assign) ViewerVertex* cpuEdgeVertices;
@property(nonatomic, assign) Vec3* baseVertexColors;
@property(nonatomic, assign) ViewerFaceRange* faceRanges;
@property(nonatomic, assign) size_t faceRangeCount;
@property(nonatomic, assign) Bounds3 sceneBounds;
@property(nonatomic, assign) Vec3 target;
@property(nonatomic, assign) Vec3 orbitLerpTarget;
@property(nonatomic, assign) float yaw;
@property(nonatomic, assign) float pitch;
@property(nonatomic, assign) float distance;
@property(nonatomic, assign) Vec3 freeLookPosition;
@property(nonatomic, assign) BOOL freeLookActive;
@property(nonatomic, assign) CameraMovement movementMask;
@property(nonatomic, assign) CFTimeInterval lastFrameTime;
@property(nonatomic, assign) Vec3 orthoCenter;
@property(nonatomic, assign) float orthoSize;
@property(nonatomic, assign) Vec3 primaryLightPosition;
@property(nonatomic, assign) Vec3 primaryLightColor;
@property(nonatomic, assign) float primaryLightIntensity;
@property(nonatomic, assign) float primaryLightRange;
@property(nonatomic, assign) BOOL primaryLightEnabled;
@property(nonatomic, assign) Bounds3 selectionBounds;
@property(nonatomic, assign) BOOL selectionVisible;
@property(nonatomic, assign) Vec3* selectionVertices;
@property(nonatomic, assign) size_t selectionVertexCount;
@property(nonatomic, assign) VmfSolidEdge* selectionEdges;
@property(nonatomic, assign) size_t selectionEdgeCount;
@property(nonatomic, assign) VmfViewportSelectionEdge selectedFaceEdge;
@property(nonatomic, assign) BOOL selectedFaceVisible;
@property(nonatomic, assign) size_t selectedFaceEntityIndex;
@property(nonatomic, assign) size_t selectedFaceSolidIndex;
@property(nonatomic, assign) size_t selectedFaceSideIndex;
@property(nonatomic, assign) BOOL highlightedFaceVisible;
@property(nonatomic, assign) size_t highlightedFaceEntityIndex;
@property(nonatomic, assign) size_t highlightedFaceSolidIndex;
@property(nonatomic, assign) size_t highlightedFaceSideIndex;
@property(nonatomic, assign) Bounds3 creationBounds;
@property(nonatomic, assign) BOOL creationVisible;
@property(nonatomic, assign) Bounds3 pluginDebugBounds;
@property(nonatomic, assign) BOOL pluginDebugVisible;
@property(nonatomic, assign) BOOL clipGuideVisible;
@property(nonatomic, assign) Vec3 clipGuideStart;
@property(nonatomic, assign) Vec3 clipGuideEnd;
@property(nonatomic, assign) ViewportDragMode dragMode;
@property(nonatomic, assign) ViewportHandle activeHandle;
@property(nonatomic, assign) size_t activeEdgeFirstSideIndex;
@property(nonatomic, assign) size_t activeEdgeSecondSideIndex;
@property(nonatomic, assign) Vec3 dragAnchorWorld;
@property(nonatomic, assign) Bounds3 dragOriginalBounds;
@property(nonatomic, assign) NSPoint dragStartPoint;
@property(nonatomic, assign) BOOL pendingClickSelection;
@property(nonatomic, assign) BOOL vertexEditIsInvalid;
@property(nonatomic, strong) id<MTLBuffer> vertexEditPreviewBuffer;
@property(nonatomic, assign) NSUInteger vertexEditPreviewVertexCount;
@property(nonatomic, strong) id<MTLSamplerState> samplerState;
@property(nonatomic, strong) NSMutableDictionary<NSString*, id>* textureCache; // id<MTLTexture> or NSNull
@property(nonatomic, strong) NSMutableDictionary<NSString*, id>* textureDataCache; // NSDictionary or NSNull
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSNumber*>* textureMissLogTimes;
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSDictionary<NSString*, id>*>* previewBakedLightmaps;
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSNumber*>* previewBakeBrushResolutions;
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSDictionary<NSString*, NSNumber*>*>* previewBakeBrushStats;
@property(nonatomic, strong) NSMutableDictionary<NSString*, id>* previewBakedDebugTextures;
@property(nonatomic, copy) NSString* previewBakeDebugSelectedKey;
@property(nonatomic, assign) BOOL previewBakeDebugWindowOpen;
@property(nonatomic, assign) float previewBakeDebugExposure;
@property(nonatomic, assign) uint32_t previewBakeRtSamplesPerTexel;
@property(nonatomic, assign) uint32_t previewBakeTargetSamplesPerTexel;
@property(nonatomic, assign) uint32_t previewBakeBounceCount;
@property(nonatomic, assign) int previewBakeDensity;
@property(nonatomic, assign) uint32_t previewBakeAccumulatedSamplesPerTexel;
@property(nonatomic, assign) int previewBakeDisplayMode;
@property(nonatomic, assign) BOOL previewBakePauseRequested;
@property(nonatomic, assign) BOOL previewBakeCancelRequested;
@property(nonatomic, strong) id<MTLComputePipelineState> hwrtBakePipeline;
@property(nonatomic, copy) NSString* textureDirectory;
@property(nonatomic, assign) NovaToolMetalEditorViewportRenderer metalRenderer;
@property(nonatomic, assign) NovaToolMetalContext fullMetalContext;
@property(nonatomic, assign) NovaToolMetalRenderer fullMetalRenderer;
@property(nonatomic, assign) NovaSceneData importedSceneData;
@property(nonatomic, assign) UiGizmoState fullRendererUiState;
@property(nonatomic, assign) NovaSceneWorld* sceneWorld;
@property(nonatomic, assign) BOOL fullRendererInitialized;
@property(nonatomic, assign) uint32_t fullRendererFrameIndex;
@property(nonatomic, assign) void* imguiContext;
@property(nonatomic, assign) BOOL gizmoHovered;
@property(nonatomic, assign) BOOL gizmoInteractionActive;
@property(nonatomic, assign) BOOL orbitLerpActive;
@property(nonatomic, assign) BOOL previewBakeInProgress;
@property(nonatomic, assign) BOOL previewBakedLightingEnabled;
@property(nonatomic, assign) uint64_t meshRevision;

@end

@interface VmfViewport () {
    size_t _activeVertexIndices[VMF_MAX_SOLID_VERTICES];
    size_t _activeVertexIndexCount;
}

@end

@implementation VmfViewport

- (void)dealloc {
    if (self.imguiContext != NULL) {
        ImGui::SetCurrentContext((ImGuiContext*)self.imguiContext);
        ImGui_ImplMetal_Shutdown();
        ImGui_ImplOSX_Shutdown();
        ImGui::DestroyContext((ImGuiContext*)self.imguiContext);
        self.imguiContext = NULL;
    }
    nova_tool_metal_renderer_shutdown(&_fullMetalRenderer);
    nova_tool_metal_context_shutdown(&_fullMetalContext);
    nova_scene_data_release(&_importedSceneData);
    nova_tool_metal_editor_viewport_renderer_shutdown(&_metalRenderer);
    free(self.cpuVertices);
    free(self.cpuEdgeVertices);
    free(self.baseVertexColors);
    free(self.faceRanges);
    free(self.selectionVertices);
    free(self.selectionEdges);
}

- (instancetype)initWithFrame:(NSRect)frame
                       device:(id<MTLDevice>)device
                        title:(NSString*)title
                    dimension:(VmfViewportDimension)dimension
                        plane:(VmfViewportPlane)plane
                   renderMode:(VmfViewportRenderMode)renderMode {
    self = [super initWithFrame:frame];
    if (!self) {
        return nil;
    }

    _device = device;
    _title = [title copy];
    _dimension = dimension;
    _plane = plane;
    _renderMode = renderMode;
    _sceneBounds = bounds3_empty();
    _yaw = 0.75f;
    _pitch = 0.65f;
    _distance = 1024.0f;
    _target = vec3_make(0.0f, 0.0f, 0.0f);
    _orbitLerpTarget = _target;
    _freeLookPosition = vec3_make(0.0f, 0.0f, 0.0f);
    _orthoCenter = vec3_make(0.0f, 0.0f, 0.0f);
    _orthoSize = 2048.0f;
    _primaryLightPosition = vec3_make(256.0f, 256.0f, 512.0f);
    _primaryLightColor = vec3_make(1.0f, 0.95f, 0.8f);
    _primaryLightIntensity = 1.0f;
    _primaryLightRange = 2048.0f;
    _primaryLightEnabled = NO;
    _editorTool = VmfViewportEditorToolSelect;
    _gridSize = 32.0;
    _selectionBounds = bounds3_empty();
    _creationBounds = bounds3_empty();
    _pluginDebugBounds = bounds3_empty();
    _selectedFaceEdge = VmfViewportSelectionEdgeNone;
    _activeVertexIndexCount = 0;
    _activeEdgeFirstSideIndex = SIZE_MAX;
    _activeEdgeSecondSideIndex = SIZE_MAX;
    nova_scene_data_init(&_importedSceneData);
    memset(&_fullRendererUiState, 0, sizeof(_fullRendererUiState));
    _fullRendererUiState.renderMode = 1;
    _fullRendererUiState.rasterPerformanceMode = 1;
    _fullRendererUiState.importedSceneActive = 1;

    self.wantsLayer = YES;
    self.layer.backgroundColor = CGColorCreateGenericRGB(0.055f, 0.062f, 0.075f, 1.0f);
    self.layer.cornerRadius = 8.0f;
    self.layer.borderWidth = 1.0f;
    self.layer.borderColor = CGColorCreateGenericRGB(0.20f, 0.23f, 0.28f, 1.0f);
    self.layer.masksToBounds = YES;

    _commandQueue = [_device newCommandQueue];

    NSString* executableDir = [[[NSProcessInfo processInfo] arguments][0] stringByDeletingLastPathComponent];
    NSString* metallibPath = [[NSBundle mainBundle] pathForResource:@"default" ofType:@"metallib"];
    if (metallibPath == nil) {
        metallibPath = [executableDir stringByAppendingPathComponent:@"default.metallib"];
    }
    NSError* error = nil;
    id<MTLLibrary> library = [_device newLibraryWithURL:[NSURL fileURLWithPath:metallibPath] error:&error];
    if (!library) {
        NSLog(@"Failed to load Metal library: %@", error);
        return nil;
    }

    MTLRenderPipelineDescriptor* descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction = [library newFunctionWithName:@"viewerVertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"viewerFragment"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    descriptor.colorAttachments[0].blendingEnabled = YES;
    descriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    descriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
    descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    _pipelineState = [_device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!_pipelineState) {
        NSLog(@"Failed to create pipeline: %@", error);
        return nil;
    }

    MTLDepthStencilDescriptor* depthDescriptor = [[MTLDepthStencilDescriptor alloc] init];
    depthDescriptor.depthCompareFunction = MTLCompareFunctionLessEqual;
    depthDescriptor.depthWriteEnabled = YES;
    _depthState = [_device newDepthStencilStateWithDescriptor:depthDescriptor];

    MTLDepthStencilDescriptor* disabledDepthDescriptor = [[MTLDepthStencilDescriptor alloc] init];
    disabledDepthDescriptor.depthCompareFunction = MTLCompareFunctionAlways;
    disabledDepthDescriptor.depthWriteEnabled = NO;
    _disabledDepthState = [_device newDepthStencilStateWithDescriptor:disabledDepthDescriptor];

    MTLDepthStencilDescriptor* readOnlyDepthDescriptor = [[MTLDepthStencilDescriptor alloc] init];
    readOnlyDepthDescriptor.depthCompareFunction = MTLCompareFunctionLessEqual;
    readOnlyDepthDescriptor.depthWriteEnabled = NO;
    _readOnlyDepthState = [_device newDepthStencilStateWithDescriptor:readOnlyDepthDescriptor];

    MTLSamplerDescriptor* samplerDesc = [[MTLSamplerDescriptor alloc] init];
    samplerDesc.sAddressMode = MTLSamplerAddressModeRepeat;
    samplerDesc.tAddressMode = MTLSamplerAddressModeRepeat;
    samplerDesc.minFilter = MTLSamplerMinMagFilterLinear;
    samplerDesc.magFilter = MTLSamplerMinMagFilterLinear;
    samplerDesc.mipFilter = MTLSamplerMipFilterLinear;
    samplerDesc.maxAnisotropy = 4;
    if (@available(macOS 11.0, *)) {
        samplerDesc.supportArgumentBuffers = YES;
    }
    _samplerState = [_device newSamplerStateWithDescriptor:samplerDesc];
    _textureCache = [NSMutableDictionary dictionary];
    _textureDataCache = [NSMutableDictionary dictionary];
    _textureMissLogTimes = [NSMutableDictionary dictionary];
    _previewBakedLightmaps = [NSMutableDictionary dictionary];
    _previewBakeBrushResolutions = [NSMutableDictionary dictionary];
    _previewBakeBrushStats = [NSMutableDictionary dictionary];
    _previewBakedDebugTextures = [NSMutableDictionary dictionary];
    _previewBakeDebugSelectedKey = @"";
    _previewBakeDebugWindowOpen = YES;
    _previewBakeDebugExposure = kPreviewBakeDebugExposureDefault;
    _previewBakeRtSamplesPerTexel = kPreviewBakeRtSamplesPerTexelDefault;
    _previewBakeTargetSamplesPerTexel = kPreviewBakeTargetSamplesPerTexelDefault;
    _previewBakeBounceCount = kPreviewBakeBounceCountDefault;
    _previewBakeDensity = kPreviewBakeDensityDefault;
    _previewBakeAccumulatedSamplesPerTexel = 0u;
    _previewBakeDisplayMode = kPreviewBakeDisplayModeCombined;
    _previewBakePauseRequested = NO;
    _previewBakeCancelRequested = NO;
    _previewBakeInProgress = NO;
    _previewBakedLightingEnabled = NO;
    _fullRendererUiState.previewBakeLightingEnabled = 0;
    _fullRendererUiState.previewBakeDisplayMode = kPreviewBakeDisplayModeCombined;
    _meshRevision = 1u;

    NovaToolMetalEditorViewportCreateInfo rendererCreateInfo = {
        .device = (__bridge void*)_device,
        .shaderLibraryPath = metallibPath.UTF8String,
        .colorPixelFormat = MTLPixelFormatBGRA8Unorm,
        .depthPixelFormat = MTLPixelFormatDepth32Float,
        .resolveTexture = viewport_resolve_texture,
        .textureUserData = (__bridge void*)self,
    };
    char rendererError[512] = {0};
    if (!nova_tool_metal_editor_viewport_renderer_initialize(&rendererCreateInfo, &_metalRenderer, rendererError, sizeof(rendererError))) {
        NSLog(@"Failed to create shared Metal viewport renderer: %s", rendererError);
        return nil;
    }

    [self buildUI];
    if (self.dimension == VmfViewportDimension3D && self.renderMode == VmfViewportRenderModeShaded) {
        [self initializeHeavyRenderer];
    }
    [self refreshChrome];
    return self;
}

- (BOOL)initializeHeavyRenderer {
    if (self.fullRendererInitialized || self.metalView == nil || self.metalView.layer == nil) {
        return self.fullRendererInitialized;
    }

    char errorBuffer[512] = {0};
    if (!nova_tool_metal_context_initialize_for_layer(&_fullMetalContext,
                                                      (__bridge void*)self.metalView.layer,
                                                      (__bridge void*)self.device,
                                                      (__bridge void*)self.commandQueue,
                                                      errorBuffer,
                                                      sizeof(errorBuffer))) {
        NSLog(@"Failed to initialize embedded Metal context: %s", errorBuffer);
        return NO;
    }

    NovaToolMetalRendererCreateInfo createInfo = {
        .context = &_fullMetalContext,
        .window = NULL,
        .buildUi = NULL,
        .buildUiUserData = NULL,
        .encodeOverlay = viewport_encode_overlay,
        .overlayUserData = (__bridge void*)self,
        .initialDrawableWidth = (uint32_t)MAX(1.0, self.metalView.drawableSize.width),
        .initialDrawableHeight = (uint32_t)MAX(1.0, self.metalView.drawableSize.height),
        .frameOverlap = 3u,
        .maxDrawCount = UI_MAX_SCENE_OBJECTS,
        .clusterMaxCount = 65536u,
        .clusterLightWords = 16u,
    };
    if (!nova_tool_metal_renderer_initialize(&createInfo, &_fullMetalRenderer, errorBuffer, sizeof(errorBuffer))) {
        NSLog(@"Failed to initialize full Metal renderer: %s", errorBuffer);
        nova_tool_metal_context_shutdown(&_fullMetalContext);
        memset(&_fullMetalContext, 0, sizeof(_fullMetalContext));
        return NO;
    }
    self.fullRendererInitialized = YES;
    self.fullRendererFrameIndex = 0u;
    return YES;
}

- (nullable id<MTLComputePipelineState>)hwrtBakePipelineState {
    if (self.hwrtBakePipeline != nil) {
        return self.hwrtBakePipeline;
    }

    NSError* error = nil;
    id<MTLLibrary> library = nil;
    NSString* path = [[NSBundle mainBundle] pathForResource:@"pathtrace.comp" ofType:@"metallib" inDirectory:@"shaders/metal"];
    if (path == nil) {
        NSString* executableDir = [[[NSProcessInfo processInfo] arguments][0] stringByDeletingLastPathComponent];
        path = [executableDir stringByAppendingPathComponent:@"shaders/metal/pathtrace.comp.metallib"];
    }

    library = [self.device newLibraryWithURL:[NSURL fileURLWithPath:path] error:&error];
    if (library == nil) {
        NSLog(@"[lighting] failed to load HWRT bake metallib %@: %@", path, error);
        return nil;
    }

    id<MTLFunction> function = [library newFunctionWithName:@"pathtrace_lightmap_bake_main"];
    if (function == nil) {
        NSLog(@"[lighting] HWRT bake function pathtrace_lightmap_bake_main not found in %@", path);
        return nil;
    }

    self.hwrtBakePipeline = [self.device newComputePipelineStateWithFunction:function error:&error];
    if (self.hwrtBakePipeline == nil) {
        NSLog(@"[lighting] failed to create HWRT bake pipeline: %@", error);
    }
    return self.hwrtBakePipeline;
}

- (void)setSceneWorld:(NovaSceneWorld*)sceneWorld {
    _sceneWorld = sceneWorld;
    if (self.cpuVertices != NULL && self.faceRanges != NULL && self.vertexCount > 0 && self.faceRangeCount > 0) {
        ViewerMesh mesh = {
            .vertices = self.cpuVertices,
            .vertexCount = self.vertexCount,
            .faceRanges = self.faceRanges,
            .faceRangeCount = self.faceRangeCount,
        };
        [self syncHeavyRendererSceneFromMesh:&mesh];
    }
}

- (void)buildUI {
    self.headerView = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    self.headerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerView.material = NSVisualEffectMaterialHUDWindow;
    self.headerView.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    self.headerView.state = NSVisualEffectStateActive;

    self.titleLabel = [NSTextField labelWithString:self.title];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightSemibold];
    self.titleLabel.textColor = [NSColor colorWithWhite:0.92 alpha:1.0];

    self.modeLabel = [NSTextField labelWithString:@""];
    self.modeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.modeLabel.font = [NSFont monospacedSystemFontOfSize:10.0 weight:NSFontWeightMedium];
    self.modeLabel.textColor = [NSColor colorWithWhite:0.76 alpha:1.0];
    self.modeLabel.alignment = NSTextAlignmentRight;

    [self.headerView addSubview:self.titleLabel];
    [self.headerView addSubview:self.modeLabel];

    ViewportMetalView* metalView = [[ViewportMetalView alloc] initWithFrame:NSZeroRect device:self.device];
    metalView.owner = self;
    metalView.translatesAutoresizingMaskIntoConstraints = NO;
    metalView.enableSetNeedsDisplay = NO;
    metalView.paused = NO;
    metalView.preferredFramesPerSecond = 60;
    metalView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    metalView.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
    metalView.clearColor = MTLClearColorMake(0.065, 0.072, 0.085, 1.0);
    metalView.delegate = self;
    [metalView registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];
    self.metalView = metalView;

    [self addSubview:self.metalView];

    self.overlayView = [[ViewportOverlayView alloc] initWithFrame:NSZeroRect];
    self.overlayView.owner = self;
    self.overlayView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:self.overlayView];

    [self addSubview:self.headerView];

    [NSLayoutConstraint activateConstraints:@[
        [self.headerView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.headerView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.headerView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [self.headerView.heightAnchor constraintEqualToConstant:28.0],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.headerView.leadingAnchor constant:10.0],
        [self.titleLabel.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
        [self.modeLabel.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor constant:-10.0],
        [self.modeLabel.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
        [self.modeLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.titleLabel.trailingAnchor constant:8.0],
        [self.metalView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.metalView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.metalView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [self.metalView.topAnchor constraintEqualToAnchor:self.headerView.bottomAnchor],
        [self.overlayView.leadingAnchor constraintEqualToAnchor:self.metalView.leadingAnchor],
        [self.overlayView.trailingAnchor constraintEqualToAnchor:self.metalView.trailingAnchor],
        [self.overlayView.topAnchor constraintEqualToAnchor:self.metalView.topAnchor],
        [self.overlayView.bottomAnchor constraintEqualToAnchor:self.metalView.bottomAnchor],
    ]];

    if (self.dimension == VmfViewportDimension3D) {
        IMGUI_CHECKVERSION();
        ImGuiContext* context = ImGui::CreateContext();
        if (context != NULL) {
            self.imguiContext = context;
            ImGui::SetCurrentContext(context);
            ImGuiIO& io = ImGui::GetIO();
            io.IniFilename = NULL;
            io.LogFilename = NULL;
            io.ConfigFlags |= ImGuiConfigFlags_NoMouseCursorChange;
            if (!ImGui_ImplOSX_Init(self.metalView) || !ImGui_ImplMetal_Init(self.device)) {
                ImGui_ImplMetal_Shutdown();
                ImGui_ImplOSX_Shutdown();
                ImGui::DestroyContext(context);
                self.imguiContext = NULL;
            }
        }
    }
}

- (BOOL)gizmoConsumesPrimaryMouse {
    return self.dimension == VmfViewportDimension3D && (self.gizmoHovered || self.gizmoInteractionActive);
}

- (BOOL)encodeGizmoOverlayOnCommandBuffer:(id<MTLCommandBuffer>)commandBuffer drawable:(id<CAMetalDrawable>)drawable errorMessage:(char*)errorMessage capacity:(size_t)errorMessageCapacity {
    if (self.imguiContext == NULL || self.dimension != VmfViewportDimension3D || drawable == nil) {
        self.gizmoHovered = NO;
        self.gizmoInteractionActive = NO;
        return YES;
    }

    ImGui::SetCurrentContext((ImGuiContext*)self.imguiContext);
    MTLRenderPassDescriptor* uiPass = [MTLRenderPassDescriptor renderPassDescriptor];
    uiPass.colorAttachments[0].texture = drawable.texture;
    uiPass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    uiPass.colorAttachments[0].storeAction = MTLStoreActionStore;

    ImGui_ImplMetal_NewFrame(uiPass);
    ImGui_ImplOSX_NewFrame(self.metalView);
    ImGui::NewFrame();
    ImGuizmo::BeginFrame();

    BOOL shouldDrawGizmo = self.selectionVisible && self.selectionEditable && self.editorTool == VmfViewportEditorToolSelect && !self.freeLookActive;
    if (shouldDrawGizmo) {
        float viewportWidth = fmaxf((float)self.metalView.bounds.size.width, 1.0f);
        float viewportHeight = fmaxf((float)self.metalView.bounds.size.height, 1.0f);
        float aspect = viewportWidth / viewportHeight;
        Vec3 eye;
        Mat4 projection = [self projectionMatrixForAspect:aspect];
        Mat4 view = [self viewMatrixWithCameraPosition:&eye];
        float viewMatrix[16];
        float projectionMatrix[16];
        copy_mat4_to_uniform(viewMatrix, view);
        copy_mat4_to_uniform(projectionMatrix, projection);

        Bounds3 selectionBounds = self.selectionBounds;
        Vec3 selectionCenter = bounds3_center(selectionBounds);
        float objectMatrix[16] = {
            1.0f, 0.0f, 0.0f, 0.0f,
            0.0f, 1.0f, 0.0f, 0.0f,
            0.0f, 0.0f, 1.0f, 0.0f,
            selectionCenter.raw[0], selectionCenter.raw[1], selectionCenter.raw[2], 1.0f,
        };

        ImGuizmo::SetOrthographic(false);
        ImGuizmo::SetDrawlist(ImGui::GetForegroundDrawList());
        ImGuizmo::SetRect(0.0f, 0.0f, viewportWidth, viewportHeight);
        BOOL manipulated = ImGuizmo::Manipulate(viewMatrix, projectionMatrix, ImGuizmo::TRANSLATE, ImGuizmo::WORLD, objectMatrix);
        self.gizmoHovered = ImGuizmo::IsOver();
        if (manipulated && self.delegate) {
            Vec3 translatedCenter = vec3_make(objectMatrix[12], objectMatrix[13], objectMatrix[14]);
            Vec3 delta = vec3_sub(translatedCenter, selectionCenter);
            Bounds3 translatedBounds = selectionBounds;
            translatedBounds.min = vec3_add(translatedBounds.min, delta);
            translatedBounds.max = vec3_add(translatedBounds.max, delta);
            [self.delegate viewport:self updateSelectionBounds:translatedBounds commit:NO transform:VmfViewportSelectionTransformMove];
        }

        BOOL isUsing = ImGuizmo::IsUsing();
        if (!isUsing && self.gizmoInteractionActive && self.delegate) {
            [self.delegate viewport:self updateSelectionBounds:self.selectionBounds commit:YES transform:VmfViewportSelectionTransformMove];
        }
        self.gizmoInteractionActive = isUsing;
    } else {
        self.gizmoHovered = NO;
        self.gizmoInteractionActive = NO;
    }

    if (self.previewBakeDebugWindowOpen) {
        bool open = self.previewBakeDebugWindowOpen ? true : false;
        if (ImGui::Begin("Lightmap Debug", &open)) {
            ImGui::Text("Baked brush maps: %zu", (size_t)self.previewBakedLightmaps.count);
            float debugExposure = self.previewBakeDebugExposure;
            if (ImGui::SliderFloat("Debug Exposure", &debugExposure, kPreviewBakeDebugExposureMin, kPreviewBakeDebugExposureMax, "%.3fx", ImGuiSliderFlags_Logarithmic)) {
                debugExposure = fminf(kPreviewBakeDebugExposureMax, fmaxf(kPreviewBakeDebugExposureMin, debugExposure));
                self.previewBakeDebugExposure = debugExposure;
                [self.previewBakedDebugTextures removeAllObjects];
            }
            int batchSppExp = viewport_preview_bake_power_of_two_exponent(self.previewBakeRtSamplesPerTexel,
                                                                           kPreviewBakeRtSamplesPerTexelMin,
                                                                           kPreviewBakeRtSamplesPerTexelMax);
            int batchSppExpMin = viewport_preview_bake_power_of_two_exponent(kPreviewBakeRtSamplesPerTexelMin,
                                                                              kPreviewBakeRtSamplesPerTexelMin,
                                                                              kPreviewBakeRtSamplesPerTexelMax);
            int batchSppExpMax = viewport_preview_bake_power_of_two_exponent(kPreviewBakeRtSamplesPerTexelMax,
                                                                              kPreviewBakeRtSamplesPerTexelMin,
                                                                              kPreviewBakeRtSamplesPerTexelMax);
            if (ImGui::SliderInt("RT Batch Samples (2^n)", &batchSppExp, batchSppExpMin, batchSppExpMax, "%d")) {
                self.previewBakeRtSamplesPerTexel = viewport_preview_bake_power_of_two_value(batchSppExp,
                                                                                              kPreviewBakeRtSamplesPerTexelMin,
                                                                                              kPreviewBakeRtSamplesPerTexelMax);
            }
            ImGui::SameLine();
            ImGui::Text("= %u spp", self.previewBakeRtSamplesPerTexel);
            int targetSppExp = viewport_preview_bake_power_of_two_exponent(self.previewBakeTargetSamplesPerTexel,
                                                                            kPreviewBakeTargetSamplesPerTexelMin,
                                                                            kPreviewBakeTargetSamplesPerTexelMax);
            int targetSppExpMin = viewport_preview_bake_power_of_two_exponent(kPreviewBakeTargetSamplesPerTexelMin,
                                                                               kPreviewBakeTargetSamplesPerTexelMin,
                                                                               kPreviewBakeTargetSamplesPerTexelMax);
            int targetSppExpMax = viewport_preview_bake_power_of_two_exponent(kPreviewBakeTargetSamplesPerTexelMax,
                                                                               kPreviewBakeTargetSamplesPerTexelMin,
                                                                               kPreviewBakeTargetSamplesPerTexelMax);
            if (ImGui::SliderInt("Target Samples (2^n)", &targetSppExp, targetSppExpMin, targetSppExpMax, "%d")) {
                self.previewBakeTargetSamplesPerTexel = viewport_preview_bake_power_of_two_value(targetSppExp,
                                                                                                  kPreviewBakeTargetSamplesPerTexelMin,
                                                                                                  kPreviewBakeTargetSamplesPerTexelMax);
            }
            ImGui::SameLine();
            ImGui::Text("= %u spp", self.previewBakeTargetSamplesPerTexel);
            int bakeBounceCount = (int)self.previewBakeBounceCount;
            if (ImGui::SliderInt("GI Bounces", &bakeBounceCount, (int)kPreviewBakeBounceCountMin, (int)kPreviewBakeBounceCountMax, "%d")) {
                bakeBounceCount = (int)fmin((double)kPreviewBakeBounceCountMax, fmax((double)kPreviewBakeBounceCountMin, (double)bakeBounceCount));
                self.previewBakeBounceCount = (uint32_t)bakeBounceCount;
            }
            if (self.previewBakeInProgress) {
                ImGui::Text("Bake status: running (%u / %u spp, %u bounces)", self.previewBakeAccumulatedSamplesPerTexel, self.previewBakeTargetSamplesPerTexel, self.previewBakeBounceCount);
            }

            NSArray<NSString*>* keys = [[self.previewBakedLightmaps allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
            if (keys.count == 0) {
                ImGui::Text("No baked lightmaps available.");
            } else {
                if (self.previewBakeDebugSelectedKey.length == 0 || self.previewBakedLightmaps[self.previewBakeDebugSelectedKey] == nil) {
                    self.previewBakeDebugSelectedKey = keys.firstObject;
                }

                ImGui::BeginChild("LightmapBrushList", ImVec2(240.0f, 210.0f), true);
                for (NSString* key in keys) {
                    bool selected = [key isEqualToString:self.previewBakeDebugSelectedKey];
                    if (ImGui::Selectable(key.UTF8String, selected)) {
                        self.previewBakeDebugSelectedKey = key;
                    }
                }
                ImGui::EndChild();

                NSString* selectedKey = self.previewBakeDebugSelectedKey;
                if (selectedKey.length > 0) {
                    int resolution = self.previewBakeDensity;
                    resolution = (int)fmin((double)kPreviewBakeDensityMax, fmax((double)kPreviewBakeDensityMin, (double)resolution));
                    if (ImGui::SliderInt("Lightmap Density", &resolution, kPreviewBakeDensityMin, kPreviewBakeDensityMax, "%d px / unit")) {
                        self.previewBakeDensity = resolution;
                    }

                    id<MTLTexture> debugTexture = [self previewBakedDebugTextureForKey:selectedKey];
                    if (debugTexture != nil) {
                        float previewSize = 256.0f;
                        ImGui::Image((ImTextureID)(__bridge void*)debugTexture, ImVec2(previewSize, previewSize));
                        NSDictionary<NSString*, id>* info = self.previewBakedLightmaps[selectedKey];
                        ImGui::Text("%s  (%dx%d)", selectedKey.UTF8String, [info[@"width"] intValue], [info[@"height"] intValue]);
                        NSDictionary<NSString*, NSNumber*>* stats = self.previewBakeBrushStats[selectedKey];
                        if (stats != nil) {
                            ImGui::Text("Valid texels: %u", stats[@"validTexels"].unsignedIntValue);
                            ImGui::Text("Raw lum min/avg/max: %.4f / %.4f / %.4f",
                                        stats[@"rawLumMin"].floatValue,
                                        stats[@"rawLumAvg"].floatValue,
                                        stats[@"rawLumMax"].floatValue);
                            ImGui::Text("Final lum min/avg/max: %.4f / %.4f / %.4f",
                                        stats[@"finalLumMin"].floatValue,
                                        stats[@"finalLumAvg"].floatValue,
                                        stats[@"finalLumMax"].floatValue);
                        }
                    } else {
                        ImGui::Text("Preview texture unavailable for selected brush.");
                    }
                }
            }

            if (ImGui::Button("Rebake Preview")) {
                [self startPreviewLightingBake];
            }
        }
        ImGui::End();
        self.previewBakeDebugWindowOpen = open ? YES : NO;
    }

    ImGui::Render();
    if (ImGui::GetDrawData() == NULL) {
        return YES;
    }

    id<MTLRenderCommandEncoder> uiEncoder = [commandBuffer renderCommandEncoderWithDescriptor:uiPass];
    if (uiEncoder == nil) {
        if (errorMessage != NULL && errorMessageCapacity > 0u) {
            snprintf(errorMessage, errorMessageCapacity, "Failed to create viewport gizmo encoder.");
        }
        return NO;
    }
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), commandBuffer, uiEncoder);
    [uiEncoder endEncoding];
    return YES;
}

- (void)setRenderMode:(VmfViewportRenderMode)renderMode {
    _renderMode = renderMode;
    [self refreshChrome];
}

- (void)setActive:(BOOL)active {
    _active = active;
    [self refreshChrome];
}

- (void)refreshChrome {
    self.layer.borderWidth = self.active ? 2.0f : 1.0f;
    self.layer.borderColor = self.active ? CGColorCreateGenericRGB(0.86f, 0.48f, 0.18f, 1.0f) : CGColorCreateGenericRGB(0.20f, 0.23f, 0.28f, 1.0f);
    self.titleLabel.textColor = self.active ? [NSColor colorWithRed:0.97 green:0.79 blue:0.53 alpha:1.0] : [NSColor colorWithWhite:0.92 alpha:1.0];

    NSString* dimensionLabel = self.dimension == VmfViewportDimension3D ? @"3D" : @"2D";
    NSString* modeLabel = self.renderMode == VmfViewportRenderModeShaded ? @"SHADED" : @"WIRE";
    NSString* toolLabel = @"SELECT";
    if (self.editorTool == VmfViewportEditorToolVertex) {
        toolLabel = @"VERTEX";
    } else if (self.editorTool == VmfViewportEditorToolBlock) {
        toolLabel = @"BLOCK";
    } else if (self.editorTool == VmfViewportEditorToolCylinder) {
        toolLabel = @"CYLINDER";
    } else if (self.editorTool == VmfViewportEditorToolArch) {
        toolLabel = @"ARCH";
    } else if (self.editorTool == VmfViewportEditorToolClip) {
        toolLabel = self.clipModeLabel.length > 0 ? [NSString stringWithFormat:@"CLIP-%@", self.clipModeLabel] : @"CLIP";
    } else if (self.editorTool == VmfViewportEditorToolRamp) {
        toolLabel = @"RAMP";
    } else if (self.editorTool == VmfViewportEditorToolStairs) {
        toolLabel = @"STAIRS";
    }
    if (self.dimension == VmfViewportDimension3D) {
        toolLabel = self.editorTool == VmfViewportEditorToolSelect ? @"CAMERA" : toolLabel;
    }
    if (self.dimension == VmfViewportDimension2D) {
        self.modeLabel.stringValue = [NSString stringWithFormat:@"%@ %@ %@ %.0f", dimensionLabel, modeLabel, toolLabel, self.gridSize];
    } else {
        self.modeLabel.stringValue = [NSString stringWithFormat:@"%@ %@ %@", dimensionLabel, modeLabel, toolLabel];
    }
}

- (void)setEditorTool:(VmfViewportEditorTool)editorTool {
    _editorTool = editorTool;
    if (editorTool != VmfViewportEditorToolClip && self.clipGuideVisible) {
        self.clipGuideVisible = NO;
        [self.overlayView setNeedsDisplay:YES];
    }
    [self refreshChrome];
    [self.overlayView setNeedsDisplay:YES];
}

- (void)setGridSize:(CGFloat)gridSize {
    _gridSize = fmax(gridSize, 1.0);
    [self refreshChrome];
    [self.overlayView setNeedsDisplay:YES];
}

- (void)setClipModeLabel:(NSString*)clipModeLabel {
    _clipModeLabel = [clipModeLabel copy];
    [self refreshChrome];
}

- (void)setClipKeepMode:(VmfClipKeepMode)clipKeepMode {
    _clipKeepMode = clipKeepMode;
    [self.overlayView setNeedsDisplay:YES];
}

- (void)setSelectionBounds:(Bounds3)bounds visible:(BOOL)visible {
    self.selectionBounds = normalized_bounds(bounds);
    self.selectionVisible = visible;
    [self.overlayView setNeedsDisplay:YES];
}

- (void)setSelectionVertices:(const Vec3*)vertices count:(size_t)count visible:(BOOL)visible {
    free(self.selectionVertices);
    self.selectionVertices = NULL;
    self.selectionVertexCount = 0;
    if (visible && vertices && count > 0) {
        self.selectionVertices = (Vec3*)malloc(count * sizeof(Vec3));
        if (self.selectionVertices) {
            memcpy(self.selectionVertices, vertices, count * sizeof(Vec3));
            self.selectionVertexCount = count;
        }
    }
    [self.overlayView setNeedsDisplay:YES];
}

- (void)setSelectionEdges:(const VmfSolidEdge*)edges count:(size_t)count visible:(BOOL)visible {
    free(self.selectionEdges);
    self.selectionEdges = NULL;
    self.selectionEdgeCount = 0;
    if (visible && edges && count > 0) {
        self.selectionEdges = (VmfSolidEdge*)malloc(count * sizeof(VmfSolidEdge));
        if (self.selectionEdges) {
            memcpy(self.selectionEdges, edges, count * sizeof(VmfSolidEdge));
            self.selectionEdgeCount = count;
        }
    }
    [self.overlayView setNeedsDisplay:YES];
}

- (void)setSelectedFaceEdge:(VmfViewportSelectionEdge)edge {
    _selectedFaceEdge = edge;
    [self.overlayView setNeedsDisplay:YES];
}

- (void)rebuildHighlightedFaceBuffer {
    self.highlightedFaceBuffer = nil;
    self.highlightedFaceVertexCount = 0;
    if (!self.highlightedFaceVisible || !self.cpuVertices || !self.faceRanges) {
        return;
    }

    for (size_t rangeIndex = 0; rangeIndex < self.faceRangeCount; ++rangeIndex) {
        ViewerFaceRange range = self.faceRanges[rangeIndex];
        if (range.entityIndex != self.highlightedFaceEntityIndex ||
            range.solidIndex != self.highlightedFaceSolidIndex ||
            range.sideIndex != self.highlightedFaceSideIndex ||
            range.vertexCount == 0) {
            continue;
        }

        ViewerVertex* vertices = (ViewerVertex*)malloc(range.vertexCount * sizeof(ViewerVertex));
        if (!vertices) {
            return;
        }
        memcpy(vertices, self.cpuVertices + range.vertexStart, range.vertexCount * sizeof(ViewerVertex));
        for (size_t vertexIndex = 0; vertexIndex < range.vertexCount; ++vertexIndex) {
            vertices[vertexIndex].position = vec3_add(vertices[vertexIndex].position, vec3_scale(vertices[vertexIndex].normal, 0.35f));
        }
        self.highlightedFaceBuffer = viewport_create_editor_vertex_buffer(self.device, vertices, range.vertexCount);
        self.highlightedFaceVertexCount = (NSUInteger)range.vertexCount;
        free(vertices);
        return;
    }
}

- (void)rebuildSelectedFaceBuffer {
    self.selectedFaceBuffer = nil;
    self.selectedFaceVertexCount = 0;
    if (!self.selectedFaceVisible || !self.cpuVertices || !self.faceRanges) {
        return;
    }

    for (size_t rangeIndex = 0; rangeIndex < self.faceRangeCount; ++rangeIndex) {
        ViewerFaceRange range = self.faceRanges[rangeIndex];
        if (range.entityIndex != self.selectedFaceEntityIndex ||
            range.solidIndex != self.selectedFaceSolidIndex ||
            range.sideIndex != self.selectedFaceSideIndex ||
            range.vertexCount == 0) {
            continue;
        }

        ViewerVertex* vertices = (ViewerVertex*)malloc(range.vertexCount * sizeof(ViewerVertex));
        if (!vertices) {
            return;
        }
        memcpy(vertices, self.cpuVertices + range.vertexStart, range.vertexCount * sizeof(ViewerVertex));
        for (size_t vertexIndex = 0; vertexIndex < range.vertexCount; ++vertexIndex) {
            vertices[vertexIndex].position = vec3_add(vertices[vertexIndex].position, vec3_scale(vertices[vertexIndex].normal, 0.6f));
        }
        self.selectedFaceBuffer = viewport_create_editor_vertex_buffer(self.device, vertices, range.vertexCount);
        self.selectedFaceVertexCount = (NSUInteger)range.vertexCount;
        free(vertices);
        return;
    }
}

- (void)setSelectedFaceHighlightEntityIndex:(size_t)entityIndex solidIndex:(size_t)solidIndex sideIndex:(size_t)sideIndex visible:(BOOL)visible {
    self.selectedFaceVisible = visible;
    self.selectedFaceEntityIndex = entityIndex;
    self.selectedFaceSolidIndex = solidIndex;
    self.selectedFaceSideIndex = sideIndex;
    [self rebuildSelectedFaceBuffer];
    [self.overlayView setNeedsDisplay:YES];
}

- (void)setHighlightedFaceEntityIndex:(size_t)entityIndex solidIndex:(size_t)solidIndex sideIndex:(size_t)sideIndex visible:(BOOL)visible {
    self.highlightedFaceVisible = visible;
    self.highlightedFaceEntityIndex = entityIndex;
    self.highlightedFaceSolidIndex = solidIndex;
    self.highlightedFaceSideIndex = sideIndex;
    [self rebuildHighlightedFaceBuffer];
    [self.overlayView setNeedsDisplay:YES];
}

- (void)setCreationBounds:(Bounds3)bounds visible:(BOOL)visible {
    self.creationBounds = normalized_bounds(bounds);
    self.creationVisible = visible;
    [self.overlayView setNeedsDisplay:YES];
}

- (void)setPluginDebugBounds:(Bounds3)bounds visible:(BOOL)visible {
    self.pluginDebugBounds = normalized_bounds(bounds);
    self.pluginDebugVisible = visible;
    [self.overlayView setNeedsDisplay:YES];
}

- (void)setVertexEditIsInvalid:(BOOL)invalid {
    if (_vertexEditIsInvalid == invalid) {
        return;
    }
    _vertexEditIsInvalid = invalid;
    [self.overlayView setNeedsDisplay:YES];
}

- (void)setVertexEditPreviewEdges:(const ViewerVertex*)vertices count:(size_t)count {
    if (!vertices || count == 0) {
        self.vertexEditPreviewBuffer = nil;
        self.vertexEditPreviewVertexCount = 0;
        return;
    }
    self.vertexEditPreviewBuffer = viewport_create_editor_vertex_buffer(self.device, vertices, count);
    self.vertexEditPreviewVertexCount = count;
}

- (void)clearVertexEditPreview {
    self.vertexEditPreviewBuffer = nil;
    self.vertexEditPreviewVertexCount = 0;
}

- (void)clearEditorOverlay {
    self.selectionVisible = NO;
    free(self.selectionVertices);
    self.selectionVertices = NULL;
    self.selectionVertexCount = 0;
    free(self.selectionEdges);
    self.selectionEdges = NULL;
    self.selectionEdgeCount = 0;
    self.selectedFaceEdge = VmfViewportSelectionEdgeNone;
    self.selectedFaceVisible = NO;
    [self rebuildSelectedFaceBuffer];
    self.highlightedFaceVisible = NO;
    [self rebuildHighlightedFaceBuffer];
    self.creationVisible = NO;
    self.pluginDebugVisible = NO;
    self.clipGuideVisible = NO;
    [self.overlayView setNeedsDisplay:YES];
}

- (BOOL)hasPendingClipLine {
    return self.clipGuideVisible;
}

- (BOOL)commitPendingClipLine {
    if (!self.clipGuideVisible || self.editorTool != VmfViewportEditorToolClip) {
        return NO;
    }
    if (vec3_length(vec3_sub(self.clipGuideEnd, self.clipGuideStart)) < (float)self.gridSize || !self.delegate) {
        return NO;
    }
    [self.delegate viewport:self clipSelectionFrom:self.clipGuideStart to:self.clipGuideEnd];
    self.clipGuideVisible = NO;
    [self.overlayView setNeedsDisplay:YES];
    return YES;
}

// ---------------------------------------------------------------------------
// Texture loading
// ---------------------------------------------------------------------------

- (nullable NSString*)texturePathForMaterial:(NSString*)material {
    if (!self.textureDirectory || material.length == 0) {
        return nil;
    }

    NSString* normalized = material.lowercaseString;
    if ([normalized isEqualToString:@"grid"]) {
        normalized = @"dev_grid";
    }
    return [[self.textureDirectory stringByAppendingPathComponent:normalized]
            stringByAppendingPathExtension:@"png"];
}

- (nullable NSDictionary<NSString*, id>*)loadTextureDataAtPath:(NSString*)path {
    NSImage* image = [[NSImage alloc] initWithContentsOfFile:path];
    if (!image) {
        return nil;
    }

    NSRect proposedRect = NSZeroRect;
    CGImageRef cgImage = [image CGImageForProposedRect:&proposedRect context:nil hints:nil];
    if (!cgImage) {
        return nil;
    }

    size_t imgW = CGImageGetWidth(cgImage);
    size_t imgH = CGImageGetHeight(cgImage);
    if (imgW == 0u || imgH == 0u) {
        return nil;
    }

    size_t bytesPerRow = imgW * 4u;
    NSMutableData* pixels = [NSMutableData dataWithLength:bytesPerRow * imgH];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        pixels.mutableBytes,
        imgW,
        imgH,
        8,
        bytesPerRow,
        cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) {
        return nil;
    }

    CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)imgW, (CGFloat)imgH), cgImage);
    CGContextRelease(ctx);
    return @{
        @"width": @(imgW),
        @"height": @(imgH),
        @"rgba8": pixels,
    };
}

- (nullable id<MTLTexture>)loadTextureAtPath:(NSString*)path {
    NSURL* url = [NSURL fileURLWithPath:path];
    MTKTextureLoader* loader = [[MTKTextureLoader alloc] initWithDevice:self.device];
    NSError* error = nil;
    NSDictionary* options = @{
        MTKTextureLoaderOptionSRGB: @NO,
        MTKTextureLoaderOptionGenerateMipmaps: @YES,
        MTKTextureLoaderOptionTextureUsage: @(MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget),
    };
    id<MTLTexture> tex = [loader newTextureWithContentsOfURL:url options:options error:&error];
    if (tex) {
        return tex;
    }

    // Fallback: use NSImage + CGBitmapContext to handle indexed, palette,
    // 4-bit, or any other format that MTKTextureLoader refuses.
    NSImage* image = [[NSImage alloc] initWithContentsOfFile:path];
    if (!image) {
        NSLog(@"[texture] failed to load %@: %@", path, error.localizedDescription);
        return nil;
    }
    NSRect proposedRect = NSZeroRect;
    CGImageRef cgImage = [image CGImageForProposedRect:&proposedRect context:nil hints:nil];
    if (!cgImage) return nil;

    size_t imgW = CGImageGetWidth(cgImage);
    size_t imgH = CGImageGetHeight(cgImage);
    if (imgW == 0 || imgH == 0) return nil;

    size_t bytesPerRow = imgW * 4;
    NSMutableData* pixels = [NSMutableData dataWithLength:bytesPerRow * imgH];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        pixels.mutableBytes, imgW, imgH, 8, bytesPerRow, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;
    CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)imgW, (CGFloat)imgH), cgImage);
    CGContextRelease(ctx);

    MTLTextureDescriptor* desc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:imgW height:imgH mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> result = [self.device newTextureWithDescriptor:desc];
    if (!result) return nil;
    [result replaceRegion:MTLRegionMake2D(0, 0, imgW, imgH)
              mipmapLevel:0
              withBytes:pixels.bytes
           bytesPerRow:bytesPerRow];
    NSLog(@"[texture] fallback-loaded %@ via NSImage (%zux%zu)", path.lastPathComponent, imgW, imgH);
    return result;
}

- (nullable id<MTLTexture>)cachedTextureForMaterial:(NSString*)material {
    NSString* normalized = material.lowercaseString;
    id entry = self.textureCache[normalized];
    if (entry != nil) {
        return (entry == (id)NSNull.null) ? nil : (id<MTLTexture>)entry;
    }
    // Not yet looked up — search disk
    NSString* fullPath = [self texturePathForMaterial:normalized];
    if (!fullPath) {
        self.textureCache[normalized] = NSNull.null;
        return nil;
    }
    if ([[NSFileManager defaultManager] fileExistsAtPath:fullPath]) {
        id<MTLTexture> tex = [self loadTextureAtPath:fullPath];
        if (tex) {
            NSLog(@"[texture] loaded %@ (%lux%lu)", fullPath, (unsigned long)tex.width, (unsigned long)tex.height);
            self.textureCache[normalized] = tex;
            return tex;
        }
        if ([self shouldLogTextureMissAtPath:fullPath]) {
            NSLog(@"[texture] MTKTextureLoader failed for %@", fullPath);
        }
    } else {
        if ([self shouldLogTextureMissAtPath:fullPath]) {
            NSLog(@"[texture] file not found: %@", fullPath);
        }
    }
    self.textureCache[normalized] = NSNull.null;
    return nil;
}

- (BOOL)shouldLogTextureMissAtPath:(NSString*)fullPath {
    if (fullPath.length == 0) {
        return YES;
    }

    CFTimeInterval now = CACurrentMediaTime();
    NSNumber* lastTimeValue = self.textureMissLogTimes[fullPath];
    if (lastTimeValue != nil && (now - lastTimeValue.doubleValue) < kTextureMissLogThrottleSeconds) {
        return NO;
    }

    self.textureMissLogTimes[fullPath] = @(now);
    if (self.textureMissLogTimes.count > 8192u) {
        [self.textureMissLogTimes removeAllObjects];
    }
    return YES;
}

- (nullable NSDictionary<NSString*, id>*)cachedTextureDataForMaterial:(NSString*)material {
    NSString* normalized = material.lowercaseString;
    id entry = self.textureDataCache[normalized];
    if (entry != nil) {
        return entry == (id)NSNull.null ? nil : (NSDictionary<NSString*, id>*)entry;
    }

    NSString* fullPath = [self texturePathForMaterial:normalized];
    if (!fullPath) {
        self.textureDataCache[normalized] = NSNull.null;
        return nil;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:fullPath]) {
        self.textureDataCache[normalized] = NSNull.null;
        return nil;
    }

    NSDictionary<NSString*, id>* textureInfo = [self loadTextureDataAtPath:fullPath];
    self.textureDataCache[normalized] = textureInfo != nil ? textureInfo : (id)NSNull.null;
    return textureInfo;
}

- (nullable id<MTLTexture>)previewBakedDebugTextureForKey:(NSString*)key {
    id cached = self.previewBakedDebugTextures[key];
    if (cached != nil) {
        return cached == (id)NSNull.null ? nil : (id<MTLTexture>)cached;
    }

    NSDictionary<NSString*, id>* info = self.previewBakedLightmaps[key];
    if (info == nil) {
        self.previewBakedDebugTextures[key] = NSNull.null;
        return nil;
    }

    NSData* rgba8 = info[@"rgba8"];
    NSData* rgba32f = info[@"rgba32f"];
    int width = [info[@"width"] intValue];
    int height = [info[@"height"] intValue];
    if ((rgba8 == nil && rgba32f == nil) || width <= 0 || height <= 0) {
        self.previewBakedDebugTextures[key] = NSNull.null;
        return nil;
    }

    MTLTextureDescriptor* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                           width:(NSUInteger)width
                                                                                          height:(NSUInteger)height
                                                                                       mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [self.device newTextureWithDescriptor:descriptor];
    if (texture == nil) {
        self.previewBakedDebugTextures[key] = NSNull.null;
        return nil;
    }

    MTLRegion region = MTLRegionMake2D(0, 0, (NSUInteger)width, (NSUInteger)height);
    if (rgba32f != nil && rgba32f.length >= (NSUInteger)width * (NSUInteger)height * sizeof(float) * 4u) {
        NSMutableData* debugPixels = [NSMutableData dataWithLength:(NSUInteger)width * (NSUInteger)height * 4u];
        if (debugPixels.length == (NSUInteger)width * (NSUInteger)height * 4u) {
            const float* hdr = (const float*)rgba32f.bytes;
            uint8_t* ldr = (uint8_t*)debugPixels.mutableBytes;
            float exposure = fmaxf(self.previewBakeDebugExposure, 0.0f);
            size_t texelCount = (size_t)width * (size_t)height;
            for (size_t texelIndex = 0; texelIndex < texelCount; ++texelIndex) {
                float litR = fmaxf(hdr[texelIndex * 4u + 0u], 0.0f) * exposure;
                float litG = fmaxf(hdr[texelIndex * 4u + 1u], 0.0f) * exposure;
                float litB = fmaxf(hdr[texelIndex * 4u + 2u], 0.0f) * exposure;
                float mappedR = litR / (1.0f + litR);
                float mappedG = litG / (1.0f + litG);
                float mappedB = litB / (1.0f + litB);
                ldr[texelIndex * 4u + 0u] = (uint8_t)lrintf(fminf(mappedR, 1.0f) * 255.0f);
                ldr[texelIndex * 4u + 1u] = (uint8_t)lrintf(fminf(mappedG, 1.0f) * 255.0f);
                ldr[texelIndex * 4u + 2u] = (uint8_t)lrintf(fminf(mappedB, 1.0f) * 255.0f);
                ldr[texelIndex * 4u + 3u] = 255u;
            }
            [texture replaceRegion:region mipmapLevel:0 withBytes:debugPixels.bytes bytesPerRow:(NSUInteger)width * 4u];
        } else {
            self.previewBakedDebugTextures[key] = NSNull.null;
            return nil;
        }
    } else {
        [texture replaceRegion:region mipmapLevel:0 withBytes:rgba8.bytes bytesPerRow:(NSUInteger)width * 4u];
    }
    self.previewBakedDebugTextures[key] = texture;
    return texture;
}

- (void)clearTextureMissCache {
    NSArray* keys = self.textureCache.allKeys;
    for (NSString* key in keys) {
        if (self.textureCache[key] == (id)NSNull.null) {
            [self.textureCache removeObjectForKey:key];
        }
    }
    keys = self.textureDataCache.allKeys;
    for (NSString* key in keys) {
        if (self.textureDataCache[key] == (id)NSNull.null) {
            [self.textureDataCache removeObjectForKey:key];
        }
    }
    [self.textureMissLogTimes removeAllObjects];
}

- (void)clearTextureCache {
    [self.textureCache removeAllObjects];
    [self.textureDataCache removeAllObjects];
    [self.textureMissLogTimes removeAllObjects];
}

- (void)setTextureDirectory:(NSString*)path {
    if ([path isEqualToString:_textureDirectory]) {
        return;
    }
    _textureDirectory = [path copy];
    // Clear only "not found" entries so previously loaded textures survive
    NSArray* keys = self.textureCache.allKeys;
    for (NSString* key in keys) {
        if (self.textureCache[key] == (id)NSNull.null) {
            [self.textureCache removeObjectForKey:key];
        }
    }
    keys = self.textureDataCache.allKeys;
    for (NSString* key in keys) {
        if (self.textureDataCache[key] == (id)NSNull.null) {
            [self.textureDataCache removeObjectForKey:key];
        }
    }
    [self.textureMissLogTimes removeAllObjects];
}

- (void)updateMesh:(const ViewerMesh*)mesh {
    free(self.cpuVertices);
    self.cpuVertices = NULL;
    free(self.cpuEdgeVertices);
    self.cpuEdgeVertices = NULL;
    free(self.baseVertexColors);
    self.baseVertexColors = NULL;
    free(self.faceRanges);
    self.faceRanges = NULL;
    self.faceRangeCount = 0;
    self.previewBakeInProgress = NO;
    self.previewBakePauseRequested = NO;
    self.previewBakeCancelRequested = NO;
    self.previewBakeAccumulatedSamplesPerTexel = 0u;
    self.previewBakedLightingEnabled = NO;
    _fullRendererUiState.previewBakeLightingEnabled = 0;
    [self.previewBakedLightmaps removeAllObjects];
    [self.previewBakedDebugTextures removeAllObjects];
    self.previewBakeDebugSelectedKey = @"";
    self.meshRevision += 1u;
    if (!mesh || (mesh->vertexCount == 0 && mesh->edgeVertexCount == 0)) {
        self.vertexBuffer = nil;
        self.edgeVertexBuffer = nil;
        self.selectedFaceBuffer = nil;
        self.highlightedFaceBuffer = nil;
        self.vertexCount = 0;
        self.edgeVertexCount = 0;
        self.selectedFaceVertexCount = 0;
        self.highlightedFaceVertexCount = 0;
        self.sceneBounds = bounds3_empty();
        nova_tool_metal_editor_viewport_renderer_set_mesh(&_metalRenderer, NULL, 0, NULL, 0, NULL, 0);
        return;
    }

    NSUInteger length = (NSUInteger)(mesh->vertexCount * sizeof(ViewerVertex));
    self.vertexBuffer = [self.device newBufferWithBytes:mesh->vertices length:length options:MTLResourceStorageModeShared];
    if (mesh->edgeVertexCount > 0) {
        NSUInteger edgeLength = (NSUInteger)(mesh->edgeVertexCount * sizeof(ViewerVertex));
        self.edgeVertexBuffer = [self.device newBufferWithBytes:mesh->edgeVertices length:edgeLength options:MTLResourceStorageModeShared];
    } else {
        self.edgeVertexBuffer = nil;
    }
    self.vertexCount = mesh->vertexCount;
    self.edgeVertexCount = (NSUInteger)mesh->edgeVertexCount;
    self.cpuVertices = (ViewerVertex*)malloc(mesh->vertexCount * sizeof(ViewerVertex));
    if (self.cpuVertices) {
        memcpy(self.cpuVertices, mesh->vertices, mesh->vertexCount * sizeof(ViewerVertex));
    }
    if (mesh->edgeVertexCount > 0u) {
        self.cpuEdgeVertices = (ViewerVertex*)malloc(mesh->edgeVertexCount * sizeof(ViewerVertex));
        if (self.cpuEdgeVertices != NULL) {
            memcpy(self.cpuEdgeVertices, mesh->edgeVertices, mesh->edgeVertexCount * sizeof(ViewerVertex));
        }
    }
    self.baseVertexColors = (Vec3*)malloc(mesh->vertexCount * sizeof(Vec3));
    if (self.baseVertexColors != NULL) {
        for (size_t index = 0; index < mesh->vertexCount; ++index) {
            self.baseVertexColors[index] = mesh->vertices[index].color;
        }
    }
    if (mesh->faceRangeCount > 0) {
        self.faceRanges = (ViewerFaceRange*)malloc(mesh->faceRangeCount * sizeof(ViewerFaceRange));
        if (self.faceRanges) {
            memcpy(self.faceRanges, mesh->faceRanges, mesh->faceRangeCount * sizeof(ViewerFaceRange));
            self.faceRangeCount = mesh->faceRangeCount;
        }
    }
    self.sceneBounds = mesh->bounds;
    NovaToolMetalEditorVertex* convertedVertices = viewport_create_editor_vertex_array(mesh->vertices, mesh->vertexCount);
    NovaToolMetalEditorVertex* convertedEdgeVertices = viewport_create_editor_vertex_array(mesh->edgeVertices, mesh->edgeVertexCount);
    NovaToolMetalEditorFaceRange* convertedFaceRanges = viewport_create_editor_face_range_array(mesh->faceRanges, mesh->faceRangeCount);
    nova_tool_metal_editor_viewport_renderer_set_mesh(&_metalRenderer,
                                                      convertedVertices,
                                                      mesh->vertexCount,
                                                      convertedEdgeVertices,
                                                      mesh->edgeVertexCount,
                                                      convertedFaceRanges,
                                                      mesh->faceRangeCount);
    free(convertedVertices);
    free(convertedEdgeVertices);
    free(convertedFaceRanges);
    [self syncHeavyRendererSceneFromMesh:mesh];
    [self rebuildSelectedFaceBuffer];
    [self rebuildHighlightedFaceBuffer];
}

- (void)applyBakedVertexLighting:(const Vec3*)bakedLighting count:(size_t)count {
    if (bakedLighting == NULL || self.cpuVertices == NULL || count != self.vertexCount) {
        return;
    }

    for (size_t index = 0; index < count; ++index) {
        self.cpuVertices[index].color = bakedLighting[index];
    }

    self.vertexBuffer = [self.device newBufferWithBytes:self.cpuVertices
                                                 length:(NSUInteger)(count * sizeof(ViewerVertex))
                                                options:MTLResourceStorageModeShared];

    {
        NovaToolMetalEditorVertex* convertedVertices = viewport_create_editor_vertex_array(self.cpuVertices, count);
        NovaToolMetalEditorVertex* convertedEdgeVertices = viewport_create_editor_vertex_array(self.cpuEdgeVertices, self.edgeVertexCount);
        NovaToolMetalEditorFaceRange* convertedFaceRanges = viewport_create_editor_face_range_array(self.faceRanges, self.faceRangeCount);
        nova_tool_metal_editor_viewport_renderer_set_mesh(&_metalRenderer,
                                                          convertedVertices,
                                                          count,
                                                          convertedEdgeVertices,
                                                          self.edgeVertexCount,
                                                          convertedFaceRanges,
                                                          self.faceRangeCount);
        free(convertedVertices);
        free(convertedEdgeVertices);
        free(convertedFaceRanges);
    }

    {
        ViewerMesh bakedMesh = {0};
        bakedMesh.vertices = self.cpuVertices;
        bakedMesh.vertexCount = count;
        bakedMesh.edgeVertices = self.cpuEdgeVertices;
        bakedMesh.edgeVertexCount = self.edgeVertexCount;
        bakedMesh.faceRanges = self.faceRanges;
        bakedMesh.faceRangeCount = self.faceRangeCount;
        bakedMesh.bounds = self.sceneBounds;
        [self syncHeavyRendererSceneFromMesh:&bakedMesh];
    }

    self.previewBakedLightingEnabled = YES;
    _fullRendererUiState.previewBakeLightingEnabled = 1;
    [self.metalView setNeedsDisplay:YES];
}

- (void)startPreviewLightingBake {
    size_t vertexCount;
    size_t faceRangeCount;
    ViewerVertex* verticesSnapshot;
    ViewerFaceRange* faceRangesSnapshot;
    Vec3* baseColorSnapshot;
    Vec3 lightPosition;
    Vec3 lightColor;
    float lightIntensity;
    float lightRange;
    BOOL lightEnabled;
    uint64_t revision;
    UiGizmoState uiStateSnapshot;
    uint32_t targetSamplesPerTexel;

    if (self.previewBakeInProgress ||
        self.dimension != VmfViewportDimension3D ||
        self.cpuVertices == NULL ||
        self.vertexCount == 0 ||
        self.baseVertexColors == NULL ||
        self.faceRanges == NULL ||
        self.faceRangeCount == 0) {
        return;
    }

    vertexCount = self.vertexCount;
    faceRangeCount = self.faceRangeCount;
    verticesSnapshot = (ViewerVertex*)malloc(vertexCount * sizeof(ViewerVertex));
    baseColorSnapshot = (Vec3*)malloc(vertexCount * sizeof(Vec3));
    faceRangesSnapshot = (ViewerFaceRange*)malloc(faceRangeCount * sizeof(ViewerFaceRange));
    if (verticesSnapshot == NULL || baseColorSnapshot == NULL || faceRangesSnapshot == NULL) {
        free(verticesSnapshot);
        free(baseColorSnapshot);
        free(faceRangesSnapshot);
        NSLog(@"[lighting] preview bake failed to allocate buffers");
        return;
    }

    memcpy(verticesSnapshot, self.cpuVertices, vertexCount * sizeof(ViewerVertex));
    memcpy(baseColorSnapshot, self.baseVertexColors, vertexCount * sizeof(Vec3));
    memcpy(faceRangesSnapshot, self.faceRanges, faceRangeCount * sizeof(ViewerFaceRange));
    viewport_select_preview_bake_light(&_fullRendererUiState,
                                       self.primaryLightPosition,
                                       self.primaryLightColor,
                                       self.primaryLightIntensity,
                                       self.primaryLightRange,
                                       self.primaryLightEnabled,
                                       &lightPosition,
                                       &lightColor,
                                       &lightIntensity,
                                       &lightRange,
                                       &lightEnabled);
    uiStateSnapshot = _fullRendererUiState;
    targetSamplesPerTexel = self.previewBakeTargetSamplesPerTexel;
    revision = self.meshRevision;

    self.previewBakeInProgress = YES;
    self.previewBakeAccumulatedSamplesPerTexel = 0u;
    NSLog(@"[lighting] HWRT preview bake started (%zu vertices, %zu faces, texel tracing + 1-bounce GI)", vertexCount, faceRangeCount);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableDictionary<NSString*, NSNumber*>* brushSlotByKey = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString*, NSNumber*>* brushUvMinUByKey = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString*, NSNumber*>* brushUvMinVByKey = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString*, NSNumber*>* brushUvMaxUByKey = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString*, NSNumber*>* brushUvMaxVByKey = [NSMutableDictionary dictionary];
        NSMutableArray<NSMutableData*>* brushAccums = [NSMutableArray array];
        NSMutableArray<NSString*>* brushKeys = [NSMutableArray array];
        NSMutableArray<NSNumber*>* brushWidths = [NSMutableArray array];
        NSMutableArray<NSNumber*>* brushHeights = [NSMutableArray array];
        NSMutableDictionary<NSString*, NSDictionary<NSString*, id>*>* bakedMaps = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString*, NSDictionary<NSString*, NSNumber*>*>* bakedStats = [NSMutableDictionary dictionary];
        NSMutableArray<NSMutableData*>* bakeTexelDatas = [NSMutableArray array];
        NSMutableArray<NSNumber*>* bakeValidTexelCounts = [NSMutableArray array];
        NSMutableArray<NSMutableData*>* bakeAccumulatedLighting = [NSMutableArray array];
        NSMutableArray<NSMutableDictionary<NSString*, id>*>* lightmapPages = nil;
        NSMutableArray<NSString*>* lightmapPageKeys = [NSMutableArray array];
        NSMutableArray<NSNumber*>* lightmapPageWidths = [NSMutableArray array];
        NSMutableArray<NSNumber*>* lightmapPageHeights = [NSMutableArray array];
        NSMutableArray<NSMutableData*>* lightmapPageTexelDatas = [NSMutableArray array];
        NSMutableArray<NSNumber*>* lightmapPageValidTexelCounts = [NSMutableArray array];
        NSMutableArray<NSMutableData*>* lightmapPageAccumulatedLighting = [NSMutableArray array];
        HwrtBakeLight bakeLights[UI_MAX_LIGHTS] = {0};
        uint32_t bakeLightCount = viewport_build_preview_bake_lights(&uiStateSnapshot,
                                         lightPosition,
                                         lightColor,
                                         lightIntensity,
                                         lightRange,
                                         lightEnabled,
                                         bakeLights,
                                         UI_MAX_LIGHTS);
        uint32_t totalTriangles = 0u;
        uint32_t processedTriangles = 0u;
        int lastPercent = -1;

        if (!self.device.supportsRaytracing) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.previewBakeInProgress = NO;
                NSLog(@"[lighting] HWRT preview bake unavailable: current Metal device does not support ray tracing");
            });
            free(verticesSnapshot);
            free(baseColorSnapshot);
            free(faceRangesSnapshot);
            return;
        }

        id<MTLComputePipelineState> bakePipeline = [self hwrtBakePipelineState];
        if (bakePipeline == nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.previewBakeInProgress = NO;
                NSLog(@"[lighting] HWRT preview bake failed: compute pipeline is unavailable");
            });
            free(verticesSnapshot);
            free(baseColorSnapshot);
            free(faceRangesSnapshot);
            return;
        }

        id<MTLBuffer> bakeLightsBuffer = nil;
        if (bakeLightCount > 0u) {
            bakeLightsBuffer = [self.device newBufferWithBytes:bakeLights
                                                        length:(NSUInteger)bakeLightCount * sizeof(HwrtBakeLight)
                                                       options:MTLResourceStorageModeShared];
            if (bakeLightsBuffer == nil) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.previewBakeInProgress = NO;
                    NSLog(@"[lighting] HWRT preview bake failed to allocate bake light buffer");
                });
                free(verticesSnapshot);
                free(baseColorSnapshot);
                free(faceRangesSnapshot);
                return;
            }
        }

        NovaSceneImportedRuntime* importedRuntime = self.sceneWorld != NULL ? nova_scene_world_imported_runtime(self.sceneWorld) : NULL;
        NSMutableDictionary<NSString*, NSNumber*>* materialIndexByName = [NSMutableDictionary dictionary];
        uint32_t bakeMaterialCount = 0u;
        uint32_t bakeTextureCount = 0u;
        id<MTLBuffer> bakeMaterialBuffer = nil;
        id<MTLBuffer> bakeBindlessArgumentBuffer = nil;
        NSMutableArray<id<MTLTexture>>* bakeSceneTextures = [NSMutableArray array];

        if (importedRuntime != NULL) {
            bakeMaterialCount = importedRuntime->materialCount;
            if (bakeMaterialCount > UI_MAX_LIGHTS) {
                bakeMaterialCount = UI_MAX_LIGHTS;
            }
            for (uint32_t materialIndex = 0u; materialIndex < bakeMaterialCount; ++materialIndex) {
                NSString* materialName = [NSString stringWithUTF8String:importedRuntime->materialRecords[materialIndex].name];
                if (materialName.length > 0) {
                    materialIndexByName[materialName] = @(materialIndex);
                }
            }
        }

        {
            uint32_t uploadMaterialCount = bakeMaterialCount > 0u ? bakeMaterialCount : 1u;
            NSMutableData* bakeMaterialsData = [NSMutableData dataWithLength:(NSUInteger)uploadMaterialCount * sizeof(NovaSceneGpuMaterial)];
            NovaSceneGpuMaterial* dstMaterials = (NovaSceneGpuMaterial*)bakeMaterialsData.mutableBytes;
            memset(dstMaterials, 0, bakeMaterialsData.length);
            if (bakeMaterialCount > 0u && importedRuntime != NULL) {
                memcpy(dstMaterials, importedRuntime->materialsCpu, (NSUInteger)bakeMaterialCount * sizeof(NovaSceneGpuMaterial));
            } else {
                dstMaterials[0].baseColor[0] = 1.0f;
                dstMaterials[0].baseColor[1] = 1.0f;
                dstMaterials[0].baseColor[2] = 1.0f;
                dstMaterials[0].baseColor[3] = 1.0f;
            }
            bakeMaterialBuffer = [self.device newBufferWithBytes:dstMaterials
                                                           length:bakeMaterialsData.length
                                                          options:MTLResourceStorageModeShared];
        }

        {
            uint32_t maxSceneTextures = 512u;
            uint32_t sourceTextureCount = _importedSceneData.textureCount;
            bakeTextureCount = sourceTextureCount < maxSceneTextures ? sourceTextureCount : maxSceneTextures;
            for (uint32_t textureIndex = 0u; textureIndex < bakeTextureCount; ++textureIndex) {
                const NovaSceneTexture* srcTexture = &_importedSceneData.textures[textureIndex];
                if (srcTexture->width <= 0 || srcTexture->height <= 0) {
                    continue;
                }

                MTLPixelFormat pixelFormat = srcTexture->format == NOVA_SCENE_TEXTURE_FORMAT_RGBA32_FLOAT ? MTLPixelFormatRGBA32Float : MTLPixelFormatRGBA8Unorm;
                MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pixelFormat
                                                                                                 width:(NSUInteger)srcTexture->width
                                                                                                height:(NSUInteger)srcTexture->height
                                                                                             mipmapped:NO];
                desc.usage = MTLTextureUsageShaderRead;
                desc.storageMode = MTLStorageModeManaged;
                id<MTLTexture> texture = [self.device newTextureWithDescriptor:desc];
                if (texture == nil) {
                    continue;
                }

                MTLRegion fullRegion = MTLRegionMake2D(0, 0, (NSUInteger)srcTexture->width, (NSUInteger)srcTexture->height);
                if (srcTexture->format == NOVA_SCENE_TEXTURE_FORMAT_RGBA32_FLOAT && srcTexture->rgba32f != NULL) {
                    NSUInteger bytesPerRow = (NSUInteger)srcTexture->width * sizeof(float) * 4u;
                    [texture replaceRegion:fullRegion mipmapLevel:0 withBytes:srcTexture->rgba32f bytesPerRow:bytesPerRow];
                } else if (srcTexture->rgba8 != NULL) {
                    NSUInteger bytesPerRow = (NSUInteger)srcTexture->width * 4u;
                    [texture replaceRegion:fullRegion mipmapLevel:0 withBytes:srcTexture->rgba8 bytesPerRow:bytesPerRow];
                }
                [bakeSceneTextures addObject:texture];
            }
            bakeTextureCount = (uint32_t)bakeSceneTextures.count;

            NSError* bindlessError = nil;
            NSString* shaderPath = [[NSBundle mainBundle] pathForResource:@"pathtrace.comp" ofType:@"metallib" inDirectory:@"shaders/metal"];
            if (shaderPath == nil) {
                NSString* executableDir = [[[NSProcessInfo processInfo] arguments][0] stringByDeletingLastPathComponent];
                shaderPath = [executableDir stringByAppendingPathComponent:@"shaders/metal/pathtrace.comp.metallib"];
            }
            id<MTLLibrary> bakeLibrary = [self.device newLibraryWithURL:[NSURL fileURLWithPath:shaderPath] error:&bindlessError];
            id<MTLFunction> bakeFunction = bakeLibrary != nil ? [bakeLibrary newFunctionWithName:@"pathtrace_lightmap_bake_main"] : nil;
            id<MTLArgumentEncoder> bindlessEncoder = bakeFunction != nil ? [bakeFunction newArgumentEncoderWithBufferIndex:7u] : nil;
            if (bindlessEncoder != nil) {
                bakeBindlessArgumentBuffer = [self.device newBufferWithLength:bindlessEncoder.encodedLength options:MTLResourceStorageModeShared];
                if (bakeBindlessArgumentBuffer != nil) {
                    [bindlessEncoder setArgumentBuffer:bakeBindlessArgumentBuffer offset:0u];
                    for (uint32_t index = 0u; index < bakeTextureCount; ++index) {
                        [bindlessEncoder setTexture:bakeSceneTextures[index] atIndex:index];
                    }
                    [bindlessEncoder setSamplerState:self.samplerState atIndex:512u];
                }
            }
        }

        if (bakeMaterialBuffer == nil || bakeBindlessArgumentBuffer == nil) {
            bakeMaterialCount = 0u;
            bakeTextureCount = 0u;
        }

        HwrtPathTraceVertex* rtBakeVertices = (HwrtPathTraceVertex*)malloc(vertexCount * sizeof(HwrtPathTraceVertex));
        simd_float3* rtBakePositions = (simd_float3*)malloc(vertexCount * sizeof(simd_float3));
        size_t rtBakeVertexCount = 0u;
        if (rtBakeVertices == NULL || rtBakePositions == NULL) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.previewBakeInProgress = NO;
                NSLog(@"[lighting] HWRT preview bake failed to allocate filtered bake geometry arrays");
            });
            free(rtBakeVertices);
            free(rtBakePositions);
            free(verticesSnapshot);
            free(baseColorSnapshot);
            free(faceRangesSnapshot);
            return;
        }

        for (size_t faceIndex = 0; faceIndex < faceRangeCount; ++faceIndex) {
            ViewerFaceRange range = faceRangesSnapshot[faceIndex];
            NSNumber* materialIndexValue = nil;
            uint32_t bakeMaterialIndex = 0u;
            if (viewport_face_range_is_bake_excluded(&range)) {
                continue;
            }
            if (range.vertexCount < 3u || range.vertexStart >= vertexCount) {
                continue;
            }
            if (range.vertexStart + range.vertexCount > vertexCount) {
                range.vertexCount = vertexCount - range.vertexStart;
            }
            range.vertexCount -= range.vertexCount % 3u;
            if (range.vertexCount < 3u) {
                continue;
            }

            materialIndexValue = materialIndexByName[[NSString stringWithUTF8String:range.material]];
            if (materialIndexValue != nil) {
                bakeMaterialIndex = materialIndexValue.unsignedIntValue;
            }

            for (size_t triVertex = 0; triVertex < range.vertexCount; ++triVertex) {
                const ViewerVertex* src = &verticesSnapshot[range.vertexStart + triVertex];
                rtBakeVertices[rtBakeVertexCount].position = simd_make_float4(src->position.raw[0], src->position.raw[1], src->position.raw[2], 1.0f);
                rtBakeVertices[rtBakeVertexCount].normal = simd_make_float4(src->normal.raw[0], src->normal.raw[1], src->normal.raw[2], 0.0f);
                rtBakeVertices[rtBakeVertexCount].tangent = simd_make_float4(1.0f, 0.0f, 0.0f, 1.0f);
                rtBakeVertices[rtBakeVertexCount].uv = simd_make_float4(src->u, src->v, (float)bakeMaterialIndex, 0.0f);
                rtBakePositions[rtBakeVertexCount] = simd_make_float3(src->position.raw[0], src->position.raw[1], src->position.raw[2]);
                rtBakeVertexCount += 1u;
            }
        }

        if (rtBakeVertexCount < 3u) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.previewBakeInProgress = NO;
                NSLog(@"[lighting] HWRT preview bake aborted: no bakeable world triangles after filtering helper geometry");
            });
            free(rtBakeVertices);
            free(rtBakePositions);
            free(verticesSnapshot);
            free(baseColorSnapshot);
            free(faceRangesSnapshot);
            return;
        }

        id<MTLBuffer> pathTraceVertices = [self.device newBufferWithBytes:rtBakeVertices
                                                                    length:rtBakeVertexCount * sizeof(HwrtPathTraceVertex)
                                                                   options:MTLResourceStorageModeShared];
        id<MTLBuffer> rtVertexPositions = [self.device newBufferWithBytes:rtBakePositions
                                                                   length:rtBakeVertexCount * sizeof(simd_float3)
                                                                  options:MTLResourceStorageModeShared];
        free(rtBakeVertices);
        free(rtBakePositions);
        if (pathTraceVertices == nil || rtVertexPositions == nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.previewBakeInProgress = NO;
                NSLog(@"[lighting] HWRT preview bake failed to allocate filtered geometry buffers");
            });
            free(verticesSnapshot);
            free(baseColorSnapshot);
            free(faceRangesSnapshot);
            return;
        }

        id<MTLAccelerationStructure> accelerationStructure = nil;
        {
            MTLAccelerationStructureTriangleGeometryDescriptor* geom = [MTLAccelerationStructureTriangleGeometryDescriptor descriptor];
            geom.vertexBuffer = rtVertexPositions;
            geom.vertexBufferOffset = 0u;
            geom.vertexStride = sizeof(simd_float3);
            geom.vertexFormat = MTLAttributeFormatFloat3;
            geom.triangleCount = (NSUInteger)(rtBakeVertexCount / 3u);
            geom.opaque = YES;

            MTLPrimitiveAccelerationStructureDescriptor* asDescriptor = [MTLPrimitiveAccelerationStructureDescriptor descriptor];
            asDescriptor.geometryDescriptors = @[ geom ];
            MTLAccelerationStructureSizes asSizes = [self.device accelerationStructureSizesWithDescriptor:asDescriptor];
            accelerationStructure = [self.device newAccelerationStructureWithSize:asSizes.accelerationStructureSize];
            id<MTLBuffer> asScratch = [self.device newBufferWithLength:asSizes.buildScratchBufferSize options:MTLResourceStorageModePrivate];
            if (accelerationStructure == nil || asScratch == nil) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.previewBakeInProgress = NO;
                    NSLog(@"[lighting] HWRT preview bake failed to allocate acceleration structure resources");
                });
                free(verticesSnapshot);
                free(baseColorSnapshot);
                free(faceRangesSnapshot);
                return;
            }

            id<MTLCommandBuffer> asBuildCommand = [self.commandQueue commandBuffer];
            id<MTLAccelerationStructureCommandEncoder> asEncoder = [asBuildCommand accelerationStructureCommandEncoder];
            if (asBuildCommand == nil || asEncoder == nil) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.previewBakeInProgress = NO;
                    NSLog(@"[lighting] HWRT preview bake failed to create acceleration structure encoder");
                });
                free(verticesSnapshot);
                free(baseColorSnapshot);
                free(faceRangesSnapshot);
                return;
            }

            [asEncoder buildAccelerationStructure:accelerationStructure descriptor:asDescriptor scratchBuffer:asScratch scratchBufferOffset:0u];
            [asEncoder endEncoding];
            [asBuildCommand commit];
            [asBuildCommand waitUntilCompleted];
            if (asBuildCommand.status != MTLCommandBufferStatusCompleted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.previewBakeInProgress = NO;
                    NSLog(@"[lighting] HWRT preview bake failed while building acceleration structure");
                });
                free(verticesSnapshot);
                free(baseColorSnapshot);
                free(faceRangesSnapshot);
                return;
            }
        }

        for (size_t faceIndex = 0; faceIndex < faceRangeCount; ++faceIndex) {
            if (viewport_face_range_is_bake_excluded(&faceRangesSnapshot[faceIndex])) {
                continue;
            }
            totalTriangles += (uint32_t)(faceRangesSnapshot[faceIndex].vertexCount / 3u);
            {
                ViewerFaceRange range = faceRangesSnapshot[faceIndex];
                NSString* brushKey = [NSString stringWithFormat:@"brush_%zu_%zu_%zu", range.entityIndex, range.solidIndex, range.sideIndex];
                if (range.vertexStart < vertexCount) {
                    size_t limit = range.vertexStart + range.vertexCount;
                    if (limit > vertexCount) {
                        limit = vertexCount;
                    }
                    for (size_t vi = range.vertexStart; vi < limit; ++vi) {
                        const ViewerVertex* v = &verticesSnapshot[vi];
                        NSNumber* minUExisting = brushUvMinUByKey[brushKey];
                        NSNumber* minVExisting = brushUvMinVByKey[brushKey];
                        NSNumber* maxUExisting = brushUvMaxUByKey[brushKey];
                        NSNumber* maxVExisting = brushUvMaxVByKey[brushKey];
                        float minU = minUExisting != nil ? minUExisting.floatValue : v->u;
                        float minV = minVExisting != nil ? minVExisting.floatValue : v->v;
                        float maxU = maxUExisting != nil ? maxUExisting.floatValue : v->u;
                        float maxV = maxVExisting != nil ? maxVExisting.floatValue : v->v;
                        minU = fminf(minU, v->u);
                        minV = fminf(minV, v->v);
                        maxU = fmaxf(maxU, v->u);
                        maxV = fmaxf(maxV, v->v);
                        brushUvMinUByKey[brushKey] = @(minU);
                        brushUvMinVByKey[brushKey] = @(minV);
                        brushUvMaxUByKey[brushKey] = @(maxU);
                        brushUvMaxVByKey[brushKey] = @(maxV);
                    }
                }
            }
        }
        if (totalTriangles == 0u) {
            totalTriangles = 1u;
        }

        for (size_t faceIndex = 0; faceIndex < faceRangeCount; ++faceIndex) {
            ViewerFaceRange range = faceRangesSnapshot[faceIndex];
            NSString* brushKey;
            NSNumber* slotValue;
            uint32_t slot;
            NSMutableData* accumData;
            HwrtBakeTexelAccum* accum;
            int bakeWidth;
            int bakeHeight;

            if (viewport_face_range_is_bake_excluded(&range)) {
                continue;
            }
            if (range.vertexCount < 3u || range.vertexStart >= vertexCount) {
                continue;
            }
            if (range.vertexStart + range.vertexCount > vertexCount) {
                range.vertexCount = vertexCount - range.vertexStart;
            }
            range.vertexCount -= range.vertexCount % 3u;
            if (range.vertexCount < 3u) {
                continue;
            }

            brushKey = [NSString stringWithFormat:@"brush_%zu_%zu_%zu", range.entityIndex, range.solidIndex, range.sideIndex];
            if (brushKey.length == 0) {
                brushKey = @"brush_0_0_0";
            }

            slotValue = brushSlotByKey[brushKey];
            if (slotValue == nil) {
                int resolution = (int)fmin((double)kPreviewBakeDensityMax, fmax((double)kPreviewBakeDensityMin, (double)self.previewBakeDensity));
                int chartWidth = kPreviewBakeMinResolution;
                int chartHeight = kPreviewBakeMinResolution;
                viewport_preview_bake_chart_size_for_range(verticesSnapshot, range, resolution, &chartWidth, &chartHeight);
                slot = (uint32_t)brushAccums.count;
                brushSlotByKey[brushKey] = @(slot);
                [brushKeys addObject:brushKey];
                [brushWidths addObject:@(chartWidth)];
                [brushHeights addObject:@(chartHeight)];
                [brushAccums addObject:[NSMutableData dataWithLength:(NSUInteger)chartWidth * (NSUInteger)chartHeight * sizeof(HwrtBakeTexelAccum)]];
            } else {
                slot = slotValue.unsignedIntValue;
            }

            bakeWidth = brushWidths[slot].intValue;
            bakeHeight = brushHeights[slot].intValue;
            accumData = brushAccums[slot];
            accum = (HwrtBakeTexelAccum*)accumData.mutableBytes;

            for (size_t triOffset = 0; triOffset + 2 < range.vertexCount; triOffset += 3) {
                const ViewerVertex* v0 = &verticesSnapshot[range.vertexStart + triOffset + 0u];
                const ViewerVertex* v1 = &verticesSnapshot[range.vertexStart + triOffset + 1u];
                const ViewerVertex* v2 = &verticesSnapshot[range.vertexStart + triOffset + 2u];
                const Vec3 a0 = baseColorSnapshot[range.vertexStart + triOffset + 0u];
                const Vec3 a1 = baseColorSnapshot[range.vertexStart + triOffset + 1u];
                const Vec3 a2 = baseColorSnapshot[range.vertexStart + triOffset + 2u];
                float uvMinU = brushUvMinUByKey[brushKey] != nil ? brushUvMinUByKey[brushKey].floatValue : 0.0f;
                float uvMinV = brushUvMinVByKey[brushKey] != nil ? brushUvMinVByKey[brushKey].floatValue : 0.0f;
                float uvMaxU = brushUvMaxUByKey[brushKey] != nil ? brushUvMaxUByKey[brushKey].floatValue : 1.0f;
                float uvMaxV = brushUvMaxVByKey[brushKey] != nil ? brushUvMaxVByKey[brushKey].floatValue : 1.0f;
                float uvSpanU = fmaxf(uvMaxU - uvMinU, 1e-4f);
                float uvSpanV = fmaxf(uvMaxV - uvMinV, 1e-4f);
                float x0 = ((v0->u - uvMinU) / uvSpanU) * (float)(bakeWidth - 1);
                float y0 = ((v0->v - uvMinV) / uvSpanV) * (float)(bakeHeight - 1);
                float x1 = ((v1->u - uvMinU) / uvSpanU) * (float)(bakeWidth - 1);
                float y1 = ((v1->v - uvMinV) / uvSpanV) * (float)(bakeHeight - 1);
                float x2 = ((v2->u - uvMinU) / uvSpanU) * (float)(bakeWidth - 1);
                float y2 = ((v2->v - uvMinV) / uvSpanV) * (float)(bakeHeight - 1);
                float denom = (y1 - y2) * (x0 - x2) + (x2 - x1) * (y0 - y2);

                float minU = floorf(fminf(fminf(x0, x1), x2));
                float maxU = ceilf(fmaxf(fmaxf(x0, x1), x2));
                float minV = floorf(fminf(fminf(y0, y1), y2));
                float maxV = ceilf(fmaxf(fmaxf(y0, y1), y2));

                if (fabsf(denom) < 1e-6f) {
                    int px = (int)lrintf((x0 + x1 + x2) / 3.0f);
                    int py = (int)lrintf((y0 + y1 + y2) / 3.0f);
                    px = (int)fmin((double)(bakeWidth - 1), fmax(0.0, (double)px));
                    py = (int)fmin((double)(bakeHeight - 1), fmax(0.0, (double)py));
                    size_t texelIndex = (size_t)py * (size_t)bakeWidth + (size_t)px;

                    simd_float3 worldPos = (simd_make_float3(v0->position.raw[0], v0->position.raw[1], v0->position.raw[2]) +
                                            simd_make_float3(v1->position.raw[0], v1->position.raw[1], v1->position.raw[2]) +
                                            simd_make_float3(v2->position.raw[0], v2->position.raw[1], v2->position.raw[2])) / 3.0f;
                    simd_float3 normal = (simd_make_float3(v0->normal.raw[0], v0->normal.raw[1], v0->normal.raw[2]) +
                                          simd_make_float3(v1->normal.raw[0], v1->normal.raw[1], v1->normal.raw[2]) +
                                          simd_make_float3(v2->normal.raw[0], v2->normal.raw[1], v2->normal.raw[2])) / 3.0f;
                    simd_float3 albedo = (simd_make_float3(a0.raw[0], a0.raw[1], a0.raw[2]) +
                                          simd_make_float3(a1.raw[0], a1.raw[1], a1.raw[2]) +
                                          simd_make_float3(a2.raw[0], a2.raw[1], a2.raw[2])) / 3.0f;

                    accum[texelIndex].worldPosWeight.x += worldPos.x;
                    accum[texelIndex].worldPosWeight.y += worldPos.y;
                    accum[texelIndex].worldPosWeight.z += worldPos.z;
                    accum[texelIndex].worldPosWeight.w += 1.0f;
                    accum[texelIndex].normalSum.x += normal.x;
                    accum[texelIndex].normalSum.y += normal.y;
                    accum[texelIndex].normalSum.z += normal.z;
                    accum[texelIndex].albedoSum.x += albedo.x;
                    accum[texelIndex].albedoSum.y += albedo.y;
                    accum[texelIndex].albedoSum.z += albedo.z;

                    processedTriangles += 1u;
                    continue;
                }

                if (minU < 0.0f) minU = 0.0f;
                if (minV < 0.0f) minV = 0.0f;
                if (maxU > (float)(bakeWidth - 1)) maxU = (float)(bakeWidth - 1);
                if (maxV > (float)(bakeHeight - 1)) maxV = (float)(bakeHeight - 1);

                for (int py = (int)minV; py <= (int)maxV; ++py) {
                    for (int px = (int)minU; px <= (int)maxU; ++px) {
                        float sampleU = (float)px + 0.5f;
                        float sampleV = (float)py + 0.5f;
                        float w0 = ((y1 - y2) * (sampleU - x2) + (x2 - x1) * (sampleV - y2)) / denom;
                        float w1 = ((y2 - y0) * (sampleU - x2) + (x0 - x2) * (sampleV - y2)) / denom;
                        float w2 = 1.0f - w0 - w1;
                        if (w0 < -1e-4f || w1 < -1e-4f || w2 < -1e-4f) {
                            continue;
                        }

                        simd_float3 worldPos = simd_make_float3(v0->position.raw[0], v0->position.raw[1], v0->position.raw[2]) * w0 +
                                               simd_make_float3(v1->position.raw[0], v1->position.raw[1], v1->position.raw[2]) * w1 +
                                               simd_make_float3(v2->position.raw[0], v2->position.raw[1], v2->position.raw[2]) * w2;
                        simd_float3 normal = simd_make_float3(v0->normal.raw[0], v0->normal.raw[1], v0->normal.raw[2]) * w0 +
                                             simd_make_float3(v1->normal.raw[0], v1->normal.raw[1], v1->normal.raw[2]) * w1 +
                                             simd_make_float3(v2->normal.raw[0], v2->normal.raw[1], v2->normal.raw[2]) * w2;
                        simd_float3 albedo = simd_make_float3(a0.raw[0], a0.raw[1], a0.raw[2]) * w0 +
                                             simd_make_float3(a1.raw[0], a1.raw[1], a1.raw[2]) * w1 +
                                             simd_make_float3(a2.raw[0], a2.raw[1], a2.raw[2]) * w2;
                        size_t texelIndex = (size_t)py * (size_t)bakeWidth + (size_t)px;

                        accum[texelIndex].worldPosWeight.x += worldPos.x;
                        accum[texelIndex].worldPosWeight.y += worldPos.y;
                        accum[texelIndex].worldPosWeight.z += worldPos.z;
                        accum[texelIndex].worldPosWeight.w += 1.0f;
                        accum[texelIndex].normalSum.x += normal.x;
                        accum[texelIndex].normalSum.y += normal.y;
                        accum[texelIndex].normalSum.z += normal.z;
                        accum[texelIndex].albedoSum.x += albedo.x;
                        accum[texelIndex].albedoSum.y += albedo.y;
                        accum[texelIndex].albedoSum.z += albedo.z;
                    }
                }

                processedTriangles += 1u;
                {
                    int percent = (int)((processedTriangles * 100u) / totalTriangles);
                    if (percent != lastPercent && (percent == 0 || percent % 5 == 0 || percent == 100)) {
                        int filled = percent / 5;
                        char bar[21];
                        for (int i = 0; i < 20; ++i) {
                            bar[i] = i < filled ? '#' : '-';
                        }
                        bar[20] = '\0';
                        NSLog(@"[lighting] bake unwrap [%s] %d%% (%u/%u triangles)", bar, percent, processedTriangles, totalTriangles);
                        lastPercent = percent;
                    }
                }
            }
        }

        for (NSUInteger slot = 0; slot < brushAccums.count; ++slot) {
            HwrtBakeTexelAccum* accum = (HwrtBakeTexelAccum*)brushAccums[slot].mutableBytes;
            NSString* key = brushKeys[slot];
            int bakeWidth = brushWidths[slot].intValue;
            int bakeHeight = brushHeights[slot].intValue;
            size_t texelCount = (size_t)bakeWidth * (size_t)bakeHeight;
            NSMutableData* texelData = [NSMutableData dataWithLength:texelCount * sizeof(HwrtBakeTexel)];
            HwrtBakeTexel* texels = (HwrtBakeTexel*)texelData.mutableBytes;
            uint32_t validTexelCount = 0u;

            for (size_t texelIndex = 0; texelIndex < texelCount; ++texelIndex) {
                float weight = accum[texelIndex].worldPosWeight.w;
                if (weight > 0.0f) {
                    simd_float3 worldPos = simd_make_float3(accum[texelIndex].worldPosWeight.x / weight,
                                                            accum[texelIndex].worldPosWeight.y / weight,
                                                            accum[texelIndex].worldPosWeight.z / weight);
                    simd_float3 normal = simd_make_float3(accum[texelIndex].normalSum.x / weight,
                                                          accum[texelIndex].normalSum.y / weight,
                                                          accum[texelIndex].normalSum.z / weight);
                    simd_float3 albedo = simd_make_float3(accum[texelIndex].albedoSum.x / weight,
                                                          accum[texelIndex].albedoSum.y / weight,
                                                          accum[texelIndex].albedoSum.z / weight);
                    float normalLen = sqrtf(simd_dot(normal, normal));
                    if (normalLen > 1e-5f) {
                        normal /= normalLen;
                    } else {
                        normal = simd_make_float3(0.0f, 0.0f, 1.0f);
                    }

                    worldPos += normal * kPreviewBakeTexelSurfaceBias;
                    texels[texelIndex].worldPosValid = simd_make_float4(worldPos.x, worldPos.y, worldPos.z, 1.0f);
                    texels[texelIndex].normal = simd_make_float4(normal.x, normal.y, normal.z, 0.0f);
                    texels[texelIndex].albedo = simd_make_float4(fminf(fmaxf(albedo.x, 0.0f), 1.0f),
                                                                 fminf(fmaxf(albedo.y, 0.0f), 1.0f),
                                                                 fminf(fmaxf(albedo.z, 0.0f), 1.0f),
                                                                 0.0f);
                    validTexelCount += 1u;
                } else {
                    texels[texelIndex].worldPosValid = simd_make_float4(0.0f, 0.0f, 0.0f, 0.0f);
                    texels[texelIndex].normal = simd_make_float4(0.0f, 0.0f, 1.0f, 0.0f);
                    texels[texelIndex].albedo = simd_make_float4(1.0f, 1.0f, 1.0f, 0.0f);
                }
            }

            id<MTLBuffer> texelBuffer = [self.device newBufferWithBytes:texelData.bytes length:texelData.length options:MTLResourceStorageModeShared];
            id<MTLBuffer> outputBuffer = [self.device newBufferWithLength:texelCount * sizeof(simd_float4) options:MTLResourceStorageModeShared];
            id<MTLBuffer> uniformBuffer = [self.device newBufferWithLength:sizeof(HwrtBakeUniforms) options:MTLResourceStorageModeShared];
            if (texelBuffer == nil || outputBuffer == nil || uniformBuffer == nil) {
                NSLog(@"[lighting] HWRT bake failed for brush %@: unable to allocate compute buffers", key);
                continue;
            }
            if (validTexelCount == 0u) {
                NSLog(@"[lighting] HWRT bake brush %@ has 0 valid texels after charting", key);
                [bakeTexelDatas addObject:[NSMutableData data]];
                [bakeValidTexelCounts addObject:@(0u)];
                [bakeAccumulatedLighting addObject:[NSMutableData data]];
                continue;
            }

            [bakeTexelDatas addObject:texelData];
            [bakeValidTexelCounts addObject:@(validTexelCount)];
            [bakeAccumulatedLighting addObject:[NSMutableData dataWithLength:texelCount * sizeof(simd_float4)]];
        }

        lightmapPages = viewport_build_lightmap_page_layout(brushKeys, brushWidths, brushHeights, kPreviewBakeMaxResolution);
        for (NSMutableDictionary<NSString*, id>* page in lightmapPages) {
            NSString* pageKey = page[@"key"];
            NSDictionary<NSString*, NSArray<NSNumber*>*>* charts = page[@"charts"];
            int pageWidth = [page[@"width"] intValue];
            int pageHeight = [page[@"height"] intValue];
            size_t texelCount = (size_t)pageWidth * (size_t)pageHeight;
            NSMutableData* pageTexelData = [NSMutableData dataWithLength:texelCount * sizeof(HwrtBakeTexel)];
            NSMutableData* pageSumData = [NSMutableData dataWithLength:texelCount * sizeof(simd_float4)];
            HwrtBakeTexel* dstTexels = (HwrtBakeTexel*)pageTexelData.mutableBytes;
            uint32_t pageValidTexelCount = 0u;
            if (pageKey.length == 0 || charts.count == 0 || pageWidth <= 0 || pageHeight <= 0 || pageTexelData.length == 0 || pageSumData.length == 0) {
                continue;
            }
            memset(dstTexels, 0, pageTexelData.length);
            for (NSString* faceKey in brushKeys) {
                NSArray<NSNumber*>* chartInfo = charts[faceKey];
                NSNumber* slotValue = brushSlotByKey[faceKey];
                if (chartInfo == nil || slotValue == nil) {
                    continue;
                }
                NSUInteger slot = slotValue.unsignedIntegerValue;
                NSMutableData* faceTexelData = slot < bakeTexelDatas.count ? bakeTexelDatas[slot] : nil;
                int chartX = chartInfo[0].intValue;
                int chartY = chartInfo[1].intValue;
                int chartW = chartInfo[2].intValue;
                int chartH = chartInfo[3].intValue;
                const HwrtBakeTexel* srcTexels = faceTexelData != nil ? (const HwrtBakeTexel*)faceTexelData.bytes : NULL;
                if (srcTexels == NULL || chartW <= 0 || chartH <= 0) {
                    continue;
                }
                pageValidTexelCount += slot < bakeValidTexelCounts.count ? bakeValidTexelCounts[slot].unsignedIntValue : 0u;
                for (int py = 0; py < chartH; ++py) {
                    int dstRow = chartY + py;
                    if (dstRow < 0 || dstRow >= pageHeight) {
                        continue;
                    }
                    for (int px = 0; px < chartW; ++px) {
                        int dstCol = chartX + px;
                        if (dstCol < 0 || dstCol >= pageWidth) {
                            continue;
                        }
                        size_t srcIndex = (size_t)py * (size_t)chartW + (size_t)px;
                        size_t dstIndex = (size_t)dstRow * (size_t)pageWidth + (size_t)dstCol;
                        dstTexels[dstIndex] = srcTexels[srcIndex];
                    }
                }
            }
            [lightmapPageKeys addObject:pageKey];
            [lightmapPageWidths addObject:@(pageWidth)];
            [lightmapPageHeights addObject:@(pageHeight)];
            [lightmapPageTexelDatas addObject:pageTexelData];
            [lightmapPageValidTexelCounts addObject:@(pageValidTexelCount)];
            [lightmapPageAccumulatedLighting addObject:pageSumData];
        }

        uint32_t accumulatedSamples = 0u;
        BOOL bakeDispatchFailed = NO;
        NSString* bakeDispatchFailureKey = nil;
        while (accumulatedSamples < targetSamplesPerTexel) {
            uint32_t batchSamples = self.previewBakeRtSamplesPerTexel;
            if (batchSamples > (targetSamplesPerTexel - accumulatedSamples)) {
                batchSamples = targetSamplesPerTexel - accumulatedSamples;
            }
            if (batchSamples == 0u) {
                break;
            }

            uint32_t newAccumulatedSamples = accumulatedSamples + batchSamples;
            NSMutableDictionary<NSString*, NSDictionary<NSString*, id>*>* progressiveMaps = [NSMutableDictionary dictionary];
            NSMutableDictionary<NSString*, NSDictionary<NSString*, NSNumber*>*>* progressiveStats = [NSMutableDictionary dictionary];
            NSMutableDictionary<NSString*, NSDictionary<NSString*, id>*>* progressiveFacePayloads = [NSMutableDictionary dictionary];

            for (NSUInteger pageIndex = 0; pageIndex < lightmapPageKeys.count; ++pageIndex) {
                NSString* key = lightmapPageKeys[pageIndex];
                int bakeWidth = lightmapPageWidths[pageIndex].intValue;
                int bakeHeight = lightmapPageHeights[pageIndex].intValue;
                size_t texelCount = (size_t)bakeWidth * (size_t)bakeHeight;
                NSMutableData* texelData = pageIndex < lightmapPageTexelDatas.count ? lightmapPageTexelDatas[pageIndex] : nil;
                uint32_t validTexelCount = pageIndex < lightmapPageValidTexelCounts.count ? lightmapPageValidTexelCounts[pageIndex].unsignedIntValue : 0u;
                NSMutableData* sumData = pageIndex < lightmapPageAccumulatedLighting.count ? lightmapPageAccumulatedLighting[pageIndex] : nil;
                HwrtBakeTexel* texels = (HwrtBakeTexel*)texelData.mutableBytes;

                if (texelData == nil || sumData == nil || validTexelCount == 0u || texelCount == 0u) {
                    continue;
                }

                id<MTLBuffer> texelBuffer = [self.device newBufferWithBytes:texelData.bytes length:texelData.length options:MTLResourceStorageModeShared];
                id<MTLBuffer> outputBuffer = [self.device newBufferWithLength:texelCount * sizeof(simd_float4) options:MTLResourceStorageModeShared];
                id<MTLBuffer> uniformBuffer = [self.device newBufferWithLength:sizeof(HwrtBakeUniforms) options:MTLResourceStorageModeShared];
                if (texelBuffer == nil || outputBuffer == nil || uniformBuffer == nil) {
                    NSLog(@"[lighting] HWRT bake failed for brush %@: unable to allocate compute buffers", key);
                    continue;
                }

                {
                    HwrtBakeUniforms* uniforms = (HwrtBakeUniforms*)uniformBuffer.contents;
                    uniforms->lightPosRange = simd_make_float4(lightPosition.raw[0], lightPosition.raw[1], lightPosition.raw[2], fmaxf(lightRange, 1.0f));
                    uniforms->lightColorIntensity = simd_make_float4(lightColor.raw[0], lightColor.raw[1], lightColor.raw[2], lightEnabled ? fmaxf(lightIntensity, 0.0f) : 0.0f);
                    uniforms->sampleCount = batchSamples;
                    uniforms->bounceCount = self.previewBakeBounceCount;
                    uniforms->texelCount = (uint32_t)texelCount;
                    uniforms->frameSeed = (uint32_t)(revision + (uint64_t)pageIndex * 9973ull + (uint64_t)accumulatedSamples * 131u);
                    uniforms->lightCount = bakeLightCount;
                    uniforms->importedMaterialCount = bakeMaterialCount;
                    uniforms->importedTextureCount = bakeTextureCount;
                    uniforms->sceneTriangleCount = (uint32_t)(rtBakeVertexCount / 3u);
                }

                id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
                id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
                if (commandBuffer == nil || encoder == nil) {
                    NSLog(@"[lighting] HWRT bake failed for brush %@: unable to create compute encoder", key);
                    continue;
                }

                [encoder setComputePipelineState:bakePipeline];
                [encoder setBuffer:texelBuffer offset:0u atIndex:0u];
                [encoder setBuffer:outputBuffer offset:0u atIndex:1u];
                [encoder setBuffer:uniformBuffer offset:0u atIndex:2u];
                [encoder setAccelerationStructure:accelerationStructure atBufferIndex:3u];
                [encoder setBuffer:pathTraceVertices offset:0u atIndex:4u];
                if (bakeLightsBuffer != nil) {
                    [encoder setBuffer:bakeLightsBuffer offset:0u atIndex:5u];
                }
                if (bakeMaterialBuffer != nil) {
                    [encoder setBuffer:bakeMaterialBuffer offset:0u atIndex:6u];
                }
                if (bakeBindlessArgumentBuffer != nil) {
                    [encoder setBuffer:bakeBindlessArgumentBuffer offset:0u atIndex:7u];
                }
                [encoder useResource:texelBuffer usage:MTLResourceUsageRead];
                [encoder useResource:outputBuffer usage:MTLResourceUsageWrite];
                [encoder useResource:uniformBuffer usage:MTLResourceUsageRead];
                [encoder useResource:accelerationStructure usage:MTLResourceUsageRead];
                [encoder useResource:pathTraceVertices usage:MTLResourceUsageRead];
                if (bakeLightsBuffer != nil) {
                    [encoder useResource:bakeLightsBuffer usage:MTLResourceUsageRead];
                }
                if (bakeMaterialBuffer != nil) {
                    [encoder useResource:bakeMaterialBuffer usage:MTLResourceUsageRead];
                }
                if (bakeBindlessArgumentBuffer != nil) {
                    [encoder useResource:bakeBindlessArgumentBuffer usage:MTLResourceUsageRead];
                }
                for (id<MTLTexture> bakeSceneTexture in bakeSceneTextures) {
                    if (bakeSceneTexture != nil) {
                        [encoder useResource:bakeSceneTexture usage:MTLResourceUsageRead];
                    }
                }

                NSUInteger threadsPerGroup = MIN(256u, bakePipeline.maxTotalThreadsPerThreadgroup);
                if (threadsPerGroup == 0u) {
                    threadsPerGroup = 64u;
                }
                MTLSize tg = MTLSizeMake(threadsPerGroup, 1u, 1u);
                MTLSize grid = MTLSizeMake(texelCount, 1u, 1u);
                [encoder dispatchThreads:grid threadsPerThreadgroup:tg];
                [encoder endEncoding];
                CFTimeInterval dispatchStart = CACurrentMediaTime();
                [commandBuffer commit];
                [commandBuffer waitUntilCompleted];
                CFTimeInterval dispatchEnd = CACurrentMediaTime();

                if (commandBuffer.status != MTLCommandBufferStatusCompleted) {
                    NSError* commandError = commandBuffer.error;
                    if (commandError != nil) {
                        NSLog(@"[lighting] HWRT bake failed for brush %@: compute dispatch did not complete (%@)", key, commandError.localizedDescription);
                    } else {
                        NSLog(@"[lighting] HWRT bake failed for brush %@: compute dispatch did not complete", key);
                    }
                    bakeDispatchFailed = YES;
                    bakeDispatchFailureKey = [key copy];
                    break;
                }

                simd_float4* lit = (simd_float4*)outputBuffer.contents;
                simd_float4* sum = (simd_float4*)sumData.mutableBytes;
                for (size_t texelIndex = 0; texelIndex < texelCount; ++texelIndex) {
                    sum[texelIndex] += lit[texelIndex] * (float)batchSamples;
                }

                NSMutableData* avgData = [NSMutableData dataWithLength:texelCount * sizeof(simd_float4)];
                simd_float4* avg = (simd_float4*)avgData.mutableBytes;
                float invAccum = 1.0f / (float)newAccumulatedSamples;
                for (size_t texelIndex = 0; texelIndex < texelCount; ++texelIndex) {
                    avg[texelIndex] = sum[texelIndex] * invAccum;
                }

                NSDictionary<NSString*, NSArray<NSNumber*>*>* charts = pageIndex < lightmapPages.count ? lightmapPages[pageIndex][@"charts"] : nil;
                for (NSString* faceKey in brushKeys) {
                    NSArray<NSNumber*>* chartInfo = charts[faceKey];
                    if (chartInfo == nil) {
                        continue;
                    }
                    int chartX = chartInfo[0].intValue;
                    int chartY = chartInfo[1].intValue;
                    int chartW = chartInfo[2].intValue;
                    int chartH = chartInfo[3].intValue;
                    size_t chartTexelCount = (size_t)chartW * (size_t)chartH;
                    NSMutableData* chartAvgData = [NSMutableData dataWithLength:chartTexelCount * sizeof(simd_float4)];
                    NSMutableData* chartTexelData = [NSMutableData dataWithLength:chartTexelCount * sizeof(HwrtBakeTexel)];
                    simd_float4* chartAvg = (simd_float4*)chartAvgData.mutableBytes;
                    HwrtBakeTexel* chartTexels = (HwrtBakeTexel*)chartTexelData.mutableBytes;
                    NSNumber* slotValue = brushSlotByKey[faceKey];
                    uint32_t faceValidTexels = slotValue != nil && slotValue.unsignedIntegerValue < bakeValidTexelCounts.count ? bakeValidTexelCounts[slotValue.unsignedIntegerValue].unsignedIntValue : 0u;
                    if (chartAvg == NULL || chartTexels == NULL || chartW <= 0 || chartH <= 0) {
                        continue;
                    }
                    for (int py = 0; py < chartH; ++py) {
                        int srcRow = chartY + py;
                        if (srcRow < 0 || srcRow >= bakeHeight) {
                            continue;
                        }
                        for (int px = 0; px < chartW; ++px) {
                            int srcCol = chartX + px;
                            if (srcCol < 0 || srcCol >= bakeWidth) {
                                continue;
                            }
                            size_t srcIndex = (size_t)srcRow * (size_t)bakeWidth + (size_t)srcCol;
                            size_t dstIndex = (size_t)py * (size_t)chartW + (size_t)px;
                            chartAvg[dstIndex] = avg[srcIndex];
                            chartTexels[dstIndex] = texels[srcIndex];
                        }
                    }

                    NSDictionary<NSString*, NSNumber*>* stats = nil;
                    NSDictionary<NSString*, id>* bakedMap = viewport_build_baked_lightmap_payload(chartAvg,
                                                                                                  chartTexels,
                                                                                                  chartTexelCount,
                                                                                                  chartW,
                                                                                                  chartH,
                                                                                                  faceValidTexels,
                                                                                                  &stats);
                    if (bakedMap != nil) {
                        progressiveFacePayloads[faceKey] = bakedMap;
                    }
                    if (stats != nil) {
                        progressiveStats[faceKey] = stats;
                    }
                }

                NSLog(@"[lighting] HWRT bake atlas %lu/%lu progressive (%@, %dx%d, %u/%u spp, validTexels=%u, %.2f ms)",
                      (unsigned long)(pageIndex + 1u),
                      (unsigned long)lightmapPageKeys.count,
                      key,
                      bakeWidth,
                      bakeHeight,
                      newAccumulatedSamples,
                      targetSamplesPerTexel,
                      validTexelCount,
                      (dispatchEnd - dispatchStart) * 1000.0);
            }

            if (bakeDispatchFailed) {
                break;
            }

            // Assemble per-face bakes into a small number of shared global lightmap pages.
            [progressiveMaps addEntriesFromDictionary:viewport_assemble_global_lightmap_atlases(progressiveFacePayloads, brushKeys, kPreviewBakeMaxResolution)];

            accumulatedSamples = newAccumulatedSamples;
            bakedMaps = progressiveMaps;
            bakedStats = progressiveStats;

            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.meshRevision == revision && self.cpuVertices != NULL && self.vertexCount == vertexCount) {
                    self.previewBakedLightmaps = [progressiveMaps mutableCopy];
                    self.previewBakeBrushStats = [progressiveStats mutableCopy];
                    self.previewBakeAccumulatedSamplesPerTexel = accumulatedSamples;
                    [self.previewBakedDebugTextures removeAllObjects];
                    if (self.previewBakeDebugSelectedKey.length == 0 || progressiveMaps[self.previewBakeDebugSelectedKey] == nil) {
                        NSArray<NSString*>* keys = [[progressiveMaps allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
                        self.previewBakeDebugSelectedKey = keys.count > 0 ? keys.firstObject : @"";
                    }
                    self.previewBakedLightingEnabled = progressiveMaps.count > 0;
                    _fullRendererUiState.previewBakeLightingEnabled = self.previewBakedLightingEnabled ? 1 : 0;

                    ViewerMesh progressiveMesh = {0};
                    progressiveMesh.vertices = self.cpuVertices;
                    progressiveMesh.vertexCount = self.vertexCount;
                    progressiveMesh.edgeVertices = self.cpuEdgeVertices;
                    progressiveMesh.edgeVertexCount = self.edgeVertexCount;
                    progressiveMesh.faceRanges = self.faceRanges;
                    progressiveMesh.faceRangeCount = self.faceRangeCount;
                    progressiveMesh.bounds = self.sceneBounds;
                    [self syncHeavyRendererSceneFromMesh:&progressiveMesh];
                    [self.metalView setNeedsDisplay:YES];
                }
            });
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (bakeDispatchFailed) {
                NSLog(@"[lighting] HWRT preview bake aborted after GPU dispatch failure%@",
                      bakeDispatchFailureKey != nil ? [@" on brush " stringByAppendingString:bakeDispatchFailureKey] : @"");
                self.previewBakeInProgress = NO;
                return;
            }

            if (self.meshRevision == revision && self.cpuVertices != NULL && self.vertexCount == vertexCount) {
                self.previewBakedLightmaps = [bakedMaps mutableCopy];
                self.previewBakeBrushStats = [bakedStats mutableCopy];
                self.previewBakeAccumulatedSamplesPerTexel = accumulatedSamples;
                    [self.previewBakedDebugTextures removeAllObjects];
                    if (self.previewBakeDebugSelectedKey.length == 0 || bakedMaps[self.previewBakeDebugSelectedKey] == nil) {
                        NSArray<NSString*>* keys = [[bakedMaps allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
                        self.previewBakeDebugSelectedKey = keys.count > 0 ? keys.firstObject : @"";
                    }
                self.previewBakedLightingEnabled = bakedMaps.count > 0;
                _fullRendererUiState.previewBakeLightingEnabled = self.previewBakedLightingEnabled ? 1 : 0;

                ViewerMesh bakedMesh = {0};
                bakedMesh.vertices = self.cpuVertices;
                bakedMesh.vertexCount = self.vertexCount;
                bakedMesh.edgeVertices = self.cpuEdgeVertices;
                bakedMesh.edgeVertexCount = self.edgeVertexCount;
                bakedMesh.faceRanges = self.faceRanges;
                bakedMesh.faceRangeCount = self.faceRangeCount;
                bakedMesh.bounds = self.sceneBounds;
                [self syncHeavyRendererSceneFromMesh:&bakedMesh];
                NSLog(@"[lighting] HWRT preview bake finished; texel lightmaps applied (%lu brushes)", (unsigned long)bakedMaps.count);
            } else {
                NSLog(@"[lighting] HWRT preview bake discarded because mesh changed during bake");
            }
            self.previewBakeInProgress = NO;
        });

        free(verticesSnapshot);
        free(baseColorSnapshot);
        free(faceRangesSnapshot);
    });
}

- (void)setLightmapDebugWindowVisible:(BOOL)visible {
    self.previewBakeDebugWindowOpen = visible;
    [self.metalView setNeedsDisplay:YES];
}

- (BOOL)isLightmapDebugWindowVisible {
    return self.previewBakeDebugWindowOpen;
}

- (void)syncHeavyRendererSceneFromMesh:(const ViewerMesh*)mesh {
    NovaSceneObjectRecord* objectRecords = NULL;
    char materialNames[UI_MAX_LIGHTS][128] = {{0}};
    float materialColors[UI_MAX_LIGHTS][3] = {{0}};
    uint32_t materialSamples[UI_MAX_LIGHTS] = {0};
    int32_t materialTextureIndices[UI_MAX_LIGHTS];
    int32_t* objectBakedLightmapIndices = NULL;
    uint32_t* objectBrushEntity = NULL;
    uint32_t* objectBrushSolid = NULL;
    uint32_t* objectBrushSide = NULL;
    NSMutableDictionary<NSString*, NSNumber*>* importedTextureIndices = [NSMutableDictionary dictionary];
    NSMutableArray<NSDictionary<NSString*, id>*>* importedTextures = [NSMutableArray array];
    uint32_t objectCount = 0u;
    uint32_t materialCount = 0u;
    uint32_t maxSupportedObjects = UI_MAX_SCENE_OBJECTS;
    NovaSceneImportedRuntime* importedRuntime = nova_scene_world_imported_runtime(self.sceneWorld);

    for (uint32_t index = 0u; index < UI_MAX_LIGHTS; ++index) {
        materialTextureIndices[index] = -1;
    }

    nova_scene_data_release(&_importedSceneData);
    nova_scene_data_init(&_importedSceneData);

    if (self.sceneWorld == NULL || mesh == NULL || mesh->vertices == NULL || mesh->vertexCount == 0 || mesh->faceRanges == NULL || mesh->faceRangeCount == 0) {
        _fullRendererUiState.importedSceneActive = 0;
        if (importedRuntime != NULL) {
            importedRuntime->active = 0u;
            importedRuntime->materialCount = 0u;
            importedRuntime->textureCount = 0u;
            nova_scene_world_sync_objects(self.sceneWorld, NULL, 0u);
        }
        return;
    }

    objectRecords = (NovaSceneObjectRecord*)calloc(mesh->faceRangeCount > 0u ? mesh->faceRangeCount : 1u, sizeof(*objectRecords));
    objectBakedLightmapIndices = (int32_t*)malloc((mesh->faceRangeCount > 0u ? mesh->faceRangeCount : 1u) * sizeof(int32_t));
    objectBrushEntity = (uint32_t*)malloc((mesh->faceRangeCount > 0u ? mesh->faceRangeCount : 1u) * sizeof(uint32_t));
    objectBrushSolid = (uint32_t*)malloc((mesh->faceRangeCount > 0u ? mesh->faceRangeCount : 1u) * sizeof(uint32_t));
    objectBrushSide = (uint32_t*)malloc((mesh->faceRangeCount > 0u ? mesh->faceRangeCount : 1u) * sizeof(uint32_t));
    if (objectRecords == NULL || objectBakedLightmapIndices == NULL || objectBrushEntity == NULL || objectBrushSolid == NULL || objectBrushSide == NULL) {
        _fullRendererUiState.importedSceneActive = 0;
        free(objectRecords);
        free(objectBakedLightmapIndices);
        free(objectBrushEntity);
        free(objectBrushSolid);
        free(objectBrushSide);
        if (importedRuntime != NULL) {
            importedRuntime->active = 0u;
            importedRuntime->materialCount = 0u;
            importedRuntime->textureCount = 0u;
        }
        return;
    }
    for (size_t i = 0; i < (mesh->faceRangeCount > 0u ? mesh->faceRangeCount : 1u); ++i) {
        objectBakedLightmapIndices[i] = -1;
        objectBrushEntity[i] = UINT32_MAX;
        objectBrushSolid[i] = UINT32_MAX;
        objectBrushSide[i] = UINT32_MAX;
    }

    _importedSceneData.vertexCount = (uint32_t)mesh->vertexCount;
    _importedSceneData.primitiveCount = (uint32_t)(mesh->vertexCount / 3u);
    _importedSceneData.objectCount = (uint32_t)mesh->faceRangeCount;
    _importedSceneData.vertices = (NovaSceneVertex*)calloc(_importedSceneData.vertexCount, sizeof(NovaSceneVertex));
    _importedSceneData.primitiveMaterialIndices = (uint32_t*)calloc(_importedSceneData.primitiveCount > 0u ? _importedSceneData.primitiveCount : 1u, sizeof(uint32_t));
    _importedSceneData.objects = (NovaSceneObject*)calloc(_importedSceneData.objectCount, sizeof(NovaSceneObject));
    if (_importedSceneData.vertices == NULL || _importedSceneData.primitiveMaterialIndices == NULL || _importedSceneData.objects == NULL) {
        nova_scene_data_release(&_importedSceneData);
        _fullRendererUiState.importedSceneActive = 0;
        free(objectRecords);
        free(objectBakedLightmapIndices);
        free(objectBrushEntity);
        free(objectBrushSolid);
        free(objectBrushSide);
        return;
    }

    for (size_t faceIndex = 0; faceIndex < mesh->faceRangeCount; ++faceIndex) {
        ViewerFaceRange range = mesh->faceRanges[faceIndex];
        uint32_t materialIndex = 0u;
        Bounds3 objectBounds;

        if (strncmp(range.material, "light_marker", sizeof(range.material)) == 0) {
            continue;
        }

        if (range.vertexStart >= mesh->vertexCount) {
            continue;
        }
        if (range.vertexStart + range.vertexCount > mesh->vertexCount) {
            range.vertexCount = mesh->vertexCount - range.vertexStart;
        }
        range.vertexCount -= range.vertexCount % 3u;
        if (range.vertexCount == 0u) {
            continue;
        }

        for (; materialIndex < materialCount; ++materialIndex) {
            if (strncmp(materialNames[materialIndex], range.material, sizeof(materialNames[materialIndex])) == 0) {
                break;
            }
        }
        if (materialIndex == materialCount) {
            if (materialCount >= UI_MAX_LIGHTS) {
                continue;
            }
            snprintf(materialNames[materialIndex], sizeof(materialNames[materialIndex]), "%s", range.material);
            materialCount += 1u;
        }

        for (size_t vertexOffset = 0; vertexOffset < range.vertexCount; ++vertexOffset) {
            size_t sourceIndex = range.vertexStart + vertexOffset;
            const ViewerVertex* source = &mesh->vertices[sourceIndex];
            NovaSceneVertex* destination = &_importedSceneData.vertices[sourceIndex];
            destination->position[0] = source->position.raw[0];
            destination->position[1] = source->position.raw[1];
            destination->position[2] = source->position.raw[2];
            destination->normal[0] = source->normal.raw[0];
            destination->normal[1] = source->normal.raw[1];
            destination->normal[2] = source->normal.raw[2];
            destination->uv[0] = source->u;
            destination->uv[1] = source->v;
            destination->tangent[0] = 1.0f;
            destination->tangent[1] = 0.0f;
            destination->tangent[2] = 0.0f;
            destination->tangent[3] = 1.0f;
            destination->materialIndex = materialIndex;
            materialColors[materialIndex][0] += source->color.raw[0];
            materialColors[materialIndex][1] += source->color.raw[1];
            materialColors[materialIndex][2] += source->color.raw[2];
            materialSamples[materialIndex] += 1u;
        }

        for (size_t primitiveIndex = 0; primitiveIndex < range.vertexCount / 3u; ++primitiveIndex) {
            _importedSceneData.primitiveMaterialIndices[(range.vertexStart / 3u) + primitiveIndex] = materialIndex;
        }

        objectBounds = viewport_bounds_for_vertex_range(mesh->vertices, range.vertexStart, range.vertexCount);
        if (objectCount > 0u) {
            NovaSceneObject* lastObject = &_importedSceneData.objects[objectCount - 1u];
            NovaSceneObjectRecord* lastRecord = &objectRecords[objectCount - 1u];
            uint32_t lastVertexEnd = lastObject->vertexOffset + lastObject->vertexCount;
            uint32_t currentVertexStart = (uint32_t)range.vertexStart;

            if (currentVertexStart == lastVertexEnd &&
                objectBrushEntity[objectCount - 1u] == (uint32_t)range.entityIndex &&
                objectBrushSolid[objectCount - 1u] == (uint32_t)range.solidIndex &&
                objectBrushSide[objectCount - 1u] == (uint32_t)range.sideIndex) {
                float minX = fminf(lastRecord->aabbMin[0], objectBounds.min.raw[0]);
                float minY = fminf(lastRecord->aabbMin[1], objectBounds.min.raw[1]);
                float minZ = fminf(lastRecord->aabbMin[2], objectBounds.min.raw[2]);
                float maxX = fmaxf(lastRecord->aabbMax[0], objectBounds.max.raw[0]);
                float maxY = fmaxf(lastRecord->aabbMax[1], objectBounds.max.raw[1]);
                float maxZ = fmaxf(lastRecord->aabbMax[2], objectBounds.max.raw[2]);

                lastObject->vertexCount += (uint32_t)range.vertexCount;
                lastObject->primitiveCount += (uint32_t)(range.vertexCount / 3u);
                lastRecord->vertexCount = lastObject->vertexCount;
                lastRecord->primitiveCount = lastObject->primitiveCount;
                lastRecord->aabbMin[0] = minX;
                lastRecord->aabbMin[1] = minY;
                lastRecord->aabbMin[2] = minZ;
                lastRecord->aabbMax[0] = maxX;
                lastRecord->aabbMax[1] = maxY;
                lastRecord->aabbMax[2] = maxZ;
                if (lastRecord->materialIndex != (int)materialIndex) {
                    lastRecord->materialMixed = 1;
                }
                continue;
            }
        }

        snprintf(_importedSceneData.objects[objectCount].name,
             sizeof(_importedSceneData.objects[objectCount].name),
             "face_%zu_%zu_%zu_%zu",
             range.entityIndex,
             range.solidIndex,
             range.sideIndex,
             faceIndex);
        _importedSceneData.objects[objectCount].primitiveOffset = (uint32_t)(range.vertexStart / 3u);
        _importedSceneData.objects[objectCount].primitiveCount = (uint32_t)(range.vertexCount / 3u);
        _importedSceneData.objects[objectCount].vertexOffset = (uint32_t)range.vertexStart;
        _importedSceneData.objects[objectCount].vertexCount = (uint32_t)range.vertexCount;
        viewport_identity_matrix(_importedSceneData.objects[objectCount].worldMatrix);

        snprintf(objectRecords[objectCount].name, sizeof(objectRecords[objectCount].name), "%s", _importedSceneData.objects[objectCount].name);
        viewport_identity_matrix(objectRecords[objectCount].worldMatrix);
        objectRecords[objectCount].aabbMin[0] = objectBounds.min.raw[0];
        objectRecords[objectCount].aabbMin[1] = objectBounds.min.raw[1];
        objectRecords[objectCount].aabbMin[2] = objectBounds.min.raw[2];
        objectRecords[objectCount].aabbMax[0] = objectBounds.max.raw[0];
        objectRecords[objectCount].aabbMax[1] = objectBounds.max.raw[1];
        objectRecords[objectCount].aabbMax[2] = objectBounds.max.raw[2];
        objectRecords[objectCount].vertexOffset = _importedSceneData.objects[objectCount].vertexOffset;
        objectRecords[objectCount].vertexCount = _importedSceneData.objects[objectCount].vertexCount;
        objectRecords[objectCount].primitiveOffset = _importedSceneData.objects[objectCount].primitiveOffset;
        objectRecords[objectCount].primitiveCount = _importedSceneData.objects[objectCount].primitiveCount;
        objectRecords[objectCount].materialIndex = (int)materialIndex;
        objectRecords[objectCount].materialMixed = 0;
        objectRecords[objectCount].bakedLightmap[0] = -1.0f;
        objectRecords[objectCount].bakedLightmap[1] = 0.0f;
        objectRecords[objectCount].bakedLightmap[2] = 0.0f;
        objectBrushEntity[objectCount] = (uint32_t)range.entityIndex;
        objectBrushSolid[objectCount] = (uint32_t)range.solidIndex;
        objectBrushSide[objectCount] = (uint32_t)range.sideIndex;
        objectCount += 1u;
    }

    if (objectCount > maxSupportedObjects) {
        uint32_t originalObjectCount = objectCount;
        uint32_t groupSize = (originalObjectCount + maxSupportedObjects - 1u) / maxSupportedObjects;
        uint32_t mergedCount = 0u;

        for (uint32_t start = 0u; start < originalObjectCount; start += groupSize) {
            uint32_t end = start + groupSize;
            NovaSceneObject mergedObject = _importedSceneData.objects[start];
            NovaSceneObjectRecord mergedRecord = objectRecords[start];
            uint32_t minVertexOffset = mergedObject.vertexOffset;
            uint32_t maxVertexEnd = mergedObject.vertexOffset + mergedObject.vertexCount;
            uint32_t minPrimitiveOffset = mergedObject.primitiveOffset;
            uint32_t maxPrimitiveEnd = mergedObject.primitiveOffset + mergedObject.primitiveCount;
            if (end > originalObjectCount) {
                end = originalObjectCount;
            }

            for (uint32_t sourceIndex = start + 1u; sourceIndex < end; ++sourceIndex) {
                const NovaSceneObject* sourceObject = &_importedSceneData.objects[sourceIndex];
                const NovaSceneObjectRecord* sourceRecord = &objectRecords[sourceIndex];
                uint32_t sourceVertexEnd = sourceObject->vertexOffset + sourceObject->vertexCount;
                uint32_t sourcePrimitiveEnd = sourceObject->primitiveOffset + sourceObject->primitiveCount;

                if (sourceObject->vertexOffset < minVertexOffset) {
                    minVertexOffset = sourceObject->vertexOffset;
                }
                if (sourceVertexEnd > maxVertexEnd) {
                    maxVertexEnd = sourceVertexEnd;
                }
                if (sourceObject->primitiveOffset < minPrimitiveOffset) {
                    minPrimitiveOffset = sourceObject->primitiveOffset;
                }
                if (sourcePrimitiveEnd > maxPrimitiveEnd) {
                    maxPrimitiveEnd = sourcePrimitiveEnd;
                }
                mergedRecord.aabbMin[0] = fminf(mergedRecord.aabbMin[0], sourceRecord->aabbMin[0]);
                mergedRecord.aabbMin[1] = fminf(mergedRecord.aabbMin[1], sourceRecord->aabbMin[1]);
                mergedRecord.aabbMin[2] = fminf(mergedRecord.aabbMin[2], sourceRecord->aabbMin[2]);
                mergedRecord.aabbMax[0] = fmaxf(mergedRecord.aabbMax[0], sourceRecord->aabbMax[0]);
                mergedRecord.aabbMax[1] = fmaxf(mergedRecord.aabbMax[1], sourceRecord->aabbMax[1]);
                mergedRecord.aabbMax[2] = fmaxf(mergedRecord.aabbMax[2], sourceRecord->aabbMax[2]);
                mergedRecord.materialMixed = 1;
                if (objectBrushEntity[sourceIndex] != objectBrushEntity[start] ||
                    objectBrushSolid[sourceIndex] != objectBrushSolid[start] ||
                    objectBrushSide[sourceIndex] != objectBrushSide[start]) {
                    objectBrushEntity[start] = UINT32_MAX;
                    objectBrushSolid[start] = UINT32_MAX;
                    objectBrushSide[start] = UINT32_MAX;
                }
            }

            mergedObject.vertexOffset = minVertexOffset;
            mergedObject.vertexCount = maxVertexEnd - minVertexOffset;
            mergedObject.primitiveOffset = minPrimitiveOffset;
            mergedObject.primitiveCount = maxPrimitiveEnd - minPrimitiveOffset;
            mergedRecord.vertexOffset = mergedObject.vertexOffset;
            mergedRecord.vertexCount = mergedObject.vertexCount;
            mergedRecord.primitiveOffset = mergedObject.primitiveOffset;
            mergedRecord.primitiveCount = mergedObject.primitiveCount;
            mergedRecord.materialMixed = 1;
            mergedRecord.bakedLightmap[0] = -1.0f;
            mergedRecord.bakedLightmap[1] = 0.0f;
            mergedRecord.bakedLightmap[2] = 0.0f;

            _importedSceneData.objects[mergedCount] = mergedObject;
            objectRecords[mergedCount] = mergedRecord;
            objectBrushEntity[mergedCount] = objectBrushEntity[start];
            objectBrushSolid[mergedCount] = objectBrushSolid[start];
            objectBrushSide[mergedCount] = objectBrushSide[start];
            mergedCount += 1u;
        }

        objectCount = mergedCount;
        NSLog(@"Heavy renderer coalesced %u source objects into %u draw objects to stay within runtime object capacity.",
              originalObjectCount,
              objectCount);
    }

    _importedSceneData.objectCount = objectCount;
    _importedSceneData.materialCount = materialCount;
    _importedSceneData.materials = (NovaSceneMaterial*)calloc(materialCount > 0u ? materialCount : 1u, sizeof(NovaSceneMaterial));
    if (_importedSceneData.materials == NULL) {
        nova_scene_data_release(&_importedSceneData);
        _fullRendererUiState.importedSceneActive = 0;
        free(objectRecords);
        free(objectBakedLightmapIndices);
        free(objectBrushEntity);
        free(objectBrushSolid);
        free(objectBrushSide);
        return;
    }

    for (uint32_t materialIndex = 0u; materialIndex < materialCount; ++materialIndex) {
        NSString* materialName = [NSString stringWithUTF8String:materialNames[materialIndex]];
        NSDictionary<NSString*, id>* textureInfo;
        NSNumber* existingTextureIndex;

        if (materialName.length == 0) {
            continue;
        }
        if ([materialName caseInsensitiveCompare:@"nodraw"] == NSOrderedSame ||
            [materialName caseInsensitiveCompare:@"clip"] == NSOrderedSame) {
            continue;
        }

        textureInfo = [self cachedTextureDataForMaterial:materialName];
        if (textureInfo == nil) {
            continue;
        }

        existingTextureIndex = importedTextureIndices[materialName.lowercaseString];
        if (existingTextureIndex == nil) {
            if (importedTextures.count >= UI_MAX_LIGHTS) {
                continue;
            }
            existingTextureIndex = @(importedTextures.count);
            importedTextureIndices[materialName.lowercaseString] = existingTextureIndex;
            [importedTextures addObject:textureInfo];
        }
        materialTextureIndices[materialIndex] = existingTextureIndex.intValue;
    }

    if (self.previewBakedLightingEnabled && self.previewBakedLightmaps.count > 0) {
        NSMutableDictionary<NSString*, NSDictionary<NSString*, id>*>* bakedFaceLookup = [NSMutableDictionary dictionary];
        for (NSString* atlasKey in self.previewBakedLightmaps) {
            NSDictionary<NSString*, id>* atlasInfo = self.previewBakedLightmaps[atlasKey];
            NSDictionary<NSString*, NSArray<NSNumber*>*>* atlasCharts = atlasInfo[@"charts"];
            for (NSString* faceKey in atlasCharts) {
                bakedFaceLookup[faceKey] = @{
                    @"atlasKey": atlasKey,
                    @"chart": atlasCharts[faceKey],
                };
            }
        }

        for (uint32_t objectIndex = 0u; objectIndex < objectCount; ++objectIndex) {
            if (objectBrushEntity[objectIndex] == UINT32_MAX || objectBrushSolid[objectIndex] == UINT32_MAX || objectBrushSide[objectIndex] == UINT32_MAX) {
                continue;
            }

            NSString* faceSideKey = [NSString stringWithFormat:@"brush_%u_%u_%u", objectBrushEntity[objectIndex], objectBrushSolid[objectIndex], objectBrushSide[objectIndex]];
            NSDictionary<NSString*, id>* bakedFaceEntry = bakedFaceLookup[faceSideKey];
            NSString* atlasKey = bakedFaceEntry[@"atlasKey"];
            NSDictionary<NSString*, id>* bakedInfo = atlasKey.length > 0 ? self.previewBakedLightmaps[atlasKey] : nil;
            NSString* bakedTextureKey;
            NSNumber* bakedTextureIndex;
            if (bakedInfo == nil) {
                continue;
            }

            NSArray<NSNumber*>* chartEntry = bakedFaceEntry[@"chart"];
            if (chartEntry == nil || chartEntry.count < 4) {
                continue;
            }

            float atlasW = [bakedInfo[@"width"] floatValue];
            float atlasH = [bakedInfo[@"height"] floatValue];
            float chartX = [chartEntry[0] floatValue];
            float chartY = [chartEntry[1] floatValue];
            float chartW = [chartEntry[2] floatValue];
            float chartH = [chartEntry[3] floatValue];
            float chartOriginU = atlasW > 0.0f ? (chartX + 0.5f) / atlasW : 0.0f;
            float chartOriginV = atlasH > 0.0f ? (chartY + 0.5f) / atlasH : 0.0f;
            float chartScaleU  = atlasW > 0.0f ? fmaxf(chartW - 1.0f, 0.0f) / atlasW : 1.0f;
            float chartScaleV  = atlasH > 0.0f ? fmaxf(chartH - 1.0f, 0.0f) / atlasH : 1.0f;

            bakedTextureKey = [@"__bakeobj__/" stringByAppendingString:atlasKey];
            bakedTextureIndex = importedTextureIndices[bakedTextureKey];
            if (bakedTextureIndex == nil) {
                if (importedTextures.count >= UI_MAX_LIGHTS) {
                    continue;
                }
                bakedTextureIndex = @(importedTextures.count);
                importedTextureIndices[bakedTextureKey] = bakedTextureIndex;
                [importedTextures addObject:bakedInfo];
            }
            objectBakedLightmapIndices[objectIndex] = bakedTextureIndex.intValue;
            objectRecords[objectIndex].bakedLightmap[0] = (float)bakedTextureIndex.intValue;
            objectRecords[objectIndex].bakedLightmap[1] = chartOriginU;
            objectRecords[objectIndex].bakedLightmap[2] = chartOriginV;
            objectRecords[objectIndex].bakedLightmap[3] = chartScaleU;
            objectRecords[objectIndex].bakedLightmap[4] = chartScaleV;
        }
    }

    _importedSceneData.textureCount = (uint32_t)importedTextures.count;
    if (_importedSceneData.textureCount > 0u) {
        _importedSceneData.textures = (NovaSceneTexture*)calloc(_importedSceneData.textureCount, sizeof(NovaSceneTexture));
        if (_importedSceneData.textures == NULL) {
            nova_scene_data_release(&_importedSceneData);
            _fullRendererUiState.importedSceneActive = 0;
            free(objectRecords);
            free(objectBakedLightmapIndices);
            free(objectBrushEntity);
            free(objectBrushSolid);
            free(objectBrushSide);
            return;
        }
        for (uint32_t textureIndex = 0u; textureIndex < _importedSceneData.textureCount; ++textureIndex) {
            NSDictionary<NSString*, id>* textureInfo = importedTextures[textureIndex];
            NSData* rgba8 = textureInfo[@"rgba8"];
            NSData* rgba32f = textureInfo[@"rgba32f"];
            int width = [textureInfo[@"width"] intValue];
            int height = [textureInfo[@"height"] intValue];
            uint32_t format = textureInfo[@"format"] != nil ? (uint32_t)[textureInfo[@"format"] unsignedIntValue] : NOVA_SCENE_TEXTURE_FORMAT_RGBA8_UNORM;
            size_t pixelCount = (size_t)width * (size_t)height;
            unsigned char* pixels = NULL;
            float* pixelsHdr = NULL;

            if (format == NOVA_SCENE_TEXTURE_FORMAT_RGBA32_FLOAT && rgba32f != nil) {
                size_t byteCountHdr = pixelCount * sizeof(float) * 4u;
                pixelsHdr = (float*)malloc(byteCountHdr);
                if (pixelsHdr == NULL) {
                    nova_scene_data_release(&_importedSceneData);
                    _fullRendererUiState.importedSceneActive = 0;
                    free(objectRecords);
                    free(objectBakedLightmapIndices);
                    free(objectBrushEntity);
                    free(objectBrushSolid);
                    free(objectBrushSide);
                    return;
                }
                memcpy(pixelsHdr, rgba32f.bytes, byteCountHdr);
            } else {
                size_t byteCount = pixelCount * 4u;
                pixels = (unsigned char*)malloc(byteCount);
                if (pixels == NULL) {
                    nova_scene_data_release(&_importedSceneData);
                    _fullRendererUiState.importedSceneActive = 0;
                    free(objectRecords);
                    free(objectBakedLightmapIndices);
                    free(objectBrushEntity);
                    free(objectBrushSolid);
                    free(objectBrushSide);
                    return;
                }
                memcpy(pixels, rgba8.bytes, byteCount);
                format = NOVA_SCENE_TEXTURE_FORMAT_RGBA8_UNORM;
            }

            _importedSceneData.textures[textureIndex].format = format;
            _importedSceneData.textures[textureIndex].width = width;
            _importedSceneData.textures[textureIndex].height = height;
            _importedSceneData.textures[textureIndex].rgba8 = pixels;
            _importedSceneData.textures[textureIndex].rgba32f = pixelsHdr;
        }
    }

    importedRuntime->active = objectCount > 0u ? 1u : 0u;
    importedRuntime->materialCount = materialCount;
    importedRuntime->textureCount = _importedSceneData.textureCount;
    importedRuntime->usesBuiltinMaterialSet = 0u;
    importedRuntime->rtAsUpdatePending = 1u;
    memset(importedRuntime->materialsCpu, 0, sizeof(importedRuntime->materialsCpu));
    memset(importedRuntime->materialRecords, 0, sizeof(importedRuntime->materialRecords));
    memset(importedRuntime->blasPrimitiveOffset, 0, sizeof(importedRuntime->blasPrimitiveOffset));
    memset(importedRuntime->blasVertexOffset, 0, sizeof(importedRuntime->blasVertexOffset));
    memset(importedRuntime->blasVertexCount, 0, sizeof(importedRuntime->blasVertexCount));
    memset(importedRuntime->blasFlags, 0, sizeof(importedRuntime->blasFlags));
    memset(importedRuntime->instanceBlasIndex, 0, sizeof(importedRuntime->instanceBlasIndex));

    for (uint32_t materialIndex = 0u; materialIndex < materialCount; ++materialIndex) {
        float sampleCount = materialSamples[materialIndex] > 0u ? (float)materialSamples[materialIndex] : 1.0f;
        NovaSceneMaterial* material = &_importedSceneData.materials[materialIndex];
        NovaSceneGpuMaterial* materialGpu = &importedRuntime->materialsCpu[materialIndex];
        NovaSceneImportedMaterialRecord* materialRecord = &importedRuntime->materialRecords[materialIndex];
        int32_t textureIndex = materialTextureIndices[materialIndex];
        float logicalTextureSize = -1.0f;
        float baseColorR = materialColors[materialIndex][0] / sampleCount;
        float baseColorG = materialColors[materialIndex][1] / sampleCount;
        float baseColorB = materialColors[materialIndex][2] / sampleCount;

        if (textureIndex >= 0 && strncmp(materialNames[materialIndex], "dev_", 4) == 0) {
            logicalTextureSize = 256.0f;
        }

        if (textureIndex >= 0) {
            baseColorR = 1.0f;
            baseColorG = 1.0f;
            baseColorB = 1.0f;
        }

        snprintf(material->name, sizeof(material->name), "%s", materialNames[materialIndex]);
        material->baseColorFactor[0] = baseColorR;
        material->baseColorFactor[1] = baseColorG;
        material->baseColorFactor[2] = baseColorB;
        material->baseColorFactor[3] = 1.0f;
        material->roughness = 1.0f;
        material->ior = 1.45f;
        material->baseColorTexture = textureIndex;
        material->metallicRoughnessTexture = -1;
        material->normalTexture = -1;
        material->emissiveTexture = -1;
        material->occlusionTexture = -1;
        material->transmissionTexture = -1;
        material->normalScale = 1.0f;
        material->alphaCutoff = 0.5f;
        material->alphaMode = textureIndex >= 0 ? 1 : 0;
        snprintf(materialRecord->name, sizeof(materialRecord->name), "%s", materialNames[materialIndex]);
        materialRecord->baseColor[0] = material->baseColorFactor[0];
        materialRecord->baseColor[1] = material->baseColorFactor[1];
        materialRecord->baseColor[2] = material->baseColorFactor[2];
        materialRecord->baseColor[3] = 1.0f;
        materialRecord->roughness = 1.0f;
        materialRecord->ior = 1.45f;
        viewport_init_imported_material_gpu_defaults(materialGpu);
        materialGpu->baseColor[0] = material->baseColorFactor[0];
        materialGpu->baseColor[1] = material->baseColorFactor[1];
        materialGpu->baseColor[2] = material->baseColorFactor[2];
        materialGpu->baseColor[3] = 1.0f;
        materialGpu->params[1] = 1.0f;
        materialGpu->params[3] = 1.45f;
        materialGpu->texIndices[0] = (float)textureIndex;
        materialGpu->extra[1] = -1.0f;
        materialGpu->emissive[3] = logicalTextureSize;
    }

    for (uint32_t objectIndex = 0u; objectIndex < objectCount; ++objectIndex) {
        objectRecords[objectIndex].sceneObjectIndex = objectIndex;
        objectRecords[objectIndex].blasIndex = objectIndex;
        importedRuntime->instanceBlasIndex[objectIndex] = objectIndex;
        importedRuntime->blasPrimitiveOffset[objectIndex] = objectRecords[objectIndex].primitiveOffset;
        importedRuntime->blasVertexOffset[objectIndex] = objectRecords[objectIndex].vertexOffset;
        importedRuntime->blasVertexCount[objectIndex] = objectRecords[objectIndex].vertexCount;
        importedRuntime->blasFlags[objectIndex] = objectRecords[objectIndex].flags;
    }

    nova_scene_world_sync_objects(self.sceneWorld, objectRecords, objectCount);
    _fullRendererUiState.importedSceneActive = objectCount > 0u ? 1 : 0;
    free(objectRecords);
    free(objectBakedLightmapIndices);
    free(objectBrushEntity);
    free(objectBrushSolid);
    free(objectBrushSide);
}

- (void)frameScene {
    if (!bounds3_is_valid(self.sceneBounds)) {
        self.target = vec3_make(0.0f, 0.0f, 0.0f);
        self.distance = 1024.0f;
        self.orthoCenter = self.target;
        self.orthoSize = 2048.0f;
        return;
    }

    Vec3 size = bounds3_size(self.sceneBounds);
    float radius = fmaxf(vec3_length(size) * 0.5f, 64.0f);
    self.target = bounds3_center(self.sceneBounds);
    self.distance = radius * 2.1f;
    self.freeLookPosition = [self cameraPosition];
    self.orthoCenter = self.target;
    self.orthoSize = fmaxf(fmaxf(size.raw[0], fmaxf(size.raw[1], size.raw[2])) * 1.15f, 256.0f);
    [self.overlayView setNeedsDisplay:YES];
}

- (void)setMovementForward:(BOOL)forward backward:(BOOL)backward left:(BOOL)left right:(BOOL)right {
    CameraMovement movementMask = 0;
    if (forward) {
        movementMask |= CameraMovementForward;
    }
    if (backward) {
        movementMask |= CameraMovementBackward;
    }
    if (left) {
        movementMask |= CameraMovementLeft;
    }
    if (right) {
        movementMask |= CameraMovementRight;
    }
    self.movementMask = movementMask;
}

- (Vec3)forwardVector {
    float cosPitch = cosf(self.pitch);
    return vec3_normalize(vec3_make(
        -cosPitch * cosf(self.yaw),
        -cosPitch * sinf(self.yaw),
        -sinf(self.pitch)
    ));
}

- (Vec3)rightVector {
    return vec3_normalize(vec3_cross([self forwardVector], world_up()));
}

- (Vec3)cameraPosition {
    if (self.freeLookActive) {
        return self.freeLookPosition;
    }

    float cosPitch = cosf(self.pitch);
    Vec3 offset = vec3_make(
        self.distance * cosPitch * cosf(self.yaw),
        self.distance * cosPitch * sinf(self.yaw),
        self.distance * sinf(self.pitch)
    );
    return vec3_add(self.target, offset);
}

- (Vec3)cameraTarget {
    if (self.freeLookActive) {
        return vec3_add(self.freeLookPosition, [self forwardVector]);
    }
    return self.target;
}

- (Mat4)projectionMatrixForAspect:(float)aspect {
    if (self.dimension == VmfViewportDimension3D) {
        return cglm_mat4_perspective(kViewportPerspectiveFovRadians, aspect, 1.0f, 131072.0f);
    }

    float halfHeight = self.orthoSize * 0.5f;
    float halfWidth = halfHeight * aspect;
    return cglm_mat4_ortho(-halfWidth, halfWidth, -halfHeight, halfHeight, -131072.0f, 131072.0f);
}

- (Mat4)viewMatrixWithCameraPosition:(Vec3*)outCameraPosition {
    if (self.dimension == VmfViewportDimension3D) {
        Vec3 eye = [self cameraPosition];
        if (outCameraPosition) {
            *outCameraPosition = eye;
        }
        return cglm_mat4_look_at(eye, [self cameraTarget], world_up());
    }

    Vec3 forward = plane_forward(self.plane);
    Vec3 up = plane_up(self.plane);
    Vec3 eye = vec3_sub(self.orthoCenter, vec3_scale(forward, 4096.0f));
    if (outCameraPosition) {
        *outCameraPosition = eye;
    }
    return cglm_mat4_look_at(eye, self.orthoCenter, up);
}

- (Uniforms)uniformsForAspect:(float)aspect {
    Vec3 eye;
    Mat4 projection = [self projectionMatrixForAspect:aspect];
    Mat4 viewMatrix = [self viewMatrixWithCameraPosition:&eye];
    Uniforms uniforms = {0};
    copy_mat4_to_uniform(uniforms.viewProjection, cglm_mat4_mul(projection, viewMatrix));
    uniforms.cameraPosition[0] = eye.raw[0];
    uniforms.cameraPosition[1] = eye.raw[1];
    uniforms.cameraPosition[2] = eye.raw[2];
    uniforms.lightDirectionIntensity[0] = -0.45f;
    uniforms.lightDirectionIntensity[1] = -0.25f;
    uniforms.lightDirectionIntensity[2] = 0.85f;
    uniforms.lightDirectionIntensity[3] = self.primaryLightIntensity;
    uniforms.lightPositionRange[0] = self.primaryLightPosition.raw[0];
    uniforms.lightPositionRange[1] = self.primaryLightPosition.raw[1];
    uniforms.lightPositionRange[2] = self.primaryLightPosition.raw[2];
    uniforms.lightPositionRange[3] = self.primaryLightRange;
    uniforms.lightColor[0] = self.primaryLightColor.raw[0];
    uniforms.lightColor[1] = self.primaryLightColor.raw[1];
    uniforms.lightColor[2] = self.primaryLightColor.raw[2];
    uniforms.lightColor[3] = 1.0f;
    uniforms.colorTint[0] = 1.0f;
    uniforms.colorTint[1] = 1.0f;
    uniforms.colorTint[2] = 1.0f;
    uniforms.colorTint[3] = 1.0f;
    uniforms.flags[0] = self.primaryLightEnabled ? 1u : 0u;
    uniforms.flags[1] = self.previewBakedLightingEnabled ? 2u : 0u;
    uniforms.flags[2] = (self.dimension == VmfViewportDimension3D && self.renderMode == VmfViewportRenderModeShaded) ? 1u : 0u;
    uniforms.flags[3] = 0u;
    return uniforms;
}

- (void)setPrimaryLightPosition:(Vec3)position color:(Vec3)color intensity:(float)intensity range:(float)range enabled:(BOOL)enabled {
    self.primaryLightPosition = position;
    self.primaryLightColor = color;
    self.primaryLightIntensity = intensity;
    self.primaryLightRange = range;
    self.primaryLightEnabled = enabled;
}

- (void)updateFreeLookWithDeltaTime:(CFTimeInterval)deltaTime {
    if (!self.freeLookActive || self.movementMask == 0) {
        return;
    }

    Vec3 forward = [self forwardVector];
    Vec3 right = [self rightVector];
    Vec3 up = world_up();
    Vec3 movement = vec3_make(0.0f, 0.0f, 0.0f);
    if (self.movementMask & CameraMovementForward) {
        movement = vec3_add(movement, forward);
    }
    if (self.movementMask & CameraMovementBackward) {
        movement = vec3_sub(movement, forward);
    }
    if (self.movementMask & CameraMovementRight) {
        movement = vec3_add(movement, right);
    }
    if (self.movementMask & CameraMovementLeft) {
        movement = vec3_sub(movement, right);
    }
    if (self.movementMask & CameraMovementUp) {
        movement = vec3_add(movement, up);
    }
    if (self.movementMask & CameraMovementDown) {
        movement = vec3_sub(movement, up);
    }
    if (vec3_length(movement) < 1e-5f) {
        return;
    }

    float speed = fmaxf(self.distance * 0.25f, 76.8f);
    self.freeLookPosition = vec3_add(self.freeLookPosition, vec3_scale(vec3_normalize(movement), speed * (float)deltaTime));
}

- (void)updateOrbitTargetLerpWithDeltaTime:(CFTimeInterval)deltaTime {
    if (!self.orbitLerpActive || self.dimension != VmfViewportDimension3D || self.freeLookActive) {
        return;
    }

    float dt = (float)fmax(deltaTime, 0.0);
    float t = 1.0f - expf(-10.0f * dt);
    self.target = vec3_lerp(self.target, self.orbitLerpTarget, t);

    if (vec3_length(vec3_sub(self.orbitLerpTarget, self.target)) < 0.5f) {
        self.target = self.orbitLerpTarget;
        self.orbitLerpActive = NO;
    }
}

- (void)zoomByDelta:(float)delta {
    float zoomFactor = expf(delta * 0.1f);
    if (self.dimension == VmfViewportDimension3D) {
        self.distance *= zoomFactor;
        return;
    }
    self.orthoSize *= zoomFactor;
    [self.overlayView setNeedsDisplay:YES];
}

- (void)panOrOrbitByDeltaX:(float)deltaX deltaY:(float)deltaY {
    if (self.dimension == VmfViewportDimension3D) {
        if (self.freeLookActive) {
            return;
        }
        self.yaw -= deltaX * 0.002f;
        self.pitch = fminf(fmaxf(self.pitch - deltaY * 0.002f, -1.45f), 1.45f);
        return;
    }

    float viewportHeight = fmaxf(self.metalView.bounds.size.height, 1.0f);
    float worldPerPoint = self.orthoSize / viewportHeight;
    Vec3 horizontal = vec3_scale(plane_right(self.plane), -deltaX * worldPerPoint);
    Vec3 vertical = vec3_scale(plane_up(self.plane), -deltaY * worldPerPoint);
    self.orthoCenter = vec3_add(self.orthoCenter, vec3_add(horizontal, vertical));
    [self.overlayView setNeedsDisplay:YES];
}

- (float)visibleWidth {
    float height = fmaxf(self.metalView.bounds.size.height, 1.0f);
    float width = fmaxf(self.metalView.bounds.size.width, 1.0f);
    return self.orthoSize * (width / height);
}

- (Vec3)snappedWorldPointForViewPoint:(NSPoint)point {
    Vec3 axisU = plane_right(self.plane);
    Vec3 axisV = plane_up(self.plane);
    float centerU = plane_u_value(self.plane, self.orthoCenter);
    float centerV = plane_v_value(self.plane, self.orthoCenter);
    Vec3 planeOrigin = vec3_sub(self.orthoCenter, vec3_add(vec3_scale(axisU, centerU), vec3_scale(axisV, centerV)));
    float u = centerU + ((float)(point.x / fmax(self.metalView.bounds.size.width, 1.0)) - 0.5f) * [self visibleWidth];
    float v = centerV + ((float)(point.y / fmax(self.metalView.bounds.size.height, 1.0)) - 0.5f) * self.orthoSize;
    u = snap_to_grid(u, (float)self.gridSize);
    v = snap_to_grid(v, (float)self.gridSize);
    return vec3_add(planeOrigin, vec3_add(vec3_scale(axisU, u), vec3_scale(axisV, v)));
}

- (Vec3)snappedWorldPointForViewPoint:(NSPoint)point preservingHiddenAxisFrom:(Vec3)referencePoint {
    Vec3 snappedPoint = [self snappedWorldPointForViewPoint:point];
    switch (self.plane) {
        case VmfViewportPlaneXY:
            snappedPoint.raw[2] = referencePoint.raw[2];
            break;
        case VmfViewportPlaneXZ:
            snappedPoint.raw[1] = referencePoint.raw[1];
            break;
        case VmfViewportPlaneZY:
            snappedPoint.raw[0] = referencePoint.raw[0];
            break;
    }
    return snappedPoint;
}

- (NSPoint)viewPointForWorldPoint:(Vec3)point {
    float width = fmaxf(self.metalView.bounds.size.width, 1.0f);
    float height = fmaxf(self.metalView.bounds.size.height, 1.0f);
    float visibleWidth = [self visibleWidth];
    float centerU = plane_u_value(self.plane, self.orthoCenter);
    float centerV = plane_v_value(self.plane, self.orthoCenter);
    float u = plane_u_value(self.plane, point);
    float v = plane_v_value(self.plane, point);
    return NSMakePoint(((u - centerU) / visibleWidth + 0.5f) * width,
                       ((v - centerV) / self.orthoSize + 0.5f) * height);
}

- (NSRect)screenRectForBounds:(Bounds3)bounds {
    if (!bounds3_is_valid(bounds)) {
        return NSZeroRect;
    }
    Bounds3 normalized = normalized_bounds(bounds);
    float width = fmaxf(self.metalView.bounds.size.width, 1.0f);
    float height = fmaxf(self.metalView.bounds.size.height, 1.0f);
    float visibleWidth = [self visibleWidth];
    float centerU = plane_u_value(self.plane, self.orthoCenter);
    float centerV = plane_v_value(self.plane, self.orthoCenter);
    float minU = plane_u_value(self.plane, normalized.min);
    float maxU = plane_u_value(self.plane, normalized.max);
    float minV = plane_v_value(self.plane, normalized.min);
    float maxV = plane_v_value(self.plane, normalized.max);

    float left = ((minU - centerU) / visibleWidth + 0.5f) * width;
    float right = ((maxU - centerU) / visibleWidth + 0.5f) * width;
    float bottom = ((minV - centerV) / self.orthoSize + 0.5f) * height;
    float top = ((maxV - centerV) / self.orthoSize + 0.5f) * height;
    return NSMakeRect(fmin(left, right), fmin(bottom, top), fabsf(right - left), fabsf(top - bottom));
}

- (Vec3)rayDirectionForViewPoint:(NSPoint)point {
    float width = fmaxf(self.metalView.bounds.size.width, 1.0f);
    float height = fmaxf(self.metalView.bounds.size.height, 1.0f);
    float aspect = width / height;
    float ndcX = (2.0f * (float)point.x / width) - 1.0f;
    float ndcY = (2.0f * (float)point.y / height) - 1.0f;
    float tanHalfFov = tanf(kViewportPerspectiveFovRadians * 0.5f);
    Vec3 forward = [self forwardVector];
    Vec3 right = [self rightVector];
    Vec3 up = vec3_normalize(vec3_cross(right, forward));
    Vec3 direction = vec3_add(forward,
                              vec3_add(vec3_scale(right, ndcX * aspect * tanHalfFov),
                                       vec3_scale(up, ndcY * tanHalfFov)));
    return vec3_normalize(direction);
}

- (ViewportHandle)handleAtPoint:(NSPoint)point {
    if (!self.selectionVisible || self.dimension != VmfViewportDimension2D) {
        return ViewportHandleNone;
    }
    NSRect rect = [self screenRectForBounds:self.selectionBounds];
    if (self.selectionEditable) {
        const CGFloat handleSize = 10.0;
        NSRect corners[4] = {
            NSMakeRect(NSMinX(rect) - handleSize * 0.5, NSMinY(rect) - handleSize * 0.5, handleSize, handleSize),
            NSMakeRect(NSMaxX(rect) - handleSize * 0.5, NSMinY(rect) - handleSize * 0.5, handleSize, handleSize),
            NSMakeRect(NSMaxX(rect) - handleSize * 0.5, NSMaxY(rect) - handleSize * 0.5, handleSize, handleSize),
            NSMakeRect(NSMinX(rect) - handleSize * 0.5, NSMaxY(rect) - handleSize * 0.5, handleSize, handleSize),
        };
        NSRect midpoints[4] = {
            NSMakeRect(NSMinX(rect) - handleSize * 0.5, NSMidY(rect) - handleSize * 0.5, handleSize, handleSize),
            NSMakeRect(NSMaxX(rect) - handleSize * 0.5, NSMidY(rect) - handleSize * 0.5, handleSize, handleSize),
            NSMakeRect(NSMidX(rect) - handleSize * 0.5, NSMinY(rect) - handleSize * 0.5, handleSize, handleSize),
            NSMakeRect(NSMidX(rect) - handleSize * 0.5, NSMaxY(rect) - handleSize * 0.5, handleSize, handleSize),
        };
        if (NSPointInRect(point, corners[0])) {
            return ViewportHandleMinUMinV;
        }
        if (NSPointInRect(point, corners[1])) {
            return ViewportHandleMaxUMinV;
        }
        if (NSPointInRect(point, corners[2])) {
            return ViewportHandleMaxUMaxV;
        }
        if (NSPointInRect(point, corners[3])) {
            return ViewportHandleMinUMaxV;
        }
        if (NSPointInRect(point, midpoints[0])) {
            return ViewportHandleMinUMidV;
        }
        if (NSPointInRect(point, midpoints[1])) {
            return ViewportHandleMaxUMidV;
        }
        if (NSPointInRect(point, midpoints[2])) {
            return ViewportHandleMidUMinV;
        }
        if (NSPointInRect(point, midpoints[3])) {
            return ViewportHandleMidUMaxV;
        }
    }
    if (NSPointInRect(point, NSInsetRect(rect, -3.0, -3.0))) {
        return ViewportHandleBody;
    }
    return ViewportHandleNone;
}

- (VmfViewportSelectionEdge)selectionEdgeAtPoint:(NSPoint)point {
    if (!self.selectionVisible || !self.selectionEditable || self.dimension != VmfViewportDimension2D) {
        return VmfViewportSelectionEdgeNone;
    }

    NSRect rect = [self screenRectForBounds:self.selectionBounds];
    if (NSIsEmptyRect(rect)) {
        return VmfViewportSelectionEdgeNone;
    }

    const CGFloat threshold = 8.0;
    CGFloat distanceMinU = fabs(point.x - NSMinX(rect));
    CGFloat distanceMaxU = fabs(point.x - NSMaxX(rect));
    CGFloat distanceMinV = fabs(point.y - NSMinY(rect));
    CGFloat distanceMaxV = fabs(point.y - NSMaxY(rect));
    CGFloat bestDistance = threshold;
    VmfViewportSelectionEdge bestEdge = VmfViewportSelectionEdgeNone;

    if (point.y >= NSMinY(rect) - threshold && point.y <= NSMaxY(rect) + threshold && distanceMinU <= bestDistance) {
        bestDistance = distanceMinU;
        bestEdge = VmfViewportSelectionEdgeMinU;
    }
    if (point.y >= NSMinY(rect) - threshold && point.y <= NSMaxY(rect) + threshold && distanceMaxU <= bestDistance) {
        bestDistance = distanceMaxU;
        bestEdge = VmfViewportSelectionEdgeMaxU;
    }
    if (point.x >= NSMinX(rect) - threshold && point.x <= NSMaxX(rect) + threshold && distanceMinV <= bestDistance) {
        bestDistance = distanceMinV;
        bestEdge = VmfViewportSelectionEdgeMinV;
    }
    if (point.x >= NSMinX(rect) - threshold && point.x <= NSMaxX(rect) + threshold && distanceMaxV <= bestDistance) {
        bestEdge = VmfViewportSelectionEdgeMaxV;
    }
    return bestEdge;
}

- (NSInteger)vertexIndexAtPoint:(NSPoint)point {
    if (!self.selectionVisible || self.dimension != VmfViewportDimension2D || !self.selectionVertices || self.selectionVertexCount == 0) {
        return -1;
    }

    const CGFloat threshold = 8.0;
    CGFloat bestDistance = threshold;
    NSInteger bestIndex = -1;
    for (size_t vertexIndex = 0; vertexIndex < self.selectionVertexCount; ++vertexIndex) {
        NSPoint vertexPoint = [self viewPointForWorldPoint:self.selectionVertices[vertexIndex]];
        CGFloat distance = hypot(point.x - vertexPoint.x, point.y - vertexPoint.y);
        if (distance <= bestDistance) {
            bestDistance = distance;
            bestIndex = (NSInteger)vertexIndex;
        }
    }
    return bestIndex;
}

- (NSUInteger)vertexIndicesAtPoint:(NSPoint)point outIndices:(size_t*)outIndices maxCount:(NSUInteger)maxCount {
    if (!self.selectionVisible || self.dimension != VmfViewportDimension2D || !self.selectionVertices || self.selectionVertexCount == 0 || !outIndices || maxCount == 0) {
        return 0;
    }

    // First find the best (closest) index
    NSInteger bestIndex = [self vertexIndexAtPoint:point];
    if (bestIndex < 0) {
        return 0;
    }

    // Now find the 2D screen position of that best vertex and collect all vertices
    // within a small screen tolerance of that exact 2D position (stacked vertices).
    NSPoint bestScreenPt = [self viewPointForWorldPoint:self.selectionVertices[(size_t)bestIndex]];
    const CGFloat stackThreshold = 2.0;
    NSUInteger count = 0;
    for (size_t vertexIndex = 0; vertexIndex < self.selectionVertexCount && count < maxCount; ++vertexIndex) {
        NSPoint screenPt = [self viewPointForWorldPoint:self.selectionVertices[vertexIndex]];
        CGFloat dist = hypot(screenPt.x - bestScreenPt.x, screenPt.y - bestScreenPt.y);
        if (dist <= stackThreshold) {
            outIndices[count++] = vertexIndex;
        }
    }
    return count;
}

- (NSInteger)edgeIndexAtPoint:(NSPoint)point {
    if (!self.selectionVisible || self.dimension != VmfViewportDimension2D || !self.selectionEdges || self.selectionEdgeCount == 0) {
        return -1;
    }

    const CGFloat threshold = 7.0;
    CGFloat bestDistance = threshold;
    NSInteger bestIndex = -1;
    for (size_t edgeIndex = 0; edgeIndex < self.selectionEdgeCount; ++edgeIndex) {
        const VmfSolidEdge* edge = &self.selectionEdges[edgeIndex];
        if (edge->endpointCount < 2) {
            continue;
        }
        NSPoint start = [self viewPointForWorldPoint:edge->start];
        NSPoint end = [self viewPointForWorldPoint:edge->end];
        CGFloat segmentDx = end.x - start.x;
        CGFloat segmentDy = end.y - start.y;
        CGFloat segmentLengthSquared = segmentDx * segmentDx + segmentDy * segmentDy;
        if (segmentLengthSquared < 16.0) {
            continue;
        }
        CGFloat t = ((point.x - start.x) * segmentDx + (point.y - start.y) * segmentDy) / segmentLengthSquared;
        t = fmax(0.0, fmin(1.0, t));
        CGFloat closestX = start.x + segmentDx * t;
        CGFloat closestY = start.y + segmentDy * t;
        CGFloat distance = hypot(point.x - closestX, point.y - closestY);
        if (distance <= bestDistance) {
            bestDistance = distance;
            bestIndex = (NSInteger)edgeIndex;
        }
    }
    return bestIndex;
}

- (Bounds3)boundsForBlockFromAnchor:(Vec3)anchor current:(Vec3)current {
    Bounds3 bounds = bounds3_empty();
    bounds3_expand(&bounds, anchor);
    bounds3_expand(&bounds, current);
    bounds = normalized_bounds(bounds);
    switch (self.plane) {
        case VmfViewportPlaneXY:
            bounds.min.raw[2] = snap_to_grid(self.orthoCenter.raw[2] - (float)self.gridSize * 2.0f, (float)self.gridSize);
            bounds.max.raw[2] = snap_to_grid(self.orthoCenter.raw[2] + (float)self.gridSize * 2.0f, (float)self.gridSize);
            break;
        case VmfViewportPlaneXZ:
            bounds.min.raw[1] = snap_to_grid(self.orthoCenter.raw[1] - (float)self.gridSize * 2.0f, (float)self.gridSize);
            bounds.max.raw[1] = snap_to_grid(self.orthoCenter.raw[1] + (float)self.gridSize * 2.0f, (float)self.gridSize);
            break;
        case VmfViewportPlaneZY:
            bounds.min.raw[0] = snap_to_grid(self.orthoCenter.raw[0] - (float)self.gridSize * 2.0f, (float)self.gridSize);
            bounds.max.raw[0] = snap_to_grid(self.orthoCenter.raw[0] + (float)self.gridSize * 2.0f, (float)self.gridSize);
            break;
    }
    return bounds;
}

- (Bounds3)translatedBoundsFromOriginal:(Bounds3)original current:(Vec3)current {
    Bounds3 result = original;
    Vec3 delta = vec3_sub(current, self.dragAnchorWorld);
    switch (self.plane) {
        case VmfViewportPlaneXY:
            delta.raw[2] = 0.0f;
            break;
        case VmfViewportPlaneXZ:
            delta.raw[1] = 0.0f;
            break;
        case VmfViewportPlaneZY:
            delta.raw[0] = 0.0f;
            break;
    }
    result.min = vec3_add(result.min, delta);
    result.max = vec3_add(result.max, delta);
    return normalized_bounds(result);
}

- (Bounds3)resizedBoundsFromOriginal:(Bounds3)original current:(Vec3)current {
    Bounds3 result = original;
    float u = plane_u_value(self.plane, current);
    float v = plane_v_value(self.plane, current);
    BOOL affectsMinU = self.activeHandle == ViewportHandleMinUMinV || self.activeHandle == ViewportHandleMinUMaxV || self.activeHandle == ViewportHandleMinUMidV;
    BOOL affectsMaxU = self.activeHandle == ViewportHandleMaxUMinV || self.activeHandle == ViewportHandleMaxUMaxV || self.activeHandle == ViewportHandleMaxUMidV;
    BOOL affectsMinV = self.activeHandle == ViewportHandleMinUMinV || self.activeHandle == ViewportHandleMaxUMinV || self.activeHandle == ViewportHandleMidUMinV;
    BOOL affectsMaxV = self.activeHandle == ViewportHandleMinUMaxV || self.activeHandle == ViewportHandleMaxUMaxV || self.activeHandle == ViewportHandleMidUMaxV;
    switch (self.plane) {
        case VmfViewportPlaneXY:
            if (affectsMinU) {
                result.min.raw[0] = adjusted_dragged_edge(u, original.max.raw[0], (float)self.gridSize, u >= original.max.raw[0]);
            }
            if (affectsMaxU) {
                result.max.raw[0] = adjusted_dragged_edge(u, original.min.raw[0], (float)self.gridSize, u >= original.min.raw[0]);
            }
            if (affectsMinV) {
                result.min.raw[1] = adjusted_dragged_edge(v, original.max.raw[1], (float)self.gridSize, v >= original.max.raw[1]);
            }
            if (affectsMaxV) {
                result.max.raw[1] = adjusted_dragged_edge(v, original.min.raw[1], (float)self.gridSize, v >= original.min.raw[1]);
            }
            break;
        case VmfViewportPlaneXZ:
            if (affectsMinU) {
                result.min.raw[0] = adjusted_dragged_edge(u, original.max.raw[0], (float)self.gridSize, u >= original.max.raw[0]);
            }
            if (affectsMaxU) {
                result.max.raw[0] = adjusted_dragged_edge(u, original.min.raw[0], (float)self.gridSize, u >= original.min.raw[0]);
            }
            if (affectsMinV) {
                result.min.raw[2] = adjusted_dragged_edge(v, original.max.raw[2], (float)self.gridSize, v >= original.max.raw[2]);
            }
            if (affectsMaxV) {
                result.max.raw[2] = adjusted_dragged_edge(v, original.min.raw[2], (float)self.gridSize, v >= original.min.raw[2]);
            }
            break;
        case VmfViewportPlaneZY:
            if (affectsMinU) {
                result.min.raw[1] = adjusted_dragged_edge(u, original.max.raw[1], (float)self.gridSize, u >= original.max.raw[1]);
            }
            if (affectsMaxU) {
                result.max.raw[1] = adjusted_dragged_edge(u, original.min.raw[1], (float)self.gridSize, u >= original.min.raw[1]);
            }
            if (affectsMinV) {
                result.min.raw[2] = adjusted_dragged_edge(v, original.max.raw[2], (float)self.gridSize, v >= original.max.raw[2]);
            }
            if (affectsMaxV) {
                result.max.raw[2] = adjusted_dragged_edge(v, original.min.raw[2], (float)self.gridSize, v >= original.min.raw[2]);
            }
            break;
    }
    return result;
}

- (void)drawEditorOverlay {
    if (self.dimension != VmfViewportDimension2D) {
        return;
    }

    if (self.creationVisible) {
        NSRect previewRect = [self screenRectForBounds:self.creationBounds];
        [[NSColor colorWithCalibratedRed:0.26 green:0.78 blue:0.48 alpha:0.95] setStroke];
        NSBezierPath* previewPath = [NSBezierPath bezierPathWithRect:previewRect];
        CGFloat dashes[2] = { 6.0, 4.0 };
        [previewPath setLineDash:dashes count:2 phase:0.0];
        previewPath.lineWidth = 1.5;
        [previewPath stroke];
    }

    if (self.pluginDebugVisible) {
        NSRect debugRect = [self screenRectForBounds:self.pluginDebugBounds];
        if (!NSIsEmptyRect(debugRect)) {
            [[NSColor colorWithCalibratedRed:1.0 green:0.68 blue:0.18 alpha:0.10] setFill];
            NSRectFill(debugRect);

            [[NSColor colorWithCalibratedRed:1.0 green:0.68 blue:0.18 alpha:0.95] setStroke];
            NSBezierPath* debugPath = [NSBezierPath bezierPathWithRect:debugRect];
            CGFloat dashes[2] = { 10.0, 6.0 };
            [debugPath setLineDash:dashes count:2 phase:0.0];
            debugPath.lineWidth = 2.0;
            [debugPath stroke];
        }
    }

    if (self.clipGuideVisible) {
        NSPoint start = [self viewPointForWorldPoint:self.clipGuideStart];
        NSPoint end = [self viewPointForWorldPoint:self.clipGuideEnd];
        NSPoint clipStart = start;
        NSPoint clipEnd = end;
        BOOL hasInteriorSegment = NO;
        BOOL startInside = NO;
        BOOL endInside = NO;
        NSPoint segmentIntersections[4];
        CGFloat segmentIntersectionTs[4];
        NSUInteger segmentIntersectionCount = 0;
        if (self.selectionVisible) {
            NSRect selectionRect = [self screenRectForBounds:self.selectionBounds];
            NSPoint corners[4] = {
                NSMakePoint(NSMinX(selectionRect), NSMinY(selectionRect)),
                NSMakePoint(NSMaxX(selectionRect), NSMinY(selectionRect)),
                NSMakePoint(NSMaxX(selectionRect), NSMaxY(selectionRect)),
                NSMakePoint(NSMinX(selectionRect), NSMaxY(selectionRect)),
            };
            NSPoint lineIntersections[4];
            CGFloat lineIntersectionTs[4];
            NSUInteger lineIntersectionCount = 0;
            for (NSUInteger index = 0; index < 4; ++index) {
                NSPoint a = corners[index];
                NSPoint b = corners[(index + 1) % 4];
                CGFloat lineDx = end.x - start.x;
                CGFloat lineDy = end.y - start.y;
                CGFloat edgeDx = b.x - a.x;
                CGFloat edgeDy = b.y - a.y;
                CGFloat denominator = (lineDx * edgeDy) - (lineDy * edgeDx);
                if (fabs(denominator) < 1e-6) {
                    continue;
                }
                CGFloat startToEdgeX = a.x - start.x;
                CGFloat startToEdgeY = a.y - start.y;
                CGFloat t = ((startToEdgeX * edgeDy) - (startToEdgeY * edgeDx)) / denominator;
                CGFloat u = ((startToEdgeX * lineDy) - (startToEdgeY * lineDx)) / denominator;
                if (u >= 0.0 && u <= 1.0) {
                    NSPoint intersection = NSMakePoint(start.x + lineDx * t, start.y + lineDy * t);
                    BOOL duplicate = NO;
                    for (NSUInteger existingIndex = 0; existingIndex < lineIntersectionCount; ++existingIndex) {
                        if (hypot(lineIntersections[existingIndex].x - intersection.x,
                                  lineIntersections[existingIndex].y - intersection.y) < 0.5) {
                            duplicate = YES;
                            break;
                        }
                    }
                    if (!duplicate && lineIntersectionCount < 4) {
                        lineIntersections[lineIntersectionCount] = intersection;
                        lineIntersectionTs[lineIntersectionCount] = t;
                        lineIntersectionCount += 1;
                    }

                    if (t >= 0.0 && t <= 1.0) {
                        duplicate = NO;
                        for (NSUInteger existingIndex = 0; existingIndex < segmentIntersectionCount; ++existingIndex) {
                            if (hypot(segmentIntersections[existingIndex].x - intersection.x,
                                      segmentIntersections[existingIndex].y - intersection.y) < 0.5) {
                                duplicate = YES;
                                break;
                            }
                        }
                        if (!duplicate && segmentIntersectionCount < 4) {
                            segmentIntersections[segmentIntersectionCount] = intersection;
                            segmentIntersectionTs[segmentIntersectionCount] = t;
                            segmentIntersectionCount += 1;
                        }
                    }
                }
            }
            startInside = NSPointInRect(start, selectionRect);
            endInside = NSPointInRect(end, selectionRect);
            if (lineIntersectionCount >= 2) {
                if (lineIntersectionTs[0] <= lineIntersectionTs[1]) {
                    clipStart = lineIntersections[0];
                    clipEnd = lineIntersections[1];
                } else {
                    clipStart = lineIntersections[1];
                    clipEnd = lineIntersections[0];
                }
                hasInteriorSegment = YES;
            } else if (startInside && endInside) {
                clipStart = start;
                clipEnd = end;
                hasInteriorSegment = YES;
            }

            if (self.clipKeepMode != VmfClipKeepModeBoth && hasInteriorSegment) {
                NSPoint polygon[4] = {
                    corners[0], corners[1], corners[2], corners[3]
                };
                NSPoint clipped[8];
                BOOL deletePositiveHalf = self.clipKeepMode == VmfClipKeepModeA;
                NSUInteger clippedCount = clip_polygon_to_halfplane(polygon,
                                                                    4,
                                                                    clipStart,
                                                                    clipEnd,
                                                                    deletePositiveHalf,
                                                                    clipped,
                                                                    8);
                if (clippedCount >= 3) {
                    [[NSColor colorWithCalibratedRed:0.94 green:0.18 blue:0.18 alpha:0.22] setFill];
                    NSBezierPath* deletePreview = [NSBezierPath bezierPath];
                    [deletePreview moveToPoint:clipped[0]];
                    for (NSUInteger pointIndex = 1; pointIndex < clippedCount; ++pointIndex) {
                        [deletePreview lineToPoint:clipped[pointIndex]];
                    }
                    [deletePreview closePath];
                    [deletePreview fill];
                }
            }
        }
        CGFloat dashes[2] = { 8.0, 4.0 };
        [[NSColor colorWithCalibratedRed:0.34 green:0.78 blue:0.96 alpha:1.0] setStroke];
        if (!hasInteriorSegment) {
            NSBezierPath* clipPath = [NSBezierPath bezierPath];
            [clipPath setLineDash:dashes count:2 phase:0.0];
            clipPath.lineWidth = 2.0;
            [clipPath moveToPoint:start];
            [clipPath lineToPoint:end];
            [clipPath stroke];
        } else {
            if (!startInside && segmentIntersectionCount > 0) {
                NSUInteger nearestIndex = 0;
                CGFloat nearestT = segmentIntersectionTs[0];
                for (NSUInteger index = 1; index < segmentIntersectionCount; ++index) {
                    if (segmentIntersectionTs[index] < nearestT) {
                        nearestT = segmentIntersectionTs[index];
                        nearestIndex = index;
                    }
                }
                NSBezierPath* leadingPath = [NSBezierPath bezierPath];
                [leadingPath setLineDash:dashes count:2 phase:0.0];
                leadingPath.lineWidth = 2.0;
                [leadingPath moveToPoint:start];
                [leadingPath lineToPoint:segmentIntersections[nearestIndex]];
                [leadingPath stroke];
            }
            if (!endInside && segmentIntersectionCount > 0) {
                NSUInteger farthestIndex = 0;
                CGFloat farthestT = segmentIntersectionTs[0];
                for (NSUInteger index = 1; index < segmentIntersectionCount; ++index) {
                    if (segmentIntersectionTs[index] > farthestT) {
                        farthestT = segmentIntersectionTs[index];
                        farthestIndex = index;
                    }
                }
                NSBezierPath* trailingPath = [NSBezierPath bezierPath];
                [trailingPath setLineDash:dashes count:2 phase:0.0];
                trailingPath.lineWidth = 2.0;
                [trailingPath moveToPoint:segmentIntersections[farthestIndex]];
                [trailingPath lineToPoint:end];
                [trailingPath stroke];
            }
        }

        if (hasInteriorSegment) {
            NSColor* interiorColor = self.clipKeepMode == VmfClipKeepModeBoth
                ? [NSColor colorWithCalibratedWhite:1.0 alpha:1.0]
                : [NSColor colorWithCalibratedRed:0.94 green:0.22 blue:0.22 alpha:1.0];
            [interiorColor setStroke];
            NSBezierPath* interiorPath = [NSBezierPath bezierPath];
            [interiorPath setLineDash:dashes count:2 phase:0.0];
            interiorPath.lineWidth = 2.0;
            [interiorPath moveToPoint:clipStart];
            [interiorPath lineToPoint:clipEnd];
            [interiorPath stroke];
        }

        [[NSColor colorWithCalibratedRed:0.34 green:0.78 blue:0.96 alpha:1.0] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(start.x - 4.0, start.y - 4.0, 8.0, 8.0)] fill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(end.x - 4.0, end.y - 4.0, 8.0, 8.0)] fill];
    }

    if (!self.selectionVisible) {
        return;
    }

    NSRect rect = [self screenRectForBounds:self.selectionBounds];
    if (self.editorTool != VmfViewportEditorToolVertex) {
        [[NSColor colorWithCalibratedRed:0.95 green:0.61 blue:0.18 alpha:0.95] setStroke];
        NSBezierPath* path = [NSBezierPath bezierPathWithRect:rect];
        path.lineWidth = 1.5;
        [path stroke];
    }

    if (self.editorTool == VmfViewportEditorToolVertex && self.selectionEdgeCount > 0 && self.selectionEdges) {
        // Draw edges as wireframe - red when invalid, otherwise normal vertex edit colors
        for (size_t edgeIndex = 0; edgeIndex < self.selectionEdgeCount; ++edgeIndex) {
            const VmfSolidEdge* edge = &self.selectionEdges[edgeIndex];
            if (edge->endpointCount < 2) {
                continue;
            }
            NSPoint start = [self viewPointForWorldPoint:edge->start];
            NSPoint end = [self viewPointForWorldPoint:edge->end];
            // Skip degenerate (point-like) projected edges
            if (hypot(end.x - start.x, end.y - start.y) < 0.5) {
                continue;
            }
            BOOL isActiveEdge = edge->sideIndices[0] == self.activeEdgeFirstSideIndex && edge->sideIndices[1] == self.activeEdgeSecondSideIndex;
            NSColor* edgeColor;
            if (self.vertexEditIsInvalid) {
                edgeColor = [NSColor colorWithCalibratedRed:0.95 green:0.22 blue:0.22 alpha:0.92];
            } else if (isActiveEdge) {
                edgeColor = [NSColor colorWithCalibratedRed:0.34 green:0.78 blue:0.96 alpha:1.0];
            } else {
                edgeColor = [NSColor colorWithCalibratedRed:0.86 green:0.73 blue:0.33 alpha:0.85];
            }
            [edgeColor setStroke];
            NSBezierPath* edgePath = [NSBezierPath bezierPath];
            edgePath.lineWidth = isActiveEdge ? 3.0 : 1.5;
            [edgePath moveToPoint:start];
            [edgePath lineToPoint:end];
            [edgePath stroke];
        }
    }

    if (self.editorTool == VmfViewportEditorToolVertex && self.selectionVertexCount > 0 && self.selectionVertices) {
        NSColor* dotColor = self.vertexEditIsInvalid
            ? [NSColor colorWithCalibratedRed:1.0 green:0.35 blue:0.35 alpha:1.0]
            : [NSColor colorWithCalibratedRed:0.98 green:0.82 blue:0.46 alpha:1.0];
        [dotColor setFill];
        for (size_t vertexIndex = 0; vertexIndex < self.selectionVertexCount; ++vertexIndex) {
            // Check if this vertex is one of the active (dragged) vertices - draw slightly larger
            BOOL isActive = NO;
            for (size_t ai = 0; ai < _activeVertexIndexCount; ++ai) {
                if (_activeVertexIndices[ai] == vertexIndex) {
                    isActive = YES;
                    break;
                }
            }
            NSPoint pt = [self viewPointForWorldPoint:self.selectionVertices[vertexIndex]];
            CGFloat r = isActive ? 5.0 : 4.0;
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(pt.x - r, pt.y - r, r * 2.0, r * 2.0)] fill];
        }
    }

    if (self.editorTool != VmfViewportEditorToolVertex && self.selectedFaceEdge != VmfViewportSelectionEdgeNone) {
        [[NSColor colorWithCalibratedRed:0.28 green:0.74 blue:0.93 alpha:1.0] setStroke];
        NSBezierPath* facePath = [NSBezierPath bezierPath];
        facePath.lineWidth = 3.0;
        switch (self.selectedFaceEdge) {
            case VmfViewportSelectionEdgeMinU:
                [facePath moveToPoint:NSMakePoint(NSMinX(rect), NSMinY(rect))];
                [facePath lineToPoint:NSMakePoint(NSMinX(rect), NSMaxY(rect))];
                break;
            case VmfViewportSelectionEdgeMaxU:
                [facePath moveToPoint:NSMakePoint(NSMaxX(rect), NSMinY(rect))];
                [facePath lineToPoint:NSMakePoint(NSMaxX(rect), NSMaxY(rect))];
                break;
            case VmfViewportSelectionEdgeMinV:
                [facePath moveToPoint:NSMakePoint(NSMinX(rect), NSMinY(rect))];
                [facePath lineToPoint:NSMakePoint(NSMaxX(rect), NSMinY(rect))];
                break;
            case VmfViewportSelectionEdgeMaxV:
                [facePath moveToPoint:NSMakePoint(NSMinX(rect), NSMaxY(rect))];
                [facePath lineToPoint:NSMakePoint(NSMaxX(rect), NSMaxY(rect))];
                break;
            default:
                break;
        }
        [facePath stroke];
    }

    if (self.selectionEditable && self.editorTool == VmfViewportEditorToolSelect) {
        [[NSColor colorWithCalibratedRed:0.95 green:0.61 blue:0.18 alpha:1.0] setFill];
        const CGFloat handleSize = 8.0;
        NSRect handles[8] = {
            NSMakeRect(NSMinX(rect) - handleSize * 0.5, NSMinY(rect) - handleSize * 0.5, handleSize, handleSize),
            NSMakeRect(NSMaxX(rect) - handleSize * 0.5, NSMinY(rect) - handleSize * 0.5, handleSize, handleSize),
            NSMakeRect(NSMaxX(rect) - handleSize * 0.5, NSMaxY(rect) - handleSize * 0.5, handleSize, handleSize),
            NSMakeRect(NSMinX(rect) - handleSize * 0.5, NSMaxY(rect) - handleSize * 0.5, handleSize, handleSize),
            NSMakeRect(NSMinX(rect) - handleSize * 0.5, NSMidY(rect) - handleSize * 0.5, handleSize, handleSize),
            NSMakeRect(NSMaxX(rect) - handleSize * 0.5, NSMidY(rect) - handleSize * 0.5, handleSize, handleSize),
            NSMakeRect(NSMidX(rect) - handleSize * 0.5, NSMinY(rect) - handleSize * 0.5, handleSize, handleSize),
            NSMakeRect(NSMidX(rect) - handleSize * 0.5, NSMaxY(rect) - handleSize * 0.5, handleSize, handleSize),
        };
        for (int i = 0; i < 8; ++i) {
            [[NSBezierPath bezierPathWithRect:handles[i]] fill];
        }
    }
}

- (void)lookByDeltaX:(float)deltaX deltaY:(float)deltaY {
    if (self.dimension != VmfViewportDimension3D) {
        return;
    }
    self.yaw -= deltaX * 0.002f;
    self.pitch = fminf(fmaxf(self.pitch + deltaY * 0.002f, -1.45f), 1.45f);
}

- (void)beginFreeLook {
    if (self.dimension != VmfViewportDimension3D || self.freeLookActive) {
        return;
    }
    // Right mouse free-look overrides any in-progress left-mouse orbit retargeting.
    self.orbitLerpActive = NO;
    self.freeLookPosition = [self cameraPosition];
    self.freeLookActive = YES;
    self.lastFrameTime = CACurrentMediaTime();
}

- (void)endFreeLook {
    if (!self.freeLookActive) {
        return;
    }
    self.freeLookActive = NO;
    self.movementMask = 0;
    self.lastFrameTime = 0.0;
    self.target = vec3_add(self.freeLookPosition, vec3_scale([self forwardVector], self.distance));
}

- (void)drawGridInEncoder:(id<MTLRenderCommandEncoder>)encoder aspect:(float)aspect {
    if (self.dimension != VmfViewportDimension2D) {
        return;
    }

    float visibleHeight = self.orthoSize;
    float visibleWidth = visibleHeight * aspect;
    float gridStep = ortho_grid_step(visibleHeight, (float)self.gridSize);
    float majorStep = gridStep * 8.0f;

    Vec3 axisU = plane_right(self.plane);
    Vec3 axisV = plane_up(self.plane);
    float centerU = vec3_dot(self.orthoCenter, axisU);
    float centerV = vec3_dot(self.orthoCenter, axisV);
    Vec3 planeOrigin = vec3_sub(self.orthoCenter,
                                vec3_add(vec3_scale(axisU, centerU),
                                         vec3_scale(axisV, centerV)));
    float minU = centerU - visibleWidth * 0.5f;
    float maxU = centerU + visibleWidth * 0.5f;
    float minV = centerV - visibleHeight * 0.5f;
    float maxV = centerV + visibleHeight * 0.5f;

    NovaToolMetalEditorVertex gridVertices[2048];
    NSUInteger gridVertexCount = 0;
    for (float u = floorf(minU / gridStep) * gridStep; u <= maxU + gridStep; u += gridStep) {
        BOOL isAxis = fabsf(u) < 0.5f * gridStep;
        BOOL isMajor = fmodf(fabsf(u), majorStep) < 0.01f || majorStep - fmodf(fabsf(u), majorStep) < 0.01f;
        Vec3 color = isAxis ? vec3_make(0.84f, 0.34f, 0.34f) : (isMajor ? vec3_make(0.30f, 0.33f, 0.38f) : vec3_make(0.18f, 0.20f, 0.24f));
        Vec3 start = vec3_add(planeOrigin, vec3_add(vec3_scale(axisU, u), vec3_scale(axisV, minV)));
        Vec3 end = vec3_add(planeOrigin, vec3_add(vec3_scale(axisU, u), vec3_scale(axisV, maxV)));
        append_grid_line(gridVertices, 2048, &gridVertexCount, start, end, color);
    }
    for (float v = floorf(minV / gridStep) * gridStep; v <= maxV + gridStep; v += gridStep) {
        BOOL isAxis = fabsf(v) < 0.5f * gridStep;
        BOOL isMajor = fmodf(fabsf(v), majorStep) < 0.01f || majorStep - fmodf(fabsf(v), majorStep) < 0.01f;
        Vec3 color = isAxis ? vec3_make(0.34f, 0.60f, 0.84f) : (isMajor ? vec3_make(0.30f, 0.33f, 0.38f) : vec3_make(0.18f, 0.20f, 0.24f));
        Vec3 start = vec3_add(planeOrigin, vec3_add(vec3_scale(axisU, minU), vec3_scale(axisV, v)));
        Vec3 end = vec3_add(planeOrigin, vec3_add(vec3_scale(axisU, maxU), vec3_scale(axisV, v)));
        append_grid_line(gridVertices, 2048, &gridVertexCount, start, end, color);
    }

    if (gridVertexCount == 0) {
        return;
    }

    id<MTLBuffer> gridBuffer = [self.device newBufferWithBytes:gridVertices
                                                        length:gridVertexCount * sizeof(NovaToolMetalEditorVertex)
                                                       options:MTLResourceStorageModeShared];
    if (!gridBuffer) {
        return;
    }

    Uniforms uniforms = [self uniformsForAspect:aspect];
    [encoder setDepthStencilState:self.disabledDepthState];
    [encoder setVertexBuffer:gridBuffer offset:0 atIndex:0];
    [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeLine vertexStart:0 vertexCount:gridVertexCount];
}

- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size {
    if (self.fullRendererInitialized) {
        char errorBuffer[256] = {0};
        nova_tool_metal_context_resize_drawable(&_fullMetalContext, (uint32_t)MAX(size.width, 1.0), (uint32_t)MAX(size.height, 1.0));
        if (!nova_tool_metal_renderer_resize(&_fullMetalRenderer,
                                             (uint32_t)MAX(size.width, 1.0),
                                             (uint32_t)MAX(size.height, 1.0),
                                             errorBuffer,
                                             sizeof(errorBuffer))) {
            NSLog(@"Heavy Metal renderer resize failed: %s", errorBuffer);
        }
    }
    (void)view;
}

- (void)drawInMTKView:(MTKView*)view {
    CFTimeInterval now = CACurrentMediaTime();
    if (self.lastFrameTime == 0.0) {
        self.lastFrameTime = now;
    }
    CFTimeInterval deltaTime = now - self.lastFrameTime;
    [self updateFreeLookWithDeltaTime:deltaTime];
    [self updateOrbitTargetLerpWithDeltaTime:deltaTime];
    self.lastFrameTime = now;

    if (self.dimension == VmfViewportDimension3D &&
        self.renderMode == VmfViewportRenderModeShaded &&
        self.fullRendererInitialized &&
        self.sceneWorld != NULL &&
        self.importedSceneData.objectCount > 0u) {
        char errorBuffer[512] = {0};
        Vec3 eye = [self cameraPosition];
        Vec3 target = [self cameraTarget];
        Vec3 forward = vec3_sub(target, eye);
        float heavyYaw = self.yaw;
        float heavyPitch = self.pitch;
        uint32_t frameSlot = self.fullRendererFrameIndex % 3u;

        if (vec3_length(forward) > 0.0001f) {
            forward = vec3_normalize(forward);
            heavyYaw = atan2f(forward.raw[0], -forward.raw[1]);
            heavyPitch = asinf(fmaxf(fminf(forward.raw[2], 1.0f), -1.0f));
        }

        nova_scene_world_sync_to_ui(self.sceneWorld,
                                    self.importedSceneData.objectCount > 0u ? 1u : 0u,
                                    &_fullRendererUiState);
        _fullRendererUiState.previewBakeLightingEnabled = self.previewBakedLightingEnabled ? 1 : 0;

        if (
            !nova_tool_metal_renderer_reset_frame_resources(&_fullMetalRenderer, frameSlot, errorBuffer, sizeof(errorBuffer)) ||
            !nova_tool_metal_renderer_sync_editor_state(&_fullMetalRenderer,
                                                        &_fullRendererUiState,
                                                        self.sceneWorld,
                                                        &_importedSceneData,
                                                        (float[3]){ eye.raw[0], eye.raw[1], eye.raw[2] },
                                                        heavyYaw,
                                                        heavyPitch,
                                                        self.fullRendererFrameIndex,
                                                        errorBuffer,
                                                        sizeof(errorBuffer)) ||
            !nova_tool_metal_renderer_draw_frame(&_fullMetalRenderer, errorBuffer, sizeof(errorBuffer))) {
            NSLog(@"Heavy Metal viewport draw failed: %s", errorBuffer);
        } else {
            self.fullRendererFrameIndex += 1u;
            return;
        }
    }

    id<CAMetalDrawable> drawable = view.currentDrawable;
    MTLRenderPassDescriptor* passDescriptor = view.currentRenderPassDescriptor;
    if (!drawable || !passDescriptor) {
        return;
    }

    float aspect = view.drawableSize.height > 0.0 ? (float)(view.drawableSize.width / view.drawableSize.height) : 1.0f;
    Uniforms uniforms = [self uniformsForAspect:aspect];

    NovaToolMetalEditorVertex gridVertices[2048];
    NSUInteger gridVertexCount = 0;
    if (self.dimension == VmfViewportDimension2D) {
        float visibleHeight = self.orthoSize;
        float visibleWidth = visibleHeight * aspect;
        float gridStep = ortho_grid_step(visibleHeight, (float)self.gridSize);
        float majorStep = gridStep * 8.0f;
        Vec3 axisU = plane_right(self.plane);
        Vec3 axisV = plane_up(self.plane);
        float centerU = vec3_dot(self.orthoCenter, axisU);
        float centerV = vec3_dot(self.orthoCenter, axisV);
        Vec3 planeOrigin = vec3_sub(self.orthoCenter,
                                    vec3_add(vec3_scale(axisU, centerU),
                                             vec3_scale(axisV, centerV)));
        float minU = centerU - visibleWidth * 0.5f;
        float maxU = centerU + visibleWidth * 0.5f;
        float minV = centerV - visibleHeight * 0.5f;
        float maxV = centerV + visibleHeight * 0.5f;

        for (float u = floorf(minU / gridStep) * gridStep; u <= maxU + gridStep; u += gridStep) {
            BOOL isAxis = fabsf(u) < 0.5f * gridStep;
            BOOL isMajor = fmodf(fabsf(u), majorStep) < 0.01f || majorStep - fmodf(fabsf(u), majorStep) < 0.01f;
            Vec3 color = isAxis ? vec3_make(0.84f, 0.34f, 0.34f) : (isMajor ? vec3_make(0.30f, 0.33f, 0.38f) : vec3_make(0.18f, 0.20f, 0.24f));
            Vec3 start = vec3_add(planeOrigin, vec3_add(vec3_scale(axisU, u), vec3_scale(axisV, minV)));
            Vec3 end = vec3_add(planeOrigin, vec3_add(vec3_scale(axisU, u), vec3_scale(axisV, maxV)));
            append_grid_line(gridVertices, 2048, &gridVertexCount, start, end, color);
        }
        for (float v = floorf(minV / gridStep) * gridStep; v <= maxV + gridStep; v += gridStep) {
            BOOL isAxis = fabsf(v) < 0.5f * gridStep;
            BOOL isMajor = fmodf(fabsf(v), majorStep) < 0.01f || majorStep - fmodf(fabsf(v), majorStep) < 0.01f;
            Vec3 color = isAxis ? vec3_make(0.34f, 0.60f, 0.84f) : (isMajor ? vec3_make(0.30f, 0.33f, 0.38f) : vec3_make(0.18f, 0.20f, 0.24f));
            Vec3 start = vec3_add(planeOrigin, vec3_add(vec3_scale(axisU, minU), vec3_scale(axisV, v)));
            Vec3 end = vec3_add(planeOrigin, vec3_add(vec3_scale(axisU, maxU), vec3_scale(axisV, v)));
            append_grid_line(gridVertices, 2048, &gridVertexCount, start, end, color);
        }
    }

    NovaToolMetalEditorViewportDrawInfo drawInfo = {
        .renderPassDescriptor = (__bridge void*)passDescriptor,
        .drawable = (__bridge void*)drawable,
        .uniforms = &uniforms,
        .gridVertices = gridVertices,
        .gridVertexCount = gridVertexCount,
        .selectedFaceBuffer = (__bridge void*)self.selectedFaceBuffer,
        .selectedFaceVertexCount = self.selectedFaceVertexCount,
        .highlightedFaceBuffer = (__bridge void*)self.highlightedFaceBuffer,
        .highlightedFaceVertexCount = self.highlightedFaceVertexCount,
        .vertexEditPreviewBuffer = (__bridge void*)self.vertexEditPreviewBuffer,
        .vertexEditPreviewVertexCount = self.vertexEditPreviewVertexCount,
        .dimension3D = self.dimension == VmfViewportDimension3D ? 1u : 0u,
        .shaded = self.renderMode == VmfViewportRenderModeShaded ? 1u : 0u,
        .encodeOverlay = viewport_encode_overlay,
        .overlayUserData = (__bridge void*)self,
    };
    char errorBuffer[512] = {0};
    if (!nova_tool_metal_editor_viewport_renderer_draw(&_metalRenderer, &drawInfo, errorBuffer, sizeof(errorBuffer))) {
        NSLog(@"Viewport renderer draw failed: %s", errorBuffer);
    }
}

- (BOOL)handleViewportKeyDown:(NSEvent*)event {
    NSString* key = event.charactersIgnoringModifiers.lowercaseString;
    if (self.dimension == VmfViewportDimension3D &&
        [key isEqualToString:@"f"] &&
        self.selectionVisible &&
        bounds3_is_valid(self.selectionBounds)) {
        // Explicit focus key: preserve current distance (zoom), only retarget orbit pivot.
        self.orbitLerpTarget = bounds3_center(self.selectionBounds);
        self.orbitLerpActive = YES;
        return YES;
    }

    if (self.freeLookActive) {
        if ([key isEqualToString:@"w"]) {
            self.movementMask |= CameraMovementForward;
            return YES;
        }
        if ([key isEqualToString:@"s"]) {
            self.movementMask |= CameraMovementBackward;
            return YES;
        }
        if ([key isEqualToString:@"a"]) {
            self.movementMask |= CameraMovementLeft;
            return YES;
        }
        if ([key isEqualToString:@"d"]) {
            self.movementMask |= CameraMovementRight;
            return YES;
        }
        if ([key isEqualToString:@"q"]) {
            self.movementMask |= CameraMovementUp;
            return YES;
        }
        if ([key isEqualToString:@"e"]) {
            self.movementMask |= CameraMovementDown;
            return YES;
        }
    }

    if (self.delegate) {
        [self.delegate viewport:self handleKeyDown:event];
        return YES;
    }
    return NO;
}

- (BOOL)handleViewportKeyUp:(NSEvent*)event {
    NSString* key = event.charactersIgnoringModifiers.lowercaseString;
    if ([key isEqualToString:@"w"]) {
        self.movementMask &= ~CameraMovementForward;
        return YES;
    }
    if ([key isEqualToString:@"s"]) {
        self.movementMask &= ~CameraMovementBackward;
        return YES;
    }
    if ([key isEqualToString:@"a"]) {
        self.movementMask &= ~CameraMovementLeft;
        return YES;
    }
    if ([key isEqualToString:@"d"]) {
        self.movementMask &= ~CameraMovementRight;
        return YES;
    }
    if ([key isEqualToString:@"q"]) {
        self.movementMask &= ~CameraMovementUp;
        return YES;
    }
    if ([key isEqualToString:@"e"]) {
        self.movementMask &= ~CameraMovementDown;
        return YES;
    }

    if (self.delegate) {
        [self.delegate viewport:self handleKeyUp:event];
        return YES;
    }
    return NO;
}

- (void)handleViewportMouseDownAtPoint:(NSPoint)point {
    [self.delegate viewportDidBecomeActive:self];
    if (self.dimension == VmfViewportDimension3D && self.freeLookActive) {
        self.dragMode = ViewportDragModeNone;
        self.pendingClickSelection = NO;
        return;
    }
    if (self.dimension == VmfViewportDimension3D && [self gizmoConsumesPrimaryMouse]) {
        self.dragMode = ViewportDragModeNone;
        self.pendingClickSelection = NO;
        return;
    }
    self.dragStartPoint = point;
    self.pendingClickSelection = self.dimension == VmfViewportDimension3D;
    if (self.dimension != VmfViewportDimension2D) {
        // No implicit target lock on left mouse in 3D; focus is explicit via key.
        self.dragMode = ViewportDragModePan;
        return;
    }

    Vec3 worldPoint = [self snappedWorldPointForViewPoint:point];
    self.dragAnchorWorld = worldPoint;
    self.dragOriginalBounds = self.selectionBounds;
    self.activeHandle = ViewportHandleNone;
    _activeVertexIndexCount = 0;

    if (([NSApp currentEvent].modifierFlags & NSEventModifierFlagShift) != 0) {
        VmfViewportSelectionEdge edge = [self selectionEdgeAtPoint:point];
        if (edge != VmfViewportSelectionEdgeNone && self.delegate) {
            [self.delegate viewport:self requestFaceSelectionOnEdge:edge];
            self.dragMode = ViewportDragModeNone;
            return;
        }
    }

    if (([NSApp currentEvent].modifierFlags & NSEventModifierFlagOption) != 0) {
        self.dragMode = ViewportDragModePan;
        return;
    }

    NSInteger vertexIndex = [self vertexIndexAtPoint:point];
    if (vertexIndex >= 0 && self.editorTool == VmfViewportEditorToolVertex) {
        NSUInteger foundCount = [self vertexIndicesAtPoint:point outIndices:_activeVertexIndices maxCount:VMF_MAX_SOLID_VERTICES];
        _activeVertexIndexCount = foundCount > 0 ? foundCount : 1;
        if (foundCount == 0) {
            _activeVertexIndices[0] = (size_t)vertexIndex;
        }
        // Use the closest vertex as the anchor for world point computation
        self.dragAnchorWorld = self.selectionVertices[(size_t)vertexIndex];
        self.dragMode = ViewportDragModeMoveVertex;
        self.vertexEditIsInvalid = NO;
        return;
    }

    NSInteger edgeIndex = [self edgeIndexAtPoint:point];
    if (edgeIndex >= 0 && self.editorTool == VmfViewportEditorToolVertex) {
        self.activeEdgeFirstSideIndex = self.selectionEdges[(size_t)edgeIndex].sideIndices[0];
        self.activeEdgeSecondSideIndex = self.selectionEdges[(size_t)edgeIndex].sideIndices[1];
        self.dragMode = ViewportDragModeMoveEdge;
        return;
    }

    if (self.editorTool == VmfViewportEditorToolClip) {
        self.dragMode = ViewportDragModeDrawClipLine;
        self.clipGuideStart = worldPoint;
        self.clipGuideEnd = worldPoint;
        self.clipGuideVisible = YES;
        [self.overlayView setNeedsDisplay:YES];
        return;
    }

    if (self.editorTool == VmfViewportEditorToolBlock ||
        self.editorTool == VmfViewportEditorToolCylinder ||
        self.editorTool == VmfViewportEditorToolArch ||
        self.editorTool == VmfViewportEditorToolRamp ||
        self.editorTool == VmfViewportEditorToolStairs) {
        self.dragMode = ViewportDragModeCreateBlock;
        [self setCreationBounds:[self boundsForBlockFromAnchor:worldPoint current:worldPoint] visible:YES];
        return;
    }

    if (self.editorTool == VmfViewportEditorToolSelect) {
        ViewportHandle handle = [self handleAtPoint:point];
        self.activeHandle = handle;
        if (handle == ViewportHandleBody) {
            self.dragMode = ViewportDragModeMoveSelection;
            return;
        }
        if (handle != ViewportHandleNone) {
            self.dragMode = ViewportDragModeResizeSelection;
            return;
        }
    }

    self.dragMode = ViewportDragModePan;
    self.pendingClickSelection = YES;
}

- (void)handleViewportMouseUpAtPoint:(NSPoint)point {
    if (self.dimension != VmfViewportDimension2D) {
        if ([self gizmoConsumesPrimaryMouse]) {
            self.dragMode = ViewportDragModeNone;
            self.pendingClickSelection = NO;
            return;
        }
        if (self.pendingClickSelection && !self.freeLookActive && self.delegate) {
            [self.delegate viewport:self requestSelectionRayOrigin:[self cameraPosition] direction:[self rayDirectionForViewPoint:point]];
        }
        self.dragMode = ViewportDragModeNone;
        self.pendingClickSelection = NO;
        return;
    }

    Vec3 worldPoint = [self snappedWorldPointForViewPoint:point];
    if (self.dragMode == ViewportDragModeCreateBlock && self.creationVisible) {
        Bounds3 bounds = [self boundsForBlockFromAnchor:self.dragAnchorWorld current:worldPoint];
        if (self.editorTool == VmfViewportEditorToolCylinder) {
            [self.delegate viewport:self createCylinderWithBounds:bounds];
        } else if (self.editorTool == VmfViewportEditorToolArch) {
            [self.delegate viewport:self createArchWithBounds:bounds];
        } else if (self.editorTool == VmfViewportEditorToolRamp) {
            [self.delegate viewport:self createRampWithBounds:bounds];
        } else if (self.editorTool == VmfViewportEditorToolStairs) {
            [self.delegate viewport:self createStairsWithBounds:bounds];
        } else {
            [self.delegate viewport:self createBlockWithBounds:bounds];
        }
        [self setCreationBounds:bounds visible:NO];
    } else if (self.pendingClickSelection) {
        if (self.delegate) {
            [self.delegate viewport:self requestSelectionAtPoint:worldPoint];
        }
    } else if (self.dragMode == ViewportDragModeMoveSelection && self.selectionVisible) {
        [self.delegate viewport:self updateSelectionBounds:[self translatedBoundsFromOriginal:self.dragOriginalBounds current:worldPoint] commit:YES transform:VmfViewportSelectionTransformMove];
    } else if (self.dragMode == ViewportDragModeResizeSelection && self.selectionVisible) {
        [self.delegate viewport:self updateSelectionBounds:[self resizedBoundsFromOriginal:self.dragOriginalBounds current:worldPoint] commit:YES transform:VmfViewportSelectionTransformResize];
    } else if (self.dragMode == ViewportDragModeMoveVertex && _activeVertexIndexCount > 0 && self.selectionVertices) {
        Vec3 newPositions[VMF_MAX_SOLID_VERTICES];
        for (size_t i = 0; i < _activeVertexIndexCount; ++i) {
            size_t idx = _activeVertexIndices[i];
            newPositions[i] = (idx < self.selectionVertexCount)
                ? [self snappedWorldPointForViewPoint:point preservingHiddenAxisFrom:self.selectionVertices[idx]]
                : worldPoint;
        }
        [self.delegate viewport:self updateSelectionVerticesAtIndices:_activeVertexIndices positions:newPositions count:_activeVertexIndexCount commit:YES];
    } else if (self.dragMode == ViewportDragModeMoveEdge && self.activeEdgeFirstSideIndex != SIZE_MAX && self.activeEdgeSecondSideIndex != SIZE_MAX) {
        [self.delegate viewport:self
            updateSelectionEdgeFirstSideIndex:self.activeEdgeFirstSideIndex
                               secondSideIndex:self.activeEdgeSecondSideIndex
                                         offset:vec3_sub(worldPoint, self.dragAnchorWorld)
                                         commit:YES];
    } else if (self.dragMode == ViewportDragModeDrawClipLine) {
        self.clipGuideEnd = worldPoint;
        self.clipGuideVisible = YES;
        [self.overlayView setNeedsDisplay:YES];
    }

    self.dragMode = ViewportDragModeNone;
    self.activeHandle = ViewportHandleNone;
    _activeVertexIndexCount = 0;
    self.activeEdgeFirstSideIndex = SIZE_MAX;
    self.activeEdgeSecondSideIndex = SIZE_MAX;
    self.pendingClickSelection = NO;
}

- (void)handleViewportPrimaryDragWithDelta:(NSPoint)delta alternate:(BOOL)alternate {
    if (self.dimension == VmfViewportDimension3D) {
        if ([self gizmoConsumesPrimaryMouse]) {
            self.pendingClickSelection = NO;
            return;
        }
        CGFloat dragDistance = hypot(delta.x, delta.y);
        if (dragDistance > 0.5) {
            self.pendingClickSelection = NO;
        }
        [self panOrOrbitByDeltaX:(float)delta.x deltaY:(float)delta.y];
        return;
    }

    NSPoint point = [self.metalView convertPoint:[NSApp currentEvent].locationInWindow fromView:nil];
    Vec3 worldPoint = [self snappedWorldPointForViewPoint:point];
    if (self.pendingClickSelection) {
        CGFloat dragDistance = hypot(point.x - self.dragStartPoint.x, point.y - self.dragStartPoint.y);
        if (dragDistance > 3.0) {
            self.pendingClickSelection = NO;
        }
    }
    if (alternate || self.dragMode == ViewportDragModePan) {
        [self panOrOrbitByDeltaX:(float)delta.x deltaY:(float)delta.y];
        return;
    }
    if (self.dragMode == ViewportDragModeCreateBlock) {
        [self setCreationBounds:[self boundsForBlockFromAnchor:self.dragAnchorWorld current:worldPoint] visible:YES];
        return;
    }
    if (self.dragMode == ViewportDragModeDrawClipLine) {
        self.clipGuideEnd = worldPoint;
        self.clipGuideVisible = YES;
        [self.overlayView setNeedsDisplay:YES];
        return;
    }
    if (self.dragMode == ViewportDragModeMoveVertex && _activeVertexIndexCount > 0 && self.selectionVertices) {
        Vec3 newPositions[VMF_MAX_SOLID_VERTICES];
        for (size_t i = 0; i < _activeVertexIndexCount; ++i) {
            size_t idx = _activeVertexIndices[i];
            newPositions[i] = (idx < self.selectionVertexCount)
                ? [self snappedWorldPointForViewPoint:point preservingHiddenAxisFrom:self.selectionVertices[idx]]
                : worldPoint;
        }
        [self.delegate viewport:self updateSelectionVerticesAtIndices:_activeVertexIndices positions:newPositions count:_activeVertexIndexCount commit:NO];
        return;
    }
    if (self.dragMode == ViewportDragModeMoveEdge && self.activeEdgeFirstSideIndex != SIZE_MAX && self.activeEdgeSecondSideIndex != SIZE_MAX) {
        Vec3 offset = vec3_sub(worldPoint, self.dragAnchorWorld);
        [self.delegate viewport:self
            updateSelectionEdgeFirstSideIndex:self.activeEdgeFirstSideIndex
                               secondSideIndex:self.activeEdgeSecondSideIndex
                                         offset:offset
                                         commit:NO];
        self.dragAnchorWorld = worldPoint;
        return;
    }
    if (self.dragMode == ViewportDragModeMoveSelection && self.selectionVisible) {
        [self.delegate viewport:self updateSelectionBounds:[self translatedBoundsFromOriginal:self.dragOriginalBounds current:worldPoint] commit:NO transform:VmfViewportSelectionTransformMove];
        return;
    }
    if (self.dragMode == ViewportDragModeResizeSelection && self.selectionVisible) {
        [self.delegate viewport:self updateSelectionBounds:[self resizedBoundsFromOriginal:self.dragOriginalBounds current:worldPoint] commit:NO transform:VmfViewportSelectionTransformResize];
    }
}

- (BOOL)handleViewportSecondaryMouseDown {
    if (self.dimension != VmfViewportDimension3D) {
        return NO;
    }
    [self beginFreeLook];
    return YES;
}

- (void)handleViewportSecondaryDragWithDelta:(NSPoint)delta {
    if (self.dimension == VmfViewportDimension3D) {
        [self lookByDeltaX:(float)delta.x deltaY:(float)delta.y];
    }
}

- (void)handleViewportSecondaryMouseUp {
    [self endFreeLook];
}

- (void)handleViewportScrollDelta:(CGFloat)deltaY {
    [self zoomByDelta:(float)(-deltaY * 0.1f)];
}

- (void)handleViewportDroppedPath:(NSString*)path {
    if (self.delegate) {
        [self.delegate viewportDidRequestOpenDroppedPath:path];
    }
}

- (void)handleViewportMouseHoverAtPoint:(NSPoint)point {
    if (self.dimension != VmfViewportDimension3D) {
        return;
    }
    if (!self.delegate) {
        return;
    }
    Vec3 origin = [self cameraPosition];
    Vec3 direction = [self rayDirectionForViewPoint:point];
    [self.delegate viewport:self requestHoverRayOrigin:origin direction:direction];
}

- (void)handleViewportSecondaryClickAtPoint:(NSPoint)point modifierFlags:(NSEventModifierFlags)flags {
    if (self.dimension != VmfViewportDimension3D) {
        return;
    }
    if (!self.delegate) {
        return;
    }
    Vec3 origin = [self cameraPosition];
    Vec3 direction = [self rayDirectionForViewPoint:point];
    // Alt+right-click  = eyedropper sample
    // Cmd+right-click  = paint material + world-align UVs (contiguous)
    // plain right-click = paint material only, UV axes untouched
    if (flags & NSEventModifierFlagOption) {
        [self.delegate viewport:self requestSampleRayOrigin:origin direction:direction];
    } else if (flags & NSEventModifierFlagCommand) {
        [self.delegate viewport:self requestPaintAlignRayOrigin:origin direction:direction];
    } else {
        [self.delegate viewport:self requestPaintRayOrigin:origin direction:direction];
    }
}

@end
