local addonName, EC = ...

local UI = {}
EC.UI = UI

-- Shared settings palette and logical dimensions; the window scale applies once.
local function RGB(hex)
    return { tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255,
        tonumber(hex:sub(5, 6), 16) / 255, 1 }
end
local COLORS = {
    bg = RGB("14181D"), panel = RGB("1B2128"), panelAlt = RGB("1B2128"),
    input = RGB("101419"), border = RGB("303944"), accent = RGB("69C9AE"),
    gold = RGB("D2B272"), green = RGB("69C9AE"), red = RGB("D98787"),
    text = RGB("E4EAF0"), muted = RGB("9AA5B3"), faint = RGB("788491"),
    button = RGB("1B2128"), buttonHover = RGB("253831"), primaryHover = RGB("82D5BD"),
}
local STYLE = { small = 8, gap = 12, inset = 16, margin = 24,
    controlHeight = 32, title = 20, pageTitle = 18, section = 16, body = 14, caption = 13, wheelStep = 44,
    columnLeft = 26, columnRight = 386, columnWidth = 300 }
local BUTTON_HEIGHT, INPUT_HEIGHT = STYLE.controlHeight, STYLE.controlHeight
local function ApplyFont(region, size)
    local font = region:GetFont()
    if font then region:SetFont(font, size or STYLE.body, "") end
    region:SetShadowOffset(0, 0)
    region:SetShadowColor(0, 0, 0, 0)
    region:SetTextColor(unpack(COLORS.text))
end

UI.initialized = false
UI.frame = nil
UI.pages = {}
UI.navButtons = {}
UI.activePage = "overview"
UI.activeTab = "functions"
UI.tabButtons = {}
UI.timelineRows = {}
UI.controls = {}
-- Session-only state: a login or /reload must allow the guide to appear again.
-- Do not store this flag in EvokerCueDB.
UI.usageShownThisSession = false
UI.usageDialog = nil
UI.positionConfirm = nil
UI.pendingPositionAction = nil
local PANEL_FRAME_LEVEL = 100
local GUIDE_WIDTH, GUIDE_HEIGHT = 680, 448

local function SetBackdrop(frame, background, border)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    frame:SetBackdropColor(unpack(background or COLORS.panel))
    frame:SetBackdropBorderColor(unpack(border or COLORS.border))
end

local function CreateText(parent, fontObject, text, x, y, width)
    local fontString = parent:CreateFontString(nil, "OVERLAY", fontObject or "GameFontNormal")
    fontString:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    if width then
        fontString:SetWidth(width)
        fontString:SetJustifyH("LEFT")
    end
    ApplyFont(fontString, fontObject == "GameFontNormalHuge" and STYLE.title
        or fontObject == "GameFontNormalLarge" and STYLE.section
        or (fontObject and fontObject:find("Small")) and STYLE.caption or STYLE.body)
    if fontObject and fontObject:find("Small") then fontString:SetTextColor(unpack(COLORS.muted)) end
    fontString:SetText(text or "")
    return fontString
end

local function CreateButton(parent, text, x, y, width, onClick)
    local button = CreateFrame("Button", nil, parent, "BackdropTemplate")
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    button:SetSize(width or 120, BUTTON_HEIGHT)
    SetBackdrop(button, COLORS.button, COLORS.border)

    button.label = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ApplyFont(button.label)
    button.label:SetPoint("CENTER")
    button.label:SetJustifyH("CENTER")
    button.label:SetText(text)
    button.label:SetTextColor(unpack(COLORS.text))

    function button:RefreshStyle()
        local highlighted = self.selected or self.hovered or self.pressed
        local primary = self.variant == "primary"
        local color = self.variant == "danger" and COLORS.red or COLORS.accent
        self:SetBackdropColor(unpack(primary and (self.pressed and COLORS.muted or self.hovered and COLORS.primaryHover or COLORS.accent)
            or highlighted and COLORS.buttonHover or COLORS.button))
        self:SetBackdropBorderColor(unpack(highlighted and color or primary and COLORS.accent or COLORS.border))
        self.label:SetTextColor(unpack(not self:IsEnabled() and COLORS.faint
            or primary and COLORS.input or (self.selected or self.variant == "danger") and color
            or self.variant == "quiet" and COLORS.muted or COLORS.text))
        self:SetAlpha(self:IsEnabled() and 1 or 0.5)
        if self.label:GetJustifyH() == "CENTER" then self.label:SetPoint("CENTER", 0, self.pressed and -1 or 0) end
    end
    function button:SetVariant(variant) self.variant = variant; self:RefreshStyle() end
    function button:SetSelected(selected)
        self.selected = selected == true
        self:RefreshStyle()
    end
    button:SetScript("OnEnter", function(self) self.hovered = true; self:RefreshStyle() end)
    button:SetScript("OnLeave", function(self) self.hovered = false; self.pressed = false; self:RefreshStyle() end)
    button:SetScript("OnHide", function(self) self.hovered = false; self.pressed = false; self:RefreshStyle() end)
    button:HookScript("OnMouseDown", function(self) self.pressed = true; self:RefreshStyle() end)
    button:HookScript("OnMouseUp", function(self) self.pressed = false; self:RefreshStyle() end)
    button:HookScript("OnEnable", function(self) self:RefreshStyle() end)
    button:HookScript("OnDisable", function(self) self:RefreshStyle() end)
    button:SetScript("OnClick", onClick)
    return button
end

local function CreateEditBox(parent, x, y, width, height)
    local edit = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    edit:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    edit:SetSize(width, height or INPUT_HEIGHT)
    edit:SetMultiLine(false)
    edit:SetAutoFocus(false)
    edit:SetFontObject("ChatFontNormal")
    ApplyFont(edit)
    edit:SetTextInsets(8, 8, 0, 0)
    edit:SetJustifyH("LEFT")
    SetBackdrop(edit, COLORS.input, COLORS.border)
    edit:SetScript("OnEditFocusGained", function(self) self:SetBackdropBorderColor(unpack(COLORS.accent)) end)
    edit:SetScript("OnEditFocusLost", function(self) self:SetBackdropBorderColor(unpack(COLORS.border)) end)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    return edit
end

-- Scroll offsets are logical UI units, just like content coordinates. Apply
-- scale only through the window, never again to the wheel delta. SetScript
-- replaces the template handler rather than invoking both for the same notch.
local function SetPageWheel(scroll)
    local function OnWheel(_, delta)
        local maximum = math.max(0, scroll:GetVerticalScrollRange() or 0)
        scroll:SetVerticalScroll(math.max(0, math.min(maximum,
            (scroll:GetVerticalScroll() or 0) - delta * STYLE.wheelStep)))
    end
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", OnWheel)
    local bar = scroll.ScrollBar or (scroll:GetName() and _G[scroll:GetName() .. "ScrollBar"])
    if bar then
        bar:EnableMouseWheel(true)
        bar:SetScript("OnMouseWheel", OnWheel)
    end
end

-- Keep Blizzard's range, wheel and drag logic, skin only its visual regions.
local function SkinScroll(scroll)
    local bar = scroll.ScrollBar or (scroll:GetName() and _G[scroll:GetName() .. "ScrollBar"])
    if not bar or bar.ecSkinned then return end
    bar.ecSkinned = true
    for _, region in ipairs({ bar:GetRegions() }) do
        if region:GetObjectType() == "Texture" then region:SetAlpha(0) end
    end
    for _, button in ipairs({ bar.ScrollUpButton or _G[(bar:GetName() or "") .. "ScrollUpButton"],
        bar.ScrollDownButton or _G[(bar:GetName() or "") .. "ScrollDownButton"] }) do
        button:SetAlpha(0); button:EnableMouse(false)
    end
    bar:ClearAllPoints()
    bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 4, 0)
    bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 4, 0)
    bar:SetWidth(16) -- generous drag target; the painted track stays narrow
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("TOP", 0, 0); track:SetPoint("BOTTOM", 0, 0); track:SetWidth(4)
    track:SetColorTexture(unpack(COLORS.border))
    local thumb = bar:GetThumbTexture()
    if thumb then
        thumb:SetTexture("Interface\\Buttons\\WHITE8X8")
        thumb:SetVertexColor(unpack(COLORS.muted)); thumb:SetAlpha(1); thumb:SetSize(8, 36)
    end
    local function Update()
        local scrollable = (scroll:GetVerticalScrollRange() or 0) > 0.5
        bar:SetAlpha(scrollable and 1 or 0)
        bar:EnableMouse(scrollable)
    end
    scroll:HookScript("OnScrollRangeChanged", Update)
    scroll:HookScript("OnShow", Update)
    scroll:HookScript("OnSizeChanged", Update)
    bar:HookScript("OnEnter", function() if thumb then thumb:SetVertexColor(unpack(COLORS.accent)) end end)
    bar:HookScript("OnLeave", function() if thumb then thumb:SetVertexColor(unpack(COLORS.muted)) end end)
    Update()
end

local function CreateDropdown(parent, name, x, y, width, getItems, onSelect)
    local selector = CreateButton(parent, "", x, y, width)
    selector.label:ClearAllPoints()
    selector.label:SetPoint("LEFT", 10, 0)
    selector.label:SetPoint("RIGHT", -30, 0)
    selector.label:SetJustifyH("LEFT")
    selector.label:SetWordWrap(false)
    -- Draw the chevron with lines: no dependency on font glyph coverage.
    for i = 1, 2 do
        local line = selector:CreateLine(nil, "OVERLAY")
        line:SetThickness(1.5)
        line:SetColorTexture(unpack(COLORS.muted))
        line:SetStartPoint("RIGHT", selector, i == 1 and -20 or -15, i == 1 and 2 or -3)
        line:SetEndPoint("RIGHT", selector, i == 1 and -15 or -10, i == 1 and -3 or 2)
    end
    function selector:SetText(text) self.label:SetText(text) end
    local function FullNameTooltip(button)
        button:HookScript("OnEnter", function(self)
            if self.label:GetStringWidth() > self:GetWidth() - 40 then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(self.label:GetText(), nil, nil, nil, nil, true)
                GameTooltip:Show()
            end
        end)
        button:HookScript("OnLeave", function() GameTooltip:Hide() end)
        button:HookScript("OnHide", function() GameTooltip:Hide() end)
    end
    FullNameTooltip(selector)

    -- Catch clicks elsewhere in this page; Escape and page changes also close it.
    local dismiss = CreateFrame("Button", name, parent)
    dismiss:SetAllPoints(parent)
    dismiss:SetFrameLevel(parent:GetFrameLevel() + 20)
    dismiss:Hide()
    table.insert(UISpecialFrames, name)
    dismiss:SetScript("OnClick", function(self) self:Hide() end)
    dismiss:SetScript("OnHide", function() selector:SetSelected(false) end)
    selector:HookScript("OnHide", function() dismiss:Hide() end)
    local menu = CreateFrame("Frame", nil, dismiss, "BackdropTemplate")
    menu:SetPoint("TOPLEFT", selector, "BOTTOMLEFT", 0, -4)
    menu:SetWidth(width)
    menu:EnableMouse(true)
    SetBackdrop(menu, COLORS.input, COLORS.border)
    local scroll = CreateFrame("ScrollFrame", name .. "Scroll", menu, "UIPanelScrollFrameTemplate")
    SkinScroll(scroll)
    scroll:SetPoint("TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", -26, 4)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        self:SetVerticalScroll(math.max(0, math.min(self:GetVerticalScrollRange(),
            self:GetVerticalScroll() - delta * BUTTON_HEIGHT)))
    end)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetWidth(width - 30)
    scroll:SetScrollChild(child)
    local rows = {}
    selector:SetScript("OnClick", function()
        if dismiss:IsShown() then dismiss:Hide(); return end
        local items = getItems()
        local count = #items
        menu:SetHeight(math.max(1, math.min(count, 8)) * BUTTON_HEIGHT + 8)
        child:SetHeight(math.max(1, count) * BUTTON_HEIGHT)
        local selectedIndex = 1
        for i, item in ipairs(items) do
            local row = rows[i]
            if not row then
                row = CreateButton(child, "", 0, -(i - 1) * BUTTON_HEIGHT, width - 30)
                row.label:ClearAllPoints()
                row.label:SetPoint("LEFT", 8, 0)
                row.label:SetPoint("RIGHT", -8, 0)
                row.label:SetJustifyH("LEFT")
                row.label:SetWordWrap(false)
                FullNameTooltip(row)
                row:SetScript("OnClick", function(self)
                    if not self:IsEnabled() then return end
                    dismiss:Hide()
                    onSelect(self.value)
                end)
                rows[i] = row
            end
            row.value = item.value
            row.label:SetText(item.text)
            row:SetEnabled(not item.isTitle and not item.disabled)
            row:SetVariant(item.isTitle and "quiet" or nil)
            row:SetSelected(item.selected)
            row:Show()
            if item.selected then selectedIndex = i end
        end
        for i = count + 1, #rows do rows[i]:Hide() end
        dismiss:Show()
        selector:SetSelected(true)
        scroll:UpdateScrollChildRect()
        scroll:SetVerticalScroll(math.min(selectedIndex - 1, math.max(0, count - 8)) * BUTTON_HEIGHT)
    end)
    return selector
