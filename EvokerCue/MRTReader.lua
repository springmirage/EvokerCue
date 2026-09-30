local addonName, EC = ...

local MRTReader = {}
EC.MRTReader = MRTReader

MRTReader.initialized = false
MRTReader.noteHooked = false
MRTReader.pollTicker = nil
MRTReader.hookRetryTicker = nil

function MRTReader:GetMRT()
    if type(_G.VMRT) == "table" then
        return _G.VMRT, "VMRT"
    end

    if type(_G.VExRT) == "table" then
        return _G.VExRT, "VExRT"
    end

    return nil, nil
end

local function NormalizeSelection(selection)
    if selection == "self" or selection == "MRT_SELF" then
        return "self"
    elseif selection == "both" or selection == "MRT_BOTH" then
        return "both"
    end
    return "raid"
end

function MRTReader:GetCurrentNote(selection)
    local mrt, namespace = self:GetMRT()
    if not mrt or type(mrt.Note) ~= "table" then
        return "", {
            available = false,
            namespace = namespace,
        }
    end

    local raidText = type(mrt.Note.Text1) == "string" and mrt.Note.Text1 or ""
    local selfText = type(mrt.Note.SelfText) == "string" and mrt.Note.SelfText or ""
    selection = NormalizeSelection(selection)
    local function Readable(value) return value == nil or type(value) == "string" end
    local inputCoverage = (selection == "self" or Readable(mrt.Note.Text1))
        and (selection == "raid" or Readable(mrt.Note.SelfText))

    local text, raidLineCount
    if selection == "self" then
        text = selfText
    elseif selection == "both" then
        if raidText ~= "" and selfText ~= "" then
            text = raidText .. "\n" .. selfText
            -- Preserve the boundary, including blank/trailing lines, so only
            -- duplicate assignments across the two sources are merged.
            raidLineCount = select(2, raidText:gsub("\n", "")) + 1
        else
            text = raidText ~= "" and raidText or selfText
        end
    else
        text = raidText
    end

    local label = selection == "self" and "MRT个人方案（个人）"
        or selection == "both" and "MRT两者（团队+个人）"
        or "MRT当前方案（团队）"
    return text, {
        available = true,
        namespace = namespace,
        selection = selection,
        raidLineCount = raidLineCount,
        inputCoverage = inputCoverage,
        status = text ~= "" and "READ" or "EMPTY",
        statusText = text ~= "" and ("已读取（" .. label .. "）") or (label .. "为空"),
    }
end

function MRTReader:HashText(text)
    if type(text) ~= "string" or text == "" then
        return "0:0"
    end

    local hash = 5381
    for index = 1, #text do
        hash = (hash * 33 + text:byte(index)) % 4294967296
    end

    return tostring(#text) .. ":" .. tostring(hash)
end

function MRTReader:TryHookNoteFrame()
    if self.noteHooked then
        return true
    end

    local noteFrame = _G.MRTNote or _G.ExRTNote
    if not noteFrame or not noteFrame.text or not hooksecurefunc then
        return false
    end

    hooksecurefunc(noteFrame.text, "SetText", function()
        C_Timer.After(0.25, function()
            if not EC.state.dbReady or not EC.db.autoRefresh then
                return
            end
            if EC.PlanSources and EC.PlanSources.IsMRTSource and not EC.PlanSources:IsMRTSource(EC.PlanSources:GetSelected()) then return end

            -- The current attempt uses a frozen snapshot. Do not reparse the live
            -- note while in combat; the next pull will read the newest board.
            if (EC.Runtime and EC.Runtime.encounterActive) or (InCombatLockdown and InCombatLockdown()) then
                return
            end

            EC:RefreshCurrentNote("MRT 文本更新", false, false)
        end)
    end)

    self.noteHooked = true
    EC:Log("已挂接 MRT 当前战术板文本更新")
    return true
end

function MRTReader:StartHookRetries()
    if self.hookRetryTicker then
        return
    end

    local attempts = 0
    local ticker
    ticker = C_Timer.NewTicker(2.0, function()
        attempts = attempts + 1
        if self:TryHookNoteFrame() or attempts >= 15 then
            if ticker then
                ticker:Cancel()
            end
            self.hookRetryTicker = nil
        end
    end)
    self.hookRetryTicker = ticker
end

function MRTReader:StartPolling()
    if self.pollTicker then
        return
    end

    self.pollTicker = C_Timer.NewTicker(1.0, function()
        if not EC.state.dbReady or not EC.db.autoRefresh then
            return
        end

        if (EC.Runtime and EC.Runtime.encounterActive) or (InCombatLockdown and InCombatLockdown()) then
            return
        end

        EC:RefreshCurrentNote("自动检测", false, false)
    end)
end

function MRTReader:Initialize()
    if self.initialized then
        return
    end

    self.initialized = true
    self:StartPolling()

    C_Timer.After(1.5, function()
        if not self:TryHookNoteFrame() then
            self:StartHookRetries()
        end
    end)
end
