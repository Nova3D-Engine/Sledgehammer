#include "vmf_parser.h"

#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef enum TokenType {
    TokenTypeEnd,
    TokenTypeWord,
    TokenTypeString,
    TokenTypeOpenBrace,
    TokenTypeCloseBrace,
} TokenType;

typedef struct Token {
    TokenType type;
    const char* start;
    size_t length;
} Token;

typedef struct Parser {
    const char* cursor;
    const char* end;
} Parser;

static void skip_block(Parser* parser);

static long parser_line_number(const char* start, const char* cursor) {
    long line = 1;
    for (const char* p = start; p < cursor; ++p) {
        if (*p == '\n') {
            line += 1;
        }
    }
    return line;
}

static void skip_whitespace(Parser* parser) {
    while (parser->cursor < parser->end) {
        if (parser->cursor[0] == '/' && parser->cursor + 1 < parser->end && parser->cursor[1] == '/') {
            parser->cursor += 2;
            while (parser->cursor < parser->end && *parser->cursor != '\n') {
                parser->cursor += 1;
            }
            continue;
        }

        if (!isspace((unsigned char)*parser->cursor)) {
            break;
        }
        parser->cursor += 1;
    }
}

static Token next_token(Parser* parser) {
    skip_whitespace(parser);
    if (parser->cursor >= parser->end) {
        return (Token) { .type = TokenTypeEnd };
    }

    char c = *parser->cursor;
    if (c == '{') {
        parser->cursor += 1;
        return (Token) { .type = TokenTypeOpenBrace, .start = parser->cursor - 1, .length = 1 };
    }
    if (c == '}') {
        parser->cursor += 1;
        return (Token) { .type = TokenTypeCloseBrace, .start = parser->cursor - 1, .length = 1 };
    }
    if (c == '"') {
        parser->cursor += 1;
        const char* start = parser->cursor;
        while (parser->cursor < parser->end && *parser->cursor != '"') {
            if (*parser->cursor == '\\' && parser->cursor + 1 < parser->end) {
                parser->cursor += 2;
                continue;
            }
            parser->cursor += 1;
        }
        const char* finish = parser->cursor;
        if (parser->cursor < parser->end) {
            parser->cursor += 1;
        }
        return (Token) { .type = TokenTypeString, .start = start, .length = (size_t)(finish - start) };
    }

    const char* start = parser->cursor;
    while (parser->cursor < parser->end) {
        char ch = *parser->cursor;
        if (isspace((unsigned char)ch) || ch == '{' || ch == '}') {
            break;
        }
        parser->cursor += 1;
    }
    return (Token) { .type = TokenTypeWord, .start = start, .length = (size_t)(parser->cursor - start) };
}

static void token_copy(Token token, char* destination, size_t destinationSize) {
    size_t length = token.length;
    if (length >= destinationSize) {
        length = destinationSize - 1;
    }
    memcpy(destination, token.start, length);
    destination[length] = '\0';
}

static int token_equals(Token token, const char* text) {
    size_t len = strlen(text);
    return token.length == len && strncmp(token.start, text, len) == 0;
}

static int parse_plane(const char* text, Vec3 outPoints[3]) {
    float values[9];
    int matched = sscanf(
        text,
        " ( %f %f %f ) ( %f %f %f ) ( %f %f %f ) ",
        &values[0], &values[1], &values[2],
        &values[3], &values[4], &values[5],
        &values[6], &values[7], &values[8]
    );
    if (matched != 9) {
        matched = sscanf(
            text,
            "(%f %f %f) (%f %f %f) (%f %f %f)",
            &values[0], &values[1], &values[2],
            &values[3], &values[4], &values[5],
            &values[6], &values[7], &values[8]
        );
    }
    if (matched != 9) {
        return 0;
    }
    for (int i = 0; i < 3; ++i) {
        outPoints[i] = vec3_make(values[i * 3], values[i * 3 + 1], values[i * 3 + 2]);
    }
    return 1;
}

static int parse_bracket_vec3(const char* text, Vec3* outVector) {
    float x;
    float y;
    float z;
    if (sscanf(text, " [ %f %f %f ] ", &x, &y, &z) != 3 &&
        sscanf(text, "[%f %f %f]", &x, &y, &z) != 3) {
        return 0;
    }
    *outVector = vec3_make(x, y, z);
    return 1;
}

static int parse_color_vec3(const char* text, Vec3* outVector) {
    return parse_bracket_vec3(text, outVector);
}

