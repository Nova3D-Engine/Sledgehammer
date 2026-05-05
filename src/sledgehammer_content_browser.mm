#import "sledgehammer_viewer_app_internal.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "novamodel_asset.h"

static NSString* const kSledgehammerModelAssetExtension = @"novamodel";

static NSString* sledgehammer_sanitized_model_asset_name(NSString* rawName) {
    NSString* trimmedName;

    if (rawName.length == 0) {
        return nil;
    }

    trimmedName = [[rawName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] stringByDeletingPathExtension];
    if (trimmedName.length == 0) {
        return nil;
    }

    trimmedName = [[trimmedName componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/:"]] componentsJoinedByString:@"_"];
    trimmedName = [trimmedName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmedName.length > 0 ? trimmedName : nil;
}

static NSString* sledgehammer_default_model_asset_name_for_url(NSURL* url) {
    NSString* sourceName;
    NSString* parentName;
    NSString* normalizedSourceName;

    if (url == nil) {
        return @"model";
    }

    sourceName = sledgehammer_sanitized_model_asset_name(url.lastPathComponent.stringByDeletingPathExtension);
    parentName = sledgehammer_sanitized_model_asset_name(url.URLByDeletingLastPathComponent.lastPathComponent);
    normalizedSourceName = sourceName.lowercaseString;

    if (sourceName.length == 0) {
        return parentName.length > 0 ? parentName : @"model";
    }

    if (([normalizedSourceName isEqualToString:@"scene"] ||
         [normalizedSourceName isEqualToString:@"model"] ||
         [normalizedSourceName isEqualToString:@"untitled"]) &&
        parentName.length > 0) {
        return parentName;
    }

    return sourceName;
}

@interface ContentBrowserAssetButton : NSButton <NSDraggingSource>

@property(nonatomic, copy) NSString* assetPath;

@end

@implementation ContentBrowserAssetButton

- (void)beginAssetDragWithEvent:(NSEvent*)event {
    if (self.assetPath.length == 0) {
        return;
    }

    NSURL* fileURL = [NSURL fileURLWithPath:self.assetPath];
    NSDraggingItem* draggingItem = [[NSDraggingItem alloc] initWithPasteboardWriter:fileURL];
    NSRect dragFrame = self.bounds;
    id dragContents = self.image != nil ? self.image : self.title;
    [draggingItem setDraggingFrame:dragFrame contents:dragContents];
    NSDraggingSession* session = [self beginDraggingSessionWithItems:@[draggingItem] event:event source:self];
    session.animatesToStartingPositionsOnCancelOrFail = YES;
}

- (void)mouseDown:(NSEvent*)event {
    if (self.assetPath.length == 0 || self.window == nil) {
        [super mouseDown:event];
        return;
    }

    NSPoint mouseDownPoint = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat dragThreshold = 4.0;
    BOOL startedDrag = NO;

    for (;;) {
        NSEvent* nextEvent = [self.window nextEventMatchingMask:(NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp)];
        if (nextEvent.type == NSEventTypeLeftMouseUp) {
            break;
        }

        NSPoint currentPoint = [self convertPoint:nextEvent.locationInWindow fromView:nil];
        CGFloat deltaX = currentPoint.x - mouseDownPoint.x;
        CGFloat deltaY = currentPoint.y - mouseDownPoint.y;
        if ((deltaX * deltaX + deltaY * deltaY) >= (dragThreshold * dragThreshold)) {
            [self beginAssetDragWithEvent:event];
            startedDrag = YES;
            break;
        }
    }

    if (!startedDrag && self.target != nil && self.action != NULL) {
        [NSApp sendAction:self.action to:self.target from:self];
    }
}

- (void)mouseDragged:(NSEvent*)event {
    if (self.assetPath.length == 0) {
        [super mouseDragged:event];
        return;
    }

    [self beginAssetDragWithEvent:event];
}

- (NSDragOperation)draggingSession:(NSDraggingSession*)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    (void)session;
    (void)context;
    return NSDragOperationCopy;
}

- (BOOL)ignoreModifierKeysForDraggingSession:(NSDraggingSession*)session {
    (void)session;
    return YES;
}

@end

static NSImage* sledgehammer_make_thumbnail_image(const NovaModelAssetThumbnail* thumbnail) {
    if (thumbnail == NULL || thumbnail->rgba8 == NULL || thumbnail->width == 0u || thumbnail->height == 0u) {
        return nil;
    }

    NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:nil
                      pixelsWide:(NSInteger)thumbnail->width
                      pixelsHigh:(NSInteger)thumbnail->height
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSCalibratedRGBColorSpace
                     bytesPerRow:(NSInteger)thumbnail->width * 4
                    bitsPerPixel:32];
    if (bitmap == nil || bitmap.bitmapData == NULL) {
        return nil;
    }

    memcpy(bitmap.bitmapData, thumbnail->rgba8, (size_t)thumbnail->width * (size_t)thumbnail->height * 4u);
    bitmap.size = NSMakeSize((CGFloat)thumbnail->width, (CGFloat)thumbnail->height);
    NSImage* image = [[NSImage alloc] initWithSize:NSMakeSize((CGFloat)thumbnail->width, (CGFloat)thumbnail->height)];
    [image addRepresentation:bitmap];
    [image setTemplate:NO];
    return image;
}

static NSImage* sledgehammer_make_placeholder_thumbnail_image(NSString* title) {
    NSSize size = NSMakeSize(192.0, 192.0);
    NSImage* image = [[NSImage alloc] initWithSize:size];
    [image lockFocus];

    NSGradient* gradient = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedRed:0.18 green:0.21 blue:0.26 alpha:1.0]
                                                         endingColor:[NSColor colorWithCalibratedRed:0.10 green:0.12 blue:0.16 alpha:1.0]];
    [gradient drawInRect:NSMakeRect(0.0, 0.0, size.width, size.height) angle:-90.0];

    [[NSColor colorWithCalibratedWhite:1.0 alpha:0.08] setFill];
    NSBezierPath* accentPath = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(18.0, 18.0, size.width - 36.0, size.height - 36.0) xRadius:18.0 yRadius:18.0];
    [accentPath fill];

    NSString* displayTitle = title.length > 0 ? title : @"Model";
    NSDictionary<NSAttributedStringKey, id>* attributes = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:18.0],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.98 alpha:1.0],
    };
    NSRect textRect = NSMakeRect(20.0, 20.0, size.width - 40.0, 48.0);
    [displayTitle drawInRect:textRect withAttributes:attributes];

    NSDictionary<NSAttributedStringKey, id>* subtitleAttributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.86 alpha:0.9],
    };
    [@"No embedded thumbnail" drawInRect:NSMakeRect(20.0, 54.0, size.width - 40.0, 24.0) withAttributes:subtitleAttributes];

    [image unlockFocus];
    [image setTemplate:NO];
    return image;
}

