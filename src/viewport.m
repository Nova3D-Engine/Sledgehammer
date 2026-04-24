#import "viewport.h"

#import <QuartzCore/QuartzCore.h>
#import <simd/simd.h>
#import <stdint.h>

#include <stdio.h>

#include "app_metal.h"
#include "app_metal_editor_viewport_renderer.h"
#define Vec3 AppMetalMathVec3
#include "app_metal_renderer.h"
#undef Vec3
#include "nova_scene_data.h"

#include <imgui.h>
#include <ImGuizmo.h>
#include <backends/imgui_impl_metal.h>
#include <backends/imgui_impl_osx.h>

#include "math3d.h"

typedef AppMetalEditorViewportUniforms Uniforms;

typedef NS_OPTIONS(NSUInteger, CameraMovement) {
    CameraMovementForward = 1 << 0,
    CameraMovementBackward = 1 << 1,
    CameraMovementLeft = 1 << 2,
    CameraMovementRight = 1 << 3,
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

@class VmfViewport;

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
- (void)handleViewportMouseHoverAtPoint:(NSPoint)point;
- (void)handleViewportSecondaryClickAtPoint:(NSPoint)point modifierFlags:(NSEventModifierFlags)flags;
- (void)drawEditorOverlay;
- (Vec3)rayDirectionForViewPoint:(NSPoint)point;
- (nullable id<MTLTexture>)cachedTextureForMaterial:(NSString*)material;
- (nullable NSDictionary<NSString*, id>*)cachedTextureDataForMaterial:(NSString*)material;
- (BOOL)encodeGizmoOverlayOnCommandBuffer:(id<MTLCommandBuffer>)commandBuffer drawable:(id<CAMetalDrawable>)drawable errorMessage:(char*)errorMessage capacity:(size_t)errorMessageCapacity;
- (BOOL)gizmoConsumesPrimaryMouse;
- (void)syncHeavyRendererSceneFromMesh:(const ViewerMesh*)mesh;
- (BOOL)initializeHeavyRenderer;

@end

@interface ViewportMetalView : MTKView

@property(nonatomic, weak) VmfViewport* owner;

@end


@interface ViewportOverlayView : NSView

@property(nonatomic, weak) VmfViewport* owner;

@end

static matrix_float4x4 matrix_from_mat4(Mat4 matrix) {
    matrix_float4x4 result;
    for (int column = 0; column < 4; ++column) {
        for (int row = 0; row < 4; ++row) {
            result.columns[column][row] = matrix.raw[column][row];
        }
    }
    return result;
}

static void copy_mat4_to_uniform(float destination[16], Mat4 matrix) {
    for (int column = 0; column < 4; ++column) {
        for (int row = 0; row < 4; ++row) {
            destination[column * 4 + row] = matrix.raw[column][row];
        }
    }
}

static void viewport_identity_matrix(float matrix[16]) {
    memset(matrix, 0, sizeof(float) * 16u);
    matrix[0] = 1.0f;
    matrix[5] = 1.0f;
    matrix[10] = 1.0f;
    matrix[15] = 1.0f;
}

static Bounds3 viewport_bounds_for_vertex_range(const ViewerVertex* vertices, size_t start, size_t count) {
    Bounds3 bounds = bounds3_empty();
    if (vertices == NULL) {
        return bounds;
    }
    for (size_t index = 0; index < count; ++index) {
        bounds3_expand(&bounds, vertices[start + index].position);
    }
    return bounds;
}

static void viewport_init_imported_material_gpu_defaults(NovaSceneGpuMaterial* material) {
    if (material == NULL) {
        return;
    }

    memset(material, 0, sizeof(*material));
    material->baseColor[3] = 1.0f;
    material->params[3] = 1.45f;
    material->texIndices[0] = -1.0f;
    material->texIndices[1] = -1.0f;
    material->texIndices[2] = -1.0f;
    material->texIndices[3] = -1.0f;
    material->extra[0] = 1.0f;
    material->extra[1] = -1.0f;
    material->extra[2] = 0.5f;
}

static Vec3 world_up(void) {
    return vec3_make(0.0f, 0.0f, 1.0f);
}

static Vec3 plane_right(VmfViewportPlane plane) {
    switch (plane) {
        case VmfViewportPlaneXY:
        case VmfViewportPlaneXZ:
            return vec3_make(1.0f, 0.0f, 0.0f);
        case VmfViewportPlaneZY:
            return vec3_make(0.0f, 1.0f, 0.0f);
    }
    return vec3_make(1.0f, 0.0f, 0.0f);
}

static Vec3 plane_up(VmfViewportPlane plane) {
    switch (plane) {
        case VmfViewportPlaneXY:
            return vec3_make(0.0f, 1.0f, 0.0f);
        case VmfViewportPlaneXZ:
        case VmfViewportPlaneZY:
            return vec3_make(0.0f, 0.0f, 1.0f);
    }
    return vec3_make(0.0f, 1.0f, 0.0f);
}

static Vec3 plane_forward(VmfViewportPlane plane) {
    switch (plane) {
        case VmfViewportPlaneXY:
            return vec3_make(0.0f, 0.0f, -1.0f);
        case VmfViewportPlaneXZ:
            return vec3_make(0.0f, 1.0f, 0.0f);
        case VmfViewportPlaneZY:
            return vec3_make(-1.0f, 0.0f, 0.0f);
    }
    return vec3_make(0.0f, 0.0f, -1.0f);
}

static float snap_to_grid(float value, float grid) {
    grid = fmaxf(grid, 1.0f);
    return roundf(value / grid) * grid;
}

static float plane_u_value(VmfViewportPlane plane, Vec3 point) {
    switch (plane) {
        case VmfViewportPlaneXY:
        case VmfViewportPlaneXZ:
            return point.raw[0];
        case VmfViewportPlaneZY:
            return point.raw[1];
    }
    return point.raw[0];
}

static float plane_v_value(VmfViewportPlane plane, Vec3 point) {
    switch (plane) {
        case VmfViewportPlaneXY:
            return point.raw[1];
        case VmfViewportPlaneXZ:
        case VmfViewportPlaneZY:
            return point.raw[2];
    }
    return point.raw[1];
}

static Bounds3 normalized_bounds(Bounds3 bounds) {
    Bounds3 normalized = bounds;
    for (int axis = 0; axis < 3; ++axis) {
        if (normalized.min.raw[axis] > normalized.max.raw[axis]) {
            float tmp = normalized.min.raw[axis];
            normalized.min.raw[axis] = normalized.max.raw[axis];
            normalized.max.raw[axis] = tmp;
        }
    }
    return normalized;
}

static float adjusted_dragged_edge(float draggedValue, float fixedValue, float minimumSpan, BOOL preservePositiveDirection) {
    if (fabsf(draggedValue - fixedValue) >= minimumSpan) {
        return draggedValue;
    }
    return fixedValue + (preservePositiveDirection ? minimumSpan : -minimumSpan);
}

static float ortho_grid_step(float visibleSpan, float baseStep) {
    float step = fmaxf(baseStep, 1.0f);
    float targetStep = fmaxf(visibleSpan / 24.0f, step);
    while (step < targetStep) {
        step *= 2.0f;
    }
    return step;
}

static CGFloat signed_distance_to_screen_line(NSPoint point, NSPoint lineStart, NSPoint lineEnd) {
    CGFloat dx = lineEnd.x - lineStart.x;
    CGFloat dy = lineEnd.y - lineStart.y;
    return (dx * (point.y - lineStart.y)) - (dy * (point.x - lineStart.x));
}

static NSUInteger clip_polygon_to_halfplane(NSPoint* points,
                                            NSUInteger count,
                                            NSPoint lineStart,
                                            NSPoint lineEnd,
                                            BOOL keepPositive,
                                            NSPoint* outPoints,
                                            NSUInteger maxOutPoints) {
    if (!points || !outPoints || count == 0 || maxOutPoints == 0) {
        return 0;
    }

    NSUInteger outCount = 0;
    for (NSUInteger index = 0; index < count; ++index) {
        NSPoint current = points[index];
        NSPoint previous = points[(index + count - 1) % count];
        CGFloat currentDistance = signed_distance_to_screen_line(current, lineStart, lineEnd);
        CGFloat previousDistance = signed_distance_to_screen_line(previous, lineStart, lineEnd);
        BOOL currentInside = keepPositive ? currentDistance >= 0.0 : currentDistance <= 0.0;
        BOOL previousInside = keepPositive ? previousDistance >= 0.0 : previousDistance <= 0.0;

        if (currentInside != previousInside) {
            CGFloat denominator = currentDistance - previousDistance;
            if (fabs(denominator) > 1e-6) {
                CGFloat t = currentDistance / denominator;
                NSPoint intersection = NSMakePoint(current.x + (previous.x - current.x) * t,
                                                   current.y + (previous.y - current.y) * t);
                if (outCount < maxOutPoints) {
                    outPoints[outCount++] = intersection;
                }
            }
        }
        if (currentInside && outCount < maxOutPoints) {
            outPoints[outCount++] = current;
        }
    }
    return outCount;
}

static AppMetalEditorVertex app_metal_editor_vertex_from_viewer_vertex(ViewerVertex vertex) {
    AppMetalEditorVertex converted = {0};
    converted.position[0] = vertex.position.raw[0];
    converted.position[1] = vertex.position.raw[1];
    converted.position[2] = vertex.position.raw[2];
    converted.normal[0] = vertex.normal.raw[0];
    converted.normal[1] = vertex.normal.raw[1];
    converted.normal[2] = vertex.normal.raw[2];
    converted.color[0] = vertex.color.raw[0];
    converted.color[1] = vertex.color.raw[1];
    converted.color[2] = vertex.color.raw[2];
    converted.u = vertex.u;
    converted.v = vertex.v;
    return converted;
}

static void append_grid_line(AppMetalEditorVertex* vertices,
                             NSUInteger capacity,
                             NSUInteger* count,
                             Vec3 start,
                             Vec3 end,
                             Vec3 color) {
    if (*count + 2 > capacity) {
        return;
    }

    ViewerVertex a = {
        .position = start,
        .normal = vec3_make(0.0f, 0.0f, 1.0f),
        .color = color,
    };
    ViewerVertex b = {
        .position = end,
        .normal = vec3_make(0.0f, 0.0f, 1.0f),
        .color = color,
    };
    vertices[*count] = app_metal_editor_vertex_from_viewer_vertex(a);
    vertices[*count + 1] = app_metal_editor_vertex_from_viewer_vertex(b);
    *count += 2;
}

static AppMetalEditorFaceRange app_metal_editor_face_range_from_viewer_face_range(ViewerFaceRange range) {
    AppMetalEditorFaceRange converted = {0};
    converted.entityIndex = range.entityIndex;
    converted.solidIndex = range.solidIndex;
    converted.sideIndex = range.sideIndex;
    converted.vertexStart = range.vertexStart;
    converted.vertexCount = range.vertexCount;
    memcpy(converted.material, range.material, sizeof(converted.material));
    return converted;
}

static id<MTLBuffer> viewport_create_editor_vertex_buffer(id<MTLDevice> device, const ViewerVertex* vertices, size_t count) {
    if (device == nil || vertices == NULL || count == 0) {
        return nil;
    }

    AppMetalEditorVertex* converted = (AppMetalEditorVertex*)malloc(count * sizeof(AppMetalEditorVertex));
    if (converted == NULL) {
        return nil;
    }
    for (size_t index = 0; index < count; ++index) {
        converted[index] = app_metal_editor_vertex_from_viewer_vertex(vertices[index]);
    }
    id<MTLBuffer> buffer = [device newBufferWithBytes:converted
                                               length:count * sizeof(AppMetalEditorVertex)
                                              options:MTLResourceStorageModeShared];
    free(converted);
    return buffer;
}

static AppMetalEditorVertex* viewport_create_editor_vertex_array(const ViewerVertex* vertices, size_t count) {
    if (vertices == NULL || count == 0) {
        return NULL;
    }

    AppMetalEditorVertex* converted = (AppMetalEditorVertex*)malloc(count * sizeof(AppMetalEditorVertex));
    if (converted == NULL) {
        return NULL;
    }
    for (size_t index = 0; index < count; ++index) {
        converted[index] = app_metal_editor_vertex_from_viewer_vertex(vertices[index]);
    }
    return converted;
}

static AppMetalEditorFaceRange* viewport_create_editor_face_range_array(const ViewerFaceRange* ranges, size_t count) {
    if (ranges == NULL || count == 0) {
        return NULL;
    }

    AppMetalEditorFaceRange* converted = (AppMetalEditorFaceRange*)malloc(count * sizeof(AppMetalEditorFaceRange));
    if (converted == NULL) {
        return NULL;
    }
    for (size_t index = 0; index < count; ++index) {
        converted[index] = app_metal_editor_face_range_from_viewer_face_range(ranges[index]);
    }
    return converted;
}

static void* viewport_resolve_texture(const char* materialName, void* userData) {
    if (materialName == NULL || userData == NULL) {
        return NULL;
    }

    VmfViewport* viewport = (__bridge VmfViewport*)userData;
    NSString* material = [NSString stringWithUTF8String:materialName];
    id<MTLTexture> texture = [viewport cachedTextureForMaterial:material];
    return texture != nil ? (__bridge void*)texture : NULL;
}

static int viewport_encode_overlay(void* commandBufferHandle, void* drawableHandle, void* userData, char* errorMessage, size_t errorMessageCapacity) {
    if (commandBufferHandle == NULL || drawableHandle == NULL || userData == NULL) {
        return 1;
    }

    VmfViewport* viewport = (__bridge VmfViewport*)userData;
    return [viewport encodeGizmoOverlayOnCommandBuffer:(__bridge id<MTLCommandBuffer>)commandBufferHandle
                                             drawable:(__bridge id<CAMetalDrawable>)drawableHandle
                                         errorMessage:errorMessage
                                             capacity:errorMessageCapacity] ? 1 : 0;
}

@implementation ViewportMetalView {
    NSPoint _lastPoint;
    CGPoint _lockedCursorPoint;
    BOOL _cursorLocked;
    BOOL _hadFreeLookDrag;
    NSEventModifierFlags _clickModifierFlags;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    NSPasteboard* pasteboard = sender.draggingPasteboard;
    if ([pasteboard canReadObjectForClasses:@[[NSURL class]] options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }]) {
        return NSDragOperationCopy;
    }
    return NSDragOperationNone;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSPasteboard* pasteboard = sender.draggingPasteboard;
    NSArray<NSURL*>* urls = [pasteboard readObjectsForClasses:@[[NSURL class]] options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
    NSURL* firstURL = urls.firstObject;
    if (!firstURL) {
        return NO;
    }
    [self.owner handleViewportDroppedPath:firstURL.path];
    return YES;
}

- (void)keyDown:(NSEvent*)event {
    if (![self.owner handleViewportKeyDown:event]) {
        [super keyDown:event];
    }
}

- (void)keyUp:(NSEvent*)event {
    if (![self.owner handleViewportKeyUp:event]) {
        [super keyUp:event];
    }
}

- (void)mouseDown:(NSEvent*)event {
    [self.window makeFirstResponder:self];
    _lastPoint = [self convertPoint:event.locationInWindow fromView:nil];
    [self.owner handleViewportMouseDownAtPoint:_lastPoint];
}

- (void)mouseDragged:(NSEvent*)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSPoint delta = NSMakePoint(point.x - _lastPoint.x, point.y - _lastPoint.y);
    _lastPoint = point;
    [self.owner handleViewportPrimaryDragWithDelta:delta alternate:(event.modifierFlags & NSEventModifierFlagOption) != 0];
}

- (void)mouseUp:(NSEvent*)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    [self.owner handleViewportMouseUpAtPoint:point];
}

- (void)rightMouseDown:(NSEvent*)event {
    [self.window makeFirstResponder:self];
    _lastPoint = [self convertPoint:event.locationInWindow fromView:nil];
    _hadFreeLookDrag = NO;
    _clickModifierFlags = event.modifierFlags;  // capture here while all keys are definitely held
    [self.owner handleViewportMouseDownAtPoint:_lastPoint];
    if (![self.owner handleViewportSecondaryMouseDown]) {
        return;
    }

    CGEventRef currentEvent = CGEventCreate(NULL);
    if (currentEvent) {
        _lockedCursorPoint = CGEventGetLocation(currentEvent);
        CFRelease(currentEvent);
    }
    if (!_cursorLocked) {
        CGAssociateMouseAndMouseCursorPosition(false);
        [NSCursor hide];
        _cursorLocked = YES;
    }
}

- (void)rightMouseDragged:(NSEvent*)event {
    NSPoint delta = NSMakePoint(event.deltaX, event.deltaY);
    if (hypot(delta.x, delta.y) > 0.5) {
        _hadFreeLookDrag = YES;
    }
    [self.owner handleViewportSecondaryDragWithDelta:delta];
}

- (void)rightMouseUp:(NSEvent*)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (_cursorLocked) {
        CGWarpMouseCursorPosition(_lockedCursorPoint);
        CGAssociateMouseAndMouseCursorPosition(true);
        [NSCursor unhide];
        _cursorLocked = NO;
    }
    [self.owner handleViewportSecondaryMouseUp];
    if (!_hadFreeLookDrag) {
        [self.owner handleViewportSecondaryClickAtPoint:point modifierFlags:_clickModifierFlags];
    }
}

- (void)scrollWheel:(NSEvent*)event {
    [self.owner handleViewportScrollDelta:event.deltaY];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea* area in self.trackingAreas) {
        [self removeTrackingArea:area];
    }
    NSTrackingAreaOptions options = NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect;
    NSTrackingArea* area = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:options owner:self userInfo:nil];
    [self addTrackingArea:area];
}

- (void)mouseMoved:(NSEvent*)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    [self.owner handleViewportMouseHoverAtPoint:point];
}

