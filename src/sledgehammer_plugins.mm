#import "sledgehammer_viewer_app_internal.h"

#include <fcntl.h>
#include <dlfcn.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#import "sledgehammer_plugin_api.h"
@interface SledgehammerLoadedPluginRecord : NSObject

@property(nonatomic, copy) NSString* sourcePath;
@property(nonatomic, copy) NSString* runtimePath;
@property(nonatomic, copy) NSString* modificationToken;
@property(nonatomic, copy) NSString* pluginIdentifier;
@property(nonatomic, copy) NSString* displayName;
@property(nonatomic, assign) void* handle;
@property(nonatomic, assign) void* userData;
@property(nonatomic, assign) SledgehammerPluginApiV1 api;

@end

@implementation SledgehammerLoadedPluginRecord

@end

@interface SledgehammerPluginCommandTarget : NSObject

@property(nonatomic, weak) ViewerAppDelegate* appDelegate;
@property(nonatomic, weak) SledgehammerLoadedPluginRecord* pluginRecord;
@property(nonatomic, assign) NSUInteger commandIndex;

- (void)invoke:(id)sender;

@end

static size_t sledgehammer_copy_utf8_string(NSString* value, char* buffer, size_t buffer_size) {
    const char* utf8 = value.length > 0 ? value.UTF8String : "";
    size_t required = strlen(utf8);
    if (buffer != NULL && buffer_size > 0) {
        size_t copy_count = required < (buffer_size - 1) ? required : (buffer_size - 1);
        memcpy(buffer, utf8, copy_count);
        buffer[copy_count] = '\0';
    }
    return required;
}

static NSEventModifierFlags sledgehammer_menu_flags_for_plugin_modifiers(uint32_t modifiers) {
    NSEventModifierFlags flags = 0;
    if ((modifiers & SledgehammerPluginKeyModifierCommand) != 0u) {
        flags |= NSEventModifierFlagCommand;
    }
    if ((modifiers & SledgehammerPluginKeyModifierShift) != 0u) {
        flags |= NSEventModifierFlagShift;
    }
    if ((modifiers & SledgehammerPluginKeyModifierOption) != 0u) {
        flags |= NSEventModifierFlagOption;
    }
    if ((modifiers & SledgehammerPluginKeyModifierControl) != 0u) {
        flags |= NSEventModifierFlagControl;
    }
    return flags;
}

static ViewerAppDelegate* sledgehammer_plugin_host_delegate(void* app_context) {
    return (__bridge ViewerAppDelegate*)app_context;
}

static void sledgehammer_plugin_host_log(void* app_context, const char* plugin_identifier, const char* message) {
    ViewerAppDelegate* delegate = sledgehammer_plugin_host_delegate(app_context);
    NSString* pluginLabel = plugin_identifier != NULL && plugin_identifier[0] != '\0' ? [NSString stringWithUTF8String:plugin_identifier] : @"unknown";
    NSString* text = message != NULL && message[0] != '\0' ? [NSString stringWithUTF8String:message] : @"";
    (void)delegate;
    NSLog(@"[plugin:%@] %@", pluginLabel, text);
}

static void sledgehammer_plugin_host_show_message(void* app_context,
                                                  const char* plugin_identifier,
                                                  const char* title,
                                                  const char* message) {
    ViewerAppDelegate* delegate = sledgehammer_plugin_host_delegate(app_context);
    NSString* pluginLabel = plugin_identifier != NULL && plugin_identifier[0] != '\0' ? [NSString stringWithUTF8String:plugin_identifier] : @"plugin";
    NSString* alertTitle = title != NULL && title[0] != '\0' ? [NSString stringWithUTF8String:title] : @"Plugin";
    NSString* alertMessage = message != NULL && message[0] != '\0' ? [NSString stringWithUTF8String:message] : @"";
    void (^presentAlert)(void) = ^{
        NSAlert* alert = [[NSAlert alloc] init];
        alert.messageText = [NSString stringWithFormat:@"%@ (%@)", alertTitle, pluginLabel];
        alert.informativeText = alertMessage;
        [alert beginSheetModalForWindow:delegate.window completionHandler:nil];
    };
    if ([NSThread isMainThread]) {
        presentAlert();
    } else {
        dispatch_async(dispatch_get_main_queue(), presentAlert);
    }
}

