--[[----------------------------------------------------------------------------
    成就开关 / Achievement Switch
    以撒的结合：重生 忏悔+ (The Binding of Isaac: Repentance+)

    作用：一个开关，决定「本局是否能解锁成就」。

    ── 为什么需要它 ──────────────────────────────────────────────
    原版（含忏悔+）的成就门控是引擎内部的 Seeds::AchievementUnlocksDisallowed()，
    没有任何 Lua API 可以读写它。装了忏悔龙(REPENTOGON)后它额外提供了：
      * Game:AchievementUnlocksDisallowed()  → 读取本局能否解锁成就（只读，引擎自己用的判定）
      * Isaac.StartNewGame(角色, 挑战, 难度, 种子, IsCustomRun)
        官方说明：「Setting IsCustomRun to true will disable achievements for the run」
        这正是游戏原生用来「本局不解锁成就」的标记（自定义局／种子局）。
    所以本 mod 是用原生标记关掉成就，而不是伪造判定。

    ── 两种生效通道 ─────────────────────────────────────────────
    通道 A（即时、免重开）：把本局起始种子写回自身，再用 Game:AchievementUnlocksDisallowed()
                          读回自检。部分版本会因此把本局当成种子局。
    通道 B（重开）：用 Isaac.StartNewGame(..., IsCustomRun=true) 以同一角色／同一难度／
                    同一种子重开本局。只在「全新开局的头几秒」自动执行，或由你手动点击。

    ── 安全护栏 ─────────────────────────────────────────────────
      * 自动重开只在「非续关 + 开局 240 帧内 + 单人」时发生；续关／多人一律不自动重开。
      * 自动重开最多执行一次；若无效则本次游戏内永久停用自动重开并提示。
      * 本局一旦成为自定义局，引擎无法撤销 —— 想恢复成就请开新的一局。
      * 引擎限制：mid-run 关闭可能不生效，此时一律「下一局生效」，绝不偷偷重开你的进度。
----------------------------------------------------------------------------]]

local MOD_NAME    = "Achievement Switch"
local MOD_VERSION = "1.1.1"
local MOD_TAG     = "[AchievementSwitch]"

local mod = RegisterMod(MOD_NAME, 1)   -- 1 = Repentance API

--============================================================== 状态（先声明，避免回调里读不到）

local mcmRegistered     = false   -- 是否已注册进 Mod Config Menu
local imguInited        = false   -- 是否已建好忏悔龙 ImGui 菜单
local pendingNotice     = nil     -- 延迟显示的屏幕提示
local restartCooldown   = 0       -- 帧计数，防止重开死循环
local autoRestartOn     = false   -- 本次重开是否为 mod 自动发起
local autoRestartOff    = false   -- 自动重开已被判定无效，本次游戏内不再使用
local gateLostWarned    = false   -- 本局是否已经提示过「标记丢失」
local syncedToggleKey   = nil     -- 已知的 MCM 按键值，用于双向同步
local liveApplyUsable   = true    -- 通道 A 是否还有效（实测无效后就不再白试）
local expectedDifficulty = nil    -- 最近一次重开时打算用的难度，用于重开后核对
local expectedChallenge  = nil    -- 同上，挑战模式
local pendingAutoRestart = false  -- 待执行的开局自动重开
local pendingAutoFrames  = 0      -- 再等几帧动手（不在开局回调里直接重开）
local autoRestartAttempts = 0     -- 本会话里自动重开试了几次
local AUTO_RESTART_MAX_TRIES = 2  -- 最多试两次，避免遇到死循环
local framesSinceGameStart = 100000  -- 距上次开局过了几帧，用于避开开局瞬间
local pendingGateCheck    = false -- 换层复查排队中
local pendingGateCheckFrames = 0

-- 前向声明（回调里会用到，定义在文件后段）
local registerModConfigMenu
local initImGui
local refreshInterfaceStatus
local syncKeybindFromModConfigMenu

--============================================================== 基础工具

--- 日志往哪写：以撒的 Lua 沙箱里没有 io/os，所以只能走这两条：
---   print            → 游戏内调试控制台（按 ~ 看）
---   Isaac.DebugString→ log.txt（实测会写成 "[INFO] - Lua Debug: ..."）
local function log(msg)
	local line = MOD_TAG .. " " .. tostring(msg)
	print(line)
	if Isaac ~= nil and type(Isaac.DebugString) == "function" then
		pcall(Isaac.DebugString, line)
	end
end

local function getGame()
	return Game()
end

local function isRepentogon()
	return REPENTOGON ~= nil
end

local function pcallValue(fn, fallback)
	local ok, value = pcall(fn)
	if ok then return value end
	return fallback
end

--============================================================== 设置与存档