static NSString* sledgehammer_model_import_unit_label(uint32_t unit, uint32_t hintSource) {
    NSString* base = @"Unknown";
    switch (unit) {
        case NOVA_MODEL_IMPORT_UNIT_MILLIMETERS:
            base = @"Millimetres";
            break;
        case NOVA_MODEL_IMPORT_UNIT_CENTIMETERS:
            base = @"Centimetres";
            break;
        case NOVA_MODEL_IMPORT_UNIT_METERS:
            base = @"Metres";
            break;
        case NOVA_MODEL_IMPORT_UNIT_INCHES:
            base = @"Inches";
            break;
        case NOVA_MODEL_IMPORT_UNIT_FEET:
            base = @"Feet";
            break;
        default:
            break;
    }

    if (hintSource == NOVA_MODEL_IMPORT_UNIT_HINT_METADATA) {
        return [base stringByAppendingString:@" (metadata)"];
    }
    if (hintSource == NOVA_MODEL_IMPORT_UNIT_HINT_GLTF_DEFAULT) {
        return [base stringByAppendingString:@" (glTF default)"];
    }
    return base;
}

static NSString* sledgehammer_model_import_size_string(const float boundsMin[3], const float boundsMax[3], float scale) {
    float sizeX = (boundsMax[0] - boundsMin[0]) * scale;
    float sizeY = (boundsMax[1] - boundsMin[1]) * scale;
    float sizeZ = (boundsMax[2] - boundsMin[2]) * scale;
    return [NSString stringWithFormat:@"%.2f x %.2f x %.2f", sizeX, sizeY, sizeZ];
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation ViewerAppDelegate (SledgehammerContentBrowser)

- (void)buildContentBrowserUI {
    if (self.contentBrowserPanel != nil) {
        return;
    }

    self.contentBrowserPanel = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    self.contentBrowserPanel.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentBrowserPanel.material = NSVisualEffectMaterialSidebar;
    self.contentBrowserPanel.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    self.contentBrowserPanel.state = NSVisualEffectStateActive;
    self.contentBrowserPanel.wantsLayer = YES;
    self.contentBrowserPanel.layer.cornerRadius = 8.0;
    self.contentBrowserPanel.layer.masksToBounds = YES;

    NSStackView* stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8.0;
    stack.edgeInsets = NSEdgeInsetsMake(10.0, 10.0, 10.0, 10.0);

    NSStackView* header = [[NSStackView alloc] initWithFrame:NSZeroRect];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    header.alignment = NSLayoutAttributeCenterY;
    header.spacing = 8.0;

    self.contentBrowserTabButton = [NSButton buttonWithTitle:@"Content Browser" target:self action:@selector(toggleContentBrowser:)];
    self.contentBrowserTabButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentBrowserTabButton.bezelStyle = NSBezelStyleTexturedRounded;

    self.contentBrowserImportButton = [NSButton buttonWithTitle:@"Import Models" target:self action:@selector(importModelsToContentBrowser:)];
    self.contentBrowserImportButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentBrowserImportButton.bezelStyle = NSBezelStyleRounded;

    [header addArrangedSubview:self.contentBrowserTabButton];
    [header addArrangedSubview:self.contentBrowserImportButton];

    self.contentBrowserBodyView = [[NSView alloc] initWithFrame:NSZeroRect];
    self.contentBrowserBodyView.translatesAutoresizingMaskIntoConstraints = NO;

    self.contentBrowserStatusLabel = [NSTextField labelWithString:@"No imported model assets yet."];
    self.contentBrowserStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentBrowserStatusLabel.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
    self.contentBrowserStatusLabel.textColor = [NSColor secondaryLabelColor];
    self.contentBrowserStatusLabel.maximumNumberOfLines = 2;

    self.contentBrowserGridView = [[NSView alloc] initWithFrame:NSZeroRect];
    self.contentBrowserGridView.translatesAutoresizingMaskIntoConstraints = NO;

    self.contentBrowserScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.contentBrowserScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentBrowserScrollView.hasVerticalScroller = YES;
    self.contentBrowserScrollView.borderType = NSNoBorder;
    self.contentBrowserScrollView.drawsBackground = NO;
    self.contentBrowserScrollView.documentView = self.contentBrowserGridView;

    [self.contentBrowserBodyView addSubview:self.contentBrowserStatusLabel];
    [self.contentBrowserBodyView addSubview:self.contentBrowserScrollView];
    [self.contentBrowserPanel addSubview:stack];
    [stack addArrangedSubview:header];
    [stack addArrangedSubview:self.contentBrowserBodyView];

    [self.rootView addSubview:self.contentBrowserPanel];

    self.contentBrowserHeightConstraint = [self.contentBrowserPanel.heightAnchor constraintEqualToConstant:42.0];
    self.contentBrowserHeightConstraint.active = YES;
    self.contentBrowserBodyView.hidden = YES;
    self.contentBrowserBodyView.alphaValue = 0.0;

    [NSLayoutConstraint activateConstraints:@[
        [self.contentBrowserPanel.leadingAnchor constraintEqualToAnchor:self.rootView.leadingAnchor constant:80.0],
        [self.contentBrowserPanel.trailingAnchor constraintEqualToAnchor:self.rootView.trailingAnchor constant:-12.0],
        [self.contentBrowserPanel.bottomAnchor constraintEqualToAnchor:self.rootView.bottomAnchor constant:-12.0],
        [stack.leadingAnchor constraintEqualToAnchor:self.contentBrowserPanel.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.contentBrowserPanel.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:self.contentBrowserPanel.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:self.contentBrowserPanel.bottomAnchor],
        [self.contentBrowserBodyView.widthAnchor constraintEqualToConstant:260.0],
        [self.contentBrowserStatusLabel.leadingAnchor constraintEqualToAnchor:self.contentBrowserBodyView.leadingAnchor],
        [self.contentBrowserStatusLabel.trailingAnchor constraintEqualToAnchor:self.contentBrowserBodyView.trailingAnchor],
        [self.contentBrowserStatusLabel.topAnchor constraintEqualToAnchor:self.contentBrowserBodyView.topAnchor],
        [self.contentBrowserScrollView.leadingAnchor constraintEqualToAnchor:self.contentBrowserBodyView.leadingAnchor],
        [self.contentBrowserScrollView.trailingAnchor constraintEqualToAnchor:self.contentBrowserBodyView.trailingAnchor],
        [self.contentBrowserScrollView.topAnchor constraintEqualToAnchor:self.contentBrowserStatusLabel.bottomAnchor constant:8.0],
        [self.contentBrowserScrollView.bottomAnchor constraintEqualToAnchor:self.contentBrowserBodyView.bottomAnchor],
        [self.contentBrowserScrollView.heightAnchor constraintEqualToConstant:240.0],
    ]];

    [self reloadContentBrowser];
}

- (void)setContentBrowserCollapsed:(BOOL)collapsed animated:(BOOL)animated {
    self.contentBrowserCollapsed = collapsed;

    CGFloat targetHeight = self.hasDocument ? (collapsed ? 42.0 : 330.0) : 0.0;
    self.contentBrowserPanel.hidden = !self.hasDocument;

    if (!collapsed) {
        self.contentBrowserBodyView.hidden = NO;
    }

    void (^applyState)(BOOL) = ^(BOOL useAnimator) {
        if (useAnimator) {
            self.contentBrowserHeightConstraint.animator.constant = targetHeight;
            self.contentBrowserBodyView.animator.alphaValue = collapsed ? 0.0 : 1.0;
        } else {
            self.contentBrowserHeightConstraint.constant = targetHeight;
            self.contentBrowserBodyView.alphaValue = collapsed ? 0.0 : 1.0;
        }
    };

    if (animated && self.hasDocument) {
        [self.rootView layoutSubtreeIfNeeded];
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext* context) {
            context.duration = 0.22;
            applyState(YES);
            [self.rootView layoutSubtreeIfNeeded];
        } completionHandler:^{
            self.contentBrowserBodyView.hidden = collapsed;
            self.contentBrowserPanel.hidden = !self.hasDocument;
        }];
    } else {
        applyState(NO);
        self.contentBrowserBodyView.hidden = collapsed || !self.hasDocument;
    }
}