static size_t sledgehammer_plugin_host_copy_current_document_path(void* app_context, char* buffer, size_t buffer_size) {
    ViewerAppDelegate* delegate = sledgehammer_plugin_host_delegate(app_context);
    return sledgehammer_copy_utf8_string(delegate.currentPath ?: @"", buffer, buffer_size);
}

static size_t sledgehammer_plugin_host_copy_current_material_name(void* app_context, char* buffer, size_t buffer_size) {
    ViewerAppDelegate* delegate = sledgehammer_plugin_host_delegate(app_context);
    return sledgehammer_copy_utf8_string(delegate.brushMaterialName ?: @"", buffer, buffer_size);
}

static size_t sledgehammer_plugin_host_copy_materials_directory(void* app_context, char* buffer, size_t buffer_size) {
    ViewerAppDelegate* delegate = sledgehammer_plugin_host_delegate(app_context);
    return sledgehammer_copy_utf8_string(delegate.materialsDirectory ?: @"", buffer, buffer_size);
}

static size_t sledgehammer_plugin_host_copy_plugins_directory(void* app_context, char* buffer, size_t buffer_size) {
    ViewerAppDelegate* delegate = sledgehammer_plugin_host_delegate(app_context);
    return sledgehammer_copy_utf8_string(delegate.pluginsDirectory ?: @"", buffer, buffer_size);
}

static void sledgehammer_plugin_host_frame_scene(void* app_context) {
    ViewerAppDelegate* delegate = sledgehammer_plugin_host_delegate(app_context);
    void (^frameScene)(void) = ^{
        [delegate frameAllViewports];
    };
    if ([NSThread isMainThread]) {
        frameScene();
    } else {
        dispatch_async(dispatch_get_main_queue(), frameScene);
    }
}

static bool sledgehammer_plugin_host_rebuild_mesh(void* app_context) {
    ViewerAppDelegate* delegate = sledgehammer_plugin_host_delegate(app_context);
    if ([NSThread isMainThread]) {
        return [delegate rebuildMeshFromScene];
    }

    __block BOOL rebuildResult = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        rebuildResult = [delegate rebuildMeshFromScene];
    });
    return rebuildResult;
}

static Vec3 sledgehammer_plugin_vec3_to_vec3(SledgehammerPluginVec3 value) {
    return vec3_make(value.x, value.y, value.z);
}

static void sledgehammer_plugin_host_set_debug_bounds(void* app_context,
                                                      SledgehammerPluginVec3 min,
                                                      SledgehammerPluginVec3 max,
                                                      bool visible) {
    ViewerAppDelegate* delegate = sledgehammer_plugin_host_delegate(app_context);
    Bounds3 bounds = bounds3_empty();
    bounds.min = sledgehammer_plugin_vec3_to_vec3(min);
    bounds.max = sledgehammer_plugin_vec3_to_vec3(max);

    void (^applyBounds)(void) = ^{
        for (VmfViewport* viewport in delegate.viewports) {
            [viewport setPluginDebugBounds:bounds visible:visible ? YES : NO];
        }
    };
    if ([NSThread isMainThread]) {
        applyBounds();
    } else {
        dispatch_async(dispatch_get_main_queue(), applyBounds);
    }
}

static bool sledgehammer_plugin_host_get_editor_stats(void* app_context,
                                                      SledgehammerPluginEditorStatsV1* outStats) {
    if (outStats == NULL) {
        return false;
    }

    ViewerAppDelegate* delegate = sledgehammer_plugin_host_delegate(app_context);
    memset(outStats, 0, sizeof(*outStats));
    outStats->struct_size = (uint32_t)sizeof(*outStats);
    outStats->has_document = delegate.hasDocument ? 1u : 0u;
    outStats->document_dirty = delegate.documentDirty ? 1u : 0u;

    if (!delegate.hasDocument) {
        return true;
    }

    VmfScene scene = delegate.scene;
    outStats->entity_count = (uint32_t)scene.entityCount;

    for (size_t entityIndex = 0; entityIndex < scene.entityCount; ++entityIndex) {
        const VmfEntity* entity = &scene.entities[entityIndex];
        if (entity->kind == VmfEntityKindLight) {
            outStats->light_entity_count += 1u;
        }
        if (entity->solidCount > 0) {
            outStats->brush_entity_count += 1u;
        }

        outStats->solid_count += (uint32_t)entity->solidCount;
        for (size_t solidIndex = 0; solidIndex < entity->solidCount; ++solidIndex) {
            outStats->side_count += (uint32_t)entity->solids[solidIndex].sideCount;
        }
    }

    return true;
}

