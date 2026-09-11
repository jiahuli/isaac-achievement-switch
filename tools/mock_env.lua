-- 离线测试用的假环境：在真实 Lua 解释器里模拟以撒+忏悔龙的 API，
-- 这样不需要启动游戏就能验证 main.lua 的语法与判定逻辑。

MOCK = {
	-- 运行状态
	inRun           = true,
	frame           = 0,
	continued       = false,
	players         = 1,
	challenge       = 0,
	difficulty      = 0,

	-- 引擎行为开关（用来模拟各种版本差异）
	hasRepentogon   = true,   -- 是否有 Game:AchievementUnlocksDisallowed()
	hasStartNewGame = true,   -- 是否有 Isaac.StartNewGame
	blocked         = false,  -- 引擎当前是否禁止解锁成就
	validSeedString = true,   -- Seeds.IsStringValidSeed 的结果
	setStartSeedWorks = true, -- 通道 A 是否真的能关掉成就
	restartWorks    = true,   -- 通道 B（StartNewGame）是否真的能关掉成就

	-- 种子
	startSeed       = 123456789,
	seedString      = "B911 99JA",

	-- 记录
	calls           = {},
	hudTexts        = {},
	startNewGameCount = 0,
}

function MOCK:record(name, ...)
	self.calls[#self.calls + 1] = { name = name, n = select("#", ...), ... }
end

function MOCK:countCalls(name)
	local n = 0
	for _, c in ipairs(self.calls) do
		if c.name == name then n = n + 1 end
	end
	return n
end

function MOCK:lastCall(name)
	for i = #self.calls, 1, -1 do
		if self.calls[i].name == name then return self.calls[i] end
	end
	return nil
end

function MOCK:reset()
	self.calls = {}
	self.hudTexts = {}
	self.startNewGameCount = 0
end

--============================================================== 假引擎对象
-- 注意：假引擎刻意 **不提供** Game:GetDifficulty() / Game:GetChallenge() 方法，
-- 只提供 Game().Difficulty / Game().Challenge 这两个属性 —— 这正是真机的样子，
-- 之前用的 GetDifficulty() 在本版 Lua 里根本不存在，导致难度永远取到 0。

MOCK.difficulty = 0   -- 0普通 1困难 2贪婪 3困难贪婪
MOCK.challenge  = 0

local fakeSeeds = {}
function fakeSeeds:GetStartSeedString() return MOCK.seedString end
function fakeSeeds:GetStartSeed() return MOCK.startSeed end
function fakeSeeds:IsCustomRun() return MOCK.blocked end
function fakeSeeds:SetStartSeed(str)
	MOCK:record("SetStartSeed", str)
	if MOCK.setStartSeedWorks then MOCK.blocked = true end
end

Seeds = {}
function Seeds.IsStringValidSeed(str) return MOCK.validSeedString end

local fakeHUD = {}
function fakeHUD:ShowItemText(main, sub) MOCK.hudTexts[#MOCK.hudTexts + 1] = tostring(main) .. "|" .. tostring(sub) end

local fakePlayer = {}
function fakePlayer:GetPlayerType() return 3 end

local fakeGame = {}
function fakeGame:GetSeeds() return MOCK.inRun and fakeSeeds or nil end
function fakeGame:GetFrameCount() return MOCK.frame end
function fakeGame:GetNumPlayers() return MOCK.players end
function fakeGame:GetRoom() return MOCK.inRun and {} or nil end
function fakeGame:IsContinued() return MOCK.continued end
function fakeGame:GetPlayer(i) return fakePlayer end
function fakeGame:GetHUD() return fakeHUD end
function fakeGame:AchievementUnlocksDisallowed()
	MOCK:record("AchievementUnlocksDisallowed")
	return MOCK.blocked
end
-- 贪婪/困难判定也不给（真机上这些是 忏悔龙 才有的），只留属性
setmetatable(fakeGame, {
	__index = function(_, key)
		if key == "Difficulty" then return MOCK.difficulty end
		if key == "Challenge" then return MOCK.challenge end
		return nil
	end,
})

local fakeGameNoGetter = {}
for k, v in pairs(fakeGame) do fakeGameNoGetter[k] = v end
fakeGameNoGetter.AchievementUnlocksDisallowed = nil
setmetatable(fakeGameNoGetter, getmetatable(fakeGame))

function Game() return MOCK.hasRepentogon and fakeGame or fakeGameNoGetter end

local function implStartNewGame(character, challenge, difficulty, seed, isCustomRun)
	MOCK:record("StartNewGame", character, challenge, difficulty, seed, isCustomRun)
	MOCK.startNewGameCount = MOCK.startNewGameCount + 1
	if MOCK.restartWorks and isCustomRun then MOCK.blocked = true end
	MOCK.frame = 0
	MOCK.continued = false
end

-- 没有忏悔龙时 Isaac.StartNewGame 就应该不存在，用元表模拟这一点
Isaac = setmetatable({}, {
	__index = function(_, key)
		if key == "StartNewGame" then
			return MOCK.hasStartNewGame and implStartNewGame or nil
		end
		if key == "DebugString" then
			return function(s) MOCK:record("DebugString", s) end
		end
		return nil
	end,
})

-- 以撒的 Lua 沙箱里没有 io / os（实测 main.lua 用了 io 会直接 "attempt to index
-- a nil value (global 'io')" 并把整个 mod 的加载中断）。这里照样抹掉，
-- 让离线测试就能抓到这类沙箱问题。
io = nil
os = nil

REPENTOGON = { Real = true, Name = "REPENTOGON", Version = "1.1.2g" }

--============================================================== 假回调常量

ModCallbacks = {
	MC_POST_RENDER       = 2,
	MC_POST_GAME_STARTED = 15,
	MC_POST_NEW_LEVEL    = 30,
}

local GAME = nil

function RegisterMod(name, api)
	GAME = { name = name, api = api, callbacks = {}, data = PENDING_DATA }
	function GAME:AddCallback(id, fn) self.callbacks[id] = fn end
	function GAME:SaveData(s) self.data = s end
	function GAME:LoadData() return self.data end
	function GAME:HasData() return self.data ~= nil end
	return GAME
end

function MOD() return GAME end

--- 触发某个回调
function FIRE(id, ...)
	assert(GAME, "mod 尚未注册")
	assert(GAME.callbacks[id], "回调未注册: " .. tostring(id))
	return GAME.callbacks[id](...)
end

function RENDER(n)
	for _ = 1, (n or 1) do FIRE(ModCallbacks.MC_POST_RENDER) end
end

--============================================================== 假 Mod Config Menu

MCM = {
	registered = {},   -- {category, subcategory, settingTable}
	texts = {},
	keyboard = {},
	removedCategory = nil,
}

ModConfigMenu = {}
ModConfigMenu.OptionType = {
	TEXT = 1, SPACE = 2, SCROLL = 3, BOOLEAN = 4, NUMBER = 5,
	KEYBIND_KEYBOARD = 6, KEYBIND_CONTROLLER = 7, TITLE = 8,
}
ModConfigMenu.Config = {}

function ModConfigMenu.AddSetting(category, sub, settingTable)
	MCM.registered[#MCM.registered + 1] = { category = category, sub = sub, setting = settingTable }
	if type(settingTable.Attribute) == "string" then
		ModConfigMenu.Config[category] = ModConfigMenu.Config[category] or {}
		if ModConfigMenu.Config[category][settingTable.Attribute] == nil then
			ModConfigMenu.Config[category][settingTable.Attribute] = settingTable.Default
		end
	end
	return settingTable
end

function ModConfigMenu.AddKeyboardSetting(category, sub, attr, default, displayText)
	local settingTable = { Type = 6, Attribute = attr, Default = default, Display = displayText }
	return ModConfigMenu.AddSetting(category, sub, settingTable)
end

function ModConfigMenu.AddText(category, sub, text)
	MCM.texts[#MCM.texts + 1] = { category = category, sub = sub, text = text }
end

function ModConfigMenu.RemoveCategory(category)
	MCM.removedCategory = category
	MCM.registered = {}
	ModConfigMenu.Config[category] = nil
end

--- 模拟玩家在 MCM 里改动某个布尔项
function MCM_INTERACT(category, attr)
	for _, entry in ipairs(MCM.registered) do
		if entry.category == category and entry.setting.Attribute == attr then
			local cur = entry.setting.CurrentSetting
			local value = (type(cur) == "function") and cur() or cur
			local newValue = not value
			if entry.setting.OnChange then entry.setting.OnChange(newValue) end
			return newValue
		end
	end
	return nil
end

function MCM_FIND(category, attr)
	for _, entry in ipairs(MCM.registered) do
		if entry.category == category and entry.setting.Attribute == attr then return entry.setting end
	end
	return nil
end

--============================================================== 假 ImGui

ImGuiElement = { Menu = 1, MenuItem = 2, Text = 3 }
ImGuiData = { Value = 1, Label = 2 }
ImGuiNotificationType = { INFO = 0, SUCCESS = 1, WARNING = 2, ERROR = 3 }

ImGuiEvents = {}
ImGuiCallbacks = {}   -- id -> 回调，测试里可以模拟点击
ImGui = {}
local function imguiRecord(name, ...) ImGuiEvents[#ImGuiEvents + 1] = { name = name, ... } end
function ImGui.CreateMenu(id, label) imguiRecord("CreateMenu", id, label) end
function ImGui.CreateWindow(id, title) imguiRecord("CreateWindow", id, title) end
function ImGui.AddElement(p, id, t, label) imguiRecord("AddElement", p, id, t, label) end
function ImGui.LinkWindowToElement(w, e) imguiRecord("LinkWindowToElement", w, e) end
function ImGui.AddText(p, text, wrap, id) imguiRecord("AddText", p, text, wrap, id) end
function ImGui.UpdateText(id, text) imguiRecord("UpdateText", id, text) end
function ImGui.UpdateData(id, kind, value) imguiRecord("UpdateData", id, kind, value) end
function ImGui.PushNotification(text, t, life) imguiRecord("PushNotification", text, t, life) end
function ImGui.AddCheckbox(p, id, label, cb, active)
	ImGuiCallbacks[id] = cb
	imguiRecord("AddCheckbox", p, id, label, active)
end
function ImGui.AddButton(p, id, label, cb)
	ImGuiCallbacks[id] = cb
	imguiRecord("AddButton", p, id, label)
end

--- 模拟玩家在忏悔龙 ImGui 菜单里点某个控件
function IMGUI_ACT(id, value)
	local cb = ImGuiCallbacks[id]
	if cb == nil then return false end
	cb(value)
	return true
end

--============================================================== 假 Input

Input = {}
Input.triggered = {}
function Input.IsButtonTriggered(key, idx) return Input.triggered[key] == true end

--============================================================== 断言工具

PASSED, FAILED = 0, 0
function CHECK(cond, msg)
	if cond then
		PASSED = PASSED + 1
		print("  [PASS] " .. msg)
	else
		FAILED = FAILED + 1
		print("  [FAIL] " .. msg)
	end
end

function SETTINGS(overrides)
	local lines = { "achievement-switch/1" }
	local base = {
		allowAchievements = true,
		applyOnRunStart = true,
		tryLiveApply = true,
		showNotice = true,
		toggleKey = -1,
		debugLog = true,
	}
	for k, v in pairs(overrides or {}) do base[k] = v end
	for k, v in pairs(base) do lines[#lines + 1] = k .. "=" .. tostring(v) end
	local data = table.concat(lines, "\n")
	if MOD() then MOD().data = data else PENDING_DATA = data end
end

function SUMMARY()
	print(string.format("\n=== %d passed, %d failed ===", PASSED, FAILED))
	if FAILED > 0 then error("测试失败: " .. FAILED .. " 项", 0) end
end