end

local function CreateCheckbox(parent, text, x, y, getter, setter, tooltip)
    local check = CreateFrame("CheckButton", nil, parent, "BackdropTemplate")
    check:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    check:SetSize(24, 24)
    SetBackdrop(check, COLORS.input, COLORS.border)
    local mark = check:CreateTexture(nil, "ARTWORK")
    mark:SetColorTexture(unpack(COLORS.accent))
    mark:SetSize(12, 12)
    mark:SetPoint("CENTER", check, "CENTER", 0, 0)
    check:SetCheckedTexture(mark)
    check:HookScript("OnEnter", function(self) self:SetBackdropBorderColor(unpack(COLORS.accent)) end)
    check:HookScript("OnLeave", function(self) self:SetBackdropBorderColor(unpack(COLORS.border)) end)
    check:HookScript("OnMouseDown", function(self) self:SetBackdropColor(unpack(COLORS.buttonHover)) end)
    check:HookScript("OnMouseUp", function(self) self:SetBackdropColor(unpack(COLORS.input)) end)
    check:HookScript("OnDisable", function(self) self:SetAlpha(0.45) end)
    check:HookScript("OnEnable", function(self) self:SetAlpha(1) end)

    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ApplyFont(label)
    label:SetPoint("LEFT", check, "RIGHT", 8, 0)
    label:SetText(text)
    label:SetTextColor(unpack(COLORS.text))

    -- Make only this checkbox's own label clickable (not the next column).
    check:SetHitRectInsets(0, -(math.ceil(label:GetStringWidth() or 0) + 8), 0, 0)
    check:SetScript("OnClick", function(self)
        setter(self:GetChecked() and true or false)
    end)

    if tooltip and tooltip ~= "" then
        check:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(text, 1, 1, 1)
            GameTooltip:AddLine(tooltip, nil, nil, nil, true)
            GameTooltip:Show()
        end)
        check:HookScript("OnLeave", function()
            GameTooltip:Hide()
        end)
    end

    function check:Refresh()
        self:SetChecked(getter() and true or false)
    end

    table.insert(UI.controls, check)
    return check, label
end

local function CreateSlider(parent, labelText, x, y, width, minValue, maxValue, step, getter, setter, formatter)
    local label = CreateText(parent, "GameFontNormal", labelText, x, y, width)
    label:SetTextColor(unpack(COLORS.text))

    local valueText = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ApplyFont(valueText, STYLE.caption)
    valueText:SetPoint("TOPRIGHT", parent, "TOPLEFT", x + width, y)
    valueText:SetTextColor(unpack(COLORS.muted))

    local slider = CreateFrame("Slider", nil, parent, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y - 20)
    slider:SetWidth(width)
    slider:SetMinMaxValues(minValue, maxValue)
    slider:SetValueStep(step)
    if slider.SetObeyStepOnDrag then
        slider:SetObeyStepOnDrag(true)
    end

    if slider.Low then slider.Low:SetText("") end
    if slider.High then slider.High:SetText("") end
    if slider.Text then slider.Text:SetText("") end

    slider._refreshing = false

    local function Format(value)
        return formatter and formatter(value) or tostring(value)
    end

    slider:SetScript("OnValueChanged", function(self, value)
        local rounded = math.floor(value / step + 0.5) * step
        valueText:SetText(Format(rounded))
        if self._refreshing then
            return
        end
        setter(rounded)
    end)

    function slider:Refresh()
        self._refreshing = true
        local value = getter()
        self:SetValue(value)
        valueText:SetText(Format(value))
        self._refreshing = false
    end

    table.insert(UI.controls, slider)
    return slider
end

local function CreateChoice(parent, labelText, x, y, width, choices, getter, setter)
    local label = CreateText(parent, "GameFontNormal", labelText, x, y, width)
    label:SetTextColor(unpack(COLORS.text))

    local box = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    box:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y - 24)
    box:SetSize(width, BUTTON_HEIGHT)
    SetBackdrop(box, COLORS.panelAlt, COLORS.border)

    local left = CreateButton(box, "‹", 0, 0, 34, function()
        local current = getter()
        local index = 1
        for i, item in ipairs(choices) do
            if item.key == current then index = i break end
        end
        index = index - 1
        if index < 1 then index = #choices end
        setter(choices[index].key)
        box:Refresh()
    end)

    local right = CreateButton(box, "›", width - 34, 0, 34, function()
        local current = getter()
        local index = 1
        for i, item in ipairs(choices) do
            if item.key == current then index = i break end
        end
        index = index + 1
        if index > #choices then index = 1 end
        setter(choices[index].key)
        box:Refresh()
    end)

    local value = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ApplyFont(value)
    value:SetPoint("LEFT", box, "LEFT", 42, 0)
    value:SetPoint("RIGHT", box, "RIGHT", -42, 0)
    value:SetJustifyH("CENTER")
    value:SetTextColor(unpack(COLORS.text))

    function box:Refresh()
        local current = getter()
        local labelValue = "-"
        for _, item in ipairs(choices) do
            if item.key == current then
                labelValue = item.label
                break
            end
        end
        value:SetText(labelValue)
    end

    table.insert(UI.controls, box)
    return box
end

local function CreateSection(parent, title, x, y, width)
    local titleText = CreateText(parent, "GameFontNormalLarge", title, x, y, width)
    titleText:SetTextColor(unpack(COLORS.text))

    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(COLORS.border[1], COLORS.border[2], COLORS.border[3], 0.85)
    line:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y - 24)
    line:SetSize(width, 1)
    return titleText
end

local function CreateStatusRow(parent, labelText, x, y, width)
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    row:SetSize(width, 30)
    -- Alignment supplies structure; no per-field box or fill.

    local label = CreateText(row, "GameFontHighlightSmall", labelText, 10, -8, 126)
    label:SetTextColor(unpack(COLORS.muted))

    local value = CreateText(row, "GameFontNormal", "-", 142, -7, width - 154)
    value:SetTextColor(unpack(COLORS.text))
    value:SetWordWrap(true)
    row.value = value
    return value
end

local function JoinCandidateNames(identity)
    local names = {}
    for _, candidate in ipairs(identity.candidates or {}) do
        table.insert(names, candidate.value)
    end
    return #names > 0 and table.concat(names, " / ") or "-"
end

-- A reusable, clipped document reader. All dimensions are in UI units.
local function CreateDocumentReader(parent, name, text, left, top, right, bottom)
    local reader = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    reader:SetPoint("TOPLEFT", parent, "TOPLEFT", left, -top)
    reader:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -right, bottom)
    SetBackdrop(reader, COLORS.input, COLORS.border)

    -- The template's scrollbar lives to the right of the scroll frame. Reserve
    -- room inside the reader rather than letting it hang outside the window.
    local scroll = CreateFrame("ScrollFrame", name, reader, "UIPanelScrollFrameTemplate")
    SkinScroll(scroll)
    scroll:SetPoint("TOPLEFT", reader, "TOPLEFT", 12, -12)
    scroll:SetPoint("BOTTOMRIGHT", reader, "BOTTOMRIGHT", -32, 12)
    scroll:EnableMouseWheel(true)
    if reader.SetClipsChildren then reader:SetClipsChildren(true) end

    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(1, 1)
    scroll:SetScrollChild(child)

    local document = child:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    document:SetPoint("TOPLEFT", child, "TOPLEFT", 0, 0)
    document:SetJustifyH("LEFT")
    document:SetJustifyV("TOP")
    document:SetWordWrap(true)
    document:SetNonSpaceWrap(true)
    document:SetSpacing(5)
    document:SetTextColor(unpack(COLORS.text))
    ApplyFont(document, STYLE.body)
    document:SetText(text or "")

    reader.scroll = scroll
    reader.child = child
    reader.document = document
    reader.text = text or ""

    function reader:RefreshLayout()
        if self._layingOut then return end
        local width, height = self.scroll:GetWidth(), self.scroll:GetHeight()
        if not width or width <= 1 or not height or height <= 1 then return end
        self._layingOut = true
        self.child:SetWidth(width)
        self.document:SetWidth(math.max(1, width - 4))
        -- Only anchor the top. A fixed font-string height would crop paragraphs
        -- before the ScrollFrame ever had a chance to scroll to them.
        local textHeight = self.document:GetStringHeight() or 0
        self.child:SetHeight(math.max(height, math.ceil(textHeight) + (self.bottomPadding or STYLE.inset)))
        self.scroll:UpdateScrollChildRect()
        local maximum = math.max(0, self.scroll:GetVerticalScrollRange() or 0)
        local current = self.scroll:GetVerticalScroll() or 0
        self.scroll:SetVerticalScroll(math.max(0, math.min(current, maximum)))
        self._layingOut = false
    end

    function reader:ScrollToTop()
        self:RefreshLayout()
        self.scroll:SetVerticalScroll(0)
    end

    SetPageWheel(scroll)
    -- Preserve the template's scripts for its scrollbar and clipping behavior.
    scroll:HookScript("OnSizeChanged", function() reader:RefreshLayout() end)
    reader:SetScript("OnShow", function()
        reader:RefreshLayout()
        -- A first Show can occur before anchors/font metrics have settled.
        C_Timer.After(0, function()
            if reader:IsVisible() then reader:RefreshLayout() end
        end)
    end)
    return reader
