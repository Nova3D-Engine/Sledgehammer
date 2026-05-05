#pragma once

#include <imgui.h>

#include <cmath>
#include <cstdint>

namespace ImGizmo2D {

inline ImGuiID HashID(const char* id, int handle) {
    ImGuiID hash = 2166136261u;
    if (id != nullptr) {
        for (const unsigned char* p = reinterpret_cast<const unsigned char*>(id); *p != 0u; ++p) {
            hash ^= static_cast<ImGuiID>(*p);
            hash *= 16777619u;
        }
    }
    hash ^= static_cast<ImGuiID>(static_cast<uint32_t>(handle) * 2654435761u);
    return hash;
}

struct Context {
    ImDrawList* drawList = nullptr;

    ImVec2 viewOrigin = ImVec2(0.0f, 0.0f);
    ImVec2 viewSize = ImVec2(0.0f, 0.0f);
    ImVec2 cameraPos = ImVec2(0.0f, 0.0f);
    float zoom = 1.0f;

    float handleRadius = 6.0f;
    float lineThickness = 2.0f;
    float snapGrid = 0.0f;

    ImU32 colIdle = IM_COL32(100, 200, 220, 255);
    ImU32 colHover = IM_COL32(255, 220, 80, 255);
    ImU32 colActive = IM_COL32(255, 255, 120, 255);
    ImU32 colLine = IM_COL32(100, 200, 220, 180);
    ImU32 colFill = IM_COL32(100, 200, 220, 30);
    ImU32 colAxisX = IM_COL32(230, 70, 70, 255);
    ImU32 colAxisY = IM_COL32(70, 200, 70, 255);
    ImU32 colAxisZ = IM_COL32(80, 140, 255, 255);