local DEFAULTS = {
	allowAchievements = true,   -- 本局是否允许解锁成就
	applyOnRunStart   = true,   -- 开局自动生效（必要时自动重开本局）
	tryLiveApply      = true,   -- 先试一次免重开的即时通道
	showNotice        = true,   -- 屏幕提示
	toggleKey         = -1,     -- 局内快捷切换键（-1 = 未绑定）
	debugLog          = true,   -- 详细日志
	showInMCM         = false,  -- 是否在 Mod Config Menu（L 键菜单）里显示入口（默认隐藏）
}

local settings = {}
for k, v in pairs(DEFAULTS) do settings[k] = v end

local function serializeSettings()
	local parts = { "achievement-switch/1" }
	for k, v in pairs(settings) do
		parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
	end
	return table.concat(parts, "\n")
end

local function deserializeSettings(data)
	if type(data) ~= "string" then return false end
	local loaded = false
	for key, value in data:gmatch("([%w_]+)=([^\n]*)") do
		local def = DEFAULTS[key]
		if def ~= nil then
			if type(def) == "boolean" then
				settings[key] = (value == "true")
				loaded = true
			elseif type(def) == "number" then
				settings[key] = tonumber(value) or def
				loaded = true
			end
		end
	end
	return loaded
end

local function saveSettings()
	local ok, err = pcall(function() mod:SaveData(serializeSettings()) end)
	if not ok then log("保存设置失败：" .. tostring(err)) end
end

local function loadSettings()
	local has = pcallValue(function() return mod:HasData() end, false)
	if not has then return false end
	local data = pcallValue(function() return mod:LoadData() end, nil)
	return deserializeSettings(data)
end

--============================================================== 引擎状态读取

--- 本局是否被引擎禁止解锁成就。返回 blocked(boolean), source(string)
local function achievementsBlocked()
	local game = getGame()
	if game == nil then return false, "no-game" end

	-- 忏悔龙：这就是引擎发放成就时自己用的那个判定
	if type(game.AchievementUnlocksDisallowed) == "function" then
		local res = pcallValue(function() return game:AchievementUnlocksDisallowed() end, nil)
		if type(res) == "boolean" then return res, "repentogon" end
	end

	-- 原版回退：自定义局／挑战局／种子局
	local seeds = pcallValue(function() return game:GetSeeds() end, nil)
	if seeds ~= nil then
		local res = pcallValue(function() return seeds:IsCustomRun() end, nil)
		if type(res) == "boolean" then return res, "vanilla" end
	end

	return false, "unknown"
end

local function getSeeds()
	local game = getGame()
	if game == nil then return nil end
	return pcallValue(function() return game:GetSeeds() end, nil)
end

local function runFrameCount()
	local game = getGame()
	if game == nil then return 0 end
	return pcallValue(function() return game:GetFrameCount() end, 0) or 0
end

local function numPlayers()
	local game = getGame()
	if game == nil then return 0 end
	return pcallValue(function() return game:GetNumPlayers() end, 0) or 0
end

local function isInRun()
	local game = getGame()
	if game == nil then return false end
	return pcallValue(function() return game:GetRoom() ~= nil end, false) == true
end

local function isContinuedRun()
	local game = getGame()
	if game == nil then return false end
	local v = pcallValue(function() return game:IsContinued() end, nil)
	if type(v) == "boolean" then return v end
	return false
end

--- MC_POST_GAME_STARTED 的参数在不同版本里位置不一样，全部扫一遍再兜底
local function readIsContinued(...)
	local n = select("#", ...)
	for i = 1, n do
		local v = select(i, ...)
		if type(v) == "boolean" then return v end
	end
	return isContinuedRun()
end

--- 本局难度。官方文档明确写了：区分 Greed / Greedier 要用 Game().Difficulty 这个
--- **属性**；Game:GetDifficulty() 这个方法在本版 Lua 里并不存在（踩过坑）。
local function currentDifficulty()
	local game = getGame()
	if game == nil then return 0, "no-game" end

	local v = pcallValue(function() return game.Difficulty end, nil)
	if type(v) == "number" then return v, "property" end

	v = pcallValue(function() return game:GetDifficulty() end, nil)
	if type(v) == "number" then return v, "method" end

	-- 属性取不到时只能分到「贪婪/困难」这一档，Greed 与 Greedier 分不出来
	if pcallValue(function() return game:IsGreedMode() end, false) == true then
		return 2, "greed-flag"
	end
	if pcallValue(function() return game:IsHardMode() end, false) == true then
		return 1, "hard-flag"
	end
	return 0, "fallback"
end