end

-- Settings controls may extend past the viewport, but never past the window.
local function CreateControlPage(content, name, height)
    local page = CreateFrame("Frame", nil, content)
    page:SetAllPoints()
    page:Hide()
    local scroll = CreateFrame("ScrollFrame", name, page, "UIPanelScrollFrameTemplate")
    SkinScroll(scroll)
    scroll:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -26, 8)
    scroll:EnableMouseWheel(true)
    -- Clip to the PAGE, not the scroll frame: its template scrollbar sits
    -- outside the viewport, in the reserved 26-unit right margin.
    if page.SetClipsChildren then page:SetClipsChildren(true) end
    local body = CreateFrame("Frame", nil, scroll)
    body:SetSize(704, height)
    scroll:SetScrollChild(body)
    SetPageWheel(scroll)
    page:SetScript("OnShow", function()
        scroll:UpdateScrollChildRect()
        local maximum = math.max(0, scroll:GetVerticalScrollRange() or 0)
        scroll:SetVerticalScroll(math.min(maximum, scroll:GetVerticalScroll() or 0))
    end)
    page.scroll, page.body = scroll, body
    return page, body
end

function UI:ApplyWindowLayers(raise)
    if not self.frame then return end
    local strata = EC.db and EC.db.panel and EC.db.panel.strata or "FULLSCREEN_DIALOG"
    self.frame:SetFrameStrata(strata)
    self.frame:SetToplevel(true)
    self.frame:SetFrameLevel(math.max(PANEL_FRAME_LEVEL, self.frame:GetFrameLevel()))
    if raise and self.frame:IsShown() then self.frame:Raise() end
    -- Reapply explicit modal levels after Raise; they must stay above our own
    -- scrolling pages even when the player changes the settings-window strata.
    local base = self.frame:GetFrameLevel()
    if self.usageDialog then
        self.usageDialog:SetFrameStrata(strata)
        self.usageDialog:SetFrameLevel(base + 40)
    end
    if self.positionConfirm then
        self.positionConfirm:SetFrameStrata(strata)
        self.positionConfirm:SetFrameLevel(base + 80)
        self.positionConfirm.dialog:SetFrameLevel(base + 81)
    end
end

function UI:FitPanelToScreen()
    if not self.frame then return end
    local width, height = UIParent:GetWidth(), UIParent:GetHeight()
    self.frame:SetScale(math.min(1, math.max(0.1, (width - 24) / 900),
        math.max(0.1, (height - 24) / 760)))
end

function UI:CanAdjustPosition(announce)
    local inBoss = EC.Runtime and EC.Runtime:IsEncounterRunning()
    local inCombat = (EC.Runtime and EC.Runtime.combatActive)
        or (InCombatLockdown and InCombatLockdown())
    if inBoss or inCombat then
        if announce then
            print("|cffffc857[奶龙打地鼠]|r 请在战斗结束后调整位置，当前设置未改变。")
        end
        return false
    end
    return EC.state.dbReady == true
end

function UI:CancelPositionConfirmation()
    self.pendingPositionAction = nil
    if self.positionConfirm then self.positionConfirm:Hide() end
end

function UI:CreatePositionConfirmation()
    if self.positionConfirm then return end
    -- A panel-local mouse shield prevents a second underlying button click.
    -- Hiding the panel, changing page or pressing Escape cancels the request.
    local overlay = CreateFrame("Frame", "EvokerCuePositionConfirmFrame", self.frame, "BackdropTemplate")
    overlay:SetAllPoints(self.frame)
    overlay:EnableMouse(true)
    overlay:EnableMouseWheel(true)
    overlay:SetScript("OnMouseWheel", function() end)
    overlay:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    overlay:SetBackdropColor(0, 0, 0, 0.55)
    overlay:Hide()

    local dialog = CreateFrame("Frame", nil, overlay, "BackdropTemplate")
    dialog:SetSize(464, 184)
    dialog:SetPoint("CENTER", overlay, "CENTER", 0, 0)
    dialog:EnableMouse(true)
    SetBackdrop(dialog, COLORS.bg, COLORS.accent)
    overlay.dialog = dialog
    overlay.question = CreateText(dialog, "GameFontNormalLarge", "", 22, -26, 420)
    overlay.question:SetTextColor(unpack(COLORS.text))
    overlay.detail = CreateText(dialog, "GameFontHighlight", "", 22, -68, 420)
    overlay.detail:SetTextColor(unpack(COLORS.muted))
    overlay.detail:SetWordWrap(true)
    overlay.detail:SetNonSpaceWrap(true)
    overlay.confirmButton = CreateButton(dialog, "确定", 78, -128, 142, function()
        local action = UI.pendingPositionAction
        UI:CancelPositionConfirmation()
        -- An encounter might start while the confirmation window is open.
        if not action or not UI:CanAdjustPosition(true) then return end
        action()
        UI:Refresh()
    end)
    overlay.cancelButton = CreateButton(dialog, "取消", 244, -128, 142, function()
        UI:CancelPositionConfirmation()
    end)
    overlay:SetScript("OnHide", function() UI.pendingPositionAction = nil end)
    self.positionConfirm = overlay
    table.insert(UISpecialFrames, "EvokerCuePositionConfirmFrame")
    self:ApplyWindowLayers(false)
end

function UI:RequestPositionChange(kind)
    if not self.frame or not self.frame:IsShown() or not self:CanAdjustPosition(true) then return false end
    local actions = {
        reminderReset = { "确定重置提醒区位置？", "恢复提醒区的默认位置，不影响记录区和其他设置。",
            function() if EC.AlertUI then EC.AlertUI:ResetPosition() end end },
        reminderCenter = { "确定水平居中提醒区？", "只调整左右位置，上下位置保持不变。",
            function() if EC.AlertUI then EC.AlertUI:HorizontalCenter() end end },
        trackerReset = { "确定重置记录区位置？", "恢复记录区的默认位置，不影响提醒区和其他设置。",
            function() if EC.TrackerHUD then EC.TrackerHUD:ResetPosition() end end },
        trackerCenter = { "确定水平居中记录区？", "只调整左右位置，上下位置保持不变。",
            function() if EC.TrackerHUD then EC.TrackerHUD:CenterHorizontally() end end },
    }
    local selected = actions[kind]
    if not selected then return false end
    self:CreatePositionConfirmation()
    self.pendingPositionAction = selected[3]
    self.positionConfirm.question:SetText(selected[1])
    self.positionConfirm.detail:SetText(selected[2])
    self:ApplyWindowLayers(false)
    self.positionConfirm:Show()
    return true
end

function UI:StartHUDTest()
    -- The existing MRT_TEST session already starts both the timeline and the
    -- actual cast tracker. Never fabricate successful casts for a visual test.
    if not EC.Timeline then return false end
    local started = EC.Timeline:StartCurrentMRTTest()
    if started and EC.TrackerHUD then
        EC.TrackerHUD:CancelPreview()
        EC.TrackerHUD:Update()
    end
    self:RefreshRuntime()
    return started
end

function UI:StopHUDTest()
    if not EC.Timeline then return false end
    local stopped = EC.Timeline:StopTest()
    if stopped and EC.TrackerHUD then
        EC.TrackerHUD:CancelPreview()
        EC.TrackerHUD:Update()
    end
    self:RefreshRuntime()
    return stopped
end

function UI:SavePosition()
    if not self.frame or not EC.state.dbReady then
        return
    end

    local point, _, relativePoint, x, y = self.frame:GetPoint(1)
    EC.db.panel.point = point or "CENTER"
    EC.db.panel.relativePoint = relativePoint or "CENTER"
    EC.db.panel.x = math.floor((x or 0) + 0.5)
    EC.db.panel.y = math.floor((y or 0) + 0.5)
end

function UI:RestorePosition()
    if not self.frame or not EC.state.dbReady then
        return
    end

    self.frame:ClearAllPoints()
    self.frame:SetPoint(
        EC.db.panel.point or "CENTER",
        UIParent,
        EC.db.panel.relativePoint or "CENTER",
        EC.db.panel.x or 0,
        EC.db.panel.y or 0
    )
end

function UI:CreateHeader(frame)
    local header = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    header:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -1)
    header:SetHeight(62)
    header:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    header:SetBackdropColor(unpack(COLORS.panel))

    local accent = header:CreateTexture(nil, "ARTWORK")
    accent:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT", 0, 0)
    accent:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", 0, 0)
    accent:SetHeight(1)
    accent:SetColorTexture(unpack(COLORS.accent))

    local title = CreateText(header, "GameFontNormalHuge", EC.DISPLAY_NAME or "奶龙打地鼠", 20, -11)
    title:SetTextColor(unpack(COLORS.text))

    local subtitle = CreateText(header, "GameFontHighlightSmall", "EvokerCue · 奶龙个人技能轴提醒", 20, -38)
    subtitle:SetTextColor(unpack(COLORS.muted))

    local close = CreateFrame("Button", nil, header)
    close:SetSize(32, 32)
    close:SetPoint("RIGHT", header, "RIGHT", -12, 0)
    close.label = close:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    close.label:SetPoint("CENTER", 0, 1)
    close.label:SetText("×")
    close.label:SetTextColor(unpack(COLORS.muted))
    close:SetScript("OnEnter", function(self) self.label:SetTextColor(unpack(COLORS.red)) end)
    close:SetScript("OnLeave", function(self) self.label:SetTextColor(unpack(COLORS.muted)) end)
    close:SetScript("OnClick", function() frame:Hide() end)

    self.headerEnabledCheck = CreateCheckbox(
        header,
        "启用",
        0,
        0,
        function() return EC.db and EC.db.enabled end,
        function(value)
            EC:SetEnabled(value)
            UI:Refresh()
        end
    )
    self.headerEnabledCheck:ClearAllPoints()
    self.headerEnabledCheck:SetPoint("RIGHT", close, "LEFT", -54, 0)
    self.headerEnabledCheck:SetHitRectInsets(0, -46, 0, 0)

    local version = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ApplyFont(version, STYLE.caption)
    version:SetPoint("RIGHT", self.headerEnabledCheck, "LEFT", -18, 0)
    version:SetText(EC.RELEASE_LABEL or "正式版")
    self.versionLabel = version
    version:SetTextColor(unpack(COLORS.muted))

    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() frame:StartMoving() end)
    header:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        UI:SavePosition()
    end)
end

