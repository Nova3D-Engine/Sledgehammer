#ifndef VIEWPORT_H
#define VIEWPORT_H

#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>

#include "nova_scene_ecs.h"

#include "vmf_editor.h"
#include "vmf_geometry.h"

typedef NS_ENUM(NSUInteger, VmfViewportDimension) {
    VmfViewportDimension2D = 0,
    VmfViewportDimension3D = 1,
};

typedef NS_ENUM(NSUInteger, VmfViewportPlane) {
    VmfViewportPlaneXY = 0,
    VmfViewportPlaneXZ = 1,
    VmfViewportPlaneZY = 2,
};

typedef NS_ENUM(NSUInteger, VmfViewportRenderMode) {
    VmfViewportRenderModeShaded = 0,
    VmfViewportRenderModeWireframe = 1,
};

typedef NS_ENUM(NSUInteger, VmfViewportEditorTool) {
    VmfViewportEditorToolSelect = 0,
    VmfViewportEditorToolVertex = 1,
    VmfViewportEditorToolBlock = 2,
    VmfViewportEditorToolCylinder = 3,
    VmfViewportEditorToolRamp = 4,
    VmfViewportEditorToolStairs = 5,
    VmfViewportEditorToolArch = 6,
    VmfViewportEditorToolClip = 7,
};

typedef NS_ENUM(NSUInteger, VmfViewportSelectionTransform) {
    VmfViewportSelectionTransformNone = 0,
    VmfViewportSelectionTransformMove,
    VmfViewportSelectionTransformResize,
};

typedef NS_ENUM(NSUInteger, VmfViewportSelectionEdge) {
    VmfViewportSelectionEdgeNone = 0,
    VmfViewportSelectionEdgeMinU,
    VmfViewportSelectionEdgeMaxU,
    VmfViewportSelectionEdgeMinV,
    VmfViewportSelectionEdgeMaxV,
};

@class VmfViewport;

@protocol VmfViewportDelegate <NSObject>

- (void)viewportDidBecomeActive:(VmfViewport*)viewport;
- (void)viewportDidRequestOpenDroppedPath:(NSString*)path;
- (void)viewport:(VmfViewport*)viewport handleKeyDown:(NSEvent*)event;
- (void)viewport:(VmfViewport*)viewport handleKeyUp:(NSEvent*)event;
- (void)viewport:(VmfViewport*)viewport requestSelectionAtPoint:(Vec3)point;
- (void)viewport:(VmfViewport*)viewport requestSelectionRayOrigin:(Vec3)origin direction:(Vec3)direction;
- (void)viewport:(VmfViewport*)viewport requestHoverRayOrigin:(Vec3)origin direction:(Vec3)direction;
- (void)viewport:(VmfViewport*)viewport requestSampleRayOrigin:(Vec3)origin direction:(Vec3)direction;
- (void)viewport:(VmfViewport*)viewport requestPaintRayOrigin:(Vec3)origin direction:(Vec3)direction;
/* Cmd+right-click: set material AND world-align UVs for contiguous texturing */
- (void)viewport:(VmfViewport*)viewport requestPaintAlignRayOrigin:(Vec3)origin direction:(Vec3)direction;
- (void)viewport:(VmfViewport*)viewport requestFaceSelectionOnEdge:(VmfViewportSelectionEdge)edge;
- (void)viewport:(VmfViewport*)viewport updateSelectionBounds:(Bounds3)bounds commit:(BOOL)commit transform:(VmfViewportSelectionTransform)transform;
- (void)viewport:(VmfViewport*)viewport updateSelectionVertexAtIndex:(size_t)vertexIndex position:(Vec3)position commit:(BOOL)commit;
- (void)viewport:(VmfViewport*)viewport updateSelectionVerticesAtIndices:(const size_t*)indices positions:(const Vec3*)positions count:(size_t)count commit:(BOOL)commit;
- (void)viewport:(VmfViewport*)viewport updateSelectionEdgeFirstSideIndex:(size_t)firstSideIndex secondSideIndex:(size_t)secondSideIndex offset:(Vec3)offset commit:(BOOL)commit;
- (void)viewport:(VmfViewport*)viewport clipSelectionFrom:(Vec3)start to:(Vec3)end;
- (void)viewport:(VmfViewport*)viewport createBlockWithBounds:(Bounds3)bounds;
- (void)viewport:(VmfViewport*)viewport createCylinderWithBounds:(Bounds3)bounds;
- (void)viewport:(VmfViewport*)viewport createRampWithBounds:(Bounds3)bounds;
- (void)viewport:(VmfViewport*)viewport createStairsWithBounds:(Bounds3)bounds;
- (void)viewport:(VmfViewport*)viewport createArchWithBounds:(Bounds3)bounds;

