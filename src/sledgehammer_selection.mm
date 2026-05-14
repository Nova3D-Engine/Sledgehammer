#import "sledgehammer_viewer_app_internal.h"
#import "sledgehammer_viewport_internal.h"

#include "sledgehammer_editor_logic.h"
#include "nova_scene_ecs_internal.h"
#include <float.h>
#include <math.h>

static void sledgehammer_selection_compute_world_aabb(const float world[16], const float localMin[3], const float localMax[3], float outMin[3], float outMax[3]) {
    float corners[8][3] = {
        { localMin[0], localMin[1], localMin[2] },
        { localMax[0], localMin[1], localMin[2] },
        { localMax[0], localMax[1], localMin[2] },
        { localMin[0], localMax[1], localMin[2] },
        { localMin[0], localMin[1], localMax[2] },
        { localMax[0], localMin[1], localMax[2] },
        { localMax[0], localMax[1], localMax[2] },
        { localMin[0], localMax[1], localMax[2] },
    };
    outMin[0] = outMin[1] = outMin[2] = FLT_MAX;
    outMax[0] = outMax[1] = outMax[2] = -FLT_MAX;
    for (size_t cornerIndex = 0; cornerIndex < 8u; ++cornerIndex) {
        float wx = world[0] * corners[cornerIndex][0] + world[4] * corners[cornerIndex][1] + world[8] * corners[cornerIndex][2] + world[12];
        float wy = world[1] * corners[cornerIndex][0] + world[5] * corners[cornerIndex][1] + world[9] * corners[cornerIndex][2] + world[13];
        float wz = world[2] * corners[cornerIndex][0] + world[6] * corners[cornerIndex][1] + world[10] * corners[cornerIndex][2] + world[14];
        if (wx < outMin[0]) outMin[0] = wx;
        if (wy < outMin[1]) outMin[1] = wy;
        if (wz < outMin[2]) outMin[2] = wz;
        if (wx > outMax[0]) outMax[0] = wx;
        if (wy > outMax[1]) outMax[1] = wy;
        if (wz > outMax[2]) outMax[2] = wz;
    }
}

static BOOL sledgehammer_selection_ray_intersects_bounds(Vec3 origin, Vec3 direction, Bounds3 bounds, float* outDistance) {
    float tMin = 0.0f;
    float tMax = FLT_MAX;
    for (int axis = 0; axis < 3; ++axis) {
        float rayOrigin = origin.raw[axis];
        float rayDirection = direction.raw[axis];
        float boundsMin = bounds.min.raw[axis];
        float boundsMax = bounds.max.raw[axis];
        if (fabsf(rayDirection) < 1e-6f) {
            if (rayOrigin < boundsMin || rayOrigin > boundsMax) {
                return NO;
            }
            continue;
        }
        float invDirection = 1.0f / rayDirection;
        float t0 = (boundsMin - rayOrigin) * invDirection;
        float t1 = (boundsMax - rayOrigin) * invDirection;
        if (t0 > t1) {
            float swap = t0;
            t0 = t1;
            t1 = swap;
        }
        tMin = fmaxf(tMin, t0);
        tMax = fminf(tMax, t1);
        if (tMax < tMin) {
            return NO;
        }
    }
    if (outDistance != NULL) {
        *outDistance = tMin;
    }
    return YES;
}

