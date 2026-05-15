#import "sledgehammer_viewer_app_internal.h"

#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "novamodel_asset.h"

static NSString* const kSledgehammerModelAssetExtension = @"novamodel";
static NSString* const kSledgehammerMaterialAssetSuffix = @".material.json";

typedef NS_ENUM(NSInteger, SledgehammerContentBrowserMode) {
    SledgehammerContentBrowserModeModels = 0,
    SledgehammerContentBrowserModeMaterials = 1,
};

static NSString* sledgehammer_sanitized_model_asset_name(NSString* rawName) {
    NSString* trimmedName;

    if (rawName.length == 0) {
        return nil;
    }

    trimmedName = [[rawName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] stringByDeletingPathExtension];
    if (trimmedName.length == 0) {
        return nil;
    }

    trimmedName = [[trimmedName componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/:"]] componentsJoinedByString:@"_"];
    trimmedName = [trimmedName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmedName.length > 0 ? trimmedName : nil;
}

static NSString* sledgehammer_default_model_asset_name_for_url(NSURL* url) {
    NSString* sourceName;
    NSString* parentName;
    NSString* normalizedSourceName;

    if (url == nil) {
        return @"model";
    }

    sourceName = sledgehammer_sanitized_model_asset_name(url.lastPathComponent.stringByDeletingPathExtension);
    parentName = sledgehammer_sanitized_model_asset_name(url.URLByDeletingLastPathComponent.lastPathComponent);
    normalizedSourceName = sourceName.lowercaseString;

    if (sourceName.length == 0) {
        return parentName.length > 0 ? parentName : @"model";
    }

    if (([normalizedSourceName isEqualToString:@"scene"] ||
         [normalizedSourceName isEqualToString:@"model"] ||
         [normalizedSourceName isEqualToString:@"untitled"]) &&
        parentName.length > 0) {
        return parentName;
    }

    return sourceName;
}

static NSString* sledgehammer_content_root_directory(void) {
    NSString* executableDir = [NSBundle.mainBundle.executablePath stringByDeletingLastPathComponent];
    return [executableDir stringByAppendingPathComponent:@"content"];
}

static NSString* sledgehammer_models_directory(void) {
    return [sledgehammer_content_root_directory() stringByAppendingPathComponent:@"models"];
}

static NSString* sledgehammer_materials_directory(void) {
    return [sledgehammer_content_root_directory() stringByAppendingPathComponent:@"materials"];
}

static NSString* sledgehammer_textures_directory(void) {
    return [sledgehammer_content_root_directory() stringByAppendingPathComponent:@"textures"];
}

static NSString* sledgehammer_material_icons_directory(void) {
    return [[sledgehammer_content_root_directory() stringByAppendingPathComponent:@"icons"] stringByAppendingPathComponent:@"materials"];
}

static NSString* sledgehammer_model_icons_directory(void) {
    return [[sledgehammer_content_root_directory() stringByAppendingPathComponent:@"icons"] stringByAppendingPathComponent:@"models"];
}

static NSDictionary<NSString*, id>* sledgehammer_read_material_definition(NSString* path) {
    if (path.length == 0) {
        return nil;
    }
    NSData* data = [NSData dataWithContentsOfFile:path];
    if (data == nil) {
        return nil;
    }
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [json isKindOfClass:[NSDictionary class]] ? (NSDictionary<NSString*, id>*)json : nil;
}

static NSString* sledgehammer_material_name_from_asset_path(NSString* path) {
    NSString* filename = path.lastPathComponent;
    if (![filename.lowercaseString hasSuffix:kSledgehammerMaterialAssetSuffix]) {
        return filename.stringByDeletingPathExtension.lowercaseString;
    }
    return [[filename stringByDeletingPathExtension] stringByDeletingPathExtension].lowercaseString;
}

static NSString* sledgehammer_material_icon_path_for_name(NSString* materialName) {
    return [sledgehammer_material_icons_directory() stringByAppendingPathComponent:[materialName.lowercaseString stringByAppendingPathExtension:@"png"]];
}

static NSString* sledgehammer_model_icon_path_for_name(NSString* modelName) {
    return [sledgehammer_model_icons_directory() stringByAppendingPathComponent:[modelName.lowercaseString stringByAppendingPathExtension:@"png"]];
}

static NSString* sledgehammer_sanitized_material_asset_name(NSString* rawName) {
    NSString* sanitized = sledgehammer_sanitized_model_asset_name(rawName);
    return sanitized.length > 0 ? sanitized.lowercaseString : nil;
}

static NSImage* sledgehammer_make_thumbnail_image(const NovaModelAssetThumbnail* thumbnail);
static NSImage* sledgehammer_make_placeholder_thumbnail_image(NSString* title);

typedef struct SledgehammerMaterialPreviewVertex {
    struct { float x, y, z; } position;
    struct { float x, y, z; } normal;
    struct { float x, y; } uv;
} SledgehammerMaterialPreviewVertex;

typedef struct SledgehammerModelPreviewVertex {
    struct { float x, y, z; } position;
    struct { float x, y, z; } normal;
    struct { float x, y; } uv;
} SledgehammerModelPreviewVertex;

typedef struct SledgehammerMaterialPreviewUniforms {
    matrix_float4x4 modelViewProjection;
    matrix_float4x4 modelMatrix;
    vector_float4 keyLightDirection;
    vector_float4 rimLightDirection;
    vector_float4 baseColorTint;
} SledgehammerMaterialPreviewUniforms;

typedef struct SledgehammerModelPreviewUniforms {
    matrix_float4x4 viewProjection;
    vector_float4 cameraPosition;
    vector_float4 lightDirectionIntensity;
    vector_float4 lightPositionRange;
    vector_float4 lightColor;
    vector_float4 colorTint;
    vector_uint4 flags;
} SledgehammerModelPreviewUniforms;

static matrix_float4x4 sledgehammer_matrix_identity(void) {
    return (matrix_float4x4){ .columns = {
        { 1.0f, 0.0f, 0.0f, 0.0f },
        { 0.0f, 1.0f, 0.0f, 0.0f },
        { 0.0f, 0.0f, 1.0f, 0.0f },
        { 0.0f, 0.0f, 0.0f, 1.0f },
    } };
}

static matrix_float4x4 sledgehammer_matrix_multiply(matrix_float4x4 a, matrix_float4x4 b) {
    return matrix_multiply(a, b);
}

static matrix_float4x4 sledgehammer_matrix_translation(float x, float y, float z) {
    matrix_float4x4 matrix = sledgehammer_matrix_identity();
    matrix.columns[3] = (vector_float4){ x, y, z, 1.0f };
    return matrix;
}

static matrix_float4x4 sledgehammer_matrix_look_at(vector_float3 eye, vector_float3 target, vector_float3 up) {
    vector_float3 forward = simd_normalize(target - eye);
    vector_float3 right = simd_normalize(simd_cross(forward, up));
    vector_float3 cameraUp = simd_cross(right, forward);
    matrix_float4x4 matrix = sledgehammer_matrix_identity();
    matrix.columns[0] = (vector_float4){ right.x, cameraUp.x, -forward.x, 0.0f };
    matrix.columns[1] = (vector_float4){ right.y, cameraUp.y, -forward.y, 0.0f };
    matrix.columns[2] = (vector_float4){ right.z, cameraUp.z, -forward.z, 0.0f };
    matrix.columns[3] = (vector_float4){ -simd_dot(right, eye), -simd_dot(cameraUp, eye), simd_dot(forward, eye), 1.0f };
    return matrix;
}

static matrix_float4x4 sledgehammer_matrix_rotation_y(float radians) {
    float c = cosf(radians);
    float s = sinf(radians);
    return (matrix_float4x4){ .columns = {
        { c, 0.0f, -s, 0.0f },
        { 0.0f, 1.0f, 0.0f, 0.0f },
        { s, 0.0f, c, 0.0f },
        { 0.0f, 0.0f, 0.0f, 1.0f },
    } };
}

static matrix_float4x4 sledgehammer_matrix_rotation_x(float radians) {
    float c = cosf(radians);
    float s = sinf(radians);
    return (matrix_float4x4){ .columns = {
        { 1.0f, 0.0f, 0.0f, 0.0f },
        { 0.0f, c, s, 0.0f },
        { 0.0f, -s, c, 0.0f },
        { 0.0f, 0.0f, 0.0f, 1.0f },
    } };
}

static matrix_float4x4 sledgehammer_matrix_perspective(float fovYRadians, float aspect, float zNear, float zFar) {
    float yScale = 1.0f / tanf(fovYRadians * 0.5f);
    float xScale = yScale / fmaxf(aspect, 1e-4f);
    float zRange = zFar - zNear;
    return (matrix_float4x4){ .columns = {
        { xScale, 0.0f, 0.0f, 0.0f },
        { 0.0f, yScale, 0.0f, 0.0f },
        { 0.0f, 0.0f, -(zFar + zNear) / zRange, -1.0f },
        { 0.0f, 0.0f, -(2.0f * zFar * zNear) / zRange, 0.0f },
    } };
}

static id<MTLDevice> sledgehammer_material_preview_device(void) {
    static id<MTLDevice> device = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        device = MTLCreateSystemDefaultDevice();
    });
    return device;
}

static id<MTLCommandQueue> sledgehammer_material_preview_command_queue(void) {
    static id<MTLCommandQueue> queue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        id<MTLDevice> device = sledgehammer_material_preview_device();
        queue = [device newCommandQueue];
    });
    return queue;
}

static id<MTLLibrary> sledgehammer_material_preview_library(void) {
    static id<MTLLibrary> library = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        id<MTLDevice> device = sledgehammer_material_preview_device();
        NSString* executableDir = [NSBundle.mainBundle.executablePath stringByDeletingLastPathComponent];
        NSString* metallibPath = [[NSBundle mainBundle] pathForResource:@"default" ofType:@"metallib"];
        if (metallibPath == nil) {
            metallibPath = [executableDir stringByAppendingPathComponent:@"default.metallib"];
        }
        if (metallibPath != nil) {
            library = [device newLibraryWithURL:[NSURL fileURLWithPath:metallibPath] error:nil];
        }
    });
    return library;
}

static id<MTLRenderPipelineState> sledgehammer_material_preview_pipeline(void) {
    static id<MTLRenderPipelineState> pipeline = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        id<MTLDevice> device = sledgehammer_material_preview_device();
        id<MTLLibrary> library = sledgehammer_material_preview_library();
        if (device == nil || library == nil) {
            return;
        }
        MTLRenderPipelineDescriptor* descriptor = [[MTLRenderPipelineDescriptor alloc] init];
        descriptor.label = @"SledgehammerMaterialPreviewPipeline";
        descriptor.vertexFunction = [library newFunctionWithName:@"sledgehammerMaterialPreviewVertex"];
        descriptor.fragmentFunction = [library newFunctionWithName:@"sledgehammerMaterialPreviewFragment"];
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:nil];
    });
    return pipeline;
}

