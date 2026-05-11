#import "sledgehammer_viewer_app_internal.h"

#include "sledgehammer_editor_logic.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation ViewerAppDelegate (VertexEdit)

- (void)startVertexEditSession {
    if (!self.hasSelection) {
        return;
    }
    if (_hasVertexEditSession &&
        _vertexEditEntityIndex == self.selectedEntityIndex &&
        _vertexEditSolidIndex == self.selectedSolidIndex) {
        return;
    }
    [self endVertexEditSession:NO];

    _vertexEditEntityIndex = self.selectedEntityIndex;
    _vertexEditSolidIndex = self.selectedSolidIndex;
    _hasVertexEditSession = YES;
    _draftIsValid = YES;

    _draftVertexCount = 0;
    char vertErr[256] = { 0 };
    vmf_scene_solid_vertices(&_scene,
                             self.selectedEntityIndex,
                             self.selectedSolidIndex,
                             _draftVertices,
                             VMF_MAX_SOLID_VERTICES,
                             &_draftVertexCount,
                             vertErr, sizeof(vertErr));

    VmfSolidEdge edges[VMF_MAX_SOLID_EDGES];
    size_t edgeCount = 0;
    char edgeErr[256] = { 0 };
    vmf_scene_solid_edges(&_scene,
                          self.selectedEntityIndex,
                          self.selectedSolidIndex,
                          edges, VMF_MAX_SOLID_EDGES, &edgeCount,
                          edgeErr, sizeof(edgeErr));
    _draftEdgeConnCount = 0;
    for (size_t i = 0; i < edgeCount; ++i) {
        size_t vA = SIZE_MAX, vB = SIZE_MAX;
        for (size_t v = 0; v < _draftVertexCount; ++v) {
            if (vec3_length(vec3_sub(_draftVertices[v], edges[i].start)) < 0.1f) { vA = v; }
            if (vec3_length(vec3_sub(_draftVertices[v], edges[i].end)) < 0.1f) { vB = v; }
        }
        if (vA != SIZE_MAX && vB != SIZE_MAX && _draftEdgeConnCount < VMF_MAX_SOLID_EDGES) {
            _draftEdgeConnVA[_draftEdgeConnCount] = vA;
            _draftEdgeConnVB[_draftEdgeConnCount] = vB;
            _draftEdgeTemplates[_draftEdgeConnCount] = edges[i];
            ++_draftEdgeConnCount;
        }
    }

    _draftFaceCount = 0;
    VmfSolid* baseSolid = &_scene.entities[_vertexEditEntityIndex].solids[_vertexEditSolidIndex];
    Vec3 interior = vec3_make(0.0f, 0.0f, 0.0f);
    float sampleCount = 0.0f;
    for (size_t s = 0; s < baseSolid->sideCount; ++s) {
        for (size_t p = 0; p < 3; ++p) {
            interior = vec3_add(interior, baseSolid->sides[s].points[p]);
            sampleCount += 1.0f;
        }
    }
    if (sampleCount > 0.0f) {
        interior = vec3_scale(interior, 1.0f / sampleCount);
    }
    for (size_t e = 0; e < _draftEdgeConnCount; ++e) {
        for (int ep = 0; ep < 2; ++ep) {
            size_t sideIdx = _draftEdgeTemplates[e].sideIndices[ep];
            BOOL found = NO;
            for (size_t f = 0; f < _draftFaceCount; ++f) {
                if (_draftFaceSideIndices[f] == sideIdx) { found = YES; break; }
            }
            if (found || _draftFaceCount >= 128 || sideIdx >= baseSolid->sideCount) {
                continue;
            }
            Vec3 p0 = baseSolid->sides[sideIdx].points[0];
            Vec3 p1 = baseSolid->sides[sideIdx].points[1];
            Vec3 p2 = baseSolid->sides[sideIdx].points[2];
            Vec3 n = vec3_normalize(vec3_cross(vec3_sub(p1, p0), vec3_sub(p2, p0)));
            if (vec3_dot(n, vec3_sub(interior, p0)) > 0.0f) {
                n = vec3_scale(n, -1.0f);
            }
            _draftFaceSideIndices[_draftFaceCount] = sideIdx;
            _draftFaceRefNormals[_draftFaceCount] = n;
            ++_draftFaceCount;
        }
    }
}