static int disp_sample_count(const VmfSide* side) {
    if (!side->dispinfo.hasData || side->dispinfo.resolution <= 0) {
        return 0;
    }
    return side->dispinfo.resolution * side->dispinfo.resolution;
}

static int alloc_dispinfo(VmfSide* side) {
    int sampleCount = disp_sample_count(side);
    if (sampleCount <= 0) {
        return 0;
    }

    side->dispinfo.normals = calloc((size_t)sampleCount, sizeof(Vec3));
    side->dispinfo.distances = calloc((size_t)sampleCount, sizeof(float));
    side->dispinfo.offsets = calloc((size_t)sampleCount, sizeof(Vec3));
    side->dispinfo.offsetNormals = calloc((size_t)sampleCount, sizeof(Vec3));
    side->dispinfo.alphas = calloc((size_t)sampleCount, sizeof(float));

    return side->dispinfo.normals && side->dispinfo.distances && side->dispinfo.offsets &&
        side->dispinfo.offsetNormals && side->dispinfo.alphas;
}

static void free_dispinfo(VmfSide* side) {
    free(side->dispinfo.normals);
    free(side->dispinfo.distances);
    free(side->dispinfo.offsets);
    free(side->dispinfo.offsetNormals);
    free(side->dispinfo.alphas);
    memset(&side->dispinfo, 0, sizeof(side->dispinfo));
}

static int parse_row_index(const char* key) {
    if (strncmp(key, "row", 3) != 0) {
        return -1;
    }
    return atoi(key + 3);
}

static int parse_float_row(const char* text, float* values, int expectedCount) {
    const char* cursor = text;
    char* end = NULL;
    for (int i = 0; i < expectedCount; ++i) {
        values[i] = strtof(cursor, &end);
        if (end == cursor) {
            return 0;
        }
        cursor = end;
    }
    return 1;
}

static int parse_vec3_row(const char* text, Vec3* values, int expectedCount) {
    float* scalars = malloc((size_t)expectedCount * 3 * sizeof(float));
    if (!scalars) {
        return 0;
    }
    int ok = parse_float_row(text, scalars, expectedCount * 3);
    if (ok) {
        for (int i = 0; i < expectedCount; ++i) {
            values[i] = vec3_make(scalars[i * 3], scalars[i * 3 + 1], scalars[i * 3 + 2]);
        }
    }
    free(scalars);
    return ok;
}

static int parse_dispinfo_rows(Parser* parser, VmfSide* side, Vec3* vec3Target, float* floatTarget, int isVec3) {
    Token open = next_token(parser);
    if (open.type != TokenTypeOpenBrace) {
        return 0;
    }

    int resolution = side->dispinfo.resolution;
    for (;;) {
        Token key = next_token(parser);
        if (key.type == TokenTypeCloseBrace) {
            return 1;
        }
        if (key.type == TokenTypeEnd) {
            return 0;
        }

        Token value = next_token(parser);
        if (value.type != TokenTypeString && value.type != TokenTypeWord) {
            return 0;
        }

        char keyBuffer[32];
        char valueBuffer[4096];
        token_copy(key, keyBuffer, sizeof(keyBuffer));
        token_copy(value, valueBuffer, sizeof(valueBuffer));

        int rowIndex = parse_row_index(keyBuffer);
        if (rowIndex < 0 || rowIndex >= resolution) {
            continue;
        }

        if (isVec3) {
            if (!parse_vec3_row(valueBuffer, vec3Target + rowIndex * resolution, resolution)) {
                return 0;
            }
        } else {
            if (!parse_float_row(valueBuffer, floatTarget + rowIndex * resolution, resolution)) {
                return 0;
            }
        }
    }
}

