#include "vmf_geometry.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct Plane {
    Vec3 normal;
    float distance;
} Plane;

static int reserve_vertices(ViewerMesh* mesh, size_t minimum) {
    if (mesh->vertexCapacity >= minimum) {
        return 1;
    }
    size_t capacity = mesh->vertexCapacity == 0 ? 4096 : mesh->vertexCapacity * 2;
    while (capacity < minimum) {
        capacity *= 2;
    }
    ViewerVertex* vertices = realloc(mesh->vertices, capacity * sizeof(ViewerVertex));
    if (!vertices) {
        return 0;
    }
    mesh->vertices = vertices;
    mesh->vertexCapacity = capacity;
    return 1;
}

static int reserve_edge_vertices(ViewerMesh* mesh, size_t minimum) {
    if (mesh->edgeVertexCapacity >= minimum) {
        return 1;
    }
    size_t capacity = mesh->edgeVertexCapacity == 0 ? 4096 : mesh->edgeVertexCapacity * 2;
    while (capacity < minimum) {
        capacity *= 2;
    }
    ViewerVertex* vertices = realloc(mesh->edgeVertices, capacity * sizeof(ViewerVertex));
    if (!vertices) {
        return 0;
    }
    mesh->edgeVertices = vertices;
    mesh->edgeVertexCapacity = capacity;
    return 1;
}

static int reserve_face_ranges(ViewerMesh* mesh, size_t minimum) {
    if (mesh->faceRangeCapacity >= minimum) {
        return 1;
    }
    size_t capacity = mesh->faceRangeCapacity == 0 ? 256 : mesh->faceRangeCapacity * 2;
    while (capacity < minimum) {
        capacity *= 2;
    }
    ViewerFaceRange* ranges = realloc(mesh->faceRanges, capacity * sizeof(ViewerFaceRange));
    if (!ranges) {
        return 0;
    }
    mesh->faceRanges = ranges;
    mesh->faceRangeCapacity = capacity;
    return 1;
}

static unsigned int hash_string(const char* text) {
    unsigned int hash = 2166136261u;
    while (*text) {
        hash ^= (unsigned char)*text++;
        hash *= 16777619u;
    }
    return hash;
}

static Vec3 color_from_material(const char* material) {
    unsigned int hash = hash_string(material && material[0] ? material : "default");
    float r = 0.35f + ((hash & 0xFFu) / 255.0f) * 0.55f;
    float g = 0.35f + (((hash >> 8) & 0xFFu) / 255.0f) * 0.55f;
    float b = 0.35f + (((hash >> 16) & 0xFFu) / 255.0f) * 0.55f;
    return vec3_make(r, g, b);
}

/* Compute texture UV for a world-space position given a side's texture axes.
   Sledgehammer scale convention: u = (dot(pos, uaxis) + uoffset) / (uscale * 0.5)
   This gives UV in texel space (0..textureWidth = one full repeat).
   The shader then normalises by actual texture dimensions for rendering. */
static void compute_uv(Vec3 position, const VmfSide* side, float* outU, float* outV) {
    if (fabsf(side->uscale) > 1e-5f) {
        *outU = (vec3_dot(position, side->uaxis) + side->uoffset) / (side->uscale * 0.5f);
    } else {
        *outU = vec3_dot(position, side->uaxis) + side->uoffset;
    }
    if (fabsf(side->vscale) > 1e-5f) {
        *outV = (vec3_dot(position, side->vaxis) + side->voffset) / (side->vscale * 0.5f);
    } else {
        *outV = vec3_dot(position, side->vaxis) + side->voffset;
    }
}

static Plane plane_from_side(const VmfSide* side) {
    Vec3 edgeA = vec3_sub(side->points[1], side->points[0]);
    Vec3 edgeB = vec3_sub(side->points[2], side->points[0]);
    Vec3 normal = vec3_normalize(vec3_cross(edgeA, edgeB));
    Plane plane = {
        .normal = normal,
        .distance = vec3_dot(normal, side->points[0]),
    };
    return plane;
}

static Vec3 solid_reference_point(const VmfSolid* solid) {
    Vec3 center = vec3_make(0.0f, 0.0f, 0.0f);
    float sampleCount = 0.0f;
    for (size_t sideIndex = 0; sideIndex < solid->sideCount; ++sideIndex) {
        for (size_t pointIndex = 0; pointIndex < 3; ++pointIndex) {
            center = vec3_add(center, solid->sides[sideIndex].points[pointIndex]);
            sampleCount += 1.0f;
        }
    }
    if (sampleCount <= 0.0f) {
        return center;
    }
    return vec3_scale(center, 1.0f / sampleCount);
}

