"""0.8.12 scoped completeness and tactical-test release regression; mocked APIs only."""
from pathlib import Path
import json
from lupa.lua51 import LuaRuntime
ROOT=Path(__file__).resolve().parents[1]
def runtime():
 r=LuaRuntime(unpack_returned_tuples=True)
 r.execute((ROOT/'tests/wow_mock.lua').read_text(encoding='utf-8'))
 r.execute('SlashCmdList={};now=1000;GetTime=function() return now end;C_Timer.After=function() end;print=function() end')
 for n in ['Core.lua','Features.lua','Parser.lua','PlanGuard.lua','Diagnostics.lua','CastTracker.lua','Timeline.lua','AlertUI.lua','TrackerHUD.lua']:
  r.execute((ROOT/n).read_text(encoding='utf-8-sig'),'EvokerCue',r.globals().EC)
 r.execute(r"""
 EC.db=EC.defaults;EC.state.dbReady=true;EC.Log=function() end;EC.CanShowGameplay=function() return true end
 EC.db.runtime.onlyVenomousAbyss=false;EC.db.runtime.combatOnly=false
 identity.game.classFile='EVOKER';identity.game.role='HEALER';identity.game.className='唤魔师'
 EC.Diagnostics.initialized=true;EC.Diagnostics.IsEnabled=function() return true end
 observations={};EC.Diagnostics.RecordCast=function(_,record) observations[#observations+1]=record end;EC.Diagnostics.Event=function() end
 EC.CastTracker:Initialize();EC.TrackerHUD:Initialize();EC.AlertUI:Initialize()
 function ParseBoard(text) return EC.Parser:BuildResult(text,identity) end
 function StartBoard(text,mode,encounter)
  local c,t=EC.CastTracker,EC.Timeline;EC.Runtime=nil;C_UnitAuras=nil
  c:ResetPrepullState('fixture');c.lastAcceptedInitialStasisAt=nil;c.bridgedReadyExpiresAt=nil;c.lastStasisEventAt=nil;c.recentInitialStasisGUID=nil
  now=1000;local result=ParseBoard(text);assert(result.ok)
  assert(t:StartFromResult(result,mode or 'MRT_TEST',{}))
  if encounter then EC.Runtime={encounterActive=true,IsEncounterRunning=function() return true end,IsZoneAllowed=function() return true end,CanRun=function() return true end} end
  return t.snapshot,result
 end
 function FireCast(event,...) EC.CastTracker.eventFrame:fire('OnEvent',event,'player',...) end
 function Stasis() FireCast('UNIT_SPELLCAST_SUCCEEDED','stasis',370537) end
 function BeginBreath(id) FireCast('UNIT_SPELLCAST_EMPOWER_START',nil,355936,id) end
 function EndBreath(id,complete) FireCast('UNIT_SPELLCAST_EMPOWER_STOP',nil,355936,complete,nil,id) end
 function LateBreaths()
  local entries=EC.Timeline:GetVisibleEntries(now-1000);local count=0
  for _,entry in ipairs(entries) do if entry.event.skillKey=='DREAM_BREATH' and entry.state=='LATE' then count=count+1 end end
  return count
 end
 """)
 return r

