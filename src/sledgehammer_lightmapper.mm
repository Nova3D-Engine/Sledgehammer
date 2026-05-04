#import "sledgehammer_viewport_internal.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation VmfViewport (SledgehammerLightmapper)

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

- (void)setLightmapDebugWindowVisible:(BOOL)visible {
    self.previewBakeDebugWindowOpen = visible;
    if (!visible) {
        [self.previewBakePanel orderOut:nil];
        return;
    }

    [self buildPreviewBakePanelIfNeeded];
    [self syncPreviewBakePanel];
    if (self.window != nil) {
        [self.window addChildWindow:self.previewBakePanel ordered:NSWindowAbove];
    }
    [self.previewBakePanel makeKeyAndOrderFront:nil];
}

- (BOOL)isLightmapDebugWindowVisible {
    return self.previewBakePanel != nil && self.previewBakePanel.visible;
}

@end
#pragma clang diagnostic pop