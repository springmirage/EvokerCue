"""Restore original healer target contract; exact scope and overlap de-duplication."""
from pathlib import Path
import runpy,json
runtime=runpy.run_path(str(Path(__file__).with_name('run_scope_lifecycle.py')),run_name='fixture_import')['runtime']
r=runtime()
r.execute(r"""
passed={};local function pass(s) passed[#passed+1]=s end
local function one(text,key)
 local result=ParseBoard(text);assert(#result.events==1,text)
 assert(result.events[1].skillKey==(key or 'DREAM_BREATH'),text)
 assert(result.integrity.domains.DREAM_BREATH.state=='COMPLETE',text)
 return result
end
for _,target in ipairs({'测试奶龙','{唤魔师}','{治疗}'}) do
 for _,spell in ipairs({'绿喷','<绿喷>','{spell:355936}','<{spell:355936}>'}) do
  one('00:10 '..target..' '..spell)
 end
end
pass('all_three_targets_accept_skill_names_angle_wrappers_spell_ids_and_nested_wrappers')
EC.db.timeline.customAliases.DREAM_BREATH='小喷'
one('00:10 {治疗} 小喷');EC.db.timeline.customAliases.DREAM_BREATH=nil
one('00:10 |cff00ff00测试奶龙|r <绿喷>')
identity.candidates={{value='测试奶龙-测试服',source='AUTO'},{value='测试奶龙',source='AUTO'}}
one('00:10 |cff00ff00测试奶龙-测试服|r {spell:355936}')
identity.candidates={{value='测试奶龙',source='AUTO'}}
pass('existing_alias_color_and_full_realm_name_normalization_retained')
for _,text in ipairs({'00:10 测试奶龙 {唤魔师} {治疗} 绿喷',
 '00:10 {治疗} 绿喷 / {唤魔师} <绿喷> / 测试奶龙 {spell:355936}',
 '00:10 测试奶龙 绿喷 {治疗} 绿喷',
 '00:10 {唤魔师} <{spell:355936}> / {治疗} 绿喷'}) do one(text) end
pass('same_line_same_time_same_skill_multiple_own_targets_emit_exactly_one_event')
local result=ParseBoard('00:10 {治疗} 绿喷 / 测试奶龙 回溯 / {唤魔师} 微风')
assert(#result.events==3 and result.counts.DREAM_BREATH==1 and result.counts.REWIND==1 and result.counts.ZEPHYR==1)
result=ParseBoard([[00:10 {治疗} 绿喷
00:11 测试奶龙 绿喷]])
assert(#result.events==2 and result.events[1].time==10 and result.events[2].time==11)
pass('different_skills_or_times_are_not_deduplicated_away')
for _,text in ipairs({'00:10 {治疗} 绿喷 / 其他人 回溯',
 '00:10 其他人 回溯 / {治疗} 绿喷',
 '00:10 {治疗} 绿喷 其他人 回溯',
 '00:10 其他人 回溯 {治疗} 绿喷',
 '00:10 {治疗} 绿喷 / {圣骑士} 回溯 / 测试奶龙二号 回溯',
 '00:10 {未知分组} 回溯 / {治疗} 绿喷 / 无关文字'}) do one(text) end
pass('same_line_other_players_classes_unknown_selectors_and_adjacent_payloads_never_leak')
local clean=[[00:00 测试奶龙 静滞
00:01 测试奶龙 绿喷
00:20 测试奶龙 释放静滞]]
for _,tail in ipairs({'00:10 {圣骑士}给坦克自由','00:10 其他人 绿喷','00:10 {治疗} 未知法术','{time:bad} {治疗} 绿喷'}) do
 result=ParseBoard(clean..'\n'..tail);assert(#result.events==3 and result.waves[1].quotaReliable,tail)
end
result=ParseBoard(clean..'\n{time:bad} {治疗} 绿喷');local found=false
for _,issue in ipairs(result.parseIssues) do if issue.code=='PERSONAL_TIME_UNPARSED' then found=true end end
assert(found)
pass('other_or_unknown_entries_do_not_poison_accepted_quota_invalid_own_time_is_local')
identity.game.role='DAMAGER'
assert(#ParseBoard('00:10 {治疗} 绿喷').events==0)
one('00:10 {唤魔师} 绿喷');one('00:10 测试奶龙 绿喷')
identity.game.role='HEALER';identity.game.classFile='PRIEST'
assert(#ParseBoard('00:10 {唤魔师} 绿喷').events==0)
one('00:10 {治疗} 绿喷');identity.game.classFile='EVOKER'
pass('healer_and_evoker_tags_require_the_actual_player_role_and_class')
local snap=StartBoard('00:10 测试奶龙 绿喷 / {唤魔师} <绿喷> / {治疗} {spell:355936}')
assert(#snap.events==1);BeginBreath('shared');EndBreath('shared',true);EndBreath('shared',true)
assert(EC.CastTracker.breathCount==1 and EC.Timeline:GetTokenLedgerStatus().consumed==1)
pass('overlapping_own_targets_create_one_slot_one_claim_and_duplicate_stop_no_extra_count')
""")
print(json.dumps({'passed_cases':list(r.globals().passed.values()),'live_game':'pending'},ensure_ascii=False))
