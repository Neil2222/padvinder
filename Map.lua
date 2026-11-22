-- Draws the recorded paths as a heatmap on the world map (colours: see Segments.lua).
-- Yellow = walked rarely, orange/red = walked often, blue = only ever fallen down,
-- purple = only walked during/just after combat (grinding, not travelling).
--
-- Performance: recorded connections are 8 yards long, so a continent holds thousands of them.
--  * Connections are joined into chains and simplified (Douglas-Peucker) before drawing, so a
--    straight road becomes a few lines.
--  * Working that out takes tens of milliseconds on a big continent, so it runs in a coroutine,
--    a few milliseconds per frame. The lines already shown stay until the new ones are ready.
--  * Opening the map again without new data costs nothing: the lines are still there.
--  * New lines are put in place a portion per frame, and a line whose position, colour and width
--    didn't change isn't touched at all (after a short walk almost nothing changes).

local ADDON, ns = ...
local HBD = LibStub("HereBeDragons-2.0")

local THICKNESS = 2.5     -- line width in screen pixels (corrected for zoom)
local MAX_LINES = 6000
local FRAME_LEVEL = 2010  -- just below Questie's icons (2015+)
local REDRAW_INTERVAL = 5 -- seconds: with the map open, redraw for new data at most this often
local SIMPLIFY = 1.0      -- max deviation in canvas units (~screen pixels) when simplifying chains
local ZOOM_DRIFT = 0.25   -- restyle mid-zoom only when line width drifts this far
local APPLY_PER_FRAME = 600   -- lines put in place per frame
local ROUTE_THICKNESS = 4 -- the planned route (Route.lua), drawn on top of the paths
local DASH, GAP = 7, 5    -- screen pixels: unsure stretches of the route are dashed

local overlay
local lines, used = {}, 0
local routeLines, routeUsed = {}, 0
local shownRouteRev

-- What the lines on the map show (map, canvas size, data revision, mode, on/off)
local shownMap, shownW, shownH, shownRev, shownMode, shownShow
local shownScale, lastScale
local sinceDraw = 0
-- Work in progress: the coroutine working out new lines, then putting them in place
local job, jobMap, jobW, jobH, jobRev, jobMode, jobShow
local geo, applyAt

---------------------------------------------------------------------------------------------
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
        local scale = WorldMapFrame.ScrollContainer:GetCanvasScale()
        local thick = ROUTE_THICKNESS / scale
        local function Line(cls, x1, y1, x2, y2)
            routeUsed = routeUsed + 1
            local line = routeLines[routeUsed]
            if not line then
                line = overlay:CreateLine(nil, "OVERLAY", nil, 7)
                routeLines[routeUsed] = line
            end
            line:SetStartPoint("TOPLEFT", overlay, x1, -y1)
            line:SetEndPoint("TOPLEFT", overlay, x2, -y2)
            line:SetThickness(thick)
            line:SetColorTexture(ns.ClassColor(cls))
            line:Show()
        end
        for _, leg in ipairs(route.legs) do
            if leg.inst == data.instance then
                -- walking cyan (dashed where unsure), flights and boats gold
                local rx, ry, sure = leg.x, leg.y, leg.sure
                for i = 1, #rx - 1 do
                    local x1, y1 = (left - rx[i]) / zw * width, (top - ry[i]) / zh * height
                    local x2, y2 = (left - rx[i + 1]) / zw * width, (top - ry[i + 1]) / zh * height
                    if leg.kind ~= "walk" then
                        Line("routeAir", x1, y1, x2, y2)
                    elseif sure and sure[i] then
                        Line("route", x1, y1, x2, y2)
                    else
                        ns.Dashes(x1, y1, x2, y2, DASH / scale, GAP / scale, function(a, b, c, d)
                            Line("routeGuess", a, b, c, d)
                        end)
                    end
                end
            end
        end
    end
    for i = routeUsed + 1, #routeLines do routeLines[i]:Hide() end
end

---------------------------------------------------------------------------------------------
-- Working out the lines (in a coroutine)

-- Returns {n, x1 = {}, y1 = {}, x2 = {}, y2 = {}, cls = {}} in canvas units.
local function Compute(mapID, width, height, mode, show)
    local out = {n = 0, x1 = {}, y1 = {}, x2 = {}, y2 = {}, cls = {}}
    local data = mapID and HBD.mapData[mapID]
    local w = data and PadvinderDB.worlds[data.instance]
    if not (show and w and data[1] ~= 0 and data[2] ~= 0 and width > 0) then return out end
    local seg = ns.Segments(data.instance)
    if not seg then return out end
    local zw, zh, left, top = data[1], data[2], data[3], data[4]

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

    local n, X1, Y1, X2, Y2, C = 0, out.x1, out.y1, out.x2, out.y2, out.cls
    ns.Polylines(seg, Visible, Pos, SIMPLIFY, function(xs, ys, idx, cls)
        for j = 1, #idx - 1 do
            if n >= MAX_LINES then return false end
            local s, e = idx[j], idx[j + 1]
            n = n + 1
            X1[n], Y1[n], X2[n], Y2[n], C[n] = xs[s], ys[s], xs[e], ys[e], cls
        end
    end)
    out.n = n
    return out
