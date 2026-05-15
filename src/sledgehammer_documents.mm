#import "sledgehammer_viewer_app_internal.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <fcntl.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation ViewerAppDelegate (SledgehammerDocuments)

- (void)openDocument:(id)sender {
    (void)sender;
    if (![self confirmDiscardChangesForAction:@"opening another map"]) {
        return;
    }
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.allowedContentTypes = @[ [UTType typeWithFilenameExtension:@"slg"], [UTType typeWithFilenameExtension:@"vmf"] ];
    panel.message = @"Choose a Sledgehammer scene file or a folder to recursively scan for scenes.";
    panel.prompt = @"Open";
    if ([panel runModal] == NSModalResponseOK) {
        [self openPath:panel.URL.path];
    }
}

- (BOOL)saveDocumentIfNeeded {
    if (!self.hasDocument) {
        return YES;
    }
    if (self.currentPath.length == 0) {
        return [self saveDocumentAsWithPrompt];
    }

    char errorBuffer[512] = { 0 };
    if (!vmf_scene_save(self.currentPath.fileSystemRepresentation, &_scene, errorBuffer, sizeof(errorBuffer))) {
        [self showError:[NSString stringWithUTF8String:errorBuffer]];
        return NO;
    }
    self.savedRevision = self.currentRevision;
    [self syncDirtyState];
    [self updateWindowTitle];
    [self updateChrome];
    return YES;
}

- (BOOL)saveDocumentAsWithPrompt {
    if (!self.hasDocument) {
        return YES;
    }
    NSSavePanel* panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[ [UTType typeWithFilenameExtension:@"slg"] ];
    panel.nameFieldStringValue = self.currentPath.lastPathComponent.length > 0 ? self.currentPath.lastPathComponent : @"untitled.slg";
    if ([panel runModal] != NSModalResponseOK) {
        return NO;
    }
    self.currentPath = panel.URL.path;
    return [self saveDocumentIfNeeded];
}

- (BOOL)confirmDiscardChangesForAction:(NSString*)actionDescription {
    if (!self.hasDocument || !self.documentDirty) {
        return YES;
    }

    NSString* documentName = self.currentPath.lastPathComponent.length > 0 ? self.currentPath.lastPathComponent : @"Untitled";
    NSAlert* alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = [NSString stringWithFormat:@"Save changes to %@?", documentName];
    alert.informativeText = [NSString stringWithFormat:@"Your changes will be lost if you continue %@ without saving.", actionDescription];
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Don't Save"];
    [alert addButtonWithTitle:@"Cancel"];

    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) {
        return [self saveDocumentIfNeeded];
    }
    if (response == NSAlertSecondButtonReturn) {
        return YES;
    }
    return NO;
}

- (void)openPath:(NSString*)path {
    if (path.length == 0) {
        return;
    }

    if (![self confirmDiscardChangesForAction:@"opening another map"]) {
        return;
    }

    file_index_free(&_fileIndex);

    char errorBuffer[512] = { 0 };
    if (!file_index_build(path.fileSystemRepresentation, &_fileIndex, errorBuffer, sizeof(errorBuffer))) {
        [self showError:[NSString stringWithUTF8String:errorBuffer]];
        return;
    }

    const char* firstPath = file_index_current(&_fileIndex);
    if (firstPath != NULL) {
        [self loadVmfAtPath:[NSString stringWithUTF8String:firstPath]];
    }
}

- (void)resetDocumentState {
    [self endVertexEditSession:NO];
    vmf_scene_free(&_scene);
    viewer_mesh_free(&_mesh);
    [self resetHistory];
    [self resetRevisionTracking];
    [self.currentPrefabs removeAllObjects];
    self.editingPrefab = nil;
    self.hasDocument = NO;
    self.hasSelection = NO;
    self.selectedEntityIndex = 0;
    self.selectedSolidIndex = 0;
    self.hasFaceSelection = NO;
    self.selectedSideIndex = 0;
    self.currentPath = nil;
    for (VmfViewport* viewport in self.viewports) {
        [viewport updateMesh:NULL];
        [viewport clearEditorOverlay];
    }
}