static int parse_dispinfo_block(Parser* parser, VmfSide* side) {
    Token open = next_token(parser);
    if (open.type != TokenTypeOpenBrace) {
        return 0;
    }

    side->dispinfo.hasData = 1;
    for (;;) {
        Token key = next_token(parser);
        if (key.type == TokenTypeCloseBrace) {
            return 1;
        }
        if (key.type == TokenTypeEnd) {
            return 0;
        }

        if (key.type == TokenTypeWord) {
            if (token_equals(key, "normals")) {
                if (!parse_dispinfo_rows(parser, side, side->dispinfo.normals, NULL, 1)) {
                    return 0;
                }
                continue;
            }
            if (token_equals(key, "distances")) {
                if (!parse_dispinfo_rows(parser, side, NULL, side->dispinfo.distances, 0)) {
                    return 0;
                }
                continue;
            }
            if (token_equals(key, "offsets")) {
                if (!parse_dispinfo_rows(parser, side, side->dispinfo.offsets, NULL, 1)) {
                    return 0;
                }
                continue;
            }
            if (token_equals(key, "offset_normals")) {
                if (!parse_dispinfo_rows(parser, side, side->dispinfo.offsetNormals, NULL, 1)) {
                    return 0;
                }
                continue;
            }
            if (token_equals(key, "alphas")) {
                if (!parse_dispinfo_rows(parser, side, NULL, side->dispinfo.alphas, 0)) {
                    return 0;
                }
                continue;
            }

            Token maybeBlock = next_token(parser);
            if (maybeBlock.type == TokenTypeOpenBrace) {
                parser->cursor = maybeBlock.start;
                skip_block(parser);
                continue;
            }
            parser->cursor = maybeBlock.start;
        }

        Token value = next_token(parser);
        if (value.type != TokenTypeString && value.type != TokenTypeWord) {
            return 0;
        }

        char keyBuffer[64];
        char valueBuffer[256];
        token_copy(key, keyBuffer, sizeof(keyBuffer));
        token_copy(value, valueBuffer, sizeof(valueBuffer));

        if (strcmp(keyBuffer, "power") == 0) {
            side->dispinfo.power = atoi(valueBuffer);
            side->dispinfo.resolution = (1 << side->dispinfo.power) + 1;
            if (!alloc_dispinfo(side)) {
                return 0;
            }
        } else if (strcmp(keyBuffer, "startposition") == 0) {
            if (!parse_bracket_vec3(valueBuffer, &side->dispinfo.startPosition)) {
                return 0;
            }
        } else if (strcmp(keyBuffer, "elevation") == 0) {
            side->dispinfo.elevation = strtof(valueBuffer, NULL);
        }
    }
}

static int reserve_sides(VmfSolid* solid, size_t minimum) {
    if (solid->sideCapacity >= minimum) {
        return 1;
    }
    size_t capacity = solid->sideCapacity == 0 ? 8 : solid->sideCapacity * 2;
    while (capacity < minimum) {
        capacity *= 2;
    }
    VmfSide* sides = realloc(solid->sides, capacity * sizeof(VmfSide));
    if (!sides) {
        return 0;
    }
    solid->sides = sides;
    solid->sideCapacity = capacity;
    return 1;
}

static int reserve_solids(VmfEntity* entity, size_t minimum) {
    if (entity->solidCapacity >= minimum) {
        return 1;
    }
    size_t capacity = entity->solidCapacity == 0 ? 8 : entity->solidCapacity * 2;
    while (capacity < minimum) {
        capacity *= 2;
    }
    VmfSolid* solids = realloc(entity->solids, capacity * sizeof(VmfSolid));
    if (!solids) {
        return 0;
    }
    entity->solids = solids;
    entity->solidCapacity = capacity;
    return 1;
}

static int reserve_entities(VmfScene* scene, size_t minimum) {
    if (scene->entityCapacity >= minimum) {
        return 1;
    }
    size_t capacity = scene->entityCapacity == 0 ? 16 : scene->entityCapacity * 2;
    while (capacity < minimum) {
        capacity *= 2;
    }
    VmfEntity* entities = realloc(scene->entities, capacity * sizeof(VmfEntity));
    if (!entities) {
        return 0;
    }
    scene->entities = entities;
    scene->entityCapacity = capacity;
    return 1;
}

static int append_side(VmfSolid* solid, VmfSide side) {
    if (!reserve_sides(solid, solid->sideCount + 1)) {
        return 0;
    }
    solid->sides[solid->sideCount++] = side;
    return 1;
}

static int append_solid(VmfEntity* entity, VmfSolid solid) {
    if (!reserve_solids(entity, entity->solidCount + 1)) {
        return 0;
    }
    entity->solids[entity->solidCount++] = solid;
    return 1;
}

static int append_entity(VmfScene* scene, VmfEntity entity) {
    if (!reserve_entities(scene, scene->entityCount + 1)) {
        return 0;
    }
    scene->entities[scene->entityCount++] = entity;
    return 1;
}