--- 本局挑战模式。同样是属性 Game().Challenge，而不是 Game:GetChallenge()。
local function currentChallenge()
	local game = getGame()
	if game == nil then return 0, "no-game" end

	local v = pcallValue(function() return game.Challenge end, nil)
	if type(v) == "number" then return v, "property" end

	v = pcallValue(function() return game:GetChallenge() end, nil)
	if type(v) == "number" then return v, "method" end

	return 0, "fallback"
end

local DIFFICULTY_NAME = { [0] = "普通", [1] = "困难", [2] = "贪婪", [3] = "困难贪婪" }
local function difficultyName(v)
	return DIFFICULTY_NAME[v] or ("未知(" .. tostring(v) .. ")")
end

--============================================================== 提示输出

local function hudNotice(mainText, subText)
	if not settings.showNotice then return end
	local game = getGame()
	if game == nil then return end
	-- HUD 用游戏自带字体，只有 ASCII 能正常显示
	pcall(function() game:GetHUD():ShowItemText(mainText, subText or "") end)
end

local function scheduleHudNotice(mainText, subText, delayFrames)
	pendingNotice = { main = mainText, sub = subText, frames = delayFrames or 90 }
end

local function imguNotify(text)
	if not isRepentogon() or ImGui == nil then return end
	pcall(function()
		local ntype = 0
		if type(ImGuiNotificationType) == "table" and type(ImGuiNotificationType.INFO) == "number" then
			ntype = ImGuiNotificationType.INFO
		end
		ImGui.PushNotification(text, ntype, 4000)
	end)
end

--- 统一反馈：日志 + 忏悔龙弹窗 +（可选）屏幕提示
local function notify(text, hudMain, hudSub)
	log(text)
	imguNotify(text)
	if hudMain then hudNotice(hudMain, hudSub) end
	if refreshInterfaceStatus then refreshInterfaceStatus() end
end

--============================================================== 生效通道

--- 通道 A：把本局起始种子写回自身，看引擎是否因此关闭成就。返回 blocked(boolean)
local function tryLiveApply()
	local seeds = getSeeds()
	if seeds == nil then return false end

	local seedString = pcallValue(function() return seeds:GetStartSeedString() end, nil)
	if type(seedString) ~= "string" or seedString == "" then return false end

	local seedInt = pcallValue(function() return seeds:GetStartSeed() end, nil)
	if type(seedInt) ~= "number" or seedInt == 0 then return false end

	-- 必须是合法种子串，否则 SetStartSeed 会随机换种子（那就是副作用了）
	if Seeds ~= nil and type(Seeds.IsStringValidSeed) == "function" then
		local valid = pcallValue(function() return Seeds.IsStringValidSeed(seedString) end, true)
		if valid == false then
			if settings.debugLog then
				log('通道 A 跳过：种子串 "' .. seedString .. '" 被判定为非法')
			end
			return false
		end
	end

	local ok, err = pcall(function() seeds:SetStartSeed(seedString) end)
	if not ok then
		if settings.debugLog then log("通道 A 失败：SetStartSeed 出错 " .. tostring(err)) end
		return false
	end

	local blocked = achievementsBlocked()
	if blocked then
		log("通道 A 成功：写回起始种子后本局成就已被引擎关闭（免重开）")
		return true
	end

	if liveApplyUsable then
		liveApplyUsable = false
		log("通道 A 无效：写回起始种子后标记没有变化 —— 本版引擎不支持免重开，改用重开通道")
	end
	return false
end

--- 通道 B：以同一角色／挑战／难度／种子重开本局，并标记为自定义局（原生禁用成就）
local function restartAsCustomRun()
	if type(Isaac.StartNewGame) ~= "function" then
		return false, "未检测到忏悔龙的 Isaac.StartNewGame，无法使用重开通道"
	end

	local game = getGame()
	if game == nil then return false, "当前没有进行中的游戏" end
	if numPlayers() > 1 then
		return false, "多人／协作局不自动重开，以免破坏队友角色"
	end

	local character             = pcallValue(function() return game:GetPlayer(0):GetPlayerType() end, 0) or 0
	local challenge, chalSource = currentChallenge()
	local difficulty, difSource = currentDifficulty()

	local seeds = getSeeds()
	local seed = 0
	if seeds ~= nil then
		seed = pcallValue(function() return seeds:GetStartSeed() end, 0) or 0
	end

	-- 记下来，重开后的那一局开局时用来核对模式有没有被改动
	expectedDifficulty = difficulty
	expectedChallenge  = challenge

	local ok, err = pcall(function()
		Isaac.StartNewGame(character, challenge, difficulty, seed, true)
	end)
	if not ok then return false, tostring(err) end

	log(string.format("通道 B：已要求重开为自定义局（角色=%d 挑战=%d(%s) 难度=%d-%s(%s) 种子=%d）",
		character, challenge, chalSource, difficulty, difficultyName(difficulty), difSource, seed))
	return true
end