static id<MTLRenderPipelineState> sledgehammer_model_preview_pipeline(void) {
    static id<MTLRenderPipelineState> pipeline = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        id<MTLDevice> device = sledgehammer_material_preview_device();
        id<MTLLibrary> library = sledgehammer_material_preview_library();
        if (device == nil || library == nil) {
            return;
        }
        MTLRenderPipelineDescriptor* descriptor = [[MTLRenderPipelineDescriptor alloc] init];
        descriptor.label = @"SledgehammerModelPreviewPipeline";
        descriptor.vertexFunction = [library newFunctionWithName:@"sledgehammerModelPreviewVertex"];
        descriptor.fragmentFunction = [library newFunctionWithName:@"sledgehammerModelPreviewFragment"];
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:nil];
    });
    return pipeline;
}

static id<MTLDepthStencilState> sledgehammer_material_preview_depth_state(void) {
    static id<MTLDepthStencilState> depthState = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        id<MTLDevice> device = sledgehammer_material_preview_device();
        if (device == nil) {
            return;
        }
        MTLDepthStencilDescriptor* descriptor = [[MTLDepthStencilDescriptor alloc] init];
        descriptor.depthCompareFunction = MTLCompareFunctionLess;
        descriptor.depthWriteEnabled = YES;
        depthState = [device newDepthStencilStateWithDescriptor:descriptor];
    });
    return depthState;
}

static id<MTLSamplerState> sledgehammer_material_preview_sampler(void) {
    static id<MTLSamplerState> sampler = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        id<MTLDevice> device = sledgehammer_material_preview_device();
        if (device == nil) {
            return;
        }
        MTLSamplerDescriptor* descriptor = [[MTLSamplerDescriptor alloc] init];
        descriptor.sAddressMode = MTLSamplerAddressModeRepeat;
        descriptor.tAddressMode = MTLSamplerAddressModeClampToEdge;
        descriptor.minFilter = MTLSamplerMinMagFilterLinear;
        descriptor.magFilter = MTLSamplerMinMagFilterLinear;
        descriptor.mipFilter = MTLSamplerMipFilterLinear;
        sampler = [device newSamplerStateWithDescriptor:descriptor];
    });
    return sampler;
}

static id<MTLTexture> sledgehammer_material_preview_fallback_texture(void) {
    static id<MTLTexture> texture = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        id<MTLDevice> device = sledgehammer_material_preview_device();
        if (device == nil) {
            return;
        }
        MTLTextureDescriptor* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                               width:1
                                                                                              height:1
                                                                                           mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead;
        descriptor.storageMode = MTLStorageModeShared;
        texture = [device newTextureWithDescriptor:descriptor];
        uint32_t pixel = 0xFF7A776F;
        [texture replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&pixel bytesPerRow:sizeof(pixel)];
    });
    return texture;
}

static id<MTLTexture> sledgehammer_texture_from_scene_texture(id<MTLDevice> device, const NovaSceneTexture* sceneTexture) {
    if (device == nil || sceneTexture == NULL || sceneTexture->width <= 0 || sceneTexture->height <= 0) {
        return nil;
    }

    MTLPixelFormat pixelFormat = sceneTexture->format == NOVA_SCENE_TEXTURE_FORMAT_RGBA32_FLOAT
        ? MTLPixelFormatRGBA32Float
        : MTLPixelFormatRGBA8Unorm;
    MTLTextureDescriptor* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pixelFormat
                                                                                           width:(NSUInteger)sceneTexture->width
                                                                                          height:(NSUInteger)sceneTexture->height
                                                                                       mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    if (texture == nil) {
        return nil;
    }

    MTLRegion fullRegion = MTLRegionMake2D(0, 0, (NSUInteger)sceneTexture->width, (NSUInteger)sceneTexture->height);
    if (sceneTexture->format == NOVA_SCENE_TEXTURE_FORMAT_RGBA32_FLOAT && sceneTexture->rgba32f != NULL) {
        [texture replaceRegion:fullRegion
                   mipmapLevel:0
                     withBytes:sceneTexture->rgba32f
                   bytesPerRow:(NSUInteger)sceneTexture->width * sizeof(float) * 4u];
        return texture;
    }
    if (sceneTexture->rgba8 != NULL) {
        [texture replaceRegion:fullRegion
                   mipmapLevel:0
                     withBytes:sceneTexture->rgba8
                   bytesPerRow:(NSUInteger)sceneTexture->width * 4u];
        return texture;
    }
    return nil;
}

static void sledgehammer_build_preview_sphere_mesh(NSMutableData* vertexData, NSMutableData* indexData) {
    const uint32_t slices = 96u;
    const uint32_t stacks = 64u;
    [vertexData setLength:0];
    [indexData setLength:0];

    for (uint32_t stack = 0u; stack <= stacks; ++stack) {
        float v = (float)stack / (float)stacks;
        float phi = v * (float)M_PI;
        float sinPhi = sinf(phi);
        float cosPhi = cosf(phi);
        for (uint32_t slice = 0u; slice <= slices; ++slice) {
            float u = (float)slice / (float)slices;
            float theta = u * ((float)M_PI * 2.0f);
            float sinTheta = sinf(theta);
            float cosTheta = cosf(theta);
            vector_float3 normal = { cosTheta * sinPhi, cosPhi, sinTheta * sinPhi };
            vector_float3 normalized = simd_normalize(normal);
            SledgehammerMaterialPreviewVertex vertex = {
                .position = { normal.x, normal.y, normal.z },
                .normal = { normalized.x, normalized.y, normalized.z },
                .uv = { u, v },
            };
            [vertexData appendBytes:&vertex length:sizeof(vertex)];
        }
    }

    for (uint32_t stack = 0u; stack < stacks; ++stack) {
        for (uint32_t slice = 0u; slice < slices; ++slice) {
            uint16_t a = (uint16_t)(stack * (slices + 1u) + slice);
            uint16_t b = (uint16_t)((stack + 1u) * (slices + 1u) + slice);
            uint16_t c = (uint16_t)(a + 1u);
            uint16_t d = (uint16_t)(b + 1u);
            uint16_t indices[6] = { a, b, c, c, b, d };
            [indexData appendBytes:indices length:sizeof(indices)];
        }
    }
}

static NSImage* sledgehammer_render_material_preview_image(NSString* texturePath) {
    id<MTLDevice> device = sledgehammer_material_preview_device();
    id<MTLCommandQueue> commandQueue = sledgehammer_material_preview_command_queue();
    id<MTLRenderPipelineState> pipeline = sledgehammer_material_preview_pipeline();
    id<MTLDepthStencilState> depthState = sledgehammer_material_preview_depth_state();
    id<MTLSamplerState> sampler = sledgehammer_material_preview_sampler();
    if (device == nil || commandQueue == nil || pipeline == nil || depthState == nil || sampler == nil) {
        return nil;
    }

    static NSMutableData* sphereVertexData = nil;
    static NSMutableData* sphereIndexData = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sphereVertexData = [NSMutableData data];
        sphereIndexData = [NSMutableData data];
        sledgehammer_build_preview_sphere_mesh(sphereVertexData, sphereIndexData);
    });

    const NSUInteger textureSize = 192u;
    MTLTextureDescriptor* colorDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                                 width:textureSize
                                                                                                height:textureSize
                                                                                             mipmapped:NO];
    colorDescriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    colorDescriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> colorTexture = [device newTextureWithDescriptor:colorDescriptor];

    MTLTextureDescriptor* depthDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                                 width:textureSize
                                                                                                height:textureSize
                                                                                             mipmapped:NO];
    depthDescriptor.usage = MTLTextureUsageRenderTarget;
    depthDescriptor.storageMode = MTLStorageModePrivate;
    id<MTLTexture> depthTexture = [device newTextureWithDescriptor:depthDescriptor];
    if (colorTexture == nil || depthTexture == nil) {
        return nil;
    }

    MTKTextureLoader* textureLoader = [[MTKTextureLoader alloc] initWithDevice:device];
    NSDictionary* options = @{
        MTKTextureLoaderOptionSRGB: @YES,
        MTKTextureLoaderOptionGenerateMipmaps: @YES,
    };
    id<MTLTexture> materialTexture = nil;
    if (texturePath.length > 0) {
        materialTexture = [textureLoader newTextureWithContentsOfURL:[NSURL fileURLWithPath:texturePath] options:options error:nil];
    }
    if (materialTexture == nil) {
        materialTexture = sledgehammer_material_preview_fallback_texture();
    }

    id<MTLBuffer> vertexBuffer = [device newBufferWithBytes:sphereVertexData.bytes length:sphereVertexData.length options:MTLResourceStorageModeShared];
    id<MTLBuffer> indexBuffer = [device newBufferWithBytes:sphereIndexData.bytes length:sphereIndexData.length options:MTLResourceStorageModeShared];
    if (vertexBuffer == nil || indexBuffer == nil) {
        return nil;
    }

    matrix_float4x4 model = sledgehammer_matrix_multiply(sledgehammer_matrix_rotation_y(-0.48f),
                                                         sledgehammer_matrix_rotation_x(0.35f));
    float previewFov = 35.0f * (float)M_PI / 180.0f;
    float previewDistance = 1.0f / sinf(previewFov * 0.5f) + 0.55f;
    vector_float3 eye = { 0.0f, -0.02f, previewDistance };
    vector_float3 target = { 0.0f, -0.02f, 0.0f };
    matrix_float4x4 view = sledgehammer_matrix_look_at(eye, target, (vector_float3){ 0.0f, 1.0f, 0.0f });
    matrix_float4x4 projection = sledgehammer_matrix_perspective(previewFov, 1.0f, 0.1f, 16.0f);
    SledgehammerMaterialPreviewUniforms uniforms = {
        .modelViewProjection = sledgehammer_matrix_multiply(projection, sledgehammer_matrix_multiply(view, model)),
        .modelMatrix = model,
        .keyLightDirection = { -0.48f, 0.62f, 0.62f, 0.0f },
        .rimLightDirection = { 0.75f, 0.10f, 0.55f, 0.0f },
        .baseColorTint = { 1.0f, 1.0f, 1.0f, 1.0f },
    };

    id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
    MTLRenderPassDescriptor* passDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    passDescriptor.colorAttachments[0].texture = colorTexture;
    passDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    passDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.11, 0.12, 0.14, 1.0);
    passDescriptor.depthAttachment.texture = depthTexture;
    passDescriptor.depthAttachment.loadAction = MTLLoadActionClear;
    passDescriptor.depthAttachment.storeAction = MTLStoreActionDontCare;
    passDescriptor.depthAttachment.clearDepth = 1.0;

    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:passDescriptor];
    [encoder setRenderPipelineState:pipeline];
    [encoder setDepthStencilState:depthState];
    [encoder setCullMode:MTLCullModeBack];
    [encoder setFrontFacingWinding:MTLWindingCounterClockwise];
    [encoder setVertexBuffer:vertexBuffer offset:0 atIndex:0];
    [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder setFragmentTexture:materialTexture atIndex:0];
    [encoder setFragmentSamplerState:sampler atIndex:0];
    [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                        indexCount:(NSUInteger)(sphereIndexData.length / sizeof(uint16_t))
                         indexType:MTLIndexTypeUInt16
                       indexBuffer:indexBuffer
                 indexBufferOffset:0];
    [encoder endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];

    if (commandBuffer.status != MTLCommandBufferStatusCompleted) {
        return nil;
    }

    NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:(NSInteger)textureSize
                      pixelsHigh:(NSInteger)textureSize
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSCalibratedRGBColorSpace
                     bytesPerRow:(NSInteger)textureSize * 4
                    bitsPerPixel:32];
    if (bitmap == nil || bitmap.bitmapData == NULL) {
        return nil;
    }
    [colorTexture getBytes:bitmap.bitmapData
               bytesPerRow:(NSUInteger)textureSize * 4
                fromRegion:MTLRegionMake2D(0, 0, textureSize, textureSize)
               mipmapLevel:0];

    NSImage* image = [[NSImage alloc] initWithSize:NSMakeSize((CGFloat)textureSize, (CGFloat)textureSize)];
    [image addRepresentation:bitmap];
    [image setTemplate:NO];
    return image;
}

