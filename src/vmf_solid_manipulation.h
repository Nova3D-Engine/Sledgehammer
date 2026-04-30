#ifndef VMF_SOLID_MANIPULATION_H
#define VMF_SOLID_MANIPULATION_H

#include <stddef.h>

#include "math3d.h"
#include "vmf_parser.h"

#ifdef __cplusplus
extern "C" {
#endif

int vmf_scene_translate_solid(VmfScene* scene,
                              size_t entityIndex,
                              size_t solidIndex,
                              Vec3 offset,
                              int textureLock,
                              char* errorBuffer,
                              size_t errorBufferSize);

int vmf_scene_move_solid_vertex(VmfScene* scene,
                                size_t entityIndex,
                                size_t solidIndex,
                                size_t vertexIndex,
                                Vec3 newPosition,
                                char* errorBuffer,
                                size_t errorBufferSize);

typedef struct VmfVertexMove {
    size_t vertexIndex;
    Vec3 newPosition;
} VmfVertexMove;

int vmf_scene_move_solid_vertices(VmfScene* scene,
                                  size_t entityIndex,
                                  size_t solidIndex,
                                  const VmfVertexMove* moves,
                                  size_t moveCount,
                                  char* errorBuffer,
                                  size_t errorBufferSize);

int vmf_scene_check_vertex_moves(const VmfScene* scene,
                                  size_t entityIndex,
                                  size_t solidIndex,
                                  const VmfVertexMove* moves,
                                  size_t moveCount,
                                  char* errorBuffer,
                                  size_t errorBufferSize);

int vmf_scene_move_solid_edge(VmfScene* scene,
                              size_t entityIndex,
                              size_t solidIndex,
                              size_t firstSideIndex,
                              size_t secondSideIndex,
                              Vec3 offset,
                              char* errorBuffer,
                              size_t errorBufferSize);

typedef enum VmfClipKeepMode {
    VmfClipKeepModeBoth = 0,
    VmfClipKeepModeA = 1,
    VmfClipKeepModeB = 2,
} VmfClipKeepMode;

int vmf_scene_split_solid_by_plane(VmfScene* scene,
                                   size_t entityIndex,
                                   size_t solidIndex,
                                   Vec3 planeNormal,
                                   float planeDistance,
                                   VmfClipKeepMode keepMode,
                                   const char* clipMaterial,
                                   size_t* outNewSolidIndex,
                                   char* errorBuffer,
                                   size_t errorBufferSize);

int vmf_scene_set_solid_bounds(VmfScene* scene,
                               size_t entityIndex,
                               size_t solidIndex,
                               Bounds3 bounds,
                               char* errorBuffer,
                               size_t errorBufferSize);

int vmf_scene_set_block_solid_bounds(VmfScene* scene,
                                     size_t entityIndex,
                                     size_t solidIndex,
                                     Bounds3 bounds,
                                     char* errorBuffer,
                                     size_t errorBufferSize);

int vmf_scene_delete_solid(VmfScene* scene,
                           size_t entityIndex,
                           size_t solidIndex,
                           char* errorBuffer,
                           size_t errorBufferSize);

int vmf_scene_duplicate_solid(VmfScene* scene,
                              size_t entityIndex,
                              size_t solidIndex,
                              Vec3 offset,
                              size_t* outEntityIndex,
                              size_t* outSolidIndex,
                              char* errorBuffer,
                              size_t errorBufferSize);

#ifdef __cplusplus
}
#endif

#endif // VMF_SOLID_MANIPULATION_H