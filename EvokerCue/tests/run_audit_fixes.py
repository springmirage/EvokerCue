"""Audit fixes: whole-input evidence, negative-correction gates, provenance lifecycle.
Uses Lua 5.1 with simulated APIs; this is not game/rendering validation.
"""
from pathlib import Path
import runpy
base = runpy.run_path(str(Path(__file__).with_name('run_dreamloom.py')))
r = base['runtime'](True, ['Parser.lua','PlanGuard.lua','MRTReader.lua','RaidaryPlan.lua','PlanSources.lua'] + base['MODEL'] + ['DreamLoomFormatter.lua','Timeline.lua','CastTracker.lua','AlertUI.lua'])
r.execute('''
local parser,d,p,t,c,a=EC.Parser,EC.DreamLoom,EC.RaidaryPlan,EC.Timeline,EC.CastTracker,EC.AlertUI
now=10;GetTime=function() return now end
EC.Log=function() end;EC.IsSecret=function() return false end;EC.CanShowGameplay=function() return true end
EC.RefreshCurrentNote=function() end
EC.db.enabled=true;EC.db.reminder={enabled=true,leadTime=3,postHold=0.9,locked=true}
a.initialized=true;a.frame=CreateFrame('Frame');a.rows={}
GetNumGroupMembers=function() return 2 end;IsInRaid=function() return true end
UnitIsUnit=function(unit) return unit=='raid1' end
UnitFullName=function(unit) if unit=='raid2' then return '其他人','测试服' end end
local clean='00:00 测试奶龙 静滞\\n00:01 测试奶龙 梦境吐息\\n00:02 测试奶龙 梦境吐息\\n00:30 测试奶龙 球'
local function parse(text) return parser:BuildResult(text,identity) end
local result=parse(clean)
assert(result.integrity.state=='COMPLETE' and result.negativeCorrectionAllowed)
assert(#result.integrity.lines==result.stats.totalLines)
for _,text in ipairs({clean..'\\n# 测试奶龙 绿喷说明',clean..'\\n00:40 其他人 梦境吐息',clean..'\\n{time:0:40} - 其他人 {spell:355936}'}) do
 local r=parse(text);assert(r.negativeCorrectionAllowed and r.integrity.state=='COMPLETE')
end
-- These were silent skips, not necessarily parser errors. None can prove absence.
for _,line in ipairs({'00-03 测试奶龙 梦境吐息','测试奶龙 梦境吐息','03 测试奶龙 绿喷',
 '00:03 梦境吐息','00:03 {未知分组} 绿喷',
 '00:03 测试奶龙 未知技能','00:03 测试奶龙 回溯 / 测试奶龙 未知技能',
 '00:03 测试奶龙 回溯 / 无法解释的尾段','{time:0:03,p2} 测试奶龙 梦境吐息'}) do
 local r=parse(clean..'\\n'..line)
 assert(not r.negativeCorrectionAllowed and r.integrity.state~='COMPLETE',line)
 assert(not r.waves[1].quotaReliable)
 assert(r.integrity.unknownLines+r.integrity.partialLines>0,line)
 assert(#r.events>=4) -- positive parsed entries were retained
end
-- No evidence object must fail closed, including synthetic result callers.
local noEvidence={events={},waves={},warnings={},parseIssues={},stats={}}
EC.PlanGuard:Validate(noEvidence);assert(not noEvidence.negativeCorrectionAllowed)
-- MRT's read contract certifies which raw fields were included, not just source name.
VMRT={Note={Text1=clean,SelfText=''}}
local text,info=EC.MRTReader:GetCurrentNote('both');assert(info.inputCoverage)
info.source='MRT_BOTH';info.origins={};info.issues={}
result=EC.PlanSources:BuildResult(text,identity,info);assert(result.negativeCorrectionAllowed)
VMRT.Note.SelfText={unexpected='format'}
text,info=EC.MRTReader:GetCurrentNote('both');assert(not info.inputCoverage)
info.source='MRT_BOTH';info.origins={};info.issues={}
result=EC.PlanSources:BuildResult(text,identity,info);assert(not result.negativeCorrectionAllowed)
-- Successfully parsed normalized output still does not certify raw adapter coverage.
for _,source in ipairs({'DFT','NSRT'}) do
 result=EC.PlanSources:BuildResult(clean,identity,{source=source,available=true,origins={},issues={}})
 assert(result.integrity.textState=='COMPLETE' and result.integrity.state=='UNKNOWN')
 assert(not result.negativeCorrectionAllowed)
end
-- Actual correction gates must agree; on-time reminders/real success still work.
local partial=parse('00:00 测试奶龙 静滞\\n00:01 测试奶龙 梦境吐息\\n00:02 测试奶龙 梦境吐息 待确认\\n00:30 测试奶龙 球')
t.active=true;t.startTime=0;t.source='BOSS';t.snapshot=t:BuildSnapshot(partial)
c:BeginSession(t.snapshot,'BOSS',0);c.currentWaveIndex=1;c.tracking=true;c.quotaConfirmed=true;c.currentWaveLimit=1;c.breathCount=1
assert(not c:HasReliableQuota() and not c:IsOverQuotaBeforeNextBreath())
c:ShowOverQuotaWarning();assert(not a.emergencyEntry)
for _,event in ipairs(t.snapshot.events) do if event.skillKey=='DREAM_BREATH' then assert(not t:CanCorrectEvent(event,10)) end end
c:StartBallCast('off-plan',373861);assert(a.ballEmergencyEntry and c.ballCast);c:ClearBallCast('test')
local function ballState() for _,entry in ipairs(t:GetVisibleEntries(now)) do if entry.event.skillKey=='BALL' then return entry.state end end end
now=30;t:Update();assert(ballState()=='NORMAL')
c:StartBallCast('on-plan',373861);assert(c.ballCast)
now=32;t:Update();assert(c.ballCast and c.ballCast.event.manualCastPending and ballState()=='BALL_CASTING')
c:FinishBallCast('on-plan',373861,nil,true);assert(t.snapshot.events[#t.snapshot.events].consumed)
-- A later complete parse does not silently promote the active partial battle snapshot.
result=parse(clean);assert(result.negativeCorrectionAllowed and not t.snapshot.negativeCorrectionAllowed)
local good=t:BuildSnapshot(result);t.snapshot=good;c:BeginSession(good,'BOSS',0)
c.currentWaveIndex=1;c.tracking=true;c.quotaConfirmed=true;c.currentWaveLimit=2;c.breathCount=2
assert(c:IsOverQuotaBeforeNextBreath());now=5;c:StartBallCast('too-early',373861);assert(a.ballEmergencyEntry)
c:ClearBallCast('test');a:ClearEmergency();t:Stop('test',true)
-- CRLF-only normalization retains proof. Edited generated skills do not.
local source='00:36 测试奶龙 静滞\\r\\n00:12 其他人 回溯'
p:SetDraft(source);d:SetParameter('endText','00:50')
local req=assert(d:Prepare());assert(d:Apply(req,d:Solve(req)));local output=p:GetDraft()
assert(p:Save(output));req=assert(d:Prepare());assert(not req.baseText:find('\\r',1,true))
local normalized=p:GetDraft();assert(d:Apply(req,d:Solve(req)));assert(p:GetDraft()==normalized)
p:SetDraft(normalized..'\\n00:49 测试奶龙 绿喷');assert(not d:Prepare())
p:SetDraft(normalized)
-- Copy owns independent settings/provenance, keeps unique plan identity and binding behavior.
local original=p:GetDB();p:Create(true);local copy=p:GetDB()
assert(copy.id~=original.id and copy.dreamLoom~=original.dreamLoom)
assert(copy.dreamLoom.settings~=original.dreamLoom.settings and d:Prepare())
d:SetParameter('endText','00:55');assert(original.dreamLoom.settings.endText=='00:50')
req=assert(d:Prepare());assert(d:Apply(req,d:Solve(req)));assert(p:Save(p:GetDraft()))
local firstSaved=p:GetText()
d:SetParameter('endText','01:00');req=assert(d:Prepare());assert(d:Apply(req,d:Solve(req)));assert(p:Save(p:GetDraft()))
local secondSaved=p:GetText();assert(firstSaved~=secondSaved)
assert(p:RestoreHistory());assert(p:GetDraft()==firstSaved and p:GetText()==secondSaved)
req=assert(d:Prepare());assert(d:Apply(req,d:Solve(req)))
-- SavedVariables-style table roundtrip retains history provenance without shared tables.
EC.db.raidaryPlan=d:CopyPlanData(EC.db.raidaryPlan)
assert(p:RestoreHistory());assert(d:Prepare());assert(p:Save(p:GetDraft()));assert(d:Prepare())
-- Bounded metadata alongside existing 10 text histories, ordinary text remains strings.
for i=1,12 do
 d:SetParameter('endText',string.format('01:%02d',i));req=assert(d:Prepare());assert(d:Apply(req,d:Solve(req)));assert(p:Save(p:GetDraft()))
end
assert(#p:GetDB().history==10 and #p:GetDB().dreamLoom.history==10)
for _,value in ipairs(p:GetDB().history) do assert(type(value)=='string') end
assert(p:RestoreHistory());assert(d:Prepare())
''')
print('PASS audit fixes: full-input evidence, silent skips and mixed segments, raw-source coverage, fail-closed negative correction, positive reminders, frozen snapshots, CRLF/save/copy/history/reload/provenance isolation and retention')
r.execute('''
local text='00:00 测试奶龙 静滞\\n00:01 测试奶龙 绿喷\\n这一行旧解析器直接忽略'
local result=EC.Parser:BuildResult(text,identity)
assert(#result.parseIssues==0 and result.integrity.state=='COMPLETE' and result.negativeCorrectionAllowed)
local empty=EC.Parser:BuildResult('',identity)
assert(not empty.negativeCorrectionAllowed and #empty.warnings==0)
local p,d=EC.RaidaryPlan,EC.DreamLoom
-- Previously untracked legacy generated histories must not acquire invented provenance.
p:GetDB().dreamLoom=nil;p:GetDB().history={'00:36 测试奶龙 静滞\\n00:38 测试奶龙 球'}
assert(p:RestoreHistory());d:SetParameter('endText','00:50');assert(not d:Prepare())
''')
print('PASS plain prose is outside arrangement grammar; empty state neutral; legacy missing provenance never guessed')

r.execute('''
local parser=EC.Parser
local main='00:00 测试奶龙 静滞\\n00:01 测试奶龙 绿喷'
local r=parser:BuildResult(main..'\\n00:03 等下 绿喷',identity)
assert(r.integrity.state=='UNKNOWN' and not r.negativeCorrectionAllowed)
GetNumGroupMembers=function() return 0 end
r=parser:BuildResult(main..'\\n00:03 其他人 绿喷',identity)
assert(r.integrity.state=='UNKNOWN' and not r.negativeCorrectionAllowed)
''')
print('PASS an apparent other owner is not exclusion proof without readable non-player roster identity')
