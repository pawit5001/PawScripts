if not game:IsLoaded() then
	game.Loaded:Wait()
end

local Players = game:GetService("Players")
local player = Players.LocalPlayer

local DESCRIPTION_RETRY_COUNT = 2
local DESCRIPTION_RETRY_DELAY = 0.75
local DESCRIPTION_COOLDOWN_WAIT = 2
local DESCRIPTION_COOLDOWN_TIMEOUT = 15
local HORST_READY_TIMEOUT = 20
local LOG_INTERVAL = 15

local GOLD_PATH = "Interface.Topbar.Main.Currencies.Gold.Amount"
local GEMS_PATH = "Interface.Topbar.Main.Currencies.Gems.Amount"
local FAMILY_PROMPT_PATHS = {
	"Interface.Warning.Prompt.Main.Title",
	"Interface.Notification.Prompt.Main.Title",
}
local LEVEL_ATTRIBUTE = "Level"
local PRESTIGE_ATTRIBUTE = "Prestige"
local SLOT_ATTRIBUTE = "Slot"

_G.PawSHOP_AOTR_RunId = (_G.PawSHOP_AOTR_RunId or 0) + 1
local RUN_ID = _G.PawSHOP_AOTR_RunId

local lastDescriptionMessage = nil
local lastDescriptionSentAt = 0
local lastValidFamily = nil

local function isCurrentRun()
	return _G.PawSHOP_AOTR_RunId == RUN_ID
end

local function abortIfStale()
	return not isCurrentRun()
end

local function waitForPath(path, timeoutSeconds)
	local timeoutAt = tick() + (timeoutSeconds or 30)
	local current = player:WaitForChild("PlayerGui", 30)
	for child in string.gmatch(path, "[^%.]+") do
		if abortIfStale() then
			return nil
		end
		local remaining = math.max(timeoutAt - tick(), 0.1)
		current = current and current:WaitForChild(child, remaining)
		if not current then
			return nil
		end
	end
	return current
end

local function findPath(path)
	local current = player:FindFirstChild("PlayerGui")
	if not current then
		return nil
	end

	for child in string.gmatch(path, "[^%.]+") do
		current = current and current:FindFirstChild(child)
		if not current then
			return nil
		end
	end

	return current
end

local function sanitizeDescriptionText(text)
	return tostring(text or "null")
		:gsub("|", "")
		:gsub(";", "")
		:gsub("%s+,", ",")
		:gsub(",%s+", ", ")
		:gsub("%s+", " ")
		:gsub("^%s+", "")
		:gsub("%s+$", "")
end

local function safeText(obj)
	if obj and typeof(obj.Text) == "string" and obj.Text ~= "" then
		return obj.Text
	end
	return "null"
end

local function safeAttribute(instance, attributeName)
	local ok, value = pcall(function()
		return instance:GetAttribute(attributeName)
	end)
	if ok and value ~= nil then
		return tostring(value)
	end
	return "null"
end

local function normalizeCompactNumber(text)
	local rawText = tostring(text or "")
	local compactText = rawText:gsub(",", ""):gsub("%s+", "")
	local numberPart, suffix = compactText:match("^(%d+%.?%d*)([kKmMbBtT]?)$")
	local numericValue = tonumber(numberPart)
	if not numericValue then
		return rawText ~= "" and rawText or "null"
	end

	local multiplierMap = {
		[""] = 1,
		K = 1e3,
		M = 1e6,
		B = 1e9,
		T = 1e12,
	}

	local normalizedSuffix = string.upper(suffix or "")
	local baseValue = numericValue * (multiplierMap[normalizedSuffix] or 1)
	local scaledValue = baseValue
	local finalSuffix = ""

	if baseValue >= 1e12 then
		scaledValue = baseValue / 1e12
		finalSuffix = "T"
	elseif baseValue >= 1e9 then
		scaledValue = baseValue / 1e9
		finalSuffix = "B"
	elseif baseValue >= 1e6 then
		scaledValue = baseValue / 1e6
		finalSuffix = "M"
	elseif baseValue >= 1e3 then
		scaledValue = baseValue / 1e3
		finalSuffix = "K"
	end

	if finalSuffix == "" then
		return tostring(math.floor(baseValue + 0.5))
	end

	if math.abs(scaledValue - math.floor(scaledValue)) < 0.0001 then
		return string.format("%d%s", math.floor(scaledValue), finalSuffix)
	end

	return string.format("%.2f%s", scaledValue, finalSuffix)
end

local function parseFamilyFromText(text)
	local familyText = tostring(text or "")
	local rerollFamily = familyText:match("your%s+([%a_%-]+)%s+family%?")
	if rerollFamily and rerollFamily ~= "" then
		return rerollFamily
	end

	local trailingWord = familyText:match("([%a_%-]+)%s*$")
	if not trailingWord or trailingWord == "" then
		return nil
	end

	local loweredWord = string.lower(trailingWord)
	if loweredWord == string.lower(player.Name) then
		return nil
	end
	if player.DisplayName and loweredWord == string.lower(player.DisplayName) then
		return nil
	end

	return trailingWord
end

local function readFamilyFromCharacter()
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	local overhead = head and head:FindFirstChild("Overhead")
	local usernameLabel = overhead and overhead:FindFirstChild("Username")
	local familyName = parseFamilyFromText(safeText(usernameLabel))
	if familyName and familyName ~= "" then
		return familyName
	end
	return nil
