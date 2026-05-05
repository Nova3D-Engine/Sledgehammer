#import "sledgehammer_viewport_internal.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation VmfViewport (SledgehammerCore)

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

@end
#pragma clang diagnostic pop