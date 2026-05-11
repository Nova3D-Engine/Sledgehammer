#include "sledgehammer_editor_logic.h"

#include <math.h>
#include <string.h>

static Bounds3 sledgehammer_editor_logic_normalize_bounds(Bounds3 bounds) {
    for (int axis = 0; axis < 3; ++axis) {
        if (bounds.min.raw[axis] > bounds.max.raw[axis]) {
            float tmp = bounds.min.raw[axis];
            bounds.min.raw[axis] = bounds.max.raw[axis];
            bounds.max.raw[axis] = tmp;
        }
    }
    return bounds;
}

int sledgehammer_editor_logic_selection_edge_for_plane(int plane, size_t sideIndex) {
    switch (plane) {
        case SledgehammerViewportPlaneXY:
            if (sideIndex == 1) return SledgehammerViewportSelectionEdgeMinU;
            if (sideIndex == 0) return SledgehammerViewportSelectionEdgeMaxU;
            if (sideIndex == 3) return SledgehammerViewportSelectionEdgeMinV;
            if (sideIndex == 2) return SledgehammerViewportSelectionEdgeMaxV;
            break;
        case SledgehammerViewportPlaneXZ:
            if (sideIndex == 1) return SledgehammerViewportSelectionEdgeMinU;
            if (sideIndex == 0) return SledgehammerViewportSelectionEdgeMaxU;
            if (sideIndex == 5) return SledgehammerViewportSelectionEdgeMinV;
            if (sideIndex == 4) return SledgehammerViewportSelectionEdgeMaxV;
            break;
        case SledgehammerViewportPlaneZY:
            if (sideIndex == 3) return SledgehammerViewportSelectionEdgeMinU;
            if (sideIndex == 2) return SledgehammerViewportSelectionEdgeMaxU;
            if (sideIndex == 5) return SledgehammerViewportSelectionEdgeMinV;
            if (sideIndex == 4) return SledgehammerViewportSelectionEdgeMaxV;
            break;
    }
    return SledgehammerViewportSelectionEdgeNone;
}

int sledgehammer_editor_logic_side_index_for_plane(int plane, int edge) {
    switch (plane) {
        case SledgehammerViewportPlaneXY:
            if (edge == SledgehammerViewportSelectionEdgeMinU) return 1;
            if (edge == SledgehammerViewportSelectionEdgeMaxU) return 0;
            if (edge == SledgehammerViewportSelectionEdgeMinV) return 3;
            if (edge == SledgehammerViewportSelectionEdgeMaxV) return 2;
            break;
        case SledgehammerViewportPlaneXZ:
            if (edge == SledgehammerViewportSelectionEdgeMinU) return 1;
            if (edge == SledgehammerViewportSelectionEdgeMaxU) return 0;
            if (edge == SledgehammerViewportSelectionEdgeMinV) return 5;
            if (edge == SledgehammerViewportSelectionEdgeMaxV) return 4;
            break;
        case SledgehammerViewportPlaneZY:
            if (edge == SledgehammerViewportSelectionEdgeMinU) return 3;
            if (edge == SledgehammerViewportSelectionEdgeMaxU) return 2;
            if (edge == SledgehammerViewportSelectionEdgeMinV) return 5;
            if (edge == SledgehammerViewportSelectionEdgeMaxV) return 4;
            break;
    }
    return -1;
}

Vec3 sledgehammer_editor_logic_duplicate_offset_for_plane(int plane, float delta) {
    switch (plane) {
        case SledgehammerViewportPlaneXZ:
            return vec3_make(delta, 0.0f, 0.0f);
        case SledgehammerViewportPlaneZY:
            return vec3_make(0.0f, delta, 0.0f);
        case SledgehammerViewportPlaneXY:
        default:
            return vec3_make(delta, delta, 0.0f);
    }
}

VmfBrushAxis sledgehammer_editor_logic_active_brush_axis_for_plane(int plane) {
    switch (plane) {
        case SledgehammerViewportPlaneXZ:
            return VmfBrushAxisY;
        case SledgehammerViewportPlaneZY:
            return VmfBrushAxisX;
        case SledgehammerViewportPlaneXY:
        default:
            return VmfBrushAxisZ;
    }
}

VmfBrushAxis sledgehammer_editor_logic_run_brush_axis_for_plane(int plane) {
    switch (plane) {
        case SledgehammerViewportPlaneZY:
            return VmfBrushAxisY;
        case SledgehammerViewportPlaneXY:
        case SledgehammerViewportPlaneXZ:
        default:
            return VmfBrushAxisX;
    }
}

