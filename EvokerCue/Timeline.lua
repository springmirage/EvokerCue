local addonName, EC = ...

local Timeline = {}
EC.Timeline = Timeline

Timeline.initialized = false
Timeline.driver = nil
Timeline.active = false
Timeline.source = nil
Timeline.startTime = nil
Timeline.snapshot = nil
Timeline.metadata = nil
Timeline.visibleCount = 0
Timeline.lastElapsed = 0
Timeline.updateAccumulator = 0
Timeline.earlyWarningToken = nil
Timeline.earlyWarningCastGUID = nil
Timeline.earlyWarningCastBarID = nil

local function Now()
    if GetTimePreciseSec then
        return GetTimePreciseSec()
    end
    return GetTime()
end


local function IsLiveSource(source)
    return source == "COMBAT" or source == "BOSS" or source == "ENCOUNTER"
end

local function CopyColor(color)
    if type(color) ~= "table" then
        return { 1, 1, 1 }
    end
    return { color[1] or 1, color[2] or 1, color[3] or 1 }
end

local function CopyEvent(event)
    return {
        time = tonumber(event.time) or 0,
        lineNumber = event.lineNumber,
        sequence = event.sequence,
        rawLine = event.rawLine,
        cleanContent = event.cleanContent,
        skillKey = event.skillKey,
        skillName = event.skillName,
        spellID = event.spellID,
        texture = event.texture,
        color = CopyColor(event.color),
        waveIndex = event.waveIndex or 0,
        breathIndex = event.breathIndex,
        breathLimit = event.breathLimit,
        displayBreathIndex = event.breathIndex,
        displayBreathLimit = event.breathLimit,
        quotaReliable = event.quotaReliable,
        slotReliable = event.slotReliable == true,
        eventID = event.sequence,
        reminderClosed = false,
        dismissed = false,
        diagnosticVisibleLogged = false,
        diagnosticWindowEndLogged = false,
        diagnosticLateLogged = false,
        diagnosticPlanClosedLogged = false,
        earlyWarningActive = false,

        -- Dream Breath token ledger.
        tokenIndex = nil,
        consumed = false,
        expired = false,
        consumedByWave = nil,
        consumedAt = nil,
        consumptionReason = nil,
        expiredReason = nil,
    }
end

local function StableSort(events)
    table.sort(events, function(a, b)
        if a.time ~= b.time then
            return a.time < b.time
        end
        -- Preserve the parser's Stasis-first ordering at equal timestamps in
        -- both the visual stack and the voice queue, regardless of input order.
        if a.skillKey == "STASIS" and b.skillKey ~= "STASIS" then return true end
        if b.skillKey == "STASIS" and a.skillKey ~= "STASIS" then return false end
        if (a.lineNumber or 0) ~= (b.lineNumber or 0) then
            return (a.lineNumber or 0) < (b.lineNumber or 0)
        end
        return (a.sequence or 0) < (b.sequence or 0)
    end)
end

function Timeline:BuildSnapshot(result)
    local absenceAllowed = {}
    for key, value in pairs(result.absenceAllowed or {}) do absenceAllowed[key] = value end
    local snapshot = {
        absenceAllowed = absenceAllowed,
        negativeCorrectionAllowed = result.negativeCorrectionAllowed == true,
        integrityReason = result.integrityReason,
        openingReleaseMissing = result.openingReleaseMissing,
        orphanBreathCount = result.orphanBreathCount,
        playerName = result.matchedPlayerName,
        waveQuotaText = result.waveQuotaText,
        events = {},
        waves = {},
        createdAt = Now(),
        lastEventTime = 0,
        dreamBreathTokenCount = 0,
    }

    for _, wave in ipairs(result.waves or {}) do
        table.insert(snapshot.waves, {
            mappingReliable = wave.mappingReliable,
            quotaReliable = wave.quotaReliable,
            invalidReason = wave.invalidReason,
            index = wave.index,
            stasisTime = wave.stasisTime,
            nextStasisTime = wave.nextStasisTime,
            breathLimit = wave.breathLimit or #(wave.breaths or {}),
        })
    end

    for _, event in ipairs(result.events or {}) do
        if not EC.Features or EC.Features:SkillEnabled(event.skillKey) then
            local copied = CopyEvent(event)
            table.insert(snapshot.events, copied)
            if copied.time > snapshot.lastEventTime then
                snapshot.lastEventTime = copied.time
            end
        end
    end

    StableSort(snapshot.events)

    local tokenIndex = 0
    for _, event in ipairs(snapshot.events) do
        if event.skillKey == "DREAM_BREATH" then
            tokenIndex = tokenIndex + 1
            event.tokenIndex = tokenIndex
        end
    end
    snapshot.dreamBreathTokenCount = tokenIndex

    return snapshot
end

