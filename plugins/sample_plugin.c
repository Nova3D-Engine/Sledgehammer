#include "sledgehammer_plugin_api.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct SamplePluginState {
    unsigned int invocation_count;
} SamplePluginState;

static SledgehammerPluginVec3 plugin_vec3(float x, float y, float z) {
    SledgehammerPluginVec3 value;
    value.x = x;
    value.y = y;
    value.z = z;
    return value;
}

static int append_line(char* buffer, size_t buffer_size, size_t* cursor, const char* text) {
    int written = snprintf(buffer + *cursor,
                           *cursor < buffer_size ? buffer_size - *cursor : 0,
                           "%s\n",
                           text);
    if (written < 0) {
        return 0;
    }
    *cursor += (size_t)written;
    return 1;
}

static void sample_show_editor_state(void* plugin_user_data, const SledgehammerPluginHostV1* host) {
    SamplePluginState* state = (SamplePluginState*)plugin_user_data;
    char document_path[1024] = { 0 };
    char material_name[256] = { 0 };
    char plugins_directory[1024] = { 0 };
    char message[2048] = { 0 };

    if (host == NULL) {
        return;
    }

    if (host->copy_current_document_path) {
        host->copy_current_document_path(host->app_context, document_path, sizeof(document_path));
    }
    if (host->copy_current_material_name) {
        host->copy_current_material_name(host->app_context, material_name, sizeof(material_name));
    }
    if (host->copy_plugins_directory) {
        host->copy_plugins_directory(host->app_context, plugins_directory, sizeof(plugins_directory));
    }
    if (state != NULL) {
        state->invocation_count += 1;
    }

    snprintf(message,
             sizeof(message),
             "Build: %s %s\nInvocations: %u\nDocument: %s\nBrush Material: %s\nPlugins Directory: %s",
             __DATE__,
             __TIME__,
             state != NULL ? state->invocation_count : 0u,
             document_path[0] ? document_path : "(none)",
             material_name[0] ? material_name : "(none)",
             plugins_directory[0] ? plugins_directory : "(none)");

    if (host->log) {
        host->log(host->app_context, "sample.state", "sample plugin command invoked");
    }
    if (host->frame_scene) {
        host->frame_scene(host->app_context);
    }
    if (host->show_message) {
        host->show_message(host->app_context, "sample.state", "Sample Plugin", message);
    }
}

static void sample_run_practical_diagnostics(void* plugin_user_data, const SledgehammerPluginHostV1* host) {
    SamplePluginState* state = (SamplePluginState*)plugin_user_data;
    SledgehammerPluginEditorStatsV1 stats;
    char document_path[1024] = { 0 };
    char materials_directory[1024] = { 0 };
    char report[4096] = { 0 };
    size_t cursor = 0;

    if (host == NULL || host->show_message == NULL) {
        return;
    }
    if (state != NULL) {
        state->invocation_count += 1;
    }

    memset(&stats, 0, sizeof(stats));
    stats.struct_size = (uint32_t)sizeof(stats);
    if (host->get_editor_stats == NULL || !host->get_editor_stats(host->app_context, &stats)) {
        host->show_message(host->app_context,
                           "sample.state",
                           "Map Diagnostics",
                           "Host does not provide editor stats yet. Rebuild and relaunch Sledgehammer.");
        return;
    }

    if (host->copy_current_document_path != NULL) {
        host->copy_current_document_path(host->app_context, document_path, sizeof(document_path));
    }
    if (host->copy_materials_directory != NULL) {
        host->copy_materials_directory(host->app_context, materials_directory, sizeof(materials_directory));
    }

    append_line(report, sizeof(report), &cursor, "Practical Diagnostics");
    append_line(report, sizeof(report), &cursor, "---------------------");

    if (!stats.has_document) {
        append_line(report, sizeof(report), &cursor, "- No map is open. Load a VMF to run scene checks.");
    } else {
        char line[256];
        snprintf(line,
                 sizeof(line),
                 "- Entities: %u | Brush Entities: %u | Lights: %u | Solids: %u | Sides: %u",
                 stats.entity_count,
                 stats.brush_entity_count,
                 stats.light_entity_count,
                 stats.solid_count,
                 stats.side_count);
        append_line(report, sizeof(report), &cursor, line);

        if (stats.document_dirty) {
            append_line(report, sizeof(report), &cursor, "- Unsaved changes detected.");
        }
        if (stats.light_entity_count == 0u) {
            append_line(report, sizeof(report), &cursor, "- No lights found. Add at least one light for sane preview lighting.");
        } else if (stats.light_entity_count > 96u) {
            append_line(report, sizeof(report), &cursor, "- High light count (>96). Consider culling/merging for better preview performance.");
        }
        if (stats.solid_count == 0u) {
            append_line(report, sizeof(report), &cursor, "- No brush solids found.");
        }
        if (stats.solid_count > 0u) {
            float avg_sides = (float)stats.side_count / (float)stats.solid_count;
            if (avg_sides > 8.5f) {
                append_line(report,
                            sizeof(report),
                            &cursor,
                            "- Average brush complexity is high. Watch for expensive booleans or over-segmented geometry.");
            }
        }
    }

    if (materials_directory[0] == '\0') {
        append_line(report,
                    sizeof(report),
                    &cursor,
                    "- Materials directory is not set. Textures may fail to resolve in the editor.");
    }
    if (document_path[0] == '\0' && stats.has_document) {
        append_line(report,
                    sizeof(report),
                    &cursor,
                    "- Current document has no path yet (unsaved map). Save once for deterministic plugin workflows.");
    }

    if (host->log != NULL) {
        host->log(host->app_context, "sample.state", "practical diagnostics executed");
    }
    host->show_message(host->app_context, "sample.state", "Map Diagnostics", report);
}

