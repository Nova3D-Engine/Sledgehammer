#import "sledgehammer_viewer_app_internal.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation ViewerAppDelegate (LightInspector)

- (NSStackView*)lightInspectorSliderRowWithField:(NSTextField* __strong *)outField
                                          slider:(NSSlider* __strong *)outSlider
                                             min:(double)minValue
                                             max:(double)maxValue
                                          action:(SEL)action {
    NSStackView* row = [[NSStackView alloc] initWithFrame:NSZeroRect];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.distribution = NSStackViewDistributionFill;
    row.spacing = 8.0;

    NSTextField* field = [self inspectorNumericFieldWithAction:action];
    [field setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [field setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [row addArrangedSubview:field];

    NSSlider* slider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    slider.minValue = minValue;
    slider.maxValue = maxValue;
    slider.continuous = NO;
    slider.target = self;
    slider.action = action;
    slider.translatesAutoresizingMaskIntoConstraints = NO;
    [slider setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [slider setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [slider.widthAnchor constraintGreaterThanOrEqualToConstant:150.0].active = YES;
    [row addArrangedSubview:slider];
    [row.widthAnchor constraintGreaterThanOrEqualToConstant:240.0].active = YES;

    if (outField != NULL) {
        *outField = field;
    }
    if (outSlider != NULL) {
        *outSlider = slider;
    }
    return row;
}

- (void)buildLightInspectorView {
    if (self.lightInspectorView) {
        return;
    }

    NSStackView* container = [[NSStackView alloc] initWithFrame:NSZeroRect];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.orientation = NSUserInterfaceLayoutOrientationVertical;
    container.alignment = NSLayoutAttributeLeading;
    container.distribution = NSStackViewDistributionFill;
    container.spacing = 10.0;

    [container addArrangedSubview:[self inspectorSectionLabel:@"Light"]];

    self.lightNameLabel = [self inspectorBodyLabel:@"Light"];
    [container addArrangedSubview:self.lightNameLabel];

    [container addArrangedSubview:[self inspectorSectionLabel:@"Type"]];
    self.lightTypePopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.lightTypePopUp addItemsWithTitles:@[ @"Point", @"Spot", @"Sun" ]];
    [[self.lightTypePopUp itemAtIndex:0] setTag:UI_LIGHT_POINT];
    [[self.lightTypePopUp itemAtIndex:1] setTag:UI_LIGHT_SPOT];
    [[self.lightTypePopUp itemAtIndex:2] setTag:UI_LIGHT_SUN];
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
    NSTextField* lightIntensityField = nil;
    NSSlider* lightIntensitySlider = nil;
    [container addArrangedSubview:[self lightInspectorSliderRowWithField:&lightIntensityField
                                                                  slider:&lightIntensitySlider
                                                                     min:0.1
                                                                     max:200.0
                                                                  action:@selector(lightIntensityChanged:)]];
    self.lightIntensityValueLabel = lightIntensityField;
    self.lightIntensitySlider = lightIntensitySlider;

    [container addArrangedSubview:[self inspectorSectionLabel:@"Range"]];
    NSTextField* lightRangeField = nil;
    NSSlider* lightRangeSlider = nil;
    [container addArrangedSubview:[self lightInspectorSliderRowWithField:&lightRangeField
                                                                  slider:&lightRangeSlider
                                                                     min:64.0
                                                                     max:4096.0
                                                                  action:@selector(lightRangeChanged:)]];
    self.lightRangeValueLabel = lightRangeField;
    self.lightRangeSlider = lightRangeSlider;

    self.lightSourceSizeLabel = [self inspectorSectionLabel:@"Source Radius"];
    [container addArrangedSubview:self.lightSourceSizeLabel];
    NSTextField* lightSourceSizeField = nil;
    NSSlider* lightSourceSizeSlider = nil;
    [container addArrangedSubview:[self lightInspectorSliderRowWithField:&lightSourceSizeField
                                                                  slider:&lightSourceSizeSlider
                                                                     min:0.25
                                                                     max:128.0
                                                                  action:@selector(lightSourceSizeChanged:)]];
    self.lightSourceSizeValueLabel = lightSourceSizeField;
    self.lightSourceSizeSlider = lightSourceSizeSlider;

    self.lightSpotSettingsView = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.lightSpotSettingsView.translatesAutoresizingMaskIntoConstraints = NO;
    self.lightSpotSettingsView.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.lightSpotSettingsView.alignment = NSLayoutAttributeLeading;
    self.lightSpotSettingsView.distribution = NSStackViewDistributionFill;
    self.lightSpotSettingsView.spacing = 8.0;

    [self.lightSpotSettingsView addArrangedSubview:[self inspectorSectionLabel:@"Spot Inner"]];
    NSTextField* lightSpotInnerField = nil;
    NSSlider* lightSpotInnerSlider = nil;
    [self.lightSpotSettingsView addArrangedSubview:[self lightInspectorSliderRowWithField:&lightSpotInnerField
                                                                                   slider:&lightSpotInnerSlider
                                                                                      min:1.0
                                                                                      max:89.0
                                                                                   action:@selector(lightSpotInnerChanged:)]];
    self.lightSpotInnerValueLabel = lightSpotInnerField;
    self.lightSpotInnerSlider = lightSpotInnerSlider;

    [self.lightSpotSettingsView addArrangedSubview:[self inspectorSectionLabel:@"Spot Outer"]];
    NSTextField* lightSpotOuterField = nil;
    NSSlider* lightSpotOuterSlider = nil;
    [self.lightSpotSettingsView addArrangedSubview:[self lightInspectorSliderRowWithField:&lightSpotOuterField
                                                                                   slider:&lightSpotOuterSlider
                                                                                      min:2.0
                                                                                      max:90.0
                                                                                   action:@selector(lightSpotOuterChanged:)]];
    self.lightSpotOuterValueLabel = lightSpotOuterField;
    self.lightSpotOuterSlider = lightSpotOuterSlider;

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
    BOOL isSunLight = entity->lightType == UI_LIGHT_SUN;
    NSInteger selectedType = entity->lightType;
    if (selectedType != UI_LIGHT_POINT && selectedType != UI_LIGHT_SPOT && selectedType != UI_LIGHT_SUN) {
        selectedType = UI_LIGHT_POINT;
    }
    self.lightNameLabel.stringValue = displayName;
    [self.lightTypePopUp selectItemWithTag:selectedType];
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
    self.lightSourceSizeLabel.stringValue = isSunLight ? @"Angular Diameter" : @"Source Radius";
    self.lightSourceSizeSlider.minValue = isSunLight ? 0.1 : 0.25;
    self.lightSourceSizeSlider.maxValue = isSunLight ? 5.0 : 128.0;
    self.lightSourceSizeSlider.doubleValue = isSunLight ? fmax(entity->sourceSize, 0.53f) : fmax(entity->sourceSize, 0.25f);
    self.lightSourceSizeValueLabel.stringValue = isSunLight
        ? [NSString stringWithFormat:@"%.2f", fmax(entity->sourceSize, 0.53f)]
        : [NSString stringWithFormat:@"%.2f", fmax(entity->sourceSize, 0.25f)];
    self.lightSpotInnerSlider.doubleValue = entity->spotInnerDegrees;
    self.lightSpotOuterSlider.minValue = entity->spotInnerDegrees;
    self.lightSpotOuterSlider.doubleValue = fmax(entity->spotOuterDegrees, entity->spotInnerDegrees);
    self.lightSpotInnerValueLabel.stringValue = [NSString stringWithFormat:@"%.1f", entity->spotInnerDegrees];
    self.lightSpotOuterValueLabel.stringValue = [NSString stringWithFormat:@"%.1f", fmax(entity->spotOuterDegrees, entity->spotInnerDegrees)];
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
    VmfEntity* entity = [self selectedLightEntity];
    if (entity == NULL) {
        return;
    }

    SceneHistoryEntry* entry = [self captureHistoryEntry];
    double value = [sender respondsToSelector:@selector(doubleValue)] ? [sender doubleValue] : self.lightIntensitySlider.doubleValue;
    entity->intensity = fmaxf((float)value, 0.1f);
    [self commitImmediateLightEditWithEntry:entry label:@"Edit Light Intensity"];
}

- (void)lightRangeChanged:(id)sender {
    VmfEntity* entity = [self selectedLightEntity];
    if (entity == NULL) {
        return;
    }

    SceneHistoryEntry* entry = [self captureHistoryEntry];
    double value = [sender respondsToSelector:@selector(doubleValue)] ? [sender doubleValue] : self.lightRangeSlider.doubleValue;
    entity->range = fmaxf((float)value, 64.0f);
    [self commitImmediateLightEditWithEntry:entry label:@"Edit Light Range"];
}

- (void)lightSourceSizeChanged:(id)sender {
    VmfEntity* entity = [self selectedLightEntity];
    if (entity == NULL) {
        return;
    }

    SceneHistoryEntry* entry = [self captureHistoryEntry];
    double value = [sender respondsToSelector:@selector(doubleValue)] ? [sender doubleValue] : self.lightSourceSizeSlider.doubleValue;
    if (entity->lightType == UI_LIGHT_SUN) {
        entity->sourceSize = fmaxf((float)value, 0.1f);
    } else {
        entity->sourceSize = fmaxf((float)value, 0.25f);
    }
    [self commitImmediateLightEditWithEntry:entry label:@"Edit Light Source Size"];
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
        entity->sourceSize = fmaxf(entity->sourceSize, 8.0f);
        strncpy(entity->classname, "light", sizeof(entity->classname) - 1);
        entity->classname[sizeof(entity->classname) - 1] = '\0';
    } else if (entity->lightType == UI_LIGHT_SUN) {
        entity->sourceSize = fmaxf(entity->sourceSize, 0.53f);
        entity->castShadows = 1;
        strncpy(entity->classname, "light_sun", sizeof(entity->classname) - 1);
        entity->classname[sizeof(entity->classname) - 1] = '\0';
    } else {
        entity->sourceSize = fmaxf(entity->sourceSize, 8.0f);
        strncpy(entity->classname, "light", sizeof(entity->classname) - 1);
        entity->classname[sizeof(entity->classname) - 1] = '\0';
    }
    [self commitImmediateLightEditWithEntry:entry label:@"Edit Light Type"];
}

- (void)lightSpotInnerChanged:(id)sender {
    VmfEntity* entity = [self selectedLightEntity];
    if (entity == NULL) {
        return;
    }

    SceneHistoryEntry* entry = [self captureHistoryEntry];
    double value = [sender respondsToSelector:@selector(doubleValue)] ? [sender doubleValue] : self.lightSpotInnerSlider.doubleValue;
    entity->spotInnerDegrees = fminf(fmaxf((float)value, 1.0f), 89.0f);
    entity->spotOuterDegrees = fmaxf(fminf(entity->spotOuterDegrees, 90.0f), entity->spotInnerDegrees);
    [self commitImmediateLightEditWithEntry:entry label:@"Edit Spot Inner Cone"];
}

- (void)lightSpotOuterChanged:(id)sender {
    VmfEntity* entity = [self selectedLightEntity];
    if (entity == NULL) {
        return;
    }

    SceneHistoryEntry* entry = [self captureHistoryEntry];
    double value = [sender respondsToSelector:@selector(doubleValue)] ? [sender doubleValue] : self.lightSpotOuterSlider.doubleValue;
    entity->spotOuterDegrees = fminf(fmaxf((float)value, entity->spotInnerDegrees), 90.0f);
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