static void skip_block(Parser* parser) {
    Token open = next_token(parser);
    if (open.type != TokenTypeOpenBrace) {
        return;
    }
    int depth = 1;
    while (depth > 0) {
        Token token = next_token(parser);
        if (token.type == TokenTypeEnd) {
            return;
        }
        if (token.type == TokenTypeOpenBrace) {
            depth += 1;
        } else if (token.type == TokenTypeCloseBrace) {
            depth -= 1;
        }
    }
}

static int parse_side_block(Parser* parser, VmfSide* outSide) {
    memset(outSide, 0, sizeof(*outSide));

    Token open = next_token(parser);
    if (open.type != TokenTypeOpenBrace) {
        return 0;
    }

    for (;;) {
        Token key = next_token(parser);
        if (key.type == TokenTypeCloseBrace) {
            return 1;
        }
        if (key.type == TokenTypeEnd) {
            return 0;
        }

        if (key.type == TokenTypeWord) {
            if (token_equals(key, "dispinfo")) {
                if (!parse_dispinfo_block(parser, outSide)) {
                    free_dispinfo(outSide);
                    return 0;
                }
                continue;
            }
            Token maybeBlock = next_token(parser);
            if (maybeBlock.type == TokenTypeOpenBrace) {
                parser->cursor = maybeBlock.start;
                skip_block(parser);
                continue;
            }
            parser->cursor = maybeBlock.start;
        }

        Token value = next_token(parser);
        if (value.type != TokenTypeString && value.type != TokenTypeWord) {
            return 0;
        }

        char keyBuffer[64];
        char valueBuffer[256];
        token_copy(key, keyBuffer, sizeof(keyBuffer));
        token_copy(value, valueBuffer, sizeof(valueBuffer));

        if (strcmp(keyBuffer, "id") == 0) {
            outSide->id = atoi(valueBuffer);
        } else if (strcmp(keyBuffer, "plane") == 0) {
            if (!parse_plane(valueBuffer, outSide->points)) {
                return 0;
            }
        } else if (strcmp(keyBuffer, "material") == 0) {
            strncpy(outSide->material, valueBuffer, sizeof(outSide->material) - 1);
            outSide->material[sizeof(outSide->material) - 1] = '\0';
        } else if (strcmp(keyBuffer, "uaxis") == 0) {
            /* format: "[x y z offset] scale" */
            float x = 0, y = 0, z = 0, off = 0, scale = 0.25f;
            sscanf(valueBuffer, "[%f %f %f %f] %f", &x, &y, &z, &off, &scale);
            outSide->uaxis   = vec3_make(x, y, z);
            outSide->uoffset = off;
            outSide->uscale  = fabsf(scale) > 1e-5f ? scale : 0.25f;
        } else if (strcmp(keyBuffer, "vaxis") == 0) {
            float x = 0, y = 0, z = 0, off = 0, scale = 0.25f;
            sscanf(valueBuffer, "[%f %f %f %f] %f", &x, &y, &z, &off, &scale);
            outSide->vaxis   = vec3_make(x, y, z);
            outSide->voffset = off;
            outSide->vscale  = fabsf(scale) > 1e-5f ? scale : 0.25f;
        }
    }
}

static int parse_solid_block(Parser* parser, VmfSolid* outSolid) {
    memset(outSolid, 0, sizeof(*outSolid));

    Token open = next_token(parser);
    if (open.type != TokenTypeOpenBrace) {
        return 0;
    }

    for (;;) {
        Token key = next_token(parser);
        if (key.type == TokenTypeCloseBrace) {
            return 1;
        }
        if (key.type == TokenTypeEnd) {
            return 0;
        }

        if (key.type == TokenTypeWord && token_equals(key, "side")) {
            VmfSide side;
            if (!parse_side_block(parser, &side)) {
                return 0;
            }
            if (!append_side(outSolid, side)) {
                return 0;
            }
            continue;
        }

        Token next = next_token(parser);
        if (next.type == TokenTypeOpenBrace) {
            parser->cursor = next.start;
            skip_block(parser);
            continue;
        }
        if (next.type != TokenTypeString && next.type != TokenTypeWord) {
            return 0;
        }

        char keyBuffer[64];
        char valueBuffer[128];
        token_copy(key, keyBuffer, sizeof(keyBuffer));
        token_copy(next, valueBuffer, sizeof(valueBuffer));
        if (strcmp(keyBuffer, "id") == 0) {
            outSolid->id = atoi(valueBuffer);
        }
    }
}

