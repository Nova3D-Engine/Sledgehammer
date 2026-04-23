#import "viewer_app.h"

#include <fcntl.h>
#include <float.h>

#import <CoreText/CoreText.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "nova_scene_ecs.h"

#import "file_index.h"
#import "viewport.h"
#import "vmf_editor.h"
#import "vmf_geometry.h"
#import "vmf_parser.h"

@interface StyledSplitView : NSSplitView

@end

@implementation StyledSplitView

- (CGFloat)dividerThickness {
    return 10.0;
}

- (void)drawDividerInRect:(NSRect)rect {
    [[NSColor colorWithCalibratedWhite:0.09 alpha:1.0] setFill];
    NSRectFill(rect);

    NSRect accentRect = rect;
    if (self.isVertical) {
        accentRect.origin.x += floor((rect.size.width - 2.0) * 0.5);
        accentRect.size.width = 2.0;
    } else {
        accentRect.origin.y += floor((rect.size.height - 2.0) * 0.5);
        accentRect.size.height = 2.0;
    }
    [[NSColor colorWithCalibratedRed:0.28 green:0.31 blue:0.36 alpha:1.0] setFill];
    NSRectFill(accentRect);
}

@end

@interface SceneHistoryEntry : NSObject {
@public
    VmfScene scene;
    NSInteger revision;
    NSString* stateLabel;
    NSArray* prefabState;
    BOOL hasSelection;
    size_t selectedEntityIndex;
    size_t selectedSolidIndex;
    BOOL hasFaceSelection;
    size_t selectedSideIndex;
}

@end

@implementation SceneHistoryEntry

- (void)dealloc {
    vmf_scene_free(&scene);
}

@end

@interface ProceduralShapePrefab : NSObject <NSCopying>

@property(nonatomic, assign) VmfViewportEditorTool tool;
@property(nonatomic, assign) size_t entityIndex;
@property(nonatomic, assign) size_t startSolidIndex;
@property(nonatomic, assign) size_t solidCount;
@property(nonatomic, assign) Bounds3 bounds;
@property(nonatomic, assign) VmfBrushAxis upAxis;
@property(nonatomic, assign) VmfBrushAxis runAxis;
@property(nonatomic, assign) NSInteger primaryValue;
@property(nonatomic, assign) CGFloat secondaryValue;
@property(nonatomic, copy) NSString* historyLabel;

@end

@implementation ProceduralShapePrefab

- (id)copyWithZone:(NSZone*)zone {
    ProceduralShapePrefab* copy = [[[self class] allocWithZone:zone] init];
    copy.tool = self.tool;
    copy.entityIndex = self.entityIndex;
    copy.startSolidIndex = self.startSolidIndex;
    copy.solidCount = self.solidCount;
    copy.bounds = self.bounds;
    copy.upAxis = self.upAxis;
    copy.runAxis = self.runAxis;
    copy.primaryValue = self.primaryValue;
    copy.secondaryValue = self.secondaryValue;
    copy.historyLabel = [self.historyLabel copy];
    return copy;
}

@end

typedef NS_ENUM(NSUInteger, ViewerClipMode) {
    ViewerClipModeBoth = 0,
    ViewerClipModeA = 1,
    ViewerClipModeB = 2,
};

static NSString* const kAppDisplayName = @"Sledgehammer";

static NSString* light_type_label(int lightType) {
    switch (lightType) {
        case UI_LIGHT_SPOT:
            return @"Spot";
        case UI_LIGHT_POINT:
        default:
            return @"Point";
    }
}

static BOOL bounds_equal(Bounds3 a, Bounds3 b) {
    const float epsilon = 0.01f;
    for (int axis = 0; axis < 3; ++axis) {
        if (fabsf(a.min.raw[axis] - b.min.raw[axis]) > epsilon || fabsf(a.max.raw[axis] - b.max.raw[axis]) > epsilon) {
            return NO;
        }
    }
    return YES;
}

static float entity_pick_radius(const VmfEntity* entity) {
    if (entity == NULL) {
        return 16.0f;
    }
    if (entity->kind == VmfEntityKindLight) {
        return fmaxf(24.0f, fminf(entity->range * 0.1f, 64.0f));
    }
    return 16.0f;
}

static NSString* clip_mode_label(ViewerClipMode mode) {
    switch (mode) {
        case ViewerClipModeA:
            return @"A";
        case ViewerClipModeB:
            return @"B";
        case ViewerClipModeBoth:
        default:
            return @"BOTH";
    }
}

@interface ViewerAppDelegate () <VmfViewportDelegate, NSMenuDelegate, NSMenuItemValidation, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate>

@property(nonatomic, strong) NSWindow* window;
@property(nonatomic, strong) NSView* rootView;
@property(nonatomic, strong) StyledSplitView* verticalSplitView;
@property(nonatomic, strong) StyledSplitView* topSplitView;
@property(nonatomic, strong) StyledSplitView* bottomSplitView;
@property(nonatomic, strong) VmfViewport* topViewport;
@property(nonatomic, strong) VmfViewport* perspectiveViewport;
@property(nonatomic, strong) VmfViewport* frontViewport;
@property(nonatomic, strong) VmfViewport* sideViewport;
@property(nonatomic, strong) NSArray<VmfViewport*>* viewports;
@property(nonatomic, weak) VmfViewport* activeViewport;
@property(nonatomic, strong) NSVisualEffectView* emptyStateView;
@property(nonatomic, strong) NSTextField* emptyStateSubtitle;
@property(nonatomic, strong) NSVisualEffectView* toolRail;
@property(nonatomic, strong) NSStackView* toolRailStack;
@property(nonatomic, strong) NSVisualEffectView* controlBar;
@property(nonatomic, strong) NSStackView* controlStack;
@property(nonatomic, strong) NSVisualEffectView* inspectorPanel;
@property(nonatomic, strong) NSStackView* inspectorStack;
@property(nonatomic, strong) NSTextField* inspectorTitleLabel;
@property(nonatomic, strong) NSTextField* inspectorSubtitleLabel;
@property(nonatomic, strong) NSView* prefabInspectorView;
@property(nonatomic, strong) NSView* lightInspectorView;
@property(nonatomic, strong) NSView* faceTextureInspectorView;
@property(nonatomic, strong) NSView* genericInspectorView;
@property(nonatomic, strong) NSTextField* genericInspectorDetailsLabel;
@property(nonatomic, strong) NSTextField* faceTextureMaterialLabel;
@property(nonatomic, strong) NSTextField* faceTextureUScaleField;
@property(nonatomic, strong) NSTextField* faceTextureVScaleField;
@property(nonatomic, strong) NSTextField* faceTextureUOffsetField;
@property(nonatomic, strong) NSTextField* faceTextureVOffsetField;
@property(nonatomic, strong) NSTextField* faceTextureRotationField;
@property(nonatomic, strong) NSTextField* lightNameLabel;
@property(nonatomic, strong) NSPopUpButton* lightTypePopUp;
@property(nonatomic, strong) NSColorWell* lightColorWell;
@property(nonatomic, strong) NSTextField* lightPositionLabel;
@property(nonatomic, strong) NSTextField* lightIntensityValueLabel;
@property(nonatomic, strong) NSSlider* lightIntensitySlider;
@property(nonatomic, strong) NSTextField* lightRangeValueLabel;
@property(nonatomic, strong) NSSlider* lightRangeSlider;
@property(nonatomic, strong) NSStackView* lightSpotSettingsView;
@property(nonatomic, strong) NSTextField* lightSpotInnerValueLabel;
@property(nonatomic, strong) NSSlider* lightSpotInnerSlider;
@property(nonatomic, strong) NSTextField* lightSpotOuterValueLabel;
@property(nonatomic, strong) NSSlider* lightSpotOuterSlider;
@property(nonatomic, strong) NSButton* lightEnabledButton;
@property(nonatomic, strong) NSButton* lightCastShadowsButton;
@property(nonatomic, strong) NSLayoutConstraint* controlBarHeightConstraint;
@property(nonatomic, strong) NSSegmentedControl* renderControl;
@property(nonatomic, strong) NSPopUpButton* materialPopUp;
@property(nonatomic, strong) NSPopUpButton* gridPopUp;
@property(nonatomic, strong) NSButton* createMapButton;
@property(nonatomic, strong) NSButton* openButton;
@property(nonatomic, strong) NSButton* saveButton;
@property(nonatomic, strong) NSButton* undoButton;
@property(nonatomic, strong) NSButton* redoButton;
@property(nonatomic, strong) NSButton* duplicateButton;
@property(nonatomic, strong) NSButton* deleteButton;
@property(nonatomic, strong) NSButton* applyMaterialButton;
@property(nonatomic, strong) NSButton* textureModeButton;
@property(nonatomic, strong) NSButton* textureLockButton;
@property(nonatomic, strong) NSButton* ignoreGroupsButton;
@property(nonatomic, strong) NSButton* browseMaterialButton;
@property(nonatomic, strong) NSButton* selectToolButton;
@property(nonatomic, strong) NSButton* vertexToolButton;
@property(nonatomic, strong) NSButton* blockToolButton;
@property(nonatomic, strong) NSButton* cylinderToolButton;
@property(nonatomic, strong) NSButton* rampToolButton;
@property(nonatomic, strong) NSButton* stairsToolButton;
@property(nonatomic, strong) NSButton* archToolButton;
@property(nonatomic, strong) NSButton* clipToolButton;
@property(nonatomic, strong) NSTextField* renderLabel;
@property(nonatomic, strong) NSTextField* gridLabel;
@property(nonatomic, strong) NSTextField* materialLabel;
@property(nonatomic, assign) BOOL toolbarCompact;
@property(nonatomic, assign) BOOL toolbarUltraCompact;
@property(nonatomic, assign) BOOL textureLockEnabled;
@property(nonatomic, strong) NSMenu* editMenu;
@property(nonatomic, strong) NSMenu* historyMenu;
@property(nonatomic, strong) NSMenuItem* undoMenuItem;
@property(nonatomic, strong) NSMenuItem* redoMenuItem;
@property(nonatomic, copy) NSString* startupPath;
@property(nonatomic, assign) VmfScene scene;
@property(nonatomic, assign) BOOL hasDocument;
@property(nonatomic, assign) BOOL documentDirty;
@property(nonatomic, assign) BOOL hasSelection;
@property(nonatomic, assign) size_t selectedEntityIndex;
@property(nonatomic, assign) size_t selectedSolidIndex;
@property(nonatomic, assign) BOOL hasFaceSelection;
@property(nonatomic, assign) size_t selectedSideIndex;
@property(nonatomic, assign) VmfViewportEditorTool editorTool;
@property(nonatomic, assign) FileIndex fileIndex;
@property(nonatomic, assign) ViewerMesh mesh;
@property(nonatomic, assign) NovaSceneWorld sceneWorld;
@property(nonatomic, copy) NSString* currentPath;
@property(nonatomic, copy) NSString* brushMaterialName;
@property(nonatomic, strong) NSPanel* materialBrowserPanel;
@property(nonatomic, strong) NSTableView* materialTableView;
@property(nonatomic, strong) NSSearchField* materialSearchField;
@property(nonatomic, strong) NSMutableArray<NSString*>* allMaterials;
@property(nonatomic, strong) NSMutableArray<NSString*>* filteredMaterials;
@property(nonatomic, strong) NSTextField* shapePrimaryLabel;
@property(nonatomic, strong) NSTextField* shapePrimaryValueLabel;
@property(nonatomic, strong) NSStepper* shapePrimaryStepper;
@property(nonatomic, strong) NSTextField* shapeSecondaryLabel;
@property(nonatomic, strong) NSTextField* shapeSecondaryValueLabel;
@property(nonatomic, strong) NSSlider* shapeSecondarySlider;
@property(nonatomic, strong) NSButton* shapeCollapseButton;
@property(nonatomic, strong) NSMutableArray<ProceduralShapePrefab*>* currentPrefabs;
@property(nonatomic, strong) ProceduralShapePrefab* editingPrefab;
@property(nonatomic, strong) SceneHistoryEntry* activeShapeSessionEntry;
@property(nonatomic, assign) VmfViewportEditorTool activeShapeSessionTool;
@property(nonatomic, assign) Bounds3 activeShapeSessionBounds;
@property(nonatomic, assign) VmfBrushAxis activeShapeSessionUpAxis;
@property(nonatomic, assign) VmfBrushAxis activeShapeSessionRunAxis;
@property(nonatomic, assign) NSInteger activeShapePrimaryValue;
@property(nonatomic, assign) CGFloat activeShapeSecondaryValue;
@property(nonatomic, copy) NSString* activeShapeHistoryLabel;
// Face hover state (3D viewport)
@property(nonatomic, assign) BOOL hasHoveredFace;
@property(nonatomic, assign) size_t hoveredEntityIndex;
@property(nonatomic, assign) size_t hoveredSolidIndex;
@property(nonatomic, assign) size_t hoveredSideIndex;
@property(nonatomic, copy) NSString* materialsDirectory;
@property(nonatomic, assign) CGFloat gridSize;
@property(nonatomic, assign) NSInteger currentRevision;
@property(nonatomic, assign) NSInteger savedRevision;
@property(nonatomic, assign) NSInteger nextRevision;
@property(nonatomic, assign) NSInteger pendingRevision;
@property(nonatomic, copy) NSString* currentHistoryLabel;
@property(nonatomic, copy) NSString* pendingHistoryActionLabel;
@property(nonatomic, strong) NSMutableArray<SceneHistoryEntry*>* undoStack;
@property(nonatomic, strong) NSMutableArray<SceneHistoryEntry*>* redoStack;
@property(nonatomic, strong) SceneHistoryEntry* pendingHistoryEntry;
@property(nonatomic, assign) ViewerClipMode clipMode;
@property(nonatomic, assign) int activeGroupEntityId;
@property(nonatomic, assign) BOOL ignoreGroupSelection;
@property(nonatomic, assign) BOOL textureApplicationModeActive;

@end

@implementation ViewerAppDelegate {
    // Materials directory watcher
    dispatch_source_t _directoryWatchSource;
    int _directoryWatchFd;
    // Vertex edit session state
    BOOL _hasVertexEditSession;
    size_t _vertexEditEntityIndex;
    size_t _vertexEditSolidIndex;
    // Draft vertex positions — freely moved, may be invalid
    Vec3 _draftVertices[VMF_MAX_SOLID_VERTICES];
    size_t _draftVertexCount;
    // Edge connectivity by vertex index so we can display edges from draft positions
    size_t _draftEdgeConnVA[VMF_MAX_SOLID_EDGES];
    size_t _draftEdgeConnVB[VMF_MAX_SOLID_EDGES];
    VmfSolidEdge _draftEdgeTemplates[VMF_MAX_SOLID_EDGES];
    size_t _draftEdgeConnCount;
    BOOL _draftIsValid;
    // Face convexity data — captured at session start for geometric validity check
    // Each slot corresponds to one solid side; holds the inward-facing reference
    // normal (used to orient re-computed planes consistently) and the solid->sides[]
    // index so we can look up which edges belong to each face.
    Vec3   _draftFaceRefNormals[128];
    size_t _draftFaceSideIndices[128];
    size_t _draftFaceCount;
}

- (instancetype)initWithStartupPath:(NSString*)startupPath {
    self = [super init];
    if (!self) {
        return nil;
    }
    _startupPath = [startupPath copy];
    _gridSize = 32.0;
    _currentRevision = 0;
    _savedRevision = 0;
    _nextRevision = 1;
    _pendingRevision = -1;
    _currentHistoryLabel = @"Initial State";
    _undoStack = [NSMutableArray array];
    _redoStack = [NSMutableArray array];
    _currentPrefabs = [NSMutableArray array];
    _clipMode = ViewerClipModeBoth;
    _activeGroupEntityId = 0;
    _ignoreGroupSelection = NO;
    _textureApplicationModeActive = NO;
    _textureLockEnabled = YES;
    nova_scene_world_initialize(&_sceneWorld);
    nova_scene_world_register_editor_tags(&_sceneWorld);
    return self;
}

- (void)dealloc {
    [self stopWatchingMaterialsDirectory];
    nova_scene_world_shutdown(&_sceneWorld);
    file_index_free(&_fileIndex);
    vmf_scene_free(&_scene);
    viewer_mesh_free(&_mesh);
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    (void)notification;
    [self createMenu];
    [self createWindow];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    // Use the absolute exe path so detection works regardless of CWD/launch method
    NSString* exeDir = [NSBundle.mainBundle.executablePath stringByDeletingLastPathComponent];
    BOOL isDir = NO;
    NSArray<NSString*>* candidatePaths = @[
        [[exeDir stringByAppendingPathComponent:@"content"] stringByAppendingPathComponent:@"materials"],
        [exeDir stringByAppendingPathComponent:@"materials"],
        @"/content/materials",
    ];
    for (NSString* candidate in candidatePaths) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:candidate isDirectory:&isDir] && isDir) {
            self.materialsDirectory = candidate;
            break;
        }
    }
    // User-chosen path takes highest priority
    NSString* savedPath = [[NSUserDefaults standardUserDefaults] stringForKey:@"materialsDirectory"];
    if (savedPath.length > 0) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:savedPath isDirectory:&isDir] && isDir) {
            self.materialsDirectory = savedPath;
        }
    }

    if (self.startupPath.length > 0) {
        [self openPath:self.startupPath];
    }
}

- (BOOL)application:(NSApplication*)application openFile:(NSString*)filename {
    (void)application;
    [self openPath:filename];
    return YES;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    (void)sender;
    return YES;
}

- (void)createMenu {
    NSMenu* mainMenu = [[NSMenu alloc] initWithTitle:kAppDisplayName];
    NSMenuItem* appItem = [[NSMenuItem alloc] initWithTitle:kAppDisplayName action:nil keyEquivalent:@""];
    [mainMenu addItem:appItem];

    NSMenu* appMenu = [[NSMenu alloc] initWithTitle:kAppDisplayName];
    [appMenu addItemWithTitle:@"New" action:@selector(newDocument:) keyEquivalent:@"n"];
    [appMenu addItemWithTitle:@"Open..." action:@selector(openDocument:) keyEquivalent:@"o"];
    [appMenu addItemWithTitle:@"Save" action:@selector(saveDocument:) keyEquivalent:@"s"];
    NSMenuItem* saveAsItem = [appMenu addItemWithTitle:@"Save As..." action:@selector(saveDocumentAs:) keyEquivalent:@"S"];
    saveAsItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [appMenu addItemWithTitle:@"Reload" action:@selector(reloadDocument:) keyEquivalent:@"r"];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Set Textures Folder\u2026" action:@selector(chooseTexturesFolder:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:[NSString stringWithFormat:@"Quit %@", kAppDisplayName] action:@selector(terminate:) keyEquivalent:@"q"];
    [appItem setSubmenu:appMenu];

    NSMenuItem* editItem = [[NSMenuItem alloc] initWithTitle:@"Edit" action:nil keyEquivalent:@""];
    [mainMenu addItem:editItem];
    self.editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    self.editMenu.delegate = self;
    self.undoMenuItem = [self.editMenu addItemWithTitle:@"Undo" action:@selector(undoAction:) keyEquivalent:@"z"];
    self.redoMenuItem = [self.editMenu addItemWithTitle:@"Redo" action:@selector(redoAction:) keyEquivalent:@"Z"];
    self.redoMenuItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [self.editMenu addItem:[NSMenuItem separatorItem]];
    [self.editMenu addItemWithTitle:@"Duplicate Selection" action:@selector(duplicateSelection:) keyEquivalent:@"d"];
    NSMenuItem* deleteItem = [self.editMenu addItemWithTitle:@"Delete Selection" action:@selector(deleteSelection:) keyEquivalent:@"\177"];
    deleteItem.keyEquivalentModifierMask = 0;
    [self.editMenu addItemWithTitle:@"Apply Material" action:@selector(applyMaterialToSelection:) keyEquivalent:@"m"];
    [editItem setSubmenu:self.editMenu];

    NSMenuItem* historyItem = [[NSMenuItem alloc] initWithTitle:@"History" action:nil keyEquivalent:@""];
    [mainMenu addItem:historyItem];
    self.historyMenu = [[NSMenu alloc] initWithTitle:@"History"];
    self.historyMenu.delegate = self;
    [historyItem setSubmenu:self.historyMenu];

    NSMenuItem* viewItem = [[NSMenuItem alloc] initWithTitle:@"View" action:nil keyEquivalent:@""];
    [mainMenu addItem:viewItem];
    NSMenu* viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    [viewMenu addItemWithTitle:@"Shaded" action:@selector(setShadedMode:) keyEquivalent:@"1"];
    [viewMenu addItemWithTitle:@"Wireframe" action:@selector(setWireframeMode:) keyEquivalent:@"2"];
    [viewMenu addItemWithTitle:@"Frame Scene" action:@selector(frameScene:) keyEquivalent:@"f"];
    [viewMenu addItemWithTitle:@"Next File" action:@selector(nextDocument:) keyEquivalent:@"n"];
    [viewMenu addItemWithTitle:@"Previous File" action:@selector(previousDocument:) keyEquivalent:@"p"];
    [viewItem setSubmenu:viewMenu];

    NSMenuItem* toolsItem = [[NSMenuItem alloc] initWithTitle:@"Tools" action:nil keyEquivalent:@""];
    [mainMenu addItem:toolsItem];
    NSMenu* toolsMenu = [[NSMenu alloc] initWithTitle:@"Tools"];
    [toolsMenu addItemWithTitle:@"Selection Tool" action:@selector(setSelectTool:) keyEquivalent:@"v"];
    [toolsMenu addItemWithTitle:@"Vertex Tool" action:@selector(setVertexTool:) keyEquivalent:@"e"];
    [toolsMenu addItemWithTitle:@"Block Tool" action:@selector(setBlockTool:) keyEquivalent:@"b"];
    [toolsMenu addItemWithTitle:@"Cylinder Tool" action:@selector(setCylinderTool:) keyEquivalent:@"c"];
    [toolsMenu addItemWithTitle:@"Ramp Tool" action:@selector(setRampTool:) keyEquivalent:@"g"];
    [toolsMenu addItemWithTitle:@"Stairs Tool" action:@selector(setStairsTool:) keyEquivalent:@"t"];
    [toolsMenu addItemWithTitle:@"Arch Tool" action:@selector(setArchTool:) keyEquivalent:@"a"];
    [toolsMenu addItemWithTitle:@"Clip Tool" action:@selector(setClipTool:) keyEquivalent:@"x"];
    [toolsMenu addItem:[NSMenuItem separatorItem]];
    [toolsMenu addItemWithTitle:@"Add Light" action:@selector(addLightEntity:) keyEquivalent:@"l"];
    [toolsItem setSubmenu:toolsMenu];

    NSMenuItem* groupsItem = [[NSMenuItem alloc] initWithTitle:@"Groups" action:nil keyEquivalent:@""];
    [mainMenu addItem:groupsItem];
    NSMenu* groupsMenu = [[NSMenu alloc] initWithTitle:@"Groups"];
    [groupsMenu addItemWithTitle:@"Create Group" action:@selector(createGroupFromSelection:) keyEquivalent:@"g"];
    NSMenuItem* addToGroupItem = [groupsMenu addItemWithTitle:@"Add Selection To Active Group" action:@selector(addSelectionToActiveGroup:) keyEquivalent:@"G"];
    addToGroupItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [groupsMenu addItemWithTitle:@"Ungroup" action:@selector(ungroupSelection:) keyEquivalent:@"u"];
    [groupsItem setSubmenu:groupsMenu];

    [NSApp setMainMenu:mainMenu];
}