- (void)pushDraftOverlayToViewports {
    VmfSolidEdge displayEdges[VMF_MAX_SOLID_EDGES];
    size_t displayEdgeCount = sledgehammer_editor_logic_build_draft_display_edges(_draftVertices,
                                                                                  _draftEdgeConnVA,
                                                                                  _draftEdgeConnVB,
                                                                                  _draftEdgeTemplates,
                                                                                  _draftEdgeConnCount,
                                                                                  displayEdges);

    Vec3 previewColor = _draftIsValid ? vec3_make(0.86f, 0.73f, 0.33f) : vec3_make(0.95f, 0.22f, 0.22f);
    ViewerVertex previewVerts[VMF_MAX_SOLID_EDGES * 2];
    size_t previewVertCount = sledgehammer_editor_logic_build_draft_preview_vertices(_draftVertices,
                                                                                     _draftEdgeConnVA,
                                                                                     _draftEdgeConnVB,
                                                                                     _draftEdgeConnCount,
                                                                                     previewColor,
                                                                                     previewVerts);

    for (VmfViewport* vp in self.viewports) {
        [vp setSelectionVertices:_draftVertices count:_draftVertexCount visible:YES];
        [vp setSelectionEdges:displayEdges count:displayEdgeCount visible:YES];
        [vp setVertexEditIsInvalid:!_draftIsValid];
        if (vp.dimension == VmfViewportDimension3D) {
            [vp setVertexEditPreviewEdges:previewVerts count:previewVertCount];
        }
    }
}

- (void)endVertexEditSession:(BOOL)tryApply {
    if (!_hasVertexEditSession) {
        return;
    }

    for (VmfViewport* vp in self.viewports) {
        [vp clearVertexEditPreview];
        [vp setVertexEditIsInvalid:NO];
    }

    if (tryApply && _draftIsValid && _draftVertexCount > 0) {
        VmfSolidVertex solidVerts[VMF_MAX_SOLID_VERTICES];
        size_t solidVertCount = 0;
        char refErr[256] = { 0 };
        vmf_scene_solid_vertex_refs(&_scene, _vertexEditEntityIndex, _vertexEditSolidIndex,
                                    solidVerts, VMF_MAX_SOLID_VERTICES, &solidVertCount,
                                    refErr, sizeof(refErr));

        VmfVertexMove moves[VMF_MAX_SOLID_VERTICES];
        size_t moveCount = 0;
        if (solidVertCount == _draftVertexCount) {
            static const float mergeEps = 0.5f;
            Vec3 committed[VMF_MAX_SOLID_VERTICES];
            memcpy(committed, _draftVertices, _draftVertexCount * sizeof(Vec3));
            for (size_t i = 0; i < _draftVertexCount; ++i) {
                for (size_t j = 0; j < i; ++j) {
                    if (vec3_length(vec3_sub(committed[i], committed[j])) < mergeEps) {
                        committed[i] = committed[j];
                    }
                }
            }
            for (size_t i = 0; i < _draftVertexCount; ++i) {
                if (vec3_length(vec3_sub(committed[i], solidVerts[i].position)) >= 0.01f) {
                    moves[moveCount++] = (VmfVertexMove){ .vertexIndex = i, .newPosition = committed[i] };
                }
            }
        }

        if (moveCount > 0) {
            SceneHistoryEntry* entry = [self captureHistoryEntry];
            char moveErr[256] = { 0 };
            if (vmf_scene_move_solid_vertices(&_scene, _vertexEditEntityIndex, _vertexEditSolidIndex,
                                              moves, moveCount, moveErr, sizeof(moveErr))) {
                if (entry) {
                    [self pushUndoEntry:entry];
                }
                [self markDocumentChangedWithLabel:@"Edit Vertices"];
            }
        }
    }

    _hasVertexEditSession = NO;
    _draftVertexCount = 0;
    _draftEdgeConnCount = 0;
    _draftIsValid = YES;

    [self rebuildMeshFromScene];
}