- (void)viewWillMoveToWindow:(NSWindow*)newWindow {
    if (!newWindow && _cursorLocked) {
        CGAssociateMouseAndMouseCursorPosition(true);
        [NSCursor unhide];
        _cursorLocked = NO;
    }
    [super viewWillMoveToWindow:newWindow];
}

@end

@implementation ViewportOverlayView

- (BOOL)isOpaque {
    return NO;
}

- (NSView*)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [self.owner drawEditorOverlay];
}

@end

@interface VmfViewport () <MTKViewDelegate>

@property(nonatomic, copy) NSString* title;
@property(nonatomic, assign) VmfViewportDimension dimension;
@property(nonatomic, assign) VmfViewportPlane plane;
@property(nonatomic, strong) ViewportMetalView* metalView;
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
@property(nonatomic, assign) ViewerFaceRange* faceRanges;
@property(nonatomic, assign) size_t faceRangeCount;
@property(nonatomic, assign) Bounds3 sceneBounds;
@property(nonatomic, assign) Vec3 target;
@property(nonatomic, assign) float yaw;
@property(nonatomic, assign) float pitch;
@property(nonatomic, assign) float distance;
@property(nonatomic, assign) Vec3 freeLookPosition;
@property(nonatomic, assign) BOOL freeLookActive;
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
@property(nonatomic, strong) NSMutableDictionary<NSString*, id>* textureCache; // id<MTLTexture> or NSNull
@property(nonatomic, strong) NSMutableDictionary<NSString*, id>* textureDataCache; // NSDictionary or NSNull
@property(nonatomic, copy) NSString* textureDirectory;
@property(nonatomic, assign) AppMetalEditorViewportRenderer metalRenderer;
@property(nonatomic, assign) AppMetalContext fullMetalContext;
@property(nonatomic, assign) AppMetalRenderer fullMetalRenderer;
@property(nonatomic, assign) NovaSceneData importedSceneData;
@property(nonatomic, assign) UiGizmoState fullRendererUiState;
@property(nonatomic, assign) NovaSceneWorld* sceneWorld;
@property(nonatomic, assign) BOOL fullRendererInitialized;
@property(nonatomic, assign) uint32_t fullRendererFrameIndex;
@property(nonatomic, assign) void* imguiContext;
@property(nonatomic, assign) BOOL gizmoHovered;
@property(nonatomic, assign) BOOL gizmoInteractionActive;

@end

@interface VmfViewport () {
    size_t _activeVertexIndices[VMF_MAX_SOLID_VERTICES];
    size_t _activeVertexIndexCount;
}

@end

@implementation VmfViewport

- (void)dealloc {
    if (self.imguiContext != NULL) {
        ImGui::SetCurrentContext((ImGuiContext*)self.imguiContext);
        ImGui_ImplMetal_Shutdown();
        ImGui_ImplOSX_Shutdown();
        ImGui::DestroyContext((ImGuiContext*)self.imguiContext);
        self.imguiContext = NULL;
    }
    app_metal_renderer_shutdown(&_fullMetalRenderer);
    app_metal_shutdown(&_fullMetalContext);
    nova_scene_data_release(&_importedSceneData);
    app_metal_editor_viewport_renderer_shutdown(&_metalRenderer);
    free(self.cpuVertices);
    free(self.faceRanges);
    free(self.selectionVertices);
    free(self.selectionEdges);
}

- (instancetype)initWithFrame:(NSRect)frame
                       device:(id<MTLDevice>)device
                        title:(NSString*)title
                    dimension:(VmfViewportDimension)dimension
                        plane:(VmfViewportPlane)plane
                   renderMode:(VmfViewportRenderMode)renderMode {
    self = [super initWithFrame:frame];
    if (!self) {
        return nil;
    }

    _device = device;
    _title = [title copy];
    _dimension = dimension;
    _plane = plane;
    _renderMode = renderMode;
    _sceneBounds = bounds3_empty();
    _yaw = 0.75f;
    _pitch = 0.65f;
    _distance = 1024.0f;
    _target = vec3_make(0.0f, 0.0f, 0.0f);
    _freeLookPosition = vec3_make(0.0f, 0.0f, 0.0f);
    _orthoCenter = vec3_make(0.0f, 0.0f, 0.0f);
    _orthoSize = 2048.0f;
    _primaryLightPosition = vec3_make(256.0f, 256.0f, 512.0f);
    _primaryLightColor = vec3_make(1.0f, 0.95f, 0.8f);
    _primaryLightIntensity = 1.0f;
    _primaryLightRange = 2048.0f;
    _primaryLightEnabled = NO;
    _editorTool = VmfViewportEditorToolSelect;
    _gridSize = 32.0;
    _selectionBounds = bounds3_empty();
    _creationBounds = bounds3_empty();
    _selectedFaceEdge = VmfViewportSelectionEdgeNone;
    _activeVertexIndexCount = 0;
    _activeEdgeFirstSideIndex = SIZE_MAX;
    _activeEdgeSecondSideIndex = SIZE_MAX;
    nova_scene_data_init(&_importedSceneData);
    memset(&_fullRendererUiState, 0, sizeof(_fullRendererUiState));
    _fullRendererUiState.renderMode = 1;
    _fullRendererUiState.importedSceneActive = 1;

    self.wantsLayer = YES;
    self.layer.backgroundColor = CGColorCreateGenericRGB(0.055f, 0.062f, 0.075f, 1.0f);
    self.layer.cornerRadius = 8.0f;
    self.layer.borderWidth = 1.0f;
    self.layer.borderColor = CGColorCreateGenericRGB(0.20f, 0.23f, 0.28f, 1.0f);
    self.layer.masksToBounds = YES;

    _commandQueue = [_device newCommandQueue];

    NSString* executableDir = [[[NSProcessInfo processInfo] arguments][0] stringByDeletingLastPathComponent];
    NSString* metallibPath = [[NSBundle mainBundle] pathForResource:@"default" ofType:@"metallib"];
    if (metallibPath == nil) {
        metallibPath = [executableDir stringByAppendingPathComponent:@"default.metallib"];
    }
    NSError* error = nil;
    id<MTLLibrary> library = [_device newLibraryWithURL:[NSURL fileURLWithPath:metallibPath] error:&error];
    if (!library) {
        NSLog(@"Failed to load Metal library: %@", error);
        return nil;
    }

    MTLRenderPipelineDescriptor* descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction = [library newFunctionWithName:@"viewerVertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"viewerFragment"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    descriptor.colorAttachments[0].blendingEnabled = YES;
    descriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    descriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
    descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    _pipelineState = [_device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!_pipelineState) {
        NSLog(@"Failed to create pipeline: %@", error);
        return nil;
    }

    MTLDepthStencilDescriptor* depthDescriptor = [[MTLDepthStencilDescriptor alloc] init];
    depthDescriptor.depthCompareFunction = MTLCompareFunctionLessEqual;
    depthDescriptor.depthWriteEnabled = YES;
    _depthState = [_device newDepthStencilStateWithDescriptor:depthDescriptor];

    MTLDepthStencilDescriptor* disabledDepthDescriptor = [[MTLDepthStencilDescriptor alloc] init];
    disabledDepthDescriptor.depthCompareFunction = MTLCompareFunctionAlways;
    disabledDepthDescriptor.depthWriteEnabled = NO;
    _disabledDepthState = [_device newDepthStencilStateWithDescriptor:disabledDepthDescriptor];

    MTLDepthStencilDescriptor* readOnlyDepthDescriptor = [[MTLDepthStencilDescriptor alloc] init];
    readOnlyDepthDescriptor.depthCompareFunction = MTLCompareFunctionLessEqual;
    readOnlyDepthDescriptor.depthWriteEnabled = NO;
    _readOnlyDepthState = [_device newDepthStencilStateWithDescriptor:readOnlyDepthDescriptor];

    MTLSamplerDescriptor* samplerDesc = [[MTLSamplerDescriptor alloc] init];
    samplerDesc.sAddressMode = MTLSamplerAddressModeRepeat;
    samplerDesc.tAddressMode = MTLSamplerAddressModeRepeat;
    samplerDesc.minFilter = MTLSamplerMinMagFilterLinear;
    samplerDesc.magFilter = MTLSamplerMinMagFilterLinear;
    samplerDesc.mipFilter = MTLSamplerMipFilterLinear;
    samplerDesc.maxAnisotropy = 4;
    _samplerState = [_device newSamplerStateWithDescriptor:samplerDesc];
    _textureCache = [NSMutableDictionary dictionary];
    _textureDataCache = [NSMutableDictionary dictionary];

    AppMetalEditorViewportCreateInfo rendererCreateInfo = {
        .device = (__bridge void*)_device,
        .shaderLibraryPath = metallibPath.UTF8String,
        .colorPixelFormat = MTLPixelFormatBGRA8Unorm,
        .depthPixelFormat = MTLPixelFormatDepth32Float,
        .resolveTexture = viewport_resolve_texture,
        .textureUserData = (__bridge void*)self,
    };
    char rendererError[512] = {0};
    if (!app_metal_editor_viewport_renderer_initialize(&rendererCreateInfo, &_metalRenderer, rendererError, sizeof(rendererError))) {
        NSLog(@"Failed to create shared Metal viewport renderer: %s", rendererError);
        return nil;
    }

    [self buildUI];
    if (self.dimension == VmfViewportDimension3D && self.renderMode == VmfViewportRenderModeShaded) {
        [self initializeHeavyRenderer];
    }
    [self refreshChrome];
    return self;
}

- (BOOL)initializeHeavyRenderer {
    if (self.fullRendererInitialized || self.metalView == nil || self.metalView.layer == nil) {
        return self.fullRendererInitialized;
    }

    char errorBuffer[512] = {0};
    if (!app_metal_initialize_for_layer(&_fullMetalContext,
                                        (__bridge void*)self.metalView.layer,
                                        (__bridge void*)self.device,
                                        (__bridge void*)self.commandQueue,
                                        errorBuffer,
                                        sizeof(errorBuffer))) {
        NSLog(@"Failed to initialize embedded Metal context: %s", errorBuffer);
        return NO;
    }

    AppMetalRendererCreateInfo createInfo = {
        .context = &_fullMetalContext,
        .window = NULL,
        .buildUi = NULL,
        .buildUiUserData = NULL,
        .encodeOverlay = viewport_encode_overlay,
        .overlayUserData = (__bridge void*)self,
        .initialDrawableWidth = (uint32_t)MAX(1.0, self.metalView.drawableSize.width),
        .initialDrawableHeight = (uint32_t)MAX(1.0, self.metalView.drawableSize.height),
        .frameOverlap = 3u,
        .maxDrawCount = UI_MAX_SCENE_OBJECTS,
        .clusterMaxCount = 65536u,
        .clusterLightWords = 16u,
    };
    if (!app_metal_renderer_initialize(&createInfo, &_fullMetalRenderer, errorBuffer, sizeof(errorBuffer))) {
        NSLog(@"Failed to initialize full Metal renderer: %s", errorBuffer);
        app_metal_shutdown(&_fullMetalContext);
        memset(&_fullMetalContext, 0, sizeof(_fullMetalContext));
        return NO;
    }
    self.fullRendererInitialized = YES;
    self.fullRendererFrameIndex = 0u;
    return YES;
}

- (void)setSceneWorld:(NovaSceneWorld*)sceneWorld {
    _sceneWorld = sceneWorld;
    if (self.cpuVertices != NULL && self.faceRanges != NULL && self.vertexCount > 0 && self.faceRangeCount > 0) {
        ViewerMesh mesh = {
            .vertices = self.cpuVertices,
            .vertexCount = self.vertexCount,
            .faceRanges = self.faceRanges,
            .faceRangeCount = self.faceRangeCount,
        };
        [self syncHeavyRendererSceneFromMesh:&mesh];
    }
}

- (void)buildUI {
    self.headerView = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    self.headerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerView.material = NSVisualEffectMaterialHUDWindow;
    self.headerView.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    self.headerView.state = NSVisualEffectStateActive;

    self.titleLabel = [NSTextField labelWithString:self.title];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightSemibold];
    self.titleLabel.textColor = [NSColor colorWithWhite:0.92 alpha:1.0];

    self.modeLabel = [NSTextField labelWithString:@""];
    self.modeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.modeLabel.font = [NSFont monospacedSystemFontOfSize:10.0 weight:NSFontWeightMedium];
    self.modeLabel.textColor = [NSColor colorWithWhite:0.76 alpha:1.0];
    self.modeLabel.alignment = NSTextAlignmentRight;

    [self.headerView addSubview:self.titleLabel];
    [self.headerView addSubview:self.modeLabel];

    ViewportMetalView* metalView = [[ViewportMetalView alloc] initWithFrame:NSZeroRect device:self.device];
    metalView.owner = self;
    metalView.translatesAutoresizingMaskIntoConstraints = NO;
    metalView.enableSetNeedsDisplay = NO;
    metalView.paused = NO;
    metalView.preferredFramesPerSecond = 60;
    metalView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    metalView.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
    metalView.clearColor = MTLClearColorMake(0.065, 0.072, 0.085, 1.0);
    metalView.delegate = self;
    [metalView registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];
    self.metalView = metalView;

    [self addSubview:self.metalView];

    self.overlayView = [[ViewportOverlayView alloc] initWithFrame:NSZeroRect];
    self.overlayView.owner = self;
    self.overlayView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:self.overlayView];

    [self addSubview:self.headerView];

    [NSLayoutConstraint activateConstraints:@[
        [self.headerView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.headerView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.headerView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [self.headerView.heightAnchor constraintEqualToConstant:28.0],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.headerView.leadingAnchor constant:10.0],
        [self.titleLabel.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
        [self.modeLabel.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor constant:-10.0],
        [self.modeLabel.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
        [self.modeLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.titleLabel.trailingAnchor constant:8.0],
        [self.metalView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.metalView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.metalView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [self.metalView.topAnchor constraintEqualToAnchor:self.headerView.bottomAnchor],
        [self.overlayView.leadingAnchor constraintEqualToAnchor:self.metalView.leadingAnchor],
        [self.overlayView.trailingAnchor constraintEqualToAnchor:self.metalView.trailingAnchor],
        [self.overlayView.topAnchor constraintEqualToAnchor:self.metalView.topAnchor],
        [self.overlayView.bottomAnchor constraintEqualToAnchor:self.metalView.bottomAnchor],
    ]];

    if (self.dimension == VmfViewportDimension3D) {
        IMGUI_CHECKVERSION();
        ImGuiContext* context = ImGui::CreateContext();
        if (context != NULL) {
            self.imguiContext = context;
            ImGui::SetCurrentContext(context);
            ImGuiIO& io = ImGui::GetIO();
            io.IniFilename = NULL;
            io.LogFilename = NULL;
            io.ConfigFlags |= ImGuiConfigFlags_NoMouseCursorChange;
            if (!ImGui_ImplOSX_Init(self.metalView) || !ImGui_ImplMetal_Init(self.device)) {
                ImGui_ImplMetal_Shutdown();
                ImGui_ImplOSX_Shutdown();
                ImGui::DestroyContext(context);
                self.imguiContext = NULL;
            }
        }
    }
}

- (BOOL)gizmoConsumesPrimaryMouse {
    return self.dimension == VmfViewportDimension3D && (self.gizmoHovered || self.gizmoInteractionActive);
}

- (BOOL)encodeGizmoOverlayOnCommandBuffer:(id<MTLCommandBuffer>)commandBuffer drawable:(id<CAMetalDrawable>)drawable errorMessage:(char*)errorMessage capacity:(size_t)errorMessageCapacity {
    if (self.imguiContext == NULL || self.dimension != VmfViewportDimension3D || drawable == nil) {
        self.gizmoHovered = NO;
        self.gizmoInteractionActive = NO;
        return YES;
    }

    ImGui::SetCurrentContext((ImGuiContext*)self.imguiContext);
    MTLRenderPassDescriptor* uiPass = [MTLRenderPassDescriptor renderPassDescriptor];
    uiPass.colorAttachments[0].texture = drawable.texture;
    uiPass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    uiPass.colorAttachments[0].storeAction = MTLStoreActionStore;

    ImGui_ImplMetal_NewFrame(uiPass);
    ImGui_ImplOSX_NewFrame(self.metalView);
    ImGui::NewFrame();
    ImGuizmo::BeginFrame();

    BOOL shouldDrawGizmo = self.selectionVisible && self.selectionEditable && self.editorTool == VmfViewportEditorToolSelect && !self.freeLookActive;
    if (shouldDrawGizmo) {
        float aspect = self.metalView.drawableSize.height > 0.0 ? (float)(self.metalView.drawableSize.width / self.metalView.drawableSize.height) : 1.0f;
        Vec3 eye;
        Mat4 projection = [self projectionMatrixForAspect:aspect];
        Mat4 view = [self viewMatrixWithCameraPosition:&eye];
        float viewMatrix[16];
        float projectionMatrix[16];
        memcpy(viewMatrix, view.raw, sizeof(viewMatrix));
        memcpy(projectionMatrix, projection.raw, sizeof(projectionMatrix));

        Bounds3 selectionBounds = self.selectionBounds;
        Vec3 selectionCenter = bounds3_center(selectionBounds);
        float objectMatrix[16] = {
            1.0f, 0.0f, 0.0f, 0.0f,
            0.0f, 1.0f, 0.0f, 0.0f,
            0.0f, 0.0f, 1.0f, 0.0f,
            selectionCenter.raw[0], selectionCenter.raw[1], selectionCenter.raw[2], 1.0f,
        };

        ImGuizmo::SetOrthographic(false);
        ImGuizmo::SetDrawlist(ImGui::GetForegroundDrawList());
        ImGuizmo::SetRect(0.0f, 0.0f, ImGui::GetIO().DisplaySize.x, ImGui::GetIO().DisplaySize.y);
        BOOL manipulated = ImGuizmo::Manipulate(viewMatrix, projectionMatrix, ImGuizmo::TRANSLATE, ImGuizmo::WORLD, objectMatrix);
        self.gizmoHovered = ImGuizmo::IsOver();
        if (manipulated && self.delegate) {
            Vec3 translatedCenter = vec3_make(objectMatrix[12], objectMatrix[13], objectMatrix[14]);
            Vec3 delta = vec3_sub(translatedCenter, selectionCenter);
            Bounds3 translatedBounds = selectionBounds;
            translatedBounds.min = vec3_add(translatedBounds.min, delta);
            translatedBounds.max = vec3_add(translatedBounds.max, delta);
            [self.delegate viewport:self updateSelectionBounds:translatedBounds commit:NO transform:VmfViewportSelectionTransformMove];
        }

        BOOL isUsing = ImGuizmo::IsUsing();
        if (!isUsing && self.gizmoInteractionActive && self.delegate) {
            [self.delegate viewport:self updateSelectionBounds:self.selectionBounds commit:YES transform:VmfViewportSelectionTransformMove];
        }
        self.gizmoInteractionActive = isUsing;
    } else {
        self.gizmoHovered = NO;
        self.gizmoInteractionActive = NO;
    }

    ImGui::Render();
    if (ImGui::GetDrawData() == NULL) {
        return YES;
    }

    id<MTLRenderCommandEncoder> uiEncoder = [commandBuffer renderCommandEncoderWithDescriptor:uiPass];
    if (uiEncoder == nil) {
        if (errorMessage != NULL && errorMessageCapacity > 0u) {
            snprintf(errorMessage, errorMessageCapacity, "Failed to create viewport gizmo encoder.");
        }
        return NO;
    }
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), commandBuffer, uiEncoder);
    [uiEncoder endEncoding];
    return YES;
}

