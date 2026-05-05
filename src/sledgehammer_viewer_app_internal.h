#ifndef SLEDGEHAMMER_VIEWER_APP_INTERNAL_H
#define SLEDGEHAMMER_VIEWER_APP_INTERNAL_H

#import "viewer_app.h"

#import <Cocoa/Cocoa.h>

#include "file_index.h"
#include "nova_scene_ecs.h"
#include "sledgehammer_plugin_api.h"
#include "viewport.h"
#include "vmf_geometry.h"
#include "vmf_parser.h"

@class SledgehammerLoadedPluginRecord;
@class SledgehammerPluginCommandTarget;
@interface StyledSplitView : NSSplitView

@end

@interface ProceduralShapePrefab : NSObject <NSCopying>

@property(nonatomic, assign) VmfViewportEditorTool tool;
@property(nonatomic, assign) Bounds3 bounds;
@property(nonatomic, assign) VmfBrushAxis upAxis;
@property(nonatomic, assign) VmfBrushAxis runAxis;
@property(nonatomic, assign) NSInteger primaryValue;
@property(nonatomic, assign) CGFloat secondaryValue;
@property(nonatomic, assign) size_t solidCount;
@property(nonatomic, copy) NSString* historyLabel;
@property(nonatomic, assign) size_t entityIndex;
@property(nonatomic, assign) size_t startSolidIndex;

@end

@interface SceneHistoryEntry : NSObject {
@public
    VmfScene scene;
    NSInteger revision;
    NSString* stateLabel;
    NSArray<ProceduralShapePrefab*>* prefabState;
    BOOL hasSelection;
    size_t selectedEntityIndex;
    size_t selectedSolidIndex;
    BOOL hasFaceSelection;
    size_t selectedSideIndex;
}

@end

typedef NS_ENUM(NSUInteger, ViewerClipMode) {
    ViewerClipModeBoth = 0,
    ViewerClipModeA = 1,
    ViewerClipModeB = 2,
};

@interface ViewerAppDelegate () <VmfViewportDelegate, NSMenuDelegate, NSMenuItemValidation, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate> {
    FileIndex _fileIndex;
    VmfScene _scene;
    ViewerMesh _mesh;
    NovaSceneWorld* _sceneWorld;
    NSString* _materialsDirectory;
    dispatch_source_t _directoryWatchSource;
    int _directoryWatchFd;
    BOOL _hasVertexEditSession;
    size_t _vertexEditEntityIndex;
    size_t _vertexEditSolidIndex;
    Vec3 _draftVertices[VMF_MAX_SOLID_VERTICES];
    size_t _draftVertexCount;
    size_t _draftEdgeConnVA[VMF_MAX_SOLID_EDGES];
    size_t _draftEdgeConnVB[VMF_MAX_SOLID_EDGES];
    VmfSolidEdge _draftEdgeTemplates[VMF_MAX_SOLID_EDGES];
    size_t _draftEdgeConnCount;
    BOOL _draftIsValid;
    Vec3 _draftFaceRefNormals[128];
    size_t _draftFaceSideIndices[128];
    size_t _draftFaceCount;
    BOOL _hasPointEntityDragPreview;
    size_t _pointEntityDragEntityIndex;
    Bounds3 _pointEntityDragBounds;
}

