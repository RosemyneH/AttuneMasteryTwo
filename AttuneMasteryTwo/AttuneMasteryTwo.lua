-- Attune Mastery Two — bag-native link scan, no chat link matching
local ADDON_NAME = "AttuneMasteryTwo"
local ADDON_VERSION = "1.0.0"

local PERK_NAME = "Prestige: Attune Mastery"
local PERK_OPTION = "Disable for BoE"

local INVENTORY_SLOT_BAG_0 = 0xFF
local INVENTORY_SLOT_ITEM_START = 23
local SERVER_BAG_MAP = {
    [0] = INVENTORY_SLOT_BAG_0,
    [1] = 0x13,
    [2] = 0x14,
    [3] = 0x15,
    [4] = 0x16,
}

local FORGE_NAMES = {
    [0] = "Unforged",
    [1] = "Titanforge",
    [2] = "Warforge",
    [3] = "Lightforge",
}

AttuneMasteryTwoDB = AttuneMasteryTwoDB or {}

local guidForgeCache = {}
local pendingBags = {}
local scanFrame = nil
local scanElapsed = 0
local scanDelay = 0.08
local SCAN_DELAY = 0.08
local SCAN_DELAY_LOOT = 0.2
local affixApiWarned = false
local apisMissingWarned = false
local minimapBtn = nil

local function Print(...)
    print("|cFF00FF00[AMT]|r", ...)
end

local function DebugPrint(...)
    if AttuneMasteryTwoDB.debug then
        print("|cFF88FF88[AMT]|r", ...)
    end
end

local function ToNativeBagSlot(uiBag, uiSlot)
    local nativeBag = SERVER_BAG_MAP[uiBag]
    if not nativeBag or not uiSlot then
        return nil, nil
    end
    if uiBag == 0 then
        return nativeBag, INVENTORY_SLOT_ITEM_START + uiSlot - 1
    end
    return nativeBag, uiSlot - 1
end

local function GetLinkAtUiBagSlot(uiBag, uiSlot)
    local nb, ns = ToNativeBagSlot(uiBag, uiSlot)
    if not nb or not ns then
        return nil, nil, nil
    end
    if type(Custom_GetItemLinkBySlot) ~= "function" then
        return nil, nb, ns
    end
    return Custom_GetItemLinkBySlot(nb, ns), nb, ns
end

local function GuidKeyFromNative(nativeBag, nativeSlot)
    if type(Custom_GetItemGuid) ~= "function" then
        return nil
    end
    local low, high = Custom_GetItemGuid(nativeBag, nativeSlot)
    if low == nil or high == nil then
        return nil
    end
    return tostring(low) .. ":" .. tostring(high)
end

local function GetItemIdFromLink(link)
    if not link or type(Custom_GetIdFromLink) ~= "function" then
        return nil
    end
    local id = Custom_GetIdFromLink(link)
    if type(id) == "number" then
        return id
    end
    return nil
end

local function HasAffix(itemId)
    if not itemId or type(GetItemAffixMask) ~= "function" then
        if not affixApiWarned then
            affixApiWarned = true
            Print("|cFFFFFF00WARNING:|r GetItemAffixMask missing — affix gate disabled.")
        end
        return false
    end
    local mask = GetItemAffixMask(itemId)
    DebugPrint("GetItemAffixMask", itemId, "->", mask)
    return mask and mask > 0
end

local function SetBoEDisabled(disable)
    if AttuneMasteryTwoDB.suspended then
        DebugPrint("Suspended — skip perk change")
        return false
    end
    if type(ChangePerkOption) ~= "function" then
        Print("Error: ChangePerkOption not available.")
        return false
    end
    AttuneMasteryTwoDB.boeDisabled = disable
    ChangePerkOption(PERK_NAME, PERK_OPTION, disable, true)
    if disable then
        Print("|cFFFF0000BoE Exp = Off|r")
    else
        Print("|cFF00FF00BoE Exp = On|r")
    end
    UpdateMinimapIcon()
    return true
end

local function TriggerAutoDisable(forgeName)
    if AttuneMasteryTwoDB.boeDisabled then
        DebugPrint("BoE already disabled")
        return
    end
    Print("|cFFFFFFa6" .. (forgeName or "FORGE") .. " DETECTED!|r |cFFFF0000BoE Exp = Off|r")
    SetBoEDisabled(true)
end