end

local function readFamily()
	local characterFamily = readFamilyFromCharacter()
	if characterFamily then
		lastValidFamily = characterFamily
		return characterFamily
	end

	for _, path in ipairs(FAMILY_PROMPT_PATHS) do
		local familyName = parseFamilyFromText(safeText(findPath(path)))
		if familyName and familyName ~= "" then
			lastValidFamily = familyName
			return familyName
		end
	end

	return lastValidFamily or "null"
end
local function waitForHorstDescription()
	local deadline = tick() + HORST_READY_TIMEOUT
	while tick() < deadline do
		if abortIfStale() then
			return false
		end
		if _G.Horst_SetDescription then
			return true
		end
		task.wait(0.5)
	end

	return false
end

local function pushDescription(message)
	if abortIfStale() then
		return false, "Stale run"
	end

	if not _G.Horst_SetDescription then
		return false, "Horst_SetDescription missing"
	end

	local sanitizedMessage = sanitizeDescriptionText(message)
	local lastErr

	for attempt = 1, DESCRIPTION_RETRY_COUNT do
		local ok, resultA, resultB = pcall(_G.Horst_SetDescription, sanitizedMessage)
		if ok then
			if resultA == nil or resultA == true then
				return true, resultB
			end

			lastErr = resultB or resultA or "Unknown response"
			if attempt < DESCRIPTION_RETRY_COUNT then
				task.wait(DESCRIPTION_RETRY_DELAY)
			end
		else
			lastErr = resultA
			break
		end
	end

	return false, lastErr
end

local function pushDescriptionUntilSent(message, timeoutSeconds)
	local deadline = tick() + (timeoutSeconds or DESCRIPTION_COOLDOWN_TIMEOUT)
	local lastErr

	repeat
		if abortIfStale() then
			return false, "Stale run"
		end
		local sent, err = pushDescription(message)
		if sent then
			return true, err
		end

		lastErr = err
		if err ~= "Cooldown active" then
			return false, err
		end

		task.wait(DESCRIPTION_COOLDOWN_WAIT)
	until tick() >= deadline

	return false, lastErr or "Description send timeout"
end

local function collectAotrState()
	if abortIfStale() then
		return {
			gold = "null",
			gems = "null",
			rawGold = "null",
			rawGems = "null",
			family = "null",
			slot = "null",
			level = "null",
			prestige = "null",
		}
	end

	local goldObj = waitForPath(GOLD_PATH)
	local gemsObj = waitForPath(GEMS_PATH)

	local gold = safeText(goldObj)
	local gems = safeText(gemsObj)
	local family = readFamily()
	local slot = safeAttribute(player, SLOT_ATTRIBUTE)
	local level = safeAttribute(player, LEVEL_ATTRIBUTE)
	local prestige = safeAttribute(player, PRESTIGE_ATTRIBUTE)
	local mappedGold = normalizeCompactNumber(gold)
	local mappedGems = normalizeCompactNumber(gems)

	return {
		gold = mappedGold,
		gems = mappedGems,
		rawGold = gold,
		rawGems = gems,
		family = family,
		slot = slot,
		level = level,
		prestige = prestige,
	}
end

local function buildDescription(state)
	return string.format(
		"LV. %s, 🏆: P%s, Family: %s, Slot: %s, 💰: %s, 💎: %s",
		state.level,
		state.prestige,
		state.family,
		state.slot,
		state.gold,
		state.gems
	)
end

local function debugLog(state, message, sendOk, sendErr)
	warn("===== AOTR Description Debug =====")
	warn("Run ID:", RUN_ID, "Current Run:", isCurrentRun())
	warn("Level:", state.level)
	warn("Prestige:", state.prestige)
	warn("Family:", state.family)
	warn("Slot:", state.slot)
	warn("Gold Raw:", state.rawGold)
	warn("Gold:", state.gold)
	warn("Gems Raw:", state.rawGems)
	warn("Gems:", state.gems)
	warn("Message:", message)
	warn("Send OK:", sendOk)
	warn("Send Result:", sendErr or "nil")
	warn("==================================")
end

local function sendAotrDescription(forceSend)
	if abortIfStale() then
		return false, "Stale run"
	end

	local state = collectAotrState()
	local message = buildDescription(state)

	if not forceSend and message == lastDescriptionMessage and tick() - lastDescriptionSentAt < LOG_INTERVAL then
		debugLog(state, message, true, "Skipped duplicate inside interval")
		return true
	end

	local sent, err = pushDescriptionUntilSent(message, DESCRIPTION_COOLDOWN_TIMEOUT)
	if sent then
		lastDescriptionMessage = message
		lastDescriptionSentAt = tick()
	end

	debugLog(state, message, sent, err)
	return sent, err
end

print("PawSHOP loading...", "AOTR run", RUN_ID)

if not waitForHorstDescription() then
	warn("AOTR log: Horst_SetDescription was not ready in time")
end

task.spawn(function()
	player:WaitForChild("PlayerGui", 30)
	if isCurrentRun() then
		sendAotrDescription(true)
	end
end)

task.spawn(function()
	while isCurrentRun() do
		task.wait(LOG_INTERVAL)
		if isCurrentRun() then
			sendAotrDescription(true)
		end
	end
end)