static Plane orient_plane_toward_interior(Plane plane, Vec3 interiorPoint) {
    float signedDistance = vec3_dot(plane.normal, interiorPoint) - plane.distance;
    if (signedDistance > 0.0f) {
        plane.normal = vec3_scale(plane.normal, -1.0f);
        plane.distance = -plane.distance;
    }
    return plane;
}

static int intersect_planes(Plane a, Plane b, Plane c, Vec3* outPoint) {
    Vec3 bc = vec3_cross(b.normal, c.normal);
    float determinant = vec3_dot(a.normal, bc);
    if (fabsf(determinant) < 1e-5f) {
        return 0;
    }

    Vec3 termA = vec3_scale(bc, a.distance);
    Vec3 termB = vec3_scale(vec3_cross(c.normal, a.normal), b.distance);
    Vec3 termC = vec3_scale(vec3_cross(a.normal, b.normal), c.distance);
    *outPoint = vec3_scale(vec3_add(vec3_add(termA, termB), termC), 1.0f / determinant);
    return 1;
}

static int point_in_brush(const Plane* planes, size_t planeCount, Vec3 point) {
    for (size_t i = 0; i < planeCount; ++i) {
        float distance = vec3_dot(planes[i].normal, point) - planes[i].distance;
        if (distance > 0.05f) {
            return 0;
        }
    }
    return 1;
}

static int point_equals(Vec3 a, Vec3 b) {
    Vec3 delta = vec3_sub(a, b);
    return vec3_length(delta) < 0.05f;
}

static int append_unique(Vec3* points, size_t* pointCount, Vec3 point) {
    for (size_t i = 0; i < *pointCount; ++i) {
        if (point_equals(points[i], point)) {
            return 1;
        }
    }
    points[*pointCount] = point;
    *pointCount += 1;
    return 1;
}

static void sort_polygon(Vec3* points, size_t pointCount, Vec3 normal) {
    if (pointCount < 3) {
        return;
    }

    Vec3 center = vec3_make(0.0f, 0.0f, 0.0f);
    for (size_t i = 0; i < pointCount; ++i) {
        center = vec3_add(center, points[i]);
    }
    center = vec3_scale(center, 1.0f / (float)pointCount);

    Vec3 tangent = fabsf(normal.raw[2]) < 0.99f ? vec3_make(0.0f, 0.0f, 1.0f) : vec3_make(0.0f, 1.0f, 0.0f);
    Vec3 axisX = vec3_normalize(vec3_cross(tangent, normal));
    Vec3 axisY = vec3_cross(normal, axisX);

    for (size_t i = 0; i < pointCount; ++i) {
        for (size_t j = i + 1; j < pointCount; ++j) {
            Vec3 ai = vec3_sub(points[i], center);
            Vec3 aj = vec3_sub(points[j], center);
            float angleI = atan2f(vec3_dot(ai, axisY), vec3_dot(ai, axisX));
            float angleJ = atan2f(vec3_dot(aj, axisY), vec3_dot(aj, axisX));
            if (angleJ < angleI) {
                Vec3 tmp = points[i];
                points[i] = points[j];
                points[j] = tmp;
            }
        }
    }
}

static int append_triangle(ViewerMesh* mesh, ViewerVertex a, ViewerVertex b, ViewerVertex c) {
    if (!reserve_vertices(mesh, mesh->vertexCount + 3)) {
        return 0;
    }
    mesh->vertices[mesh->vertexCount++] = a;
    mesh->vertices[mesh->vertexCount++] = b;
    mesh->vertices[mesh->vertexCount++] = c;
    bounds3_expand(&mesh->bounds, a.position);
    bounds3_expand(&mesh->bounds, b.position);
    bounds3_expand(&mesh->bounds, c.position);
    return 1;
}

static int append_line(ViewerMesh* mesh, ViewerVertex a, ViewerVertex b) {
    if (!reserve_edge_vertices(mesh, mesh->edgeVertexCount + 2)) {
        return 0;
    }
    mesh->edgeVertices[mesh->edgeVertexCount++] = a;
    mesh->edgeVertices[mesh->edgeVertexCount++] = b;
    return 1;
}

