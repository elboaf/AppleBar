-- AppleBar - Compact raid marker bar for TurtleWoW
-- Requires SuperWoW. Optional: AutoMarker, UnitXP_SP3.

if not SetAutoloot then
  StaticPopupDialogs["NO_SUPERWOW_APPLEBAR"] = {
    text = "|cffFFFF00AppleBar|r|cffFF0000 requires SuperWoW to operate.|r",
    button1 = TEXT(OKAY),
    timeout = 0, whileDead = 1, hideOnEscape = 1, showAlert = 1,
  }
  StaticPopup_Show("NO_SUPERWOW_APPLEBAR")
  return
end

local AB_VERSION = "1.1.0"

local MARK_NAMES = { "Star", "Circle", "Diamond", "Triangle", "Moon", "Square", "Cross", "Skull" }

local ICON_TEXTURE = "Interface\\TargetingFrame\\UI-RaidTargetingIcons"
local MARK_COORDS = {
  [1] = {0,    0.25, 0,    0.25},
  [2] = {0.25, 0.5,  0,    0.25},
  [3] = {0.5,  0.75, 0,    0.25},
  [4] = {0.75, 1,    0,    0.25},
  [5] = {0,    0.25, 0.25, 0.5 },
  [6] = {0.25, 0.5,  0.25, 0.5 },
  [7] = {0.5,  0.75, 0.25, 0.5 },
  [8] = {0.75, 1,    0.25, 0.5 },
}

local AUTOMARK_ICON = "Interface\\Icons\\Inv_misc_food_19"
local CLEAR_ICON    = "Interface\\Icons\\Inv_scroll_09"
local BUTTON_SIZE    = 28
local BAR_PADDING    = 4
local NUM_MARKS      = 8
local PACK_RANGE     = 20  -- social aggro baseline for proximity pack inference

-- upvalues
local UnitExists            = UnitExists
local UnitName              = UnitName
local UnitIsDead            = UnitIsDead
local UnitIsEnemy           = UnitIsEnemy
local GetRaidTargetIndex    = GetRaidTargetIndex
local SetRaidTarget         = SetRaidTarget
local CheckInteractDistance = CheckInteractDistance
local IsRaidOfficer         = IsRaidOfficer
local IsPartyLeader         = IsPartyLeader
local GetNumPartyMembers    = GetNumPartyMembers
local GetNumRaidMembers     = GetNumRaidMembers
local GetRealZoneText       = GetRealZoneText
local pairs                 = pairs
local next                  = next

local AB_DEFAULTS = {
  point             = "CENTER",
  x                 = 0,
  y                 = -200,
  locked            = false,
  autoMode          = false,
  scale             = 1.0,
  flipped           = false,
  guidMarkOverrides = {},
  customPacks       = {},
  observations      = {},
}

-- ============================================================
-- NPC ID extraction
-- Vanilla GUID format: 0xF130NNNNNNXXXXXX
-- Characters 5-8 (1-indexed) encode the NPC entry ID in hex.
-- ============================================================

local function NpcIdFromGuid(guid)
  if not guid then return nil end
  -- guid looks like "0xF130003E69269C39"
  -- NPC entry is at nibbles 9-16 counting from "0x" = chars 3-18
  -- More specifically: upper 32 bits after the type nibbles
  -- Extract chars 5-12 (skipping "0xF1") -> 8 hex chars = entry id region
  local s = string.sub(guid, 5, 12)
  if s and string.len(s) == 8 then
    return s  -- store as hex string, stable across spawns
  end
  return nil
end

local function MobKey(guid)
  -- Returns (npcid, name) for a guid, used as observation/pack keys
  local npcid = NpcIdFromGuid(guid)
  local name  = UnitName(guid) or "unknown"
  return npcid, name
end

-- ============================================================
-- Utility
-- ============================================================

local function InGroup()
  return (GetNumPartyMembers() + GetNumRaidMembers()) > 0
end

local function PlayerCanRaidMark()
  return InGroup() and (IsRaidOfficer() or IsPartyLeader())
end

local function PlayerCanMark()
  return PlayerCanRaidMark() or not InGroup()
end

local function SafeSetRaidTarget(unit, mark)
  if PlayerCanRaidMark() then
    SetRaidTarget(unit, mark)
  else
    SetRaidTarget(unit, mark, 1)
  end
end

local function GuidForMark(i)
  local exists, guid = UnitExists("mark" .. i)
  if exists then return guid end
  return nil
end

local function NameForMark(i)
  if UnitExists("mark" .. i) then return UnitName("mark" .. i) end
  return nil
end

local function UnitDistance(guid1, guid2)
  if UnitXP then
    return UnitXP("distanceBetween", guid1, guid2)
  end
  return nil
end

local function MarkIsReachable(i)
  local token = "mark" .. i
  local exists, guid = UnitExists(token)
  if not exists then return false end
  if UnitIsDead(token) then return false end
  if UnitXP then
    local dist = UnitXP("distanceBetween", "player", guid)
    if dist then return dist <= 100 end
  end
  return CheckInteractDistance(token, 4) or false
end

local function PickFreeMarkIndex()
  for i = 1, 8 do
    if not GuidForMark(i) then return i end
  end
  return nil
end

