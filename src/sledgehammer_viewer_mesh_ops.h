#ifndef SLEDGEHAMMER_VIEWER_MESH_OPS_H
#define SLEDGEHAMMER_VIEWER_MESH_OPS_H

#include <stdbool.h>

#include "viewport.h"
#include "vmf_parser.h"

bool sledgehammer_viewer_mesh_bounds_equal(Bounds3 a, Bounds3 b);
void sledgehammer_viewer_mesh_translate_entity(ViewerMesh* mesh, size_t entityIndex, Vec3 delta);
void sledgehammer_viewer_mesh_translate_solid(ViewerMesh* mesh, size_t entityIndex, size_t solidIndex, Vec3 delta);

#endif