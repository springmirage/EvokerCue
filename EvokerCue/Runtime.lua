local addonName, EC = ...

local Runtime = {}
EC.Runtime = Runtime

local RAID_12_1_INSTANCE_IDS = {
    [3004] = true, -- 烈毒之渊
    [2987] = true, -- 潮缚石窟（尼姆瑞莎·唤波者）
    [3095] = true, -- 基希克斯破封（12.1.5）
}
local COMBAT_FALLBACK_DELAY = 0.80

Runtime.initialized = false
Runtime.encounterActive = false
Runtime.combatActive = false
Runtime.sessionActive = false
Runtime.sessionSource = nil
Runtime.eventFrame = nil
Runtime.pendingCombatTimer = nil
Runtime.encounterID = nil
Runtime.difficultyID = nil

local function Now()
    if GetTimePreciseSec then
        return GetTimePreciseSec()
    end
    return GetTime()
end

local function GetInstanceID()
    local _, _, _, _, _, _, _, instanceID = GetInstanceInfo()
    return tonumber(instanceID) or 0
end

function Runtime:IsZoneAllowed()
    if not EC.state.dbReady or not EC.db.enabled then
        return false
    end

    if not EC.db.runtime.onlyVenomousAbyss then
        return true
    end

    return RAID_12_1_INSTANCE_IDS[GetInstanceID()] == true
end

function Runtime:GetZoneText()
    local name = GetInstanceInfo()
    return name or "当前区域"
end

function Runtime:CanRun()
    return EC.state.dbReady and EC.db.enabled and self:IsZoneAllowed()
end

-- Freeze a fresh plan at encounter start; keep this legacy method name for callers.
-- MRT still reads Text1. Structured providers resolve their own selected plan.
function Runtime:ReadLiveMRTPlan(reason)
    if not EC.state.dbReady or not EC.MRTReader or not EC.Parser then
        return nil, nil
    end

    local identity = EC:RefreshPlayerIdentity()
    local noteText, info = EC.PlanSources:GetCurrentNote(identity,
        self.encounterActive and { encounterID = self.encounterID, encounterName = self.encounterName, difficultyID = self.difficultyID } or nil)
    noteText = noteText or ""
    info = info or {}

    local noteHash = EC.PlanSources:HashText(noteText, info)
    local result = EC.PlanSources:BuildResult(noteText, identity, info)

    if EC.PlanGuard then EC.PlanGuard:AnnouncePlan(result, noteHash, self.encounterActive) end

    if EC.Diagnostics and EC.Diagnostics.CapturePlan then
        EC.Diagnostics:CapturePlan(noteText, info, identity, result, reason)
    end

    -- 同步概览页状态，但本次战斗使用下面刚刚生成的 result，绝不拿旧结果启动。
    EC.state.mrtAvailable = info.available == true
    EC.state.sourceInfo = info
    EC.state.mrtNamespace = info.namespace
    EC.state.noteLength = #noteText
    EC.state.noteText = noteText
    EC.state.noteHash = noteHash
    EC.state.lastIdentitySignature = identity.signature
    EC.state.lastRefreshReason = reason or "战斗开始读取"
    EC.state.lastRefreshAt = date and date("%H:%M:%S") or "刚刚"
    EC.state.result = result

    local snapshot = nil
    if result and result.ok and EC.Timeline and EC.Timeline.BuildSnapshot then
        snapshot = EC.Timeline:BuildSnapshot(result)
    end

    EC:Log(
        "战斗开始直接读取战术板：字符=%d，匹配=%s，事件=%d，波次=%s",
        #noteText,
        result and tostring(result.matchedPlayerName or "-") or "-",
        result and #(result.events or {}) or 0,
        result and tostring(result.waveQuotaText or "-") or "-"
    )

    return result, snapshot
end

function Runtime:GetCurrentPlan()
    return self:ReadLiveMRTPlan("读取当前战术板")
end

function Runtime:CancelCombatFallback()
    if self.pendingCombatTimer then
        self.pendingCombatTimer:Cancel()
        self.pendingCombatTimer = nil
    end
end

