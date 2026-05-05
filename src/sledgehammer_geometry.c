#include "sledgehammer_geometry.h"

#include <math.h>
#include <stdlib.h>
#include <strings.h>

typedef struct SledgehammerBakePlane {
    Vec3 normal;
    float distance;
} SledgehammerBakePlane;

static SledgehammerBakePlane sledgehammer_geometry_bake_plane_from_side(const VmfSide* side) {
    Vec3 edgeA = vec3_sub(side->points[1], side->points[0]);
    Vec3 edgeB = vec3_sub(side->points[2], side->points[0]);
    Vec3 normal = vec3_normalize(vec3_cross(edgeA, edgeB));
    SledgehammerBakePlane plane = {
        .normal = normal,
        .distance = vec3_dot(normal, side->points[0]),
    };
    return plane;
}

static Vec3 sledgehammer_geometry_bake_solid_reference_point(const VmfSolid* solid) {
    Vec3 center = vec3_make(0.0f, 0.0f, 0.0f);
    float sampleCount = 0.0f;
    for (size_t sideIndex = 0; sideIndex < solid->sideCount; ++sideIndex) {
        for (size_t pointIndex = 0; pointIndex < 3; ++pointIndex) {
            center = vec3_add(center, solid->sides[sideIndex].points[pointIndex]);
            sampleCount += 1.0f;
        }
    }
    return sampleCount > 0.0f ? vec3_scale(center, 1.0f / sampleCount) : center;
}

static SledgehammerBakePlane sledgehammer_geometry_bake_orient_plane_outward(SledgehammerBakePlane plane, Vec3 interiorPoint) {
    float signedDistance = vec3_dot(plane.normal, interiorPoint) - plane.distance;
    if (signedDistance > 0.0f) {
        plane.normal = vec3_scale(plane.normal, -1.0f);
        plane.distance = -plane.distance;
    }
    return plane;
}

static int sledgehammer_geometry_bake_intersect_planes(SledgehammerBakePlane a,
                                                       SledgehammerBakePlane b,
                                                       SledgehammerBakePlane c,
                                                       Vec3* outPoint) {
    Vec3 bc = vec3_cross(b.normal, c.normal);
    float determinant = vec3_dot(a.normal, bc);
    if (fabsf(determinant) < 1e-5f) {
        return 0;
    }

    Vec3 termA = vec3_scale(bc, a.distance);
    Vec3 termB = vec3_scale(vec3_cross(c.normal, a.normal), b.distance);
    Vec3 termC = vec3_scale(vec3_cross(a.normal, b.normal), c.distance);
    *outPoint = vec3_scale(vec3_add(vec3_add(termA, termB), termC), 1.0f / determinant);
    return 1;
}

static int sledgehammer_geometry_bake_point_in_brush(const SledgehammerBakePlane* planes, size_t planeCount, Vec3 point) {
    for (size_t planeIndex = 0; planeIndex < planeCount; ++planeIndex) {
        float distance = vec3_dot(planes[planeIndex].normal, point) - planes[planeIndex].distance;
        if (distance > 0.05f) {
            return 0;
        }
    }
    return 1;
}

static int sledgehammer_geometry_bake_point_equals(Vec3 a, Vec3 b) {
    return vec3_length(vec3_sub(a, b)) < 0.05f;
}

static void sledgehammer_geometry_bake_append_unique(Vec3* points, size_t* pointCount, Vec3 point) {
    for (size_t pointIndex = 0; pointIndex < *pointCount; ++pointIndex) {
        if (sledgehammer_geometry_bake_point_equals(points[pointIndex], point)) {
            return;
        }
    }
    if (*pointCount < SLEDGEHAMMER_BAKE_MAX_POLYGON_POINTS) {
        points[*pointCount] = point;
        *pointCount += 1u;
    }
}