static int append_polygon_edges(ViewerMesh* mesh, const Vec3* polygon, size_t polygonCount, Vec3 normal, Vec3 color) {
    if (polygonCount < 2) {
        return 1;
    }

    for (size_t edgeIndex = 0; edgeIndex < polygonCount; ++edgeIndex) {
        size_t nextIndex = (edgeIndex + 1) % polygonCount;
        ViewerVertex a = { .position = polygon[edgeIndex], .normal = normal, .color = color };
        ViewerVertex b = { .position = polygon[nextIndex], .normal = normal, .color = color };
        if (!append_line(mesh, a, b)) {
            return 0;
        }
    }
    return 1;
}

static int append_triangle_edges(ViewerMesh* mesh, ViewerVertex a, ViewerVertex b, ViewerVertex c) {
    return append_line(mesh, a, b) && append_line(mesh, b, c) && append_line(mesh, c, a);
}

static int displacement_start_corner(const Vec3* quad, Vec3 startPosition) {
    int bestIndex = 0;
    float bestDistance = FLT_MAX;
    for (int i = 0; i < 4; ++i) {
        float distance = vec3_length(vec3_sub(quad[i], startPosition));
        if (distance < bestDistance) {
            bestDistance = distance;
            bestIndex = i;
        }
    }
    return bestIndex;
}

static int triangulate_displacement(const VmfSide* side,
                                   const Vec3* polygon,
                                   size_t polygonCount,
                                   Vec3 faceNormal,
                                   ViewerMesh* mesh,
                                   size_t entityIndex,
                                   size_t solidIndex,
                                   size_t sideIndex) {
    if (!side->dispinfo.hasData || polygonCount != 4 || side->dispinfo.resolution <= 1) {
        return 0;
    }

    Vec3 quad[4];
    int startIndex = displacement_start_corner(polygon, side->dispinfo.startPosition);
    for (int i = 0; i < 4; ++i) {
        quad[i] = polygon[(startIndex + i) % 4];
    }

    int resolution = side->dispinfo.resolution;
    Vec3 color = color_from_material(side->material);

    if (!append_polygon_edges(mesh, polygon, polygonCount, faceNormal, color)) {
        return 0;
    }

    size_t vertexStart = mesh->vertexCount;
    for (int y = 0; y < resolution - 1; ++y) {
        for (int x = 0; x < resolution - 1; ++x) {
            ViewerVertex cell[4];
            int indices[4][2] = {
                { x, y },
                { x + 1, y },
                { x + 1, y + 1 },
                { x, y + 1 },
            };

            for (int i = 0; i < 4; ++i) {
                int gridX = indices[i][0];
                int gridY = indices[i][1];
                float u = (float)gridX / (float)(resolution - 1);
                float v = (float)gridY / (float)(resolution - 1);
                Vec3 top = vec3_lerp(quad[0], quad[1], u);
                Vec3 bottom = vec3_lerp(quad[3], quad[2], u);
                Vec3 basePosition = vec3_lerp(top, bottom, v);
                int sampleIndex = gridY * resolution + gridX;
                Vec3 dispNormal = side->dispinfo.normals[sampleIndex];
                if (vec3_length(dispNormal) < 1e-5f) {
                    dispNormal = faceNormal;
                } else {
                    dispNormal = vec3_normalize(dispNormal);
                }
                Vec3 position = basePosition;
                position = vec3_add(position, vec3_scale(faceNormal, side->dispinfo.elevation));
                position = vec3_add(position, vec3_scale(dispNormal, side->dispinfo.distances[sampleIndex]));
                position = vec3_add(position, side->dispinfo.offsets[sampleIndex]);

                cell[i] = (ViewerVertex) {
                    .position = position,
                    .normal = dispNormal,
                    .color = color,
                };
            }

            if (!append_triangle(mesh, cell[0], cell[1], cell[2]) ||
                !append_triangle(mesh, cell[0], cell[2], cell[3]) ||
                !append_triangle_edges(mesh, cell[0], cell[1], cell[2]) ||
                !append_triangle_edges(mesh, cell[0], cell[2], cell[3])) {
                return 0;
            }
        }
    }

    if (mesh->vertexCount > vertexStart) {
        if (!reserve_face_ranges(mesh, mesh->faceRangeCount + 1)) {
            return 0;
        }
        ViewerFaceRange dispRange = {
            .entityIndex = entityIndex,
            .solidIndex = solidIndex,
            .sideIndex = sideIndex,
            .vertexStart = vertexStart,
            .vertexCount = mesh->vertexCount - vertexStart,
        };
        snprintf(dispRange.material, sizeof(dispRange.material), "%s", side->material);
        mesh->faceRanges[mesh->faceRangeCount++] = dispRange;
    }

    return 1;
}