size_t sledgehammer_editor_logic_solid_count_for_shape_tool(int tool, int primaryValue) {
    switch (tool) {
        case SledgehammerViewportEditorToolArch:
        case SledgehammerViewportEditorToolStairs:
            return (size_t)(primaryValue < 2 ? 2 : primaryValue);
        case SledgehammerViewportEditorToolCylinder:
        case SledgehammerViewportEditorToolRamp:
        default:
            return 1;
    }
}

int sledgehammer_editor_logic_default_shape_primary_value(int tool,
                                                          Bounds3 bounds,
                                                          VmfBrushAxis upAxis,
                                                          VmfBrushAxis runAxis,
                                                          float gridSize) {
    if (tool == SledgehammerViewportEditorToolCylinder) {
        return 12;
    }
    if (tool == SledgehammerViewportEditorToolArch) {
        return 8;
    }
    if (tool == SledgehammerViewportEditorToolStairs) {
        float runSize = bounds.max.raw[runAxis] - bounds.min.raw[runAxis];
        float upSize = bounds.max.raw[upAxis] - bounds.min.raw[upAxis];
        float snapped = floorf(fminf(runSize, upSize) / gridSize);
        if (snapped < 2.0f) {
            return 2;
        }
        if (snapped > 16.0f) {
            return 16;
        }
        return (int)snapped;
    }
    return 0;
}

int sledgehammer_editor_logic_minimum_shape_primary_value(int tool) {
    switch (tool) {
        case SledgehammerViewportEditorToolCylinder:
            return 3;
        case SledgehammerViewportEditorToolArch:
        case SledgehammerViewportEditorToolStairs:
            return 2;
        default:
            return 0;
    }
}

int sledgehammer_editor_logic_maximum_shape_primary_value(int tool) {
    switch (tool) {
        case SledgehammerViewportEditorToolCylinder:
            return 64;
        case SledgehammerViewportEditorToolArch:
        case SledgehammerViewportEditorToolStairs:
            return 32;
        default:
            return 0;
    }
}

bool sledgehammer_editor_logic_tool_has_secondary_shape_setting(int tool) {
    return tool == SledgehammerViewportEditorToolArch;
}

float sledgehammer_editor_logic_default_shape_secondary_value(int tool) {
    return tool == SledgehammerViewportEditorToolArch ? 30.0f : 0.0f;
}

const char* sledgehammer_editor_logic_shape_primary_label(int tool) {
    switch (tool) {
        case SledgehammerViewportEditorToolCylinder:
        case SledgehammerViewportEditorToolArch:
            return "Segments";
        case SledgehammerViewportEditorToolStairs:
            return "Steps";
        default:
            return "Value";
    }
}

const char* sledgehammer_editor_logic_shape_secondary_label(int tool) {
    return tool == SledgehammerViewportEditorToolArch ? "Thickness" : "";
}

const char* sledgehammer_editor_logic_shape_settings_panel_title(int tool) {
    switch (tool) {
        case SledgehammerViewportEditorToolCylinder:
            return "Cylinder Settings";
        case SledgehammerViewportEditorToolStairs:
            return "Stairs Settings";
        case SledgehammerViewportEditorToolArch:
            return "Arch Settings";
        default:
            return "Shape Settings";
    }
}

const VmfSide* sledgehammer_editor_logic_selected_face_side(const VmfScene* scene,
                                                            bool hasSelection,
                                                            bool hasFaceSelection,
                                                            bool hasEditingPrefab,
                                                            size_t selectedEntityIndex,
                                                            size_t selectedSolidIndex,
                                                            size_t selectedSideIndex) {
    if (!sledgehammer_editor_logic_selection_has_editable_face_texture(scene,
                                                                       hasSelection,
                                                                       hasFaceSelection,
                                                                       hasEditingPrefab,
                                                                       selectedEntityIndex,
                                                                       selectedSolidIndex,
                                                                       selectedSideIndex)) {
        return NULL;
    }
    return &scene->entities[selectedEntityIndex].solids[selectedSolidIndex].sides[selectedSideIndex];
}

