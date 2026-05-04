#ifndef SLEDGEHAMMER_GEOMETRY_H
#define SLEDGEHAMMER_GEOMETRY_H

#include <stdbool.h>
#include <stddef.h>

#include "vmf_geometry.h"

#ifdef __cplusplus
extern "C" {
#endif

enum {
    SLEDGEHAMMER_BAKE_MAX_FRAGMENTS = 128,
    SLEDGEHAMMER_BAKE_MAX_POLYGON_POINTS = 256,
};

typedef struct SledgehammerBakePolygon {
    Vec3 points[SLEDGEHAMMER_BAKE_MAX_POLYGON_POINTS];
    size_t pointCount;
} SledgehammerBakePolygon;

bool sledgehammer_geometry_face_range_is_bake_excluded(const ViewerFaceRange* range);
void sledgehammer_geometry_bake_compute_uv(Vec3 position, const VmfSide* side, float* outU, float* outV);
bool sledgehammer_geometry_collect_exposed_fragments(const VmfScene* scene,
                                                     size_t entityIndex,
                                                     size_t solidIndex,
                                                     size_t sideIndex,
                                                     SledgehammerBakePolygon* outFragments,
                                                     size_t maxFragments,
                                                     size_t* outFragmentCount,
                                                     Vec3* outFaceNormal);

#ifdef __cplusplus
}
#endif

#endif