static size_t sledgehammer_selection_collect_scene_ray_candidates(const VmfScene* scene,
                                                                  const VmfViewport* viewport,
                                                                  Vec3 origin,
                                                                  Vec3 direction,
                                                                  size_t* outEntityIndices,
                                                                  size_t* outSolidIndices,
                                                                  size_t* outSideIndices,
                                                                  BOOL* outPointEntityFlags,
                                                                  float* outDistances,
                                                                  float* outSizes,
                                                                  size_t maxCandidates) {
    typedef struct SceneRayCandidate {
        size_t entityIndex;
        size_t solidIndex;
        size_t sideIndex;
        BOOL pointEntity;
        float distance;
        float size;
    } SceneRayCandidate;
    SceneRayCandidate candidates[256];
    size_t candidateCount = 0;
    Vec3 normalizedDirection = vec3_normalize(direction);
    if (scene == NULL || viewport == nil || viewport.sceneWorld == NULL ||
        viewport.heavyObjectEntityIndices == NULL || maxCandidates == 0) {
        return 0;
    }

    const NovaSceneWorld* sceneWorld = viewport.sceneWorld;
    uint32_t objectCount = sceneWorld->objectCount;
    if (objectCount > viewport.heavyObjectMappingCount) {
        objectCount = viewport.heavyObjectMappingCount;
    }

    for (uint32_t objectIndex = 0u; objectIndex < objectCount; ++objectIndex) {
        size_t entityIndex = viewport.heavyObjectEntityIndices[objectIndex];
        if (entityIndex >= scene->entityCount) {
            continue;
        }

        float worldMin[3];
        float worldMax[3];
        const NovaSceneObjectRecord* record = &sceneWorld->objectRecords[objectIndex];
        sledgehammer_selection_compute_world_aabb(record->worldMatrix, record->aabbMin, record->aabbMax, worldMin, worldMax);
        Bounds3 bounds = bounds3_empty();
        bounds.min = vec3_make(worldMin[0], worldMin[1], worldMin[2]);
        bounds.max = vec3_make(worldMax[0], worldMax[1], worldMax[2]);
        float distance = 0.0f;
        if (!sledgehammer_selection_ray_intersects_bounds(origin, normalizedDirection, bounds, &distance)) {
            continue;
        }

        size_t solidIndex = viewport.heavyObjectSolidIndices != NULL ? viewport.heavyObjectSolidIndices[objectIndex] : UINT32_MAX;
        size_t sideIndex = viewport.heavyObjectSideIndices != NULL ? viewport.heavyObjectSideIndices[objectIndex] : UINT32_MAX;
        BOOL pointEntity = solidIndex == UINT32_MAX ? YES : NO;
        Vec3 diag = vec3_sub(bounds.max, bounds.min);
        float size = fmaxf(1.0f, vec3_length(diag));

        size_t existingIndex = SIZE_MAX;
        for (size_t candidateIndex = 0; candidateIndex < candidateCount; ++candidateIndex) {
            if (candidates[candidateIndex].entityIndex == entityIndex &&
                candidates[candidateIndex].solidIndex == solidIndex &&
                candidates[candidateIndex].pointEntity == pointEntity) {
                existingIndex = candidateIndex;
                break;
            }
        }

        if (existingIndex != SIZE_MAX) {
            if (distance < candidates[existingIndex].distance) {
                candidates[existingIndex].distance = distance;
                candidates[existingIndex].size = size;
                candidates[existingIndex].sideIndex = sideIndex;
            }
            continue;
        }

        if (candidateCount < sizeof(candidates) / sizeof(candidates[0])) {
            candidates[candidateCount++] = (SceneRayCandidate) {
                .entityIndex = entityIndex,
                .solidIndex = solidIndex,
                .sideIndex = sideIndex,
                .pointEntity = pointEntity,
                .distance = distance,
                .size = size,
            };
        }
    }

    for (size_t i = 0; i < candidateCount; ++i) {
        size_t bestIndex = i;
        for (size_t j = i + 1; j < candidateCount; ++j) {
            if (candidates[j].distance < candidates[bestIndex].distance - 1e-3f ||
                (fabsf(candidates[j].distance - candidates[bestIndex].distance) <= 1e-3f &&
                 candidates[j].size < candidates[bestIndex].size)) {
                bestIndex = j;
            }
        }
        if (bestIndex != i) {
            SceneRayCandidate tmp = candidates[i];
            candidates[i] = candidates[bestIndex];
            candidates[bestIndex] = tmp;
        }
    }

    size_t writeCount = candidateCount < maxCandidates ? candidateCount : maxCandidates;
    for (size_t index = 0; index < writeCount; ++index) {
        outEntityIndices[index] = candidates[index].entityIndex;
        outSolidIndices[index] = candidates[index].solidIndex;
        outSideIndices[index] = candidates[index].sideIndex;
        outPointEntityFlags[index] = candidates[index].pointEntity;
        outDistances[index] = candidates[index].distance;
        outSizes[index] = candidates[index].size;
    }
    return writeCount;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation ViewerAppDelegate (Selection)

- (BOOL)selectionHasEditableFaceTexture {
    return sledgehammer_editor_logic_selection_has_editable_face_texture(&_scene,
                                                                         self.hasSelection,
                                                                         self.hasFaceSelection,
                                                                         self.editingPrefab != nil,
                                                                         self.selectedEntityIndex,
                                                                         self.selectedSolidIndex,
                                                                         self.selectedSideIndex) ? YES : NO;
}

- (BOOL)selectedEntityBounds:(Bounds3*)outBounds {
    return sledgehammer_editor_logic_entity_bounds(&_scene, self.selectedEntityIndex, outBounds) ? YES : NO;
}

- (BOOL)isSelectedSolidBoxBrush {
    return sledgehammer_editor_logic_selected_solid_is_box_brush(&_scene,
                                                                 self.hasSelection,
                                                                 self.selectedEntityIndex,
                                                                 self.selectedSolidIndex) ? YES : NO;
}

- (void)createGroupFromSelection:(id)sender {
    (void)sender;
    if (!self.hasSelection || [self selectionIsPointEntity] || [self selectionIsPrefab] || [self selectionIsGroupedBrushEntity]) {
        return;
    }

    SceneHistoryEntry* entry = [self captureHistoryEntry];
    if (!entry) {
        return;
    }

    size_t sourceEntityIndex = self.selectedEntityIndex;
    size_t groupEntityIndex = 0;
    size_t groupedSolidIndex = 0;
    char errorBuffer[256] = { 0 };
    if (!vmf_scene_add_brush_entity(&_scene, [self nextGroupName].UTF8String, "func_group", &groupEntityIndex, errorBuffer, sizeof(errorBuffer)) ||
        !vmf_scene_move_solid_to_entity(&_scene, sourceEntityIndex, self.selectedSolidIndex, groupEntityIndex, &groupedSolidIndex, errorBuffer, sizeof(errorBuffer))) {
        [self showError:[NSString stringWithUTF8String:errorBuffer]];
        return;
    }

    if (sourceEntityIndex < self.scene.entityCount && sourceEntityIndex != groupEntityIndex &&
        self.scene.entities[sourceEntityIndex].kind == VmfEntityKindBrush &&
        !self.scene.entities[sourceEntityIndex].isWorld &&
        self.scene.entities[sourceEntityIndex].solidCount == 0) {
        if (!vmf_scene_delete_entity(&_scene, sourceEntityIndex, errorBuffer, sizeof(errorBuffer))) {
            [self showError:[NSString stringWithUTF8String:errorBuffer]];
            return;
        }
        if (sourceEntityIndex < groupEntityIndex) {
            groupEntityIndex -= 1;
        }
    }

    self.hasSelection = YES;
    self.selectedEntityIndex = groupEntityIndex;
    self.selectedSolidIndex = groupedSolidIndex;
    self.hasFaceSelection = NO;
    self.selectedSideIndex = 0;
    self.activeGroupEntityId = self.scene.entities[groupEntityIndex].id;
    [self pushUndoEntry:entry];
    [self markDocumentChangedWithLabel:@"Create Group"];
    [self rebuildMeshFromScene];
}

- (void)addSelectionToActiveGroup:(id)sender {
    (void)sender;
    if (!self.hasSelection || [self selectionIsPointEntity] || [self selectionIsPrefab] || [self selectionIsGroupedBrushEntity]) {
        return;
    }

    size_t targetEntityIndex = [self activeGroupEntityIndex];
    if (targetEntityIndex >= self.scene.entityCount || ![self entityIndexIsGroupedBrushEntity:targetEntityIndex]) {
        return;
    }

    SceneHistoryEntry* entry = [self captureHistoryEntry];
    if (!entry) {
        return;
    }

    size_t sourceEntityIndex = self.selectedEntityIndex;
    size_t groupedSolidIndex = 0;
    char errorBuffer[256] = { 0 };
    if (!vmf_scene_move_solid_to_entity(&_scene, sourceEntityIndex, self.selectedSolidIndex, targetEntityIndex, &groupedSolidIndex, errorBuffer, sizeof(errorBuffer))) {
        [self showError:[NSString stringWithUTF8String:errorBuffer]];
        return;
    }

    if (sourceEntityIndex < self.scene.entityCount && sourceEntityIndex != targetEntityIndex &&
        self.scene.entities[sourceEntityIndex].kind == VmfEntityKindBrush &&
        !self.scene.entities[sourceEntityIndex].isWorld &&
        self.scene.entities[sourceEntityIndex].solidCount == 0) {
        if (!vmf_scene_delete_entity(&_scene, sourceEntityIndex, errorBuffer, sizeof(errorBuffer))) {
            [self showError:[NSString stringWithUTF8String:errorBuffer]];
            return;
        }
        if (sourceEntityIndex < targetEntityIndex) {
            targetEntityIndex -= 1;
        }
    }

    self.hasSelection = YES;
    self.selectedEntityIndex = targetEntityIndex;
    self.selectedSolidIndex = groupedSolidIndex;
    self.hasFaceSelection = NO;
    self.selectedSideIndex = 0;
    self.activeGroupEntityId = self.scene.entities[targetEntityIndex].id;
    [self pushUndoEntry:entry];
    [self markDocumentChangedWithLabel:@"Add To Group"];
    [self rebuildMeshFromScene];
}

- (void)ungroupSelection:(id)sender {
    (void)sender;
    if (![self selectionIsGroupedBrushEntity]) {
        return;
    }

    SceneHistoryEntry* entry = [self captureHistoryEntry];
    if (!entry) {
        return;
    }

    size_t groupEntityIndex = self.selectedEntityIndex;
    size_t worldEntityIndex = 0;
    size_t lastSolidIndex = 0;
    char errorBuffer[256] = { 0 };
    while (groupEntityIndex < self.scene.entityCount && self.scene.entities[groupEntityIndex].solidCount > 0) {
        if (!vmf_scene_move_solid_to_entity(&_scene, groupEntityIndex, 0, worldEntityIndex, &lastSolidIndex, errorBuffer, sizeof(errorBuffer))) {
            [self showError:[NSString stringWithUTF8String:errorBuffer]];
            return;
        }
    }
    if (!vmf_scene_delete_entity(&_scene, groupEntityIndex, errorBuffer, sizeof(errorBuffer))) {
        [self showError:[NSString stringWithUTF8String:errorBuffer]];
        return;
    }

    self.hasSelection = YES;
    self.selectedEntityIndex = worldEntityIndex;
    self.selectedSolidIndex = lastSolidIndex;
    self.hasFaceSelection = NO;
    self.selectedSideIndex = 0;
    [self pushUndoEntry:entry];
    [self markDocumentChangedWithLabel:@"Ungroup"];
    [self rebuildMeshFromScene];
}

- (BOOL)selectSolidAtPoint:(Vec3)point plane:(VmfViewportPlane)plane {
    size_t entityCandidates[256];
    size_t solidCandidates[256];
    size_t candidateCount = sledgehammer_editor_logic_collect_pick_candidates_2d(&_scene,
                                                                                 point,
                                                                                 (int)plane,
                                                                                 entityCandidates,
                                                                                 solidCandidates,
                                                                                 sizeof(entityCandidates) / sizeof(entityCandidates[0]));
    BOOL found = candidateCount > 0 ? YES : NO;
    size_t bestEntityIndex = 0;
    size_t bestSolidIndex = 0;
    if (found) {
        size_t selectedCandidate = 0;
        for (size_t candidateIndex = 0; candidateIndex < candidateCount; ++candidateIndex) {
            if (!self.hasSelection) {
                break;
            }
            if (entityCandidates[candidateIndex] == self.selectedEntityIndex &&
                solidCandidates[candidateIndex] == self.selectedSolidIndex) {
                selectedCandidate = (candidateIndex + 1u) % candidateCount;
                break;
            }
        }
        bestEntityIndex = entityCandidates[selectedCandidate];
        bestSolidIndex = solidCandidates[selectedCandidate];
    }

    self.hasSelection = found;
    self.selectedEntityIndex = bestEntityIndex;
    self.selectedSolidIndex = bestSolidIndex;
    self.hasFaceSelection = NO;
    self.selectedSideIndex = 0;
    self.editingPrefab = found ? [self prefabContainingEntityIndex:bestEntityIndex solidIndex:bestSolidIndex] : nil;
    if (self.editorTool == VmfViewportEditorToolVertex) {
        [self endVertexEditSession:YES];
        if (found && ![self selectionIsPointEntity]) {
            [self startVertexEditSession];
        }
    }
    [self syncSelectionOverlay];
    return found;
}

- (void)viewport:(VmfViewport*)viewport requestSelectionAtPoint:(Vec3)point {
    if (!self.hasDocument) {
        return;
    }
    if (![self selectSolidAtPoint:point plane:viewport.plane]) {
        [self endVertexEditSession:YES];
        self.hasSelection = NO;
        self.hasFaceSelection = NO;
        [self syncSelectionOverlay];
    }
}

- (void)viewport:(VmfViewport*)viewport requestSelectionRayOrigin:(Vec3)origin direction:(Vec3)direction {
    if (!self.hasDocument) {
        return;
    }

    size_t candidateEntity[96];
    size_t candidateSolid[96];
    size_t candidateSide[96];
    BOOL candidateIsPointEntity[96];
    float candidateDistance[96];
    float candidateSize[96];
    size_t candidateCount = sledgehammer_selection_collect_scene_ray_candidates(&_scene,
                                                                                viewport,
                                                                                origin,
                                                                                direction,
                                                                                candidateEntity,
                                                                                candidateSolid,
                                                                                candidateSide,
                                                                                candidateIsPointEntity,
                                                                                candidateDistance,
                                                                                candidateSize,
                                                                                sizeof(candidateEntity) / sizeof(candidateEntity[0]));
    size_t pointEntityCandidates[64];
    float pointEntityDistances[64];
    float pointEntityRadii[64];
    size_t pointEntityCandidateCount = sledgehammer_editor_logic_collect_point_entity_ray_candidates(&_scene,
                                                                                                     origin,
                                                                                                     direction,
                                                                                                     pointEntityCandidates,
                                                                                                     pointEntityDistances,
                                                                                                     pointEntityRadii,
                                                                                                     sizeof(pointEntityCandidates) / sizeof(pointEntityCandidates[0]));
    for (size_t pointCandidateIndex = 0; pointCandidateIndex < pointEntityCandidateCount && candidateCount < sizeof(candidateEntity) / sizeof(candidateEntity[0]); ++pointCandidateIndex) {
        size_t entityIndex = pointEntityCandidates[pointCandidateIndex];
        if (entityIndex >= _scene.entityCount || _scene.entities[entityIndex].kind == VmfEntityKindModel) {
            continue;
        }
        candidateEntity[candidateCount] = entityIndex;
        candidateSolid[candidateCount] = 0;
        candidateSide[candidateCount] = 0;
        candidateIsPointEntity[candidateCount] = YES;
        candidateDistance[candidateCount] = pointEntityDistances[pointCandidateIndex];
        candidateSize[candidateCount] = fmaxf(pointEntityRadii[pointCandidateIndex], 1.0f);
        candidateCount += 1u;
    }

    if (candidateCount == 0) {
        self.hasSelection = NO;
        self.hasFaceSelection = NO;
        self.editingPrefab = nil;
        [self syncSelectionOverlay];
        return;
    }
    for (size_t i = 0; i < candidateCount; ++i) {
        size_t bestIndex = i;
        for (size_t j = i + 1; j < candidateCount; ++j) {
            if (candidateDistance[j] < candidateDistance[bestIndex] - 1e-3f ||
                (fabsf(candidateDistance[j] - candidateDistance[bestIndex]) <= 1e-3f &&
                 candidateSize[j] < candidateSize[bestIndex])) {
                bestIndex = j;
            }
        }
        if (bestIndex != i) {
            size_t tmpEntity = candidateEntity[i];
            size_t tmpSolid = candidateSolid[i];
            size_t tmpSide = candidateSide[i];
            BOOL tmpPoint = candidateIsPointEntity[i];
            float tmpDist = candidateDistance[i];
            float tmpSize = candidateSize[i];
            candidateEntity[i] = candidateEntity[bestIndex];
            candidateSolid[i] = candidateSolid[bestIndex];
            candidateSide[i] = candidateSide[bestIndex];
            candidateIsPointEntity[i] = candidateIsPointEntity[bestIndex];
            candidateDistance[i] = candidateDistance[bestIndex];
            candidateSize[i] = candidateSize[bestIndex];
            candidateEntity[bestIndex] = tmpEntity;
            candidateSolid[bestIndex] = tmpSolid;
            candidateSide[bestIndex] = tmpSide;
            candidateIsPointEntity[bestIndex] = tmpPoint;
            candidateDistance[bestIndex] = tmpDist;
            candidateSize[bestIndex] = tmpSize;
        }
    }

    size_t entityIndex = 0;
    size_t solidIndex = 0;
    size_t sideIndex = 0;
    size_t selectedCandidate = 0;
    for (size_t candidateIndex = 0; candidateIndex < candidateCount; ++candidateIndex) {
        if (!self.hasSelection) {
            break;
        }
        if (candidateEntity[candidateIndex] == self.selectedEntityIndex &&
            candidateSolid[candidateIndex] == self.selectedSolidIndex &&
            candidateIsPointEntity[candidateIndex] == [self selectionIsPointEntity]) {
            selectedCandidate = (candidateIndex + 1u) % candidateCount;
            break;
        }
    }

    entityIndex = candidateEntity[selectedCandidate];
    solidIndex = candidateSolid[selectedCandidate];
    sideIndex = candidateSide[selectedCandidate];
    if (candidateIsPointEntity[selectedCandidate]) {
            self.hasSelection = YES;
            self.selectedEntityIndex = entityIndex;
            self.selectedSolidIndex = 0;
            self.editingPrefab = nil;
            self.hasFaceSelection = NO;
            self.selectedSideIndex = 0;
            [self syncSelectionOverlay];
            return;
    }

    self.hasSelection = YES;
    self.selectedEntityIndex = entityIndex;
    self.selectedSolidIndex = solidIndex;
    self.editingPrefab = [self prefabContainingEntityIndex:entityIndex solidIndex:solidIndex];
    self.hasFaceSelection = self.textureApplicationModeActive && self.editingPrefab == nil;
    self.selectedSideIndex = self.editingPrefab ? 0 : sideIndex;
    [self syncSelectionOverlay];
}

@end

#pragma clang diagnostic pop