static NSImage* sledgehammer_render_model_preview_image(NSString* modelAssetPath) {
    if (modelAssetPath.length == 0) {
        return nil;
    }

    NovaSceneData scene = {};
    char sceneError[512] = {0};
    if (!nova_model_asset_load_scene(modelAssetPath.fileSystemRepresentation, &scene, sceneError, (uint32_t)sizeof(sceneError))) {
        return nil;
    }

    id<MTLDevice> device = sledgehammer_material_preview_device();
    id<MTLCommandQueue> commandQueue = sledgehammer_material_preview_command_queue();
    id<MTLRenderPipelineState> pipeline = sledgehammer_model_preview_pipeline();
    id<MTLDepthStencilState> depthState = sledgehammer_material_preview_depth_state();
    id<MTLSamplerState> sampler = sledgehammer_material_preview_sampler();
    if (device == nil || commandQueue == nil || pipeline == nil || depthState == nil || sampler == nil || scene.vertexCount == 0u) {
        nova_scene_data_release(&scene);
        return nil;
    }

    NSMutableData* vertexData = [NSMutableData dataWithLength:(NSUInteger)scene.vertexCount * sizeof(SledgehammerModelPreviewVertex)];
    SledgehammerModelPreviewVertex* previewVertices = (SledgehammerModelPreviewVertex*)vertexData.mutableBytes;
    for (uint32_t vertexIndex = 0u; vertexIndex < scene.vertexCount; ++vertexIndex) {
        const NovaSceneVertex* source = &scene.vertices[vertexIndex];
        previewVertices[vertexIndex] = (SledgehammerModelPreviewVertex) {
            .position = { source->position[0], source->position[1], source->position[2] },
            .normal = { source->normal[0], source->normal[1], source->normal[2] },
            .uv = { source->uv[0], source->uv[1] },
        };
    }

    id<MTLBuffer> vertexBuffer = [device newBufferWithBytes:previewVertices
                                                     length:vertexData.length
                                                    options:MTLResourceStorageModeShared];
    if (vertexBuffer == nil) {
        nova_scene_data_release(&scene);
        return nil;
    }

    NSMutableArray<id<MTLBuffer>>* materialIndexBuffers = [NSMutableArray arrayWithCapacity:(NSUInteger)MAX(scene.materialCount, 1u)];
    NSMutableArray<NSNumber*>* materialIndexCounts = [NSMutableArray arrayWithCapacity:(NSUInteger)MAX(scene.materialCount, 1u)];
    for (uint32_t materialIndex = 0u; materialIndex < MAX(scene.materialCount, 1u); ++materialIndex) {
        NSMutableData* indexData = [NSMutableData data];
        if (scene.indices != NULL && scene.indexCount >= 3u && scene.primitiveMaterialIndices != NULL) {
            uint32_t primitiveCount = MIN(scene.primitiveCount, scene.indexCount / 3u);
            for (uint32_t primitiveIndex = 0u; primitiveIndex < primitiveCount; ++primitiveIndex) {
                if (scene.primitiveMaterialIndices[primitiveIndex] != materialIndex) {
                    continue;
                }
                uint32_t tri[3] = {
                    scene.indices[primitiveIndex * 3u + 0u],
                    scene.indices[primitiveIndex * 3u + 1u],
                    scene.indices[primitiveIndex * 3u + 2u],
                };
                [indexData appendBytes:tri length:sizeof(tri)];
            }
        } else {
            for (uint32_t primitiveIndex = 0u; primitiveIndex < scene.primitiveCount; ++primitiveIndex) {
                uint32_t base = primitiveIndex * 3u;
                if (base + 2u >= scene.vertexCount) {
                    break;
                }
                uint32_t sourceMaterial = scene.vertices[base].materialIndex;
                if (sourceMaterial != materialIndex) {
                    continue;
                }
                uint32_t tri[3] = { base + 0u, base + 1u, base + 2u };
                [indexData appendBytes:tri length:sizeof(tri)];
            }
        }
        if (indexData.length == 0) {
            [materialIndexBuffers addObject:(id)NSNull.null];
            [materialIndexCounts addObject:@0];
            continue;
        }
        id<MTLBuffer> indexBuffer = [device newBufferWithBytes:indexData.bytes
                                                        length:indexData.length
                                                       options:MTLResourceStorageModeShared];
        [materialIndexBuffers addObject:indexBuffer ?: (id)NSNull.null];
        [materialIndexCounts addObject:@(indexData.length / sizeof(uint32_t))];
    }

    const NSUInteger textureSize = 192u;
    MTLTextureDescriptor* colorDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                                 width:textureSize
                                                                                                height:textureSize
                                                                                             mipmapped:NO];
    colorDescriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    colorDescriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> colorTexture = [device newTextureWithDescriptor:colorDescriptor];
    MTLTextureDescriptor* depthDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                                 width:textureSize
                                                                                                height:textureSize
                                                                                             mipmapped:NO];
    depthDescriptor.usage = MTLTextureUsageRenderTarget;
    depthDescriptor.storageMode = MTLStorageModePrivate;
    id<MTLTexture> depthTexture = [device newTextureWithDescriptor:depthDescriptor];
    if (colorTexture == nil || depthTexture == nil) {
        nova_scene_data_release(&scene);
        return nil;
    }

    vector_float3 boundsMin = { scene.boundsMin[0], scene.boundsMin[1], scene.boundsMin[2] };
    vector_float3 boundsMax = { scene.boundsMax[0], scene.boundsMax[1], scene.boundsMax[2] };
    vector_float3 center = (boundsMin + boundsMax) * 0.5f;
    vector_float3 extent = boundsMax - boundsMin;
    float radius = 0.5f * simd_length(extent);
    if (!(radius > 1e-4f)) {
        radius = 0.5f;
    }
    vector_float3 eyeDirection = simd_normalize((vector_float3){ -1.25f, -1.05f, 0.85f });
    vector_float3 eye = center + eyeDirection * (radius / sinf(35.0f * (float)M_PI / 180.0f * 0.5f) + radius * 0.55f);
    vector_float3 up = fabsf(simd_dot(eyeDirection, (vector_float3){ 0.0f, 0.0f, 1.0f })) > 0.98f
        ? (vector_float3){ 0.0f, 1.0f, 0.0f }
        : (vector_float3){ 0.0f, 0.0f, 1.0f };
    matrix_float4x4 view = sledgehammer_matrix_look_at(eye, center, up);
    matrix_float4x4 projection = sledgehammer_matrix_perspective(35.0f * (float)M_PI / 180.0f, 1.0f, MAX(0.01f, radius * 0.05f), radius * 6.0f + 1.0f);
    SledgehammerModelPreviewUniforms uniforms = {
        .viewProjection = sledgehammer_matrix_multiply(projection, view),
        .cameraPosition = { eye.x, eye.y, eye.z, 1.0f },
        .lightDirectionIntensity = { -0.45f, 0.65f, 0.60f, 1.0f },
        .lightPositionRange = { 0.0f, 0.0f, 0.0f, 0.0f },
        .lightColor = { 1.0f, 1.0f, 1.0f, 1.0f },
        .colorTint = { 1.0f, 1.0f, 1.0f, 1.0f },
        .flags = { 0u, 0u, 1u, 0u },
    };

    MTLRenderPassDescriptor* passDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    passDescriptor.colorAttachments[0].texture = colorTexture;
    passDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    passDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.11, 0.12, 0.14, 1.0);
    passDescriptor.depthAttachment.texture = depthTexture;
    passDescriptor.depthAttachment.loadAction = MTLLoadActionClear;
    passDescriptor.depthAttachment.storeAction = MTLStoreActionDontCare;
    passDescriptor.depthAttachment.clearDepth = 1.0;

    id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:passDescriptor];
    [encoder setRenderPipelineState:pipeline];
    [encoder setDepthStencilState:depthState];
    [encoder setCullMode:MTLCullModeBack];
    [encoder setFrontFacingWinding:MTLWindingCounterClockwise];
    [encoder setVertexBuffer:vertexBuffer offset:0 atIndex:0];
    [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder setFragmentSamplerState:sampler atIndex:0];

    id<MTLTexture> fallbackTexture = sledgehammer_material_preview_fallback_texture();
    for (uint32_t materialIndex = 0u; materialIndex < MAX(scene.materialCount, 1u); ++materialIndex) {
        NSNumber* countNumber = materialIndexCounts[(NSUInteger)materialIndex];
        if (countNumber.unsignedIntegerValue == 0u) {
            continue;
        }
        id bufferObject = materialIndexBuffers[(NSUInteger)materialIndex];
        if (bufferObject == (id)NSNull.null) {
            continue;
        }
        id<MTLTexture> texture = fallbackTexture;
        if (materialIndex < scene.materialCount) {
            const NovaSceneMaterial* material = &scene.materials[materialIndex];
            if (material->baseColorTexture >= 0 && (uint32_t)material->baseColorTexture < scene.textureCount) {
                id<MTLTexture> sceneTexture = sledgehammer_texture_from_scene_texture(device, &scene.textures[(uint32_t)material->baseColorTexture]);
                if (sceneTexture != nil) {
                    texture = sceneTexture;
                }
            }
        }
        uniforms.flags = (vector_uint4){ 0u, 0u, 1u, texture != nil ? 1u : 0u };
        [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
        [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
        [encoder setFragmentTexture:texture atIndex:0];
        [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:countNumber.unsignedIntegerValue
                             indexType:MTLIndexTypeUInt32
                           indexBuffer:(id<MTLBuffer>)bufferObject
                     indexBufferOffset:0];
    }

    [encoder endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    nova_scene_data_release(&scene);
    if (commandBuffer.status != MTLCommandBufferStatusCompleted) {
        return nil;
    }

    NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:(NSInteger)textureSize
                      pixelsHigh:(NSInteger)textureSize
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSCalibratedRGBColorSpace
                     bytesPerRow:(NSInteger)textureSize * 4
                    bitsPerPixel:32];
    if (bitmap == nil || bitmap.bitmapData == NULL) {
        return nil;
    }
    [colorTexture getBytes:bitmap.bitmapData
               bytesPerRow:(NSUInteger)textureSize * 4
                fromRegion:MTLRegionMake2D(0, 0, textureSize, textureSize)
               mipmapLevel:0];
    NSImage* image = [[NSImage alloc] initWithSize:NSMakeSize((CGFloat)textureSize, (CGFloat)textureSize)];
    [image addRepresentation:bitmap];
    [image setTemplate:NO];
    return image;
}

static NSImage* sledgehammer_make_material_icon_image(NSString* materialName, NSString* texturePath) {
    (void)materialName;
    return sledgehammer_render_material_preview_image(texturePath);
}

static BOOL sledgehammer_write_material_icon_if_needed(NSString* materialName, NSString* materialAssetPath, NSString* texturePath) {
    if (materialName.length == 0) {
        return NO;
    }

    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSString* iconPath = sledgehammer_material_icon_path_for_name(materialName);
    [fileManager createDirectoryAtPath:sledgehammer_material_icons_directory() withIntermediateDirectories:YES attributes:nil error:nil];

    NSDictionary<NSFileAttributeKey, id>* iconAttributes = [fileManager attributesOfItemAtPath:iconPath error:nil];
    NSDictionary<NSFileAttributeKey, id>* materialAttributes = [fileManager attributesOfItemAtPath:materialAssetPath error:nil];
    NSDictionary<NSFileAttributeKey, id>* textureAttributes = texturePath.length > 0 ? [fileManager attributesOfItemAtPath:texturePath error:nil] : nil;
    NSDictionary<NSFileAttributeKey, id>* executableAttributes = [fileManager attributesOfItemAtPath:NSBundle.mainBundle.executablePath error:nil];
    NSDate* iconModified = iconAttributes[NSFileModificationDate];
    NSDate* materialModified = materialAttributes[NSFileModificationDate];
    NSDate* textureModified = textureAttributes[NSFileModificationDate];
    NSDate* executableModified = executableAttributes[NSFileModificationDate];
    BOOL iconIsCurrent = iconModified != nil &&
        (materialModified == nil || [iconModified compare:materialModified] != NSOrderedAscending) &&
        (textureModified == nil || [iconModified compare:textureModified] != NSOrderedAscending) &&
        (executableModified == nil || [iconModified compare:executableModified] != NSOrderedAscending);
    if (iconIsCurrent) {
        return YES;
    }

    NSImage* image = sledgehammer_make_material_icon_image(materialName, texturePath);
    NSBitmapImageRep* rep = nil;
    for (NSImageRep* candidate in image.representations) {
        if ([candidate isKindOfClass:[NSBitmapImageRep class]]) {
            rep = (NSBitmapImageRep*)candidate;
            break;
        }
    }
    if (rep == nil) {
        CGImageRef cgImage = [image CGImageForProposedRect:NULL context:nil hints:nil];
        if (cgImage != nil) {
            rep = [[NSBitmapImageRep alloc] initWithCGImage:cgImage];
        }
    }
    NSData* pngData = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return pngData != nil ? [pngData writeToFile:iconPath atomically:YES] : NO;
}

static NSString* sledgehammer_write_material_asset_definition(NSString* materialName, NSDictionary<NSString*, id>* definition) {
    if (materialName.length == 0 || definition.count == 0) {
        return nil;
    }
    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSString* materialsDirectory = sledgehammer_materials_directory();
    [fileManager createDirectoryAtPath:materialsDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    NSString* materialAssetPath = [materialsDirectory stringByAppendingPathComponent:[materialName.lowercaseString stringByAppendingString:kSledgehammerMaterialAssetSuffix]];
    NSData* jsonData = [NSJSONSerialization dataWithJSONObject:definition options:NSJSONWritingPrettyPrinted error:nil];
    if (jsonData == nil) {
        return nil;
    }
    if (![jsonData writeToFile:materialAssetPath atomically:YES]) {
        return nil;
    }
    return materialAssetPath;
}

static NSString* sledgehammer_write_material_asset(NSString* materialName, NSString* textureRelativePath) {
    if (materialName.length == 0) {
        return nil;
    }
    NSDictionary* definition = @{
        @"version": @1,
        @"name": materialName.lowercaseString,
        @"domain": @"surface",
        @"baseColorTexture": textureRelativePath ?: @"",
        @"previewIcon": [NSString stringWithFormat:@"icons/materials/%@.png", materialName.lowercaseString],
    };
    return sledgehammer_write_material_asset_definition(materialName, definition);
}

static NSData* sledgehammer_png_data_for_scene_texture(const NovaSceneTexture* texture) {
    if (texture == NULL || texture->width <= 0 || texture->height <= 0) {
        return nil;
    }

    const NSUInteger width = (NSUInteger)texture->width;
    const NSUInteger height = (NSUInteger)texture->height;
    NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:nil
                      pixelsWide:(NSInteger)width
                      pixelsHigh:(NSInteger)height
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSCalibratedRGBColorSpace
                     bytesPerRow:(NSInteger)width * 4
                    bitsPerPixel:32];
    if (bitmap == nil || bitmap.bitmapData == NULL) {
        return nil;
    }

    uint8_t* dst = bitmap.bitmapData;
    const size_t pixelCount = width * height;
    if (texture->rgba8 != NULL) {
        memcpy(dst, texture->rgba8, pixelCount * 4u);
    } else if (texture->rgba32f != NULL) {
        for (size_t index = 0; index < pixelCount; ++index) {
            for (size_t channel = 0; channel < 4u; ++channel) {
                float value = texture->rgba32f[index * 4u + channel];
                value = fminf(fmaxf(value, 0.0f), 1.0f);
                dst[index * 4u + channel] = (uint8_t)lrintf(value * 255.0f);
            }
        }
    } else {
        return nil;
    }

    return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

static BOOL sledgehammer_write_model_icon_if_needed(NSString* modelName, NSString* modelAssetPath) {
    if (modelName.length == 0 || modelAssetPath.length == 0) {
        return NO;
    }

    NSFileManager* fileManager = [NSFileManager defaultManager];
    [fileManager createDirectoryAtPath:sledgehammer_model_icons_directory() withIntermediateDirectories:YES attributes:nil error:nil];
    NSString* iconPath = sledgehammer_model_icon_path_for_name(modelName);
    NSDictionary<NSFileAttributeKey, id>* iconAttributes = [fileManager attributesOfItemAtPath:iconPath error:nil];
    NSDictionary<NSFileAttributeKey, id>* modelAttributes = [fileManager attributesOfItemAtPath:modelAssetPath error:nil];
    NSDictionary<NSFileAttributeKey, id>* executableAttributes = [fileManager attributesOfItemAtPath:NSBundle.mainBundle.executablePath error:nil];
    NSDate* iconModified = iconAttributes[NSFileModificationDate];
    NSDate* modelModified = modelAttributes[NSFileModificationDate];
    NSDate* executableModified = executableAttributes[NSFileModificationDate];
    if (iconModified != nil &&
        (modelModified == nil || [iconModified compare:modelModified] != NSOrderedAscending) &&
        (executableModified == nil || [iconModified compare:executableModified] != NSOrderedAscending)) {
        return YES;
    }

    NSImage* image = sledgehammer_render_model_preview_image(modelAssetPath);
    if (image == nil) {
        image = sledgehammer_make_placeholder_thumbnail_image(modelName);
    }

    NSBitmapImageRep* rep = nil;
    for (NSImageRep* candidate in image.representations) {
        if ([candidate isKindOfClass:[NSBitmapImageRep class]]) {
            rep = (NSBitmapImageRep*)candidate;
            break;
        }
    }
    if (rep == nil) {
        CGImageRef cgImage = [image CGImageForProposedRect:NULL context:nil hints:nil];
        if (cgImage != nil) {
            rep = [[NSBitmapImageRep alloc] initWithCGImage:cgImage];
        }
    }
    NSData* pngData = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return pngData != nil ? [pngData writeToFile:iconPath atomically:YES] : NO;
}

static NSDictionary<NSString*, NSString*>* sledgehammer_texture_slot_map_for_material(const NovaSceneMaterial* material) {
    if (material == NULL) {
        return @{};
    }
    return @{
        @"baseColorTexture": [NSString stringWithFormat:@"%d", material->baseColorTexture],
        @"metallicRoughnessTexture": [NSString stringWithFormat:@"%d", material->metallicRoughnessTexture],
        @"normalTexture": [NSString stringWithFormat:@"%d", material->normalTexture],
        @"emissiveTexture": [NSString stringWithFormat:@"%d", material->emissiveTexture],
        @"occlusionTexture": [NSString stringWithFormat:@"%d", material->occlusionTexture],
        @"transmissionTexture": [NSString stringWithFormat:@"%d", material->transmissionTexture],
    };
}

static void sledgehammer_sync_model_sidecar_assets(NSString* modelAssetPath) {
    if (modelAssetPath.length == 0) {
        return;
    }

    NSString* modelName = modelAssetPath.lastPathComponent.stringByDeletingPathExtension.lowercaseString;
    if (modelName.length == 0) {
        return;
    }

    NSFileManager* fileManager = [NSFileManager defaultManager];
    [fileManager createDirectoryAtPath:sledgehammer_materials_directory() withIntermediateDirectories:YES attributes:nil error:nil];
    [fileManager createDirectoryAtPath:sledgehammer_textures_directory() withIntermediateDirectories:YES attributes:nil error:nil];
    [fileManager createDirectoryAtPath:sledgehammer_material_icons_directory() withIntermediateDirectories:YES attributes:nil error:nil];
    [fileManager createDirectoryAtPath:sledgehammer_model_icons_directory() withIntermediateDirectories:YES attributes:nil error:nil];
    sledgehammer_write_model_icon_if_needed(modelName, modelAssetPath);
    NSString* sourceModelRelativePath = [@"models" stringByAppendingPathComponent:modelAssetPath.lastPathComponent];
    NSDirectoryEnumerator* staleMaterialEnumerator = [fileManager enumeratorAtPath:sledgehammer_materials_directory()];
    NSString* staleRelativePath = nil;
    while ((staleRelativePath = [staleMaterialEnumerator nextObject])) {
        if (![staleRelativePath.lowercaseString hasSuffix:kSledgehammerMaterialAssetSuffix]) {
            continue;
        }
        NSString* staleFullPath = [sledgehammer_materials_directory() stringByAppendingPathComponent:staleRelativePath];
        NSDictionary<NSString*, id>* staleDefinition = sledgehammer_read_material_definition(staleFullPath);
        if (![staleDefinition[@"generatedFromModel"] boolValue]) {
            continue;
        }
        NSString* staleSourceModel = [staleDefinition[@"sourceModel"] isKindOfClass:[NSString class]] ? staleDefinition[@"sourceModel"] : nil;
        if (![staleSourceModel isEqualToString:sourceModelRelativePath]) {
            continue;
        }
        [fileManager removeItemAtPath:staleFullPath error:nil];
    }

    NovaSceneData scene = {};
    char sceneError[512] = {0};
    if (!nova_model_asset_load_scene(modelAssetPath.fileSystemRepresentation, &scene, sceneError, (uint32_t)sizeof(sceneError))) {
        return;
    }

    NSString* modelTextureDirectory = [[sledgehammer_textures_directory() stringByAppendingPathComponent:@"models"] stringByAppendingPathComponent:modelName];
    [fileManager createDirectoryAtPath:modelTextureDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary<NSFileAttributeKey, id>* modelAttributes = [fileManager attributesOfItemAtPath:modelAssetPath error:nil];
    NSDate* modelModified = modelAttributes[NSFileModificationDate];

    for (uint32_t materialIndex = 0u; materialIndex < scene.materialCount; ++materialIndex) {
        const NovaSceneMaterial* material = &scene.materials[materialIndex];
        NSString* sourceMaterialName = [NSString stringWithUTF8String:material->name];
        NSString* materialAssetName = [NSString stringWithFormat:@"%@_mat_%u", modelName, materialIndex];

        NSMutableDictionary<NSString*, id>* definition = [@{
            @"version": @1,
            @"name": materialAssetName,
            @"domain": @"surface",
            @"sourceModel": sourceModelRelativePath,
            @"sourceMaterialName": sourceMaterialName.length > 0 ? sourceMaterialName : materialAssetName,
            @"generatedFromModel": @YES,
            @"previewIcon": [NSString stringWithFormat:@"icons/materials/%@.png", materialAssetName],
            @"baseColorFactor": @[ @(material->baseColorFactor[0]), @(material->baseColorFactor[1]), @(material->baseColorFactor[2]), @(material->baseColorFactor[3]) ],
            @"emissiveFactor": @[ @(material->emissiveFactor[0]), @(material->emissiveFactor[1]), @(material->emissiveFactor[2]) ],
            @"metallic": @(material->metallic),
            @"roughness": @(material->roughness),
            @"transmission": @(material->transmission),
            @"ior": @(material->ior),
            @"normalScale": @(material->normalScale),
            @"alphaCutoff": @(material->alphaCutoff),
            @"alphaMode": @(material->alphaMode),
            @"doubleSided": @(material->doubleSided != 0),
        } mutableCopy];

        NSDictionary<NSString*, NSString*>* slotMap = sledgehammer_texture_slot_map_for_material(material);
        [slotMap enumerateKeysAndObjectsUsingBlock:^(NSString* key, NSString* rawTextureIndex, BOOL* stop) {
            (void)stop;
            NSInteger textureIndex = rawTextureIndex.integerValue;
            if (textureIndex < 0 || (uint32_t)textureIndex >= scene.textureCount) {
                return;
            }

            NSString* semantic = [key stringByReplacingOccurrencesOfString:@"Texture" withString:@""].lowercaseString;
            NSString* filename = [NSString stringWithFormat:@"%@_%@.png", materialAssetName, semantic];
            NSString* texturePath = [modelTextureDirectory stringByAppendingPathComponent:filename];
            NSString* relativeTexturePath = [[@"textures/models" stringByAppendingPathComponent:modelName] stringByAppendingPathComponent:filename];
            NSDictionary<NSFileAttributeKey, id>* textureAttributes = [fileManager attributesOfItemAtPath:texturePath error:nil];
            NSDate* textureModified = textureAttributes[NSFileModificationDate];
            BOOL needsWrite = textureModified == nil || (modelModified != nil && [textureModified compare:modelModified] == NSOrderedAscending);
            if (needsWrite) {
                NSData* pngData = sledgehammer_png_data_for_scene_texture(&scene.textures[(uint32_t)textureIndex]);
                if (pngData != nil) {
                    [pngData writeToFile:texturePath atomically:YES];
                }
            }
            definition[key] = relativeTexturePath;
        }];

        NSString* materialAssetPath = sledgehammer_write_material_asset_definition(materialAssetName, definition);
        NSString* iconTexturePath = [definition[@"baseColorTexture"] isKindOfClass:[NSString class]]
            ? [sledgehammer_content_root_directory() stringByAppendingPathComponent:definition[@"baseColorTexture"]]
            : nil;
        sledgehammer_write_material_icon_if_needed(materialAssetName, materialAssetPath, iconTexturePath);
    }

    nova_scene_data_release(&scene);
}

@interface ContentBrowserAssetButton : NSButton <NSDraggingSource>

@property(nonatomic, copy) NSString* assetPath;

@end

@implementation ContentBrowserAssetButton

- (void)beginAssetDragWithEvent:(NSEvent*)event {
    if (self.assetPath.length == 0) {
        return;
    }

    NSURL* fileURL = [NSURL fileURLWithPath:self.assetPath];
    NSDraggingItem* draggingItem = [[NSDraggingItem alloc] initWithPasteboardWriter:fileURL];
    NSRect dragFrame = self.bounds;
    id dragContents = self.image != nil ? self.image : self.title;

    if (self.image != nil) {
        CGFloat inset = 10.0;
        CGFloat availableWidth = NSWidth(self.bounds) - inset * 2.0;
        CGFloat availableHeight = NSHeight(self.bounds) - inset * 2.0;
        CGFloat side = floor(MAX(1.0, MIN(availableWidth, availableHeight)));
        dragFrame = NSMakeRect(floor((NSWidth(self.bounds) - side) * 0.5),
                               floor((NSHeight(self.bounds) - side) * 0.5),
                               side,
                               side);
    }

    [draggingItem setDraggingFrame:dragFrame contents:dragContents];
    NSDraggingSession* session = [self beginDraggingSessionWithItems:@[draggingItem] event:event source:self];
    session.animatesToStartingPositionsOnCancelOrFail = YES;
}

- (void)mouseDown:(NSEvent*)event {
    if (self.assetPath.length == 0 || self.window == nil) {
        [super mouseDown:event];
        return;
    }

    NSPoint mouseDownPoint = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat dragThreshold = 4.0;
    BOOL startedDrag = NO;

    for (;;) {
        NSEvent* nextEvent = [self.window nextEventMatchingMask:(NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp)];
        if (nextEvent.type == NSEventTypeLeftMouseUp) {
            break;
        }

        NSPoint currentPoint = [self convertPoint:nextEvent.locationInWindow fromView:nil];
        CGFloat deltaX = currentPoint.x - mouseDownPoint.x;
        CGFloat deltaY = currentPoint.y - mouseDownPoint.y;
        if ((deltaX * deltaX + deltaY * deltaY) >= (dragThreshold * dragThreshold)) {
            [self beginAssetDragWithEvent:event];
            startedDrag = YES;
            break;
        }
    }

    if (!startedDrag && self.target != nil && self.action != NULL) {
        [NSApp sendAction:self.action to:self.target from:self];
    }
}

- (void)mouseDragged:(NSEvent*)event {
    if (self.assetPath.length == 0) {
        [super mouseDragged:event];
        return;
    }

    [self beginAssetDragWithEvent:event];
}

- (NSDragOperation)draggingSession:(NSDraggingSession*)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    (void)session;
    (void)context;
    return NSDragOperationCopy;
}

- (BOOL)ignoreModifierKeysForDraggingSession:(NSDraggingSession*)session {
    (void)session;
    return YES;
}

@end

static NSImage* sledgehammer_make_thumbnail_image(const NovaModelAssetThumbnail* thumbnail) {
    if (thumbnail == NULL || thumbnail->rgba8 == NULL || thumbnail->width == 0u || thumbnail->height == 0u) {
        return nil;
    }

    NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:nil
                      pixelsWide:(NSInteger)thumbnail->width
                      pixelsHigh:(NSInteger)thumbnail->height
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSCalibratedRGBColorSpace
                     bytesPerRow:(NSInteger)thumbnail->width * 4
                    bitsPerPixel:32];
    if (bitmap == nil || bitmap.bitmapData == NULL) {
        return nil;
    }

    memcpy(bitmap.bitmapData, thumbnail->rgba8, (size_t)thumbnail->width * (size_t)thumbnail->height * 4u);
    bitmap.size = NSMakeSize((CGFloat)thumbnail->width, (CGFloat)thumbnail->height);
    NSImage* image = [[NSImage alloc] initWithSize:NSMakeSize((CGFloat)thumbnail->width, (CGFloat)thumbnail->height)];
    [image addRepresentation:bitmap];
    [image setTemplate:NO];
    return image;
}

static NSImage* sledgehammer_make_placeholder_thumbnail_image(NSString* title) {
    NSSize size = NSMakeSize(192.0, 192.0);
    NSImage* image = [[NSImage alloc] initWithSize:size];
    [image lockFocus];

    NSGradient* gradient = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedRed:0.18 green:0.21 blue:0.26 alpha:1.0]
                                                         endingColor:[NSColor colorWithCalibratedRed:0.10 green:0.12 blue:0.16 alpha:1.0]];
    [gradient drawInRect:NSMakeRect(0.0, 0.0, size.width, size.height) angle:-90.0];

    [[NSColor colorWithCalibratedWhite:1.0 alpha:0.08] setFill];
    NSBezierPath* accentPath = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(18.0, 18.0, size.width - 36.0, size.height - 36.0) xRadius:18.0 yRadius:18.0];
    [accentPath fill];

    NSString* displayTitle = title.length > 0 ? title : @"Model";
    NSDictionary<NSAttributedStringKey, id>* attributes = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:18.0],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.98 alpha:1.0],
    };
    NSRect textRect = NSMakeRect(20.0, 20.0, size.width - 40.0, 48.0);
    [displayTitle drawInRect:textRect withAttributes:attributes];

    NSDictionary<NSAttributedStringKey, id>* subtitleAttributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.86 alpha:0.9],
    };
    [@"No embedded thumbnail" drawInRect:NSMakeRect(20.0, 54.0, size.width - 40.0, 24.0) withAttributes:subtitleAttributes];

    [image unlockFocus];
    [image setTemplate:NO];
    return image;
}