- (void)syncSelectionOverlay {
    if (_hasVertexEditSession && self.hasSelection &&
        _vertexEditEntityIndex == self.selectedEntityIndex &&
        _vertexEditSolidIndex == self.selectedSolidIndex) {
        Bounds3 selectionBounds = bounds3_empty();
        char boundsErr[256] = { 0 };
        vmf_scene_solid_bounds(&_scene, self.selectedEntityIndex, self.selectedSolidIndex, &selectionBounds, boundsErr, sizeof(boundsErr));
        for (VmfViewport* viewport in self.viewports) {
            viewport.selectionEditable = YES;
            [viewport setSelectionRotationDegrees:vec3_make(0.0f, 0.0f, 0.0f) rotatable:NO];
            [viewport setSelectionBounds:selectionBounds visible:YES];
            [viewport setSelectedFaceEdge:VmfViewportSelectionEdgeNone];
        }
        [self pushDraftOverlayToViewports];
        return;
    }

    Bounds3 selectionBounds = bounds3_empty();
    Vec3 selectionVertices[VMF_MAX_SOLID_VERTICES];
    size_t selectionVertexCount = 0;
    VmfSolidEdge selectionEdges[VMF_MAX_SOLID_EDGES];
    size_t selectionEdgeCount = 0;
    BOOL showSelection = self.hasSelection;
    BOOL prefabSelection = [self selectionIsPrefab];
    BOOL pointEntitySelection = [self selectionIsPointEntity];
    BOOL modelPointSelection = pointEntitySelection &&
        self.selectedEntityIndex < self.scene.entityCount &&
        self.scene.entities[self.selectedEntityIndex].kind == VmfEntityKindModel;
    BOOL groupedBrushSelection = [self selectionIsGroupedBrushEntity];
    BOOL boxSelection = !prefabSelection && !groupedBrushSelection && [self isSelectedSolidBoxBrush];
    if (showSelection) {
        if (prefabSelection) {
            ProceduralShapePrefab* prefab = [self prefabContainingEntityIndex:self.selectedEntityIndex solidIndex:self.selectedSolidIndex];
            selectionBounds = prefab.bounds;
        } else if (pointEntitySelection || groupedBrushSelection) {
            showSelection = [self selectedEntityBounds:&selectionBounds];
            if (pointEntitySelection && _hasPointEntityDragPreview && _pointEntityDragEntityIndex == self.selectedEntityIndex) {
                selectionBounds = _pointEntityDragBounds;
                showSelection = bounds3_is_valid(selectionBounds) ? YES : showSelection;
            }
        } else {
            char errorBuffer[256] = { 0 };
            showSelection = vmf_scene_solid_bounds(&_scene, self.selectedEntityIndex, self.selectedSolidIndex, &selectionBounds, errorBuffer, sizeof(errorBuffer));
        }
        if ([self selectionIsGroupedBrushEntity] && self.selectedEntityIndex < self.scene.entityCount) {
            self.activeGroupEntityId = self.scene.entities[self.selectedEntityIndex].id;
        }
        if (showSelection && !prefabSelection && !pointEntitySelection && !groupedBrushSelection) {
            char vertexErrorBuffer[256] = { 0 };
            if (!vmf_scene_solid_vertices(&_scene,
                                          self.selectedEntityIndex,
                                          self.selectedSolidIndex,
                                          selectionVertices,
                                          VMF_MAX_SOLID_VERTICES,
                                          &selectionVertexCount,
                                          vertexErrorBuffer,
                                          sizeof(vertexErrorBuffer))) {
                selectionVertexCount = 0;
            }
            char edgeErrorBuffer[256] = { 0 };
            if (!vmf_scene_solid_edges(&_scene,
                                       self.selectedEntityIndex,
                                       self.selectedSolidIndex,
                                       selectionEdges,
                                       VMF_MAX_SOLID_EDGES,
                                       &selectionEdgeCount,
                                       edgeErrorBuffer,
                                       sizeof(edgeErrorBuffer))) {
                selectionEdgeCount = 0;
            }
        }
    }
    for (VmfViewport* viewport in self.viewports) {
        viewport.selectionEditable = showSelection;
        [viewport setSelectionRotationDegrees:(modelPointSelection ? self.scene.entities[self.selectedEntityIndex].rotationDegrees : vec3_make(0.0f, 0.0f, 0.0f))
                                    rotatable:(showSelection && modelPointSelection)];
        [viewport setSelectionVertices:selectionVertices count:selectionVertexCount visible:(showSelection && !prefabSelection && !pointEntitySelection && !groupedBrushSelection)];
        [viewport setSelectionEdges:selectionEdges count:selectionEdgeCount visible:(showSelection && !prefabSelection && !pointEntitySelection && !groupedBrushSelection)];
        [viewport setSelectedFaceEdge:(showSelection && !prefabSelection && !pointEntitySelection && !groupedBrushSelection && self.hasFaceSelection && boxSelection) ? [self selectionEdgeForPlane:viewport.plane sideIndex:self.selectedSideIndex] : VmfViewportSelectionEdgeNone];
        [viewport setSelectedFaceHighlightEntityIndex:(showSelection && !prefabSelection && !pointEntitySelection && !groupedBrushSelection && self.hasFaceSelection) ? self.selectedEntityIndex : 0
                                            solidIndex:(showSelection && !prefabSelection && !pointEntitySelection && !groupedBrushSelection && self.hasFaceSelection) ? self.selectedSolidIndex : 0
                                             sideIndex:(showSelection && !prefabSelection && !pointEntitySelection && !groupedBrushSelection && self.hasFaceSelection) ? self.selectedSideIndex : 0
                                               visible:(showSelection && !prefabSelection && !pointEntitySelection && !groupedBrushSelection && self.hasFaceSelection)];
        [viewport setSelectionBounds:selectionBounds visible:showSelection];
        if (!showSelection) {
            [viewport setVertexEditIsInvalid:NO];
        }
    }
}

@end

#pragma clang diagnostic pop