@implementation SledgehammerPluginCommandTarget

- (void)invoke:(id)sender {
    (void)sender;
    [self.appDelegate invokePluginRecord:self.pluginRecord commandIndex:self.commandIndex];
}

@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation ViewerAppDelegate (SledgehammerPlugins)

- (NSString*)defaultPluginsDirectory {
    const char* overridePath = getenv("SLEDGEHAMMER_PLUGIN_DIR");
    if (overridePath != NULL && overridePath[0] != '\0') {
        return [NSString stringWithUTF8String:overridePath];
    }
    NSString* executableDirectory = [NSBundle.mainBundle.executablePath stringByDeletingLastPathComponent];
    return [executableDirectory stringByAppendingPathComponent:@"plugins"];
}

- (NSString*)pluginRuntimeDirectory {
    NSString* executableName = NSBundle.mainBundle.executablePath.lastPathComponent;
    NSString* runtimeRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:@"SledgehammerPluginRuntime"];
    return [runtimeRoot stringByAppendingPathComponent:executableName.length > 0 ? executableName : @"Sledgehammer"];
}

- (SledgehammerPluginHostV1)pluginHost {
    SledgehammerPluginHostV1 host = { 0 };
    host.struct_size = sizeof(host);
    host.api_version = SLEDGEHAMMER_PLUGIN_API_VERSION;
    host.app_context = (__bridge void*)self;
    host.log = sledgehammer_plugin_host_log;
    host.show_message = sledgehammer_plugin_host_show_message;
    host.copy_current_document_path = sledgehammer_plugin_host_copy_current_document_path;
    host.copy_current_material_name = sledgehammer_plugin_host_copy_current_material_name;
    host.copy_materials_directory = sledgehammer_plugin_host_copy_materials_directory;
    host.copy_plugins_directory = sledgehammer_plugin_host_copy_plugins_directory;
    host.frame_scene = sledgehammer_plugin_host_frame_scene;
    host.rebuild_mesh = sledgehammer_plugin_host_rebuild_mesh;
    host.set_debug_bounds = sledgehammer_plugin_host_set_debug_bounds;
    host.get_editor_stats = sledgehammer_plugin_host_get_editor_stats;
    return host;
}

- (void)configurePlugins {
    self.pluginsDirectory = [self defaultPluginsDirectory];
    if (self.pluginsDirectory.length == 0) {
        return;
    }

    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSError* directoryError = nil;
    if (![fileManager createDirectoryAtPath:self.pluginsDirectory withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
        NSLog(@"[plugin] failed to create plugins directory %@: %@", self.pluginsDirectory, directoryError.localizedDescription);
        return;
    }

    NSString* runtimeDirectory = [self pluginRuntimeDirectory];
    [fileManager removeItemAtPath:runtimeDirectory error:nil];
    [fileManager createDirectoryAtPath:runtimeDirectory withIntermediateDirectories:YES attributes:nil error:nil];

    [self startWatchingPluginsDirectory:self.pluginsDirectory];
    [self reloadPlugins:nil];
}

- (NSArray<NSString*>*)pluginCandidatePathsInDirectory:(NSString*)directory {
    NSError* listError = nil;
    NSArray<NSString*>* contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:&listError];
    if (contents == nil) {
        NSLog(@"[plugin] failed to list %@: %@", directory, listError.localizedDescription);
        return @[];
    }

    NSMutableArray<NSString*>* dylibPaths = [NSMutableArray array];
    for (NSString* entry in contents) {
        if (![entry.pathExtension.lowercaseString isEqualToString:@"dylib"]) {
            continue;
        }
        [dylibPaths addObject:[directory stringByAppendingPathComponent:entry]];
    }
    [dylibPaths sortUsingSelector:@selector(localizedStandardCompare:)];
    return dylibPaths;
}

