if not game:IsLoaded() then game.Loaded:Wait() end

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local plr = Players.LocalPlayer

local DESCRIPTION_RETRY_COUNT = 2
local DESCRIPTION_RETRY_DELAY = 0.75
local DESCRIPTION_SETTLE_DELAY = 4
local DESCRIPTION_COOLDOWN_WAIT = 2
local DESCRIPTION_COOLDOWN_TIMEOUT = 15
local REGULAR_DESCRIPTION_RESEND_INTERVAL = 20
local STATS_MENU_KEY = Enum.KeyCode.M
local STATS_MENU_RETRY_DELAY = 1
local STATS_MENU_OPEN_COOLDOWN = 3
local STATS_MENU_REFRESH_DELAY = 0.2
local MOOLA_READY_TIMEOUT = 6
local MOOLA_RETRY_DELAY = 0.5
local HORST_READY_TIMEOUT = 20

local lastDescriptionMessage
local lastDescriptionSentAt = 0
local lastStatsMenuOpenAt = 0

local function sanitizeDescriptionText(text)
    return tostring(text)
        :gsub("|", "")
        :gsub(";", "")
        :gsub("%s+,", ",")
        :gsub(",%s+", ", ")
        :gsub("%s+", " ")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
end

local function cleanUiText(text)
    return tostring(text or "")
        :gsub("|", "")
        :gsub(";", "")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
end

local function waitForHorstDescription()
    local deadline = tick() + HORST_READY_TIMEOUT
    while tick() < deadline do
        if _G.Horst_SetDescription then
            return true
        end
        task.wait(0.5)
    end

    return false
end

local function toggleStatsMenu()
    return pcall(function()
        VirtualInputManager:SendKeyEvent(true, STATS_MENU_KEY, false, game)
        task.wait(0.05)
        VirtualInputManager:SendKeyEvent(false, STATS_MENU_KEY, false, game)
    end)
end

local function isStatsMenuOpen()
    local gui = plr.PlayerGui:FindFirstChild("StatsGui")
    if not gui then
        return false
    end

    if gui:IsA("ScreenGui") then
        return gui.Enabled ~= false
    end

    local background = gui:FindFirstChild("Background")
    if background and background:IsA("GuiObject") then
        return background.Visible ~= false
    end

    return true
end

local function setStatsMenuOpen(shouldOpen)
    if isStatsMenuOpen() == shouldOpen then
        return true
    end

    return toggleStatsMenu()
end

local function refreshStatsMenu()
    if tick() - lastStatsMenuOpenAt < STATS_MENU_OPEN_COOLDOWN then
        return true
    end

    if isStatsMenuOpen() then
        if not setStatsMenuOpen(false) then
            return false
        end
        task.wait(STATS_MENU_REFRESH_DELAY)
    end

    if not setStatsMenuOpen(true) then
        return false
    end

    task.wait(STATS_MENU_RETRY_DELAY)

    if not setStatsMenuOpen(false) then
        return false
    end

    task.wait(STATS_MENU_REFRESH_DELAY)
    lastStatsMenuOpenAt = tick()
    return true
end

-- 1. รายชื่อ Stand ที่ต้องการ (ถ้าได้แล้วให้เปลี่ยนไอดี)
local TARGET_STANDS = {
    ["D4C"] = true,
    ["Tusk"] = true,
    ["GTUSK"] = true,
    ["Tusk2"] = true,
    ["Tusk3"] = true,
    ["Tusk4"] = true,
    ["TWAU"] = true,
    ["StarPlatinumTheWorld"] = true,
    ["TheWorld"] = true
}

-- 2. ฟังก์ชันดึง object ใน StatsGui.Background (รองรับ Autoexec)
local function getStatsBackground()
    local gui = plr.PlayerGui:WaitForChild("StatsGui", 30)
    if gui then
        return gui:WaitForChild("Background", 10)
    end
    return nil
end

local function getPathTextObj()
    local bg = getStatsBackground()
    if bg then
        return bg:WaitForChild("PathText", 10)
    end
    return nil
end

local function getTierTextObj()
    local bg = getStatsBackground()
    if bg then
        return bg:WaitForChild("TierText", 10)
    end
    return nil
end

local function getCoinAmountObj()
    local coinGui = plr.PlayerGui:WaitForChild("MoolaCount", 30)
    if coinGui then
        local frame = coinGui:WaitForChild("Frame", 10)
        if frame then
            return frame:WaitForChild("CoinAmount", 10)
        end
    end
    return nil
end

local function getCurrentTier()
    local tierTextObj = getTierTextObj()
    if not tierTextObj or not tierTextObj.Text then
        return "Unknown Tier"
    end

    local currentTier = cleanUiText(tierTextObj.Text:gsub("Tier:%s*", ""))
    if currentTier == "" or currentTier == "???" or currentTier:lower() == "nil" then
        return "Unknown Tier"
    end

    return currentTier
end

local function getCurrentMoola()
    local coinAmountObj = getCoinAmountObj()
    if not coinAmountObj or not coinAmountObj.Text then
        return "Unknown"
    end

    local currentMoola = cleanUiText(coinAmountObj.Text)
    if currentMoola == "" or currentMoola == "???" or currentMoola:lower() == "nil" or not currentMoola:find("%d") then
        return "Unknown"
    end

    return currentMoola
end

local function waitForCurrentMoola()
    local currentMoola = getCurrentMoola()
    if currentMoola ~= "Unknown" then
        return currentMoola, true
    end

    local deadline = tick() + MOOLA_READY_TIMEOUT
    while tick() < deadline do
        task.wait(MOOLA_RETRY_DELAY)
        currentMoola = getCurrentMoola()
        if currentMoola ~= "Unknown" then
            return currentMoola, true
        end
    end

    return "Unknown", false