--============================================================== 开关动作

--- 局内/菜单显示用的状态文字（顺带显示难度，方便核对贪婪与困难模式）
local function currentStatusText()
	if not isInRun() then
		return settings.allowAchievements
			and "状态：允许解锁成就（等待开局）"
			or  "状态：已关闭成就解锁（下一局生效）"
	end
	local blocked, source = achievementsBlocked()
	local mode = difficultyName(currentDifficulty())
	if settings.allowAchievements then
		return "本局状态：允许解锁成就（" .. mode .. "）"
	end
	if blocked then
		return "本局状态：已禁止解锁（引擎确认／" .. source .. "，" .. mode .. "）"
	end
	return "本局状态：本局未能禁止，下一局生效（" .. mode .. "）"
end

--- 现在就把「关闭成就」生效。explicitRestart=true 表示玩家主动点了重开按钮
local function disableAchievementsNow(explicitRestart)
	if not isInRun() then
		notify("已关闭成就解锁：从新的一局开始生效。")
		return
	end

	local blocked, source = achievementsBlocked()
	if blocked then
		notify("本局已经不会解锁成就了（引擎标记：" .. source .. "）。")
		return
	end

	if settings.tryLiveApply and liveApplyUsable and tryLiveApply() then
		notify("已即时关闭本局成就（通道 A：种子写回，免重开）。", "ACHIEVEMENTS", "DISABLED")
		return
	end

	if explicitRestart then
		if numPlayers() > 1 then
			notify("多人局不自动重开：请自行重开并让所有人用同一角色。")
			return
		end
		local ok, err = restartAsCustomRun()
		if ok then
			restartCooldown = 300
			scheduleHudNotice("ACHIEVEMENTS", "DISABLED", 150)
			notify("已重开本局（同角色／同难度／同种子）并关闭成就。")
		else
			notify("重开失败：" .. tostring(err))
		end
		return
	end

	if not liveApplyUsable then
		notify("本版引擎不支持「不重开就关闭成就」，本局只能靠重开；也可以从下一局开始生效。",
			"ACHIEVEMENTS", "OFF NEXT RUN")
	else
		notify("引擎不允许中途关闭本局成就，将从下一局开始生效。",
			"ACHIEVEMENTS", "OFF NEXT RUN")
	end
end

--- 局内快捷切换
local function toggleAllowAchievements()
	settings.allowAchievements = not settings.allowAchievements
	saveSettings()
	if refreshInterfaceStatus then refreshInterfaceStatus() end

	if settings.allowAchievements then
		notify("已允许解锁成就。注意：本局若已被标记为自定义局，引擎无法撤销，需开新局才恢复成就。",
			"ACHIEVEMENTS", "ON NEXT RUN")
	else
		notify("已关闭成就解锁。", "ACHIEVEMENTS", "OFF")
		disableAchievementsNow(false)
	end
end

--============================================================== 回调：开局