- (NSString*)pluginModificationTokenForPath:(NSString*)path {
    NSDictionary<NSFileAttributeKey, id>* attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    NSDate* modified = attributes[NSFileModificationDate];
    NSNumber* fileSize = attributes[NSFileSize];
    long long modifiedMillis = modified != nil ? (long long)llround(modified.timeIntervalSince1970 * 1000.0) : 0ll;
    unsigned long long sizeValue = fileSize != nil ? fileSize.unsignedLongLongValue : 0ull;
    return [NSString stringWithFormat:@"%lld:%llu", modifiedMillis, sizeValue];
}

- (BOOL)validatePluginApi:(const SledgehammerPluginApiV1*)api errorMessage:(NSString* __autoreleasing *)errorMessage {
    if (api == NULL) {
        if (errorMessage != NULL) {
            *errorMessage = @"plugin query returned no API";
        }
        return NO;
    }
    if (api->api_version != SLEDGEHAMMER_PLUGIN_API_VERSION) {
        if (errorMessage != NULL) {
            *errorMessage = [NSString stringWithFormat:@"unsupported plugin API version %u", api->api_version];
        }
        return NO;
    }
    if (api->plugin_identifier == NULL || api->plugin_identifier[0] == '\0') {
        if (errorMessage != NULL) {
            *errorMessage = @"plugin is missing plugin_identifier";
        }
        return NO;
    }
    if (api->display_name == NULL || api->display_name[0] == '\0') {
        if (errorMessage != NULL) {
            *errorMessage = @"plugin is missing display_name";
        }
        return NO;
    }
    if (api->command_count > 0u && api->commands == NULL) {
        if (errorMessage != NULL) {
            *errorMessage = @"plugin declared commands without a command table";
        }
        return NO;
    }
    for (uint32_t index = 0; index < api->command_count; ++index) {
        const SledgehammerPluginCommandV1* command = &api->commands[index];
        if (command->identifier == NULL || command->identifier[0] == '\0' ||
            command->display_name == NULL || command->display_name[0] == '\0' ||
            command->invoke == NULL) {
            if (errorMessage != NULL) {
                *errorMessage = [NSString stringWithFormat:@"plugin command %u is incomplete", index];
            }
            return NO;
        }
    }
    return YES;
}

- (SledgehammerLoadedPluginRecord*)loadPluginRecordFromSourcePath:(NSString*)sourcePath
                                                 modificationToken:(NSString*)modificationToken
                                                      errorMessage:(NSString* __autoreleasing *)errorMessage {
    NSString* runtimeDirectory = [self pluginRuntimeDirectory];
    NSString* runtimeName = [NSString stringWithFormat:@"%@-%@.dylib",
                             sourcePath.lastPathComponent.stringByDeletingPathExtension,
                             NSUUID.UUID.UUIDString];
    NSString* runtimePath = [runtimeDirectory stringByAppendingPathComponent:runtimeName];
    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSError* copyError = nil;
    if (![fileManager copyItemAtPath:sourcePath toPath:runtimePath error:&copyError]) {
        if (errorMessage != NULL) {
            *errorMessage = [NSString stringWithFormat:@"failed to stage %@: %@", sourcePath.lastPathComponent, copyError.localizedDescription];
        }
        return nil;
    }

    void* handle = dlopen(runtimePath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        NSString* dlerrorMessage = dlerror() != NULL ? [NSString stringWithUTF8String:dlerror()] : @"unknown dlopen failure";
        [fileManager removeItemAtPath:runtimePath error:nil];
        if (errorMessage != NULL) {
            *errorMessage = dlerrorMessage;
        }
        return nil;
    }

    SledgehammerPluginQueryFn query = (SledgehammerPluginQueryFn)dlsym(handle, SLEDGEHAMMER_PLUGIN_QUERY_SYMBOL);
    if (query == NULL) {
        if (errorMessage != NULL) {
            *errorMessage = [NSString stringWithFormat:@"%@ does not export %s", sourcePath.lastPathComponent, SLEDGEHAMMER_PLUGIN_QUERY_SYMBOL];
        }
        dlclose(handle);
        [fileManager removeItemAtPath:runtimePath error:nil];
        return nil;
    }

    SledgehammerPluginHostV1 host = [self pluginHost];
    SledgehammerPluginApiV1 api = { 0 };
    char errorBuffer[512] = { 0 };
    if (!query(&host, &api, errorBuffer, sizeof(errorBuffer))) {
        if (errorMessage != NULL) {
            *errorMessage = errorBuffer[0] != '\0' ? [NSString stringWithUTF8String:errorBuffer] : @"plugin query failed";
        }
        dlclose(handle);
        [fileManager removeItemAtPath:runtimePath error:nil];
        return nil;
    }

    NSString* validationError = nil;
    if (![self validatePluginApi:&api errorMessage:&validationError]) {
        if (errorMessage != NULL) {
            *errorMessage = validationError;
        }
        dlclose(handle);
        [fileManager removeItemAtPath:runtimePath error:nil];
        return nil;
    }

    void* pluginUserData = NULL;
    if (api.startup != NULL && !api.startup(&pluginUserData, &host, errorBuffer, sizeof(errorBuffer))) {
        if (errorMessage != NULL) {
            *errorMessage = errorBuffer[0] != '\0' ? [NSString stringWithUTF8String:errorBuffer] : @"plugin startup failed";
        }
        dlclose(handle);
        [fileManager removeItemAtPath:runtimePath error:nil];
        return nil;
    }

    SledgehammerLoadedPluginRecord* record = [[SledgehammerLoadedPluginRecord alloc] init];
    record.sourcePath = sourcePath;
    record.runtimePath = runtimePath;
    record.modificationToken = modificationToken;
    record.pluginIdentifier = [NSString stringWithUTF8String:api.plugin_identifier];
    record.displayName = [NSString stringWithUTF8String:api.display_name];
    record.handle = handle;
    record.userData = pluginUserData;
    record.api = api;
    return record;
}

