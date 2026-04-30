#ifndef VMF_TEXTURE_OPERATIONS_H
#define VMF_TEXTURE_OPERATIONS_H

#include <stddef.h>

#include "math3d.h"
#include "vmf_parser.h"

#ifdef __cplusplus
extern "C" {
#endif

int vmf_scene_set_solid_material(VmfScene* scene,
                                 size_t entityIndex,
                                 size_t solidIndex,
                                 const char* material,
                                 char* errorBuffer,
                                 size_t errorBufferSize);

int vmf_scene_set_side_material(VmfScene* scene,
                                size_t entityIndex,
                                size_t solidIndex,
                                size_t sideIndex,
                                const char* material,
                                char* errorBuffer,
                                size_t errorBufferSize);

int vmf_scene_set_side_texture_transform(VmfScene* scene,
                                                      size_t entityIndex,
                                                      size_t solidIndex,
                                                      size_t sideIndex,
                                                      float uoffset,
                                                      float voffset,
                                                      float uscale,
                                                      float vscale,
                                                      char* errorBuffer,
                                                      size_t errorBufferSize);

int vmf_scene_rotate_side_texture(VmfScene* scene,
                                             size_t entityIndex,
                                             size_t solidIndex,
                                             size_t sideIndex,
                                             float degrees,
                                             char* errorBuffer,
                                             size_t errorBufferSize);

int vmf_scene_flip_side_texture(VmfScene* scene,
                                          size_t entityIndex,
                                          size_t solidIndex,
                                          size_t sideIndex,
                                          int flipU,
                                          int flipV,
                                          char* errorBuffer,
                                          size_t errorBufferSize);

typedef enum VmfTextureJustifyMode {
    VmfTextureJustifyFit = 0,
    VmfTextureJustifyLeft = 1,
    VmfTextureJustifyRight = 2,
    VmfTextureJustifyTop = 3,
    VmfTextureJustifyBottom = 4,
    VmfTextureJustifyCenter = 5,
} VmfTextureJustifyMode;

int vmf_scene_justify_side_texture(VmfScene* scene,
                                              size_t entityIndex,
                                              size_t solidIndex,
                                              size_t sideIndex,
                                              VmfTextureJustifyMode mode,
                                              float textureWidth,
                                              float textureHeight,
                                              char* errorBuffer,
                                              size_t errorBufferSize);

int vmf_scene_world_align_side(VmfScene* scene,
                               size_t entityIndex,
                               size_t solidIndex,
                               size_t sideIndex,
                               char* errorBuffer,
                               size_t errorBufferSize);

int vmf_scene_wrap_align_solid_from_side(VmfScene* scene,
                                         size_t entityIndex,
                                         size_t solidIndex,
                                         size_t sideIndex,
                                         char* errorBuffer,
                                         size_t errorBufferSize);

#ifdef __cplusplus
}
#endif

#endif // VMF_TEXTURE_OPERATIONS_H