static int triangulate_solid(const VmfSolid* solid, ViewerMesh* mesh, size_t entityIndex, size_t solidIndex) {
    if (solid->sideCount < 4) {
        return 1;
    }

    Plane planes[128];
    Vec3 interiorPoint = solid_reference_point(solid);
    if (solid->sideCount > sizeof(planes) / sizeof(planes[0])) {
        return 0;
    }
    for (size_t i = 0; i < solid->sideCount; ++i) {
        planes[i] = orient_plane_toward_interior(plane_from_side(&solid->sides[i]), interiorPoint);
    }

    for (size_t sideIndex = 0; sideIndex < solid->sideCount; ++sideIndex) {
        Vec3 polygon[256];
        size_t polygonCount = 0;

        for (size_t j = 0; j < solid->sideCount; ++j) {
            if (j == sideIndex) {
                continue;
            }
            for (size_t k = j + 1; k < solid->sideCount; ++k) {
                if (k == sideIndex) {
                    continue;
                }
                Vec3 point;
                if (!intersect_planes(planes[sideIndex], planes[j], planes[k], &point)) {
                    continue;
                }
                if (!point_in_brush(planes, solid->sideCount, point)) {
                    continue;
                }
                if (polygonCount < sizeof(polygon) / sizeof(polygon[0])) {
                    append_unique(polygon, &polygonCount, point);
                }
            }
        }

        if (polygonCount < 3) {
            continue;
        }

        sort_polygon(polygon, polygonCount, planes[sideIndex].normal);
        if (solid->sides[sideIndex].dispinfo.hasData) {
            if (!triangulate_displacement(&solid->sides[sideIndex], polygon, polygonCount, planes[sideIndex].normal, mesh, entityIndex, solidIndex, sideIndex)) {
                return 0;
            }
            continue;
        }

        Vec3 color = color_from_material(solid->sides[sideIndex].material);
        size_t vertexStart = mesh->vertexCount;
        if (!append_polygon_edges(mesh, polygon, polygonCount, planes[sideIndex].normal, color)) {
            return 0;
        }
        const VmfSide* side = &solid->sides[sideIndex];
        for (size_t vertexIndex = 1; vertexIndex + 1 < polygonCount; ++vertexIndex) {
            float u0, v0, u1, v1, u2, v2;
            compute_uv(polygon[0],             side, &u0, &v0);
            compute_uv(polygon[vertexIndex],   side, &u1, &v1);
            compute_uv(polygon[vertexIndex+1], side, &u2, &v2);
            ViewerVertex a = { .position = polygon[0],             .normal = planes[sideIndex].normal, .color = color, .u = u0, .v = v0 };
            ViewerVertex b = { .position = polygon[vertexIndex],   .normal = planes[sideIndex].normal, .color = color, .u = u1, .v = v1 };
            ViewerVertex c = { .position = polygon[vertexIndex+1], .normal = planes[sideIndex].normal, .color = color, .u = u2, .v = v2 };
            if (!append_triangle(mesh, a, b, c)) {
                return 0;
            }
        }
        if (mesh->vertexCount > vertexStart) {
            if (!reserve_face_ranges(mesh, mesh->faceRangeCount + 1)) {
                return 0;
            }
            ViewerFaceRange solidRange = {
                .entityIndex = entityIndex,
                .solidIndex = solidIndex,
                .sideIndex = sideIndex,
                .vertexStart = vertexStart,
                .vertexCount = mesh->vertexCount - vertexStart,
            };
            snprintf(solidRange.material, sizeof(solidRange.material), "%s",
                     solid->sides[sideIndex].material);
            mesh->faceRanges[mesh->faceRangeCount++] = solidRange;
        }
    }

    return 1;
}