- (void)refreshPluginsMenu {
    if (self.pluginsMenu == nil) {
        return;
    }

    while (self.pluginsMenu.numberOfItems > self.pluginMenuDynamicStartIndex) {
        [self.pluginsMenu removeItemAtIndex:self.pluginMenuDynamicStartIndex];
    }
    [self.pluginCommandTargets removeAllObjects];

    NSArray<SledgehammerLoadedPluginRecord*>* plugins = [[self.loadedPluginsBySourcePath allValues] sortedArrayUsingComparator:^NSComparisonResult(SledgehammerLoadedPluginRecord* lhs, SledgehammerLoadedPluginRecord* rhs) {
        return [lhs.displayName localizedStandardCompare:rhs.displayName];
    }];

    BOOL addedCommand = NO;
    for (SledgehammerLoadedPluginRecord* plugin in plugins) {
        for (uint32_t index = 0; index < plugin.api.command_count; ++index) {
            const SledgehammerPluginCommandV1* command = &plugin.api.commands[index];
            NSString* title = [NSString stringWithFormat:@"%@: %s", plugin.displayName, command->display_name];
            NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title action:@selector(invoke:) keyEquivalent:command->key_equivalent != NULL ? [NSString stringWithUTF8String:command->key_equivalent] : @""];
            item.keyEquivalentModifierMask = sledgehammer_menu_flags_for_plugin_modifiers(command->key_modifiers);
            SledgehammerPluginCommandTarget* target = [[SledgehammerPluginCommandTarget alloc] init];
            target.appDelegate = self;
            target.pluginRecord = plugin;
            target.commandIndex = index;
            item.target = target;
            [self.pluginCommandTargets addObject:target];
            [self.pluginsMenu addItem:item];
            addedCommand = YES;
        }
    }

    if (!addedCommand) {
        NSMenuItem* placeholder = [[NSMenuItem alloc] initWithTitle:@"No Plugin Commands Loaded" action:nil keyEquivalent:@""];
        placeholder.enabled = NO;
        [self.pluginsMenu addItem:placeholder];
    }
}

- (void)unloadPluginRecord:(SledgehammerLoadedPluginRecord*)record reason:(NSString*)reason {
    if (record == nil) {
        return;
    }

    SledgehammerPluginHostV1 host = [self pluginHost];
    if (record.api.shutdown != NULL) {
        record.api.shutdown(record.userData, &host);
    }
    if (record.handle != NULL) {
        dlclose(record.handle);
        record.handle = NULL;
    }
    if (record.runtimePath.length > 0) {
        [[NSFileManager defaultManager] removeItemAtPath:record.runtimePath error:nil];
    }
    NSLog(@"[plugin] unloaded %@ (%@)", record.displayName ?: record.sourcePath.lastPathComponent, reason ?: @"update");
}

