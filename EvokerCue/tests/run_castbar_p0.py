"""P0 regression using trusted source and synthetic event payloads; no game QA."""
from pathlib import Path
import json
from lupa.lua51 import LuaRuntime
ROOT=Path(__file__).resolve().parents[1]
r=LuaRuntime(unpack_returned_tuples=True)
r.execute((ROOT/'tests/wow_mock.lua').read_text(encoding='utf-8'))
r.execute("SlashCmdList={};now=1000;GetTime=function() return now end;C_Timer.After=function() end;print=function() end")
for n in ['Core.lua','Features.lua','Parser.lua','PlanGuard.lua','Diagnostics.lua','CastTracker.lua','Timeline.lua','AlertUI.lua','TrackerHUD.lua']:
 r.execute((ROOT/n).read_text(encoding='utf-8-sig'),'EvokerCue',r.globals().EC)
r.execute(r"""
EC.db=EC.defaults;EC.state.dbReady=true;EC.db.runtime.onlyVenomousAbyss=false;EC.db.runtime.combatOnly=false
local restricted={};EC.IsSecret=function(_,v) return rawequal(v,restricted) end
EC.Log=function() end;EC.CanShowGameplay=function() return true end
EC.Diagnostics.initialized=true;EC.Diagnostics.IsEnabled=function() return true end
observations={};EC.Diagnostics.RecordCast=function(_,rec) observations[#observations+1]=rec end;EC.Diagnostics.Event=function() end
local c,t=EC.CastTracker,EC.Timeline
c:Initialize();EC.TrackerHUD:Initialize();EC.AlertUI:Initialize()
local function fire(event,...) c.eventFrame:fire('OnEvent',event,'player',...) end
local function start(text)
 c:ResetPrepullState('fixture');c.lastAcceptedInitialStasisAt=nil;c.bridgedReadyExpiresAt=nil;c.lastStasisEventAt=nil;c.recentInitialStasisGUID=nil;c.recentInitialStasisBarID=nil;now=1000;local result=EC.Parser:BuildResult(text,identity);assert(result.ok)
 assert(t:StartFromResult(result,'MRT_TEST',{}));return t.snapshot,result
end
local clean='00:00 测试奶龙 静滞\n00:01 测试奶龙 绿喷\n00:02 测试奶龙 绿喷\n00:10 测试奶龙 释放静滞'
local function stasis() fire('UNIT_SPELLCAST_SUCCEEDED','stasis',370537) end
local function begin(id,guid) fire('UNIT_SPELLCAST_EMPOWER_START',guid,355936,id) end
local function finish(id,complete,guid) fire('UNIT_SPELLCAST_EMPOWER_STOP',guid,355936,complete,nil,id) end
local function breathVisible()
 local n=0
 for _,entry in ipairs(t:GetVisibleEntries(now-1000)) do if entry.event.skillKey=='DREAM_BREATH' then n=n+1 end end
 return n
end
cases={};local function pass(name) cases[#cases+1]=name end
-- Reader never coerces numbers/strings or touches secret payloads.
for _,id in ipairs({'CastBar-fixture',42,0}) do local value,state=EC:ReadCastBarID(id);assert(value==id and state=='READABLE') end
for _,id in ipairs({'',true,{},function() end,math.huge,-math.huge,0/0}) do local value,state=EC:ReadCastBarID(id);assert(value==nil and state=='INVALID') end
local value,state=EC:ReadCastBarID(nil);assert(value==nil and state=='MISSING')
value,state=EC:ReadCastBarID(restricted);assert(value==nil and state=='RESTRICTED');pass('reader_types_and_secret')
-- Recorded START(nil,spell,string)/STOP(nil,spell,true,nil,string) shape.
local snap=start(clean);stasis();assert(c:HasReliableQuota() and c.currentWaveLimit==2, tostring(c.quotaReason)..' limit='..tostring(c.currentWaveLimit)..' planned='..tostring(snap.waves[1].breathLimit)..' invalid='..tostring(snap.waves[1].invalidReason))
now=1001.1;begin('CastBar-one');local gen=c.activeEmpower.generation
fire('UNIT_SPELLCAST_SUCCEEDED','readable-success-guid',355936);assert(c.breathCount==0 and c.activeEmpower.generation==gen)
now=1001.8;finish('CastBar-one',true);assert(c.breathCount==1 and snap.events[2].consumed)
EC.TrackerHUD:Update();assert(EC.TrackerHUD.count:GetText():find('1 / 2',1,true))
local last=observations[#observations];assert(last.input.barState=='READABLE' and last.input.argumentShapes[6].kind=='string' and last.after.count==1)
finish('CastBar-one',true);fire('UNIT_SPELLCAST_SUCCEEDED','readable-success-guid',355936);assert(c.breathCount==1)
pass('actual_payload_string_complete_succeeded_no_count_duplicate_stop_hud')
-- Normal completion clears exactly the oldest reserved reminder, even if both are late.
snap=start(clean);stasis();now=1004;t:Update();assert(breathVisible()==2,'visible='..breathVisible()..' quota='..tostring(c.quotaReason))
begin('late-one');finish('late-one',true);assert(c.breathCount==1 and breathVisible()==1 and snap.events[2].consumed and not snap.events[3].consumed,'count='..c.breathCount..' visible='..breathVisible()..' reason='..tostring(c.quotaReason))
begin('late-two');finish('late-two',true);assert(c.breathCount==2 and breathVisible()==0)
pass('reliable_quota_two_late_cleared_one_per_verified_release')
-- Legacy numeric ID still works.
snap=start(clean);stasis();now=1001;begin(123);finish(123,true);assert(c.breathCount==1);pass('legacy_number')
-- String "123" is not numeric 123, and a wrong readable GUID overrides the same bar.
snap=start(clean);stasis();now=1001;begin('123','guid-a');finish(123,true,'guid-a');assert(c.breathCount==0 and c.activeEmpower)
finish('123',true,'guid-b');assert(c.breathCount==0);finish('123',true,'guid-a');assert(c.breathCount==1);pass('cross_type_and_guid_contradiction')
snap=start(clean);stasis();now=1001;begin('id-a');finish('id-b',true);assert(c.breathCount==0 and c:HasReliableQuota());finish('id-a',true);assert(c.breathCount==1);pass('wrong_string_identity')
-- Incomplete, interrupted and failed casts never count/consume.
for _,event in ipairs({'NONE','UNIT_SPELLCAST_INTERRUPTED','UNIT_SPELLCAST_FAILED'}) do
 snap=start(clean);stasis();now=1001;begin('incomplete')
 if event~='NONE' then fire(event,nil,355936) end
 finish('incomplete',false);assert(c.breathCount==0 and not snap.events[2].consumed)
end
pass('incomplete_interrupt_failure')
-- Restricted/missing/empty keys do not acquire another cast by spell or time.
for _,id in ipairs({restricted,'',false}) do
 snap=start(clean);stasis();now=1001;begin(id);finish(id,true);assert(c.breathCount==0 and not c:HasReliableQuota())
end
snap=start(clean);stasis();now=1001;begin(nil);finish(nil,true);assert(c.breathCount==0);pass('invalid_or_unreadable_identity_fail_closed')
snap=start(clean);stasis();now=1001;begin('completion-secret');finish('completion-secret',restricted);assert(c.breathCount==0 and not c:HasReliableQuota());pass('restricted_complete')
-- A new START owns its own generation; an old STOP must leave it intact.
snap=start(clean);stasis();now=1001;begin('old');begin('new');local active=c.activeEmpower
finish('old',true);assert(c.activeEmpower==active and c.breathCount==0);finish('new',true);assert(c.breathCount==1);pass('replaced_generation_stale_stop')
-- A wave change discards the former owner; a delayed former STOP cannot consume new wave.
local two='00:00 测试奶龙 静滞\n00:01 测试奶龙 绿喷\n00:05 测试奶龙 释放静滞\n01:30 测试奶龙 静滞\n01:31 测试奶龙 绿喷'
EC.Runtime={encounterActive=true,IsEncounterRunning=function() return true end,IsZoneAllowed=function() return true end,CanRun=function() return true end};snap=start(two);stasis();now=1001;begin('wave-one');now=1090;fire('UNIT_SPELLCAST_SUCCEEDED','next-stasis',370537)
assert(c.currentWaveIndex==2);begin('wave-two');finish('wave-one',true);assert(c.breathCount==0);finish('wave-two',true);assert(c.breathCount==1 and snap.events[2].consumed and not snap.events[#snap.events].consumed);pass('cross_wave_stale_stop');EC.Runtime=nil
-- Incomplete domain stays incomplete; unique known reminder can still close on proven release.
local partial='00:00 测试奶龙 静滞\n00:01 测试奶龙 绿喷\n00-02 测试奶龙 绿喷\n00:30 测试奶龙 回溯'
snap=start(partial);stasis();assert(c:HasReliableQuota() and c.quotaReason=='MATCHED','quota reason '..tostring(c.quotaReason))
now=1004;t:Update();assert(breathVisible()==1);begin('unique');finish('unique',true)
assert(c.breathCount==1 and snap.events[2].consumed and breathVisible()==0 and c:HasReliableQuota());pass('ignored_bad_clock_unique_late_success')
-- Multiple unknown-quota slots remain ambiguous: actual count increases but no guessed closure.
partial=partial..'\n00:02 测试奶龙 绿喷';snap=start(partial);stasis();now=1004;t:Update();assert(breathVisible()==2,'visible='..breathVisible()..' quota='..tostring(c.quotaReason))
begin('ambiguous');assert(not c.activeEmpower.knownSlot);finish('ambiguous',true)
assert(c.breathCount==1 and breathVisible()==1 and snap.events[2].consumed and c:HasReliableQuota());pass('ignored_bad_clock_multiple_late_claims_first')
-- Other configured skills still dispatch/dismiss their own reminders.
local observed={};c.DismissActiveReminder=function(_,key) observed[key]=true end
for _,id in ipairs({363534,374227,406732,374968}) do c:HandleSucceeded('other',id) end
assert(observed.REWIND and observed.ZEPHYR and observed.SPATIAL_PARADOX and observed.TIME_SPIRAL)
assert(not observed.BALL and not EC.Features:SkillEnabled('BALL'));pass('other_skills_and_ball_disabled')
""")
print(json.dumps({'passed_cases':list(r.globals().cases.values()),'game_validation':'pending'},ensure_ascii=False))
