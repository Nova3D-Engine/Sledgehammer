#import "sledgehammer_viewer_app_internal.h"

@implementation SceneHistoryEntry

- (void)dealloc {
    vmf_scene_free(&scene);
}

@end

@implementation ProceduralShapePrefab

- (id)copyWithZone:(NSZone*)zone {
    ProceduralShapePrefab* copy = [[[self class] allocWithZone:zone] init];
    copy.tool = self.tool;
    copy.bounds = self.bounds;
    copy.upAxis = self.upAxis;
    copy.runAxis = self.runAxis;
    copy.primaryValue = self.primaryValue;
    copy.secondaryValue = self.secondaryValue;
    copy.solidCount = self.solidCount;
    copy.historyLabel = self.historyLabel;
    copy.entityIndex = self.entityIndex;
    copy.startSolidIndex = self.startSolidIndex;
    return copy;
}

@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation ViewerAppDelegate (History)

- (void)rebuildHistoryMenu {
    [self.historyMenu removeAllItems];

    if (!self.hasDocument) {
        NSMenuItem* emptyItem = [[NSMenuItem alloc] initWithTitle:@"No document" action:nil keyEquivalent:@""];
        emptyItem.enabled = NO;
        [self.historyMenu addItem:emptyItem];
        return;
    }

    NSMenuItem* currentItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Current: %@", [self displayHistoryLabel:self.currentHistoryLabel fallback:@"Initial State"]] action:nil keyEquivalent:@""];
    currentItem.enabled = NO;
    [self.historyMenu addItem:currentItem];

    if (self.undoStack.count > 0) {
        [self.historyMenu addItem:[NSMenuItem separatorItem]];
        NSMenuItem* undoHeader = [[NSMenuItem alloc] initWithTitle:@"Undo To" action:nil keyEquivalent:@""];
        undoHeader.enabled = NO;
        [self.historyMenu addItem:undoHeader];
        for (NSInteger index = self.undoStack.count - 1; index >= 0; --index) {
            SceneHistoryEntry* entry = self.undoStack[(NSUInteger)index];
            NSInteger steps = self.undoStack.count - index;
            NSString* title = [NSString stringWithFormat:@"%@", [self displayHistoryLabel:entry->stateLabel fallback:@"Earlier State"]];
            NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title action:@selector(jumpToHistoryState:) keyEquivalent:@""];
            item.target = self;
            item.representedObject = @(steps * -1);
            [self.historyMenu addItem:item];
        }
    }

    if (self.redoStack.count > 0) {
        [self.historyMenu addItem:[NSMenuItem separatorItem]];
        NSMenuItem* redoHeader = [[NSMenuItem alloc] initWithTitle:@"Redo To" action:nil keyEquivalent:@""];
        redoHeader.enabled = NO;
        [self.historyMenu addItem:redoHeader];
        for (NSInteger index = self.redoStack.count - 1; index >= 0; --index) {
            SceneHistoryEntry* entry = self.redoStack[(NSUInteger)index];
            NSInteger steps = self.redoStack.count - index;
            NSString* title = [NSString stringWithFormat:@"%@", [self displayHistoryLabel:entry->stateLabel fallback:@"Later State"]];
            NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title action:@selector(jumpToHistoryState:) keyEquivalent:@""];
            item.target = self;
            item.representedObject = @(steps);
            [self.historyMenu addItem:item];
        }
    }
}

- (void)jumpToHistoryState:(id)sender {
    NSMenuItem* item = (NSMenuItem*)sender;
    NSInteger steps = [item.representedObject integerValue];
    if (steps < 0) {
        for (NSInteger index = 0; index < -steps; ++index) {
            [self undoAction:nil];
        }
    } else if (steps > 0) {
        for (NSInteger index = 0; index < steps; ++index) {
            [self redoAction:nil];
        }
    }
}

- (void)syncDirtyState {
    self.documentDirty = self.hasDocument && self.currentRevision != self.savedRevision;
}

- (void)resetRevisionTracking {
    self.currentRevision = 0;
    self.savedRevision = 0;
    self.nextRevision = 1;
    self.pendingRevision = -1;
    self.currentHistoryLabel = self.hasDocument ? @"Initial State" : @"No Document";
    self.pendingHistoryActionLabel = nil;
    [self syncDirtyState];
}