- (void)setRenderMode:(VmfViewportRenderMode)renderMode {
    _renderMode = renderMode;
    [self refreshChrome];
}

- (void)setActive:(BOOL)active {
    _active = active;
    [self refreshChrome];
}

- (void)refreshChrome {
    self.layer.borderWidth = self.active ? 2.0f : 1.0f;
    self.layer.borderColor = self.active ? CGColorCreateGenericRGB(0.86f, 0.48f, 0.18f, 1.0f) : CGColorCreateGenericRGB(0.20f, 0.23f, 0.28f, 1.0f);
    self.titleLabel.textColor = self.active ? [NSColor colorWithRed:0.97 green:0.79 blue:0.53 alpha:1.0] : [NSColor colorWithWhite:0.92 alpha:1.0];

    NSString* dimensionLabel = self.dimension == VmfViewportDimension3D ? @"3D" : @"2D";
    NSString* modeLabel = self.renderMode == VmfViewportRenderModeShaded ? @"SHADED" : @"WIRE";
    NSString* toolLabel = @"SELECT";
    if (self.editorTool == VmfViewportEditorToolVertex) {
        toolLabel = @"VERTEX";
    } else if (self.editorTool == VmfViewportEditorToolBlock) {
        toolLabel = @"BLOCK";
    } else if (self.editorTool == VmfViewportEditorToolCylinder) {
        toolLabel = @"CYLINDER";
    } else if (self.editorTool == VmfViewportEditorToolArch) {
        toolLabel = @"ARCH";
    } else if (self.editorTool == VmfViewportEditorToolClip) {
        toolLabel = self.clipModeLabel.length > 0 ? [NSString stringWithFormat:@"CLIP-%@", self.clipModeLabel] : @"CLIP";
    } else if (self.editorTool == VmfViewportEditorToolRamp) {
        toolLabel = @"RAMP";
    } else if (self.editorTool == VmfViewportEditorToolStairs) {
        toolLabel = @"STAIRS";
    }
    if (self.dimension == VmfViewportDimension3D) {
        toolLabel = self.editorTool == VmfViewportEditorToolSelect ? @"CAMERA" : toolLabel;
    }
    if (self.dimension == VmfViewportDimension2D) {
        self.modeLabel.stringValue = [NSString stringWithFormat:@"%@ %@ %@ %.0f", dimensionLabel, modeLabel, toolLabel, self.gridSize];
    } else {
        self.modeLabel.stringValue = [NSString stringWithFormat:@"%@ %@ %@", dimensionLabel, modeLabel, toolLabel];
    }
}

- (void)setEditorTool:(VmfViewportEditorTool)editorTool {
    _editorTool = editorTool;
    if (editorTool != VmfViewportEditorToolClip && self.clipGuideVisible) {
        self.clipGuideVisible = NO;
        [self.overlayView setNeedsDisplay:YES];
    }
    [self refreshChrome];
    [self.overlayView setNeedsDisplay:YES];
}

- (void)setGridSize:(CGFloat)gridSize {
    _gridSize = fmax(gridSize, 1.0);
    [self refreshChrome];
    [self.overlayView setNeedsDisplay:YES];
}

- (void)setClipModeLabel:(NSString*)clipModeLabel {
    _clipModeLabel = [clipModeLabel copy];
    [self refreshChrome];
}

- (void)setClipKeepMode:(VmfClipKeepMode)clipKeepMode {
    _clipKeepMode = clipKeepMode;
    [self.overlayView setNeedsDisplay:YES];
}

- (void)setSelectionBounds:(Bounds3)bounds visible:(BOOL)visible {
    self.selectionBounds = normalized_bounds(bounds);
    self.selectionVisible = visible;
    [self.overlayView setNeedsDisplay:YES];
}

- (void)setSelectionVertices:(const Vec3*)vertices count:(size_t)count visible:(BOOL)visible {
    free(self.selectionVertices);
    self.selectionVertices = NULL;
    self.selectionVertexCount = 0;
    if (visible && vertices && count > 0) {
        self.selectionVertices = (Vec3*)malloc(count * sizeof(Vec3));
        if (self.selectionVertices) {
            memcpy(self.selectionVertices, vertices, count * sizeof(Vec3));
            self.selectionVertexCount = count;
        }
    }
    [self.overlayView setNeedsDisplay:YES];
}

- (void)setSelectionEdges:(const VmfSolidEdge*)edges count:(size_t)count visible:(BOOL)visible {
    free(self.selectionEdges);
    self.selectionEdges = NULL;
    self.selectionEdgeCount = 0;
    if (visible && edges && count > 0) {
        self.selectionEdges = (VmfSolidEdge*)malloc(count * sizeof(VmfSolidEdge));
        if (self.selectionEdges) {
            memcpy(self.selectionEdges, edges, count * sizeof(VmfSolidEdge));
            self.selectionEdgeCount = count;
        }
    }
    [self.overlayView setNeedsDisplay:YES];
}

- (void)setSelectedFaceEdge:(VmfViewportSelectionEdge)edge {
    _selectedFaceEdge = edge;
    [self.overlayView setNeedsDisplay:YES];
}

- (void)rebuildHighlightedFaceBuffer {
    self.highlightedFaceBuffer = nil;
    self.highlightedFaceVertexCount = 0;
    if (!self.highlightedFaceVisible || !self.cpuVertices || !self.faceRanges) {
        return;
    }

    for (size_t rangeIndex = 0; rangeIndex < self.faceRangeCount; ++rangeIndex) {
        ViewerFaceRange range = self.faceRanges[rangeIndex];
        if (range.entityIndex != self.highlightedFaceEntityIndex ||
            range.solidIndex != self.highlightedFaceSolidIndex ||
            range.sideIndex != self.highlightedFaceSideIndex ||
            range.vertexCount == 0) {
            continue;
        }

        ViewerVertex* vertices = (ViewerVertex*)malloc(range.vertexCount * sizeof(ViewerVertex));
        if (!vertices) {
            return;
        }
        memcpy(vertices, self.cpuVertices + range.vertexStart, range.vertexCount * sizeof(ViewerVertex));
        for (size_t vertexIndex = 0; vertexIndex < range.vertexCount; ++vertexIndex) {
            vertices[vertexIndex].position = vec3_add(vertices[vertexIndex].position, vec3_scale(vertices[vertexIndex].normal, 0.35f));
        }
        self.highlightedFaceBuffer = viewport_create_editor_vertex_buffer(self.device, vertices, range.vertexCount);
        self.highlightedFaceVertexCount = (NSUInteger)range.vertexCount;
        free(vertices);
        return;
    }
}

- (void)rebuildSelectedFaceBuffer {
    self.selectedFaceBuffer = nil;
    self.selectedFaceVertexCount = 0;
    if (!self.selectedFaceVisible || !self.cpuVertices || !self.faceRanges) {
        return;
    }

    for (size_t rangeIndex = 0; rangeIndex < self.faceRangeCount; ++rangeIndex) {
        ViewerFaceRange range = self.faceRanges[rangeIndex];
        if (range.entityIndex != self.selectedFaceEntityIndex ||
            range.solidIndex != self.selectedFaceSolidIndex ||
            range.sideIndex != self.selectedFaceSideIndex ||
            range.vertexCount == 0) {
            continue;
        }

        ViewerVertex* vertices = (ViewerVertex*)malloc(range.vertexCount * sizeof(ViewerVertex));
        if (!vertices) {
            return;
        }
        memcpy(vertices, self.cpuVertices + range.vertexStart, range.vertexCount * sizeof(ViewerVertex));
        for (size_t vertexIndex = 0; vertexIndex < range.vertexCount; ++vertexIndex) {
            vertices[vertexIndex].position = vec3_add(vertices[vertexIndex].position, vec3_scale(vertices[vertexIndex].normal, 0.6f));
        }
        self.selectedFaceBuffer = viewport_create_editor_vertex_buffer(self.device, vertices, range.vertexCount);
        self.selectedFaceVertexCount = (NSUInteger)range.vertexCount;
        free(vertices);
        return;
    }
}

- (void)setSelectedFaceHighlightEntityIndex:(size_t)entityIndex solidIndex:(size_t)solidIndex sideIndex:(size_t)sideIndex visible:(BOOL)visible {
    self.selectedFaceVisible = visible;
    self.selectedFaceEntityIndex = entityIndex;
    self.selectedFaceSolidIndex = solidIndex;
    self.selectedFaceSideIndex = sideIndex;
    [self rebuildSelectedFaceBuffer];
    [self.overlayView setNeedsDisplay:YES];
}

- (void)setHighlightedFaceEntityIndex:(size_t)entityIndex solidIndex:(size_t)solidIndex sideIndex:(size_t)sideIndex visible:(BOOL)visible {
    self.highlightedFaceVisible = visible;
    self.highlightedFaceEntityIndex = entityIndex;
    self.highlightedFaceSolidIndex = solidIndex;
    self.highlightedFaceSideIndex = sideIndex;
    [self rebuildHighlightedFaceBuffer];
    [self.overlayView setNeedsDisplay:YES];
}

- (void)setCreationBounds:(Bounds3)bounds visible:(BOOL)visible {
    self.creationBounds = normalized_bounds(bounds);
    self.creationVisible = visible;
    [self.overlayView setNeedsDisplay:YES];
}

- (void)setVertexEditIsInvalid:(BOOL)invalid {
    if (_vertexEditIsInvalid == invalid) {
        return;
    }
    _vertexEditIsInvalid = invalid;
    [self.overlayView setNeedsDisplay:YES];
}

- (void)setVertexEditPreviewEdges:(const ViewerVertex*)vertices count:(size_t)count {
    if (!vertices || count == 0) {
        self.vertexEditPreviewBuffer = nil;
        self.vertexEditPreviewVertexCount = 0;
        return;
    }
    self.vertexEditPreviewBuffer = viewport_create_editor_vertex_buffer(self.device, vertices, count);
    self.vertexEditPreviewVertexCount = count;
}

- (void)clearVertexEditPreview {
    self.vertexEditPreviewBuffer = nil;
    self.vertexEditPreviewVertexCount = 0;
}

- (void)clearEditorOverlay {
    self.selectionVisible = NO;
    free(self.selectionVertices);
    self.selectionVertices = NULL;
    self.selectionVertexCount = 0;
    free(self.selectionEdges);
    self.selectionEdges = NULL;
    self.selectionEdgeCount = 0;
    self.selectedFaceEdge = VmfViewportSelectionEdgeNone;
    self.selectedFaceVisible = NO;
    [self rebuildSelectedFaceBuffer];
    self.highlightedFaceVisible = NO;
    [self rebuildHighlightedFaceBuffer];
    self.creationVisible = NO;
    self.clipGuideVisible = NO;
    [self.overlayView setNeedsDisplay:YES];
}

- (BOOL)hasPendingClipLine {
    return self.clipGuideVisible;
}

- (BOOL)commitPendingClipLine {
    if (!self.clipGuideVisible || self.editorTool != VmfViewportEditorToolClip) {
        return NO;
    }
    if (vec3_length(vec3_sub(self.clipGuideEnd, self.clipGuideStart)) < (float)self.gridSize || !self.delegate) {
        return NO;
    }
    [self.delegate viewport:self clipSelectionFrom:self.clipGuideStart to:self.clipGuideEnd];
    self.clipGuideVisible = NO;
    [self.overlayView setNeedsDisplay:YES];
    return YES;
}

// ---------------------------------------------------------------------------
// Texture loading
// ---------------------------------------------------------------------------

- (nullable NSString*)texturePathForMaterial:(NSString*)material {
    if (!self.textureDirectory || material.length == 0) {
        return nil;
    }

    NSString* normalized = material.lowercaseString;
    if ([normalized isEqualToString:@"grid"]) {
        normalized = @"dev_grid";
    }
    return [[self.textureDirectory stringByAppendingPathComponent:normalized]
            stringByAppendingPathExtension:@"png"];
}

- (nullable NSDictionary<NSString*, id>*)loadTextureDataAtPath:(NSString*)path {
    NSImage* image = [[NSImage alloc] initWithContentsOfFile:path];
    if (!image) {
        return nil;
    }

    NSRect proposedRect = NSZeroRect;
    CGImageRef cgImage = [image CGImageForProposedRect:&proposedRect context:nil hints:nil];
    if (!cgImage) {
        return nil;
    }

    size_t imgW = CGImageGetWidth(cgImage);
    size_t imgH = CGImageGetHeight(cgImage);
    if (imgW == 0u || imgH == 0u) {
        return nil;
    }

    size_t bytesPerRow = imgW * 4u;
    NSMutableData* pixels = [NSMutableData dataWithLength:bytesPerRow * imgH];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        pixels.mutableBytes,
        imgW,
        imgH,
        8,
        bytesPerRow,
        cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) {
        return nil;
    }

    CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)imgW, (CGFloat)imgH), cgImage);
    CGContextRelease(ctx);
    return @{
        @"width": @(imgW),
        @"height": @(imgH),
        @"rgba8": pixels,
    };
}

- (nullable id<MTLTexture>)loadTextureAtPath:(NSString*)path {
    NSURL* url = [NSURL fileURLWithPath:path];
    MTKTextureLoader* loader = [[MTKTextureLoader alloc] initWithDevice:self.device];
    NSError* error = nil;
    NSDictionary* options = @{
        MTKTextureLoaderOptionSRGB: @NO,
        MTKTextureLoaderOptionGenerateMipmaps: @YES,
        MTKTextureLoaderOptionTextureUsage: @(MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget),
    };
    id<MTLTexture> tex = [loader newTextureWithContentsOfURL:url options:options error:&error];
    if (tex) {
        return tex;
    }

    // Fallback: use NSImage + CGBitmapContext to handle indexed, palette,
    // 4-bit, or any other format that MTKTextureLoader refuses.
    NSImage* image = [[NSImage alloc] initWithContentsOfFile:path];
    if (!image) {
        NSLog(@"[texture] failed to load %@: %@", path, error.localizedDescription);
        return nil;
    }
    NSRect proposedRect = NSZeroRect;
    CGImageRef cgImage = [image CGImageForProposedRect:&proposedRect context:nil hints:nil];
    if (!cgImage) return nil;

    size_t imgW = CGImageGetWidth(cgImage);
    size_t imgH = CGImageGetHeight(cgImage);
    if (imgW == 0 || imgH == 0) return nil;

    size_t bytesPerRow = imgW * 4;
    NSMutableData* pixels = [NSMutableData dataWithLength:bytesPerRow * imgH];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        pixels.mutableBytes, imgW, imgH, 8, bytesPerRow, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;
    CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)imgW, (CGFloat)imgH), cgImage);
    CGContextRelease(ctx);

    MTLTextureDescriptor* desc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:imgW height:imgH mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> result = [self.device newTextureWithDescriptor:desc];
    if (!result) return nil;
    [result replaceRegion:MTLRegionMake2D(0, 0, imgW, imgH)
              mipmapLevel:0
              withBytes:pixels.bytes
           bytesPerRow:bytesPerRow];
    NSLog(@"[texture] fallback-loaded %@ via NSImage (%zux%zu)", path.lastPathComponent, imgW, imgH);
    return result;
}

- (nullable id<MTLTexture>)cachedTextureForMaterial:(NSString*)material {
    NSString* normalized = material.lowercaseString;
    id entry = self.textureCache[normalized];
    if (entry != nil) {
        return (entry == (id)NSNull.null) ? nil : (id<MTLTexture>)entry;
    }
    // Not yet looked up — search disk
    NSString* fullPath = [self texturePathForMaterial:normalized];
    if (!fullPath) {
        self.textureCache[normalized] = NSNull.null;
        return nil;
    }
    if ([[NSFileManager defaultManager] fileExistsAtPath:fullPath]) {
        id<MTLTexture> tex = [self loadTextureAtPath:fullPath];
        if (tex) {
            NSLog(@"[texture] loaded %@ (%lux%lu)", fullPath, (unsigned long)tex.width, (unsigned long)tex.height);
            self.textureCache[normalized] = tex;
            return tex;
        }
        NSLog(@"[texture] MTKTextureLoader failed for %@", fullPath);
    } else {
        NSLog(@"[texture] file not found: %@", fullPath);
    }
    self.textureCache[normalized] = NSNull.null;
    return nil;
}