- (void)createWindow {
    NSRect frame = NSMakeRect(100, 100, 1440, 900);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable)
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = kAppDisplayName;
    self.window.delegate = self;

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    self.rootView = [[NSView alloc] initWithFrame:frame];
    self.rootView.wantsLayer = YES;
    self.rootView.layer.backgroundColor = CGColorCreateGenericRGB(0.045f, 0.05f, 0.06f, 1.0f);
    self.brushMaterialName = @"dev_grid";

    [self registerMaterialSymbolsFont];

    [self buildViewportLayoutWithDevice:device];
    self.window.contentView = self.rootView;

    [self buildMacUI];
    [self setEditorTool:VmfViewportEditorToolSelect];
    [self setActiveViewport:self.perspectiveViewport];
    [self.window makeFirstResponder:self.perspectiveViewport.metalView];
    [self updateChrome];
}

- (StyledSplitView*)newSplitViewVertical:(BOOL)vertical {
    StyledSplitView* splitView = [[StyledSplitView alloc] initWithFrame:NSZeroRect];
    splitView.vertical = vertical;
    splitView.translatesAutoresizingMaskIntoConstraints = NO;
    splitView.autosaveName = @"";
    splitView.dividerStyle = NSSplitViewDividerStyleThin;
    return splitView;
}

- (void)buildViewportLayoutWithDevice:(id<MTLDevice>)device {
    self.verticalSplitView = [self newSplitViewVertical:NO];
    self.topSplitView = [self newSplitViewVertical:YES];
    self.bottomSplitView = [self newSplitViewVertical:YES];

    self.topViewport = [[VmfViewport alloc] initWithFrame:NSZeroRect
                                                   device:device
                                                    title:@"Top XY"
                                                dimension:VmfViewportDimension2D
                                                    plane:VmfViewportPlaneXY
                                               renderMode:VmfViewportRenderModeWireframe];
    self.perspectiveViewport = [[VmfViewport alloc] initWithFrame:NSZeroRect
                                                           device:device
                                                            title:@"Camera 3D"
                                                        dimension:VmfViewportDimension3D
                                                            plane:VmfViewportPlaneXY
                                                       renderMode:VmfViewportRenderModeShaded];
    self.frontViewport = [[VmfViewport alloc] initWithFrame:NSZeroRect
                                                     device:device
                                                      title:@"Front XZ"
                                                  dimension:VmfViewportDimension2D
                                                      plane:VmfViewportPlaneXZ
                                                 renderMode:VmfViewportRenderModeWireframe];
    self.sideViewport = [[VmfViewport alloc] initWithFrame:NSZeroRect
                                                    device:device
                                                     title:@"Side ZY"
                                                 dimension:VmfViewportDimension2D
                                                     plane:VmfViewportPlaneZY
                                                renderMode:VmfViewportRenderModeWireframe];

    self.viewports = @[ self.topViewport, self.perspectiveViewport, self.frontViewport, self.sideViewport ];
    for (VmfViewport* viewport in self.viewports) {
        viewport.delegate = self;
        viewport.gridSize = self.gridSize;
        [viewport setSceneWorld:&_sceneWorld];
    }

    [self.topSplitView addSubview:self.topViewport];
    [self.topSplitView addSubview:self.perspectiveViewport];
    [self.bottomSplitView addSubview:self.frontViewport];
    [self.bottomSplitView addSubview:self.sideViewport];

    [self.verticalSplitView addSubview:self.topSplitView];
    [self.verticalSplitView addSubview:self.bottomSplitView];
    [self.rootView addSubview:self.verticalSplitView];

    [NSLayoutConstraint activateConstraints:@[
        [self.verticalSplitView.leadingAnchor constraintEqualToAnchor:self.rootView.leadingAnchor constant:80.0],
        [self.verticalSplitView.trailingAnchor constraintEqualToAnchor:self.rootView.trailingAnchor constant:-324.0],
        [self.verticalSplitView.topAnchor constraintEqualToAnchor:self.rootView.topAnchor constant:68.0],
        [self.verticalSplitView.bottomAnchor constraintEqualToAnchor:self.rootView.bottomAnchor constant:-12.0],
    ]];

    [self.rootView layoutSubtreeIfNeeded];
    CGFloat midX = NSWidth(self.rootView.bounds) * 0.5 - self.topSplitView.dividerThickness * 0.5;
    CGFloat midY = NSHeight(self.rootView.bounds) * 0.5 - self.verticalSplitView.dividerThickness * 0.5;
    [self.topSplitView setPosition:midX ofDividerAtIndex:0];
    [self.bottomSplitView setPosition:midX ofDividerAtIndex:0];
    [self.verticalSplitView setPosition:midY ofDividerAtIndex:0];
}

- (void)registerMaterialSymbolsFont {
    NSString* executableDir = [[[NSProcessInfo processInfo] arguments][0] stringByDeletingLastPathComponent];
    NSString* fontPath = [executableDir stringByAppendingPathComponent:@"MaterialSymbolsOutlined.ttf"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:fontPath]) {
        return;
    }

    NSURL* fontURL = [NSURL fileURLWithPath:fontPath];
    CTFontManagerRegisterFontsForURL((__bridge CFURLRef)fontURL, kCTFontManagerScopeProcess, NULL);
}

- (NSAttributedString*)toolbarAttributedTitleWithIcon:(NSString*)icon text:(NSString*)text {
    NSMutableAttributedString* attributedTitle = [[NSMutableAttributedString alloc] init];
    NSFont* iconFont = [NSFont fontWithName:@"Material Symbols Outlined" size:18.0];
    if (!iconFont) {
        iconFont = [NSFont systemFontOfSize:18.0 weight:NSFontWeightRegular];
    }
    [attributedTitle appendAttributedString:[[NSAttributedString alloc] initWithString:icon
                                                                             attributes:@{
                                                                                 NSFontAttributeName: iconFont,
                                                                                 NSForegroundColorAttributeName: [NSColor colorWithWhite:0.94 alpha:1.0],
                                                                             }]];
    [attributedTitle appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"  %@", text]
                                                                             attributes:@{
                                                                                 NSFontAttributeName: [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium],
                                                                                 NSForegroundColorAttributeName: [NSColor colorWithWhite:0.94 alpha:1.0],
                                                                             }]];
    return attributedTitle;
}

- (NSAttributedString*)toolbarAttributedTitleWithIconOnly:(NSString*)icon {
    NSFont* iconFont = [NSFont fontWithName:@"Material Symbols Outlined" size:18.0];
    if (!iconFont) {
        iconFont = [NSFont systemFontOfSize:18.0 weight:NSFontWeightRegular];
    }
    return [[NSAttributedString alloc] initWithString:icon
                                           attributes:@{
                                               NSFontAttributeName: iconFont,
                                               NSForegroundColorAttributeName: [NSColor colorWithWhite:0.94 alpha:1.0],
                                           }];
}

- (NSAttributedString*)toolRailAttributedTitleWithIcon:(NSString*)icon active:(BOOL)active {
    NSFont* iconFont = [NSFont fontWithName:@"Material Symbols Outlined" size:19.0];
    if (!iconFont) {
        iconFont = [NSFont systemFontOfSize:19.0 weight:NSFontWeightRegular];
    }
    NSColor* color = active ? [NSColor colorWithCalibratedRed:0.95 green:0.61 blue:0.18 alpha:1.0] : [NSColor colorWithWhite:0.90 alpha:1.0];
    return [[NSAttributedString alloc] initWithString:icon
                                           attributes:@{
                                               NSFontAttributeName: iconFont,
                                               NSForegroundColorAttributeName: color,
                                           }];
}