function UI:CreateNavigation(frame)
    local nav = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    nav:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -63)
    nav:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 1, 44)
    nav:SetWidth(146)
    nav:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    nav:SetBackdropColor(unpack(COLORS.panel))

    local items = {
        { key = "overview", label = "概览" },
        { key = "timeline", label = "时间轴" },
        { key = "reminder", label = "功能" },
        { key = "interface", label = "界面" },
        { key = "sound", label = "声音" },
        { key = "feedback", label = "反馈" },
    }

    for index, item in ipairs(items) do
        local button = CreateFrame("Button", nil, nav, "BackdropTemplate")
        button:SetPoint("TOPLEFT", nav, "TOPLEFT", 10, -18 - (index - 1) * 38)
        button:SetSize(126, 34)
        button:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
        button:SetBackdropColor(0, 0, 0, 0)

        button.indicator = button:CreateTexture(nil, "ARTWORK")
        button.indicator:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
        button.indicator:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
        button.indicator:SetWidth(3)
        button.indicator:SetColorTexture(unpack(COLORS.accent))
        button.indicator:Hide()

        button.label = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        ApplyFont(button.label)
        button.label:SetPoint("LEFT", button, "LEFT", 14, 0)
        button.label:SetText(item.label)
        button.label:SetTextColor(unpack(COLORS.muted))

        button:SetScript("OnClick", function() UI:ShowPage(item.key) end)
        button:SetScript("OnEnter", function(self)
            if UI.activePage ~= item.key then
                self:SetBackdropColor(unpack(COLORS.buttonHover))
                self.label:SetTextColor(unpack(COLORS.text))
            end
        end)
        button:SetScript("OnLeave", function(self)
            if UI.activePage ~= item.key then
                self:SetBackdropColor(0, 0, 0, 0)
                self.label:SetTextColor(unpack(COLORS.muted))
            end
        end)
        self.navButtons[item.key] = button
    end

    local footer = nav:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ApplyFont(footer, STYLE.caption)
    footer:SetPoint("BOTTOM", nav, "BOTTOM", 0, 18)
    footer:SetWidth(116)
    footer:SetJustifyH("CENTER")
    footer:SetText("作者：韶光逍珑")
    footer:SetTextColor(unpack(COLORS.faint))
end

function UI:CreateOverviewPage(content)
    local page = CreateFrame("Frame", nil, content)
    page:SetAllPoints()
    self.pages.overview = page

    local scroll = CreateFrame("ScrollFrame", nil, page, "UIPanelScrollFrameTemplate")
    SkinScroll(scroll)
    scroll:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -26, 0)

    local body = CreateFrame("Frame", nil, scroll)
    body:SetSize(704, 1080)
    scroll:SetScrollChild(body)
    self.overviewBody = body
    self.overviewScroll = scroll
    SetPageWheel(scroll)
    if page.SetClipsChildren then page:SetClipsChildren(true) end

    CreateSection(body, "当前战术板", 24, -24, 660)
    self.usageButton = CreateButton(body, "使用说明", 544, -16, 140, function() UI:ShowUsageGuide() end)
    self.overviewSummary = CreateText(body, "GameFontHighlightSmall", "尚未读取", 24, -60, 660)
    self.overviewSummary:SetSpacing(3)
    self.overviewStatus = {}
    self.overviewRows = {}
    for _, item in ipairs({ { "mrt", "来源" }, { "note", "战术板" }, { "character", "当前角色" },
        { "mode", "识别方式" }, { "matched", "战术板名字" }, { "parse", "个人时间轴" } }) do
        local value = CreateStatusRow(body, item[2], 24, 0, 660)
        self.overviewStatus[item[1]] = value
        self.overviewRows[#self.overviewRows + 1] = value:GetParent()
    end
    local readActions = CreateFrame("Frame", nil, body)
    readActions:SetSize(660, 32)
    self.overviewReadActions = readActions
    self.autoRefreshCheck = CreateCheckbox(readActions, "自动读取战术板更新", 0, -4,
        function() return EC.db and EC.db.autoRefresh end,
        function(value) EC.db.autoRefresh = value end)
    CreateButton(readActions, "重新读取", 520, 0, 140, function()
        EC:RefreshCurrentNote("手动刷新", true, true)
    end)
    local skills = CreateFrame("Frame", nil, body)
    skills:SetSize(704, 150)
    self.overviewSkills = skills
    CreateSection(skills, "技能安排", 24, 0, 660)
    self.skillCounts = {}
    local entries = { { "STASIS", "静滞" }, { "DREAM_BREATH", "梦境吐息" },
        { "RELEASE_STASIS", "释放静滞" }, { "REWIND", "回溯" }, { "ZEPHYR", "微风" },
        { "SPATIAL_PARADOX", "空间悖论" }, { "TIME_SPIRAL", "时间螺旋" }, { "TOTAL", "个人安排总数" } }
    for i, item in ipairs(entries) do
        local x, y = 24 + ((i - 1) % 4) * 169, -40 - math.floor((i - 1) / 4) * 32
        CreateText(skills, "GameFontHighlightSmall", item[2], x, y, 108)
        local value = CreateText(skills, "GameFontHighlight", "0", x + 112, y, 36)
        value:SetJustifyH("RIGHT")
        self.skillCounts[item[1]] = value
    end
    self.summaryText = CreateText(skills, "GameFontHighlightSmall", "", 24, -110, 660)
    self.summaryText:SetSpacing(4)

    local details = CreateFrame("Frame", nil, body)
    details:SetSize(704, 580)
    self.overviewDetails = details
    CreateSection(details, "运行范围", 26, 0, 660)
    self.zoneOnlyCheck = CreateCheckbox(details, "仅在12.1团队副本中运行", 26, -38,
        function() return EC.db and EC.db.runtime.onlyVenomousAbyss end,
        function(value)
            EC.db.runtime.onlyVenomousAbyss = value
            if EC.Runtime then EC.Runtime:RefreshAfterSettings() end
            UI:Refresh()
        end,
        "开启后，仅在烈毒之渊、潮缚石窟、基希克斯破封显示记录框、提醒框或预览，并播放战斗语音；关闭后可在其他区域使用。")
    self.combatOnlyCheck = CreateCheckbox(details, "仅战斗中显示", 26, -74,
        function() return EC.db and EC.db.runtime.combatOnly end,
        function(value)
            EC.db.runtime.combatOnly = value
            if EC.Runtime then EC.Runtime:RefreshAfterSettings() end
            UI:Refresh()
        end,
        "开启后，战前预铺仍会在后台记录，开怪后继承；关闭可脱战测试。区域限制仍然生效，首领战中死亡和战复不清记录。")
    self.runtimeText = CreateText(details, "GameFontHighlight", "当前状态：-", 26, -112, 500)
    self.runtimeText:SetTextColor(unpack(COLORS.muted))
    self.runtimeText:SetSpacing(6)
    self.prepullResetButton = CreateButton(details, "清空预铺", 546, -102, 140, function()
        if EC.Runtime and EC.Runtime.ResetPrepullState then
            EC.Runtime:ResetPrepullState("设置面板清空预铺", true)
        end
    end)

    local extra = CreateFrame("Frame", nil, details)
    extra:SetWidth(704)
    self.overviewExtra = extra
    CreateSection(extra, "战术板名字", 26, 0, 660)
    self.identityGameText = CreateText(extra, "GameFontNormal", "当前角色：-", 26, -38, 660)
    self.identityGameText:SetTextColor(unpack(COLORS.text))
    self.customNameCheck = CreateCheckbox(extra, "使用自定义名字", 26, -74,
        function() return EC.db and EC.db.identity.useCustomName end,
        function(value)
            EC:SetUseCustomName(value)
            EC:RefreshCurrentNote("名字设置", true, false)
            UI:Refresh()
        end,
        "战术板使用其他名字时才需开启。")

    self.customNameEdit = CreateEditBox(extra, 26, -114, 360, 36)
    self.customNameEdit:SetMaxLetters(48)
    self.customNameEdit:SetTextInsets(10, 10, 0, 0)

    local function ApplyCustomName()
        EC:SetCustomName(UI.customNameEdit:GetText())
        UI.customNameEdit:ClearFocus()
        EC:RefreshCurrentNote("名字设置", true, false)
        UI:Refresh()
    end
    self.customNameEdit:SetScript("OnEnterPressed", ApplyCustomName)
    self.customNameEdit:SetScript("OnEscapePressed", function(self)
        self:SetText(EC.db.identity.customName or "")
        self:ClearFocus()
    end)
    CreateButton(extra, "应用", 406, -117, 120, ApplyCustomName)
    CreateButton(extra, "自动识别", 540, -117, 146, function()
        EC:SetUseCustomName(false)
        EC:RefreshCurrentNote("自动识别", true, false)
        UI:Refresh()
    end)
    CreateSection(extra, "问题反馈", 26, -194, 660)
    self.diagnosticCheck = CreateCheckbox(extra, "保存反馈日志（含角色名与战术板原文）", 26, -232,
        function() return EC.db and EC.db.diagnostics.enabled end,
        function(value) if EC.Diagnostics then EC.Diagnostics:SetEnabled(value) end end,
        "默认开启，仅保存在本机，不会自动上传。最多保留最近 20 场首领记录。")
    CreateButton(extra, "查看反馈说明", 546, -228, 140, function()
        UI:ShowPage("feedback")
    end)
    local help = CreateText(extra, "GameFontHighlightSmall",
        "反馈 QQ 群：251935247\n本场结束后 /reload，再取日志；提交方法见“反馈”。\n欢迎提交正常场次日志和功能建议。", 26, -278, 660)
    self.overviewHelp = help
    help:SetSpacing(6)
    help:SetTextColor(unpack(COLORS.muted))

    self.prepullResetButton:SetVariant("quiet")
    page:SetScript("OnShow", function() UI:LayoutOverview() end)

end

function UI:CreateTimelinePage(content)
    local holder, page = CreateControlPage(content, "EvokerCueTimelineScroll", 1180)
    self.pages.timeline = holder
    self.timelineBody = page
    CreateSection(page, "战术板来源", 22, -22, 642)
    self.sourceChecks = {}
    local sourceChoices = {
        { key = "MRT_RAID", label = "MRT当前方案（团队）" },
        { key = "MRT_SELF", label = "MRT个人方案（个人）" },
        { key = "MRT_BOTH", label = "MRT两者（团队+个人）" },
        { key = "RAIDARY", label = "Raidary Plan（专属战术板）" },
        { key = "NSRT", label = "NSRT" },
        { key = "DFT", label = "DFT" },
    }
    for i, choice in ipairs(sourceChoices) do
        local selectedSource = choice.key
        self.sourceChecks[selectedSource] = CreateCheckbox(page, choice.label, i <= 3 and STYLE.columnLeft or STYLE.columnRight, -60 - ((i - 1) % 3) * 36,
            function() return EC.PlanSources:GetSelected() == selectedSource end,
            function() EC.PlanSources:SetSelected(selectedSource); UI:Refresh() end)
    end
    self.sourceStatus = CreateText(page, "GameFontHighlightSmall", "尚未读取", STYLE.columnLeft, -168, 660)
    self.sourceStatus:SetSpacing(4)
    CreateText(page, "GameFontHighlightSmall", "MRT 直接读取自身数据。来源和别名脱战立即生效，战斗中下场生效。\nDFT：脱战读当前打开方案；开怪读该首领和难度已载入的方案。", STYLE.columnLeft, -220, 660)
    CreateSection(page, "自定义技能名称", STYLE.columnLeft, -282, 660)
    self.aliasHelp = CreateText(page, "GameFontHighlightSmall",
        "额外别名用中英文逗号或分号分隔。内置名称和技能 ID 始终保留。", STYLE.columnLeft, -320, 660)
    self.aliasHelp:SetSpacing(4)
    self.aliasEdits = {}
    self.builtinAliasLabels = {}
    local rowTop = 320 + self.aliasHelp:GetStringHeight() + 18
    for _, key in ipairs(EC.Parser:GetEnabledSkillKeys()) do
        local def = EC.Parser:GetSkillDefinition(key)
        local y = -rowTop
        CreateText(page, "GameFontHighlight", def.name, 22, y - 8, 124)
        local edit = CreateEditBox(page, 152, y, 490)
        edit:SetMaxLetters(512)
        self.aliasEdits[key] = edit
        local builtin = CreateText(page, "GameFontHighlightSmall",
            "内置（不可修改）：" .. table.concat(def.aliases, "、"), 152, y - 36, 490)
        builtin:SetTextColor(unpack(COLORS.muted))
        self.builtinAliasLabels[key] = builtin
        rowTop = rowTop + math.max(66, 36 + builtin:GetStringHeight() + 12)
    end
    local saveTop = rowTop + 12
    self.saveAliasesButton = CreateButton(page, "保存技能别名", 22, -saveTop, 166, function()
        local values = {}
        for key, edit in pairs(UI.aliasEdits) do values[key] = edit:GetText(); edit:ClearFocus() end
        EC.Parser:SetCustomAliases(values)
        UI:Refresh()
    end)
    self.aliasStatusTop = saveTop + 3
    self.timelineMinTop = saveTop + 78
    self.aliasStatus = CreateText(page, "GameFontHighlightSmall", "", 206, -self.aliasStatusTop, 432)
    self.aliasStatus:SetSpacing(4)

    local area = CreateFrame("Frame", nil, page)
    area:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -self.timelineMinTop)
    area:SetSize(704, 300)
    self.timelineArea = area
    CreateSection(area, "个人时间轴", 22, -22, 642)

    self.timelineSummary = CreateText(area, "GameFontHighlightSmall", "尚未读取", 22, -58, 642)
    self.timelineSummary:SetTextColor(unpack(COLORS.muted))

    local header = CreateFrame("Frame", nil, area, "BackdropTemplate")
    header:SetPoint("TOPLEFT", area, "TOPLEFT", 22, -86)
    header:SetSize(642, 28)
    SetBackdrop(header, { 0.060, 0.073, 0.090, 1.00 }, COLORS.border)

    local columns = {
        { text = "时间", x = 10, width = 72 },
        { text = "波次", x = 86, width = 54 },
        { text = "技能", x = 144, width = 160 },
        { text = "绿喷安排", x = 308, width = 86 },
        { text = "位置", x = 398, width = 66 },
        { text = "战术板内容", x = 468, width = 164 },
    }

    for _, column in ipairs(columns) do
        local text = CreateText(header, "GameFontHighlightSmall", column.text, column.x, -8, column.width)
        text:SetTextColor(unpack(COLORS.muted))
    end

    local child = CreateFrame("Frame", nil, area)
    child:SetPoint("TOPLEFT", area, "TOPLEFT", 22, -116)
    child:SetSize(622, 1)
    self.timelineChild = child
    self.timelineEmpty = CreateText(child, "GameFontHighlight", "当前没有可显示的个人技能安排。", 14, -20, 580)
    self.timelineEmpty:SetTextColor(unpack(COLORS.muted))
