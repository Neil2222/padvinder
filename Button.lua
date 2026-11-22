-- Minimap button (LibDBIcon), so it sits with the other addon buttons and can be dragged around.
--   Left-click:  recording on/off
--   Shift-click: minimap paths on/off
--   Right-click: cycle map view (all -> travel -> grind -> off)

local ADDON, ns = ...
local HBD = LibStub("HereBeDragons-2.0")
local LDB = LibStub("LibDataBroker-1.1")
local DBIcon = LibStub("LibDBIcon-1.0")

local ICON = "Interface\\Icons\\INV_Misc_Map_01"
local NEXT_VIEW = {all = "travel", travel = "grind", grind = "off", off = "all"}

local dataObject

function ns.UpdateButton()
    if not dataObject then return end
    -- Grey icon while not recording.
    local c = PadvinderDB.recording and 1 or 0.4
    dataObject.iconR, dataObject.iconG, dataObject.iconB = c, c, c
end

local function OnClick(_, button)
    if IsShiftKeyDown() then
        ns.SetMinimap(not PadvinderDB.showMinimap)
    elseif button == "RightButton" then
        local current = PadvinderDB.showMap and PadvinderDB.mapMode or "off"
        local nextView = NEXT_VIEW[current] or "all"
        if nextView == "off" then
            ns.SetMap(false)
        else
            ns.SetMap(true, nextView)
        end
    else
        ns.SetRecording(not PadvinderDB.recording)
    end
end

local function OnTooltipShow(tooltip)
    tooltip:AddLine("Padvinder")
    tooltip:AddDoubleLine("Recording",
        PadvinderDB.recording and "|cff00ff00on|r" or "|cffff4444off|r")
    tooltip:AddDoubleLine("Map", PadvinderDB.showMap and PadvinderDB.mapMode or "off", nil, nil, nil, 1, 1, 1)
    tooltip:AddDoubleLine("Minimap", PadvinderDB.showMinimap and "on" or "off", nil, nil, nil, 1, 1, 1)
    if ns.RouteInfo then
        tooltip:AddDoubleLine("Route", ns.RouteInfo(), nil, nil, nil, 1, 1, 1)
    end
    local _, _, inst = ns.PlayerPos()
    if inst and PadvinderDB.worlds[inst] then
        local _, _, travel, grinding = ns.Stats(inst)
        tooltip:AddDoubleLine("Travel paths", ("%.1f km"):format(travel), nil, nil, nil, 1, 1, 1)
        tooltip:AddDoubleLine("Grinding paths", ("%.1f km"):format(grinding), nil, nil, nil, 1, 1, 1)
    end
    tooltip:AddLine(" ")
    tooltip:AddLine("|cffffff00Left-click|r to toggle recording", 0.8, 0.8, 0.8)
    tooltip:AddLine("|cffffff00Right-click|r to change the map view", 0.8, 0.8, 0.8)
    tooltip:AddLine("|cffffff00Shift-click|r to toggle paths on the minimap", 0.8, 0.8, 0.8)
end

function ns.ToggleButton()
    PadvinderDB.minimap.hide = not PadvinderDB.minimap.hide
    if PadvinderDB.minimap.hide then
        DBIcon:Hide(ADDON)
        ns.Print("minimap button hidden. Type /pad button to bring it back.")
    else
        DBIcon:Show(ADDON)
        ns.Print("minimap button shown.")
    end
end

function ns.InitButton()
    if dataObject then return end
    dataObject = LDB:NewDataObject(ADDON, {
        type = "launcher",
        text = "Padvinder",
        icon = ICON,
        OnClick = OnClick,
        OnTooltipShow = OnTooltipShow,
    })
    ns.UpdateButton()
    DBIcon:Register(ADDON, dataObject, PadvinderDB.minimap)
end