static int append_light_marker(ViewerMesh* mesh, const VmfEntity* entity, size_t entityIndex) {
    float radius = fmaxf(entity->range * 0.0625f, 16.0f);
    Vec3 center = entity->position;
    Vec3 color = entity->enabled ? entity->color : vec3_make(0.45f, 0.45f, 0.45f);
    Vec3 top = vec3_add(center, vec3_make(0.0f, 0.0f, radius));
    Vec3 bottom = vec3_add(center, vec3_make(0.0f, 0.0f, -radius));
    Vec3 east = vec3_add(center, vec3_make(radius, 0.0f, 0.0f));
    Vec3 west = vec3_add(center, vec3_make(-radius, 0.0f, 0.0f));
    Vec3 north = vec3_add(center, vec3_make(0.0f, radius, 0.0f));
    Vec3 south = vec3_add(center, vec3_make(0.0f, -radius, 0.0f));
    size_t vertexStart = mesh->vertexCount;

    ViewerVertex vTop = { .position = top, .normal = vec3_make(0.0f, 0.0f, 1.0f), .color = color };
    ViewerVertex vBottom = { .position = bottom, .normal = vec3_make(0.0f, 0.0f, -1.0f), .color = color };
    ViewerVertex vEast = { .position = east, .normal = vec3_make(1.0f, 0.0f, 0.0f), .color = color };
    ViewerVertex vWest = { .position = west, .normal = vec3_make(-1.0f, 0.0f, 0.0f), .color = color };
    ViewerVertex vNorth = { .position = north, .normal = vec3_make(0.0f, 1.0f, 0.0f), .color = color };
    ViewerVertex vSouth = { .position = south, .normal = vec3_make(0.0f, -1.0f, 0.0f), .color = color };

    if (!append_triangle(mesh, vTop, vEast, vNorth) ||
        !append_triangle(mesh, vTop, vNorth, vWest) ||
        !append_triangle(mesh, vTop, vWest, vSouth) ||
        !append_triangle(mesh, vTop, vSouth, vEast) ||
        !append_triangle(mesh, vBottom, vNorth, vEast) ||
        !append_triangle(mesh, vBottom, vWest, vNorth) ||
        !append_triangle(mesh, vBottom, vSouth, vWest) ||
        !append_triangle(mesh, vBottom, vEast, vSouth)) {
        return 0;
    }

    if (!append_line(mesh, vTop, vBottom) ||
        !append_line(mesh, vEast, vWest) ||
        !append_line(mesh, vNorth, vSouth)) {
        return 0;
    }

    if (!reserve_face_ranges(mesh, mesh->faceRangeCount + 1)) {
        return 0;
    }

    ViewerFaceRange lightRange = {
        .entityIndex = entityIndex,
        .solidIndex = 0,
        .sideIndex = 0,
        .vertexStart = vertexStart,
        .vertexCount = mesh->vertexCount - vertexStart,
    };
    snprintf(lightRange.material, sizeof(lightRange.material), "%s", "light_marker");
    mesh->faceRanges[mesh->faceRangeCount++] = lightRange;
    return 1;
}

int vmf_build_mesh(const VmfScene* scene, ViewerMesh* outMesh, char* errorBuffer, size_t errorBufferSize) {
    memset(outMesh, 0, sizeof(*outMesh));
    outMesh->bounds = bounds3_empty();

    for (size_t entityIndex = 0; entityIndex < scene->entityCount; ++entityIndex) {
        const VmfEntity* entity = &scene->entities[entityIndex];
        if (entity->kind == VmfEntityKindLight) {
            if (!append_light_marker(outMesh, entity, entityIndex)) {
                viewer_mesh_free(outMesh);
                snprintf(errorBuffer, errorBufferSize, "failed to build light entity geometry");
                return 0;
            }
            continue;
        }
        for (size_t solidIndex = 0; solidIndex < entity->solidCount; ++solidIndex) {
            if (!triangulate_solid(&entity->solids[solidIndex], outMesh, entityIndex, solidIndex)) {
                viewer_mesh_free(outMesh);
                snprintf(errorBuffer, errorBufferSize, "failed to triangulate brush geometry");
                return 0;
            }
        }
    }

    return 1;
}

void viewer_mesh_free(ViewerMesh* mesh) {
    if (!mesh) {
        return;
    }
    free(mesh->vertices);
    free(mesh->edgeVertices);
    free(mesh->faceRanges);
    memset(mesh, 0, sizeof(*mesh));
}