static void sample_spawn_debug_box(void* plugin_user_data, const SledgehammerPluginHostV1* host) {
    SamplePluginState* state = (SamplePluginState*)plugin_user_data;
    char message[512] = { 0 };

    if (state != NULL) {
        state->invocation_count += 1;
    }
    if (host == NULL || host->set_debug_bounds == NULL) {
        return;
    }

    host->set_debug_bounds(host->app_context,
                           plugin_vec3(-192.0f, -192.0f, 0.0f),
                           plugin_vec3(192.0f, 192.0f, 256.0f),
                           true);
    if (host->frame_scene != NULL) {
        host->frame_scene(host->app_context);
    }

    snprintf(message,
             sizeof(message),
             "Debug box refreshed from plugin build %s %s\nInvocation: %u\nExpected result: a dashed amber bounds overlay in the 2D viewports.",
             __DATE__,
             __TIME__,
             state != NULL ? state->invocation_count : 0u);
    if (host->log != NULL) {
        host->log(host->app_context, "sample.state", "plugin debug box updated");
    }
    if (host->show_message != NULL) {
        host->show_message(host->app_context, "sample.state", "Plugin Debug Box", message);
    }
}

static void sample_clear_debug_box(void* plugin_user_data, const SledgehammerPluginHostV1* host) {
    (void)plugin_user_data;
    if (host == NULL || host->set_debug_bounds == NULL) {
        return;
    }
    host->set_debug_bounds(host->app_context,
                           plugin_vec3(0.0f, 0.0f, 0.0f),
                           plugin_vec3(0.0f, 0.0f, 0.0f),
                           false);
    if (host->log != NULL) {
        host->log(host->app_context, "sample.state", "plugin debug box cleared");
    }
}

static bool sample_plugin_startup(void** plugin_user_data,
                                  const SledgehammerPluginHostV1* host,
                                  char* error_message,
                                  size_t error_message_size) {
    (void)error_message;
    (void)error_message_size;

    SamplePluginState* state = (SamplePluginState*)calloc(1, sizeof(*state));
    if (state == NULL) {
        if (error_message != NULL && error_message_size > 0) {
            snprintf(error_message, error_message_size, "failed to allocate sample plugin state");
        }
        return false;
    }

    *plugin_user_data = state;
    if (host != NULL && host->log) {
        host->log(host->app_context, "sample.state", "sample plugin started");
    }
    return true;
}

static void sample_plugin_shutdown(void* plugin_user_data, const SledgehammerPluginHostV1* host) {
    if (host != NULL && host->log) {
        host->log(host->app_context, "sample.state", "sample plugin stopped");
    }
    free(plugin_user_data);
}

static const SledgehammerPluginCommandV1 kSamplePluginCommands[] = {
    {
        .identifier = "sample.state.show",
        .display_name = "Show Editor State",
        .key_equivalent = "",
        .key_modifiers = 0,
        .invoke = sample_show_editor_state,
    },
    {
        .identifier = "sample.diagnostics.run",
        .display_name = "Run Practical Diagnostics",
        .key_equivalent = "",
        .key_modifiers = 0,
        .invoke = sample_run_practical_diagnostics,
    },
    {
        .identifier = "sample.debug_box.spawn",
        .display_name = "Spawn Debug Box",
        .key_equivalent = "",
        .key_modifiers = 0,
        .invoke = sample_spawn_debug_box,
    },
    {
        .identifier = "sample.debug_box.clear",
        .display_name = "Clear Debug Box",
        .key_equivalent = "",
        .key_modifiers = 0,
        .invoke = sample_clear_debug_box,
    },
};

SLEDGEHAMMER_PLUGIN_EXPORT bool sledgehammer_plugin_query(const SledgehammerPluginHostV1* host,
                                                          SledgehammerPluginApiV1* out_api,
                                                          char* error_message,
                                                          size_t error_message_size) {
    (void)host;
    (void)error_message;
    (void)error_message_size;

    if (out_api == NULL) {
        return false;
    }

    memset(out_api, 0, sizeof(*out_api));
    out_api->struct_size = sizeof(*out_api);
    out_api->api_version = SLEDGEHAMMER_PLUGIN_API_VERSION;
    out_api->plugin_identifier = "sample.state";
    out_api->display_name = "Sample Plugin";
    out_api->command_count = (uint32_t)(sizeof(kSamplePluginCommands) / sizeof(kSamplePluginCommands[0]));
    out_api->commands = kSamplePluginCommands;
    out_api->startup = sample_plugin_startup;
    out_api->shutdown = sample_plugin_shutdown;
    return true;
}