@property(nonatomic, strong) NSWindow* window;
@property(nonatomic, strong) NSView* rootView;
@property(nonatomic, strong) StyledSplitView* verticalSplitView;
@property(nonatomic, strong) NSLayoutConstraint* verticalSplitBottomConstraint;
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
@property(nonatomic, strong) NSMenu* pluginsMenu;
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
@property(nonatomic, assign) NovaSceneWorld* sceneWorld;
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
@property(nonatomic, strong) NSVisualEffectView* contentBrowserPanel;
@property(nonatomic, strong) NSButton* contentBrowserTabButton;
@property(nonatomic, strong) NSButton* contentBrowserImportButton;
@property(nonatomic, strong) NSView* contentBrowserBodyView;
@property(nonatomic, strong) NSScrollView* contentBrowserScrollView;
@property(nonatomic, strong) NSView* contentBrowserGridView;
@property(nonatomic, strong) NSTextField* contentBrowserStatusLabel;
@property(nonatomic, strong) NSLayoutConstraint* contentBrowserHeightConstraint;
@property(nonatomic, strong) NSLayoutConstraint* inspectorBottomConstraint;
@property(nonatomic, strong) NSMutableArray<NSDictionary<NSString*, id>*>* contentBrowserItems;
@property(nonatomic, assign) BOOL contentBrowserCollapsed;
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
@property(nonatomic, copy) NSString* pluginsDirectory;
@property(nonatomic, assign) NSInteger pluginMenuDynamicStartIndex;
@property(nonatomic, strong) NSMutableDictionary<NSString*, SledgehammerLoadedPluginRecord*>* loadedPluginsBySourcePath;
@property(nonatomic, strong) NSMutableArray<SledgehammerPluginCommandTarget*>* pluginCommandTargets;
@property(nonatomic, strong) dispatch_source_t pluginDirectoryWatchSource;
@property(nonatomic, assign) int pluginDirectoryWatchFd;

- (void)showError:(NSString*)message;
- (NSModalResponse)runModelImportSettingsModalForURL:(NSURL*)url outAssetName:(NSString**)outAssetName outScale:(float*)outScale error:(NSString**)outError;
- (BOOL)confirmDiscardChangesForAction:(NSString*)actionDescription;
- (void)createMenu;
- (void)createWindow;
- (void)buildMacUI;
- (void)buildInspectorUI;
- (NSTextField*)inspectorSectionLabel:(NSString*)title;
- (NSTextField*)inspectorBodyLabel:(NSString*)value;
- (void)buildFaceTextureInspectorView;
- (void)buildLightInspectorView;
- (void)buildViewportLayoutWithDevice:(id<MTLDevice>)device;
- (void)frameAllViewports;
- (BOOL)rebuildMeshFromScene;
- (BOOL)rebuildMeshFromSceneSyncHeavyRenderer:(BOOL)syncHeavyRenderer;
- (void)syncSceneWorldLightsFromScene;
- (void)refreshInspector;
- (void)refreshFaceTextureInspector;
- (void)refreshLightInspector;
- (void)refreshToolRailSelection;
- (BOOL)saveDocumentIfNeeded;
- (BOOL)saveDocumentAsWithPrompt;
- (void)refreshViewportsFromCurrentMeshSyncHeavyRenderer:(BOOL)syncHeavyRenderer clearingMaterialMisses:(BOOL)clearMaterialMisses;
- (void)layoutViewportSplitsEqually;
- (void)openPath:(NSString*)path;
- (void)loadVmfAtPath:(NSString*)path;
- (nullable NSString*)texturePathForInspectorMaterial:(NSString*)materialName;
- (BOOL)textureDimensionsForMaterial:(NSString*)materialName width:(float*)outWidth height:(float*)outHeight;
- (void)resetDocumentState;
- (void)resetHistory;
- (void)resetRevisionTracking;
- (void)reloadDocument:(id)sender;
- (BOOL)restoreHistoryEntry:(SceneHistoryEntry*)entry;
- (BOOL)beginPendingHistoryEntryWithLabel:(NSString*)label;
- (SceneHistoryEntry*)captureHistoryEntry;
- (void)commitPendingHistoryEntry;
- (void)discardPendingHistoryEntry;
- (NSString*)displayHistoryLabel:(NSString*)label fallback:(NSString*)fallback;
- (void)undoAction:(id)sender;
- (void)redoAction:(id)sender;
- (void)jumpToHistoryState:(id)sender;
- (void)markDocumentChangedWithLabel:(NSString*)label;
- (ProceduralShapePrefab*)prefabContainingEntityIndex:(size_t)entityIndex solidIndex:(size_t)solidIndex;
- (VmfEntity*)selectedLightEntity;
- (void)pushUndoEntry:(SceneHistoryEntry*)entry;
- (void)rebuildHistoryMenu;
- (void)removePrefab:(ProceduralShapePrefab*)prefab;
- (BOOL)restoreSceneFromHistoryEntrySnapshot:(SceneHistoryEntry*)entry errorBuffer:(char*)errorBuffer size:(size_t)errorBufferSize;
- (BOOL)restoreSceneFromPendingHistorySnapshot:(char*)errorBuffer size:(size_t)errorBufferSize;
- (BOOL)selectionIsPrefab;
- (VmfViewportSelectionEdge)selectionEdgeForPlane:(VmfViewportPlane)plane sideIndex:(size_t)sideIndex;
- (void)collapseEditingPrefab:(id)sender;
- (void)commitImmediateLightEditWithEntry:(SceneHistoryEntry*)entry label:(NSString*)label;
- (void)commitFaceTextureEditWithLabel:(NSString*)label
                             operation:(BOOL (^)(size_t entityIndex,
                                                 size_t solidIndex,
                                                 size_t sideIndex,
                                                 char* errorBuffer,
                                                 size_t errorBufferSize))operation;
