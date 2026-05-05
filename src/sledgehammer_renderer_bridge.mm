#import "sledgehammer_renderer_bridge.h"

#include <string.h>

Vec3 sledgehammer_renderer_bridge_scene_bounds_center(const NovaSceneData* scene) {
    Bounds3 bounds = bounds3_empty();
    if (scene == NULL) {
        return vec3_make(0.0f, 0.0f, 0.0f);
    }
    for (uint32_t vertexIndex = 0u; vertexIndex < scene->vertexCount; ++vertexIndex) {
        const NovaSceneVertex* vertex = &scene->vertices[vertexIndex];
        bounds3_expand(&bounds, vec3_make(vertex->position[0], vertex->position[1], vertex->position[2]));
    }
    return bounds3_is_valid(bounds) ? bounds3_center(bounds) : vec3_make(0.0f, 0.0f, 0.0f);
}

void sledgehammer_renderer_bridge_init_imported_material_gpu_defaults(NovaSceneGpuMaterial* material) {
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

NSDictionary<NSString*, id>* sledgehammer_renderer_bridge_texture_dictionary_from_scene_texture(const NovaSceneTexture* texture) {
    NSMutableDictionary<NSString*, id>* textureInfo;
    size_t pixelCount;

    if (texture == NULL || texture->width <= 0 || texture->height <= 0) {
        return nil;
    }

    textureInfo = [NSMutableDictionary dictionaryWithCapacity:4];
    textureInfo[@"width"] = @(texture->width);
    textureInfo[@"height"] = @(texture->height);
    textureInfo[@"format"] = @(texture->format);
    pixelCount = (size_t)texture->width * (size_t)texture->height;
    if (texture->format == NOVA_SCENE_TEXTURE_FORMAT_RGBA32_FLOAT && texture->rgba32f != NULL) {
        textureInfo[@"rgba32f"] = [NSData dataWithBytes:texture->rgba32f length:pixelCount * sizeof(float) * 4u];
        return textureInfo;
    }
    if (texture->rgba8 != NULL) {
        textureInfo[@"format"] = @(NOVA_SCENE_TEXTURE_FORMAT_RGBA8_UNORM);
        textureInfo[@"rgba8"] = [NSData dataWithBytes:texture->rgba8 length:pixelCount * 4u];
        return textureInfo;
    }
    return nil;
}

int32_t sledgehammer_renderer_bridge_import_texture_dictionary(NSMutableDictionary<NSString*, NSNumber*>* importedTextureIndices,
                                                               NSMutableArray<NSDictionary<NSString*, id>*>* importedTextures,
                                                               NSString* textureKey,
                                                               NSDictionary<NSString*, id>* textureInfo) {
    NSNumber* existingTextureIndex;

    if (importedTextureIndices == nil || importedTextures == nil || textureKey.length == 0 || textureInfo == nil) {
        return -1;
    }

    existingTextureIndex = importedTextureIndices[textureKey];
    if (existingTextureIndex != nil) {
        return existingTextureIndex.intValue;
    }
    if (importedTextures.count >= UI_MAX_LIGHTS) {
        return -1;
    }

    existingTextureIndex = @(importedTextures.count);
    importedTextureIndices[textureKey] = existingTextureIndex;
    [importedTextures addObject:textureInfo];
    return existingTextureIndex.intValue;
}