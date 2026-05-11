#ifndef SLEDGEHAMMER_EDITOR_LOGIC_H
#define SLEDGEHAMMER_EDITOR_LOGIC_H

#include <stdbool.h>
#include <stddef.h>

#include "math3d.h"
#include "vmf_editor.h"
#include "vmf_geometry.h"
#include "vmf_parser.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum SledgehammerViewportPlane {
    SledgehammerViewportPlaneXY = 0,
    SledgehammerViewportPlaneXZ = 1,
    SledgehammerViewportPlaneZY = 2,
} SledgehammerViewportPlane;

typedef enum SledgehammerViewportSelectionEdge {
    SledgehammerViewportSelectionEdgeNone = 0,
    SledgehammerViewportSelectionEdgeMinU = 1,
    SledgehammerViewportSelectionEdgeMaxU = 2,
    SledgehammerViewportSelectionEdgeMinV = 3,
    SledgehammerViewportSelectionEdgeMaxV = 4,
} SledgehammerViewportSelectionEdge;

typedef enum SledgehammerViewportEditorTool {
    SledgehammerViewportEditorToolSelect = 0,
    SledgehammerViewportEditorToolVertex = 1,
    SledgehammerViewportEditorToolBlock = 2,
    SledgehammerViewportEditorToolCylinder = 3,
    SledgehammerViewportEditorToolRamp = 4,
    SledgehammerViewportEditorToolStairs = 5,
    SledgehammerViewportEditorToolArch = 6,
    SledgehammerViewportEditorToolClip = 7,
} SledgehammerViewportEditorTool;

int sledgehammer_editor_logic_selection_edge_for_plane(int plane, size_t sideIndex);
int sledgehammer_editor_logic_side_index_for_plane(int plane, int edge);
Vec3 sledgehammer_editor_logic_duplicate_offset_for_plane(int plane, float delta);
VmfBrushAxis sledgehammer_editor_logic_active_brush_axis_for_plane(int plane);
VmfBrushAxis sledgehammer_editor_logic_run_brush_axis_for_plane(int plane);
size_t sledgehammer_editor_logic_solid_count_for_shape_tool(int tool, int primaryValue);
int sledgehammer_editor_logic_default_shape_primary_value(int tool,
                                                          Bounds3 bounds,
                                                          VmfBrushAxis upAxis,
                                                          VmfBrushAxis runAxis,
                                                          float gridSize);
int sledgehammer_editor_logic_minimum_shape_primary_value(int tool);
int sledgehammer_editor_logic_maximum_shape_primary_value(int tool);
bool sledgehammer_editor_logic_tool_has_secondary_shape_setting(int tool);
float sledgehammer_editor_logic_default_shape_secondary_value(int tool);
const char* sledgehammer_editor_logic_shape_primary_label(int tool);
const char* sledgehammer_editor_logic_shape_secondary_label(int tool);
const char* sledgehammer_editor_logic_shape_settings_panel_title(int tool);
const VmfSide* sledgehammer_editor_logic_selected_face_side(const VmfScene* scene,
                                                            bool hasSelection,
                                                            bool hasFaceSelection,
                                                            bool hasEditingPrefab,
                                                            size_t selectedEntityIndex,
                                                            size_t selectedSolidIndex,
                                                            size_t selectedSideIndex);
void sledgehammer_editor_logic_default_texture_axes_for_side(const VmfSide* side,
                                                             Vec3* outUAxis,
                                                             Vec3* outVAxis);
float sledgehammer_editor_logic_texture_rotation_degrees_for_side(const VmfSide* side);
float sledgehammer_editor_logic_entity_pick_radius(const VmfEntity* entity);
bool sledgehammer_editor_logic_entity_is_grouped_brush(const VmfScene* scene, size_t entityIndex);
size_t sledgehammer_editor_logic_entity_index_for_id(const VmfScene* scene, int entityId);
bool sledgehammer_editor_logic_entity_is_point_entity(const VmfScene* scene, size_t entityIndex);
bool sledgehammer_editor_logic_selection_is_grouped_brush(const VmfScene* scene,
                                                          bool hasSelection,
                                                          size_t selectedEntityIndex);
