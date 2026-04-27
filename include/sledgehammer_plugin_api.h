#ifndef SLEDGEHAMMER_PLUGIN_API_H
#define SLEDGEHAMMER_PLUGIN_API_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SLEDGEHAMMER_PLUGIN_API_VERSION 3u
#define SLEDGEHAMMER_PLUGIN_QUERY_SYMBOL "sledgehammer_plugin_query"

#if defined(_WIN32)
#define SLEDGEHAMMER_PLUGIN_EXPORT __declspec(dllexport)
#else
#define SLEDGEHAMMER_PLUGIN_EXPORT __attribute__((visibility("default")))
#endif

typedef enum SledgehammerPluginKeyModifier {
    SledgehammerPluginKeyModifierCommand = 1u << 0,
    SledgehammerPluginKeyModifierShift = 1u << 1,
    SledgehammerPluginKeyModifierOption = 1u << 2,
    SledgehammerPluginKeyModifierControl = 1u << 3,
} SledgehammerPluginKeyModifier;

typedef struct SledgehammerPluginHostV1 SledgehammerPluginHostV1;

typedef struct SledgehammerPluginVec3 {
    float x;
    float y;
    float z;
} SledgehammerPluginVec3;

typedef struct SledgehammerPluginEditorStatsV1 {
    uint32_t struct_size;
    uint8_t has_document;
    uint8_t document_dirty;
    uint16_t reserved0;
    uint32_t entity_count;
    uint32_t brush_entity_count;
    uint32_t light_entity_count;
    uint32_t solid_count;
    uint32_t side_count;
} SledgehammerPluginEditorStatsV1;

typedef void (*SledgehammerPluginCommandInvokeFnV1)(void* plugin_user_data,
                                                    const SledgehammerPluginHostV1* host);

typedef struct SledgehammerPluginCommandV1 {
    const char* identifier;
    const char* display_name;
    const char* key_equivalent;
    uint32_t key_modifiers;
    SledgehammerPluginCommandInvokeFnV1 invoke;
} SledgehammerPluginCommandV1;

typedef bool (*SledgehammerPluginStartupFnV1)(void** plugin_user_data,
                                              const SledgehammerPluginHostV1* host,
                                              char* error_message,
                                              size_t error_message_size);

typedef void (*SledgehammerPluginShutdownFnV1)(void* plugin_user_data,
                                               const SledgehammerPluginHostV1* host);

struct SledgehammerPluginHostV1 {
    uint32_t struct_size;
    uint32_t api_version;
    void* app_context;

    void (*log)(void* app_context, const char* plugin_identifier, const char* message);
    void (*show_message)(void* app_context,
                         const char* plugin_identifier,
                         const char* title,
                         const char* message);
    size_t (*copy_current_document_path)(void* app_context, char* buffer, size_t buffer_size);
    size_t (*copy_current_material_name)(void* app_context, char* buffer, size_t buffer_size);
    size_t (*copy_materials_directory)(void* app_context, char* buffer, size_t buffer_size);
    size_t (*copy_plugins_directory)(void* app_context, char* buffer, size_t buffer_size);
    void (*frame_scene)(void* app_context);
    bool (*rebuild_mesh)(void* app_context);
    void (*set_debug_bounds)(void* app_context,
                             SledgehammerPluginVec3 min,
                             SledgehammerPluginVec3 max,
                             bool visible);
    bool (*get_editor_stats)(void* app_context, SledgehammerPluginEditorStatsV1* out_stats);
};

typedef struct SledgehammerPluginApiV1 {
    uint32_t struct_size;
    uint32_t api_version;
    const char* plugin_identifier;
    const char* display_name;
    uint32_t command_count;
    const SledgehammerPluginCommandV1* commands;
    SledgehammerPluginStartupFnV1 startup;
    SledgehammerPluginShutdownFnV1 shutdown;
} SledgehammerPluginApiV1;

typedef bool (*SledgehammerPluginQueryFn)(const SledgehammerPluginHostV1* host,
                                          SledgehammerPluginApiV1* out_api,
                                          char* error_message,
                                          size_t error_message_size);

#ifdef __cplusplus
}
#endif

#endif