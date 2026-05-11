#include "vmf_geometry.h"

#include "novamodel_asset.h"
#include "nova_scene_data.h"
#include "sledgehammer_geometry.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct Plane {
    Vec3 normal;
    float distance;
} Plane;

static Vec3 transform_point_matrix(const float matrix[16], Vec3 point) {
    Vec3 result;
    result.raw[0] = matrix[0] * point.raw[0] + matrix[4] * point.raw[1] + matrix[8] * point.raw[2] + matrix[12];
    result.raw[1] = matrix[1] * point.raw[0] + matrix[5] * point.raw[1] + matrix[9] * point.raw[2] + matrix[13];
    result.raw[2] = matrix[2] * point.raw[0] + matrix[6] * point.raw[1] + matrix[10] * point.raw[2] + matrix[14];
    return result;
}

static Vec3 transform_direction_matrix(const float matrix[16], Vec3 direction) {
    Vec3 result;
    result.raw[0] = matrix[0] * direction.raw[0] + matrix[4] * direction.raw[1] + matrix[8] * direction.raw[2];
    result.raw[1] = matrix[1] * direction.raw[0] + matrix[5] * direction.raw[1] + matrix[9] * direction.raw[2];
    result.raw[2] = matrix[2] * direction.raw[0] + matrix[6] * direction.raw[1] + matrix[10] * direction.raw[2];
    return result;
}

static float vmf_geometry_degrees_to_radians(float degrees) {
    return degrees * (float)M_PI / 180.0f;
}

static void vmf_geometry_fill_euler_rotation_matrix(Vec3 rotationDegrees, float outMatrix[16]) {
    float rx = vmf_geometry_degrees_to_radians(rotationDegrees.raw[0]);
    float ry = vmf_geometry_degrees_to_radians(rotationDegrees.raw[1]);
    float rz = vmf_geometry_degrees_to_radians(rotationDegrees.raw[2]);
    float cx = cosf(rx), sx = sinf(rx);
    float cy = cosf(ry), sy = sinf(ry);
    float cz = cosf(rz), sz = sinf(rz);
    outMatrix[0] = cy * cz;
    outMatrix[1] = cy * sz;
    outMatrix[2] = -sy;
    outMatrix[3] = 0.0f;
    outMatrix[4] = sx * sy * cz - cx * sz;
    outMatrix[5] = sx * sy * sz + cx * cz;
    outMatrix[6] = sx * cy;
    outMatrix[7] = 0.0f;
    outMatrix[8] = cx * sy * cz + sx * sz;
    outMatrix[9] = cx * sy * sz - sx * cz;
    outMatrix[10] = cx * cy;
    outMatrix[11] = 0.0f;
    outMatrix[12] = 0.0f;
    outMatrix[13] = 0.0f;
    outMatrix[14] = 0.0f;
    outMatrix[15] = 1.0f;
}

static void vmf_geometry_fill_model_world_matrix(const VmfEntity* entity, float outMatrix[16]) {
    vmf_geometry_fill_euler_rotation_matrix(entity != NULL ? entity->rotationDegrees : vec3_make(0.0f, 0.0f, 0.0f), outMatrix);
    if (entity != NULL) {
        outMatrix[12] = entity->position.raw[0];
        outMatrix[13] = entity->position.raw[1];
        outMatrix[14] = entity->position.raw[2];
    }
}

static Bounds3 scene_vertex_bounds(const NovaSceneData* scene) {
    Bounds3 bounds = bounds3_empty();
    if (scene == NULL || scene->vertices == NULL) {
        return bounds;
    }
    for (uint32_t i = 0u; i < scene->vertexCount; ++i) {
        const NovaSceneVertex* vertex = &scene->vertices[i];
        bounds3_expand(&bounds, vec3_make(vertex->position[0], vertex->position[1], vertex->position[2]));
    }
    return bounds;
}

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

