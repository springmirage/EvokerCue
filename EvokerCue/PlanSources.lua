local addonName, EC = ...

-- Read-only adapters. Never call another addon's import/migration/selection setters.
local Sources = { registered = {} }
EC.PlanSources = Sources
local ADDONS = {
    MRT_RAID = "MRT", MRT_SELF = "MRT", MRT_BOTH = "MRT",
    NSRT = "NorthernSkyRaidTools", DFT = "DreamForgeTools",
}
local SOURCE_LABELS = {
    RAIDARY = "Raidary Plan（专属战术板）",
    MRT_RAID = "MRT当前方案（团队）",
    MRT_SELF = "MRT个人方案（个人）",
    MRT_BOTH = "MRT两者（团队+个人）",
    NSRT = "NSRT",
    DFT = "DFT",
}
local MRT_MODES = { MRT_RAID = "raid", MRT_SELF = "self", MRT_BOTH = "both" }
local function Trim(s) return type(s) == "string" and (s:match("^%s*(.-)%s*$") or "") or "" end
local function List(t) return type(t) == "table" and t or {} end
local function Finite(n) return type(n) == "number" and n == n and n > -math.huge and n < math.huge end
local function Clean(s) return EC.Parser.StripMarkup(s) end
local function Issue(info, code, text, line)
    info.issues[#info.issues + 1] = { code = code, text = text, lineNumber = line }
end
local function Emit(lines, info, at, owner, skill, origin)
    if not Finite(at) or at < 0 then
        Issue(info, "SOURCE_TIME_UNSUPPORTED", "来源安排时间无效或位于开怪前，已跳过：" .. tostring(origin))
        return
    end
    if Trim(owner) == "" or Trim(skill) == "" then return end
    local minutes = math.floor(at / 60)
    lines[#lines + 1] = string.format("{time:%d:%06.3f} %s %s", minutes, at - minutes * 60, owner, skill)
    info.origins[(info.lineOffset or 0) + #lines] = origin
end
function Sources:GetSelected()
    local source = EC.db and EC.db.timeline and EC.db.timeline.planSource or "MRT_RAID"
    if source == "MRT" then source = "MRT_RAID" end
    if not SOURCE_LABELS[source] then source = "MRT_RAID" end
    return source
end
function Sources:GetLabel(source)
    source = source or self:GetSelected()
    if source == "MRT" then source = "MRT_RAID" end
    return SOURCE_LABELS[source] or tostring(source or "-")
end
function Sources:GetSelectedLabel()
    return self:GetLabel(self:GetSelected())
end
function Sources:IsMRTSource(source)
    return MRT_MODES[source == "MRT" and "MRT_RAID" or source] ~= nil
end
function Sources:SetSelected(source)
    if source == "MRT" then source = "MRT_RAID" end
    if not SOURCE_LABELS[source] then return false end
    EC.db.timeline.planSource = source
    EC:RefreshCurrentNote("战术板来源设置", true, false)
    return true
end
local function MyName(identity)
    return identity.candidates and identity.candidates[1] and identity.candidates[1].value or ""
end
local function MatchesName(value, identity)
    value = Clean(value):lower()
    for _, c in ipairs(identity.candidates or {}) do
        if value == Clean(c.value):lower() then return true end
    end
    return false
end
local function Subgroup()
    if IsInRaid and IsInRaid() and GetRaidRosterInfo and UnitIsUnit then
        for i = 1, (GetNumGroupMembers and GetNumGroupMembers() or 40) do
            if UnitIsUnit("raid" .. i, "player") then return select(3, GetRaidRosterInfo(i)) or 1 end
        end
    end
    return 1
end
local function SpecID()
    local api = C_SpecializationInfo
    local index = api and api.GetSpecialization and api.GetSpecialization() or (GetSpecialization and GetSpecialization())
    local getter = api and api.GetSpecializationInfo or GetSpecializationInfo
    return index and getter and getter(index) or nil
end
local function NSMatches(tag, identity, nsi)
    local game = identity.game or {}
    local classID = UnitClass and select(3, UnitClass("player"))
    local spec = SpecID()
    local nickname
    if NSAPI and type(NSAPI.GetName) == "function" then
        local ok, name = pcall(NSAPI.GetName, NSAPI, "player", "GlobalNickNames")
        if ok then nickname = Clean(name):lower() end
    end
    tag = Clean(tag):lower()
    -- NSRT treats everyone as a whole-tag selector, and other tokens as OR.
    if tag == "everyone" then return not (NSRT and NSRT.ReminderSettings and NSRT.ReminderSettings.IgnoreEveryone) end
    for token in tag:gmatch("%S+") do
        if MatchesName(token, identity) or (nickname and token == nickname)
            or token == tostring(game.role or ""):lower()
            or (classID and token == tostring(classID)) or (spec and token == tostring(spec))
            or token == "group" .. Subgroup()
            or (token == "ranged" and game.classFile == "EVOKER" and game.role ~= "TANK")
            or (token == "melee" and (game.role == "TANK" or (nsi.meleetable and nsi.meleetable[spec]))) then return true end
    end
    return false
end
function Sources:NormalizeNSRT(raw, identity, info, nsi, context)
    local lines, encounter, difficulty, seen = {}, nil, "Mythic", {}
    local index = 0
    for line in (raw .. "\n"):gmatch("(.-)\n") do
        index = index + 1
        local enc = line:match("EncounterID:(%d+)")
        if enc then encounter = tonumber(enc); difficulty = Trim(line:match("Difficulty:([^;\r\n]+)") or "Mythic") end
        local time = tonumber(line:match("time:(%d*%.?%d+)"))
        local tag = line:match("tag:([^;]+)")
        if not enc and not line:match("assign:([^;]+)") and time and tag and NSMatches(tag, identity, nsi) then
            local phase = tonumber(line:match("ph:(%d*%.?%d+)")) or 1
            local offset = phase == 1 and 0 or nil
            if phase ~= 1 then
                -- Validate existence first: NSRT's GetPhaseStart returns 0 for unknown phases.
                local timeline
                if type(nsi.GetBossTimeline) == "function" then
                    local ok, data = pcall(nsi.GetBossTimeline, nsi, encounter, difficulty)
                    if ok then timeline = data end
                end
                if timeline and timeline.phases and timeline.phases[phase] and type(nsi.GetPhaseStart) == "function" then
                    local ok, value = pcall(nsi.GetPhaseStart, nsi, encounter, phase, difficulty)
                    if ok and Finite(value) then offset = value end
                end
            end
            if context and context.encounterID and encounter and context.encounterID ~= encounter then
                Issue(info, "SOURCE_ENCOUNTER_MISMATCH", "NSRT 当前战术板的首领与本场不一致，已跳过。", index)
            elseif offset == nil then
                Issue(info, "SOURCE_PHASE_UNRESOLVED", "NSRT 第 " .. index .. " 行缺少阶段起点，已跳过。", index)
            else
                local id = line:match("spellid:(%d+)")
                -- spellid is the assignment; text beside it is a display caption.
                local caption = line:match("text:([^;]+)")
                local skill = id and ("{spell:" .. id .. "}") or caption
                -- NSRT deduplicates identical shared/personal assignments by this
                -- tuple. Preserve distinct owners/text entries at the same time.
                local stamp = table.concat({ tostring(encounter), tostring(phase),
                    line:match("time:(%d*%.?%d+)"), tag, caption or id or "" }, "\031")
                if not seen[stamp] then
                    seen[stamp] = true
                    Emit(lines, info, time + offset, MyName(identity), skill or "", "NSRT:" .. index)
                end
            end
        end
    end
    return table.concat(lines, "\n")
end
local function DFTTarget(note, identity, runtime)
    local mod = runtime.moduleMap and runtime.moduleMap.Timeline
    -- This getter was audited: only tests player selectors; no writes or scheduling.
    if mod and type(mod.NoteFiresForMe) == "function" then
        local ok, value = pcall(mod.NoteFiresForMe, mod, note)
        if ok then return value == true end
    end
    if type(note.target) ~= "table" or #note.target == 0 then return true end
    local game = identity.game or {}
    for _, target in ipairs(note.target) do
        local value = tostring(target.value or ""):lower()
        if target.type == "all"
            or (target.type == "class" and value == tostring(game.classFile):lower())
            or (target.type == "role" and value == tostring(game.role):lower())
            or (target.type == "group" and tonumber(value) == Subgroup())
            or (target.type == "position" and value == "ranged" and game.classFile == "EVOKER") then return true end
    end
    return false
end
function Sources:NormalizeDFT(board, identity, info, runtime, boardID)
    local lines, players, phases = {}, {}, {}
    for _, p in ipairs(List(board.players)) do if p.id then players[p.id] = p end end
    for _, p in ipairs(List(board.phases)) do phases[p.phaseNumber] = p.phaseTimer end
    local function Add(item, owner, skill, origin)
        local phase = tonumber(item.phaseNumber) or 1
        local offset = phases[phase]
        if offset == nil and phase == 1 then offset = 0 end
        if item.condition and next(List(item.condition)) then
            Issue(info, "SOURCE_CONDITION_UNSUPPORTED", "DFT 条件节点无法转换为固定时间，已跳过：" .. origin)
        elseif not Finite(offset) then
            Issue(info, "SOURCE_PHASE_UNRESOLVED", "DFT 缺少阶段起点，已跳过：" .. origin)
        else
            local relative = tonumber(item.time) or 0
            Emit(lines, info, relative + offset, owner, skill, origin)
        end
    end
    local function Owner(player)
        if not player then return nil end
        local name = player.name or ""
        if MatchesName(name, identity) or MatchesName(name .. "-" .. (player.server or ""), identity) then return MyName(identity) end
        local nick = runtime.Nick
        if nick and type(nick.GetByName) == "function" then
            local ok, value = pcall(nick.GetByName, nick, name)
            if ok and MatchesName(value, identity) then return MyName(identity) end
        end
    end
    for i, item in ipairs(List(board.playerAbilities)) do
        local owner = Owner(players[item.playerId])
        local id = tostring(item.abilityId or ""):match("_(%d+)$")
        if owner and id then Add(item, owner, "{spell:" .. id .. "}", tostring(boardID) .. ":playerAbilities:" .. i) end
    end
    -- Iterate player order, never pairs() order, to keep normalized hashes stable.
    for _, player in ipairs(List(board.players)) do
        local owner = Owner(player)
        if owner then
            for i, item in ipairs(List(List(board.playerNotes)[player.id])) do
                Add(item, owner, item.text or "", tostring(boardID) .. ":playerNotes:" .. tostring(player.id) .. ":" .. i)
            end
        end
    end
    for i, item in ipairs(List(board.bossNotes)) do
        if DFTTarget(item, identity, runtime) then Add(item, MyName(identity), item.text or "", tostring(boardID) .. ":bossNotes:" .. i) end
    end
    return table.concat(lines, "\n")
end
function Sources:ReadDFT(identity, info, context)
    local runtime = type(DFT) == "table" and DFT[1]
    if type(runtime) ~= "table" then return "" end
    info.available, info.namespace = true, "DFT[1]"
    local mod = runtime.moduleMap and runtime.moduleMap.Timeline
    local db = mod and mod.db
    local window = runtime.TimelineWindow
    local encounter = context and context.encounterID
    local difficulty = context and context.difficultyID
    local diff = ({ [14] = "N", [15] = "H", [16] = "M", [17] = "LFR", [233] = "M" })[difficulty]
    local boards, ids = {}, {}
    if encounter then
        -- Reconstruct the selected loaded plan without ResolveLoaded/GetLoadedIds:
        -- those functions can import daemon data and migrate SavedVariables.
        local slot = db and List(db.loadedBoards)[tostring(encounter) .. "_" .. tostring(diff)]
        local selected = slot and (slot.boardIds or (slot.boardId and { slot.boardId }))
        for _, id in ipairs(List(selected)) do
            local entry = List(db.boards)[id]
            if type(entry) ~= "table" or type(entry.data) ~= "table" then
                info.status = "UNREADABLE_SELECTION"
                info.statusText = "DFT 已选方案尚未载入公开数据，请先在 DFT 打开该方案"
                return ""
            end
            boards[#boards + 1], ids[#ids + 1] = entry.data, id
        end
    elseif window and type(window.currentBoard) == "table" then
        boards[1], ids[1] = window.currentBoard, window.currentBoardId or "current"
    end
    if #boards == 0 then
        info.status, info.statusText = "NO_CURRENT_BOARD", "未检测到可读取的当前战术板" .. (encounter and "（本场首领未载入方案）" or "（请在 DFT 打开方案）")
        return ""
    end
    local texts = {}
    for i, board in ipairs(boards) do
        info.lineOffset = #info.origins
        local normalized = self:NormalizeDFT(board, identity, info, runtime, ids[i])
        if normalized ~= "" then texts[#texts + 1] = normalized end
    end
    info.lineOffset = nil
    info.selection = table.concat(ids, ",")
    return table.concat(texts, "\n")
end
function Sources:ReadCurrentNote(identity, context)
    identity = identity or EC:GetPlayerIdentity()
    local source = self:GetSelected()
    local info = { source = source, available = false, issues = {}, origins = {} }
    local text = ""
    if source == "RAIDARY" then
        local plan
        text, plan = EC.RaidaryPlan:Resolve(context)
        info.inputCoverage = type(text) == "string"
        info.selection = tostring(plan.id)
        info.available, info.namespace = true, "EvokerCueDB.raidaryPlan"
    elseif self:IsMRTSource(source) then
        text, info = EC.MRTReader:GetCurrentNote(MRT_MODES[source])
        info.source, info.issues, info.origins = source, {}, {}
    elseif source == "NSRT" and type(NorthernSkyRaidTools) == "table" then
        local nsi, raw = NorthernSkyRaidTools, {}
        info.available, info.namespace = true, "NorthernSkyRaidTools"
        if type(nsi.Reminder) == "string" then raw[#raw + 1] = nsi.Reminder end
        local personal = nsi.PersonalReminder
        local usePersonal = NSRT and NSRT.ReminderSettings and NSRT.ReminderSettings.PersNote
        if context and context.encounterID and NSRT and type(nsi.GetProfileKey) == "function" then
            -- NSRT loads its selected personal note during ENCOUNTER_START.
            -- Resolve the same selection without depending on addon event order.
            -- Do NOT call GetActivePersonalReminders: it creates a saved table.
            local ok, char = pcall(nsi.GetProfileKey, nsi)
            local selected = ok and char and List(List(NSRT.ActivePersonalReminder)[char])[context.encounterID]
            local current = selected and List(NSRT.PersonalReminders)[selected]
            if type(current) == "string" then personal, usePersonal = current, true end
        end
        if usePersonal and type(personal) == "string" then
            raw[#raw + 1] = personal
        end
        info.rawText = table.concat(raw, "\n")
        text = self:NormalizeNSRT(info.rawText, identity, info, nsi, context)
    elseif source == "DFT" then text = self:ReadDFT(identity, info, context) end
    if not info.status then
        info.status = not info.available and "ADDON_UNAVAILABLE" or (text == "" and "EMPTY" or "READ")
        info.statusText = not info.available and "插件未安装或未加载" or (text == "" and "当前战术板为空或无本人安排" or "已读取")
        if not info.available and C_AddOns and C_AddOns.GetAddOnMetadata and ADDONS[source] then
            local ok, title = pcall(C_AddOns.GetAddOnMetadata, ADDONS[source], "Title")
            info.statusText = ok and title and "插件已安装但未加载" or "未安装对应插件"
        end
    end
    if #info.issues > 0 then info.statusText = info.statusText .. "；" .. #info.issues .. " 处来源安排被跳过" end
    return text, info
end
function Sources:GetCurrentNote(identity, context)
    local ok, text, info = pcall(self.ReadCurrentNote, self, identity, context)
    if ok then return text, info end
    return "", { source = self:GetSelected(), available = false, status = "READ_ERROR",
        statusText = "当前战术板数据无法读取，请检查来源插件与数据格式", origins = {},
        issues = { { code = "SOURCE_READ_ERROR", text = "战术板只读适配失败：" .. tostring(text) } } }
end
function Sources:HashText(text, info)
    local extra = {}
    for _, issue in ipairs(info.issues or {}) do extra[#extra + 1] = issue.code .. ":" .. tostring(issue.lineNumber) .. ":" .. issue.text end
    return EC.MRTReader:HashText(text .. "\n" .. info.source .. ":" .. tostring(info.status) .. ":" .. tostring(info.selection)
        .. ":" .. tostring(info.raidLineCount) .. ":" .. tostring(info.inputCoverage)
        .. table.concat(extra, "|") .. EC.Parser:GetAliasSignature())
end
function Sources:BuildResult(text, identity, info)
    local mergeBoundary = info.source == "MRT_BOTH" and info.raidLineCount or nil
    local result = EC.Parser:BuildResult(text, identity, info.issues, mergeBoundary)
    result.source = info.source
    result.sourceStatus = info.statusText
    -- A normalized string cannot prove that its adapter did not silently drop
    -- raw nodes. Only verbatim sources currently provide whole-input coverage.
    local verbatim = (info.source == "RAIDARY" or MRT_MODES[info.source] ~= nil) and info.inputCoverage == true
    if result.integrity then
        result.integrity.textState = result.integrity.state
        result.integrity.sourceState = verbatim and info.available and "VERBATIM" or "UNKNOWN"
    end
    -- An unresolved source node can be a missing Stasis or breath. Keep valid
    -- reminders, but never turn a partially imported plan into a smaller quota.
    if #(info.issues or {}) > 0 or not info.available or not verbatim then
        result.negativeCorrectionAllowed = false
        for key in pairs(result.absenceAllowed or {}) do
            result.absenceAllowed[key] = false
            if result.integrity.domains[key] then result.integrity.domains[key].state = "UNKNOWN" end
        end
        result.integrityReason = #(info.issues or {}) > 0 and "SOURCE_INCOMPLETE" or "SOURCE_COVERAGE_UNKNOWN"
        if result.integrity then result.integrity.state = #(info.issues or {}) > 0 and "PARTIAL" or "UNKNOWN" end
        if #result.events > 0 then result.warnings[#result.warnings+1] = "来源未提供完整输入覆盖证据：保留可靠计划项状态，暂停基于缺少安排的纠错。" end
        result.quotaAvailable = false
        for _, wave in ipairs(result.waves) do wave.quotaReliable = false; wave.invalidReason = "SOURCE_INCOMPLETE" end
        for _, event in ipairs(result.events) do event.quotaReliable = false end
    end
    for _, event in ipairs(result.events) do event.sourceOrigin = info.origins[event.lineNumber] end
    if not info.available or (text == "" and info.status ~= "READ") then result.statusText = info.statusText end
    return result
end
function Sources:OnUpdate(source)
    if source ~= self:GetSelected() or not EC.state.dbReady or not EC.db.autoRefresh then return end
    if (EC.Runtime and EC.Runtime.encounterActive) or (InCombatLockdown and InCombatLockdown()) then return end
    EC:RefreshCurrentNote(source .. " 战术板更新", false, false)
end
function Sources:TryCallbacks()
    local nsi = NorthernSkyRaidTools
    if not self.registered.NSRT and type(nsi) == "table" and type(nsi.RegisterCallback) == "function" then
        self.registered.NSRT = pcall(nsi.RegisterCallback, self, "NSRT_REMINDER_CHANGED", function() pcall(Sources.OnUpdate, Sources, "NSRT") end)
    end
    local runtime = type(DFT) == "table" and DFT[1]
    if not self.registered.DFT and type(runtime) == "table" and type(runtime.On) == "function" then
        self.registered.DFT = true
        for _, event in ipairs({ "DFT_BOARD_OPENED", "DFT_BOARDS_CHANGED", "TIMELINE_BOARD_CONTENT_CHANGED", "TACTICS_BOARD_CONTEXT_CHANGED" }) do
            runtime:On(event, function() pcall(Sources.OnUpdate, Sources, "DFT") end)
        end
    end
end
function Sources:Initialize()
    if self.ticker then return end
    self:TryCallbacks()
    -- Also catches direct edits/phase timings lacking notifications; never per-frame.
    self.ticker = C_Timer.NewTicker(1, function()
        self:TryCallbacks()
        self:OnUpdate(self:GetSelected())
    end)
    EC.MRTReader:TryHookNoteFrame()
    EC.MRTReader:StartHookRetries()
end
