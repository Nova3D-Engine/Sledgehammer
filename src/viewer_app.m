#import "viewer_app.h"
#import "sledgehammer_viewer_app_internal.h"

#include <fcntl.h>
#include <float.h>
#include <dlfcn.h>

#import <CoreText/CoreText.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "nova_scene_ecs.h"
#include "nova_ui_state.h"
#include "novamodel_asset.h"

#import "file_index.h"
#include "sledgehammer_editor_logic.h"
#import "sledgehammer_plugin_api.h"
#include "sledgehammer_viewer_mesh_ops.h"
#import "viewport.h"
#import "vmf_editor.h"
#import "vmf_geometry.h"
#import "vmf_parser.h"

@class SledgehammerLoadedPluginRecord;
@class SledgehammerPluginCommandTarget;

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

@implementation ViewerAppDelegate

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

- (VmfViewportSelectionEdge)selectionEdgeForPlane:(VmfViewportPlane)plane sideIndex:(size_t)sideIndex {
    return (VmfViewportSelectionEdge)sledgehammer_editor_logic_selection_edge_for_plane((int)plane, sideIndex);
}

- (NSInteger)sideIndexForPlane:(VmfViewportPlane)plane edge:(VmfViewportSelectionEdge)edge {
    return (NSInteger)sledgehammer_editor_logic_side_index_for_plane((int)plane, (int)edge);
}

- (Vec3)duplicateOffsetForActiveViewport {
    return sledgehammer_editor_logic_duplicate_offset_for_plane((int)self.activeViewport.plane, (float)self.gridSize);
}

- (VmfBrushAxis)activeBrushAxis {
    VmfViewport* viewport = self.activeViewport ? self.activeViewport : self.topViewport;
    return sledgehammer_editor_logic_active_brush_axis_for_plane((int)viewport.plane);
}

- (VmfBrushAxis)runBrushAxisForViewport:(VmfViewport*)viewport {
    return sledgehammer_editor_logic_run_brush_axis_for_plane((int)viewport.plane);
}

- (size_t)solidCountForShapeTool:(VmfViewportEditorTool)tool primaryValue:(NSInteger)primaryValue {
    return sledgehammer_editor_logic_solid_count_for_shape_tool((int)tool, (int)primaryValue);
}

- (BOOL)entityIndexIsGroupedBrushEntity:(size_t)entityIndex {
    return sledgehammer_editor_logic_entity_is_grouped_brush(&_scene, entityIndex) ? YES : NO;
}

- (BOOL)selectionIsGroupedBrushEntity {
    return sledgehammer_editor_logic_selection_is_grouped_brush(&_scene, self.hasSelection, self.selectedEntityIndex) ? YES : NO;
}

- (BOOL)selectionActsAsGroupedBrushEntity {
    return [self selectionIsGroupedBrushEntity] && !self.ignoreGroupSelection;
}

- (size_t)entityIndexForEntityId:(int)entityId {
    return sledgehammer_editor_logic_entity_index_for_id(&_scene, entityId);
}

- (size_t)activeGroupEntityIndex {
    return sledgehammer_editor_logic_active_group_entity_index(&_scene,
                                                               self.hasSelection,
                                                               self.selectedEntityIndex,
                                                               self.activeGroupEntityId);
}

- (NSString*)nextGroupName {
    size_t groupCount = sledgehammer_editor_logic_grouped_brush_entity_count(&_scene);
    return [NSString stringWithFormat:@"Group %lu", (unsigned long)(groupCount + 1)];
}

- (BOOL)selectionIsPointEntity {
    return sledgehammer_editor_logic_selection_is_point_entity(&_scene, self.hasSelection, self.selectedEntityIndex) ? YES : NO;
}

- (BOOL)pickPointEntityAtPoint:(Vec3)point plane:(VmfViewportPlane)plane outEntityIndex:(size_t*)outEntityIndex {
    return sledgehammer_editor_logic_pick_point_entity_at_point(&_scene, point, (int)plane, outEntityIndex) ? YES : NO;
}