void sledgehammer_editor_logic_default_texture_axes_for_side(const VmfSide* side,
                                                             Vec3* outUAxis,
                                                             Vec3* outVAxis) {
    Vec3 edgeA;
    Vec3 edgeB;
    Vec3 normal;
    Vec3 worldUp;
    float dotUp;
    Vec3 skyOnFace;

    if (side == NULL || outUAxis == NULL || outVAxis == NULL) {
        return;
    }

    edgeA = vec3_sub(side->points[1], side->points[0]);
    edgeB = vec3_sub(side->points[2], side->points[0]);
    normal = vec3_normalize(vec3_cross(edgeA, edgeB));
    worldUp = vec3_make(0.0f, 0.0f, 1.0f);
    dotUp = vec3_dot(normal, worldUp);
    if (fabsf(dotUp) >= 0.999f) {
        *outUAxis = vec3_make(1.0f, 0.0f, 0.0f);
        *outVAxis = vec3_make(0.0f, dotUp > 0.0f ? -1.0f : 1.0f, 0.0f);
        return;
    }

    skyOnFace = vec3_normalize(vec3_sub(worldUp, vec3_scale(normal, dotUp)));
    *outVAxis = vec3_make(-skyOnFace.raw[0], -skyOnFace.raw[1], -skyOnFace.raw[2]);
    *outUAxis = vec3_normalize(vec3_cross(normal, skyOnFace));
}

float sledgehammer_editor_logic_texture_rotation_degrees_for_side(const VmfSide* side) {
    Vec3 defaultU = vec3_make(1.0f, 0.0f, 0.0f);
    Vec3 defaultV = vec3_make(0.0f, -1.0f, 0.0f);
    Vec3 currentU;
    Vec3 edgeA;
    Vec3 edgeB;
    Vec3 normal;
    float sinAngle;
    float cosAngle;

    if (side == NULL) {
        return 0.0f;
    }

    currentU = side->uaxis;
    edgeA = vec3_sub(side->points[1], side->points[0]);
    edgeB = vec3_sub(side->points[2], side->points[0]);
    normal = vec3_normalize(vec3_cross(edgeA, edgeB));

    sledgehammer_editor_logic_default_texture_axes_for_side(side, &defaultU, &defaultV);
    (void)defaultV;
    if (vec3_length(currentU) < 1e-5f || vec3_length(normal) < 1e-5f) {
        return 0.0f;
    }
    currentU = vec3_normalize(currentU);
    defaultU = vec3_normalize(defaultU);
    sinAngle = vec3_dot(normal, vec3_cross(defaultU, currentU));
    cosAngle = fmaxf(fminf(vec3_dot(defaultU, currentU), 1.0f), -1.0f);
    return atan2f(sinAngle, cosAngle) * 57.29577951308232f;
}

float sledgehammer_editor_logic_entity_pick_radius(const VmfEntity* entity) {
    if (entity == NULL) {
        return 16.0f;
    }
    if (entity->kind == VmfEntityKindLight) {
        return fmaxf(24.0f, fminf(entity->range * 0.1f, 64.0f));
    }
    if (entity->kind == VmfEntityKindModel) {
        float maxExtent = fmaxf(entity->modelHalfExtents.raw[0],
                                fmaxf(entity->modelHalfExtents.raw[1], entity->modelHalfExtents.raw[2]));
        return fmaxf(maxExtent, 24.0f);
    }
    return 16.0f;
}

bool sledgehammer_editor_logic_entity_is_grouped_brush(const VmfScene* scene, size_t entityIndex) {
    if (scene == NULL || entityIndex >= scene->entityCount) {
        return false;
    }
    const VmfEntity* entity = &scene->entities[entityIndex];
    if (entity->kind != VmfEntityKindBrush || entity->isWorld || entity->solidCount == 0) {
        return false;
    }
    if (strcmp(entity->classname, "func_group") == 0) {
        return true;
    }
    return entity->classname[0] == '\0' && entity->name[0] != '\0';
}

size_t sledgehammer_editor_logic_entity_index_for_id(const VmfScene* scene, int entityId) {
    size_t entityCount = scene != NULL ? scene->entityCount : 0;
    if (scene == NULL || entityId <= 0) {
        return entityCount;
    }
    for (size_t entityIndex = 0; entityIndex < entityCount; ++entityIndex) {
        if (scene->entities[entityIndex].id == entityId) {
            return entityIndex;
        }
    }
    return entityCount;
}

