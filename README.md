# 奶龙打地鼠 EvokerCue

魔兽世界正式服插件，当前版本 **0.8.9**。提供奶龙个人技能轴提醒、绿喷保护、心火监控、语音提醒与战术板。

## 安装

下载本仓库 ZIP，将其中的 EvokerCue 文件夹放入 World of Warcraft/_retail_/Interface/AddOns，游戏内输入 /reload，再输入 /evc 打开设置。

详细使用说明见 [EvokerCue/README.txt](EvokerCue/README.txt)，更新记录见 [CHANGELOG](EvokerCue/CHANGELOG.md)。

作者：韶光逍珑。

## 0.8.9

支持正式服 12.1.5（Interface 120105）。修复副本外声音测试静默：手动测试可在副本外使用，总开关关闭时明确提示；自动提醒继续遵守原有限制。

暂时禁用溜溜球（时空畸体 373861）与梦境织机并隐藏相关入口，保留源码和已有方案数据。其他技能、绿喷判定和配额保持原有行为。

回归使用 Lua 5.1 与模拟 WoW API，兼容声明不代表完成游戏内实战验收。完整更新见 [更新记录](EvokerCue/CHANGELOG.md)。
