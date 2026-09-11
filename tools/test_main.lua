-- 离线逻辑测试：不启动游戏，用假环境跑通 main.lua 的全部判定分支。
-- 运行： python tools/run_tests.py
--
-- 两个会话级状态会影响后续场景，所以顺序很讲究：
--   * liveApplyUsable：通道 A 一旦被判无效，本次游戏内就不再尝试（由 [3d] 触发）
--   * autoRestartOff ：通道 B 一旦被判无效，本次游戏内就不再自动重开（由 [10] 触发，放最后）
-- 凡是会「排队自动重开」的场景，结束时都要 CONSUME_RESTART() 把这次重开消费掉。

local MAIN = "achievement_switch/main.lua"

local function resetRun(opts)
	opts = opts or {}
	MOCK.inRun      = (opts.inRun ~= false)
	MOCK.frame      = opts.frame or 0
	MOCK.continued  = opts.continued or false
	MOCK.players    = opts.players or 1
	MOCK.blocked    = opts.blocked or false
	MOCK.difficulty = opts.difficulty or 0
	MOCK.challenge  = opts.challenge or 0
	MOCK.validSeedString   = (opts.validSeedString ~= false)
	MOCK.setStartSeedWorks = (opts.setStartSeedWorks ~= false)
	MOCK.restartWorks      = (opts.restartWorks ~= false)
	MOCK.hasRepentogon     = (opts.hasRepentogon ~= false)
	MOCK.hasStartNewGame   = (opts.hasStartNewGame ~= false)

	-- 先把上一个场景可能残留在队列里的重开跑掉（模拟现实里过了 5 秒）
	RENDER(320)
	MOCK:reset()
end

--- 模拟「重开后的那一局开局」，把 autoRestartOn 状态消费掉
--- （难度/挑战要沿用，否则会被 mod 判成「模式变了」）
local function CONSUME_RESTART(blockedAfter)
	local d, c = MOCK.difficulty, MOCK.challenge
	resetRun({ blocked = (blockedAfter ~= false), restartWorks = true, difficulty = d, challenge = c })
	FIRE(ModCallbacks.MC_POST_GAME_STARTED, false)
	MOCK:reset()
end

local function countHud(text)
	local n = 0
	for _, t in ipairs(MOCK.hudTexts) do
		if t == text then n = n + 1 end
	end
	return n
end

local function countImGuiNotification(sub)
	local n = 0
	for _, e in ipairs(ImGuiEvents) do
		if e.name == "PushNotification" and type(e[1]) == "string" and e[1]:find(sub, 1, true) then
			n = n + 1
		end
	end
	return n
end

--============================================================== 1. 加载

print("\n[1] 加载 main.lua（沙箱里没有 io/os）")
SETTINGS({})   -- 默认：allowAchievements=true, showInMCM=false
local ok, err = pcall(dofile, MAIN)
CHECK(ok, "main.lua 无语法/运行时错误" .. (ok and "" or (": " .. tostring(err))))
CHECK(MOD() ~= nil and MOD().name == "Achievement Switch", "已注册 RegisterMod")

--============================================================== 2. 默认隐藏 L 键菜单入口

