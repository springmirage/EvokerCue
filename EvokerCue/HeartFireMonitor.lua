local addonName, EC = ...

local Monitor = { generation = 0 }
EC.HeartFireMonitor = Monitor
local HEART_FIRE_DURATION = 15
local RING_TEXTURE = "Interface\\AddOns\\" .. addonName .. "\\Media\\Ring.tga"

function Monitor:IsEnabled()
    return EC.state.dbReady and EC.db.enabled and EC.db.heartFire.enabled
end
function Monitor:Hide()
    self.generation = self.generation + 1
    if self.timer then self.timer:Cancel(); self.timer = nil end
    self.endsAt = nil
    if self.frame then self.frame:Hide() end
end
function Monitor:CreateRing()
    if self.frame then return end
    local ring = CreateFrame("Frame", "EvokerCueHeartFireRing", UIParent)
    ring:SetSize(140, 140)
    ring:SetPoint("CENTER", UIParent, "CENTER", 0, -15)
    ring:SetFrameStrata("HIGH")
    ring:EnableMouse(false)
    ring:Hide()
    ring.bg = ring:CreateTexture(nil, "BACKGROUND")
    ring.bg:SetAllPoints()
    ring.bg:SetTexture(RING_TEXTURE)
    ring.bg:SetVertexColor(0, 0, 0, 0.6)
    ring.cd = CreateFrame("Cooldown", nil, ring, "CooldownFrameTemplate")
    ring.cd:SetAllPoints()
    ring.cd:SetDrawEdge(false)
    ring.cd:SetDrawBling(false)
    ring.cd:SetHideCountdownNumbers(true)
    ring.cd:SetReverse(false)
    ring.cd:SetSwipeTexture(RING_TEXTURE)
    -- Only this visible ring checks its deadline per frame; no source/aura scans.
    ring:SetScript("OnUpdate", function()
        if not Monitor:IsEnabled() or (Monitor.endsAt and GetTime() >= Monitor.endsAt) then Monitor:Hide() end
    end)
    self.frame = ring
end
function Monitor:OnStasisStarted()
    if not self:IsEnabled() then return end
    self:CreateRing()
    self:Hide()
    local generation = self.generation
    local now = GetTime()
    self.startedAt, self.endsAt = now, now + HEART_FIRE_DURATION
    local ring = self.frame
    ring:SetAlpha(1)
    ring:Show()
    ring.cd:Show()
    ring.cd:Clear()
    ring.cd:SetSwipeColor(1, 48 / 255, 48 / 255, 0.95)
    ring.cd:SetCooldown(now, HEART_FIRE_DURATION)
    self.timer = C_Timer.NewTimer(HEART_FIRE_DURATION, function()
        if generation == self.generation then self:Hide() end
    end)
end
function Monitor:ApplySettings()
    if not self:IsEnabled() then self:Hide() end
    if EC.db and not EC.db.enabled and self.observer then
        self.observer:ClearRecentStasisHistory("心火观察关闭")
    end
end
function Monitor:SetEnabled(enabled)
    EC.db.heartFire.enabled = enabled == true
    self:ApplySettings()
end

function Monitor:Initialize()
    if self.eventFrame then return end
    -- The accounting tracker deliberately drops ALL events outside its zone.
    -- Reuse its exact classifier/aura lifecycle on a separate, whitelisted receiver.
    -- No inherited live fields, wave methods, token methods, UI notifications or
    -- empower objects are reachable. No classifier/state-machine code is copied.
    -- This receiver observes even while the feature is off, so enabling the UI
    -- between Stasis and release cannot misclassify that release as a fresh cast.
    local tracker, observer = EC.CastTracker, {}
    for _, name in ipairs({ "ObserveInitialStasis", "ObserveStasisRelease", "CheckPrepullAura",
        "ClearPrepullPackage", "ClearPrepullEmpower", "CreatePrepullStasisCandidate", "ClearRecentStasisHistory" }) do
        observer[name] = tracker[name]
    end
    observer.ResetPrepullState = tracker.ClearRecentStasisHistory
    self.observer = observer
    local frame = CreateFrame("Frame")
    frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    frame:RegisterUnitEvent("UNIT_AURA", "player")
    frame:RegisterEvent("PLAYER_DEAD")
    frame:RegisterEvent("ENCOUNTER_START")
    local function OnEvent(_, event, unit, guid, spellID, barID)
        if not EC.state.dbReady or not EC.db.enabled then return end
        if event == "ENCOUNTER_START" then
            -- The same aura deadline used by the accounting tracker's handoff,
            -- without adopting any prepull casts, waves or tokens.
            observer.bridgedReadyExpiresAt = observer.prepullReadyExpiresAt
            observer:ClearPrepullPackage("心火静滞观察跨开怪")
            return
        end
        if event == "PLAYER_DEAD" then
            if not (EC.Runtime and EC.Runtime.encounterActive) then observer:ClearRecentStasisHistory("心火战前死亡") end
            return
        end
        if EC:IsSecret(unit) or unit ~= "player" then return end
        if event == "UNIT_AURA" then observer:CheckPrepullAura(); return end
        if EC:IsSecret(spellID) then return end
        if EC:IsSecret(guid) then guid = nil end
        if EC:IsSecret(barID) then barID = nil end
        -- IDs come from the canonical skill definitions, never a second skill table.
        local start = EC.Parser:GetSkillDefinition("STASIS")
        local release = EC.Parser:GetSkillDefinition("RELEASE_STASIS")
        if start.ids[spellID] then
            local _, accepted = observer:ObserveInitialStasis(guid, barID)
            if accepted then
                -- Notification occurs only after successful semantic classification.
                -- UI failure cannot escape into any cast/ledger path.
                pcall(Monitor.OnStasisStarted, Monitor)
            end
        elseif release.ids[spellID] then observer:ObserveStasisRelease(spellID) end
    end
    frame:SetScript("OnEvent", function(...) pcall(OnEvent, ...) end)
    self.eventFrame = frame
end