- (NSButton*)toolbarButtonWithIcon:(NSString*)icon text:(NSString*)text action:(SEL)action {
    NSButton* button = [NSButton buttonWithTitle:@"" target:self action:action];
    button.bezelStyle = NSBezelStyleTexturedRounded;
    button.attributedTitle = [self toolbarAttributedTitleWithIcon:icon text:text];
    button.attributedAlternateTitle = [self toolbarAttributedTitleWithIconOnly:icon];
    button.imagePosition = NSImageLeft;
    button.lineBreakMode = NSLineBreakByClipping;
    [button setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [button setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return button;
}

- (NSTextField*)toolbarBadgeLabelWithIcon:(NSString*)icon text:(NSString*)text {
    NSTextField* label = [NSTextField labelWithAttributedString:[self toolbarAttributedTitleWithIcon:icon text:text]];
    label.lineBreakMode = NSLineBreakByClipping;
    label.maximumNumberOfLines = 1;
    [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [label setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return label;
}

- (void)applyToolbarModeToButton:(NSButton*)button icon:(NSString*)icon text:(NSString*)text compact:(BOOL)compact {
    button.attributedTitle = compact ? [self toolbarAttributedTitleWithIconOnly:icon] : [self toolbarAttributedTitleWithIcon:icon text:text];
    button.toolTip = text;
}

- (void)applyToolbarModeToLabel:(NSTextField*)label icon:(NSString*)icon text:(NSString*)text compact:(BOOL)compact {
    label.attributedStringValue = compact ? [self toolbarAttributedTitleWithIconOnly:icon] : [self toolbarAttributedTitleWithIcon:icon text:text];
    label.toolTip = text;
}

- (NSButton*)toolRailButtonWithIcon:(NSString*)icon tooltip:(NSString*)tooltip action:(SEL)action {
    NSButton* button = [NSButton buttonWithTitle:@"" target:self action:action];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.bezelStyle = NSBezelStyleTexturedRounded;
    button.attributedTitle = [self toolRailAttributedTitleWithIcon:icon active:NO];
    button.attributedAlternateTitle = [self toolRailAttributedTitleWithIcon:icon active:YES];
    button.toolTip = tooltip;
    button.imagePosition = NSNoImage;
    [button.widthAnchor constraintEqualToConstant:40.0].active = YES;
    [button.heightAnchor constraintEqualToConstant:32.0].active = YES;
    return button;
}

- (void)refreshToolRailSelection {
    NSDictionary<NSNumber*, NSButton*>* buttons = @{
        @(VmfViewportEditorToolSelect): self.selectToolButton,
        @(VmfViewportEditorToolVertex): self.vertexToolButton,
        @(VmfViewportEditorToolBlock): self.blockToolButton,
        @(VmfViewportEditorToolCylinder): self.cylinderToolButton,
        @(VmfViewportEditorToolRamp): self.rampToolButton,
        @(VmfViewportEditorToolStairs): self.stairsToolButton,
        @(VmfViewportEditorToolArch): self.archToolButton,
        @(VmfViewportEditorToolClip): self.clipToolButton,
    };
    for (NSNumber* key in buttons) {
        NSButton* button = buttons[key];
        BOOL active = self.editorTool == key.unsignedIntegerValue;
        button.state = active ? NSControlStateValueOn : NSControlStateValueOff;
        NSString* icon = @"";
        if (button == self.selectToolButton) {
            icon = @"arrow_selector_tool";
        } else if (button == self.vertexToolButton) {
            icon = @"polyline";
        } else if (button == self.blockToolButton) {
            icon = @"crop_square";
        } else if (button == self.cylinderToolButton) {
            icon = @"circle";
        } else if (button == self.rampToolButton) {
            icon = @"change_history";
        } else if (button == self.stairsToolButton) {
            icon = @"stairs";
        } else if (button == self.archToolButton) {
            icon = @"architecture";
        } else if (button == self.clipToolButton) {
            icon = @"content_cut";
        }
        button.attributedTitle = [self toolRailAttributedTitleWithIcon:icon active:active];
    }
}

- (void)updateToolbarLayout {
    CGFloat availableWidth = NSWidth(self.window.contentView.bounds);
    BOOL compact = availableWidth < 1220.0;
    BOOL ultraCompact = availableWidth < 980.0;
    if (compact == self.toolbarCompact && ultraCompact == self.toolbarUltraCompact) {
        return;
    }

    self.toolbarCompact = compact;
    self.toolbarUltraCompact = ultraCompact;

    [self applyToolbarModeToButton:self.createMapButton icon:@"add" text:@"New" compact:compact];
    [self applyToolbarModeToButton:self.openButton icon:@"folder_open" text:@"Open" compact:compact];
    [self applyToolbarModeToButton:self.saveButton icon:@"save" text:@"Save" compact:compact];
    [self applyToolbarModeToButton:self.undoButton icon:@"undo" text:@"Undo" compact:compact];
    [self applyToolbarModeToButton:self.redoButton icon:@"redo" text:@"Redo" compact:compact];
    [self applyToolbarModeToButton:self.duplicateButton icon:@"content_copy" text:@"Duplicate" compact:compact];
    [self applyToolbarModeToButton:self.deleteButton icon:@"delete" text:@"Delete" compact:compact];
    [self applyToolbarModeToButton:self.textureModeButton icon:@"format_paint" text:@"Texture" compact:compact];
    [self applyToolbarModeToButton:self.textureLockButton icon:@"link" text:@"Tex Lock" compact:compact];
    [self applyToolbarModeToButton:self.ignoreGroupsButton icon:@"filter_none" text:@"Ignore Groups" compact:compact];
    [self applyToolbarModeToButton:self.applyMaterialButton icon:@"format_paint" text:@"Apply" compact:compact];
    [self applyToolbarModeToButton:self.browseMaterialButton icon:@"search" text:@"Browse" compact:compact];

    [self applyToolbarModeToLabel:self.gridLabel icon:@"grid_view" text:@"Snap" compact:compact];
    [self applyToolbarModeToLabel:self.renderLabel icon:@"dehaze" text:@"Render" compact:compact];
    [self applyToolbarModeToLabel:self.materialLabel icon:@"wallpaper" text:@"Brush" compact:compact];

    self.controlStack.spacing = ultraCompact ? 4.0 : (compact ? 6.0 : 8.0);
    self.controlBarHeightConstraint.constant = ultraCompact ? 42.0 : 46.0;
    [self.controlBar invalidateIntrinsicContentSize];
    [self.controlStack invalidateIntrinsicContentSize];
}

- (void)setGridSize:(CGFloat)gridSize {
    _gridSize = fmax(gridSize, 1.0);
    for (VmfViewport* viewport in self.viewports) {
        viewport.gridSize = _gridSize;
    }
    [self updateChrome];
}

- (void)stepGridSizeByOffset:(NSInteger)offset {
    NSArray<NSString*>* gridSteps = @[ @"1", @"2", @"4", @"8", @"16", @"32", @"64", @"128", @"256" ];
    NSInteger currentIndex = [gridSteps indexOfObject:[NSString stringWithFormat:@"%.0f", self.gridSize]];
    if (currentIndex == NSNotFound) {
        currentIndex = 0;
    }
    NSInteger nextIndex = MIN(MAX(currentIndex + offset, 0), (NSInteger)gridSteps.count - 1);
    self.gridSize = gridSteps[(NSUInteger)nextIndex].doubleValue;
}

- (NSString*)displayHistoryLabel:(NSString*)label fallback:(NSString*)fallback {
    return label.length > 0 ? label : fallback;
}

- (void)updateHistoryMenuTitles {
    NSString* undoLabel = self.undoStack.count > 0 ? [self displayHistoryLabel:self.currentHistoryLabel fallback:@"Change"] : nil;
    NSString* redoLabel = self.redoStack.count > 0 ? [self displayHistoryLabel:self.redoStack.lastObject->stateLabel fallback:@"Change"] : nil;
    self.undoMenuItem.title = undoLabel ? [NSString stringWithFormat:@"Undo %@", undoLabel] : @"Undo";
    self.redoMenuItem.title = redoLabel ? [NSString stringWithFormat:@"Redo %@", redoLabel] : @"Redo";
    self.undoButton.toolTip = undoLabel ? self.undoMenuItem.title : @"Undo";
    self.redoButton.toolTip = redoLabel ? self.redoMenuItem.title : @"Redo";
}

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

- (VmfViewportSelectionEdge)selectionEdgeForPlane:(VmfViewportPlane)plane sideIndex:(size_t)sideIndex {
    switch (plane) {
        case VmfViewportPlaneXY:
            if (sideIndex == 1) return VmfViewportSelectionEdgeMinU;
            if (sideIndex == 0) return VmfViewportSelectionEdgeMaxU;
            if (sideIndex == 3) return VmfViewportSelectionEdgeMinV;
            if (sideIndex == 2) return VmfViewportSelectionEdgeMaxV;
            break;
        case VmfViewportPlaneXZ:
            if (sideIndex == 1) return VmfViewportSelectionEdgeMinU;
            if (sideIndex == 0) return VmfViewportSelectionEdgeMaxU;
            if (sideIndex == 5) return VmfViewportSelectionEdgeMinV;
            if (sideIndex == 4) return VmfViewportSelectionEdgeMaxV;
            break;
        case VmfViewportPlaneZY:
            if (sideIndex == 3) return VmfViewportSelectionEdgeMinU;
            if (sideIndex == 2) return VmfViewportSelectionEdgeMaxU;
            if (sideIndex == 5) return VmfViewportSelectionEdgeMinV;
            if (sideIndex == 4) return VmfViewportSelectionEdgeMaxV;
            break;
    }
    return VmfViewportSelectionEdgeNone;
}

- (NSInteger)sideIndexForPlane:(VmfViewportPlane)plane edge:(VmfViewportSelectionEdge)edge {
    switch (plane) {
        case VmfViewportPlaneXY:
            if (edge == VmfViewportSelectionEdgeMinU) return 1;
            if (edge == VmfViewportSelectionEdgeMaxU) return 0;
            if (edge == VmfViewportSelectionEdgeMinV) return 3;
            if (edge == VmfViewportSelectionEdgeMaxV) return 2;
            break;
        case VmfViewportPlaneXZ:
            if (edge == VmfViewportSelectionEdgeMinU) return 1;
            if (edge == VmfViewportSelectionEdgeMaxU) return 0;
            if (edge == VmfViewportSelectionEdgeMinV) return 5;
            if (edge == VmfViewportSelectionEdgeMaxV) return 4;
            break;
        case VmfViewportPlaneZY:
            if (edge == VmfViewportSelectionEdgeMinU) return 3;
            if (edge == VmfViewportSelectionEdgeMaxU) return 2;
            if (edge == VmfViewportSelectionEdgeMinV) return 5;
            if (edge == VmfViewportSelectionEdgeMaxV) return 4;
            break;
    }
    return -1;
}

- (Vec3)duplicateOffsetForActiveViewport {
    float delta = (float)self.gridSize;
    switch (self.activeViewport.plane) {
        case VmfViewportPlaneXZ:
            return vec3_make(delta, 0.0f, 0.0f);
        case VmfViewportPlaneZY:
            return vec3_make(0.0f, delta, 0.0f);
        case VmfViewportPlaneXY:
        default:
            return vec3_make(delta, delta, 0.0f);
    }
}

- (VmfBrushAxis)activeBrushAxis {
    VmfViewport* viewport = self.activeViewport ? self.activeViewport : self.topViewport;
    switch (viewport.plane) {
        case VmfViewportPlaneXZ:
            return VmfBrushAxisY;
        case VmfViewportPlaneZY:
            return VmfBrushAxisX;
        case VmfViewportPlaneXY:
        default:
            return VmfBrushAxisZ;
    }
}

- (VmfBrushAxis)runBrushAxisForViewport:(VmfViewport*)viewport {
    switch (viewport.plane) {
        case VmfViewportPlaneZY:
            return VmfBrushAxisY;
        case VmfViewportPlaneXY:
        case VmfViewportPlaneXZ:
        default:
            return VmfBrushAxisX;
    }
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

- (size_t)solidCountForShapeTool:(VmfViewportEditorTool)tool primaryValue:(NSInteger)primaryValue {
    switch (tool) {
        case VmfViewportEditorToolArch:
        case VmfViewportEditorToolStairs:
            return (size_t)MAX(2, primaryValue);
        case VmfViewportEditorToolCylinder:
        case VmfViewportEditorToolRamp:
        default:
            return 1;
    }
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

- (BOOL)entityIndexIsGroupedBrushEntity:(size_t)entityIndex {
    if (entityIndex >= self.scene.entityCount) {
        return NO;
    }
    const VmfEntity* entity = &self.scene.entities[entityIndex];
    if (entity->kind != VmfEntityKindBrush || entity->isWorld || entity->solidCount == 0) {
        return NO;
    }
    if (strcmp(entity->classname, "func_group") == 0) {
        return YES;
    }
    return entity->classname[0] == '\0' && entity->name[0] != '\0';
}

- (BOOL)selectionIsGroupedBrushEntity {
    return self.hasSelection && [self entityIndexIsGroupedBrushEntity:self.selectedEntityIndex];
}

- (BOOL)selectionActsAsGroupedBrushEntity {
    return [self selectionIsGroupedBrushEntity] && !self.ignoreGroupSelection;
}

- (size_t)entityIndexForEntityId:(int)entityId {
    if (entityId <= 0) {
        return self.scene.entityCount;
    }
    for (size_t entityIndex = 0; entityIndex < self.scene.entityCount; ++entityIndex) {
        if (self.scene.entities[entityIndex].id == entityId) {
            return entityIndex;
        }
    }
    return self.scene.entityCount;
}

- (size_t)activeGroupEntityIndex {
    if ([self selectionIsGroupedBrushEntity]) {
        return self.selectedEntityIndex;
    }
    return [self entityIndexForEntityId:self.activeGroupEntityId];
}

- (NSString*)nextGroupName {
    NSUInteger groupCount = 0;
    for (size_t entityIndex = 0; entityIndex < self.scene.entityCount; ++entityIndex) {
        if ([self entityIndexIsGroupedBrushEntity:entityIndex]) {
            groupCount += 1;
        }
    }
    return [NSString stringWithFormat:@"Group %lu", (unsigned long)(groupCount + 1)];
}

- (BOOL)selectionIsPointEntity {
    if (!self.hasSelection || self.selectedEntityIndex >= self.scene.entityCount) {
        return NO;
    }
    const VmfEntity* entity = &self.scene.entities[self.selectedEntityIndex];
    return entity->solidCount == 0 && entity->kind == VmfEntityKindLight;
}

- (BOOL)selectedEntityBounds:(Bounds3*)outBounds {
    if (!self.hasSelection || outBounds == NULL || self.selectedEntityIndex >= self.scene.entityCount) {
        return NO;
    }
    char errorBuffer[256] = { 0 };
    return vmf_scene_entity_bounds(&_scene, self.selectedEntityIndex, outBounds, errorBuffer, sizeof(errorBuffer));
}

- (BOOL)pickPointEntityAtPoint:(Vec3)point plane:(VmfViewportPlane)plane outEntityIndex:(size_t*)outEntityIndex {
    BOOL found = NO;
    float bestArea = FLT_MAX;
    size_t bestEntityIndex = 0;
    for (size_t entityIndex = 0; entityIndex < self.scene.entityCount; ++entityIndex) {
        const VmfEntity* entity = &self.scene.entities[entityIndex];
        if (entity->solidCount != 0 || entity->kind != VmfEntityKindLight) {
            continue;
        }

        Bounds3 bounds = bounds3_empty();
        char errorBuffer[128] = { 0 };
        if (!vmf_scene_entity_bounds(&_scene, entityIndex, &bounds, errorBuffer, sizeof(errorBuffer))) {
            continue;
        }

        float minU = plane == VmfViewportPlaneZY ? bounds.min.raw[1] : bounds.min.raw[0];
        float maxU = plane == VmfViewportPlaneZY ? bounds.max.raw[1] : bounds.max.raw[0];
        float minV = plane == VmfViewportPlaneXY ? bounds.min.raw[1] : bounds.min.raw[2];
        float maxV = plane == VmfViewportPlaneXY ? bounds.max.raw[1] : bounds.max.raw[2];
        float u = plane == VmfViewportPlaneZY ? point.raw[1] : point.raw[0];
        float v = plane == VmfViewportPlaneXY ? point.raw[1] : point.raw[2];
        if (u < minU || u > maxU || v < minV || v > maxV) {
            continue;
        }

        float area = (maxU - minU) * (maxV - minV);
        if (!found || area < bestArea) {
            found = YES;
            bestArea = area;
            bestEntityIndex = entityIndex;
        }
    }

    if (found && outEntityIndex != NULL) {
        *outEntityIndex = bestEntityIndex;
    }
    return found;
}

- (BOOL)pickPointEntityRayOrigin:(Vec3)origin direction:(Vec3)direction outEntityIndex:(size_t*)outEntityIndex {
    BOOL found = NO;
    float bestDistance = FLT_MAX;
    size_t bestEntityIndex = 0;
    Vec3 normalizedDirection = vec3_normalize(direction);
    for (size_t entityIndex = 0; entityIndex < self.scene.entityCount; ++entityIndex) {
        const VmfEntity* entity = &self.scene.entities[entityIndex];
        if (entity->solidCount != 0 || entity->kind != VmfEntityKindLight) {
            continue;
        }

        float radius = entity_pick_radius(entity);
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
            found = YES;
            bestDistance = surfaceDistance;
            bestEntityIndex = entityIndex;
        }
    }

    if (found && outEntityIndex != NULL) {
        *outEntityIndex = bestEntityIndex;
    }
    return found;
}

- (NSInteger)defaultShapePrimaryValueForTool:(VmfViewportEditorTool)tool bounds:(Bounds3)bounds {
    if (tool == VmfViewportEditorToolCylinder) {
        return 12;
    }
    if (tool == VmfViewportEditorToolArch) {
        return 8;
    }
    if (tool == VmfViewportEditorToolStairs) {
        VmfBrushAxis upAxis = self.activeShapeSessionUpAxis;
        VmfBrushAxis runAxis = self.activeShapeSessionRunAxis;
        float runSize = bounds.max.raw[runAxis] - bounds.min.raw[runAxis];
        float upSize = bounds.max.raw[upAxis] - bounds.min.raw[upAxis];
        return MAX(2, MIN(16, (NSInteger)floor(fminf(runSize, upSize) / (float)self.gridSize)));
    }
    return 0;
}

- (NSInteger)minimumShapePrimaryValueForTool:(VmfViewportEditorTool)tool {
    switch (tool) {
        case VmfViewportEditorToolCylinder:
            return 3;
        case VmfViewportEditorToolArch:
            return 2;
        case VmfViewportEditorToolStairs:
            return 2;
        default:
            return 0;
    }
}

- (NSInteger)maximumShapePrimaryValueForTool:(VmfViewportEditorTool)tool {
    switch (tool) {
        case VmfViewportEditorToolCylinder:
            return 64;
        case VmfViewportEditorToolArch:
            return 32;
        case VmfViewportEditorToolStairs:
            return 32;
        default:
            return 0;
    }
}

- (NSString*)shapePrimaryLabelForTool:(VmfViewportEditorTool)tool {
    switch (tool) {
        case VmfViewportEditorToolCylinder:
            return @"Segments";
        case VmfViewportEditorToolArch:
            return @"Segments";
        case VmfViewportEditorToolStairs:
            return @"Steps";
        default:
            return @"Value";
    }
}

- (BOOL)toolHasSecondaryShapeSetting:(VmfViewportEditorTool)tool {
    return tool == VmfViewportEditorToolArch;
}

- (NSString*)shapeSecondaryLabelForTool:(VmfViewportEditorTool)tool {
    return tool == VmfViewportEditorToolArch ? @"Thickness" : @"";
}

- (CGFloat)defaultShapeSecondaryValueForTool:(VmfViewportEditorTool)tool {
    return tool == VmfViewportEditorToolArch ? 30.0f : 0.0f;
}

- (NSString*)shapeSettingsPanelTitleForTool:(VmfViewportEditorTool)tool {
    switch (tool) {
        case VmfViewportEditorToolCylinder:
            return @"Cylinder Settings";
        case VmfViewportEditorToolStairs:
            return @"Stairs Settings";
        case VmfViewportEditorToolArch:
            return @"Arch Settings";
        default:
            return @"Shape Settings";
    }
}

- (NSTextField*)inspectorSectionLabel:(NSString*)title {
    NSTextField* label = [NSTextField labelWithString:title];
    label.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightSemibold];
    label.textColor = [NSColor secondaryLabelColor];
    return label;
}

- (NSTextField*)inspectorBodyLabel:(NSString*)value {
    NSTextField* label = [NSTextField labelWithString:value];
    label.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightRegular];
    label.textColor = [NSColor labelColor];
    label.maximumNumberOfLines = 0;
    return label;
}

- (NSTextField*)inspectorNumericFieldWithAction:(SEL)action {
    NSTextField* field = [[NSTextField alloc] initWithFrame:NSZeroRect];
    field.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightRegular];
    field.alignment = NSTextAlignmentRight;
    field.target = self;
    field.action = action;
    field.bezelStyle = NSTextFieldRoundedBezel;
    field.translatesAutoresizingMaskIntoConstraints = NO;
    [field.widthAnchor constraintEqualToConstant:84.0].active = YES;
    if ([field.cell respondsToSelector:@selector(setSendsActionOnEndEditing:)]) {
        [(id)field.cell setSendsActionOnEndEditing:YES];
    }
    return field;
}

- (NSStackView*)inspectorLabeledFieldRow:(NSString*)title field:(NSTextField* __strong *)outField action:(SEL)action {
    NSStackView* row = [[NSStackView alloc] initWithFrame:NSZeroRect];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.distribution = NSStackViewDistributionFill;
    row.spacing = 8.0;

    NSTextField* label = [self inspectorBodyLabel:title];
    [label setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [row addArrangedSubview:label];

    NSTextField* field = [self inspectorNumericFieldWithAction:action];
    [row addArrangedSubview:field];
    if (outField != NULL) {
        *outField = field;
    }
    return row;
}

- (NSButton*)inspectorActionButton:(NSString*)title action:(SEL)action tag:(NSInteger)tag {
    NSButton* button = [NSButton buttonWithTitle:title target:self action:action];
    button.bezelStyle = NSBezelStyleRounded;
    button.tag = tag;
    return button;
}

- (void)buildShapeSettingsPanel {
    if (self.prefabInspectorView) {
        return;
    }

    NSStackView* container = [[NSStackView alloc] initWithFrame:NSZeroRect];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.orientation = NSUserInterfaceLayoutOrientationVertical;
    container.alignment = NSLayoutAttributeLeading;
    container.spacing = 10.0;
    container.edgeInsets = NSEdgeInsetsMake(0.0, 0.0, 0.0, 0.0);

    [container addArrangedSubview:[self inspectorSectionLabel:@"Prefab"]];

    self.shapePrimaryLabel = [self inspectorBodyLabel:@"Segments"];
    [container addArrangedSubview:self.shapePrimaryLabel];

    NSStackView* primaryRow = [[NSStackView alloc] initWithFrame:NSZeroRect];
    primaryRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    primaryRow.alignment = NSLayoutAttributeCenterY;
    primaryRow.spacing = 8.0;

    self.shapePrimaryValueLabel = [self inspectorBodyLabel:@"12"];
    self.shapePrimaryValueLabel.alignment = NSTextAlignmentRight;
    [self.shapePrimaryValueLabel.widthAnchor constraintEqualToConstant:56.0].active = YES;

    self.shapePrimaryStepper = [[NSStepper alloc] initWithFrame:NSZeroRect];
    self.shapePrimaryStepper.valueWraps = NO;
    self.shapePrimaryStepper.target = self;
    self.shapePrimaryStepper.action = @selector(shapePrimarySettingChanged:);

    [primaryRow addArrangedSubview:self.shapePrimaryValueLabel];
    [primaryRow addArrangedSubview:self.shapePrimaryStepper];
    [container addArrangedSubview:primaryRow];

    self.shapeSecondaryLabel = [self inspectorBodyLabel:@"Thickness"];
    [container addArrangedSubview:self.shapeSecondaryLabel];

    NSStackView* secondaryHeader = [[NSStackView alloc] initWithFrame:NSZeroRect];
    secondaryHeader.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    secondaryHeader.alignment = NSLayoutAttributeCenterY;
    secondaryHeader.spacing = 8.0;

    self.shapeSecondaryValueLabel = [self inspectorBodyLabel:@"30%"];
    self.shapeSecondaryValueLabel.alignment = NSTextAlignmentRight;
    [self.shapeSecondaryValueLabel.widthAnchor constraintEqualToConstant:56.0].active = YES;

    [secondaryHeader addArrangedSubview:self.shapeSecondaryValueLabel];
    [container addArrangedSubview:secondaryHeader];

    self.shapeSecondarySlider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    self.shapeSecondarySlider.minValue = 10.0;
    self.shapeSecondarySlider.maxValue = 90.0;
    self.shapeSecondarySlider.continuous = NO;
    self.shapeSecondarySlider.target = self;
    self.shapeSecondarySlider.action = @selector(shapeSecondarySettingChanged:);
    [container addArrangedSubview:self.shapeSecondarySlider];

    self.shapeCollapseButton = [NSButton buttonWithTitle:@"Collapse To BSP" target:self action:@selector(collapseEditingPrefab:)];
    self.shapeCollapseButton.bezelStyle = NSBezelStyleRounded;
    [container addArrangedSubview:self.shapeCollapseButton];

    NSTextField* hintLabel = [NSTextField labelWithString:@"Adjust values live. Collapse to convert the prefab into plain BSP."];
    hintLabel.textColor = [NSColor secondaryLabelColor];
    hintLabel.font = [NSFont systemFontOfSize:11.0];
    hintLabel.maximumNumberOfLines = 2;
    [container addArrangedSubview:hintLabel];

    self.prefabInspectorView = container;
}

- (void)buildLightInspectorView {
    if (self.lightInspectorView) {
        return;
    }

    NSStackView* container = [[NSStackView alloc] initWithFrame:NSZeroRect];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.orientation = NSUserInterfaceLayoutOrientationVertical;
    container.alignment = NSLayoutAttributeLeading;
    container.spacing = 10.0;

    [container addArrangedSubview:[self inspectorSectionLabel:@"Light"]];

    self.lightNameLabel = [self inspectorBodyLabel:@"Light"];
    [container addArrangedSubview:self.lightNameLabel];

    [container addArrangedSubview:[self inspectorSectionLabel:@"Type"]];
    self.lightTypePopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.lightTypePopUp addItemsWithTitles:@[ @"Point", @"Spot" ]];
    [[self.lightTypePopUp itemAtIndex:0] setTag:UI_LIGHT_POINT];
    [[self.lightTypePopUp itemAtIndex:1] setTag:UI_LIGHT_SPOT];
    self.lightTypePopUp.target = self;
    self.lightTypePopUp.action = @selector(lightTypeChanged:);
    [container addArrangedSubview:self.lightTypePopUp];

    [container addArrangedSubview:[self inspectorSectionLabel:@"Color"]];
    self.lightColorWell = [[NSColorWell alloc] initWithFrame:NSMakeRect(0.0, 0.0, 64.0, 28.0)];
    self.lightColorWell.target = self;
    self.lightColorWell.action = @selector(lightColorChanged:);
    [container addArrangedSubview:self.lightColorWell];

    [container addArrangedSubview:[self inspectorSectionLabel:@"Position"]];
    self.lightPositionLabel = [self inspectorBodyLabel:@"0, 0, 0"];
    [container addArrangedSubview:self.lightPositionLabel];

    [container addArrangedSubview:[self inspectorSectionLabel:@"Intensity"]];
    self.lightIntensityValueLabel = [self inspectorBodyLabel:@"10.0"];
    [container addArrangedSubview:self.lightIntensityValueLabel];
    self.lightIntensitySlider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    self.lightIntensitySlider.minValue = 0.1;
    self.lightIntensitySlider.maxValue = 50.0;
    self.lightIntensitySlider.continuous = NO;
    self.lightIntensitySlider.target = self;
    self.lightIntensitySlider.action = @selector(lightIntensityChanged:);
    [container addArrangedSubview:self.lightIntensitySlider];

    [container addArrangedSubview:[self inspectorSectionLabel:@"Range"]];
    self.lightRangeValueLabel = [self inspectorBodyLabel:@"512"];
    [container addArrangedSubview:self.lightRangeValueLabel];
    self.lightRangeSlider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    self.lightRangeSlider.minValue = 64.0;
    self.lightRangeSlider.maxValue = 4096.0;
    self.lightRangeSlider.continuous = NO;
    self.lightRangeSlider.target = self;
    self.lightRangeSlider.action = @selector(lightRangeChanged:);
    [container addArrangedSubview:self.lightRangeSlider];

    self.lightSpotSettingsView = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.lightSpotSettingsView.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.lightSpotSettingsView.alignment = NSLayoutAttributeLeading;
    self.lightSpotSettingsView.spacing = 10.0;

    [self.lightSpotSettingsView addArrangedSubview:[self inspectorSectionLabel:@"Spot Inner Cone"]];
    self.lightSpotInnerValueLabel = [self inspectorBodyLabel:@"18"];
    [self.lightSpotSettingsView addArrangedSubview:self.lightSpotInnerValueLabel];
    self.lightSpotInnerSlider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    self.lightSpotInnerSlider.minValue = 1.0;
    self.lightSpotInnerSlider.maxValue = 89.0;
    self.lightSpotInnerSlider.continuous = NO;
    self.lightSpotInnerSlider.target = self;
    self.lightSpotInnerSlider.action = @selector(lightSpotInnerChanged:);
    [self.lightSpotSettingsView addArrangedSubview:self.lightSpotInnerSlider];

    [self.lightSpotSettingsView addArrangedSubview:[self inspectorSectionLabel:@"Spot Outer Cone"]];
    self.lightSpotOuterValueLabel = [self inspectorBodyLabel:@"28"];
    [self.lightSpotSettingsView addArrangedSubview:self.lightSpotOuterValueLabel];
    self.lightSpotOuterSlider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    self.lightSpotOuterSlider.minValue = 1.0;
    self.lightSpotOuterSlider.maxValue = 89.0;
    self.lightSpotOuterSlider.continuous = NO;
    self.lightSpotOuterSlider.target = self;
    self.lightSpotOuterSlider.action = @selector(lightSpotOuterChanged:);
    [self.lightSpotSettingsView addArrangedSubview:self.lightSpotOuterSlider];
    [container addArrangedSubview:self.lightSpotSettingsView];

    self.lightEnabledButton = [NSButton checkboxWithTitle:@"Enabled" target:self action:@selector(lightEnabledChanged:)];
    self.lightCastShadowsButton = [NSButton checkboxWithTitle:@"Cast Shadows" target:self action:@selector(lightCastShadowsChanged:)];
    [container addArrangedSubview:self.lightEnabledButton];
    [container addArrangedSubview:self.lightCastShadowsButton];

    self.lightInspectorView = container;
}

- (void)buildFaceTextureInspectorView {
    if (self.faceTextureInspectorView) {
        return;
    }

    NSStackView* container = [[NSStackView alloc] initWithFrame:NSZeroRect];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.orientation = NSUserInterfaceLayoutOrientationVertical;
    container.alignment = NSLayoutAttributeLeading;
    container.spacing = 10.0;

    [container addArrangedSubview:[self inspectorSectionLabel:@"Face Texture"]];

    self.faceTextureMaterialLabel = [self inspectorBodyLabel:@"Material: -"];
    self.faceTextureMaterialLabel.textColor = [NSColor secondaryLabelColor];
    [container addArrangedSubview:self.faceTextureMaterialLabel];

    [container addArrangedSubview:[self inspectorLabeledFieldRow:@"U Scale" field:&_faceTextureUScaleField action:@selector(faceTextureTransformChanged:)]];
    [container addArrangedSubview:[self inspectorLabeledFieldRow:@"V Scale" field:&_faceTextureVScaleField action:@selector(faceTextureTransformChanged:)]];
    [container addArrangedSubview:[self inspectorLabeledFieldRow:@"U Offset" field:&_faceTextureUOffsetField action:@selector(faceTextureTransformChanged:)]];
    [container addArrangedSubview:[self inspectorLabeledFieldRow:@"V Offset" field:&_faceTextureVOffsetField action:@selector(faceTextureTransformChanged:)]];
    [container addArrangedSubview:[self inspectorLabeledFieldRow:@"Rotation" field:&_faceTextureRotationField action:@selector(faceTextureRotationChanged:)]];

    NSStackView* flipRow = [[NSStackView alloc] initWithFrame:NSZeroRect];
    flipRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    flipRow.alignment = NSLayoutAttributeCenterY;
    flipRow.spacing = 8.0;
    [flipRow addArrangedSubview:[self inspectorActionButton:@"Flip U" action:@selector(faceTextureFlipPressed:) tag:0]];
    [flipRow addArrangedSubview:[self inspectorActionButton:@"Flip V" action:@selector(faceTextureFlipPressed:) tag:1]];
    [container addArrangedSubview:flipRow];

    NSStackView* justifyRowA = [[NSStackView alloc] initWithFrame:NSZeroRect];
    justifyRowA.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    justifyRowA.alignment = NSLayoutAttributeCenterY;
    justifyRowA.spacing = 8.0;
    [justifyRowA addArrangedSubview:[self inspectorActionButton:@"Fit" action:@selector(faceTextureJustifyPressed:) tag:VmfTextureJustifyFit]];
    [justifyRowA addArrangedSubview:[self inspectorActionButton:@"Left" action:@selector(faceTextureJustifyPressed:) tag:VmfTextureJustifyLeft]];
    [justifyRowA addArrangedSubview:[self inspectorActionButton:@"Right" action:@selector(faceTextureJustifyPressed:) tag:VmfTextureJustifyRight]];
    [container addArrangedSubview:justifyRowA];

    NSStackView* justifyRowB = [[NSStackView alloc] initWithFrame:NSZeroRect];
    justifyRowB.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    justifyRowB.alignment = NSLayoutAttributeCenterY;
    justifyRowB.spacing = 8.0;
    [justifyRowB addArrangedSubview:[self inspectorActionButton:@"Top" action:@selector(faceTextureJustifyPressed:) tag:VmfTextureJustifyTop]];
    [justifyRowB addArrangedSubview:[self inspectorActionButton:@"Bottom" action:@selector(faceTextureJustifyPressed:) tag:VmfTextureJustifyBottom]];
    [justifyRowB addArrangedSubview:[self inspectorActionButton:@"Center" action:@selector(faceTextureJustifyPressed:) tag:VmfTextureJustifyCenter]];
    [container addArrangedSubview:justifyRowB];

    NSTextField* hintLabel = [NSTextField labelWithString:@"Negative scale flips the texture too. Use Fit to map one full texture across the face."];
    hintLabel.textColor = [NSColor secondaryLabelColor];
    hintLabel.font = [NSFont systemFontOfSize:11.0];
    hintLabel.maximumNumberOfLines = 3;
    [container addArrangedSubview:hintLabel];

    self.faceTextureInspectorView = container;
}

- (void)buildGenericInspectorView {
    if (self.genericInspectorView) {
        return;
    }

    NSStackView* container = [[NSStackView alloc] initWithFrame:NSZeroRect];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.orientation = NSUserInterfaceLayoutOrientationVertical;
    container.alignment = NSLayoutAttributeLeading;
    container.spacing = 10.0;

    [container addArrangedSubview:[self inspectorSectionLabel:@"Selection"]];
    self.genericInspectorDetailsLabel = [self inspectorBodyLabel:@"No selection"];
    self.genericInspectorDetailsLabel.textColor = [NSColor secondaryLabelColor];
    [container addArrangedSubview:self.genericInspectorDetailsLabel];

    self.genericInspectorView = container;
}

- (void)buildInspectorUI {
    if (self.inspectorPanel) {
        return;
    }

    self.inspectorPanel = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    self.inspectorPanel.translatesAutoresizingMaskIntoConstraints = NO;
    self.inspectorPanel.material = NSVisualEffectMaterialHUDWindow;
    self.inspectorPanel.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    self.inspectorPanel.state = NSVisualEffectStateActive;
    self.inspectorPanel.wantsLayer = YES;
    self.inspectorPanel.layer.cornerRadius = 8.0;
    self.inspectorPanel.layer.masksToBounds = YES;

    self.inspectorStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.inspectorStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.inspectorStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.inspectorStack.alignment = NSLayoutAttributeLeading;
    self.inspectorStack.spacing = 12.0;
    self.inspectorStack.edgeInsets = NSEdgeInsetsMake(14.0, 14.0, 14.0, 14.0);

    self.inspectorTitleLabel = [NSTextField labelWithString:@"Inspector"];
    self.inspectorTitleLabel.font = [NSFont systemFontOfSize:16.0 weight:NSFontWeightSemibold];
    self.inspectorSubtitleLabel = [NSTextField labelWithString:@"Select a brush, prefab, or light to edit it."];
    self.inspectorSubtitleLabel.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightRegular];
    self.inspectorSubtitleLabel.textColor = [NSColor secondaryLabelColor];
    self.inspectorSubtitleLabel.maximumNumberOfLines = 2;

    [self buildShapeSettingsPanel];
    [self buildLightInspectorView];
    [self buildFaceTextureInspectorView];
    [self buildGenericInspectorView];

    [self.inspectorStack addArrangedSubview:self.inspectorTitleLabel];
    [self.inspectorStack addArrangedSubview:self.inspectorSubtitleLabel];
    [self.inspectorStack addArrangedSubview:self.prefabInspectorView];
    [self.inspectorStack addArrangedSubview:self.lightInspectorView];
    [self.inspectorStack addArrangedSubview:self.faceTextureInspectorView];
    [self.inspectorStack addArrangedSubview:self.genericInspectorView];

    [self.inspectorPanel addSubview:self.inspectorStack];
    [self.rootView addSubview:self.inspectorPanel];

    [NSLayoutConstraint activateConstraints:@[
        [self.inspectorPanel.trailingAnchor constraintEqualToAnchor:self.rootView.trailingAnchor constant:-12.0],
        [self.inspectorPanel.topAnchor constraintEqualToAnchor:self.verticalSplitView.topAnchor],
        [self.inspectorPanel.bottomAnchor constraintEqualToAnchor:self.verticalSplitView.bottomAnchor],
        [self.inspectorPanel.widthAnchor constraintEqualToConstant:300.0],
        [self.inspectorStack.leadingAnchor constraintEqualToAnchor:self.inspectorPanel.leadingAnchor],
        [self.inspectorStack.trailingAnchor constraintEqualToAnchor:self.inspectorPanel.trailingAnchor],
        [self.inspectorStack.topAnchor constraintEqualToAnchor:self.inspectorPanel.topAnchor],
        [self.inspectorStack.bottomAnchor constraintLessThanOrEqualToAnchor:self.inspectorPanel.bottomAnchor],
    ]];
}

- (BOOL)applyShapeTool:(VmfViewportEditorTool)tool
                bounds:(Bounds3)bounds
                upAxis:(VmfBrushAxis)upAxis
               runAxis:(VmfBrushAxis)runAxis
          primaryValue:(NSInteger)primaryValue
        secondaryValue:(CGFloat)secondaryValue
        outEntityIndex:(size_t*)outEntityIndex
         outSolidIndex:(size_t*)outSolidIndex
           errorBuffer:(char*)errorBuffer
      errorBufferSize:(size_t)errorBufferSize {
    switch (tool) {
        case VmfViewportEditorToolCylinder:
            return vmf_scene_add_cylinder_brush(&_scene,
                                                bounds,
                                                upAxis,
                                                (size_t)primaryValue,
                                                self.brushMaterialName.UTF8String,
                                                outEntityIndex,
                                                outSolidIndex,
                                                errorBuffer,
                                                errorBufferSize);
        case VmfViewportEditorToolArch:
            return vmf_scene_add_arch_brushes(&_scene,
                                              bounds,
                                              upAxis,
                                              runAxis,
                                              (size_t)primaryValue,
                                              secondaryValue / 100.0f,
                                              self.brushMaterialName.UTF8String,
                                              outEntityIndex,
                                              outSolidIndex,
                                              errorBuffer,
                                              errorBufferSize);
        case VmfViewportEditorToolStairs: {
            NSInteger stepCount = MAX(2, primaryValue);
            int widthAxis = 3 - (int)upAxis - (int)runAxis;
            float runMin = bounds.min.raw[runAxis];
            float runMax = bounds.max.raw[runAxis];
            float upMin = bounds.min.raw[upAxis];
            float upMax = bounds.max.raw[upAxis];
            float runSize = runMax - runMin;
            float upSize = upMax - upMin;
            float stepRun = runSize / (float)stepCount;
            float stepRise = upSize / (float)stepCount;
            size_t entityIndex = 0;
            size_t solidIndex = 0;
            for (NSInteger stepIndex = 0; stepIndex < stepCount; ++stepIndex) {
                Bounds3 stepBounds = bounds;
                stepBounds.min.raw[runAxis] = runMin + stepRun * (float)stepIndex;
                stepBounds.max.raw[runAxis] = runMin + stepRun * (float)(stepIndex + 1);
                stepBounds.min.raw[upAxis] = upMin;
                stepBounds.max.raw[upAxis] = upMin + stepRise * (float)(stepIndex + 1);
                stepBounds.min.raw[widthAxis] = bounds.min.raw[widthAxis];
                stepBounds.max.raw[widthAxis] = bounds.max.raw[widthAxis];
                if (!vmf_scene_add_block_brush(&_scene,
                                               stepBounds,
                                               self.brushMaterialName.UTF8String,
                                               &entityIndex,
                                               &solidIndex,
                                               errorBuffer,
                                               errorBufferSize)) {
                    return NO;
                }
            }
            if (outEntityIndex) {
                *outEntityIndex = entityIndex;
            }
            if (outSolidIndex) {
                *outSolidIndex = solidIndex;
            }
            return YES;
        }
        default:
            snprintf(errorBuffer, errorBufferSize, "unsupported shape tool");
            return NO;
    }
}

- (BOOL)rebuildPrefab:(ProceduralShapePrefab*)prefab errorBuffer:(char*)errorBuffer size:(size_t)errorBufferSize {
    if (!prefab) {
        snprintf(errorBuffer, errorBufferSize, "missing prefab");
        return NO;
    }

    NSUInteger prefabIndex = [self.currentPrefabs indexOfObjectIdenticalTo:prefab];
    NSArray<ProceduralShapePrefab*>* prefabSnapshot = [[NSArray alloc] initWithArray:self.currentPrefabs copyItems:YES];
    VmfScene sceneSnapshot;
    memset(&sceneSnapshot, 0, sizeof(sceneSnapshot));
    if (!vmf_scene_clone(&_scene, &sceneSnapshot, errorBuffer, errorBufferSize)) {
        return NO;
    }

    for (size_t offset = prefab.solidCount; offset > 0; --offset) {
        if (!vmf_scene_delete_solid(&_scene, prefab.entityIndex, prefab.startSolidIndex + offset - 1, errorBuffer, errorBufferSize)) {
            vmf_scene_free(&_scene);
            self.scene = sceneSnapshot;
            self.currentPrefabs = [NSMutableArray arrayWithArray:prefabSnapshot];
            self.editingPrefab = prefabIndex != NSNotFound && prefabIndex < self.currentPrefabs.count ? self.currentPrefabs[prefabIndex] : nil;
            return NO;
        }
    }
    [self shiftPrefabIndicesInEntity:prefab.entityIndex startingAtSolidIndex:prefab.startSolidIndex + prefab.solidCount delta:-((NSInteger)prefab.solidCount) excludingPrefab:prefab];

    size_t entityIndex = 0;
    size_t solidIndex = 0;
    if (![self applyShapeTool:prefab.tool
                       bounds:prefab.bounds
                       upAxis:prefab.upAxis
                      runAxis:prefab.runAxis
                 primaryValue:prefab.primaryValue
               secondaryValue:prefab.secondaryValue
               outEntityIndex:&entityIndex
                outSolidIndex:&solidIndex
                  errorBuffer:errorBuffer
             errorBufferSize:errorBufferSize]) {
           vmf_scene_free(&_scene);
           self.scene = sceneSnapshot;
           self.currentPrefabs = [NSMutableArray arrayWithArray:prefabSnapshot];
           self.editingPrefab = prefabIndex != NSNotFound && prefabIndex < self.currentPrefabs.count ? self.currentPrefabs[prefabIndex] : nil;
        return NO;
    }

        vmf_scene_free(&sceneSnapshot);

    prefab.entityIndex = entityIndex;
    prefab.solidCount = [self solidCountForShapeTool:prefab.tool primaryValue:prefab.primaryValue];
    prefab.startSolidIndex = solidIndex + 1 - prefab.solidCount;
    self.hasSelection = YES;
    self.selectedEntityIndex = entityIndex;
    self.selectedSolidIndex = solidIndex;
    self.hasFaceSelection = NO;
    self.selectedSideIndex = 0;
    [self rebuildMeshFromScene];
    return YES;
}

- (VmfEntity*)selectedLightEntity {
    if (![self selectionIsPointEntity] || self.selectedEntityIndex >= self.scene.entityCount) {
        return NULL;
    }
    return &_scene.entities[self.selectedEntityIndex];
}

- (void)refreshShapeSettingsPanel {
    [self buildShapeSettingsPanel];
    self.prefabInspectorView.hidden = self.editingPrefab == nil;
    if (!self.editingPrefab) {
        return;
    }

    self.shapePrimaryLabel.stringValue = [self shapePrimaryLabelForTool:self.editingPrefab.tool];
    self.shapePrimaryStepper.minValue = [self minimumShapePrimaryValueForTool:self.editingPrefab.tool];
    self.shapePrimaryStepper.maxValue = [self maximumShapePrimaryValueForTool:self.editingPrefab.tool];
    self.shapePrimaryStepper.integerValue = self.editingPrefab.primaryValue;
    self.shapePrimaryValueLabel.stringValue = [NSString stringWithFormat:@"%ld", (long)self.editingPrefab.primaryValue];

    BOOL showSecondary = [self toolHasSecondaryShapeSetting:self.editingPrefab.tool];
    self.shapeSecondaryLabel.hidden = !showSecondary;
    self.shapeSecondaryValueLabel.hidden = !showSecondary;
    self.shapeSecondarySlider.hidden = !showSecondary;
    if (showSecondary) {
        self.shapeSecondaryLabel.stringValue = [self shapeSecondaryLabelForTool:self.editingPrefab.tool];
        self.shapeSecondarySlider.doubleValue = self.editingPrefab.secondaryValue;
        self.shapeSecondaryValueLabel.stringValue = [NSString stringWithFormat:@"%.0f%%", self.editingPrefab.secondaryValue];
    }
}

- (void)refreshLightInspector {
    [self buildLightInspectorView];

    VmfEntity* entity = [self selectedLightEntity];
    self.lightInspectorView.hidden = entity == NULL;
    if (entity == NULL) {
        return;
    }

    NSString* displayName = entity->name[0] != '\0'
        ? [NSString stringWithUTF8String:entity->name]
        : (entity->targetname[0] != '\0' ? [NSString stringWithUTF8String:entity->targetname] : @"Light");
    BOOL isSpotLight = entity->lightType == UI_LIGHT_SPOT;
    self.lightNameLabel.stringValue = displayName;
    [self.lightTypePopUp selectItemWithTag:entity->lightType == UI_LIGHT_SPOT ? UI_LIGHT_SPOT : UI_LIGHT_POINT];
    self.lightColorWell.color = [NSColor colorWithCalibratedRed:entity->color.raw[0]
                                                         green:entity->color.raw[1]
                                                          blue:entity->color.raw[2]
                                                         alpha:1.0];
    self.lightPositionLabel.stringValue = [NSString stringWithFormat:@"%.0f, %.0f, %.0f",
                                           entity->position.raw[0],
                                           entity->position.raw[1],
                                           entity->position.raw[2]];
    self.lightIntensitySlider.doubleValue = entity->intensity;
    self.lightIntensityValueLabel.stringValue = [NSString stringWithFormat:@"%.2f", entity->intensity];
    self.lightRangeSlider.doubleValue = entity->range;
    self.lightRangeValueLabel.stringValue = [NSString stringWithFormat:@"%.0f", entity->range];
    self.lightSpotInnerSlider.doubleValue = entity->spotInnerDegrees;
    self.lightSpotOuterSlider.minValue = entity->spotInnerDegrees;
    self.lightSpotOuterSlider.doubleValue = fmax(entity->spotOuterDegrees, entity->spotInnerDegrees);
    self.lightSpotInnerValueLabel.stringValue = [NSString stringWithFormat:@"%.1f deg", entity->spotInnerDegrees];
    self.lightSpotOuterValueLabel.stringValue = [NSString stringWithFormat:@"%.1f deg", fmax(entity->spotOuterDegrees, entity->spotInnerDegrees)];
    self.lightSpotSettingsView.hidden = !isSpotLight;
    self.lightEnabledButton.state = entity->enabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.lightCastShadowsButton.state = entity->castShadows ? NSControlStateValueOn : NSControlStateValueOff;
}

- (BOOL)selectionHasEditableFaceTexture {
    return self.hasSelection &&
        self.hasFaceSelection &&
        !self.editingPrefab &&
        ![self selectionIsPointEntity] &&
        self.selectedEntityIndex < self.scene.entityCount &&
        self.selectedSolidIndex < self.scene.entities[self.selectedEntityIndex].solidCount &&
        self.selectedSideIndex < self.scene.entities[self.selectedEntityIndex].solids[self.selectedSolidIndex].sideCount;
}

- (const VmfSide*)selectedFaceSide {
    if (![self selectionHasEditableFaceTexture]) {
        return NULL;
    }
    return &self.scene.entities[self.selectedEntityIndex].solids[self.selectedSolidIndex].sides[self.selectedSideIndex];
}

- (void)defaultTextureAxesForSide:(const VmfSide*)side uAxis:(Vec3*)outUAxis vAxis:(Vec3*)outVAxis {
    Vec3 edgeA = vec3_sub(side->points[1], side->points[0]);
    Vec3 edgeB = vec3_sub(side->points[2], side->points[0]);
    Vec3 normal = vec3_normalize(vec3_cross(edgeA, edgeB));
    Vec3 worldUp = vec3_make(0.0f, 0.0f, 1.0f);
    float dotUp = vec3_dot(normal, worldUp);
    if (fabsf(dotUp) >= 0.999f) {
        *outUAxis = vec3_make(1.0f, 0.0f, 0.0f);
        *outVAxis = vec3_make(0.0f, dotUp > 0.0f ? -1.0f : 1.0f, 0.0f);
        return;
    }

    Vec3 skyOnFace = vec3_normalize(vec3_sub(worldUp, vec3_scale(normal, dotUp)));
    *outVAxis = vec3_make(-skyOnFace.raw[0], -skyOnFace.raw[1], -skyOnFace.raw[2]);
    *outUAxis = vec3_normalize(vec3_cross(normal, skyOnFace));
}

- (float)textureRotationDegreesForSide:(const VmfSide*)side {
    Vec3 defaultU = vec3_make(1.0f, 0.0f, 0.0f);
    Vec3 defaultV = vec3_make(0.0f, -1.0f, 0.0f);
    Vec3 currentU = side->uaxis;
    Vec3 edgeA = vec3_sub(side->points[1], side->points[0]);
    Vec3 edgeB = vec3_sub(side->points[2], side->points[0]);
    Vec3 normal = vec3_normalize(vec3_cross(edgeA, edgeB));
    float sinAngle;
    float cosAngle;

    [self defaultTextureAxesForSide:side uAxis:&defaultU vAxis:&defaultV];
    (void)defaultV;
    if (vec3_length(currentU) < 1e-5f || vec3_length(normal) < 1e-5f) {
        return 0.0f;
    }
    currentU = vec3_normalize(currentU);
    defaultU = vec3_normalize(defaultU);
    sinAngle = vec3_dot(normal, vec3_cross(defaultU, currentU));
    cosAngle = fmaxf(fminf(vec3_dot(defaultU, currentU), 1.0f), -1.0f);
    return atan2f(sinAngle, cosAngle) * 180.0f / (float)M_PI;
}

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

    const VmfSide* side = [self selectedFaceSide];
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
    self.faceTextureRotationField.stringValue = [NSString stringWithFormat:@"%.2f", [self textureRotationDegreesForSide:side]];
}