- (nullable NSDictionary<NSString*, id>*)cachedTextureDataForMaterial:(NSString*)material {
    NSString* normalized = material.lowercaseString;
    id entry = self.textureDataCache[normalized];
    if (entry != nil) {
        return entry == (id)NSNull.null ? nil : (NSDictionary<NSString*, id>*)entry;
    }

    NSString* fullPath = [self texturePathForMaterial:normalized];
    if (!fullPath) {
        self.textureDataCache[normalized] = NSNull.null;
        return nil;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:fullPath]) {
        self.textureDataCache[normalized] = NSNull.null;
        return nil;
    }

    NSDictionary<NSString*, id>* textureInfo = [self loadTextureDataAtPath:fullPath];
    self.textureDataCache[normalized] = textureInfo != nil ? textureInfo : (id)NSNull.null;
    return textureInfo;
}

- (void)clearTextureMissCache {
    NSArray* keys = self.textureCache.allKeys;
    for (NSString* key in keys) {
        if (self.textureCache[key] == (id)NSNull.null) {
            [self.textureCache removeObjectForKey:key];
        }
    }
    keys = self.textureDataCache.allKeys;
    for (NSString* key in keys) {
        if (self.textureDataCache[key] == (id)NSNull.null) {
            [self.textureDataCache removeObjectForKey:key];
        }
    }
}

- (void)clearTextureCache {
    [self.textureCache removeAllObjects];
    [self.textureDataCache removeAllObjects];
}

- (void)setTextureDirectory:(NSString*)path {
    if ([path isEqualToString:_textureDirectory]) {
        return;
    }
    _textureDirectory = [path copy];
    // Clear only "not found" entries so previously loaded textures survive
    NSArray* keys = self.textureCache.allKeys;
    for (NSString* key in keys) {
        if (self.textureCache[key] == (id)NSNull.null) {
            [self.textureCache removeObjectForKey:key];
        }
    }
    keys = self.textureDataCache.allKeys;
    for (NSString* key in keys) {
        if (self.textureDataCache[key] == (id)NSNull.null) {
            [self.textureDataCache removeObjectForKey:key];
        }
    }
}

- (void)updateMesh:(const ViewerMesh*)mesh {
    free(self.cpuVertices);
    self.cpuVertices = NULL;
    free(self.faceRanges);
    self.faceRanges = NULL;
    self.faceRangeCount = 0;
    if (!mesh || (mesh->vertexCount == 0 && mesh->edgeVertexCount == 0)) {
        self.vertexBuffer = nil;
        self.edgeVertexBuffer = nil;
        self.selectedFaceBuffer = nil;
        self.highlightedFaceBuffer = nil;
        self.vertexCount = 0;
        self.edgeVertexCount = 0;
        self.selectedFaceVertexCount = 0;
        self.highlightedFaceVertexCount = 0;
        self.sceneBounds = bounds3_empty();
        app_metal_editor_viewport_renderer_set_mesh(&_metalRenderer, NULL, 0, NULL, 0, NULL, 0);
        return;
    }

    NSUInteger length = (NSUInteger)(mesh->vertexCount * sizeof(ViewerVertex));
    self.vertexBuffer = [self.device newBufferWithBytes:mesh->vertices length:length options:MTLResourceStorageModeShared];
    if (mesh->edgeVertexCount > 0) {
        NSUInteger edgeLength = (NSUInteger)(mesh->edgeVertexCount * sizeof(ViewerVertex));
        self.edgeVertexBuffer = [self.device newBufferWithBytes:mesh->edgeVertices length:edgeLength options:MTLResourceStorageModeShared];
    } else {
        self.edgeVertexBuffer = nil;
    }
    self.vertexCount = mesh->vertexCount;
    self.edgeVertexCount = (NSUInteger)mesh->edgeVertexCount;
    self.cpuVertices = (ViewerVertex*)malloc(mesh->vertexCount * sizeof(ViewerVertex));
    if (self.cpuVertices) {
        memcpy(self.cpuVertices, mesh->vertices, mesh->vertexCount * sizeof(ViewerVertex));
    }
    if (mesh->faceRangeCount > 0) {
        self.faceRanges = (ViewerFaceRange*)malloc(mesh->faceRangeCount * sizeof(ViewerFaceRange));
        if (self.faceRanges) {
            memcpy(self.faceRanges, mesh->faceRanges, mesh->faceRangeCount * sizeof(ViewerFaceRange));
            self.faceRangeCount = mesh->faceRangeCount;
        }
    }
    self.sceneBounds = mesh->bounds;
    AppMetalEditorVertex* convertedVertices = viewport_create_editor_vertex_array(mesh->vertices, mesh->vertexCount);
    AppMetalEditorVertex* convertedEdgeVertices = viewport_create_editor_vertex_array(mesh->edgeVertices, mesh->edgeVertexCount);
    AppMetalEditorFaceRange* convertedFaceRanges = viewport_create_editor_face_range_array(mesh->faceRanges, mesh->faceRangeCount);
    app_metal_editor_viewport_renderer_set_mesh(&_metalRenderer,
                                                convertedVertices,
                                                mesh->vertexCount,
                                                convertedEdgeVertices,
                                                mesh->edgeVertexCount,
                                                convertedFaceRanges,
                                                mesh->faceRangeCount);
    free(convertedVertices);
    free(convertedEdgeVertices);
    free(convertedFaceRanges);
    [self syncHeavyRendererSceneFromMesh:mesh];
    [self rebuildSelectedFaceBuffer];
    [self rebuildHighlightedFaceBuffer];
}

- (void)syncHeavyRendererSceneFromMesh:(const ViewerMesh*)mesh {
    NovaSceneObjectRecord objectRecords[UI_MAX_SCENE_OBJECTS] = {0};
    char materialNames[UI_MAX_LIGHTS][128] = {{0}};
    float materialColors[UI_MAX_LIGHTS][3] = {{0}};
    uint32_t materialSamples[UI_MAX_LIGHTS] = {0};
    int32_t materialTextureIndices[UI_MAX_LIGHTS];
    NSMutableDictionary<NSString*, NSNumber*>* importedTextureIndices = [NSMutableDictionary dictionary];
    NSMutableArray<NSDictionary<NSString*, id>*>* importedTextures = [NSMutableArray array];
    uint32_t objectCount = 0u;
    uint32_t materialCount = 0u;
    NovaSceneImportedRuntime* importedRuntime = nova_scene_world_imported_runtime(self.sceneWorld);

    for (uint32_t index = 0u; index < UI_MAX_LIGHTS; ++index) {
        materialTextureIndices[index] = -1;
    }

    nova_scene_data_release(&_importedSceneData);
    nova_scene_data_init(&_importedSceneData);

    if (self.sceneWorld == NULL || mesh == NULL || mesh->vertices == NULL || mesh->vertexCount == 0 || mesh->faceRanges == NULL || mesh->faceRangeCount == 0 || mesh->faceRangeCount > UI_MAX_SCENE_OBJECTS) {
        _fullRendererUiState.importedSceneActive = 0;
        if (importedRuntime != NULL) {
            importedRuntime->active = 0u;
            importedRuntime->materialCount = 0u;
            importedRuntime->textureCount = 0u;
            nova_scene_world_sync_objects(self.sceneWorld, objectRecords, 0u);
        }
        return;
    }

    _importedSceneData.vertexCount = (uint32_t)mesh->vertexCount;
    _importedSceneData.primitiveCount = (uint32_t)(mesh->vertexCount / 3u);
    _importedSceneData.objectCount = (uint32_t)mesh->faceRangeCount;
    _importedSceneData.vertices = (NovaSceneVertex*)calloc(_importedSceneData.vertexCount, sizeof(NovaSceneVertex));
    _importedSceneData.primitiveMaterialIndices = (uint32_t*)calloc(_importedSceneData.primitiveCount > 0u ? _importedSceneData.primitiveCount : 1u, sizeof(uint32_t));
    _importedSceneData.objects = (NovaSceneObject*)calloc(_importedSceneData.objectCount, sizeof(NovaSceneObject));
    if (_importedSceneData.vertices == NULL || _importedSceneData.primitiveMaterialIndices == NULL || _importedSceneData.objects == NULL) {
        nova_scene_data_release(&_importedSceneData);
        _fullRendererUiState.importedSceneActive = 0;
        return;
    }

    for (size_t faceIndex = 0; faceIndex < mesh->faceRangeCount; ++faceIndex) {
        ViewerFaceRange range = mesh->faceRanges[faceIndex];
        uint32_t materialIndex = 0u;
        Bounds3 objectBounds;

        if (strncmp(range.material, "light_marker", sizeof(range.material)) == 0) {
            continue;
        }

        if (range.vertexStart >= mesh->vertexCount) {
            continue;
        }
        if (range.vertexStart + range.vertexCount > mesh->vertexCount) {
            range.vertexCount = mesh->vertexCount - range.vertexStart;
        }
        range.vertexCount -= range.vertexCount % 3u;
        if (range.vertexCount == 0u) {
            continue;
        }

        for (; materialIndex < materialCount; ++materialIndex) {
            if (strncmp(materialNames[materialIndex], range.material, sizeof(materialNames[materialIndex])) == 0) {
                break;
            }
        }
        if (materialIndex == materialCount) {
            if (materialCount >= UI_MAX_LIGHTS) {
                continue;
            }
            snprintf(materialNames[materialIndex], sizeof(materialNames[materialIndex]), "%s", range.material);
            materialCount += 1u;
        }

        for (size_t vertexOffset = 0; vertexOffset < range.vertexCount; ++vertexOffset) {
            size_t sourceIndex = range.vertexStart + vertexOffset;
            const ViewerVertex* source = &mesh->vertices[sourceIndex];
            NovaSceneVertex* destination = &_importedSceneData.vertices[sourceIndex];
            destination->position[0] = source->position.raw[0];
            destination->position[1] = source->position.raw[1];
            destination->position[2] = source->position.raw[2];
            destination->normal[0] = source->normal.raw[0];
            destination->normal[1] = source->normal.raw[1];
            destination->normal[2] = source->normal.raw[2];
            destination->uv[0] = source->u;
            destination->uv[1] = source->v;
            destination->tangent[0] = 1.0f;
            destination->tangent[1] = 0.0f;
            destination->tangent[2] = 0.0f;
            destination->tangent[3] = 1.0f;
            destination->materialIndex = materialIndex;
            materialColors[materialIndex][0] += source->color.raw[0];
            materialColors[materialIndex][1] += source->color.raw[1];
            materialColors[materialIndex][2] += source->color.raw[2];
            materialSamples[materialIndex] += 1u;
        }

        for (size_t primitiveIndex = 0; primitiveIndex < range.vertexCount / 3u; ++primitiveIndex) {
            _importedSceneData.primitiveMaterialIndices[(range.vertexStart / 3u) + primitiveIndex] = materialIndex;
        }

        snprintf(_importedSceneData.objects[objectCount].name,
             sizeof(_importedSceneData.objects[objectCount].name),
             "face_%zu_%zu_%zu_%zu",
             range.entityIndex,
             range.solidIndex,
             range.sideIndex,
             faceIndex);
        _importedSceneData.objects[objectCount].primitiveOffset = (uint32_t)(range.vertexStart / 3u);
        _importedSceneData.objects[objectCount].primitiveCount = (uint32_t)(range.vertexCount / 3u);
        _importedSceneData.objects[objectCount].vertexOffset = (uint32_t)range.vertexStart;
        _importedSceneData.objects[objectCount].vertexCount = (uint32_t)range.vertexCount;
        viewport_identity_matrix(_importedSceneData.objects[objectCount].worldMatrix);

        objectBounds = viewport_bounds_for_vertex_range(mesh->vertices, range.vertexStart, range.vertexCount);
        snprintf(objectRecords[objectCount].name, sizeof(objectRecords[objectCount].name), "%s", _importedSceneData.objects[objectCount].name);
        viewport_identity_matrix(objectRecords[objectCount].worldMatrix);
        objectRecords[objectCount].aabbMin[0] = objectBounds.min.raw[0];
        objectRecords[objectCount].aabbMin[1] = objectBounds.min.raw[1];
        objectRecords[objectCount].aabbMin[2] = objectBounds.min.raw[2];
        objectRecords[objectCount].aabbMax[0] = objectBounds.max.raw[0];
        objectRecords[objectCount].aabbMax[1] = objectBounds.max.raw[1];
        objectRecords[objectCount].aabbMax[2] = objectBounds.max.raw[2];
        objectRecords[objectCount].sceneObjectIndex = objectCount;
        objectRecords[objectCount].blasIndex = objectCount;
        objectRecords[objectCount].vertexOffset = _importedSceneData.objects[objectCount].vertexOffset;
        objectRecords[objectCount].vertexCount = _importedSceneData.objects[objectCount].vertexCount;
        objectRecords[objectCount].primitiveOffset = _importedSceneData.objects[objectCount].primitiveOffset;
        objectRecords[objectCount].primitiveCount = _importedSceneData.objects[objectCount].primitiveCount;
        objectRecords[objectCount].materialIndex = (int)materialIndex;
        objectCount += 1u;
    }

    _importedSceneData.objectCount = objectCount;
    _importedSceneData.materialCount = materialCount;
    _importedSceneData.materials = (NovaSceneMaterial*)calloc(materialCount > 0u ? materialCount : 1u, sizeof(NovaSceneMaterial));
    if (_importedSceneData.materials == NULL) {
        nova_scene_data_release(&_importedSceneData);
        _fullRendererUiState.importedSceneActive = 0;
        return;
    }

    for (uint32_t materialIndex = 0u; materialIndex < materialCount; ++materialIndex) {
        NSString* materialName = [NSString stringWithUTF8String:materialNames[materialIndex]];
        NSDictionary<NSString*, id>* textureInfo;
        NSNumber* existingTextureIndex;

        if (materialName.length == 0) {
            continue;
        }
        if ([materialName caseInsensitiveCompare:@"nodraw"] == NSOrderedSame ||
            [materialName caseInsensitiveCompare:@"clip"] == NSOrderedSame) {
            continue;
        }

        textureInfo = [self cachedTextureDataForMaterial:materialName];
        if (textureInfo == nil) {
            continue;
        }

        existingTextureIndex = importedTextureIndices[materialName.lowercaseString];
        if (existingTextureIndex == nil) {
            if (importedTextures.count >= UI_MAX_LIGHTS) {
                continue;
            }
            existingTextureIndex = @(importedTextures.count);
            importedTextureIndices[materialName.lowercaseString] = existingTextureIndex;
            [importedTextures addObject:textureInfo];
        }
        materialTextureIndices[materialIndex] = existingTextureIndex.intValue;
    }

    _importedSceneData.textureCount = (uint32_t)importedTextures.count;
    if (_importedSceneData.textureCount > 0u) {
        _importedSceneData.textures = (NovaSceneTexture*)calloc(_importedSceneData.textureCount, sizeof(NovaSceneTexture));
        if (_importedSceneData.textures == NULL) {
            nova_scene_data_release(&_importedSceneData);
            _fullRendererUiState.importedSceneActive = 0;
            return;
        }
        for (uint32_t textureIndex = 0u; textureIndex < _importedSceneData.textureCount; ++textureIndex) {
            NSDictionary<NSString*, id>* textureInfo = importedTextures[textureIndex];
            NSData* rgba8 = textureInfo[@"rgba8"];
            int width = [textureInfo[@"width"] intValue];
            int height = [textureInfo[@"height"] intValue];
            size_t byteCount = (size_t)width * (size_t)height * 4u;
            unsigned char* pixels = (unsigned char*)malloc(byteCount);

            if (pixels == NULL) {
                nova_scene_data_release(&_importedSceneData);
                _fullRendererUiState.importedSceneActive = 0;
                return;
            }

            memcpy(pixels, rgba8.bytes, byteCount);
            _importedSceneData.textures[textureIndex].width = width;
            _importedSceneData.textures[textureIndex].height = height;
            _importedSceneData.textures[textureIndex].rgba8 = pixels;
        }
    }

    importedRuntime->active = objectCount > 0u ? 1u : 0u;
    importedRuntime->materialCount = materialCount;
    importedRuntime->textureCount = _importedSceneData.textureCount;
    importedRuntime->usesBuiltinMaterialSet = 0u;
    importedRuntime->rtAsUpdatePending = 1u;
    memset(importedRuntime->materialsCpu, 0, sizeof(importedRuntime->materialsCpu));
    memset(importedRuntime->materialRecords, 0, sizeof(importedRuntime->materialRecords));
    memset(importedRuntime->blasPrimitiveOffset, 0, sizeof(importedRuntime->blasPrimitiveOffset));
    memset(importedRuntime->blasVertexOffset, 0, sizeof(importedRuntime->blasVertexOffset));
    memset(importedRuntime->blasVertexCount, 0, sizeof(importedRuntime->blasVertexCount));
    memset(importedRuntime->blasFlags, 0, sizeof(importedRuntime->blasFlags));
    memset(importedRuntime->instanceBlasIndex, 0, sizeof(importedRuntime->instanceBlasIndex));

    for (uint32_t materialIndex = 0u; materialIndex < materialCount; ++materialIndex) {
        float sampleCount = materialSamples[materialIndex] > 0u ? (float)materialSamples[materialIndex] : 1.0f;
        NovaSceneMaterial* material = &_importedSceneData.materials[materialIndex];
        NovaSceneGpuMaterial* materialGpu = &importedRuntime->materialsCpu[materialIndex];
        NovaSceneImportedMaterialRecord* materialRecord = &importedRuntime->materialRecords[materialIndex];
        int32_t textureIndex = materialTextureIndices[materialIndex];
        float logicalTextureSize = -1.0f;
        float baseColorR = materialColors[materialIndex][0] / sampleCount;
        float baseColorG = materialColors[materialIndex][1] / sampleCount;
        float baseColorB = materialColors[materialIndex][2] / sampleCount;

        if (textureIndex >= 0 && strncmp(materialNames[materialIndex], "dev_", 4) == 0) {
            logicalTextureSize = 256.0f;
        }

        if (textureIndex >= 0) {
            baseColorR = 1.0f;
            baseColorG = 1.0f;
            baseColorB = 1.0f;
        }

        snprintf(material->name, sizeof(material->name), "%s", materialNames[materialIndex]);
        material->baseColorFactor[0] = baseColorR;
        material->baseColorFactor[1] = baseColorG;
        material->baseColorFactor[2] = baseColorB;
        material->baseColorFactor[3] = 1.0f;
        material->roughness = 1.0f;
        material->ior = 1.45f;
        material->baseColorTexture = textureIndex;
        material->metallicRoughnessTexture = -1;
        material->normalTexture = -1;
        material->emissiveTexture = -1;
        material->occlusionTexture = -1;
        material->transmissionTexture = -1;
        material->normalScale = 1.0f;
        material->alphaCutoff = 0.5f;
        material->alphaMode = textureIndex >= 0 ? 1 : 0;
        snprintf(materialRecord->name, sizeof(materialRecord->name), "%s", materialNames[materialIndex]);
        materialRecord->baseColor[0] = material->baseColorFactor[0];
        materialRecord->baseColor[1] = material->baseColorFactor[1];
        materialRecord->baseColor[2] = material->baseColorFactor[2];
        materialRecord->baseColor[3] = 1.0f;
        materialRecord->roughness = 1.0f;
        materialRecord->ior = 1.45f;
        viewport_init_imported_material_gpu_defaults(materialGpu);
        materialGpu->baseColor[0] = material->baseColorFactor[0];
        materialGpu->baseColor[1] = material->baseColorFactor[1];
        materialGpu->baseColor[2] = material->baseColorFactor[2];
        materialGpu->baseColor[3] = 1.0f;
        materialGpu->params[1] = 1.0f;
        materialGpu->params[3] = 1.45f;
        materialGpu->texIndices[0] = (float)textureIndex;
        materialGpu->emissive[3] = logicalTextureSize;
    }

    for (uint32_t objectIndex = 0u; objectIndex < objectCount; ++objectIndex) {
        importedRuntime->instanceBlasIndex[objectIndex] = objectIndex;
        importedRuntime->blasPrimitiveOffset[objectIndex] = objectRecords[objectIndex].primitiveOffset;
        importedRuntime->blasVertexOffset[objectIndex] = objectRecords[objectIndex].vertexOffset;
        importedRuntime->blasVertexCount[objectIndex] = objectRecords[objectIndex].vertexCount;
        importedRuntime->blasFlags[objectIndex] = objectRecords[objectIndex].flags;
    }

    nova_scene_world_sync_objects(self.sceneWorld, objectRecords, objectCount);
    _fullRendererUiState.importedSceneActive = objectCount > 0u ? 1 : 0;
}