static NSString* sledgehammer_model_import_unit_label(uint32_t unit, uint32_t hintSource) {
    NSString* base = @"Unknown";
    switch (unit) {
        case NOVA_MODEL_IMPORT_UNIT_MILLIMETERS:
            base = @"Millimetres";
            break;
        case NOVA_MODEL_IMPORT_UNIT_CENTIMETERS:
            base = @"Centimetres";
            break;
        case NOVA_MODEL_IMPORT_UNIT_METERS:
            base = @"Metres";
            break;
        case NOVA_MODEL_IMPORT_UNIT_INCHES:
            base = @"Inches";
            break;
        case NOVA_MODEL_IMPORT_UNIT_FEET:
            base = @"Feet";
            break;
        default:
            break;
    }

    if (hintSource == NOVA_MODEL_IMPORT_UNIT_HINT_METADATA) {
        return [base stringByAppendingString:@" (metadata)"];
    }
    if (hintSource == NOVA_MODEL_IMPORT_UNIT_HINT_GLTF_DEFAULT) {
        return [base stringByAppendingString:@" (glTF default)"];
    }
    return base;
}

static NSString* sledgehammer_model_import_size_string(const float boundsMin[3], const float boundsMax[3], float scale) {
    float sizeX = (boundsMax[0] - boundsMin[0]) * scale;
    float sizeY = (boundsMax[1] - boundsMin[1]) * scale;
    float sizeZ = (boundsMax[2] - boundsMin[2]) * scale;
    return [NSString stringWithFormat:@"%.2f x %.2f x %.2f", sizeX, sizeY, sizeZ];
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation ViewerAppDelegate (SledgehammerContentBrowser)

- (NSInteger)contentBrowserColumnCountForAvailableWidth:(CGFloat)availableWidth itemWidth:(CGFloat)itemWidth spacing:(CGFloat)spacing {
    CGFloat safeWidth = MAX(availableWidth, itemWidth);
    NSInteger columnCount = (NSInteger)floor((safeWidth + spacing) / (itemWidth + spacing));
    return MAX(1, columnCount);
}

- (void)layoutContentBrowserItems {
    CGFloat itemWidth = 116.0;
    CGFloat itemHeight = 132.0;
    CGFloat spacing = 10.0;
    CGFloat availableWidth = self.contentBrowserScrollView.contentView.bounds.size.width;
    if (!(availableWidth > 0.0)) {
        availableWidth = self.contentBrowserBodyView.bounds.size.width;
    }
    NSInteger columnCount = [self contentBrowserColumnCountForAvailableWidth:availableWidth itemWidth:itemWidth spacing:spacing];
    CGFloat usedWidth = columnCount * itemWidth + MAX(0, columnCount - 1) * spacing;
    CGFloat contentWidth = MAX(availableWidth, usedWidth);
    CGFloat leftInset = 0.0;

    [self.contentBrowserGridView.subviews enumerateObjectsUsingBlock:^(__kindof NSView* subview, NSUInteger index, BOOL* stop) {
        (void)stop;
        NSInteger row = (NSInteger)index / columnCount;
        NSInteger column = (NSInteger)index % columnCount;
        subview.frame = NSMakeRect(leftInset + (itemWidth + spacing) * column,
                                   (itemHeight + spacing) * row,
                                   itemWidth,
                                   itemHeight);
    }];

    NSInteger rowCount = (NSInteger)((self.contentBrowserItems.count + (NSUInteger)columnCount - 1u) / (NSUInteger)columnCount);
    CGFloat contentHeight = MAX(1.0, rowCount * itemHeight + MAX(0, rowCount - 1) * spacing);
    self.contentBrowserGridView.frame = NSMakeRect(0.0, 0.0, contentWidth, contentHeight);
}

- (void)contentBrowserClipViewFrameDidChange:(NSNotification*)notification {
    if (notification.object != self.contentBrowserScrollView.contentView) {
        return;
    }
    [self layoutContentBrowserItems];
}

- (void)contentBrowserAssetPressed:(ContentBrowserAssetButton*)sender {
    if (![sender isKindOfClass:[ContentBrowserAssetButton class]]) {
        return;
    }
    if (![sender.assetPath.lowercaseString hasSuffix:kSledgehammerMaterialAssetSuffix]) {
        return;
    }
    NSString* materialName = sledgehammer_material_name_from_asset_path(sender.assetPath);
    if (materialName.length == 0) {
        return;
    }
    self.brushMaterialName = materialName;
    [self updateChrome];
}

- (void)buildContentBrowserUI {
    if (self.contentBrowserPanel != nil) {
        return;
    }

    self.contentBrowserPanel = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    self.contentBrowserPanel.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentBrowserPanel.material = NSVisualEffectMaterialSidebar;
    self.contentBrowserPanel.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    self.contentBrowserPanel.state = NSVisualEffectStateActive;
    self.contentBrowserPanel.wantsLayer = YES;
    self.contentBrowserPanel.layer.cornerRadius = 8.0;
    self.contentBrowserPanel.layer.masksToBounds = YES;

    NSStackView* stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8.0;
    stack.edgeInsets = NSEdgeInsetsMake(10.0, 10.0, 10.0, 10.0);

    NSStackView* header = [[NSStackView alloc] initWithFrame:NSZeroRect];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    header.alignment = NSLayoutAttributeCenterY;
    header.spacing = 8.0;

    self.contentBrowserTabButton = [NSButton buttonWithTitle:@"Content Browser" target:self action:@selector(toggleContentBrowser:)];
    self.contentBrowserTabButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentBrowserTabButton.bezelStyle = NSBezelStyleTexturedRounded;

    self.contentBrowserModeControl = [[NSSegmentedControl alloc] initWithFrame:NSZeroRect];
    self.contentBrowserModeControl.segmentCount = 2;
    [self.contentBrowserModeControl setLabel:@"Models" forSegment:0];
    [self.contentBrowserModeControl setLabel:@"Materials" forSegment:1];
    self.contentBrowserModeControl.trackingMode = NSSegmentSwitchTrackingSelectOne;
    self.contentBrowserModeControl.target = self;
    self.contentBrowserModeControl.action = @selector(contentBrowserModeChanged:);
    self.contentBrowserModeControl.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentBrowserModeControl.controlSize = NSControlSizeSmall;
    self.contentBrowserModeControl.selectedSegment = SledgehammerContentBrowserModeModels;
    [self.contentBrowserModeControl setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.contentBrowserImportButton = [NSButton buttonWithTitle:@"Import Models" target:self action:@selector(importModelsToContentBrowser:)];
    self.contentBrowserImportButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentBrowserImportButton.bezelStyle = NSBezelStyleRounded;
    [self.contentBrowserTabButton setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.contentBrowserImportButton setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    [header addArrangedSubview:self.contentBrowserTabButton];
    [header addArrangedSubview:self.contentBrowserModeControl];
    [header addArrangedSubview:self.contentBrowserImportButton];

    self.contentBrowserBodyView = [[NSView alloc] initWithFrame:NSZeroRect];
    self.contentBrowserBodyView.translatesAutoresizingMaskIntoConstraints = NO;

    self.contentBrowserStatusLabel = [NSTextField labelWithString:@"No imported model assets yet."];
    self.contentBrowserStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentBrowserStatusLabel.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
    self.contentBrowserStatusLabel.textColor = [NSColor secondaryLabelColor];
    self.contentBrowserStatusLabel.maximumNumberOfLines = 2;

    self.contentBrowserGridView = [[NSView alloc] initWithFrame:NSZeroRect];
    self.contentBrowserGridView.translatesAutoresizingMaskIntoConstraints = NO;

    self.contentBrowserScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.contentBrowserScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentBrowserScrollView.hasVerticalScroller = YES;
    self.contentBrowserScrollView.hasHorizontalScroller = NO;
    self.contentBrowserScrollView.autohidesScrollers = YES;
    self.contentBrowserScrollView.borderType = NSNoBorder;
    self.contentBrowserScrollView.drawsBackground = NO;
    self.contentBrowserScrollView.documentView = self.contentBrowserGridView;
    self.contentBrowserScrollView.contentView.postsFrameChangedNotifications = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(contentBrowserClipViewFrameDidChange:)
                                                 name:NSViewFrameDidChangeNotification
                                               object:self.contentBrowserScrollView.contentView];

    [self.contentBrowserBodyView addSubview:self.contentBrowserStatusLabel];
    [self.contentBrowserBodyView addSubview:self.contentBrowserScrollView];
    [self.contentBrowserPanel addSubview:stack];
    [stack addArrangedSubview:header];
    [stack addArrangedSubview:self.contentBrowserBodyView];

    [self.rootView addSubview:self.contentBrowserPanel];

    self.contentBrowserHeightConstraint = [self.contentBrowserPanel.heightAnchor constraintEqualToConstant:42.0];
    self.contentBrowserHeightConstraint.active = YES;
    self.contentBrowserBodyView.hidden = YES;
    self.contentBrowserBodyView.alphaValue = 0.0;

    NSLayoutConstraint* panelLeadingConstraint = [self.contentBrowserPanel.leadingAnchor constraintEqualToAnchor:self.rootView.leadingAnchor constant:80.0];
    NSLayoutConstraint* panelTrailingConstraint = [self.contentBrowserPanel.trailingAnchor constraintEqualToAnchor:self.rootView.trailingAnchor constant:-12.0];
    NSLayoutConstraint* stackLeadingConstraint = [stack.leadingAnchor constraintEqualToAnchor:self.contentBrowserPanel.leadingAnchor];
    NSLayoutConstraint* stackTrailingConstraint = [stack.trailingAnchor constraintEqualToAnchor:self.contentBrowserPanel.trailingAnchor];
    NSLayoutConstraint* headerWidthConstraint = [header.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-(stack.edgeInsets.left + stack.edgeInsets.right)];
    headerWidthConstraint.priority = NSLayoutPriorityDefaultLow;
    NSLayoutConstraint* bodyWidthConstraint = [self.contentBrowserBodyView.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-(stack.edgeInsets.left + stack.edgeInsets.right)];
    bodyWidthConstraint.priority = NSLayoutPriorityDefaultLow;
    NSLayoutConstraint* statusLeadingConstraint = [self.contentBrowserStatusLabel.leadingAnchor constraintEqualToAnchor:self.contentBrowserBodyView.leadingAnchor];
    statusLeadingConstraint.priority = NSLayoutPriorityDefaultLow;
    NSLayoutConstraint* statusTrailingConstraint = [self.contentBrowserStatusLabel.trailingAnchor constraintEqualToAnchor:self.contentBrowserBodyView.trailingAnchor];
    statusTrailingConstraint.priority = NSLayoutPriorityDefaultLow;
    NSLayoutConstraint* scrollLeadingConstraint = [self.contentBrowserScrollView.leadingAnchor constraintEqualToAnchor:self.contentBrowserBodyView.leadingAnchor];
    scrollLeadingConstraint.priority = NSLayoutPriorityDefaultLow;
    NSLayoutConstraint* scrollTrailingConstraint = [self.contentBrowserScrollView.trailingAnchor constraintEqualToAnchor:self.contentBrowserBodyView.trailingAnchor];
    scrollTrailingConstraint.priority = NSLayoutPriorityDefaultLow;
    [NSLayoutConstraint activateConstraints:@[
        panelLeadingConstraint,
        panelTrailingConstraint,
        [self.contentBrowserPanel.bottomAnchor constraintEqualToAnchor:self.rootView.bottomAnchor constant:-12.0],
        stackLeadingConstraint,
        stackTrailingConstraint,
        [stack.topAnchor constraintEqualToAnchor:self.contentBrowserPanel.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:self.contentBrowserPanel.bottomAnchor],
        headerWidthConstraint,
        bodyWidthConstraint,
        statusLeadingConstraint,
        statusTrailingConstraint,
        [self.contentBrowserStatusLabel.topAnchor constraintEqualToAnchor:self.contentBrowserBodyView.topAnchor],
        scrollLeadingConstraint,
        scrollTrailingConstraint,
        [self.contentBrowserScrollView.topAnchor constraintEqualToAnchor:self.contentBrowserStatusLabel.bottomAnchor constant:8.0],
        [self.contentBrowserScrollView.bottomAnchor constraintEqualToAnchor:self.contentBrowserBodyView.bottomAnchor],
        [self.contentBrowserScrollView.heightAnchor constraintEqualToConstant:240.0],
    ]];

    [self reloadContentBrowser];
}

- (void)setContentBrowserCollapsed:(BOOL)collapsed animated:(BOOL)animated {
    self.contentBrowserCollapsed = collapsed;

    CGFloat targetHeight = self.hasDocument ? (collapsed ? 42.0 : 330.0) : 0.0;
    self.contentBrowserPanel.hidden = !self.hasDocument;

    if (!collapsed) {
        self.contentBrowserBodyView.hidden = NO;
    }

    void (^applyState)(BOOL) = ^(BOOL useAnimator) {
        if (useAnimator) {
            self.contentBrowserHeightConstraint.animator.constant = targetHeight;
            self.contentBrowserBodyView.animator.alphaValue = collapsed ? 0.0 : 1.0;
        } else {
            self.contentBrowserHeightConstraint.constant = targetHeight;
            self.contentBrowserBodyView.alphaValue = collapsed ? 0.0 : 1.0;
        }
    };

    if (animated && self.hasDocument) {
        [self.rootView layoutSubtreeIfNeeded];
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext* context) {
            context.duration = 0.22;
            applyState(YES);
            [self.rootView layoutSubtreeIfNeeded];
        } completionHandler:^{
            self.contentBrowserBodyView.hidden = collapsed;
            self.contentBrowserPanel.hidden = !self.hasDocument;
        }];
    } else {
        applyState(NO);
        self.contentBrowserBodyView.hidden = collapsed || !self.hasDocument;
    }
}