bool sledgehammer_editor_logic_entity_is_point_entity(const VmfScene* scene, size_t entityIndex) {
    if (scene == NULL || entityIndex >= scene->entityCount) {
        return false;
    }
    const VmfEntity* entity = &scene->entities[entityIndex];
    return entity->solidCount == 0 &&
        entity->kind != VmfEntityKindRoot &&
        (entity->kind == VmfEntityKindLight || entity->kind == VmfEntityKindModel);
}

bool sledgehammer_editor_logic_selection_is_grouped_brush(const VmfScene* scene,
                                                          bool hasSelection,
                                                          size_t selectedEntityIndex) {
    return hasSelection && sledgehammer_editor_logic_entity_is_grouped_brush(scene, selectedEntityIndex);
}

bool sledgehammer_editor_logic_selection_is_point_entity(const VmfScene* scene,
                                                         bool hasSelection,
                                                         size_t selectedEntityIndex) {
    return hasSelection && sledgehammer_editor_logic_entity_is_point_entity(scene, selectedEntityIndex);
}

size_t sledgehammer_editor_logic_active_group_entity_index(const VmfScene* scene,
                                                           bool hasSelection,
                                                           size_t selectedEntityIndex,
                                                           int activeGroupEntityId) {
    if (sledgehammer_editor_logic_selection_is_grouped_brush(scene, hasSelection, selectedEntityIndex)) {
        return selectedEntityIndex;
    }
    return sledgehammer_editor_logic_entity_index_for_id(scene, activeGroupEntityId);
}

size_t sledgehammer_editor_logic_grouped_brush_entity_count(const VmfScene* scene) {
    size_t groupedBrushCount = 0;
    if (scene == NULL) {
        return 0;
    }
    for (size_t entityIndex = 0; entityIndex < scene->entityCount; ++entityIndex) {
        if (sledgehammer_editor_logic_entity_is_grouped_brush(scene, entityIndex)) {
            groupedBrushCount += 1;
        }
    }
    return groupedBrushCount;
}

bool sledgehammer_editor_logic_entity_bounds(const VmfScene* scene,
                                             size_t entityIndex,
                                             Bounds3* outBounds) {
    char errorBuffer[256] = { 0 };
    if (scene == NULL || outBounds == NULL || entityIndex >= scene->entityCount) {
        return false;
    }
    return vmf_scene_entity_bounds(scene, entityIndex, outBounds, errorBuffer, sizeof(errorBuffer));
}

bool sledgehammer_editor_logic_selection_has_editable_face_texture(const VmfScene* scene,
                                                                   bool hasSelection,
                                                                   bool hasFaceSelection,
                                                                   bool hasEditingPrefab,
                                                                   size_t selectedEntityIndex,
                                                                   size_t selectedSolidIndex,
                                                                   size_t selectedSideIndex) {
    return hasSelection &&
        hasFaceSelection &&
        !hasEditingPrefab &&
        !sledgehammer_editor_logic_selection_is_point_entity(scene, hasSelection, selectedEntityIndex) &&
        scene != NULL &&
        selectedEntityIndex < scene->entityCount &&
        selectedSolidIndex < scene->entities[selectedEntityIndex].solidCount &&
        selectedSideIndex < scene->entities[selectedEntityIndex].solids[selectedSolidIndex].sideCount;
}

bool sledgehammer_editor_logic_selected_solid_is_box_brush(const VmfScene* scene,
                                                           bool hasSelection,
                                                           size_t selectedEntityIndex,
                                                           size_t selectedSolidIndex) {
    if (scene == NULL || !hasSelection || selectedEntityIndex >= scene->entityCount ||
        selectedSolidIndex >= scene->entities[selectedEntityIndex].solidCount) {
        return false;
    }
    return scene->entities[selectedEntityIndex].solids[selectedSolidIndex].sideCount == 6;
}