end

function UI:CreateReminderPage(content)
    -- Internal page key remains "reminder" for compatibility; visible name is 功能.
    local page, body = CreateControlPage(content, "EvokerCueFunctionScroll", 714)
    self.pages.reminder = page

    CreateSection(body, "下方 · 技能提醒", 26, -28, 660)
    self.reminderEnabledCheck = CreateCheckbox(body, "启用技能提醒", 26, -66,
        function() return EC.db and EC.db.reminder.enabled end,
        function(value)
            EC.db.reminder.enabled = value
            if EC.Voice then EC.Voice:Prune() end
            if not value and EC.AlertUI and EC.AlertUI.Clear then
                EC.AlertUI:Clear()
            elseif EC.AlertUI then EC.AlertUI:RefreshVisibility() end
            UI:RefreshRuntime()
        end, "按当前战术板提醒技能；关闭不影响上方记录和实际绿喷计数。")

    self.leadTimeSlider = CreateSlider(body, "提前显示", STYLE.columnLeft, -116, STYLE.columnWidth, 0.5, 8.0, 0.1,
        function() return EC.db.reminder.leadTime end,
        function(value) EC.db.reminder.leadTime = value end,
        function(value) return string.format("%.1f 秒", value) end)
    self.postHoldSlider = CreateSlider(body, "到点后保留", STYLE.columnRight, -116, STYLE.columnWidth, 0.2, 2.0, 0.1,
        function() return EC.db.reminder.postHold end,
        function(value) EC.db.reminder.postHold = value end,
        function(value) return string.format("%.1f 秒", value) end)
    self.earlyWarningSlider = CreateSlider(body, "绿喷过早警告", STYLE.columnLeft, -188, STYLE.columnWidth, 5.0, 15.0, 0.5,
        function() return EC.db.reminder.earlyWarningThreshold end,
        function(value) EC.db.reminder.earlyWarningThreshold = value end,
        function(value) return string.format("%.1f 秒", value) end)
    self.maxRowsSlider = CreateSlider(body, "最多同时显示", STYLE.columnRight, -188, STYLE.columnWidth, 3, 8, 1,
        function() return EC.db.reminder.maxRows end,
        function(value)
            EC.db.reminder.maxRows = math.floor(value + 0.5)
            if EC.AlertUI then EC.AlertUI:RefreshVisibility() end
        end,
        function(value) return string.format("%d 条", math.floor(value + 0.5)) end)
    self.reminderScaleSlider = CreateSlider(body, "提醒 UI 缩放", STYLE.columnLeft, -260, STYLE.columnWidth, 0.70, 1.50, 0.05,
        function() return EC.db.reminder.scale end,
        function(value)
            EC.db.reminder.scale = value
            if EC.AlertUI then EC.AlertUI:ApplySettings() end
        end,
        function(value) return string.format("%d%%", math.floor(value * 100 + 0.5)) end)
    self.reminderOpacitySlider = CreateSlider(body, "提醒 UI 透明度", STYLE.columnRight, -260, STYLE.columnWidth, 0.40, 1.00, 0.05,
        function() return EC.db.reminder.opacity end,
        function(value)
            EC.db.reminder.opacity = value
            if EC.AlertUI then EC.AlertUI:ApplySettings() end
        end,
        function(value) return string.format("%d%%", math.floor(value * 100 + 0.5)) end)

    CreateSection(body, "上方 · 记录 HUD", 26, -344, 660)
    self.trackerEnabledCheck = CreateCheckbox(body, "启用记录 HUD", 26, -382,
        function() return EC.db and EC.db.tracker.hud.enabled end,
        function(value)
            EC.db.tracker.hud.enabled = value
            if EC.TrackerHUD then EC.TrackerHUD:Update() end
        end, "控制上方记录框的显示；隐藏后不清空已记录的次数。")
    self.trackerIconCheck = CreateCheckbox(body, "显示技能图标", STYLE.columnLeft, -420,
        function() return EC.db and EC.db.tracker.hud.showIcon end,
        function(value)
            EC.db.tracker.hud.showIcon = value
            if EC.TrackerHUD then EC.TrackerHUD:ApplySettings(); EC.TrackerHUD:Update() end
        end)
    self.trackerRemainingCheck = CreateCheckbox(body, "显示剩余次数", STYLE.columnRight, -420,
        function() return EC.db and EC.db.tracker.hud.showRemaining end,
        function(value)
            EC.db.tracker.hud.showRemaining = value
            if EC.TrackerHUD then EC.TrackerHUD:ApplySettings(); EC.TrackerHUD:Update() end
        end)
    self.trackerScaleSlider = CreateSlider(body, "记录 HUD 缩放", STYLE.columnLeft, -472, STYLE.columnWidth, 0.70, 1.50, 0.05,
        function() return EC.db.tracker.hud.scale end,
        function(value)
            EC.db.tracker.hud.scale = value
            if EC.TrackerHUD then EC.TrackerHUD:ApplySettings(); EC.TrackerHUD:Update() end
        end,
        function(value) return string.format("%d%%", math.floor(value * 100 + 0.5)) end)
    self.trackerOpacitySlider = CreateSlider(body, "记录 HUD 透明度", STYLE.columnRight, -472, STYLE.columnWidth, 0.40, 1.00, 0.05,
        function() return EC.db.tracker.hud.opacity end,
        function(value)
            EC.db.tracker.hud.opacity = value
            if EC.TrackerHUD then EC.TrackerHUD:ApplySettings(); EC.TrackerHUD:Update() end
        end,
        function(value) return string.format("%d%%", math.floor(value * 100 + 0.5)) end)
    CreateSection(body, "独立技能辅助", 26, -554, 660)
    self.heartFireCheck = CreateCheckbox(body, "心火监控", 26, -592,
        function() return EC.db and EC.db.heartFire.enabled end,
        function(value) EC.HeartFireMonitor:SetEnabled(value) end,
        "施放静滞后显示15秒红色倒计时圆环；脱战和副本外均可触发。")
    CreateText(body, "GameFontHighlightSmall", "施放静滞后显示15秒红色倒计时圆环；释放静滞不会重新计时。", 54, -638, 620)
end