static void compute_lightmap_uv(Vec3 origin, Vec3 tangent, Vec3 bitangent, Vec3 position, float* outU, float* outV) {
    Vec3 delta = vec3_sub(position, origin);
    if (outU != NULL) {
        *outU = vec3_dot(delta, tangent);
    }
    if (outV != NULL) {
        *outV = vec3_dot(delta, bitangent);
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

    size_t edgeVertexStart = mesh->edgeVertexCount;

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
                !append_triangle(mesh, cell[0], cell[2], cell[3])) {
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
            .edgeVertexStart = edgeVertexStart,
            .edgeVertexCount = mesh->edgeVertexCount - edgeVertexStart,
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
        size_t edgeVertexStart = mesh->edgeVertexCount;
        if (!append_polygon_edges(mesh, polygon, polygonCount, planes[sideIndex].normal, color)) {
            return 0;
        }
        const VmfSide* side = &solid->sides[sideIndex];
        Vec3 lightmapOrigin = polygon[0];
        Vec3 lightmapTangent;
        Vec3 lightmapBitangent;
        if (!sledgehammer_geometry_bake_compute_lightmap_basis(side,
                                                               planes[sideIndex].normal,
                                                               &lightmapTangent,
                                                               &lightmapBitangent)) {
            lightmapTangent = fabsf(planes[sideIndex].normal.raw[2]) < 0.999f ? vec3_make(0.0f, 0.0f, 1.0f) : vec3_make(1.0f, 0.0f, 0.0f);
            lightmapTangent = vec3_normalize(vec3_cross(lightmapTangent, planes[sideIndex].normal));
            lightmapBitangent = vec3_normalize(vec3_cross(planes[sideIndex].normal, lightmapTangent));
        }
        for (size_t vertexIndex = 1; vertexIndex + 1 < polygonCount; ++vertexIndex) {
            float u0, v0, u1, v1, u2, v2;
            float lu0, lv0, lu1, lv1, lu2, lv2;
            compute_uv(polygon[0],             side, &u0, &v0);
            compute_uv(polygon[vertexIndex],   side, &u1, &v1);
            compute_uv(polygon[vertexIndex+1], side, &u2, &v2);
            compute_lightmap_uv(lightmapOrigin, lightmapTangent, lightmapBitangent, polygon[0], &lu0, &lv0);
            compute_lightmap_uv(lightmapOrigin, lightmapTangent, lightmapBitangent, polygon[vertexIndex], &lu1, &lv1);
            compute_lightmap_uv(lightmapOrigin, lightmapTangent, lightmapBitangent, polygon[vertexIndex+1], &lu2, &lv2);
            ViewerVertex a = { .position = polygon[0],             .normal = planes[sideIndex].normal, .color = color, .u = u0, .v = v0, .lightmapU = lu0, .lightmapV = lv0 };
            ViewerVertex b = { .position = polygon[vertexIndex],   .normal = planes[sideIndex].normal, .color = color, .u = u1, .v = v1, .lightmapU = lu1, .lightmapV = lv1 };
            ViewerVertex c = { .position = polygon[vertexIndex+1], .normal = planes[sideIndex].normal, .color = color, .u = u2, .v = v2, .lightmapU = lu2, .lightmapV = lv2 };
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
                .edgeVertexStart = edgeVertexStart,
                .edgeVertexCount = mesh->edgeVertexCount - edgeVertexStart,
            };
            snprintf(solidRange.material, sizeof(solidRange.material), "%s",
                     solid->sides[sideIndex].material);
            mesh->faceRanges[mesh->faceRangeCount++] = solidRange;
        }
    }

    return 1;
}