static void sledgehammer_geometry_bake_sort_polygon(Vec3* points, size_t pointCount, Vec3 normal) {
    if (pointCount < 3u) {
        return;
    }

    Vec3 center = vec3_make(0.0f, 0.0f, 0.0f);
    for (size_t pointIndex = 0; pointIndex < pointCount; ++pointIndex) {
        center = vec3_add(center, points[pointIndex]);
    }
    center = vec3_scale(center, 1.0f / (float)pointCount);

    Vec3 tangentSeed = fabsf(normal.raw[2]) < 0.99f ? vec3_make(0.0f, 0.0f, 1.0f) : vec3_make(0.0f, 1.0f, 0.0f);
    Vec3 axisX = vec3_normalize(vec3_cross(tangentSeed, normal));
    Vec3 axisY = vec3_cross(normal, axisX);

    for (size_t i = 0; i + 1 < pointCount; ++i) {
        for (size_t j = i + 1; j < pointCount; ++j) {
            Vec3 ai = vec3_sub(points[i], center);
            Vec3 aj = vec3_sub(points[j], center);
            float angleI = atan2f(vec3_dot(ai, axisY), vec3_dot(ai, axisX));
            float angleJ = atan2f(vec3_dot(aj, axisY), vec3_dot(aj, axisX));
            if (angleJ < angleI) {
                Vec3 tmp = points[i];
                points[i] = points[j];
                points[j] = tmp;
            }
        }
    }
}

void sledgehammer_geometry_bake_compute_uv(Vec3 position, const VmfSide* side, float* outU, float* outV) {
    if (fabsf(side->uscale) > 1e-5f) {
        *outU = (vec3_dot(position, side->uaxis) + side->uoffset) / (side->uscale * 0.5f);
    } else {
        *outU = vec3_dot(position, side->uaxis) + side->uoffset;
    }
    if (fabsf(side->vscale) > 1e-5f) {
        *outV = (vec3_dot(position, side->vaxis) + side->voffset) / (side->vscale * 0.5f);
    } else {
        *outV = vec3_dot(position, side->vaxis) + side->voffset;
    }
}

static Bounds3 sledgehammer_geometry_bake_solid_bounds(const VmfSolid* solid) {
    Bounds3 bounds = bounds3_empty();
    for (size_t sideIndex = 0; sideIndex < solid->sideCount; ++sideIndex) {
        for (size_t pointIndex = 0; pointIndex < 3; ++pointIndex) {
            bounds3_expand(&bounds, solid->sides[sideIndex].points[pointIndex]);
        }
    }
    return bounds;
}

static Bounds3 sledgehammer_geometry_bake_polygon_bounds(const SledgehammerBakePolygon* polygon) {
    Bounds3 bounds = bounds3_empty();
    for (size_t pointIndex = 0; pointIndex < polygon->pointCount; ++pointIndex) {
        bounds3_expand(&bounds, polygon->points[pointIndex]);
    }
    return bounds;
}

static bool sledgehammer_geometry_bake_bounds_overlap(Bounds3 a, Bounds3 b, float pad) {
    if (!bounds3_is_valid(a) || !bounds3_is_valid(b)) {
        return false;
    }
    return !(a.max.raw[0] < b.min.raw[0] - pad || a.min.raw[0] > b.max.raw[0] + pad ||
             a.max.raw[1] < b.min.raw[1] - pad || a.min.raw[1] > b.max.raw[1] + pad ||
             a.max.raw[2] < b.min.raw[2] - pad || a.min.raw[2] > b.max.raw[2] + pad);
}