end

local function getCurrentStand()
    local pathTextObj = getPathTextObj()
    if not pathTextObj or not pathTextObj.Text then
        return nil, false
    end

    local currentStand = cleanUiText(pathTextObj.Text:gsub("Path:%s*", ""))
    if currentStand == "???" then
        return "No Stand", true
    end

    if currentStand == "" or currentStand:lower() == "nil" then
        return "No Stand", false
    end

    return currentStand, true
end

local function ensureStatsDataReady()
    refreshStatsMenu()

    local currentStand, standReady = getCurrentStand()
    local currentTier = getCurrentTier()

    return currentStand, currentTier, standReady and currentTier ~= "Unknown Tier"
end

local function getRokakakaCounts()
    local backpack = plr:FindFirstChild("Backpack")
    local seedCount = 0
    local fruitCount = 0

    if not backpack then
        return seedCount, fruitCount
    end

    for _, item in ipairs(backpack:GetChildren()) do
        if item.Name == "Rokakaka Seed" then
            seedCount = seedCount + 1
        elseif item.Name == "Rokakaka" then
            fruitCount = fruitCount + 1
        end
    end

    return seedCount, fruitCount
end

local function pushDescription(message, payload)
    if not _G.Horst_SetDescription then
        return false, "Horst_SetDescription missing"
    end

    message = sanitizeDescriptionText(message)

    local lastErr
    for attempt = 1, DESCRIPTION_RETRY_COUNT do
        local ok, resultA, resultB = pcall(_G.Horst_SetDescription, message, payload)
        if ok then
            if resultA == true then
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

    return lastErr == nil, lastErr
end

local function pushDescriptionUntilSent(message, payload, timeoutSeconds)
    local deadline = tick() + (timeoutSeconds or DESCRIPTION_COOLDOWN_TIMEOUT)
    local lastErr

    repeat
        local sent, err = pushDescription(message, payload)
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

local function shouldSendRegularDescription(message)
    if message ~= lastDescriptionMessage then
        return true
    end

    return tick() - lastDescriptionSentAt >= REGULAR_DESCRIPTION_RESEND_INTERVAL
end

-- 3. ฟังก์ชันจบงาน (เปลี่ยนสถานะเป็น DONE สีชมพู)
local function handleDone(standName, tierName, moolaAmount, seedCount, fruitCount)
    local sheetData = { 
        Moola = moolaAmount,
        Stand = standName, 
        Tier = tierName,
        RokakakaSeed = seedCount,
        RokakakaFruits = fruitCount,
        Status = "COMPLETED",
        Time = os.date("%X")
    }
    local encodeJson = HttpService:JSONEncode(sheetData)
    local message = "💰 Moola: " .. moolaAmount .. ", 🎭 Stand: " .. standName .. ", ⭐ Tier: " .. tierName .. ", 🌱 Rokakaka Seed: " .. seedCount .. ", 🍎 Rokakaka Fruits: " .. fruitCount
    
    -- ส่งข้อมูลเข้า Manager
    local logSent, logErr = pushDescriptionUntilSent(message, encodeJson)
    if not logSent and logErr then
        warn("Failed to send description before DONE:", logErr)
    else
        lastDescriptionMessage = message
        lastDescriptionSentAt = tick()
    end
    
    task.wait(DESCRIPTION_SETTLE_DELAY)
    
    -- สั่งเปลี่ยนสถานะหลักเป็น DONE สีชมพู
    if _G.Horst_AccountChangeDone then
        local ok, err = _G.Horst_AccountChangeDone()
        if not ok then print("Failed to send DONE:", err) end
    end
    
    -- ป้องกันระบบค้าง บังคับเปลี่ยนไอดี
    task.wait(2)
    plr:Kick("\n\n[SUCCESS]\nFound: " .. standName .. "\nSwitching Account...")
end

-- 4. ลูปหลัก
print("🚀 Multi-Stand Watcher Active...")
waitForHorstDescription()

spawn(function()
    while true do
        local success, result = pcall(function()
            local currentStand, currentTier, statsReady = ensureStatsDataReady()
            if currentStand then
                local currentMoola, moolaReady = waitForCurrentMoola()
                local currentSeedCount, currentFruitCount = getRokakakaCounts()
                local canReportFullState = statsReady and moolaReady

                -- ตรวจสอบว่าชื่อปัจจุบัน อยู่ในลิสต์ที่ต้องการหรือไม่
                if TARGET_STANDS[currentStand] and canReportFullState then
                    handleDone(currentStand, currentTier, currentMoola, currentSeedCount, currentFruitCount)
                    return true -- หยุดลูป
                end

                -- ถ้ายังไม่ใช่ตัวที่ต้องการ ให้อัปเดต Log ปกติ
                local currentMessage = "💰 Moola: " .. currentMoola .. ", 🎭 Stand: " .. currentStand .. ", ⭐ Tier: " .. currentTier .. ", 🌱 Rokakaka Seed: " .. currentSeedCount .. ", 🍎 Rokakaka Fruits: " .. currentFruitCount
                if canReportFullState and shouldSendRegularDescription(currentMessage) then
                    local logSent, logErr = pushDescriptionUntilSent(currentMessage, nil, 8)
                    if logSent then
                        lastDescriptionMessage = currentMessage
                        lastDescriptionSentAt = tick()
                    elseif logErr and logErr ~= "Cooldown active" then
                        warn("Failed to send regular description:", logErr)
                    end
                end
            end
            return false
        end)

        if success and result then break end
        task.wait(5) -- เช็คทุก 5 วินาที
    end
end)