- (NSString*)contentBrowserRootDirectory {
    NSString* executableDir = [NSBundle.mainBundle.executablePath stringByDeletingLastPathComponent];
    return [[executableDir stringByAppendingPathComponent:@"content"] stringByAppendingPathComponent:@"models"];
}

- (void)reloadContentBrowser {
    if (self.contentBrowserItems == nil) {
        self.contentBrowserItems = [NSMutableArray array];
    }
    [self.contentBrowserItems removeAllObjects];

    NSString* modelsDirectory = [self contentBrowserRootDirectory];
    BOOL isDirectory = NO;
    NSFileManager* fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:modelsDirectory isDirectory:&isDirectory] || !isDirectory) {
        [fileManager createDirectoryAtPath:modelsDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    }

    NSArray<NSString*>* entries = [fileManager contentsOfDirectoryAtPath:modelsDirectory error:nil];
    NSArray<NSString*>* sortedEntries = [entries sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    for (NSString* entry in sortedEntries) {
        if (![entry.pathExtension.lowercaseString isEqualToString:kSledgehammerModelAssetExtension]) {
            continue;
        }
        NSString* fullPath = [modelsDirectory stringByAppendingPathComponent:entry];
        [self.contentBrowserItems addObject:@{ @"name": entry.stringByDeletingPathExtension, @"path": fullPath }];
    }

    for (NSView* subview in self.contentBrowserGridView.subviews.copy) {
        [subview removeFromSuperview];
    }

    CGFloat itemWidth = 116.0;
    CGFloat itemHeight = 132.0;
    CGFloat spacing = 10.0;
    NSInteger columnCount = 2;
    [self.contentBrowserItems enumerateObjectsUsingBlock:^(NSDictionary<NSString*, id>* item, NSUInteger index, BOOL* stop) {
        (void)stop;
        NSInteger row = (NSInteger)index / columnCount;
        NSInteger column = (NSInteger)index % columnCount;
        NSRect frame = NSMakeRect((itemWidth + spacing) * column,
                                  (itemHeight + spacing) * row,
                                  itemWidth,
                                  itemHeight);
        ContentBrowserAssetButton* button = [[ContentBrowserAssetButton alloc] initWithFrame:frame];
        button.assetPath = item[@"path"];
        button.title = item[@"name"];
        button.imagePosition = NSImageAbove;
        button.bordered = NO;
        button.imageScaling = NSImageScaleProportionallyUpOrDown;
        button.alignment = NSTextAlignmentCenter;
        button.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium];
        NovaModelAssetThumbnail thumbnail = {0};
        char thumbnailError[256] = {0};
        NSImage* thumbnailImage = nil;
        if (nova_model_asset_read_thumbnail(button.assetPath.fileSystemRepresentation, &thumbnail, thumbnailError, (uint32_t)sizeof(thumbnailError))) {
            thumbnailImage = sledgehammer_make_thumbnail_image(&thumbnail);
        }
        nova_model_asset_thumbnail_release(&thumbnail);
        if (thumbnailImage == nil) {
            thumbnailImage = sledgehammer_make_placeholder_thumbnail_image(button.title);
        }
        [thumbnailImage setTemplate:NO];
        button.image = thumbnailImage;
        button.target = nil;
        [self.contentBrowserGridView addSubview:button];
    }];

    NSInteger rowCount = (NSInteger)((self.contentBrowserItems.count + (NSUInteger)columnCount - 1u) / (NSUInteger)columnCount);
    self.contentBrowserGridView.frame = NSMakeRect(0.0, 0.0, columnCount * itemWidth + (columnCount - 1) * spacing, MAX(1.0, rowCount * itemHeight + MAX(0, rowCount - 1) * spacing));
    self.contentBrowserStatusLabel.stringValue = self.contentBrowserItems.count > 0
        ? [NSString stringWithFormat:@"%zu model assets", (size_t)self.contentBrowserItems.count]
        : @"No imported model assets yet.";
}

