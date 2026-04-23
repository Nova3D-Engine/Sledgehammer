#ifndef VMF_PARSER_H
#define VMF_PARSER_H

#include <stddef.h>

#include "math3d.h"

typedef enum VmfEntityKind {
    VmfEntityKindRoot = 0,
    VmfEntityKindBrush = 1,
    VmfEntityKindLight = 2,
} VmfEntityKind;

typedef struct VmfSide {
    int id;
    Vec3 points[3];
    char material[128];
    /* Texture axes from VMF.  uaxis/vaxis are 4-component: xyz = axis direction,
       w = translation offset.  scale is the texture scale (u and v). */
    Vec3  uaxis;
    float uoffset;
    Vec3  vaxis;
    float voffset;
    float uscale;
    float vscale;
    struct {
        int hasData;
        int power;
        int resolution;
        float elevation;
        Vec3 startPosition;
        Vec3* normals;
        float* distances;
        Vec3* offsets;
        Vec3* offsetNormals;
        float* alphas;
    } dispinfo;
} VmfSide;

typedef struct VmfSolid {
    int id;
    VmfSide* sides;
    size_t sideCount;
    size_t sideCapacity;
} VmfSolid;

typedef struct VmfEntity {
    int id;
    int isWorld;
    int enabled;
    int castShadows;
    int lightType;
    float spotInnerDegrees;
    float spotOuterDegrees;
    char classname[128];
    char targetname[128];
    char name[128];
    VmfEntityKind kind;
    Vec3 position;
    Vec3 color;
    float intensity;
    float range;
    VmfSolid* solids;
    size_t solidCount;
    size_t solidCapacity;
} VmfEntity;

typedef struct VmfScene {
    VmfEntity* entities;
    size_t entityCount;
    size_t entityCapacity;
} VmfScene;

int vmf_scene_load(const char* path, VmfScene* outScene, char* errorBuffer, size_t errorBufferSize);
void vmf_scene_free(VmfScene* scene);

#endif
