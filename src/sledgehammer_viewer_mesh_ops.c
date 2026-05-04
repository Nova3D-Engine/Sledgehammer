#include "sledgehammer_viewer_mesh_ops.h"

#include <math.h>

static void sledgehammer_viewer_mesh_translate_range(ViewerVertex* vertices, size_t start, size_t count, Vec3 delta) {
    if (vertices == NULL || count == 0u) {
        return;
    }
    for (size_t index = start; index < start + count; ++index) {
        vertices[index].position = vec3_add(vertices[index].position, delta);
    }
}

static void sledgehammer_viewer_mesh_recompute_bounds(ViewerMesh* mesh) {
    if (mesh == NULL) {
        return;
    }
    mesh->bounds = bounds3_empty();
    if (mesh->vertices == NULL) {
        return;
    }
    for (size_t index = 0; index < mesh->vertexCount; ++index) {
        bounds3_expand(&mesh->bounds, mesh->vertices[index].position);
    }
}

bool sledgehammer_viewer_mesh_bounds_equal(Bounds3 a, Bounds3 b) {
    const float epsilon = 0.01f;
    for (int axis = 0; axis < 3; ++axis) {
        if (fabsf(a.min.raw[axis] - b.min.raw[axis]) > epsilon || fabsf(a.max.raw[axis] - b.max.raw[axis]) > epsilon) {
            return false;
        }
    }
    return true;
}

void sledgehammer_viewer_mesh_translate_entity(ViewerMesh* mesh, size_t entityIndex, Vec3 delta) {
    if (mesh == NULL || mesh->faceRanges == NULL || mesh->vertices == NULL) {
        return;
    }

    for (size_t rangeIndex = 0; rangeIndex < mesh->faceRangeCount; ++rangeIndex) {
        const ViewerFaceRange* range = &mesh->faceRanges[rangeIndex];
        if (range->entityIndex != entityIndex) {
            continue;
        }

        if (range->vertexStart < mesh->vertexCount) {
            size_t vertexCount = range->vertexCount;
            if (range->vertexStart + vertexCount > mesh->vertexCount) {
                vertexCount = mesh->vertexCount - range->vertexStart;
            }
            sledgehammer_viewer_mesh_translate_range(mesh->vertices, range->vertexStart, vertexCount, delta);
        }

        if (mesh->edgeVertices != NULL && range->edgeVertexStart < mesh->edgeVertexCount) {
            size_t edgeVertexCount = range->edgeVertexCount;
            if (range->edgeVertexStart + edgeVertexCount > mesh->edgeVertexCount) {
                edgeVertexCount = mesh->edgeVertexCount - range->edgeVertexStart;
            }
            sledgehammer_viewer_mesh_translate_range(mesh->edgeVertices, range->edgeVertexStart, edgeVertexCount, delta);
        }
    }

    sledgehammer_viewer_mesh_recompute_bounds(mesh);
}

void sledgehammer_viewer_mesh_translate_solid(ViewerMesh* mesh, size_t entityIndex, size_t solidIndex, Vec3 delta) {
    if (mesh == NULL || mesh->faceRanges == NULL || mesh->vertices == NULL) {
        return;
    }

    for (size_t rangeIndex = 0; rangeIndex < mesh->faceRangeCount; ++rangeIndex) {
        const ViewerFaceRange* range = &mesh->faceRanges[rangeIndex];
        if (range->entityIndex != entityIndex || range->solidIndex != solidIndex) {
            continue;
        }

        if (range->vertexStart < mesh->vertexCount) {
            size_t vertexCount = range->vertexCount;
            if (range->vertexStart + vertexCount > mesh->vertexCount) {
                vertexCount = mesh->vertexCount - range->vertexStart;
            }
            sledgehammer_viewer_mesh_translate_range(mesh->vertices, range->vertexStart, vertexCount, delta);
        }

        if (mesh->edgeVertices != NULL && range->edgeVertexStart < mesh->edgeVertexCount) {
            size_t edgeVertexCount = range->edgeVertexCount;
            if (range->edgeVertexStart + edgeVertexCount > mesh->edgeVertexCount) {
                edgeVertexCount = mesh->edgeVertexCount - range->edgeVertexStart;
            }
            sledgehammer_viewer_mesh_translate_range(mesh->edgeVertices, range->edgeVertexStart, edgeVertexCount, delta);
        }
    }

    sledgehammer_viewer_mesh_recompute_bounds(mesh);
}