local function onGameStarted(isContinuedParam)
	local continued = (isContinuedParam == true) or isContinuedRun()

	loadSettings()
	registerModConfigMenu()
	initImGui()
	if refreshInterfaceStatus then refreshInterfaceStatus() end

	gateLostWarned = false
	framesSinceGameStart = 0

	local blocked, source = achievementsBlocked()

	-- 每局一行的判定摘要，始终记录（顺带把模式/难度记下来，方便核对贪婪、困难）
	local difficulty, difSource = currentDifficulty()
	local challenge, chalSource = currentChallenge()
	log(string.format("新局开始：允许成就=%s 引擎已禁止=%s(%s) 难度=%d-%s(%s) 挑战=%d(%s) 续关=%s 人数=%d 帧=%d",
		tostring(settings.allowAchievements), tostring(blocked), source,
		difficulty, difficultyName(difficulty), difSource, challenge, chalSource,
		tostring(continued), numPlayers(), runFrameCount()))

	-- 重开后的那一局：核对模式有没有被改动（贪婪/困难最容易在这里露馅）
	if expectedDifficulty ~= nil and not settings.allowAchievements then
		if difficulty ~= expectedDifficulty or challenge ~= expectedChallenge then
			notify(string.format("注意：重开后模式变了（难度 %s → %s，挑战 %s → %s）。请把日志发我。",
				difficultyName(expectedDifficulty), difficultyName(difficulty),
				tostring(expectedChallenge), tostring(challenge)))
		end
		expectedDifficulty, expectedChallenge = nil, nil
	end

	if settings.allowAchievements then return end

	-- 上一次是 mod 自动重开的：现在验证通道 B 到底有没有生效
	if autoRestartOn then
		autoRestartOn = false
		if blocked then
			autoRestartAttempts = 0   -- 成功就归零，下次遇到问题还能重试
			log("通道 B 成功：重开后本局已被引擎标记为不解锁成就")
			return
		end
		-- 没生效：换更晚的时机再试一次（有时刚开局的瞬间引擎还没把状态落定）
		if autoRestartAttempts < AUTO_RESTART_MAX_TRIES and type(Isaac.StartNewGame) == "function" then
			log(string.format("通道 B 第 %d 次重开后没生效，换更晚的时机再试一次", autoRestartAttempts))
			autoRestartAttempts = autoRestartAttempts + 1
			pendingAutoRestart = true
			pendingAutoFrames  = 30
			return
		end
		autoRestartOff = true
		notify("通道 B 重开后成就标记仍未生效，已停止自动重开。请用忏悔龙菜单里的「立即重开本局」。",
			"ACHIEVEMENTS", "OFF FAILED")
		return
	end

	if blocked then return end

	-- 1) 先试免重开通道（实测本版引擎无效后就不再白试）
	if settings.tryLiveApply and liveApplyUsable and tryLiveApply() then
		scheduleHudNotice("ACHIEVEMENTS", "DISABLED", 60)
		return
	end

	-- 2) 再排一次自动重开
	if not settings.applyOnRunStart then
		log("未自动重开：设置里关掉了「开局自动生效」")
		notify("本局成就未能关闭（未开启自动重开），将从下一局开始生效。",
			"ACHIEVEMENTS", "OFF NEXT RUN")
		return
	end
	if autoRestartOff then
		log("未自动重开：本会话内自动重开已因失败被停用")
		notify("本局成就未能关闭（自动重开已停用），将从下一局开始生效。",
			"ACHIEVEMENTS", "OFF NEXT RUN")
		return
	end
	if restartCooldown > 0 then
		log(string.format("未自动重开：重开冷却中（剩 %d 帧）", restartCooldown))
		notify("本局成就未能关闭，将从下一局开始生效。", "ACHIEVEMENTS", "OFF NEXT RUN")
		return
	end
	if continued then
		log("未自动重开：这是读档续关的局（替你保住进度）")
		notify("本局成就未能关闭（读档续关不重开），将从下一局开始生效。",
			"ACHIEVEMENTS", "OFF NEXT RUN")
		return
	end
	if numPlayers() > 1 then
		log("未自动重开：多人局")
		notify("本局成就未能关闭（多人局不重开），将从下一局开始生效。",
			"ACHIEVEMENTS", "OFF NEXT RUN")
		return
	end
	if type(Isaac.StartNewGame) ~= "function" then
		-- 没有忏悔龙就没有重开通道；这不是失败，别把自动重开判死
		log("未自动重开：没有忏悔龙的 Isaac.StartNewGame（重开通道不可用）")
		notify("本局成就未能关闭（需要忏悔龙才能重开本局），将从下一局开始生效。",
			"ACHIEVEMENTS", "OFF NEXT RUN")
		return
	end

	-- 关键：不在 MC_POST_GAME_STARTED 里直接 StartNewGame（引擎会把它连同本局的
	-- 启动流程一起吞掉，重开出来的局不是自定义局）。推迟几帧，等游戏真正开跑再动手。
	pendingAutoRestart = true
	pendingAutoFrames  = 2
	autoRestartAttempts = autoRestartAttempts + 1
	log(string.format("已排队：开局自动重开（第 %d 次，等 2 帧后执行）", autoRestartAttempts))
end

--============================================================== 回调：换层

--- 换层后的复查。注意：开局时 MC_POST_NEW_LEVEL 会**先于** MC_POST_GAME_STARTED
--- 触发，所以这里只是排个队，等几帧后由 onRender 执行 —— 那时 GAME_STARTED 已经跑过
--- 并把 framesSinceGameStart 归零，护栏才真正起作用（否则每开一局都会误报“标记丢失”）。
local function scheduleGateCheck()
	pendingGateCheck = true
	pendingGateCheckFrames = 5
end

local function runGateCheck()
	if settings.allowAchievements then return end
	if not isInRun() then return end
	if framesSinceGameStart < 120 then return end
	if achievementsBlocked() then return end

	-- 引擎可能在新的一层重置了标记：再试一次通道 A（幂等，无副作用）
	if settings.tryLiveApply and liveApplyUsable and tryLiveApply() then
		log("换层后标记丢失，通道 A 已重新生效")
		return
	end

	if not gateLostWarned then
		gateLostWarned = true
		notify("警告：本局没能保持「不解锁成就」标记，本局可能仍会正常解锁成就。" ..
			"（续关读档的局不会替你重开，以免毁进度；要确保关闭请退出后重新开一局。）",
			"ACHIEVEMENTS", "GATE LOST")
	end
end

--============================================================== 回调：渲染