- (void)unloadAllPlugins {
    NSArray<SledgehammerLoadedPluginRecord*>* records = [self.loadedPluginsBySourcePath.allValues copy];
    [self.loadedPluginsBySourcePath removeAllObjects];
    for (SledgehammerLoadedPluginRecord* record in records) {
        [self unloadPluginRecord:record reason:@"shutdown"];
    }
    [self refreshPluginsMenu];
}

- (void)reloadPlugins:(id)sender {
    (void)sender;
    if (self.pluginsDirectory.length == 0) {
        return;
    }

    NSArray<NSString*>* sourcePaths = [self pluginCandidatePathsInDirectory:self.pluginsDirectory];
    NSMutableSet<NSString*>* livePaths = [NSMutableSet setWithArray:sourcePaths];
    NSArray<NSString*>* existingPaths = [self.loadedPluginsBySourcePath.allKeys copy];
    for (NSString* existingPath in existingPaths) {
        if ([livePaths containsObject:existingPath]) {
            continue;
        }
        SledgehammerLoadedPluginRecord* removed = self.loadedPluginsBySourcePath[existingPath];
        [self.loadedPluginsBySourcePath removeObjectForKey:existingPath];
        [self unloadPluginRecord:removed reason:@"removed from plugin directory"];
    }

    for (NSString* sourcePath in sourcePaths) {
        NSString* modificationToken = [self pluginModificationTokenForPath:sourcePath];
        SledgehammerLoadedPluginRecord* existing = self.loadedPluginsBySourcePath[sourcePath];
        if (existing != nil && [existing.modificationToken isEqualToString:modificationToken]) {
            continue;
        }

        NSString* loadError = nil;
        SledgehammerLoadedPluginRecord* replacement = [self loadPluginRecordFromSourcePath:sourcePath
                                                                          modificationToken:modificationToken
                                                                               errorMessage:&loadError];
        if (replacement == nil) {
            NSLog(@"[plugin] failed to load %@: %@", sourcePath.lastPathComponent, loadError ?: @"unknown error");
            continue;
        }

        if (existing != nil) {
            [self unloadPluginRecord:existing reason:@"hot reload"];
        }
        self.loadedPluginsBySourcePath[sourcePath] = replacement;
        NSLog(@"[plugin] loaded %@ from %@", replacement.displayName, sourcePath.lastPathComponent);
    }

    [self refreshPluginsMenu];
}

- (void)startWatchingPluginsDirectory:(NSString*)path {
    [self stopWatchingPluginsDirectory];
    if (path.length == 0) {
        return;
    }

    int fd = open(path.fileSystemRepresentation, O_EVTONLY);
    if (fd < 0) {
        return;
    }

    self.pluginDirectoryWatchFd = fd;
    __weak __typeof__(self) weakSelf = self;
    self.pluginDirectoryWatchSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE,
                                                            (uintptr_t)fd,
                                                            DISPATCH_VNODE_WRITE | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_ATTRIB,
                                                            dispatch_get_main_queue());
    dispatch_source_set_event_handler(self.pluginDirectoryWatchSource, ^{
        [weakSelf pluginsDirectoryDidChange];
    });
    dispatch_source_set_cancel_handler(self.pluginDirectoryWatchSource, ^{
        close(fd);
    });
    dispatch_resume(self.pluginDirectoryWatchSource);
    NSLog(@"[plugin] watching %@", path);
}

- (void)stopWatchingPluginsDirectory {
    if (self.pluginDirectoryWatchSource != nil) {
        dispatch_source_cancel(self.pluginDirectoryWatchSource);
        self.pluginDirectoryWatchSource = nil;
        self.pluginDirectoryWatchFd = -1;
    }
}

- (void)pluginsDirectoryDidChange {
    NSLog(@"[plugin] directory changed — reloading plugins");
    [self reloadPlugins:nil];
}

- (void)invokePluginRecord:(SledgehammerLoadedPluginRecord*)plugin commandIndex:(NSUInteger)commandIndex {
    if (plugin == nil || commandIndex >= plugin.api.command_count) {
        return;
    }
    SledgehammerPluginHostV1 host = [self pluginHost];
    plugin.api.commands[commandIndex].invoke(plugin.userData, &host);
}

@end
#pragma clang diagnostic pop