- (BOOL)pickPointEntityRayOrigin:(Vec3)origin direction:(Vec3)direction outEntityIndex:(size_t*)outEntityIndex {
    return sledgehammer_editor_logic_pick_point_entity_ray(&_scene, origin, direction, outEntityIndex) ? YES : NO;
}

- (NSInteger)defaultShapePrimaryValueForTool:(VmfViewportEditorTool)tool bounds:(Bounds3)bounds {
    return (NSInteger)sledgehammer_editor_logic_default_shape_primary_value((int)tool,
                                                                            bounds,
                                                                            self.activeShapeSessionUpAxis,
                                                                            self.activeShapeSessionRunAxis,
                                                                            (float)self.gridSize);
}

- (NSInteger)minimumShapePrimaryValueForTool:(VmfViewportEditorTool)tool {
    return (NSInteger)sledgehammer_editor_logic_minimum_shape_primary_value((int)tool);
}

- (NSInteger)maximumShapePrimaryValueForTool:(VmfViewportEditorTool)tool {
    return (NSInteger)sledgehammer_editor_logic_maximum_shape_primary_value((int)tool);
}

- (NSString*)shapePrimaryLabelForTool:(VmfViewportEditorTool)tool {
    return [NSString stringWithUTF8String:sledgehammer_editor_logic_shape_primary_label((int)tool)];
}

- (BOOL)toolHasSecondaryShapeSetting:(VmfViewportEditorTool)tool {
    return sledgehammer_editor_logic_tool_has_secondary_shape_setting((int)tool) ? YES : NO;
}

- (NSString*)shapeSecondaryLabelForTool:(VmfViewportEditorTool)tool {
    return [NSString stringWithUTF8String:sledgehammer_editor_logic_shape_secondary_label((int)tool)];
}

- (CGFloat)defaultShapeSecondaryValueForTool:(VmfViewportEditorTool)tool {
    return (CGFloat)sledgehammer_editor_logic_default_shape_secondary_value((int)tool);
}