function Runtime:StartSession(source, metadata, forceRestart)
    source = source or "COMBAT"
    metadata = metadata or {}

    if not self:CanRun() then
        if EC.Diagnostics and EC.Diagnostics.Event then
            EC.Diagnostics:Event("START_BLOCKED", string.format(
                "source=%s dbReady=%s enabled=%s zoneAllowed=%s",
                tostring(source),
                tostring(EC.state.dbReady),
                tostring(EC.db and EC.db.enabled),
                tostring(self:IsZoneAllowed())
            ))
        end
        return false
    end

    -- Transfer only the in-flight prepull identity across the explicit Boss
    -- restart. Ordinary EndSession calls must discard all pending empowers.
    local prepullEmpower = source == "BOSS" and EC.CastTracker and EC.CastTracker:DetachPrepullEmpower() or nil
    if forceRestart then
        -- ENCOUNTER_START 必须成为最终权威起点。
        -- 即便 PLAYER_REGEN_DISABLED 先一步建立过普通战斗会话，也在这里彻底重建。
        self:StopSession("首领战重新读取战术板", true)
    end

    if EC.Diagnostics and EC.Diagnostics.BeginSession then
        EC.Diagnostics:BeginSession(source, metadata)
    end

    metadata.startTime = metadata.startTime or (source == "BOSS" and self.encounterStartTime) or Now()
    if EC.Diagnostics and EC.Diagnostics.active then
        EC.Diagnostics.active.timelineStart = metadata.startTime
        EC.Diagnostics.active.prepull = EC.CastTracker and EC.CastTracker:GetPrepullSnapshot() or nil
    end
    local result, snapshot = self:ReadLiveMRTPlan(
        source == "BOSS" and "首领战开始读取" or "进入战斗读取"
    )
    local startedTimeline = false

    if EC.Timeline then
        if source == "BOSS" and result and result.ok then
            startedTimeline = EC.Timeline:StartFromResult(result, source, metadata) and true or false
        else
            EC.Timeline:Stop("停止提醒", true)
        end
    end

    -- 时间轴未启动时仍建立真实施法记录。
    -- 没有有效 MRT 时只保留实际记录，不编造配额。
    if EC.CastTracker and not startedTimeline then
        EC.CastTracker:BeginSession(source == "COMBAT" and nil or snapshot, source, metadata.startTime or Now())
    end

    self.sessionActive = true
    self.sessionSource = source

    -- The boss timer starts at ENCOUNTER_START, but the record HUD can inherit the
    -- prepull W1 package: a real Stasis plus any Dream Breaths already released (or
    -- still empowering) after it. Wave identity is still matched to MRT.
    if source == "BOSS" and EC.CastTracker and EC.CastTracker.BridgeRecentPrepullStasis then
        EC.CastTracker:RestorePrepullEmpower(prepullEmpower)
        EC.CastTracker:BridgeRecentPrepullStasis()
    end



    if EC.UI and EC.UI.Refresh then
        EC.UI:Refresh()
    end
    return true
end

function Runtime:StopSession(reason, silent)
    if EC.Diagnostics and EC.Diagnostics.CaptureFinalState then
        EC.Diagnostics:CaptureFinalState("before_stop")
    end

    if EC.Timeline then
        EC.Timeline:Stop(reason or "战斗结束", silent == true)
    elseif EC.CastTracker then
        EC.CastTracker:EndSession(reason or "战斗结束")
    end

    -- Timeline:Stop 已经会结束 CastTracker；只有没有 Timeline 时才需要上面的兜底。
    self.sessionActive = false
    self.sessionSource = nil

    if EC.Diagnostics and EC.Diagnostics.EndSession then
        EC.Diagnostics:EndSession(reason or "战斗结束")
    end

    if not silent and EC.UI and EC.UI.Refresh then
        EC.UI:Refresh()
    end
end

function Runtime:EnsureFreeTestSession()
    if not self:CanRun() then
        return false
    end
    -- A live encounter can never be restarted as a zero-based TEST session.
    if self.encounterActive then
        if EC.CastTracker and EC.CastTracker.sessionActive then return true end
        self:RefreshAfterSettings()
        return EC.CastTracker and EC.CastTracker.sessionActive or false
    end
    if EC.db.runtime.combatOnly then
        return false
    end

    if EC.CastTracker and EC.CastTracker.sessionActive then
        return true
    end

    local _, snapshot = self:GetCurrentPlan()
    if EC.CastTracker then
        EC.CastTracker:BeginSession(snapshot, "TEST", Now())
    end
    self.sessionActive = true
    self.sessionSource = "TEST"

    if EC.UI and EC.UI.Refresh then
        EC.UI:Refresh()
    end
    return true
end

-- Player-facing prepull reset.  It never touches the MRT note/timeline and is
-- deliberately blocked from ENCOUNTER_START through ENCOUNTER_END.
function Runtime:ResetPrepullState(reason, announce)
    if self:IsEncounterRunning() then
        if announce then
            print("|cffff7777[奶龙打地鼠]|r 首领战进行中，不能清空预铺。")
        end
        EC:Log("手动清空预铺被阻止：首领战进行中")
        return false
    end

    if EC.CastTracker and EC.CastTracker.ResetPrepullState then
        EC.CastTracker:ResetPrepullState(reason or "手动清空预铺")
    elseif EC.CastTracker and EC.CastTracker.ClearRecentStasisHistory then
        EC.CastTracker:ClearRecentStasisHistory(reason or "手动清空预铺")
    end

    if EC.UI and EC.UI.Refresh then
        EC.UI:Refresh()
    end

    if announce then
        print("|cff52d6a0[奶龙打地鼠]|r 已清空预铺记录，等待下一次静滞。")
    end
    return true
