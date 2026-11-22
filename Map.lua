-- Draws the recorded paths as a heatmap on the world map (colours: see Segments.lua).
-- Yellow = walked rarely, orange/red = walked often, blue = only ever fallen down,
-- purple = only walked during/just after combat (grinding, not travelling).
--
-- Performance: recorded connections are 8 yards long, so a zone holds thousands of them.
-- Drawing each as its own Line makes panning/zooming the map slow, so connections are first
-- joined into chains and those chains are simplified (Douglas-Peucker) before drawing.
-- Straight roads become a few lines.

local ADDON, ns = ...
local HBD = LibStub("HereBeDragons-2.0")

local THICKNESS = 2.5     -- line width in screen pixels (corrected for zoom)
local MAX_LINES = 6000
local FRAME_LEVEL = 2010  -- just below Questie's icons (2015+)
local REDRAW_INTERVAL = 5 -- seconds: with the map open, redraw for new data at most this often
local SIMPLIFY = 1.0      -- max deviation in canvas units (~screen pixels) when simplifying chains
local ZOOM_DRIFT = 0.25   -- restyle mid-zoom only when line width drifts this far
local ROUTE_THICKNESS = 4 -- the planned route (Route.lua), drawn on top of the paths

local overlay
local lines, used = {}, 0
local shownMap, shownW, shownH, shownScale, shownRev, lastScale
local sinceDraw = 0
local routeLines, routeUsed = {}, 0
local shownRouteRev

local function Acquire()
    used = used + 1
    local line = lines[used]
    if not line then
        line = overlay:CreateLine(nil, "OVERLAY")
        lines[used] = line
    end
    line:Show()
    return line
end

-- The planned route, on top of the paths. Cheap (a few dozen lines), so it is redrawn
-- right away whenever the route changes.
local function DrawRoute()
    routeUsed = 0
    shownRouteRev = ns.routeRev
    local route = ns.route
    local mapID = WorldMapFrame:GetMapID()
    local data = mapID and HBD.mapData[mapID]
    local canvas = WorldMapFrame:GetCanvas()
    local width, height = canvas:GetWidth(), canvas:GetHeight()
    if route and route.legs and data and data[1] ~= 0 and data[2] ~= 0 then
        local zw, zh, left, top = data[1], data[2], data[3], data[4]
        local thick = ROUTE_THICKNESS / WorldMapFrame.ScrollContainer:GetCanvasScale()
        for _, leg in ipairs(route.legs) do
            if leg.inst == data.instance then
                -- walking cyan, flights and boats gold
                local r, g, b, a = ns.ClassColor(leg.kind == "walk" and "route" or "routeAir")
                local rx, ry = leg.x, leg.y
                for i = 1, #rx - 1 do
                    routeUsed = routeUsed + 1
                    local line = routeLines[routeUsed]
                    if not line then
                        line = overlay:CreateLine(nil, "OVERLAY", nil, 7)
                        routeLines[routeUsed] = line
                    end
                    line:SetStartPoint("TOPLEFT", overlay, (left - rx[i]) / zw * width, -(top - ry[i]) / zh * height)
                    line:SetEndPoint("TOPLEFT", overlay, (left - rx[i + 1]) / zw * width, -(top - ry[i + 1]) / zh * height)
                    line:SetThickness(thick)
                    line:SetColorTexture(r, g, b, a)
                    line:Show()
                end
            end
        end
    end
    for i = routeUsed + 1, #routeLines do routeLines[i]:Hide() end
end

local function Redraw()
    used = 0
    local mapID = WorldMapFrame:GetMapID()
    local data = mapID and HBD.mapData[mapID]
    local canvas = WorldMapFrame:GetCanvas()
    local width, height = canvas:GetWidth(), canvas:GetHeight()
    local scale = WorldMapFrame.ScrollContainer:GetCanvasScale()
    shownMap, shownW, shownH, shownScale, shownRev = mapID, width, height, scale, ns.rev
    sinceDraw = 0

    local w = data and PadvinderDB.worlds[data.instance]
    local seg = w and ns.Segments(data.instance)
    if PadvinderDB.showMap and seg and data[1] ~= 0 and data[2] ~= 0 and width > 0 then
        local zw, zh, left, top = data[1], data[2], data[3], data[4]
        local mode = PadvinderDB.mapMode

        -- Canvas position per cell (only cells we touch).
        local px, py = {}, {}
        local function Pos(key)
            local x = px[key]
            if not x then
                local wx, wy = ns.CellPos(w, key)
                x = (left - wx) / zw * width
                px[key] = x
                py[key] = (top - wy) / zh * height
            end
            return x, py[key]
        end
        local minX, maxX = -0.02 * width, 1.02 * width
        local minY, maxY = -0.02 * height, 1.02 * height
        local function Visible(i)
            if not ns.InMode(seg.fight[i], mode) then return false end
            local x1, y1 = Pos(seg.a[i])
            local x2, y2 = Pos(seg.b[i])
            return (x1 > minX and x1 < maxX and y1 > minY and y1 < maxY)
                or (x2 > minX and x2 < maxX and y2 > minY and y2 < maxY)
        end

        local thick = THICKNESS / scale
        ns.Polylines(seg, Visible, Pos, SIMPLIFY, function(xs, ys, idx, cls)
            local r, g, b, a = ns.ClassColor(cls)
            for j = 1, #idx - 1 do
                if used >= MAX_LINES then return false end
                local s, e = idx[j], idx[j + 1]
                local line = Acquire()
                line:SetStartPoint("TOPLEFT", overlay, xs[s], -ys[s])
                line:SetEndPoint("TOPLEFT", overlay, xs[e], -ys[e])
                line:SetThickness(thick)
                line:SetColorTexture(r, g, b, a)
            end
        end)
    end

    for i = used + 1, #lines do
        lines[i]:Hide()
    end
    ns.lastLineCount = used
    DrawRoute()
end

local function Restyle(scale)
    shownScale = scale
    local thick = THICKNESS / scale
    for i = 1, used do
        lines[i]:SetThickness(thick)
    end
    local routeThick = ROUTE_THICKNESS / scale
    for i = 1, routeUsed do
        routeLines[i]:SetThickness(routeThick)
    end
end

local function OnUpdate(_, elapsed)
    sinceDraw = sinceDraw + elapsed
    local canvas = WorldMapFrame:GetCanvas()
    local mapID = WorldMapFrame:GetMapID()
    local width, height = canvas:GetWidth(), canvas:GetHeight()
    local scale = WorldMapFrame.ScrollContainer:GetCanvasScale()
    local settled = scale == lastScale
    lastScale = scale
    if mapID ~= shownMap or width ~= shownW or height ~= shownH then
        Redraw()
    elseif shownRev ~= ns.rev and sinceDraw >= REDRAW_INTERVAL and settled then
        Redraw()
    elseif scale ~= shownScale and (settled or math.abs(scale / shownScale - 1) > ZOOM_DRIFT) then
        -- Smooth zoom eases the scale over many frames: restyle once it settles, not every frame.
        Restyle(scale)
    end
    if shownRouteRev ~= ns.routeRev then DrawRoute() end
end

function ns.InitMap()
    if overlay or not WorldMapFrame then return end
    local canvas = WorldMapFrame:GetCanvas()
    overlay = CreateFrame("Frame", nil, canvas)
    overlay:SetAllPoints(canvas)
    overlay:SetFrameLevel(FRAME_LEVEL)
    -- OnUpdate only runs while the map is open
    overlay:SetScript("OnUpdate", OnUpdate)
    overlay:SetScript("OnShow", function() shownMap = nil end)
end
