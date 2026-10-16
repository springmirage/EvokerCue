"""Personal exact-name / explicit own Evoker selectors; everything else ignored."""
from pathlib import Path
import runpy,json
runtime=runpy.run_path(str(Path(__file__).with_name('run_scope_lifecycle.py')),run_name='fixture_import')['runtime']
r=runtime()
r.execute(r"""
passed={};local function pass(s) passed[#passed+1]=s end
local clean='00:00 测试奶龙 静滞\n00:01 测试奶龙 绿喷\n00:02 测试奶龙 绿喷\n00:29 测试奶龙 释放静滞'
local function ignored(line)
 local result=ParseBoard(clean..'\n'..line)
 assert(result.waves[1].quotaReliable,line)
 assert(result.integrity.domains.DREAM_BREATH.state=='COMPLETE',line)
 assert(#result.events==4,line)
 return result
end
ignored('{time:0:15} {圣骑士}给坦克自由')
pass('actual_paladin_tag_ignored_without_domain_pollution')
for _,tag in ipairs({'圣骑士','聖騎士','PALADIN','paladin',' Paladin ','战士','WARRIOR','猎人','HUNTER','潜行者','ROGUE','牧师','PRIEST','死亡骑士','DEATHKNIGHT','萨满祭司','SHAMAN','法师','MAGE','术士','WARLOCK','武僧','MONK','德鲁伊','DRUID','恶魔猎手','DEMONHUNTER','未知分组','治疗','HEALER','PALADINX'}) do
 ignored('00:15 {'..tag..'} 未知技能');ignored('00:15 {'..tag..'} 绿喷');ignored('00-15 {'..tag..'} 绿喷')
end
pass('all_other_classes_unknown_groups_roles_and_malformed_foreign_lines_ignored')
local result=ParseBoard(clean..'\n00:15 {唤魔师} 绿喷')
assert(#result.events==5 and result.waves[1].breathLimit==3 and result.waves[1].quotaReliable)
ignored('00:15 {唤魔师} 未知技能')
pass('explicit_own_evoker_selector_only_known_spells')
for _,line in ipairs({'00:15 测试奶龙 未知技能','00:15 测试奶龙 {spell:99999999}',
 '00:15 其他人 绿喷','00:15 测试奶龙二号 绿喷','00:15 大测试奶龙 绿喷','00:15 测试奶龙-其他服 绿喷',
 '00:15 绿喷 测试奶龙','00:15 {圣骑士} 绿喷','00:15 <测试奶龙二号> 绿喷'}) do ignored(line) end
pass('unknown_spells_other_players_and_prefix_or_wrong_realm_names_ignored')
for _,line in ipairs({'00:15 测试奶龙 绿喷 / 其他人 回溯','00:15 其他人 回溯 / 测试奶龙 绿喷',
 '00:15 测试奶龙 绿喷 其他人 回溯','00:15 其他人 回溯 测试奶龙 绿喷',
 '00:15 测试奶龙 绿喷 / {圣骑士} 回溯','00:15 测试奶龙 绿喷 未知指令 其他人 回溯',
 '00:15 测试奶龙 绿喷；其他人 回溯','00:15 测试奶龙 绿喷 | 其他人 回溯'}) do
 result=ParseBoard(line);assert(#result.events==1 and result.events[1].skillKey=='DREAM_BREATH',line)
end
pass('multiple_players_same_line_separators_or_spaces_never_swallow_other_payload')
result=ParseBoard('00:15 测试奶龙 绿喷 / 其他人 回溯 / 测试奶龙 微风')
assert(#result.events==2 and result.counts.DREAM_BREATH==1 and result.counts.ZEPHYR==1 and result.counts.REWIND==0)
pass('multiple_personal_segments_keep_own_spells_only')
for _,line in ipairs({'00:15 |cff00ff00测试奶龙|r <绿喷>','00:15 <测试奶龙> <绿喷>',
 '00:15 测试奶龙绿喷','00:15 测试奶龙:绿喷','00:15 测试奶龙 {rt1} 绿喷',
 '00:15 测试奶龙 {spell:355936}','00:15 测试奶龙 |Hspell:355936|h[梦境吐息]|h',
 '00:15 测试奶龙 355936','00:15 测试奶龙 绿喷 待确认','00:15 测试奶龙 绿喷 / 未知内容'}) do
 result=ParseBoard(line);assert(#result.events==1 and result.events[1].skillKey=='DREAM_BREATH',line)
end
pass('color_name_and_skill_wrappers_adjacent_skill_markers_ids_links_and_tail_text')
identity.candidates={{value='测试奶龙-测试服',source='AUTO'},{value='测试奶龙',source='AUTO'}}
result=ParseBoard('00:15 |cff00ff00测试奶龙-测试服|r 绿喷');assert(#result.events==1)
ignored('00:15 测试奶龙-其他服 绿喷')
identity.candidates={{value='测试奶龙',source='AUTO'}}
pass('explicit_full_realm_and_short_name_candidates_do_not_match_other_realm')
EC.db.timeline.customAliases.DREAM_BREATH='自定义喷,喷'
for _,alias in ipairs({'自定义喷','喷','绿喷','梦境吐息'}) do
 result=ParseBoard('00:15 测试奶龙 '..alias);assert(#result.events==1 and result.events[1].skillKey=='DREAM_BREATH',alias)
end
EC.db.timeline.customAliases.DREAM_BREATH=nil
pass('existing_builtin_and_custom_aliases_preserved')
for _,line in ipairs({'测试奶龙 绿喷','00-15 测试奶龙 绿喷','00:99 测试奶龙 绿喷','{time:bad} 测试奶龙 绿喷'}) do
 result=ignored(line)
 local found=false;for _,issue in ipairs(result.parseIssues) do if issue.code=='PERSONAL_TIME_UNPARSED' then found=true end end
 assert(found,line)
end
pass('missing_invalid_personal_time_is_local_diagnostic_and_never_invented')
""")
print(json.dumps({'passed_cases':list(r.globals().passed.values()),'live_game':'not_deployed'},ensure_ascii=False))