local function onRender()
	if restartCooldown > 0 then restartCooldown = restartCooldown - 1 end
	if framesSinceGameStart < 100000 then framesSinceGameStart = framesSinceGameStart + 1 end

	-- 开局自动重开：推迟到开局回调之后几帧再执行（在回调里直接重开会被引擎吞掉）
	if pendingAutoRestart then
		pendingAutoFrames = pendingAutoFrames - 1
		if pendingAutoFrames <= 0 then
			pendingAutoRestart = false
			if (not settings.allowAchievements) and (not achievementsBlocked()) then
				autoRestartOn = true
				local ok, err = restartAsCustomRun()
				if ok then
					restartCooldown = 300
					scheduleHudNotice("ACHIEVEMENTS", "DISABLED", 150)
				else
					autoRestartOn = false
					autoRestartOff = true
					notify("自动重开失败：" .. tostring(err), "ACHIEVEMENTS", "OFF FAILED")
				end
			end
		end
	end

	if pendingGateCheck then
		pendingGateCheckFrames = pendingGateCheckFrames - 1
		if pendingGateCheckFrames <= 0 then
			pendingGateCheck = false
			runGateCheck()
		end
	end

	-- 兜底重试：万一菜单类 mod 比本 mod 晚加载
	if not mcmRegistered then registerModConfigMenu() end
	if not imguInited then initImGui() end
	syncKeybindFromModConfigMenu()

	if pendingNotice ~= nil then
		pendingNotice.frames = pendingNotice.frames - 1
		if pendingNotice.frames <= 0 then
			hudNotice(pendingNotice.main, pendingNotice.sub)
			pendingNotice = nil
		end
	end

	if type(settings.toggleKey) == "number" and settings.toggleKey > -1 then
		local pressed = pcallValue(function()
			return Input.IsButtonTriggered(settings.toggleKey, 0)
		end, false)
		if pressed then toggleAllowAchievements() end
	end
end

--============================================================== Mod Config Menu（L 键菜单）

local MCM_CATEGORY = "成就开关"
local MCM_SUB      = "设置"

local function yesno(v) return v and "是" or "否" end

