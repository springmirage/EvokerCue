local addonName, EC = ...

local MRTButton = {}
EC.MRTButton = MRTButton

MRTButton.initialized = false
MRTButton.button = nil
MRTButton.ticker = nil

local function FindMRTFrame()
    return _G.MRTOptionsFrame
        or (_G.GExRT and _G.GExRT.OptionsFrame)
        or _G.ExRTOptionsFrame
end

function MRTButton:Position()
    if not self.button then
        return
    end

    local frame = FindMRTFrame()
    if not frame then
        return
    end

    self.button:ClearAllPoints()
    self.button:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -118, 26)
end

function MRTButton:Attach()
    if self.button then
        self:Position()
        return true
    end

    local frame = FindMRTFrame()
    if not frame then
        return false
    end

    local button = CreateFrame("Button", "EvokerCueMRTButton", frame, "BackdropTemplate")
    button:SetSize(104, 24)
    button:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    button:SetBackdropColor(0.10, 0.05, 0.03, 0.96)
    button:SetBackdropBorderColor(0.78, 0.42, 0.12, 0.96)
    button:SetFrameLevel((frame:GetFrameLevel() or 1) + 20)

    button.label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    button.label:SetPoint("CENTER")
    button.label:SetText("奶龙打地鼠")
    button.label:SetTextColor(1.00, 0.82, 0.22, 1.00)

    self.button = button
    self:Position()

    button:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.16, 0.08, 0.04, 1.00)
        self:SetBackdropBorderColor(1.00, 0.68, 0.18, 1.00)
    end)
    button:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.10, 0.05, 0.03, 0.96)
        self:SetBackdropBorderColor(0.78, 0.42, 0.12, 0.96)
    end)
    button:SetScript("OnClick", function()
        if EC.UI and EC.UI.Toggle then
            EC.UI:Toggle()
        end
    end)

    return true
end

function MRTButton:Initialize()
    if self.initialized then
        return
    end
    self.initialized = true

    C_Timer.After(1.0, function()
        local tries = 0
        MRTButton.ticker = C_Timer.NewTicker(1.0, function(ticker)
            tries = tries + 1
            MRTButton:Attach()
            MRTButton:Position()
            if tries >= 20 then
                ticker:Cancel()
                MRTButton.ticker = nil
            end
        end)
    end)
end
