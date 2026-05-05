#import "sledgehammer_viewer_app_internal.h"

#include "sledgehammer_editor_logic.h"

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
    size_t bestEntityIndex = 0;
    size_t bestSolidIndex = 0;
    BOOL found = sledgehammer_editor_logic_pick_scene_at_point_2d(&_scene,
                                                                  point,
                                                                  (int)plane,
                                                                  &bestEntityIndex,
                                                                  &bestSolidIndex) ? YES : NO;

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
    if (!vmf_scene_pick_ray(&_scene, origin, direction, &entityIndex, &solidIndex, &sideIndex, &hitPoint, errorBuffer, sizeof(errorBuffer))) {
        if ([self pickPointEntityRayOrigin:origin direction:direction outEntityIndex:&entityIndex]) {
            self.hasSelection = YES;
            self.selectedEntityIndex = entityIndex;
            self.selectedSolidIndex = 0;
            self.editingPrefab = nil;
            self.hasFaceSelection = NO;
            self.selectedSideIndex = 0;
            [self syncSelectionOverlay];
            return;
        }
        self.hasSelection = NO;
        self.hasFaceSelection = NO;
        self.editingPrefab = nil;
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