static int parse_entity_block(Parser* parser, VmfEntity* outEntity, int isWorld) {
    memset(outEntity, 0, sizeof(*outEntity));
    outEntity->isWorld = isWorld;
    outEntity->kind = isWorld ? VmfEntityKindRoot : VmfEntityKindBrush;
    outEntity->enabled = 1;
    outEntity->castShadows = 1;
    outEntity->lightType = 3;
    outEntity->spotInnerDegrees = 18.0f;
    outEntity->spotOuterDegrees = 28.0f;
    outEntity->color = vec3_make(1.0f, 0.95f, 0.8f);
    outEntity->intensity = 10.0f;
    outEntity->range = 512.0f;
    if (isWorld) {
        strncpy(outEntity->classname, "worldspawn", sizeof(outEntity->classname) - 1);
        strncpy(outEntity->name, "Scene Root", sizeof(outEntity->name) - 1);
    }

    Token open = next_token(parser);
    if (open.type != TokenTypeOpenBrace) {
        return 0;
    }

    for (;;) {
        Token key = next_token(parser);
        if (key.type == TokenTypeCloseBrace) {
            return 1;
        }
        if (key.type == TokenTypeEnd) {
            return 0;
        }

        if (key.type == TokenTypeWord && token_equals(key, "solid")) {
            VmfSolid solid;
            if (!parse_solid_block(parser, &solid)) {
                return 0;
            }
            if (!append_solid(outEntity, solid)) {
                return 0;
            }
            continue;
        }

        Token next = next_token(parser);
        if (next.type == TokenTypeOpenBrace) {
            parser->cursor = next.start;
            skip_block(parser);
            continue;
        }
        if (next.type != TokenTypeString && next.type != TokenTypeWord) {
            return 0;
        }

        char keyBuffer[64];
        char valueBuffer[256];
        token_copy(key, keyBuffer, sizeof(keyBuffer));
        token_copy(next, valueBuffer, sizeof(valueBuffer));

        if (strcmp(keyBuffer, "id") == 0) {
            outEntity->id = atoi(valueBuffer);
        } else if (strcmp(keyBuffer, "type") == 0) {
            if (strcmp(valueBuffer, "root") == 0) {
                outEntity->kind = VmfEntityKindRoot;
                outEntity->isWorld = 1;
            } else if (strcmp(valueBuffer, "light") == 0) {
                outEntity->kind = VmfEntityKindLight;
                outEntity->isWorld = 0;
            } else {
                outEntity->kind = VmfEntityKindBrush;
                outEntity->isWorld = 0;
            }
        } else if (strcmp(keyBuffer, "name") == 0) {
            strncpy(outEntity->name, valueBuffer, sizeof(outEntity->name) - 1);
            outEntity->name[sizeof(outEntity->name) - 1] = '\0';
        } else if (strcmp(keyBuffer, "position") == 0 || strcmp(keyBuffer, "origin") == 0) {
            parse_bracket_vec3(valueBuffer, &outEntity->position);
        } else if (strcmp(keyBuffer, "color") == 0) {
            parse_color_vec3(valueBuffer, &outEntity->color);
        } else if (strcmp(keyBuffer, "intensity") == 0) {
            outEntity->intensity = strtof(valueBuffer, NULL);
        } else if (strcmp(keyBuffer, "range") == 0) {
            outEntity->range = strtof(valueBuffer, NULL);
        } else if (strcmp(keyBuffer, "enabled") == 0) {
            outEntity->enabled = atoi(valueBuffer) != 0;
        } else if (strcmp(keyBuffer, "cast_shadows") == 0) {
            outEntity->castShadows = atoi(valueBuffer) != 0;
        } else if (strcmp(keyBuffer, "light_type") == 0) {
            outEntity->lightType = atoi(valueBuffer);
        } else if (strcmp(keyBuffer, "spot_inner_degrees") == 0) {
            outEntity->spotInnerDegrees = strtof(valueBuffer, NULL);
        } else if (strcmp(keyBuffer, "spot_outer_degrees") == 0) {
            outEntity->spotOuterDegrees = strtof(valueBuffer, NULL);
        } else if (strcmp(keyBuffer, "classname") == 0) {
            strncpy(outEntity->classname, valueBuffer, sizeof(outEntity->classname) - 1);
            outEntity->classname[sizeof(outEntity->classname) - 1] = '\0';
            if (strcmp(valueBuffer, "worldspawn") == 0) {
                outEntity->kind = VmfEntityKindRoot;
                outEntity->isWorld = 1;
            } else if (strcmp(valueBuffer, "light") == 0 || strcmp(valueBuffer, "light_point") == 0) {
                outEntity->kind = VmfEntityKindLight;
                outEntity->isWorld = 0;
            }
        } else if (strcmp(keyBuffer, "targetname") == 0) {
            strncpy(outEntity->targetname, valueBuffer, sizeof(outEntity->targetname) - 1);
            outEntity->targetname[sizeof(outEntity->targetname) - 1] = '\0';
            if (outEntity->name[0] == '\0') {
                strncpy(outEntity->name, valueBuffer, sizeof(outEntity->name) - 1);
                outEntity->name[sizeof(outEntity->name) - 1] = '\0';
            }
        }
    }
}

