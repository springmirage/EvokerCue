local addonName, EC = ...
local PlanUI = {}
EC.RaidaryPlanUI = PlanUI

local function MakeEditor(parent, name, font, readOnly)
    local widgets = EC.UI.widgets
    local box = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    widgets.SetBackdrop(box, readOnly and widgets.colors.panel or widgets.colors.input, widgets.colors.border)
    local scroll = CreateFrame("ScrollFrame", name, box, "UIPanelScrollFrameTemplate")
    widgets.SkinScroll(scroll)
    widgets.SetPageWheel(scroll)
    scroll:SetPoint("TOPLEFT", widgets.style.inset, -widgets.style.inset)
    scroll:SetPoint("BOTTOMRIGHT", -36, widgets.style.inset)
    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject(font)
    widgets.ApplyFont(edit, widgets.style.body)
    edit:SetTextInsets(0, 4, 2, 2)
    edit:SetWidth(790)
    edit:SetHeight(100)
    edit:SetMaxLetters(0)
    if edit.SetCountInvisibleLetters then edit:SetCountInvisibleLetters(false) end
    scroll:SetScrollChild(edit)
    box:EnableMouse(true)
    box:SetScript("OnMouseDown", function() edit:SetFocus() end)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnEditFocusGained", function() box:SetBackdropBorderColor(unpack(widgets.colors.accent)) end)
    edit:SetScript("OnEditFocusLost", function() box:SetBackdropBorderColor(unpack(widgets.colors.border)) end)
    scroll:HookScript("OnSizeChanged", function(self, width) edit:SetWidth(math.max(100, width - 4)) end)
    edit:SetScript("OnCursorChanged", function(_, _, y, _, height)
        local top = -y
        local offset = scroll:GetVerticalScroll()
        local visible = scroll:GetHeight()
        if top < offset then scroll:SetVerticalScroll(math.max(0, top))
        elseif top + height > offset + visible then scroll:SetVerticalScroll(math.max(0, top + height - visible)) end
    end)
    if readOnly then
        edit:SetScript("OnTextChanged", function(self, userInput)
            if userInput and self:GetText() ~= (self.outputText or "") then self:SetText(self.outputText or "") end
        end)
    end
    return box, edit, scroll
end

local GENERAL_BOSS = "通用方案（不绑定首领）"
local UNKNOWN_BOSS = "原绑定未识别，请重新选择首领。"

function PlanUI:RefreshBoss()
    local value = self.bossValue
    local entry = EC.RaidaryPlan:FindBoss(value, self.bossCatalog)
    self.boss:SetText((value == nil or value == "") and GENERAL_BOSS or entry and entry.text or "原绑定未识别")
    if self.bindingHelp then
        self.bindingHelp:SetText(value ~= nil and value ~= "" and not entry and UNKNOWN_BOSS
            or "通用方案不绑定首领；每个首领可存多份，自动使用一份（仅 Raidary 来源生效）。")
    end
end