end

function Runtime:RefreshDisplays()
    if EC.TrackerHUD then EC.TrackerHUD:Update() end
    if EC.AlertUI then EC.AlertUI:RefreshVisibility() end
    if EC.Voice then EC.Voice:Prune() end
end

function Runtime:IsEncounterRunning()
    if self.encounterActive then return true end
    if IsEncounterInProgress then
        local ok, active = pcall(IsEncounterInProgress)
        if ok and not EC:IsSecret(active) and active then return true end
    end
    return false
end

function Runtime:RefreshAfterSettings()
    if not EC.state.dbReady then
        return
    end

    if not EC.db.enabled or not self:IsZoneAllowed() then
        self:StopSession("当前设置下不运行")
        if not self.encounterActive and EC.CastTracker then EC.CastTracker:ResetPrepullState("运行范围变更") end
        self:RefreshDisplays()
        return
    end

    if self.encounterActive then
        if not (EC.CastTracker and EC.CastTracker.sessionActive) then
            if self.encounterStartTime then
                self:StartSession("BOSS", {
                    encounterID = self.encounterID, difficultyID = self.difficultyID,
                    startTime = self.encounterStartTime, partial = true,
                }, true)
                if EC.PlanGuard then EC.PlanGuard:Warn("MID_FIGHT_ENABLE",
                    "本场中途启用：此前施法无法补记，等待下一次可匹配的静滞；时间轴仍按原开怪时间运行。") end
            elseif EC.CastTracker then
                if EC.Diagnostics then EC.Diagnostics:BeginSession("BOSS_RELOAD", { partial = true }) end
                EC.CastTracker:BeginSession(nil, "BOSS", Now())
                self.sessionActive, self.sessionSource = true, "BOSS_RELOAD"
                if EC.PlanGuard then EC.PlanGuard:Warn("MID_FIGHT_NO_CLOCK",
                    "无法恢复本场开怪时间，暂时只记录后续实际施法；下次开怪自动恢复时间轴与配额纠错。") end
            end
        end
    elseif EC.db.runtime.combatOnly then
        if self.combatActive then
            if not (EC.CastTracker and EC.CastTracker.sessionActive) then self:StartSession("COMBAT") end
        else self:StopSession("等待进入战斗") end
    end

    self:RefreshDisplays()
    if EC.UI and EC.UI.Refresh then EC.UI:Refresh() end
end

function Runtime:GetStatus()
    return {
        zoneAllowed = self:IsZoneAllowed(),
        zoneName = self:GetZoneText(),
        instanceID = GetInstanceID(),
        combatOnly = not EC.state.dbReady or EC.db.runtime.combatOnly == true,
        combatActive = self.combatActive,
        encounterActive = self.encounterActive,
        sessionActive = (EC.CastTracker and EC.CastTracker.sessionActive) and true or false,
    }
end

