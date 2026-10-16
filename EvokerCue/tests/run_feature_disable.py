"""Disabled release policy with real Lua handlers and simulated WoW UI/events."""
from pathlib import Path
from lupa.lua51 import LuaRuntime
ROOT=Path(__file__).resolve().parents[1]
def runtime(modules):
 r=LuaRuntime(unpack_returned_tuples=True)
 r.execute((ROOT/'tests/wow_mock.lua').read_text(encoding='utf-8-sig'))
 for name in ['Features.lua']+modules:
  r.execute((ROOT/name).read_text(encoding='utf-8-sig'),'EvokerCue',r.globals().EC)
 return r
modules=['Parser.lua','PlanGuard.lua','RaidaryPlan.lua','DreamLoom.lua','DreamLoomVerifier.lua','DreamLoomSolver.lua','DreamLoomFormatter.lua','CastTracker.lua','Timeline.lua','AlertUI.lua','Voice.lua','HelpContent.lua','UI.lua','RaidaryPlanUI.lua','DreamLoomUI.lua']
r=runtime(modules)
for path in ROOT.glob('*.lua'): r.execute('assert(loadstring(...))',path.read_text(encoding='utf-8-sig'))
print('PASS Lua 5.1 syntax: all addon files')
r.execute(r"""
now=0;GetTime=function() return now end
EC.Log=function() end;EC.IsSecret=function() return false end;EC.SafeText=function(_,v) return tostring(v) end
EC.CanShowGameplay=function() return true end
EC.db.enabled=true;EC.db.reminder={enabled=true,leadTime=3,postHold=0.9,locked=true}
local p,t,c,a,d=EC.Parser,EC.Timeline,EC.CastTracker,EC.AlertUI,EC.DreamLoom
assert(not EC.Features:SkillEnabled('BALL') and not EC.Features:DreamLoomEnabled())
EC.db.timeline.customAliases.BALL='我的球'
for _,text in ipairs({'球','溜溜球','时空畸体','我的球','{spell:373861}','{spellid:373861}','spellid:373861','373861','|Hspell:373861|h[时空畸体]|h'}) do
 local events,why=p:ParseLineEvents('00:20 测试奶龙 '..text,1,identity)
 assert(events and #events==0,text..':'..tostring(why))
 local result=p:BuildResult('00:20 测试奶龙 '..text,identity)
 assert(#result.events==0 and result.counts.BALL==0 and #result.waves==0)
 assert(#result.warnings==0 and #result.parseIssues==0)
end
local note='00:00 测试奶龙 静滞\n00:01 测试奶龙 绿喷\n00:02 测试奶龙 绿喷\n00:10 测试奶龙 释放静滞\n00:20 测试奶龙 回溯\n00:21 测试奶龙 微风\n00:22 测试奶龙 空间悖论\n00:23 测试奶龙 时间螺旋\n00:24 测试奶龙 花'
local clean=p:BuildResult(note,identity)
local result=p:BuildResult(note..'\n00:30 测试奶龙 球\n00:40 测试奶龙 {spell:373861}',identity)
assert(#clean.events==9 and #result.events==9 and result.counts.BALL==0)
assert(result.waves[1].breathLimit==clean.waves[1].breathLimit and result.waves[1].quotaReliable==clean.waves[1].quotaReliable)
for i,event in ipairs(clean.events) do assert(result.events[i].skillKey==event.skillKey and result.events[i].time==event.time) end
for _,key in ipairs(p:GetEnabledSkillKeys()) do assert(key~='BALL') end
-- Defensive snapshot filtering also accepts older/synthetic results without mutating them.
result.events[#result.events+1]={time=1000,skillKey='BALL',spellID=373861,slotReliable=true}
local snapshot=t:BuildSnapshot(result)
assert(#snapshot.events==9 and #result.events==10 and snapshot.lastEventTime==24)
t.active=true;t.startTime=0;t.source='BOSS';t.snapshot=snapshot
c:Initialize();c:BeginSession(snapshot,'BOSS',0)
a.initialized=true;a.frame=CreateFrame('Frame');a.rows={}
for _,event in ipairs({'UNIT_SPELLCAST_START','UNIT_SPELLCAST_SUCCEEDED','UNIT_SPELLCAST_STOP','UNIT_SPELLCAST_INTERRUPTED','UNIT_SPELLCAST_FAILED'}) do
 c.eventFrame:fire('OnEvent',event,'player','disabled-ball',373861,123)
end
c:StartBallCast('direct',373861);c:FinishBallCast('direct',373861,nil,true)
assert(not c.ballCast and not a.ballEmergencyEntry and not c:IsBallCastPending())
local slot,hasPlan=t:GetBallSlot(30);assert(not slot and not hasPlan)
a:ShowBallEmergency();assert(not a.ballEmergencyEntry)
a.ballEmergencyEntry={event={skillKey='BALL'}}
a:Render({{event={skillKey='BALL'},remaining=0,state='NORMAL'}})
assert(not a.ballEmergencyEntry and not a.frame:IsShown())
assert(EC.Voice:PlaySkill('BALL',true)==false)
-- Existing plan body and model metadata survive ordinary editor operations.
local plan=EC.RaidaryPlan:GetDB();local metadata={settings={endText='00:50',mode='STRICT_BBY'},baseText='original',generatedText='old',generation={revision=7},history={{baseText='older',generatedText='old'}}}
plan.dreamLoom=metadata
local settings=d:GetSettings(plan);assert(settings==metadata.settings)
local job=d:NewJob({fightEnd=50,mode='STRICT_BBY',stasisTimes={0}})
assert(job.result.status=='DISABLED' and not job.thread and job.expandedStates==0)
assert(job:Step(10000).status=='DISABLED')
assert(d:Solve({fightEnd=50,mode='STRICT_BBY',stasisTimes={0}}).status=='DISABLED')
assert(not d:Prepare() and not d:Apply({},{}));assert(not d:Verify({},{}))
local revision=d.inputRevision;d:InputsChanged();assert(revision==d.inputRevision)
d:SetParameter('endText','99:99');d:RestoreProvenance(plan,'different');d:OnPlanSave(plan,'different')
assert(plan.dreamLoom==metadata and metadata.generatedText=='old' and metadata.settings.endText=='00:50' and #metadata.history==1)
local timers=0;C_Timer.After=function() timers=timers+1 end
d.UI:Start();assert(timers==0 and not d.UI.job)
EC.RaidaryPlan:SetDraft(note..'\n# original ball text retained\n00:30 测试奶龙 球')
local draft=EC.RaidaryPlan:GetDraft();EC.RaidaryPlan:Save(draft,false)
assert(EC.RaidaryPlan:GetText()==draft and plan.dreamLoom==metadata and metadata.generatedText=='old')
EC.UI:CreatePanel();local ui=EC.UI
assert(ui.tabButtons.functions and ui.tabButtons.plan and not ui.tabButtons.loom)
assert(not ui.loomPage and not d.UI.page and not ui.aliasEdits.BALL and ui.aliasEdits.FLOWER)
assert(ui.tabButtons.plan.points[1][2]==ui.tabButtons.functions)
ui:ShowTab('loom');assert(ui.activeTab=='functions' and ui.functionRoot:IsShown())
ui:ShowTab('plan');assert(ui.activeTab=='plan' and ui.planPage:IsShown())
ui:ShowTab('functions');assert(EC.RaidaryPlan:GetText()==draft and plan.dreamLoom==metadata)
assert(not EC.HelpContent.usage:find('梦境织机',1,true) and not EC.HelpContent.usage:find('溜溜球',1,true))
local copyID=EC.RaidaryPlan:Create(true)
local copy=EC.RaidaryPlan:GetDB();assert(copy.dreamLoom~=metadata and copy.dreamLoom.generatedText=='old')
assert(copy.dreamLoom.settings.endText=='00:50' and #copy.dreamLoom.history==1)
assert(EC.db.timeline.customAliases.BALL=='我的球' and EC.PlanSources:GetSelected()=='RAIDARY')
""")
print('PASS disabled BALL: all aliases/IDs, no events/count/wave contribution; other nine skills and breath quota unchanged')
print('PASS disabled handlers: cast START/SUCCESS/STOP/fail, direct calls, snapshots, emergency render, voice')
print('PASS disabled DreamLoom: no search/coroutine/timer, direct Solve/Verify/Apply/Prepare rejected, metadata untouched')
print('PASS simulated UI: two adjacent tabs, no BALL settings, old loom route -> settings, plan editor usable')
print('PASS persistence: original text/custom aliases/model metadata retained; save/copy preserve data; source choice unchanged')
# Resume a pre-existing job after switching policy off: no coroutine resumes.
s=runtime(['DreamLoom.lua','DreamLoomVerifier.lua','DreamLoomSolver.lua'])
s.execute("""
EC.Features.ball=true;EC.Features.dreamLoom=true
local job=EC.DreamLoom:NewJob({fightEnd=50,mode='STRICT_BBY',stasisTimes={0}})
assert(job.thread);EC.Features.dreamLoom=false
assert(job:Step(1000).status=='DISABLED' and not job.thread and job.expandedStates==0)
""")
print('PASS pending-job policy stop: next slice frees coroutine before work')