registerModConfigMenu = function()
	if mcmRegistered then return true end
	-- 默认隐藏 L 键菜单里的入口（代码保留，可在忏悔龙菜单里重新打开）
	if not settings.showInMCM then return false end
	if ModConfigMenu == nil or type(ModConfigMenu.AddSetting) ~= "function" then return false end

	local OT = ModConfigMenu.OptionType or {}
	local TYPE_BOOLEAN  = OT.BOOLEAN or 4
	local TYPE_KEYBOARD = OT.KEYBIND_KEYBOARD or 6

	local ok, err = pcall(function()
		-- 主开关
		ModConfigMenu.AddSetting(MCM_CATEGORY, MCM_SUB, {
			Type = TYPE_BOOLEAN,
			Attribute = "allowAchievements",
			Default = DEFAULTS.allowAchievements,
			CurrentSetting = function() return settings.allowAchievements end,
			Display = function() return "允许本局解锁成就: " .. yesno(settings.allowAchievements) end,
			OnChange = function(newValue)
				settings.allowAchievements = (newValue == true)
				saveSettings()
				if refreshInterfaceStatus then refreshInterfaceStatus() end
				if settings.allowAchievements then
					notify("已允许解锁成就。（本局若已是自定义局需开新局才恢复）", "ACHIEVEMENTS", "ON NEXT RUN")
				else
					notify("已关闭成就解锁。", "ACHIEVEMENTS", "OFF")
					disableAchievementsNow(false)
				end
			end,
			Info = {
				"关闭后，本局不会解锁任何成就（含 Steam 成就与解锁类道具）。",
				"原理：使用游戏原生的「自定义局／种子局」标记，不是伪造判定。",
				"若本局已经开始，可能无法中途关闭 —— 那时会从下一局开始生效。",
			},
		})

		-- 开局自动生效
		ModConfigMenu.AddSetting(MCM_CATEGORY, MCM_SUB, {
			Type = TYPE_BOOLEAN,
			Attribute = "applyOnRunStart",
			Default = DEFAULTS.applyOnRunStart,
			CurrentSetting = function() return settings.applyOnRunStart end,
			Display = function() return "开局自动生效: " .. yesno(settings.applyOnRunStart) end,
			OnChange = function(newValue)
				settings.applyOnRunStart = (newValue == true)
				saveSettings()
			end,
			Info = {
				"开启后：只要主开关是关的，进入新的一局时会自动把本局标记为不解锁成就。",
				"必要时会以同一角色／同一种子把本局重开一次（仅在开局头几秒、单人时）。",
			},
		})

		-- 即时通道
		ModConfigMenu.AddSetting(MCM_CATEGORY, MCM_SUB, {
			Type = TYPE_BOOLEAN,
			Attribute = "tryLiveApply",
			Default = DEFAULTS.tryLiveApply,
			CurrentSetting = function() return settings.tryLiveApply end,
			Display = function() return "优先即时生效（免重开）: " .. yesno(settings.tryLiveApply) end,
			OnChange = function(newValue)
				settings.tryLiveApply = (newValue == true)
				saveSettings()
			end,
			Info = {
				"先尝试把本局起始种子写回自身，让引擎把本局当成种子局。",
				"每次都会用引擎接口读回自检，失败才走重开通道。",
			},
		})

		-- 屏幕提示
		ModConfigMenu.AddSetting(MCM_CATEGORY, MCM_SUB, {
			Type = TYPE_BOOLEAN,
			Attribute = "showNotice",
			Default = DEFAULTS.showNotice,
			CurrentSetting = function() return settings.showNotice end,
			Display = function() return "显示屏幕提示: " .. yesno(settings.showNotice) end,
			OnChange = function(newValue)
				settings.showNotice = (newValue == true)
				saveSettings()
			end,
			Info = { "在局内用提示条告诉你开关的状态变化。" },
		})

		-- 调试日志
		ModConfigMenu.AddSetting(MCM_CATEGORY, MCM_SUB, {
			Type = TYPE_BOOLEAN,
			Attribute = "debugLog",
			Default = DEFAULTS.debugLog,
			CurrentSetting = function() return settings.debugLog end,
			Display = function() return "输出详细日志: " .. yesno(settings.debugLog) end,
			OnChange = function(newValue)
				settings.debugLog = (newValue == true)
				saveSettings()
			end,
			Info = {
				"每局的开局判定结果始终会记进 log.txt（搜 [AchievementSwitch]）。",
				"开启后连通道细节、失败原因一起记，排查问题时开。",
			},
		})

		-- 局内快捷切换键
		if type(ModConfigMenu.AddKeyboardSetting) == "function" then
			ModConfigMenu.AddKeyboardSetting(
				MCM_CATEGORY, MCM_SUB,
				"toggleKey",
				DEFAULTS.toggleKey,
				"局内快捷切换键",
				nil,
				{ "局内按一下即可切换「是否解锁成就」。默认未绑定。" },
				nil
			)
			-- 具体数值交给 syncKeybindFromModConfigMenu 双向同步，
			-- 因为 MCM 不替第三方 mod 保存设置，只会给个默认值。
		end
	end)

	if not ok then
		log("注册 Mod Config Menu 失败：" .. tostring(err))
		return false
	end

	-- 状态行最后注册：即使该版本不支持函数式文本，也不影响上面的设置项
	pcall(function()
		if type(ModConfigMenu.AddText) == "function" then
			ModConfigMenu.AddText(MCM_CATEGORY, MCM_SUB, function() return currentStatusText() end)
		end
	end)

	mcmRegistered = true
	log("已注册到 Mod Config Menu（L 打开；F10 始终可打开）")
	return true
end

--- MCM 入口显隐（保守做法：只是不注册，代码全留着，随时能开回来）
local function setShowInMCM(value)
	settings.showInMCM = (value == true)
	saveSettings()

	if settings.showInMCM then
		registerModConfigMenu()
	elseif mcmRegistered then
		pcall(function()
			if type(ModConfigMenu.RemoveCategory) == "function" then
				ModConfigMenu.RemoveCategory(MCM_CATEGORY)
			end
		end)
		mcmRegistered = false
		log("已从 Mod Config Menu 移除入口（L 键菜单里不再显示）")
	end
	if refreshInterfaceStatus then refreshInterfaceStatus() end
end

--- MCM 不替第三方 mod 保存设置，所以按键值要在两边双向同步：
---   玩家在 MCM 里改了 → 抄回自己的存档
---   自己这边变了（切换存档槽／重新载入）→ 推回 MCM 显示
syncKeybindFromModConfigMenu = function()
	if not mcmRegistered then return end
	if ModConfigMenu == nil or type(ModConfigMenu.Config) ~= "table" then return end
	local cfg = ModConfigMenu.Config[MCM_CATEGORY]
	if type(cfg) ~= "table" or type(cfg.toggleKey) ~= "number" then return end

	if syncedToggleKey == nil then
		syncedToggleKey = settings.toggleKey
		cfg.toggleKey = settings.toggleKey
		return
	end

	local mcmKey = cfg.toggleKey
	if mcmKey ~= syncedToggleKey then
		syncedToggleKey = mcmKey
		settings.toggleKey = mcmKey
		saveSettings()
		if refreshInterfaceStatus then refreshInterfaceStatus() end
	elseif settings.toggleKey ~= syncedToggleKey then
		syncedToggleKey = settings.toggleKey
		cfg.toggleKey = settings.toggleKey
	end