bool sledgehammer_editor_logic_selection_is_point_entity(const VmfScene* scene,
                                                         bool hasSelection,
                                                         size_t selectedEntityIndex);
size_t sledgehammer_editor_logic_active_group_entity_index(const VmfScene* scene,
                                                           bool hasSelection,
                                                           size_t selectedEntityIndex,
                                                           int activeGroupEntityId);
size_t sledgehammer_editor_logic_grouped_brush_entity_count(const VmfScene* scene);
bool sledgehammer_editor_logic_entity_bounds(const VmfScene* scene,
                                             size_t entityIndex,
                                             Bounds3* outBounds);
bool sledgehammer_editor_logic_selection_has_editable_face_texture(const VmfScene* scene,
                                                                   bool hasSelection,
                                                                   bool hasFaceSelection,
                                                                   bool hasEditingPrefab,
                                                                   size_t selectedEntityIndex,
                                                                   size_t selectedSolidIndex,
                                                                   size_t selectedSideIndex);
bool sledgehammer_editor_logic_selected_solid_is_box_brush(const VmfScene* scene,
                                                           bool hasSelection,
                                                           size_t selectedEntityIndex,
                                                           size_t selectedSolidIndex);
bool sledgehammer_editor_logic_pick_point_entity_at_point(const VmfScene* scene,
                                                          Vec3 point,
                                                          int plane,
                                                          size_t* outEntityIndex);
bool sledgehammer_editor_logic_pick_point_entity_ray(const VmfScene* scene,
                                                     Vec3 origin,
                                                     Vec3 direction,
                                                     size_t* outEntityIndex);
bool sledgehammer_editor_logic_pick_scene_at_point_2d(const VmfScene* scene,
                                                      Vec3 point,
                                                      int plane,
                                                      size_t* outEntityIndex,
                                                      size_t* outSolidIndex);
size_t sledgehammer_editor_logic_collect_pick_candidates_2d(const VmfScene* scene,
                                                            Vec3 point,
                                                            int plane,
                                                            size_t* outEntityIndices,
                                                            size_t* outSolidIndices,
                                                            size_t maxCandidates);
size_t sledgehammer_editor_logic_collect_point_entity_ray_candidates(const VmfScene* scene,
                                                                     Vec3 origin,
                                                                     Vec3 direction,
                                                                     size_t* outEntityIndices,
                                                                     float* outDistances,
                                                                     float* outPickRadii,
                                                                     size_t maxCandidates);
bool sledgehammer_editor_logic_is_draft_convex(const Vec3* draftVertices,
                                               size_t draftVertexCount,
                                               const size_t* draftEdgeConnVA,
                                               const size_t* draftEdgeConnVB,
                                               const VmfSolidEdge* draftEdgeTemplates,
                                               size_t draftEdgeConnCount,
                                               const Vec3* draftFaceRefNormals,
                                               const size_t* draftFaceSideIndices,
                                               size_t draftFaceCount);
size_t sledgehammer_editor_logic_build_draft_display_edges(const Vec3* draftVertices,
                                                           const size_t* draftEdgeConnVA,
                                                           const size_t* draftEdgeConnVB,
                                                           const VmfSolidEdge* draftEdgeTemplates,
                                                           size_t draftEdgeConnCount,
                                                           VmfSolidEdge* outEdges);
size_t sledgehammer_editor_logic_build_draft_preview_vertices(const Vec3* draftVertices,
                                                              const size_t* draftEdgeConnVA,
                                                              const size_t* draftEdgeConnVB,
                                                              size_t draftEdgeConnCount,
                                                              Vec3 previewColor,
                                                              ViewerVertex* outVertices);

#ifdef __cplusplus
}
#endif

#endif
