#ifndef FILE_INDEX_H
#define FILE_INDEX_H

#include <stddef.h>

typedef struct FileIndex {
    char** paths;
    size_t count;
    size_t capacity;
    size_t currentIndex;
} FileIndex;

int file_index_build(const char* path, FileIndex* outIndex, char* errorBuffer, size_t errorBufferSize);
void file_index_free(FileIndex* index);
const char* file_index_current(const FileIndex* index);
const char* file_index_next(FileIndex* index);
const char* file_index_previous(FileIndex* index);

#endif