function Timeline:StartFromResult(result, source, metadata)
    if not EC.state.dbReady or not EC.db.enabled then
        return false, "DISABLED"
    end

    if not result or not result.ok or #(result.events or {}) == 0 then
        return false, "NO_VALID_RESULT"
    end

    self:Stop("启动新时间轴", true)

    self.snapshot = self:BuildSnapshot(result)
    self.source = source or "UNKNOWN"
    self.metadata = metadata or {}
    self.startTime = tonumber(self.metadata.startTime) or Now()
    self.lastElapsed = 0
    self.visibleCount = 0
    self.updateAccumulator = 0
    self.earlyWarningToken = nil
    self.earlyWarningCastGUID = nil
    self.earlyWarningCastBarID = nil
    self.active = true

    if self.driver then
        self.driver:Show()
    end

    if EC.AlertUI then
        if EC.AlertUI.Clear then EC.AlertUI:Clear() end
        if EC.AlertUI.ClearEmergency then EC.AlertUI:ClearEmergency() end
    end

    if EC.CastTracker and (IsLiveSource(self.source) or self.source == "MRT_TEST") then
        EC.CastTracker:BeginSession(self.snapshot, self.source, self.startTime)
    end

    EC:Log(
        "时间轴启动：来源=%s，角色=%s，事件=%d，波次=%s，绿喷Token=%d",
        tostring(self.source),
        tostring(self.snapshot.playerName or "-"),
        #self.snapshot.events,
        tostring(self.snapshot.waveQuotaText or "-"),
        self.snapshot.dreamBreathTokenCount or 0
    )

    if EC.UI and EC.UI.RefreshRuntime then
        EC.UI:RefreshRuntime()
    end

    return true
end

function Timeline:Stop(reason, silent)
    if EC.CastTracker and EC.CastTracker.ClearBallCast then EC.CastTracker:ClearBallCast(reason) end
    local wasActive = self.active
    if EC.Voice then EC.Voice:Stop(true) end

    self.active = false
    self.source = nil
    self.startTime = nil
    self.snapshot = nil
    self.metadata = nil
    self.visibleCount = 0
    self.lastElapsed = 0
    self.updateAccumulator = 0
    self.earlyWarningToken = nil
    self.earlyWarningCastGUID = nil
    self.earlyWarningCastBarID = nil

    if self.driver then
        self.driver:Hide()
    end

    if EC.AlertUI then
        if EC.AlertUI.Clear then EC.AlertUI:Clear() end
        if EC.AlertUI.ClearEmergency then EC.AlertUI:ClearEmergency() end
    end

    if EC.CastTracker then
        EC.CastTracker:EndSession(reason or "时间轴停止")
    end

    if wasActive and not silent then
        EC:Log("时间轴停止：%s", tostring(reason or "未指定"))
    end

    if EC.UI and EC.UI.RefreshRuntime then
        EC.UI:RefreshRuntime()
    end
end

function Timeline:GetElapsed()
    if not self.active or not self.startTime then
        return 0
    end
    return math.max(0, Now() - self.startTime)
end

-- A token consumed by an EARLIER actual wave is a debt paid in advance.
-- Normal consumption inside its own wave remains part of that wave's original quota.
function Timeline:RecalculateWaveDisplayQuota(waveIndex)
    if not self.snapshot then
        return 0
    end

    local tokens = {}
    for _, event in ipairs(self.snapshot.events) do
        if event.skillKey == "DREAM_BREATH" and event.waveIndex == waveIndex then
            table.insert(tokens, event)
        end
    end

    local effectiveLimit = 0
    for _, token in ipairs(tokens) do
        local borrowedBeforeWave = token.consumed
            and token.consumedByWave ~= nil
            and token.consumedByWave < waveIndex

        if not borrowedBeforeWave then
            effectiveLimit = effectiveLimit + 1
        end
    end

    local displayIndex = 0
    for _, token in ipairs(tokens) do
        local borrowedBeforeWave = token.consumed
            and token.consumedByWave ~= nil
            and token.consumedByWave < waveIndex

        if borrowedBeforeWave then
            token.displayBreathIndex = nil
            token.displayBreathLimit = effectiveLimit
        else
            displayIndex = displayIndex + 1
            token.displayBreathIndex = displayIndex
            token.displayBreathLimit = effectiveLimit
        end
    end

    return effectiveLimit
end

function Timeline:GetWaveTokenStats(waveIndex)
    local stats = {
        planned = 0,
        effective = 0,
        borrowedBefore = 0,
        consumedThisWave = 0,
        remaining = 0,
        expired = 0,
    }

    if not self.snapshot then
        return stats
    end

    for _, token in ipairs(self.snapshot.events) do
        if token.skillKey == "DREAM_BREATH" and token.waveIndex == waveIndex then
            stats.planned = stats.planned + 1

            local borrowedBeforeWave = token.consumed
                and token.consumedByWave ~= nil
                and token.consumedByWave < waveIndex

            if borrowedBeforeWave then
                stats.borrowedBefore = stats.borrowedBefore + 1
            else
                stats.effective = stats.effective + 1

                if token.expired then
                    stats.expired = stats.expired + 1
                elseif token.consumed then
                    stats.consumedThisWave = stats.consumedThisWave + 1
                else
                    stats.remaining = stats.remaining + 1
                end
            end
        end
    end

    return stats
end

function Timeline:ExpireDreamBreathTokensBeforeWave(waveIndex, reason)
    -- Compatibility hook: Stasis cannot retire the independent claim ledger.
    return 0