bool sledgehammer_editor_logic_pick_point_entity_at_point(const VmfScene* scene,
                                                          Vec3 point,
                                                          int plane,
                                                          size_t* outEntityIndex) {
    bool found = false;
    float bestArea = FLT_MAX;
    size_t bestEntityIndex = 0;
    if (scene == NULL) {
        return false;
    }

    for (size_t entityIndex = 0; entityIndex < scene->entityCount; ++entityIndex) {
        const VmfEntity* entity = &scene->entities[entityIndex];
        if (!sledgehammer_editor_logic_entity_is_point_entity(scene, entityIndex)) {
            continue;
        }

        Bounds3 bounds = bounds3_empty();
        char errorBuffer[128] = { 0 };
        if (!vmf_scene_entity_bounds(scene, entityIndex, &bounds, errorBuffer, sizeof(errorBuffer))) {
            continue;
        }

        float minU = plane == SledgehammerViewportPlaneZY ? bounds.min.raw[1] : bounds.min.raw[0];
        float maxU = plane == SledgehammerViewportPlaneZY ? bounds.max.raw[1] : bounds.max.raw[0];
        float minV = plane == SledgehammerViewportPlaneXY ? bounds.min.raw[1] : bounds.min.raw[2];
        float maxV = plane == SledgehammerViewportPlaneXY ? bounds.max.raw[1] : bounds.max.raw[2];
        float u = plane == SledgehammerViewportPlaneZY ? point.raw[1] : point.raw[0];
        float v = plane == SledgehammerViewportPlaneXY ? point.raw[1] : point.raw[2];
        if (u < minU || u > maxU || v < minV || v > maxV) {
            continue;
        }

        float area = (maxU - minU) * (maxV - minV);
        if (!found || area < bestArea) {
            found = true;
            bestArea = area;
            bestEntityIndex = entityIndex;
        }
    }

    if (found && outEntityIndex != NULL) {
        *outEntityIndex = bestEntityIndex;
    }
    return found;
}

size_t sledgehammer_editor_logic_collect_pick_candidates_2d(const VmfScene* scene,
                                                            Vec3 point,
                                                            int plane,
                                                            size_t* outEntityIndices,
                                                            size_t* outSolidIndices,
                                                            size_t maxCandidates) {
    typedef struct PickCandidate2D {
        size_t entityIndex;
        size_t solidIndex;
        float area;
    } PickCandidate2D;
    PickCandidate2D candidates[512];
    size_t candidateCount = 0;
    if (scene == NULL || outEntityIndices == NULL || outSolidIndices == NULL || maxCandidates == 0) {
        return 0;
    }

    for (size_t entityIndex = 0; entityIndex < scene->entityCount; ++entityIndex) {
        for (size_t solidIndex = 0; solidIndex < scene->entities[entityIndex].solidCount; ++solidIndex) {
            Bounds3 bounds;
            char errorBuffer[128] = { 0 };
            if (!vmf_scene_solid_bounds(scene, entityIndex, solidIndex, &bounds, errorBuffer, sizeof(errorBuffer))) {
                continue;
            }
            bounds = sledgehammer_editor_logic_normalize_bounds(bounds);

            float minU = plane == SledgehammerViewportPlaneZY ? bounds.min.raw[1] : bounds.min.raw[0];
            float maxU = plane == SledgehammerViewportPlaneZY ? bounds.max.raw[1] : bounds.max.raw[0];
            float minV = plane == SledgehammerViewportPlaneXY ? bounds.min.raw[1] : bounds.min.raw[2];
            float maxV = plane == SledgehammerViewportPlaneXY ? bounds.max.raw[1] : bounds.max.raw[2];
            float u = plane == SledgehammerViewportPlaneZY ? point.raw[1] : point.raw[0];
            float v = plane == SledgehammerViewportPlaneXY ? point.raw[1] : point.raw[2];
            if (u < minU || u > maxU || v < minV || v > maxV) {
                continue;
            }

            if (candidateCount < sizeof(candidates) / sizeof(candidates[0])) {
                candidates[candidateCount++] = (PickCandidate2D) {
                    .entityIndex = entityIndex,
                    .solidIndex = solidIndex,
                    .area = fabsf((maxU - minU) * (maxV - minV)),
                };
            }
        }
    }

    for (size_t entityIndex = 0; entityIndex < scene->entityCount; ++entityIndex) {
        const VmfEntity* entity = &scene->entities[entityIndex];
        if (!sledgehammer_editor_logic_entity_is_point_entity(scene, entityIndex)) {
            continue;
        }
        Bounds3 bounds = bounds3_empty();
        char errorBuffer[128] = { 0 };
        if (!vmf_scene_entity_bounds(scene, entityIndex, &bounds, errorBuffer, sizeof(errorBuffer))) {
            continue;
        }
        float minU = plane == SledgehammerViewportPlaneZY ? bounds.min.raw[1] : bounds.min.raw[0];
        float maxU = plane == SledgehammerViewportPlaneZY ? bounds.max.raw[1] : bounds.max.raw[0];
        float minV = plane == SledgehammerViewportPlaneXY ? bounds.min.raw[1] : bounds.min.raw[2];
        float maxV = plane == SledgehammerViewportPlaneXY ? bounds.max.raw[1] : bounds.max.raw[2];
        float u = plane == SledgehammerViewportPlaneZY ? point.raw[1] : point.raw[0];
        float v = plane == SledgehammerViewportPlaneXY ? point.raw[1] : point.raw[2];
        if (u < minU || u > maxU || v < minV || v > maxV) {
            continue;
        }
        if (candidateCount < sizeof(candidates) / sizeof(candidates[0])) {
            candidates[candidateCount++] = (PickCandidate2D) {
                .entityIndex = entityIndex,
                .solidIndex = 0,
                .area = fabsf((maxU - minU) * (maxV - minV)),
            };
        }
    }

    for (size_t i = 0; i < candidateCount; ++i) {
        size_t bestIndex = i;
        for (size_t j = i + 1; j < candidateCount; ++j) {
            if (candidates[j].area < candidates[bestIndex].area) {
                bestIndex = j;
            }
        }
        if (bestIndex != i) {
            PickCandidate2D tmp = candidates[i];
            candidates[i] = candidates[bestIndex];
            candidates[bestIndex] = tmp;
        }
    }

    size_t writeCount = candidateCount < maxCandidates ? candidateCount : maxCandidates;
    for (size_t index = 0; index < writeCount; ++index) {
        outEntityIndices[index] = candidates[index].entityIndex;
        outSolidIndices[index] = candidates[index].solidIndex;
    }
    return writeCount;
}

