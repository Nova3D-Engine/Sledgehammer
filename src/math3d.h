#ifndef MATH3D_H
#define MATH3D_H

#include <float.h>

#include <cglm/struct.h>

typedef vec2s Vec2;
typedef vec3s Vec3;
typedef mat4s Mat4;

typedef struct Bounds3 {
    Vec3 min;
    Vec3 max;
} Bounds3;

static inline Vec3 vec3_make(float x, float y, float z) {
    return (Vec3) { .raw = { x, y, z } };
}

static inline Vec2 vec2_make(float x, float y) {
    return (Vec2) { .raw = { x, y } };
}

static inline Vec3 vec3_add(Vec3 a, Vec3 b) {
    return glms_vec3_add(a, b);
}

static inline Vec3 vec3_sub(Vec3 a, Vec3 b) {
    return glms_vec3_sub(a, b);
}

static inline Vec3 vec3_scale(Vec3 v, float s) {
    return glms_vec3_scale(v, s);
}

static inline Vec3 vec3_lerp(Vec3 a, Vec3 b, float t) {
    return vec3_add(a, vec3_scale(vec3_sub(b, a), t));
}

static inline float vec3_dot(Vec3 a, Vec3 b) {
    return glms_vec3_dot(a, b);
}

static inline Vec3 vec3_cross(Vec3 a, Vec3 b) {
    return glms_vec3_cross(a, b);
}

static inline float vec3_length(Vec3 v) {
    return glms_vec3_norm(v);
}

static inline Vec3 vec3_normalize(Vec3 v) {
    if (vec3_length(v) < 1e-6f) {
        return vec3_make(0.0f, 0.0f, 0.0f);
    }
    return glms_vec3_normalize(v);
}

static inline Vec3 vec3_min(Vec3 a, Vec3 b) {
    return glms_vec3_minv(a, b);
}

static inline Vec3 vec3_max(Vec3 a, Vec3 b) {
    return glms_vec3_maxv(a, b);
}

static inline Bounds3 bounds3_empty(void) {
    Bounds3 bounds;
    bounds.min = vec3_make(FLT_MAX, FLT_MAX, FLT_MAX);
    bounds.max = vec3_make(-FLT_MAX, -FLT_MAX, -FLT_MAX);
    return bounds;
}

static inline int bounds3_is_valid(Bounds3 bounds) {
    return bounds.min.raw[0] <= bounds.max.raw[0] &&
        bounds.min.raw[1] <= bounds.max.raw[1] &&
        bounds.min.raw[2] <= bounds.max.raw[2];
}

static inline void bounds3_expand(Bounds3* bounds, Vec3 point) {
    bounds->min = vec3_min(bounds->min, point);
    bounds->max = vec3_max(bounds->max, point);
}

static inline Vec3 bounds3_center(Bounds3 bounds) {
    return vec3_scale(vec3_add(bounds.min, bounds.max), 0.5f);
}

static inline Vec3 bounds3_size(Bounds3 bounds) {
    return vec3_sub(bounds.max, bounds.min);
}

static inline Mat4 cglm_mat4_identity(void) {
    return glms_mat4_identity();
}

static inline Mat4 cglm_mat4_mul(Mat4 a, Mat4 b) {
    return glms_mat4_mul(a, b);
}

static inline Mat4 cglm_mat4_translate(Vec3 t) {
    return glms_translate_make(t);
}

static inline Mat4 cglm_mat4_perspective(float fovYRadians, float aspect, float nearZ, float farZ) {
    return glms_perspective(fovYRadians, aspect, nearZ, farZ);
}

static inline Mat4 cglm_mat4_ortho(float left, float right, float bottom, float top, float nearZ, float farZ) {
    return glms_ortho(left, right, bottom, top, nearZ, farZ);
}

static inline Mat4 cglm_mat4_look_at(Vec3 eye, Vec3 target, Vec3 up) {
    return glms_lookat(eye, target, up);
}

#endif
