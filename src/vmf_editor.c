#include "vmf_editor.h"

#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct EditorPlane {
    Vec3 normal;
    float distance;
} EditorPlane;

typedef struct EditorSolidPlane {
    EditorPlane plane;
    char material[128];
    int sideId;
    Vec3 uaxis;
    float uoffset;
    Vec3 vaxis;
    float voffset;
    float uscale;
    float vscale;
    int preserveTextureFrame;
} EditorSolidPlane;

typedef struct EditorFacePolygon {
    Vec3 points[256];
    size_t pointCount;
    EditorSolidPlane face;
} EditorFacePolygon;

static int build_solid_from_planes(VmfSolid* solid,
                                   const EditorSolidPlane* planes,
                                   size_t planeCount,
                                   size_t* nextId);
static void replace_solid_contents(VmfSolid* destination, VmfSolid* replacement);
static void free_solid_contents(VmfSolid* solid);

static int reserve_sides(VmfSolid* solid, size_t minimum) {
    if (solid->sideCapacity >= minimum) {
        return 1;
    }
    size_t capacity = solid->sideCapacity == 0 ? 8 : solid->sideCapacity * 2;
    while (capacity < minimum) {
        capacity *= 2;
    }
    VmfSide* sides = realloc(solid->sides, capacity * sizeof(VmfSide));
    if (!sides) {
        return 0;
    }
    solid->sides = sides;
    solid->sideCapacity = capacity;
    return 1;
}

static int reserve_solids(VmfEntity* entity, size_t minimum) {
    if (entity->solidCapacity >= minimum) {
        return 1;
    }
    size_t capacity = entity->solidCapacity == 0 ? 8 : entity->solidCapacity * 2;
    while (capacity < minimum) {
        capacity *= 2;
    }
    VmfSolid* solids = realloc(entity->solids, capacity * sizeof(VmfSolid));
    if (!solids) {
        return 0;
    }
    entity->solids = solids;
    entity->solidCapacity = capacity;
    return 1;
}

static int reserve_entities(VmfScene* scene, size_t minimum) {
    if (scene->entityCapacity >= minimum) {
        return 1;
    }
    size_t capacity = scene->entityCapacity == 0 ? 8 : scene->entityCapacity * 2;
    while (capacity < minimum) {
        capacity *= 2;
    }
    VmfEntity* entities = realloc(scene->entities, capacity * sizeof(VmfEntity));
    if (!entities) {
        return 0;
    }
    scene->entities = entities;
    scene->entityCapacity = capacity;
    return 1;
}

static size_t scene_next_id(const VmfScene* scene) {
    size_t nextId = 1;
    for (size_t entityIndex = 0; entityIndex < scene->entityCount; ++entityIndex) {
        const VmfEntity* entity = &scene->entities[entityIndex];
        if ((size_t)entity->id >= nextId) {
            nextId = (size_t)entity->id + 1;
        }
        for (size_t solidIndex = 0; solidIndex < entity->solidCount; ++solidIndex) {
            const VmfSolid* solid = &entity->solids[solidIndex];
            if ((size_t)solid->id >= nextId) {
                nextId = (size_t)solid->id + 1;
            }
            for (size_t sideIndex = 0; sideIndex < solid->sideCount; ++sideIndex) {
                if ((size_t)solid->sides[sideIndex].id >= nextId) {
                    nextId = (size_t)solid->sides[sideIndex].id + 1;
                }
            }
        }
    }
    return nextId;
}

static VmfEntity* worldspawn_entity(VmfScene* scene) {
    for (size_t entityIndex = 0; entityIndex < scene->entityCount; ++entityIndex) {
        if (scene->entities[entityIndex].isWorld || scene->entities[entityIndex].kind == VmfEntityKindRoot) {
            return &scene->entities[entityIndex];
        }
    }
    return NULL;
}

static void free_entity_contents(VmfEntity* entity) {
    if (entity == NULL) {
        return;
    }
    for (size_t solidIndex = 0; solidIndex < entity->solidCount; ++solidIndex) {
        free_solid_contents(&entity->solids[solidIndex]);
    }
    free(entity->solids);
    memset(entity, 0, sizeof(*entity));
}

static void remove_entity_at(VmfScene* scene, size_t entityIndex) {
    if (scene == NULL || entityIndex >= scene->entityCount) {
        return;
    }
    free_entity_contents(&scene->entities[entityIndex]);
    for (size_t copyIndex = entityIndex + 1; copyIndex < scene->entityCount; ++copyIndex) {
        scene->entities[copyIndex - 1] = scene->entities[copyIndex];
    }
    scene->entityCount -= 1;
    if (scene->entityCount < scene->entityCapacity) {
        memset(&scene->entities[scene->entityCount], 0, sizeof(VmfEntity));
    }
}

static int validate_bounds(Bounds3 bounds) {
    Vec3 size = bounds3_size(bounds);
    return bounds3_is_valid(bounds) && size.raw[0] >= 1.0f && size.raw[1] >= 1.0f && size.raw[2] >= 1.0f;
}

static int validate_resize_bounds(Bounds3 bounds) {
    for (int axis = 0; axis < 3; ++axis) {
        float minValue = bounds.min.raw[axis];
        float maxValue = bounds.max.raw[axis];
        if (!isfinite(minValue) || !isfinite(maxValue) || fabsf(maxValue - minValue) < 1.0f) {
            return 0;
        }
    }
    return 1;
}

static int remaining_axis(VmfBrushAxis first, VmfBrushAxis second) {
    for (int axis = 0; axis < 3; ++axis) {
        if (axis != (int)first && axis != (int)second) {
            return axis;
        }
    }
    return -1;
}