    ImGuiID activeId = 0;
    ImGuiID hoveredId = 0;
    const char* activeName = nullptr;
    const char* hoveredName = nullptr;
    ImVec2 grabOffset = ImVec2(0.0f, 0.0f);
};

inline Context& GetContext() {
    static Context ctx;
    return ctx;
}

inline void SetDrawList(ImDrawList* dl) {
    GetContext().drawList = dl;
}

inline void SetViewRect(ImVec2 origin, ImVec2 size) {
    Context& ctx = GetContext();
    ctx.viewOrigin = origin;
    ctx.viewSize = size;
}

inline void SetViewTransform(float camX, float camY, float zoom) {
    Context& ctx = GetContext();
    ctx.cameraPos = ImVec2(camX, camY);
    ctx.zoom = (zoom == 0.0f) ? 1.0f : zoom;
}

inline void SetSnapGrid(float snap) {
    GetContext().snapGrid = snap;
}

inline void SetHandleRadius(float radius) {
    GetContext().handleRadius = (radius > 1.0f) ? radius : 1.0f;
}

inline void SetColors(ImU32 idle, ImU32 hover, ImU32 active) {
    Context& ctx = GetContext();
    ctx.colIdle = idle;
    ctx.colHover = hover;
    ctx.colActive = active;
}

inline void SetLineColor(ImU32 col) {
    GetContext().colLine = col;
}

inline void SetFillColor(ImU32 col) {
    GetContext().colFill = col;
}

inline void SetAxisColors(ImU32 x, ImU32 y, ImU32 z = IM_COL32(80, 140, 255, 255)) {
    Context& ctx = GetContext();
    ctx.colAxisX = x;
    ctx.colAxisY = y;
    ctx.colAxisZ = z;
}

inline void SetAxisColorZ(ImU32 z) {
    GetContext().colAxisZ = z;
}

inline void SetLineThickness(float thickness) {
    GetContext().lineThickness = (thickness > 0.5f) ? thickness : 0.5f;
}

inline void BeginFrame() {
    Context& ctx = GetContext();
    if (ctx.drawList == nullptr) {
        ctx.drawList = ImGui::GetWindowDrawList();
    }

    ctx.hoveredId = 0;
    ctx.hoveredName = nullptr;
    if (!ImGui::IsMouseDown(0)) {
        ctx.activeId = 0;
        ctx.activeName = nullptr;
        ctx.grabOffset = ImVec2(0.0f, 0.0f);
    }
}

inline float Snap(float value, float grid) {
    if (grid <= 0.0f) {
        return value;
    }
    return std::round(value / grid) * grid;
}

inline ImVec2 WorldToScreen(float wx, float wy) {
    const Context& ctx = GetContext();
    const float sx = ctx.viewOrigin.x + (wx - ctx.cameraPos.x) * ctx.zoom + (ctx.viewSize.x * 0.5f);
    const float sy = ctx.viewOrigin.y + (wy - ctx.cameraPos.y) * ctx.zoom + (ctx.viewSize.y * 0.5f);
    return ImVec2(sx, sy);
}

inline ImVec2 ScreenToWorld(float sx, float sy) {
    const Context& ctx = GetContext();
    const float safeZoom = (std::fabs(ctx.zoom) < 1e-6f) ? 1.0f : ctx.zoom;
    const float wx = ((sx - ctx.viewOrigin.x - (ctx.viewSize.x * 0.5f)) / safeZoom) + ctx.cameraPos.x;
    const float wy = ((sy - ctx.viewOrigin.y - (ctx.viewSize.y * 0.5f)) / safeZoom) + ctx.cameraPos.y;
    return ImVec2(wx, wy);
}

inline bool HasDrawList() {
    return GetContext().drawList != nullptr;
}

inline bool HandlePoint(const char* parentId, int handle, float* x, float* y) {
    if (x == nullptr || y == nullptr || !HasDrawList()) {
        return false;
    }

    Context& ctx = GetContext();
    const ImGuiID id = HashID(parentId, handle);

    const ImVec2 point = WorldToScreen(*x, *y);
    const ImVec2 mouse = ImGui::GetMousePos();
    const float dx = mouse.x - point.x;
    const float dy = mouse.y - point.y;
    const float dist = std::sqrt(dx * dx + dy * dy);

    const bool hovered = (dist <= (ctx.handleRadius + 3.0f));
    const bool active = (ctx.activeId == id);
    bool modified = false;

    if (hovered && ctx.activeId == 0) {
        ctx.hoveredId = id;
        ctx.hoveredName = parentId;
    }

    if (hovered && ImGui::IsMouseClicked(0) && ctx.activeId == 0) {
        ctx.activeId = id;
        ctx.activeName = parentId;
        const ImVec2 worldMouse = ScreenToWorld(mouse.x, mouse.y);
        ctx.grabOffset = ImVec2(worldMouse.x - *x, worldMouse.y - *y);
    }

    if (active && ImGui::IsMouseDown(0)) {
        const ImVec2 worldMouse = ScreenToWorld(mouse.x, mouse.y);
        *x = Snap(worldMouse.x - ctx.grabOffset.x, ctx.snapGrid);
        *y = Snap(worldMouse.y - ctx.grabOffset.y, ctx.snapGrid);
        modified = true;
    }

    ImU32 color = ctx.colIdle;
    if (active) {
        color = ctx.colActive;
    } else if (ctx.hoveredId == id) {
        color = ctx.colHover;
    }

    ctx.drawList->AddCircleFilled(point, ctx.handleRadius, color);
    ctx.drawList->AddCircle(point, ctx.handleRadius, IM_COL32(0, 0, 0, 180), 0, 1.5f);

    return modified;
}

inline bool HandleAxis(const char* parentId, int handle, float* value, float wx, float wy, bool isX) {
    if (value == nullptr || !HasDrawList()) {
        return false;
    }

    Context& ctx = GetContext();
    const ImGuiID id = HashID(parentId, handle);

    const ImVec2 point = WorldToScreen(wx, wy);
    const ImVec2 mouse = ImGui::GetMousePos();
    const float dx = mouse.x - point.x;
    const float dy = mouse.y - point.y;
    const float dist = std::sqrt(dx * dx + dy * dy);

    const bool hovered = (dist <= (ctx.handleRadius + 4.0f));
    const bool active = (ctx.activeId == id);
    bool modified = false;

    if (hovered && ctx.activeId == 0) {
        ctx.hoveredId = id;
        ctx.hoveredName = parentId;
    }

    if (hovered && ImGui::IsMouseClicked(0) && ctx.activeId == 0) {
        ctx.activeId = id;
        ctx.activeName = parentId;
        const ImVec2 worldMouse = ScreenToWorld(mouse.x, mouse.y);
        ctx.grabOffset = isX ? ImVec2(worldMouse.x - *value, 0.0f) : ImVec2(0.0f, worldMouse.y - *value);
    }

    if (active && ImGui::IsMouseDown(0)) {
        const ImVec2 worldMouse = ScreenToWorld(mouse.x, mouse.y);
        if (isX) {
            *value = Snap(worldMouse.x - ctx.grabOffset.x, ctx.snapGrid);
        } else {
            *value = Snap(worldMouse.y - ctx.grabOffset.y, ctx.snapGrid);
        }
        modified = true;
    }

    ImU32 color = isX ? ctx.colAxisX : ctx.colAxisY;
    if (active) {
        color = ctx.colActive;
    } else if (ctx.hoveredId == id) {
        color = ctx.colHover;
    }

    ctx.drawList->AddCircleFilled(point, ctx.handleRadius - 1.0f, color);
    ctx.drawList->AddCircle(point, ctx.handleRadius - 1.0f, IM_COL32(0, 0, 0, 180), 0, 1.5f);

    return modified;
}

inline bool Translate(const char* id, float* x, float* y) {
    if (x == nullptr || y == nullptr || !HasDrawList()) {
        return false;
    }

    Context& ctx = GetContext();
    bool modified = false;

    const float axisLen = 40.0f;
    const ImVec2 center = WorldToScreen(*x, *y);
    const ImVec2 axisX = ImVec2(center.x + axisLen, center.y);
    const ImVec2 axisY = ImVec2(center.x, center.y + axisLen);

    ctx.drawList->AddLine(center, axisX, ctx.colAxisX, ctx.lineThickness);
    ctx.drawList->AddLine(center, axisY, ctx.colAxisY, ctx.lineThickness);
    ctx.drawList->AddTriangleFilled(ImVec2(axisX.x + 6.0f, axisX.y), ImVec2(axisX.x - 2.0f, axisX.y - 5.0f), ImVec2(axisX.x - 2.0f, axisX.y + 5.0f), ctx.colAxisX);
    ctx.drawList->AddTriangleFilled(ImVec2(axisY.x, axisY.y + 6.0f), ImVec2(axisY.x - 5.0f, axisY.y - 2.0f), ImVec2(axisY.x + 5.0f, axisY.y - 2.0f), ctx.colAxisY);

    const float axisHandleX = *x + (axisLen / ((std::fabs(ctx.zoom) < 1e-6f) ? 1.0f : ctx.zoom));
    const float axisHandleY = *y + (axisLen / ((std::fabs(ctx.zoom) < 1e-6f) ? 1.0f : ctx.zoom));

    modified |= HandleAxis(id, 1, x, axisHandleX, *y, true);
    modified |= HandleAxis(id, 2, y, *x, axisHandleY, false);
    modified |= HandlePoint(id, 0, x, y);
    return modified;
}

inline bool Rect(const char* id, float* x, float* y, float* w, float* h) {
    if (x == nullptr || y == nullptr || w == nullptr || h == nullptr || !HasDrawList()) {
        return false;
    }

    Context& ctx = GetContext();
    bool modified = false;

    const float x0 = *x;
    const float y0 = *y;
    const float x1 = *x + *w;
    const float y1 = *y + *h;

    const ImVec2 minP = WorldToScreen((x0 < x1) ? x0 : x1, (y0 < y1) ? y0 : y1);
    const ImVec2 maxP = WorldToScreen((x0 > x1) ? x0 : x1, (y0 > y1) ? y0 : y1);

    ctx.drawList->AddRectFilled(minP, maxP, ctx.colFill);
    ctx.drawList->AddRect(minP, maxP, ctx.colLine, 0.0f, 0, ctx.lineThickness);

    float corners[4][2] = {
        {*x, *y},
        {*x + *w, *y},
        {*x, *y + *h},
        {*x + *w, *y + *h},
    };

    for (int i = 0; i < 4; ++i) {
        float px = corners[i][0];
        float py = corners[i][1];
        if (HandlePoint(id, i + 1, &px, &py)) {
            modified = true;
            switch (i) {
                case 0:
                    *w += *x - px;
                    *h += *y - py;
                    *x = px;
                    *y = py;
                    break;
                case 1:
                    *w = px - *x;
                    *h += *y - py;
                    *y = py;
                    break;
                case 2:
                    *w += *x - px;
                    *x = px;
                    *h = py - *y;
                    break;
                case 3:
                    *w = px - *x;
                    *h = py - *y;
                    break;
                default:
                    break;
            }
        }
    }

    if (*w < 0.0f) {
        *x += *w;
        *w = -*w;
    }
    if (*h < 0.0f) {
        *y += *h;
        *h = -*h;
    }

    if (*w < 1.0f) {
        *w = 1.0f;
    }
    if (*h < 1.0f) {
        *h = 1.0f;
    }

    return modified;
}

inline bool Circle(const char* id, float* cx, float* cy, float* radius) {
    if (cx == nullptr || cy == nullptr || radius == nullptr || !HasDrawList()) {
        return false;
    }

    Context& ctx = GetContext();
    bool modified = false;

    const ImVec2 center = WorldToScreen(*cx, *cy);
    const float screenR = (*radius > 1.0f ? *radius : 1.0f) * std::fabs(ctx.zoom);

    ctx.drawList->AddCircleFilled(center, screenR, ctx.colFill);
    ctx.drawList->AddCircle(center, screenR, ctx.colLine, 0, ctx.lineThickness);

    modified |= HandlePoint(id, 0, cx, cy);

    float edgeX = *cx + *radius;
    float edgeY = *cy;
    if (HandlePoint(id, 1, &edgeX, &edgeY)) {
        const float dx = edgeX - *cx;
        const float dy = edgeY - *cy;
        *radius = std::sqrt(dx * dx + dy * dy);
        if (*radius < 1.0f) {
            *radius = 1.0f;
        }
        modified = true;
    }

    return modified;
}

inline bool Rotate(const char* id, float* cx, float* cy, float* angle) {
    if (cx == nullptr || cy == nullptr || angle == nullptr || !HasDrawList()) {
        return false;
    }

    Context& ctx = GetContext();
    bool modified = false;

    const ImVec2 center = WorldToScreen(*cx, *cy);
    const float ringRadius = 50.0f;
    const float degToRad = 3.14159265358979323846f / 180.0f;
    const float radToDeg = 180.0f / 3.14159265358979323846f;

    ctx.drawList->AddCircle(center, ringRadius, ctx.colLine, 0, ctx.lineThickness);

    const float currentRadians = (*angle) * degToRad;
    const ImVec2 handle = ImVec2(center.x + std::cos(currentRadians) * ringRadius, center.y + std::sin(currentRadians) * ringRadius);

    ctx.drawList->AddLine(center, handle, ctx.colActive, ctx.lineThickness + 1.0f);

    const ImGuiID handleId = HashID(id, 1);
    const ImVec2 mouse = ImGui::GetMousePos();
    const float dx = mouse.x - handle.x;
    const float dy = mouse.y - handle.y;
    const float dist = std::sqrt(dx * dx + dy * dy);

    const bool hovered = (dist <= (ctx.handleRadius + 3.0f));
    const bool active = (ctx.activeId == handleId);

    if (hovered && ctx.activeId == 0) {
        ctx.hoveredId = handleId;
        ctx.hoveredName = id;
    }

    if (hovered && ImGui::IsMouseClicked(0) && ctx.activeId == 0) {
        ctx.activeId = handleId;
        ctx.activeName = id;
    }

    if (active && ImGui::IsMouseDown(0)) {
        float newAngle = std::atan2(mouse.y - center.y, mouse.x - center.x) * radToDeg;
        if (ctx.snapGrid > 0.0f) {
            newAngle = Snap(newAngle, ctx.snapGrid);
        }
        *angle = newAngle;
        modified = true;
    }

    ImU32 color = ctx.colIdle;
    if (active) {
        color = ctx.colActive;
    } else if (hovered) {
        color = ctx.colHover;
    }

    ctx.drawList->AddCircleFilled(handle, ctx.handleRadius, color);
    ctx.drawList->AddCircle(handle, ctx.handleRadius, IM_COL32(0, 0, 0, 180), 0, 1.5f);

    modified |= HandlePoint(id, 0, cx, cy);

    return modified;
}

inline bool Scale(const char* id, float* x, float* y, float* sx, float* sy) {
    if (x == nullptr || y == nullptr || sx == nullptr || sy == nullptr || !HasDrawList()) {
        return false;
    }

    Context& ctx = GetContext();
    bool modified = false;

    const ImVec2 origin = WorldToScreen(*x, *y);
    const float axisLen = 50.0f;

    const ImVec2 xEnd = ImVec2(origin.x + axisLen * (*sx), origin.y);
    const ImVec2 yEnd = ImVec2(origin.x, origin.y + axisLen * (*sy));

    ctx.drawList->AddLine(origin, xEnd, ctx.colAxisX, ctx.lineThickness);
    ctx.drawList->AddLine(origin, yEnd, ctx.colAxisY, ctx.lineThickness);

    const float boxSize = 5.0f;

    const ImGuiID xId = HashID(id, 1);
    const ImGuiID yId = HashID(id, 2);
    const ImVec2 mouse = ImGui::GetMousePos();

    const float xdx = mouse.x - xEnd.x;
    const float xdy = mouse.y - xEnd.y;
    const float xdist = std::sqrt(xdx * xdx + xdy * xdy);
    const bool xHovered = (xdist <= (ctx.handleRadius + 4.0f));
    const bool xActive = (ctx.activeId == xId);

    if (xHovered && ctx.activeId == 0) {
        ctx.hoveredId = xId;
        ctx.hoveredName = id;
    }
    if (xHovered && ImGui::IsMouseClicked(0) && ctx.activeId == 0) {
        ctx.activeId = xId;
        ctx.activeName = id;
    }
    if (xActive && ImGui::IsMouseDown(0)) {
        float newScaleX = (mouse.x - origin.x) / axisLen;
        if (ctx.snapGrid > 0.0f) {
            newScaleX = Snap(newScaleX, ctx.snapGrid);
        }
        *sx = (newScaleX < 0.1f) ? 0.1f : newScaleX;
        modified = true;
    }

    const float ydx = mouse.x - yEnd.x;
    const float ydy = mouse.y - yEnd.y;
    const float ydist = std::sqrt(ydx * ydx + ydy * ydy);
    const bool yHovered = (ydist <= (ctx.handleRadius + 4.0f));
    const bool yActive = (ctx.activeId == yId);

    if (yHovered && ctx.activeId == 0) {
        ctx.hoveredId = yId;
        ctx.hoveredName = id;
    }
    if (yHovered && ImGui::IsMouseClicked(0) && ctx.activeId == 0) {
        ctx.activeId = yId;
        ctx.activeName = id;
    }
    if (yActive && ImGui::IsMouseDown(0)) {
        float newScaleY = (mouse.y - origin.y) / axisLen;
        if (ctx.snapGrid > 0.0f) {
            newScaleY = Snap(newScaleY, ctx.snapGrid);
        }
        *sy = (newScaleY < 0.1f) ? 0.1f : newScaleY;
        modified = true;
    }

    ImU32 xColor = ctx.colAxisX;
    if (xActive) {
        xColor = ctx.colActive;
    } else if (xHovered) {
        xColor = ctx.colHover;
    }

    ImU32 yColor = ctx.colAxisY;
    if (yActive) {
        yColor = ctx.colActive;
    } else if (yHovered) {
        yColor = ctx.colHover;
    }

    ctx.drawList->AddRectFilled(ImVec2(xEnd.x - boxSize, xEnd.y - boxSize), ImVec2(xEnd.x + boxSize, xEnd.y + boxSize), xColor);
    ctx.drawList->AddRectFilled(ImVec2(yEnd.x - boxSize, yEnd.y - boxSize), ImVec2(yEnd.x + boxSize, yEnd.y + boxSize), yColor);

    modified |= HandlePoint(id, 0, x, y);

    return modified;
}

inline bool Point(const char* id, float* x, float* y) {
    return HandlePoint(id, 0, x, y);
}

inline bool Line(const char* id, float* x1, float* y1, float* x2, float* y2) {
    if (x1 == nullptr || y1 == nullptr || x2 == nullptr || y2 == nullptr || !HasDrawList()) {
        return false;
    }

    Context& ctx = GetContext();
    bool modified = false;

    const ImVec2 a = WorldToScreen(*x1, *y1);
    const ImVec2 b = WorldToScreen(*x2, *y2);
    ctx.drawList->AddLine(a, b, ctx.colLine, ctx.lineThickness);

    modified |= HandlePoint(id, 0, x1, y1);
    modified |= HandlePoint(id, 1, x2, y2);

    return modified;
}

inline bool Polygon(const char* id, float* points, int count) {
    if (points == nullptr || count < 2 || !HasDrawList()) {
        return false;
    }

    Context& ctx = GetContext();
    bool modified = false;

    for (int i = 0; i < count; ++i) {
        const int next = (i + 1) % count;
        const ImVec2 a = WorldToScreen(points[i * 2], points[i * 2 + 1]);
        const ImVec2 b = WorldToScreen(points[next * 2], points[next * 2 + 1]);
        ctx.drawList->AddLine(a, b, ctx.colLine, ctx.lineThickness);
    }

    for (int i = 0; i < count; ++i) {
        modified |= HandlePoint(id, i, &points[i * 2], &points[i * 2 + 1]);
    }

    return modified;
}

inline bool IsHovered() {
    return GetContext().hoveredId != 0;
}

inline bool IsActive() {
    return GetContext().activeId != 0;
}

inline const char* GetActiveId() {
    return GetContext().activeName;
}

inline const char* GetHoveredId() {
    return GetContext().hoveredName;
}

}  // namespace ImGizmo2D