function Runtime:Initialize()
    if self.initialized then
        return
    end
    self.initialized = true

    local frame = CreateFrame("Frame")
    frame:RegisterEvent("PLAYER_REGEN_DISABLED")
    frame:RegisterEvent("PLAYER_REGEN_ENABLED")
    frame:RegisterEvent("ENCOUNTER_START")
    frame:RegisterEvent("ENCOUNTER_END")
    frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")

    local function OnRuntimeEvent(_, event, ...)
        if EC.Diagnostics and EC.Diagnostics.RuntimeEvent then
            EC.Diagnostics:RuntimeEvent(event, ...)
        end

        if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
            C_Timer.After(0.2, function()
                if not Runtime:IsZoneAllowed() then
                    Runtime:CancelCombatFallback()
                    Runtime:StopSession("离开运行区域")
                    if EC.CastTracker then EC.CastTracker:ClearRecentStasisHistory("离开运行区域") end
                end
                Runtime:RefreshDisplays()
                if EC.UI and EC.UI.Refresh then EC.UI:Refresh() end
            end)
            return
        end

        if event == "PLAYER_REGEN_DISABLED" then
            Runtime.combatActive = true

            -- 不在这里抢先启动 Boss 时间轴。
            -- 红豆依赖 ENCOUNTER_START 作为首领战权威起点；这里只保留普通战斗兜底。
            if EC.state.dbReady
                and EC.db.enabled
                and EC.db.runtime.combatOnly
                and Runtime:IsZoneAllowed()
                and not (EC.CastTracker and EC.CastTracker.sessionActive)
            then
                Runtime:CancelCombatFallback()
                Runtime.pendingCombatTimer = C_Timer.NewTimer(COMBAT_FALLBACK_DELAY, function()
                    Runtime.pendingCombatTimer = nil
                    if Runtime.combatActive
                        and not Runtime.encounterActive
                        and not (EC.CastTracker and EC.CastTracker.sessionActive)
                    then
                        Runtime:StartSession("COMBAT")
                    end
                end)
            end

            if EC.UI and EC.UI.Refresh then
                EC.UI:Refresh()
            end
            return
        end

        if event == "PLAYER_REGEN_ENABLED" then
            Runtime.combatActive = false
            Runtime:CancelCombatFallback()

            -- 只有“首领战尚未开始”的真实脱战，才清掉可跨进下一场的静滞历史。
            -- 这会隔离清小怪/路上战斗留下的静滞，避免它们污染下一次 Boss 的 W1。
            -- Boss 战一旦 ENCOUNTER_START，玩家死亡/战复可能触发个人脱战；此时必须
            -- 完整保留当前 Wave、绿喷计数和最近静滞，直到 ENCOUNTER_END 才真正收尾。
            if not Runtime.encounterActive then
                if EC.CastTracker and EC.CastTracker.ResetPrepullState then
                    EC.CastTracker:ResetPrepullState("非首领战脱战")
                elseif EC.CastTracker and EC.CastTracker.ClearRecentStasisHistory then
                    EC.CastTracker:ClearRecentStasisHistory("非首领战脱战")
                end

                if EC.state.dbReady and EC.db.runtime.combatOnly then
                    Runtime:StopSession("战斗结束")
                end
            else
                EC:Log("首领战进行中发生个人脱战：保留当前 Wave 与静滞记录")
            end

            if EC.UI and EC.UI.Refresh then
                EC.UI:Refresh()
            end
            return
        end

        if event == "ENCOUNTER_START" then
            local encounterID, encounterName, difficultyID, groupSize = ...

            Runtime.encounterStartTime = Now()
            Runtime.encounterActive = true
            Runtime.combatActive = true
            if EC.PlanGuard then EC.PlanGuard:BeginScope("BOSS:" .. tostring(Runtime.encounterStartTime)) end
            Runtime.encounterID = encounterID
            Runtime.encounterName = encounterName
            Runtime.difficultyID = difficultyID
            Runtime:CancelCombatFallback()

            if EC.state.dbReady
                and EC.db.enabled
                and Runtime:IsZoneAllowed()
            then
                -- 与红豆一致：ENCOUNTER_START 当场读取 MRT 当前 Text1 并启动。
                -- 不管之前是否已有普通 COMBAT/TEST 会话，都强制以这次读取结果重建。
                Runtime:StartSession("BOSS", {
                    encounterID = encounterID,
                    encounterName = encounterName,
                    difficultyID = difficultyID,
                    groupSize = groupSize,
                    startTime = Runtime.encounterStartTime,
                }, true)
            end

            if EC.UI and EC.UI.Refresh then
                EC.UI:Refresh()
            end
            return
        end

        if event == "ENCOUNTER_END" then
            Runtime.encounterActive = false
            Runtime.combatActive = false
            Runtime.encounterID = nil
            Runtime.difficultyID = nil
            Runtime:CancelCombatFallback()

            if EC.Diagnostics and EC.Diagnostics.active then
                local _, _, _, _, success = ...
                if not EC:IsSecret(success) then EC.Diagnostics.active.success = success end
            end
            Runtime:StopSession("首领战结束")
            Runtime.encounterStartTime = nil
            if EC.CastTracker and EC.CastTracker.ClearRecentStasisHistory then
                EC.CastTracker:ClearRecentStasisHistory("首领战结束")
            end

            if EC.UI and EC.UI.Refresh then
                EC.UI:Refresh()
            end
        end
    end
    frame:SetScript("OnEvent", function(...)
        if EC.Diagnostics and EC.Diagnostics.Run then EC.Diagnostics:Run("战斗事件", OnRuntimeEvent, ...)
        else OnRuntimeEvent(...) end
    end)
    self.eventFrame = frame
    -- Mid-encounter /reload cannot reconstruct the original boss timestamp or casts.
    -- Don't fabricate a fresh zero-time plan or allow the prepull-reset command.
    if self:IsEncounterRunning() then
        self.encounterActive = true
        self.combatActive = true
        self.encounterStartTime = nil
        if self:CanRun() then
            if EC.Diagnostics then EC.Diagnostics:BeginSession("BOSS_RELOAD", { partial = true }) end
            if EC.CastTracker then EC.CastTracker:BeginSession(nil, "BOSS", Now()) end
            self.sessionActive, self.sessionSource = true, "BOSS_RELOAD"
            if EC.PlanGuard then EC.PlanGuard:Warn("RELOAD_IN_BOSS",
                "检测到首领战中重载：本场此前记录无法恢复，暂停时间轴与配额纠错，仅记录后续实际施法；下次开怪自动恢复。") end
        end
    end
end
