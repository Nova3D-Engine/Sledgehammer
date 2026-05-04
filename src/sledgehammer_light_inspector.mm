#import "sledgehammer_viewer_app_internal.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation ViewerAppDelegate (LightInspector)

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
    self.lightSpotSettingsView.translatesAutoresizingMaskIntoConstraints = NO;
    self.lightSpotSettingsView.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.lightSpotSettingsView.alignment = NSLayoutAttributeLeading;
    self.lightSpotSettingsView.spacing = 8.0;

    [self.lightSpotSettingsView addArrangedSubview:[self inspectorSectionLabel:@"Spot Inner"]];
    self.lightSpotInnerValueLabel = [self inspectorBodyLabel:@"20.0 deg"];
    [self.lightSpotSettingsView addArrangedSubview:self.lightSpotInnerValueLabel];
    self.lightSpotInnerSlider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    self.lightSpotInnerSlider.minValue = 1.0;
    self.lightSpotInnerSlider.maxValue = 89.0;
    self.lightSpotInnerSlider.continuous = NO;
    self.lightSpotInnerSlider.target = self;
    self.lightSpotInnerSlider.action = @selector(lightSpotInnerChanged:);
    [self.lightSpotSettingsView addArrangedSubview:self.lightSpotInnerSlider];

    [self.lightSpotSettingsView addArrangedSubview:[self inspectorSectionLabel:@"Spot Outer"]];
    self.lightSpotOuterValueLabel = [self inspectorBodyLabel:@"35.0 deg"];
    [self.lightSpotSettingsView addArrangedSubview:self.lightSpotOuterValueLabel];
    self.lightSpotOuterSlider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    self.lightSpotOuterSlider.minValue = 2.0;
    self.lightSpotOuterSlider.maxValue = 90.0;
    self.lightSpotOuterSlider.continuous = NO;
    self.lightSpotOuterSlider.target = self;
    self.lightSpotOuterSlider.action = @selector(lightSpotOuterChanged:);
    [self.lightSpotSettingsView addArrangedSubview:self.lightSpotOuterSlider];

    self.lightEnabledButton = [NSButton checkboxWithTitle:@"Enabled" target:self action:@selector(lightEnabledChanged:)];
    self.lightCastShadowsButton = [NSButton checkboxWithTitle:@"Cast Shadows" target:self action:@selector(lightCastShadowsChanged:)];
    [container addArrangedSubview:self.lightSpotSettingsView];
    [container addArrangedSubview:self.lightEnabledButton];
    [container addArrangedSubview:self.lightCastShadowsButton];

    self.lightInspectorView = container;
}

- (VmfEntity*)selectedLightEntity {
    if (![self selectionIsPointEntity] || self.selectedEntityIndex >= self.scene.entityCount) {
        return NULL;
    }
    VmfEntity* entity = &_scene.entities[self.selectedEntityIndex];
    return entity->kind == VmfEntityKindLight ? entity : NULL;
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

- (void)commitImmediateLightEditWithEntry:(SceneHistoryEntry*)entry label:(NSString*)label {
    if (!entry) {
        return;
    }
    [self pushUndoEntry:entry];
    [self markDocumentChangedWithLabel:label];
    [self syncSceneWorldLightsFromScene];
    [self refreshInspector];
    [self updateWindowTitle];
    [self updateChrome];
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

@end
#pragma clang diagnostic pop