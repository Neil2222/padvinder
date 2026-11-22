-- Draws the recorded paths as a heatmap on the world map (colours: see Segments.lua).
-- Yellow = walked rarely, orange/red = walked often, blue = only ever fallen down,
-- purple = only walked during/just after combat (grinding, not travelling).
--
-- Performance: recorded connections are 8 yards long, so a zone holds thousands of them.
-- Drawing each as its own Line makes panning/zooming the map slow, so connections are first
-- joined into chains (through cells with exactly two connections of the same colour) and those
-- chains are simplified (Douglas-Peucker) before drawing. Straight roads become a few lines.

local ADDON, ns = ...
local HBD = LibStub("HereBeDragons-2.0")

local THICKNESS = 2.5     -- line width in screen pixels (corrected for zoom)
local MAX_LINES = 6000
local FRAME_LEVEL = 2010  -- just below Questie's icons (2015+)
local REDRAW_INTERVAL = 5 -- seconds: with the map open, redraw for new data at most this often
local SIMPLIFY = 1.0      -- max deviation in canvas units (~screen pixels) when simplifying chains
local ZOOM_DRIFT = 0.25   -- restyle mid-zoom only when line width drifts this far

local overlay
local lines, used = {}, 0
local shownMap, shownW, shownH, shownScale, shownRev, lastScale
local sinceDraw = 0

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

-- Douglas-Peucker on parallel x/y arrays; returns the kept indices in order.
local function Simplify(xs, ys, tol)
    local n = #xs
    if n <= 2 then return {1, n} end
    local keep = {[1] = true, [n] = true}
    local stack = {1, n}
    local tol2 = tol * tol
    while #stack > 0 do
        local last = stack[#stack]; stack[#stack] = nil
        local first = stack[#stack]; stack[#stack] = nil
        local x1, y1, x2, y2 = xs[first], ys[first], xs[last], ys[last]
        local dx, dy = x2 - x1, y2 - y1
        local len2 = dx * dx + dy * dy
        local worst, worstD = nil, tol2
        for i = first + 1, last - 1 do
            local px, py = xs[i] - x1, ys[i] - y1
            local d
            if len2 == 0 then
                d = px * px + py * py
            else
                local cross = px * dy - py * dx
                d = cross * cross / len2
            end
            if d > worstD then worst, worstD = i, d end
        end
        if worst then
            keep[worst] = true
            stack[#stack + 1] = first; stack[#stack + 1] = worst
            stack[#stack + 1] = worst; stack[#stack + 1] = last
        end
    end
    local out = {}
    for i = 1, n do if keep[i] then out[#out + 1] = i end end
    return out
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
    if PadvinderDB.showMap and w and data[1] ~= 0 and data[2] ~= 0 and width > 0 then
        local zw, zh, left, top = data[1], data[2], data[3], data[4]
        local mode = PadvinderDB.mapMode
        local seg = ns.Segments(data.instance)

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

        -- 1. Collect visible segments with their colour class.
        local ea, eb, ecls, eused = {}, {}, {}, {}
        local adj = {}   -- adj[cls][node] = {edge indices}
        local n = 0
        for i = 1, seg and seg.n or 0 do
            if ns.InMode(seg.fight[i], mode) then
                local a, b = seg.a[i], seg.b[i]
                local x1, y1 = Pos(a)
                local x2, y2 = Pos(b)
                if (x1 > minX and x1 < maxX and y1 > minY and y1 < maxY)
                    or (x2 > minX and x2 < maxX and y2 > minY and y2 < maxY) then
                    local cls = seg.cls[i]
                    n = n + 1
                    ea[n], eb[n], ecls[n] = a, b, cls
                    local byNode = adj[cls]
                    if not byNode then byNode = {}; adj[cls] = byNode end
                    local la = byNode[a]; if not la then la = {}; byNode[a] = la end
                    local lb = byNode[b]; if not lb then lb = {}; byNode[b] = lb end
                    la[#la + 1] = n
                    lb[#lb + 1] = n
                end
            end
        end

        -- Follow a chain from `node` through any not-yet-drawn connection of the same colour
        -- (also across junctions: a polyline may branch off later). Appends nodes to `chain`.
        local function Extend(chain, node, from, cls)
            local byNode = adj[cls]
            while true do
                local list = byNode[node]
                local nxt
                if list then
                    for k = 1, #list do
                        local e = list[k]
                        if not eused[e] then nxt = e; break end
                    end
                end
                if not nxt then return end
                eused[nxt] = true
                node = ea[nxt] == node and eb[nxt] or ea[nxt]
                chain[#chain + 1] = node
                from = nxt
            end
        end

        -- 2. Join into chains, simplify, draw.
        local thick = THICKNESS / scale
        for i = 1, n do
            if not eused[i] then
                eused[i] = true
                local cls = ecls[i]
                local fwd = {ea[i], eb[i]}
                Extend(fwd, eb[i], i, cls)
                local back = {}
                Extend(back, ea[i], i, cls)
                -- chain = reverse(back) .. fwd
                local xs, ys = {}, {}
                for j = #back, 1, -1 do
                    local x, y = Pos(back[j]); xs[#xs + 1] = x; ys[#ys + 1] = y
                end
                for j = 1, #fwd do
                    local x, y = Pos(fwd[j]); xs[#xs + 1] = x; ys[#ys + 1] = y
                end
                local idx = Simplify(xs, ys, SIMPLIFY)
                local r, g, b, a = ns.ClassColor(cls)
                for j = 1, #idx - 1 do
                    if used >= MAX_LINES then break end
                    local s, e = idx[j], idx[j + 1]
                    local line = Acquire()
                    line:SetStartPoint("TOPLEFT", overlay, xs[s], -ys[s])
                    line:SetEndPoint("TOPLEFT", overlay, xs[e], -ys[e])
                    line:SetThickness(thick)
                    line:SetColorTexture(r, g, b, a)
                end
            end
        end
    end

    for i = used + 1, #lines do
        lines[i]:Hide()
    end
    ns.lastLineCount = used
end

local function Restyle(scale)
    shownScale = scale
    local thick = THICKNESS / scale
    for i = 1, used do
        lines[i]:SetThickness(thick)
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
