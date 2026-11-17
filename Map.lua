-- Draws the recorded paths as a heatmap on the world map.
-- Yellow = walked rarely, orange/red = walked often, blue = only ever fallen down,
-- purple = only walked during/just after combat (grinding, not travelling).

local ADDON, ns = ...
local HBD = LibStub("HereBeDragons-2.0")

local THICKNESS = 2.5     -- line width in screen pixels (corrected for zoom)
local MAX_LINES = 15000
local FRAME_LEVEL = 2010  -- just below Questie's icons (2015+)
local REDRAW_INTERVAL = 2 -- seconds: with the map open, redraw for new data at most this often

local log, min = math.log, math.min

local overlay
local lines, used = {}, 0
local shownMap, shownW, shownH, shownScale, shownRev
local sinceDraw = 0

-- Cache split edge keys
local splitCache = {}
local function Split(ek)
    local s = splitCache[ek]
    if not s then
        local a, b = ek:match("^(.-)>(.+)$")
        s = {a, b}
        splitCache[ek] = s
    end
    return s[1], s[2]
end

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

-- Heat of a cell = how often the area around it (3x3 cells) was walked. Walking the same road
-- twice rarely hits exactly the same cells, but it does hit the same neighbourhood.
local heatCache, heatCells = {}, nil
local function Heat(key)
    local h = heatCache[key]
    if not h then
        local cx, cy = key:match("^(-?%d+):(-?%d+)$")
        cx, cy = tonumber(cx), tonumber(cy)
        local sum = 0
        for i = -1, 1 do
            for j = -1, 1 do
                sum = sum + (heatCells[(cx + i) .. ":" .. (cy + j)] or 0)
            end
        end
        h = sum / 3   -- one pass touches ~3 cells in the neighbourhood
        heatCache[key] = h
    end
    return h
end

local function HeatColor(heat)
    -- 1 pass = yellow, 2 = orange, ~6+ = red
    local t = min(1, log(math.max(1, heat)) / log(6))
    return 1, 1 - 0.9 * t, 0.2 - 0.2 * t, 0.6 + 0.35 * t
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

    if PadvinderDB.showMap and data and data[1] ~= 0 and data[2] ~= 0 and width > 0 then
        local zw, zh, left, top = data[1], data[2], data[3], data[4]
        local w = PadvinderDB.worlds[data.instance]
        if w then
            local edges, drops, fight = w.edges, w.drops, w.fight
            local thick = THICKNESS / scale
            local mode = PadvinderDB.mapMode
            -- heat from travel only: cell visits minus the ones made while fighting
            local cells, fightCells = w.cells, w.fightCells
            heatCache = {}
            heatCells = setmetatable({}, {__index = function(_, k)
                local c = cells[k]
                return c and (c - (fightCells[k] or 0)) or nil
            end})
            for ek, count in pairs(edges) do
                local a, b = Split(ek)
                local rk = b .. ">" .. a
                local reverse = edges[rk]
                local travel = count - (fight[ek] or 0) + (reverse and (reverse - (fight[rk] or 0)) or 0)
                local isFight = travel <= 0
                local wanted = mode == "all" or (mode == "travel" and not isFight) or (mode == "grind" and isFight)
                -- draw each connection once, even if it was walked both ways
                if wanted and (not reverse or a < b) then
                    local ax, ay = ns.CellPos(w, a)
                    local bx, by = ns.CellPos(w, b)
                    local x1, y1 = (left - ax) / zw, (top - ay) / zh
                    local x2, y2 = (left - bx) / zw, (top - by) / zh
                    if (x1 > -0.02 and x1 < 1.02 and y1 > -0.02 and y1 < 1.02)
                        or (x2 > -0.02 and x2 < 1.02 and y2 > -0.02 and y2 < 1.02) then
                        if used >= MAX_LINES then break end
                        local line = Acquire()
                        line:SetStartPoint("TOPLEFT", overlay, x1 * width, -y1 * height)
                        line:SetEndPoint("TOPLEFT", overlay, x2 * width, -y2 * height)
                        line:SetThickness(thick)
                        if drops[ek] and not reverse then
                            line:SetColorTexture(0.4, 0.7, 1, 0.8)
                        elseif isFight then
                            line:SetColorTexture(0.75, 0.4, 1, 0.55)
                        else
                            line:SetColorTexture(HeatColor((Heat(a) + Heat(b)) / 2))
                        end
                    end
                end
            end
        end
    end

    for i = used + 1, #lines do
        lines[i]:Hide()
    end
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
    if mapID ~= shownMap or width ~= shownW or height ~= shownH then
        Redraw()
    elseif shownRev ~= ns.rev and sinceDraw >= REDRAW_INTERVAL then
        Redraw()
    elseif scale ~= shownScale then
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