end

--============================================================== 忏悔龙 ImGui 菜单

local IMGUI_IDS = {
	menu     = "ASwitch_Menu",
	menuItem = "ASwitch_MenuItem",
	window   = "ASwitch_Window",
	status   = "ASwitch_StatusText",
	toggle   = "ASwitch_ToggleCheckbox",
	apply    = "ASwitch_ApplyButton",
	restart  = "ASwitch_RestartButton",
	mcmToggle = "ASwitch_McmToggleCheckbox",
	notice   = "ASwitch_NoticeText",
}

initImGui = function()
	if imguInited then return true end
	if not isRepentogon() then return false end
	if ImGui == nil or ImGuiElement == nil then return false end

	local ok, err = pcall(function()
		ImGui.CreateMenu(IMGUI_IDS.menu, "\u{f0c3} 成就开关")
		ImGui.AddElement(IMGUI_IDS.menu, IMGUI_IDS.menuItem, ImGuiElement.MenuItem,
			"\u{f091} 成就开关 / Achievement Switch")
		ImGui.CreateWindow(IMGUI_IDS.window, "\u{f091} 成就开关")
		ImGui.LinkWindowToElement(IMGUI_IDS.window, IMGUI_IDS.menuItem)

		ImGui.AddText(IMGUI_IDS.window, currentStatusText(), false, IMGUI_IDS.status)

		ImGui.AddCheckbox(IMGUI_IDS.window, IMGUI_IDS.toggle, "允许本局解锁成就",
			function(value)
				settings.allowAchievements = (value == true)
				saveSettings()
				if refreshInterfaceStatus then refreshInterfaceStatus() end
				if settings.allowAchievements then
					notify("已允许解锁成就。", "ACHIEVEMENTS", "ON NEXT RUN")
				else
					notify("已关闭成就解锁。", "ACHIEVEMENTS", "OFF")
					disableAchievementsNow(false)
				end
			end,
			settings.allowAchievements)

		ImGui.AddButton(IMGUI_IDS.window, IMGUI_IDS.apply, "关闭成就（不重开，若引擎不支持会提示）",
			function() disableAchievementsNow(false) end)

		ImGui.AddButton(IMGUI_IDS.window, IMGUI_IDS.restart, "立即重开本局生效（同角色／同难度／同种子）",
			function() disableAchievementsNow(true) end)

		ImGui.AddCheckbox(IMGUI_IDS.window, IMGUI_IDS.mcmToggle, "在 Mod Config Menu（L 键）里显示入口",
			function(value) setShowInMCM(value == true) end,
			settings.showInMCM)

		ImGui.AddText(IMGUI_IDS.window,
			"关掉后本局不再解锁成就；本局一旦成为自定义局就无法恢复，需开新的一局。" ..
			"贪婪/困难模式会按当前难度重开，不会掉回普通模式。",
			true, IMGUI_IDS.notice)
	end)

	if not ok then
		log("创建 ImGui 菜单失败：" .. tostring(err))
		return false
	end

	imguInited = true
	log("已创建忏悔龙 ImGui 菜单（按 ~ 打开调试控制台后可见）")
	return true
end

--- 保持 MCM 与 ImGui 的显示一致
refreshInterfaceStatus = function()
	if not imguInited then return end
	pcall(function() ImGui.UpdateText(IMGUI_IDS.status, currentStatusText()) end)
	pcall(function()
		if type(ImGuiData) == "table" and ImGuiData.Value ~= nil then
			ImGui.UpdateData(IMGUI_IDS.toggle, ImGuiData.Value, settings.allowAchievements)
		end
	end)
end

--============================================================== 注册回调

mod:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, function(...)
	onGameStarted(readIsContinued(...))
end)

mod:AddCallback(ModCallbacks.MC_POST_NEW_LEVEL, function()
	scheduleGateCheck()
end)

mod:AddCallback(ModCallbacks.MC_POST_RENDER, function()
	onRender()
end)

--============================================================== 启动

loadSettings()
log(string.format("v%s 已加载 | 忏悔龙=%s | ModConfigMenu=%s",
	MOD_VERSION, tostring(isRepentogon()), tostring(ModConfigMenu ~= nil)))
if not isRepentogon() then
	log("警告：未检测到忏悔龙(REPENTOGON)。「重开为自定义局」通道不可用，" ..
		"只剩写回起始种子的即时通道；装忏悔龙才能获得完整功能。")
end

-- 加载时就注册菜单：这样在主菜单里按 L 也能看到「成就开关」分类。
-- 本机实测 Mod Config Menu 比本 mod 先加载；万一顺序反了，回调里的重试还会补上。
registerModConfigMenu()
initImGui()
