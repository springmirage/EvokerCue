# 溜溜球 planned slot 状态机（2026-09-28）

本记录覆盖旧交付中“起手后 postHold + 2 秒转迟到”的描述。完整性、来源降级、绿喷配额、求解器、保存与音频策略不变。

## 原逻辑与本次改动

原实现使用 consumed、expired、manualCastPending 等独立标志和时间条件，没有权威状态字段。成功已经要求起手身份关联，但合法读条超过 postHold + 2 秒后会显示迟到。

现以 `event.ballState` 为权威状态，转换表限制转移；原标志由转换函数统一派生，仅供通用时间轴/UI读取。球不能通过通用同技能消除接口完成。

## 状态与转移

| 状态 | 条件 / 显示 | 离开条件 |
| --- | --- | --- |
| WAITING | 尚未进入 time - leadTime | 进入窗口 -> DUE；时间直接跳过截止 -> LATE；被后续窗口替代 -> MISSED |
| DUE | 合法提醒窗口，显示“溜溜球” | 合法 START -> CASTING；超过 time + postHold -> LATE；被新窗口替代 -> MISSED |
| LATE | 尚未成功且仍允许补打，显示“溜溜球晚了” | 合法 START -> CASTING；被新窗口替代 -> MISSED |
| CASTING | 与一次真实起手绑定，显示“施法中” | 匹配 SUCCESS -> DONE；匹配 FAILED/INTERRUPTED 或明确清理 -> 重新按当前时间判定 DUE/LATE/MISSED |
| DONE | 匹配手动施法成功，关闭 | 终态，不可重复完成 |
| MISSED | 旧项未起手，其后一个不同时间点的提前窗口已开启，关闭 | 终态，不表示施法成功 |

CASTING 不因 postHold、旧 hold + 2 秒边界或后续 slot 窗口开启而迟到/关闭。保留原有 15 秒无结果 watchdog：超过后结束该次关联，不伪造成功；可重试项回到 DUE/LATE，已被后续窗口替代的项为 MISSED。新本人起手替代旧起手、死亡、会话结束/更换也是明确清理条件。旧施法后续成功不得恢复已结束关联。

## START 选择与窗口约定

现有代码和测试规定：B 的提前窗口开启后，尚未起手的 A 不再允许补打。这个约定与“无条件最早未完成项优先”冲突，本次保留既有产品行为。

选择前同步刷新状态（不依赖上一帧是否更新）：排除 WAITING、CASTING、DONE、MISSED，只在 DUE/LATE 中选择最早时间；同时间按快照原顺序选择。一次 START 只绑定一个项。

- A LATE，B 窗口未开：迟到补打归属 A，不提示取消。
- A LATE，B 窗口已开：A -> MISSED，新 START 归属 B。
- A 已 CASTING，B 窗口开启：A 继续等待自己的结果，B 独立为 DUE；A 的成功只完成 A。
- A 在 B 窗口开启后失败：A -> MISSED，新起手归属 B。

## 非计划施法与身份

没有合法候选时，施法记录不带 slot 引用：有 BALL 域 absenceAllowed 为 ILLEGAL 并提示“取消读条！”；无许可为 UNASSIGNED_UNKNOWN，保持中性。没有本人球计划时仍沿用原来不建立纠错权限的行为。

SUCCESS 只检查 START 当时绑定的引用，绝不搜索最近或未来 slot。ILLEGAL/UNASSIGNED_UNKNOWN 的成功都不能消费任何计划项，即便成功时未来窗口已经开启。

继续复用可读 castGUID / castBarID 的匹配函数：任何可读字段矛盾优先拒绝，没有共同身份键也拒绝。仅本人事件可进入关联；仅相同 SpellID 的成功、静滞复制或没有对应 START 的成功不核销。STOP 不证明成功，也不清除当前关联。

本次增加会话内已结束施法记录，拒绝重复 START/SUCCESS 与旧施法回报。若一个结果仅提供被旧、新施法复用的键而无法区分归属，保守不确认。中断/失败释放 slot，随后新身份可以重新绑定。一个 cast 最多完成一个 slot，一个 slot 最多成功一次。

## 文件

- Timeline.lua：权威状态与转换、确定候选选择、窗口替代、提醒状态投影、禁止通用消除球项。
- CastTracker.lua：START 归属、非法/中性记录、身份匹配、重复回报隔离、重试与清理。
- AlertUI.lua：由 BALL_CASTING 明确显示“施法中”，不再依赖独立 pending 标志。
- tests/run_ball_slots.py：16 个指定场景及额外边界；入口串行运行完整性与完整模型回归。
- tests/run_dreamloom.py、tests/run_audit_fixes.py：仅更新旧“读条超过固定时长显示迟到”和读条显示状态的断言。

## 已执行验证

执行 `python tests/run_ball_slots.py`，全部通过：

- 用户指定 CASE 1–16，包括 COMPLETE/UNKNOWN 非法成功不偷未来项、合法迟到补打、失败重试、读条跨越 postHold、旧事件污染和静滞复制。
- 额外：同时间稳定选择、无 Update 帧时窗口切换、已起手 A 与 B 并发、A 跨窗口失败、15 秒清理、不读/冲突身份、复用身份键、死亡/换会话、绿喷紧急提醒与球提示独立。
- `run_integrity_domains.py`、`run_audit_fixes.py`：技能域/波次隔离、绿喷纠错、MRT/Raidary 及 NSRT/DFT 降级行为、保存/复制/历史。
- `run_dreamloom.py`：模型与独立验证器、模拟 UI、施法 API 回归；包括所有顶层插件文件 Lua 5.1 编译检查。

模拟测试不等同游戏验收。尚未进行游戏内验证：真实可读身份字段及事件顺序、延迟/读条推迟时的无结果清理、静滞复制实际回报、并发提示显示与中断重试仍待验。