static bool sledgehammer_geometry_bake_collect_face_polygon(const VmfSolid* solid,
                                                            size_t sideIndex,
                                                            SledgehammerBakePolygon* outPolygon,
                                                            Vec3* outNormal) {
    if (solid == NULL || outPolygon == NULL || sideIndex >= solid->sideCount || solid->sideCount > 128u) {
        return false;
    }

    SledgehammerBakePlane planes[128];
    Vec3 interiorPoint = sledgehammer_geometry_bake_solid_reference_point(solid);
    for (size_t planeIndex = 0; planeIndex < solid->sideCount; ++planeIndex) {
        planes[planeIndex] = sledgehammer_geometry_bake_orient_plane_outward(sledgehammer_geometry_bake_plane_from_side(&solid->sides[planeIndex]), interiorPoint);
    }

    outPolygon->pointCount = 0u;
    for (size_t j = 0; j < solid->sideCount; ++j) {
        if (j == sideIndex) {
            continue;
        }
        for (size_t k = j + 1u; k < solid->sideCount; ++k) {
            if (k == sideIndex) {
                continue;
            }
            Vec3 point;
            if (!sledgehammer_geometry_bake_intersect_planes(planes[sideIndex], planes[j], planes[k], &point)) {
                continue;
            }
            if (!sledgehammer_geometry_bake_point_in_brush(planes, solid->sideCount, point)) {
                continue;
            }
            sledgehammer_geometry_bake_append_unique(outPolygon->points, &outPolygon->pointCount, point);
        }
    }

    if (outPolygon->pointCount < 3u) {
        return false;
    }

    sledgehammer_geometry_bake_sort_polygon(outPolygon->points, outPolygon->pointCount, planes[sideIndex].normal);
    if (outNormal != NULL) {
        *outNormal = planes[sideIndex].normal;
    }
    return true;
}

static void sledgehammer_geometry_bake_append_polygon_point(SledgehammerBakePolygon* polygon, Vec3 point) {
    if (polygon->pointCount == 0u || !sledgehammer_geometry_bake_point_equals(polygon->points[polygon->pointCount - 1u], point)) {
        if (polygon->pointCount < SLEDGEHAMMER_BAKE_MAX_POLYGON_POINTS) {
            polygon->points[polygon->pointCount++] = point;
        }
    }
}

static void sledgehammer_geometry_bake_split_polygon_by_plane(const SledgehammerBakePolygon* polygon,
                                                              SledgehammerBakePlane plane,
                                                              float epsilon,
                                                              SledgehammerBakePolygon* outOutside,
                                                              SledgehammerBakePolygon* outInside) {
    outOutside->pointCount = 0u;
    outInside->pointCount = 0u;
    if (polygon == NULL || polygon->pointCount < 3u) {
        return;
    }

    for (size_t pointIndex = 0; pointIndex < polygon->pointCount; ++pointIndex) {
        Vec3 current = polygon->points[pointIndex];
        Vec3 next = polygon->points[(pointIndex + 1u) % polygon->pointCount];
        float currentDist = vec3_dot(plane.normal, current) - plane.distance;
        float nextDist = vec3_dot(plane.normal, next) - plane.distance;
        bool currentOutside = currentDist > epsilon;
        bool nextOutside = nextDist > epsilon;

        if (!currentOutside) {
            sledgehammer_geometry_bake_append_polygon_point(outInside, current);
        } else {
            sledgehammer_geometry_bake_append_polygon_point(outOutside, current);
        }

        if (currentOutside != nextOutside) {
            float denom = currentDist - nextDist;
            if (fabsf(denom) > 1e-6f) {
                float t = currentDist / denom;
                t = fminf(fmaxf(t, 0.0f), 1.0f);
                Vec3 intersection = vec3_add(current, vec3_scale(vec3_sub(next, current), t));
                sledgehammer_geometry_bake_append_polygon_point(outOutside, intersection);
                sledgehammer_geometry_bake_append_polygon_point(outInside, intersection);
            }
        }
    }

    if (outOutside->pointCount >= 2u && sledgehammer_geometry_bake_point_equals(outOutside->points[0], outOutside->points[outOutside->pointCount - 1u])) {
        outOutside->pointCount -= 1u;
    }
    if (outInside->pointCount >= 2u && sledgehammer_geometry_bake_point_equals(outInside->points[0], outInside->points[outInside->pointCount - 1u])) {
        outInside->pointCount -= 1u;
    }
}