end

function Timeline:EnterActualWave(waveIndex)
    if not self.snapshot then
        return nil, nil
    end

    -- Stasis transitions never expire unclaimed Dream Breath slots.
    local effectiveLimit = self:RecalculateWaveDisplayQuota(waveIndex)
    local stats = self:GetWaveTokenStats(waveIndex)

    -- Re-render immediately because a borrowed future token can change 2/4 -> 1/3.
    local elapsed = self:GetElapsed()
    local entries = self:GetVisibleEntries(elapsed)
    self.visibleCount = #entries
    if EC.AlertUI and EC.AlertUI.Render then
        EC.AlertUI:Render(entries)
    end

    return effectiveLimit, stats
end

-- Every REAL released Dream Breath consumes the earliest still-available MRT token.
-- Selection uses the entire plan, independently of actual or planned Stasis.
function Timeline:ConsumeNextDreamBreathToken(actualWaveIndex, reason)
    local token = self:ReserveDreamBreath(actualWaveIndex)
    if not token then return nil, false end
    token.reserved = nil
    return self:ConsumeDreamBreathToken(token, actualWaveIndex, reason, false)
end

function Timeline:ReserveDreamBreath(waveIndex)
    if not self.active or not self.snapshot then return nil end
    local cast = EC.CastTracker
    if not cast or not cast.sessionActive or cast.snapshot ~= self.snapshot then return nil end
    -- One ordered ledger for the whole plan. Stasis and quota diagnostics do not
    -- decide whether a completed Dream Breath can claim a parsed personal slot.
    for _, token in ipairs(self.snapshot.events) do
        if token.skillKey == "DREAM_BREATH" and not token.consumed
            and not token.expired and not token.reserved and not token.reminderClosed then
            token.reserved = true
            return token
        end
    end
    return nil
end