static int append_model_marker(ViewerMesh* mesh, const VmfEntity* entity, size_t entityIndex) {
    NovaSceneData scene;
    char errorText[512] = {0};
    size_t vertexStart = mesh->vertexCount;
    size_t edgeVertexStart = mesh->edgeVertexCount;

    if (entity != NULL && entity->modelAssetPath[0] != '\0') {
        nova_scene_data_init(&scene);
        if (nova_model_asset_load_scene(entity->modelAssetPath, &scene, errorText, (uint32_t)sizeof(errorText))) {
            Bounds3 modelBounds = scene_vertex_bounds(&scene);
            Vec3 sceneCenter = bounds3_is_valid(modelBounds) ? bounds3_center(modelBounds) : vec3_make(0.0f, 0.0f, 0.0f);
            Vec3 color = vec3_make(0.30f, 0.78f, 0.98f);
            float worldMatrix[16];
            vmf_geometry_fill_model_world_matrix(entity, worldMatrix);

            if (scene.objectCount > 0u && scene.objects != NULL) {
                for (uint32_t objectIndex = 0u; objectIndex < scene.objectCount; ++objectIndex) {
                    const NovaSceneObject* object = &scene.objects[objectIndex];
                    uint32_t vertexOffset = object->vertexOffset;
                    uint32_t vertexCount = object->vertexCount;
                    if (vertexOffset >= scene.vertexCount) {
                        continue;
                    }
                    if (vertexOffset + vertexCount > scene.vertexCount) {
                        vertexCount = scene.vertexCount - vertexOffset;
                    }
                    vertexCount -= vertexCount % 3u;
                    if (vertexCount < 3u) {
                        continue;
                    }

                    for (uint32_t tri = 0u; tri < vertexCount; tri += 3u) {
                        ViewerVertex triangle[3];
                        for (uint32_t triVertex = 0u; triVertex < 3u; ++triVertex) {
                            const NovaSceneVertex* src = &scene.vertices[vertexOffset + tri + triVertex];
                            Vec3 localPosition = vec3_sub(vec3_make(src->position[0], src->position[1], src->position[2]), sceneCenter);
                            Vec3 worldPosition = transform_point_matrix(worldMatrix, localPosition);
                            Vec3 normal = vec3_make(src->normal[0], src->normal[1], src->normal[2]);
                            normal = transform_direction_matrix(worldMatrix, normal);
                            if (vec3_length(normal) < 1e-5f) {
                                normal = vec3_make(0.0f, 0.0f, 1.0f);
                            } else {
                                normal = vec3_normalize(normal);
                            }

                            triangle[triVertex].position = worldPosition;
                            triangle[triVertex].normal = normal;
                            triangle[triVertex].color = color;
                            triangle[triVertex].u = src->uv[0];
                            triangle[triVertex].v = src->uv[1];
                            triangle[triVertex].lightmapU = src->lightmapUv[0];
                            triangle[triVertex].lightmapV = src->lightmapUv[1];
                        }

                        if (!append_triangle(mesh, triangle[0], triangle[1], triangle[2])) {
                            nova_scene_data_release(&scene);
                            return 0;
                        }
                    }
                }

                if (mesh->vertexCount > vertexStart) {
                    if (!reserve_face_ranges(mesh, mesh->faceRangeCount + 1)) {
                        nova_scene_data_release(&scene);
                        return 0;
                    }

                    ViewerFaceRange modelRange = {
                        .entityIndex = entityIndex,
                        .solidIndex = 0,
                        .sideIndex = 0,
                        .vertexStart = vertexStart,
                        .vertexCount = mesh->vertexCount - vertexStart,
                        .edgeVertexStart = edgeVertexStart,
                        .edgeVertexCount = mesh->edgeVertexCount - edgeVertexStart,
                    };
                    snprintf(modelRange.material, sizeof(modelRange.material), "%s", "model_marker");
                    snprintf(modelRange.modelAssetPath, sizeof(modelRange.modelAssetPath), "%s", entity->modelAssetPath);
                    mesh->faceRanges[mesh->faceRangeCount++] = modelRange;
                    nova_scene_data_release(&scene);
                    return 1;
                }
            }
            nova_scene_data_release(&scene);
        }
    }

    Vec3 center = entity->position;
    Vec3 extents = entity->modelHalfExtents;
    Vec3 color = vec3_make(0.30f, 0.78f, 0.98f);
    float worldMatrix[16];
    vmf_geometry_fill_model_world_matrix(entity, worldMatrix);

    if (extents.raw[0] <= 1e-3f) {
        extents.raw[0] = 16.0f;
    }
    if (extents.raw[1] <= 1e-3f) {
        extents.raw[1] = 16.0f;
    }
    if (extents.raw[2] <= 1e-3f) {
        extents.raw[2] = 16.0f;
    }

    Vec3 corners[8] = {
        vec3_add(center, vec3_make(-extents.raw[0], -extents.raw[1], -extents.raw[2])),
        vec3_add(center, vec3_make( extents.raw[0], -extents.raw[1], -extents.raw[2])),
        vec3_add(center, vec3_make( extents.raw[0],  extents.raw[1], -extents.raw[2])),
        vec3_add(center, vec3_make(-extents.raw[0],  extents.raw[1], -extents.raw[2])),
        vec3_add(center, vec3_make(-extents.raw[0], -extents.raw[1],  extents.raw[2])),
        vec3_add(center, vec3_make( extents.raw[0], -extents.raw[1],  extents.raw[2])),
        vec3_add(center, vec3_make( extents.raw[0],  extents.raw[1],  extents.raw[2])),
        vec3_add(center, vec3_make(-extents.raw[0],  extents.raw[1],  extents.raw[2])),
    };

    ViewerVertex v[8];
    for (int i = 0; i < 8; ++i) {
        v[i].position = transform_point_matrix(worldMatrix, vec3_sub(corners[i], center));
        v[i].normal = vec3_make(0.0f, 0.0f, 1.0f);
        v[i].color = color;
    }

    if (!append_triangle(mesh, v[4], v[5], v[6]) ||
        !append_triangle(mesh, v[4], v[6], v[7]) ||
        !append_triangle(mesh, v[0], v[2], v[1]) ||
        !append_triangle(mesh, v[0], v[3], v[2]) ||
        !append_triangle(mesh, v[0], v[4], v[7]) ||
        !append_triangle(mesh, v[0], v[7], v[3]) ||
        !append_triangle(mesh, v[1], v[2], v[6]) ||
        !append_triangle(mesh, v[1], v[6], v[5]) ||
        !append_triangle(mesh, v[3], v[7], v[6]) ||
        !append_triangle(mesh, v[3], v[6], v[2]) ||
        !append_triangle(mesh, v[0], v[1], v[5]) ||
        !append_triangle(mesh, v[0], v[5], v[4])) {
        return 0;
    }

    if (!append_line(mesh, v[0], v[1]) || !append_line(mesh, v[1], v[2]) ||
        !append_line(mesh, v[2], v[3]) || !append_line(mesh, v[3], v[0]) ||
        !append_line(mesh, v[4], v[5]) || !append_line(mesh, v[5], v[6]) ||
        !append_line(mesh, v[6], v[7]) || !append_line(mesh, v[7], v[4]) ||
        !append_line(mesh, v[0], v[4]) || !append_line(mesh, v[1], v[5]) ||
        !append_line(mesh, v[2], v[6]) || !append_line(mesh, v[3], v[7])) {
        return 0;
    }

    if (!reserve_face_ranges(mesh, mesh->faceRangeCount + 1)) {
        return 0;
    }

    ViewerFaceRange modelRange = {
        .entityIndex = entityIndex,
        .solidIndex = 0,
        .sideIndex = 0,
        .vertexStart = vertexStart,
        .vertexCount = mesh->vertexCount - vertexStart,
        .edgeVertexStart = edgeVertexStart,
        .edgeVertexCount = mesh->edgeVertexCount - edgeVertexStart,
    };
    snprintf(modelRange.material, sizeof(modelRange.material), "%s", "model_marker");
    mesh->faceRanges[mesh->faceRangeCount++] = modelRange;
    return 1;
}

int vmf_build_mesh(const VmfScene* scene, ViewerMesh* outMesh, char* errorBuffer, size_t errorBufferSize) {
    memset(outMesh, 0, sizeof(*outMesh));
    outMesh->bounds = bounds3_empty();

    for (size_t entityIndex = 0; entityIndex < scene->entityCount; ++entityIndex) {
        const VmfEntity* entity = &scene->entities[entityIndex];
        if (entity->kind == VmfEntityKindLight) {
            continue;
        }
        if (entity->kind == VmfEntityKindModel) {
            if (!append_model_marker(outMesh, entity, entityIndex)) {
                viewer_mesh_free(outMesh);
                snprintf(errorBuffer, errorBufferSize, "failed to build model marker geometry");
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
