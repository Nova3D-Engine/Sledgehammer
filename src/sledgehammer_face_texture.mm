#import "sledgehammer_viewer_app_internal.h"

#include "sledgehammer_editor_logic.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation ViewerAppDelegate (FaceTexture)

- (nullable NSString*)texturePathForInspectorMaterial:(NSString*)materialName {
    NSString* normalized;
    if (!self.materialsDirectory || materialName.length == 0) {
        return nil;
    }
    normalized = materialName.lowercaseString;
    if ([normalized isEqualToString:@"grid"]) {
        normalized = @"dev_grid";
    }
    return [[self.materialsDirectory stringByAppendingPathComponent:normalized] stringByAppendingPathExtension:@"png"];
}

- (BOOL)textureDimensionsForMaterial:(NSString*)materialName width:(float*)outWidth height:(float*)outHeight {
    NSString* path = [self texturePathForInspectorMaterial:materialName];
    NSImage* image;
    NSRect proposedRect = NSZeroRect;
    CGImageRef cgImage;
    if (path.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return NO;
    }
    image = [[NSImage alloc] initWithContentsOfFile:path];
    if (!image) {
        return NO;
    }
    cgImage = [image CGImageForProposedRect:&proposedRect context:nil hints:nil];
    if (!cgImage) {
        return NO;
    }
    if (outWidth != NULL) *outWidth = (float)CGImageGetWidth(cgImage);
    if (outHeight != NULL) *outHeight = (float)CGImageGetHeight(cgImage);
    return CGImageGetWidth(cgImage) > 0 && CGImageGetHeight(cgImage) > 0;
}

- (void)refreshFaceTextureInspector {
    [self buildFaceTextureInspectorView];

    const VmfSide* side = sledgehammer_editor_logic_selected_face_side(&_scene,
                                                                       self.hasSelection,
                                                                       self.hasFaceSelection,
                                                                       self.editingPrefab != nil,
                                                                       self.selectedEntityIndex,
                                                                       self.selectedSolidIndex,
                                                                       self.selectedSideIndex);
    self.faceTextureInspectorView.hidden = side == NULL;
    if (side == NULL) {
        return;
    }

    float textureWidth = 0.0f;
    float textureHeight = 0.0f;
    NSString* materialName = [NSString stringWithUTF8String:side->material];
    NSString* materialDetails = materialName.length > 0 ? materialName : @"(unnamed)";
    if ([self textureDimensionsForMaterial:materialName width:&textureWidth height:&textureHeight]) {
        materialDetails = [materialDetails stringByAppendingFormat:@"  %.0fx%.0f", textureWidth, textureHeight];
    }

    self.faceTextureMaterialLabel.stringValue = [NSString stringWithFormat:@"Material: %@", materialDetails];
    self.faceTextureUScaleField.stringValue = [NSString stringWithFormat:@"%.4f", side->uscale];
    self.faceTextureVScaleField.stringValue = [NSString stringWithFormat:@"%.4f", side->vscale];
    self.faceTextureUOffsetField.stringValue = [NSString stringWithFormat:@"%.2f", side->uoffset];
    self.faceTextureVOffsetField.stringValue = [NSString stringWithFormat:@"%.2f", side->voffset];
    self.faceTextureRotationField.stringValue = [NSString stringWithFormat:@"%.2f", sledgehammer_editor_logic_texture_rotation_degrees_for_side(side)];
}

- (void)commitFaceTextureEditWithLabel:(NSString*)label
                             operation:(BOOL (^)(size_t entityIndex,
                                                 size_t solidIndex,
                                                 size_t sideIndex,
                                                 char* errorBuffer,
                                                 size_t errorBufferSize))operation {
    SceneHistoryEntry* entry;
    char errorBuffer[256] = { 0 };

    if (!operation || ![self selectionHasEditableFaceTexture]) {
        return;
    }

    entry = [self captureHistoryEntry];
    if (!entry) {
        return;
    }

    if (!operation(self.selectedEntityIndex,
                   self.selectedSolidIndex,
                   self.selectedSideIndex,
                   errorBuffer,
                   sizeof(errorBuffer))) {
        [self showError:[NSString stringWithUTF8String:errorBuffer]];
        [self refreshFaceTextureInspector];
        return;
    }

    [self pushUndoEntry:entry];
    [self markDocumentChangedWithLabel:label];
    [self rebuildMeshFromScene];
}