def main():
 r=runtime()
 r.execute(r"""
 local c,t,p=EC.CastTracker,EC.Timeline,EC.Parser
 local clean='00:00 测试奶龙 静滞\n00:01 测试奶龙 绿喷\n00:02 测试奶龙 绿喷\n00:29 测试奶龙 释放静滞\n01:00 测试奶龙 回溯'
 passed={};local function pass(name) passed[#passed+1]=name end
 -- Whole-note coverage remains diagnostic; plain timed notes have no personal-skill evidence.
 for _,line in ipairs({'00:15 场地变化','{time:0:27} - 全团集合','00-20 场地变化','00:15 <场地变化>'}) do
  local result=ParseBoard(clean..'\n'..line)
  assert(result.integrity.state~='COMPLETE' and result.waves[1].breathLimit==2 and result.waves[1].quotaReliable)
  assert(result.integrity.domains.DREAM_BREATH.state=='COMPLETE')
 end
 pass('unrelated_timed_text_does_not_invent_missing_breath')
 -- Self-owned unknown skills, class/role assignments and truncated mixed segments remain unsafe.
 for _,line in ipairs({'00:15 测试奶龙 未知技能','00-15 测试奶龙 未知技能','测试奶龙 未知技能',
  '00:15 {治疗} 未知技能','00:15 {唤魔师} 未知技能','00:15 测试奶龙 回溯 / 无法解释的尾段',
  '00:15 {未知分组} 未知技能','00:15 测试奶龙 <未知技能>','00:15 <测试奶龙> 未知技能','00:15 {spell:9999999}'}) do
  local result=ParseBoard(clean..'\n'..line)
  assert(not result.waves[1].quotaReliable and result.waves[1].invalidReason=='DOMAIN_INCOMPLETE',line)
 end
 pass('self_unknown_selector_markup_and_mixed_tail_stay_protected')
 -- Even without an owner, a supported skill reference is meaningful domain evidence.
 for _,line in ipairs({'00:15 未证实角色 绿喷','00-15 测试奶龙 绿喷','00:15 绿喷','绿喷','00:15 {未知分组} 绿喷','00:15 {spell:355936}','00:15 <绿喷>'}) do
  local result=ParseBoard(clean..'\n'..line)
  assert(not result.waves[1].quotaReliable and result.integrity.domains.DREAM_BREATH.state~='COMPLETE',line)
 end
 pass('missing_time_or_owner_breath_reference_stays_protected')
 -- Proven other owner exclusions still require roster evidence, not guesses.
 GetNumGroupMembers=function() return 2 end;IsInRaid=function() return true end
 UnitIsUnit=function(unit) return unit=='raid1' end;UnitFullName=function(unit) if unit=='raid2' then return '其他人','测试服' end end
 local result=ParseBoard(clean..'\n00:15 其他人 绿喷');assert(result.waves[1].quotaReliable)
 GetNumGroupMembers=function() return 0 end
 result=ParseBoard(clean..'\n00:15 其他人 绿喷');assert(not result.waves[1].quotaReliable)
 pass('other_owner_requires_proof')
 -- Genuine lifecycle omissions are independent from unrelated prose.
 result=ParseBoard('00:00 测试奶龙 静滞\n00:30 测试奶龙 静滞\n00:31 测试奶龙 绿喷')
 assert(not result.waves[1].quotaReliable and not result.waves[2].quotaReliable)
 pass('empty_wave_and_missing_release_not_promoted')
 -- Reliable quota closes exactly the reserved token, never all late slots at once.
 local snap=StartBoard(clean..'\n00:15 场地变化');Stasis();now=1004;t:Update();assert(LateBreaths()==2)
 BeginBreath('first');FireCast('UNIT_SPELLCAST_SUCCEEDED','success-a',355936);assert(c.breathCount==0)
 EndBreath('wrong',true);assert(c.breathCount==0 and LateBreaths()==2)
 EndBreath('first',false);assert(c.breathCount==0 and LateBreaths()==2)
 BeginBreath('retry');EndBreath('retry',true);assert(c.breathCount==1 and LateBreaths()==1)
 EndBreath('retry',true);assert(c.breathCount==1 and LateBreaths()==1)
 BeginBreath('second');EndBreath('second',true);assert(c.breathCount==2 and LateBreaths()==0)
 pass('late_exact_ownership_incomplete_wrong_id_and_duplicate')
 -- Incomplete quota and >1 known slot still have no unambiguous owner.
 snap=StartBoard(clean..'\n00-15 测试奶龙 绿喷');Stasis();now=1004;t:Update();assert(LateBreaths()==2)
 BeginBreath('ambiguous');assert(not c.activeEmpower.knownSlot);EndBreath('ambiguous',true)
 assert(c.breathCount==1 and LateBreaths()==2 and not c:HasReliableQuota());pass('true_ambiguity_not_blindly_closed')
 -- Release clears cache while preserving the active MRT_TEST wave/count and ledger.
 snap=StartBoard(clean);Stasis();now=1001;BeginBreath('release');EndBreath('release',true)
 local consumed=snap.events[2];assert(c.prepullStasisEligible and c.prepullDreamBreathCount==1)
 now=1004;FireCast('UNIT_SPELLCAST_SUCCEEDED','release-stasis',370564)
 assert(c.breathCount==1 and c.currentWaveIndex==1 and c.tracking and c:HasReliableQuota())
 assert(not c.prepullStasisEligible and c.prepullDreamBreathCount==0 and not c.prepullEmpower and consumed.consumed)
 EC.TrackerHUD:Update();assert(EC.TrackerHUD.count:GetText():find('1 / 2',1,true));pass('explicit_release_preserves_test_hud_clears_cache')
 -- Some clients report Stasis release using its initial spell ID.
 snap=StartBoard(clean);Stasis();now=1001;BeginBreath('same-id-release');EndBreath('same-id-release',true)
 c:ClearPrepullPackage('fixture prior cache ended');now=1005
 FireCast('UNIT_SPELLCAST_SUCCEEDED','different-stasis-report',370537)
 assert(c.breathCount==1 and c.currentWaveIndex==1 and c.tracking and not c.prepullStasisEligible)
 pass('initial_id_release_preserves_test_counter')
 -- Aura end needs two readable missing samples and a prior observed aura.
 snap=StartBoard(clean);Stasis();now=1001;BeginBreath('aura');EndBreath('aura',true)
 c.prepullAuraSeen=true;C_UnitAuras={GetPlayerAuraBySpellID=function() return nil end}
 now=1004;c:CheckPrepullAura();assert(c.prepullStasisEligible)
 now=1004.3;c:CheckPrepullAura();assert(not c.prepullStasisEligible and c.breathCount==1 and c.currentWaveIndex==1)
 pass('confirmed_aura_end_preserves_test_counter')
 -- A release while an empower is unfinished must not permit its stale STOP to count.
 snap=StartBoard(clean);Stasis();now=1001;BeginBreath('unfinished')
 FireCast('UNIT_SPELLCAST_SUCCEEDED','release-during-start',370564);EndBreath('unfinished',true)
 assert(c.breathCount==0 and not c.activeEmpower and not snap.events[2].consumed)
 pass('release_during_empower_stale_stop_rejected')
 -- Ordinary prepull/COMBAT and explicit reset still reset; Boss still preserves.
 for _,mode in ipairs({'COMBAT','TEST','IDLE'}) do
  snap=StartBoard(clean,mode);c.currentWaveIndex=1;c.breathCount=3;c.tracking=true
  FireCast('UNIT_SPELLCAST_SUCCEEDED','ordinary-release',370564)
  assert(c.breathCount==0 and c.currentWaveIndex==0 and c.quotaReason=='RESET')
 end
 snap=StartBoard(clean,'BOSS',true);c.currentWaveIndex=1;c.breathCount=3;c.tracking=true
 FireCast('UNIT_SPELLCAST_SUCCEEDED','boss-release',370564);assert(c.breathCount==3 and c.currentWaveIndex==1)
 snap=StartBoard(clean);Stasis();now=1001;BeginBreath('manual');EndBreath('manual',true)
 c:ResetPrepullState('manual user reset');assert(c.breathCount==0 and c.currentWaveIndex==0)
 pass('ordinary_prepull_boss_and_manual_reset_preserved')
 -- Stopping the test frees its pending token and fully resets the session/HUD.
 snap=StartBoard(clean);Stasis();now=1001;BeginBreath('stop-owner');local token=c.activeEmpower.token
 assert(token.reserved);assert(t:StopTest());assert(not c.sessionActive and not c.activeEmpower and c.breathCount==0 and c.currentWaveIndex==0 and not token.reserved)
 EndBreath('stop-owner',true);assert(c.breathCount==0);pass('stop_test_pending_owner_and_stale_stop_cleanup')
 """)
 print(json.dumps({'passed_cases':list(r.globals().passed.values()),'live_game':'pending'},ensure_ascii=False))
if __name__=='__main__':main()