static EditorPlane plane_from_side(const VmfSide* side) {
    Vec3 edgeA = vec3_sub(side->points[1], side->points[0]);
    Vec3 edgeB = vec3_sub(side->points[2], side->points[0]);
    Vec3 normal = vec3_normalize(vec3_cross(edgeA, edgeB));
    EditorPlane plane = {
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

static EditorPlane orient_plane_toward_interior(EditorPlane plane, Vec3 interiorPoint) {
    float signedDistance = vec3_dot(plane.normal, interiorPoint) - plane.distance;
    if (signedDistance > 0.0f) {
        plane.normal = vec3_scale(plane.normal, -1.0f);
        plane.distance = -plane.distance;
    }
    return plane;
}

static int intersect_planes(EditorPlane a, EditorPlane b, EditorPlane c, Vec3* outPoint) {
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

static int point_in_brush(const EditorPlane* planes, size_t planeCount, Vec3 point) {
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

static const char* default_material_name(const char* material) {
    return material && material[0] ? material : "dev_grid";
}

static int side_sample_count(const VmfSide* side) {
    if (!side->dispinfo.hasData || side->dispinfo.resolution <= 0) {
        return 0;
    }
    return side->dispinfo.resolution * side->dispinfo.resolution;
}

static void free_side_contents(VmfSide* side) {
    free(side->dispinfo.normals);
    free(side->dispinfo.distances);
    free(side->dispinfo.offsets);
    free(side->dispinfo.offsetNormals);
    free(side->dispinfo.alphas);
    memset(side, 0, sizeof(*side));
}

static void free_solid_contents(VmfSolid* solid) {
    if (!solid) {
        return;
    }
    for (size_t sideIndex = 0; sideIndex < solid->sideCount; ++sideIndex) {
        free_side_contents(&solid->sides[sideIndex]);
    }
    free(solid->sides);
    memset(solid, 0, sizeof(*solid));
}

static int clone_side(const VmfSide* source, VmfSide* outSide) {
    memset(outSide, 0, sizeof(*outSide));
    outSide->id = source->id;
    memcpy(outSide->points, source->points, sizeof(source->points));
    memcpy(outSide->material, source->material, sizeof(source->material));
    outSide->uaxis = source->uaxis;
    outSide->uoffset = source->uoffset;
    outSide->vaxis = source->vaxis;
    outSide->voffset = source->voffset;
    outSide->uscale = source->uscale;
    outSide->vscale = source->vscale;
    outSide->dispinfo.hasData = source->dispinfo.hasData;
    outSide->dispinfo.power = source->dispinfo.power;
    outSide->dispinfo.resolution = source->dispinfo.resolution;
    outSide->dispinfo.elevation = source->dispinfo.elevation;
    outSide->dispinfo.startPosition = source->dispinfo.startPosition;

    int sampleCount = side_sample_count(source);
    if (sampleCount <= 0) {
        return 1;
    }

    size_t vectorBytes = (size_t)sampleCount * sizeof(Vec3);
    size_t floatBytes = (size_t)sampleCount * sizeof(float);
    outSide->dispinfo.normals = malloc(vectorBytes);
    outSide->dispinfo.distances = malloc(floatBytes);
    outSide->dispinfo.offsets = malloc(vectorBytes);
    outSide->dispinfo.offsetNormals = malloc(vectorBytes);
    outSide->dispinfo.alphas = malloc(floatBytes);
    if (!outSide->dispinfo.normals || !outSide->dispinfo.distances || !outSide->dispinfo.offsets ||
        !outSide->dispinfo.offsetNormals || !outSide->dispinfo.alphas) {
        free_side_contents(outSide);
        return 0;
    }

    memcpy(outSide->dispinfo.normals, source->dispinfo.normals, vectorBytes);
    memcpy(outSide->dispinfo.distances, source->dispinfo.distances, floatBytes);
    memcpy(outSide->dispinfo.offsets, source->dispinfo.offsets, vectorBytes);
    memcpy(outSide->dispinfo.offsetNormals, source->dispinfo.offsetNormals, vectorBytes);
    memcpy(outSide->dispinfo.alphas, source->dispinfo.alphas, floatBytes);
    return 1;
}

static int clone_solid(const VmfSolid* source, VmfSolid* outSolid) {
    memset(outSolid, 0, sizeof(*outSolid));
    outSolid->id = source->id;
    if (source->sideCount == 0) {
        return 1;
    }

    outSolid->sides = calloc(source->sideCount, sizeof(VmfSide));
    if (!outSolid->sides) {
        return 0;
    }
    outSolid->sideCapacity = source->sideCount;
    outSolid->sideCount = source->sideCount;
    for (size_t sideIndex = 0; sideIndex < source->sideCount; ++sideIndex) {
        if (!clone_side(&source->sides[sideIndex], &outSolid->sides[sideIndex])) {
            for (size_t cleanupIndex = 0; cleanupIndex < sideIndex; ++cleanupIndex) {
                free_side_contents(&outSolid->sides[cleanupIndex]);
            }
            free(outSolid->sides);
            memset(outSolid, 0, sizeof(*outSolid));
            return 0;
        }
    }
    return 1;
}

static int clone_entity(const VmfEntity* source, VmfEntity* outEntity) {
    memset(outEntity, 0, sizeof(*outEntity));
    outEntity->id = source->id;
    outEntity->isWorld = source->isWorld;
    outEntity->enabled = source->enabled;
    outEntity->castShadows = source->castShadows;
    outEntity->lightType = source->lightType;
    outEntity->spotInnerDegrees = source->spotInnerDegrees;
    outEntity->spotOuterDegrees = source->spotOuterDegrees;
    outEntity->kind = source->kind;
    outEntity->position = source->position;
    outEntity->color = source->color;
    outEntity->intensity = source->intensity;
    outEntity->range = source->range;
    memcpy(outEntity->classname, source->classname, sizeof(source->classname));
    memcpy(outEntity->targetname, source->targetname, sizeof(source->targetname));
    memcpy(outEntity->name, source->name, sizeof(source->name));
    if (source->solidCount == 0) {
        return 1;
    }

    outEntity->solids = calloc(source->solidCount, sizeof(VmfSolid));
    if (!outEntity->solids) {
        return 0;
    }
    outEntity->solidCapacity = source->solidCount;
    outEntity->solidCount = source->solidCount;
    for (size_t solidIndex = 0; solidIndex < source->solidCount; ++solidIndex) {
        if (!clone_solid(&source->solids[solidIndex], &outEntity->solids[solidIndex])) {
            for (size_t cleanupIndex = 0; cleanupIndex < solidIndex; ++cleanupIndex) {
                VmfSolid* solid = &outEntity->solids[cleanupIndex];
                for (size_t sideIndex = 0; sideIndex < solid->sideCount; ++sideIndex) {
                    free_side_contents(&solid->sides[sideIndex]);
                }
                free(solid->sides);
            }
            free(outEntity->solids);
            memset(outEntity, 0, sizeof(*outEntity));
            return 0;
        }
    }
    return 1;
}

static void offset_side_geometry(VmfSide* side, Vec3 offset) {
    for (size_t pointIndex = 0; pointIndex < 3; ++pointIndex) {
        side->points[pointIndex] = vec3_add(side->points[pointIndex], offset);
    }
    if (side->dispinfo.hasData) {
        side->dispinfo.startPosition = vec3_add(side->dispinfo.startPosition, offset);
    }
}

static void offset_side_texture_lock(VmfSide* side, Vec3 offset) {
    if (side == NULL) {
        return;
    }
    side->uoffset -= vec3_dot(offset, side->uaxis);
    side->voffset -= vec3_dot(offset, side->vaxis);
}

static Bounds3 entity_selection_bounds(const VmfEntity* entity) {
    if (entity == NULL) {
        return bounds3_empty();
    }

    Bounds3 bounds = bounds3_empty();
    for (size_t solidIndex = 0; solidIndex < entity->solidCount; ++solidIndex) {
        const VmfSolid* solid = &entity->solids[solidIndex];
        for (size_t sideIndex = 0; sideIndex < solid->sideCount; ++sideIndex) {
            const VmfSide* side = &solid->sides[sideIndex];
            for (size_t pointIndex = 0; pointIndex < 3; ++pointIndex) {
                bounds3_expand(&bounds, side->points[pointIndex]);
            }
        }
    }

    if (bounds3_is_valid(bounds)) {
        return bounds;
    }

    float markerHalfExtent = entity->kind == VmfEntityKindLight
        ? fmaxf(24.0f, fminf(entity->range * 0.1f, 64.0f))
        : 16.0f;
    Vec3 extent = vec3_make(markerHalfExtent, markerHalfExtent, markerHalfExtent);
    bounds.min = vec3_sub(entity->position, extent);
    bounds.max = vec3_add(entity->position, extent);
    return bounds;
}

static Vec3 vec3_mul_components(Vec3 a, Vec3 b) {
    return vec3_make(a.raw[0] * b.raw[0], a.raw[1] * b.raw[1], a.raw[2] * b.raw[2]);
}

static float remap_axis_to_bounds(float value, float sourceMin, float sourceMax, float targetMin, float targetMax) {
    float sourceSize = sourceMax - sourceMin;
    if (fabsf(sourceSize) < 1e-5f) {
        return targetMin;
    }
    return targetMin + ((value - sourceMin) / sourceSize) * (targetMax - targetMin);
}

static Vec3 remap_point_to_bounds(Vec3 point, Bounds3 sourceBounds, Bounds3 targetBounds) {
    return vec3_make(remap_axis_to_bounds(point.raw[0], sourceBounds.min.raw[0], sourceBounds.max.raw[0], targetBounds.min.raw[0], targetBounds.max.raw[0]),
                     remap_axis_to_bounds(point.raw[1], sourceBounds.min.raw[1], sourceBounds.max.raw[1], targetBounds.min.raw[1], targetBounds.max.raw[1]),
                     remap_axis_to_bounds(point.raw[2], sourceBounds.min.raw[2], sourceBounds.max.raw[2], targetBounds.min.raw[2], targetBounds.max.raw[2]));
}

static Vec3 bounds_scale_factors(Bounds3 sourceBounds, Bounds3 targetBounds) {
    Vec3 factors = vec3_make(1.0f, 1.0f, 1.0f);
    for (int axis = 0; axis < 3; ++axis) {
        float sourceSize = sourceBounds.max.raw[axis] - sourceBounds.min.raw[axis];
        float targetSize = targetBounds.max.raw[axis] - targetBounds.min.raw[axis];
        factors.raw[axis] = fabsf(sourceSize) < 1e-5f ? 1.0f : targetSize / sourceSize;
    }
    return factors;
}

static void resize_side_geometry(VmfSide* side, Bounds3 sourceBounds, Bounds3 targetBounds) {
    Vec3 scaleFactors = bounds_scale_factors(sourceBounds, targetBounds);
    float averageScale = (fabsf(scaleFactors.raw[0]) + fabsf(scaleFactors.raw[1]) + fabsf(scaleFactors.raw[2])) / 3.0f;
    if (averageScale < 1e-5f) {
        averageScale = 1.0f;
    }

    for (size_t pointIndex = 0; pointIndex < 3; ++pointIndex) {
        side->points[pointIndex] = remap_point_to_bounds(side->points[pointIndex], sourceBounds, targetBounds);
    }
    if (!side->dispinfo.hasData) {
        return;
    }

    side->dispinfo.startPosition = remap_point_to_bounds(side->dispinfo.startPosition, sourceBounds, targetBounds);
    int sampleCount = side_sample_count(side);
    for (int sampleIndex = 0; sampleIndex < sampleCount; ++sampleIndex) {
        side->dispinfo.offsets[sampleIndex] = vec3_mul_components(side->dispinfo.offsets[sampleIndex], scaleFactors);
        if (side->dispinfo.distances && side->dispinfo.normals) {
            Vec3 scaledNormal = vec3_mul_components(side->dispinfo.normals[sampleIndex], scaleFactors);
            float distanceScale = vec3_length(scaledNormal);
            if (distanceScale < 1e-5f) {
                distanceScale = averageScale;
            }
            side->dispinfo.distances[sampleIndex] *= distanceScale;
        }
    }
}

static void assign_material(char destination[128], const char* material) {
    strncpy(destination, default_material_name(material), 127);
    destination[127] = '\0';
}

static int set_plane_from_points(EditorSolidPlane* plane,
                                 Vec3 a,
                                 Vec3 b,
                                 Vec3 c,
                                 Vec3 interiorPoint,
                                 const char* material) {
    Vec3 normal = vec3_cross(vec3_sub(b, a), vec3_sub(c, a));
    if (vec3_length(normal) < 1e-5f) {
        return 0;
    }

    plane->plane.normal = vec3_normalize(normal);
    plane->plane.distance = vec3_dot(plane->plane.normal, a);
    plane->plane = orient_plane_toward_interior(plane->plane, interiorPoint);
    assign_material(plane->material, material);
    plane->sideId = 0;
    return 1;
}

static Vec3 shaped_point_on_axes(int runAxis,
                                 float runValue,
                                 int upAxis,
                                 float upValue,
                                 int widthAxis,
                                 float widthValue) {
    Vec3 point = vec3_make(0.0f, 0.0f, 0.0f);
    point.raw[runAxis] = runValue;
    point.raw[upAxis] = upValue;
    point.raw[widthAxis] = widthValue;
    return point;
}

static void setup_side(VmfSide* side, int id, Vec3 p0, Vec3 p1, Vec3 p2, const char* material) {
    memset(side, 0, sizeof(*side));
    side->id = id;
    side->points[0] = p0;
    side->points[1] = p1;
    side->points[2] = p2;
    assign_material(side->material, material);
    /* Generate default texture axes aligned to the dominant face normal. */
    Vec3 edgeA = vec3_sub(p1, p0);
    Vec3 edgeB = vec3_sub(p2, p0);
    Vec3 normal = vec3_normalize(vec3_cross(edgeA, edgeB));
    float ax = fabsf(normal.raw[0]), ay = fabsf(normal.raw[1]), az = fabsf(normal.raw[2]);
    if (az >= ax && az >= ay) {
        side->uaxis = vec3_make(1.0f, 0.0f, 0.0f);
        side->vaxis = vec3_make(0.0f, -1.0f, 0.0f);
    } else if (ax >= ay) {
        side->uaxis = vec3_make(0.0f, 1.0f, 0.0f);
        side->vaxis = vec3_make(0.0f, 0.0f, -1.0f);
    } else {
        side->uaxis = vec3_make(1.0f, 0.0f, 0.0f);
        side->vaxis = vec3_make(0.0f, 0.0f, -1.0f);
    }
    side->uoffset = 0.0f;
    side->voffset = 0.0f;
    side->uscale  = 0.25f;
    side->vscale  = 0.25f;
}

static int solid_has_displacement(const VmfSolid* solid) {
    for (size_t sideIndex = 0; sideIndex < solid->sideCount; ++sideIndex) {
        if (solid->sides[sideIndex].dispinfo.hasData) {
            return 1;
        }
    }
    return 0;
}

int vmf_scene_entity_bounds(const VmfScene* scene,
                            size_t entityIndex,
                            Bounds3* outBounds,
                            char* errorBuffer,
                            size_t errorBufferSize) {
    if (outBounds == NULL) {
        snprintf(errorBuffer, errorBufferSize, "output bounds pointer is required");
        return 0;
    }
    *outBounds = bounds3_empty();
    if (scene == NULL) {
        snprintf(errorBuffer, errorBufferSize, "scene is required");
        return 0;
    }
    if (entityIndex >= scene->entityCount) {
        snprintf(errorBuffer, errorBufferSize, "entity index %zu is out of range", entityIndex);
        return 0;
    }

    *outBounds = entity_selection_bounds(&scene->entities[entityIndex]);
    return bounds3_is_valid(*outBounds) ? 1 : 0;
}

int vmf_scene_translate_entity(VmfScene* scene,
                               size_t entityIndex,
                               Vec3 offset,
                               int textureLock,
                               char* errorBuffer,
                               size_t errorBufferSize) {
    if (scene == NULL) {
        snprintf(errorBuffer, errorBufferSize, "scene is required");
        return 0;
    }
    if (entityIndex >= scene->entityCount) {
        snprintf(errorBuffer, errorBufferSize, "entity index %zu is out of range", entityIndex);
        return 0;
    }

    VmfEntity* entity = &scene->entities[entityIndex];
    entity->position = vec3_add(entity->position, offset);
    for (size_t solidIndex = 0; solidIndex < entity->solidCount; ++solidIndex) {
        VmfSolid* solid = &entity->solids[solidIndex];
        for (size_t sideIndex = 0; sideIndex < solid->sideCount; ++sideIndex) {
            offset_side_geometry(&solid->sides[sideIndex], offset);
            if (textureLock != 0) {
                offset_side_texture_lock(&solid->sides[sideIndex], offset);
            }
        }
    }
    return 1;
}

static int append_unique_vertex_ref(VmfSolidVertex* vertices,
                                    size_t* vertexCount,
                                    size_t maxVertices,
                                    Vec3 point,
                                    size_t sideA,
                                    size_t sideB,
                                    size_t sideC) {
    size_t indices[3] = { sideA, sideB, sideC };
    for (size_t vertexIndex = 0; vertexIndex < *vertexCount; ++vertexIndex) {
        if (!point_equals(vertices[vertexIndex].position, point)) {
            continue;
        }
        for (size_t i = 0; i < 3; ++i) {
            size_t sideIndex = indices[i];
            int alreadyPresent = 0;
            for (size_t existing = 0; existing < vertices[vertexIndex].sideIndexCount; ++existing) {
                if (vertices[vertexIndex].sideIndices[existing] == sideIndex) {
                    alreadyPresent = 1;
                    break;
                }
            }
            if (!alreadyPresent && vertices[vertexIndex].sideIndexCount < VMF_MAX_VERTEX_PLANES) {
                vertices[vertexIndex].sideIndices[vertices[vertexIndex].sideIndexCount++] = sideIndex;
            }
        }
        return 1;
    }

    if (*vertexCount >= maxVertices) {
        return 0;
    }

    VmfSolidVertex* vertex = &vertices[*vertexCount];
    memset(vertex, 0, sizeof(*vertex));
    vertex->position = point;
    vertex->sideIndices[0] = sideA;
    vertex->sideIndices[1] = sideB;
    vertex->sideIndices[2] = sideC;
    vertex->sideIndexCount = 3;
    *vertexCount += 1;
    return 1;
}

static int append_unique_edge_ref(VmfSolidEdge* edges,
                                  size_t* edgeCount,
                                  size_t maxEdges,
                                  Vec3 point,
                                  size_t sideA,
                                  size_t sideB) {
    if (sideA == sideB) {
        return 1;
    }

    if (sideA > sideB) {
        size_t tmp = sideA;
        sideA = sideB;
        sideB = tmp;
    }

    for (size_t edgeIndex = 0; edgeIndex < *edgeCount; ++edgeIndex) {
        VmfSolidEdge* edge = &edges[edgeIndex];
        if (edge->sideIndices[0] != sideA || edge->sideIndices[1] != sideB) {
            continue;
        }
        if (edge->endpointCount == 0) {
            edge->start = point;
            edge->endpointCount = 1;
            return 1;
        }
        if (point_equals(edge->start, point) || (edge->endpointCount > 1 && point_equals(edge->end, point))) {
            return 1;
        }
        if (edge->endpointCount == 1) {
            edge->end = point;
            edge->endpointCount = 2;
        }
        return 1;
    }

    if (*edgeCount >= maxEdges) {
        return 0;
    }

    VmfSolidEdge* edge = &edges[*edgeCount];
    memset(edge, 0, sizeof(*edge));
    edge->start = point;
    edge->end = point;
    edge->sideIndices[0] = sideA;
    edge->sideIndices[1] = sideB;
    edge->endpointCount = 1;
    *edgeCount += 1;
    return 1;
}

static int collect_solid_vertex_refs(const VmfSolid* solid,
                                     VmfSolidVertex* outVertices,
                                     size_t maxVertices,
                                     size_t* outVertexCount) {
    if (!solid || !outVertices || maxVertices == 0 || !outVertexCount) {
        return 0;
    }

    *outVertexCount = 0;
    if (solid->sideCount < 4 || solid->sideCount > 128) {
        return 1;
    }

    EditorPlane planes[128];
    Vec3 interiorPoint = solid_reference_point(solid);
    for (size_t sideIndex = 0; sideIndex < solid->sideCount; ++sideIndex) {
        planes[sideIndex] = orient_plane_toward_interior(plane_from_side(&solid->sides[sideIndex]), interiorPoint);
    }

    size_t vertexCount = 0;
    for (size_t i = 0; i < solid->sideCount; ++i) {
        for (size_t j = i + 1; j < solid->sideCount; ++j) {
            for (size_t k = j + 1; k < solid->sideCount; ++k) {
                Vec3 point;
                if (!intersect_planes(planes[i], planes[j], planes[k], &point)) {
                    continue;
                }
                if (!point_in_brush(planes, solid->sideCount, point)) {
                    continue;
                }
                if (!append_unique_vertex_ref(outVertices, &vertexCount, maxVertices, point, i, j, k)) {
                    return 0;
                }
            }
        }
    }

    *outVertexCount = vertexCount;
    return 1;
}

static int collect_solid_edges(const VmfSolid* solid,
                               VmfSolidEdge* outEdges,
                               size_t maxEdges,
                               size_t* outEdgeCount) {
    if (!solid || !outEdges || maxEdges == 0 || !outEdgeCount) {
        return 0;
    }

    VmfSolidVertex vertices[VMF_MAX_SOLID_VERTICES];
    size_t vertexCount = 0;
    if (!collect_solid_vertex_refs(solid, vertices, VMF_MAX_SOLID_VERTICES, &vertexCount)) {
        return 0;
    }

    size_t edgeCount = 0;
    for (size_t vertexIndex = 0; vertexIndex < vertexCount; ++vertexIndex) {
        const VmfSolidVertex* vertex = &vertices[vertexIndex];
        for (size_t sideAIndex = 0; sideAIndex < vertex->sideIndexCount; ++sideAIndex) {
            for (size_t sideBIndex = sideAIndex + 1; sideBIndex < vertex->sideIndexCount; ++sideBIndex) {
                if (!append_unique_edge_ref(outEdges,
                                            &edgeCount,
                                            maxEdges,
                                            vertex->position,
                                            vertex->sideIndices[sideAIndex],
                                            vertex->sideIndices[sideBIndex])) {
                    return 0;
                }
            }
        }
    }

    size_t compactedCount = 0;
    for (size_t edgeIndex = 0; edgeIndex < edgeCount; ++edgeIndex) {
        if (outEdges[edgeIndex].endpointCount < 2) {
            continue;
        }
        if (vec3_length(vec3_sub(outEdges[edgeIndex].end, outEdges[edgeIndex].start)) < 0.05f) {
            continue;
        }
        if (compactedCount != edgeIndex) {
            outEdges[compactedCount] = outEdges[edgeIndex];
        }
        compactedCount += 1;
    }

    *outEdgeCount = compactedCount;
    return 1;
}

static int collect_solid_planes(const VmfSolid* solid, EditorSolidPlane* outPlanes, size_t maxPlanes, size_t* outPlaneCount) {
    if (!solid || !outPlanes || !outPlaneCount || solid->sideCount > maxPlanes) {
        return 0;
    }

    Vec3 interiorPoint = solid_reference_point(solid);
    for (size_t sideIndex = 0; sideIndex < solid->sideCount; ++sideIndex) {
        outPlanes[sideIndex].plane = orient_plane_toward_interior(plane_from_side(&solid->sides[sideIndex]), interiorPoint);
        assign_material(outPlanes[sideIndex].material, solid->sides[sideIndex].material);
        outPlanes[sideIndex].sideId = solid->sides[sideIndex].id;
        outPlanes[sideIndex].uaxis = solid->sides[sideIndex].uaxis;
        outPlanes[sideIndex].uoffset = solid->sides[sideIndex].uoffset;
        outPlanes[sideIndex].vaxis = solid->sides[sideIndex].vaxis;
        outPlanes[sideIndex].voffset = solid->sides[sideIndex].voffset;
        outPlanes[sideIndex].uscale = solid->sides[sideIndex].uscale;
        outPlanes[sideIndex].vscale = solid->sides[sideIndex].vscale;
        outPlanes[sideIndex].preserveTextureFrame = 1;
    }
    *outPlaneCount = solid->sideCount;
    return 1;
}

static int collect_solid_face_polygons(const VmfSolid* solid,
                                       EditorFacePolygon* outFaces,
                                       size_t maxFaces,
                                       size_t* outFaceCount) {
    if (!solid || !outFaces || !outFaceCount || solid->sideCount > maxFaces) {
        return 0;
    }

    EditorPlane planes[128];
    Vec3 interiorPoint = solid_reference_point(solid);
    for (size_t sideIndex = 0; sideIndex < solid->sideCount; ++sideIndex) {
        planes[sideIndex] = orient_plane_toward_interior(plane_from_side(&solid->sides[sideIndex]), interiorPoint);
    }

    size_t faceCount = 0;
    for (size_t sideIndex = 0; sideIndex < solid->sideCount; ++sideIndex) {
        if (faceCount >= maxFaces) {
            return 0;
        }

        EditorFacePolygon* face = &outFaces[faceCount];
        memset(face, 0, sizeof(*face));
        face->face.plane = planes[sideIndex];
        assign_material(face->face.material, solid->sides[sideIndex].material);
        face->face.sideId = solid->sides[sideIndex].id;

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
                if (face->pointCount < 256) {
                    append_unique(face->points, &face->pointCount, point);
                }
            }
        }

        if (face->pointCount < 3) {
            continue;
        }

        sort_polygon(face->points, face->pointCount, face->face.plane.normal);
        faceCount += 1;
    }

    *outFaceCount = faceCount;
    return 1;
}

static int plane_from_points_matching_reference(Vec3 a,
                                                Vec3 b,
                                                Vec3 c,
                                                Vec3 referenceNormal,
                                                EditorPlane* outPlane) {
    Vec3 normal = vec3_cross(vec3_sub(b, a), vec3_sub(c, a));
    if (vec3_length(normal) < 1e-5f) {
        return 0;
    }
    normal = vec3_normalize(normal);
    if (vec3_dot(normal, referenceNormal) < 0.0f) {
        normal = vec3_scale(normal, -1.0f);
    }

    outPlane->normal = normal;
    outPlane->distance = vec3_dot(normal, a);
    return 1;
}

static ssize_t polygon_vertex_index(const EditorFacePolygon* face, Vec3 point) {
    for (size_t pointIndex = 0; pointIndex < face->pointCount; ++pointIndex) {
        if (point_equals(face->points[pointIndex], point)) {
            return (ssize_t)pointIndex;
        }
    }
    return -1;
}

static Vec3 rotate_vector_around_axis(Vec3 vector, Vec3 axis, float angle) {
    Vec3 unitAxis = vec3_normalize(axis);
    if (vec3_length(unitAxis) < 1e-5f || fabsf(angle) < 1e-6f) {
        return vector;
    }

    float cosAngle = cosf(angle);
    float sinAngle = sinf(angle);
    Vec3 parallel = vec3_scale(unitAxis, vec3_dot(unitAxis, vector));
    Vec3 perpendicular = vec3_sub(vector, parallel);
    Vec3 tangent = vec3_cross(unitAxis, perpendicular);
    return vec3_add(parallel,
                    vec3_add(vec3_scale(perpendicular, cosAngle),
                             vec3_scale(tangent, sinAngle)));
}

static void default_face_wrap_axes(Vec3 normal, Vec3* outUAxis, Vec3* outVAxis) {
    Vec3 worldUp = vec3_make(0.0f, 0.0f, 1.0f);
    float dotUp = vec3_dot(normal, worldUp);
    if (fabsf(dotUp) >= 0.999f) {
        *outUAxis = vec3_make(1.0f, 0.0f, 0.0f);
        *outVAxis = vec3_make(0.0f, dotUp > 0.0f ? -1.0f : 1.0f, 0.0f);
        return;
    }

    Vec3 skyOnFace = vec3_normalize(vec3_sub(worldUp, vec3_scale(normal, dotUp)));
    *outVAxis = vec3_make(-skyOnFace.raw[0], -skyOnFace.raw[1], -skyOnFace.raw[2]);
    *outUAxis = vec3_normalize(vec3_cross(normal, skyOnFace));
}

static void normalize_side_uv_frame(VmfSide* side) {
    if (vec3_length(side->uaxis) > 1e-5f) {
        side->uaxis = vec3_normalize(side->uaxis);
    }
    if (vec3_length(side->vaxis) > 1e-5f) {
        side->vaxis = vec3_normalize(side->vaxis);
    }
}

static int validate_texture_side_request(VmfScene* scene,
                                         size_t entityIndex,
                                         size_t solidIndex,
                                         size_t sideIndex,
                                         VmfSolid** outSolid,
                                         VmfSide** outSide,
                                         char* errorBuffer,
                                         size_t errorBufferSize) {
    if (!scene || entityIndex >= scene->entityCount ||
        solidIndex >= scene->entities[entityIndex].solidCount ||
        sideIndex >= scene->entities[entityIndex].solids[solidIndex].sideCount) {
        snprintf(errorBuffer, errorBufferSize, "invalid face texture request");
        return 0;
    }

    if (outSolid != NULL) {
        *outSolid = &scene->entities[entityIndex].solids[solidIndex];
    }
    if (outSide != NULL) {
        *outSide = &scene->entities[entityIndex].solids[solidIndex].sides[sideIndex];
    }
    return 1;
}

static int collect_face_polygon_for_side(const VmfSolid* solid,
                                         size_t sideIndex,
                                         EditorFacePolygon* outFace) {
    EditorFacePolygon faces[128];
    size_t faceCount = 0;
    int sideId;

    if (solid == NULL || outFace == NULL || sideIndex >= solid->sideCount || solid->sideCount == 0 || solid->sideCount > 128) {
        return 0;
    }

    if (!collect_solid_face_polygons(solid, faces, 128, &faceCount)) {
        return 0;
    }

    sideId = solid->sides[sideIndex].id;
    for (size_t faceIndex = 0; faceIndex < faceCount; ++faceIndex) {
        if (faces[faceIndex].face.sideId == sideId) {
            *outFace = faces[faceIndex];
            return 1;
        }
    }

    return 0;
}

static void projected_face_bounds(const EditorFacePolygon* face,
                                  Vec3 uaxis,
                                  Vec3 vaxis,
                                  float* outMinU,
                                  float* outMaxU,
                                  float* outMinV,
                                  float* outMaxV) {
    float minU;
    float maxU;
    float minV;
    float maxV;

    minU = maxU = vec3_dot(face->points[0], uaxis);
    minV = maxV = vec3_dot(face->points[0], vaxis);
    for (size_t pointIndex = 1; pointIndex < face->pointCount; ++pointIndex) {
        float projectedU = vec3_dot(face->points[pointIndex], uaxis);
        float projectedV = vec3_dot(face->points[pointIndex], vaxis);
        if (projectedU < minU) minU = projectedU;
        if (projectedU > maxU) maxU = projectedU;
        if (projectedV < minV) minV = projectedV;
        if (projectedV > maxV) maxV = projectedV;
    }

    if (outMinU != NULL) *outMinU = minU;
    if (outMaxU != NULL) *outMaxU = maxU;
    if (outMinV != NULL) *outMinV = minV;
    if (outMaxV != NULL) *outMaxV = maxV;
}

static int rebuild_solid_from_planes_checked(VmfSolid* solid,
                                             const EditorSolidPlane* planes,
                                             size_t planeCount,
                                             size_t* nextId) {
    VmfSolid rebuilt;
    memset(&rebuilt, 0, sizeof(rebuilt));
    rebuilt.id = solid->id;
    if (!build_solid_from_planes(&rebuilt, planes, planeCount, nextId)) {
        free_solid_contents(&rebuilt);
        return 0;
    }
    replace_solid_contents(solid, &rebuilt);
    return 1;
}

static int build_solid_from_planes(VmfSolid* solid,
                                   const EditorSolidPlane* planes,
                                   size_t planeCount,
                                   size_t* nextId) {
    if (!solid || !planes || planeCount == 0 || !nextId) {
        return 0;
    }
    if (!reserve_sides(solid, planeCount)) {
        return 0;
    }

    EditorPlane planeBuffer[129];
    for (size_t planeIndex = 0; planeIndex < planeCount; ++planeIndex) {
        planeBuffer[planeIndex] = planes[planeIndex].plane;
    }

    size_t builtCount = 0;
    for (size_t sideIndex = 0; sideIndex < planeCount; ++sideIndex) {
        Vec3 polygon[256];
        size_t polygonCount = 0;
        for (size_t j = 0; j < planeCount; ++j) {
            if (j == sideIndex) {
                continue;
            }
            for (size_t k = j + 1; k < planeCount; ++k) {
                if (k == sideIndex) {
                    continue;
                }
                Vec3 point;
                if (!intersect_planes(planes[sideIndex].plane, planes[j].plane, planes[k].plane, &point)) {
                    continue;
                }
                if (!point_in_brush(planeBuffer, planeCount, point)) {
                    continue;
                }
                if (polygonCount < 256) {
                    append_unique(polygon, &polygonCount, point);
                }
            }
        }
        if (polygonCount < 3) {
            continue;
        }

        sort_polygon(polygon, polygonCount, planes[sideIndex].plane.normal);
        Vec3 p0 = polygon[0];
        Vec3 p1 = polygon[1];
        Vec3 p2 = polygon[2];
        Vec3 builtNormal = vec3_normalize(vec3_cross(vec3_sub(p1, p0), vec3_sub(p2, p0)));
        if (vec3_dot(builtNormal, planes[sideIndex].plane.normal) < 0.0f) {
            Vec3 tmp = p1;
            p1 = p2;
            p2 = tmp;
        }

        int sideId = planes[sideIndex].sideId > 0 ? planes[sideIndex].sideId : (int)(*nextId)++;
        setup_side(&solid->sides[builtCount], sideId, p0, p1, p2, planes[sideIndex].material);
        if (planes[sideIndex].preserveTextureFrame) {
            solid->sides[builtCount].uaxis = planes[sideIndex].uaxis;
            solid->sides[builtCount].uoffset = planes[sideIndex].uoffset;
            solid->sides[builtCount].vaxis = planes[sideIndex].vaxis;
            solid->sides[builtCount].voffset = planes[sideIndex].voffset;
            solid->sides[builtCount].uscale = planes[sideIndex].uscale;
            solid->sides[builtCount].vscale = planes[sideIndex].vscale;
        }
        builtCount += 1;
    }

    solid->sideCount = builtCount;
    return builtCount >= 4;
}

static void replace_solid_contents(VmfSolid* destination, VmfSolid* replacement) {
    for (size_t sideIndex = 0; sideIndex < destination->sideCount; ++sideIndex) {
        free_side_contents(&destination->sides[sideIndex]);
    }
    free(destination->sides);
    *destination = *replacement;
    memset(replacement, 0, sizeof(*replacement));
}

static int fill_block_sides(VmfSolid* solid, Bounds3 bounds, size_t* nextId, const char* material) {
    if (!reserve_sides(solid, 6)) {
        return 0;
    }

    solid->sideCount = 6;
    setup_side(&solid->sides[0], (int)(*nextId)++,
               vec3_make(bounds.max.raw[0], bounds.min.raw[1], bounds.min.raw[2]),
               vec3_make(bounds.max.raw[0], bounds.max.raw[1], bounds.min.raw[2]),
               vec3_make(bounds.max.raw[0], bounds.max.raw[1], bounds.max.raw[2]),
               material);
    setup_side(&solid->sides[1], (int)(*nextId)++,
               vec3_make(bounds.min.raw[0], bounds.min.raw[1], bounds.min.raw[2]),
               vec3_make(bounds.min.raw[0], bounds.min.raw[1], bounds.max.raw[2]),
               vec3_make(bounds.min.raw[0], bounds.max.raw[1], bounds.max.raw[2]),
               material);
    setup_side(&solid->sides[2], (int)(*nextId)++,
               vec3_make(bounds.min.raw[0], bounds.max.raw[1], bounds.min.raw[2]),
               vec3_make(bounds.min.raw[0], bounds.max.raw[1], bounds.max.raw[2]),
               vec3_make(bounds.max.raw[0], bounds.max.raw[1], bounds.max.raw[2]),
               material);
    setup_side(&solid->sides[3], (int)(*nextId)++,
               vec3_make(bounds.min.raw[0], bounds.min.raw[1], bounds.min.raw[2]),
               vec3_make(bounds.max.raw[0], bounds.min.raw[1], bounds.min.raw[2]),
               vec3_make(bounds.max.raw[0], bounds.min.raw[1], bounds.max.raw[2]),
               material);
    setup_side(&solid->sides[4], (int)(*nextId)++,
               vec3_make(bounds.min.raw[0], bounds.min.raw[1], bounds.max.raw[2]),
               vec3_make(bounds.max.raw[0], bounds.min.raw[1], bounds.max.raw[2]),
               vec3_make(bounds.max.raw[0], bounds.max.raw[1], bounds.max.raw[2]),
               material);
    setup_side(&solid->sides[5], (int)(*nextId)++,
               vec3_make(bounds.min.raw[0], bounds.min.raw[1], bounds.min.raw[2]),
               vec3_make(bounds.min.raw[0], bounds.max.raw[1], bounds.min.raw[2]),
               vec3_make(bounds.max.raw[0], bounds.max.raw[1], bounds.min.raw[2]),
               material);
    return 1;
}

static int fill_cylinder_sides(VmfSolid* solid,
                               Bounds3 bounds,
                               VmfBrushAxis axis,
                               size_t segmentCount,
                               size_t* nextId,
                               const char* material) {
    if (segmentCount < 3) {
        segmentCount = 3;
    }
    if (!reserve_sides(solid, segmentCount + 2)) {
        return 0;
    }

    solid->sideCount = segmentCount + 2;
    float alongMin = bounds.min.raw[axis];
    float alongMax = bounds.max.raw[axis];
    int uAxis = axis == VmfBrushAxisX ? 1 : 0;
    int vAxis = axis == VmfBrushAxisZ ? 1 : 2;
    if (axis == VmfBrushAxisY) {
        vAxis = 2;
    }
    float centerU = (bounds.min.raw[uAxis] + bounds.max.raw[uAxis]) * 0.5f;
    float centerV = (bounds.min.raw[vAxis] + bounds.max.raw[vAxis]) * 0.5f;
    float radiusU = fmaxf((bounds.max.raw[uAxis] - bounds.min.raw[uAxis]) * 0.5f, 1.0f);
    float radiusV = fmaxf((bounds.max.raw[vAxis] - bounds.min.raw[vAxis]) * 0.5f, 1.0f);

    Vec3* ring = calloc(segmentCount, sizeof(Vec3));
    if (!ring) {
        return 0;
    }

    for (size_t index = 0; index < segmentCount; ++index) {
        float angle = (float)index / (float)segmentCount * (float)(M_PI * 2.0);
        float u = centerU + cosf(angle) * radiusU;
        float v = centerV + sinf(angle) * radiusV;
        ring[index] = vec3_make(0.0f, 0.0f, 0.0f);
        ring[index].raw[uAxis] = u;
        ring[index].raw[vAxis] = v;
    }

    for (size_t index = 0; index < segmentCount; ++index) {
        size_t nextIndex = (index + 1) % segmentCount;
        Vec3 bottomA = ring[index];
        Vec3 bottomB = ring[nextIndex];
        bottomA.raw[axis] = alongMin;
        bottomB.raw[axis] = alongMin;
        Vec3 topB = bottomB;
        topB.raw[axis] = alongMax;
        setup_side(&solid->sides[index], (int)(*nextId)++, bottomA, bottomB, topB, material);
    }

    Vec3 cap0 = ring[0]; cap0.raw[axis] = alongMax;
    Vec3 cap1 = ring[1 % segmentCount]; cap1.raw[axis] = alongMax;
    Vec3 cap2 = ring[2 % segmentCount]; cap2.raw[axis] = alongMax;
    setup_side(&solid->sides[segmentCount], (int)(*nextId)++, cap0, cap1, cap2, material);

    Vec3 bottom0 = ring[0]; bottom0.raw[axis] = alongMin;
    Vec3 bottom1 = ring[2 % segmentCount]; bottom1.raw[axis] = alongMin;
    Vec3 bottom2 = ring[1 % segmentCount]; bottom2.raw[axis] = alongMin;
    setup_side(&solid->sides[segmentCount + 1], (int)(*nextId)++, bottom0, bottom1, bottom2, material);

    free(ring);
    return 1;
}

static int fill_ramp_sides(VmfSolid* solid,
                           Bounds3 bounds,
                           VmfBrushAxis axis,
                           VmfBrushAxis slopeAxis,
                           size_t* nextId,
                           const char* material) {
    int widthAxis = remaining_axis(axis, slopeAxis);
    if (widthAxis < 0 || axis == slopeAxis) {
        return 0;
    }

    float minValues[3] = {
        bounds.min.raw[0],
        bounds.min.raw[1],
        bounds.min.raw[2],
    };
    float maxValues[3] = {
        bounds.max.raw[0],
        bounds.max.raw[1],
        bounds.max.raw[2],
    };

    Vec3 lowMinMin = vec3_make(minValues[0], minValues[1], minValues[2]);
    Vec3 lowMinMax = lowMinMin;
    Vec3 lowMaxMin = lowMinMin;
    Vec3 lowMaxMax = lowMinMin;
    Vec3 highMaxMin = lowMinMin;
    Vec3 highMaxMax = lowMinMin;

    lowMinMax.raw[widthAxis] = maxValues[widthAxis];
    lowMaxMin.raw[slopeAxis] = maxValues[slopeAxis];
    lowMaxMax.raw[slopeAxis] = maxValues[slopeAxis];
    lowMaxMax.raw[widthAxis] = maxValues[widthAxis];
    highMaxMin = lowMaxMin;
    highMaxMin.raw[axis] = maxValues[axis];
    highMaxMax = lowMaxMax;
    highMaxMax.raw[axis] = maxValues[axis];

    Vec3 interiorPoint = vec3_make((minValues[0] + maxValues[0]) * 0.5f,
                                   (minValues[1] + maxValues[1]) * 0.5f,
                                   (minValues[2] + maxValues[2]) * 0.5f);
    interiorPoint.raw[slopeAxis] = minValues[slopeAxis] + (maxValues[slopeAxis] - minValues[slopeAxis]) * 0.75f;
    interiorPoint.raw[axis] = minValues[axis] + (maxValues[axis] - minValues[axis]) * 0.25f;

    EditorSolidPlane planes[5];
    if (!set_plane_from_points(&planes[0], lowMaxMin, lowMaxMax, highMaxMax, interiorPoint, material) ||
        !set_plane_from_points(&planes[1], lowMinMin, lowMaxMin, lowMaxMax, interiorPoint, material) ||
        !set_plane_from_points(&planes[2], lowMinMin, highMaxMin, lowMaxMin, interiorPoint, material) ||
        !set_plane_from_points(&planes[3], lowMinMax, lowMaxMax, highMaxMax, interiorPoint, material) ||
        !set_plane_from_points(&planes[4], lowMinMin, lowMinMax, highMaxMax, interiorPoint, material)) {
        return 0;
    }

    return build_solid_from_planes(solid, planes, 5, nextId);
}

static int collect_solid_vertices(const VmfSolid* solid,
                                  Vec3* outVertices,
                                  size_t maxVertices,
                                  size_t* outVertexCount) {
    if (!solid || !outVertices || maxVertices == 0 || !outVertexCount) {
        return 0;
    }

    *outVertexCount = 0;
    if (solid->sideCount < 4 || solid->sideCount > 128) {
        return 1;
    }

    EditorPlane planes[128];
    Vec3 interiorPoint = solid_reference_point(solid);
    for (size_t sideIndex = 0; sideIndex < solid->sideCount; ++sideIndex) {
        planes[sideIndex] = orient_plane_toward_interior(plane_from_side(&solid->sides[sideIndex]), interiorPoint);
    }

    size_t vertexCount = 0;
    for (size_t i = 0; i < solid->sideCount; ++i) {
        for (size_t j = i + 1; j < solid->sideCount; ++j) {
            for (size_t k = j + 1; k < solid->sideCount; ++k) {
                Vec3 point;
                if (!intersect_planes(planes[i], planes[j], planes[k], &point)) {
                    continue;
                }
                if (!point_in_brush(planes, solid->sideCount, point)) {
                    continue;
                }

                int duplicate = 0;
                for (size_t existingIndex = 0; existingIndex < vertexCount; ++existingIndex) {
                    if (point_equals(outVertices[existingIndex], point)) {
                        duplicate = 1;
                        break;
                    }
                }
                if (duplicate) {
                    continue;
                }
                if (vertexCount >= maxVertices) {
                    return 0;
                }
                outVertices[vertexCount++] = point;
            }
        }
    }

    *outVertexCount = vertexCount;
    return 1;
}

static int ray_triangle_intersection(Vec3 origin,
                                     Vec3 direction,
                                     Vec3 a,
                                     Vec3 b,
                                     Vec3 c,
                                     float* outDistance,
                                     Vec3* outPoint) {
    Vec3 edgeA = vec3_sub(b, a);
    Vec3 edgeB = vec3_sub(c, a);
    Vec3 p = vec3_cross(direction, edgeB);
    float determinant = vec3_dot(edgeA, p);
    if (fabsf(determinant) < 1e-6f) {
        return 0;
    }

    float inverse = 1.0f / determinant;
    Vec3 t = vec3_sub(origin, a);
    float u = vec3_dot(t, p) * inverse;
    if (u < 0.0f || u > 1.0f) {
        return 0;
    }

    Vec3 q = vec3_cross(t, edgeA);
    float v = vec3_dot(direction, q) * inverse;
    if (v < 0.0f || u + v > 1.0f) {
        return 0;
    }

    float distance = vec3_dot(edgeB, q) * inverse;
    if (distance <= 0.001f) {
        return 0;
    }
    if (outDistance) {
        *outDistance = distance;
    }
    if (outPoint) {
        *outPoint = vec3_add(origin, vec3_scale(direction, distance));
    }
    return 1;
}

static void write_side(FILE* file, const VmfSide* side, int indent) {
    fprintf(file, "%*sside\n", indent, "");
    fprintf(file, "%*s{\n", indent, "");
    fprintf(file, "%*s\"id\" \"%d\"\n", indent + 4, "", side->id);
    fprintf(file,
            "%*s\"plane\" \"( %.6f %.6f %.6f ) ( %.6f %.6f %.6f ) ( %.6f %.6f %.6f )\"\n",
            indent + 4,
            "",
            side->points[0].raw[0], side->points[0].raw[1], side->points[0].raw[2],
            side->points[1].raw[0], side->points[1].raw[1], side->points[1].raw[2],
            side->points[2].raw[0], side->points[2].raw[1], side->points[2].raw[2]);
    fprintf(file, "%*s\"material\" \"%s\"\n", indent + 4, "", side->material[0] ? side->material : "dev_grid");
    {
        Vec3  ua  = side->uaxis.raw[0] != 0.0f || side->uaxis.raw[1] != 0.0f || side->uaxis.raw[2] != 0.0f ? side->uaxis : vec3_make(1,0,0);
        float uof = side->uoffset;
        float usc = fabsf(side->uscale) > 1e-5f ? side->uscale : 0.25f;
        Vec3  va  = side->vaxis.raw[0] != 0.0f || side->vaxis.raw[1] != 0.0f || side->vaxis.raw[2] != 0.0f ? side->vaxis : vec3_make(0,-1,0);
        float vof = side->voffset;
        float vsc = fabsf(side->vscale) > 1e-5f ? side->vscale : 0.25f;
        fprintf(file, "%*s\"uaxis\" \"[%.6f %.6f %.6f %.6f] %.6f\"\n", indent + 4, "", ua.raw[0], ua.raw[1], ua.raw[2], uof, usc);
        fprintf(file, "%*s\"vaxis\" \"[%.6f %.6f %.6f %.6f] %.6f\"\n", indent + 4, "", va.raw[0], va.raw[1], va.raw[2], vof, vsc);
    }
    fprintf(file, "%*s\"rotation\" \"0\"\n", indent + 4, "");
    fprintf(file, "%*s\"lightmapscale\" \"16\"\n", indent + 4, "");
    fprintf(file, "%*s\"smoothing_groups\" \"0\"\n", indent + 4, "");
    fprintf(file, "%*s}\n", indent, "");
}

int vmf_scene_init_empty(VmfScene* outScene, char* errorBuffer, size_t errorBufferSize) {
    if (!outScene) {
        snprintf(errorBuffer, errorBufferSize, "invalid scene pointer");
        return 0;
    }

    memset(outScene, 0, sizeof(*outScene));
    outScene->entities = calloc(1, sizeof(VmfEntity));
    if (!outScene->entities) {
        snprintf(errorBuffer, errorBufferSize, "out of memory creating empty scene");
        return 0;
    }
    outScene->entityCapacity = 1;
    outScene->entityCount = 1;
    outScene->entities[0].id = 1;
    outScene->entities[0].isWorld = 1;
    outScene->entities[0].enabled = 1;
    outScene->entities[0].kind = VmfEntityKindRoot;
    strncpy(outScene->entities[0].name, "Scene Root", sizeof(outScene->entities[0].name) - 1);
    strncpy(outScene->entities[0].classname, "worldspawn", sizeof(outScene->entities[0].classname) - 1);
    return 1;
}

int vmf_scene_clone(const VmfScene* source, VmfScene* outScene, char* errorBuffer, size_t errorBufferSize) {
    if (!source || !outScene) {
        snprintf(errorBuffer, errorBufferSize, "invalid scene clone request");
        return 0;
    }

    memset(outScene, 0, sizeof(*outScene));
    if (source->entityCount == 0) {
        return 1;
    }

    outScene->entities = calloc(source->entityCount, sizeof(VmfEntity));
    if (!outScene->entities) {
        snprintf(errorBuffer, errorBufferSize, "out of memory cloning scene");
        return 0;
    }
    outScene->entityCapacity = source->entityCount;
    outScene->entityCount = source->entityCount;
    for (size_t entityIndex = 0; entityIndex < source->entityCount; ++entityIndex) {
        if (!clone_entity(&source->entities[entityIndex], &outScene->entities[entityIndex])) {
            vmf_scene_free(outScene);
            snprintf(errorBuffer, errorBufferSize, "out of memory cloning scene entity");
            return 0;
        }
    }
    return 1;
}

int vmf_scene_save(const char* path, const VmfScene* scene, char* errorBuffer, size_t errorBufferSize) {
    if (!path || !scene) {
        snprintf(errorBuffer, errorBufferSize, "invalid scene save request");
        return 0;
    }

    FILE* file = fopen(path, "wb");
    if (!file) {
        snprintf(errorBuffer, errorBufferSize, "failed to open %s for writing: %s", path, strerror(errno));
        return 0;
    }

    fprintf(file, "sledgehammer\n{\n    \"format\" \"slg\"\n    \"version\" \"1\"\n}\n");
    fprintf(file, "viewsettings\n{\n    \"snap_to_grid\" \"1\"\n    \"show_grid\" \"1\"\n    \"grid_spacing\" \"64\"\n}\n");

    for (size_t entityIndex = 0; entityIndex < scene->entityCount; ++entityIndex) {
        const VmfEntity* entity = &scene->entities[entityIndex];
        fprintf(file, (entity->kind == VmfEntityKindRoot || entity->isWorld) ? "scene\n{\n" : "entity\n{\n");
        fprintf(file, "    \"id\" \"%d\"\n", entity->id);
        fprintf(file, "    \"type\" \"%s\"\n",
                (entity->kind == VmfEntityKindRoot || entity->isWorld) ? "root" :
                (entity->kind == VmfEntityKindLight ? "light" : "brush"));
        if (entity->name[0]) {
            fprintf(file, "    \"name\" \"%s\"\n", entity->name);
        }
        if (entity->classname[0]) {
            fprintf(file, "    \"classname\" \"%s\"\n", entity->classname);
        }
        if (entity->targetname[0]) {
            fprintf(file, "    \"targetname\" \"%s\"\n", entity->targetname);
        }
        if (entity->kind == VmfEntityKindLight) {
            fprintf(file, "    \"position\" \"[%.6f %.6f %.6f]\"\n", entity->position.raw[0], entity->position.raw[1], entity->position.raw[2]);
            fprintf(file, "    \"color\" \"[%.6f %.6f %.6f]\"\n", entity->color.raw[0], entity->color.raw[1], entity->color.raw[2]);
            fprintf(file, "    \"intensity\" \"%.6f\"\n", entity->intensity);
            fprintf(file, "    \"range\" \"%.6f\"\n", entity->range);
            fprintf(file, "    \"enabled\" \"%d\"\n", entity->enabled ? 1 : 0);
            fprintf(file, "    \"cast_shadows\" \"%d\"\n", entity->castShadows ? 1 : 0);
            fprintf(file, "    \"light_type\" \"%d\"\n", entity->lightType);
            fprintf(file, "    \"spot_inner_degrees\" \"%.6f\"\n", entity->spotInnerDegrees);
            fprintf(file, "    \"spot_outer_degrees\" \"%.6f\"\n", entity->spotOuterDegrees);
        }

        for (size_t solidIndex = 0; solidIndex < entity->solidCount; ++solidIndex) {
            const VmfSolid* solid = &entity->solids[solidIndex];
            fprintf(file, "    solid\n    {\n");
            fprintf(file, "        \"id\" \"%d\"\n", solid->id);
            for (size_t sideIndex = 0; sideIndex < solid->sideCount; ++sideIndex) {
                write_side(file, &solid->sides[sideIndex], 8);
            }
            fprintf(file, "    }\n");
        }
        fprintf(file, "}\n");
    }
    fclose(file);
    return 1;
}

int vmf_scene_add_light_entity(VmfScene* scene,
                               const char* name,
                               Vec3 position,
                               Vec3 color,
                               float intensity,
                               float range,
                               int castShadows,
                               size_t* outEntityIndex,
                               char* errorBuffer,
                               size_t errorBufferSize) {
    if (!scene) {
        snprintf(errorBuffer, errorBufferSize, "invalid light entity request");
        return 0;
    }
    if (!reserve_entities(scene, scene->entityCount + 1)) {
        snprintf(errorBuffer, errorBufferSize, "out of memory adding light entity");
        return 0;
    }

    VmfEntity entity;
    memset(&entity, 0, sizeof(entity));
    entity.id = (int)scene_next_id(scene);
    entity.enabled = 1;
    entity.castShadows = castShadows != 0;
    entity.lightType = 3;
    entity.spotInnerDegrees = 18.0f;
    entity.spotOuterDegrees = 28.0f;
    entity.kind = VmfEntityKindLight;
    entity.position = position;
    entity.color = color;
    entity.intensity = intensity > 0.0f ? intensity : 10.0f;
    entity.range = range > 0.0f ? range : 512.0f;
    strncpy(entity.name, (name && name[0]) ? name : "Light", sizeof(entity.name) - 1);
    strncpy(entity.classname, "light", sizeof(entity.classname) - 1);

    scene->entities[scene->entityCount] = entity;
    if (outEntityIndex) {
        *outEntityIndex = scene->entityCount;
    }
    scene->entityCount += 1;
    return 1;
}

int vmf_scene_add_brush_entity(VmfScene* scene,
                               const char* name,
                               const char* classname,
                               size_t* outEntityIndex,
                               char* errorBuffer,
                               size_t errorBufferSize) {
    if (!scene) {
        snprintf(errorBuffer, errorBufferSize, "invalid brush entity request");
        return 0;
    }
    if (!reserve_entities(scene, scene->entityCount + 1)) {
        snprintf(errorBuffer, errorBufferSize, "out of memory adding brush entity");
        return 0;
    }

    VmfEntity entity;
    memset(&entity, 0, sizeof(entity));
    entity.id = (int)scene_next_id(scene);
    entity.enabled = 1;
    entity.castShadows = 1;
    entity.kind = VmfEntityKindBrush;
    strncpy(entity.name, (name && name[0]) ? name : "Group", sizeof(entity.name) - 1);
    strncpy(entity.classname, (classname && classname[0]) ? classname : "func_group", sizeof(entity.classname) - 1);

    scene->entities[scene->entityCount] = entity;
    if (outEntityIndex) {
        *outEntityIndex = scene->entityCount;
    }
    scene->entityCount += 1;
    return 1;
}

int vmf_scene_add_block_brush(VmfScene* scene,
                              Bounds3 bounds,
                              const char* material,
                              size_t* outEntityIndex,
                              size_t* outSolidIndex,
                              char* errorBuffer,
                              size_t errorBufferSize) {
    if (!scene) {
        snprintf(errorBuffer, errorBufferSize, "invalid scene pointer");
        return 0;
    }
    if (!validate_bounds(bounds)) {
        snprintf(errorBuffer, errorBufferSize, "invalid brush bounds");
        return 0;
    }

    VmfEntity* world = worldspawn_entity(scene);
    if (!world) {
        snprintf(errorBuffer, errorBufferSize, "scene is missing worldspawn");
        return 0;
    }
    if (!reserve_solids(world, world->solidCount + 1)) {
        snprintf(errorBuffer, errorBufferSize, "out of memory adding brush");
        return 0;
    }

    size_t nextId = scene_next_id(scene);
    VmfSolid solid;
    memset(&solid, 0, sizeof(solid));
    solid.id = (int)nextId++;
    if (!fill_block_sides(&solid, bounds, &nextId, material)) {
        free(solid.sides);
        snprintf(errorBuffer, errorBufferSize, "out of memory building brush sides");
        return 0;
    }

    world->solids[world->solidCount] = solid;
    if (outEntityIndex) {
        *outEntityIndex = (size_t)(world - scene->entities);
    }
    if (outSolidIndex) {
        *outSolidIndex = world->solidCount;
    }
    world->solidCount += 1;
    return 1;
}

int vmf_scene_add_cylinder_brush(VmfScene* scene,
                                 Bounds3 bounds,
                                 VmfBrushAxis axis,
                                 size_t segmentCount,
                                 const char* material,
                                 size_t* outEntityIndex,
                                 size_t* outSolidIndex,
                                 char* errorBuffer,
                                 size_t errorBufferSize) {
    if (!scene) {
        snprintf(errorBuffer, errorBufferSize, "invalid scene pointer");
        return 0;
    }
    if (!validate_bounds(bounds)) {
        snprintf(errorBuffer, errorBufferSize, "invalid cylinder bounds");
        return 0;
    }

    VmfEntity* world = worldspawn_entity(scene);
    if (!world) {
        snprintf(errorBuffer, errorBufferSize, "scene is missing worldspawn");
        return 0;
    }
    if (!reserve_solids(world, world->solidCount + 1)) {
        snprintf(errorBuffer, errorBufferSize, "out of memory adding cylinder");
        return 0;
    }

    size_t nextId = scene_next_id(scene);
    VmfSolid solid;
    memset(&solid, 0, sizeof(solid));
    solid.id = (int)nextId++;
    if (!fill_cylinder_sides(&solid, bounds, axis, segmentCount, &nextId, material)) {
        free(solid.sides);
        snprintf(errorBuffer, errorBufferSize, "out of memory building cylinder sides");
        return 0;
    }

    world->solids[world->solidCount] = solid;
    if (outEntityIndex) {
        *outEntityIndex = (size_t)(world - scene->entities);
    }
    if (outSolidIndex) {
        *outSolidIndex = world->solidCount;
    }
    world->solidCount += 1;
    return 1;
}

int vmf_scene_add_ramp_brush(VmfScene* scene,
                             Bounds3 bounds,
                             VmfBrushAxis axis,
                             VmfBrushAxis slopeAxis,
                             const char* material,
                             size_t* outEntityIndex,
                             size_t* outSolidIndex,
                             char* errorBuffer,
                             size_t errorBufferSize) {
    if (!scene) {
        snprintf(errorBuffer, errorBufferSize, "invalid scene pointer");
        return 0;
    }
    if (!validate_bounds(bounds)) {
        snprintf(errorBuffer, errorBufferSize, "invalid ramp bounds");
        return 0;
    }
    if (axis == slopeAxis || remaining_axis(axis, slopeAxis) < 0) {
        snprintf(errorBuffer, errorBufferSize, "invalid ramp axes");
        return 0;
    }

    VmfEntity* world = worldspawn_entity(scene);
    if (!world) {
        snprintf(errorBuffer, errorBufferSize, "scene is missing worldspawn");
        return 0;
    }
    if (!reserve_solids(world, world->solidCount + 1)) {
        snprintf(errorBuffer, errorBufferSize, "out of memory adding ramp");
        return 0;
    }

    size_t nextId = scene_next_id(scene);
    VmfSolid solid;
    memset(&solid, 0, sizeof(solid));
    solid.id = (int)nextId++;
    if (!fill_ramp_sides(&solid, bounds, axis, slopeAxis, &nextId, material)) {
        free_solid_contents(&solid);
        snprintf(errorBuffer, errorBufferSize, "out of memory building ramp sides");
        return 0;
    }

    world->solids[world->solidCount] = solid;
    if (outEntityIndex) {
        *outEntityIndex = (size_t)(world - scene->entities);
    }
    if (outSolidIndex) {
        *outSolidIndex = world->solidCount;
    }
    world->solidCount += 1;
    return 1;
}

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
                               size_t errorBufferSize) {
    if (!scene) {
        snprintf(errorBuffer, errorBufferSize, "invalid scene pointer");
        return 0;
    }
    if (!validate_bounds(bounds)) {
        snprintf(errorBuffer, errorBufferSize, "invalid arch bounds");
        return 0;
    }
    if (axis == runAxis || remaining_axis(axis, runAxis) < 0) {
        snprintf(errorBuffer, errorBufferSize, "invalid arch axes");
        return 0;
    }

    segmentCount = segmentCount < 2 ? 2 : segmentCount;
    if (thicknessRatio <= 0.01f || thicknessRatio >= 0.95f) {
        snprintf(errorBuffer, errorBufferSize, "invalid arch thickness");
        return 0;
    }

    VmfEntity* world = worldspawn_entity(scene);
    if (!world) {
        snprintf(errorBuffer, errorBufferSize, "scene is missing worldspawn");
        return 0;
    }
    if (!reserve_solids(world, world->solidCount + segmentCount)) {
        snprintf(errorBuffer, errorBufferSize, "out of memory adding arch");
        return 0;
    }

    int widthAxis = remaining_axis(axis, runAxis);
    float runMin = bounds.min.raw[runAxis];
    float runMax = bounds.max.raw[runAxis];
    float upMin = bounds.min.raw[axis];
    float upMax = bounds.max.raw[axis];
    float widthMin = bounds.min.raw[widthAxis];
    float widthMax = bounds.max.raw[widthAxis];
    float centerRun = (runMin + runMax) * 0.5f;
    float outerRunRadius = (runMax - runMin) * 0.5f;
    float outerUpRadius = upMax - upMin;
    float innerRunRadius = outerRunRadius * (1.0f - thicknessRatio);
    float innerUpRadius = outerUpRadius * (1.0f - thicknessRatio);
    if (innerRunRadius < 1.0f || innerUpRadius < 1.0f) {
        snprintf(errorBuffer, errorBufferSize, "arch thickness leaves no interior span");
        return 0;
    }

    size_t originalSolidCount = world->solidCount;
    size_t nextId = scene_next_id(scene);
    for (size_t segmentIndex = 0; segmentIndex < segmentCount; ++segmentIndex) {
        float angle0 = (float)M_PI * ((float)segmentIndex / (float)segmentCount);
        float angle1 = (float)M_PI * ((float)(segmentIndex + 1) / (float)segmentCount);
        float midAngle = (angle0 + angle1) * 0.5f;

        float outerRun0 = centerRun + cosf(angle0) * outerRunRadius;
        float outerUp0 = upMin + sinf(angle0) * outerUpRadius;
        float outerRun1 = centerRun + cosf(angle1) * outerRunRadius;
        float outerUp1 = upMin + sinf(angle1) * outerUpRadius;
        float innerRun0 = centerRun + cosf(angle0) * innerRunRadius;
        float innerUp0 = upMin + sinf(angle0) * innerUpRadius;
        float innerRun1 = centerRun + cosf(angle1) * innerRunRadius;
        float innerUp1 = upMin + sinf(angle1) * innerUpRadius;

        Vec3 outerStartMin = shaped_point_on_axes((int)runAxis, outerRun0, (int)axis, outerUp0, widthAxis, widthMin);
        Vec3 outerStartMax = shaped_point_on_axes((int)runAxis, outerRun0, (int)axis, outerUp0, widthAxis, widthMax);
        Vec3 outerEndMin = shaped_point_on_axes((int)runAxis, outerRun1, (int)axis, outerUp1, widthAxis, widthMin);
        Vec3 outerEndMax = shaped_point_on_axes((int)runAxis, outerRun1, (int)axis, outerUp1, widthAxis, widthMax);
        Vec3 innerStartMin = shaped_point_on_axes((int)runAxis, innerRun0, (int)axis, innerUp0, widthAxis, widthMin);
        Vec3 innerStartMax = shaped_point_on_axes((int)runAxis, innerRun0, (int)axis, innerUp0, widthAxis, widthMax);
        Vec3 innerEndMin = shaped_point_on_axes((int)runAxis, innerRun1, (int)axis, innerUp1, widthAxis, widthMin);
        Vec3 innerEndMax = shaped_point_on_axes((int)runAxis, innerRun1, (int)axis, innerUp1, widthAxis, widthMax);
        Vec3 interiorPoint = shaped_point_on_axes((int)runAxis,
                                                  centerRun + cosf(midAngle) * (outerRunRadius + innerRunRadius) * 0.5f,
                                                  (int)axis,
                                                  upMin + sinf(midAngle) * (outerUpRadius + innerUpRadius) * 0.5f,
                                                  widthAxis,
                                                  (widthMin + widthMax) * 0.5f);

        EditorSolidPlane planes[6];
        if (!set_plane_from_points(&planes[0], outerStartMin, outerStartMax, outerEndMax, interiorPoint, material) ||
            !set_plane_from_points(&planes[1], innerStartMin, innerEndMax, innerStartMax, interiorPoint, material) ||
            !set_plane_from_points(&planes[2], innerStartMin, outerStartMin, outerStartMax, interiorPoint, material) ||
            !set_plane_from_points(&planes[3], innerEndMin, outerEndMax, outerEndMin, interiorPoint, material) ||
            !set_plane_from_points(&planes[4], outerStartMin, outerEndMin, innerEndMin, interiorPoint, material) ||
            !set_plane_from_points(&planes[5], outerStartMax, innerEndMax, outerEndMax, interiorPoint, material)) {
            snprintf(errorBuffer, errorBufferSize, "failed to build arch segment planes");
            for (size_t cleanupIndex = originalSolidCount; cleanupIndex < world->solidCount; ++cleanupIndex) {
                free_solid_contents(&world->solids[cleanupIndex]);
            }
            world->solidCount = originalSolidCount;
            return 0;
        }

        VmfSolid solid;
        memset(&solid, 0, sizeof(solid));
        solid.id = (int)nextId++;
        if (!build_solid_from_planes(&solid, planes, 6, &nextId)) {
            free_solid_contents(&solid);
            snprintf(errorBuffer, errorBufferSize, "failed to build arch segment");
            for (size_t cleanupIndex = originalSolidCount; cleanupIndex < world->solidCount; ++cleanupIndex) {
                free_solid_contents(&world->solids[cleanupIndex]);
            }
            world->solidCount = originalSolidCount;
            return 0;
        }

        world->solids[world->solidCount++] = solid;
        if (outEntityIndex) {
            *outEntityIndex = (size_t)(world - scene->entities);
        }
        if (outSolidIndex) {
            *outSolidIndex = world->solidCount - 1;
        }
    }

    return 1;
}

int vmf_scene_delete_solid(VmfScene* scene,
                           size_t entityIndex,
                           size_t solidIndex,
                           char* errorBuffer,
                           size_t errorBufferSize) {
    if (!scene || entityIndex >= scene->entityCount || solidIndex >= scene->entities[entityIndex].solidCount) {
        snprintf(errorBuffer, errorBufferSize, "invalid delete brush request");
        return 0;
    }

    VmfEntity* entity = &scene->entities[entityIndex];
    VmfSolid* solid = &entity->solids[solidIndex];
    for (size_t sideIndex = 0; sideIndex < solid->sideCount; ++sideIndex) {
        free_side_contents(&solid->sides[sideIndex]);
    }
    free(solid->sides);

    for (size_t copyIndex = solidIndex + 1; copyIndex < entity->solidCount; ++copyIndex) {
        entity->solids[copyIndex - 1] = entity->solids[copyIndex];
    }
    entity->solidCount -= 1;
    if (entity->solidCount < entity->solidCapacity) {
        memset(&entity->solids[entity->solidCount], 0, sizeof(VmfSolid));
    }
    return 1;
}

int vmf_scene_delete_entity(VmfScene* scene,
                            size_t entityIndex,
                            char* errorBuffer,
                            size_t errorBufferSize) {
    if (!scene || entityIndex >= scene->entityCount) {
        snprintf(errorBuffer, errorBufferSize, "invalid delete entity request");
        return 0;
    }
    if (scene->entities[entityIndex].isWorld || scene->entities[entityIndex].kind == VmfEntityKindRoot) {
        snprintf(errorBuffer, errorBufferSize, "cannot delete root entity");
        return 0;
    }

    remove_entity_at(scene, entityIndex);
    return 1;
}

int vmf_scene_move_solid_to_entity(VmfScene* scene,
                                   size_t sourceEntityIndex,
                                   size_t sourceSolidIndex,
                                   size_t targetEntityIndex,
                                   size_t* outTargetSolidIndex,
                                   char* errorBuffer,
                                   size_t errorBufferSize) {
    if (!scene || sourceEntityIndex >= scene->entityCount || targetEntityIndex >= scene->entityCount) {
        snprintf(errorBuffer, errorBufferSize, "invalid move brush request");
        return 0;
    }
    if (sourceEntityIndex == targetEntityIndex) {
        snprintf(errorBuffer, errorBufferSize, "source and target entities are the same");
        return 0;
    }

    VmfEntity* sourceEntity = &scene->entities[sourceEntityIndex];
    VmfEntity* targetEntity = &scene->entities[targetEntityIndex];
    if (sourceSolidIndex >= sourceEntity->solidCount) {
        snprintf(errorBuffer, errorBufferSize, "invalid move brush request");
        return 0;
    }
    if (targetEntity->kind == VmfEntityKindLight) {
        snprintf(errorBuffer, errorBufferSize, "cannot add brush to light entity");
        return 0;
    }
    if (!reserve_solids(targetEntity, targetEntity->solidCount + 1)) {
        snprintf(errorBuffer, errorBufferSize, "out of memory moving brush");
        return 0;
    }

    VmfSolid movedSolid = sourceEntity->solids[sourceSolidIndex];
    for (size_t copyIndex = sourceSolidIndex + 1; copyIndex < sourceEntity->solidCount; ++copyIndex) {
        sourceEntity->solids[copyIndex - 1] = sourceEntity->solids[copyIndex];
    }
    sourceEntity->solidCount -= 1;
    if (sourceEntity->solidCount < sourceEntity->solidCapacity) {
        memset(&sourceEntity->solids[sourceEntity->solidCount], 0, sizeof(VmfSolid));
    }

    targetEntity->solids[targetEntity->solidCount] = movedSolid;
    if (outTargetSolidIndex) {
        *outTargetSolidIndex = targetEntity->solidCount;
    }
    targetEntity->solidCount += 1;
    return 1;
}

int vmf_scene_duplicate_solid(VmfScene* scene,
                              size_t entityIndex,
                              size_t solidIndex,
                              Vec3 offset,
                              size_t* outEntityIndex,
                              size_t* outSolidIndex,
                              char* errorBuffer,
                              size_t errorBufferSize) {
    if (!scene || entityIndex >= scene->entityCount || solidIndex >= scene->entities[entityIndex].solidCount) {
        snprintf(errorBuffer, errorBufferSize, "invalid duplicate brush request");
        return 0;
    }

    VmfEntity* entity = &scene->entities[entityIndex];
    if (!reserve_solids(entity, entity->solidCount + 1)) {
        snprintf(errorBuffer, errorBufferSize, "out of memory duplicating brush");
        return 0;
    }

    VmfSolid duplicate;
    if (!clone_solid(&entity->solids[solidIndex], &duplicate)) {
        snprintf(errorBuffer, errorBufferSize, "out of memory cloning brush");
        return 0;
    }

    size_t nextId = scene_next_id(scene);
    duplicate.id = (int)nextId++;
    for (size_t sideIndex = 0; sideIndex < duplicate.sideCount; ++sideIndex) {
        duplicate.sides[sideIndex].id = (int)nextId++;
        offset_side_geometry(&duplicate.sides[sideIndex], offset);
    }

    entity->solids[entity->solidCount] = duplicate;
    if (outEntityIndex) {
        *outEntityIndex = entityIndex;
    }
    if (outSolidIndex) {
        *outSolidIndex = entity->solidCount;
    }
    entity->solidCount += 1;
    return 1;
}

int vmf_scene_solid_bounds(const VmfScene* scene,
                           size_t entityIndex,
                           size_t solidIndex,
                           Bounds3* outBounds,
                           char* errorBuffer,
                           size_t errorBufferSize) {
    if (!scene || !outBounds || entityIndex >= scene->entityCount || solidIndex >= scene->entities[entityIndex].solidCount) {
        snprintf(errorBuffer, errorBufferSize, "invalid solid bounds request");
        return 0;
    }

    const VmfSolid* solid = &scene->entities[entityIndex].solids[solidIndex];
    Bounds3 bounds = bounds3_empty();
    Vec3 vertices[VMF_MAX_SOLID_VERTICES];
    size_t vertexCount = 0;
    if (collect_solid_vertices(solid, vertices, VMF_MAX_SOLID_VERTICES, &vertexCount) && vertexCount > 0) {
        for (size_t vertexIndex = 0; vertexIndex < vertexCount; ++vertexIndex) {
            bounds3_expand(&bounds, vertices[vertexIndex]);
        }
    } else {
        for (size_t sideIndex = 0; sideIndex < solid->sideCount; ++sideIndex) {
            for (size_t pointIndex = 0; pointIndex < 3; ++pointIndex) {
                bounds3_expand(&bounds, solid->sides[sideIndex].points[pointIndex]);
            }
        }
    }

    if (!bounds3_is_valid(bounds)) {
        snprintf(errorBuffer, errorBufferSize, "solid has no valid bounds");
        return 0;
    }
    *outBounds = bounds;
    return 1;
}

int vmf_scene_solid_vertices(const VmfScene* scene,
                             size_t entityIndex,
                             size_t solidIndex,
                             Vec3* outVertices,
                             size_t maxVertices,
                             size_t* outVertexCount,
                             char* errorBuffer,
                             size_t errorBufferSize) {
    if (!scene || !outVertices || !outVertexCount || entityIndex >= scene->entityCount || solidIndex >= scene->entities[entityIndex].solidCount) {
        snprintf(errorBuffer, errorBufferSize, "invalid solid vertex request");
        return 0;
    }

    if (!collect_solid_vertices(&scene->entities[entityIndex].solids[solidIndex], outVertices, maxVertices, outVertexCount)) {
        snprintf(errorBuffer, errorBufferSize, "solid vertex buffer too small");
        return 0;
    }
    return 1;
}

int vmf_scene_solid_vertex_refs(const VmfScene* scene,
                                size_t entityIndex,
                                size_t solidIndex,
                                VmfSolidVertex* outVertices,
                                size_t maxVertices,
                                size_t* outVertexCount,
                                char* errorBuffer,
                                size_t errorBufferSize) {
    if (!scene || !outVertices || !outVertexCount || entityIndex >= scene->entityCount || solidIndex >= scene->entities[entityIndex].solidCount) {
        snprintf(errorBuffer, errorBufferSize, "invalid solid vertex ref request");
        return 0;
    }

    if (!collect_solid_vertex_refs(&scene->entities[entityIndex].solids[solidIndex], outVertices, maxVertices, outVertexCount)) {
        snprintf(errorBuffer, errorBufferSize, "solid vertex ref buffer too small");
        return 0;
    }
    return 1;
}

int vmf_scene_solid_edges(const VmfScene* scene,
                          size_t entityIndex,
                          size_t solidIndex,
                          VmfSolidEdge* outEdges,
                          size_t maxEdges,
                          size_t* outEdgeCount,
                          char* errorBuffer,
                          size_t errorBufferSize) {
    if (!scene || !outEdges || !outEdgeCount || entityIndex >= scene->entityCount || solidIndex >= scene->entities[entityIndex].solidCount) {
        snprintf(errorBuffer, errorBufferSize, "invalid solid edge request");
        return 0;
    }

    if (!collect_solid_edges(&scene->entities[entityIndex].solids[solidIndex], outEdges, maxEdges, outEdgeCount)) {
        snprintf(errorBuffer, errorBufferSize, "solid edge buffer too small");
        return 0;
    }
    return 1;
}

int vmf_scene_translate_solid(VmfScene* scene,
                              size_t entityIndex,
                              size_t solidIndex,
                              Vec3 offset,
                              int textureLock,
                              char* errorBuffer,
                              size_t errorBufferSize) {
    if (!scene || entityIndex >= scene->entityCount || solidIndex >= scene->entities[entityIndex].solidCount) {
        snprintf(errorBuffer, errorBufferSize, "invalid solid move request");
        return 0;
    }

    VmfSolid* solid = &scene->entities[entityIndex].solids[solidIndex];
    for (size_t sideIndex = 0; sideIndex < solid->sideCount; ++sideIndex) {
        offset_side_geometry(&solid->sides[sideIndex], offset);
        if (textureLock != 0) {
            offset_side_texture_lock(&solid->sides[sideIndex], offset);
        }
    }
    return 1;
}

int vmf_scene_move_solid_vertex(VmfScene* scene,
                                size_t entityIndex,
                                size_t solidIndex,
                                size_t vertexIndex,
                                Vec3 newPosition,
                                char* errorBuffer,
                                size_t errorBufferSize) {
    if (!scene || entityIndex >= scene->entityCount || solidIndex >= scene->entities[entityIndex].solidCount) {
        snprintf(errorBuffer, errorBufferSize, "invalid vertex edit request");
        return 0;
    }

    VmfSolid* solid = &scene->entities[entityIndex].solids[solidIndex];
    if (solid_has_displacement(solid)) {
        snprintf(errorBuffer, errorBufferSize, "vertex editing displacements is not supported");
        return 0;
    }

    VmfSolid original;
    memset(&original, 0, sizeof(original));
    if (!clone_solid(solid, &original)) {
        snprintf(errorBuffer, errorBufferSize, "out of memory preparing vertex edit");
        return 0;
    }

    VmfSolidVertex vertices[VMF_MAX_SOLID_VERTICES];
    size_t vertexCount = 0;
    if (!collect_solid_vertex_refs(solid, vertices, VMF_MAX_SOLID_VERTICES, &vertexCount) || vertexIndex >= vertexCount) {
        free_solid_contents(&original);
        snprintf(errorBuffer, errorBufferSize, "invalid solid vertex index");
        return 0;
    }

    VmfSolidVertex vertex = vertices[vertexIndex];
    if (vertex.sideIndexCount < 3) {
        free_solid_contents(&original);
        snprintf(errorBuffer, errorBufferSize, "vertex does not have enough incident planes");
        return 0;
    }

    EditorFacePolygon faces[128];
    size_t faceCount = 0;
    if (!collect_solid_face_polygons(solid, faces, 128, &faceCount) || faceCount < 4) {
        free_solid_contents(&original);
        snprintf(errorBuffer, errorBufferSize, "failed to collect solid face polygons");
        return 0;
    }

    EditorSolidPlane editedPlanes[128];
    for (size_t faceIndex = 0; faceIndex < faceCount; ++faceIndex) {
        editedPlanes[faceIndex] = faces[faceIndex].face;
        ssize_t movedPointIndex = polygon_vertex_index(&faces[faceIndex], vertex.position);
        if (movedPointIndex < 0) {
            continue;
        }

        size_t currentIndex = (size_t)movedPointIndex;
        size_t previousIndex = (currentIndex + faces[faceIndex].pointCount - 1) % faces[faceIndex].pointCount;
        size_t nextIndex = (currentIndex + 1) % faces[faceIndex].pointCount;
        if (!plane_from_points_matching_reference(faces[faceIndex].points[previousIndex],
                                                  newPosition,
                                                  faces[faceIndex].points[nextIndex],
                                                  faces[faceIndex].face.plane.normal,
                                                  &editedPlanes[faceIndex].plane)) {
            free_solid_contents(&original);
            snprintf(errorBuffer, errorBufferSize, "vertex move would create a degenerate face");
            return 0;
        }
    }

    size_t nextId = scene_next_id(scene);
    if (!rebuild_solid_from_planes_checked(solid, editedPlanes, faceCount, &nextId)) {
        replace_solid_contents(solid, &original);
        snprintf(errorBuffer, errorBufferSize, "vertex move produced invalid brush");
        return 0;
    }

    Bounds3 bounds = bounds3_empty();
    size_t rebuiltVertexCount = 0;
    int foundMovedVertex = 0;
    if (!collect_solid_vertex_refs(solid, vertices, VMF_MAX_SOLID_VERTICES, &rebuiltVertexCount) || rebuiltVertexCount < 4 ||
        !vmf_scene_solid_bounds(scene, entityIndex, solidIndex, &bounds, errorBuffer, errorBufferSize) || !bounds3_is_valid(bounds)) {
        replace_solid_contents(solid, &original);
        snprintf(errorBuffer, errorBufferSize, "vertex move produced invalid brush");
        return 0;
    }

    for (size_t rebuiltIndex = 0; rebuiltIndex < rebuiltVertexCount; ++rebuiltIndex) {
        if (vec3_length(vec3_sub(vertices[rebuiltIndex].position, newPosition)) < 0.1f) {
            foundMovedVertex = 1;
            break;
        }
    }
    if (!foundMovedVertex) {
        replace_solid_contents(solid, &original);
        snprintf(errorBuffer, errorBufferSize, "vertex move would break convex brush validity");
        return 0;
    }

    free_solid_contents(&original);
    return 1;
}

static int plane_from_polygon_matching_reference(const Vec3* points,
                                                 size_t pointCount,
                                                 Vec3 referenceNormal,
                                                 EditorPlane* outPlane) {
    for (size_t i = 0; i < pointCount; ++i) {
        for (size_t j = i + 1; j < pointCount; ++j) {
            for (size_t k = j + 1; k < pointCount; ++k) {
                if (plane_from_points_matching_reference(points[i], points[j], points[k], referenceNormal, outPlane)) {
                    return 1;
                }
            }
        }
    }
    return 0;
}

int vmf_scene_move_solid_vertices(VmfScene* scene,
                                  size_t entityIndex,
                                  size_t solidIndex,
                                  const VmfVertexMove* moves,
                                  size_t moveCount,
                                  char* errorBuffer,
                                  size_t errorBufferSize) {
    if (!scene || entityIndex >= scene->entityCount || solidIndex >= scene->entities[entityIndex].solidCount || !moves || moveCount == 0) {
        snprintf(errorBuffer, errorBufferSize, "invalid vertex edit request");
        return 0;
    }

    VmfSolid* solid = &scene->entities[entityIndex].solids[solidIndex];
    if (solid_has_displacement(solid)) {
        snprintf(errorBuffer, errorBufferSize, "vertex editing displacements is not supported");
        return 0;
    }

    VmfSolidVertex vertices[VMF_MAX_SOLID_VERTICES];
    size_t vertexCount = 0;
    if (!collect_solid_vertex_refs(solid, vertices, VMF_MAX_SOLID_VERTICES, &vertexCount)) {
        snprintf(errorBuffer, errorBufferSize, "failed to collect solid vertices");
        return 0;
    }

    for (size_t moveIndex = 0; moveIndex < moveCount; ++moveIndex) {
        if (moves[moveIndex].vertexIndex >= vertexCount) {
            snprintf(errorBuffer, errorBufferSize, "invalid vertex index in move list");
            return 0;
        }
    }

    VmfSolid original;
    memset(&original, 0, sizeof(original));
    if (!clone_solid(solid, &original)) {
        snprintf(errorBuffer, errorBufferSize, "out of memory preparing vertex edit");
        return 0;
    }

    EditorFacePolygon faces[128];
    size_t faceCount = 0;
    if (!collect_solid_face_polygons(solid, faces, 128, &faceCount) || faceCount < 4) {
        free_solid_contents(&original);
        snprintf(errorBuffer, errorBufferSize, "failed to collect solid face polygons");
        return 0;
    }

    EditorSolidPlane editedPlanes[128];
    for (size_t faceIndex = 0; faceIndex < faceCount; ++faceIndex) {
        editedPlanes[faceIndex] = faces[faceIndex].face;

        Vec3 updatedPoints[256];
        size_t pointCount = faces[faceIndex].pointCount;
        if (pointCount > 256) {
            pointCount = 256;
        }
        memcpy(updatedPoints, faces[faceIndex].points, pointCount * sizeof(Vec3));

        int anyMoved = 0;
        for (size_t pIdx = 0; pIdx < pointCount; ++pIdx) {
            for (size_t mIdx = 0; mIdx < moveCount; ++mIdx) {
                if (point_equals(updatedPoints[pIdx], vertices[moves[mIdx].vertexIndex].position)) {
                    updatedPoints[pIdx] = moves[mIdx].newPosition;
                    anyMoved = 1;
                }
            }
        }

        if (!anyMoved) {
            continue;
        }

        if (!plane_from_polygon_matching_reference(updatedPoints, pointCount,
                                                   faces[faceIndex].face.plane.normal,
                                                   &editedPlanes[faceIndex].plane)) {
            free_solid_contents(&original);
            snprintf(errorBuffer, errorBufferSize, "vertex move would create a degenerate face");
            return 0;
        }
    }

    size_t nextId = scene_next_id(scene);
    if (!rebuild_solid_from_planes_checked(solid, editedPlanes, faceCount, &nextId)) {
        replace_solid_contents(solid, &original);
        snprintf(errorBuffer, errorBufferSize, "vertex move produced invalid brush");
        return 0;
    }

    VmfSolidVertex rebuiltVertices[VMF_MAX_SOLID_VERTICES];
    size_t rebuiltVertexCount = 0;
    Bounds3 bounds = bounds3_empty();
    if (!collect_solid_vertex_refs(solid, rebuiltVertices, VMF_MAX_SOLID_VERTICES, &rebuiltVertexCount) ||
        rebuiltVertexCount < 4 ||
        !vmf_scene_solid_bounds(scene, entityIndex, solidIndex, &bounds, errorBuffer, errorBufferSize) ||
        !bounds3_is_valid(bounds)) {
        replace_solid_contents(solid, &original);
        snprintf(errorBuffer, errorBufferSize, "vertex move produced invalid brush");
        return 0;
    }

    for (size_t mIdx = 0; mIdx < moveCount; ++mIdx) {
        int found = 0;
        for (size_t vIdx = 0; vIdx < rebuiltVertexCount && !found; ++vIdx) {
            if (vec3_length(vec3_sub(rebuiltVertices[vIdx].position, moves[mIdx].newPosition)) < 0.1f) {
                found = 1;
            }
        }
        if (!found) {
            replace_solid_contents(solid, &original);
            snprintf(errorBuffer, errorBufferSize, "vertex move would break convex brush validity");
            return 0;
        }
    }

    free_solid_contents(&original);
    return 1;
}

int vmf_scene_check_vertex_moves(const VmfScene* scene,
                                  size_t entityIndex,
                                  size_t solidIndex,
                                  const VmfVertexMove* moves,
                                  size_t moveCount,
                                  char* errorBuffer,
                                  size_t errorBufferSize) {
    if (!scene || entityIndex >= scene->entityCount ||
        solidIndex >= scene->entities[entityIndex].solidCount ||
        moveCount == 0) {
        return 1; /* nothing to check — trivially valid */
    }

    /* Clone just the target solid onto the stack (sides are heap-allocated). */
    VmfSolid test;
    memset(&test, 0, sizeof(test));
    if (!clone_solid(&scene->entities[entityIndex].solids[solidIndex], &test)) {
        if (errorBuffer) snprintf(errorBuffer, errorBufferSize, "out of memory for validity check");
        return 0;
    }

    /* Construct a minimal fake scene wrapping the test solid. */
    VmfEntity fakeEntity;
    memset(&fakeEntity, 0, sizeof(fakeEntity));
    fakeEntity.solids = &test;
    fakeEntity.solidCount = 1;
    fakeEntity.solidCapacity = 1;
    fakeEntity.isWorld = 1;

    VmfScene fakeScene;
    memset(&fakeScene, 0, sizeof(fakeScene));
    fakeScene.entities = &fakeEntity;
    fakeScene.entityCount = 1;

    char localErr[256] = { 0 };
    int result = vmf_scene_move_solid_vertices(&fakeScene, 0, 0, moves, moveCount,
                                               localErr, sizeof(localErr));

    /* Free whatever sides the test solid owns after the check. */
    free_solid_contents(&test);

    if (!result && errorBuffer) {
        snprintf(errorBuffer, errorBufferSize, "%s", localErr);
    }
    return result;
}

int vmf_scene_move_solid_edge(VmfScene* scene,
                              size_t entityIndex,
                              size_t solidIndex,
                              size_t firstSideIndex,
                              size_t secondSideIndex,
                              Vec3 offset,
                              char* errorBuffer,
                              size_t errorBufferSize) {
    if (!scene || entityIndex >= scene->entityCount || solidIndex >= scene->entities[entityIndex].solidCount) {
        snprintf(errorBuffer, errorBufferSize, "invalid edge edit request");
        return 0;
    }

    VmfSolid* solid = &scene->entities[entityIndex].solids[solidIndex];
    if (solid_has_displacement(solid)) {
        snprintf(errorBuffer, errorBufferSize, "edge editing displacements is not supported");
        return 0;
    }

    if (firstSideIndex == secondSideIndex || firstSideIndex >= solid->sideCount || secondSideIndex >= solid->sideCount) {
        snprintf(errorBuffer, errorBufferSize, "invalid solid edge");
        return 0;
    }

    if (firstSideIndex > secondSideIndex) {
        size_t tmp = firstSideIndex;
        firstSideIndex = secondSideIndex;
        secondSideIndex = tmp;
    }

    VmfSolid original;
    memset(&original, 0, sizeof(original));
    if (!clone_solid(solid, &original)) {
        snprintf(errorBuffer, errorBufferSize, "out of memory preparing edge edit");
        return 0;
    }

    VmfSolidEdge edges[VMF_MAX_SOLID_EDGES];
    size_t edgeCount = 0;
    if (!collect_solid_edges(solid, edges, VMF_MAX_SOLID_EDGES, &edgeCount)) {
        free_solid_contents(&original);
        snprintf(errorBuffer, errorBufferSize, "edge buffer too small");
        return 0;
    }

    int edgeFound = 0;
    for (size_t edgeIndex = 0; edgeIndex < edgeCount; ++edgeIndex) {
        if (edges[edgeIndex].sideIndices[0] == firstSideIndex && edges[edgeIndex].sideIndices[1] == secondSideIndex) {
            edgeFound = 1;
            break;
        }
    }
    if (!edgeFound) {
        free_solid_contents(&original);
        snprintf(errorBuffer, errorBufferSize, "invalid solid edge");
        return 0;
    }

    EditorFacePolygon faces[128];
    size_t faceCount = 0;
    if (!collect_solid_face_polygons(solid, faces, 128, &faceCount) || faceCount < 4) {
        free_solid_contents(&original);
        snprintf(errorBuffer, errorBufferSize, "failed to collect solid face polygons");
        return 0;
    }

    Vec3 movedStart = vec3_add(edges[0].start, offset);
    Vec3 movedEnd = vec3_add(edges[0].end, offset);
    for (size_t edgeIndex = 0; edgeIndex < edgeCount; ++edgeIndex) {
        if (edges[edgeIndex].sideIndices[0] == firstSideIndex && edges[edgeIndex].sideIndices[1] == secondSideIndex) {
            movedStart = vec3_add(edges[edgeIndex].start, offset);
            movedEnd = vec3_add(edges[edgeIndex].end, offset);
            break;
        }
    }

    EditorSolidPlane editedPlanes[128];
    for (size_t faceIndex = 0; faceIndex < faceCount; ++faceIndex) {
        editedPlanes[faceIndex] = faces[faceIndex].face;
        if (faceIndex != firstSideIndex && faceIndex != secondSideIndex) {
            continue;
        }

        ssize_t startIndex = polygon_vertex_index(&faces[faceIndex], edges[0].start);
        ssize_t endIndex = polygon_vertex_index(&faces[faceIndex], edges[0].end);
        for (size_t edgeIndex = 0; edgeIndex < edgeCount; ++edgeIndex) {
            if (edges[edgeIndex].sideIndices[0] == firstSideIndex && edges[edgeIndex].sideIndices[1] == secondSideIndex) {
                startIndex = polygon_vertex_index(&faces[faceIndex], edges[edgeIndex].start);
                endIndex = polygon_vertex_index(&faces[faceIndex], edges[edgeIndex].end);
                break;
            }
        }
        if (startIndex < 0 || endIndex < 0) {
            free_solid_contents(&original);
            snprintf(errorBuffer, errorBufferSize, "edge move could not locate face vertices");
            return 0;
        }

        Vec3 anchor = faces[faceIndex].points[0];
        for (size_t pointIndex = 0; pointIndex < faces[faceIndex].pointCount; ++pointIndex) {
            if (!point_equals(faces[faceIndex].points[pointIndex], edges[0].start) && !point_equals(faces[faceIndex].points[pointIndex], edges[0].end)) {
                anchor = faces[faceIndex].points[pointIndex];
                break;
            }
        }
        for (size_t edgeIndex = 0; edgeIndex < edgeCount; ++edgeIndex) {
            if (edges[edgeIndex].sideIndices[0] == firstSideIndex && edges[edgeIndex].sideIndices[1] == secondSideIndex) {
                for (size_t pointIndex = 0; pointIndex < faces[faceIndex].pointCount; ++pointIndex) {
                    if (!point_equals(faces[faceIndex].points[pointIndex], edges[edgeIndex].start) && !point_equals(faces[faceIndex].points[pointIndex], edges[edgeIndex].end)) {
                        anchor = faces[faceIndex].points[pointIndex];
                        break;
                    }
                }
                break;
            }
        }

        if (!plane_from_points_matching_reference(movedStart,
                                                  movedEnd,
                                                  anchor,
                                                  faces[faceIndex].face.plane.normal,
                                                  &editedPlanes[faceIndex].plane)) {
            free_solid_contents(&original);
            snprintf(errorBuffer, errorBufferSize, "edge move would create a degenerate face");
            return 0;
        }
    }

    size_t nextId = scene_next_id(scene);
    if (!rebuild_solid_from_planes_checked(solid, editedPlanes, faceCount, &nextId)) {
        replace_solid_contents(solid, &original);
        snprintf(errorBuffer, errorBufferSize, "edge move produced invalid brush");
        return 0;
    }

    Bounds3 bounds = bounds3_empty();
    VmfSolidVertex vertices[VMF_MAX_SOLID_VERTICES];
    size_t vertexCount = 0;
    if (!collect_solid_vertex_refs(solid, vertices, VMF_MAX_SOLID_VERTICES, &vertexCount) || vertexCount < 4 ||
        !vmf_scene_solid_bounds(scene, entityIndex, solidIndex, &bounds, errorBuffer, errorBufferSize) || !bounds3_is_valid(bounds)) {
        replace_solid_contents(solid, &original);
        snprintf(errorBuffer, errorBufferSize, "edge move produced invalid brush");
        return 0;
    }

    free_solid_contents(&original);
    return 1;
}

int vmf_scene_split_solid_by_plane(VmfScene* scene,
                                   size_t entityIndex,
                                   size_t solidIndex,
                                   Vec3 planeNormal,
                                   float planeDistance,
                                   VmfClipKeepMode keepMode,
                                   const char* clipMaterial,
                                   size_t* outNewSolidIndex,
                                   char* errorBuffer,
                                   size_t errorBufferSize) {
    if (!scene || entityIndex >= scene->entityCount || solidIndex >= scene->entities[entityIndex].solidCount) {
        snprintf(errorBuffer, errorBufferSize, "invalid clip request");
        return 0;
    }

    VmfEntity* entity = &scene->entities[entityIndex];
    VmfSolid* source = &entity->solids[solidIndex];
    if (solid_has_displacement(source)) {
        snprintf(errorBuffer, errorBufferSize, "clipping displacements is not supported");
        return 0;
    }

    planeNormal = vec3_normalize(planeNormal);
    if (vec3_length(planeNormal) < 1e-5f) {
        snprintf(errorBuffer, errorBufferSize, "invalid clip plane");
        return 0;
    }

    VmfSolidVertex vertices[VMF_MAX_SOLID_VERTICES];
    size_t vertexCount = 0;
    if (!collect_solid_vertex_refs(source, vertices, VMF_MAX_SOLID_VERTICES, &vertexCount) || vertexCount == 0) {
        snprintf(errorBuffer, errorBufferSize, "brush has no clip vertices");
        return 0;
    }

    int hasFront = 0;
    int hasBack = 0;
    for (size_t vertexIndex = 0; vertexIndex < vertexCount; ++vertexIndex) {
        float side = vec3_dot(planeNormal, vertices[vertexIndex].position) - planeDistance;
        if (side > 0.05f) {
            hasFront = 1;
        } else if (side < -0.05f) {
            hasBack = 1;
        }
    }
    if (!hasFront || !hasBack) {
        snprintf(errorBuffer, errorBufferSize, "clip plane does not split the selected brush");
        return 0;
    }

    EditorSolidPlane sourcePlanes[129];
    size_t sourcePlaneCount = 0;
    if (!collect_solid_planes(source, sourcePlanes, 129, &sourcePlaneCount)) {
        snprintf(errorBuffer, errorBufferSize, "failed to collect brush planes");
        return 0;
    }

    size_t nextId = scene_next_id(scene);
    EditorSolidPlane frontPlanes[130];
    EditorSolidPlane backPlanes[130];
    memcpy(frontPlanes, sourcePlanes, sourcePlaneCount * sizeof(EditorSolidPlane));
    memcpy(backPlanes, sourcePlanes, sourcePlaneCount * sizeof(EditorSolidPlane));
    frontPlanes[sourcePlaneCount].plane.normal = planeNormal;
    frontPlanes[sourcePlaneCount].plane.distance = planeDistance;
    assign_material(frontPlanes[sourcePlaneCount].material, clipMaterial);
    frontPlanes[sourcePlaneCount].sideId = (int)nextId++;
    backPlanes[sourcePlaneCount].plane.normal = vec3_scale(planeNormal, -1.0f);
    backPlanes[sourcePlaneCount].plane.distance = -planeDistance;
    assign_material(backPlanes[sourcePlaneCount].material, clipMaterial);
    backPlanes[sourcePlaneCount].sideId = (int)nextId++;

    VmfSolid frontSolid;
    VmfSolid backSolid;
    memset(&frontSolid, 0, sizeof(frontSolid));
    memset(&backSolid, 0, sizeof(backSolid));
    frontSolid.id = source->id;
    backSolid.id = (int)nextId++;

    if (!build_solid_from_planes(&frontSolid, frontPlanes, sourcePlaneCount + 1, &nextId) ||
        !build_solid_from_planes(&backSolid, backPlanes, sourcePlaneCount + 1, &nextId)) {
        for (size_t sideIndex = 0; sideIndex < frontSolid.sideCount; ++sideIndex) {
            free_side_contents(&frontSolid.sides[sideIndex]);
        }
        free(frontSolid.sides);
        for (size_t sideIndex = 0; sideIndex < backSolid.sideCount; ++sideIndex) {
            free_side_contents(&backSolid.sides[sideIndex]);
        }
        free(backSolid.sides);
        snprintf(errorBuffer, errorBufferSize, "clip plane produced an invalid brush split");
        return 0;
    }

    if (keepMode == VmfClipKeepModeBoth && !reserve_solids(entity, entity->solidCount + 1)) {
        for (size_t sideIndex = 0; sideIndex < frontSolid.sideCount; ++sideIndex) {
            free_side_contents(&frontSolid.sides[sideIndex]);
        }
        free(frontSolid.sides);
        for (size_t sideIndex = 0; sideIndex < backSolid.sideCount; ++sideIndex) {
            free_side_contents(&backSolid.sides[sideIndex]);
        }
        free(backSolid.sides);
        snprintf(errorBuffer, errorBufferSize, "out of memory adding clipped brush");
        return 0;
    }

    source = &entity->solids[solidIndex];
    if (keepMode == VmfClipKeepModeA) {
        replace_solid_contents(source, &backSolid);
        free_solid_contents(&frontSolid);
        if (outNewSolidIndex) {
            *outNewSolidIndex = solidIndex;
        }
        return 1;
    }
    if (keepMode == VmfClipKeepModeB) {
        replace_solid_contents(source, &frontSolid);
        free_solid_contents(&backSolid);
        if (outNewSolidIndex) {
            *outNewSolidIndex = solidIndex;
        }
        return 1;
    }

    replace_solid_contents(source, &frontSolid);
    entity->solids[entity->solidCount] = backSolid;
    if (outNewSolidIndex) {
        *outNewSolidIndex = entity->solidCount;
    }
    entity->solidCount += 1;
    return 1;
}

int vmf_scene_set_solid_bounds(VmfScene* scene,
                               size_t entityIndex,
                               size_t solidIndex,
                               Bounds3 bounds,
                               char* errorBuffer,
                               size_t errorBufferSize) {
    if (!scene || entityIndex >= scene->entityCount || solidIndex >= scene->entities[entityIndex].solidCount) {
        snprintf(errorBuffer, errorBufferSize, "invalid solid edit request");
        return 0;
    }
    if (!validate_resize_bounds(bounds)) {
        snprintf(errorBuffer, errorBufferSize, "invalid edited brush bounds");
        return 0;
    }

    Bounds3 sourceBounds = bounds3_empty();
    if (!vmf_scene_solid_bounds(scene, entityIndex, solidIndex, &sourceBounds, errorBuffer, errorBufferSize)) {
        return 0;
    }

    VmfSolid* solid = &scene->entities[entityIndex].solids[solidIndex];
    for (size_t sideIndex = 0; sideIndex < solid->sideCount; ++sideIndex) {
        resize_side_geometry(&solid->sides[sideIndex], sourceBounds, bounds);
    }
    return 1;
}

int vmf_scene_set_block_solid_bounds(VmfScene* scene,
                                     size_t entityIndex,
                                     size_t solidIndex,
                                     Bounds3 bounds,
                                     char* errorBuffer,
                                     size_t errorBufferSize) {
    return vmf_scene_set_solid_bounds(scene, entityIndex, solidIndex, bounds, errorBuffer, errorBufferSize);
}

int vmf_scene_set_solid_material(VmfScene* scene,
                                 size_t entityIndex,
                                 size_t solidIndex,
                                 const char* material,
                                 char* errorBuffer,
                                 size_t errorBufferSize) {
    if (!scene || entityIndex >= scene->entityCount || solidIndex >= scene->entities[entityIndex].solidCount) {
        snprintf(errorBuffer, errorBufferSize, "invalid brush material request");
        return 0;
    }

    VmfSolid* solid = &scene->entities[entityIndex].solids[solidIndex];
    for (size_t sideIndex = 0; sideIndex < solid->sideCount; ++sideIndex) {
        assign_material(solid->sides[sideIndex].material, material);
    }
    return 1;
}

int vmf_scene_set_side_material(VmfScene* scene,
                                size_t entityIndex,
                                size_t solidIndex,
                                size_t sideIndex,
                                const char* material,
                                char* errorBuffer,
                                size_t errorBufferSize) {
    if (!scene || entityIndex >= scene->entityCount || solidIndex >= scene->entities[entityIndex].solidCount ||
        sideIndex >= scene->entities[entityIndex].solids[solidIndex].sideCount) {
        snprintf(errorBuffer, errorBufferSize, "invalid face material request");
        return 0;
    }

    assign_material(scene->entities[entityIndex].solids[solidIndex].sides[sideIndex].material, material);
    return 1;
}

int vmf_scene_set_side_texture_transform(VmfScene* scene,
                                         size_t entityIndex,
                                         size_t solidIndex,
                                         size_t sideIndex,
                                         float uoffset,
                                         float voffset,
                                         float uscale,
                                         float vscale,
                                         char* errorBuffer,
                                         size_t errorBufferSize) {
    VmfSide* side = NULL;

    if (!validate_texture_side_request(scene, entityIndex, solidIndex, sideIndex, NULL, &side, errorBuffer, errorBufferSize)) {
        return 0;
    }
    if (fabsf(uscale) < 1e-5f || fabsf(vscale) < 1e-5f) {
        snprintf(errorBuffer, errorBufferSize, "texture scale cannot be zero");
        return 0;
    }

    side->uoffset = uoffset;
    side->voffset = voffset;
    side->uscale = uscale;
    side->vscale = vscale;
    normalize_side_uv_frame(side);
    return 1;
}

int vmf_scene_rotate_side_texture(VmfScene* scene,
                                  size_t entityIndex,
                                  size_t solidIndex,
                                  size_t sideIndex,
                                  float degrees,
                                  char* errorBuffer,
                                  size_t errorBufferSize) {
    VmfSide* side = NULL;
    Vec3 edgeA;
    Vec3 edgeB;
    Vec3 normal;
    float radians;

    if (!validate_texture_side_request(scene, entityIndex, solidIndex, sideIndex, NULL, &side, errorBuffer, errorBufferSize)) {
        return 0;
    }

    edgeA = vec3_sub(side->points[1], side->points[0]);
    edgeB = vec3_sub(side->points[2], side->points[0]);
    normal = vec3_normalize(vec3_cross(edgeA, edgeB));
    if (vec3_length(normal) < 1e-5f) {
        snprintf(errorBuffer, errorBufferSize, "invalid face for texture rotation");
        return 0;
    }

    if (vec3_length(side->uaxis) < 1e-5f || vec3_length(side->vaxis) < 1e-5f) {
        default_face_wrap_axes(normal, &side->uaxis, &side->vaxis);
    }

    radians = degrees * (float)M_PI / 180.0f;
    side->uaxis = rotate_vector_around_axis(side->uaxis, normal, radians);
    side->vaxis = rotate_vector_around_axis(side->vaxis, normal, radians);
    normalize_side_uv_frame(side);
    return 1;
}

int vmf_scene_flip_side_texture(VmfScene* scene,
                                size_t entityIndex,
                                size_t solidIndex,
                                size_t sideIndex,
                                int flipU,
                                int flipV,
                                char* errorBuffer,
                                size_t errorBufferSize) {
    VmfSide* side = NULL;

    if (!validate_texture_side_request(scene, entityIndex, solidIndex, sideIndex, NULL, &side, errorBuffer, errorBufferSize)) {
        return 0;
    }

    if (flipU != 0) {
        side->uscale = -(fabsf(side->uscale) > 1e-5f ? side->uscale : 0.25f);
    }
    if (flipV != 0) {
        side->vscale = -(fabsf(side->vscale) > 1e-5f ? side->vscale : 0.25f);
    }
    return 1;
}

int vmf_scene_justify_side_texture(VmfScene* scene,
                                   size_t entityIndex,
                                   size_t solidIndex,
                                   size_t sideIndex,
                                   VmfTextureJustifyMode mode,
                                   float textureWidth,
                                   float textureHeight,
                                   char* errorBuffer,
                                   size_t errorBufferSize) {
    VmfSolid* solid = NULL;
    VmfSide* side = NULL;
    EditorFacePolygon face;
    float minU;
    float maxU;
    float minV;
    float maxV;
    float uSign;
    float vSign;

    if (!validate_texture_side_request(scene, entityIndex, solidIndex, sideIndex, &solid, &side, errorBuffer, errorBufferSize)) {
        return 0;
    }
    if (textureWidth <= 0.0f || textureHeight <= 0.0f) {
        snprintf(errorBuffer, errorBufferSize, "texture size must be positive for justify");
        return 0;
    }
    if (!collect_face_polygon_for_side(solid, sideIndex, &face)) {
        snprintf(errorBuffer, errorBufferSize, "failed to collect face polygon for texture justify");
        return 0;
    }

    if (vec3_length(side->uaxis) < 1e-5f || vec3_length(side->vaxis) < 1e-5f) {
        default_face_wrap_axes(face.face.plane.normal, &side->uaxis, &side->vaxis);
    }
    normalize_side_uv_frame(side);
    projected_face_bounds(&face, side->uaxis, side->vaxis, &minU, &maxU, &minV, &maxV);

    uSign = side->uscale < 0.0f ? -1.0f : 1.0f;
    vSign = side->vscale < 0.0f ? -1.0f : 1.0f;
    if (mode == VmfTextureJustifyFit) {
        side->uscale = uSign * fmaxf(2.0f * (maxU - minU) / textureWidth, 1e-4f);
        side->vscale = vSign * fmaxf(2.0f * (maxV - minV) / textureHeight, 1e-4f);
    } else {
        if (fabsf(side->uscale) < 1e-5f) side->uscale = uSign * 0.25f;
        if (fabsf(side->vscale) < 1e-5f) side->vscale = vSign * 0.25f;
    }

    switch (mode) {
        case VmfTextureJustifyFit:
            side->uoffset = -minU;
            side->voffset = -minV;
            break;
        case VmfTextureJustifyLeft:
            side->uoffset = -minU;
            break;
        case VmfTextureJustifyRight:
            side->uoffset = textureWidth * side->uscale * 0.5f - maxU;
            break;
        case VmfTextureJustifyTop:
            side->voffset = -minV;
            break;
        case VmfTextureJustifyBottom:
            side->voffset = textureHeight * side->vscale * 0.5f - maxV;
            break;
        case VmfTextureJustifyCenter:
            side->uoffset = 0.5f * (textureWidth * side->uscale * 0.5f - (minU + maxU));
            side->voffset = 0.5f * (textureHeight * side->vscale * 0.5f - (minV + maxV));
            break;
        default:
            snprintf(errorBuffer, errorBufferSize, "unsupported texture justify mode");
            return 0;
    }

    return 1;
}

int vmf_scene_world_align_side(VmfScene* scene,
                               size_t entityIndex,
                               size_t solidIndex,
                               size_t sideIndex,
                               char* errorBuffer,
                               size_t errorBufferSize) {
    if (!scene || entityIndex >= scene->entityCount ||
        solidIndex >= scene->entities[entityIndex].solidCount ||
        sideIndex >= scene->entities[entityIndex].solids[solidIndex].sideCount) {
        snprintf(errorBuffer, errorBufferSize, "invalid world-align request");
        return 0;
    }
    VmfSide* side = &scene->entities[entityIndex].solids[solidIndex].sides[sideIndex];
    /* Recompute the face normal from the three defining points, then pick
       world-axis-aligned U/V axes using the same dominant-axis scheme as
       setup_side.  Offsets are reset to 0 so the texture is anchored to
       the world origin, giving contiguous mapping across adjacent faces. */
    Vec3 edgeA = vec3_sub(side->points[1], side->points[0]);
    Vec3 edgeB = vec3_sub(side->points[2], side->points[0]);
    Vec3 normal = vec3_normalize(vec3_cross(edgeA, edgeB));
    /* Face-projected UV: derive U/V axes from the face normal so that V always
       points toward the sky along the face surface and U is the perpendicular
       horizontal direction.  This gives continuous cross-face tiling for any
       face orientation, not just axis-aligned walls. */
    Vec3 world_up = vec3_make(0.0f, 0.0f, 1.0f);
    float dot_up = vec3_dot(normal, world_up);
    if (fabsf(dot_up) >= 0.999f) {
        /* Horizontal face (floor/ceiling): use fixed world axes */
        side->uaxis = vec3_make(1.0f, 0.0f, 0.0f);
        side->vaxis = vec3_make(0.0f, dot_up > 0.0f ? -1.0f : 1.0f, 0.0f);
    } else {
        /* Non-horizontal face: project world_up onto the face plane to get
           the "sky direction" along the face, then derive both axes. */
        Vec3 sky_on_face = vec3_normalize(
            vec3_sub(world_up, vec3_scale(normal, dot_up)));
        /* V points toward sky: negate sky_on_face so V decreases toward sky
           (low V = top-of-texture = sky-end of wall). */
        side->vaxis = vec3_make(-sky_on_face.raw[0],
                                -sky_on_face.raw[1],
                                -sky_on_face.raw[2]);
        /* U = right direction along the face when facing the wall outward. */
        side->uaxis = vec3_normalize(vec3_cross(normal, sky_on_face));
    }
    /* Anchor the tiling to the world origin (offset=0) so any two adjacent
       faces sharing a world position produce the same UV at that position,
       giving seamless face-to-face texture continuity.
       Preserve the existing scale; fall back to 0.25 only if unset. */
    side->uoffset = 0.0f;
    side->voffset = 0.0f;
    if (side->uscale == 0.0f) side->uscale = 0.25f;
    if (side->vscale == 0.0f) side->vscale = 0.25f;
    return 1;
}

int vmf_scene_wrap_align_solid_from_side(VmfScene* scene,
                                         size_t entityIndex,
                                         size_t solidIndex,
                                         size_t sideIndex,
                                         char* errorBuffer,
                                         size_t errorBufferSize) {
    if (!scene || entityIndex >= scene->entityCount ||
        solidIndex >= scene->entities[entityIndex].solidCount) {
        snprintf(errorBuffer, errorBufferSize, "invalid wrap-align request");
        return 0;
    }

    VmfSolid* solid = &scene->entities[entityIndex].solids[solidIndex];
    if (sideIndex >= solid->sideCount) {
        snprintf(errorBuffer, errorBufferSize, "invalid wrap-align seed face");
        return 0;
    }
    if (solid->sideCount == 0 || solid->sideCount > 128) {
        snprintf(errorBuffer, errorBufferSize, "unsupported solid for wrap-align");
        return 0;
    }

    EditorFacePolygon faces[128];
    size_t faceCount = 0;
    if (!collect_solid_face_polygons(solid, faces, 128, &faceCount) || faceCount != solid->sideCount) {
        snprintf(errorBuffer, errorBufferSize, "failed to collect solid face polygons");
        return 0;
    }

    VmfSolidEdge edges[VMF_MAX_SOLID_EDGES];
    size_t edgeCount = 0;
    if (!collect_solid_edges(solid, edges, VMF_MAX_SOLID_EDGES, &edgeCount)) {
        snprintf(errorBuffer, errorBufferSize, "failed to collect solid edges");
        return 0;
    }

    size_t queue[128];
    size_t queueHead = 0;
    size_t queueTail = 0;
    int visited[128] = { 0 };

    VmfSide* seedSide = &solid->sides[sideIndex];
    Vec3 seedNormal = faces[sideIndex].face.plane.normal;
    if (vec3_length(seedSide->uaxis) < 1e-5f || vec3_length(seedSide->vaxis) < 1e-5f) {
        default_face_wrap_axes(seedNormal, &seedSide->uaxis, &seedSide->vaxis);
    }
    normalize_side_uv_frame(seedSide);
    if (seedSide->uscale == 0.0f) seedSide->uscale = 0.25f;
    if (seedSide->vscale == 0.0f) seedSide->vscale = 0.25f;

    float wrapUScale = seedSide->uscale;
    float wrapVScale = seedSide->vscale;
    queue[queueTail++] = sideIndex;
    visited[sideIndex] = 1;

    while (queueHead < queueTail) {
        size_t currentIndex = queue[queueHead++];
        VmfSide* currentSide = &solid->sides[currentIndex];
        Vec3 currentNormal = faces[currentIndex].face.plane.normal;
        normalize_side_uv_frame(currentSide);

        for (size_t edgeIndex = 0; edgeIndex < edgeCount; ++edgeIndex) {
            const VmfSolidEdge* edge = &edges[edgeIndex];
            size_t neighborIndex = SIZE_MAX;
            if (edge->sideIndices[0] == currentIndex) {
                neighborIndex = edge->sideIndices[1];
            } else if (edge->sideIndices[1] == currentIndex) {
                neighborIndex = edge->sideIndices[0];
            }
            if (neighborIndex == SIZE_MAX || neighborIndex >= solid->sideCount || visited[neighborIndex]) {
                continue;
            }

            Vec3 edgeAxis = vec3_normalize(vec3_sub(edge->end, edge->start));
            if (vec3_length(edgeAxis) < 1e-5f) {
                continue;
            }

            VmfSide* neighborSide = &solid->sides[neighborIndex];
            Vec3 neighborNormal = faces[neighborIndex].face.plane.normal;
            float sinAngle = vec3_dot(edgeAxis, vec3_cross(neighborNormal, currentNormal));
            float cosAngle = vec3_dot(neighborNormal, currentNormal);
            float unfoldAngle = atan2f(sinAngle, cosAngle);

            neighborSide->uaxis = vec3_normalize(rotate_vector_around_axis(currentSide->uaxis, edgeAxis, -unfoldAngle));
            neighborSide->vaxis = vec3_normalize(rotate_vector_around_axis(currentSide->vaxis, edgeAxis, -unfoldAngle));
            neighborSide->uscale = wrapUScale;
            neighborSide->vscale = wrapVScale;

            Vec3 rotatedEdgePointForU = rotate_vector_around_axis(edge->start, edgeAxis, unfoldAngle);
            Vec3 rotatedEdgePointForV = rotatedEdgePointForU;
            neighborSide->uoffset = currentSide->uoffset + vec3_dot(edge->start, currentSide->uaxis) - vec3_dot(rotatedEdgePointForU, currentSide->uaxis);
            neighborSide->voffset = currentSide->voffset + vec3_dot(edge->start, currentSide->vaxis) - vec3_dot(rotatedEdgePointForV, currentSide->vaxis);

            visited[neighborIndex] = 1;
            queue[queueTail++] = neighborIndex;
        }
    }

    for (size_t faceIndex = 0; faceIndex < solid->sideCount; ++faceIndex) {
        if (visited[faceIndex]) {
            continue;
        }
        Vec3 fallbackU = vec3_make(0.0f, 0.0f, 0.0f);
        Vec3 fallbackV = vec3_make(0.0f, 0.0f, 0.0f);
        default_face_wrap_axes(faces[faceIndex].face.plane.normal, &fallbackU, &fallbackV);
        solid->sides[faceIndex].uaxis = fallbackU;
        solid->sides[faceIndex].vaxis = fallbackV;
        solid->sides[faceIndex].uoffset = 0.0f;
        solid->sides[faceIndex].voffset = 0.0f;
        solid->sides[faceIndex].uscale = wrapUScale;
        solid->sides[faceIndex].vscale = wrapVScale;
    }

    return 1;
}

int vmf_scene_pick_ray(const VmfScene* scene,
                       Vec3 origin,
                       Vec3 direction,
                       size_t* outEntityIndex,
                       size_t* outSolidIndex,
                       size_t* outSideIndex,
                       Vec3* outHitPoint,
                       char* errorBuffer,
                       size_t errorBufferSize) {
    if (!scene) {
        snprintf(errorBuffer, errorBufferSize, "invalid ray pick request");
        return 0;
    }

    float bestDistance = FLT_MAX;
    int found = 0;
    for (size_t entityIndex = 0; entityIndex < scene->entityCount; ++entityIndex) {
        const VmfEntity* entity = &scene->entities[entityIndex];
        for (size_t solidIndex = 0; solidIndex < entity->solidCount; ++solidIndex) {
            const VmfSolid* solid = &entity->solids[solidIndex];
            if (solid->sideCount < 4 || solid->sideCount > 128) {
                continue;
            }

            EditorPlane planes[128];
            Vec3 interiorPoint = solid_reference_point(solid);
            for (size_t sideIndex = 0; sideIndex < solid->sideCount; ++sideIndex) {
                planes[sideIndex] = orient_plane_toward_interior(plane_from_side(&solid->sides[sideIndex]), interiorPoint);
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
                        if (polygonCount < 256) {
                            append_unique(polygon, &polygonCount, point);
                        }
                    }
                }
                if (polygonCount < 3) {
                    continue;
                }

                sort_polygon(polygon, polygonCount, planes[sideIndex].normal);
                for (size_t vertexIndex = 1; vertexIndex + 1 < polygonCount; ++vertexIndex) {
                    float distance = 0.0f;
                    Vec3 hitPoint;
                    if (!ray_triangle_intersection(origin, direction, polygon[0], polygon[vertexIndex], polygon[vertexIndex + 1], &distance, &hitPoint)) {
                        continue;
                    }
                    if (distance < bestDistance) {
                        bestDistance = distance;
                        found = 1;
                        if (outEntityIndex) {
                            *outEntityIndex = entityIndex;
                        }
                        if (outSolidIndex) {
                            *outSolidIndex = solidIndex;
                        }
                        if (outSideIndex) {
                            *outSideIndex = sideIndex;
                        }
                        if (outHitPoint) {
                            *outHitPoint = hitPoint;
                        }
                    }
                }
            }
        }
    }

    if (!found) {
        snprintf(errorBuffer, errorBufferSize, "no brush hit");
        return 0;
    }
    return 1;
}
