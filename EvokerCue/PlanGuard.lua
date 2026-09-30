local addonName, EC = ...

-- Validation never invents Stasis entries or changes MRT wave numbers.
local Guard = {}
EC.PlanGuard = Guard
Guard.MATCH_TOLERANCE = 20.0
Guard.OPENING_TIME_MAX = 15.0
Guard.OPENING_BREATH_MAX = 15.0
Guard.noticeKeys = {}
Guard.noticeScope = "LOGIN"

local function Clock(t) return EC:FormatClock(tonumber(t) or 0) end

function Guard:BeginScope(scope)
    self.noticeScope = tostring(scope or "LOGIN")
    self.noticeKeys = {}
end

function Guard:Warn(key, text)
    if not EC.state.dbReady or not EC.db.enabled then return false end
    if EC.Runtime and not EC.Runtime:IsZoneAllowed() then return false end
    key = tostring(key or text)
    if self.noticeKeys[key] then return false end
    self.noticeKeys[key] = true
    print("|cffffc857[奶龙打地鼠]|r " .. text)
    EC:Log("CHAT_WARNING：%s，%s", key, text)
    return true
end

function Guard:Validate(result)
    local issues = {}
    result.planIssues = issues
    result.orphanBreathCount = 0
    result.openingReleaseMissing = false
    local function Issue(code, text, wave, event)
        local item = { code = code, text = text, waveIndex = wave and wave.index,
            lineNumber = event and event.lineNumber, time = event and event.time,
            segmentIndex = event and event.segmentIndex }
        issues[#issues + 1] = item
        result.warnings[#result.warnings + 1] = text
    end

    for _, item in ipairs(result.parseIssues or {}) do
        Issue(item.code, item.text, nil, item)
    end

    -- The aura lifecycle is independent of resource waves. Release closes this
    -- pairing only; breaths after release still belong to the same resource wave.
    local openStasis
    for _, event in ipairs(result.events or {}) do
        local wave = (result.waves or {})[event.waveIndex or 0]
        if event.skillKey == "STASIS" then
            if openStasis then
                Issue("NEW_STASIS_WITH_OPEN_STASIS", string.format(
                    "%s（第 %d 行）安排了新的静滞，但前一次静滞（第 %d 行）没有对应释放。请核对静滞生命周期。",
                    Clock(event.time), event.lineNumber or 0, openStasis.lineNumber or 0), wave, event)
            end
            openStasis = event
        elseif event.skillKey == "RELEASE_STASIS" then
            if openStasis then
                openStasis = nil
            elseif (event.waveIndex or 0) == 0 then
                result.openingReleaseMissing = true
                Issue("OPENING_RELEASE_WITHOUT_STASIS", string.format(
                    "开场有释放静滞安排，但是缺少对应静滞（%s，第 %d 行）。请补上开场静滞与预铺绿喷；该段仅保留到点提醒，配额纠错已暂停。",
                    Clock(event.time), event.lineNumber or 0), nil, event)
            else
                Issue("RELEASE_WITHOUT_STASIS", string.format(
                    "%s（第 %d 行）安排了释放静滞，但前面没有尚未释放的静滞。请检查是否重复释放或遗漏静滞。",
                    Clock(event.time), event.lineNumber or 0), wave, event)
            end
        elseif event.skillKey == "DREAM_BREATH" and (event.waveIndex or 0) == 0 then
            result.orphanBreathCount = result.orphanBreathCount + 1
        end
    end
    -- A trailing open Stasis or standalone pre-Stasis breath can be intentional.
    -- Do not infer missing events or reject such a truncated plan.

    for i, wave in ipairs(result.waves or {}) do
        wave.mappingReliable = true
        wave.quotaReliable = (wave.breathLimit or 0) > 0
        wave.invalidReason = nil
        local prev, nextWave = result.waves[i - 1], result.waves[i + 1]
        if (prev and math.abs(wave.stasisTime - prev.stasisTime) < 0.001)
            or (nextWave and math.abs(wave.stasisTime - nextWave.stasisTime) < 0.001) then
            wave.mappingReliable = false
            wave.quotaReliable = false
            wave.invalidReason = "DUPLICATE_STASIS"
            if not prev or math.abs(wave.stasisTime - prev.stasisTime) >= 0.001 then
                Issue("DUPLICATE_STASIS", string.format(
                    "%s 有重复静滞安排，相关波次的配额未确认。请检查重复行。", Clock(wave.stasisTime)), wave)
            end
        elseif not wave.quotaReliable then
            wave.invalidReason = "NO_BREATH_QUOTA"
            Issue("NO_BREATH_QUOTA", string.format(
                "W%d（%s）有静滞，但没有梦境吐息安排；本波只记录实际次数，暂不进行配额纠错。",
                wave.index, Clock(wave.stasisTime)), wave)
        end
    end
    for _, event in ipairs(result.events or {}) do
        local wave = (result.waves or {})[event.waveIndex or 0]
        event.quotaReliable = wave ~= nil and wave.quotaReliable == true
    end
    result.quotaAvailable = false
    for _, wave in ipairs(result.waves or {}) do
        if wave.quotaReliable then result.quotaAvailable = true; break end
    end
    -- Whole-board state is diagnostic only. Absence authority belongs to a
    -- skill domain; Stasis boundaries additionally govern Breath quota scopes.
    local domains = result.integrity and result.integrity.domains or {}
    result.absenceAllowed = {}
    for key, domain in pairs(domains) do result.absenceAllowed[key] = domain.state == "COMPLETE" end
    local function AffectsWave(domain, wave)
        if not domain then return true end
        for _, candidate in ipairs(domain.candidates) do
            if not candidate.time or (candidate.time >= wave.stasisTime
                and (not wave.nextStasisTime or candidate.time < wave.nextStasisTime)) then return true end
        end
        return false
    end
    result.quotaAvailable = false
    for _, wave in ipairs(result.waves or {}) do
        if AffectsWave(domains.DREAM_BREATH, wave) or AffectsWave(domains.STASIS, wave)
            or AffectsWave(domains.RELEASE_STASIS, wave) then
            wave.quotaReliable = false; wave.invalidReason = "DOMAIN_INCOMPLETE"
        end
        for _, issue in ipairs(issues) do
            if issue.code == "NEW_STASIS_WITH_OPEN_STASIS" or issue.code == "RELEASE_WITHOUT_STASIS" then
                if issue.waveIndex == wave.index or (issue.code == "NEW_STASIS_WITH_OPEN_STASIS" and issue.waveIndex == wave.index + 1) then
                    wave.quotaReliable = false; wave.invalidReason = issue.code
                end
            end
        end
        if wave.quotaReliable then result.quotaAvailable = true end
    end
    for _, event in ipairs(result.events or {}) do
        local wave = (result.waves or {})[event.waveIndex or 0]
        event.quotaReliable = wave ~= nil and wave.quotaReliable == true
    end
    result.negativeCorrectionAllowed = next(domains) ~= nil
    for _, allowed in pairs(result.absenceAllowed) do
        if not allowed then result.negativeCorrectionAllowed = false end
    end
    result.integrityReason = not result.negativeCorrectionAllowed and "DOMAIN_INCOMPLETE" or nil
    if not result.negativeCorrectionAllowed and #(result.events or {}) > 0 then
        Issue("PLAN_INCOMPLETE", "部分技能安排完整性未确认：保留可靠计划项的到点与迟到状态，仅暂停受影响范围的提前、超额和取消施法纠错。")
    end
    return result
end

function Guard:AnnouncePlan(result, noteHash, fromBoss)
    if not result then return end
    -- A different board/name gets a fresh warning, not one warning per polling tick.
    local signature = tostring(noteHash or "") .. ":" .. tostring(result.matchedPlayerName or "")
    if self.lastPlanSignature ~= signature then
        self.lastPlanSignature = signature
        self:BeginScope(self.noticeScope)
    end
    local count = 0
    for _, issue in ipairs(result.planIssues or {}) do
        if count < 3 then
            self:Warn("PLAN:" .. issue.code .. ":" .. tostring(issue.waveIndex or 0)
                .. ":" .. tostring(issue.lineNumber or 0) .. ":" .. tostring(issue.segmentIndex or 0), issue.text)
        end
        count = count + 1
    end
    if count > 3 then
        self:Warn("PLAN:MORE", "另有 " .. (count - 3) .. " 处战术板问题，已写入反馈日志；请核对静滞与绿喷安排。")
    end
    if fromBoss and (not result.ok or #(result.events or {}) == 0) then
        self:Warn("PLAN:EMPTY", "没有读取到当前角色的有效 MRT 技能轴。本场先记录实际施法，配额未确认；请检查当前战术板与角色名。")
    end
end

function Guard:FindWave(snapshot, elapsed, claimed)
    local matches = {}
    for i, wave in ipairs(snapshot and snapshot.waves or {}) do
        if wave.mappingReliable ~= false
            and math.abs(elapsed - wave.stasisTime) <= self.MATCH_TOLERANCE then
            matches[#matches + 1] = { index = i, time = wave.stasisTime,
                distance = math.abs(elapsed - wave.stasisTime) }
        end
    end
    -- A previously claimed match does not make a nearby second match less ambiguous.
    if #matches == 0 then return nil, nil, nil, "OUT_OF_WINDOW" end
    if #matches ~= 1 then return nil, nil, nil, "AMBIGUOUS" end
    local item = matches[1]
    if claimed and claimed[item.index] then return nil, item.time, item.distance, "ALREADY_CLAIMED" end
    return item.index, item.time, item.distance
end

function Guard:FindOpeningWave(snapshot, breathCount, ongoing)
    local wave = snapshot and snapshot.waves and snapshot.waves[1]
    if not wave or wave.mappingReliable == false or wave.stasisTime < 0
        or wave.stasisTime > self.OPENING_TIME_MAX then
        return nil, "NO_OPENING_STASIS"
    end
    for _, event in ipairs(snapshot.events or {}) do
        if (event.waveIndex or 0) == 0 and
            (event.skillKey == "RELEASE_STASIS" or event.skillKey == "DREAM_BREATH") then
            return nil, "OPENING_CONFLICT"
        end
    end
    if wave.quotaReliable == false or (wave.breathLimit or 0) == 0 then
        return 1, "NO_OPENING_QUOTA"
    end
    local openingTokens = {}
    for _, event in ipairs(snapshot.events or {}) do
        if event.skillKey == "DREAM_BREATH" and event.waveIndex == 1
            and event.time <= self.OPENING_BREATH_MAX then
            openingTokens[#openingTokens + 1] = event
        end
    end
    if #openingTokens < (breathCount or 0) + (ongoing and 1 or 0) then
        return 1, "MISSING_OPENING_BREATHS"
    end
    return 1, nil, openingTokens
end