print("\n[2] 默认隐藏 Mod Config Menu（L 键）入口，代码保留可随时开回来")
RENDER(1)
CHECK(#MCM.registered == 0, "默认不注册 MCM 分类（L 键菜单里看不到）")
CHECK(ImGuiCallbacks["ASwitch_McmToggleCheckbox"] ~= nil, "ImGui 里有『在 L 键菜单显示入口』的复选框")

IMGUI_ACT("ASwitch_McmToggleCheckbox", true)
CHECK(#MCM.registered >= 5, "打开后注册了设置项（" .. #MCM.registered .. " 项）")
IMGUI_ACT("ASwitch_McmToggleCheckbox", false)
CHECK(MCM.removedCategory == "成就开关", "关掉后从 MCM 移除了分类（" .. tostring(MCM.removedCategory) .. "）")

--============================================================== 3. 通道 A 有效：免重开

print("\n[3] 开局关成就 + 通道 A 有效 → 免重开")
resetRun({ setStartSeedWorks = true })
SETTINGS({ allowAchievements = false })
FIRE(ModCallbacks.MC_POST_GAME_STARTED, false)
CHECK(MOCK:countCalls("SetStartSeed") == 1, "调用了 SetStartSeed（写回起始种子）")
RENDER(5)
CHECK(MOCK:countCalls("StartNewGame") == 0, "没有重开本局")
CHECK(MOCK:lastCall("SetStartSeed")[1] == "B911 99JA", "写回的是本局当前种子串")
RENDER(80)
CHECK(countHud("ACHIEVEMENTS|DISABLED") >= 1, "显示了 DISABLED 提示")

--============================================================== 3b. 非法种子串（趁通道 A 还有效）

print("\n[3b] 种子串非法 → 不写回种子，直接走重开通道")
resetRun({ setStartSeedWorks = true, restartWorks = true, validSeedString = false })
SETTINGS({ allowAchievements = false })
FIRE(ModCallbacks.MC_POST_GAME_STARTED, false)
CHECK(MOCK:countCalls("SetStartSeed") == 0, "非法种子串不会写回（避免随机换种子）")
RENDER(3)
CHECK(MOCK:countCalls("StartNewGame") == 1, "改走重开通道")
CHECK(countImGuiNotification("模式变了") == 0, "没有误报模式变化")
CONSUME_RESTART(true)

--============================================================== 3c. 没有忏悔龙

print("\n[3c] 未安装忏悔龙 → 只用通道 A，不报错、不重开")
resetRun({ hasRepentogon = false, hasStartNewGame = false, setStartSeedWorks = true })
SETTINGS({ allowAchievements = false })
CHECK(pcall(FIRE, ModCallbacks.MC_POST_GAME_STARTED, false), "无忏悔龙时开局回调不报错")
CHECK(MOCK:countCalls("SetStartSeed") == 1, "仍然尝试通道 A")

print("\n[3d] 无忏悔龙 + 通道 A 无效 → 安全跳过（并从此记住通道 A 不可用）")
resetRun({ hasRepentogon = false, hasStartNewGame = false, setStartSeedWorks = false })
SETTINGS({ allowAchievements = false })
CHECK(pcall(FIRE, ModCallbacks.MC_POST_GAME_STARTED, false), "不报错")
RENDER(5)
CHECK(MOCK:countCalls("StartNewGame") == 0, "没有 StartNewGame 可用，安全跳过")

--============================================================== 4. 通道 A 无效 → 延迟重开（关键修复）

print("\n[4] 通道 A 无效 → 自动重开必须推迟到开局回调之后")
resetRun({ setStartSeedWorks = false, restartWorks = true, difficulty = 0 })
SETTINGS({ allowAchievements = false })
FIRE(ModCallbacks.MC_POST_GAME_STARTED, false)
CHECK(MOCK:countCalls("StartNewGame") == 0, "开局回调里【不】直接重开（会被引擎吞掉）")
CHECK(MOCK:countCalls("SetStartSeed") == 0, "通道 A 已被记住无效，不再白试")
RENDER(3)
CHECK(MOCK:countCalls("StartNewGame") == 1, "几帧之后才真正重开")
local sn = MOCK:lastCall("StartNewGame")
CHECK(sn ~= nil and sn[5] == true, "IsCustomRun = true（原生禁用成就）")
CHECK(sn ~= nil and sn[1] == 3, "沿用原角色")
CHECK(sn ~= nil and sn[4] == MOCK.startSeed, "沿用原种子")
CONSUME_RESTART(true)

--============================================================== 5. 难度：普通 / 困难 / 贪婪 / 困难贪婪

print("\n[5] 重开时用 Game().Difficulty 属性带上正确难度（不是 GetDifficulty() 方法）")
local function checkDifficultyPerMode(diff, label, challenge)
	resetRun({ setStartSeedWorks = false, restartWorks = true, difficulty = diff, challenge = challenge or 0 })
	SETTINGS({ allowAchievements = false })
	FIRE(ModCallbacks.MC_POST_GAME_STARTED, false)
	RENDER(3)
	local call = MOCK:lastCall("StartNewGame")
	CHECK(call ~= nil and call[3] == diff,
		label .. "：难度参数 = " .. tostring(call and call[3]) .. "（应为 " .. diff .. "）")
	if challenge then
		CHECK(call ~= nil and call[2] == challenge,
			label .. "：保留挑战模式 = " .. tostring(call and call[2]))
	end
	CONSUME_RESTART(true)
end
checkDifficultyPerMode(0, "普通模式")
checkDifficultyPerMode(1, "困难模式")
checkDifficultyPerMode(2, "贪婪模式")
checkDifficultyPerMode(3, "困难贪婪模式")
checkDifficultyPerMode(0, "挑战局（挑战=8）", 8)

--============================================================== 6. 模式被改动时报警

print("\n[6] 重开后难度被改动会报警（贪婪掉回普通这种）")
resetRun({ setStartSeedWorks = false, restartWorks = true, difficulty = 2 })
SETTINGS({ allowAchievements = false })
FIRE(ModCallbacks.MC_POST_GAME_STARTED, false)
RENDER(3)
MOCK:reset()
resetRun({ blocked = true, difficulty = 0 })   -- 重开后的那一局：难度变成了普通
FIRE(ModCallbacks.MC_POST_GAME_STARTED, false)
CHECK(countImGuiNotification("模式变了") == 1, "检测到难度从贪婪变成普通并给出提示")

--============================================================== 7. 续关不自动重开

print("\n[7] 续关（读档）不自动重开")
resetRun({ continued = true, setStartSeedWorks = false })
SETTINGS({ allowAchievements = false })
FIRE(ModCallbacks.MC_POST_GAME_STARTED, true)
RENDER(5)
CHECK(MOCK:countCalls("StartNewGame") == 0, "续关不重开，避免毁掉进度")
CHECK(countHud("ACHIEVEMENTS|OFF NEXT RUN") >= 1, "提示「下一局生效」")

--============================================================== 8. 局内手动关闭

print("\n[8] 局内手动关闭成就：不重开，只提示；点按钮才重开")
resetRun({ frame = 3000, setStartSeedWorks = false })
SETTINGS({ allowAchievements = true })
FIRE(ModCallbacks.MC_POST_GAME_STARTED, false)
MOCK:reset()
IMGUI_ACT("ASwitch_ToggleCheckbox", false)
CHECK(MOCK:countCalls("StartNewGame") == 0, "局内绝不偷偷重开玩家进度")
CHECK(countHud("ACHIEVEMENTS|OFF NEXT RUN") >= 1, "明确提示：只能重开或下一局生效")

MOCK:reset()
IMGUI_ACT("ASwitch_RestartButton")
CHECK(MOCK:countCalls("StartNewGame") == 1, "手动点『立即重开本局生效』才会重开")
RENDER(160)
CHECK(countHud("ACHIEVEMENTS|DISABLED") >= 1, "重开后给出已关闭提示")
CONSUME_RESTART(true)

--============================================================== 9. 多人 / 关闭自动重开 / 允许成就

print("\n[9] 多人局、关闭「开局自动生效」、允许成就时不重开")
resetRun({ players = 2, setStartSeedWorks = false })
SETTINGS({ allowAchievements = false })
FIRE(ModCallbacks.MC_POST_GAME_STARTED, false)
RENDER(3)
CHECK(MOCK:countCalls("StartNewGame") == 0, "多人局不重开（免得破坏队友角色）")

resetRun({ setStartSeedWorks = false })
SETTINGS({ allowAchievements = false, applyOnRunStart = false })
FIRE(ModCallbacks.MC_POST_GAME_STARTED, false)
RENDER(3)
CHECK(MOCK:countCalls("StartNewGame") == 0, "尊重「开局自动生效」关闭设置")

resetRun({})
SETTINGS({ allowAchievements = true })
FIRE(ModCallbacks.MC_POST_GAME_STARTED, false)
RENDER(5)
CHECK(MOCK:countCalls("SetStartSeed") == 0 and MOCK:countCalls("StartNewGame") == 0, "允许成就时不碰引擎")

--============================================================== 10. 换层复查

print("\n[10] 换层复查：开局顺序不误报；真丢了才提示一次")
-- 真机顺序是 NEW_LEVEL 先于 GAME_STARTED（之前就是在这里误报「标记丢失」的）
resetRun({})
SETTINGS({ allowAchievements = false, applyOnRunStart = false })
FIRE(ModCallbacks.MC_POST_NEW_LEVEL)
FIRE(ModCallbacks.MC_POST_GAME_STARTED, false)
RENDER(20)
CHECK(countHud("ACHIEVEMENTS|GATE LOST") == 0, "开局顺序导致的 NEW_LEVEL 不误报（关键修复）")

-- 中途换层真的丢了标记 → 提示一次，且只一次
MOCK.blocked = false
RENDER(200)                            -- 过掉开局保护期
FIRE(ModCallbacks.MC_POST_NEW_LEVEL)
FIRE(ModCallbacks.MC_POST_NEW_LEVEL)
RENDER(20)
CHECK(countHud("ACHIEVEMENTS|GATE LOST") == 1,
	"真丢了才提示，且只提示一次（实际 " .. countHud("ACHIEVEMENTS|GATE LOST") .. "）")

--============================================================== 11. 快捷按键

print("\n[11] 局内快捷按键切换")
resetRun({ setStartSeedWorks = true })
SETTINGS({ allowAchievements = true, toggleKey = 65 })
FIRE(ModCallbacks.MC_POST_GAME_STARTED, false)
MOCK:reset()
Input.triggered[65] = true
RENDER(1)
Input.triggered[65] = false
CHECK(countHud("ACHIEVEMENTS|OFF") >= 1, "按一下把成就关掉")
RENDER(1)
CHECK(countHud("ACHIEVEMENTS|OFF") == 1, "松开后不重复触发")

--============================================================== 12. ImGui 菜单

print("\n[12] 忏悔龙 ImGui 菜单元素齐全")
local hasWindow = false
for _, e in ipairs(ImGuiEvents) do
	if e.name == "CreateWindow" then hasWindow = true end
end
local hasToggle  = ImGuiCallbacks["ASwitch_ToggleCheckbox"] ~= nil
local hasRestart = ImGuiCallbacks["ASwitch_RestartButton"] ~= nil
local hasMcm     = ImGuiCallbacks["ASwitch_McmToggleCheckbox"] ~= nil
CHECK(hasWindow and hasToggle and hasRestart and hasMcm,
	"窗口 + 主开关 + 重开按钮 + L键菜单开关 都在")

--============================================================== 13. MCM 按键同步

print("\n[13] 在 MCM 里改按键会写回存档")
resetRun({})
SETTINGS({ allowAchievements = true, showInMCM = true })
FIRE(ModCallbacks.MC_POST_GAME_STARTED, false)
RENDER(1)   -- 第一次同步先把存档里的值推给 MCM
ModConfigMenu.Config["成就开关"].toggleKey = 70
RENDER(1)
CHECK((MOD().data or ""):find("toggleKey=70", 1, true) ~= nil, "toggleKey=70 已写入存档")

--============================================================== 14. 通道 B 无效 → 停用自动重开（最后测）

print("\n[14] 通道 B 无效 → 重试一次后停用自动重开（本组必须最后测）")
resetRun({ setStartSeedWorks = false, restartWorks = false })
SETTINGS({ allowAchievements = false })
FIRE(ModCallbacks.MC_POST_GAME_STARTED, false)
RENDER(3)
CHECK(MOCK:countCalls("StartNewGame") == 1, "第 1 次自动重开")
FIRE(ModCallbacks.MC_POST_GAME_STARTED, false)   -- 重开后的开局：验证失败
CHECK(MOCK.blocked == false, "引擎仍未关闭成就")
RENDER(35)
CHECK(MOCK:countCalls("StartNewGame") == 2, "换更晚的时机再试第 2 次")
FIRE(ModCallbacks.MC_POST_GAME_STARTED, false)   -- 仍然失败
CHECK(countHud("ACHIEVEMENTS|OFF FAILED") >= 1, "两次都失败后给出提示并停用")
resetRun({ setStartSeedWorks = false, restartWorks = false })
SETTINGS({ allowAchievements = false })
FIRE(ModCallbacks.MC_POST_GAME_STARTED, false)
RENDER(40)
CHECK(MOCK:countCalls("StartNewGame") == 0, "之后不再自动重开，不骚扰玩家")

--============================================================== 15. 长时间渲染

print("\n[15] 连续渲染 300 帧无异常")
CHECK(pcall(RENDER, 300), "300 帧渲染无 Lua 错误")

SUMMARY()