- (void)frameScene {
    if (!bounds3_is_valid(self.sceneBounds)) {
        self.target = vec3_make(0.0f, 0.0f, 0.0f);
        self.distance = 1024.0f;
        self.orthoCenter = self.target;
        self.orthoSize = 2048.0f;
        return;
    }

    Vec3 size = bounds3_size(self.sceneBounds);
    float radius = fmaxf(vec3_length(size) * 0.5f, 64.0f);
    self.target = bounds3_center(self.sceneBounds);
    self.distance = radius * 2.1f;
    self.freeLookPosition = [self cameraPosition];
    self.orthoCenter = self.target;
    self.orthoSize = fmaxf(fmaxf(size.raw[0], fmaxf(size.raw[1], size.raw[2])) * 1.15f, 256.0f);
    [self.overlayView setNeedsDisplay:YES];
}

- (void)setMovementForward:(BOOL)forward backward:(BOOL)backward left:(BOOL)left right:(BOOL)right {
    CameraMovement movementMask = 0;
    if (forward) {
        movementMask |= CameraMovementForward;
    }
    if (backward) {
        movementMask |= CameraMovementBackward;
    }
    if (left) {
        movementMask |= CameraMovementLeft;
    }
    if (right) {
        movementMask |= CameraMovementRight;
    }
    self.movementMask = movementMask;
}

- (Vec3)forwardVector {
    float cosPitch = cosf(self.pitch);
    return vec3_normalize(vec3_make(
        -cosPitch * cosf(self.yaw),
        -cosPitch * sinf(self.yaw),
        -sinf(self.pitch)
    ));
}

- (Vec3)rightVector {
    return vec3_normalize(vec3_cross([self forwardVector], world_up()));
}

- (Vec3)cameraPosition {
    if (self.freeLookActive) {
        return self.freeLookPosition;
    }

    float cosPitch = cosf(self.pitch);
    Vec3 offset = vec3_make(
        self.distance * cosPitch * cosf(self.yaw),
        self.distance * cosPitch * sinf(self.yaw),
        self.distance * sinf(self.pitch)
    );
    return vec3_add(self.target, offset);
}

- (Vec3)cameraTarget {
    if (self.freeLookActive) {
        return vec3_add(self.freeLookPosition, [self forwardVector]);
    }
    return self.target;
}

- (Mat4)projectionMatrixForAspect:(float)aspect {
    if (self.dimension == VmfViewportDimension3D) {
        return cglm_mat4_perspective(0.75f, aspect, 1.0f, 131072.0f);
    }

    float halfHeight = self.orthoSize * 0.5f;
    float halfWidth = halfHeight * aspect;
    return cglm_mat4_ortho(-halfWidth, halfWidth, -halfHeight, halfHeight, -131072.0f, 131072.0f);
}

- (Mat4)viewMatrixWithCameraPosition:(Vec3*)outCameraPosition {
    if (self.dimension == VmfViewportDimension3D) {
        Vec3 eye = [self cameraPosition];
        if (outCameraPosition) {
            *outCameraPosition = eye;
        }
        return cglm_mat4_look_at(eye, [self cameraTarget], world_up());
    }

    Vec3 forward = plane_forward(self.plane);
    Vec3 up = plane_up(self.plane);
    Vec3 eye = vec3_sub(self.orthoCenter, vec3_scale(forward, 4096.0f));
    if (outCameraPosition) {
        *outCameraPosition = eye;
    }
    return cglm_mat4_look_at(eye, self.orthoCenter, up);
}

- (Uniforms)uniformsForAspect:(float)aspect {
    Vec3 eye;
    Mat4 projection = [self projectionMatrixForAspect:aspect];
    Mat4 viewMatrix = [self viewMatrixWithCameraPosition:&eye];
    Uniforms uniforms = {0};
    copy_mat4_to_uniform(uniforms.viewProjection, cglm_mat4_mul(projection, viewMatrix));
    uniforms.cameraPosition[0] = eye.raw[0];
    uniforms.cameraPosition[1] = eye.raw[1];
    uniforms.cameraPosition[2] = eye.raw[2];
    uniforms.lightDirectionIntensity[0] = -0.45f;
    uniforms.lightDirectionIntensity[1] = -0.25f;
    uniforms.lightDirectionIntensity[2] = 0.85f;
    uniforms.lightDirectionIntensity[3] = self.primaryLightIntensity;
    uniforms.lightPositionRange[0] = self.primaryLightPosition.raw[0];
    uniforms.lightPositionRange[1] = self.primaryLightPosition.raw[1];
    uniforms.lightPositionRange[2] = self.primaryLightPosition.raw[2];
    uniforms.lightPositionRange[3] = self.primaryLightRange;
    uniforms.lightColor[0] = self.primaryLightColor.raw[0];
    uniforms.lightColor[1] = self.primaryLightColor.raw[1];
    uniforms.lightColor[2] = self.primaryLightColor.raw[2];
    uniforms.lightColor[3] = 1.0f;
    uniforms.colorTint[0] = 1.0f;
    uniforms.colorTint[1] = 1.0f;
    uniforms.colorTint[2] = 1.0f;
    uniforms.colorTint[3] = 1.0f;
    uniforms.flags[0] = self.primaryLightEnabled ? 1u : 0u;
    uniforms.flags[1] = 0u;
    uniforms.flags[2] = (self.dimension == VmfViewportDimension3D && self.renderMode == VmfViewportRenderModeShaded) ? 1u : 0u;
    uniforms.flags[3] = 0u;
    return uniforms;
}

- (void)setPrimaryLightPosition:(Vec3)position color:(Vec3)color intensity:(float)intensity range:(float)range enabled:(BOOL)enabled {
    self.primaryLightPosition = position;
    self.primaryLightColor = color;
    self.primaryLightIntensity = intensity;
    self.primaryLightRange = range;
    self.primaryLightEnabled = enabled;
}

- (void)updateFreeLookWithDeltaTime:(CFTimeInterval)deltaTime {
    if (!self.freeLookActive || self.movementMask == 0) {
        return;
    }

    Vec3 forward = [self forwardVector];
    Vec3 right = [self rightVector];
    Vec3 movement = vec3_make(0.0f, 0.0f, 0.0f);
    if (self.movementMask & CameraMovementForward) {
        movement = vec3_add(movement, forward);
    }
    if (self.movementMask & CameraMovementBackward) {
        movement = vec3_sub(movement, forward);
    }
    if (self.movementMask & CameraMovementRight) {
        movement = vec3_add(movement, right);
    }
    if (self.movementMask & CameraMovementLeft) {
        movement = vec3_sub(movement, right);
    }
    if (vec3_length(movement) < 1e-5f) {
        return;
    }

    float speed = fmaxf(self.distance * 0.25f, 76.8f);
    self.freeLookPosition = vec3_add(self.freeLookPosition, vec3_scale(vec3_normalize(movement), speed * (float)deltaTime));
}

- (void)zoomByDelta:(float)delta {
    if (self.dimension == VmfViewportDimension3D) {
        self.distance = fmaxf(self.distance * (1.0f + delta * 0.1f), 8.0f);
        return;
    }
    self.orthoSize = fmaxf(self.orthoSize * (1.0f + delta * 0.1f), 16.0f);
    [self.overlayView setNeedsDisplay:YES];
}

- (void)panOrOrbitByDeltaX:(float)deltaX deltaY:(float)deltaY {
    if (self.dimension == VmfViewportDimension3D) {
        if (self.freeLookActive) {
            return;
        }
        self.yaw -= deltaX * 0.002f;
        self.pitch = fminf(fmaxf(self.pitch - deltaY * 0.002f, -1.45f), 1.45f);
        return;
    }

    float viewportHeight = fmaxf(self.metalView.bounds.size.height, 1.0f);
    float worldPerPoint = self.orthoSize / viewportHeight;
    Vec3 horizontal = vec3_scale(plane_right(self.plane), -deltaX * worldPerPoint);
    Vec3 vertical = vec3_scale(plane_up(self.plane), -deltaY * worldPerPoint);
    self.orthoCenter = vec3_add(self.orthoCenter, vec3_add(horizontal, vertical));
    [self.overlayView setNeedsDisplay:YES];
}

- (float)visibleWidth {
    float height = fmaxf(self.metalView.bounds.size.height, 1.0f);
    float width = fmaxf(self.metalView.bounds.size.width, 1.0f);
    return self.orthoSize * (width / height);
}

- (Vec3)snappedWorldPointForViewPoint:(NSPoint)point {
    Vec3 axisU = plane_right(self.plane);
    Vec3 axisV = plane_up(self.plane);
    float centerU = plane_u_value(self.plane, self.orthoCenter);
    float centerV = plane_v_value(self.plane, self.orthoCenter);
    Vec3 planeOrigin = vec3_sub(self.orthoCenter, vec3_add(vec3_scale(axisU, centerU), vec3_scale(axisV, centerV)));
    float u = centerU + ((float)(point.x / fmax(self.metalView.bounds.size.width, 1.0)) - 0.5f) * [self visibleWidth];
    float v = centerV + ((float)(point.y / fmax(self.metalView.bounds.size.height, 1.0)) - 0.5f) * self.orthoSize;
    u = snap_to_grid(u, (float)self.gridSize);
    v = snap_to_grid(v, (float)self.gridSize);
    return vec3_add(planeOrigin, vec3_add(vec3_scale(axisU, u), vec3_scale(axisV, v)));
}

- (Vec3)snappedWorldPointForViewPoint:(NSPoint)point preservingHiddenAxisFrom:(Vec3)referencePoint {
    Vec3 snappedPoint = [self snappedWorldPointForViewPoint:point];
    switch (self.plane) {
        case VmfViewportPlaneXY:
            snappedPoint.raw[2] = referencePoint.raw[2];
            break;
        case VmfViewportPlaneXZ:
            snappedPoint.raw[1] = referencePoint.raw[1];
            break;
        case VmfViewportPlaneZY:
            snappedPoint.raw[0] = referencePoint.raw[0];
            break;
    }
    return snappedPoint;
}

- (NSPoint)viewPointForWorldPoint:(Vec3)point {
    float width = fmaxf(self.metalView.bounds.size.width, 1.0f);
    float height = fmaxf(self.metalView.bounds.size.height, 1.0f);
    float visibleWidth = [self visibleWidth];
    float centerU = plane_u_value(self.plane, self.orthoCenter);
    float centerV = plane_v_value(self.plane, self.orthoCenter);
    float u = plane_u_value(self.plane, point);
    float v = plane_v_value(self.plane, point);
    return NSMakePoint(((u - centerU) / visibleWidth + 0.5f) * width,
                       ((v - centerV) / self.orthoSize + 0.5f) * height);
}

- (NSRect)screenRectForBounds:(Bounds3)bounds {
    if (!bounds3_is_valid(bounds)) {
        return NSZeroRect;
    }
    Bounds3 normalized = normalized_bounds(bounds);
    float width = fmaxf(self.metalView.bounds.size.width, 1.0f);
    float height = fmaxf(self.metalView.bounds.size.height, 1.0f);
    float visibleWidth = [self visibleWidth];
    float centerU = plane_u_value(self.plane, self.orthoCenter);
    float centerV = plane_v_value(self.plane, self.orthoCenter);
    float minU = plane_u_value(self.plane, normalized.min);
    float maxU = plane_u_value(self.plane, normalized.max);
    float minV = plane_v_value(self.plane, normalized.min);
    float maxV = plane_v_value(self.plane, normalized.max);

    float left = ((minU - centerU) / visibleWidth + 0.5f) * width;
    float right = ((maxU - centerU) / visibleWidth + 0.5f) * width;
    float bottom = ((minV - centerV) / self.orthoSize + 0.5f) * height;
    float top = ((maxV - centerV) / self.orthoSize + 0.5f) * height;
    return NSMakeRect(fmin(left, right), fmin(bottom, top), fabsf(right - left), fabsf(top - bottom));
}

- (Vec3)rayDirectionForViewPoint:(NSPoint)point {
    float width = fmaxf(self.metalView.bounds.size.width, 1.0f);
    float height = fmaxf(self.metalView.bounds.size.height, 1.0f);
    float aspect = width / height;
    float ndcX = (2.0f * (float)point.x / width) - 1.0f;
    float ndcY = (2.0f * (float)point.y / height) - 1.0f;
    float tanHalfFov = tanf(0.75f * 0.5f);
    Vec3 forward = [self forwardVector];
    Vec3 right = [self rightVector];
    Vec3 up = vec3_normalize(vec3_cross(right, forward));
    Vec3 direction = vec3_add(forward,
                              vec3_add(vec3_scale(right, ndcX * aspect * tanHalfFov),
                                       vec3_scale(up, ndcY * tanHalfFov)));
    return vec3_normalize(direction);
}

- (ViewportHandle)handleAtPoint:(NSPoint)point {
    if (!self.selectionVisible || self.dimension != VmfViewportDimension2D) {
        return ViewportHandleNone;
    }
    NSRect rect = [self screenRectForBounds:self.selectionBounds];
    if (self.selectionEditable) {
        const CGFloat handleSize = 10.0;
        NSRect corners[4] = {
            NSMakeRect(NSMinX(rect) - handleSize * 0.5, NSMinY(rect) - handleSize * 0.5, handleSize, handleSize),
            NSMakeRect(NSMaxX(rect) - handleSize * 0.5, NSMinY(rect) - handleSize * 0.5, handleSize, handleSize),
            NSMakeRect(NSMaxX(rect) - handleSize * 0.5, NSMaxY(rect) - handleSize * 0.5, handleSize, handleSize),
            NSMakeRect(NSMinX(rect) - handleSize * 0.5, NSMaxY(rect) - handleSize * 0.5, handleSize, handleSize),
        };
        NSRect midpoints[4] = {
            NSMakeRect(NSMinX(rect) - handleSize * 0.5, NSMidY(rect) - handleSize * 0.5, handleSize, handleSize),
            NSMakeRect(NSMaxX(rect) - handleSize * 0.5, NSMidY(rect) - handleSize * 0.5, handleSize, handleSize),
            NSMakeRect(NSMidX(rect) - handleSize * 0.5, NSMinY(rect) - handleSize * 0.5, handleSize, handleSize),
            NSMakeRect(NSMidX(rect) - handleSize * 0.5, NSMaxY(rect) - handleSize * 0.5, handleSize, handleSize),
        };
        if (NSPointInRect(point, corners[0])) {
            return ViewportHandleMinUMinV;
        }
        if (NSPointInRect(point, corners[1])) {
            return ViewportHandleMaxUMinV;
        }
        if (NSPointInRect(point, corners[2])) {
            return ViewportHandleMaxUMaxV;
        }
        if (NSPointInRect(point, corners[3])) {
            return ViewportHandleMinUMaxV;
        }
        if (NSPointInRect(point, midpoints[0])) {
            return ViewportHandleMinUMidV;
        }
        if (NSPointInRect(point, midpoints[1])) {
            return ViewportHandleMaxUMidV;
        }
        if (NSPointInRect(point, midpoints[2])) {
            return ViewportHandleMidUMinV;
        }
        if (NSPointInRect(point, midpoints[3])) {
            return ViewportHandleMidUMaxV;
        }
    }
    if (NSPointInRect(point, NSInsetRect(rect, -3.0, -3.0))) {
        return ViewportHandleBody;
    }
    return ViewportHandleNone;
}