function UI:CreateInterfacePage(content)
    local page, body = CreateControlPage(content, "EvokerCueInterfaceScroll", 810)
    self.pages.interface = page

    CreateSection(body, "提醒区 · 下方", 26, -28, 660)
    self.reminderLockCheck = CreateCheckbox(body, "锁定提醒区位置", 26, -66,
        function() return EC.db and EC.db.reminder.locked end,
        function(value)
            if not value and not UI:CanAdjustPosition(true) then UI.reminderLockCheck:Refresh(); return end
            if value and EC.AlertUI then EC.AlertUI:SavePosition() end
            EC.db.reminder.locked = value
            if EC.AlertUI then EC.AlertUI:ApplySettings() end
        end, "关闭后可拖动提醒区；战斗中不能解锁。")
    self.reminderPreviewButton = CreateButton(body, "预览密集提醒", 26, -106, 196, function()
        if EC.Timeline then EC.Timeline:StartDensePreview() end
    end)
    self.reminderResetButton = CreateButton(body, "提醒区重置位置", 246, -106, 196, function()
        UI:RequestPositionChange("reminderReset")
    end)
    self.reminderCenterButton = CreateButton(body, "提醒区水平居中", 466, -106, 196, function()
        UI:RequestPositionChange("reminderCenter")
    end)

    CreateSection(body, "记录区 · 上方", 26, -168, 660)
    self.trackerLockCheck = CreateCheckbox(body, "锁定记录区位置", 26, -206,
        function() return EC.db and EC.db.tracker.hud.locked end,
        function(value)
            if not value and not UI:CanAdjustPosition(true) then UI.trackerLockCheck:Refresh(); return end
            if EC.TrackerHUD then EC.TrackerHUD:SetLocked(value)
            else EC.db.tracker.hud.locked = value end
            UI:RefreshTrackerStatus()
        end, "关闭后可拖动记录区；战斗中不能解锁。")
    self.trackerPreviewButton = CreateButton(body, "预览记录 HUD", 26, -246, 196, function()
        if EC.TrackerHUD then EC.TrackerHUD:ShowPreview(4.0) end
    end)
    self.trackerResetButton = CreateButton(body, "记录区重置位置", 246, -246, 196, function()
        UI:RequestPositionChange("trackerReset")
    end)
    self.trackerCenterButton = CreateButton(body, "记录区水平居中", 466, -246, 196, function()
        UI:RequestPositionChange("trackerCenter")
    end)

    CreateSection(body, "显示层级", 26, -308, 660)
    local note = CreateText(body, "GameFontHighlightSmall",
        "如果某个提醒被其他插件挡住，可以单独把它的显示层级调高。", 26, -342, 660)
    note:SetTextColor(unpack(COLORS.muted))
    self.panelStrataChoice = CreateChoice(body, "设置窗口", STYLE.columnLeft, -380, STYLE.columnWidth,
        EC.UI_LEVEL_CHOICES,
        function() return EC.db.panel.strata end,
        function(value)
            EC.db.panel.strata = value
            UI:ApplyWindowLayers(true)
        end)
    self.trackerStrataChoice = CreateChoice(body, "记录 HUD", STYLE.columnRight, -380, STYLE.columnWidth,
        EC.UI_LEVEL_CHOICES,
        function() return EC.db.tracker.hud.strata end,
        function(value)
            EC.db.tracker.hud.strata = value
            if EC.TrackerHUD then EC.TrackerHUD:ApplySettings(); EC.TrackerHUD:Update() end
        end)
    self.reminderStrataChoice = CreateChoice(body, "技能提醒", STYLE.columnLeft, -456, STYLE.columnWidth,
        EC.UI_LEVEL_CHOICES,
        function() return EC.db.reminder.strata end,
        function(value)
            EC.db.reminder.strata = value
            if EC.AlertUI then EC.AlertUI:ApplySettings() end
        end)
    self.emergencyStrataChoice = CreateChoice(body, "取消蓄力警告", STYLE.columnRight, -456, STYLE.columnWidth,
        EC.UI_LEVEL_CHOICES,
        function() return EC.db.reminder.emergencyStrata end,
        function(value)
            EC.db.reminder.emergencyStrata = value
            if EC.AlertUI then EC.AlertUI:ApplySettings() end
        end)

    CreateSection(body, "战术板测试", 26, -552, 660)
    self.testBothButton = CreateButton(body, "测试当前战术板", 26, -592, 196, function() UI:StartHUDTest() end)
    self.stopBothButton = CreateButton(body, "停止测试", 246, -592, 196, function() UI:StopHUDTest() end)
    local testHint = CreateText(body, "GameFontHighlightSmall",
        "同时测试上下两个框；记录框按你的实际施法计数。", 26, -640, 660)
    testHint:SetTextColor(unpack(COLORS.muted))
    self.reminderRuntime = CreateFrame("Frame", nil, body, "BackdropTemplate")
    self.reminderRuntime:SetPoint("TOPLEFT", body, "TOPLEFT", 26, -680)
    self.reminderRuntime:SetSize(660, 100)
    SetBackdrop(self.reminderRuntime, COLORS.panelAlt, COLORS.border)
    self.reminderRuntimeText = CreateText(self.reminderRuntime, "GameFontHighlightSmall", "", 12, -12, 634)
    self.reminderRuntimeText:SetTextColor(unpack(COLORS.muted))
    self.reminderRuntimeText:SetWordWrap(true)
    self.reminderRuntimeText:SetNonSpaceWrap(true)
    self.reminderRuntimeText:SetSpacing(5)
end

function UI:CreateSoundPage(content)
    local holder, page = CreateControlPage(content, "EvokerCueSoundScroll", 720)
    self.pages.sound = holder

    CreateSection(page, "语音提醒", 26, -28, 660)
    CreateText(page, "GameFontHighlightSmall", "声音测试可在副本外使用；测试前请开启插件总开关。", 26, -698, 660)
    self.voiceEnabledCheck = CreateCheckbox(page, "启用语音提醒", 26, -66,
        function() return EC.db and EC.db.voice and EC.db.voice.enabled end,
        function(value) EC.db.voice.enabled = value; if EC.Voice then EC.Voice:Prune() end end,
        "关闭后不会播放奶龙打地鼠的语音文件。")
    self.voiceNormalCheck = CreateCheckbox(page, "普通技能语音", STYLE.columnLeft, -102,
        function() return EC.db and EC.db.voice and EC.db.voice.normalEnabled end,
        function(value) EC.db.voice.normalEnabled = value; if EC.Voice then EC.Voice:Prune() end end,
        "静滞、绿喷、释放静滞、回溯、微风、空间悖论、时间螺旋。")
    self.voiceCorrectionCheck = CreateCheckbox(page, "绿喷纠错语音", STYLE.columnRight, -102,
        function() return EC.db and EC.db.voice and EC.db.voice.correctionEnabled end,
        function(value) EC.db.voice.correctionEnabled = value; if EC.Voice then EC.Voice:Prune() end end,
        "先别喷、绿喷晚啦、取消绿喷。")
    self.voiceChannel = CreateChoice(page, "语音通道", STYLE.columnLeft, -150, STYLE.columnWidth,
        EC.SOUND_CHANNELS,
        function() return EC.db.voice.channel end,
        function(value) EC.db.voice.channel = value end)

    CreateSection(page, "普通技能语音测试", 26, -232, 660)
    local skillTests = {
        { "绿喷", "DREAM_BREATH" }, { "静滞", "STASIS" }, { "释放静滞", "RELEASE_STASIS" },
        { "回溯", "REWIND" }, { "微风", "ZEPHYR" }, { "空间悖论", "SPATIAL_PARADOX" },
        { "时间螺旋", "TIME_SPIRAL" },
    }
    for index, item in ipairs(skillTests) do
        local column = (index - 1) % 3
        local row = math.floor((index - 1) / 3)
        CreateButton(page, item[1], 26 + column * 220, -270 - row * 40, 196, function()
            if EC.Voice and EC.Voice.PlaySkill then EC.Voice:PlaySkill(item[2], true) end
        end)
    end

    CreateSection(page, "绿喷纠错语音测试", 26, -398, 660)
    local correctionTests = { { "先别喷", "EARLY" }, { "绿喷晚啦", "LATE" }, { "取消绿喷", "CANCEL" } }
    for index, item in ipairs(correctionTests) do
        CreateButton(page, item[1], 26 + (index - 1) * 220, -436, 196, function()
            if EC.Voice and EC.Voice.PlaySpecial then EC.Voice:PlaySpecial(item[2], true, true) end
        end)
    end

    CreateSection(page, "紧急警告音", 26, -500, 660)
    self.soundEnabledCheck = CreateCheckbox(page, "启用备用警告音", 26, -538,
        function() return EC.db and EC.db.sound.enabled end,
        function(value) EC.db.sound.enabled = value end,
        "当“取消绿喷”语音关闭时，继续使用原来的紧急警告音。")
    self.soundChoice = CreateChoice(page, "警告音", STYLE.columnLeft, -582, STYLE.columnWidth, EC.SOUND_CHOICES,
        function() return EC.db.sound.key end,
        function(value) EC.db.sound.key = value end)
    self.soundChannel = CreateChoice(page, "警告音通道", STYLE.columnRight, -582, STYLE.columnWidth, EC.SOUND_CHANNELS,
        function() return EC.db.sound.channel end,
        function(value) EC.db.sound.channel = value end)
    CreateButton(page, "测试警告音", 26, -654, 140, function()
        if EC.PlayAlertSound then EC:PlayAlertSound(true) end
    end)
end

function UI:CreateFeedbackPage(content)
    local page = CreateFrame("Frame", nil, content)
    page:SetAllPoints()
    page:Hide()
    self.pages.feedback = page

    CreateSection(page, "问题反馈", 26, -28, 660)
    self.feedbackReader = CreateDocumentReader(page, "EvokerCueFeedbackScroll",
        EC.HelpContent and EC.HelpContent.feedback or "", 26, 72, 26, 46)
    local hint = CreateText(page, "GameFontHighlightSmall", "", 26, -28, 660)
    hint:ClearAllPoints()
    hint:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 26, 19)
    hint:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -26, 19)
    hint:SetText("鼠标滚轮或右侧滚动条查看全文；/evc log 可提示路径或留下反馈标记。")
    hint:SetTextColor(unpack(COLORS.muted))

    page:SetScript("OnShow", function()
        UI.feedbackReader:RefreshLayout()
    end)
end

function UI:CreateUsageGuide()
    if self.usageDialog then return end
    local dialog = CreateFrame("Frame", "EvokerCueUsageFrame", self.frame, "BackdropTemplate")
    dialog:SetSize(GUIDE_WIDTH, GUIDE_HEIGHT)
    -- Inherit the settings window's selected strata, then draw above its pages.
    dialog:SetFrameLevel(self.frame:GetFrameLevel() + 40)
    dialog:SetToplevel(true)
    dialog:SetClampedToScreen(true)
    dialog:SetMovable(true)
    dialog:EnableMouse(true)
    dialog:Hide()
    SetBackdrop(dialog, COLORS.bg, COLORS.border)
    self.usageDialog = dialog

    local header = CreateFrame("Frame", nil, dialog, "BackdropTemplate")
    header:SetPoint("TOPLEFT", dialog, "TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", -1, -1)
    header:SetHeight(66)
    header:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    header:SetBackdropColor(0.035, 0.045, 0.058, 1)
    local title = CreateText(header, "GameFontNormalLarge", "使用说明", 20, -13, 540)
    title:SetTextColor(unpack(COLORS.text))
    local subtitle = CreateText(header, "GameFontHighlightSmall",
        "奶龙打地鼠 · 正式版", 20, -40, 540)
    subtitle:SetTextColor(unpack(COLORS.muted))
    local accent = header:CreateTexture(nil, "ARTWORK")
    accent:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT", 0, 0)
    accent:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", 0, 0)
    accent:SetHeight(1)
    accent:SetColorTexture(unpack(COLORS.accent))

    local close = CreateButton(header, "×", 0, 0, 30, function() dialog:Hide() end)
    close:ClearAllPoints()
    close:SetPoint("TOPRIGHT", header, "TOPRIGHT", -12, -12)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() dialog:StartMoving() end)
    header:SetScript("OnDragStop", function() dialog:StopMovingOrSizing() end)

    self.usageReader = CreateDocumentReader(dialog, "EvokerCueUsageScroll",
        EC.HelpContent and EC.HelpContent.usage or "", 18, 80, 18, 64)

    local hint = CreateText(dialog, "GameFontHighlightSmall", "", 20, 0, 500)
    hint:ClearAllPoints()
    hint:SetPoint("BOTTOMLEFT", dialog, "BOTTOMLEFT", 20, 26)
    hint:SetPoint("BOTTOMRIGHT", dialog, "BOTTOMRIGHT", -150, 26)
    hint:SetText("关闭后，可在“概览”点击“使用说明”再次查看。")
    hint:SetTextColor(unpack(COLORS.muted))
    local done = CreateButton(dialog, "关闭", 0, 0, 110, function() dialog:Hide() end)
    done:ClearAllPoints()
    done:SetPoint("BOTTOMRIGHT", dialog, "BOTTOMRIGHT", -20, 18)
    self.usageCloseButton = done

    dialog:SetScript("OnShow", function()
        UI.usageReader:ScrollToTop()
    end)
    table.insert(UISpecialFrames, "EvokerCueUsageFrame")