- (NSString*)shapeSettingsPanelTitleForTool:(VmfViewportEditorTool)tool {
    return [NSString stringWithUTF8String:sledgehammer_editor_logic_shape_settings_panel_title((int)tool)];
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
    [self buildContentBrowserUI];

    self.verticalSplitBottomConstraint.active = NO;
    self.verticalSplitBottomConstraint = [self.verticalSplitView.bottomAnchor constraintEqualToAnchor:self.contentBrowserPanel.topAnchor constant:-12.0];
    self.verticalSplitBottomConstraint.active = YES;

    [self.inspectorPanel addSubview:self.inspectorStack];
    [self.rootView addSubview:self.inspectorPanel];

    self.inspectorBottomConstraint = [self.inspectorPanel.bottomAnchor constraintEqualToAnchor:self.contentBrowserPanel.topAnchor constant:-12.0];

    [NSLayoutConstraint activateConstraints:@[
        [self.inspectorPanel.trailingAnchor constraintEqualToAnchor:self.rootView.trailingAnchor constant:-12.0],
        [self.inspectorPanel.topAnchor constraintEqualToAnchor:self.verticalSplitView.topAnchor],
        self.inspectorBottomConstraint,
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

- (void)refreshGenericInspector {
    [self buildGenericInspectorView];

    NSString* details = @"Select a brush, prefab, light, or model to edit it here.";
    if (self.editingPrefab) {
        details = [NSString stringWithFormat:@"Prefab with %zu solids. Use the controls above to regenerate it.", self.editingPrefab.solidCount];
    } else if ([self selectionIsPointEntity] && self.selectedEntityIndex < self.scene.entityCount) {
        const VmfEntity* entity = &self.scene.entities[self.selectedEntityIndex];
        if (entity->kind == VmfEntityKindLight) {
            details = [NSString stringWithFormat:@"%@ light. %s, %s.",
                       light_type_label(entity->lightType),
                       entity->enabled ? "enabled" : "disabled",
                       entity->castShadows ? "casts shadows" : "no shadows"];
        } else {
            NSString* assetName = [[NSString stringWithUTF8String:entity->modelAssetPath] lastPathComponent];
            details = [NSString stringWithFormat:@"Model instance: %@ at %.0f, %.0f, %.0f.",
                       assetName.length > 0 ? assetName : @"(missing asset)",
                       entity->position.raw[0],
                       entity->position.raw[1],
                       entity->position.raw[2]];
        }
    } else if (self.hasSelection && self.selectedEntityIndex < self.scene.entityCount) {
        const VmfEntity* entity = &self.scene.entities[self.selectedEntityIndex];
        details = [NSString stringWithFormat:@"Brush selection in entity %d with %zu solids.", entity->id, entity->solidCount];
    }

    self.genericInspectorDetailsLabel.stringValue = details;
}

- (void)refreshInspector {
    [self buildInspectorUI];

    NSString* title = @"Inspector";
    NSString* subtitle = @"Select a brush, prefab, light, or model to edit it.";
    if (self.editingPrefab) {
        title = [self shapeSettingsPanelTitleForTool:self.editingPrefab.tool];
        subtitle = @"Procedural prefab settings are docked here now.";
    } else if ([self selectionIsPointEntity]) {
        const VmfEntity* entity = self.selectedEntityIndex < self.scene.entityCount ? &self.scene.entities[self.selectedEntityIndex] : NULL;
        if (entity != NULL && entity->kind == VmfEntityKindModel) {
            title = @"Model";
            subtitle = @"Model placement is editable through the viewport and saved in the scene.";
        } else {
            title = @"Light";
            subtitle = @"Point and spot light properties update the scene and renderer live.";
        }
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

- (BOOL)currentMeshContainsMaterialNamed:(NSString*)materialName {
    if (materialName.length == 0 || self.mesh.faceRanges == NULL) {
        return NO;
    }

    for (size_t rangeIndex = 0; rangeIndex < self.mesh.faceRangeCount; ++rangeIndex) {
        const ViewerFaceRange* range = &self.mesh.faceRanges[rangeIndex];
        if (strcmp(range->material, materialName.UTF8String) == 0) {
            return YES;
        }
    }
    return NO;
}

- (void)refreshViewportsFromCurrentMeshSyncHeavyRenderer:(BOOL)syncHeavyRenderer clearingMaterialMisses:(BOOL)clearMaterialMisses {
    for (VmfViewport* viewport in self.viewports) {
        [viewport updateMesh:&_mesh syncHeavyRenderer:syncHeavyRenderer];
        if (self.materialsDirectory) {
            if (clearMaterialMisses) {
                [viewport clearTextureMissCache];
            }
            [viewport setTextureDirectory:self.materialsDirectory];
        }
    }
    [self syncSceneWorldLightsFromScene];
    [self syncSelectionOverlay];
    [self updateMaterialBrowser];
    [self updateWindowTitle];
    [self updateChrome];
}

- (void)refreshViewportsFromCurrentMeshClearingMaterialMisses:(BOOL)clearMaterialMisses {
    [self refreshViewportsFromCurrentMeshSyncHeavyRenderer:YES clearingMaterialMisses:clearMaterialMisses];
}

- (void)applyMaterialToCurrentMesh:(NSString*)materialName entityIndex:(size_t)entityIndex solidIndex:(size_t)solidIndex sideIndex:(size_t)sideIndex wholeSolid:(BOOL)wholeSolid {
    if (materialName.length == 0 || self.mesh.faceRanges == NULL) {
        return;
    }

    for (size_t rangeIndex = 0; rangeIndex < self.mesh.faceRangeCount; ++rangeIndex) {
        ViewerFaceRange* range = &self.mesh.faceRanges[rangeIndex];
        if (range->entityIndex != entityIndex || range->solidIndex != solidIndex) {
            continue;
        }
        if (!wholeSolid && range->sideIndex != sideIndex) {
            continue;
        }
        snprintf(range->material, sizeof(range->material), "%s", materialName.UTF8String);
    }
}

- (void)applyMaterialToCurrentMeshForEntity:(size_t)entityIndex materialName:(NSString*)materialName {
    if (materialName.length == 0 || self.mesh.faceRanges == NULL) {
        return;
    }

    for (size_t rangeIndex = 0; rangeIndex < self.mesh.faceRangeCount; ++rangeIndex) {
        ViewerFaceRange* range = &self.mesh.faceRanges[rangeIndex];
        if (range->entityIndex != entityIndex) {
            continue;
        }
        snprintf(range->material, sizeof(range->material), "%s", materialName.UTF8String);
    }
}

- (void)commitMaterialOnlyEditWithEntry:(SceneHistoryEntry*)entry
                                 label:(NSString*)label
                 introducedNewMaterial:(BOOL)introducedNewMaterial {
    if (!entry) {
        return;
    }

    [self pushUndoEntry:entry];
    [self markDocumentChangedWithLabel:label];
    [self refreshViewportsFromCurrentMeshClearingMaterialMisses:introducedNewMaterial];
    [self refreshInspector];
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
    _draftIsValid = sledgehammer_editor_logic_is_draft_convex(_draftVertices,
                                                              _draftVertexCount,
                                                              _draftEdgeConnVA,
                                                              _draftEdgeConnVB,
                                                              _draftEdgeTemplates,
                                                              _draftEdgeConnCount,
                                                              _draftFaceRefNormals,
                                                              _draftFaceSideIndices,
                                                              _draftFaceCount) ? YES : NO;

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

    [self rebuildMeshFromSceneSyncHeavyRenderer:commit];
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
    if (action == @selector(bakePreviewLighting:)) {
        VmfViewport* viewport = self.activeViewport ? self.activeViewport : self.perspectiveViewport;
        return self.hasDocument && viewport != nil && viewport.dimension == VmfViewportDimension3D;
    }
    if (action == @selector(showLightmapDebugWindow:)) {
        VmfViewport* viewport = self.activeViewport ? self.activeViewport : self.perspectiveViewport;
        if (viewport.dimension != VmfViewportDimension3D) {
            viewport = self.perspectiveViewport;
        }
        menuItem.state = (viewport != nil && [viewport isLightmapDebugWindowVisible]) ? NSControlStateValueOn : NSControlStateValueOff;
        return self.hasDocument && viewport != nil && viewport.dimension == VmfViewportDimension3D;
    }
    if (action == @selector(toggleContentBrowser:)) {
        menuItem.state = self.contentBrowserCollapsed ? NSControlStateValueOff : NSControlStateValueOn;
        return self.hasDocument;
    }
    if (action == @selector(importModelsToContentBrowser:)) {
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
    } else if ([key isEqualToString:@"k"]) {
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

- (BOOL)rebuildMeshFromScene {
    return [self rebuildMeshFromSceneSyncHeavyRenderer:YES];
}

- (BOOL)rebuildMeshFromSceneSyncHeavyRenderer:(BOOL)syncHeavyRenderer {
    _hasPointEntityDragPreview = NO;
    viewer_mesh_free(&_mesh);
    char errorBuffer[512] = { 0 };
    if (!vmf_build_mesh(&_scene, &_mesh, errorBuffer, sizeof(errorBuffer))) {
        [self showError:[NSString stringWithUTF8String:errorBuffer]];
        return NO;
    }

    for (VmfViewport* viewport in self.viewports) {
        [viewport setVmfScene:&_scene];
    }
    [self refreshViewportsFromCurrentMeshSyncHeavyRenderer:syncHeavyRenderer clearingMaterialMisses:YES];
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

    nova_scene_world_sync_lights(_sceneWorld, records, lightCount);

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

- (void)bakePreviewLighting:(id)sender {
    (void)sender;
    VmfViewport* viewport = self.activeViewport ? self.activeViewport : self.perspectiveViewport;
    if (viewport.dimension != VmfViewportDimension3D) {
        viewport = self.perspectiveViewport;
    }
    [viewport startPreviewLightingBake];
}

- (void)showLightmapDebugWindow:(id)sender {
    (void)sender;
    VmfViewport* viewport = self.activeViewport ? self.activeViewport : self.perspectiveViewport;
    if (viewport.dimension != VmfViewportDimension3D) {
        viewport = self.perspectiveViewport;
    }
    [viewport setLightmapDebugWindowVisible:YES];
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

- (void)duplicateSelection:(id)sender {
    (void)sender;
    if (!self.hasSelection) {
        return;
    }

    if ([self selectionIsPointEntity]) {
        SceneHistoryEntry* entry = [self captureHistoryEntry];
        if (!entry) {
            return;
        }

        size_t duplicatedEntityIndex = 0;
        char errorBuffer[256] = { 0 };
        if (!vmf_scene_duplicate_entity(&_scene,
                                        self.selectedEntityIndex,
                                        [self duplicateOffsetForActiveViewport],
                                        &duplicatedEntityIndex,
                                        errorBuffer,
                                        sizeof(errorBuffer))) {
            [self showError:[NSString stringWithUTF8String:errorBuffer]];
            return;
        }

        self.hasSelection = YES;
        self.selectedEntityIndex = duplicatedEntityIndex;
        self.selectedSolidIndex = 0;
        self.hasFaceSelection = NO;
        self.selectedSideIndex = 0;
        [self pushUndoEntry:entry];
        [self markDocumentChangedWithLabel:@"Duplicate Entity"];
        [self rebuildMeshFromScene];
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
    BOOL introducedNewMaterial = ![self currentMeshContainsMaterialNamed:self.brushMaterialName];
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

    if ([self selectionActsAsGroupedBrushEntity]) {
        [self applyMaterialToCurrentMeshForEntity:self.selectedEntityIndex materialName:self.brushMaterialName];
    } else if (self.hasFaceSelection) {
        [self applyMaterialToCurrentMesh:self.brushMaterialName
                            entityIndex:self.selectedEntityIndex
                             solidIndex:self.selectedSolidIndex
                              sideIndex:self.selectedSideIndex
                             wholeSolid:NO];
    } else {
        [self applyMaterialToCurrentMesh:self.brushMaterialName
                            entityIndex:self.selectedEntityIndex
                             solidIndex:self.selectedSolidIndex
                              sideIndex:0
                             wholeSolid:YES];
    }

    [self commitMaterialOnlyEditWithEntry:entry
                                    label:[self selectionActsAsGroupedBrushEntity] ? @"Apply Group Material" : (self.hasFaceSelection ? @"Apply Face Material" : @"Apply Brush Material")
                    introducedNewMaterial:introducedNewMaterial];
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
    [self layoutViewportSplitsEqually];
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

- (void)placeModelAssetAtPath:(NSString*)path worldPoint:(Vec3)worldPoint {
    if (!self.hasDocument) {
        [self showError:@"Open or create a scene before placing a model."];
        return;
    }
    if (path.length == 0) {
        return;
    }

    Vec3 halfExtents = vec3_make(32.0f, 32.0f, 32.0f);
    NSString* error = nil;
    if (!sledgehammer_model_asset_bounds(path, NULL, &halfExtents, &error)) {
        [self showError:error ?: @"Failed to inspect model asset."];
        return;
    }

    SceneHistoryEntry* entry = [self captureHistoryEntry];
    if (!entry) {
        return;
    }

    size_t entityIndex = 0;
    char errorBuffer[512] = { 0 };
    NSString* displayName = path.lastPathComponent.stringByDeletingPathExtension;
    if (!vmf_scene_add_model_entity(&_scene,
                                    displayName.UTF8String,
                                    path.fileSystemRepresentation,
                                    vec3_add(worldPoint, vec3_make(0.0f, 0.0f, halfExtents.raw[2])),
                                    halfExtents,
                                    &entityIndex,
                                    errorBuffer,
                                    sizeof(errorBuffer))) {
        [self showError:[NSString stringWithUTF8String:errorBuffer]];
        return;
    }

    self.hasSelection = YES;
    self.selectedEntityIndex = entityIndex;
    self.selectedSolidIndex = 0;
    self.hasFaceSelection = NO;
    self.selectedSideIndex = 0;
    self.editingPrefab = nil;
    [self pushUndoEntry:entry];
    [self markDocumentChangedWithLabel:@"Place Model"];
    [self rebuildMeshFromScene];
}

- (void)viewport:(VmfViewport*)viewport didRequestPlaceDroppedPath:(NSString*)path atPoint:(Vec3)point {
    [self setActiveViewport:viewport];
    [self placeModelAssetAtPath:path worldPoint:point];
}

- (void)viewport:(VmfViewport*)viewport handleKeyDown:(NSEvent*)event {
    [self setActiveViewport:viewport];
    [self handleKey:event];
}

- (void)viewport:(VmfViewport*)viewport handleKeyUp:(NSEvent*)event {
    (void)viewport;
    [self handleKeyUp:event];
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
    BOOL introducedNewMaterial = ![self currentMeshContainsMaterialNamed:self.brushMaterialName];
    if (!vmf_scene_set_side_material(&_scene, entityIndex, solidIndex, sideIndex,
                                      self.brushMaterialName.UTF8String,
                                      errorBuffer, sizeof(errorBuffer))) {
        [self showError:[NSString stringWithUTF8String:errorBuffer]];
        return;
    }
    [self applyMaterialToCurrentMesh:self.brushMaterialName
                        entityIndex:entityIndex
                         solidIndex:solidIndex
                          sideIndex:sideIndex
                         wholeSolid:NO];
    [self commitMaterialOnlyEditWithEntry:entry label:@"Paint Face" introducedNewMaterial:introducedNewMaterial];
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

        _hasPointEntityDragPreview = NO;
        sledgehammer_viewer_mesh_translate_entity(&_mesh, self.selectedEntityIndex, delta);
        [self refreshViewportsFromCurrentMeshSyncHeavyRenderer:NO clearingMaterialMisses:NO];
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

        sledgehammer_viewer_mesh_translate_entity(&_mesh, self.selectedEntityIndex, delta);
        [self refreshViewportsFromCurrentMeshSyncHeavyRenderer:commit clearingMaterialMisses:NO];
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
            if (sledgehammer_viewer_mesh_bounds_equal(bounds, currentBounds)) {
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
        if (sledgehammer_viewer_mesh_bounds_equal(bounds, currentBounds)) {
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
        sledgehammer_viewer_mesh_translate_solid(&_mesh, self.selectedEntityIndex, self.selectedSolidIndex, delta);
        [self refreshViewportsFromCurrentMeshSyncHeavyRenderer:commit clearingMaterialMisses:NO];
    } else {
        if (![self restoreSceneFromPendingHistorySnapshot:errorBuffer size:sizeof(errorBuffer)]) {
            [self discardPendingHistoryEntry];
            return;
        }
        if (!vmf_scene_set_solid_bounds(&_scene, self.selectedEntityIndex, self.selectedSolidIndex, bounds, errorBuffer, sizeof(errorBuffer))) {
            [self discardPendingHistoryEntry];
            return;
        }
        if (![self rebuildMeshFromSceneSyncHeavyRenderer:commit]) {
            [self discardPendingHistoryEntry];
            return;
        }
    }
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
#pragma clang diagnostic pop
