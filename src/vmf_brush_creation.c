#include "vmf_brush_creation.h"

#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "vmf_editor.h"

static int remaining_axis(VmfBrushAxis first, VmfBrushAxis second) {
    for (int axis = 0; axis < 3; ++axis) {
        if (axis != (int)first && axis != (int)second) {
            return axis;
        }
    }
    return -1;
}

static void assign_material(char destination[128], const char* material) {
    const char* source = material && material[0] ? material : "dev_grid";
    strncpy(destination, source, 127);
    destination[127] = '\0';
}

static void orient_plane_toward_interior(EditorSolidPlane* plane, Vec3 interiorPoint) {
    float signedDistance = vec3_dot(plane->normal, interiorPoint) - plane->distance;
    if (signedDistance > 0.0f) {
        plane->normal = vec3_scale(plane->normal, -1.0f);
        plane->distance = -plane->distance;
    }
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

    plane->normal = vec3_normalize(normal);
    plane->distance = vec3_dot(plane->normal, a);
    orient_plane_toward_interior(plane, interiorPoint);
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

static int validate_bounds(Bounds3 bounds) {
    Vec3 size = bounds3_size(bounds);
    return bounds3_is_valid(bounds) && size.raw[0] >= 1.0f && size.raw[1] >= 1.0f && size.raw[2] >= 1.0f;
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