- (VmfViewportSelectionEdge)selectionEdgeAtPoint:(NSPoint)point {
    if (!self.selectionVisible || !self.selectionEditable || self.dimension != VmfViewportDimension2D) {
        return VmfViewportSelectionEdgeNone;
    }

    NSRect rect = [self screenRectForBounds:self.selectionBounds];
    if (NSIsEmptyRect(rect)) {
        return VmfViewportSelectionEdgeNone;
    }

    const CGFloat threshold = 8.0;
    CGFloat distanceMinU = fabs(point.x - NSMinX(rect));
    CGFloat distanceMaxU = fabs(point.x - NSMaxX(rect));
    CGFloat distanceMinV = fabs(point.y - NSMinY(rect));
    CGFloat distanceMaxV = fabs(point.y - NSMaxY(rect));
    CGFloat bestDistance = threshold;
    VmfViewportSelectionEdge bestEdge = VmfViewportSelectionEdgeNone;

    if (point.y >= NSMinY(rect) - threshold && point.y <= NSMaxY(rect) + threshold && distanceMinU <= bestDistance) {
        bestDistance = distanceMinU;
        bestEdge = VmfViewportSelectionEdgeMinU;
    }
    if (point.y >= NSMinY(rect) - threshold && point.y <= NSMaxY(rect) + threshold && distanceMaxU <= bestDistance) {
        bestDistance = distanceMaxU;
        bestEdge = VmfViewportSelectionEdgeMaxU;
    }
    if (point.x >= NSMinX(rect) - threshold && point.x <= NSMaxX(rect) + threshold && distanceMinV <= bestDistance) {
        bestDistance = distanceMinV;
        bestEdge = VmfViewportSelectionEdgeMinV;
    }
    if (point.x >= NSMinX(rect) - threshold && point.x <= NSMaxX(rect) + threshold && distanceMaxV <= bestDistance) {
        bestEdge = VmfViewportSelectionEdgeMaxV;
    }
    return bestEdge;
}

- (NSInteger)vertexIndexAtPoint:(NSPoint)point {
    if (!self.selectionVisible || self.dimension != VmfViewportDimension2D || !self.selectionVertices || self.selectionVertexCount == 0) {
        return -1;
    }

    const CGFloat threshold = 8.0;
    CGFloat bestDistance = threshold;
    NSInteger bestIndex = -1;
    for (size_t vertexIndex = 0; vertexIndex < self.selectionVertexCount; ++vertexIndex) {
        NSPoint vertexPoint = [self viewPointForWorldPoint:self.selectionVertices[vertexIndex]];
        CGFloat distance = hypot(point.x - vertexPoint.x, point.y - vertexPoint.y);
        if (distance <= bestDistance) {
            bestDistance = distance;
            bestIndex = (NSInteger)vertexIndex;
        }
    }
    return bestIndex;
}

- (NSUInteger)vertexIndicesAtPoint:(NSPoint)point outIndices:(size_t*)outIndices maxCount:(NSUInteger)maxCount {
    if (!self.selectionVisible || self.dimension != VmfViewportDimension2D || !self.selectionVertices || self.selectionVertexCount == 0 || !outIndices || maxCount == 0) {
        return 0;
    }

    // First find the best (closest) index
    NSInteger bestIndex = [self vertexIndexAtPoint:point];
    if (bestIndex < 0) {
        return 0;
    }

    // Now find the 2D screen position of that best vertex and collect all vertices
    // within a small screen tolerance of that exact 2D position (stacked vertices).
    NSPoint bestScreenPt = [self viewPointForWorldPoint:self.selectionVertices[(size_t)bestIndex]];
    const CGFloat stackThreshold = 2.0;
    NSUInteger count = 0;
    for (size_t vertexIndex = 0; vertexIndex < self.selectionVertexCount && count < maxCount; ++vertexIndex) {
        NSPoint screenPt = [self viewPointForWorldPoint:self.selectionVertices[vertexIndex]];
        CGFloat dist = hypot(screenPt.x - bestScreenPt.x, screenPt.y - bestScreenPt.y);
        if (dist <= stackThreshold) {
            outIndices[count++] = vertexIndex;
        }
    }
    return count;
}

- (NSInteger)edgeIndexAtPoint:(NSPoint)point {
    if (!self.selectionVisible || self.dimension != VmfViewportDimension2D || !self.selectionEdges || self.selectionEdgeCount == 0) {
        return -1;
    }

    const CGFloat threshold = 7.0;
    CGFloat bestDistance = threshold;
    NSInteger bestIndex = -1;
    for (size_t edgeIndex = 0; edgeIndex < self.selectionEdgeCount; ++edgeIndex) {
        const VmfSolidEdge* edge = &self.selectionEdges[edgeIndex];
        if (edge->endpointCount < 2) {
            continue;
        }
        NSPoint start = [self viewPointForWorldPoint:edge->start];
        NSPoint end = [self viewPointForWorldPoint:edge->end];
        CGFloat segmentDx = end.x - start.x;
        CGFloat segmentDy = end.y - start.y;
        CGFloat segmentLengthSquared = segmentDx * segmentDx + segmentDy * segmentDy;
        if (segmentLengthSquared < 16.0) {
            continue;
        }
        CGFloat t = ((point.x - start.x) * segmentDx + (point.y - start.y) * segmentDy) / segmentLengthSquared;
        t = fmax(0.0, fmin(1.0, t));
        CGFloat closestX = start.x + segmentDx * t;
        CGFloat closestY = start.y + segmentDy * t;
        CGFloat distance = hypot(point.x - closestX, point.y - closestY);
        if (distance <= bestDistance) {
            bestDistance = distance;
            bestIndex = (NSInteger)edgeIndex;
        }
    }
    return bestIndex;
}

- (Bounds3)boundsForBlockFromAnchor:(Vec3)anchor current:(Vec3)current {
    Bounds3 bounds = bounds3_empty();
    bounds3_expand(&bounds, anchor);
    bounds3_expand(&bounds, current);
    bounds = normalized_bounds(bounds);
    switch (self.plane) {
        case VmfViewportPlaneXY:
            bounds.min.raw[2] = snap_to_grid(self.orthoCenter.raw[2] - (float)self.gridSize * 2.0f, (float)self.gridSize);
            bounds.max.raw[2] = snap_to_grid(self.orthoCenter.raw[2] + (float)self.gridSize * 2.0f, (float)self.gridSize);
            break;
        case VmfViewportPlaneXZ:
            bounds.min.raw[1] = snap_to_grid(self.orthoCenter.raw[1] - (float)self.gridSize * 2.0f, (float)self.gridSize);
            bounds.max.raw[1] = snap_to_grid(self.orthoCenter.raw[1] + (float)self.gridSize * 2.0f, (float)self.gridSize);
            break;
        case VmfViewportPlaneZY:
            bounds.min.raw[0] = snap_to_grid(self.orthoCenter.raw[0] - (float)self.gridSize * 2.0f, (float)self.gridSize);
            bounds.max.raw[0] = snap_to_grid(self.orthoCenter.raw[0] + (float)self.gridSize * 2.0f, (float)self.gridSize);
            break;
    }
    return bounds;
}

- (Bounds3)translatedBoundsFromOriginal:(Bounds3)original current:(Vec3)current {
    Bounds3 result = original;
    Vec3 delta = vec3_sub(current, self.dragAnchorWorld);
    switch (self.plane) {
        case VmfViewportPlaneXY:
            delta.raw[2] = 0.0f;
            break;
        case VmfViewportPlaneXZ:
            delta.raw[1] = 0.0f;
            break;
        case VmfViewportPlaneZY:
            delta.raw[0] = 0.0f;
            break;
    }
    result.min = vec3_add(result.min, delta);
    result.max = vec3_add(result.max, delta);
    return normalized_bounds(result);
}

- (Bounds3)resizedBoundsFromOriginal:(Bounds3)original current:(Vec3)current {
    Bounds3 result = original;
    float u = plane_u_value(self.plane, current);
    float v = plane_v_value(self.plane, current);
    BOOL affectsMinU = self.activeHandle == ViewportHandleMinUMinV || self.activeHandle == ViewportHandleMinUMaxV || self.activeHandle == ViewportHandleMinUMidV;
    BOOL affectsMaxU = self.activeHandle == ViewportHandleMaxUMinV || self.activeHandle == ViewportHandleMaxUMaxV || self.activeHandle == ViewportHandleMaxUMidV;
    BOOL affectsMinV = self.activeHandle == ViewportHandleMinUMinV || self.activeHandle == ViewportHandleMaxUMinV || self.activeHandle == ViewportHandleMidUMinV;
    BOOL affectsMaxV = self.activeHandle == ViewportHandleMinUMaxV || self.activeHandle == ViewportHandleMaxUMaxV || self.activeHandle == ViewportHandleMidUMaxV;
    switch (self.plane) {
        case VmfViewportPlaneXY:
            if (affectsMinU) {
                result.min.raw[0] = adjusted_dragged_edge(u, original.max.raw[0], (float)self.gridSize, u >= original.max.raw[0]);
            }
            if (affectsMaxU) {
                result.max.raw[0] = adjusted_dragged_edge(u, original.min.raw[0], (float)self.gridSize, u >= original.min.raw[0]);
            }
            if (affectsMinV) {
                result.min.raw[1] = adjusted_dragged_edge(v, original.max.raw[1], (float)self.gridSize, v >= original.max.raw[1]);
            }
            if (affectsMaxV) {
                result.max.raw[1] = adjusted_dragged_edge(v, original.min.raw[1], (float)self.gridSize, v >= original.min.raw[1]);
            }
            break;
        case VmfViewportPlaneXZ:
            if (affectsMinU) {
                result.min.raw[0] = adjusted_dragged_edge(u, original.max.raw[0], (float)self.gridSize, u >= original.max.raw[0]);
            }
            if (affectsMaxU) {
                result.max.raw[0] = adjusted_dragged_edge(u, original.min.raw[0], (float)self.gridSize, u >= original.min.raw[0]);
            }
            if (affectsMinV) {
                result.min.raw[2] = adjusted_dragged_edge(v, original.max.raw[2], (float)self.gridSize, v >= original.max.raw[2]);
            }
            if (affectsMaxV) {
                result.max.raw[2] = adjusted_dragged_edge(v, original.min.raw[2], (float)self.gridSize, v >= original.min.raw[2]);
            }
            break;
        case VmfViewportPlaneZY:
            if (affectsMinU) {
                result.min.raw[1] = adjusted_dragged_edge(u, original.max.raw[1], (float)self.gridSize, u >= original.max.raw[1]);
            }
            if (affectsMaxU) {
                result.max.raw[1] = adjusted_dragged_edge(u, original.min.raw[1], (float)self.gridSize, u >= original.min.raw[1]);
            }
            if (affectsMinV) {
                result.min.raw[2] = adjusted_dragged_edge(v, original.max.raw[2], (float)self.gridSize, v >= original.max.raw[2]);
            }
            if (affectsMaxV) {
                result.max.raw[2] = adjusted_dragged_edge(v, original.min.raw[2], (float)self.gridSize, v >= original.min.raw[2]);
            }
            break;
    }
    return result;
}