-- Prepare is read-only. In particular, clock reads and quota arithmetic happen
-- before any token or CastTracker count is changed. Never select a fallback token.
function Timeline:PrepareDreamBreathTokenCommit(token, actualWave, reason, prepull, generation)
    if not self.active or not self.snapshot then return nil, "TOKEN_SNAPSHOT_UNAVAILABLE" end
    if type(token) ~= "table" or token.skillKey ~= "DREAM_BREATH"
        or token.consumed ~= false or token.expired ~= false
        or token.consumedByWave ~= nil or token.consumedAt ~= nil then
        return nil, "INVALID_TOKEN_STATE"
    end
    if generation ~= nil and (token.reserved ~= true or token.empowerGeneration ~= generation) then
        return nil, "EMPOWER_TOKEN_OWNER_MISMATCH"
    end
    if generation == nil and token.empowerGeneration ~= nil then return nil, "TOKEN_OWNED_BY_EMPOWER" end
    local found = false
    for _, event in ipairs(self.snapshot.events) do
        if event == token then found = true; break end
    end
    if not found then return nil, "TOKEN_OUTSIDE_SNAPSHOT" end
    local commit = { token = token, actualWave = actualWave, consumedAt = self:GetElapsed(),
        reason = reason or "实际绿喷", borrowed = token.waveIndex > actualWave, display = {} }
    if commit.borrowed then
        local effective, index = 0, 0
        for _, event in ipairs(self.snapshot.events) do
            if event.skillKey == "DREAM_BREATH" and event.waveIndex == token.waveIndex then
                local borrowed = event == token or (event.consumed and event.consumedByWave
                    and event.consumedByWave < event.waveIndex)
                if not borrowed then effective = effective + 1; index = index + 1 end
                commit.display[#commit.display + 1] = { token = event, index = not borrowed and index or nil }
            end
        end
        commit.effectiveLimit = effective
    end
    return commit
end

-- Internal to the synchronous prepare/commit boundary: plain state writes only.
-- The caller must finish its count/debt/empower writes BEFORE notifying anyone.
function Timeline:CommitDreamBreathToken(commit)
    local token = commit.token
    token.consumed = true
    token.reserved = nil
    token.empowerGeneration = nil
    token.dismissed = true
    token.reminderClosed = true
    token.consumedAt = commit.consumedAt
    token.consumedByWave = commit.actualWave
    token.consumptionReason = commit.reason
    token.earlyWarningActive = false
    for _, entry in ipairs(commit.display) do
        entry.token.displayBreathIndex = entry.index
        entry.token.displayBreathLimit = commit.effectiveLimit
    end
end

function Timeline:NotifyDreamBreathTokenCommit(commit)
    local token = commit.token
    local notify = EC.CastTracker.NotifyEmpowerEffect
    notify(function() if EC.Voice then EC.Voice:CancelOwner(token) end end)
    notify(function()
        EC:Log("消费绿喷 Token #%s：计划W%d %s，实际W%d，borrowed=%s reason=%s",
            tostring(token.tokenIndex), token.waveIndex, EC:FormatClock(token.time), commit.actualWave,
            tostring(commit.borrowed), token.consumptionReason)
    end)
    notify(self.RenderNow, self)
end

function Timeline:ConsumeDreamBreathToken(token, actualWave, reason, prepull)
    local commit = self:PrepareDreamBreathTokenCommit(token, actualWave, reason, prepull)
    if not commit then return nil, false end
    self:CommitDreamBreathToken(commit)
    self:NotifyDreamBreathTokenCommit(commit)
    return token, commit.borrowed
end

function Timeline:CloseReminder(event, reason, expire)
    if event.consumed then return end
    local changed = not event.reminderClosed
    event.reminderClosed = true
    event.closeReason = reason
    event.closedAt = self:GetElapsed()
    event.earlyWarningActive = false
    if expire then event.expired = true; event.expiredReason = reason end
    if self.earlyWarningToken == event then self.earlyWarningToken = nil end
    if EC.Voice then EC.Voice:CancelOwner(event) end
    if changed then
        EC:Log("提醒结束：id=%s token=%s W%d %s reason=%s（未伪造成功施法）",
            tostring(event.eventID), tostring(event.tokenIndex or "-"), event.waveIndex or 0,
            EC:FormatClock(event.time), tostring(reason))
    end
end

function Timeline:InvalidateRecord(reason, waveIndex, deferNotify)
    if not self.snapshot then return end
    local elapsed, closed = self:GetElapsed(), {}
    local wave = self.snapshot.waves[waveIndex or 0]
    if wave then wave.runtimeInvalid = reason or "UNCONFIRMED" end
    for _, event in ipairs(self.snapshot.events) do
        if event.skillKey == "DREAM_BREATH" then
            event.earlyWarningActive = false
            if event.waveIndex == waveIndex then event.quotaReliable = false end
        end
    end
    self.earlyWarningToken = nil
    self.earlyWarningCastGUID = nil
    self.earlyWarningCastBarID = nil
    if not deferNotify then self:NotifyRecordInvalidated(closed) end
    return closed
end

function Timeline:NotifyRecordInvalidated(closed)
    local notify = EC.CastTracker.NotifyEmpowerEffect
    for _, event in ipairs(self.snapshot and self.snapshot.events or {}) do
        if event.skillKey == "DREAM_BREATH" then
            notify(function() if EC.Voice then EC.Voice:CancelOwner(event, "CORRECTION") end end)
        end
    end
    for _, entry in ipairs(closed or {}) do
        local event = entry.token
        notify(function() if EC.Voice then EC.Voice:CancelOwner(event) end end)
        if entry.changed then
            notify(function()
                EC:Log("提醒结束：id=%s token=%s W%d %s reason=%s（未伪造成功施法）",
                    tostring(event.eventID), tostring(event.tokenIndex or "-"), event.waveIndex or 0,
                    EC:FormatClock(event.time), event.closeReason)
            end)
        end
    end
    notify(self.RenderNow, self)
end

-- A parsed slot states what was requested, without claiming no omitted cast exists.
function Timeline:CanTrackKnownSlot(event, elapsed)
    local cast = EC.CastTracker
    if not self.snapshot or not event or event.slotReliable ~= true
        or event.consumed or event.expired or event.dismissed or event.reminderClosed
        or not cast or not cast.sessionActive or cast.snapshot ~= self.snapshot then return false end
    if event.skillKey == "BALL" then return true end
    if event.skillKey ~= "DREAM_BREATH" then return false end
    return true -- Parsed personal Dream Breath slots remain claimable across Stasis boundaries.
end

function Timeline:GetKnownBreathSlot(elapsed)
    local chosen
    for _, event in ipairs(self.snapshot and self.snapshot.events or {}) do
        if event.skillKey == "DREAM_BREATH" and self:CanTrackKnownSlot(event, elapsed)
            and event.time <= elapsed + (EC.db.reminder.leadTime or 3) then
            if chosen then return nil end -- Never guess between two outstanding slots.
            chosen = event
        end
    end
    return chosen
end

function Timeline:CanCorrectEvent(event, elapsed)
    if not self.snapshot then return false end
    if not event or event.skillKey ~= "DREAM_BREATH" or event.quotaReliable ~= true
        or (event.waveIndex or 0) < 1 or event.reminderClosed or event.consumed or event.expired then return false end
    local wave = self.snapshot and self.snapshot.waves[event.waveIndex]
    local cast = EC.CastTracker
    return wave and wave.quotaReliable == true and not wave.runtimeInvalid
        and cast and cast.snapshot == self.snapshot and cast.quotaConfirmed and cast.tracking
        and cast.currentWaveIndex == event.waveIndex
        and (not wave.nextStasisTime or elapsed < wave.nextStasisTime) or false
end

function Timeline:GetTokenLedgerStatus()
    local status = {
        total = 0,
        consumed = 0,
        borrowed = 0,
        expired = 0,
        remaining = 0,
    }

    if not self.snapshot then
        return status
    end

    for _, token in ipairs(self.snapshot.events) do
        if token.skillKey == "DREAM_BREATH" then
            status.total = status.total + 1
            if token.expired then
                status.expired = status.expired + 1
            elseif token.consumed then
                status.consumed = status.consumed + 1
                if token.consumedByWave and token.consumedByWave < (token.waveIndex or 0) then
                    status.borrowed = status.borrowed + 1
                end
            else
                status.remaining = status.remaining + 1
            end
        end
    end

    return status
end

function Timeline:GetWaveEndTime(waveIndex)
    local wave = self.snapshot and self.snapshot.waves and self.snapshot.waves[tonumber(waveIndex) or 0]
    return wave and tonumber(wave.nextStasisTime) or nil
end

function Timeline:IsDreamBreathReminderWithinPlannedWave(event, elapsed)
    if not event or event.skillKey ~= "DREAM_BREATH" then return true end
    if (event.waveIndex or 0) < 1 then return false end
    local ending = self:GetWaveEndTime(event.waveIndex)
    return ending == nil or elapsed < ending
end

function Timeline:GetNextFutureDreamBreathToken(elapsed)
    if not self.snapshot then return nil end
    for _, event in ipairs(self.snapshot.events) do
        if self:CanCorrectEvent(event, elapsed or self:GetElapsed()) then return event end
    end
end

function Timeline:RenderNow()
    local elapsed = self:GetElapsed()
    local entries = self:GetVisibleEntries(elapsed)
    self.visibleCount = #entries
    if EC.AlertUI and EC.AlertUI.Render then
        EC.AlertUI:Render(entries)
    end
    return entries
end

-- Called by the real cast observer when Dream Breath empower START fires.  This is
-- reminder-only state: it does not increment the HUD counter or consume a token.
function Timeline:HandleDreamBreathEmpowerStart(castGUID, castBarID, token)
    if not self.active or not EC.state.dbReady or not EC.db.reminder.enabled or not token then return end
    local elapsed = self:GetElapsed()
    if not self:CanCorrectEvent(token, elapsed) then return end
    if self.earlyWarningToken then return self.earlyWarningToken end
    local remaining = token.time - elapsed
    if remaining + 0.0001 < (EC.db.reminder.earlyWarningThreshold or 10) then return end
    token.earlyWarningActive = true
    self.earlyWarningToken = token
    self.earlyWarningCastGUID, self.earlyWarningCastBarID = castGUID, castBarID
    EC:Log("绿喷提前警告：再等%.1fs token=%s W%d", remaining, tostring(token.tokenIndex), token.waveIndex)
    if EC.Voice then EC.Voice:PlaySpecial("EARLY", false, true, token) end
    self:RenderNow()
    return token
end

function Timeline:HandleDreamBreathEmpowerStop(castGUID, castBarID, complete)
    local token = self.earlyWarningToken
    if not token then
        return
    end

    token.earlyWarningActive = false
    if EC.Voice then EC.Voice:CancelOwner(token, "CORRECTION") end
    self.earlyWarningToken = nil
    self.earlyWarningCastGUID = nil
    self.earlyWarningCastBarID = nil

    EC:Log(
        "绿喷提前警告结束：complete=%s，计划W%d %s",
        tostring(complete),
        token.waveIndex or 0,
        EC:FormatClock(token.time or 0)
    )

    if self.active then
        self:RenderNow()
    end
end

-- Ball state is authoritative. Legacy flags below are projections for generic
-- timeline/UI consumers, never independent inputs to the ball state machine.
local BALL_TRANSITIONS = {
    WAITING = {WAITING=true, DUE=true, LATE=true, MISSED=true},
    DUE = {WAITING=true, DUE=true, LATE=true, CASTING=true, MISSED=true},
    LATE = {WAITING=true, DUE=true, LATE=true, CASTING=true, MISSED=true},
    CASTING = {DUE=true, DONE=true},
}
function Timeline:SetBallSlotState(event, state, reason)
    if EC.Features and not EC.Features:SkillEnabled("BALL") then return false end
    if event.ballState then
        local allowed = BALL_TRANSITIONS[event.ballState]
        if not allowed or not allowed[state] then return false end
    elseif state ~= "WAITING" then return false end
    event.ballState = state
    event.manualCastPending = state == "CASTING" or nil
    event.consumed = state == "DONE"
    event.dismissed = state == "DONE"
    event.expired = state == "MISSED"
    event.reminderClosed = state == "DONE" or state == "MISSED"
    if event.reminderClosed then event.closeReason = reason end
    return true
end

function Timeline:RefreshBallSlots(elapsed)
    if EC.Features and not EC.Features:SkillEnabled("BALL") then return end
    local lead, hold = EC.db.reminder.leadTime or 3, EC.db.reminder.postHold or 0.9
    local newest
    for _, event in ipairs(self.snapshot and self.snapshot.events or {}) do
        if event.skillKey == "BALL" and event.slotReliable == true then
            if not event.ballState then self:SetBallSlotState(event, "WAITING") end
            -- Even a completed newer slot closes the old slot's retry window.
            if event.time - lead <= elapsed and (not newest or event.time > newest) then newest = event.time end
        end
    end
    for _, event in ipairs(self.snapshot and self.snapshot.events or {}) do
        if event.skillKey == "BALL" and event.slotReliable == true
            and event.ballState ~= "CASTING" and event.ballState ~= "DONE" and event.ballState ~= "MISSED" then
            if newest and event.time < newest then
                self:SetBallSlotState(event, "MISSED", "下一条球的提前窗口已开启")
            elseif elapsed < event.time - lead then self:SetBallSlotState(event, "WAITING")
            elseif elapsed > event.time + hold then self:SetBallSlotState(event, "LATE")
            else self:SetBallSlotState(event, "DUE") end
        end
    end
end

-- Preserve the product rule: an unstarted old slot is superseded when a newer
-- time's lead window opens. CASTING keeps its owner. Among remaining candidates
-- take the earliest time, with snapshot order as the stable same-time tie break.
function Timeline:GetBallSlot(elapsed)
    if EC.Features and not EC.Features:SkillEnabled("BALL") then return nil, false end
    self:RefreshBallSlots(elapsed)
    local chosen, hasPlan
    for _, event in ipairs(self.snapshot and self.snapshot.events or {}) do
        if event.skillKey == "BALL" and event.slotReliable == true then
            hasPlan = true
            if (event.ballState == "DUE" or event.ballState == "LATE")
                and (not chosen or event.time < chosen.time) then chosen = event end
        end
    end
    return chosen, hasPlan
end

function Timeline:GetVisibleEntries(elapsed)
    local entries = {}
    if not self.snapshot then return entries end
    local lead, hold = EC.db.reminder.leadTime or 3, EC.db.reminder.postHold or 0.9
    self:RefreshBallSlots(elapsed)
    for _, event in ipairs(self.snapshot.events) do
        if not event.dismissed and not event.consumed and not event.expired and not event.reminderClosed then
            local remaining = event.time - elapsed
            local state
            if event.skillKey == "BALL" and self:CanTrackKnownSlot(event, elapsed) then
                if event.ballState == "CASTING" then state = "BALL_CASTING"
                elseif event.ballState == "LATE" then state = "BALL_LATE"
                elseif event.ballState == "DUE" then state = "NORMAL" end
            elseif event.earlyWarningActive and remaining > 0 and self:CanCorrectEvent(event, elapsed) then
                state = "EARLY"
            elseif event.manualCastPending and EC.CastTracker and EC.CastTracker:IsBallCastPending(event) then
                state = "NORMAL"
            elseif remaining <= lead and remaining >= -hold then
                state = "NORMAL"
            elseif remaining < -hold and self:CanTrackKnownSlot(event, elapsed) then state = "LATE" end
            if state then entries[#entries + 1] = { event = event, remaining = remaining, state = state } end
        end
    end
    return entries
end

function Timeline:DismissPlannedStasisWave(waveIndex, reason)
    if not self.active or not self.snapshot then
        return nil
    end

    for _, event in ipairs(self.snapshot.events) do
        if event.skillKey == "STASIS"
            and event.waveIndex == waveIndex
            and not event.dismissed
            and not event.consumed
            and not event.expired
        then
            event.dismissed = true
            event.closeReason = reason or "实际技能施放"
            if EC.Voice then EC.Voice:CancelOwner(event) end
            EC:Log(
                "移除对应静滞提醒：W%d，reason=%s，MRT 行=%s",
                waveIndex or 0,
                tostring(reason or "实际施放静滞"),
                tostring(event.lineNumber or "-")
            )
            self:RenderNow()
            return event
        end
    end

    return nil
end

function Timeline:DismissActiveEvent(skillKey, reason)
    if skillKey == "RELEASE_STASIS" or skillKey == "REWIND" then return nil end -- Timer-only cues.
    if skillKey == "BALL" then return nil end -- Only its matched START owner may finish a ball slot.
    if not self.active or not self.snapshot then
        return nil
    end

    local elapsed = self:GetElapsed()
    local leadTime = EC.db.reminder.leadTime or 3.0
    local postHold = EC.db.reminder.postHold or 0.9

    for _, event in ipairs(self.snapshot.events) do
        local remaining = event.time - elapsed
        if not event.dismissed
            and not event.consumed
            and not event.expired
            and event.skillKey == skillKey
            and remaining <= leadTime
            and remaining >= -postHold
        then
            event.dismissed = true
            event.closeReason = reason or "实际技能施放"
            if EC.Voice then EC.Voice:CancelOwner(event) end
            EC:Log(
                "移除当前提醒：%s，reason=%s，MRT 行=%s",
                tostring(skillKey),
                tostring(reason or "实际施放"),
                tostring(event.lineNumber or "-")
            )

            local entries = self:GetVisibleEntries(elapsed)
            self.visibleCount = #entries
            if EC.AlertUI and EC.AlertUI.Render then
                EC.AlertUI:Render(entries)
            end
            return event
        end
    end

    return nil
end

function Timeline:Update()
    if not self.active then return end
    if not EC.state.dbReady or not EC.db.enabled then self:Stop("插件已关闭"); return end
    local elapsed = self:GetElapsed()
    self.lastElapsed = elapsed
    if EC.CastTracker and EC.CastTracker.ballCast then EC.CastTracker:IsBallCastPending(EC.CastTracker.ballCast.event) end
    local lead, hold = EC.db.reminder.leadTime or 3, EC.db.reminder.postHold or 0.9
    self:RefreshBallSlots(elapsed)
    -- Ledger maintenance is never disabled by hiding the lower reminder module.
    for _, event in ipairs(self.snapshot and self.snapshot.events or {}) do
        if not event.consumed and not event.expired and not event.dismissed and not event.reminderClosed then
            local remaining = event.time - elapsed
            local wave = self.snapshot.waves[event.waveIndex or 0]
            if event.skillKey == "DREAM_BREATH" then
                -- Unclaimed Dream Breath slots stay pending until an actual completed cast.
            elseif event.skillKey == "BALL" and event.slotReliable == true then
                -- RefreshBallSlots owns all clock-driven ball transitions.
                -- CASTING is immune to postHold and newer planned windows.
            elseif remaining < -hold and not (EC.CastTracker and EC.CastTracker:IsBallCastPending(event)) then
                self:CloseReminder(event, "到点提醒窗口结束", true)
            end
        end
    end
    if EC.CastTracker and EC.CastTracker.sessionActive and EC.CastTracker.snapshot == self.snapshot then
        EC.CastTracker:RefreshQuotaReliability()
    end
    local enabled = EC.db.reminder.enabled and EC:CanShowGameplay(self.source == "DENSE_PREVIEW")
    if not enabled then
        self.visibleCount = 0
        if EC.AlertUI then EC.AlertUI:Render({}) end
        if EC.Voice then EC.Voice:Prune() end
    else
        local entries = self:GetVisibleEntries(elapsed)
        for _, entry in ipairs(entries) do
            local event, state = entry.event, entry.state
            if state == "NORMAL" and not event.diagnosticVisibleLogged then
                event.diagnosticVisibleLogged = true
                EC:Log("提醒进入窗口：elapsed=%.2f 计划=%s skill=%s W%d line=%s", elapsed,
                    EC:FormatClock(event.time), event.skillKey, event.waveIndex or 0, tostring(event.lineNumber or "-"))
                if EC.Voice and event.skillKey ~= "BALL" then event.voiceNormalPlayed = true; EC.Voice:PlaySkill(event.skillKey, false, event) end
            elseif state == "BALL_LATE" and not event.diagnosticLateLogged then
                event.diagnosticLateLogged = true
                EC:Log("溜溜球晚了：elapsed=%.2f plan=%.2f（尚无匹配成功回报）", elapsed, event.time)
            elseif state == "LATE" and not event.diagnosticLateLogged then
                event.diagnosticLateLogged = true
                EC:Log("绿喷提醒进入已晚：elapsed=%.2f 已晚=%.2f token=%s W%d line=%s", elapsed,
                    -entry.remaining, tostring(event.tokenIndex), event.waveIndex, tostring(event.lineNumber or "-"))
                if EC.Voice then event.voiceLatePlayed = true; EC.Voice:PlaySpecial("LATE", false, false, event) end
            end
        end
        self.visibleCount = #entries
        if EC.AlertUI then EC.AlertUI:Render(entries) end
        if EC.Voice then EC.Voice:Prune() end
    end
    if not IsLiveSource(self.source) and self.snapshot
        and elapsed > self.snapshot.lastEventTime + hold + 0.25
        and not (EC.CastTracker and EC.CastTracker.ballCast)
        and not (EC.CastTracker and EC.CastTracker.sessionActive and self:GetBallSlot(elapsed)) then self:Stop("测试时间轴结束") end
end

function Timeline:StartDensePreview()
    if EC.Runtime and EC.Runtime:IsEncounterRunning() then
        print("|cffffc857[奶龙打地鼠]|r 首领战进行中，不能启动或停止测试；不会改变本场记录。")
        return false
    end
    if EC.Runtime and not EC.Runtime:CanRun() then
        print("|cffffc857[奶龙打地鼠]|r 当前运行范围内不可预览，请先检查启用与区域限制。")
        return false
    end
    if self.active and IsLiveSource(self.source) then
        print("|cffffc857[奶龙打地鼠]|r 当前战斗提醒正在运行，战斗结束后再预览。")
        return false
    end

    local parser = EC.Parser
    if not parser then
        return false
    end

    local stasisDef = parser:GetSkillDefinition("STASIS")
    local breathDef = parser:GetSkillDefinition("DREAM_BREATH")

    local result = {
        ok = true,
        matchedPlayerName = "预览",
        waveQuotaText = "4",
        waves = {
            { index = 1, stasisTime = 3.0, nextStasisTime = nil, breathLimit = 4 },
        },
        events = {
            {
                time = 3.0, lineNumber = 1, sequence = 1,
                skillKey = "STASIS", skillName = "静滞",
                spellID = stasisDef and stasisDef.primaryID or 370537,
                texture = parser:GetSkillTexture("STASIS"),
                color = stasisDef and stasisDef.color or { 1.0, 0.76, 0.18 },
                waveIndex = 1,
            },
            {
                time = 3.0, lineNumber = 2, sequence = 2,
                skillKey = "DREAM_BREATH", skillName = "梦境吐息",
                spellID = breathDef and breathDef.primaryID or 355936,
                texture = parser:GetSkillTexture("DREAM_BREATH"),
                color = breathDef and breathDef.color or { 0.25, 1.0, 0.48 },
                waveIndex = 1, breathIndex = 1, breathLimit = 4,
            },
            {
                time = 4.0, lineNumber = 3, sequence = 3,
                skillKey = "DREAM_BREATH", skillName = "梦境吐息",
                spellID = breathDef and breathDef.primaryID or 355936,
                texture = parser:GetSkillTexture("DREAM_BREATH"),
                color = breathDef and breathDef.color or { 0.25, 1.0, 0.48 },
                waveIndex = 1, breathIndex = 2, breathLimit = 4,
            },
        },
    }

    return self:StartFromResult(result, "DENSE_PREVIEW", {})
end

function Timeline:StartCurrentMRTTest()
    if EC.Runtime and EC.Runtime:IsEncounterRunning() then
        print("|cffffc857[奶龙打地鼠]|r 首领战进行中，不能启动或停止测试；不会改变本场记录。")
        return false
    end
    if EC.Runtime and not EC.Runtime:IsZoneAllowed() then
        print("|cffffc857[奶龙打地鼠]|r 当前设置只允许在12.1团队副本中运行（烈毒之渊、潮缚石窟、基希克斯破封）。")
        return false
    end

    if EC.db and EC.db.runtime and EC.db.runtime.combatOnly
        and not (EC.Runtime and (EC.Runtime.combatActive or EC.Runtime.encounterActive))
    then
        print("|cffffc857[奶龙打地鼠]|r 请先在“概览”里关闭“仅战斗中显示”，再进行脱战测试。")
        return false
    end

    if self.active and IsLiveSource(self.source) then
        print("|cffffc857[奶龙打地鼠]|r 当前战斗提醒正在运行。")
        return false
    end

    EC:RefreshCurrentNote("测试前读取", true, false)
    local result = EC.state.result
    if not result or not result.ok then
        print("|cffffc857[奶龙打地鼠]|r 当前战术板没有识别到你的个人技能安排。")
        return false
    end

    local started = self:StartFromResult(result, "MRT_TEST", {})
    if started then
        print("|cff52d6a0[奶龙打地鼠]|r 已开始测试当前战术板。")
    end
    return started
end

function Timeline:StopTest()
    if EC.Runtime and EC.Runtime:IsEncounterRunning() then
        print("|cffffc857[奶龙打地鼠]|r 首领战进行中，不能启动或停止测试；不会改变本场记录。")
        return false
    end
    if self.active and IsLiveSource(self.source) then
        print("|cffffc857[奶龙打地鼠]|r 当前战斗提醒会在战斗结束后自动关闭。")
        return false
    end

    self:Stop("手动停止测试")
    return true
end

function Timeline:GetStatus()
    local ledger = self:GetTokenLedgerStatus()
    return {
        active = self.active,
        source = self.source,
        elapsed = self.active and self:GetElapsed() or 0,
        eventCount = self.snapshot and #self.snapshot.events or 0,
        visibleCount = self.visibleCount or 0,
        playerName = self.snapshot and self.snapshot.playerName or nil,
        waveQuotaText = self.snapshot and self.snapshot.waveQuotaText or nil,
        tokenTotal = ledger.total,
        tokenConsumed = ledger.consumed,
        tokenBorrowed = ledger.borrowed,
        tokenExpired = ledger.expired,
        tokenRemaining = ledger.remaining,
    }
end

function Timeline:GetDiagnosticLines()
    local status = self:GetStatus()
    return {
        "时间轴：" .. (status.active and "ACTIVE" or "IDLE"),
        "运行来源：" .. tostring(status.source or "-"),
        "运行时间：" .. string.format("%.1fs", status.elapsed or 0),
        "快照事件：" .. tostring(status.eventCount or 0),
        "当前提醒行：" .. tostring(status.visibleCount or 0),
        "快照角色：" .. tostring(status.playerName or "-"),
        "快照波次：" .. tostring(status.waveQuotaText or "-"),
        string.format(
            "绿喷Token：总%d / 已消费%d / 借用%d / 跳过%d / 剩余%d",
            status.tokenTotal or 0,
            status.tokenConsumed or 0,
            status.tokenBorrowed or 0,
            status.tokenExpired or 0,
            status.tokenRemaining or 0
        ),
        "实际施法记录：" .. tostring(EC.CastTracker and EC.CastTracker.sessionActive and "ACTIVE" or "IDLE"),
    }
end

function Timeline:Initialize()
    if self.initialized then
        return
    end

    self.initialized = true
    self.driver = CreateFrame("Frame")
    self.driver:Hide()
    self.driver:SetScript("OnUpdate", function(_, elapsed)
        Timeline.updateAccumulator = Timeline.updateAccumulator + elapsed
        if Timeline.updateAccumulator < 0.05 then
            return
        end
        Timeline.updateAccumulator = 0
        if EC.Diagnostics and EC.Diagnostics.Run then EC.Diagnostics:Run("时间轴更新", Timeline.Update, Timeline)
        else Timeline:Update() end
    end)
end
