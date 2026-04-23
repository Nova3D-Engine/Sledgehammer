#ifndef VMF_EDITOR_H
#define VMF_EDITOR_H

#include <stddef.h>

#include "math3d.h"
#include "vmf_parser.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum VmfBrushAxis {
    VmfBrushAxisX = 0,
    VmfBrushAxisY = 1,
    VmfBrushAxisZ = 2,
} VmfBrushAxis;

typedef enum VmfTextureJustifyMode {
    VmfTextureJustifyFit = 0,
    VmfTextureJustifyLeft = 1,
    VmfTextureJustifyRight = 2,
    VmfTextureJustifyTop = 3,
    VmfTextureJustifyBottom = 4,
    VmfTextureJustifyCenter = 5,
} VmfTextureJustifyMode;

#define VMF_MAX_SOLID_VERTICES 256
#define VMF_MAX_SOLID_EDGES 512
#define VMF_MAX_VERTEX_PLANES 8

typedef struct VmfSolidVertex {
    Vec3 position;
    size_t sideIndices[VMF_MAX_VERTEX_PLANES];
    size_t sideIndexCount;
} VmfSolidVertex;

typedef struct VmfSolidEdge {
    Vec3 start;
    Vec3 end;
    size_t sideIndices[2];
    size_t endpointCount;
} VmfSolidEdge;

int vmf_scene_init_empty(VmfScene* outScene, char* errorBuffer, size_t errorBufferSize);
int vmf_scene_clone(const VmfScene* source, VmfScene* outScene, char* errorBuffer, size_t errorBufferSize);
int vmf_scene_save(const char* path, const VmfScene* scene, char* errorBuffer, size_t errorBufferSize);
int vmf_scene_add_light_entity(VmfScene* scene,
                               const char* name,
                               Vec3 position,
                               Vec3 color,
                               float intensity,
                               float range,
                               int castShadows,
                               size_t* outEntityIndex,
                               char* errorBuffer,
                               size_t errorBufferSize);
int vmf_scene_add_brush_entity(VmfScene* scene,
                               const char* name,
                               const char* classname,
                               size_t* outEntityIndex,
                               char* errorBuffer,
                               size_t errorBufferSize);
int vmf_scene_add_block_brush(VmfScene* scene,
                              Bounds3 bounds,
                              const char* material,
                              size_t* outEntityIndex,
                              size_t* outSolidIndex,
                              char* errorBuffer,
                              size_t errorBufferSize);
int vmf_scene_add_cylinder_brush(VmfScene* scene,
                                 Bounds3 bounds,
                                 VmfBrushAxis axis,
                                 size_t segmentCount,
                                 const char* material,
                                 size_t* outEntityIndex,
                                 size_t* outSolidIndex,
                                 char* errorBuffer,
                                 size_t errorBufferSize);
int vmf_scene_add_ramp_brush(VmfScene* scene,
                             Bounds3 bounds,
                             VmfBrushAxis axis,
                             VmfBrushAxis slopeAxis,
                             const char* material,
                             size_t* outEntityIndex,
                             size_t* outSolidIndex,
                             char* errorBuffer,
                             size_t errorBufferSize);
int vmf_scene_add_arch_brushes(VmfScene* scene,
                               Bounds3 bounds,
                               VmfBrushAxis axis,
                               VmfBrushAxis runAxis,
                               size_t segmentCount,
                               float thicknessRatio,
                               const char* material,
                               size_t* outEntityIndex,
                               size_t* outSolidIndex,
                               char* errorBuffer,
                               size_t errorBufferSize);
int vmf_scene_delete_entity(VmfScene* scene,
                            size_t entityIndex,
                            char* errorBuffer,
                            size_t errorBufferSize);
int vmf_scene_move_solid_to_entity(VmfScene* scene,
                                   size_t sourceEntityIndex,
                                   size_t sourceSolidIndex,
                                   size_t targetEntityIndex,
                                   size_t* outTargetSolidIndex,
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
int vmf_scene_solid_bounds(const VmfScene* scene,
                           size_t entityIndex,
                           size_t solidIndex,
                           Bounds3* outBounds,
                           char* errorBuffer,
                           size_t errorBufferSize);
int vmf_scene_solid_vertices(const VmfScene* scene,
                             size_t entityIndex,
                             size_t solidIndex,
                             Vec3* outVertices,
                             size_t maxVertices,
                             size_t* outVertexCount,
                             char* errorBuffer,
                             size_t errorBufferSize);
int vmf_scene_solid_vertex_refs(const VmfScene* scene,
                                size_t entityIndex,
                                size_t solidIndex,
                                VmfSolidVertex* outVertices,
                                size_t maxVertices,
                                size_t* outVertexCount,
                                char* errorBuffer,
                                size_t errorBufferSize);
int vmf_scene_solid_edges(const VmfScene* scene,
                          size_t entityIndex,
                          size_t solidIndex,
                          VmfSolidEdge* outEdges,
                          size_t maxEdges,
                          size_t* outEdgeCount,
                          char* errorBuffer,
                          size_t errorBufferSize);
int vmf_scene_entity_bounds(const VmfScene* scene,
                            size_t entityIndex,
                            Bounds3* outBounds,
                            char* errorBuffer,
                            size_t errorBufferSize);
int vmf_scene_translate_entity(VmfScene* scene,
                               size_t entityIndex,
                               Vec3 offset,
                               int textureLock,
                               char* errorBuffer,
                               size_t errorBufferSize);
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

/* Check whether vertex moves would produce a valid convex brush WITHOUT
   modifying the scene.  Returns 1 if valid, 0 if not. */
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
int vmf_scene_justify_side_texture(VmfScene* scene,
                                              size_t entityIndex,
                                              size_t solidIndex,
                                              size_t sideIndex,
                                              VmfTextureJustifyMode mode,
                                              float textureWidth,
                                              float textureHeight,
                                              char* errorBuffer,
                                              size_t errorBufferSize);
/* Recompute the UV axes for a single face using world-axis alignment:
   pick the two world axes most perpendicular to the face normal as uaxis/vaxis,
   reset uoffset/voffset to 0 so the texture is anchored to the world origin.
   This gives seamless (contiguous) texturing across adjacent coplanar and
   perpendicular faces that share the same world-aligned UV direction. */
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
int vmf_scene_pick_ray(const VmfScene* scene,
                       Vec3 origin,
                       Vec3 direction,
                       size_t* outEntityIndex,
                       size_t* outSolidIndex,
                       size_t* outSideIndex,
                       Vec3* outHitPoint,
                       char* errorBuffer,
                       size_t errorBufferSize);

#ifdef __cplusplus
}
#endif

#endif