- (void)drawEditorOverlay {
    if (self.dimension != VmfViewportDimension2D) {
        return;
    }

    if (self.creationVisible) {
        NSRect previewRect = [self screenRectForBounds:self.creationBounds];
        [[NSColor colorWithCalibratedRed:0.26 green:0.78 blue:0.48 alpha:0.95] setStroke];
        NSBezierPath* previewPath = [NSBezierPath bezierPathWithRect:previewRect];
        CGFloat dashes[2] = { 6.0, 4.0 };
        [previewPath setLineDash:dashes count:2 phase:0.0];
        previewPath.lineWidth = 1.5;
        [previewPath stroke];
    }

    if (self.clipGuideVisible) {
        NSPoint start = [self viewPointForWorldPoint:self.clipGuideStart];
        NSPoint end = [self viewPointForWorldPoint:self.clipGuideEnd];
        NSPoint clipStart = start;
        NSPoint clipEnd = end;
        BOOL hasInteriorSegment = NO;
        BOOL startInside = NO;
        BOOL endInside = NO;
        NSPoint segmentIntersections[4];
        CGFloat segmentIntersectionTs[4];
        NSUInteger segmentIntersectionCount = 0;
        if (self.selectionVisible) {
            NSRect selectionRect = [self screenRectForBounds:self.selectionBounds];
            NSPoint corners[4] = {
                NSMakePoint(NSMinX(selectionRect), NSMinY(selectionRect)),
                NSMakePoint(NSMaxX(selectionRect), NSMinY(selectionRect)),
                NSMakePoint(NSMaxX(selectionRect), NSMaxY(selectionRect)),
                NSMakePoint(NSMinX(selectionRect), NSMaxY(selectionRect)),
            };
            NSPoint lineIntersections[4];
            CGFloat lineIntersectionTs[4];
            NSUInteger lineIntersectionCount = 0;
            for (NSUInteger index = 0; index < 4; ++index) {
                NSPoint a = corners[index];
                NSPoint b = corners[(index + 1) % 4];
                CGFloat lineDx = end.x - start.x;
                CGFloat lineDy = end.y - start.y;
                CGFloat edgeDx = b.x - a.x;
                CGFloat edgeDy = b.y - a.y;
                CGFloat denominator = (lineDx * edgeDy) - (lineDy * edgeDx);
                if (fabs(denominator) < 1e-6) {
                    continue;
                }
                CGFloat startToEdgeX = a.x - start.x;
                CGFloat startToEdgeY = a.y - start.y;
                CGFloat t = ((startToEdgeX * edgeDy) - (startToEdgeY * edgeDx)) / denominator;
                CGFloat u = ((startToEdgeX * lineDy) - (startToEdgeY * lineDx)) / denominator;
                if (u >= 0.0 && u <= 1.0) {
                    NSPoint intersection = NSMakePoint(start.x + lineDx * t, start.y + lineDy * t);
                    BOOL duplicate = NO;
                    for (NSUInteger existingIndex = 0; existingIndex < lineIntersectionCount; ++existingIndex) {
                        if (hypot(lineIntersections[existingIndex].x - intersection.x,
                                  lineIntersections[existingIndex].y - intersection.y) < 0.5) {
                            duplicate = YES;
                            break;
                        }
                    }
                    if (!duplicate && lineIntersectionCount < 4) {
                        lineIntersections[lineIntersectionCount] = intersection;
                        lineIntersectionTs[lineIntersectionCount] = t;
                        lineIntersectionCount += 1;
                    }

                    if (t >= 0.0 && t <= 1.0) {
                        duplicate = NO;
                        for (NSUInteger existingIndex = 0; existingIndex < segmentIntersectionCount; ++existingIndex) {
                            if (hypot(segmentIntersections[existingIndex].x - intersection.x,
                                      segmentIntersections[existingIndex].y - intersection.y) < 0.5) {
                                duplicate = YES;
                                break;
                            }
                        }
                        if (!duplicate && segmentIntersectionCount < 4) {
                            segmentIntersections[segmentIntersectionCount] = intersection;
                            segmentIntersectionTs[segmentIntersectionCount] = t;
                            segmentIntersectionCount += 1;
                        }
                    }
                }
            }
            startInside = NSPointInRect(start, selectionRect);
            endInside = NSPointInRect(end, selectionRect);
            if (lineIntersectionCount >= 2) {
                if (lineIntersectionTs[0] <= lineIntersectionTs[1]) {
                    clipStart = lineIntersections[0];
                    clipEnd = lineIntersections[1];
                } else {
                    clipStart = lineIntersections[1];
                    clipEnd = lineIntersections[0];
                }
                hasInteriorSegment = YES;
            } else if (startInside && endInside) {
                clipStart = start;
                clipEnd = end;
                hasInteriorSegment = YES;
            }

            if (self.clipKeepMode != VmfClipKeepModeBoth && hasInteriorSegment) {
                NSPoint polygon[4] = {
                    corners[0], corners[1], corners[2], corners[3]
                };
                NSPoint clipped[8];
                BOOL deletePositiveHalf = self.clipKeepMode == VmfClipKeepModeA;
                NSUInteger clippedCount = clip_polygon_to_halfplane(polygon,
                                                                    4,
                                                                    clipStart,
                                                                    clipEnd,
                                                                    deletePositiveHalf,
                                                                    clipped,
                                                                    8);
                if (clippedCount >= 3) {
                    [[NSColor colorWithCalibratedRed:0.94 green:0.18 blue:0.18 alpha:0.22] setFill];
                    NSBezierPath* deletePreview = [NSBezierPath bezierPath];
                    [deletePreview moveToPoint:clipped[0]];
                    for (NSUInteger pointIndex = 1; pointIndex < clippedCount; ++pointIndex) {
                        [deletePreview lineToPoint:clipped[pointIndex]];
                    }
                    [deletePreview closePath];
                    [deletePreview fill];
                }
            }
        }
        CGFloat dashes[2] = { 8.0, 4.0 };
        [[NSColor colorWithCalibratedRed:0.34 green:0.78 blue:0.96 alpha:1.0] setStroke];
        if (!hasInteriorSegment) {
            NSBezierPath* clipPath = [NSBezierPath bezierPath];
            [clipPath setLineDash:dashes count:2 phase:0.0];
            clipPath.lineWidth = 2.0;
            [clipPath moveToPoint:start];
            [clipPath lineToPoint:end];
            [clipPath stroke];
        } else {
            if (!startInside && segmentIntersectionCount > 0) {
                NSUInteger nearestIndex = 0;
                CGFloat nearestT = segmentIntersectionTs[0];
                for (NSUInteger index = 1; index < segmentIntersectionCount; ++index) {
                    if (segmentIntersectionTs[index] < nearestT) {
                        nearestT = segmentIntersectionTs[index];
                        nearestIndex = index;
                    }
                }
                NSBezierPath* leadingPath = [NSBezierPath bezierPath];
                [leadingPath setLineDash:dashes count:2 phase:0.0];
                leadingPath.lineWidth = 2.0;
                [leadingPath moveToPoint:start];
                [leadingPath lineToPoint:segmentIntersections[nearestIndex]];
                [leadingPath stroke];
            }
            if (!endInside && segmentIntersectionCount > 0) {
                NSUInteger farthestIndex = 0;
                CGFloat farthestT = segmentIntersectionTs[0];
                for (NSUInteger index = 1; index < segmentIntersectionCount; ++index) {
                    if (segmentIntersectionTs[index] > farthestT) {
                        farthestT = segmentIntersectionTs[index];
                        farthestIndex = index;
                    }
                }
                NSBezierPath* trailingPath = [NSBezierPath bezierPath];
                [trailingPath setLineDash:dashes count:2 phase:0.0];
                trailingPath.lineWidth = 2.0;
                [trailingPath moveToPoint:segmentIntersections[farthestIndex]];
                [trailingPath lineToPoint:end];
                [trailingPath stroke];
            }
        }

        if (hasInteriorSegment) {
            NSColor* interiorColor = self.clipKeepMode == VmfClipKeepModeBoth
                ? [NSColor colorWithCalibratedWhite:1.0 alpha:1.0]
                : [NSColor colorWithCalibratedRed:0.94 green:0.22 blue:0.22 alpha:1.0];
            [interiorColor setStroke];
            NSBezierPath* interiorPath = [NSBezierPath bezierPath];
            [interiorPath setLineDash:dashes count:2 phase:0.0];
            interiorPath.lineWidth = 2.0;
            [interiorPath moveToPoint:clipStart];
            [interiorPath lineToPoint:clipEnd];
            [interiorPath stroke];
        }

        [[NSColor colorWithCalibratedRed:0.34 green:0.78 blue:0.96 alpha:1.0] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(start.x - 4.0, start.y - 4.0, 8.0, 8.0)] fill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(end.x - 4.0, end.y - 4.0, 8.0, 8.0)] fill];
    }

    if (!self.selectionVisible) {
        return;
    }

    NSRect rect = [self screenRectForBounds:self.selectionBounds];
    if (self.editorTool != VmfViewportEditorToolVertex) {
        [[NSColor colorWithCalibratedRed:0.95 green:0.61 blue:0.18 alpha:0.95] setStroke];
        NSBezierPath* path = [NSBezierPath bezierPathWithRect:rect];
        path.lineWidth = 1.5;
        [path stroke];
    }

    if (self.editorTool == VmfViewportEditorToolVertex && self.selectionEdgeCount > 0 && self.selectionEdges) {
        // Draw edges as wireframe - red when invalid, otherwise normal vertex edit colors
        for (size_t edgeIndex = 0; edgeIndex < self.selectionEdgeCount; ++edgeIndex) {
            const VmfSolidEdge* edge = &self.selectionEdges[edgeIndex];
            if (edge->endpointCount < 2) {
                continue;
            }
            NSPoint start = [self viewPointForWorldPoint:edge->start];
            NSPoint end = [self viewPointForWorldPoint:edge->end];
            // Skip degenerate (point-like) projected edges
            if (hypot(end.x - start.x, end.y - start.y) < 0.5) {
                continue;
            }
            BOOL isActiveEdge = edge->sideIndices[0] == self.activeEdgeFirstSideIndex && edge->sideIndices[1] == self.activeEdgeSecondSideIndex;
            NSColor* edgeColor;
            if (self.vertexEditIsInvalid) {
                edgeColor = [NSColor colorWithCalibratedRed:0.95 green:0.22 blue:0.22 alpha:0.92];
            } else if (isActiveEdge) {
                edgeColor = [NSColor colorWithCalibratedRed:0.34 green:0.78 blue:0.96 alpha:1.0];
            } else {
                edgeColor = [NSColor colorWithCalibratedRed:0.86 green:0.73 blue:0.33 alpha:0.85];
            }
            [edgeColor setStroke];
            NSBezierPath* edgePath = [NSBezierPath bezierPath];
            edgePath.lineWidth = isActiveEdge ? 3.0 : 1.5;
            [edgePath moveToPoint:start];
            [edgePath lineToPoint:end];
            [edgePath stroke];
        }
    }

    if (self.editorTool == VmfViewportEditorToolVertex && self.selectionVertexCount > 0 && self.selectionVertices) {
        NSColor* dotColor = self.vertexEditIsInvalid
            ? [NSColor colorWithCalibratedRed:1.0 green:0.35 blue:0.35 alpha:1.0]
            : [NSColor colorWithCalibratedRed:0.98 green:0.82 blue:0.46 alpha:1.0];
        [dotColor setFill];
        for (size_t vertexIndex = 0; vertexIndex < self.selectionVertexCount; ++vertexIndex) {
            // Check if this vertex is one of the active (dragged) vertices - draw slightly larger
            BOOL isActive = NO;
            for (size_t ai = 0; ai < _activeVertexIndexCount; ++ai) {
                if (_activeVertexIndices[ai] == vertexIndex) {
                    isActive = YES;
                    break;
                }
            }
            NSPoint pt = [self viewPointForWorldPoint:self.selectionVertices[vertexIndex]];
            CGFloat r = isActive ? 5.0 : 4.0;
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(pt.x - r, pt.y - r, r * 2.0, r * 2.0)] fill];
        }
    }

    if (self.editorTool != VmfViewportEditorToolVertex && self.selectedFaceEdge != VmfViewportSelectionEdgeNone) {
        [[NSColor colorWithCalibratedRed:0.28 green:0.74 blue:0.93 alpha:1.0] setStroke];
        NSBezierPath* facePath = [NSBezierPath bezierPath];
        facePath.lineWidth = 3.0;
        switch (self.selectedFaceEdge) {
            case VmfViewportSelectionEdgeMinU:
                [facePath moveToPoint:NSMakePoint(NSMinX(rect), NSMinY(rect))];
                [facePath lineToPoint:NSMakePoint(NSMinX(rect), NSMaxY(rect))];
                break;
            case VmfViewportSelectionEdgeMaxU:
                [facePath moveToPoint:NSMakePoint(NSMaxX(rect), NSMinY(rect))];
                [facePath lineToPoint:NSMakePoint(NSMaxX(rect), NSMaxY(rect))];
                break;
            case VmfViewportSelectionEdgeMinV:
                [facePath moveToPoint:NSMakePoint(NSMinX(rect), NSMinY(rect))];
                [facePath lineToPoint:NSMakePoint(NSMaxX(rect), NSMinY(rect))];
                break;
            case VmfViewportSelectionEdgeMaxV:
                [facePath moveToPoint:NSMakePoint(NSMinX(rect), NSMaxY(rect))];
                [facePath lineToPoint:NSMakePoint(NSMaxX(rect), NSMaxY(rect))];
                break;
            default:
                break;
        }
        [facePath stroke];
    }

    if (self.selectionEditable && self.editorTool == VmfViewportEditorToolSelect) {
        [[NSColor colorWithCalibratedRed:0.95 green:0.61 blue:0.18 alpha:1.0] setFill];
        const CGFloat handleSize = 8.0;
        NSRect handles[8] = {
            NSMakeRect(NSMinX(rect) - handleSize * 0.5, NSMinY(rect) - handleSize * 0.5, handleSize, handleSize),
            NSMakeRect(NSMaxX(rect) - handleSize * 0.5, NSMinY(rect) - handleSize * 0.5, handleSize, handleSize),
            NSMakeRect(NSMaxX(rect) - handleSize * 0.5, NSMaxY(rect) - handleSize * 0.5, handleSize, handleSize),
            NSMakeRect(NSMinX(rect) - handleSize * 0.5, NSMaxY(rect) - handleSize * 0.5, handleSize, handleSize),
            NSMakeRect(NSMinX(rect) - handleSize * 0.5, NSMidY(rect) - handleSize * 0.5, handleSize, handleSize),
            NSMakeRect(NSMaxX(rect) - handleSize * 0.5, NSMidY(rect) - handleSize * 0.5, handleSize, handleSize),
            NSMakeRect(NSMidX(rect) - handleSize * 0.5, NSMinY(rect) - handleSize * 0.5, handleSize, handleSize),
            NSMakeRect(NSMidX(rect) - handleSize * 0.5, NSMaxY(rect) - handleSize * 0.5, handleSize, handleSize),
        };
        for (int i = 0; i < 8; ++i) {
            [[NSBezierPath bezierPathWithRect:handles[i]] fill];
        }
    }
}

- (void)lookByDeltaX:(float)deltaX deltaY:(float)deltaY {
    if (self.dimension != VmfViewportDimension3D) {
        return;
    }
    self.yaw -= deltaX * 0.002f;
    self.pitch = fminf(fmaxf(self.pitch - deltaY * 0.002f, -1.45f), 1.45f);
}

- (void)beginFreeLook {
    if (self.dimension != VmfViewportDimension3D || self.freeLookActive) {
        return;
    }
    self.freeLookPosition = [self cameraPosition];
    self.freeLookActive = YES;
    self.lastFrameTime = CACurrentMediaTime();
}

- (void)endFreeLook {
    if (!self.freeLookActive) {
        return;
    }
    self.freeLookActive = NO;
    self.movementMask = 0;
    self.lastFrameTime = 0.0;
    self.target = vec3_add(self.freeLookPosition, vec3_scale([self forwardVector], self.distance));
}

- (void)drawGridInEncoder:(id<MTLRenderCommandEncoder>)encoder aspect:(float)aspect {
    if (self.dimension != VmfViewportDimension2D) {
        return;
    }

    float visibleHeight = self.orthoSize;
    float visibleWidth = visibleHeight * aspect;
    float gridStep = ortho_grid_step(visibleHeight, (float)self.gridSize);
    float majorStep = gridStep * 8.0f;

    Vec3 axisU = plane_right(self.plane);
    Vec3 axisV = plane_up(self.plane);
    float centerU = vec3_dot(self.orthoCenter, axisU);
    float centerV = vec3_dot(self.orthoCenter, axisV);
    Vec3 planeOrigin = vec3_sub(self.orthoCenter,
                                vec3_add(vec3_scale(axisU, centerU),
                                         vec3_scale(axisV, centerV)));
    float minU = centerU - visibleWidth * 0.5f;
    float maxU = centerU + visibleWidth * 0.5f;
    float minV = centerV - visibleHeight * 0.5f;
    float maxV = centerV + visibleHeight * 0.5f;

    AppMetalEditorVertex gridVertices[2048];
    NSUInteger gridVertexCount = 0;
    for (float u = floorf(minU / gridStep) * gridStep; u <= maxU + gridStep; u += gridStep) {
        BOOL isAxis = fabsf(u) < 0.5f * gridStep;
        BOOL isMajor = fmodf(fabsf(u), majorStep) < 0.01f || majorStep - fmodf(fabsf(u), majorStep) < 0.01f;
        Vec3 color = isAxis ? vec3_make(0.84f, 0.34f, 0.34f) : (isMajor ? vec3_make(0.30f, 0.33f, 0.38f) : vec3_make(0.18f, 0.20f, 0.24f));
        Vec3 start = vec3_add(planeOrigin, vec3_add(vec3_scale(axisU, u), vec3_scale(axisV, minV)));
        Vec3 end = vec3_add(planeOrigin, vec3_add(vec3_scale(axisU, u), vec3_scale(axisV, maxV)));
        append_grid_line(gridVertices, 2048, &gridVertexCount, start, end, color);
    }
    for (float v = floorf(minV / gridStep) * gridStep; v <= maxV + gridStep; v += gridStep) {
        BOOL isAxis = fabsf(v) < 0.5f * gridStep;
        BOOL isMajor = fmodf(fabsf(v), majorStep) < 0.01f || majorStep - fmodf(fabsf(v), majorStep) < 0.01f;
        Vec3 color = isAxis ? vec3_make(0.34f, 0.60f, 0.84f) : (isMajor ? vec3_make(0.30f, 0.33f, 0.38f) : vec3_make(0.18f, 0.20f, 0.24f));
        Vec3 start = vec3_add(planeOrigin, vec3_add(vec3_scale(axisU, minU), vec3_scale(axisV, v)));
        Vec3 end = vec3_add(planeOrigin, vec3_add(vec3_scale(axisU, maxU), vec3_scale(axisV, v)));
        append_grid_line(gridVertices, 2048, &gridVertexCount, start, end, color);
    }

    if (gridVertexCount == 0) {
        return;
    }

    id<MTLBuffer> gridBuffer = [self.device newBufferWithBytes:gridVertices
                                                        length:gridVertexCount * sizeof(AppMetalEditorVertex)
                                                       options:MTLResourceStorageModeShared];
    if (!gridBuffer) {
        return;
    }

    Uniforms uniforms = [self uniformsForAspect:aspect];
    [encoder setDepthStencilState:self.disabledDepthState];
    [encoder setVertexBuffer:gridBuffer offset:0 atIndex:0];
    [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeLine vertexStart:0 vertexCount:gridVertexCount];
}

- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size {
    if (self.fullRendererInitialized) {
        char errorBuffer[256] = {0};
        app_metal_resize_drawable(&_fullMetalContext, (uint32_t)MAX(size.width, 1.0), (uint32_t)MAX(size.height, 1.0));
        if (!app_metal_renderer_resize(&_fullMetalRenderer,
                                       (uint32_t)MAX(size.width, 1.0),
                                       (uint32_t)MAX(size.height, 1.0),
                                       errorBuffer,
                                       sizeof(errorBuffer))) {
            NSLog(@"Heavy Metal renderer resize failed: %s", errorBuffer);
        }
    }
    (void)view;
}

- (void)drawInMTKView:(MTKView*)view {
    if (self.dimension == VmfViewportDimension3D &&
        self.renderMode == VmfViewportRenderModeShaded &&
        self.fullRendererInitialized &&
        self.sceneWorld != NULL &&
        self.importedSceneData.objectCount > 0u) {
        char errorBuffer[512] = {0};
        Vec3 eye = [self cameraPosition];
        Vec3 target = [self cameraTarget];
        Vec3 forward = vec3_sub(target, eye);
        float heavyYaw = self.yaw;
        float heavyPitch = self.pitch;
        uint32_t frameSlot = self.fullRendererFrameIndex % 3u;

        if (vec3_length(forward) > 0.0001f) {
            forward = vec3_normalize(forward);
            heavyYaw = atan2f(forward.raw[0], -forward.raw[1]);
            heavyPitch = asinf(fmaxf(fminf(forward.raw[2], 1.0f), -1.0f));
        }

        nova_scene_world_sync_to_ui(self.sceneWorld,
                                    self.importedSceneData.objectCount > 0u ? 1u : 0u,
                                    &_fullRendererUiState);

        if (!app_metal_renderer_reset_frame_resources(&_fullMetalRenderer, frameSlot, errorBuffer, sizeof(errorBuffer)) ||
            !app_metal_renderer_sync_editor_state(&_fullMetalRenderer,
                                                  &_fullRendererUiState,
                                                  self.sceneWorld,
                                                  &_importedSceneData,
                                                  (AppMetalMathVec3){ eye.raw[0], eye.raw[1], eye.raw[2] },
                                                  heavyYaw,
                                                  heavyPitch,
                                                  self.fullRendererFrameIndex,
                                                  errorBuffer,
                                                  sizeof(errorBuffer)) ||
            !app_metal_renderer_draw_frame(&_fullMetalRenderer, errorBuffer, sizeof(errorBuffer))) {
            NSLog(@"Heavy Metal viewport draw failed: %s", errorBuffer);
        } else {
            self.fullRendererFrameIndex += 1u;
            return;
        }
    }

    id<CAMetalDrawable> drawable = view.currentDrawable;
    MTLRenderPassDescriptor* passDescriptor = view.currentRenderPassDescriptor;
    if (!drawable || !passDescriptor) {
        return;
    }

    CFTimeInterval now = CACurrentMediaTime();
    if (self.lastFrameTime == 0.0) {
        self.lastFrameTime = now;
    }
    [self updateFreeLookWithDeltaTime:(now - self.lastFrameTime)];
    self.lastFrameTime = now;

    float aspect = view.drawableSize.height > 0.0 ? (float)(view.drawableSize.width / view.drawableSize.height) : 1.0f;
    Uniforms uniforms = [self uniformsForAspect:aspect];

    AppMetalEditorVertex gridVertices[2048];
    NSUInteger gridVertexCount = 0;
    if (self.dimension == VmfViewportDimension2D) {
        float visibleHeight = self.orthoSize;
        float visibleWidth = visibleHeight * aspect;
        float gridStep = ortho_grid_step(visibleHeight, (float)self.gridSize);
        float majorStep = gridStep * 8.0f;
        Vec3 axisU = plane_right(self.plane);
        Vec3 axisV = plane_up(self.plane);
        float centerU = vec3_dot(self.orthoCenter, axisU);
        float centerV = vec3_dot(self.orthoCenter, axisV);
        Vec3 planeOrigin = vec3_sub(self.orthoCenter,
                                    vec3_add(vec3_scale(axisU, centerU),
                                             vec3_scale(axisV, centerV)));
        float minU = centerU - visibleWidth * 0.5f;
        float maxU = centerU + visibleWidth * 0.5f;
        float minV = centerV - visibleHeight * 0.5f;
        float maxV = centerV + visibleHeight * 0.5f;

        for (float u = floorf(minU / gridStep) * gridStep; u <= maxU + gridStep; u += gridStep) {
            BOOL isAxis = fabsf(u) < 0.5f * gridStep;
            BOOL isMajor = fmodf(fabsf(u), majorStep) < 0.01f || majorStep - fmodf(fabsf(u), majorStep) < 0.01f;
            Vec3 color = isAxis ? vec3_make(0.84f, 0.34f, 0.34f) : (isMajor ? vec3_make(0.30f, 0.33f, 0.38f) : vec3_make(0.18f, 0.20f, 0.24f));
            Vec3 start = vec3_add(planeOrigin, vec3_add(vec3_scale(axisU, u), vec3_scale(axisV, minV)));
            Vec3 end = vec3_add(planeOrigin, vec3_add(vec3_scale(axisU, u), vec3_scale(axisV, maxV)));
            append_grid_line(gridVertices, 2048, &gridVertexCount, start, end, color);
        }
        for (float v = floorf(minV / gridStep) * gridStep; v <= maxV + gridStep; v += gridStep) {
            BOOL isAxis = fabsf(v) < 0.5f * gridStep;
            BOOL isMajor = fmodf(fabsf(v), majorStep) < 0.01f || majorStep - fmodf(fabsf(v), majorStep) < 0.01f;
            Vec3 color = isAxis ? vec3_make(0.34f, 0.60f, 0.84f) : (isMajor ? vec3_make(0.30f, 0.33f, 0.38f) : vec3_make(0.18f, 0.20f, 0.24f));
            Vec3 start = vec3_add(planeOrigin, vec3_add(vec3_scale(axisU, minU), vec3_scale(axisV, v)));
            Vec3 end = vec3_add(planeOrigin, vec3_add(vec3_scale(axisU, maxU), vec3_scale(axisV, v)));
            append_grid_line(gridVertices, 2048, &gridVertexCount, start, end, color);
        }
    }

    AppMetalEditorViewportDrawInfo drawInfo = {
        .renderPassDescriptor = (__bridge void*)passDescriptor,
        .drawable = (__bridge void*)drawable,
        .uniforms = &uniforms,
        .gridVertices = gridVertices,
        .gridVertexCount = gridVertexCount,
        .selectedFaceBuffer = (__bridge void*)self.selectedFaceBuffer,
        .selectedFaceVertexCount = self.selectedFaceVertexCount,
        .highlightedFaceBuffer = (__bridge void*)self.highlightedFaceBuffer,
        .highlightedFaceVertexCount = self.highlightedFaceVertexCount,
        .vertexEditPreviewBuffer = (__bridge void*)self.vertexEditPreviewBuffer,
        .vertexEditPreviewVertexCount = self.vertexEditPreviewVertexCount,
        .dimension3D = self.dimension == VmfViewportDimension3D ? 1u : 0u,
        .shaded = self.renderMode == VmfViewportRenderModeShaded ? 1u : 0u,
        .encodeOverlay = viewport_encode_overlay,
        .overlayUserData = (__bridge void*)self,
    };
    char errorBuffer[512] = {0};
    if (!app_metal_editor_viewport_renderer_draw(&_metalRenderer, &drawInfo, errorBuffer, sizeof(errorBuffer))) {
        NSLog(@"Viewport renderer draw failed: %s", errorBuffer);
    }
}

