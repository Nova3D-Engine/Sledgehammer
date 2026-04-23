#include "file_index.h"

#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>

static int file_index_push(FileIndex* index, const char* path) {
    if (index->count == index->capacity) {
        size_t newCapacity = index->capacity == 0 ? 32 : index->capacity * 2;
        char** newPaths = realloc(index->paths, newCapacity * sizeof(char*));
        if (!newPaths) {
            return 0;
        }
        index->paths = newPaths;
        index->capacity = newCapacity;
    }

    index->paths[index->count] = strdup(path);
    if (!index->paths[index->count]) {
        return 0;
    }
    index->count += 1;
    return 1;
}

static int has_supported_scene_extension(const char* path) {
    const char* ext = strrchr(path, '.');
    return ext && (strcasecmp(ext, ".slg") == 0 || strcasecmp(ext, ".vmf") == 0);
}

static int compare_paths(const void* lhs, const void* rhs) {
    const char* const* left = lhs;
    const char* const* right = rhs;
    return strcasecmp(*left, *right);
}

static int walk_path(const char* path, FileIndex* index, char* errorBuffer, size_t errorBufferSize) {
    struct stat info;
    if (stat(path, &info) != 0) {
        snprintf(errorBuffer, errorBufferSize, "stat failed for %s: %s", path, strerror(errno));
        return 0;
    }

    if (S_ISREG(info.st_mode)) {
        if (!has_supported_scene_extension(path)) {
            snprintf(errorBuffer, errorBufferSize, "path is not a supported scene file (.slg/.vmf): %s", path);
            return 0;
        }
        if (!file_index_push(index, path)) {
            snprintf(errorBuffer, errorBufferSize, "out of memory while indexing %s", path);
            return 0;
        }
        return 1;
    }

    if (!S_ISDIR(info.st_mode)) {
        snprintf(errorBuffer, errorBufferSize, "unsupported path: %s", path);
        return 0;
    }

    DIR* dir = opendir(path);
    if (!dir) {
        snprintf(errorBuffer, errorBufferSize, "opendir failed for %s: %s", path, strerror(errno));
        return 0;
    }

    struct dirent* entry;
    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }

        char childPath[PATH_MAX];
        int written = snprintf(childPath, sizeof(childPath), "%s/%s", path, entry->d_name);
        if (written <= 0 || (size_t)written >= sizeof(childPath)) {
            snprintf(errorBuffer, errorBufferSize, "path too long while indexing %s", path);
            closedir(dir);
            return 0;
        }

        struct stat childInfo;
        if (stat(childPath, &childInfo) != 0) {
            continue;
        }

        if (S_ISDIR(childInfo.st_mode)) {
            if (!walk_path(childPath, index, errorBuffer, errorBufferSize)) {
                closedir(dir);
                return 0;
            }
            continue;
        }

        if (S_ISREG(childInfo.st_mode) && has_supported_scene_extension(childPath)) {
            if (!file_index_push(index, childPath)) {
                snprintf(errorBuffer, errorBufferSize, "out of memory while indexing %s", childPath);
                closedir(dir);
                return 0;
            }
        }
    }

    closedir(dir);
    return 1;
}

int file_index_build(const char* path, FileIndex* outIndex, char* errorBuffer, size_t errorBufferSize) {
    memset(outIndex, 0, sizeof(*outIndex));
    if (!walk_path(path, outIndex, errorBuffer, errorBufferSize)) {
        file_index_free(outIndex);
        return 0;
    }
    if (outIndex->count == 0) {
        snprintf(errorBuffer, errorBufferSize, "no .slg files found under %s", path);
        return 0;
    }
    qsort(outIndex->paths, outIndex->count, sizeof(char*), compare_paths);
    outIndex->currentIndex = 0;
    return 1;
}

void file_index_free(FileIndex* index) {
    for (size_t i = 0; i < index->count; ++i) {
        free(index->paths[i]);
    }
    free(index->paths);
    memset(index, 0, sizeof(*index));
}

const char* file_index_current(const FileIndex* index) {
    if (!index || index->count == 0) {
        return NULL;
    }
    return index->paths[index->currentIndex];
}

const char* file_index_next(FileIndex* index) {
    if (!index || index->count == 0) {
        return NULL;
    }
    index->currentIndex = (index->currentIndex + 1) % index->count;
    return file_index_current(index);
}

const char* file_index_previous(FileIndex* index) {
    if (!index || index->count == 0) {
        return NULL;
    }
    index->currentIndex = (index->currentIndex + index->count - 1) % index->count;
    return file_index_current(index);
}