-- ============================================================
-- Observations  (mark learning from anyone's marks)
-- observations[zone][npcid] = { [markIndex]=count, total=n }
-- ============================================================

local function RecordObservation(zone, guid, markIndex)
  if not zone or not guid or not markIndex or markIndex == 0 then return end
  local npcid = NpcIdFromGuid(guid)
  if not npcid then return end

  if not AppleBarDB.observations[zone] then
    AppleBarDB.observations[zone] = {}
  end
  if not AppleBarDB.observations[zone][npcid] then
    AppleBarDB.observations[zone][npcid] = { total = 0 }
  end
  local obs = AppleBarDB.observations[zone][npcid]
  obs[markIndex] = (obs[markIndex] or 0) + 1
  obs.total      = obs.total + 1
end

-- Returns the most-observed mark for a given npcid in this zone, or nil
local function LearnedMarkForNpcId(zone, npcid)
  if not npcid then return nil end
  local obs = AppleBarDB.observations[zone] and AppleBarDB.observations[zone][npcid]
  if not obs or obs.total == 0 then return nil end

  local bestMark, bestCount = nil, 0
  for markIndex = 1, 8 do
    local c = obs[markIndex] or 0
    if c > bestCount then
      bestCount = c
      bestMark  = markIndex
    end
  end
  -- Only return if observed at least twice (avoid single-observation noise)
  if bestCount >= 2 then return bestMark end
  return nil
end

-- ============================================================
-- Custom pack storage helpers
-- Pack entry: { mark=i, name="Mob", npcid="XXXXXXXX" }
-- ============================================================

local function SaveGuidOverride(guid, mark)
  if not guid or not mark then return end
  local npcid = NpcIdFromGuid(guid)
  local name  = UnitName(guid) or "unknown"
  AppleBarDB.guidMarkOverrides[guid] = { mark = mark, name = name, npcid = npcid }
end

local function GetOverrideMark(guid)
  local entry = AppleBarDB.guidMarkOverrides[guid]
  if entry then
    -- entry may be old format (plain number) or new format (table)
    if type(entry) == "number" then return entry end
    return entry.mark
  end
  return nil
end

-- Build a pack entry table for a guid+mark
local function MakePackEntry(guid, mark)
  local npcid = NpcIdFromGuid(guid)
  local name  = UnitName(guid) or "unknown"
  return { mark = mark, name = name, npcid = npcid }
end

-- ============================================================
-- Proximity: find all guids near a given guid within range yards
-- Uses the mark tokens we know about + any guid we're passed
-- ============================================================

local function GetNearbyMarkedGuids(guid, range)
  local nearby = {}
  for i = 1, NUM_MARKS do
    local _, mguid = UnitExists("mark" .. i)
    if mguid and mguid ~= guid then
      local dist = UnitDistance(guid, mguid)
      if dist and dist <= range then
        nearby[mguid] = GetRaidTargetIndex("mark" .. i) or 0
      end
    end
  end
  return nearby
end

-- ============================================================
-- Pack lookup
-- Priority: guidMarkOverrides -> customPacks (guid match) ->
--           customPacks (npcid match) -> AutoMarker tables ->
--           learned observations
-- ============================================================

local function FindPackForGuid(guid)
  if not guid then return nil end
  local zone  = GetRealZoneText()
  local npcid = NpcIdFromGuid(guid)

  -- 1. Our custom packs: exact guid match
  if AppleBarDB.customPacks[zone] then
    for _, pack in pairs(AppleBarDB.customPacks[zone]) do
      if pack[guid] then return pack end
    end
  end

  -- 2. Our custom packs: npcid match (handles respawns with new guids)
  if npcid and AppleBarDB.customPacks[zone] then
    for _, pack in pairs(AppleBarDB.customPacks[zone]) do
      for _, entry in pairs(pack) do
        if type(entry) == "table" and entry.npcid == npcid then
          return pack
        end
      end
    end
  end

  -- 3. AutoMarker runtime table (exact guid)
  if currentNpcsToMark and currentNpcsToMark[zone] then
    for _, p in pairs(currentNpcsToMark[zone]) do
      if p[guid] ~= nil then return p end
    end
  end

  -- 4. AutoMarker defaults (exact guid)
  if defaultNpcsToMark and defaultNpcsToMark[zone] then
    for _, p in pairs(defaultNpcsToMark[zone]) do
      if p[guid] ~= nil then return p end
    end
  end

  return nil
end

-- Get the intended mark for a single guid (no pack context)
local function GetIntendedMark(guid)
  if not guid then return nil end
  local zone  = GetRealZoneText()
  local npcid = NpcIdFromGuid(guid)

  -- 1. Explicit override (exact guid)
  local ov = GetOverrideMark(guid)
  if ov then return ov end

  -- 2. Npcid override: check all overrides for matching npcid
  if npcid then
    for _, entry in pairs(AppleBarDB.guidMarkOverrides) do
      if type(entry) == "table" and entry.npcid == npcid then
        return entry.mark
      end
    end
  end

  -- 3. AutoMarker tables (exact guid)
  if currentNpcsToMark and currentNpcsToMark[zone] then
    for _, pack in pairs(currentNpcsToMark[zone]) do
      if pack[guid] ~= nil then return pack[guid] end
    end
  end
  if defaultNpcsToMark and defaultNpcsToMark[zone] then
    for _, pack in pairs(defaultNpcsToMark[zone]) do
      if pack[guid] ~= nil then return pack[guid] end
    end
  end

  -- 4. Learned consensus
  if npcid then
    local learned = LearnedMarkForNpcId(zone, npcid)
    if learned then return learned end
  end

  return nil
end

local function MarkPack(pack)
  for pguid, entry in pairs(pack) do
    if UnitExists(pguid) then
      local mark
      if type(entry) == "table" then
        mark = GetOverrideMark(pguid) or entry.mark
      else
        mark = GetOverrideMark(pguid) or entry
      end
      if mark and mark > 0 then SafeSetRaidTarget(pguid, mark) end
    end
  end
end

-- ============================================================
-- Observation scanner: called on RAID_TARGET_UPDATE
-- Only records marks that were intentionally placed, not random
-- free-slot assignments from auto-mode on unknown mobs.
-- ============================================================

local lastObservedMarks = {}  -- [i] = guid
local junkGuids = {}          -- guids marked via random free-slot, skip from learning

local function ScanAndRecordObservations()
  local zone = GetRealZoneText()
  for i = 1, NUM_MARKS do
    local exists, guid = UnitExists("mark" .. i)
    if exists and guid then
      if lastObservedMarks[i] ~= guid then
        lastObservedMarks[i] = guid

        -- Skip learning if this was a random free-slot auto assignment
        if not junkGuids[guid] then
          RecordObservation(zone, guid, i)

          -- Proximity: record nearby marked mobs in the same pack
          local nearby = GetNearbyMarkedGuids(guid, PACK_RANGE)
          for nguid, nmark in pairs(nearby) do
            if nmark > 0 and not junkGuids[nguid] then
              RecordObservation(zone, nguid, nmark)
            end
          end
        end
      end
    else
      lastObservedMarks[i] = nil
    end
  end
end

-- ============================================================
-- Bar frame
-- ============================================================

local BAR_W = (NUM_MARKS + 2) * (BUTTON_SIZE + BAR_PADDING) + BAR_PADDING
local BAR_H = BUTTON_SIZE

local AppleBar = CreateFrame("Frame", "AppleBarFrame", UIParent)
AppleBar:SetWidth(BAR_W)
AppleBar:SetHeight(BAR_H)
AppleBar:SetClampedToScreen(true)
AppleBar:SetMovable(true)
AppleBar:SetBackdrop({
  bgFile = "", edgeFile = "", tile = false,
  tileSize = 0, edgeSize = 0,
  insets = { left = 0, right = 0, top = 0, bottom = 0 },
})

-- ============================================================
-- Shared slot scripts (vanilla 1.12: `this` not `self`)
-- ============================================================

local function Slot_OnEnter()
  local i = this.markIndex
  GameTooltip:SetOwner(this, "ANCHOR_TOP")
  local name = NameForMark(i)
  if name then
    GameTooltip:SetText(MARK_NAMES[i] .. ": " .. name, 1, 1, 1)
    GameTooltip:AddLine("Left-click: target this mob", 0.7, 0.7, 0.7)
    if UnitExists("target") then
      GameTooltip:AddLine("Right-click: assign to target", 0.7, 0.7, 0.7)
    else
      GameTooltip:AddLine("Right-click: clear this mark", 0.7, 0.7, 0.7)
    end
  else
    GameTooltip:SetText(MARK_NAMES[i], 1, 1, 1)
    GameTooltip:AddLine("Slot empty", 0.5, 0.5, 0.5)
    GameTooltip:AddLine("Right-click: assign to target", 0.7, 0.7, 0.7)
  end
  GameTooltip:Show()
  this.hover:Show()
end

local function Slot_OnLeave()
  GameTooltip:Hide()
  this.hover:Hide()
end

local function Slot_OnMouseDown()
  this.icon:SetPoint("TOPLEFT",     this, "TOPLEFT",     1, -1)
  this.icon:SetPoint("BOTTOMRIGHT", this, "BOTTOMRIGHT", 1, -1)
end

local function Slot_OnMouseUp()
  this.icon:SetAllPoints(this)
  local i  = this.markIndex
  local mb = arg1

  if mb == "LeftButton" then
    if UnitExists("mark" .. i) then
      TargetUnit("mark" .. i)
    end

  elseif mb == "RightButton" then
    if PlayerCanMark() and UnitExists("target") and not UnitIsDead("target") then
      local _, guid = UnitExists("target")
      SafeSetRaidTarget("target", i)
      if guid then
        junkGuids[guid] = nil  -- manual assignment, always trustworthy
        local intended = GetIntendedMark(guid)
        if intended == nil or intended ~= i then
          SaveGuidOverride(guid, i)
        end
      end
    else
      local token = "mark" .. i
      if UnitExists(token) then
        SafeSetRaidTarget(token, 0)
      end
    end
  end
end

local function Slot_OnDragStart()
  if not AppleBarDB or AppleBarDB.locked then return end
  AppleBar:StartMoving()
end

local function Slot_OnDragStop()
  AppleBar:StopMovingOrSizing()
  local point, _, _, x, y = AppleBar:GetPoint()
  AppleBarDB.point = point
  AppleBarDB.x     = x
  AppleBarDB.y     = y
end

-- ============================================================
-- Mark slots 1-8 (skull first, star last)
-- ============================================================

local slots = {}

local function CreateSlot(markIndex, position)
  local slot = CreateFrame("Frame", "AppleBarSlot" .. markIndex, AppleBar)
  slot:SetWidth(BUTTON_SIZE)
  slot:SetHeight(BUTTON_SIZE)
  slot:EnableMouse(true)
  slot:RegisterForDrag("LeftButton")
  slot.markIndex = markIndex

  local xOff = BAR_PADDING + (position - 1) * (BUTTON_SIZE + BAR_PADDING)
  slot:SetPoint("LEFT", AppleBar, "LEFT", xOff, 0)

  local icon = slot:CreateTexture(nil, "ARTWORK")
  icon:SetAllPoints(slot)
  icon:SetTexture(ICON_TEXTURE)
  local c = MARK_COORDS[markIndex]
  icon:SetTexCoord(c[1], c[2], c[3], c[4])
  slot.icon = icon

  local hover = slot:CreateTexture(nil, "OVERLAY")
  hover:SetAllPoints(slot)
  hover:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
  hover:SetBlendMode("ADD")
  hover:Hide()
  slot.hover = hover

  local overlay = slot:CreateTexture(nil, "OVERLAY")
  overlay:SetAllPoints(slot)
  overlay:SetTexture(0, 0, 0, 0.55)
  overlay:Hide()
  slot.overlay = overlay

  slot:SetScript("OnEnter",     Slot_OnEnter)
  slot:SetScript("OnLeave",     Slot_OnLeave)
  slot:SetScript("OnMouseDown", Slot_OnMouseDown)
  slot:SetScript("OnMouseUp",   Slot_OnMouseUp)
  slot:SetScript("OnDragStart", Slot_OnDragStart)
  slot:SetScript("OnDragStop",  Slot_OnDragStop)

  slots[markIndex] = slot
end

for i = 1, NUM_MARKS do
  CreateSlot(NUM_MARKS + 1 - i, i)
end

-- ============================================================
-- AutoMark slot
-- ============================================================

local autoSlot = CreateFrame("Frame", "AppleBarAutoSlot", AppleBar)
autoSlot:SetWidth(BUTTON_SIZE)
autoSlot:SetHeight(BUTTON_SIZE)
autoSlot:EnableMouse(true)
autoSlot:RegisterForDrag("LeftButton")
autoSlot:SetPoint("LEFT", AppleBar, "LEFT", BAR_PADDING + NUM_MARKS * (BUTTON_SIZE + BAR_PADDING), 0)

local autoIcon = autoSlot:CreateTexture(nil, "ARTWORK")
autoIcon:SetAllPoints(autoSlot)
autoIcon:SetTexture(AUTOMARK_ICON)

local autoModeGlow = autoSlot:CreateTexture(nil, "OVERLAY")
autoModeGlow:SetAllPoints(autoSlot)
autoModeGlow:SetTexture("Interface\\Buttons\\CheckButtonHilight")
autoModeGlow:SetBlendMode("ADD")
autoModeGlow:Hide()

local autoHover = autoSlot:CreateTexture(nil, "OVERLAY")
autoHover:SetAllPoints(autoSlot)
autoHover:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
autoHover:SetBlendMode("ADD")
autoHover:Hide()

function AppleBar_UpdateAutoSlot()
  if AppleBarDB and AppleBarDB.autoMode then
    autoModeGlow:Show()
  else
    autoModeGlow:Hide()
  end
end

autoSlot:SetScript("OnEnter", function()
  autoHover:Show()
  GameTooltip:SetOwner(autoSlot, "ANCHOR_TOP")
  GameTooltip:SetText("AutoMark", 1, 0.8, 0)
  GameTooltip:AddLine("Left-click: mark target/group (like /am mark)", 0.7, 0.7, 0.7)
  GameTooltip:AddLine("Right-click: toggle auto-mark mode", 0.7, 0.7, 0.7)
  if AppleBarDB and AppleBarDB.autoMode then
    GameTooltip:AddLine("Auto mode: |cff00FF00ON|r", 0.7, 0.7, 0.7)
  else
    GameTooltip:AddLine("Auto mode: |cffFF4444OFF|r", 0.7, 0.7, 0.7)
  end
  GameTooltip:Show()
end)
autoSlot:SetScript("OnLeave", function()
  autoHover:Hide()
  GameTooltip:Hide()
end)
autoSlot:SetScript("OnMouseDown", function()
  autoIcon:SetPoint("TOPLEFT",     autoSlot, "TOPLEFT",     1, -1)
  autoIcon:SetPoint("BOTTOMRIGHT", autoSlot, "BOTTOMRIGHT", 1, -1)
end)
autoSlot:SetScript("OnMouseUp", function()
  autoIcon:SetAllPoints(autoSlot)
  if arg1 == "LeftButton" then
    AppleBar_MarkGroup()
  elseif arg1 == "RightButton" then
    AppleBarDB.autoMode = not AppleBarDB.autoMode
    AppleBar_UpdateAutoSlot()
    DEFAULT_CHAT_FRAME:AddMessage("|cffFFCC00AppleBar|r Auto-mark: " ..
      (AppleBarDB.autoMode and "|cff00FF00ON|r" or "|cffFF4444OFF|r"))
  end
end)
autoSlot:SetScript("OnDragStart", Slot_OnDragStart)
autoSlot:SetScript("OnDragStop",  Slot_OnDragStop)

-- ============================================================
-- Clear/Set marks button
-- ============================================================

local clearSlot = CreateFrame("Frame", "AppleBarClearSlot", AppleBar)
clearSlot:SetWidth(BUTTON_SIZE)
clearSlot:SetHeight(BUTTON_SIZE)
clearSlot:EnableMouse(true)
clearSlot:RegisterForDrag("LeftButton")
clearSlot:SetPoint("LEFT", AppleBar, "LEFT", BAR_PADDING + (NUM_MARKS + 1) * (BUTTON_SIZE + BAR_PADDING), 0)

local clearIcon = clearSlot:CreateTexture(nil, "ARTWORK")
clearIcon:SetAllPoints(clearSlot)
clearIcon:SetTexture(CLEAR_ICON)

local clearHover = clearSlot:CreateTexture(nil, "OVERLAY")
clearHover:SetAllPoints(clearSlot)
clearHover:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
clearHover:SetBlendMode("ADD")
clearHover:Hide()

clearSlot:SetScript("OnEnter", function()
  clearHover:Show()
  GameTooltip:SetOwner(clearSlot, "ANCHOR_TOP")
  GameTooltip:SetText("Marks", 1, 0.8, 0)
  GameTooltip:AddLine("Left-click: clear all marks", 0.7, 0.7, 0.7)
  GameTooltip:AddLine("Right-click: save marks as a pack", 0.7, 0.7, 0.7)
  GameTooltip:Show()
end)
clearSlot:SetScript("OnLeave", function()
  clearHover:Hide()
  GameTooltip:Hide()
end)
clearSlot:SetScript("OnMouseDown", function()
  clearIcon:SetPoint("TOPLEFT",     clearSlot, "TOPLEFT",     1, -1)
  clearIcon:SetPoint("BOTTOMRIGHT", clearSlot, "BOTTOMRIGHT", 1, -1)
end)
clearSlot:SetScript("OnMouseUp", function()
  clearIcon:SetAllPoints(clearSlot)
  if arg1 == "LeftButton" then
    if not PlayerCanMark() then
      DEFAULT_CHAT_FRAME:AddMessage("|cffFFCC00AppleBar|r: Need leader/assist to clear marks.")
      return
    end
    for i = 1, NUM_MARKS do
      if UnitExists("mark" .. i) then SafeSetRaidTarget("mark" .. i, 0) end
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cffFFCC00AppleBar|r: All marks cleared.")

  elseif arg1 == "RightButton" then
    if not PlayerCanMark() then
      DEFAULT_CHAT_FRAME:AddMessage("|cffFFCC00AppleBar|r: Need leader/assist to set marks.")
      return
    end
    local zone = GetRealZoneText()
    local pack = {}
    local saved = 0

    -- Collect all currently marked mobs
    for i = 1, NUM_MARKS do
      local exists, guid = UnitExists("mark" .. i)
      if exists and guid then
        pack[guid] = MakePackEntry(guid, i)
        SaveGuidOverride(guid, i)
        saved = saved + 1
      end
    end

    -- Proximity sweep: include nearby unmarked mobs within PACK_RANGE
    -- as observations so the system learns them belong together
    if saved > 0 then
      local zone = GetRealZoneText()
      for pguid, _ in pairs(pack) do
        local nearby = GetNearbyMarkedGuids(pguid, PACK_RANGE)
        for nguid, nmark in pairs(nearby) do
          if not pack[nguid] and nmark > 0 then
            pack[nguid] = MakePackEntry(nguid, nmark)
            RecordObservation(zone, nguid, nmark)
            saved = saved + 1
          end
        end
      end
    end

    if saved > 0 then
      if not AppleBarDB.customPacks[zone] then
        AppleBarDB.customPacks[zone] = {}
      end
      -- Find existing pack that shares any guid or npcid, update it
      local existingKey = nil
      for packKey, packData in pairs(AppleBarDB.customPacks[zone]) do
        for guid, entry in pairs(pack) do
          if packData[guid] then
            existingKey = packKey; break
          end
          -- npcid match
          if type(entry) == "table" and entry.npcid then
            for _, pentry in pairs(packData) do
              if type(pentry) == "table" and pentry.npcid == entry.npcid then
                existingKey = packKey; break
              end
            end
          end
          if existingKey then break end
        end
        if existingKey then break end
      end
      local packKey = existingKey or ("pack_" .. math.floor(GetTime()))
      AppleBarDB.customPacks[zone][packKey] = pack
      DEFAULT_CHAT_FRAME:AddMessage("|cffFFCC00AppleBar|r: Saved pack of " .. saved .. " mob(s).")
    else
      DEFAULT_CHAT_FRAME:AddMessage("|cffFFCC00AppleBar|r: No active marks to save.")
    end
  end
end)
clearSlot:SetScript("OnDragStart", Slot_OnDragStart)
clearSlot:SetScript("OnDragStop",  Slot_OnDragStop)

-- ============================================================
-- AppleBar_MarkGroup (left-click AutoMark / /ab mark)
-- ============================================================

function AppleBar_MarkGroup()
  if not PlayerCanMark() then
    DEFAULT_CHAT_FRAME:AddMessage("|cffFFCC00AppleBar|r: Need leader/assist to mark.")
    return
  end
  local _, mouseoverGuid = UnitExists("mouseover")
  local _, targetGuid    = UnitExists("target")
  local guid = mouseoverGuid or targetGuid
  if not guid then return end
  if UnitIsDead(guid) then return end

  local pack = FindPackForGuid(guid)
  if pack then
    MarkPack(pack)
  else
    local intended = GetIntendedMark(guid)
    if intended and intended > 0 then
      SafeSetRaidTarget(guid, intended)
    else
      local freeMark = PickFreeMarkIndex()
      if freeMark then
        SafeSetRaidTarget(guid, freeMark)
        SaveGuidOverride(guid, freeMark)
      end
    end
  end
end

-- ============================================================
-- Auto-mode: PLAYER_TARGET_CHANGED
-- ============================================================

local function AppleBar_OnTargetChanged()
  if not AppleBarDB or not AppleBarDB.autoMode then return end
  if not PlayerCanMark() then return end
  local exists, guid = UnitExists("target")
  if not exists or not guid then return end
  if UnitIsDead("target") then return end
  if not UnitIsEnemy("player", "target") then return end

  local pack = FindPackForGuid(guid)
  if pack then
    local needsMark = false
    for pguid, _ in pairs(pack) do
      if UnitExists(pguid) and not UnitIsDead(pguid) and not GetRaidTargetIndex(pguid) then
        needsMark = true; break
      end
    end
    if needsMark then MarkPack(pack) end
    return
  end

  -- No saved pack. Build a proximity pack from all known nearby enemy units.
  -- Source: AutoMarker's unitCache (all recently seen GUIDs), filtered by
  -- distance <= PACK_RANGE and alive+enemy. Falls back to target-only if
  -- UnitXP_SP3 is not available.

  local function IsElite(g)
    local c = UnitClassification(g)
    return c == "elite" or c == "rareelite" or c == "worldboss"
  end

  -- If target is non-elite with no known mark, skip entirely
  local targetElite = IsElite(guid)
  local targetKnown = GetIntendedMark(guid)
  if not targetElite and (not targetKnown or targetKnown == 0) then return end

  local nearbyUnits = {}  -- { guid, isElite, intendedMark }

  if UnitXP then
    -- Always include the target
    nearbyUnits[table.getn(nearbyUnits) + 1] = {
      guid  = guid,
      elite = targetElite,
      known = targetKnown,
    }

    -- Scan AutoMarker's unit cache for nearby alive enemies
    local cache = AutoMarkerDB and AutoMarkerDB.unitCache
    if cache then
      for cguid, _ in pairs(cache) do
        if cguid ~= guid
          and UnitExists(cguid)
          and not UnitIsDead(cguid)
          and UnitIsEnemy("player", cguid)
        then
          local dist = UnitXP("distanceBetween", guid, cguid)
          if dist and dist <= PACK_RANGE then
            local isElite  = IsElite(cguid)
            local known    = GetIntendedMark(cguid)
            -- Skip non-elites with no known/learned mark
            if isElite or (known and known > 0) then
              nearbyUnits[table.getn(nearbyUnits) + 1] = {
                guid  = cguid,
                elite = isElite,
                known = known,
              }
            end
          end
        end
      end
    end
  else
    -- No UnitXP_SP3: just mark the target
    nearbyUnits[1] = { guid = guid, elite = targetElite, known = targetKnown }
  end

  -- Sort: elites first, then by known mark priority (lower index = higher priority),
  -- unknowns last within each tier.
  table.sort(nearbyUnits, function(a, b)
    if a.elite ~= b.elite then return a.elite end
    local am = a.known or 999
    local bm = b.known or 999
    return am < bm
  end)

  -- Assign marks skull-first (8 down to 1), skipping already-marked alive units.
  -- Elites get first pick, non-elites fill remaining slots.
  local nextMark = 8
  local function NextFreeSlot()
    while nextMark >= 1 do
      local token = "mark" .. nextMark
      local occupied = UnitExists(token) and not UnitIsDead(token)
      local m = nextMark
      nextMark = nextMark - 1
      if not occupied then return m end
    end
    return nil
  end

  for _, unit in ipairs(nearbyUnits) do
    local uguid = unit.guid
    if not GetRaidTargetIndex(uguid) then
      local mark = unit.known
      -- If known mark slot is free use it, otherwise grab next free slot
      if mark and mark > 0 then
        local token = "mark" .. mark
        if UnitExists(token) and not UnitIsDead(token) then
          mark = NextFreeSlot()
        end
      else
        mark = NextFreeSlot()
      end
      if mark then
        SafeSetRaidTarget(uguid, mark)
        if unit.known and unit.known > 0 then
          junkGuids[uguid] = nil
        else
          junkGuids[uguid] = true
        end
      end
    end
  end
end

-- ============================================================
-- Slot visual update + dynamic sort
-- ============================================================

local abReady = false

-- Returns the x offset for a given position (1-based) respecting flip state.
-- Flipped: position 1 is on the RIGHT (automark+clear on left, marks on right).
local function SlotXOff(position)
  return BAR_PADDING + (position - 1) * (BUTTON_SIZE + BAR_PADDING)
end

-- Reposition the automark and clear buttons based on flip state.
local function AppleBar_ApplyLayout()
  if not abReady then return end
  if AppleBarDB.flipped then
    -- Flipped: clear=pos1, auto=pos2, mark slots start at pos3
    clearSlot:ClearAllPoints()
    clearSlot:SetPoint("LEFT", AppleBar, "LEFT", SlotXOff(1), 0)
    autoSlot:ClearAllPoints()
    autoSlot:SetPoint("LEFT", AppleBar, "LEFT", SlotXOff(2), 0)
  else
    -- Normal: mark slots pos1-8, auto=pos9, clear=pos10
    autoSlot:ClearAllPoints()
    autoSlot:SetPoint("LEFT", AppleBar, "LEFT", SlotXOff(NUM_MARKS + 1), 0)
    clearSlot:ClearAllPoints()
    clearSlot:SetPoint("LEFT", AppleBar, "LEFT", SlotXOff(NUM_MARKS + 2), 0)
  end
end

local function AppleBar_UpdateSlots()
  if not abReady then return end

  local active   = {}
  local inactive = {}

  for i = 1, NUM_MARKS do
    local token  = "mark" .. i
    local exists = GuidForMark(i) ~= nil
    local dead   = exists and UnitIsDead(token)
    if exists and not dead then
      active[table.getn(active) + 1] = i
    else
      inactive[table.getn(inactive) + 1] = i
    end
  end

  local function desc(a, b) return a > b end
  local function asc(a, b)  return a < b end
  local sortFn = (AppleBarDB and AppleBarDB.flipped) and asc or desc
  table.sort(active,   sortFn)
  table.sort(inactive, sortFn)

  local flipped = AppleBarDB and AppleBarDB.flipped
  local first  = flipped and inactive or active
  local second = flipped and active   or inactive

  local startPos = flipped and 3 or 1
  local position = startPos

  for _, i in ipairs(first) do
    local slot = slots[i]
    slot:ClearAllPoints()
    slot:SetPoint("LEFT", AppleBar, "LEFT", SlotXOff(position), 0)
    if flipped then
      slot.icon:SetVertexColor(1, 1, 1, 0.3)
    else
      if MarkIsReachable(i) then
        slot.icon:SetVertexColor(1, 1, 1, 1)
      else
        slot.icon:SetVertexColor(1, 0.2, 0.2, 1)
      end
    end
    slot.overlay:Hide()
    position = position + 1
  end

  for _, i in ipairs(second) do
    local slot = slots[i]
    slot:ClearAllPoints()
    slot:SetPoint("LEFT", AppleBar, "LEFT", SlotXOff(position), 0)
    if flipped then
      if MarkIsReachable(i) then
        slot.icon:SetVertexColor(1, 1, 1, 1)
      else
        slot.icon:SetVertexColor(1, 0.2, 0.2, 1)
      end
    else
      slot.icon:SetVertexColor(1, 1, 1, 0.3)
    end
    slot.overlay:Hide()
    position = position + 1
  end
end

-- ============================================================
-- Events & OnUpdate
-- ============================================================

local updateElapsed   = 0
local UPDATE_INTERVAL = 0.25

local eventFrame = CreateFrame("Frame", "AppleBarEventFrame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("RAID_TARGET_UPDATE")

eventFrame:SetScript("OnEvent", function()
  if event == "ADDON_LOADED" and arg1 == "AppleBar" then
    AppleBar_Initialize()
  elseif event == "PLAYER_TARGET_CHANGED" and abReady then
    AppleBar_OnTargetChanged()
    AppleBar_UpdateSlots()
  elseif event == "RAID_TARGET_UPDATE" and abReady then
    ScanAndRecordObservations()
    AppleBar_UpdateSlots()
  end
end)

eventFrame:SetScript("OnUpdate", function()
  updateElapsed = updateElapsed + arg1
  if updateElapsed >= UPDATE_INTERVAL then
    updateElapsed = 0
    AppleBar_UpdateSlots()
  end
end)

-- ============================================================
-- Initialization
-- ============================================================

function AppleBar_Initialize()
  if not AppleBarDB then AppleBarDB = {} end
  for k, v in pairs(AB_DEFAULTS) do
    if AppleBarDB[k] == nil then AppleBarDB[k] = v end
  end
  -- migrate old guidMarkOverrides (plain number -> table)
  for guid, entry in pairs(AppleBarDB.guidMarkOverrides) do
    if type(entry) == "number" then
      AppleBarDB.guidMarkOverrides[guid] = {
        mark  = entry,
        name  = "unknown",
        npcid = NpcIdFromGuid(guid),
      }
    end
  end

  AppleBar:ClearAllPoints()
  AppleBar:SetPoint(
    AppleBarDB.point or "CENTER", UIParent, AppleBarDB.point or "CENTER",
    AppleBarDB.x or 0, AppleBarDB.y or -200)
  AppleBar:SetScale(AppleBarDB.scale or 1.0)
  AppleBar:Show()
  abReady = true
  AppleBar_ApplyLayout()
  AppleBar_UpdateAutoSlot()
  AppleBar_UpdateSlots()

  DEFAULT_CHAT_FRAME:AddMessage(
    "|cffFFCC00AppleBar " .. AB_VERSION .. "|r loaded. Type |cff00FF00/ab|r for commands.")
end

-- ============================================================
-- Slash commands
-- ============================================================

local function AppleBar_HandleCommand(msg)
  local cmd = string.lower(string.gsub(msg or "", "^%s*(.-)%s*$", "%1"))

  if cmd == "" or cmd == "help" then
    DEFAULT_CHAT_FRAME:AddMessage("|cffFFCC00AppleBar|r commands:")
    DEFAULT_CHAT_FRAME:AddMessage("  |cff00FF00/ab flip|r           - Mirror/flip the bar orientation")
    DEFAULT_CHAT_FRAME:AddMessage("  |cff00FF00/ab lock|r           - Toggle drag lock")
    DEFAULT_CHAT_FRAME:AddMessage("  |cff00FF00/ab auto|r           - Toggle auto-mark mode")
    DEFAULT_CHAT_FRAME:AddMessage("  |cff00FF00/ab mark|r           - Mark target/group")
    DEFAULT_CHAT_FRAME:AddMessage("  |cff00FF00/ab clear|r          - Clear all marks")
    DEFAULT_CHAT_FRAME:AddMessage("  |cff00FF00/ab scale 0.8|r      - Set bar scale (0.3 to 3.0)")
    DEFAULT_CHAT_FRAME:AddMessage("  |cff00FF00/ab reset|r          - Reset bar to center")
    DEFAULT_CHAT_FRAME:AddMessage("  |cff00FF00/ab clearoverrides|r - Forget all overrides, packs and observations")
    DEFAULT_CHAT_FRAME:AddMessage("  |cff00FF00/ab show|r / |cff00FF00hide|r")

  elseif string.sub(cmd, 1, 5) == "scale" then
    local val = tonumber(string.sub(cmd, 7))
    if val and val >= 0.3 and val <= 3.0 then
      AppleBarDB.scale = val
      AppleBar:SetScale(val)
      DEFAULT_CHAT_FRAME:AddMessage("|cffFFCC00AppleBar|r: Scale set to " .. val)
    else
      DEFAULT_CHAT_FRAME:AddMessage("|cffFFCC00AppleBar|r: Scale must be between 0.3 and 3.0")
    end

  elseif cmd == "flip" then
    AppleBarDB.flipped = not AppleBarDB.flipped
    AppleBar_ApplyLayout()
    AppleBar_UpdateSlots()
    DEFAULT_CHAT_FRAME:AddMessage("|cffFFCC00AppleBar|r: Bar " ..
      (AppleBarDB.flipped and "flipped." or "restored to normal."))

  elseif cmd == "lock" then
    AppleBarDB.locked = not AppleBarDB.locked
    DEFAULT_CHAT_FRAME:AddMessage("|cffFFCC00AppleBar|r: " ..
      (AppleBarDB.locked and "|cffFF4444Locked|r" or "|cff00FF00Unlocked|r"))

  elseif cmd == "auto" then
    AppleBarDB.autoMode = not AppleBarDB.autoMode
    AppleBar_UpdateAutoSlot()
    DEFAULT_CHAT_FRAME:AddMessage("|cffFFCC00AppleBar|r Auto-mark: " ..
      (AppleBarDB.autoMode and "|cff00FF00ON|r" or "|cffFF4444OFF|r"))

  elseif cmd == "mark" then
    AppleBar_MarkGroup()

  elseif cmd == "clear" then
    if not PlayerCanMark() then
      DEFAULT_CHAT_FRAME:AddMessage("|cffFFCC00AppleBar|r: Need leader/assist to clear marks.")
    else
      for i = 1, NUM_MARKS do
        if UnitExists("mark" .. i) then SafeSetRaidTarget("mark" .. i, 0) end
      end
      DEFAULT_CHAT_FRAME:AddMessage("|cffFFCC00AppleBar|r: All marks cleared.")
    end

  elseif cmd == "reset" then
    AppleBarDB.point = "CENTER"
    AppleBarDB.x     = 0
    AppleBarDB.y     = -200
    AppleBar:ClearAllPoints()
    AppleBar:SetPoint("CENTER", UIParent, "CENTER", 0, -200)
    DEFAULT_CHAT_FRAME:AddMessage("|cffFFCC00AppleBar|r: Position reset.")

  elseif cmd == "clearoverrides" then
    AppleBarDB.guidMarkOverrides = {}
    AppleBarDB.customPacks       = {}
    AppleBarDB.observations      = {}
    DEFAULT_CHAT_FRAME:AddMessage("|cffFFCC00AppleBar|r: All overrides, packs and observations cleared.")

  elseif cmd == "show" then
    AppleBar:Show()
  elseif cmd == "hide" then
    AppleBar:Hide()
  else
    DEFAULT_CHAT_FRAME:AddMessage("|cffFFCC00AppleBar|r: Unknown command. /ab for help.")
  end
end

SLASH_APPLEBAR1 = "/applebar"
SLASH_APPLEBAR2 = "/ab"
SlashCmdList["APPLEBAR"] = AppleBar_HandleCommand