static bool sledgehammer_geometry_bake_subtract_polygon_by_solid(const SledgehammerBakePolygon* source,
                                                                 const VmfSolid* solid,
                                                                 SledgehammerBakePolygon* outFragments,
                                                                 size_t maxFragments,
                                                                 size_t* outFragmentCount) {
    if (outFragmentCount == NULL || source == NULL || solid == NULL || solid->sideCount == 0u || solid->sideCount > 128u) {
        return false;
    }

    SledgehammerBakePlane planes[128];
    Vec3 interiorPoint = sledgehammer_geometry_bake_solid_reference_point(solid);
    for (size_t planeIndex = 0; planeIndex < solid->sideCount; ++planeIndex) {
        planes[planeIndex] = sledgehammer_geometry_bake_orient_plane_outward(sledgehammer_geometry_bake_plane_from_side(&solid->sides[planeIndex]), interiorPoint);
    }

    SledgehammerBakePolygon* insideQueue = (SledgehammerBakePolygon*)malloc(SLEDGEHAMMER_BAKE_MAX_FRAGMENTS * sizeof(SledgehammerBakePolygon));
    SledgehammerBakePolygon* nextInsideQueue = (SledgehammerBakePolygon*)malloc(SLEDGEHAMMER_BAKE_MAX_FRAGMENTS * sizeof(SledgehammerBakePolygon));
    if (insideQueue == NULL || nextInsideQueue == NULL) {
        free(insideQueue);
        free(nextInsideQueue);
        return false;
    }
    size_t insideCount = 1u;
    size_t keptCount = 0u;
    insideQueue[0] = *source;

    for (size_t planeIndex = 0; planeIndex < solid->sideCount; ++planeIndex) {
        size_t nextInsideCount = 0u;
        for (size_t fragmentIndex = 0; fragmentIndex < insideCount; ++fragmentIndex) {
            SledgehammerBakePolygon outsideFragment;
            SledgehammerBakePolygon insideFragment;
            sledgehammer_geometry_bake_split_polygon_by_plane(&insideQueue[fragmentIndex],
                                                              planes[planeIndex],
                                                              0.05f,
                                                              &outsideFragment,
                                                              &insideFragment);
            if (outsideFragment.pointCount >= 3u) {
                if (keptCount >= maxFragments) {
                    free(insideQueue);
                    free(nextInsideQueue);
                    return false;
                }
                outFragments[keptCount++] = outsideFragment;
            }
            if (insideFragment.pointCount >= 3u) {
                if (nextInsideCount >= SLEDGEHAMMER_BAKE_MAX_FRAGMENTS) {
                    free(insideQueue);
                    free(nextInsideQueue);
                    return false;
                }
                nextInsideQueue[nextInsideCount++] = insideFragment;
            }
        }
        insideCount = nextInsideCount;
        for (size_t fragmentIndex = 0; fragmentIndex < insideCount; ++fragmentIndex) {
            insideQueue[fragmentIndex] = nextInsideQueue[fragmentIndex];
        }
        if (insideCount == 0u) {
            break;
        }
    }

    *outFragmentCount = keptCount;
    free(insideQueue);
    free(nextInsideQueue);
    return true;
}