- (void)markDocumentChangedWithLabel:(NSString*)label {
    self.currentRevision = self.nextRevision;
    self.nextRevision += 1;
    self.currentHistoryLabel = [self displayHistoryLabel:label fallback:@"Change"];
    [self syncDirtyState];
}

- (void)resetHistory {
    [self.undoStack removeAllObjects];
    [self.redoStack removeAllObjects];
    self.pendingHistoryEntry = nil;
    self.pendingRevision = -1;
    self.pendingHistoryActionLabel = nil;
}

- (SceneHistoryEntry*)captureHistoryEntry {
    SceneHistoryEntry* entry = [[SceneHistoryEntry alloc] init];
    char errorBuffer[256] = { 0 };
    if (!vmf_scene_clone(&_scene, &entry->scene, errorBuffer, sizeof(errorBuffer))) {
        [self showError:[NSString stringWithUTF8String:errorBuffer]];
        return nil;
    }
    entry->revision = self.currentRevision;
    entry->stateLabel = [self.currentHistoryLabel copy];
    entry->prefabState = [[NSArray alloc] initWithArray:self.currentPrefabs copyItems:YES];
    entry->hasSelection = self.hasSelection;
    entry->selectedEntityIndex = self.selectedEntityIndex;
    entry->selectedSolidIndex = self.selectedSolidIndex;
    entry->hasFaceSelection = self.hasFaceSelection;
    entry->selectedSideIndex = self.selectedSideIndex;
    return entry;
}

- (void)pushUndoEntry:(SceneHistoryEntry*)entry {
    if (!entry) {
        return;
    }
    [self.undoStack addObject:entry];
    [self.redoStack removeAllObjects];
}

- (BOOL)restoreHistoryEntry:(SceneHistoryEntry*)entry {
    if (!entry) {
        return NO;
    }

    VmfScene restoredScene;
    char errorBuffer[256] = { 0 };
    if (!vmf_scene_clone(&entry->scene, &restoredScene, errorBuffer, sizeof(errorBuffer))) {
        [self showError:[NSString stringWithUTF8String:errorBuffer]];
        return NO;
    }

    vmf_scene_free(&_scene);
    self.scene = restoredScene;
    self.hasDocument = YES;
    self.hasSelection = entry->hasSelection;
    self.selectedEntityIndex = entry->selectedEntityIndex;
    self.selectedSolidIndex = entry->selectedSolidIndex;
    self.hasFaceSelection = entry->hasFaceSelection;
    self.selectedSideIndex = entry->selectedSideIndex;
    self.currentPrefabs = entry->prefabState ? [NSMutableArray arrayWithArray:entry->prefabState] : [NSMutableArray array];
    self.editingPrefab = nil;
    self.currentRevision = entry->revision;
    self.currentHistoryLabel = [entry->stateLabel copy];
    self.pendingHistoryEntry = nil;
    self.pendingRevision = -1;
    self.pendingHistoryActionLabel = nil;
    [self syncDirtyState];
    return [self rebuildMeshFromScene];
}

- (BOOL)beginPendingHistoryEntryWithLabel:(NSString*)label {
    if (self.pendingHistoryEntry) {
        return YES;
    }
    self.pendingHistoryEntry = [self captureHistoryEntry];
    if (self.pendingHistoryEntry) {
        self.pendingRevision = self.nextRevision;
        self.currentRevision = self.pendingRevision;
        self.pendingHistoryActionLabel = [self displayHistoryLabel:label fallback:@"Edit Brush"];
        self.currentHistoryLabel = self.pendingHistoryActionLabel;
        [self syncDirtyState];
    }
    return self.pendingHistoryEntry != nil;
}

- (void)commitPendingHistoryEntry {
    if (!self.pendingHistoryEntry) {
        return;
    }
    [self.undoStack addObject:self.pendingHistoryEntry];
    [self.redoStack removeAllObjects];
    self.nextRevision = MAX(self.nextRevision, self.pendingRevision + 1);
    self.pendingHistoryEntry = nil;
    self.pendingRevision = -1;
    self.pendingHistoryActionLabel = nil;
    [self syncDirtyState];
}