local function EvaluateSlot(uiBag, uiSlot)
    if not AttuneMasteryTwoDB.targetForge then
        InitDB()
    end
    if AttuneMasteryTwoDB.suspended then
        return
    end

    local link, nativeBag, nativeSlot = GetLinkAtUiBagSlot(uiBag, uiSlot)
    if not link then
        return
    end

    local targetForge = AttuneMasteryTwoDB.targetForge or 3
    local guidKey = GuidKeyFromNative(nativeBag, nativeSlot)

    if guidKey then
        local cached = guidForgeCache[guidKey]
        if cached ~= nil and cached ~= targetForge then
            --DebugPrint("GUID cache skip — forge", cached)
            return
        end
    end

    if type(GetItemLinkTitanforge) ~= "function" then
        return
    end

    local forge
    if guidKey and guidForgeCache[guidKey] == targetForge then
        forge = targetForge
        DebugPrint("GUID cache hit — target forge")
    else
        forge = GetItemLinkTitanforge(link)
        DebugPrint("forge", forge, "target", targetForge)
        if forge ~= targetForge then
            if guidKey and forge ~= nil then
                guidForgeCache[guidKey] = forge
            end
            return
        end
        if guidKey then
            guidForgeCache[guidKey] = forge
        end
    end

    if type(Custom_IsItemSoulbound) ~= "function" then
        return
    end
    if Custom_IsItemSoulbound(nativeBag, nativeSlot) == 1 then
        DebugPrint("soulbound — skip")
        return
    end

    local itemId = GetItemIdFromLink(link)
    if not itemId then
        DebugPrint("no item id — skip")
        return
    end

    if not HasAffix(itemId) then
        DebugPrint("no affix — skip")
        return
    end

    if type(GetItemAttuneForge) ~= "function" then
        return
    end
    local attunedForge = GetItemAttuneForge(itemId)
    DebugPrint("GetItemAttuneForge", itemId, "->", attunedForge)
    if attunedForge ~= targetForge then
        return
    end

    local forgeName = FORGE_NAMES[targetForge] or ("Forge " .. tostring(targetForge))
    TriggerAutoDisable(forgeName)
end

local function ScanBag(uiBag)
    local numSlots = GetContainerNumSlots(uiBag) or 0
    for slot = 1, numSlots do
        EvaluateSlot(uiBag, slot)
    end
end

local function FlushPendingBags()
    for bag = 0, 4 do
        if pendingBags[bag] then
            pendingBags[bag] = nil
            ScanBag(bag)
        end
    end
end

local function QueueBagScan(uiBag)
    if type(uiBag) ~= "number" or uiBag < 0 or uiBag > 4 then
        return
    end
    pendingBags[uiBag] = true
    if not scanFrame then
        return
    end
    scanDelay = SCAN_DELAY
    scanElapsed = 0
    scanFrame:SetScript("OnUpdate", scanFrame._onUpdate)
end

local function QueueAllBagsScan()
    for bag = 0, 4 do
        pendingBags[bag] = true
    end
    if scanFrame then
        scanDelay = SCAN_DELAY_LOOT
        scanElapsed = 0
        scanFrame:SetScript("OnUpdate", scanFrame._onUpdate)
    end
end

local function WarnMissingApisOnce()
    if apisMissingWarned then
        return
    end
    apisMissingWarned = true
    if type(Custom_GetItemLinkBySlot) ~= "function" then
        Print("|cFFFFFF00WARNING:|r Custom_GetItemLinkBySlot missing — addon cannot read items.")
    end
    if type(ChangePerkOption) ~= "function" then
        Print("|cFFFFFF00WARNING:|r ChangePerkOption missing — cannot toggle perk.")
    end
    if not (GetItemLinkTitanforge and GetItemAttuneForge and Custom_IsItemSoulbound) then
        Print("|cFFFFFF00WARNING:|r Missing forge/attune/soulbound APIs — auto logic limited.")
    end
end

local function InitDB()
    AttuneMasteryTwoDB = AttuneMasteryTwoDB or {}
    if AttuneMasteryTwoDB.targetForge == nil then
        AttuneMasteryTwoDB.targetForge = 3
    end
    if AttuneMasteryTwoDB.boeDisabled == nil then
        AttuneMasteryTwoDB.boeDisabled = false
    end
    if AttuneMasteryTwoDB.suspended == nil then
        AttuneMasteryTwoDB.suspended = false
    end
    if AttuneMasteryTwoDB.debug == nil then
        AttuneMasteryTwoDB.debug = false
    end
    if AttuneMasteryTwoDB.showMinimap == nil then
        AttuneMasteryTwoDB.showMinimap = true
    end
    if AttuneMasteryTwoDB.minimapAngle == nil then
        AttuneMasteryTwoDB.minimapAngle = 45
    end