- (void)lightColorChanged:(id)sender;
- (void)lightIntensityChanged:(id)sender;
- (void)lightRangeChanged:(id)sender;
- (void)lightTypeChanged:(id)sender;
- (void)lightSpotInnerChanged:(id)sender;
- (void)lightSpotOuterChanged:(id)sender;
- (void)lightEnabledChanged:(id)sender;
- (void)lightCastShadowsChanged:(id)sender;
- (void)faceTextureTransformChanged:(id)sender;
- (void)faceTextureRotationChanged:(id)sender;
- (void)faceTextureFlipPressed:(id)sender;
- (void)faceTextureJustifyPressed:(id)sender;
- (void)shiftPrefabIndicesInEntity:(size_t)entityIndex startingAtSolidIndex:(size_t)solidIndex delta:(NSInteger)delta excludingPrefab:(ProceduralShapePrefab*)excludedPrefab;
- (size_t)solidCountForShapeTool:(VmfViewportEditorTool)tool primaryValue:(NSInteger)primaryValue;
- (BOOL)entityIndexIsGroupedBrushEntity:(size_t)entityIndex;
- (BOOL)selectionIsGroupedBrushEntity;
- (BOOL)selectionActsAsGroupedBrushEntity;
- (size_t)entityIndexForEntityId:(int)entityId;
- (size_t)activeGroupEntityIndex;
- (NSString*)nextGroupName;
- (BOOL)selectionIsPointEntity;
- (BOOL)selectedEntityBounds:(Bounds3*)outBounds;
- (BOOL)selectionHasEditableFaceTexture;
- (BOOL)isSelectedSolidBoxBrush;
- (BOOL)selectSolidAtPoint:(Vec3)point plane:(VmfViewportPlane)plane;
- (void)createGroupFromSelection:(id)sender;
- (void)addSelectionToActiveGroup:(id)sender;
- (void)ungroupSelection:(id)sender;
- (void)syncSelectionOverlay;
- (void)startVertexEditSession;
- (void)pushDraftOverlayToViewports;
- (void)syncDirtyState;
- (void)updateMaterialBrowser;
- (void)updateHistoryMenuTitles;
- (void)updateToolbarLayout;
- (void)updateChrome;
- (void)updateWindowTitle;
- (void)endVertexEditSession:(BOOL)tryApply;
- (BOOL)pickPointEntityRayOrigin:(Vec3)origin direction:(Vec3)direction outEntityIndex:(size_t*)outEntityIndex;
- (void)invokePluginRecord:(SledgehammerLoadedPluginRecord*)plugin commandIndex:(NSUInteger)commandIndex;
- (void)buildContentBrowserUI;
- (void)reloadContentBrowser;
- (void)setContentBrowserCollapsed:(BOOL)collapsed animated:(BOOL)animated;
- (void)configurePlugins;
- (void)reloadPlugins:(id)sender;
- (void)startWatchingMaterialsDirectory:(NSString*)path;
- (void)materialsDirectoryDidChange;
- (void)unloadAllPlugins;
- (void)stopWatchingPluginsDirectory;
- (void)stopWatchingMaterialsDirectory;

@end

#endif