function PlanUI:GetBossItems()
    self.bossCatalog = EC.RaidaryPlan:GetBossCatalog()
    self:RefreshBoss()
    local selected = EC.RaidaryPlan:FindBoss(self.bossValue, self.bossCatalog)
    local items = { { text = GENERAL_BOSS, value = "", selected = self.bossValue == "" } }
    for _, group in ipairs(self.bossCatalog.groups) do
        items[#items + 1] = { text = group.name, isTitle = true }
        for _, entry in ipairs(group.bosses) do
            items[#items + 1] = { text = entry.text, value = entry.value, selected = selected == entry }
        end
    end
    if #items == 1 then items[#items + 1] = { text = "首领列表暂不可用，请稍后重试", disabled = true } end
    return items
end

function PlanUI:SelectBoss(value)
    -- Only a deliberate choice replaces a legacy value. Opening/saving does not.
    if value ~= "" and not self.bossCatalog.byID[value] then return end
    self.bossValue = value
    self:RefreshBoss()
    self:CommitMetadata()
end

function PlanUI:RefreshStatus(message)
    if not self.status then return end
    local selected = EC.PlanSources:GetSelected() == "RAIDARY"
    local combat = (EC.Runtime and EC.Runtime.encounterActive) or (InCombatLockdown and InCombatLockdown())
    local text = EC.RaidaryPlan:IsDirty() and "草稿未保存" or "|cff69c9ae已保存|r"
    if self.name and not self.name:GetText():find("%S") then
        text = "方案名称不能为空；名称和首领修改尚未保存"
    end
    local plan, store = EC.RaidaryPlan:GetDB(), EC.RaidaryPlan:GetStore()
    local bossEntry = EC.RaidaryPlan:FindBoss(plan.boss, self.bossCatalog)
    if plan.boss ~= nil and plan.boss ~= "" and not bossEntry then
        text = UNKNOWN_BOSS .. "\n" .. text
    elseif store.bindings[plan.boss] == plan.id then
        text = text .. " · 首领自动使用：" .. bossEntry.text
    end
    text = text .. " · 当前来源：" .. EC.PlanSources:GetSelectedLabel()
    if combat then
        text = text .. " · 本场计划保持不变，修改于下次开怪生效"
    elseif selected then
        text = text .. " · |cff69c9ae已接入技能提醒|r"
    end
    self.status:SetText((message and (message .. "\n") or "") .. text)
    if self.statusReader then self.statusReader:RefreshLayout() end
end

function PlanUI:CommitMetadata()
    if not EC.RaidaryPlan:SetMetadata(self.name:GetText(), self.bossValue) then
        self:RefreshStatus("方案名称不能为空，请先填写名称。")
        return false
    end
    self.selector:SetText(EC.RaidaryPlan:GetDB().name)
    self:RefreshStatus()
    return true
end

function PlanUI:Preview()
    local result = EC.RaidaryPlan:Preview(self.editor:GetText())
    local lines = { result.statusText,
        string.format("本人安排：%d 条", #result.events),
        "静滞波次：" .. (result.waveQuotaText or "—"), "" }
    for _, warning in ipairs(result.warnings or {}) do lines[#lines + 1] = "提示：" .. warning end
    if (result.stats.phaseLinesSkipped or 0) > 0 then
        lines[#lines + 1] = "提示：跳过了相对阶段时间；当前只支持从开怪起计时。"
    end
    if (result.stats.playerMismatchLines or 0) > 0 then
        lines[#lines + 1] = string.format("另有 %d 行非本人安排未加入提醒。", result.stats.playerMismatchLines)
    end
    for _, event in ipairs(result.events) do
        lines[#lines + 1] = EC:FormatClock(event.time) .. " " .. event.matchedPlayerName .. " " .. event.skillName
    end
    self.preview.outputText = table.concat(lines, "\n")
    self.preview:SetText(self.preview.outputText)
    self.preview:SetCursorPosition(0)
    self.previewScroll:SetVerticalScroll(0)
    self:RefreshStatus("已预览草稿；预览不会修改当前战斗计划。")
end


function PlanUI:LoadSelection()
    local plan = EC.RaidaryPlan:GetDB()
    self.name:SetText(plan.name)
    self.bossValue = plan.boss or ""
    self:RefreshBoss()
    self.selector:SetText(plan.name)
    self.editor:SetText(EC.RaidaryPlan:GetDraft())
    self.editor:SetCursorPosition(0)
    self.editorScroll:SetVerticalScroll(0)
    self:Preview()
    if EC.PlanSources:GetSelected() == "RAIDARY" then
        -- Explicit selection changes must refresh even when auto-read is off.
        -- Core refuses this refresh during combat, preserving the live snapshot.
        EC:RefreshCurrentNote("切换 Raidary Plan 方案", true, false)
    end
end

function PlanUI:Create(ui, frame)
    local widgets, plan = ui.widgets, EC.RaidaryPlan
    local page = CreateFrame("Frame", nil, frame)
    page:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -64)
    page:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 44)
    page:Hide()
    self.page = page
    local function Text(text, x, y, width)
        return widgets.CreateText(page, "GameFontHighlightSmall", text, x, y, width)
    end
    local function Button(text, x, y, width, fn)
        return widgets.CreateButton(page, text, x, y, width, fn)
    end
    local heading = widgets.CreateText(page, "GameFontNormalLarge", "战术板", 24, -16, 100)
    widgets.ApplyFont(heading, widgets.style.pageTitle)
    Text("Raidary Plan · EvokerCue 专属战术板", 132, -20, 720)
    widgets.CreateText(page, "GameFontHighlight", "方案选择与管理", 24, -44, 846)
    Text("方案", 24, -72, 40)
    self.selector = widgets.CreateDropdown(page, "EvokerCuePlanSelectorMenu", 72, -64, 350, function()
        local items = {}
        for _, item in ipairs(plan:GetStore().plans) do
            items[#items + 1] = { text = item.name, value = item.id, selected = item.id == plan:GetDB().id }
        end
        return items
    end, function(id)
        plan:Select(id); self:LoadSelection()
    end)
    Button("新建", 434, -64, 88, function() plan:Create(false); self:LoadSelection() end)
    Button("复制", 534, -64, 88, function()
        if not self:CommitMetadata() then return end
        plan:Create(true); self:LoadSelection()
    end)
    local deleteButton = Button("删除", 634, -64, 88, function()
        if plan:Delete() then self:LoadSelection(); self:RefreshStatus("已删除；可点击恢复删除。")
        else self:RefreshStatus("至少保留一份方案。") end
    end)
    deleteButton:SetVariant("danger")
    Button("恢复删除", 734, -64, 140, function()
        local restored, adjustedName = plan:RestoreDeleted()
        if restored then
            self:LoadSelection()
            if adjustedName then self:RefreshStatus("原名称已被使用，恢复的方案已改名为：" .. adjustedName) end
        else self:RefreshStatus("没有可恢复的方案。") end
    end)
    widgets.CreateText(page, "GameFontHighlight", "方案属性与绑定", 24, -104, 846)
    Text("名称", 24, -132, 40); self.name = widgets.CreateEditBox(page, 72, -124, 180)
    Text("适用首领", 268, -132, 64)
    self.bossCatalog = plan:GetBossCatalog()
    self.bossValue = plan:GetDB().boss or ""
    self.boss = widgets.CreateDropdown(page, "EvokerCueBossSelectorMenu", 344, -124, 294,
        function() return self:GetBossItems() end,
        function(value) self:SelectBoss(value) end)
    Button("自动使用", 650, -124, 106, function()
        if self.bossValue == "" then self:RefreshStatus("请先选择首领"); return end
        local entry = plan:FindBoss(self.bossValue, self.bossCatalog)
        if not entry then self:RefreshStatus(UNKNOWN_BOSS); return end
        self.bossValue = entry.value
        if not self:CommitMetadata() then return end
        if plan:Bind() then self:RefreshStatus("已设为该首领自动使用的方案（仅 Raidary 来源生效）。")
        else self:RefreshStatus("请先选择首领") end
    end)
    Button("取消绑定", 768, -124, 106, function()
        plan:Unbind(); self.bossValue = ""; self:RefreshBoss()
        self:RefreshStatus("已取消绑定，当前为通用方案。")
    end)
    local function Metadata()
        self:CommitMetadata()
    end
    self.name:SetScript("OnTextChanged", function(_, user) if user then Metadata() end end)
    local bindingHelp = Text("", 24, -164, 850)
    self.bindingHelp = bindingHelp
    local formatHelp = Text("一行一条，如 00:01 韶光逍珑 静滞。支持 MRT 横杠、尖括号、time、spell / spellid、法术链接。", 24, -208, 850)
    local editors = CreateFrame("Frame", nil, page)
    editors:SetPoint("TOPLEFT", page, "TOPLEFT", 24, -252)
    -- Bottom edge is anchored to the action row after it is created below.
    local leftTitle = widgets.CreateText(page, "GameFontHighlight", "战术板原文", 24, -232, 430)
    local rightTitle = widgets.CreateText(page, "GameFontHighlight", "本人时间轴 / 检查结果 · 只读", 0, 0, 320)
    local box, edit, scroll = MakeEditor(editors, "EvokerCueRaidaryEditorScroll", "GameFontHighlight", false)
    box:SetPoint("TOPLEFT", editors, "TOPLEFT", 0, 0)
    box:SetPoint("BOTTOMLEFT", editors, "BOTTOMLEFT", 0, 0)
    local placeholder = widgets.CreateText(box, "GameFontHighlightSmall", "在此粘贴战术板内容（保留所有人的安排）", 16, -18, 420)
    placeholder:SetTextColor(unpack(widgets.colors.faint))
    local function UpdatePlaceholder() placeholder:SetShown(edit:GetText() == "") end
    edit:HookScript("OnEditFocusGained", UpdatePlaceholder)
    edit:HookScript("OnEditFocusLost", UpdatePlaceholder)
    self.editor, self.editorScroll = edit, scroll
    edit:SetScript("OnTextChanged", function(e, user)
        UpdatePlaceholder()
        if user then
            plan:SetDraft(e:GetText()); self:RefreshStatus("原文已修改，点击检查更新预览。")
        end
    end)
    local previewBox, preview, previewScroll = MakeEditor(editors, "EvokerCueRaidaryPreviewScroll", "GameFontHighlightSmall", true)
    previewBox:SetPoint("TOPLEFT", box, "TOPRIGHT", 16, 0)
    previewBox:SetPoint("BOTTOMRIGHT", editors, "BOTTOMRIGHT", 0, 0)
    rightTitle:ClearAllPoints(); rightTitle:SetPoint("BOTTOMLEFT", previewBox, "TOPLEFT", 0, 8)
    rightTitle:SetPoint("BOTTOMRIGHT", previewBox, "TOPRIGHT", 0, 8)
    local function LayoutEditors()
        formatHelp:ClearAllPoints()
        formatHelp:SetPoint("TOPLEFT", bindingHelp, "BOTTOMLEFT", 0, -6)
        leftTitle:ClearAllPoints()
        leftTitle:SetPoint("TOPLEFT", formatHelp, "BOTTOMLEFT", 0, -8)
        box:SetWidth(math.max(100, (editors:GetWidth() - widgets.style.inset) * 0.6))
        placeholder:SetWidth(math.max(100, box:GetWidth() - 52))
    end
    editors:SetPoint("TOPLEFT", leftTitle, "BOTTOMLEFT", 0, -8)
    editors:SetScript("OnSizeChanged", LayoutEditors)
    LayoutEditors()
    self.preview, self.previewScroll = preview, previewScroll
    local function Save(activate)
        edit:ClearFocus()
        if not self:CommitMetadata() then return end
        if not plan:Save(edit:GetText(), activate) then
            self:RefreshStatus("保存失败，草稿仍保留，请重试。")
            return
        end
        ui:Refresh(); self:Preview()
        self:RefreshStatus(activate and "已保存并启用 Raidary Plan。" or "已保存战术板。")
    end
    local buttons = CreateFrame("Frame", nil, page)
    buttons:SetPoint("BOTTOMLEFT", 24, 46); buttons:SetSize(850, widgets.style.controlHeight)
    self.actionBar = buttons
    editors:SetPoint("BOTTOMRIGHT", buttons, "TOPRIGHT", 0, widgets.style.small)
    -- The action row has its own space; edit/preview frames cannot cover it.
    local y = 0 -- final placement is anchored to the bottom action container
    self.actionButtons = {
        Button("保存", 22, y, 80, function() Save(false) end),
        Button("保存并启用", 112, y, 120, function() Save(true) end),
        Button("检查", 242, y, 80, function() edit:ClearFocus(); self:Preview() end),
        Button("恢复上次保存", 332, y, 130, function()
            if plan:RestoreHistory() then self:LoadSelection(); self:RefreshStatus("历史已恢复到草稿，保存后生效。")
            else self:RefreshStatus("没有更早的保存记录。") end
        end),
    }
    for i, b in ipairs(self.actionButtons) do
        b:SetParent(buttons)
        b:ClearAllPoints(); b:SetPoint("TOPLEFT", buttons, "TOPLEFT", ({0,92,224,316})[i], 0)
    end
    self.actionButtons[2]:SetVariant("primary")
    self.actionButtons[4]:SetVariant("quiet")
    -- A clipped status reader keeps long boss/source names out of the action row.
    self.statusReader = widgets.CreateDocumentReader(page, "EvokerCuePlanStatusScroll", "", 24, 0, 24, 8)
    self.statusReader:ClearAllPoints()
    self.statusReader:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 24, 4)
    self.statusReader:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -24, 4)
    self.statusReader:SetHeight(34)
    self.statusReader.bottomPadding = 0
    self.statusReader:SetBackdrop(nil)
    self.statusReader.scroll:ClearAllPoints()
    self.statusReader.scroll:SetPoint("TOPLEFT", 0, 0)
    self.statusReader.scroll:SetPoint("BOTTOMRIGHT", -24, 0)
    self.status = self.statusReader.document
    widgets.ApplyFont(self.status, widgets.style.caption)
    self.status:SetTextColor(unpack(widgets.colors.muted))
    page:SetScript("OnShow", function()
        self.bossCatalog = plan:GetBossCatalog()
        self:RefreshBoss()
        LayoutEditors()
        UpdatePlaceholder()
        edit:SetWidth(math.max(100, scroll:GetWidth() - 4))
        preview:SetWidth(math.max(100, previewScroll:GetWidth() - 4))
        self:RefreshStatus()
    end)
    page:SetScript("OnHide", function() edit:ClearFocus(); preview:ClearFocus(); self.name:ClearFocus() end)
    self:LoadSelection()
    return page
end