end

function UI:ShowUsageGuide()
    if not self.frame or not self.frame:IsShown() then return end
    self:CreateUsageGuide()
    local dialog = self.usageDialog
    -- Fit the independent guide on small displays without modifying saved HUD
    -- positions or the scale chosen by the player for either gameplay frame.
    local parentScale = self.frame:GetEffectiveScale() or 1
    local rootScale = UIParent:GetEffectiveScale() or 1
    local width = UIParent:GetWidth() * rootScale / parentScale
    local height = UIParent:GetHeight() * rootScale / parentScale
    local fit = math.min(1, math.max(0.1, (width - 32) / GUIDE_WIDTH),
        math.max(0.1, (height - 32) / GUIDE_HEIGHT))
    dialog:SetScale(fit)
    dialog:ClearAllPoints()
    dialog:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    self.usageShownThisSession = true
    self:ApplyWindowLayers(false)
    dialog:Show()
    self.usageReader:ScrollToTop()
end

-- Shared visual helpers keep the local plan editor consistent with settings.
UI.widgets = {
    CreateText = CreateText, CreateButton = CreateButton,
    CreateEditBox = CreateEditBox, CreateDropdown = CreateDropdown,
    CreateDocumentReader = CreateDocumentReader,
    SetBackdrop = SetBackdrop, colors = COLORS, style = STYLE, ApplyFont = ApplyFont, SkinScroll = SkinScroll,
    SetPageWheel = SetPageWheel,
}

function UI:ShowTab(key)
    if key == "loom" and EC.Features and not EC.Features:DreamLoomEnabled() then key = "functions" end
    if key ~= "functions" and key ~= "loom" and key ~= "plan" then return end
    self:CancelPositionConfirmation()
    self.activeTab = key
    self.functionRoot:SetShown(key == "functions")
    self.planPage:SetShown(key == "plan")
    if self.loomPage then self.loomPage:SetShown(key == "loom") end
    for tabKey, button in pairs(self.tabButtons) do
        button:SetSelected(tabKey == key)
    end
    self:Refresh()
end

function UI:CreateBottomTabs(frame)
    local footer = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    footer:SetPoint("BOTTOMLEFT", 1, 1); footer:SetPoint("BOTTOMRIGHT", -1, 1)
    footer:SetHeight(43)
    SetBackdrop(footer, COLORS.panel, COLORS.border)
    local previous
    for i, item in ipairs({ { key = "functions", label = "设置" }, { key = "loom", label = "梦境织机" }, { key = "plan", label = "战术板" } }) do
        if item.key ~= "loom" or not EC.Features or EC.Features:DreamLoomEnabled() then
            local key = item.key
            local button = CreateButton(footer, item.label, 0, 0, 120, function() UI:ShowTab(key) end)
            button:ClearAllPoints()
            if previous then button:SetPoint("TOPLEFT", previous, "TOPRIGHT", 8, 0)
            else button:SetPoint("TOPLEFT", footer, "TOPLEFT", 12, -5) end
            self.tabButtons[key], previous = button, button
        end
    end
end

function UI:CreatePanel()
    local frame = CreateFrame("Frame", "EvokerCueSettingsFrame", UIParent, "BackdropTemplate")
    frame:SetSize(900, 760)
    frame:SetFrameStrata((EC.db and EC.db.panel and EC.db.panel.strata) or "FULLSCREEN_DIALOG")
    frame:SetFrameLevel(PANEL_FRAME_LEVEL)
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    SetBackdrop(frame, COLORS.bg, COLORS.border)
    frame:Hide()

    self.frame = frame
    self:RestorePosition()
    self:CreateHeader(frame)
    local functionRoot = CreateFrame("Frame", nil, frame)
    functionRoot:SetAllPoints(frame)
    self.functionRoot = functionRoot
    self:CreateNavigation(functionRoot)

    local content = CreateFrame("Frame", nil, functionRoot)
    content:SetPoint("TOPLEFT", frame, "TOPLEFT", 148, -64)
    content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 44)
    self.content = content

    self:CreateOverviewPage(content)
    self:CreateTimelinePage(content)
    self:CreateReminderPage(content)
    self:CreateInterfacePage(content)
    self:CreateSoundPage(content)
    self:CreateFeedbackPage(content)
    self.planPage = EC.RaidaryPlanUI:Create(self, frame)
    if not EC.Features or EC.Features:DreamLoomEnabled() then self.loomPage = EC.DreamLoom.UI:Create(self, frame) end
    self:CreateBottomTabs(frame)

    frame:SetScript("OnShow", function()
        UI:FitPanelToScreen()
        UI:ApplyWindowLayers(true)
        if EC.db and EC.db.autoRefresh then EC:RefreshCurrentNote("打开面板", false, false) end
        UI:Refresh()
        if not UI.usageShownThisSession then UI:ShowUsageGuide() end
    end)
    frame:SetScript("OnHide", function()
        -- Prevent a child dialog from silently reappearing when the panel is
        -- reopened during the same login/reload session.
        if UI.usageDialog then UI.usageDialog:Hide() end
        UI:CancelPositionConfirmation()
    end)

    table.insert(UISpecialFrames, "EvokerCueSettingsFrame")
    self:ShowPage("overview")
    self:ShowTab("functions")
end

function UI:ShowPage(key)
    if not self.pages[key] then
        return
    end

    self:CancelPositionConfirmation()
    self.activePage = key

    for pageKey, page in pairs(self.pages) do
        page:SetShown(pageKey == key)
    end

    for buttonKey, button in pairs(self.navButtons) do
        local active = buttonKey == key
        button.indicator:SetShown(active)
        if active then button:SetBackdropColor(unpack(COLORS.buttonHover))
        else button:SetBackdropColor(0, 0, 0, 0) end
        button.label:SetTextColor(unpack(active and COLORS.accent or COLORS.muted))
    end

    self:Refresh()
end

function UI:LayoutOverview()
    if not self.overviewRows then return end
    local top = 60 + self.overviewSummary:GetStringHeight() + STYLE.gap
    for _, row in ipairs(self.overviewRows) do
        local height = math.max(30, row.value:GetStringHeight() + 16)
        row:ClearAllPoints(); row:SetPoint("TOPLEFT", self.overviewBody, "TOPLEFT", 24, -top)
        row:SetHeight(height)
        top = top + height
    end
    self.overviewReadActions:SetPoint("TOPLEFT", self.overviewBody, "TOPLEFT", 24, -top - 12)
    top = top + 32 + 12 + STYLE.margin
    self.overviewSkills:SetPoint("TOPLEFT", self.overviewBody, "TOPLEFT", 0, -top)
    top = top + 110 + self.summaryText:GetStringHeight() + STYLE.margin
    self.overviewDetails:SetPoint("TOPLEFT", self.overviewBody, "TOPLEFT", 0, -top)
    local extraTop = math.max(158, 112 + self.runtimeText:GetStringHeight() + STYLE.margin)
    local extraHeight = 278 + self.overviewHelp:GetStringHeight() + STYLE.margin
    self.overviewExtra:SetPoint("TOPLEFT", self.overviewDetails, "TOPLEFT", 0, -extraTop)
    self.overviewExtra:SetHeight(extraHeight)
    self.overviewDetails:SetHeight(extraTop + extraHeight)
    self.overviewBody:SetHeight(top + extraTop + extraHeight)
    self.overviewScroll:UpdateScrollChildRect()
    self.overviewScroll:SetVerticalScroll(math.max(0, math.min(self.overviewScroll:GetVerticalScroll() or 0,
        self.overviewScroll:GetVerticalScrollRange() or 0)))
end