- (NSString*)contentBrowserRootDirectory {
    return sledgehammer_content_root_directory();
}

- (void)contentBrowserModeChanged:(id)sender {
    (void)sender;
    [self reloadContentBrowser];
}

- (NSString*)contentBrowserImportButtonTitle {
    return self.contentBrowserModeControl.selectedSegment == SledgehammerContentBrowserModeMaterials ? @"Import Textures" : @"Import Models";
}

- (void)reloadContentBrowser {
    if (self.contentBrowserItems == nil) {
        self.contentBrowserItems = [NSMutableArray array];
    }
    [self.contentBrowserItems removeAllObjects];

    NSString* modelsDirectory = sledgehammer_models_directory();
    BOOL isDirectory = NO;
    NSFileManager* fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:modelsDirectory isDirectory:&isDirectory] || !isDirectory) {
        [fileManager createDirectoryAtPath:modelsDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    }

    [self.contentBrowserImportButton setTitle:[self contentBrowserImportButtonTitle]];

    if (self.contentBrowserModeControl.selectedSegment == SledgehammerContentBrowserModeMaterials) {
        NSString* materialsDirectory = sledgehammer_materials_directory();
        NSString* texturesDirectory = sledgehammer_textures_directory();
        [fileManager createDirectoryAtPath:materialsDirectory withIntermediateDirectories:YES attributes:nil error:nil];
        [fileManager createDirectoryAtPath:texturesDirectory withIntermediateDirectories:YES attributes:nil error:nil];
        [fileManager createDirectoryAtPath:sledgehammer_material_icons_directory() withIntermediateDirectories:YES attributes:nil error:nil];

        NSMutableOrderedSet<NSString*>* materialNames = [NSMutableOrderedSet orderedSet];
        NSDirectoryEnumerator* materialEnumerator = [fileManager enumeratorAtPath:materialsDirectory];
        NSString* relativePath = nil;
        while ((relativePath = [materialEnumerator nextObject])) {
            if (![relativePath.lowercaseString hasSuffix:kSledgehammerMaterialAssetSuffix]) {
                continue;
            }
            NSString* fullPath = [materialsDirectory stringByAppendingPathComponent:relativePath];
            NSString* materialName = sledgehammer_material_name_from_asset_path(fullPath);
            NSDictionary<NSString*, id>* definition = sledgehammer_read_material_definition(fullPath);
            NSString* baseColorTexture = [definition[@"baseColorTexture"] isKindOfClass:[NSString class]] ? definition[@"baseColorTexture"] : nil;
            BOOL generatedFromModel = [definition[@"generatedFromModel"] boolValue];
            if (!generatedFromModel && [baseColorTexture.lowercaseString hasPrefix:@"textures/models/"]) {
                continue;
            }
            NSString* texturePath = baseColorTexture.length > 0 ? [self resolvedTexturePathForMaterialName:materialName] : nil;
            sledgehammer_write_material_icon_if_needed(materialName, fullPath, texturePath);
            [materialNames addObject:materialName];
        }

        for (NSString* materialName in self.allMaterials) {
            if (materialName.length > 0) {
                [materialNames addObject:materialName.lowercaseString];
            }
        }

        NSArray<NSString*>* sortedNames = [materialNames.array sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
        for (NSString* materialName in sortedNames) {
            NSString* materialAssetPath = [materialsDirectory stringByAppendingPathComponent:[materialName stringByAppendingString:kSledgehammerMaterialAssetSuffix]];
            if (![fileManager fileExistsAtPath:materialAssetPath]) {
                continue;
            }
            NSString* iconPath = sledgehammer_material_icon_path_for_name(materialName);
            [self.contentBrowserItems addObject:@{
                @"kind": @"material",
                @"name": materialName,
                @"path": materialAssetPath ?: @"",
                @"iconPath": [fileManager fileExistsAtPath:iconPath] ? iconPath : @"",
            }];
        }
    } else {
        NSArray<NSString*>* entries = [fileManager contentsOfDirectoryAtPath:modelsDirectory error:nil];
        NSArray<NSString*>* sortedEntries = [entries sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
        for (NSString* entry in sortedEntries) {
            if (![entry.pathExtension.lowercaseString isEqualToString:kSledgehammerModelAssetExtension]) {
                continue;
            }
            NSString* fullPath = [modelsDirectory stringByAppendingPathComponent:entry];
            NSString* modelName = entry.stringByDeletingPathExtension;
            sledgehammer_sync_model_sidecar_assets(fullPath);
            NSString* iconPath = sledgehammer_model_icon_path_for_name(modelName);
            [self.contentBrowserItems addObject:@{
                @"kind": @"model",
                @"name": modelName,
                @"path": fullPath,
                @"iconPath": [fileManager fileExistsAtPath:iconPath] ? iconPath : @"",
            }];
        }
    }

    for (NSView* subview in self.contentBrowserGridView.subviews.copy) {
        [subview removeFromSuperview];
    }

    [self.contentBrowserItems enumerateObjectsUsingBlock:^(NSDictionary<NSString*, id>* item, NSUInteger index, BOOL* stop) {
        (void)stop;
        NSRect frame = NSMakeRect(0.0, 0.0, 116.0, 132.0);
        ContentBrowserAssetButton* button = [[ContentBrowserAssetButton alloc] initWithFrame:frame];
        button.assetPath = item[@"path"];
        button.title = item[@"name"];
        button.imagePosition = NSImageAbove;
        button.bordered = NO;
        button.imageScaling = NSImageScaleProportionallyUpOrDown;
        button.alignment = NSTextAlignmentCenter;
        button.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium];
        button.toolTip = button.title;
        if ([button.cell isKindOfClass:[NSButtonCell class]]) {
            NSButtonCell* buttonCell = (NSButtonCell*)button.cell;
            buttonCell.wraps = NO;
            buttonCell.lineBreakMode = NSLineBreakByTruncatingTail;
        }
        NSImage* thumbnailImage = nil;
        NSString* kind = item[@"kind"];
        if ([kind isEqualToString:@"material"]) {
            NSString* iconPath = item[@"iconPath"];
            if (iconPath.length > 0) {
                thumbnailImage = [[NSImage alloc] initWithContentsOfFile:iconPath];
            }
            if (thumbnailImage == nil) {
                NSString* texturePath = [self resolvedTexturePathForMaterialName:button.title];
                thumbnailImage = sledgehammer_make_material_icon_image(button.title, texturePath);
            }
        } else {
            NSString* iconPath = item[@"iconPath"];
            if (iconPath.length > 0) {
                thumbnailImage = [[NSImage alloc] initWithContentsOfFile:iconPath];
            }
            if (thumbnailImage == nil) {
                NovaModelAssetThumbnail thumbnail = {0};
                char thumbnailError[256] = {0};
                if (nova_model_asset_read_thumbnail(button.assetPath.fileSystemRepresentation, &thumbnail, thumbnailError, (uint32_t)sizeof(thumbnailError))) {
                    thumbnailImage = sledgehammer_make_thumbnail_image(&thumbnail);
                }
                nova_model_asset_thumbnail_release(&thumbnail);
            }
            if (thumbnailImage == nil) {
                thumbnailImage = sledgehammer_make_placeholder_thumbnail_image(button.title);
            }
        }
        [thumbnailImage setTemplate:NO];
        button.image = thumbnailImage;
        if ([kind isEqualToString:@"material"] && button.assetPath.length > 0) {
            button.target = self;
            button.action = @selector(contentBrowserAssetPressed:);
        } else {
            button.target = nil;
            button.action = NULL;
        }
        [self.contentBrowserGridView addSubview:button];
    }];

    [self layoutContentBrowserItems];
    if (self.contentBrowserModeControl.selectedSegment == SledgehammerContentBrowserModeMaterials) {
        self.contentBrowserStatusLabel.stringValue = self.contentBrowserItems.count > 0
            ? [NSString stringWithFormat:@"%zu material assets", (size_t)self.contentBrowserItems.count]
            : @"No material assets yet. Import a texture to create one.";
    } else {
        self.contentBrowserStatusLabel.stringValue = self.contentBrowserItems.count > 0
            ? [NSString stringWithFormat:@"%zu model assets", (size_t)self.contentBrowserItems.count]
            : @"No imported model assets yet.";
    }
}

- (void)toggleContentBrowser:(id)sender {
    (void)sender;
    [self setContentBrowserCollapsed:!self.contentBrowserCollapsed animated:YES];
    [self.contentBrowserTabButton setTitle:self.contentBrowserCollapsed ? @"Content Browser" : @"Content Browser"];
    [self updateChrome];
}

- (void)importModelsToContentBrowser:(id)sender {
    (void)sender;
    if (self.contentBrowserModeControl.selectedSegment == SledgehammerContentBrowserModeMaterials) {
        NSOpenPanel* texturePanel = [NSOpenPanel openPanel];
        texturePanel.canChooseFiles = YES;
        texturePanel.canChooseDirectories = NO;
        texturePanel.allowsMultipleSelection = YES;
        texturePanel.allowedContentTypes = @[
            [UTType typeWithFilenameExtension:@"png"],
            [UTType typeWithFilenameExtension:@"jpg"],
            [UTType typeWithFilenameExtension:@"jpeg"],
        ];
        if ([texturePanel runModal] != NSModalResponseOK) {
            return;
        }

        NSFileManager* fileManager = [NSFileManager defaultManager];
        NSString* texturesDirectory = sledgehammer_textures_directory();
        [fileManager createDirectoryAtPath:texturesDirectory withIntermediateDirectories:YES attributes:nil error:nil];
        NSMutableArray<NSString*>* failures = [NSMutableArray array];
        for (NSURL* url in texturePanel.URLs) {
            NSString* materialName = sledgehammer_sanitized_model_asset_name(url.lastPathComponent.stringByDeletingPathExtension).lowercaseString;
            if (materialName.length == 0) {
                [failures addObject:[NSString stringWithFormat:@"%@: invalid material name.", url.lastPathComponent ?: @"<unknown>"]];
                continue;
            }
            NSString* targetTexturePath = [texturesDirectory stringByAppendingPathComponent:[materialName stringByAppendingPathExtension:url.pathExtension.lowercaseString]];
            if (![fileManager removeItemAtPath:targetTexturePath error:nil] && [fileManager fileExistsAtPath:targetTexturePath]) {
                [failures addObject:[NSString stringWithFormat:@"%@: failed to replace existing texture.", url.lastPathComponent ?: @"<unknown>"]];
                continue;
            }
            if (![fileManager copyItemAtPath:url.path toPath:targetTexturePath error:nil]) {
                [failures addObject:[NSString stringWithFormat:@"%@: failed to copy texture.", url.lastPathComponent ?: @"<unknown>"]];
                continue;
            }
        }
        [self setContentBrowserCollapsed:NO animated:YES];
        [self reloadContentBrowser];
        if (failures.count > 0) {
            [self showError:[NSString stringWithFormat:@"Texture import failed for:\n%@", [failures componentsJoinedByString:@"\n"]]];
        }
        return;
    }

    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = YES;
    panel.allowedContentTypes = @[
        [UTType typeWithFilenameExtension:@"gltf"],
        [UTType typeWithFilenameExtension:@"glb"],
        [UTType typeWithFilenameExtension:@"obj"],
    ];
    if ([panel runModal] != NSModalResponseOK) {
        return;
    }

    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSString* modelsDirectory = sledgehammer_models_directory();
    [fileManager createDirectoryAtPath:modelsDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableArray<NSString*>* failures = [NSMutableArray array];
    for (NSURL* url in panel.URLs) {
        float importScale = 1.0f;
        uint32_t importUpAxisMode = NOVA_MODEL_IMPORT_UP_AXIS_AUTO;
        NSString* assetName = nil;
        NSString* modalError = nil;
        NSModalResponse modalResponse = [self runModelImportSettingsModalForURL:url
                                                                    outAssetName:&assetName
                                                                        outScale:&importScale
                                                                   outUpAxisMode:&importUpAxisMode
                                                                           error:&modalError];
        if (modalResponse == NSAlertThirdButtonReturn) {
            break;
        }
        if (modalResponse != NSAlertFirstButtonReturn) {
            continue;
        }
        if (modalError.length > 0) {
            NSString* filename = url.lastPathComponent ?: @"<unknown>";
            [failures addObject:[NSString stringWithFormat:@"%@: %@", filename, modalError]];
            continue;
        }

        NSString* targetPath = [[modelsDirectory stringByAppendingPathComponent:assetName] stringByAppendingPathExtension:kSledgehammerModelAssetExtension];
        NSDictionary<NSFileAttributeKey, id>* sourceAttributes = [fileManager attributesOfItemAtPath:url.path error:nil];
        NSDictionary<NSFileAttributeKey, id>* targetAttributes = [fileManager attributesOfItemAtPath:targetPath error:nil];
        NSDictionary<NSFileAttributeKey, id>* executableAttributes = [fileManager attributesOfItemAtPath:NSBundle.mainBundle.executablePath error:nil];
        NSDate* sourceModified = sourceAttributes[NSFileModificationDate];
        NSDate* targetModified = targetAttributes[NSFileModificationDate];
        NSDate* executableModified = executableAttributes[NSFileModificationDate];
        BOOL targetUpToDateForSource = (sourceModified != nil && targetModified != nil && [targetModified compare:sourceModified] != NSOrderedAscending);
        BOOL targetUpToDateForImporter = (executableModified == nil || targetModified == nil || [targetModified compare:executableModified] != NSOrderedAscending);
        if (targetUpToDateForSource && targetUpToDateForImporter) {
            continue;
        }

        NovaModelAssetImportOptions options = {};
        options.uniformScale = importScale > 0.0f ? importScale : 1.0f;
        options.upAxisMode = importUpAxisMode;
        char compileMessage[512] = {0};
        if (!nova_model_asset_compile_from_source_with_options(url.path.fileSystemRepresentation,
                                                               targetPath.fileSystemRepresentation,
                                                               &options,
                                                               compileMessage,
                                                               (uint32_t)sizeof(compileMessage))) {
            NSString* filename = url.lastPathComponent ?: @"<unknown>";
            NSString* reason = compileMessage[0] != '\0' ? [NSString stringWithUTF8String:compileMessage] : @"Unknown error";
            [failures addObject:[NSString stringWithFormat:@"%@: %@", filename, reason]];
        }
    }
    [self setContentBrowserCollapsed:NO animated:YES];
    [self reloadContentBrowser];
    if (failures.count > 0) {
        [self showError:[NSString stringWithFormat:@"Model import failed for:\n%@", [failures componentsJoinedByString:@"\n"]]];
    }
}

- (NSModalResponse)runModelImportSettingsModalForURL:(NSURL*)url outAssetName:(NSString**)outAssetName outScale:(float*)outScale outUpAxisMode:(uint32_t*)outUpAxisMode error:(NSString**)outError {
    NSString* defaultAssetName;

    if (outAssetName != NULL) {
        *outAssetName = nil;
    }
    if (outScale != NULL) {
        *outScale = 1.0f;
    }
    if (outUpAxisMode != NULL) {
        *outUpAxisMode = NOVA_MODEL_IMPORT_UP_AXIS_AUTO;
    }
    if (outError != NULL) {
        *outError = nil;
    }
    if (url == nil || url.path.length == 0) {
        if (outError != NULL) {
            *outError = @"Model path is empty.";
        }
        return NSAlertSecondButtonReturn;
    }

    NovaModelAssetImportInfo info = {};
    char inspectMessage[512] = {0};
    if (!nova_model_asset_inspect_source(url.path.fileSystemRepresentation, &info, inspectMessage, (uint32_t)sizeof(inspectMessage))) {
        if (outError != NULL) {
            *outError = inspectMessage[0] != '\0' ? [NSString stringWithUTF8String:inspectMessage] : @"Failed to inspect source model.";
        }
        return NSAlertSecondButtonReturn;
    }

    float suggestedScale = info.recommendedScale > 0.0f ? info.recommendedScale : 1.0f;
    defaultAssetName = sledgehammer_default_model_asset_name_for_url(url);
    NSAlert* alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = [NSString stringWithFormat:@"Import %@", url.lastPathComponent ?: @"Model"];
    alert.informativeText = @"Editor world units use centimetres. Review the detected source units, bounds, and import scale before compiling the model asset.";
    [alert addButtonWithTitle:@"Import"];
    [alert addButtonWithTitle:@"Skip"];
    [alert addButtonWithTitle:@"Cancel"];

    NSStackView* stack = [[NSStackView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 360.0, 220.0)];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.distribution = NSStackViewDistributionFill;
    stack.spacing = 8.0;

    NSTextField* summaryLabel = [NSTextField wrappingLabelWithString:[NSString stringWithFormat:@"Detected units: %@\nSource bounds: %@\nImported bounds at suggested scale: %@ cm",
        sledgehammer_model_import_unit_label(info.detectedUnit, info.unitHintSource),
        sledgehammer_model_import_size_string(info.boundsMin, info.boundsMax, 1.0f),
        sledgehammer_model_import_size_string(info.boundsMin, info.boundsMax, suggestedScale)]];
    summaryLabel.preferredMaxLayoutWidth = 360.0;

    NSTextField* scaleLabel = [NSTextField labelWithString:@"Scale Factor"];
    NSTextField* scaleField = [[NSTextField alloc] initWithFrame:NSMakeRect(0.0, 0.0, 120.0, 24.0)];
    scaleField.stringValue = [NSString stringWithFormat:@"%.4f", suggestedScale];
    scaleField.placeholderString = @"1.0";

    NSTextField* upAxisLabel = [NSTextField labelWithString:@"Source Up Axis"];
    NSPopUpButton* upAxisPopUp = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0.0, 0.0, 220.0, 24.0) pullsDown:NO];
    [upAxisPopUp addItemsWithTitles:@[@"Auto Detect", @"X Up", @"Y Up", @"Z Up"]];
    [[upAxisPopUp itemAtIndex:0] setTag:NOVA_MODEL_IMPORT_UP_AXIS_AUTO];
    [[upAxisPopUp itemAtIndex:1] setTag:NOVA_MODEL_IMPORT_UP_AXIS_X];
    [[upAxisPopUp itemAtIndex:2] setTag:NOVA_MODEL_IMPORT_UP_AXIS_Y];
    [[upAxisPopUp itemAtIndex:3] setTag:NOVA_MODEL_IMPORT_UP_AXIS_Z];
    [upAxisPopUp selectItemAtIndex:0];

    NSTextField* nameLabel = [NSTextField labelWithString:@"Asset Name"];
    NSTextField* nameField = [[NSTextField alloc] initWithFrame:NSMakeRect(0.0, 0.0, 220.0, 24.0)];
    nameField.stringValue = defaultAssetName ?: @"model";
    nameField.placeholderString = @"model";

    NSTextField* hintLabel = [NSTextField wrappingLabelWithString:[NSString stringWithFormat:@"Suggested because source metres per unit = %.6g and editor units are centimetres.",
        info.sourceMetersPerUnit > 0.0f ? info.sourceMetersPerUnit : 0.0f]];
    hintLabel.textColor = NSColor.secondaryLabelColor;
    hintLabel.preferredMaxLayoutWidth = 360.0;

    [stack addArrangedSubview:summaryLabel];
    [stack addArrangedSubview:nameLabel];
    [stack addArrangedSubview:nameField];
    [stack addArrangedSubview:scaleLabel];
    [stack addArrangedSubview:scaleField];
    [stack addArrangedSubview:upAxisLabel];
    [stack addArrangedSubview:upAxisPopUp];
    [stack addArrangedSubview:hintLabel];
    alert.accessoryView = stack;

    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) {
        NSString* chosenAssetName = sledgehammer_sanitized_model_asset_name(nameField.stringValue);
        float chosenScale = scaleField.floatValue;

        if (chosenAssetName.length == 0) {
            if (outError != NULL) {
                *outError = @"Asset name is empty.";
            }
            return response;
        }
        if (!(chosenScale > 0.0f)) {
            chosenScale = suggestedScale > 0.0f ? suggestedScale : 1.0f;
        }
        if (outAssetName != NULL) {
            *outAssetName = chosenAssetName;
        }
        if (outScale != NULL) {
            *outScale = chosenScale;
        }
        if (outUpAxisMode != NULL) {
            NSInteger selectedIndex = upAxisPopUp.indexOfSelectedItem;
            if (selectedIndex < 0 || selectedIndex >= (NSInteger)upAxisPopUp.numberOfItems) {
                *outUpAxisMode = NOVA_MODEL_IMPORT_UP_AXIS_AUTO;
            } else {
                *outUpAxisMode = (uint32_t)[upAxisPopUp itemAtIndex:selectedIndex].tag;
            }
        }
    }
    return response;
}

@end
#pragma clang diagnostic pop
