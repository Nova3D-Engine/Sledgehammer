#ifndef SLEDGEHAMMER_VIEWPORT_INTERNAL_H
#define SLEDGEHAMMER_VIEWPORT_INTERNAL_H

#import "viewport.h"

#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

#include "novamodel_asset.h"
#include "nova_scene_data.h"
#include "nova_tool_metal.h"

#include <imgui.h>
#include <ImGuizmo.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"

typedef NS_OPTIONS(NSUInteger, CameraMovement) {
    CameraMovementForward = 1 << 0,
    CameraMovementBackward = 1 << 1,
    CameraMovementLeft = 1 << 2,
    CameraMovementRight = 1 << 3,
    CameraMovementUp = 1 << 4,
    CameraMovementDown = 1 << 5,
};

typedef NS_ENUM(NSUInteger, ViewportDragMode) {
    ViewportDragModeNone = 0,
    ViewportDragModePan,
    ViewportDragModeCreateBlock,
    ViewportDragModeMoveSelection,
    ViewportDragModeResizeSelection,
    ViewportDragModeMoveVertex,
    ViewportDragModeMoveEdge,
    ViewportDragModeDrawClipLine,
};

typedef NS_ENUM(NSUInteger, ViewportHandle) {
    ViewportHandleNone = 0,
    ViewportHandleBody,
    ViewportHandleMinUMinV,
    ViewportHandleMaxUMinV,
    ViewportHandleMaxUMaxV,
    ViewportHandleMinUMaxV,
    ViewportHandleMinUMidV,
    ViewportHandleMaxUMidV,
    ViewportHandleMidUMinV,
    ViewportHandleMidUMaxV,
};

@class ViewportMetalView;
@class ViewportOverlayView;

@interface VmfViewport (Internal)

- (BOOL)handleViewportKeyDown:(NSEvent*)event;
- (BOOL)handleViewportKeyUp:(NSEvent*)event;
- (void)handleViewportMouseDownAtPoint:(NSPoint)point;
- (void)handleViewportMouseUpAtPoint:(NSPoint)point;
- (void)handleViewportPrimaryDragWithDelta:(NSPoint)delta alternate:(BOOL)alternate;
- (BOOL)handleViewportSecondaryMouseDown;
- (void)handleViewportSecondaryDragWithDelta:(NSPoint)delta;
- (void)handleViewportSecondaryMouseUp;
- (void)handleViewportScrollDelta:(CGFloat)deltaY;
- (void)handleViewportDroppedPath:(NSString*)path;
- (Vec3)dropPlacementPointForViewPoint:(NSPoint)point;
- (void)handleViewportMouseHoverAtPoint:(NSPoint)point;
- (void)handleViewportSecondaryClickAtPoint:(NSPoint)point modifierFlags:(NSEventModifierFlags)flags;
- (void)drawEditorOverlay;
- (Vec3)rayDirectionForViewPoint:(NSPoint)point;
- (nullable id<MTLTexture>)cachedTextureForMaterial:(NSString*)material;
- (nullable NSDictionary<NSString*, id>*)cachedTextureDataForMaterial:(NSString*)material;
- (nullable id<MTLTexture>)textureFromSceneTexture:(const NovaSceneTexture*)sceneTexture;
- (nullable id<MTLTexture>)cachedTextureForModelAssetPath:(NSString*)assetPath sourceMaterialIndex:(int)sourceMaterialIndex;
- (nullable id<MTLTexture>)previewBakedDebugTextureForKey:(NSString*)key;
- (BOOL)shouldLogTextureMissAtPath:(NSString*)fullPath;
- (void)buildPreviewBakePanelIfNeeded;
- (void)syncPreviewBakePanel;
- (void)applyBakedVertexLighting:(const Vec3*)bakedLighting count:(size_t)count;
- (nullable id<MTLComputePipelineState>)hwrtBakePipelineState;
- (BOOL)encodeGizmoOverlayOnCommandBuffer:(id<MTLCommandBuffer>)commandBuffer drawable:(id<CAMetalDrawable>)drawable errorMessage:(char*)errorMessage capacity:(size_t)errorMessageCapacity;
- (BOOL)gizmoConsumesPrimaryMouse;
- (void)syncHeavyRendererSceneFromMesh:(const ViewerMesh*)mesh;
- (BOOL)initializeHeavyRenderer;