function UI:RefreshOverview()
    if not self.frame or not EC.state.dbReady then return end
    local state = EC.state
    local result = state.result
    local identity = EC:GetPlayerIdentity()
    local gameName = identity.game.fullName ~= "" and identity.game.fullName or identity.game.shortName

    self.autoRefreshCheck:Refresh()
    local sourceInfo = state.sourceInfo or {}
    local problem = sourceInfo.status == "READ_ERROR" or sourceInfo.status == "ADDON_UNAVAILABLE"
        or sourceInfo.status == "UNREADABLE_SELECTION" or (sourceInfo.issues and #sourceInfo.issues > 0)
        or (result and result.status == "NO_PLAYER_NAME")
    local summary = result and result.statusText or sourceInfo.statusText or "尚未读取"
    -- A provider problem and a frozen/parsed timeline are distinct facts.
    if problem and sourceInfo.statusText and sourceInfo.statusText ~= summary then
        summary = sourceInfo.statusText .. "\n" .. summary
    end
    if result and result.negativeCorrectionAllowed == false and #(result.events or {}) > 0 then
        summary = summary .. "\n部分技能完整性未确认：保留可靠计划项状态，受影响范围的提前、超额及取消提示已暂停。"
    end
    self.overviewSummary:SetText(summary)
    self.overviewSummary:SetTextColor(unpack(problem and COLORS.gold or COLORS.muted))
    self.overviewStatus.mrt:SetText(EC.PlanSources.GetSelectedLabel and EC.PlanSources:GetSelectedLabel() or EC.PlanSources:GetSelected())
    self.overviewStatus.note:SetText((state.noteLength or 0) > 0 and "已读取" or "—")
    self.overviewStatus.character:SetText(gameName ~= "" and gameName or "—")
    self.overviewStatus.mode:SetText(identity.mode == "CUSTOM" and "自定义名称" or "自动识别")
    self.overviewStatus.matched:SetText(result and result.matchedPlayerName or "—")
    self.overviewStatus.parse:SetText(result and string.format("%d 条安排", #(result.events or {})) or "—")
    local counts = result and result.counts or {}
    for key, value in pairs(self.skillCounts) do
        value:SetText(key == "TOTAL" and #(result and result.events or {}) or (counts[key] or 0))
    end
    local wave = "静滞波次：" .. (result and result.waveQuotaText or "—")
    if (counts.STASIS or 0) > 0 and (counts.DREAM_BREATH or 0) == 0 then
        wave = wave .. "\n未提供绿喷配额：只记录实际次数，不进行超额纠错。"
    end
    self.summaryText:SetText(wave)

    if self.diagnosticCheck then self.diagnosticCheck:Refresh() end
    if self.zoneOnlyCheck then self.zoneOnlyCheck:Refresh() end
    if self.combatOnlyCheck then self.combatOnlyCheck:Refresh() end
    if self.identityGameText then self.identityGameText:SetText("当前角色：" .. tostring(gameName ~= "" and gameName or "-")) end
    if self.customNameCheck then self.customNameCheck:Refresh() end
    if self.customNameEdit then
        self.customNameEdit:SetText(EC.db.identity.customName or "")
        self.customNameEdit:SetEnabled(EC.db.identity.useCustomName == true)
        self.customNameEdit:SetTextColor(unpack(EC.db.identity.useCustomName and COLORS.text or COLORS.faint))
    end
    local rt = EC.Runtime and EC.Runtime:GetStatus() or nil
    if self.prepullResetButton then
        local blocked = rt and rt.encounterActive
        self.prepullResetButton:SetEnabled(not blocked)
        self.prepullResetButton:SetAlpha(blocked and 0.45 or 1.0)
        if self.prepullResetButton.label then
            self.prepullResetButton.label:SetTextColor(unpack(blocked and COLORS.faint or COLORS.text))
        end
    end
    if self.runtimeText then
        if rt then
            local area = rt.zoneAllowed and "|cff69c9ae可用|r" or "当前区域不运行"
            local mode = rt.combatOnly and "仅战斗中显示" or "可脱战测试"
            local battle = rt.encounterActive and "首领战中" or (rt.combatActive and "战斗中" or "脱战")
            self.runtimeText:SetText(string.format("当前区域：%s　·　%s\n显示模式：%s　·　%s", rt.zoneName or "-", area, mode, battle))
        else
            self.runtimeText:SetText("当前状态：-")
        end
    end
    self:LayoutOverview()
end

function UI:GetOrCreateTimelineRow(index)
    local row = self.timelineRows[index]
    if row then
        return row
    end

    row = CreateFrame("Frame", nil, self.timelineChild, "BackdropTemplate")
    row:SetSize(622, 26)
    row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })

    row.time = CreateText(row, "GameFontHighlightSmall", "", 10, -7, 72)
    row.wave = CreateText(row, "GameFontHighlightSmall", "", 86, -7, 54)
    row.skill = CreateText(row, "GameFontNormal", "", 144, -6, 160)
    row.quota = CreateText(row, "GameFontHighlightSmall", "", 308, -7, 86)
    row.line = CreateText(row, "GameFontHighlightSmall", "", 398, -7, 66)
    row.raw = CreateText(row, "GameFontHighlightSmall", "", 468, -7, 146)
    row.raw:SetWordWrap(false)

    row:SetScript("OnEnter", function(self)
        if not self.eventData then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.eventData.skillName or "事件", 1, 1, 1)
        GameTooltip:AddLine(self.eventData.rawLine or "", nil, nil, nil, true)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    self.timelineRows[index] = row
    return row
end

function UI:RefreshTimeline()
    if not self.timelineChild then
        return
    end

    local result = EC.state.result
    local events = result and result.events or {}
    if self.sourceChecks then for _, check in pairs(self.sourceChecks) do check:Refresh() end end
    local info = EC.state.sourceInfo or {}
    local frozen = (EC.Runtime and EC.Runtime.encounterActive) or (InCombatLockdown and InCombatLockdown())
    if self.sourceStatus then
        local selectedLabel = EC.PlanSources.GetSelectedLabel and EC.PlanSources:GetSelectedLabel() or EC.PlanSources:GetSelected()
        local frozenSource = result and result.source or info.source or EC.PlanSources:GetSelected()
        local frozenLabel = EC.PlanSources.GetLabel and EC.PlanSources:GetLabel(frozenSource) or tostring(frozenSource)
        self.sourceStatus:SetText("当前来源：" .. selectedLabel .. "\n状态："
            .. (frozen and ("本场已冻结为 " .. frozenLabel .. "；修改下一场生效") or (info.statusText or "尚未读取")))
    end
    if self.aliasEdits then
        for key, edit in pairs(self.aliasEdits) do
            -- Never erase unsaved edits when another provider emits an update.
            if edit.loadedValue == nil then
                edit:SetText(EC.db.timeline.customAliases[key] or "")
                edit.loadedValue = true
            end
        end
    end
    local aliasIssues = EC.Parser:GetAliasIndex().issues
    if self.aliasStatus then
        local messages = {}
        for _, issue in ipairs(aliasIssues) do messages[#messages + 1] = issue.text end
        self.aliasStatus:SetText(#aliasIssues > 0 and table.concat(messages, "\n") or "内置名称全部保留；额外别名无冲突。")
        self.aliasStatus:SetTextColor(unpack(#aliasIssues > 0 and COLORS.gold or COLORS.green))
    end

    self.timelineSummary:SetText(result and string.format(
        "角色：%s　·　技能安排：%d　·　静滞波次：%s",
        result.matchedPlayerName or "-",
        #events,
        result.waveQuotaText or "-"
    ) or "尚未读取")

    for _, row in ipairs(self.timelineRows) do
        row:Hide()
    end

    self.timelineEmpty:SetShown(#events == 0)

    local rowHeight = 27
    for index, event in ipairs(events) do
        local row = self:GetOrCreateTimelineRow(index)
        row:SetPoint("TOPLEFT", self.timelineChild, "TOPLEFT", 0, -(index - 1) * rowHeight)
        row:SetBackdropColor(0.045, 0.055, 0.070, index % 2 == 0 and 0.72 or 0.46)
        row.eventData = event

        row.time:SetText(EC:FormatClock(event.time))
        row.wave:SetText(event.waveIndex and event.waveIndex > 0 and ("W" .. event.waveIndex) or "-")
        row.skill:SetText(event.skillName or event.skillKey or "-")
        row.skill:SetTextColor(unpack(event.color or COLORS.text))

        if event.skillKey == "DREAM_BREATH" and event.breathIndex then
            row.quota:SetText(string.format("%d / %d", event.breathIndex, event.breathLimit or 0))
            row.quota:SetTextColor(unpack(COLORS.green))
        else
            row.quota:SetText("-")
            row.quota:SetTextColor(unpack(COLORS.muted))
        end

        row.line:SetText("#" .. tostring(event.lineNumber or "-"))
        row.raw:SetText(event.cleanContent or "")
        row.time:SetTextColor(unpack(COLORS.text))
        row.wave:SetTextColor(unpack(COLORS.muted))
        row.line:SetTextColor(unpack(COLORS.faint))
        row.raw:SetTextColor(unpack(COLORS.muted))
        row:Show()
    end

    self.timelineChild:SetHeight(math.max(1, #events * rowHeight))
    if self.timelineBody then
        local top = math.max(self.timelineMinTop, self.aliasStatusTop + (self.aliasStatus:GetStringHeight() or 0) + 30)
        self.timelineArea:ClearAllPoints()
        self.timelineArea:SetPoint("TOPLEFT", self.timelineBody, "TOPLEFT", 0, -top)
        self.timelineArea:SetHeight(156 + math.max(54, #events * rowHeight))
        self.timelineBody:SetHeight(top + 156 + math.max(54, #events * rowHeight))
    end
end

function UI:RefreshRuntime()
    if not self.reminderRuntimeText or not EC.state.dbReady then
        return
    end

    self.reminderEnabledCheck:Refresh()
    if self.heartFireCheck then self.heartFireCheck:Refresh() end
    self.reminderLockCheck:Refresh()

    local status = EC.Timeline and EC.Timeline:GetStatus() or { active = false }
    local tracker = EC.CastTracker and EC.CastTracker:GetHUDData() or nil

    local lines = {}
    table.insert(lines, "技能提醒：" .. (status.active and "|cff55ff88运行中|r" or "未运行"))

    if tracker and tracker.sessionActive then
        if tracker.tracking then
            if tracker.quotaConfirmed == false then
                table.insert(lines, string.format("当前记录：已喷 %d 次 · 配额未确认", tracker.count or 0))
            else
                table.insert(lines, string.format("当前记录：第 %d 波　梦境吐息 %d/%s",
                    tracker.waveIndex or 0, tracker.count or 0,
                    tracker.limit ~= nil and tostring(tracker.limit) or "-"))
            end
        else
            table.insert(lines, "当前记录：等待静滞")
        end
    else
        table.insert(lines, "当前记录：未开始")
    end

    table.insert(lines, "静滞波次：" .. tostring(status.waveQuotaText or (EC.state.result and EC.state.result.waveQuotaText) or "-"))
    self.reminderRuntimeText:SetText(table.concat(lines, "\n"))
end

function UI:RefreshReminder()
    if not self.pages.reminder then
        return
    end

    self.reminderEnabledCheck:Refresh()
    self.reminderLockCheck:Refresh()
    self.leadTimeSlider:Refresh()
    self.postHoldSlider:Refresh()
    self.earlyWarningSlider:Refresh()
    self.maxRowsSlider:Refresh()
    self.reminderScaleSlider:Refresh()
    self.reminderOpacitySlider:Refresh()
    self:RefreshRuntime()
end

function UI:RefreshTrackerStatus()
    if not self.pages.interface or not EC.state.dbReady then
        return
    end

    self.trackerEnabledCheck:Refresh()
    self.trackerLockCheck:Refresh()
    self.trackerIconCheck:Refresh()
    self.trackerRemainingCheck:Refresh()
    self.trackerScaleSlider:Refresh()
    self.trackerOpacitySlider:Refresh()

    if self.trackerRuntimeText then
        local text = EC.CastTracker and EC.CastTracker:GetStatusText() or "当前没有记录"
        self.trackerRuntimeText:SetText(text)
    end
end


function UI:RefreshInterface()
    if not self.pages.interface or not EC.state.dbReady then
        return
    end

    if self.panelStrataChoice and self.panelStrataChoice.Refresh then self.panelStrataChoice:Refresh() end
    if self.trackerStrataChoice and self.trackerStrataChoice.Refresh then self.trackerStrataChoice:Refresh() end
    if self.reminderStrataChoice and self.reminderStrataChoice.Refresh then self.reminderStrataChoice:Refresh() end
    if self.emergencyStrataChoice and self.emergencyStrataChoice.Refresh then self.emergencyStrataChoice:Refresh() end
end

function UI:RefreshSound()
    if not self.pages.sound or not EC.state.dbReady then return end
    if self.voiceEnabledCheck then self.voiceEnabledCheck:Refresh() end
    if self.voiceNormalCheck then self.voiceNormalCheck:Refresh() end
    if self.voiceCorrectionCheck then self.voiceCorrectionCheck:Refresh() end
    if self.voiceChannel and self.voiceChannel.Refresh then self.voiceChannel:Refresh() end
    if self.soundEnabledCheck then self.soundEnabledCheck:Refresh() end
    if self.soundChoice and self.soundChoice.Refresh then self.soundChoice:Refresh() end
    if self.soundChannel and self.soundChannel.Refresh then self.soundChannel:Refresh() end
end

function UI:Refresh()
    if not self.initialized or not self.frame then
        return
    end

    for _, control in ipairs(self.controls) do
        if control.Refresh then
            control:Refresh()
        end
    end

    self:RefreshOverview()
    self:RefreshTimeline()
    self:RefreshReminder()
    self:RefreshTrackerStatus()
    self:RefreshInterface()
    self:RefreshSound()
    if EC.RaidaryPlanUI then EC.RaidaryPlanUI:RefreshStatus() end
    if EC.DreamLoom and EC.DreamLoom.UI and (not EC.Features or EC.Features:DreamLoomEnabled()) then EC.DreamLoom.UI:Refresh() end
    if self.headerEnabledCheck and self.headerEnabledCheck.Refresh then
        self.headerEnabledCheck:Refresh()
    end
end

function UI:Initialize()
    if self.initialized then
        return
    end

    self.initialized = true
    self:CreatePanel()
    self:Refresh()
end

function UI:Toggle()
    if not self.initialized then
        self:Initialize()
    end

    if self.frame:IsShown() then
        self.frame:Hide()
    else
        self.frame:Show()
    end
end