bool sledgehammer_editor_logic_pick_point_entity_ray(const VmfScene* scene,
                                                     Vec3 origin,
                                                     Vec3 direction,
                                                     size_t* outEntityIndex) {
    bool found = false;
    float bestDistance = FLT_MAX;
    size_t bestEntityIndex = 0;
    Vec3 normalizedDirection = vec3_normalize(direction);
    if (scene == NULL) {
        return false;
    }

    for (size_t entityIndex = 0; entityIndex < scene->entityCount; ++entityIndex) {
        const VmfEntity* entity = &scene->entities[entityIndex];
        if (!sledgehammer_editor_logic_entity_is_point_entity(scene, entityIndex)) {
            continue;
        }

        float radius = sledgehammer_editor_logic_entity_pick_radius(entity);
        Vec3 toCenter = vec3_sub(entity->position, origin);
        float projection = vec3_dot(toCenter, normalizedDirection);
        if (projection < 0.0f) {
            continue;
        }
        Vec3 closestPoint = vec3_add(origin, vec3_scale(normalizedDirection, projection));
        float centerDistance = vec3_length(vec3_sub(entity->position, closestPoint));
        if (centerDistance > radius) {
            continue;
        }
        float surfaceDistance = projection - sqrtf(fmaxf((radius * radius) - (centerDistance * centerDistance), 0.0f));
        if (!found || surfaceDistance < bestDistance) {
            found = true;
            bestDistance = surfaceDistance;
            bestEntityIndex = entityIndex;
        }
    }

    if (found && outEntityIndex != NULL) {
        *outEntityIndex = bestEntityIndex;
    }
    return found;
}

