-- Lightweight API harness: verifies construction and callbacks, not WoW rendering.
local methods = {}
frames = {}
local function noop() end
local mt = { __index = function(t, k)
    if methods[k] then return methods[k] end
    if k:match('^Set') or k:match('^Enable') or k:match('^Register') or k == 'Raise' then return noop end
end }
function CreateFrame(kind, name, parent, template)
    local f = setmetatable({kind=kind, name=name, parent=parent, scripts={}, regions={}, points={}, width=900, height=652, enabled=true, text='', shown=true}, mt)
    frames[#frames+1]=f
    if name then _G[name]=f end
    if template == 'UIPanelScrollFrameTemplate' then
        f.ScrollBar=CreateFrame('Slider', (name and name..'ScrollBar'), f)
        f.ScrollBar.ScrollUpButton=CreateFrame('Button',nil,f.ScrollBar)
        f.ScrollBar.ScrollDownButton=CreateFrame('Button',nil,f.ScrollBar)
        f.ScrollBar.thumb=f.ScrollBar:CreateTexture()
    end
    return f
end
function methods:CreateFontString() local f=CreateFrame('FontString',nil,self); self.regions[#self.regions+1]=f; return f end
function methods:CreateTexture() local f=CreateFrame('Texture',nil,self); self.regions[#self.regions+1]=f; return f end
methods.CreateLine=methods.CreateTexture
function methods:GetRegions() return unpack(self.regions) end
function methods:GetObjectType() return self.kind end
function methods:GetName() return self.name end
function methods:GetParent() return self.parent end
function methods:SetScript(k,v) self.scripts[k]=v end
function methods:GetScript(k) return self.scripts[k] end
function methods:HookScript(k,v) local old=self.scripts[k]; self.scripts[k]=function(...) if old then old(...) end; v(...) end end
function methods:fire(k,...) if self.scripts[k] then self.scripts[k](self,...) end end
function methods:SetPoint(...) self.points[#self.points+1]={...} end
function methods:ClearAllPoints() self.points={} end
function methods:SetSize(w,h) self.width=w;self.height=h end
function methods:SetWidth(w) self.width=w end
function methods:SetHeight(h) self.height=h end
function methods:GetWidth() return self.width end
function methods:GetHeight() return self.height end
function methods:GetFont() return 'existing-chinese-font',self.fontSize or 14,'' end
function methods:SetFont(_,n) self.fontSize=n end
function methods:SetText(t) self.text=tostring(t or ''); self:fire('OnTextChanged',false) end
function methods:GetText() return self.text end
function methods:GetStringWidth() return #(self.text:gsub('[\128-\191]',''))*(self.fontSize or 14) end
function methods:GetStringHeight()
    local n=0
    for line in (self.text..'\n'):gmatch('(.-)\n') do n=n+math.max(1, math.ceil(#(line:gsub('[\128-\191]',''))*(self.fontSize or 14)/self.width)) end
    return n*(self.fontSize or 14)
end
function methods:SetEnabled(v) self.enabled=v; self:fire(v and 'OnEnable' or 'OnDisable') end
function methods:IsEnabled() return self.enabled end
function methods:SetChecked(v) self.checked=v end
function methods:GetChecked() return self.checked end
function methods:SetScrollChild(c) self.child=c end
function methods:GetVerticalScrollRange() return self.range or 0 end
function methods:GetVerticalScroll() return self.offset or 0 end
function methods:SetVerticalScroll(v) self.offset=v end
function methods:GetThumbTexture() return self.thumb end
function methods:UpdateScrollChildRect() self.range=math.max(0,(self.child and self.child:GetHeight() or 0)-self.height); self:fire('OnScrollRangeChanged') end
function methods:SetAlpha(v) self.alpha=v end
function methods:Show() local changed=not self.shown;self.shown=true;if changed then self:fire('OnShow') end end
function methods:Hide() local changed=self.shown;self.shown=false;if changed then self:fire('OnHide') end end
function methods:SetShown(v) if v then self:Show() else self:Hide() end end
function methods:IsShown() return self.shown end
methods.IsVisible=methods.IsShown
function methods:SetFocus() self:fire('OnEditFocusGained') end
function methods:ClearFocus() self:fire('OnEditFocusLost') end
function methods:GetFrameLevel() return 100 end
function methods:GetPoint() return 'CENTER',nil,'CENTER',0,0 end
UISpecialFrames={}
UIParent=CreateFrame('Frame');UIParent:SetSize(1920,1080)
C_Timer={After=function(_,f) f() end}
GameTooltip=CreateFrame('Frame')
function InCombatLockdown() return false end
EC={db={raidaryPlan={},timeline={customAliases={}},identity={useCustomName=false,customName=''},runtime={},diagnostics={enabled=true},panel={}},state={dbReady=true,noteLength=0},refreshes=0}
identity={mode='AUTO',game={fullName='测试奶龙-测试服务器',shortName='测试奶龙'},candidates={{value='测试奶龙-测试服务器',source='full'},{value='测试奶龙',source='short'}}}
function EC:GetPlayerIdentity() return identity end
function EC:RefreshCurrentNote() self.refreshes=self.refreshes+1 end
function EC:FormatClock(v) return string.format('%02d:%02d',math.floor(v/60),v%60) end
EC.PlanSources={selected='RAIDARY'}
function EC.PlanSources:GetSelected() return self.selected end
function EC.PlanSources:GetSelectedLabel() return self.selected end
function EC.PlanSources:SetSelected(v) self.selected=v end
function click(label)
    for _,f in ipairs(frames) do if f.kind=='Button' and f.label and f.label:GetText()==label then f:fire('OnClick');return end end
    error('missing button '..label)
end
function methods:GetJustifyH() return self.justify or "CENTER" end; function methods:SetJustifyH(v) self.justify=v end
function methods:SetShadowOffset(x,y) self.shadowX=x;self.shadowY=y end
function methods:SetShadowColor(r,g,b,a) self.shadowAlpha=a end
function methods:SetSpacing(v) self.spacing=v end
function methods:SetScale(v) self.scale=v end
function methods:SetParent(p) self.parent=p end