- (void)faceTextureTransformChanged:(id)sender {
    (void)sender;

    float uScale = (float)self.faceTextureUScaleField.doubleValue;
    float vScale = (float)self.faceTextureVScaleField.doubleValue;
    float uOffset = (float)self.faceTextureUOffsetField.doubleValue;
    float vOffset = (float)self.faceTextureVOffsetField.doubleValue;

    [self commitFaceTextureEditWithLabel:@"Edit Face Texture Transform"
                               operation:^BOOL(size_t entityIndex,
                                               size_t solidIndex,
                                               size_t sideIndex,
                                               char* errorBuffer,
                                               size_t errorBufferSize) {
        return vmf_scene_set_side_texture_transform(&_scene,
                                                    entityIndex,
                                                    solidIndex,
                                                    sideIndex,
                                                    uOffset,
                                                    vOffset,
                                                    uScale,
                                                    vScale,
                                                    errorBuffer,
                                                    errorBufferSize);
    }];
}

- (void)faceTextureRotationChanged:(id)sender {
    (void)sender;

    const VmfSide* side = sledgehammer_editor_logic_selected_face_side(&_scene,
                                                                       self.hasSelection,
                                                                       self.hasFaceSelection,
                                                                       self.editingPrefab != nil,
                                                                       self.selectedEntityIndex,
                                                                       self.selectedSolidIndex,
                                                                       self.selectedSideIndex);
    float targetDegrees;
    float deltaDegrees;

    if (side == NULL) {
        return;
    }

    targetDegrees = (float)self.faceTextureRotationField.doubleValue;
    deltaDegrees = targetDegrees - sledgehammer_editor_logic_texture_rotation_degrees_for_side(side);
    if (fabsf(deltaDegrees) < 1e-4f) {
        return;
    }

    [self commitFaceTextureEditWithLabel:@"Rotate Face Texture"
                               operation:^BOOL(size_t entityIndex,
                                               size_t solidIndex,
                                               size_t sideIndex,
                                               char* errorBuffer,
                                               size_t errorBufferSize) {
        return vmf_scene_rotate_side_texture(&_scene,
                                             entityIndex,
                                             solidIndex,
                                             sideIndex,
                                             deltaDegrees,
                                             errorBuffer,
                                             errorBufferSize);
    }];
}

- (void)faceTextureFlipPressed:(id)sender {
    NSButton* button = (NSButton*)sender;
    int flipU = button.tag == 0 ? 1 : 0;
    int flipV = button.tag == 1 ? 1 : 0;
    NSString* label = flipU ? @"Flip Face Texture U" : @"Flip Face Texture V";

    [self commitFaceTextureEditWithLabel:label
                               operation:^BOOL(size_t entityIndex,
                                               size_t solidIndex,
                                               size_t sideIndex,
                                               char* errorBuffer,
                                               size_t errorBufferSize) {
        return vmf_scene_flip_side_texture(&_scene,
                                           entityIndex,
                                           solidIndex,
                                           sideIndex,
                                           flipU,
                                           flipV,
                                           errorBuffer,
                                           errorBufferSize);
    }];
}

- (void)faceTextureJustifyPressed:(id)sender {
    NSButton* button = (NSButton*)sender;
    const VmfSide* side = sledgehammer_editor_logic_selected_face_side(&_scene,
                                                                       self.hasSelection,
                                                                       self.hasFaceSelection,
                                                                       self.editingPrefab != nil,
                                                                       self.selectedEntityIndex,
                                                                       self.selectedSolidIndex,
                                                                       self.selectedSideIndex);
    float textureWidth = 0.0f;
    float textureHeight = 0.0f;
    NSString* materialName;

    if (side == NULL) {
        return;
    }

    materialName = [NSString stringWithUTF8String:side->material];
    if (![self textureDimensionsForMaterial:materialName width:&textureWidth height:&textureHeight]) {
        [self showError:[NSString stringWithFormat:@"Missing texture dimensions for %@", materialName.length > 0 ? materialName : @"selected material"]];
        [self refreshFaceTextureInspector];
        return;
    }

    [self commitFaceTextureEditWithLabel:@"Justify Face Texture"
                               operation:^BOOL(size_t entityIndex,
                                               size_t solidIndex,
                                               size_t sideIndex,
                                               char* errorBuffer,
                                               size_t errorBufferSize) {
        return vmf_scene_justify_side_texture(&_scene,
                                              entityIndex,
                                              solidIndex,
                                              sideIndex,
                                              (VmfTextureJustifyMode)button.tag,
                                              textureWidth,
                                              textureHeight,
                                              errorBuffer,
                                              errorBufferSize);
    }];
}

@end
#pragma clang diagnostic pop