size_t sledgehammer_editor_logic_collect_point_entity_ray_candidates(const VmfScene* scene,
                                                                     Vec3 origin,
                                                                     Vec3 direction,
                                                                     size_t* outEntityIndices,
                                                                     float* outDistances,
                                                                     float* outPickRadii,
                                                                     size_t maxCandidates) {
    typedef struct PointRayCandidate {
        size_t entityIndex;
        float distance;
        float radius;
    } PointRayCandidate;
    PointRayCandidate candidates[256];
    size_t candidateCount = 0;
    Vec3 normalizedDirection = vec3_normalize(direction);
    if (scene == NULL || outEntityIndices == NULL || maxCandidates == 0) {
        return 0;
    }

    for (size_t entityIndex = 0; entityIndex < scene->entityCount; ++entityIndex) {
        const VmfEntity* entity = &scene->entities[entityIndex];
        if (!sledgehammer_editor_logic_entity_is_point_entity(scene, entityIndex)) {
            continue;
        }
        float radius = sledgehammer_editor_logic_entity_pick_radius(entity);
        Vec3 toCenter = vec3_sub(entity->position, origin);
        float projection = vec3_dot(toCenter, normalizedDirection);
        if (projection < 0.0f) {
            continue;
        }
        Vec3 closestPoint = vec3_add(origin, vec3_scale(normalizedDirection, projection));
        float centerDistance = vec3_length(vec3_sub(entity->position, closestPoint));
        if (centerDistance > radius) {
            continue;
        }
        float surfaceDistance = projection - sqrtf(fmaxf((radius * radius) - (centerDistance * centerDistance), 0.0f));
        if (candidateCount < sizeof(candidates) / sizeof(candidates[0])) {
            candidates[candidateCount++] = (PointRayCandidate) {
                .entityIndex = entityIndex,
                .distance = surfaceDistance,
                .radius = radius,
            };
        }
    }

    for (size_t i = 0; i < candidateCount; ++i) {
        size_t bestIndex = i;
        for (size_t j = i + 1; j < candidateCount; ++j) {
            if (candidates[j].distance < candidates[bestIndex].distance - 1e-3f ||
                (fabsf(candidates[j].distance - candidates[bestIndex].distance) <= 1e-3f &&
                 candidates[j].radius < candidates[bestIndex].radius)) {
                bestIndex = j;
            }
        }
        if (bestIndex != i) {
            PointRayCandidate tmp = candidates[i];
            candidates[i] = candidates[bestIndex];
            candidates[bestIndex] = tmp;
        }
    }

    size_t writeCount = candidateCount < maxCandidates ? candidateCount : maxCandidates;
    for (size_t index = 0; index < writeCount; ++index) {
        outEntityIndices[index] = candidates[index].entityIndex;
        if (outDistances != NULL) {
            outDistances[index] = candidates[index].distance;
        }
        if (outPickRadii != NULL) {
            outPickRadii[index] = candidates[index].radius;
        }
    }
    return writeCount;
}

bool sledgehammer_editor_logic_pick_scene_at_point_2d(const VmfScene* scene,
                                                      Vec3 point,
                                                      int plane,
                                                      size_t* outEntityIndex,
                                                      size_t* outSolidIndex) {
    size_t entityIndices[1];
    size_t solidIndices[1];
    size_t count = sledgehammer_editor_logic_collect_pick_candidates_2d(scene,
                                                                        point,
                                                                        plane,
                                                                        entityIndices,
                                                                        solidIndices,
                                                                        1);
    if (count == 0) {
        return false;
    }
    if (outEntityIndex != NULL) {
        *outEntityIndex = entityIndices[0];
    }
    if (outSolidIndex != NULL) {
        *outSolidIndex = solidIndices[0];
    }
    return true;
}