- (BOOL)handleViewportKeyDown:(NSEvent*)event {
    NSString* key = event.charactersIgnoringModifiers.lowercaseString;
    if (self.freeLookActive) {
        if ([key isEqualToString:@"w"]) {
            self.movementMask |= CameraMovementForward;
            return YES;
        }
        if ([key isEqualToString:@"s"]) {
            self.movementMask |= CameraMovementBackward;
            return YES;
        }
        if ([key isEqualToString:@"a"]) {
            self.movementMask |= CameraMovementLeft;
            return YES;
        }
        if ([key isEqualToString:@"d"]) {
            self.movementMask |= CameraMovementRight;
            return YES;
        }
    }

    if (self.delegate) {
        [self.delegate viewport:self handleKeyDown:event];
        return YES;
    }
    return NO;
}

- (BOOL)handleViewportKeyUp:(NSEvent*)event {
    NSString* key = event.charactersIgnoringModifiers.lowercaseString;
    if ([key isEqualToString:@"w"]) {
        self.movementMask &= ~CameraMovementForward;
        return YES;
    }
    if ([key isEqualToString:@"s"]) {
        self.movementMask &= ~CameraMovementBackward;
        return YES;
    }
    if ([key isEqualToString:@"a"]) {
        self.movementMask &= ~CameraMovementLeft;
        return YES;
    }
    if ([key isEqualToString:@"d"]) {
        self.movementMask &= ~CameraMovementRight;
        return YES;
    }

    if (self.delegate) {
        [self.delegate viewport:self handleKeyUp:event];
        return YES;
    }
    return NO;
}

- (void)handleViewportMouseDownAtPoint:(NSPoint)point {
    [self.delegate viewportDidBecomeActive:self];
    if (self.dimension == VmfViewportDimension3D && [self gizmoConsumesPrimaryMouse]) {
        self.dragMode = ViewportDragModeNone;
        self.pendingClickSelection = NO;
        return;
    }
    self.dragStartPoint = point;
    self.pendingClickSelection = self.dimension == VmfViewportDimension3D;
    if (self.dimension != VmfViewportDimension2D) {
        self.dragMode = ViewportDragModePan;
        return;
    }

    Vec3 worldPoint = [self snappedWorldPointForViewPoint:point];
    self.dragAnchorWorld = worldPoint;
    self.dragOriginalBounds = self.selectionBounds;
    self.activeHandle = ViewportHandleNone;
    _activeVertexIndexCount = 0;

    if (([NSApp currentEvent].modifierFlags & NSEventModifierFlagShift) != 0) {
        VmfViewportSelectionEdge edge = [self selectionEdgeAtPoint:point];
        if (edge != VmfViewportSelectionEdgeNone && self.delegate) {
            [self.delegate viewport:self requestFaceSelectionOnEdge:edge];
            self.dragMode = ViewportDragModeNone;
            return;
        }
    }

    if (([NSApp currentEvent].modifierFlags & NSEventModifierFlagOption) != 0) {
        self.dragMode = ViewportDragModePan;
        return;
    }

    NSInteger vertexIndex = [self vertexIndexAtPoint:point];
    if (vertexIndex >= 0 && self.editorTool == VmfViewportEditorToolVertex) {
        NSUInteger foundCount = [self vertexIndicesAtPoint:point outIndices:_activeVertexIndices maxCount:VMF_MAX_SOLID_VERTICES];
        _activeVertexIndexCount = foundCount > 0 ? foundCount : 1;
        if (foundCount == 0) {
            _activeVertexIndices[0] = (size_t)vertexIndex;
        }
        // Use the closest vertex as the anchor for world point computation
        self.dragAnchorWorld = self.selectionVertices[(size_t)vertexIndex];
        self.dragMode = ViewportDragModeMoveVertex;
        self.vertexEditIsInvalid = NO;
        return;
    }

    NSInteger edgeIndex = [self edgeIndexAtPoint:point];
    if (edgeIndex >= 0 && self.editorTool == VmfViewportEditorToolVertex) {
        self.activeEdgeFirstSideIndex = self.selectionEdges[(size_t)edgeIndex].sideIndices[0];
        self.activeEdgeSecondSideIndex = self.selectionEdges[(size_t)edgeIndex].sideIndices[1];
        self.dragMode = ViewportDragModeMoveEdge;
        return;
    }

    if (self.editorTool == VmfViewportEditorToolClip) {
        self.dragMode = ViewportDragModeDrawClipLine;
        self.clipGuideStart = worldPoint;
        self.clipGuideEnd = worldPoint;
        self.clipGuideVisible = YES;
        [self.overlayView setNeedsDisplay:YES];
        return;
    }

    if (self.editorTool == VmfViewportEditorToolBlock ||
        self.editorTool == VmfViewportEditorToolCylinder ||
        self.editorTool == VmfViewportEditorToolArch ||
        self.editorTool == VmfViewportEditorToolRamp ||
        self.editorTool == VmfViewportEditorToolStairs) {
        self.dragMode = ViewportDragModeCreateBlock;
        [self setCreationBounds:[self boundsForBlockFromAnchor:worldPoint current:worldPoint] visible:YES];
        return;
    }

    if (self.editorTool == VmfViewportEditorToolSelect) {
        ViewportHandle handle = [self handleAtPoint:point];
        self.activeHandle = handle;
        if (handle == ViewportHandleBody) {
            self.dragMode = ViewportDragModeMoveSelection;
            return;
        }
        if (handle != ViewportHandleNone) {
            self.dragMode = ViewportDragModeResizeSelection;
            return;
        }
    }

    self.dragMode = ViewportDragModePan;
    self.pendingClickSelection = YES;
}

- (void)handleViewportMouseUpAtPoint:(NSPoint)point {
    if (self.dimension != VmfViewportDimension2D) {
        if ([self gizmoConsumesPrimaryMouse]) {
            self.dragMode = ViewportDragModeNone;
            self.pendingClickSelection = NO;
            return;
        }
        if (self.pendingClickSelection && !self.freeLookActive && self.delegate) {
            [self.delegate viewport:self requestSelectionRayOrigin:[self cameraPosition] direction:[self rayDirectionForViewPoint:point]];
        }
        self.dragMode = ViewportDragModeNone;
        self.pendingClickSelection = NO;
        return;
    }

    Vec3 worldPoint = [self snappedWorldPointForViewPoint:point];
    if (self.dragMode == ViewportDragModeCreateBlock && self.creationVisible) {
        Bounds3 bounds = [self boundsForBlockFromAnchor:self.dragAnchorWorld current:worldPoint];
        if (self.editorTool == VmfViewportEditorToolCylinder) {
            [self.delegate viewport:self createCylinderWithBounds:bounds];
        } else if (self.editorTool == VmfViewportEditorToolArch) {
            [self.delegate viewport:self createArchWithBounds:bounds];
        } else if (self.editorTool == VmfViewportEditorToolRamp) {
            [self.delegate viewport:self createRampWithBounds:bounds];
        } else if (self.editorTool == VmfViewportEditorToolStairs) {
            [self.delegate viewport:self createStairsWithBounds:bounds];
        } else {
            [self.delegate viewport:self createBlockWithBounds:bounds];
        }
        [self setCreationBounds:bounds visible:NO];
    } else if (self.pendingClickSelection) {
        if (self.delegate) {
            [self.delegate viewport:self requestSelectionAtPoint:worldPoint];
        }
    } else if (self.dragMode == ViewportDragModeMoveSelection && self.selectionVisible) {
        [self.delegate viewport:self updateSelectionBounds:[self translatedBoundsFromOriginal:self.dragOriginalBounds current:worldPoint] commit:YES transform:VmfViewportSelectionTransformMove];
    } else if (self.dragMode == ViewportDragModeResizeSelection && self.selectionVisible) {
        [self.delegate viewport:self updateSelectionBounds:[self resizedBoundsFromOriginal:self.dragOriginalBounds current:worldPoint] commit:YES transform:VmfViewportSelectionTransformResize];
    } else if (self.dragMode == ViewportDragModeMoveVertex && _activeVertexIndexCount > 0 && self.selectionVertices) {
        Vec3 newPositions[VMF_MAX_SOLID_VERTICES];
        for (size_t i = 0; i < _activeVertexIndexCount; ++i) {
            size_t idx = _activeVertexIndices[i];
            newPositions[i] = (idx < self.selectionVertexCount)
                ? [self snappedWorldPointForViewPoint:point preservingHiddenAxisFrom:self.selectionVertices[idx]]
                : worldPoint;
        }
        [self.delegate viewport:self updateSelectionVerticesAtIndices:_activeVertexIndices positions:newPositions count:_activeVertexIndexCount commit:YES];
    } else if (self.dragMode == ViewportDragModeMoveEdge && self.activeEdgeFirstSideIndex != SIZE_MAX && self.activeEdgeSecondSideIndex != SIZE_MAX) {
        [self.delegate viewport:self
            updateSelectionEdgeFirstSideIndex:self.activeEdgeFirstSideIndex
                               secondSideIndex:self.activeEdgeSecondSideIndex
                                         offset:vec3_sub(worldPoint, self.dragAnchorWorld)
                                         commit:YES];
    } else if (self.dragMode == ViewportDragModeDrawClipLine) {
        self.clipGuideEnd = worldPoint;
        self.clipGuideVisible = YES;
        [self.overlayView setNeedsDisplay:YES];
    }

    self.dragMode = ViewportDragModeNone;
    self.activeHandle = ViewportHandleNone;
    _activeVertexIndexCount = 0;
    self.activeEdgeFirstSideIndex = SIZE_MAX;
    self.activeEdgeSecondSideIndex = SIZE_MAX;
    self.pendingClickSelection = NO;
}

- (void)handleViewportPrimaryDragWithDelta:(NSPoint)delta alternate:(BOOL)alternate {
    if (self.dimension == VmfViewportDimension3D) {
        if ([self gizmoConsumesPrimaryMouse]) {
            self.pendingClickSelection = NO;
            return;
        }
        CGFloat dragDistance = hypot(delta.x, delta.y);
        if (dragDistance > 0.5) {
            self.pendingClickSelection = NO;
        }
        [self panOrOrbitByDeltaX:(float)delta.x deltaY:(float)delta.y];
        return;
    }

    NSPoint point = [self.metalView convertPoint:[NSApp currentEvent].locationInWindow fromView:nil];
    Vec3 worldPoint = [self snappedWorldPointForViewPoint:point];
    if (self.pendingClickSelection) {
        CGFloat dragDistance = hypot(point.x - self.dragStartPoint.x, point.y - self.dragStartPoint.y);
        if (dragDistance > 3.0) {
            self.pendingClickSelection = NO;
        }
    }
    if (alternate || self.dragMode == ViewportDragModePan) {
        [self panOrOrbitByDeltaX:(float)delta.x deltaY:(float)delta.y];
        return;
    }
    if (self.dragMode == ViewportDragModeCreateBlock) {
        [self setCreationBounds:[self boundsForBlockFromAnchor:self.dragAnchorWorld current:worldPoint] visible:YES];
        return;
    }
    if (self.dragMode == ViewportDragModeDrawClipLine) {
        self.clipGuideEnd = worldPoint;
        self.clipGuideVisible = YES;
        [self.overlayView setNeedsDisplay:YES];
        return;
    }
    if (self.dragMode == ViewportDragModeMoveVertex && _activeVertexIndexCount > 0 && self.selectionVertices) {
        Vec3 newPositions[VMF_MAX_SOLID_VERTICES];
        for (size_t i = 0; i < _activeVertexIndexCount; ++i) {
            size_t idx = _activeVertexIndices[i];
            newPositions[i] = (idx < self.selectionVertexCount)
                ? [self snappedWorldPointForViewPoint:point preservingHiddenAxisFrom:self.selectionVertices[idx]]
                : worldPoint;
        }
        [self.delegate viewport:self updateSelectionVerticesAtIndices:_activeVertexIndices positions:newPositions count:_activeVertexIndexCount commit:NO];
        return;
    }
    if (self.dragMode == ViewportDragModeMoveEdge && self.activeEdgeFirstSideIndex != SIZE_MAX && self.activeEdgeSecondSideIndex != SIZE_MAX) {
        Vec3 offset = vec3_sub(worldPoint, self.dragAnchorWorld);
        [self.delegate viewport:self
            updateSelectionEdgeFirstSideIndex:self.activeEdgeFirstSideIndex
                               secondSideIndex:self.activeEdgeSecondSideIndex
                                         offset:offset
                                         commit:NO];
        self.dragAnchorWorld = worldPoint;
        return;
    }
    if (self.dragMode == ViewportDragModeMoveSelection && self.selectionVisible) {
        [self.delegate viewport:self updateSelectionBounds:[self translatedBoundsFromOriginal:self.dragOriginalBounds current:worldPoint] commit:NO transform:VmfViewportSelectionTransformMove];
        return;
    }
    if (self.dragMode == ViewportDragModeResizeSelection && self.selectionVisible) {
        [self.delegate viewport:self updateSelectionBounds:[self resizedBoundsFromOriginal:self.dragOriginalBounds current:worldPoint] commit:NO transform:VmfViewportSelectionTransformResize];
    }
}

- (BOOL)handleViewportSecondaryMouseDown {
    if (self.dimension != VmfViewportDimension3D) {
        return NO;
    }
    [self beginFreeLook];
    return YES;
}

- (void)handleViewportSecondaryDragWithDelta:(NSPoint)delta {
    if (self.dimension == VmfViewportDimension3D) {
        [self lookByDeltaX:(float)delta.x deltaY:(float)delta.y];
    }
}

- (void)handleViewportSecondaryMouseUp {
    [self endFreeLook];
}

- (void)handleViewportScrollDelta:(CGFloat)deltaY {
    [self zoomByDelta:(float)(-deltaY * 0.1f)];
}

- (void)handleViewportDroppedPath:(NSString*)path {
    if (self.delegate) {
        [self.delegate viewportDidRequestOpenDroppedPath:path];
    }
}

- (void)handleViewportMouseHoverAtPoint:(NSPoint)point {
    if (self.dimension != VmfViewportDimension3D) {
        return;
    }
    if (!self.delegate) {
        return;
    }
    Vec3 origin = [self cameraPosition];
    Vec3 direction = [self rayDirectionForViewPoint:point];
    [self.delegate viewport:self requestHoverRayOrigin:origin direction:direction];
}

- (void)handleViewportSecondaryClickAtPoint:(NSPoint)point modifierFlags:(NSEventModifierFlags)flags {
    if (self.dimension != VmfViewportDimension3D) {
        return;
    }
    if (!self.delegate) {
        return;
    }
    Vec3 origin = [self cameraPosition];
    Vec3 direction = [self rayDirectionForViewPoint:point];
    // Alt+right-click  = eyedropper sample
    // Cmd+right-click  = paint material + world-align UVs (contiguous)
    // plain right-click = paint material only, UV axes untouched
    if (flags & NSEventModifierFlagOption) {
        [self.delegate viewport:self requestSampleRayOrigin:origin direction:direction];
    } else if (flags & NSEventModifierFlagCommand) {
        [self.delegate viewport:self requestPaintAlignRayOrigin:origin direction:direction];
    } else {
        [self.delegate viewport:self requestPaintRayOrigin:origin direction:direction];
    }
}

@end