end

function UpdateMinimapIcon()
    if not minimapBtn or not minimapBtn.icon then
        return
    end
    if AttuneMasteryTwoDB.suspended then
        minimapBtn.icon:SetVertexColor(0, 1, 1)
    elseif AttuneMasteryTwoDB.boeDisabled then
        minimapBtn.icon:SetVertexColor(1, 0, 0)
    else
        minimapBtn.icon:SetVertexColor(1, 1, 1)
    end
end

local function UpdateMinimapButtonPosition()
    if not minimapBtn then
        return
    end
    local angle = (AttuneMasteryTwoDB.minimapAngle or 45) * math.pi / 180
    local shape = GetMinimapShape and GetMinimapShape() or "ROUND"
    local x, y
    if shape == "SQUARE" then
        local half = (Minimap:GetWidth() / 2) + 5
        local cos, sin = math.cos(angle), math.sin(angle)
        local abscos, abssin = math.abs(cos), math.abs(sin)
        if abscos > abssin then
            x = cos > 0 and half or -half
            y = sin / cos * x
        else
            y = sin > 0 and half or -half
            x = cos / sin * y
        end
    else
        local radius = (Minimap:GetWidth() / 2) + 5
        x = math.cos(angle) * radius
        y = math.sin(angle) * radius
    end
    minimapBtn:ClearAllPoints()
    minimapBtn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function OnMinimapDragUpdate()
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    cx, cy = cx / scale, cy / scale
    local angle = math.deg(math.atan2(cy - my, cx - mx))
    if angle < 0 then
        angle = angle + 360
    end
    AttuneMasteryTwoDB.minimapAngle = angle
    UpdateMinimapButtonPosition()
end