- (void)refreshGenericInspector {
    [self buildGenericInspectorView];

    NSString* details = @"Select a brush, prefab, or light to edit it here.";
    if (self.editingPrefab) {
        details = [NSString stringWithFormat:@"Prefab with %zu solids. Use the controls above to regenerate it.", self.editingPrefab.solidCount];
    } else if ([self selectionIsPointEntity] && self.selectedEntityIndex < self.scene.entityCount) {
        const VmfEntity* entity = &self.scene.entities[self.selectedEntityIndex];
        details = [NSString stringWithFormat:@"%@ light. %s, %s.",
                   light_type_label(entity->lightType),
                   entity->enabled ? "enabled" : "disabled",
                   entity->castShadows ? "casts shadows" : "no shadows"];
    } else if (self.hasSelection && self.selectedEntityIndex < self.scene.entityCount) {
        const VmfEntity* entity = &self.scene.entities[self.selectedEntityIndex];
        details = [NSString stringWithFormat:@"Brush selection in entity %d with %zu solids.", entity->id, entity->solidCount];
    }

    self.genericInspectorDetailsLabel.stringValue = details;
}

- (void)refreshInspector {
    [self buildInspectorUI];

    NSString* title = @"Inspector";
    NSString* subtitle = @"Select a brush, prefab, or light to edit it.";
    if (self.editingPrefab) {
        title = [self shapeSettingsPanelTitleForTool:self.editingPrefab.tool];
        subtitle = @"Procedural prefab settings are docked here now.";
    } else if ([self selectionIsPointEntity]) {
        title = @"Light";
        subtitle = @"Point and spot light properties update the scene and renderer live.";
    } else if (self.hasSelection) {
        title = self.hasFaceSelection ? @"Face" : @"Brush";
        subtitle = self.hasFaceSelection
            ? @"Texture mapping for the selected face is editable here."
            : @"Generic selection details live here. More entity types can extend this inspector.";
    }

    self.inspectorTitleLabel.stringValue = title;
    self.inspectorSubtitleLabel.stringValue = subtitle;
    [self refreshShapeSettingsPanel];
    [self refreshLightInspector];
    [self refreshFaceTextureInspector];
    [self refreshGenericInspector];
}

- (void)commitImmediateLightEditWithEntry:(SceneHistoryEntry*)entry label:(NSString*)label {
    if (!entry) {
        return;
    }
    [self pushUndoEntry:entry];
    [self markDocumentChangedWithLabel:label];
    [self rebuildMeshFromScene];
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

    const VmfSide* side = [self selectedFaceSide];
    float targetDegrees;
    float deltaDegrees;

    if (side == NULL) {
        return;
    }

    targetDegrees = (float)self.faceTextureRotationField.doubleValue;
    deltaDegrees = targetDegrees - [self textureRotationDegreesForSide:side];
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
    const VmfSide* side = [self selectedFaceSide];
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

- (void)lightColorChanged:(id)sender {
    (void)sender;
    VmfEntity* entity = [self selectedLightEntity];
    if (entity == NULL) {
        return;
    }

    SceneHistoryEntry* entry = [self captureHistoryEntry];
    NSColor* color = [self.lightColorWell.color colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]];
    entity->color = vec3_make((float)color.redComponent, (float)color.greenComponent, (float)color.blueComponent);
    [self commitImmediateLightEditWithEntry:entry label:@"Edit Light Color"];
}

- (void)lightIntensityChanged:(id)sender {
    (void)sender;
    VmfEntity* entity = [self selectedLightEntity];
    if (entity == NULL) {
        return;
    }

    SceneHistoryEntry* entry = [self captureHistoryEntry];
    entity->intensity = fmaxf((float)self.lightIntensitySlider.doubleValue, 0.1f);
    [self commitImmediateLightEditWithEntry:entry label:@"Edit Light Intensity"];
}

- (void)lightRangeChanged:(id)sender {
    (void)sender;
    VmfEntity* entity = [self selectedLightEntity];
    if (entity == NULL) {
        return;
    }

    SceneHistoryEntry* entry = [self captureHistoryEntry];
    entity->range = fmaxf((float)self.lightRangeSlider.doubleValue, 64.0f);
    [self commitImmediateLightEditWithEntry:entry label:@"Edit Light Range"];
}

- (void)lightTypeChanged:(id)sender {
    (void)sender;
    VmfEntity* entity = [self selectedLightEntity];
    if (entity == NULL) {
        return;
    }

    SceneHistoryEntry* entry = [self captureHistoryEntry];
    entity->lightType = (int)self.lightTypePopUp.selectedTag;
    if (entity->lightType == UI_LIGHT_SPOT) {
        entity->spotInnerDegrees = fmaxf(entity->spotInnerDegrees, 1.0f);
        entity->spotOuterDegrees = fmaxf(entity->spotOuterDegrees, entity->spotInnerDegrees + 1.0f);
    }
    [self commitImmediateLightEditWithEntry:entry label:@"Edit Light Type"];
}

- (void)lightSpotInnerChanged:(id)sender {
    (void)sender;
    VmfEntity* entity = [self selectedLightEntity];
    if (entity == NULL) {
        return;
    }

    SceneHistoryEntry* entry = [self captureHistoryEntry];
    entity->spotInnerDegrees = fmaxf((float)self.lightSpotInnerSlider.doubleValue, 1.0f);
    entity->spotOuterDegrees = fmaxf(entity->spotOuterDegrees, entity->spotInnerDegrees);
    [self commitImmediateLightEditWithEntry:entry label:@"Edit Spot Inner Cone"];
}

- (void)lightSpotOuterChanged:(id)sender {
    (void)sender;
    VmfEntity* entity = [self selectedLightEntity];
    if (entity == NULL) {
        return;
    }

    SceneHistoryEntry* entry = [self captureHistoryEntry];
    entity->spotOuterDegrees = fmaxf((float)self.lightSpotOuterSlider.doubleValue, entity->spotInnerDegrees);
    [self commitImmediateLightEditWithEntry:entry label:@"Edit Spot Outer Cone"];
}

- (void)lightEnabledChanged:(id)sender {
    (void)sender;
    VmfEntity* entity = [self selectedLightEntity];
    if (entity == NULL) {
        return;
    }

    SceneHistoryEntry* entry = [self captureHistoryEntry];
    entity->enabled = self.lightEnabledButton.state == NSControlStateValueOn;
    [self commitImmediateLightEditWithEntry:entry label:@"Toggle Light"];
}

- (void)lightCastShadowsChanged:(id)sender {
    (void)sender;
    VmfEntity* entity = [self selectedLightEntity];
    if (entity == NULL) {
        return;
    }

    SceneHistoryEntry* entry = [self captureHistoryEntry];
    entity->castShadows = self.lightCastShadowsButton.state == NSControlStateValueOn;
    [self commitImmediateLightEditWithEntry:entry label:@"Toggle Light Shadows"];
}

- (void)beginShapeSettingsSessionForTool:(VmfViewportEditorTool)tool
                                viewport:(VmfViewport*)viewport
                                  bounds:(Bounds3)bounds
                            historyLabel:(NSString*)historyLabel {
    if (!self.hasDocument) {
        [self newDocument:nil];
    }

    SceneHistoryEntry* entry = [self captureHistoryEntry];
    if (!entry) {
        return;
    }

    self.activeShapeSessionTool = tool;
    self.activeShapeSessionBounds = bounds;
    self.activeShapeSessionUpAxis = [self activeBrushAxis];
    self.activeShapeSessionRunAxis = [self runBrushAxisForViewport:viewport];
    ProceduralShapePrefab* prefab = [[ProceduralShapePrefab alloc] init];
    prefab.tool = tool;
    prefab.bounds = bounds;
    prefab.upAxis = self.activeShapeSessionUpAxis;
    prefab.runAxis = self.activeShapeSessionRunAxis;
    prefab.primaryValue = [self defaultShapePrimaryValueForTool:tool bounds:bounds];
    prefab.secondaryValue = [self defaultShapeSecondaryValueForTool:tool];
    prefab.solidCount = [self solidCountForShapeTool:tool primaryValue:prefab.primaryValue];
    prefab.historyLabel = historyLabel;

    char errorBuffer[256] = { 0 };
    size_t entityIndex = 0;
    size_t solidIndex = 0;
    if (![self applyShapeTool:prefab.tool
                       bounds:prefab.bounds
                       upAxis:prefab.upAxis
                      runAxis:prefab.runAxis
                 primaryValue:prefab.primaryValue
               secondaryValue:prefab.secondaryValue
               outEntityIndex:&entityIndex
                outSolidIndex:&solidIndex
                  errorBuffer:errorBuffer
             errorBufferSize:sizeof(errorBuffer)]) {
        [self showError:[NSString stringWithUTF8String:errorBuffer]];
        return;
    }

    prefab.entityIndex = entityIndex;
    prefab.startSolidIndex = solidIndex + 1 - prefab.solidCount;
    [self.currentPrefabs addObject:prefab];
    self.editingPrefab = prefab;
    [self pushUndoEntry:entry];
    [self markDocumentChangedWithLabel:historyLabel];
    [self rebuildMeshFromScene];
    [self refreshInspector];
}

- (void)shapePrimarySettingChanged:(id)sender {
    (void)sender;
    if (!self.editingPrefab) {
        return;
    }
    self.editingPrefab.primaryValue = self.shapePrimaryStepper.integerValue;
    [self refreshShapeSettingsPanel];

    char errorBuffer[256] = { 0 };
    if (![self rebuildPrefab:self.editingPrefab errorBuffer:errorBuffer size:sizeof(errorBuffer)]) {
        [self showError:[NSString stringWithUTF8String:errorBuffer]];
    }
}

- (void)shapeSecondarySettingChanged:(id)sender {
    (void)sender;
    if (!self.editingPrefab) {
        return;
    }
    self.editingPrefab.secondaryValue = self.shapeSecondarySlider.doubleValue;
    [self refreshShapeSettingsPanel];

    char errorBuffer[256] = { 0 };
    if (![self rebuildPrefab:self.editingPrefab errorBuffer:errorBuffer size:sizeof(errorBuffer)]) {
        [self showError:[NSString stringWithUTF8String:errorBuffer]];
    }
}

- (Vec3)clipPlaneNormalForViewportPlane:(VmfViewportPlane)plane start:(Vec3)start end:(Vec3)end {
    Vec3 lineDirection = vec3_sub(end, start);
    Vec3 extrudeAxis = vec3_make(0.0f, 0.0f, 1.0f);
    switch (plane) {
        case VmfViewportPlaneXZ:
            extrudeAxis = vec3_make(0.0f, 1.0f, 0.0f);
            break;
        case VmfViewportPlaneZY:
            extrudeAxis = vec3_make(1.0f, 0.0f, 0.0f);
            break;
        case VmfViewportPlaneXY:
        default:
            extrudeAxis = vec3_make(0.0f, 0.0f, 1.0f);
            break;
    }
    return vec3_normalize(vec3_cross(lineDirection, extrudeAxis));
}