int vmf_scene_load(const char* path, VmfScene* outScene, char* errorBuffer, size_t errorBufferSize) {
    memset(outScene, 0, sizeof(*outScene));

    FILE* file = fopen(path, "rb");
    if (!file) {
        snprintf(errorBuffer, errorBufferSize, "failed to open %s: %s", path, strerror(errno));
        return 0;
    }

    fseek(file, 0, SEEK_END);
    long fileSize = ftell(file);
    fseek(file, 0, SEEK_SET);
    if (fileSize < 0) {
        fclose(file);
        snprintf(errorBuffer, errorBufferSize, "failed to determine file size for %s", path);
        return 0;
    }

    char* contents = malloc((size_t)fileSize + 1);
    if (!contents) {
        fclose(file);
        snprintf(errorBuffer, errorBufferSize, "out of memory reading %s", path);
        return 0;
    }

    size_t readSize = fread(contents, 1, (size_t)fileSize, file);
    fclose(file);
    contents[readSize] = '\0';
    if (readSize != (size_t)fileSize) {
        free(contents);
        snprintf(errorBuffer, errorBufferSize, "failed to read %s", path);
        return 0;
    }

    Parser parser = { .cursor = contents, .end = contents + readSize };
    while (1) {
        Token token = next_token(&parser);
        if (token.type == TokenTypeEnd) {
            break;
        }
        if (token.type != TokenTypeWord && token.type != TokenTypeString) {
            continue;
        }

        if (token.type == TokenTypeWord && (token_equals(token, "world") || token_equals(token, "scene"))) {
            VmfEntity world;
            if (!parse_entity_block(&parser, &world, 1) || !append_entity(outScene, world)) {
                long line = parser_line_number(contents, parser.cursor);
                vmf_scene_free(outScene);
                free(contents);
                snprintf(errorBuffer, errorBufferSize, "failed to parse root scene block in %s near line %ld", path, line);
                return 0;
            }
            continue;
        }

        if (token.type == TokenTypeWord && token_equals(token, "entity")) {
            VmfEntity entity;
            if (!parse_entity_block(&parser, &entity, 0) || !append_entity(outScene, entity)) {
                long line = parser_line_number(contents, parser.cursor);
                vmf_scene_free(outScene);
                free(contents);
                snprintf(errorBuffer, errorBufferSize, "failed to parse entity in %s near line %ld", path, line);
                return 0;
            }
            continue;
        }

        Token maybeBlock = next_token(&parser);
        if (maybeBlock.type == TokenTypeOpenBrace) {
            parser.cursor = maybeBlock.start;
            skip_block(&parser);
        }
    }

    free(contents);
    if (outScene->entityCount == 0) {
        snprintf(errorBuffer, errorBufferSize, "no scene or entity blocks found in %s", path);
        return 0;
    }
    return 1;
}

void vmf_scene_free(VmfScene* scene) {
    if (!scene) {
        return;
    }
    for (size_t entityIndex = 0; entityIndex < scene->entityCount; ++entityIndex) {
        VmfEntity* entity = &scene->entities[entityIndex];
        for (size_t solidIndex = 0; solidIndex < entity->solidCount; ++solidIndex) {
            for (size_t sideIndex = 0; sideIndex < entity->solids[solidIndex].sideCount; ++sideIndex) {
                free_dispinfo(&entity->solids[solidIndex].sides[sideIndex]);
            }
            free(entity->solids[solidIndex].sides);
        }
        free(entity->solids);
    }
    free(scene->entities);
    memset(scene, 0, sizeof(*scene));
}