bool sledgehammer_geometry_collect_exposed_fragments(const VmfScene* scene,
                                                     size_t entityIndex,
                                                     size_t solidIndex,
                                                     size_t sideIndex,
                                                     SledgehammerBakePolygon* outFragments,
                                                     size_t maxFragments,
                                                     size_t* outFragmentCount,
                                                     Vec3* outFaceNormal) {
    if (outFragmentCount == NULL || outFragments == NULL || maxFragments == 0u ||
        scene == NULL || entityIndex >= scene->entityCount) {
        return false;
    }

    const VmfEntity* entity = &scene->entities[entityIndex];
    if (solidIndex >= entity->solidCount) {
        return false;
    }
    const VmfSolid* solid = &entity->solids[solidIndex];
    if (sideIndex >= solid->sideCount || solid->sides[sideIndex].dispinfo.hasData) {
        return false;
    }

    SledgehammerBakePolygon basePolygon;
    Vec3 faceNormal;
    if (!sledgehammer_geometry_bake_collect_face_polygon(solid, sideIndex, &basePolygon, &faceNormal)) {
        return false;
    }

    SledgehammerBakePolygon* fragments = (SledgehammerBakePolygon*)malloc(SLEDGEHAMMER_BAKE_MAX_FRAGMENTS * sizeof(SledgehammerBakePolygon));
    SledgehammerBakePolygon* nextFragments = (SledgehammerBakePolygon*)malloc(SLEDGEHAMMER_BAKE_MAX_FRAGMENTS * sizeof(SledgehammerBakePolygon));
    SledgehammerBakePolygon* subtractedFragments = (SledgehammerBakePolygon*)malloc(SLEDGEHAMMER_BAKE_MAX_FRAGMENTS * sizeof(SledgehammerBakePolygon));
    if (fragments == NULL || nextFragments == NULL || subtractedFragments == NULL) {
        free(fragments);
        free(nextFragments);
        free(subtractedFragments);
        return false;
    }

    size_t fragmentCount = 1u;
    bool subtractionFailed = false;
    fragments[0] = basePolygon;

    for (size_t occluderEntityIndex = 0u; occluderEntityIndex < scene->entityCount && !subtractionFailed; ++occluderEntityIndex) {
        const VmfEntity* occluderEntity = &scene->entities[occluderEntityIndex];
        if (occluderEntity->kind == VmfEntityKindLight || (!occluderEntity->isWorld && !occluderEntity->enabled)) {
            continue;
        }

        for (size_t occluderSolidIndex = 0u; occluderSolidIndex < occluderEntity->solidCount && !subtractionFailed; ++occluderSolidIndex) {
            const VmfSolid* occluderSolid = &occluderEntity->solids[occluderSolidIndex];
            if (occluderSolid == solid) {
                continue;
            }

            Bounds3 solidBounds = sledgehammer_geometry_bake_solid_bounds(occluderSolid);
            size_t nextFragmentCount = 0u;
            for (size_t fragmentIndex = 0u; fragmentIndex < fragmentCount; ++fragmentIndex) {
                Bounds3 fragmentBounds = sledgehammer_geometry_bake_polygon_bounds(&fragments[fragmentIndex]);
                if (!sledgehammer_geometry_bake_bounds_overlap(fragmentBounds, solidBounds, 0.05f)) {
                    if (nextFragmentCount >= maxFragments) {
                        subtractionFailed = true;
                        break;
                    }
                    nextFragments[nextFragmentCount++] = fragments[fragmentIndex];
                    continue;
                }

                size_t subtractedCount = 0u;
                if (!sledgehammer_geometry_bake_subtract_polygon_by_solid(&fragments[fragmentIndex],
                                                                          occluderSolid,
                                                                          subtractedFragments,
                                                                          maxFragments,
                                                                          &subtractedCount)) {
                    subtractionFailed = true;
                    break;
                }
                if (nextFragmentCount + subtractedCount > maxFragments) {
                    subtractionFailed = true;
                    break;
                }
                for (size_t subtractedIndex = 0u; subtractedIndex < subtractedCount; ++subtractedIndex) {
                    nextFragments[nextFragmentCount++] = subtractedFragments[subtractedIndex];
                }
            }

            fragmentCount = nextFragmentCount;
            for (size_t fragmentIndex = 0u; fragmentIndex < fragmentCount; ++fragmentIndex) {
                fragments[fragmentIndex] = nextFragments[fragmentIndex];
            }
            if (fragmentCount == 0u) {
                break;
            }
        }
    }

    if (!subtractionFailed) {
        *outFragmentCount = fragmentCount;
        for (size_t fragmentIndex = 0u; fragmentIndex < fragmentCount; ++fragmentIndex) {
            outFragments[fragmentIndex] = fragments[fragmentIndex];
        }
        if (outFaceNormal != NULL) {
            *outFaceNormal = faceNormal;
        }
    }

    free(fragments);
    free(nextFragments);
    free(subtractedFragments);
    return !subtractionFailed;
}

bool sledgehammer_geometry_face_range_is_bake_excluded(const ViewerFaceRange* range) {
    if (range == NULL) {
        return true;
    }
    return strcasecmp(range->material, "light_marker") == 0 ||
           strcasecmp(range->material, "model_marker") == 0;
}