local function CreateMinimapButton()
    if minimapBtn then
        return
    end
    local btn = CreateFrame("Button", "AMT_MinimapButton", Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:EnableMouse(true)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetSize(24, 24)
    bg:SetPoint("CENTER")

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\Icons\\inv_enchant_essenceeternallarge")
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER")
    btn.icon = icon

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")

    local hl = btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    hl:SetBlendMode("ADD")
    hl:SetAllPoints(btn)

    btn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", OnMinimapDragUpdate)
    end)
    btn:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    btn:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            if AttuneMasteryTwoDB.suspended then
                AttuneMasteryTwoDB.suspended = false
                Print("|cFF00FF00Resumed|r — monitoring bags.")
            else
                AttuneMasteryTwoDB.suspended = true
                Print("|cFF00FFFF Suspended|r — auto-disable paused.")
            end
            UpdateMinimapIcon()
            return
        end
        if AttuneMasteryTwoDB.suspended then
            Print("|cFF00FFFF Suspended — right-click to resume|r")
            return
        end
        if type(ChangePerkOption) ~= "function" then
            Print("Error: ChangePerkOption not available.")
            return
        end
        SetBoEDisabled(not AttuneMasteryTwoDB.boeDisabled)
    end)

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Attune Mastery Two", 1, 1, 1)
        GameTooltip:AddLine("<Left-click> toggle BoE Exp", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("<Right-click> pause / resume", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("<Drag> move button", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    minimapBtn = btn
    UpdateMinimapButtonPosition()
    UpdateMinimapIcon()
end

local function ApplyMinimapVisibility()
    if AttuneMasteryTwoDB.showMinimap then
        CreateMinimapButton()
        if minimapBtn then
            minimapBtn:Show()
            UpdateMinimapButtonPosition()
            UpdateMinimapIcon()
        end
    elseif minimapBtn then
        minimapBtn:Hide()
    end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("BAG_UPDATE")
eventFrame:RegisterEvent("LOOT_CLOSED")

scanFrame = CreateFrame("Frame")
scanFrame._onUpdate = function(_, elapsed)
    scanElapsed = scanElapsed + elapsed
    if scanElapsed < scanDelay then
        return
    end
    scanFrame:SetScript("OnUpdate", nil)
    scanElapsed = 0
    scanDelay = SCAN_DELAY
    FlushPendingBags()
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name ~= ADDON_NAME then
            return
        end
        InitDB()
        WarnMissingApisOnce()
        ApplyMinimapVisibility()
        Print("Loaded v" .. ADDON_VERSION .. ". Type /amt help")
        return
    end

    if event == "BAG_UPDATE" then
        local bagID = ...
        if type(bagID) == "number" and bagID >= 0 and bagID <= 4 then
            QueueBagScan(bagID)
        end
        return
    end

    if event == "LOOT_CLOSED" then
        QueueAllBagsScan()
    end
end)

local function ParseFirstToken(msg)
    if not msg or msg == "" then
        return "", ""
    end
    local cmd, rest = string.match(msg, "^(%S+)%s*(.*)$")
    if not cmd then
        return "", msg
    end
    return string.lower(cmd), rest
end

SLASH_ATTUNEMASTERYTWO1 = "/amt"
SLASH_ATTUNEMASTERYTWO2 = "/am2"
SlashCmdList["ATTUNEMASTERYTWO"] = function(msg)
    local cmd, rest = ParseFirstToken(string.lower(msg or ""))

    if cmd == "debug" then
        AttuneMasteryTwoDB.debug = not AttuneMasteryTwoDB.debug
        Print("Debug:", AttuneMasteryTwoDB.debug and "ON" or "OFF")
    elseif cmd == "enable" then
        SetBoEDisabled(false)
    elseif cmd == "disable" then
        SetBoEDisabled(true)
    elseif cmd == "pause" or cmd == "suspend" then
        AttuneMasteryTwoDB.suspended = true
        Print("|cFF00FFFF Suspended|r — auto-disable paused.")
        UpdateMinimapIcon()
    elseif cmd == "resume" then
        AttuneMasteryTwoDB.suspended = false
        Print("|cFF00FF00 Resumed|r — monitoring bags.")
        UpdateMinimapIcon()
    elseif cmd == "minimap" then
        AttuneMasteryTwoDB.showMinimap = not AttuneMasteryTwoDB.showMinimap
        ApplyMinimapVisibility()
        Print("Minimap button:", AttuneMasteryTwoDB.showMinimap and "shown" or "hidden")
    elseif cmd == "forge" then
        local n = tonumber(rest)
        if n == nil or n < 0 or n > 3 then
            Print("Usage: /amt forge <0-3>  (0=Unforged, 1=Titanforge, 2=Warforge, 3=Lightforge)")
            return
        end
        AttuneMasteryTwoDB.targetForge = n
        local name = FORGE_NAMES[n] or tostring(n)
        Print("Target forge:", n, "(" .. name .. ")")
    elseif cmd == "test" then
        Print("API check:")
        print("  Custom_GetItemLinkBySlot:", type(Custom_GetItemLinkBySlot) == "function" and "OK" or "MISSING")
        print("  Custom_GetIdFromLink:", type(Custom_GetIdFromLink) == "function" and "OK" or "MISSING")
        print("  Custom_IsItemSoulbound:", type(Custom_IsItemSoulbound) == "function" and "OK" or "MISSING")
        print("  Custom_GetItemGuid:", type(Custom_GetItemGuid) == "function" and "OK" or "MISSING")
        print("  GetItemLinkTitanforge:", type(GetItemLinkTitanforge) == "function" and "OK" or "MISSING")
        print("  GetItemAttuneForge:", type(GetItemAttuneForge) == "function" and "OK" or "MISSING")
        print("  GetItemAffixMask:", type(GetItemAffixMask) == "function" and "OK" or "MISSING")
        print("  ChangePerkOption:", type(ChangePerkOption) == "function" and "OK" or "MISSING")
        print("  targetForge:", AttuneMasteryTwoDB.targetForge or 3)
        print("  boeDisabled:", tostring(AttuneMasteryTwoDB.boeDisabled))
        print("  suspended:", tostring(AttuneMasteryTwoDB.suspended))
        print("  showMinimap:", tostring(AttuneMasteryTwoDB.showMinimap))
    elseif cmd == "help" or cmd == "" then
        Print("Commands:")
        print("  /amt forge <0-3>  — forge tier to watch (default 3 = Lightforge)")
        print("  /amt enable|disable — BoE perk on/off")
        print("  /amt pause|resume   — pause/resume auto-disable")
        print("  /amt minimap        — show/hide minimap button")
        print("  /amt debug          — toggle debug")
        print("  /amt test           — API availability")
        print("  /amt help")
        print("")
        print("Auto-disables BoE when a bag item is BoE, has an affix, matches target forge,")
        print("and GetItemAttuneForge matches that tier (duplicate attune drop).")
    else
        Print("Unknown command. Type /amt help")
    end
end
