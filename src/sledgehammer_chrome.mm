#import "sledgehammer_viewer_app_internal.h"

#import <CoreText/CoreText.h>

static NSString* const kAppDisplayName = @"Sledgehammer";

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

static NSString* clip_mode_label(ViewerClipMode mode) {
    switch (mode) {
        case ViewerClipModeA:
            return @"Keep A";
        case ViewerClipModeB:
            return @"Keep B";
        case ViewerClipModeBoth:
        default:
            return @"Keep Both";
    }
}

static NSAttributedString* material_icon_menu_title(NSString* iconName, NSString* label) {
    NSMutableAttributedString* title = [[NSMutableAttributedString alloc] init];
    NSFont* iconFont = [NSFont fontWithName:@"Material Symbols Outlined" size:15.0];
    if (iconFont != nil) {
        [title appendAttributedString:[[NSAttributedString alloc] initWithString:iconName
                                                                       attributes:@{ NSFontAttributeName: iconFont }]];
        [title appendAttributedString:[[NSAttributedString alloc] initWithString:@"  "]];
    }
    [title appendAttributedString:[[NSAttributedString alloc] initWithString:label]];
    return title;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation ViewerAppDelegate (SledgehammerChrome)

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
    [appMenu addItemWithTitle:@"Set Textures Folder…" action:@selector(chooseTexturesFolder:) keyEquivalent:@""];
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
    [viewMenu addItemWithTitle:@"Path Traced" action:@selector(setPathTracedMode:) keyEquivalent:@"3"];
    [viewMenu addItemWithTitle:@"Frame Scene" action:@selector(frameScene:) keyEquivalent:@"k"];
    [viewMenu addItemWithTitle:@"Bake Preview Lighting (1 Bounce GI)" action:@selector(bakePreviewLighting:) keyEquivalent:@"j"];
    [viewMenu addItemWithTitle:@"Show Lightmap Debug" action:@selector(showLightmapDebugWindow:) keyEquivalent:@""];
    NSMenuItem* contentBrowserItem = [viewMenu addItemWithTitle:@"Toggle Content Browser" action:@selector(toggleContentBrowser:) keyEquivalent:@"c"];
    contentBrowserItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    NSMenuItem* importModelsItem = [viewMenu addItemWithTitle:@"Import Models To Content Browser..." action:@selector(importModelsToContentBrowser:) keyEquivalent:@"i"];
    importModelsItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    [viewMenu addItemWithTitle:@"Next File" action:@selector(nextDocument:) keyEquivalent:@"n"];
    [viewMenu addItemWithTitle:@"Previous File" action:@selector(previousDocument:) keyEquivalent:@"p"];
    [viewItem setSubmenu:viewMenu];

    NSMenuItem* toolsItem = [[NSMenuItem alloc] initWithTitle:@"Tools" action:nil keyEquivalent:@""];
    [mainMenu addItem:toolsItem];
    NSMenu* toolsMenu = [[NSMenu alloc] initWithTitle:@"Tools"];
    [toolsMenu addItemWithTitle:@"Selection Tool" action:@selector(setSelectTool:) keyEquivalent:@"v"];
    [toolsMenu addItemWithTitle:@"Vertex Tool" action:@selector(setVertexTool:) keyEquivalent:@"m"];
    [toolsMenu addItemWithTitle:@"Block Tool" action:@selector(setBlockTool:) keyEquivalent:@"b"];
    [toolsMenu addItemWithTitle:@"Cylinder Tool" action:@selector(setCylinderTool:) keyEquivalent:@"c"];
    [toolsMenu addItemWithTitle:@"Ramp Tool" action:@selector(setRampTool:) keyEquivalent:@"g"];
    [toolsMenu addItemWithTitle:@"Stairs Tool" action:@selector(setStairsTool:) keyEquivalent:@"t"];
    [toolsMenu addItemWithTitle:@"Arch Tool" action:@selector(setArchTool:) keyEquivalent:@"a"];
    [toolsMenu addItemWithTitle:@"Clip Tool" action:@selector(setClipTool:) keyEquivalent:@"x"];
    [toolsMenu addItem:[NSMenuItem separatorItem]];
    [toolsMenu addItemWithTitle:@"Add Light" action:@selector(addLightEntity:) keyEquivalent:@"l"];
    [toolsItem setSubmenu:toolsMenu];

    NSMenuItem* pluginsItem = [[NSMenuItem alloc] initWithTitle:@"Plugins" action:nil keyEquivalent:@""];
    [mainMenu addItem:pluginsItem];
    self.pluginsMenu = [[NSMenu alloc] initWithTitle:@"Plugins"];
    [self.pluginsMenu addItemWithTitle:@"Reload Plugins" action:@selector(reloadPlugins:) keyEquivalent:@""];
    [self.pluginsMenu addItem:[NSMenuItem separatorItem]];
    self.pluginMenuDynamicStartIndex = self.pluginsMenu.numberOfItems;
    [pluginsItem setSubmenu:self.pluginsMenu];

    NSMenuItem* groupsItem = [[NSMenuItem alloc] initWithTitle:@"Groups" action:nil keyEquivalent:@""];
    [mainMenu addItem:groupsItem];
    NSMenu* groupsMenu = [[NSMenu alloc] initWithTitle:@"Groups"];
    [groupsMenu addItemWithTitle:@"Create Group" action:@selector(createGroupFromSelection:) keyEquivalent:@"g"];
    NSMenuItem* addToGroupItem = [groupsMenu addItemWithTitle:@"Add Selection To Active Group" action:@selector(addSelectionToActiveGroup:) keyEquivalent:@"G"];
    addToGroupItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [groupsMenu addItemWithTitle:@"Ungroup" action:@selector(ungroupSelection:) keyEquivalent:@"u"];
    [groupsItem setSubmenu:groupsMenu];

    NSMenuItem* lightBakingItem = [[NSMenuItem alloc] initWithTitle:@"Light Baking" action:nil keyEquivalent:@""];
    [mainMenu addItem:lightBakingItem];
    NSMenu* lightBakingMenu = [[NSMenu alloc] initWithTitle:@"Light Baking"];
    NSMenuItem* openDebugLightmapItem = [lightBakingMenu addItemWithTitle:@"Show Lightmap Debug" action:@selector(showLightmapDebugWindow:) keyEquivalent:@""];
    openDebugLightmapItem.attributedTitle = material_icon_menu_title(@"deployed_code_update", @"Show Lightmap Debug");
    [lightBakingItem setSubmenu:lightBakingMenu];

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
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
}