- (BOOL)moveSelectedSolidByOffset:(Vec3)offset label:(NSString*)label {
    if (!self.hasSelection) {
        return NO;
    }

    SceneHistoryEntry* entry = [self captureHistoryEntry];
    if (!entry) {
        return NO;
    }

    char errorBuffer[256] = { 0 };
    if (!vmf_scene_translate_solid(&_scene, self.selectedEntityIndex, self.selectedSolidIndex, offset, self.textureLockEnabled ? 1 : 0, errorBuffer, sizeof(errorBuffer))) {
        [self showError:[NSString stringWithUTF8String:errorBuffer]];
        return NO;
    }

    [self pushUndoEntry:entry];
    [self markDocumentChangedWithLabel:label];
    [self rebuildMeshFromScene];
    return YES;
}

- (BOOL)moveSelectedVerticesAtIndices:(const size_t*)indices positions:(const Vec3*)positions count:(size_t)count commit:(BOOL)commit {
    (void)commit; // commits happen only in endVertexEditSession when the tool is exited
    if (!self.hasSelection || count == 0 || !_hasVertexEditSession) {
        return NO;
    }

    // Update draft positions unconditionally — never touch the actual brush.
    for (size_t i = 0; i < count; ++i) {
        if (indices[i] < _draftVertexCount) {
            _draftVertices[indices[i]] = positions[i];
        }
    }

    // Check validity — pure geometric convexity test directly on draft positions.
    // No brush modification; no plane-reconstruction edge cases.
    _draftIsValid = [self isDraftConvex];

    // Push wireframe preview to all viewports (2D overlay + 3D Metal lines).
    [self pushDraftOverlayToViewports];
    return _draftIsValid;
}

- (BOOL)moveSelectedEdgeFirstSideIndex:(size_t)firstSideIndex secondSideIndex:(size_t)secondSideIndex offset:(Vec3)offset commit:(BOOL)commit {
    if (!self.hasSelection) {
        return NO;
    }

    if (commit && !self.pendingHistoryEntry && vec3_length(offset) < 0.01f) {
        return NO;
    }

    if (![self beginPendingHistoryEntryWithLabel:@"Move Edge"]) {
        return NO;
    }

    char errorBuffer[256] = { 0 };
    if (!vmf_scene_move_solid_edge(&_scene,
                                   self.selectedEntityIndex,
                                   self.selectedSolidIndex,
                                   firstSideIndex,
                                   secondSideIndex,
                                   offset,
                                   errorBuffer,
                                   sizeof(errorBuffer))) {
        [self discardPendingHistoryEntry];
        [self showError:[NSString stringWithUTF8String:errorBuffer]];
        return NO;
    }

    [self rebuildMeshFromScene];
    if (commit) {
        [self commitPendingHistoryEntry];
    }
    return YES;
}

- (BOOL)clipSelectedSolidFrom:(Vec3)start to:(Vec3)end plane:(VmfViewportPlane)plane {
    if (!self.hasSelection) {
        return NO;
    }

    Vec3 planeNormal = [self clipPlaneNormalForViewportPlane:plane start:start end:end];
    if (vec3_length(planeNormal) < 1e-5f) {
        return NO;
    }

    SceneHistoryEntry* entry = [self captureHistoryEntry];
    if (!entry) {
        return NO;
    }

    char errorBuffer[256] = { 0 };
    size_t newSolidIndex = 0;
    if (!vmf_scene_split_solid_by_plane(&_scene,
                                        self.selectedEntityIndex,
                                        self.selectedSolidIndex,
                                        planeNormal,
                                        vec3_dot(planeNormal, start),
                                        (VmfClipKeepMode)self.clipMode,
                                        self.brushMaterialName.UTF8String,
                                        &newSolidIndex,
                                        errorBuffer,
                                        sizeof(errorBuffer))) {
        [self showError:[NSString stringWithUTF8String:errorBuffer]];
        return NO;
    }

    self.hasSelection = YES;
    self.hasFaceSelection = NO;
    self.selectedSideIndex = 0;
    [self pushUndoEntry:entry];
    [self markDocumentChangedWithLabel:self.clipMode == ViewerClipModeBoth ? @"Clip Brush" : (self.clipMode == ViewerClipModeA ? @"Clip Brush Keep A" : @"Clip Brush Keep B")];
    [self rebuildMeshFromScene];
    return YES;
}

- (void)buildMacUI {
    self.toolRail = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    self.toolRail.translatesAutoresizingMaskIntoConstraints = NO;
    self.toolRail.material = NSVisualEffectMaterialHUDWindow;
    self.toolRail.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    self.toolRail.state = NSVisualEffectStateActive;
    self.toolRail.wantsLayer = YES;
    self.toolRail.layer.cornerRadius = 8.0;
    self.toolRail.layer.masksToBounds = YES;

    self.toolRailStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.toolRailStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.toolRailStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.toolRailStack.alignment = NSLayoutAttributeCenterX;
    self.toolRailStack.spacing = 10.0;
    self.toolRailStack.edgeInsets = NSEdgeInsetsMake(10.0, 6.0, 10.0, 6.0);

    self.selectToolButton = [self toolRailButtonWithIcon:@"arrow_selector_tool" tooltip:@"Select Tool" action:@selector(setSelectTool:)];
    self.vertexToolButton = [self toolRailButtonWithIcon:@"polyline" tooltip:@"Vertex Tool" action:@selector(setVertexTool:)];
    self.blockToolButton = [self toolRailButtonWithIcon:@"crop_square" tooltip:@"Block Tool" action:@selector(setBlockTool:)];
    self.cylinderToolButton = [self toolRailButtonWithIcon:@"circle" tooltip:@"Cylinder Tool" action:@selector(setCylinderTool:)];
    self.rampToolButton = [self toolRailButtonWithIcon:@"change_history" tooltip:@"Ramp Tool" action:@selector(setRampTool:)];
    self.stairsToolButton = [self toolRailButtonWithIcon:@"stairs" tooltip:@"Stairs Tool" action:@selector(setStairsTool:)];
    self.archToolButton = [self toolRailButtonWithIcon:@"architecture" tooltip:@"Arch Tool" action:@selector(setArchTool:)];
    self.clipToolButton = [self toolRailButtonWithIcon:@"content_cut" tooltip:@"Clip Tool" action:@selector(setClipTool:)];

    [self.toolRailStack addArrangedSubview:self.selectToolButton];
    [self.toolRailStack addArrangedSubview:self.vertexToolButton];
    [self.toolRailStack addArrangedSubview:self.blockToolButton];
    [self.toolRailStack addArrangedSubview:self.cylinderToolButton];
    [self.toolRailStack addArrangedSubview:self.rampToolButton];
    [self.toolRailStack addArrangedSubview:self.stairsToolButton];
    [self.toolRailStack addArrangedSubview:self.archToolButton];
    [self.toolRailStack addArrangedSubview:self.clipToolButton];
    [self.toolRail addSubview:self.toolRailStack];
    [self.rootView addSubview:self.toolRail];

    self.controlBar = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    self.controlBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.controlBar.material = NSVisualEffectMaterialHUDWindow;
    self.controlBar.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    self.controlBar.state = NSVisualEffectStateActive;
    self.controlBar.wantsLayer = YES;
    self.controlBar.layer.cornerRadius = 8.0;
    self.controlBar.layer.masksToBounds = YES;

    self.controlStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.controlStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.controlStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    self.controlStack.alignment = NSLayoutAttributeCenterY;
    self.controlStack.spacing = 8.0;
    self.controlStack.detachesHiddenViews = YES;
    self.controlStack.distribution = NSStackViewDistributionFillProportionally;

    self.createMapButton = [self toolbarButtonWithIcon:@"add" text:@"New" action:@selector(newDocument:)];
    self.openButton = [self toolbarButtonWithIcon:@"folder_open" text:@"Open" action:@selector(openDocument:)];
    self.saveButton = [self toolbarButtonWithIcon:@"save" text:@"Save" action:@selector(saveDocument:)];
    self.undoButton = [self toolbarButtonWithIcon:@"undo" text:@"Undo" action:@selector(undoAction:)];
    self.redoButton = [self toolbarButtonWithIcon:@"redo" text:@"Redo" action:@selector(redoAction:)];
    self.duplicateButton = [self toolbarButtonWithIcon:@"content_copy" text:@"Duplicate" action:@selector(duplicateSelection:)];
    self.deleteButton = [self toolbarButtonWithIcon:@"delete" text:@"Delete" action:@selector(deleteSelection:)];

    self.renderControl = [[NSSegmentedControl alloc] initWithFrame:NSZeroRect];
    self.renderControl.segmentCount = 2;
    [self.renderControl setLabel:@"Wire" forSegment:0];
    [self.renderControl setLabel:@"Solid" forSegment:1];
    self.renderControl.trackingMode = NSSegmentSwitchTrackingSelectOne;
    self.renderControl.target = self;
    self.renderControl.action = @selector(renderControlChanged:);
    self.renderControl.segmentStyle = NSSegmentStyleRounded;

    self.materialPopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    // Items are populated dynamically by rebuildMaterialPopup; seed with fallbacks now
    [self.materialPopUp addItemsWithTitles:@[ @"dev_grid", @"nodraw", @"clip" ]];
    self.materialPopUp.target = self;
    self.materialPopUp.action = @selector(materialPresetChanged:);

    self.gridPopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.gridPopUp addItemsWithTitles:@[ @"1", @"2", @"4", @"8", @"16", @"32", @"64", @"128", @"256" ]];
    self.gridPopUp.target = self;
    self.gridPopUp.action = @selector(gridSizeChanged:);
    [self.gridPopUp setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.applyMaterialButton = [self toolbarButtonWithIcon:@"format_paint" text:@"Apply" action:@selector(applyMaterialToSelection:)];
    self.textureModeButton = [self toolbarButtonWithIcon:@"format_paint" text:@"Texture" action:@selector(toggleTextureApplicationMode:)];
    self.textureLockButton = [self toolbarButtonWithIcon:@"link" text:@"Tex Lock" action:@selector(toggleTextureLock:)];
    self.ignoreGroupsButton = [self toolbarButtonWithIcon:@"filter_none" text:@"Ignore Groups" action:@selector(toggleIgnoreGroupSelection:)];
    self.browseMaterialButton = [self toolbarButtonWithIcon:@"search" text:@"Browse" action:@selector(browseMaterials:)];

    [self.materialPopUp setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.renderLabel = [self toolbarBadgeLabelWithIcon:@"dehaze" text:@"Render"];
    self.gridLabel = [self toolbarBadgeLabelWithIcon:@"grid_view" text:@"Snap"];
    self.materialLabel = [self toolbarBadgeLabelWithIcon:@"wallpaper" text:@"Brush"];

    [self.controlStack addArrangedSubview:self.createMapButton];
    [self.controlStack addArrangedSubview:self.openButton];
    [self.controlStack addArrangedSubview:self.saveButton];
    [self.controlStack addArrangedSubview:self.undoButton];
    [self.controlStack addArrangedSubview:self.redoButton];
    [self.controlStack addArrangedSubview:self.duplicateButton];
    [self.controlStack addArrangedSubview:self.deleteButton];
    [self.controlStack addArrangedSubview:self.gridLabel];
    [self.controlStack addArrangedSubview:self.gridPopUp];
    [self.controlStack addArrangedSubview:self.renderLabel];
    [self.controlStack addArrangedSubview:self.renderControl];
    [self.controlStack addArrangedSubview:self.materialLabel];
    [self.controlStack addArrangedSubview:self.materialPopUp];
    [self.controlStack addArrangedSubview:self.textureModeButton];
    [self.controlStack addArrangedSubview:self.textureLockButton];
    [self.controlStack addArrangedSubview:self.ignoreGroupsButton];
    [self.controlStack addArrangedSubview:self.applyMaterialButton];
    [self.controlStack addArrangedSubview:self.browseMaterialButton];
    [self.controlBar addSubview:self.controlStack];
    [self.rootView addSubview:self.controlBar];

    self.emptyStateView = [[NSVisualEffectView alloc] initWithFrame:self.rootView.bounds];
    self.emptyStateView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.emptyStateView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    self.emptyStateView.material = NSVisualEffectMaterialSidebar;
    self.emptyStateView.state = NSVisualEffectStateActive;

    NSStackView* stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.spacing = 14.0;

    NSTextField* titleLabel = [NSTextField labelWithString:@"Open Or Create A VMF Map"];
    titleLabel.font = [NSFont systemFontOfSize:28.0 weight:NSFontWeightSemibold];
    titleLabel.textColor = NSColor.labelColor;

    self.emptyStateSubtitle = [NSTextField labelWithString:@"Choose a .slg file or drop a folder to recursively index every Sledgehammer scene inside it."];
    self.emptyStateSubtitle.font = [NSFont systemFontOfSize:14.0 weight:NSFontWeightRegular];
    self.emptyStateSubtitle.textColor = [NSColor secondaryLabelColor];
    self.emptyStateSubtitle.alignment = NSTextAlignmentCenter;
    self.emptyStateSubtitle.maximumNumberOfLines = 3;
    self.emptyStateSubtitle.preferredMaxLayoutWidth = 520.0;

    NSButton* emptyOpenButton = [NSButton buttonWithTitle:@"Open Scene Or Folder" target:self action:@selector(openDocument:)];
    emptyOpenButton.bezelStyle = NSBezelStyleRounded;
    emptyOpenButton.font = [NSFont systemFontOfSize:15.0 weight:NSFontWeightMedium];

    NSButton* emptyNewButton = [NSButton buttonWithTitle:@"New Blank Map" target:self action:@selector(newDocument:)];
    emptyNewButton.bezelStyle = NSBezelStyleRounded;
    emptyNewButton.font = [NSFont systemFontOfSize:15.0 weight:NSFontWeightMedium];

    NSTextField* hintLabel = [NSTextField labelWithString:@"Cmd+N creates a blank map. Cmd+O opens an existing VMF or folder."];
    hintLabel.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightRegular];
    hintLabel.textColor = [NSColor tertiaryLabelColor];
    hintLabel.alignment = NSTextAlignmentCenter;

    [stack addArrangedSubview:titleLabel];
    [stack addArrangedSubview:self.emptyStateSubtitle];
    [stack addArrangedSubview:emptyOpenButton];
    [stack addArrangedSubview:emptyNewButton];
    [stack addArrangedSubview:hintLabel];
    [self.emptyStateView addSubview:stack];
    [self.rootView addSubview:self.emptyStateView];

    [NSLayoutConstraint activateConstraints:@[
        [self.toolRail.leadingAnchor constraintEqualToAnchor:self.rootView.leadingAnchor constant:12.0],
        [self.toolRail.topAnchor constraintEqualToAnchor:self.verticalSplitView.topAnchor],
        [self.toolRail.bottomAnchor constraintEqualToAnchor:self.verticalSplitView.bottomAnchor],
        [self.toolRail.widthAnchor constraintEqualToConstant:56.0],
        [self.toolRailStack.leadingAnchor constraintEqualToAnchor:self.toolRail.leadingAnchor constant:6.0],
        [self.toolRailStack.trailingAnchor constraintEqualToAnchor:self.toolRail.trailingAnchor constant:-6.0],
        [self.toolRailStack.topAnchor constraintEqualToAnchor:self.toolRail.topAnchor constant:8.0],
        [self.controlBar.leadingAnchor constraintEqualToAnchor:self.rootView.leadingAnchor constant:16.0],
        [self.controlBar.trailingAnchor constraintLessThanOrEqualToAnchor:self.rootView.trailingAnchor constant:-16.0],
        [self.controlBar.topAnchor constraintEqualToAnchor:self.rootView.topAnchor constant:16.0],
        [self.controlStack.leadingAnchor constraintEqualToAnchor:self.controlBar.leadingAnchor constant:10.0],
        [self.controlStack.trailingAnchor constraintEqualToAnchor:self.controlBar.trailingAnchor constant:-10.0],
        [self.controlStack.topAnchor constraintEqualToAnchor:self.controlBar.topAnchor constant:6.0],
        [self.controlStack.bottomAnchor constraintEqualToAnchor:self.controlBar.bottomAnchor constant:-6.0],
        [stack.centerXAnchor constraintEqualToAnchor:self.emptyStateView.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.emptyStateView.centerYAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.emptyStateView.leadingAnchor constant:32.0],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:self.emptyStateView.trailingAnchor constant:-32.0],
    ]];

    self.controlBarHeightConstraint = [self.controlBar.heightAnchor constraintEqualToConstant:46.0];
    self.controlBarHeightConstraint.active = YES;
    [self buildInspectorUI];
    [self updateToolbarLayout];
}

- (void)updateChrome {
    [self updateHistoryMenuTitles];
    [self updateToolbarLayout];
    self.emptyStateView.hidden = self.hasDocument;
    self.saveButton.enabled = self.hasDocument;
    self.undoButton.enabled = self.undoStack.count > 0;
    self.redoButton.enabled = self.redoStack.count > 0;
    BOOL pointEntitySelection = [self selectionIsPointEntity];
    self.duplicateButton.enabled = self.hasSelection && !pointEntitySelection;
    self.deleteButton.enabled = self.hasSelection;
    self.textureModeButton.state = self.textureApplicationModeActive ? NSControlStateValueOn : NSControlStateValueOff;
    self.textureLockButton.state = self.textureLockEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.ignoreGroupsButton.state = self.ignoreGroupSelection ? NSControlStateValueOn : NSControlStateValueOff;
    self.applyMaterialButton.enabled = self.textureApplicationModeActive && self.hasSelection && !pointEntitySelection;
    [self refreshToolRailSelection];
    VmfViewport* viewport = self.activeViewport ? self.activeViewport : self.perspectiveViewport;
    [self.renderControl setSelectedSegment:viewport.renderMode == VmfViewportRenderModeShaded ? 1 : 0];
    self.renderControl.enabled = viewport.dimension == VmfViewportDimension3D;
    NSInteger gridItemIndex = [self.gridPopUp indexOfItemWithTitle:[NSString stringWithFormat:@"%.0f", self.gridSize]];
    if (gridItemIndex >= 0) {
        [self.gridPopUp selectItemAtIndex:gridItemIndex];
    }
    if (self.brushMaterialName.length > 0) {
        NSInteger matIdx = [self.materialPopUp indexOfItemWithTitle:self.brushMaterialName];
        if (matIdx >= 0) {
            [self.materialPopUp selectItemAtIndex:matIdx];
        }
    }
    NSString* clipLabel = clip_mode_label(self.clipMode);
    VmfClipKeepMode keepMode = (VmfClipKeepMode)self.clipMode;
    for (VmfViewport* viewport in self.viewports) {
        viewport.clipModeLabel = clipLabel;
        viewport.clipKeepMode = keepMode;
    }
    [self refreshInspector];
}

- (void)menuNeedsUpdate:(NSMenu*)menu {
    if (menu == self.historyMenu) {
        [self rebuildHistoryMenu];
    } else if (menu == self.editMenu) {
        [self updateHistoryMenuTitles];
    }
}

- (BOOL)validateMenuItem:(NSMenuItem*)menuItem {
    SEL action = menuItem.action;
    BOOL pointEntitySelection = [self selectionIsPointEntity];
    BOOL prefabSelection = [self selectionIsPrefab];
    BOOL groupedBrushSelection = [self selectionActsAsGroupedBrushEntity];
    if (action == @selector(undoAction:)) {
        return self.undoStack.count > 0;
    }
    if (action == @selector(redoAction:)) {
        return self.redoStack.count > 0;
    }
    if (action == @selector(duplicateSelection:)) {
        return self.hasSelection && !pointEntitySelection;
    }
    if (action == @selector(applyMaterialToSelection:)) {
        return self.textureApplicationModeActive && self.hasSelection && !pointEntitySelection;
    }
    if (action == @selector(deleteSelection:)) {
        return self.hasSelection;
    }
    if (action == @selector(createGroupFromSelection:)) {
        return self.hasSelection && !pointEntitySelection && !prefabSelection && !groupedBrushSelection;
    }
    if (action == @selector(addSelectionToActiveGroup:)) {
        return self.hasSelection && !pointEntitySelection && !prefabSelection && !groupedBrushSelection && [self activeGroupEntityIndex] < self.scene.entityCount;
    }
    if (action == @selector(ungroupSelection:)) {
        return groupedBrushSelection;
    }
    if (action == @selector(jumpToHistoryState:)) {
        return self.hasDocument;
    }
    return YES;
}

- (void)handleKey:(NSEvent*)event {
    NSString* key = event.charactersIgnoringModifiers.lowercaseString;
    if (self.editorTool == VmfViewportEditorToolClip && ([key isEqualToString:@"\r"] || [key isEqualToString:@"\n"])) {
        if ([self.activeViewport hasPendingClipLine]) {
            [self.activeViewport commitPendingClipLine];
            return;
        }
    }

    CGFloat stepMultiplier = (event.modifierFlags & NSEventModifierFlagShift) != 0 ? 4.0 : 1.0;
    float step = (float)(self.gridSize * stepMultiplier);
    if (self.hasSelection) {
        Vec3 offset = vec3_make(0.0f, 0.0f, 0.0f);
        switch (event.keyCode) {
            case 123:
                if (self.activeViewport.plane == VmfViewportPlaneZY) {
                    offset.raw[1] = -step;
                } else {
                    offset.raw[0] = -step;
                }
                break;
            case 124:
                if (self.activeViewport.plane == VmfViewportPlaneZY) {
                    offset.raw[1] = step;
                } else {
                    offset.raw[0] = step;
                }
                break;
            case 125:
                if (self.activeViewport.plane == VmfViewportPlaneXY || self.activeViewport.dimension == VmfViewportDimension3D) {
                    offset.raw[1] = -step;
                } else {
                    offset.raw[2] = -step;
                }
                break;
            case 126:
                if (self.activeViewport.plane == VmfViewportPlaneXY || self.activeViewport.dimension == VmfViewportDimension3D) {
                    offset.raw[1] = step;
                } else {
                    offset.raw[2] = step;
                }
                break;
            default:
                break;
        }
        if (vec3_length(offset) > 0.0f) {
            [self moveSelectedSolidByOffset:offset label:@"Move Brush"];
            return;
        }
    }

    if ([key isEqualToString:@"1"]) {
        [self setShadedMode:nil];
    } else if ([key isEqualToString:@"2"]) {
        [self setWireframeMode:nil];
    } else if ([key isEqualToString:@"["]) {
        [self stepGridSizeByOffset:-1];
    } else if ([key isEqualToString:@"]"]) {
        [self stepGridSizeByOffset:1];
    } else if ([key isEqualToString:@"b"]) {
        [self setBlockTool:nil];
    } else if ([key isEqualToString:@"c"]) {
        [self setCylinderTool:nil];
    } else if ([key isEqualToString:@"g"]) {
        [self setRampTool:nil];
    } else if ([key isEqualToString:@"t"]) {
        [self setStairsTool:nil];
    } else if ([key isEqualToString:@"a"]) {
        [self setArchTool:nil];
    } else if ([key isEqualToString:@"e"]) {
        [self setVertexTool:nil];
    } else if ([key isEqualToString:@"x"]) {
        [self setClipTool:nil];
    } else if ([key isEqualToString:@"v"]) {
        [self setSelectTool:nil];
    } else if ([key isEqualToString:@"n"]) {
        [self nextDocument:nil];
    } else if ([key isEqualToString:@"p"]) {
        [self previousDocument:nil];
    } else if ([key isEqualToString:@"f"]) {
        [self frameScene:nil];
    } else if ([key isEqualToString:@"r"]) {
        [self reloadDocument:nil];
    } else if ([event.charactersIgnoringModifiers isEqualToString:@"\177"]) {
        [self deleteSelection:nil];
    }
}