- (void)discardPendingHistoryEntry {
    if (self.pendingHistoryEntry) {
        self.currentRevision = self.pendingHistoryEntry->revision;
        self.currentHistoryLabel = [self.pendingHistoryEntry->stateLabel copy];
    }
    self.pendingHistoryEntry = nil;
    self.pendingRevision = -1;
    self.pendingHistoryActionLabel = nil;
    [self syncDirtyState];
}

- (BOOL)restoreSceneFromHistoryEntrySnapshot:(SceneHistoryEntry*)entry errorBuffer:(char*)errorBuffer size:(size_t)errorBufferSize {
    if (!entry) {
        snprintf(errorBuffer, errorBufferSize, "missing history snapshot");
        return NO;
    }

    VmfScene restoredScene;
    memset(&restoredScene, 0, sizeof(restoredScene));
    if (!vmf_scene_clone(&entry->scene, &restoredScene, errorBuffer, errorBufferSize)) {
        return NO;
    }

    vmf_scene_free(&_scene);
    self.scene = restoredScene;
    self.hasDocument = YES;
    self.hasSelection = entry->hasSelection;
    self.selectedEntityIndex = entry->selectedEntityIndex;
    self.selectedSolidIndex = entry->selectedSolidIndex;
    self.hasFaceSelection = entry->hasFaceSelection;
    self.selectedSideIndex = entry->selectedSideIndex;
    self.currentPrefabs = entry->prefabState ? [NSMutableArray arrayWithArray:entry->prefabState] : [NSMutableArray array];
    return YES;
}

- (BOOL)restoreSceneFromPendingHistorySnapshot:(char*)errorBuffer size:(size_t)errorBufferSize {
    return [self restoreSceneFromHistoryEntrySnapshot:self.pendingHistoryEntry errorBuffer:errorBuffer size:errorBufferSize];
}

- (ProceduralShapePrefab*)prefabContainingEntityIndex:(size_t)entityIndex solidIndex:(size_t)solidIndex {
    for (ProceduralShapePrefab* prefab in self.currentPrefabs) {
        if (prefab.entityIndex != entityIndex) {
            continue;
        }
        if (solidIndex >= prefab.startSolidIndex && solidIndex < prefab.startSolidIndex + prefab.solidCount) {
            return prefab;
        }
    }
    return nil;
}

- (void)shiftPrefabIndicesInEntity:(size_t)entityIndex startingAtSolidIndex:(size_t)solidIndex delta:(NSInteger)delta excludingPrefab:(ProceduralShapePrefab*)excludedPrefab {
    for (ProceduralShapePrefab* prefab in self.currentPrefabs) {
        if (prefab == excludedPrefab || prefab.entityIndex != entityIndex) {
            continue;
        }
        if (prefab.startSolidIndex >= solidIndex) {
            prefab.startSolidIndex = (size_t)((NSInteger)prefab.startSolidIndex + delta);
        }
    }
}

- (void)removePrefab:(ProceduralShapePrefab*)prefab {
    if (!prefab) {
        return;
    }
    [self.currentPrefabs removeObject:prefab];
    if (self.editingPrefab == prefab) {
        self.editingPrefab = nil;
    }
}

- (void)collapseEditingPrefab:(id)sender {
    (void)sender;
    [self removePrefab:self.editingPrefab];
}

- (BOOL)selectionIsPrefab {
    return self.hasSelection && [self prefabContainingEntityIndex:self.selectedEntityIndex solidIndex:self.selectedSolidIndex] != nil;
}

- (void)undoAction:(id)sender {
    (void)sender;
    if (self.undoStack.count == 0) {
        return;
    }

    SceneHistoryEntry* currentEntry = [self captureHistoryEntry];
    if (!currentEntry) {
        return;
    }
    SceneHistoryEntry* entry = self.undoStack.lastObject;
    [self.undoStack removeLastObject];
    [self.redoStack addObject:currentEntry];
    [self restoreHistoryEntry:entry];
}

- (void)redoAction:(id)sender {
    (void)sender;
    if (self.redoStack.count == 0) {
        return;
    }

    SceneHistoryEntry* currentEntry = [self captureHistoryEntry];
    if (!currentEntry) {
        return;
    }
    SceneHistoryEntry* entry = self.redoStack.lastObject;
    [self.redoStack removeLastObject];
    [self.undoStack addObject:currentEntry];
    [self restoreHistoryEntry:entry];
}

@end
#pragma clang diagnostic pop