@end

@interface VmfViewport () <MTKViewDelegate>

@property(nonatomic, readwrite, copy) NSString* title;
@property(nonatomic, readwrite, assign) VmfViewportDimension dimension;
@property(nonatomic, readwrite, assign) VmfViewportPlane plane;
@property(nonatomic, readwrite, strong) MTKView* metalView;
@property(nonatomic, strong) NSVisualEffectView* headerView;
@property(nonatomic, strong) ViewportOverlayView* overlayView;
@property(nonatomic, strong) NSTextField* titleLabel;
@property(nonatomic, strong) NSTextField* modeLabel;
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property(nonatomic, strong) id<MTLRenderPipelineState> pipelineState;
@property(nonatomic, strong) id<MTLDepthStencilState> depthState;
@property(nonatomic, strong) id<MTLDepthStencilState> disabledDepthState;
@property(nonatomic, strong) id<MTLDepthStencilState> readOnlyDepthState;
@property(nonatomic, strong) id<MTLBuffer> vertexBuffer;
@property(nonatomic, strong) id<MTLBuffer> edgeVertexBuffer;
@property(nonatomic, strong) id<MTLBuffer> selectedFaceBuffer;
@property(nonatomic, strong) id<MTLBuffer> highlightedFaceBuffer;
@property(nonatomic, assign) NSUInteger vertexCount;
@property(nonatomic, assign) NSUInteger edgeVertexCount;
@property(nonatomic, assign) NSUInteger selectedFaceVertexCount;
@property(nonatomic, assign) NSUInteger highlightedFaceVertexCount;
@property(nonatomic, assign) ViewerVertex* cpuVertices;
@property(nonatomic, assign) ViewerVertex* cpuEdgeVertices;
@property(nonatomic, assign) Vec3* baseVertexColors;
@property(nonatomic, assign) ViewerFaceRange* faceRanges;
@property(nonatomic, assign) size_t faceRangeCount;
@property(nonatomic, assign) Bounds3 sceneBounds;
@property(nonatomic, assign) Vec3 target;
@property(nonatomic, assign) Vec3 orbitLerpTarget;
@property(nonatomic, assign) float yaw;
@property(nonatomic, assign) float pitch;
@property(nonatomic, assign) float distance;
@property(nonatomic, assign) Vec3 freeLookPosition;
@property(nonatomic, readwrite, assign) BOOL freeLookActive;
@property(nonatomic, assign) CameraMovement movementMask;
@property(nonatomic, assign) CFTimeInterval lastFrameTime;
@property(nonatomic, assign) Vec3 orthoCenter;
@property(nonatomic, assign) float orthoSize;
@property(nonatomic, assign) Vec3 primaryLightPosition;
@property(nonatomic, assign) Vec3 primaryLightColor;
@property(nonatomic, assign) float primaryLightIntensity;
@property(nonatomic, assign) float primaryLightRange;
@property(nonatomic, assign) BOOL primaryLightEnabled;
@property(nonatomic, assign) Bounds3 selectionBounds;
@property(nonatomic, assign) BOOL selectionVisible;
@property(nonatomic, assign) Vec3 selectionRotationDegrees;
@property(nonatomic, assign) BOOL selectionRotatable;
@property(nonatomic, assign) NSUInteger gizmoOperation;
@property(nonatomic, assign) Vec3* selectionVertices;
@property(nonatomic, assign) size_t selectionVertexCount;
@property(nonatomic, assign) VmfSolidEdge* selectionEdges;
@property(nonatomic, assign) size_t selectionEdgeCount;
@property(nonatomic, assign) VmfViewportSelectionEdge selectedFaceEdge;
@property(nonatomic, assign) BOOL selectedFaceVisible;
@property(nonatomic, assign) size_t selectedFaceEntityIndex;
@property(nonatomic, assign) size_t selectedFaceSolidIndex;
@property(nonatomic, assign) size_t selectedFaceSideIndex;
@property(nonatomic, assign) BOOL highlightedFaceVisible;
@property(nonatomic, assign) size_t highlightedFaceEntityIndex;
@property(nonatomic, assign) size_t highlightedFaceSolidIndex;
@property(nonatomic, assign) size_t highlightedFaceSideIndex;
@property(nonatomic, assign) Bounds3 creationBounds;
@property(nonatomic, assign) BOOL creationVisible;
@property(nonatomic, assign) Bounds3 pluginDebugBounds;
@property(nonatomic, assign) BOOL pluginDebugVisible;
@property(nonatomic, assign) BOOL clipGuideVisible;
@property(nonatomic, assign) Vec3 clipGuideStart;
@property(nonatomic, assign) Vec3 clipGuideEnd;
@property(nonatomic, assign) ViewportDragMode dragMode;
@property(nonatomic, assign) ViewportHandle activeHandle;
@property(nonatomic, assign) size_t activeEdgeFirstSideIndex;
@property(nonatomic, assign) size_t activeEdgeSecondSideIndex;
@property(nonatomic, assign) Vec3 dragAnchorWorld;
@property(nonatomic, assign) Bounds3 dragOriginalBounds;
@property(nonatomic, assign) NSPoint dragStartPoint;
@property(nonatomic, assign) BOOL pendingClickSelection;
@property(nonatomic, assign) BOOL vertexEditIsInvalid;
@property(nonatomic, strong) id<MTLBuffer> vertexEditPreviewBuffer;
@property(nonatomic, assign) NSUInteger vertexEditPreviewVertexCount;
@property(nonatomic, strong) id<MTLSamplerState> samplerState;
@property(nonatomic, strong) NSMutableDictionary<NSString*, id>* textureCache;
@property(nonatomic, strong) NSMutableDictionary<NSString*, id>* textureDataCache;
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSNumber*>* textureMissLogTimes;
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSDictionary<NSString*, id>*>* previewBakedLightmaps;
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSNumber*>* previewBakeBrushResolutions;
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSDictionary<NSString*, NSNumber*>*>* previewBakeBrushStats;
@property(nonatomic, strong) NSMutableDictionary<NSString*, id>* previewBakedDebugTextures;
@property(nonatomic, copy) NSString* previewBakeDebugSelectedKey;
@property(nonatomic, assign) BOOL previewBakeDebugWindowOpen;
@property(nonatomic, strong) NSPanel* previewBakePanel;
@property(nonatomic, strong) NSTextField* previewBakeMapCountLabel;
@property(nonatomic, strong) NSTextField* previewBakeStatusLabel;
@property(nonatomic, strong) NSProgressIndicator* previewBakeProgressIndicator;
@property(nonatomic, strong) NSSlider* previewBakeExposureSlider;
@property(nonatomic, strong) NSTextField* previewBakeExposureValueLabel;
@property(nonatomic, strong) NSSlider* previewBakeBatchSppSlider;
@property(nonatomic, strong) NSTextField* previewBakeBatchSppValueLabel;
@property(nonatomic, strong) NSSlider* previewBakeTargetSppSlider;
@property(nonatomic, strong) NSTextField* previewBakeTargetSppValueLabel;
@property(nonatomic, strong) NSSlider* previewBakeBounceSlider;
@property(nonatomic, strong) NSTextField* previewBakeBounceValueLabel;
@property(nonatomic, strong) NSSlider* previewBakeSkyBrightnessSlider;
@property(nonatomic, strong) NSTextField* previewBakeSkyBrightnessValueLabel;
@property(nonatomic, strong) NSSlider* previewBakeDiffuseBounceSlider;
@property(nonatomic, strong) NSTextField* previewBakeDiffuseBounceValueLabel;
@property(nonatomic, strong) NSSlider* previewBakeDensitySlider;
@property(nonatomic, strong) NSTextField* previewBakeDensityValueLabel;
@property(nonatomic, strong) NSPopUpButton* previewBakeMapPopUp;
@property(nonatomic, strong) NSImageView* previewBakeImageView;
@property(nonatomic, strong) NSTextField* previewBakeImageInfoLabel;
@property(nonatomic, strong) NSButton* previewBakeRebakeButton;
@property(nonatomic, assign) float previewBakeDebugExposure;
@property(nonatomic, assign) uint32_t previewBakeRtSamplesPerTexel;
@property(nonatomic, assign) uint32_t previewBakeTargetSamplesPerTexel;
@property(nonatomic, assign) uint32_t previewBakeBounceCount;
@property(nonatomic, assign) float previewBakeSkyBrightness;
@property(nonatomic, assign) float previewBakeDiffuseBounceIntensity;
@property(nonatomic, assign) float previewBakeDensity;
@property(nonatomic, assign) uint32_t previewBakeAccumulatedSamplesPerTexel;
@property(nonatomic, assign) uint32_t previewBakeRunningTargetSamplesPerTexel;
@property(nonatomic, assign) uint32_t previewBakeRunningBounceCount;
@property(nonatomic, assign) int previewBakeDisplayMode;
@property(nonatomic, assign) BOOL previewBakePauseRequested;
@property(nonatomic, assign) BOOL previewBakeCancelRequested;
@property(nonatomic, assign) BOOL previewBakeRestartQueued;
@property(nonatomic, strong) id<MTLComputePipelineState> hwrtBakePipeline;
@property(nonatomic, copy) NSString* textureDirectory;
@property(nonatomic, assign) NovaToolMetalEditorViewportRenderer metalRenderer;
@property(nonatomic, assign) NovaToolMetalContext fullMetalContext;
@property(nonatomic, assign) NovaToolMetalRenderer fullMetalRenderer;
@property(nonatomic, assign) NovaSceneData importedSceneData;
@property(nonatomic, assign) UiGizmoState fullRendererUiState;
@property(nonatomic, assign) const VmfScene* vmfScene;
@property(nonatomic, assign) NovaSceneWorld* sceneWorld;
@property(nonatomic, assign) uint32_t* heavyObjectEntityIndices;
@property(nonatomic, assign) Vec3* heavyObjectModelBasePositions;
@property(nonatomic, assign) uint8_t* heavyObjectModelFlags;
@property(nonatomic, assign) uint32_t heavyObjectMappingCount;
@property(nonatomic, assign) BOOL fullRendererInitialized;
@property(nonatomic, assign) uint32_t fullRendererFrameIndex;
@property(nonatomic, assign) void* imguiContext;
@property(nonatomic, assign) BOOL gizmoHovered;
@property(nonatomic, assign) BOOL gizmoInteractionActive;
@property(nonatomic, assign) matrix_float4x4 gizmoInteractionMatrix;
@property(nonatomic, assign) Bounds3 gizmoInteractionStartBounds;
@property(nonatomic, assign) BOOL gizmoInteractionHasStart;
@property(nonatomic, assign) BOOL orbitLerpActive;
@property(nonatomic, assign) BOOL previewBakeInProgress;
@property(nonatomic, assign) BOOL previewBakedLightingEnabled;
@property(nonatomic, assign) uint64_t previewBakeGeneration;
@property(nonatomic, assign) uint64_t meshRevision;

@end

#endif

#pragma clang diagnostic pop