- (void)loadVmfAtPath:(NSString*)path {
    [self resetDocumentState];

    VmfScene scene;
    char errorBuffer[512] = { 0 };
    if (!vmf_scene_load(path.fileSystemRepresentation, &scene, errorBuffer, sizeof(errorBuffer))) {
        [self showError:[NSString stringWithUTF8String:errorBuffer]];
        return;
    }

    self.scene = scene;
    self.hasDocument = YES;
    self.currentPath = path;
    [self resetRevisionTracking];
    self.currentHistoryLabel = [NSString stringWithFormat:@"Open %@", path.lastPathComponent];
    [self rebuildMeshFromScene];
    [self frameAllViewports];
    NSLog(@"Loaded scene %@ with %zu vertices", path, self.mesh.vertexCount);
}

- (void)saveDocument:(id)sender {
    (void)sender;
    [self saveDocumentIfNeeded];
}

- (void)saveDocumentAs:(id)sender {
    (void)sender;
    [self saveDocumentAsWithPrompt];
}

- (void)reloadDocument:(id)sender {
    (void)sender;
    if (self.currentPath.length > 0 && [self confirmDiscardChangesForAction:@"reloading the current map"]) {
        [self loadVmfAtPath:self.currentPath];
    }
}

- (void)setMaterialsDirectory:(NSString*)materialsDirectory {
    _materialsDirectory = [materialsDirectory copy];
    NSLog(@"[materials] content root set to: %@", materialsDirectory);
    for (VmfViewport* viewport in self.viewports) {
        [viewport setTextureDirectory:materialsDirectory];
    }
    [self startWatchingMaterialsDirectory:materialsDirectory];
    [self updateMaterialBrowser];
}

- (void)startWatchingMaterialsDirectory:(NSString*)path {
    [self stopWatchingMaterialsDirectory];
    if (path.length == 0) {
        return;
    }

    int fd = open(path.fileSystemRepresentation, O_EVTONLY);
    if (fd < 0) {
        return;
    }

    _directoryWatchFd = fd;
    __weak __typeof__(self) weakSelf = self;
    _directoryWatchSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE,
                                                   (uintptr_t)fd,
                                                   DISPATCH_VNODE_WRITE | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_ATTRIB,
                                                   dispatch_get_main_queue());
    dispatch_source_set_event_handler(_directoryWatchSource, ^{
        [weakSelf materialsDirectoryDidChange];
    });
    dispatch_source_set_cancel_handler(_directoryWatchSource, ^{
        close(fd);
    });
    dispatch_resume(_directoryWatchSource);
    NSLog(@"[materials] watching directory for changes");
}

- (void)stopWatchingMaterialsDirectory {
    if (_directoryWatchSource != nil) {
        dispatch_source_cancel(_directoryWatchSource);
        _directoryWatchSource = nil;
        _directoryWatchFd = -1;
    }
}

- (void)materialsDirectoryDidChange {
    NSLog(@"[materials] directory changed — refreshing");
    for (VmfViewport* viewport in self.viewports) {
        [viewport clearTextureCache];
    }
    [self updateMaterialBrowser];
    for (VmfViewport* viewport in self.viewports) {
        [viewport.metalView setNeedsDisplay:YES];
    }
}

- (void)chooseTexturesFolder:(id)sender {
    (void)sender;
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.title = @"Select Content Folder";
    panel.message = @"Choose the content root containing materials, textures, models, and icons.";
    if (self.materialsDirectory != nil) {
        panel.directoryURL = [NSURL fileURLWithPath:self.materialsDirectory];
    }
    if ([panel runModal] != NSModalResponseOK) {
        return;
    }
    NSString* path = panel.URL.path;
    self.materialsDirectory = path;
    [[NSUserDefaults standardUserDefaults] setObject:path forKey:@"materialsDirectory"];
}

@end
#pragma clang diagnostic pop
