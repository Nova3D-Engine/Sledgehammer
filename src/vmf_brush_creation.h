#ifndef VMF_BRUSH_CREATION_H
#define VMF_BRUSH_CREATION_H

#include <stddef.h>

#include "math3d.h"
#include "vmf_parser.h"
#include "vmf_editor.h"

#ifdef __cplusplus
extern "C" {
#endif

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

#ifdef __cplusplus
}
#endif

#endif // VMF_BRUSH_CREATION_H