- (void)handleKeyUp:(NSEvent*)event {
    (void)event;
}

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
    if (firstPath) {
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

- (BOOL)isSelectedSolidBoxBrush {
    if (!self.hasSelection || self.selectedEntityIndex >= self.scene.entityCount || self.selectedSolidIndex >= self.scene.entities[self.selectedEntityIndex].solidCount) {
        return NO;
    }
    return self.scene.entities[self.selectedEntityIndex].solids[self.selectedSolidIndex].sideCount == 6;
}

- (void)startVertexEditSession {
    if (!self.hasSelection) {
        return;
    }
    // If already active for this exact solid, do nothing.
    if (_hasVertexEditSession &&
        _vertexEditEntityIndex == self.selectedEntityIndex &&
        _vertexEditSolidIndex == self.selectedSolidIndex) {
        return;
    }
    // End any prior session on a different solid without committing.
    [self endVertexEditSession:NO];

    _vertexEditEntityIndex = self.selectedEntityIndex;
    _vertexEditSolidIndex = self.selectedSolidIndex;
    _hasVertexEditSession = YES;
    _draftIsValid = YES;

    // Capture initial vertex positions.
    _draftVertexCount = 0;
    char vertErr[256] = { 0 };
    vmf_scene_solid_vertices(&_scene,
                             self.selectedEntityIndex,
                             self.selectedSolidIndex,
                             _draftVertices,
                             VMF_MAX_SOLID_VERTICES,
                             &_draftVertexCount,
                             vertErr, sizeof(vertErr));

    // Capture edge connectivity (vertex-index pairs) for display during invalid states.
    VmfSolidEdge edges[VMF_MAX_SOLID_EDGES];
    size_t edgeCount = 0;
    char edgeErr[256] = { 0 };
    vmf_scene_solid_edges(&_scene,
                          self.selectedEntityIndex,
                          self.selectedSolidIndex,
                          edges, VMF_MAX_SOLID_EDGES, &edgeCount,
                          edgeErr, sizeof(edgeErr));
    _draftEdgeConnCount = 0;
    for (size_t i = 0; i < edgeCount; ++i) {
        size_t vA = SIZE_MAX, vB = SIZE_MAX;
        for (size_t v = 0; v < _draftVertexCount; ++v) {
            if (vec3_length(vec3_sub(_draftVertices[v], edges[i].start)) < 0.1f) { vA = v; }
            if (vec3_length(vec3_sub(_draftVertices[v], edges[i].end))   < 0.1f) { vB = v; }
        }
        if (vA != SIZE_MAX && vB != SIZE_MAX && _draftEdgeConnCount < VMF_MAX_SOLID_EDGES) {
            _draftEdgeConnVA[_draftEdgeConnCount] = vA;
            _draftEdgeConnVB[_draftEdgeConnCount] = vB;
            _draftEdgeTemplates[_draftEdgeConnCount] = edges[i];
            ++_draftEdgeConnCount;
        }
    }

    // Capture per-face inward-facing reference normals for the geometric convexity check.
    // Enumerate all unique side indices referenced by our edges, then compute the
    // inward normal for each from the baseline solid's plane definition.
    _draftFaceCount = 0;
    VmfSolid* baseSolid = &_scene.entities[_vertexEditEntityIndex].solids[_vertexEditSolidIndex];
    // Compute interior reference point (centroid of all plane sample points).
    Vec3 interior = vec3_make(0.0f, 0.0f, 0.0f);
    float sampleCount = 0.0f;
    for (size_t s = 0; s < baseSolid->sideCount; ++s) {
        for (size_t p = 0; p < 3; ++p) {
            interior = vec3_add(interior, baseSolid->sides[s].points[p]);
            sampleCount += 1.0f;
        }
    }
    if (sampleCount > 0.0f) {
        interior = vec3_scale(interior, 1.0f / sampleCount);
    }
    for (size_t e = 0; e < _draftEdgeConnCount; ++e) {
        for (int ep = 0; ep < 2; ++ep) {
            size_t sideIdx = _draftEdgeTemplates[e].sideIndices[ep];
            // Check if already recorded.
            BOOL found = NO;
            for (size_t f = 0; f < _draftFaceCount; ++f) {
                if (_draftFaceSideIndices[f] == sideIdx) { found = YES; break; }
            }
            if (found || _draftFaceCount >= 128 || sideIdx >= baseSolid->sideCount) {
                continue;
            }
            // Compute inward normal from the side's three defining points.
            Vec3 p0 = baseSolid->sides[sideIdx].points[0];
            Vec3 p1 = baseSolid->sides[sideIdx].points[1];
            Vec3 p2 = baseSolid->sides[sideIdx].points[2];
            Vec3 n = vec3_normalize(vec3_cross(vec3_sub(p1, p0), vec3_sub(p2, p0)));
            // Orient so the interior point is on the negative (inside) side.
            if (vec3_dot(n, vec3_sub(interior, p0)) > 0.0f) {
                n = vec3_scale(n, -1.0f);
            }
            _draftFaceSideIndices[_draftFaceCount] = sideIdx;
            _draftFaceRefNormals[_draftFaceCount] = n;
            ++_draftFaceCount;
        }
    }
}

// Direct geometric convexity check on the current draft vertex positions.
//
// For each face of the solid (captured at session start), we:
//  1. Collect the current draft positions of the vertices on that face.
//  2. Find a valid plane through those positions (first non-collinear triple),
//     oriented to match the baseline inward normal.
//  3. Verify every other draft vertex sits on the interior side of that plane.
//
// To support vertex-merge dragging (two vertices dragged onto each other), we
// first de-duplicate draft positions: coincident vertices (within mergeEps) are
// treated as one point.  A face that degenerates entirely due to coincident
// merge-pairs is skipped — it will be dropped during the final brush rebuild.
- (BOOL)isDraftConvex {
    if (_draftVertexCount < 4 || _draftFaceCount == 0) {
        return YES;
    }

    // Build canonical (de-duplicated) vertex array.
    static const float mergeEps = 0.5f;
    size_t canonical[VMF_MAX_SOLID_VERTICES];
    Vec3   unique[VMF_MAX_SOLID_VERTICES];
    size_t uniqueCount = 0;
    for (size_t i = 0; i < _draftVertexCount; ++i) {
        size_t found = SIZE_MAX;
        for (size_t j = 0; j < uniqueCount; ++j) {
            if (vec3_length(vec3_sub(_draftVertices[i], unique[j])) < mergeEps) {
                found = j; break;
            }
        }
        if (found == SIZE_MAX) {
            canonical[i] = uniqueCount;
            unique[uniqueCount++] = _draftVertices[i];
        } else {
            canonical[i] = found;
        }
    }

    // Convex check epsilon: vertices this far outside a face plane = invalid.
    static const float convexEps = 0.5f;

    for (size_t f = 0; f < _draftFaceCount; ++f) {
        size_t sideIdx = _draftFaceSideIndices[f];
        Vec3   refNormal = _draftFaceRefNormals[f];

        // Collect canonical vertex indices belonging to this face.
        size_t faceCanon[VMF_MAX_SOLID_VERTICES];
        size_t faceCanonCount = 0;
        for (size_t e = 0; e < _draftEdgeConnCount; ++e) {
            if (_draftEdgeTemplates[e].sideIndices[0] != sideIdx &&
                _draftEdgeTemplates[e].sideIndices[1] != sideIdx) {
                continue;
            }
            // Add both edge endpoints (by canonical index) uniquely.
            size_t cA = canonical[_draftEdgeConnVA[e]];
            size_t cB = canonical[_draftEdgeConnVB[e]];
            BOOL hasA = NO, hasB = NO;
            for (size_t x = 0; x < faceCanonCount; ++x) {
                if (faceCanon[x] == cA) hasA = YES;
                if (faceCanon[x] == cB) hasB = YES;
            }
            if (!hasA && faceCanonCount < VMF_MAX_SOLID_VERTICES) faceCanon[faceCanonCount++] = cA;
            if (!hasB && faceCanonCount < VMF_MAX_SOLID_VERTICES) faceCanon[faceCanonCount++] = cB;
        }

        if (faceCanonCount < 3) {
            // Face collapsed entirely due to vertex merging → will be dropped in
            // rebuild, not an error.
            continue;
        }

        // Find first non-collinear point triple to define the face plane.
        Vec3 planeNormal = vec3_make(0.0f, 0.0f, 0.0f);
        float planeDist = 0.0f;
        BOOL planeFound = NO;
        for (size_t i = 0; i < faceCanonCount && !planeFound; ++i) {
            for (size_t j = i + 1; j < faceCanonCount && !planeFound; ++j) {
                for (size_t k = j + 1; k < faceCanonCount && !planeFound; ++k) {
                    Vec3 ab = vec3_sub(unique[faceCanon[j]], unique[faceCanon[i]]);
                    Vec3 ac = vec3_sub(unique[faceCanon[k]], unique[faceCanon[i]]);
                    Vec3 cross = vec3_cross(ab, ac);
                    if (vec3_length(cross) < 1e-4f) continue;
                    planeNormal = vec3_normalize(cross);
                    // refNormal is the outward-facing normal (interior is on its
                    // negative side). Orient planeNormal the same way so that
                    // dist > 0 means a vertex lies outside this face plane.
                    if (vec3_dot(planeNormal, refNormal) < 0.0f) {
                        planeNormal = vec3_scale(planeNormal, -1.0f);
                    }
                    planeDist = vec3_dot(planeNormal, unique[faceCanon[i]]);
                    planeFound = YES;
                }
            }
        }

        if (!planeFound) {
            // All face points collinear but not due to a full merge → degenerate face.
            return NO;
        }

        // Every draft vertex must be on the interior side (dist <= convexEps).
        for (size_t v = 0; v < uniqueCount; ++v) {
            float dist = vec3_dot(planeNormal, unique[v]) - planeDist;
            if (dist > convexEps) {
                return NO;
            }
        }
    }

    return YES;
}

// Build display edges from current draft vertex positions + stored connectivity.
- (void)buildDraftDisplayEdges:(VmfSolidEdge*)outEdges count:(size_t*)outCount {
    for (size_t i = 0; i < _draftEdgeConnCount; ++i) {
        outEdges[i] = _draftEdgeTemplates[i];
        outEdges[i].start = _draftVertices[_draftEdgeConnVA[i]];
        outEdges[i].end   = _draftVertices[_draftEdgeConnVB[i]];
        outEdges[i].endpointCount = 2;
    }
    *outCount = _draftEdgeConnCount;
}

- (void)pushDraftOverlayToViewports {
    // Rebuild 2D display edges from draft positions (works even when invalid).
    VmfSolidEdge displayEdges[VMF_MAX_SOLID_EDGES];
    size_t displayEdgeCount = 0;
    [self buildDraftDisplayEdges:displayEdges count:&displayEdgeCount];

    // Build ViewerVertex line pairs for the 3D wireframe preview.
    Vec3 previewColor = _draftIsValid
        ? vec3_make(0.86f, 0.73f, 0.33f)
        : vec3_make(0.95f, 0.22f, 0.22f);
    ViewerVertex previewVerts[VMF_MAX_SOLID_EDGES * 2];
    size_t previewVertCount = 0;
    for (size_t i = 0; i < _draftEdgeConnCount; ++i) {
        Vec3 a = _draftVertices[_draftEdgeConnVA[i]];
        Vec3 b = _draftVertices[_draftEdgeConnVB[i]];
        Vec3 n = vec3_make(0.0f, 0.0f, 1.0f);
        previewVerts[previewVertCount++] = (ViewerVertex){ .position = a, .normal = n, .color = previewColor };
        previewVerts[previewVertCount++] = (ViewerVertex){ .position = b, .normal = n, .color = previewColor };
    }

    for (VmfViewport* vp in self.viewports) {
        [vp setSelectionVertices:_draftVertices count:_draftVertexCount visible:YES];
        [vp setSelectionEdges:displayEdges count:displayEdgeCount visible:YES];
        [vp setVertexEditIsInvalid:!_draftIsValid];
        if (vp.dimension == VmfViewportDimension3D) {
            [vp setVertexEditPreviewEdges:previewVerts count:previewVertCount];
        }
    }
}

- (void)endVertexEditSession:(BOOL)tryApply {
    if (!_hasVertexEditSession) {
        return;
    }

    // Clear 3D preview and invalid flag from all viewports immediately.
    for (VmfViewport* vp in self.viewports) {
        [vp clearVertexEditPreview];
        [vp setVertexEditIsInvalid:NO];
    }

    if (tryApply && _draftIsValid && _draftVertexCount > 0) {
        // Build the full move list comparing draft positions to the unchanged _scene baseline.
        VmfSolidVertex solidVerts[VMF_MAX_SOLID_VERTICES];
        size_t solidVertCount = 0;
        char refErr[256] = { 0 };
        vmf_scene_solid_vertex_refs(&_scene, _vertexEditEntityIndex, _vertexEditSolidIndex,
                                    solidVerts, VMF_MAX_SOLID_VERTICES, &solidVertCount,
                                    refErr, sizeof(refErr));

        VmfVertexMove moves[VMF_MAX_SOLID_VERTICES];
        size_t moveCount = 0;
        if (solidVertCount == _draftVertexCount) {
            // Snap coincident draft vertices together before committing.
            // This implements vertex-merge: dragging a vertex onto another collapses
            // the shared edge, naturally reducing the solid's face count.
            static const float mergeEps = 0.5f;
            Vec3 committed[VMF_MAX_SOLID_VERTICES];
            memcpy(committed, _draftVertices, _draftVertexCount * sizeof(Vec3));
            for (size_t i = 0; i < _draftVertexCount; ++i) {
                for (size_t j = 0; j < i; ++j) {
                    if (vec3_length(vec3_sub(committed[i], committed[j])) < mergeEps) {
                        committed[i] = committed[j]; // snap i → j's canonical position
                    }
                }
            }
            for (size_t i = 0; i < _draftVertexCount; ++i) {
                if (vec3_length(vec3_sub(committed[i], solidVerts[i].position)) >= 0.01f) {
                    moves[moveCount++] = (VmfVertexMove){ .vertexIndex = i, .newPosition = committed[i] };
                }
            }
        }

        if (moveCount > 0) {
            SceneHistoryEntry* entry = [self captureHistoryEntry];
            char moveErr[256] = { 0 };
            if (vmf_scene_move_solid_vertices(&_scene, _vertexEditEntityIndex, _vertexEditSolidIndex,
                                              moves, moveCount, moveErr, sizeof(moveErr))) {
                if (entry) {
                    [self pushUndoEntry:entry];
                }
                [self markDocumentChangedWithLabel:@"Edit Vertices"];
            }
            // If the move failed: _scene is already at baseline (vmf_scene_move_solid_vertices
            // is transactional), nothing to revert.
        }
    }

    _hasVertexEditSession = NO;
    _draftVertexCount = 0;
    _draftEdgeConnCount = 0;
    _draftIsValid = YES;

    [self rebuildMeshFromScene];
}

- (void)syncSelectionOverlay {
    // During a vertex edit session, always show draft data (not brush-derived data)
    // so vertex dots/edges always reflect where the user actually moved things.
    if (_hasVertexEditSession && self.hasSelection &&
        _vertexEditEntityIndex == self.selectedEntityIndex &&
        _vertexEditSolidIndex == self.selectedSolidIndex) {
        Bounds3 selectionBounds = bounds3_empty();
        char boundsErr[256] = { 0 };
        vmf_scene_solid_bounds(&_scene, self.selectedEntityIndex, self.selectedSolidIndex, &selectionBounds, boundsErr, sizeof(boundsErr));
        for (VmfViewport* viewport in self.viewports) {
            viewport.selectionEditable = YES;
            [viewport setSelectionBounds:selectionBounds visible:YES];
            [viewport setSelectedFaceEdge:VmfViewportSelectionEdgeNone];
        }
        [self pushDraftOverlayToViewports];
        return;
    }

    Bounds3 selectionBounds = bounds3_empty();
    Vec3 selectionVertices[VMF_MAX_SOLID_VERTICES];
    size_t selectionVertexCount = 0;
    VmfSolidEdge selectionEdges[VMF_MAX_SOLID_EDGES];
    size_t selectionEdgeCount = 0;
    BOOL showSelection = self.hasSelection;
    BOOL prefabSelection = [self selectionIsPrefab];
    BOOL pointEntitySelection = [self selectionIsPointEntity];
    BOOL groupedBrushSelection = [self selectionIsGroupedBrushEntity];
    BOOL boxSelection = !prefabSelection && !groupedBrushSelection && [self isSelectedSolidBoxBrush];
    if (showSelection) {
        if (prefabSelection) {
            ProceduralShapePrefab* prefab = [self prefabContainingEntityIndex:self.selectedEntityIndex solidIndex:self.selectedSolidIndex];
            selectionBounds = prefab.bounds;
        } else if (pointEntitySelection || groupedBrushSelection) {
            showSelection = [self selectedEntityBounds:&selectionBounds];
        } else {
            char errorBuffer[256] = { 0 };
            showSelection = vmf_scene_solid_bounds(&_scene, self.selectedEntityIndex, self.selectedSolidIndex, &selectionBounds, errorBuffer, sizeof(errorBuffer));
        }
        if ([self selectionIsGroupedBrushEntity] && self.selectedEntityIndex < self.scene.entityCount) {
            self.activeGroupEntityId = self.scene.entities[self.selectedEntityIndex].id;
        }
        if (showSelection && !prefabSelection && !pointEntitySelection && !groupedBrushSelection) {
            char vertexErrorBuffer[256] = { 0 };
            if (!vmf_scene_solid_vertices(&_scene,
                                          self.selectedEntityIndex,
                                          self.selectedSolidIndex,
                                          selectionVertices,
                                          VMF_MAX_SOLID_VERTICES,
                                          &selectionVertexCount,
                                          vertexErrorBuffer,
                                          sizeof(vertexErrorBuffer))) {
                selectionVertexCount = 0;
            }
            char edgeErrorBuffer[256] = { 0 };
            if (!vmf_scene_solid_edges(&_scene,
                                       self.selectedEntityIndex,
                                       self.selectedSolidIndex,
                                       selectionEdges,
                                       VMF_MAX_SOLID_EDGES,
                                       &selectionEdgeCount,
                                       edgeErrorBuffer,
                                       sizeof(edgeErrorBuffer))) {
                selectionEdgeCount = 0;
            }
        }
    }
    for (VmfViewport* viewport in self.viewports) {
        viewport.selectionEditable = showSelection;
        [viewport setSelectionVertices:selectionVertices count:selectionVertexCount visible:(showSelection && !prefabSelection && !pointEntitySelection && !groupedBrushSelection)];
        [viewport setSelectionEdges:selectionEdges count:selectionEdgeCount visible:(showSelection && !prefabSelection && !pointEntitySelection && !groupedBrushSelection)];
        [viewport setSelectedFaceEdge:(showSelection && !prefabSelection && !pointEntitySelection && !groupedBrushSelection && self.hasFaceSelection && boxSelection) ? [self selectionEdgeForPlane:viewport.plane sideIndex:self.selectedSideIndex] : VmfViewportSelectionEdgeNone];
        [viewport setSelectedFaceHighlightEntityIndex:(showSelection && !prefabSelection && !pointEntitySelection && !groupedBrushSelection && self.hasFaceSelection) ? self.selectedEntityIndex : 0
                                            solidIndex:(showSelection && !prefabSelection && !pointEntitySelection && !groupedBrushSelection && self.hasFaceSelection) ? self.selectedSolidIndex : 0
                                             sideIndex:(showSelection && !prefabSelection && !pointEntitySelection && !groupedBrushSelection && self.hasFaceSelection) ? self.selectedSideIndex : 0
                                                 visible:(showSelection && !prefabSelection && !pointEntitySelection && !groupedBrushSelection && self.hasFaceSelection)];
        [viewport setSelectionBounds:selectionBounds visible:showSelection];
        if (!showSelection) {
            [viewport setVertexEditIsInvalid:NO];
        }
    }
}

- (BOOL)rebuildMeshFromScene {
    viewer_mesh_free(&_mesh);
    char errorBuffer[512] = { 0 };
    if (!vmf_build_mesh(&_scene, &_mesh, errorBuffer, sizeof(errorBuffer))) {
        [self showError:[NSString stringWithUTF8String:errorBuffer]];
        return NO;
    }

    for (VmfViewport* viewport in self.viewports) {
        [viewport updateMesh:&_mesh];
        if (self.materialsDirectory) {
            // Always clear miss-cache entries so newly added texture files are picked up
            [viewport clearTextureMissCache];
            [viewport setTextureDirectory:self.materialsDirectory];
        }
    }
    [self syncSceneWorldLightsFromScene];
    [self syncSelectionOverlay];
    [self updateMaterialBrowser];
    [self updateWindowTitle];
    [self updateChrome];
    return YES;
}

- (void)syncSceneWorldLightsFromScene {
    NovaSceneLightRecord records[UI_MAX_LIGHTS];
    uint32_t lightCount = 0u;
    memset(records, 0, sizeof(records));

    for (size_t entityIndex = 0; entityIndex < self.scene.entityCount && lightCount < UI_MAX_LIGHTS; ++entityIndex) {
        const VmfEntity* entity = &self.scene.entities[entityIndex];
        if (entity->kind != VmfEntityKindLight) {
            continue;
        }

        NovaSceneLightRecord* record = &records[lightCount];
        record->lightIndex = lightCount;
        record->lightType = entity->lightType;
        record->enabled = entity->enabled;
        record->castShadows = entity->castShadows;
        record->shadowPcss = 0;
        record->worldMatrix[0] = 1.0f;
        record->worldMatrix[5] = 1.0f;
        record->worldMatrix[10] = 1.0f;
        record->worldMatrix[15] = 1.0f;
        record->worldMatrix[12] = entity->position.raw[0];
        record->worldMatrix[13] = entity->position.raw[1];
        record->worldMatrix[14] = entity->position.raw[2];
        record->color[0] = entity->color.raw[0];
        record->color[1] = entity->color.raw[1];
        record->color[2] = entity->color.raw[2];
        record->intensity = entity->intensity;
        record->range = entity->range;
        record->spotInnerDegrees = entity->spotInnerDegrees;
        record->spotOuterDegrees = entity->spotOuterDegrees;
        record->quadHalfSize[0] = 32.0f;
        record->quadHalfSize[1] = 32.0f;
        record->sourceSize = 0.25f;
        record->shadowConstantBias = 0.001f;
        lightCount += 1u;
    }

    nova_scene_world_sync_lights(&_sceneWorld, records, lightCount);

    Vec3 primaryPosition = vec3_make(256.0f, 256.0f, 512.0f);
    Vec3 primaryColor = vec3_make(1.0f, 0.95f, 0.8f);
    float primaryIntensity = 2.0f;
    float primaryRange = 2048.0f;
    BOOL primaryEnabled = YES;
    if (lightCount > 0u) {
        const NovaSceneLightRecord* primaryLight = &records[0];
        primaryPosition = vec3_make(primaryLight->worldMatrix[12], primaryLight->worldMatrix[13], primaryLight->worldMatrix[14]);
        primaryColor = vec3_make(primaryLight->color[0], primaryLight->color[1], primaryLight->color[2]);
        primaryIntensity = fmaxf(primaryLight->intensity, 0.1f);
        primaryRange = fmaxf(primaryLight->range, 64.0f);
        primaryEnabled = primaryLight->enabled != 0;
    }
    for (VmfViewport* viewport in self.viewports) {
        [viewport setPrimaryLightPosition:primaryPosition
                                     color:primaryColor
                                 intensity:primaryIntensity
                                     range:primaryRange
                                   enabled:primaryEnabled];
    }
}

- (void)frameAllViewports {
    for (VmfViewport* viewport in self.viewports) {
        [viewport frameScene];
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

- (void)addLightEntity:(id)sender {
    (void)sender;
    if (!self.hasDocument) {
        [self newDocument:nil];
        if (!self.hasDocument) {
            return;
        }
    }

    Vec3 position = bounds3_is_valid(self.mesh.bounds) ? bounds3_center(self.mesh.bounds) : vec3_make(0.0f, 0.0f, 128.0f);
    char errorBuffer[256] = { 0 };
    size_t entityIndex = 0;
    if (!vmf_scene_add_light_entity(&_scene,
                                    "Light",
                                    position,
                                    vec3_make(1.0f, 0.95f, 0.8f),
                                    10.0f,
                                    512.0f,
                                    1,
                                    &entityIndex,
                                    errorBuffer,
                                    sizeof(errorBuffer))) {
        [self showError:[NSString stringWithUTF8String:errorBuffer]];
        return;
    }

    [self markDocumentChangedWithLabel:@"Add Light"];
    self.hasSelection = YES;
    self.selectedEntityIndex = entityIndex;
    self.selectedSolidIndex = 0;
    self.hasFaceSelection = NO;
    self.selectedSideIndex = 0;
    [self rebuildMeshFromScene];
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

- (void)newDocument:(id)sender {
    (void)sender;
    if (![self confirmDiscardChangesForAction:@"creating a new map"]) {
        return;
    }
    file_index_free(&_fileIndex);
    [self resetDocumentState];
    char errorBuffer[256] = { 0 };
    if (!vmf_scene_init_empty(&_scene, errorBuffer, sizeof(errorBuffer))) {
        [self showError:[NSString stringWithUTF8String:errorBuffer]];
        return;
    }
    self.hasDocument = YES;
    [self resetRevisionTracking];
    self.currentHistoryLabel = @"New Map";
    [self rebuildMeshFromScene];
    [self frameAllViewports];
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

- (void)nextDocument:(id)sender {
    (void)sender;
    if (![self confirmDiscardChangesForAction:@"switching to another indexed map"]) {
        return;
    }
    const char* path = file_index_next(&_fileIndex);
    if (path) {
        [self loadVmfAtPath:[NSString stringWithUTF8String:path]];
    }
}

- (void)previousDocument:(id)sender {
    (void)sender;
    if (![self confirmDiscardChangesForAction:@"switching to another indexed map"]) {
        return;
    }
    const char* path = file_index_previous(&_fileIndex);
    if (path) {
        [self loadVmfAtPath:[NSString stringWithUTF8String:path]];
    }
}

- (void)setShadedMode:(id)sender {
    (void)sender;
    VmfViewport* viewport = self.activeViewport ? self.activeViewport : self.perspectiveViewport;
    viewport.renderMode = VmfViewportRenderModeShaded;
    [self updateChrome];
}

- (void)setWireframeMode:(id)sender {
    (void)sender;
    VmfViewport* viewport = self.activeViewport ? self.activeViewport : self.perspectiveViewport;
    viewport.renderMode = VmfViewportRenderModeWireframe;
    [self updateChrome];
}

- (void)frameScene:(id)sender {
    (void)sender;
    [self frameAllViewports];
}

- (void)setEditorTool:(VmfViewportEditorTool)editorTool {
    if (editorTool != VmfViewportEditorToolVertex) {
        // Leaving vertex tool — commit if valid, revert if not.
        [self endVertexEditSession:YES];
    }
    _editorTool = editorTool;
    for (VmfViewport* viewport in self.viewports) {
        viewport.editorTool = editorTool;
    }
    if (editorTool == VmfViewportEditorToolVertex) {
        // Entering vertex tool — start a session for the current selection.
        [self startVertexEditSession];
    }
    [self updateChrome];
}

- (void)setSelectTool:(id)sender {
    (void)sender;
    [self setEditorTool:VmfViewportEditorToolSelect];
}

- (void)setVertexTool:(id)sender {
    (void)sender;
    [self setEditorTool:VmfViewportEditorToolVertex];
}

- (void)setBlockTool:(id)sender {
    (void)sender;
    [self setEditorTool:VmfViewportEditorToolBlock];
}

- (void)setCylinderTool:(id)sender {
    (void)sender;
    [self setEditorTool:VmfViewportEditorToolCylinder];
}

- (void)setRampTool:(id)sender {
    (void)sender;
    [self setEditorTool:VmfViewportEditorToolRamp];
}

- (void)setStairsTool:(id)sender {
    (void)sender;
    [self setEditorTool:VmfViewportEditorToolStairs];
}

- (void)setArchTool:(id)sender {
    (void)sender;
    [self setEditorTool:VmfViewportEditorToolArch];
}

- (void)setClipTool:(id)sender {
    (void)sender;
    if (self.editorTool == VmfViewportEditorToolClip) {
        self.clipMode = (ViewerClipMode)((self.clipMode + 1) % 3);
        [self updateChrome];
        return;
    }
    [self setEditorTool:VmfViewportEditorToolClip];
}

- (void)renderControlChanged:(id)sender {
    (void)sender;
    if (self.renderControl.selectedSegment == 1) {
        [self setShadedMode:nil];
    } else {
        [self setWireframeMode:nil];
    }
}

- (void)materialPresetChanged:(id)sender {
    (void)sender;
    NSString* title = self.materialPopUp.selectedItem.title;
    if (title.length > 0) {
        self.brushMaterialName = title;
    }
}

- (void)gridSizeChanged:(id)sender {
    (void)sender;
    self.gridSize = self.gridPopUp.selectedItem.title.floatValue;
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

- (void)duplicateSelection:(id)sender {
    (void)sender;
    if (!self.hasSelection) {
        return;
    }

    if ([self selectionActsAsGroupedBrushEntity]) {
        SceneHistoryEntry* entry = [self captureHistoryEntry];
        if (!entry) {
            return;
        }

        size_t sourceEntityIndex = self.selectedEntityIndex;
        size_t sourceSolidCount = self.scene.entities[sourceEntityIndex].solidCount;
        size_t newGroupEntityIndex = 0;
        size_t lastSolidIndex = 0;
        Vec3 duplicateOffset = [self duplicateOffsetForActiveViewport];
        char errorBuffer[256] = { 0 };
        if (!vmf_scene_add_brush_entity(&_scene, [self nextGroupName].UTF8String, "func_group", &newGroupEntityIndex, errorBuffer, sizeof(errorBuffer))) {
            [self showError:[NSString stringWithUTF8String:errorBuffer]];
            return;
        }

        for (size_t solidOffset = 0; solidOffset < sourceSolidCount; ++solidOffset) {
            size_t duplicatedEntityIndex = 0;
            size_t duplicatedSolidIndex = 0;
            if (!vmf_scene_duplicate_solid(&_scene,
                                           sourceEntityIndex,
                                           solidOffset,
                                           duplicateOffset,
                                           &duplicatedEntityIndex,
                                           &duplicatedSolidIndex,
                                           errorBuffer,
                                           sizeof(errorBuffer)) ||
                !vmf_scene_move_solid_to_entity(&_scene,
                                               duplicatedEntityIndex,
                                               duplicatedSolidIndex,
                                               newGroupEntityIndex,
                                               &lastSolidIndex,
                                               errorBuffer,
                                               sizeof(errorBuffer))) {
                [self showError:[NSString stringWithUTF8String:errorBuffer]];
                return;
            }
        }

        self.hasSelection = YES;
        self.selectedEntityIndex = newGroupEntityIndex;
        self.selectedSolidIndex = lastSolidIndex;
        self.hasFaceSelection = NO;
        self.selectedSideIndex = 0;
        self.activeGroupEntityId = self.scene.entities[newGroupEntityIndex].id;
        [self pushUndoEntry:entry];
        [self markDocumentChangedWithLabel:@"Duplicate Group"];
        [self rebuildMeshFromScene];
        return;
    }

    ProceduralShapePrefab* prefab = [self prefabContainingEntityIndex:self.selectedEntityIndex solidIndex:self.selectedSolidIndex];
    if (prefab) {
        SceneHistoryEntry* entry = [self captureHistoryEntry];
        if (!entry) {
            return;
        }

        Vec3 offset = [self duplicateOffsetForActiveViewport];
        char errorBuffer[256] = { 0 };
        size_t newStartSolidIndex = 0;
        size_t newLastSolidIndex = 0;
        for (size_t offsetIndex = 0; offsetIndex < prefab.solidCount; ++offsetIndex) {
            size_t entityIndex = 0;
            size_t solidIndex = 0;
            if (!vmf_scene_duplicate_solid(&_scene,
                                           prefab.entityIndex,
                                           prefab.startSolidIndex + offsetIndex,
                                           offset,
                                           &entityIndex,
                                           &solidIndex,
                                           errorBuffer,
                                           sizeof(errorBuffer))) {
                [self showError:[NSString stringWithUTF8String:errorBuffer]];
                return;
            }
            if (offsetIndex == 0) {
                newStartSolidIndex = solidIndex;
            }
            newLastSolidIndex = solidIndex;
        }

        ProceduralShapePrefab* newPrefab = [prefab copy];
        newPrefab.startSolidIndex = newStartSolidIndex;
        newPrefab.entityIndex = prefab.entityIndex;
        Bounds3 duplicatedBounds = newPrefab.bounds;
        duplicatedBounds.min = vec3_add(duplicatedBounds.min, offset);
        duplicatedBounds.max = vec3_add(duplicatedBounds.max, offset);
        newPrefab.bounds = duplicatedBounds;
        [self.currentPrefabs addObject:newPrefab];

        self.editingPrefab = newPrefab;
        self.hasSelection = YES;
        self.selectedEntityIndex = newPrefab.entityIndex;
        self.selectedSolidIndex = newLastSolidIndex;
        self.hasFaceSelection = NO;
        self.selectedSideIndex = 0;
        [self pushUndoEntry:entry];
        [self markDocumentChangedWithLabel:@"Duplicate Prefab"];
        [self rebuildMeshFromScene];
        [self refreshInspector];
        return;
    }

    SceneHistoryEntry* entry = [self captureHistoryEntry];
    if (!entry) {
        return;
    }

    char errorBuffer[256] = { 0 };
    size_t entityIndex = 0;
    size_t solidIndex = 0;
    if (!vmf_scene_duplicate_solid(&_scene,
                                   self.selectedEntityIndex,
                                   self.selectedSolidIndex,
                                   [self duplicateOffsetForActiveViewport],
                                   &entityIndex,
                                   &solidIndex,
                                   errorBuffer,
                                   sizeof(errorBuffer))) {
        [self showError:[NSString stringWithUTF8String:errorBuffer]];
        return;
    }

    self.hasSelection = YES;
    self.selectedEntityIndex = entityIndex;
    self.selectedSolidIndex = solidIndex;
    self.hasFaceSelection = NO;
    self.selectedSideIndex = 0;
    [self pushUndoEntry:entry];
    [self markDocumentChangedWithLabel:@"Duplicate Brush"];
    [self rebuildMeshFromScene];
}

- (void)deleteSelection:(id)sender {
    (void)sender;
    if (!self.hasSelection) {
        return;
    }

    if ([self selectionActsAsGroupedBrushEntity]) {
        SceneHistoryEntry* entry = [self captureHistoryEntry];
        if (!entry) {
            return;
        }

        char errorBuffer[256] = { 0 };
        if (!vmf_scene_delete_entity(&_scene, self.selectedEntityIndex, errorBuffer, sizeof(errorBuffer))) {
            [self showError:[NSString stringWithUTF8String:errorBuffer]];
            return;
        }

        self.hasSelection = NO;
        self.hasFaceSelection = NO;
        self.selectedSideIndex = 0;
        [self pushUndoEntry:entry];
        [self markDocumentChangedWithLabel:@"Delete Group"];
        [self rebuildMeshFromScene];
        return;
    }

    if ([self selectionIsPointEntity]) {
        SceneHistoryEntry* entry = [self captureHistoryEntry];
        if (!entry || self.selectedEntityIndex >= self.scene.entityCount) {
            return;
        }

        size_t entityIndex = self.selectedEntityIndex;
        memmove(&_scene.entities[entityIndex],
            &_scene.entities[entityIndex + 1],
            (_scene.entityCount - entityIndex - 1) * sizeof(VmfEntity));
        _scene.entityCount -= 1;
        self.hasSelection = NO;
        self.hasFaceSelection = NO;
        self.selectedSideIndex = 0;
        [self pushUndoEntry:entry];
        [self markDocumentChangedWithLabel:@"Delete Entity"];
        [self rebuildMeshFromScene];
        return;
    }

    ProceduralShapePrefab* prefab = [self prefabContainingEntityIndex:self.selectedEntityIndex solidIndex:self.selectedSolidIndex];
    if (prefab) {
        SceneHistoryEntry* entry = [self captureHistoryEntry];
        if (!entry) {
            return;
        }

        char errorBuffer[256] = { 0 };
        for (size_t offset = prefab.solidCount; offset > 0; --offset) {
            if (!vmf_scene_delete_solid(&_scene, prefab.entityIndex, prefab.startSolidIndex + offset - 1, errorBuffer, sizeof(errorBuffer))) {
                [self showError:[NSString stringWithUTF8String:errorBuffer]];
                return;
            }
        }

        [self shiftPrefabIndicesInEntity:prefab.entityIndex startingAtSolidIndex:prefab.startSolidIndex + prefab.solidCount delta:-((NSInteger)prefab.solidCount) excludingPrefab:prefab];
        [self removePrefab:prefab];
        self.hasSelection = NO;
        self.hasFaceSelection = NO;
        self.selectedSideIndex = 0;
        [self pushUndoEntry:entry];
        [self markDocumentChangedWithLabel:@"Delete Prefab"];
        [self rebuildMeshFromScene];
        return;
    }

    SceneHistoryEntry* entry = [self captureHistoryEntry];
    if (!entry) {
        return;
    }

    char errorBuffer[256] = { 0 };
    if (!vmf_scene_delete_solid(&_scene, self.selectedEntityIndex, self.selectedSolidIndex, errorBuffer, sizeof(errorBuffer))) {
        [self showError:[NSString stringWithUTF8String:errorBuffer]];
        return;
    }

    self.hasSelection = NO;
    self.hasFaceSelection = NO;
    self.selectedSideIndex = 0;
    [self pushUndoEntry:entry];
    [self markDocumentChangedWithLabel:@"Delete Brush"];
    [self rebuildMeshFromScene];
}

- (void)applyMaterialToSelection:(id)sender {
    (void)sender;
    if (!self.textureApplicationModeActive || !self.hasSelection) {
        return;
    }

    SceneHistoryEntry* entry = [self captureHistoryEntry];
    if (!entry) {
        return;
    }

    char errorBuffer[256] = { 0 };
    BOOL ok = NO;
    if ([self selectionActsAsGroupedBrushEntity]) {
        ok = YES;
        const VmfEntity* entity = &self.scene.entities[self.selectedEntityIndex];
        for (size_t solidIndex = 0; solidIndex < entity->solidCount; ++solidIndex) {
            if (!vmf_scene_set_solid_material(&_scene,
                                             self.selectedEntityIndex,
                                             solidIndex,
                                             self.brushMaterialName.UTF8String,
                                             errorBuffer,
                                             sizeof(errorBuffer))) {
                ok = NO;
                break;
            }
        }
    } else if (self.hasFaceSelection) {
        ok = vmf_scene_set_side_material(&_scene,
                                         self.selectedEntityIndex,
                                         self.selectedSolidIndex,
                                         self.selectedSideIndex,
                                         self.brushMaterialName.UTF8String,
                                         errorBuffer,
                                         sizeof(errorBuffer));
    } else {
        ok = vmf_scene_set_solid_material(&_scene,
                                          self.selectedEntityIndex,
                                          self.selectedSolidIndex,
                                          self.brushMaterialName.UTF8String,
                                          errorBuffer,
                                          sizeof(errorBuffer));
    }
    if (!ok) {
        [self showError:[NSString stringWithUTF8String:errorBuffer]];
        return;
    }

    [self pushUndoEntry:entry];
    [self markDocumentChangedWithLabel:[self selectionActsAsGroupedBrushEntity] ? @"Apply Group Material" : (self.hasFaceSelection ? @"Apply Face Material" : @"Apply Brush Material")];
    [self rebuildMeshFromScene];
}

// ---------------------------------------------------------------------------
// Material browser
// ---------------------------------------------------------------------------

- (void)buildMaterialBrowserPanel {
    NSRect panelRect = NSMakeRect(0, 0, 280, 420);
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                              NSWindowStyleMaskResizable | NSWindowStyleMaskUtilityWindow;
    self.materialBrowserPanel = [[NSPanel alloc] initWithContentRect:panelRect
                                                           styleMask:style
                                                             backing:NSBackingStoreBuffered
                                                               defer:NO];
    self.materialBrowserPanel.title = @"Materials";
    self.materialBrowserPanel.floatingPanel = YES;
    self.materialBrowserPanel.releasedWhenClosed = NO;

    NSView* content = self.materialBrowserPanel.contentView;

    // Search field at top
    self.materialSearchField = [[NSSearchField alloc] initWithFrame:NSMakeRect(8, panelRect.size.height - 36, panelRect.size.width - 16, 28)];
    self.materialSearchField.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.materialSearchField.placeholderString = @"Filter materials…";
    self.materialSearchField.delegate = self;
    [content addSubview:self.materialSearchField];

    // Scroll view + table
    NSScrollView* scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, panelRect.size.width, panelRect.size.height - 44)];
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scrollView.hasVerticalScroller = YES;
    scrollView.borderType = NSNoBorder;

    self.materialTableView = [[NSTableView alloc] initWithFrame:scrollView.bounds];
    self.materialTableView.headerView = nil;
    self.materialTableView.dataSource = self;
    self.materialTableView.delegate = self;
    self.materialTableView.allowsEmptySelection = YES;
    self.materialTableView.usesAlternatingRowBackgroundColors = YES;
    self.materialTableView.rowHeight = 20.0;
    self.materialTableView.doubleAction = @selector(materialBrowserDoubleClicked:);
    self.materialTableView.target = self;

    NSTableColumn* col = [[NSTableColumn alloc] initWithIdentifier:@"material"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    col.title = @"";
    [self.materialTableView addTableColumn:col];

    scrollView.documentView = self.materialTableView;
    [content addSubview:scrollView];
}

- (void)updateMaterialBrowser {
    NSMutableOrderedSet<NSString*>* names = [NSMutableOrderedSet orderedSet];

    // Scan materials directory for PNG files — each filename (without extension)
    // becomes a material name, preserving relative subdirectory paths.
    if (self.materialsDirectory) {
        NSDirectoryEnumerator* enumerator =
            [[NSFileManager defaultManager] enumeratorAtPath:self.materialsDirectory];
        NSMutableArray<NSString*>* found = [NSMutableArray array];
        NSString* filePath;
        while ((filePath = [enumerator nextObject])) {
            if ([filePath.pathExtension.lowercaseString isEqualToString:@"png"]) {
                [found addObject:[filePath stringByDeletingPathExtension]];
            }
        }
        [found sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        for (NSString* mat in found) {
            [names addObject:mat];
        }
    }

    // Built-in non-rendering presets (always present even without texture files)
    [names addObject:@"nodraw"];
    [names addObject:@"clip"];

    // Collect any extra material names used in the scene that aren't already listed
    for (size_t e = 0; e < _scene.entityCount; ++e) {
        const VmfEntity* entity = &_scene.entities[e];
        for (size_t s = 0; s < entity->solidCount; ++s) {
            const VmfSolid* solid = &entity->solids[s];
            for (size_t f = 0; f < solid->sideCount; ++f) {
                NSString* mat = [NSString stringWithUTF8String:solid->sides[f].material];
                if (mat.length > 0) {
                    [names addObject:mat.lowercaseString];
                }
            }
        }
    }

    self.allMaterials = [NSMutableArray arrayWithArray:names.array];
    [self filterMaterials:self.materialSearchField.stringValue];
    [self rebuildMaterialPopup];
}

- (void)rebuildMaterialPopup {
    if (!self.materialPopUp) return;
    NSString* current = self.brushMaterialName;
    [self.materialPopUp removeAllItems];
    for (NSString* mat in self.allMaterials) {
        [self.materialPopUp addItemWithTitle:mat];
    }
    // Always guarantee the fallback special materials exist
    for (NSString* fallback in @[ @"nodraw", @"clip" ]) {
        if ([self.materialPopUp indexOfItemWithTitle:fallback] < 0) {
            [self.materialPopUp addItemWithTitle:fallback];
        }
    }
    // If the current brush material isn't in the list (e.g. from a loaded VMF),
    // insert it so the user doesn't silently lose their selection.
    if (current.length > 0 && [self.materialPopUp indexOfItemWithTitle:current] < 0) {
        [self.materialPopUp insertItemWithTitle:current atIndex:0];
    }
    NSInteger idx = current.length > 0 ? [self.materialPopUp indexOfItemWithTitle:current] : 0;
    if (idx >= 0) {
        [self.materialPopUp selectItemAtIndex:idx];
    }
}

- (void)filterMaterials:(NSString*)query {
    if (!self.allMaterials) {
        return;
    }
    if (query.length == 0) {
        self.filteredMaterials = [self.allMaterials mutableCopy];
    } else {
        NSString* upper = query.uppercaseString;
        self.filteredMaterials = [NSMutableArray array];
        for (NSString* name in self.allMaterials) {
            if ([name.uppercaseString containsString:upper]) {
                [self.filteredMaterials addObject:name];
            }
        }
    }
    [self.materialTableView reloadData];
}

- (void)browseMaterials:(id)sender {
    (void)sender;
    if (!self.materialBrowserPanel) {
        [self buildMaterialBrowserPanel];
    }
    [self updateMaterialBrowser];
    // Scroll to currently selected material if present
    if (self.brushMaterialName) {
        NSString* lc = self.brushMaterialName.lowercaseString;
        NSUInteger idx = [self.filteredMaterials indexOfObjectPassingTest:^BOOL(NSString* obj, NSUInteger i, BOOL* stop) {
            (void)i;
            BOOL match = [obj.lowercaseString isEqualToString:lc];
            if (match) *stop = YES;
            return match;
        }];
        if (idx != NSNotFound) {
            [self.materialTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:idx] byExtendingSelection:NO];
            [self.materialTableView scrollRowToVisible:(NSInteger)idx];
        }
    }
    [self.materialBrowserPanel makeKeyAndOrderFront:nil];
}

- (void)materialBrowserDoubleClicked:(id)sender {
    (void)sender;
    NSInteger row = self.materialTableView.selectedRow;
    if (row < 0 || row >= (NSInteger)self.filteredMaterials.count) {
        return;
    }
    self.brushMaterialName = self.filteredMaterials[(NSUInteger)row];
    [self updateChrome];
}

- (void)toggleTextureApplicationMode:(id)sender {
    (void)sender;
    self.textureApplicationModeActive = !self.textureApplicationModeActive;
    if (!self.textureApplicationModeActive) {
        self.hasHoveredFace = NO;
        for (VmfViewport* viewport in self.viewports) {
            [viewport setHighlightedFaceEntityIndex:0 solidIndex:0 sideIndex:0 visible:NO];
        }
    }
    [self updateChrome];
}

- (void)toggleIgnoreGroupSelection:(id)sender {
    (void)sender;
    self.ignoreGroupSelection = !self.ignoreGroupSelection;
    self.hasFaceSelection = NO;
    [self syncSelectionOverlay];
    [self updateChrome];
}

- (void)toggleTextureLock:(id)sender {
    (void)sender;
    self.textureLockEnabled = !self.textureLockEnabled;
    [self updateChrome];
}

// NSTableViewDataSource
- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView {
    (void)tableView;
    return (NSInteger)(self.filteredMaterials.count);
}

- (id)tableView:(NSTableView*)tableView objectValueForTableColumn:(NSTableColumn*)tableColumn row:(NSInteger)row {
    (void)tableView; (void)tableColumn;
    if (row < 0 || row >= (NSInteger)self.filteredMaterials.count) {
        return @"";
    }
    return self.filteredMaterials[(NSUInteger)row];
}

// NSSearchFieldDelegate (controlTextDidChange:)
- (void)controlTextDidChange:(NSNotification*)notification {
    if (notification.object == self.materialSearchField) {
        [self filterMaterials:self.materialSearchField.stringValue];
    }
}

- (void)setMaterialsDirectory:(NSString*)materialsDirectory {
    _materialsDirectory = [materialsDirectory copy];
    NSLog(@"[materials] directory set to: %@", materialsDirectory);
    for (VmfViewport* vp in self.viewports) {
        [vp setTextureDirectory:materialsDirectory];
    }
    [self startWatchingMaterialsDirectory:materialsDirectory];
    [self updateMaterialBrowser];
}

- (void)startWatchingMaterialsDirectory:(NSString*)path {
    [self stopWatchingMaterialsDirectory];
    if (!path.length) return;
    int fd = open(path.fileSystemRepresentation, O_EVTONLY);
    if (fd < 0) return;
    _directoryWatchFd = fd;
    __weak __typeof__(self) weakSelf = self;
    _directoryWatchSource = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd,
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
    if (_directoryWatchSource) {
        dispatch_source_cancel(_directoryWatchSource);
        _directoryWatchSource = nil;
        _directoryWatchFd = -1;
    }
}

- (void)materialsDirectoryDidChange {
    NSLog(@"[materials] directory changed — refreshing");
    // Full texture cache invalidation so removed/replaced files resolve correctly
    for (VmfViewport* vp in self.viewports) {
        [vp clearTextureCache];
    }
    [self updateMaterialBrowser];
    // Redraw immediately so viewports pick up the new/removed textures
    for (VmfViewport* vp in self.viewports) {
        [vp.metalView setNeedsDisplay:YES];
    }
}

- (void)chooseTexturesFolder:(id)sender {
    (void)sender;
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.title = @"Select Materials Folder";
    panel.message = @"Choose the folder containing texture images (mirrors the VMF material path hierarchy).";
    if (self.materialsDirectory) {
        panel.directoryURL = [NSURL fileURLWithPath:self.materialsDirectory];
    }
    if ([panel runModal] != NSModalResponseOK) {
        return;
    }
    NSString* path = panel.URL.path;
    self.materialsDirectory = path;
    [[NSUserDefaults standardUserDefaults] setObject:path forKey:@"materialsDirectory"];
}

- (void)updateWindowTitle {
    NSString* fileName = self.currentPath.lastPathComponent;
    if (fileName.length == 0) {
        fileName = self.hasDocument ? @"Untitled" : kAppDisplayName;
    }
    if (self.documentDirty) {
        fileName = [fileName stringByAppendingString:@" *"];
    }
    if (self.fileIndex.count > 1) {
        self.window.title = [NSString stringWithFormat:@"%@ - %@ (%zu/%zu)", kAppDisplayName, fileName, self.fileIndex.currentIndex + 1, self.fileIndex.count];
    } else {
        self.window.title = [NSString stringWithFormat:@"%@ - %@", kAppDisplayName, fileName];
    }
}

- (void)windowDidResize:(NSNotification*)notification {
    (void)notification;
    [self updateToolbarLayout];
    [self updateChrome];
}

- (void)windowWillClose:(NSNotification*)notification {
    (void)notification;
}

- (BOOL)windowShouldClose:(NSWindow*)sender {
    if (sender == self.materialBrowserPanel) {
        return YES;
    }
    return [self confirmDiscardChangesForAction:@"closing the window"];
}

- (void)showError:(NSString*)message {
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"%@ Error", kAppDisplayName];
    alert.informativeText = message;
    [alert runModal];
}

- (void)setActiveViewport:(VmfViewport*)activeViewport {
    _activeViewport = activeViewport;
    for (VmfViewport* viewport in self.viewports) {
        viewport.active = viewport == activeViewport;
    }
    [self updateChrome];
}

- (void)viewportDidBecomeActive:(VmfViewport*)viewport {
    [self setActiveViewport:viewport];
}

- (void)viewportDidRequestOpenDroppedPath:(NSString*)path {
    [self openPath:path];
}

- (void)viewport:(VmfViewport*)viewport handleKeyDown:(NSEvent*)event {
    [self setActiveViewport:viewport];
    [self handleKey:event];
}

- (void)viewport:(VmfViewport*)viewport handleKeyUp:(NSEvent*)event {
    (void)viewport;
    [self handleKeyUp:event];
}

- (BOOL)selectSolidAtPoint:(Vec3)point plane:(VmfViewportPlane)plane {
    size_t bestEntityIndex = 0;
    size_t bestSolidIndex = 0;
    float bestArea = FLT_MAX;
    BOOL found = NO;
    for (size_t entityIndex = 0; entityIndex < self.scene.entityCount; ++entityIndex) {
        for (size_t solidIndex = 0; solidIndex < self.scene.entities[entityIndex].solidCount; ++solidIndex) {
            Bounds3 bounds;
            char errorBuffer[128] = { 0 };
            if (!vmf_scene_solid_bounds(&_scene, entityIndex, solidIndex, &bounds, errorBuffer, sizeof(errorBuffer))) {
                continue;
            }
            if (bounds.min.raw[0] > bounds.max.raw[0]) {
                float tmp = bounds.min.raw[0]; bounds.min.raw[0] = bounds.max.raw[0]; bounds.max.raw[0] = tmp;
            }
            if (bounds.min.raw[1] > bounds.max.raw[1]) {
                float tmp = bounds.min.raw[1]; bounds.min.raw[1] = bounds.max.raw[1]; bounds.max.raw[1] = tmp;
            }
            if (bounds.min.raw[2] > bounds.max.raw[2]) {
                float tmp = bounds.min.raw[2]; bounds.min.raw[2] = bounds.max.raw[2]; bounds.max.raw[2] = tmp;
            }

            float minU = plane == VmfViewportPlaneZY ? bounds.min.raw[1] : bounds.min.raw[0];
            float maxU = plane == VmfViewportPlaneZY ? bounds.max.raw[1] : bounds.max.raw[0];
            float minV = plane == VmfViewportPlaneXY ? bounds.min.raw[1] : bounds.min.raw[2];
            float maxV = plane == VmfViewportPlaneXY ? bounds.max.raw[1] : bounds.max.raw[2];
            float u = plane == VmfViewportPlaneZY ? point.raw[1] : point.raw[0];
            float v = plane == VmfViewportPlaneXY ? point.raw[1] : point.raw[2];
            if (u < minU || u > maxU || v < minV || v > maxV) {
                continue;
            }

            float area = (maxU - minU) * (maxV - minV);
            if (!found || area < bestArea) {
                found = YES;
                bestArea = area;
                bestEntityIndex = entityIndex;
                bestSolidIndex = solidIndex;
            }
        }
    }

    if (!found && [self pickPointEntityAtPoint:point plane:plane outEntityIndex:&bestEntityIndex]) {
        found = YES;
        bestSolidIndex = 0;
    }

    self.hasSelection = found;
    self.selectedEntityIndex = bestEntityIndex;
    self.selectedSolidIndex = bestSolidIndex;
    self.hasFaceSelection = NO;
    self.selectedSideIndex = 0;
    self.editingPrefab = found ? [self prefabContainingEntityIndex:bestEntityIndex solidIndex:bestSolidIndex] : nil;
    if (self.editorTool == VmfViewportEditorToolVertex) {
        // End old session (commit if valid, revert if not), then start a new one.
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
        // Clicked empty space — end session (revert if invalid).
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

- (void)viewport:(VmfViewport*)viewport requestHoverRayOrigin:(Vec3)origin direction:(Vec3)direction {
    (void)viewport;
    if (!self.hasDocument || !self.textureApplicationModeActive) {
        if (self.hasHoveredFace) {
            self.hasHoveredFace = NO;
            for (VmfViewport* vp in self.viewports) {
                [vp setHighlightedFaceEntityIndex:0 solidIndex:0 sideIndex:0 visible:NO];
            }
        }
        return;
    }

    size_t entityIndex = 0;
    size_t solidIndex = 0;
    size_t sideIndex = 0;
    Vec3 hitPoint = vec3_make(0.0f, 0.0f, 0.0f);
    char errorBuffer[256] = { 0 };
    if (!vmf_scene_pick_ray(&_scene, origin, direction, &entityIndex, &solidIndex, &sideIndex, &hitPoint, errorBuffer, sizeof(errorBuffer))) {
        if (self.hasHoveredFace) {
            self.hasHoveredFace = NO;
            for (VmfViewport* vp in self.viewports) {
                [vp setHighlightedFaceEntityIndex:0 solidIndex:0 sideIndex:0 visible:NO];
            }
        }
        return;
    }

    self.hasHoveredFace = YES;
    self.hoveredEntityIndex = entityIndex;
    self.hoveredSolidIndex = solidIndex;
    self.hoveredSideIndex = sideIndex;
    for (VmfViewport* vp in self.viewports) {
        [vp setHighlightedFaceEntityIndex:entityIndex solidIndex:solidIndex sideIndex:sideIndex visible:YES];
    }
}

- (void)viewport:(VmfViewport*)viewport requestSampleRayOrigin:(Vec3)origin direction:(Vec3)direction {
    (void)viewport;
    if (!self.hasDocument || !self.textureApplicationModeActive) {
        return;
    }

    size_t entityIndex = 0;
    size_t solidIndex = 0;
    size_t sideIndex = 0;
    Vec3 hitPoint = vec3_make(0.0f, 0.0f, 0.0f);
    char errorBuffer[256] = { 0 };
    if (!vmf_scene_pick_ray(&_scene, origin, direction, &entityIndex, &solidIndex, &sideIndex, &hitPoint, errorBuffer, sizeof(errorBuffer))) {
        return;
    }

    if (entityIndex < _scene.entityCount &&
        solidIndex < _scene.entities[entityIndex].solidCount &&
        sideIndex < _scene.entities[entityIndex].solids[solidIndex].sideCount) {
        const char* mat = _scene.entities[entityIndex].solids[solidIndex].sides[sideIndex].material;
        self.brushMaterialName = [NSString stringWithUTF8String:mat];
        [self updateChrome];
    }
}

- (void)viewport:(VmfViewport*)viewport requestPaintRayOrigin:(Vec3)origin direction:(Vec3)direction {
    (void)viewport;
    if (!self.hasDocument || !self.textureApplicationModeActive) return;

    size_t entityIndex = 0, solidIndex = 0, sideIndex = 0;
    Vec3 hitPoint = vec3_make(0.0f, 0.0f, 0.0f);
    char errorBuffer[256] = { 0 };
    if (!vmf_scene_pick_ray(&_scene, origin, direction, &entityIndex, &solidIndex, &sideIndex, &hitPoint, errorBuffer, sizeof(errorBuffer))) {
        return;
    }
    SceneHistoryEntry* entry = [self captureHistoryEntry];
    if (!entry) return;
    if (!vmf_scene_set_side_material(&_scene, entityIndex, solidIndex, sideIndex,
                                      self.brushMaterialName.UTF8String,
                                      errorBuffer, sizeof(errorBuffer))) {
        [self showError:[NSString stringWithUTF8String:errorBuffer]];
        return;
    }
    [self pushUndoEntry:entry];
    [self markDocumentChangedWithLabel:@"Paint Face"];
    [self rebuildMeshFromScene];
}

- (void)viewport:(VmfViewport*)viewport requestPaintAlignRayOrigin:(Vec3)origin direction:(Vec3)direction {
    (void)viewport;
    if (!self.hasDocument || !self.textureApplicationModeActive) return;

    size_t entityIndex = 0, solidIndex = 0, sideIndex = 0;
    Vec3 hitPoint = vec3_make(0.0f, 0.0f, 0.0f);
    char errorBuffer[256] = { 0 };
    if (!vmf_scene_pick_ray(&_scene, origin, direction, &entityIndex, &solidIndex, &sideIndex, &hitPoint, errorBuffer, sizeof(errorBuffer))) {
        return;
    }
    SceneHistoryEntry* entry = [self captureHistoryEntry];
    if (!entry) return;
    if (!vmf_scene_set_side_material(&_scene, entityIndex, solidIndex, sideIndex,
                                      self.brushMaterialName.UTF8String,
                                      errorBuffer, sizeof(errorBuffer))) {
        [self showError:[NSString stringWithUTF8String:errorBuffer]];
        return;
    }
    size_t seedSideIndex = sideIndex;
    if (self.hasSelection && self.hasFaceSelection &&
        self.selectedEntityIndex == entityIndex &&
        self.selectedSolidIndex == solidIndex) {
        seedSideIndex = self.selectedSideIndex;
    }
    if (!vmf_scene_wrap_align_solid_from_side(&_scene, entityIndex, solidIndex, seedSideIndex,
                                              errorBuffer, sizeof(errorBuffer))) {
        [self showError:[NSString stringWithUTF8String:errorBuffer]];
        return;
    }
    self.hasSelection = YES;
    self.selectedEntityIndex = entityIndex;
    self.selectedSolidIndex = solidIndex;
    self.hasFaceSelection = YES;
    self.selectedSideIndex = seedSideIndex;
    [self pushUndoEntry:entry];
    [self markDocumentChangedWithLabel:@"Paint Face (Aligned)"];
    [self rebuildMeshFromScene];
}

- (void)viewport:(VmfViewport*)viewport requestFaceSelectionOnEdge:(VmfViewportSelectionEdge)edge {
    if ([self selectionIsPrefab] || [self selectionActsAsGroupedBrushEntity]) {
        return;
    }
    if (![self isSelectedSolidBoxBrush]) {
        return;
    }

    NSInteger sideIndex = [self sideIndexForPlane:viewport.plane edge:edge];
    if (sideIndex < 0) {
        return;
    }
    self.hasFaceSelection = YES;
    self.selectedSideIndex = (size_t)sideIndex;
    [self syncSelectionOverlay];
}

- (void)viewport:(VmfViewport*)viewport updateSelectionVertexAtIndex:(size_t)vertexIndex position:(Vec3)position commit:(BOOL)commit {
    (void)viewport;
    [self moveSelectedVerticesAtIndices:&vertexIndex positions:&position count:1 commit:commit];
}

- (void)viewport:(VmfViewport*)viewport updateSelectionVerticesAtIndices:(const size_t*)indices positions:(const Vec3*)positions count:(size_t)count commit:(BOOL)commit {
    (void)viewport;
    [self moveSelectedVerticesAtIndices:indices positions:positions count:count commit:commit];
}

- (void)viewport:(VmfViewport*)viewport updateSelectionEdgeFirstSideIndex:(size_t)firstSideIndex secondSideIndex:(size_t)secondSideIndex offset:(Vec3)offset commit:(BOOL)commit {
    (void)viewport;
    [self moveSelectedEdgeFirstSideIndex:firstSideIndex secondSideIndex:secondSideIndex offset:offset commit:commit];
}

- (void)viewport:(VmfViewport*)viewport clipSelectionFrom:(Vec3)start to:(Vec3)end {
    [self clipSelectedSolidFrom:start to:end plane:viewport.plane];
}

- (void)viewport:(VmfViewport*)viewport updateSelectionBounds:(Bounds3)bounds commit:(BOOL)commit transform:(VmfViewportSelectionTransform)transform {
    (void)viewport;
    if (transform == VmfViewportSelectionTransformResize && !self.hasSelection) {
        return;
    }

    if (transform == VmfViewportSelectionTransformMove && !self.hasSelection) {
        return;
    }

    if ([self selectionIsPointEntity]) {
        if (transform != VmfViewportSelectionTransformMove) {
            return;
        }

        Bounds3 currentBounds = bounds3_empty();
        if (![self selectedEntityBounds:&currentBounds]) {
            return;
        }

        Vec3 delta = vec3_sub(bounds3_center(bounds), bounds3_center(currentBounds));
        if (vec3_length(delta) < 0.001f) {
            if (commit && self.pendingHistoryEntry) {
                [self commitPendingHistoryEntry];
            }
            return;
        }
        if (![self beginPendingHistoryEntryWithLabel:@"Move Entity"]) {
            return;
        }

        char errorBuffer[256] = { 0 };
        if (!vmf_scene_translate_entity(&_scene, self.selectedEntityIndex, delta, self.textureLockEnabled ? 1 : 0, errorBuffer, sizeof(errorBuffer))) {
            [self discardPendingHistoryEntry];
            return;
        }
        [self rebuildMeshFromScene];
        if (commit) {
            [self commitPendingHistoryEntry];
        }
        return;
    }

    if ([self selectionActsAsGroupedBrushEntity]) {
        if (transform != VmfViewportSelectionTransformMove) {
            return;
        }

        Bounds3 currentBounds = bounds3_empty();
        if (![self selectedEntityBounds:&currentBounds]) {
            return;
        }

        Vec3 delta = vec3_sub(bounds3_center(bounds), bounds3_center(currentBounds));
        if (vec3_length(delta) < 0.001f) {
            if (commit && self.pendingHistoryEntry) {
                [self commitPendingHistoryEntry];
            }
            return;
        }
        if (![self beginPendingHistoryEntryWithLabel:@"Move Group"]) {
            return;
        }

        char errorBuffer[256] = { 0 };
        if (!vmf_scene_translate_entity(&_scene, self.selectedEntityIndex, delta, self.textureLockEnabled ? 1 : 0, errorBuffer, sizeof(errorBuffer))) {
            [self discardPendingHistoryEntry];
            return;
        }
        [self rebuildMeshFromScene];
        if (commit) {
            [self commitPendingHistoryEntry];
        }
        return;
    }

    ProceduralShapePrefab* prefab = [self prefabContainingEntityIndex:self.selectedEntityIndex solidIndex:self.selectedSolidIndex];
    Bounds3 currentBounds = bounds3_empty();
    if (prefab) {
        currentBounds = prefab.bounds;
    } else {
        char currentErrorBuffer[256] = { 0 };
        if (!vmf_scene_solid_bounds(&_scene, self.selectedEntityIndex, self.selectedSolidIndex, &currentBounds, currentErrorBuffer, sizeof(currentErrorBuffer))) {
            return;
        }
    }
    if (prefab) {
        NSString* prefabHistoryLabel = transform == VmfViewportSelectionTransformResize ? @"Resize Prefab" : @"Move Prefab";
        if (!self.pendingHistoryEntry) {
            if (bounds_equal(bounds, currentBounds)) {
                return;
            }
            if (![self beginPendingHistoryEntryWithLabel:prefabHistoryLabel]) {
                return;
            }
        }

        if (transform == VmfViewportSelectionTransformMove) {
            Vec3 delta = vec3_sub(bounds.min, currentBounds.min);
            Bounds3 updatedBounds = prefab.bounds;
            updatedBounds.min = vec3_add(updatedBounds.min, delta);
            updatedBounds.max = vec3_add(updatedBounds.max, delta);
            prefab.bounds = updatedBounds;
        } else {
            prefab.bounds = bounds;
        }

        char prefabErrorBuffer[256] = { 0 };
        if (![self rebuildPrefab:prefab errorBuffer:prefabErrorBuffer size:sizeof(prefabErrorBuffer)]) {
            [self discardPendingHistoryEntry];
            [self rebuildMeshFromScene];
            if (commit) {
                [self showError:[NSString stringWithUTF8String:prefabErrorBuffer]];
            }
            return;
        }
        if (commit) {
            [self commitPendingHistoryEntry];
        }
        return;
    }

    if (commit && !self.pendingHistoryEntry) {
        if (bounds_equal(bounds, currentBounds)) {
            return;
        }
    }

    NSString* historyLabel = transform == VmfViewportSelectionTransformResize ? @"Resize Brush" : @"Move Brush";
    if (![self beginPendingHistoryEntryWithLabel:historyLabel]) {
        return;
    }

    char errorBuffer[256] = { 0 };
    if (transform == VmfViewportSelectionTransformMove) {
        Vec3 delta = vec3_sub(bounds.min, currentBounds.min);
        if (!vmf_scene_translate_solid(&_scene, self.selectedEntityIndex, self.selectedSolidIndex, delta, self.textureLockEnabled ? 1 : 0, errorBuffer, sizeof(errorBuffer))) {
            [self discardPendingHistoryEntry];
            return;
        }
    } else {
        if (![self restoreSceneFromPendingHistorySnapshot:errorBuffer size:sizeof(errorBuffer)]) {
            [self discardPendingHistoryEntry];
            return;
        }
        if (!vmf_scene_set_solid_bounds(&_scene, self.selectedEntityIndex, self.selectedSolidIndex, bounds, errorBuffer, sizeof(errorBuffer))) {
            [self discardPendingHistoryEntry];
            return;
        }
    }
    [self rebuildMeshFromScene];
    if (commit) {
        [self commitPendingHistoryEntry];
    }
}

- (void)viewport:(VmfViewport*)viewport createBlockWithBounds:(Bounds3)bounds {
    (void)viewport;
    if (!self.hasDocument) {
        [self newDocument:nil];
    }

    SceneHistoryEntry* entry = [self captureHistoryEntry];
    if (!entry) {
        return;
    }

    char errorBuffer[256] = { 0 };
    size_t entityIndex = 0;
    size_t solidIndex = 0;
    if (!vmf_scene_add_block_brush(&_scene, bounds, self.brushMaterialName.UTF8String, &entityIndex, &solidIndex, errorBuffer, sizeof(errorBuffer))) {
        [self showError:[NSString stringWithUTF8String:errorBuffer]];
        return;
    }
    self.hasSelection = YES;
    self.selectedEntityIndex = entityIndex;
    self.selectedSolidIndex = solidIndex;
    self.hasFaceSelection = NO;
    self.selectedSideIndex = 0;
    [self pushUndoEntry:entry];
    [self markDocumentChangedWithLabel:@"Create Brush"];
    [self rebuildMeshFromScene];
}

- (void)viewport:(VmfViewport*)viewport createCylinderWithBounds:(Bounds3)bounds {
    [self beginShapeSettingsSessionForTool:VmfViewportEditorToolCylinder viewport:viewport bounds:bounds historyLabel:@"Create Cylinder"];
}

- (void)viewport:(VmfViewport*)viewport createRampWithBounds:(Bounds3)bounds {
    if (!self.hasDocument) {
        [self newDocument:nil];
    }

    SceneHistoryEntry* entry = [self captureHistoryEntry];
    if (!entry) {
        return;
    }

    char errorBuffer[256] = { 0 };
    size_t entityIndex = 0;
    size_t solidIndex = 0;
    if (!vmf_scene_add_ramp_brush(&_scene,
                                  bounds,
                                  [self activeBrushAxis],
                                  [self runBrushAxisForViewport:viewport],
                                  self.brushMaterialName.UTF8String,
                                  &entityIndex,
                                  &solidIndex,
                                  errorBuffer,
                                  sizeof(errorBuffer))) {
        [self showError:[NSString stringWithUTF8String:errorBuffer]];
        return;
    }

    self.hasSelection = YES;
    self.selectedEntityIndex = entityIndex;
    self.selectedSolidIndex = solidIndex;
    self.hasFaceSelection = NO;
    self.selectedSideIndex = 0;
    [self pushUndoEntry:entry];
    [self markDocumentChangedWithLabel:@"Create Ramp"];
    [self rebuildMeshFromScene];
}

- (void)viewport:(VmfViewport*)viewport createStairsWithBounds:(Bounds3)bounds {
    [self beginShapeSettingsSessionForTool:VmfViewportEditorToolStairs viewport:viewport bounds:bounds historyLabel:@"Create Stairs"];
}

- (void)viewport:(VmfViewport*)viewport createArchWithBounds:(Bounds3)bounds {
    [self beginShapeSettingsSessionForTool:VmfViewportEditorToolArch viewport:viewport bounds:bounds historyLabel:@"Create Arch"];
}

@end