- (StyledSplitView*)newSplitViewVertical:(BOOL)vertical {
    StyledSplitView* splitView = [[StyledSplitView alloc] initWithFrame:NSZeroRect];
    splitView.vertical = vertical;
    splitView.translatesAutoresizingMaskIntoConstraints = NO;
    splitView.autosaveName = @"";
    splitView.dividerStyle = NSSplitViewDividerStyleThin;
    return splitView;
}

- (void)layoutViewportSplitsEqually {
    [self.rootView layoutSubtreeIfNeeded];

    CGFloat horizontalDivider = self.topSplitView.dividerThickness;
    CGFloat verticalDivider = self.verticalSplitView.dividerThickness;
    CGFloat topWidth = NSWidth(self.topSplitView.bounds);
    CGFloat bottomWidth = NSWidth(self.bottomSplitView.bounds);
    CGFloat verticalHeight = NSHeight(self.verticalSplitView.bounds);

    if (topWidth > horizontalDivider) {
        CGFloat midTop = floor((topWidth - horizontalDivider) * 0.5);
        [self.topSplitView setPosition:midTop ofDividerAtIndex:0];
    }
    if (bottomWidth > horizontalDivider) {
        CGFloat midBottom = floor((bottomWidth - horizontalDivider) * 0.5);
        [self.bottomSplitView setPosition:midBottom ofDividerAtIndex:0];
    }
    if (verticalHeight > verticalDivider) {
        CGFloat midVertical = floor((verticalHeight - verticalDivider) * 0.5);
        [self.verticalSplitView setPosition:midVertical ofDividerAtIndex:0];
    }
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
        [viewport setVmfScene:&_scene];
        [viewport setSceneWorld:_sceneWorld];
    }

    [self.topSplitView addSubview:self.topViewport];
    [self.topSplitView addSubview:self.perspectiveViewport];
    [self.bottomSplitView addSubview:self.frontViewport];
    [self.bottomSplitView addSubview:self.sideViewport];

    [self.verticalSplitView addSubview:self.topSplitView];
    [self.verticalSplitView addSubview:self.bottomSplitView];
    [self.rootView addSubview:self.verticalSplitView];

    self.verticalSplitBottomConstraint = [self.verticalSplitView.bottomAnchor constraintEqualToAnchor:self.rootView.bottomAnchor constant:-54.0];

    [NSLayoutConstraint activateConstraints:@[
        [self.verticalSplitView.leadingAnchor constraintEqualToAnchor:self.rootView.leadingAnchor constant:80.0],
        [self.verticalSplitView.trailingAnchor constraintEqualToAnchor:self.rootView.trailingAnchor constant:-324.0],
        [self.verticalSplitView.topAnchor constraintEqualToAnchor:self.rootView.topAnchor constant:68.0],
        self.verticalSplitBottomConstraint,
    ]];

    [self layoutViewportSplitsEqually];
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

    self.renderControl = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.renderControl addItemsWithTitles:@[ @"Wireframe", @"Shaded", @"Path Traced" ]];
    [[self.renderControl itemAtIndex:0] setTag:VmfViewportRenderModeWireframe];
    [[self.renderControl itemAtIndex:1] setTag:VmfViewportRenderModeShaded];
    [[self.renderControl itemAtIndex:2] setTag:VmfViewportRenderModePathTraced];
    self.renderControl.target = self;
    self.renderControl.action = @selector(renderControlChanged:);

    self.materialPopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
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
    self.inspectorPanel.hidden = !self.hasDocument;
    self.contentBrowserPanel.hidden = !self.hasDocument;
    self.contentBrowserImportButton.enabled = self.hasDocument;
    self.contentBrowserBodyView.hidden = self.contentBrowserCollapsed || !self.hasDocument;
    self.contentBrowserBodyView.alphaValue = self.contentBrowserCollapsed || !self.hasDocument ? 0.0 : 1.0;
    self.contentBrowserHeightConstraint.constant = self.hasDocument ? (self.contentBrowserCollapsed ? 42.0 : 330.0) : 0.0;
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
    [self.renderControl selectItemWithTag:viewport.renderMode];
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

@end
#pragma clang diagnostic pop