@end

@interface VmfViewport : NSView

@property(nonatomic, weak) id<VmfViewportDelegate> delegate;
@property(nonatomic, copy, readonly) NSString* title;
@property(nonatomic, assign, readonly) VmfViewportDimension dimension;
@property(nonatomic, assign, readonly) VmfViewportPlane plane;
@property(nonatomic, assign) VmfViewportRenderMode renderMode;
@property(nonatomic, assign) VmfViewportEditorTool editorTool;
@property(nonatomic, assign, getter=isActive) BOOL active;
@property(nonatomic, assign) BOOL selectionEditable;
@property(nonatomic, assign) CGFloat gridSize;
@property(nonatomic, copy) NSString* clipModeLabel;
@property(nonatomic, assign) VmfClipKeepMode clipKeepMode;
@property(nonatomic, assign, readonly) BOOL freeLookActive;
@property(nonatomic, strong, readonly) MTKView* metalView;

- (instancetype)initWithFrame:(NSRect)frame
                       device:(id<MTLDevice>)device
                        title:(NSString*)title
                    dimension:(VmfViewportDimension)dimension
                        plane:(VmfViewportPlane)plane
                   renderMode:(VmfViewportRenderMode)renderMode;
- (void)updateMesh:(const ViewerMesh*)mesh;
- (void)setSceneWorld:(NovaSceneWorld*)sceneWorld;
- (void)setTextureDirectory:(NSString*)path;
- (void)clearTextureMissCache;
- (void)clearTextureCache;
- (void)frameScene;
- (void)setMovementForward:(BOOL)forward backward:(BOOL)backward left:(BOOL)left right:(BOOL)right;
- (void)setSelectionBounds:(Bounds3)bounds visible:(BOOL)visible;
- (void)setSelectionVertices:(const Vec3*)vertices count:(size_t)count visible:(BOOL)visible;
- (void)setSelectionEdges:(const VmfSolidEdge*)edges count:(size_t)count visible:(BOOL)visible;
- (void)setSelectedFaceEdge:(VmfViewportSelectionEdge)edge;
- (void)setSelectedFaceHighlightEntityIndex:(size_t)entityIndex solidIndex:(size_t)solidIndex sideIndex:(size_t)sideIndex visible:(BOOL)visible;
- (void)setHighlightedFaceEntityIndex:(size_t)entityIndex solidIndex:(size_t)solidIndex sideIndex:(size_t)sideIndex visible:(BOOL)visible;
- (void)setPrimaryLightPosition:(Vec3)position color:(Vec3)color intensity:(float)intensity range:(float)range enabled:(BOOL)enabled;
- (void)setCreationBounds:(Bounds3)bounds visible:(BOOL)visible;
- (void)setVertexEditIsInvalid:(BOOL)invalid;
- (void)setVertexEditPreviewEdges:(const ViewerVertex*)vertices count:(size_t)count;
- (void)clearVertexEditPreview;
- (BOOL)hasPendingClipLine;
- (BOOL)commitPendingClipLine;
- (void)clearEditorOverlay;

@end

#endif
