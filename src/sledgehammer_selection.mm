#import "sledgehammer_viewer_app_internal.h"

#include "sledgehammer_editor_logic.h"
#include <math.h>

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
    (void)viewport;
    if (!self.hasDocument) {
        return;
    }

    size_t entityIndex = 0;
    size_t solidIndex = 0;
    size_t sideIndex = 0;
    Vec3 hitPoint = vec3_make(0.0f, 0.0f, 0.0f);
    char errorBuffer[256] = { 0 };
    BOOL brushHit = vmf_scene_pick_ray(&_scene, origin, direction, &entityIndex, &solidIndex, &sideIndex, &hitPoint, errorBuffer, sizeof(errorBuffer)) ? YES : NO;
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
    if (!brushHit && pointEntityCandidateCount == 0) {
        self.hasSelection = NO;
        self.hasFaceSelection = NO;
        self.editingPrefab = nil;
        [self syncSelectionOverlay];
        return;
    }

    size_t candidateEntity[66];
    size_t candidateSolid[66];
    BOOL candidateIsPointEntity[66];
    float candidateDistance[66];
    float candidateSize[66];
    size_t candidateCount = 0;
    if (brushHit) {
        candidateEntity[candidateCount] = entityIndex;
        candidateSolid[candidateCount] = solidIndex;
        candidateIsPointEntity[candidateCount] = NO;
        candidateDistance[candidateCount] = vec3_length(vec3_sub(hitPoint, origin));
        Bounds3 brushBounds;
        char boundsErrorBuffer[128] = { 0 };
        float brushSize = 1024.0f;
        if (vmf_scene_solid_bounds(&_scene, entityIndex, solidIndex, &brushBounds, boundsErrorBuffer, sizeof(boundsErrorBuffer))) {
            Vec3 diag = vec3_sub(brushBounds.max, brushBounds.min);
            brushSize = fmaxf(1.0f, vec3_length(diag));
        }
        candidateSize[candidateCount] = brushSize;
        candidateCount += 1u;
    }
    for (size_t candidateIndex = 0; candidateIndex < pointEntityCandidateCount && candidateCount < sizeof(candidateEntity) / sizeof(candidateEntity[0]); ++candidateIndex) {
        candidateEntity[candidateCount] = pointEntityCandidates[candidateIndex];
        candidateSolid[candidateCount] = 0;
        candidateIsPointEntity[candidateCount] = YES;
        candidateDistance[candidateCount] = pointEntityDistances[candidateIndex];
        candidateSize[candidateCount] = fmaxf(pointEntityRadii[candidateIndex], 1.0f);
        candidateCount += 1u;
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
            BOOL tmpPoint = candidateIsPointEntity[i];
            float tmpDist = candidateDistance[i];
            float tmpSize = candidateSize[i];
            candidateEntity[i] = candidateEntity[bestIndex];
            candidateSolid[i] = candidateSolid[bestIndex];
            candidateIsPointEntity[i] = candidateIsPointEntity[bestIndex];
            candidateDistance[i] = candidateDistance[bestIndex];
            candidateSize[i] = candidateSize[bestIndex];
            candidateEntity[bestIndex] = tmpEntity;
            candidateSolid[bestIndex] = tmpSolid;
            candidateIsPointEntity[bestIndex] = tmpPoint;
            candidateDistance[bestIndex] = tmpDist;
            candidateSize[bestIndex] = tmpSize;
        }
    }

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