bool sledgehammer_editor_logic_is_draft_convex(const Vec3* draftVertices,
                                               size_t draftVertexCount,
                                               const size_t* draftEdgeConnVA,
                                               const size_t* draftEdgeConnVB,
                                               const VmfSolidEdge* draftEdgeTemplates,
                                               size_t draftEdgeConnCount,
                                               const Vec3* draftFaceRefNormals,
                                               const size_t* draftFaceSideIndices,
                                               size_t draftFaceCount) {
    if (draftVertices == NULL || draftEdgeConnVA == NULL || draftEdgeConnVB == NULL ||
        draftEdgeTemplates == NULL || draftFaceRefNormals == NULL || draftFaceSideIndices == NULL) {
        return true;
    }
    if (draftVertexCount < 4 || draftFaceCount == 0) {
        return true;
    }

    static const float mergeEps = 0.5f;
    size_t canonical[VMF_MAX_SOLID_VERTICES];
    Vec3 unique[VMF_MAX_SOLID_VERTICES];
    size_t uniqueCount = 0;
    for (size_t i = 0; i < draftVertexCount; ++i) {
        size_t found = SIZE_MAX;
        for (size_t j = 0; j < uniqueCount; ++j) {
            if (vec3_length(vec3_sub(draftVertices[i], unique[j])) < mergeEps) {
                found = j;
                break;
            }
        }
        if (found == SIZE_MAX) {
            canonical[i] = uniqueCount;
            unique[uniqueCount++] = draftVertices[i];
        } else {
            canonical[i] = found;
        }
    }

    static const float convexEps = 0.5f;
    for (size_t f = 0; f < draftFaceCount; ++f) {
        size_t sideIdx = draftFaceSideIndices[f];
        Vec3 refNormal = draftFaceRefNormals[f];
        size_t faceCanon[VMF_MAX_SOLID_VERTICES];
        size_t faceCanonCount = 0;
        for (size_t e = 0; e < draftEdgeConnCount; ++e) {
            if (draftEdgeTemplates[e].sideIndices[0] != sideIdx &&
                draftEdgeTemplates[e].sideIndices[1] != sideIdx) {
                continue;
            }
            size_t cA = canonical[draftEdgeConnVA[e]];
            size_t cB = canonical[draftEdgeConnVB[e]];
            bool hasA = false;
            bool hasB = false;
            for (size_t x = 0; x < faceCanonCount; ++x) {
                if (faceCanon[x] == cA) hasA = true;
                if (faceCanon[x] == cB) hasB = true;
            }
            if (!hasA && faceCanonCount < VMF_MAX_SOLID_VERTICES) faceCanon[faceCanonCount++] = cA;
            if (!hasB && faceCanonCount < VMF_MAX_SOLID_VERTICES) faceCanon[faceCanonCount++] = cB;
        }

        if (faceCanonCount < 3) {
            continue;
        }

        Vec3 planeNormal = vec3_make(0.0f, 0.0f, 0.0f);
        float planeDist = 0.0f;
        bool planeFound = false;
        for (size_t i = 0; i < faceCanonCount && !planeFound; ++i) {
            for (size_t j = i + 1; j < faceCanonCount && !planeFound; ++j) {
                for (size_t k = j + 1; k < faceCanonCount && !planeFound; ++k) {
                    Vec3 ab = vec3_sub(unique[faceCanon[j]], unique[faceCanon[i]]);
                    Vec3 ac = vec3_sub(unique[faceCanon[k]], unique[faceCanon[i]]);
                    Vec3 cross = vec3_cross(ab, ac);
                    if (vec3_length(cross) < 1e-4f) continue;
                    planeNormal = vec3_normalize(cross);
                    if (vec3_dot(planeNormal, refNormal) < 0.0f) {
                        planeNormal = vec3_scale(planeNormal, -1.0f);
                    }
                    planeDist = vec3_dot(planeNormal, unique[faceCanon[i]]);
                    planeFound = true;
                }
            }
        }

        if (!planeFound) {
            return false;
        }

        for (size_t v = 0; v < uniqueCount; ++v) {
            float dist = vec3_dot(planeNormal, unique[v]) - planeDist;
            if (dist > convexEps) {
                return false;
            }
        }
    }

    return true;
}

size_t sledgehammer_editor_logic_build_draft_display_edges(const Vec3* draftVertices,
                                                           const size_t* draftEdgeConnVA,
                                                           const size_t* draftEdgeConnVB,
                                                           const VmfSolidEdge* draftEdgeTemplates,
                                                           size_t draftEdgeConnCount,
                                                           VmfSolidEdge* outEdges) {
    if (draftVertices == NULL || draftEdgeConnVA == NULL || draftEdgeConnVB == NULL ||
        draftEdgeTemplates == NULL || outEdges == NULL) {
        return 0;
    }
    for (size_t i = 0; i < draftEdgeConnCount; ++i) {
        outEdges[i] = draftEdgeTemplates[i];
        outEdges[i].start = draftVertices[draftEdgeConnVA[i]];
        outEdges[i].end = draftVertices[draftEdgeConnVB[i]];
        outEdges[i].endpointCount = 2;
    }
    return draftEdgeConnCount;
}

size_t sledgehammer_editor_logic_build_draft_preview_vertices(const Vec3* draftVertices,
                                                              const size_t* draftEdgeConnVA,
                                                              const size_t* draftEdgeConnVB,
                                                              size_t draftEdgeConnCount,
                                                              Vec3 previewColor,
                                                              ViewerVertex* outVertices) {
    if (draftVertices == NULL || draftEdgeConnVA == NULL || draftEdgeConnVB == NULL || outVertices == NULL) {
        return 0;
    }
    size_t previewVertCount = 0;
    for (size_t i = 0; i < draftEdgeConnCount; ++i) {
        Vec3 a = draftVertices[draftEdgeConnVA[i]];
        Vec3 b = draftVertices[draftEdgeConnVB[i]];
        Vec3 n = vec3_make(0.0f, 0.0f, 1.0f);
        outVertices[previewVertCount++] = (ViewerVertex){ .position = a, .normal = n, .color = previewColor };
        outVertices[previewVertCount++] = (ViewerVertex){ .position = b, .normal = n, .color = previewColor };
    }
    return previewVertCount;
}