- (void)toggleContentBrowser:(id)sender {
    (void)sender;
    [self setContentBrowserCollapsed:!self.contentBrowserCollapsed animated:YES];
    [self.contentBrowserTabButton setTitle:self.contentBrowserCollapsed ? @"Content Browser" : @"Content Browser"];
    [self updateChrome];
}

- (void)importModelsToContentBrowser:(id)sender {
    (void)sender;
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = YES;
    panel.allowedContentTypes = @[
        [UTType typeWithFilenameExtension:@"gltf"],
        [UTType typeWithFilenameExtension:@"glb"],
        [UTType typeWithFilenameExtension:@"obj"],
    ];
    if ([panel runModal] != NSModalResponseOK) {
        return;
    }

    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSString* modelsDirectory = [self contentBrowserRootDirectory];
    [fileManager createDirectoryAtPath:modelsDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableArray<NSString*>* failures = [NSMutableArray array];
    for (NSURL* url in panel.URLs) {
        float importScale = 1.0f;
        uint32_t importUpAxisMode = NOVA_MODEL_IMPORT_UP_AXIS_AUTO;
        NSString* assetName = nil;
        NSString* modalError = nil;
        NSModalResponse modalResponse = [self runModelImportSettingsModalForURL:url
                                                                    outAssetName:&assetName
                                                                        outScale:&importScale
                                                                   outUpAxisMode:&importUpAxisMode
                                                                           error:&modalError];
        if (modalResponse == NSAlertThirdButtonReturn) {
            break;
        }
        if (modalResponse != NSAlertFirstButtonReturn) {
            continue;
        }
        if (modalError.length > 0) {
            NSString* filename = url.lastPathComponent ?: @"<unknown>";
            [failures addObject:[NSString stringWithFormat:@"%@: %@", filename, modalError]];
            continue;
        }

        NSString* targetPath = [[modelsDirectory stringByAppendingPathComponent:assetName] stringByAppendingPathExtension:kSledgehammerModelAssetExtension];
        NSDictionary<NSFileAttributeKey, id>* sourceAttributes = [fileManager attributesOfItemAtPath:url.path error:nil];
        NSDictionary<NSFileAttributeKey, id>* targetAttributes = [fileManager attributesOfItemAtPath:targetPath error:nil];
        NSDictionary<NSFileAttributeKey, id>* executableAttributes = [fileManager attributesOfItemAtPath:NSBundle.mainBundle.executablePath error:nil];
        NSDate* sourceModified = sourceAttributes[NSFileModificationDate];
        NSDate* targetModified = targetAttributes[NSFileModificationDate];
        NSDate* executableModified = executableAttributes[NSFileModificationDate];
        BOOL targetUpToDateForSource = (sourceModified != nil && targetModified != nil && [targetModified compare:sourceModified] != NSOrderedAscending);
        BOOL targetUpToDateForImporter = (executableModified == nil || targetModified == nil || [targetModified compare:executableModified] != NSOrderedAscending);
        if (targetUpToDateForSource && targetUpToDateForImporter) {
            continue;
        }

        NovaModelAssetImportOptions options = {};
        options.uniformScale = importScale > 0.0f ? importScale : 1.0f;
        options.upAxisMode = importUpAxisMode;
        char compileMessage[512] = {0};
        if (!nova_model_asset_compile_from_source_with_options(url.path.fileSystemRepresentation,
                                                               targetPath.fileSystemRepresentation,
                                                               &options,
                                                               compileMessage,
                                                               (uint32_t)sizeof(compileMessage))) {
            NSString* filename = url.lastPathComponent ?: @"<unknown>";
            NSString* reason = compileMessage[0] != '\0' ? [NSString stringWithUTF8String:compileMessage] : @"Unknown error";
            [failures addObject:[NSString stringWithFormat:@"%@: %@", filename, reason]];
        }
    }
    [self setContentBrowserCollapsed:NO animated:YES];
    [self reloadContentBrowser];
    if (failures.count > 0) {
        [self showError:[NSString stringWithFormat:@"Model import failed for:\n%@", [failures componentsJoinedByString:@"\n"]]];
    }
}

- (NSModalResponse)runModelImportSettingsModalForURL:(NSURL*)url outAssetName:(NSString**)outAssetName outScale:(float*)outScale outUpAxisMode:(uint32_t*)outUpAxisMode error:(NSString**)outError {
    NSString* defaultAssetName;

    if (outAssetName != NULL) {
        *outAssetName = nil;
    }
    if (outScale != NULL) {
        *outScale = 1.0f;
    }
    if (outUpAxisMode != NULL) {
        *outUpAxisMode = NOVA_MODEL_IMPORT_UP_AXIS_AUTO;
    }
    if (outError != NULL) {
        *outError = nil;
    }
    if (url == nil || url.path.length == 0) {
        if (outError != NULL) {
            *outError = @"Model path is empty.";
        }
        return NSAlertSecondButtonReturn;
    }

    NovaModelAssetImportInfo info = {};
    char inspectMessage[512] = {0};
    if (!nova_model_asset_inspect_source(url.path.fileSystemRepresentation, &info, inspectMessage, (uint32_t)sizeof(inspectMessage))) {
        if (outError != NULL) {
            *outError = inspectMessage[0] != '\0' ? [NSString stringWithUTF8String:inspectMessage] : @"Failed to inspect source model.";
        }
        return NSAlertSecondButtonReturn;
    }

    float suggestedScale = info.recommendedScale > 0.0f ? info.recommendedScale : 1.0f;
    defaultAssetName = sledgehammer_default_model_asset_name_for_url(url);
    NSAlert* alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = [NSString stringWithFormat:@"Import %@", url.lastPathComponent ?: @"Model"];
    alert.informativeText = @"Editor world units use centimetres. Review the detected source units, bounds, and import scale before compiling the model asset.";
    [alert addButtonWithTitle:@"Import"];
    [alert addButtonWithTitle:@"Skip"];
    [alert addButtonWithTitle:@"Cancel"];

    NSStackView* stack = [[NSStackView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 360.0, 220.0)];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.distribution = NSStackViewDistributionFill;
    stack.spacing = 8.0;

    NSTextField* summaryLabel = [NSTextField wrappingLabelWithString:[NSString stringWithFormat:@"Detected units: %@\nSource bounds: %@\nImported bounds at suggested scale: %@ cm",
        sledgehammer_model_import_unit_label(info.detectedUnit, info.unitHintSource),
        sledgehammer_model_import_size_string(info.boundsMin, info.boundsMax, 1.0f),
        sledgehammer_model_import_size_string(info.boundsMin, info.boundsMax, suggestedScale)]];
    summaryLabel.preferredMaxLayoutWidth = 360.0;

    NSTextField* scaleLabel = [NSTextField labelWithString:@"Scale Factor"];
    NSTextField* scaleField = [[NSTextField alloc] initWithFrame:NSMakeRect(0.0, 0.0, 120.0, 24.0)];
    scaleField.stringValue = [NSString stringWithFormat:@"%.4f", suggestedScale];
    scaleField.placeholderString = @"1.0";

    NSTextField* upAxisLabel = [NSTextField labelWithString:@"Source Up Axis"];
    NSPopUpButton* upAxisPopUp = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0.0, 0.0, 220.0, 24.0) pullsDown:NO];
    [upAxisPopUp addItemsWithTitles:@[@"Auto Detect", @"X Up", @"Y Up", @"Z Up"]];
    [[upAxisPopUp itemAtIndex:0] setTag:NOVA_MODEL_IMPORT_UP_AXIS_AUTO];
    [[upAxisPopUp itemAtIndex:1] setTag:NOVA_MODEL_IMPORT_UP_AXIS_X];
    [[upAxisPopUp itemAtIndex:2] setTag:NOVA_MODEL_IMPORT_UP_AXIS_Y];
    [[upAxisPopUp itemAtIndex:3] setTag:NOVA_MODEL_IMPORT_UP_AXIS_Z];
    [upAxisPopUp selectItemAtIndex:0];

    NSTextField* nameLabel = [NSTextField labelWithString:@"Asset Name"];
    NSTextField* nameField = [[NSTextField alloc] initWithFrame:NSMakeRect(0.0, 0.0, 220.0, 24.0)];
    nameField.stringValue = defaultAssetName ?: @"model";
    nameField.placeholderString = @"model";

    NSTextField* hintLabel = [NSTextField wrappingLabelWithString:[NSString stringWithFormat:@"Suggested because source metres per unit = %.6g and editor units are centimetres.",
        info.sourceMetersPerUnit > 0.0f ? info.sourceMetersPerUnit : 0.0f]];
    hintLabel.textColor = NSColor.secondaryLabelColor;
    hintLabel.preferredMaxLayoutWidth = 360.0;

    [stack addArrangedSubview:summaryLabel];
    [stack addArrangedSubview:nameLabel];
    [stack addArrangedSubview:nameField];
    [stack addArrangedSubview:scaleLabel];
    [stack addArrangedSubview:scaleField];
    [stack addArrangedSubview:upAxisLabel];
    [stack addArrangedSubview:upAxisPopUp];
    [stack addArrangedSubview:hintLabel];
    alert.accessoryView = stack;

    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) {
        NSString* chosenAssetName = sledgehammer_sanitized_model_asset_name(nameField.stringValue);
        float chosenScale = scaleField.floatValue;

        if (chosenAssetName.length == 0) {
            if (outError != NULL) {
                *outError = @"Asset name is empty.";
            }
            return response;
        }
        if (!(chosenScale > 0.0f)) {
            chosenScale = suggestedScale > 0.0f ? suggestedScale : 1.0f;
        }
        if (outAssetName != NULL) {
            *outAssetName = chosenAssetName;
        }
        if (outScale != NULL) {
            *outScale = chosenScale;
        }
        if (outUpAxisMode != NULL) {
            NSInteger selectedIndex = upAxisPopUp.indexOfSelectedItem;
            if (selectedIndex < 0 || selectedIndex >= (NSInteger)upAxisPopUp.numberOfItems) {
                *outUpAxisMode = NOVA_MODEL_IMPORT_UP_AXIS_AUTO;
            } else {
                *outUpAxisMode = (uint32_t)[upAxisPopUp itemAtIndex:selectedIndex].tag;
            }
        }
    }
    return response;
}

@end
#pragma clang diagnostic pop