end

local function StartJob(mapID, width, height)
    jobMap, jobW, jobH = mapID, width, height
    jobRev, jobMode, jobShow = ns.rev, PadvinderDB.mapMode, PadvinderDB.showMap
    local mode, show = jobMode, jobShow
    sinceDraw = 0
    geo, applyAt = nil, nil
    job = coroutine.create(function() return Compute(mapID, width, height, mode, show) end)
end

local function HideLines()
    for i = 1, used do
        local line = lines[i]
        if line.pShown then
            line:Hide()
            line.pShown = false
        end
    end
    used = 0
end

---------------------------------------------------------------------------------------------
-- Putting lines in place, a portion per frame, skipping lines that didn't change

local function Apply(scale)
    local thick = THICKNESS / scale
    local n = geo.n
    local last = math.min(n, applyAt + APPLY_PER_FRAME - 1)
    local X1, Y1, X2, Y2, C = geo.x1, geo.y1, geo.x2, geo.y2, geo.cls
    for i = applyAt, last do
        local line = lines[i]
        if not line then
            line = overlay:CreateLine(nil, "OVERLAY")
            lines[i] = line
        end
        local x1, y1, x2, y2 = X1[i], Y1[i], X2[i], Y2[i]
        if line.pX1 ~= x1 or line.pY1 ~= y1 or line.pX2 ~= x2 or line.pY2 ~= y2 then
            line:SetStartPoint("TOPLEFT", overlay, x1, -y1)
            line:SetEndPoint("TOPLEFT", overlay, x2, -y2)
            line.pX1, line.pY1, line.pX2, line.pY2 = x1, y1, x2, y2
        end
        if line.pT ~= thick then
            line:SetThickness(thick)
            line.pT = thick
        end
        local cls = C[i]
        if line.pCls ~= cls then
            line:SetColorTexture(ns.ClassColor(cls))
            line.pCls = cls
        end
        if not line.pShown then
            line:Show()
            line.pShown = true
        end
    end
    if last > used then used = last end
    applyAt = last + 1
    if applyAt > n then
        -- done: hide what's left of the old picture
        for i = n + 1, used do
            local line = lines[i]
            if line.pShown then
                line:Hide()
                line.pShown = false
            end
        end
        used = n
        ns.lastLineCount = n
        geo, applyAt = nil, nil
    end
end

local function Restyle(scale)
    shownScale = scale
    local thick = THICKNESS / scale
    for i = 1, used do
        local line = lines[i]
        if line.pT ~= thick then
            line:SetThickness(thick)
            line.pT = thick
        end
    end
    DrawRoute()   -- cheap; dash lengths depend on the zoom
end

---------------------------------------------------------------------------------------------

local function OnUpdate(_, elapsed)
    sinceDraw = sinceDraw + elapsed
    local canvas = WorldMapFrame:GetCanvas()
    local mapID = WorldMapFrame:GetMapID()
    local width, height = canvas:GetWidth(), canvas:GetHeight()
    local scale = WorldMapFrame.ScrollContainer:GetCanvasScale()
    local settled = scale == lastScale
    lastScale = scale

    local target = job and jobMap or shownMap
    local targetW, targetH = job and jobW or shownW, job and jobH or shownH
    if mapID ~= target or width ~= targetW or height ~= targetH then
        -- another map (or size): the old lines don't belong here
        HideLines()
        shownMap, shownW, shownH = nil, nil, nil
        StartJob(mapID, width, height)
        DrawRoute()
    elseif not job and not geo then
        local switched = PadvinderDB.mapMode ~= shownMode or PadvinderDB.showMap ~= shownShow
        if switched or (shownRev ~= ns.rev and sinceDraw >= REDRAW_INTERVAL and settled) then
            StartJob(mapID, width, height)
        end
    end

    if job then
        ns.SliceStart()
        local ok, result = coroutine.resume(job)
        if not ok then
            job = nil
            ns.Print("map drawing failed: " .. tostring(result))
        elseif coroutine.status(job) == "dead" then
            job = nil
            geo, applyAt = result, 1
            shownMap, shownW, shownH = jobMap, jobW, jobH
            shownRev, shownMode, shownShow = jobRev, jobMode, jobShow
            shownScale = scale
        end
    elseif geo then
        Apply(scale)
    elseif shownScale and scale ~= shownScale and (settled or math.abs(scale / shownScale - 1) > ZOOM_DRIFT) then
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
    -- OnUpdate only runs while the map is open; the lines stay in place while it is closed
    overlay:SetScript("OnUpdate", OnUpdate)
end
