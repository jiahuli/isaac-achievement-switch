# 以撒禁用成就 / Achievement Switch

给《以撒的结合：重生 忏悔+》用的一个开关：**决定本局能不能解锁成就。**
关掉之后本局不再解锁成就（含 Steam 成就与解锁类道具），这样在还没全成就的时候也能安心打一把爽局，不用担心把成就进度搞乱。

> ## ⚠️ 声明：本项目由 AI 生成，人工审核
>
> * **代码（`main.lua`、测试、脚本、文档）由 AI 生成**，随后由人工审核并在真实游戏环境里实测验证。
> * 结论只对本仓库声明的版本组合负责：**忏悔+ 1.9.7.17 + 忏悔龙 REPENTOGON 1.1.2g**。
> * 关键结论都做过实机核验（见 [实测记录](#实测记录)）：难度参数、延迟重开时机、成就门控读取方式都是照着真机日志改出来的，不是猜的。
> * 这个开关**只作用于本局**，不修改存档文件、不写内存、不改 Steam 成就状态；它用的是游戏原生的「自定义局 / 种子局」标记。
> * 仍然建议：**动成就之前先备份存档**（`Documents/My Games/Binding of Isaac Repentance+/`）。

---

## 前置要求（必须）

| 需要什么 | 说明 |
| --- | --- |
| **以撒的结合：重生 忏悔+** | Steam 版，本体版本 `1.9.7.x` |
| **忏悔龙 REPENTOGON** | **必需。** 本 mod 靠它提供的 `Isaac.StartNewGame` 使用游戏原生的「不解锁成就」标记 |
| 启动方式 | 必须用 `REPENTOGONLauncher.exe` 启动游戏，否则拿不到忏悔龙的 API |

### 忏悔龙怎么装（官方安装/下载界面）

1. 打开官方安装说明页 👉 **<https://repentogon.com/install.html>**
2. 下载 **REPENTOGON Launcher** 👉 **<https://github.com/TeamREPENTOGON/Launcher/releases/latest>**
3. 按官网说明把启动器指向你的 `isaac-ng.exe`，让它自动完成安装/校验（会降到它支持的版本 `v1.9.7.12.J273`）
4. 之后**每次都用这个启动器进游戏**（也可以在 Steam 的启动选项里指向它，一劳永逸）

> 本 mod 不修改游戏本体、不需要编译任何东西、不依赖任何其他 mod。
> （L 键的 Mod Config Menu 是可选的：入口默认关闭，见下。）

## 安装

把 `achievement_switch` 整个文件夹放进游戏的 `mods` 目录：

```
<游戏目录>\mods\achievement_switch\
    ├── main.lua
    └── metadata.xml
```

Windows 默认路径通常长这样：

```
G:\SteamLibrary\steamapps\common\The Binding of Isaac Rebirth\mods\achievement_switch\
```

或者直接用仓库里的脚本（会自动在常见 Steam 库里找游戏目录）：

```powershell
powershell -ExecutionPolicy Bypass -File tools\install.ps1
```

装完后**重启游戏**（mod 只在启动时加载）。

## 怎么用

主入口在**忏悔龙的 ImGui 菜单**：

1. 游戏内按 `~` 打开调试控制台 → 顶部菜单栏出现「成就开关」→ 点进去

里面有：

| 元素 | 作用 |
| --- | --- |
| ☑ 允许本局解锁成就 | **主开关**。关掉 = 本局不解锁成就 |
| 按钮「关闭成就（不重开…）」 | 试试不重开就关掉（本版引擎不行，会给明确提示） |
| 按钮「立即重开本局生效」 | 手动以同角色 / 同难度 / 同种子重开本局，必定生效 |
| ☑ 在 Mod Config Menu（L 键）里显示入口 | **默认关闭**。想在 L 键菜单里也有分类就勾上 |
| 局内快捷切换键（在 L 键菜单的分类里绑） | 需先打开上面那项 |

推荐流程：

1. 按 `~` →「成就开关」→ 把 **允许本局解锁成就** 关掉
2. **开一局新的** → 开局瞬间 mod 自动把本局标记为「不解锁成就」（见下方原理）
3. 想恢复成就：把开关打开，然后**再开一局新的**

怎么确认生效：进游戏会弹 `ACHIEVEMENTS / DISABLED` 提示条，并且 HUD 上会出现**划掉的奖杯图标** —— 那是游戏原生的「本局不解锁成就」标志。

## 工作原理（以及为什么只能这么做）

**原版忏悔+ 没有任何 Lua API 能关成就。** 成就门控是引擎内部的 `Seeds::AchievementUnlocksDisallowed()`，暴露给 Lua 的只有只读的 `Seeds:IsCustomRun()`。真正可用的原生开关只有一个 —— **「本局是不是自定义局／种子局」**（就是社区里说的「种子局拿不到成就」）。

忏悔龙把这条路补成了可用 API：

* `Isaac.StartNewGame(角色, 挑战, 难度, 种子, IsCustomRun)` —— 官方文档原话
  *"Setting IsCustomRun to true will disable achievements for the run"*
* `Game:AchievementUnlocksDisallowed()` —— 只读，用来每次生效后**读回自检**

于是有两条通道，先 A 后 B：

* **通道 A（免重开）**：把本局起始种子写回自身，看引擎会不会因此把本局当成种子局。
  **实测本版引擎无效**，所以只试一次就记账放弃，不再白试、不刷日志。
* **通道 B（重开）**：`Isaac.StartNewGame(..., IsCustomRun=true)`，以**同一角色、同挑战、同难度、同一种子**重开本局。

通道 B 上有三个细节，全部是实机踩出来的：

1. **不能在 `MC_POST_GAME_STARTED` 回调里直接重开** —— 引擎会把它连同本局启动流程一起吞掉，重开出来的局不是自定义局。所以推迟两帧再动手。
2. **难度必须用 `Game().Difficulty` 属性**，不能写 `Game:GetDifficulty()`（本版 Lua 里没有这个方法，取值永远是 0，会让困难/贪婪掉回普通）。挑战同理用 `Game().Challenge`。
3. **第一次不生效就换更晚的时机再试一次**（等 30 帧），两次都不行才停用自动重开并提示。

安全护栏：

* 自动重开只在 **全新开局的瞬间 + 单人 + 非读档续关** 时发生；续关／多人一律不自动重开
* 一局里最多自动重开两次，失败就本次游戏内停用并提示，**不会反复重开你**
* **局内手动关开关绝不自动重开**（不然会毁掉打到一半的进度），只提示「下一局生效」，想立刻生效自己点重开按钮
* 重开后核对难度/挑战有没有被改动，变了会明确告诉你

## 已知限制（都是引擎限制）

1. **本局一旦成为自定义局就撤不回来。** 引擎没有反向 API：关成就立刻有效，但重新打开成就必须**开新的一局**。
2. **中途关多半不生效**，只能重开本局或等下一局（mod 会明说）。
3. **多人／协作局不自动重开**（`Isaac.StartNewGame` 只能指定一个角色，会破坏队友）。
4. **存盘续关的局会丢标记。** 实测：把一局存下来再「继续」进入时，引擎不再保持「不解锁成就」，这一局可能正常解锁成就。mod 不替你重开续关的局（会毁进度），只在换层时提示一次。
5. 每日挑战本身是特殊判定，本 mod 不去动它。
6. 没有忏悔龙就没有重开通道，只剩通道 A（本版无效），等于用不了。

## 排错

日志在 `Documents/My Games/Binding of Isaac Repentance+/log.txt`（以撒的 `print` 只进游戏内调试控制台，mod 日志是通过 `Isaac.DebugString` 写进 `log.txt` 的）。搜 `[AchievementSwitch]`：

```
[INFO] - Lua Debug: [AchievementSwitch] 新局开始：允许成就=false 引擎已禁止=false(repentogon) 难度=2-贪婪(property) 挑战=0(property) 续关=false 人数=1 帧=3
[INFO] - Lua Debug: [AchievementSwitch] 通道 A 无效：写回起始种子后标记没有变化 —— 本版引擎不支持免重开，改用重开通道
[INFO] - Lua Debug: [AchievementSwitch] 已排队：开局自动重开（第 1 次，等 2 帧后执行）
[INFO] - Lua Debug: [AchievementSwitch] 通道 B：已要求重开为自定义局（角色=3 挑战=0(property) 难度=2-贪婪(property) 种子=123456789）
[INFO] - Lua Debug: [AchievementSwitch] 通道 B 成功：重开后本局已被引擎标记为不解锁成就
```

* `通道 B 成功` = 成了（`难度=` 那列可以核对贪婪/困难有没有被改）
* `通道 B 第 N 次重开后没生效` → 引擎这条路有问题，开 issue 带上日志
* `注意：重开后模式变了` → 难度/挑战被改了，也请带上日志
* 搜不到任何 `[AchievementSwitch]` → mod 没被加载，确认目录层级是 `mods/achievement_switch/main.lua`，并在 `log.txt` 里搜 `There was an error running the lua file`

## 卸载

删掉 `mods/achievement_switch` 文件夹即可。设置存档在
`Documents/My Games/Binding of Isaac Repentance+/data/achievement_switch/`。

---

## 实测记录

在真实游戏里跑通并据此改过代码的现象（详细日志见 issue / 提交记录）：

| 现象 | 处理 |
| --- | --- |
| `Game:GetDifficulty()` 不存在 → 难度恒为 0，**困难掉成普通、贪婪失效** | 改用 `Game().Difficulty` 属性；困难(1)与困难贪婪(3) 均已实机验证 |
| 在 `MC_POST_GAME_STARTED` 里直接 `StartNewGame` → 重开后的局**不是**自定义局 | 推迟 2 帧执行 + 失败后换 30 帧再试一次 |
| 开局时 `MC_POST_NEW_LEVEL` **先于** `MC_POST_GAME_STARTED` 触发 → 每开一局误报「标记丢失」 | 换层复查推迟 5 帧执行 |
| 以撒 Lua 沙箱**没有 `io` / `os`** → 用 `io` 写日志会让整个 `main.lua` 加载中断 | 日志只走 `print` + `Isaac.DebugString`；离线测试的沙箱里也把 `io`/`os` 抹成 `nil` 防复发 |
| `print` 不进 `log.txt` | 统一用 `Isaac.DebugString` |

## 开发 / 测试

不需要开游戏就能跑逻辑测试（真实 Lua 解释器 + 一套假的以撒 API）：

```bash
python -m pip install lupa
python tools/run_tests.py
```

51 项断言，覆盖：免重开通道、延迟重开与重试、普通/困难/贪婪/困难贪婪四种难度的参数、续关不重开、多人不重开、非法种子不写回、无忏悔龙降级、快捷按键、L 键菜单入口显隐与双向同步、开局顺序不误报、300 帧渲染无异常等。

假环境（`tools/mock_env.lua`）刻意复刻了两个真机坑，防止改代码时复发：

* `io` / `os` 为 `nil`（以撒 Lua 沙箱就是这样）
* 只提供 `Game().Difficulty` / `Game().Challenge` **属性**，不提供 `GetDifficulty()` / `GetChallenge()` **方法**

## 许可

[MIT](LICENSE) —— 随便用、随便改、随便再发布，保留版权声明即可。

与 Nicalis / Edmund McMillen 无关，与 REPENTOGON 团队无关。以撒的结合（The Binding of Isaac）是其各自权利人的商标。

---

## English overview

**Achievement Switch** for *The Binding of Isaac: Repentance+* — a toggle that decides whether **the current run can unlock achievements**.

* **Requires [REPENTOGON](https://repentogon.com/install.html)** (its `Isaac.StartNewGame(..., IsCustomRun=true)` is the only native "no achievements" switch the engine exposes).
* Install: drop `achievement_switch/` into `<game>/mods/`, or run `tools\install.ps1`.
* Use: in game press `~` → the top menu bar → **Achievement Switch**. The Mod Config Menu (L) entry is hidden by default and can be re-enabled from there.
* Because there is no Lua API to flip the per-run achievement gate, the mod marks the run as a *custom/seeded run* by restarting it once at the very start with the **same character, challenge, difficulty and seed** — the floor layout stays identical.
* Verified against Repentance+ `1.9.7.17` + REPENTOGON `1.1.2g`. On this build the "restart-free" attempt does not work, so a restart is used.
* **AI-generated, human-reviewed.** See the notice at the top. MIT licensed.
