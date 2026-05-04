#ifndef SLEDGEHAMMER_RENDERER_BRIDGE_H
#define SLEDGEHAMMER_RENDERER_BRIDGE_H

#import <Foundation/Foundation.h>

#include "math3d.h"
#include "nova_scene_data.h"
#include "nova_tool_metal.h"

Vec3 sledgehammer_renderer_bridge_scene_bounds_center(const NovaSceneData* scene);
void sledgehammer_renderer_bridge_init_imported_material_gpu_defaults(NovaSceneGpuMaterial* material);
NSDictionary<NSString*, id>* sledgehammer_renderer_bridge_texture_dictionary_from_scene_texture(const NovaSceneTexture* texture);
int32_t sledgehammer_renderer_bridge_import_texture_dictionary(NSMutableDictionary<NSString*, NSNumber*>* importedTextureIndices,
                                                              NSMutableArray<NSDictionary<NSString*, id>*>* importedTextures,
                                                              NSString* textureKey,
                                                              NSDictionary<NSString*, id>* textureInfo);

#endif