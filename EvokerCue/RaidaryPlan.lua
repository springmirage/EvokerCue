local addonName, EC = ...

-- Local plans use the same Parser -> PlanGuard -> Timeline pipeline as MRT.
-- Drafts never become the running encounter plan until explicitly saved.
local Plan = {}
EC.RaidaryPlan = Plan

-- Match MRT's selector data contract (Functions.lua / localization.lua):
-- EncountersList contains dungeonEncounterID, the same ID sent by
-- ENCOUNTER_START. Journal encounter IDs are used ONLY to look up names.
-- Nothing is copied into SavedVariables; missing data can be retried on open.
local function ReadAPI(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if ok then return value end
end

function Plan:GetBossCatalog()
    local catalog = { groups = {}, byID = {}, byName = {} }
    local groups = {}
    local function Add(groupName, name, id)
        if type(groupName) ~= "string" or groupName == "" or type(name) ~= "string" or name == ""
            or type(id) ~= "number" or id <= 0 then return end
        local key = tostring(id)
        if catalog.byID[key] then return end
        local group = groups[groupName]
        if not group then
            group = { name = groupName, bosses = {} }
            groups[groupName] = group
            catalog.groups[#catalog.groups + 1] = group
        end
        local entry = { text = name, value = key }
        group.bosses[#group.bosses + 1] = entry
        catalog.byID[key] = entry
        -- Never guess which instance a duplicate legacy name meant.
        if catalog.byName[name] == nil then catalog.byName[name] = entry
        else catalog.byName[name] = false end
    end
    local mrt = _G.GExRT
    local list = mrt and mrt.F and ReadAPI(mrt.F.GetEncountersList, false, false, true)
    local incomplete = type(list) ~= "table" or #list == 0
    if type(list) == "table" then
        for _, instance in ipairs(list) do
            local map = C_Map and ReadAPI(C_Map.GetMapInfo, instance[1])
            local groupName = type(instance[1]) == "string" and instance[1] or (map and map.name)
            for i = 2, #instance do
                local id = instance[i]
                local name = mrt.L and ReadAPI(mrt.L.bossName2, mrt.L, id)
                if not name or name == "" then
                    local journalID = mrt.GDB and mrt.GDB.encounterIDtoEJ and mrt.GDB.encounterIDtoEJ[id]
                    if journalID then name = ReadAPI(EJ_GetEncounterInfo, journalID) end
                end
                if not groupName or not name or name == "" then incomplete = true end
                Add(groupName, name, id)
            end
        end
    end
    -- Without MRT (or with incomplete names), ask the game's journal directly.
    -- Explicit instance arguments avoid changing its selected instance/difficulty.
    -- When tier APIs exist, restore the user's tier even after an API failure.
    if incomplete and type(EJ_GetInstanceByIndex) == "function" and type(EJ_GetEncounterInfoByIndex) == "function" then
        local oldTier = ReadAPI(EJ_GetCurrentTier)
        local tiers = ReadAPI(EJ_GetNumTiers)
        local canSelectTier = oldTier and tiers and type(EJ_SelectTier) == "function"
        local function ScanTier()
            for _, isRaid in ipairs({ true, false }) do
                for index = 1, 500 do
                    local instanceID, instanceName = EJ_GetInstanceByIndex(index, isRaid)
                    if not instanceID then break end
                    for bossIndex = 1, 100 do
                        local name, _, _, _, _, _, dungeonEncounterID = EJ_GetEncounterInfoByIndex(bossIndex, instanceID)
                        if not name then break end
                        Add(instanceName, name, dungeonEncounterID)
                    end
                end
            end
        end
        pcall(function()
            if canSelectTier then
                for tier = tiers, 1, -1 do EJ_SelectTier(tier); ScanTier() end
            else ScanTier() end
        end)
        if canSelectTier then pcall(EJ_SelectTier, oldTier) end
    end
    return catalog
end

function Plan:FindBoss(value, catalog)
    if value == nil or value == "" then return nil end
    local key = tostring(value)
    return catalog.byID[key] or catalog.byName[key] or nil
end

local function ModelInputsChanged()
    if EC.DreamLoom then EC.DreamLoom:InputsChanged() end
end

function Plan:GetStore()
    if not EC.db then return nil end
    if type(EC.db.raidaryPlan) ~= "table" then EC.db.raidaryPlan = { text = "" } end
    local db = EC.db.raidaryPlan
    if not db.plans then
        db.plans = { { id = 1, name = "默认方案", text = db.text or "", draft = db.draft, boss = "", history = {} } }
        db.selectedID, db.nextID, db.bindings = 1, 2, {}
        db.text, db.draft = nil, nil
    end
    return db
end

function Plan:GetDB()
    local db = self:GetStore()
    if not db then return nil end
    for _, plan in ipairs(db.plans) do if plan.id == db.selectedID then return plan end end
    db.selectedID = db.plans[1].id
    return db.plans[1]
end

function Plan:Select(id)
    local db = self:GetStore()
    for _, plan in ipairs(db.plans) do
        if plan.id == id then
            if db.selectedID ~= id then db.selectedID = id; ModelInputsChanged() end
            return true
        end
    end
    return false
end

local function GetUsedPlanNames(plans)
    local used = {}
    for _, plan in ipairs(plans) do used[plan.name] = true end
    return used
end

local function GetNewPlanName(plans)
    local used = GetUsedPlanNames(plans)
    local number = 1
    while used["新方案 " .. number] do number = number + 1 end
    return "新方案 " .. number
end

function Plan:Create(copy)
    local db, current = self:GetStore(), self:GetDB()
    local id = db.nextID
    db.nextID = id + 1
    db.plans[#db.plans + 1] = { id = id, name = copy and (current.name .. " 副本") or GetNewPlanName(db.plans),
        text = copy and self:GetText() or "", draft = copy and self:GetDraft() or "", boss = copy and current.boss or "", history = {} }
    if copy and EC.DreamLoom and current.dreamLoom then
        db.plans[#db.plans].dreamLoom = EC.DreamLoom:CopyPlanData(current.dreamLoom)
    end
    db.selectedID = id
    ModelInputsChanged()
end

function Plan:Delete()
    local db = self:GetStore()
    if #db.plans <= 1 then return false end
    for i, plan in ipairs(db.plans) do
        if plan.id == db.selectedID then
            db.deleted = plan -- One-step recovery also preserves the unsaved draft.
            for boss, id in pairs(db.bindings) do if id == plan.id then db.bindings[boss] = nil end end
            table.remove(db.plans, i)
            db.selectedID = db.plans[math.min(i, #db.plans)].id
            ModelInputsChanged()
            return true
        end
    end
end

function Plan:RestoreDeleted()
    local db = self:GetStore()
    if not db.deleted then return false end
    local used = GetUsedPlanNames(db.plans)
    local adjustedName
    if used[db.deleted.name] then
        local originalName = db.deleted.name
        adjustedName = originalName .. "（恢复）"
        local number = 2
        while used[adjustedName] do
            adjustedName = originalName .. "（恢复 " .. number .. "）"
            number = number + 1
        end
        -- Only the restored display name changes; identity/content stay intact.
        db.deleted.name = adjustedName
    end
    db.plans[#db.plans + 1], db.selectedID = db.deleted, db.deleted.id
    db.deleted = nil
    ModelInputsChanged()
    return true, adjustedName
end

function Plan:SetMetadata(name, boss)
    local plan, db = self:GetDB(), self:GetStore()
    name = (name or ""):match("^%s*(.-)%s*$")
    -- Metadata-only saves preserve an unrecognized legacy value verbatim.
    if boss ~= plan.boss then boss = tostring(boss or ""):match("^%s*(.-)%s*$") end
    if boss == nil then boss = "" end
    if name == "" then return false end
    if plan.boss ~= boss and db.bindings[plan.boss] == plan.id then db.bindings[plan.boss] = nil end
    plan.name, plan.boss = name, boss
    return true
end

function Plan:Bind()
    local plan, db = self:GetDB(), self:GetStore()
    if plan.boss == "" then return false end
    db.bindings[plan.boss] = plan.id
    return true
end

function Plan:Unbind()
    local plan, db = self:GetDB(), self:GetStore()
    if db.bindings[plan.boss] == plan.id then db.bindings[plan.boss] = nil end
    plan.boss = "" -- Explicit cancellation returns this plan to general use.
end

function Plan:Resolve(context)
    local db, current = self:GetStore(), self:GetDB()
    if context then
        local id = db.bindings[tostring(context.encounterID)] or db.bindings[context.encounterID] or db.bindings[context.encounterName]
        for _, plan in ipairs(db.plans) do if plan.id == id then return plan.text or "", plan end end
        -- A plan bound to a different boss must never play in this encounter.
        if current.boss ~= "" and tostring(current.boss) ~= tostring(context.encounterID) and current.boss ~= context.encounterName then
            return "", current
        end
    end
    return current.text or "", current
end

function Plan:RestoreHistory()
    local db = self:GetDB()
    -- Restoring a draft must not consume the saved history before it is saved.
    local old = db.history and db.history[1]
    if type(old) ~= "string" then return false end
    if EC.DreamLoom then EC.DreamLoom:RestoreProvenance(db, old) end
    self:SetDraft(old)
    return true
end

function Plan:GetText()
    local db = self:GetDB()
    return db and type(db.text) == "string" and db.text or ""
end

function Plan:GetDraft()
    local db = self:GetDB()
    return db and type(db.draft) == "string" and db.draft or self:GetText()
end

function Plan:SetDraft(text)
    local db = self:GetDB()
    if db then
        text = type(text) == "string" and text or ""
        local changed = self:GetDraft() ~= text
        db.draft = text
        if changed then ModelInputsChanged() end
    end
end

function Plan:IsDirty()
    return self:GetDraft() ~= self:GetText()
end

function Plan:Save(text, activate)
    local db = self:GetDB()
    if not db or type(text) ~= "string" then return false end
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    if EC.DreamLoom then EC.DreamLoom:OnPlanSave(db, text) end
    db.history = db.history or {}
    if text ~= db.text then
        table.insert(db.history, 1, db.text or "")
        if #db.history > 10 then table.remove(db.history) end
    end
    local changed = self:GetDraft() ~= text
    db.text = text
    db.draft = db.text
    if changed then ModelInputsChanged() end
    if activate then
        EC.PlanSources:SetSelected("RAIDARY")
    elseif EC.PlanSources:GetSelected() == "RAIDARY" then
        EC:RefreshCurrentNote("保存 Raidary Plan", true, false)
    end
    return true
end

function Plan:Preview(text)
    -- Preview is independent of the selected source and never replaces EC.state.result.
    return EC.Parser:BuildResult(type(text) == "string" and text or self:GetDraft(), EC:GetPlayerIdentity())
end
