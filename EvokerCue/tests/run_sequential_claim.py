"""Global ordered Dream Breath claims; trusted addon sources and synthetic events."""
from pathlib import Path
import runpy,json
runtime=runpy.run_path(str(Path(__file__).with_name('run_scope_lifecycle.py')),run_name='fixture_import')['runtime']
r=runtime()
r.execute(r"""
local c,t=EC.CastTracker,EC.Timeline
passed={};local function pass(s) passed[#passed+1]=s end
local board='00:00 测试奶龙 静滞\n00:10 测试奶龙 绿喷\n00:20 测试奶龙 绿喷\n00:25 测试奶龙 释放静滞\n01:30 测试奶龙 静滞\n01:40 测试奶龙 绿喷\n01:50 测试奶龙 绿喷\n02:00 测试奶龙 释放静滞\n02:30 测试奶龙 回溯'
local function breaths(snap) local out={} for _,e in ipairs(snap.events) do if e.skillKey=='DREAM_BREATH' then out[#out+1]=e end end return out end
local function cast(id,complete) BeginBreath(id);EndBreath(id,complete) end
local snap=StartBoard('00:10 测试奶龙 绿喷\n00:20 测试奶龙 绿喷');local b=breaths(snap)
cast('no-stasis-in-plan',true);assert(b[1].consumed and not b[2].consumed)
pass('plan_without_any_stasis_still_claims_first_slot')
snap=StartBoard(board);b=breaths(snap)
assert(not c.tracking);cast('without-stasis',true);assert(b[1].consumed and not b[2].consumed)
cast('future-same-wave',true);assert(b[2].consumed and not b[3].consumed)
cast('future-next-wave',true);assert(b[3].consumed and not b[4].consumed)
cast('future-last',true);assert(b[4].consumed)
cast('extra',true);assert(t:GetTokenLedgerStatus().consumed==4)
pass('no_stasis_four_early_casts_claim_all_slots_in_order_extra_does_not_invent_slot')
snap=StartBoard(board..'\n00:15 {其他分组} 未知技能');b=breaths(snap);Stasis();assert(c:HasReliableQuota())
now=1030;Stasis();now=1040;Stasis();cast('wrong-stasis',true);assert(b[1].consumed and not b[2].consumed)
pass('wrong_stasis_and_incomplete_quota_do_not_block_first_slot')
snap=StartBoard(board);b=breaths(snap);now=1150;t:Update();assert(LateBreaths()==4)
cast('late-old-wave',true);assert(b[1].consumed and LateBreaths()==3)
pass('planned_stasis_boundaries_never_expire_unclaimed_slots')
snap=StartBoard(board);b=breaths(snap);Stasis();now=1090;c:ClearPrepullPackage('fixture');c.lastAcceptedInitialStasisAt=nil
FireCast('UNIT_SPELLCAST_SUCCEEDED','stasis-wave-two',370537);assert(c.currentWaveIndex==2)
cast('actual-wave-two',true);assert(b[1].consumed and not b[3].consumed)
pass('actual_wave_transition_still_claims_oldest_global_slot')
snap=StartBoard(board);b=breaths(snap)
BeginBreath('cancel');EndBreath('cancel',false);assert(not b[1].consumed and not b[1].reserved)
BeginBreath('valid');EndBreath('foreign',true);assert(not b[1].consumed);EndBreath('valid',true);EndBreath('valid',true)
assert(b[1].consumed and not b[2].consumed)
pass('interrupted_wrong_identity_and_duplicate_stop_never_take_extra_slot')
BeginBreath('stop-session');t:StopTest();EndBreath('stop-session',true);assert(not b[2].consumed and not b[2].reserved)
pass('session_stop_releases_reservation_and_rejects_stale_stop')
snap=StartBoard(board);local cues={}
for _,e in ipairs(snap.events) do if e.skillKey=='RELEASE_STASIS' or e.skillKey=='REWIND' then cues[#cues+1]=e end end
for _,e in ipairs(cues) do now=1000+e.time;assert(t:DismissActiveEvent(e.skillKey,'actual')==nil);assert(not e.dismissed and not e.consumed);t:Update();now=now+1;t:Update();assert(e.expired) end
pass('release_stasis_and_rewind_are_timer_only_even_inside_window')
""")
print(json.dumps({'passed_cases':list(r.globals().passed.values()),'live_game':'not_deployed'},ensure_ascii=False))
