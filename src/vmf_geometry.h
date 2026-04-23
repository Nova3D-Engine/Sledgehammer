#ifndef VMF_GEOMETRY_H
#define VMF_GEOMETRY_H

#include <stddef.h>

#include "math3d.h"
#include "vmf_parser.h"

typedef struct ViewerVertex {
    Vec3 position;
    Vec3 normal;
    Vec3 color;
    float u;
    float v;
} ViewerVertex;

typedef struct ViewerFaceRange {
    size_t entityIndex;
    size_t solidIndex;
    size_t sideIndex;
    size_t vertexStart;
    size_t vertexCount;
    char material[128];
} ViewerFaceRange;

typedef struct ViewerMesh {
    ViewerVertex* vertices;
    size_t vertexCount;
    size_t vertexCapacity;
    ViewerVertex* edgeVertices;
    size_t edgeVertexCount;
    size_t edgeVertexCapacity;
    ViewerFaceRange* faceRanges;
    size_t faceRangeCount;
    size_t faceRangeCapacity;
    Bounds3 bounds;
} ViewerMesh;

int vmf_build_mesh(const VmfScene* scene, ViewerMesh* outMesh, char* errorBuffer, size_t errorBufferSize);
void viewer_mesh_free(ViewerMesh* mesh);

#endif
