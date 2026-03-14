local encoding = require "encoding"
encoding.default = 'CP1251'
u8 = encoding.UTF8

local active = false
local lastSpamTime = 0
local needToggle = false
local spamThread = nil
local commandCount = 0
local startTime = 0
local attemptsCount = 0
local waitingForKey = false
local settingPosition = false
local antifloodPause = false
local freeMode = false
local sampev = require 'lib.samp.events'
local vkeys = require 'vkeys'
local imgui = require 'mimgui'
local effil = require 'effil'

-- ===================== SOUND & FONT =====================
local SOUND_DIR = getWorkingDirectory() .. "\\report_sounds\\"
local FONT_PATH = SOUND_DIR .. "MaybugMSRegular.ttf"
local FONT_URL  = "https://github.com/SaportBati/report1/raw/refs/heads/main/MaybugMSRegular.ttf"

local sounds = {
    caught  = SOUND_DIR .. "caught.mp3",
    enable  = SOUND_DIR .. "enable.mp3",
    disable = SOUND_DIR .. "disable.mp3",
}

local function ensureSoundDir()
    if not doesDirectoryExist(SOUND_DIR) then
        createDirectory(SOUND_DIR)
    end
end

local soundsReady = false

local function initSounds()
    ensureSoundDir()
    local base = "https://raw.githubusercontent.com/SaportBati/report1/main/"
    local files = {
        { url = base .. "caught.mp3",  path = sounds.caught  },
        { url = base .. "enable.mp3",  path = sounds.enable  },
        { url = base .. "disable.mp3", path = sounds.disable },
    }

    local dlstatus = require('moonloader').download_status
    local remaining = #files

    local function onDownload(id, status, p1, p2)
        if status == dlstatus.STATUS_ENDDOWNLOADDATA then
            remaining = remaining - 1
            if remaining == 0 then
                soundsReady = true
            end
        end
    end

    for _, f in ipairs(files) do
        if doesFileExist(f.path) then
            remaining = remaining - 1
        else
            downloadUrlToFile(f.url, f.path, onDownload)
        end
    end

    if remaining == 0 then
        soundsReady = true
    end
end

local function playSound(path)
    if not soundsReady then return end
    if not doesFileExist(path) then return end
    local stream = loadAudioStream(path)
    if stream then
        setAudioStreamVolume(stream, 0.3)
        setAudioStreamState(stream, 1)
    end
end
-- =========================================================

-- ===================== PING =====================
local currentPing = 0
local pingFlip = {}  -- flip-анимация для цифр пинга
local pingStr  = "0"

local function initPingFlip(str)
    pingFlip = {}
    for i = 1, #str do
        pingFlip[i] = { cur = str:sub(i,i), prev = str:sub(i,i), t = 1.0 }
    end
    pingStr = str
end

local function updatePingFlip(newStr)
    if #pingFlip ~= #newStr then
        initPingFlip(newStr)
        return
    end
    for i = 1, #newStr do
        local ch = newStr:sub(i,i)
        if ch ~= pingFlip[i].cur then
            pingFlip[i].prev = pingFlip[i].cur
            pingFlip[i].cur  = ch
            pingFlip[i].t    = 0.0
        end
    end
    pingStr = newStr
end

local function updatePing()
    local ok, myId = pcall(function() return select(2, sampGetPlayerIdByCharHandle(playerPed)) end)
    if ok and myId then
        local p = sampGetPlayerPing(myId)
        if p and p >= 0 then
            currentPing = p
            updatePingFlip(tostring(p))
        end
    end
end
-- ================================================

-- ===================== FLIP ANIMATION FOR TIMER =====================
-- Для каждого символа таймера храним: текущий символ, предыдущий, прогресс анимации
local timerFlip = {}
local timerStr  = "00:00"

local function initTimerFlip(str)
    timerFlip = {}
    for i = 1, #str do
        timerFlip[i] = { cur = str:sub(i,i), prev = str:sub(i,i), t = 1.0 }
    end
end

local function updateTimerFlip(newStr)
    if #timerFlip ~= #newStr then
        initTimerFlip(newStr)
        timerStr = newStr
        return
    end
    for i = 1, #newStr do
        local ch = newStr:sub(i,i)
        if ch ~= timerFlip[i].cur then
            timerFlip[i].prev = timerFlip[i].cur
            timerFlip[i].cur  = ch
            timerFlip[i].t    = 0.0
        end
    end
    timerStr = newStr
end
-- ====================================================================

-- ===================== ATTEMPTS SMOOTH COUNTER =====================
local attemptsDisplay   = 0.0   -- плавное отображаемое значение
local attemptsAnimStart = 0.0
local attemptsAnimDur   = 0.25  -- секунды анимации
local attemptsFrom      = 0
local attemptsTo        = 0

local function triggerAttemptsAnim(newVal)
    attemptsFrom      = attemptsDisplay
    attemptsTo        = newVal
    attemptsAnimStart = os.clock()
end
-- ===================================================================

-- Анимация поимки репорта
local catchAnim = {
    active = false,
    startTime = 0
}

-- Анимация появления окна
local slideAnim = {
    active = false,
    startTime = 0,
    duration = 400,
    offsetX = 0,
    offsetY = 0
}

-- Анимация скрытия окна
local slideOutAnim = {
    active = false,
    startTime = 0,
    duration = 350,
    offsetX = 0,
    offsetY = 0
}

-- Универсальное уведомление над окном (слот 1 - сверху)
local notifyAnim = {
    active = false,
    startTime = 0,
    duration = 2800,
    text = "",
    r = 1.0, g = 1.0, b = 1.0,
    useSmallFont = false,
    ending = false,
    endTime = 0
}

-- Универсальное уведомление под окном (слот 2 - снизу)
local notifyAnim2 = {
    active = false,
    startTime = 0,
    duration = 2800,
    text = "",
    r = 1.0, g = 1.0, b = 1.0,
    useSmallFont = false,
    ending = false,
    endTime = 0
}

local function showNotify(text, r, g, b, duration, useSmallFont)
    local slot
    if not notifyAnim.active and not notifyAnim.ending then
        slot = notifyAnim
    elseif not notifyAnim2.active and not notifyAnim2.ending then
        slot = notifyAnim2
    else
        -- Оба заняты — сбрасываем слот 2 и пишем в него
        notifyAnim2.active = false
        notifyAnim2.ending = false
        slot = notifyAnim2
    end
    slot.active    = true
    slot.ending    = false
    slot.startTime = os.clock()
    slot.endTime   = 0
    slot.duration  = duration
    slot.text      = text
    slot.r = r; slot.g = g; slot.b = b
    slot.useSmallFont = useSmallFont or false
end

local function hideNotify(slot)
    slot.ending = true
    slot.endTime = os.clock()
end

local ffi = require 'ffi'
ffi.cdef[[
    int MessageBoxA(void* hWnd, const char* text, const char* caption, unsigned int type);
    void* GetForegroundWindow(void);
    void* FindWindowA(const char* lpClassName, const char* lpWindowName);
]]

local function isGameFocused()
    local foreground = ffi.C.GetForegroundWindow()
    local gameWindow = ffi.C.FindWindowA("SAMP", nil)
    if gameWindow == nil or gameWindow == ffi.cast("void*", 0) then
        gameWindow = ffi.C.FindWindowA(nil, "Arizona RP")
    end
    return foreground == gameWindow
end

local showBox = effil.thread(function(text, caption)
    local ffi = require 'ffi'
    ffi.cdef[[
        int MessageBoxA(void* hWnd, const char* text, const char* caption, unsigned int type);
    ]]
    ffi.C.MessageBoxA(nil, text, caption, 0x40)
end)

local function notifyIfMinimized()
    if not isGameFocused() then
        showBox("Репорт пойман!", "Report ~~load~~")
    end
end

local function checkLoadOrder()
    local logPath = getWorkingDirectory() .. "\\moonloader.log"
    local file = io.open(logPath, "r")
    if not file then return true end
    local content = file:read("*all")
    file:close()
    local myName = thisScript().name
    local myPos, toolsPos, i = nil, nil, 0
    for line in content:gmatch("[^\r\n]+") do
        i = i + 1
        if line:find("Loading script") then
            if line:find(myName, 1, true) then myPos = i end
            if line:find("arztools", 1, true) or line:find("Arizona Tools", 1, true) then toolsPos = i end
        end
    end
    if myPos and toolsPos then return myPos < toolsPos end
    return true
end

local function checkAndWarn()
    local ok = checkLoadOrder()
    if not ok then
        sampAddChatMessage("{FF0000}Ошибка: нужно перезапустить Arizona Tools!", 0xFF0000)
        return false
    end
    return true
end

local SPAM_KEY = 0x45
local SPAM_CMD = "/ot"
local SPAM_COUNT = 3
local SPAM_DELAY = 130
local SPAM_INTERVAL = 1200

local FREE_SPAM_COUNT = 2
local FREE_SPAM_DELAY = 300
local FREE_SPAM_INTERVAL = 1200

local GITHUB_OWNER = "SaportBati"
local GITHUB_REPO  = "report1"
local GITHUB_FILE  = "users_encrypted.txt"
local v103         = "SaportBati_SecretKey_2024"

local CURRENT_VERSION = "2.13"

local WORKER_URL      = "https://loadsiteprivate.saportbati.workers.dev"
local WORKER_SITE_URL = "https://loadsite-api.grebenkinmatveyvyceslacovi2007.workers.dev"
local SITE_URL        = "http://loadrep.ru"



-- Stats accumulators (reset after each upload)
local STATS_INTERVAL   = 60
local statsPingSum     = 0
local statsPingSamples = 0
local statsCaughtDelta = 0
local statsMissedDelta = 0
local statsActiveSeconds   = 0
local statsLastActiveCheck = 0
local statsCachedSha   = nil


local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

local function b64decode(data)
    data = data:gsub('[^' .. b64chars .. '=]', '')
    return (data:gsub('.', function(x)
        if x == '=' then return '' end
        local r, f = '', (b64chars:find(x) - 1)
        for i = 6, 1, -1 do r = r .. (f % 2^i - f % 2^(i-1) > 0 and '1' or '0') end
        return r
    end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
        if #x < 8 then return '' end
        local c = 0
        for i = 1, 8 do c = c + (x:sub(i,i) == '1' and 2^(8-i) or 0) end
        return string.char(c)
    end))
end

local function xorDecrypt(data, key)
    local result = {}
    for i = 1, #data do
        local ki = ((i - 1) % #key) + 1
        result[i] = string.char(bit.bxor(data:byte(i), key:byte(ki)))
    end
    return table.concat(result)
end

local function stripPrefix(name)
    return name:match("^%[%d+%](.+)$") or name
end

-- ===================== WHITELIST THREAD =====================
local whitelistThread = effil.thread(function(xorKey, playerName)
    local requests = require 'requests'
    local b64c = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

    local function b64dec(data)
        data = data:gsub('[^' .. b64c .. '=]', '')
        return (data:gsub('.', function(x)
            if x == '=' then return '' end
            local r, f = '', (b64c:find(x) - 1)
            for i = 6, 1, -1 do r = r .. (f % 2^i - f % 2^(i-1) > 0 and '1' or '0') end
            return r
        end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
            if #x < 8 then return '' end
            local c = 0
            for i = 1, 8 do c = c + (x:sub(i,i) == '1' and 2^(8-i) or 0) end
            return string.char(c)
        end))
    end

    local function xorDecCompat(data, key)
        local result = {}
        for i = 1, #data do
            local ki = ((i - 1) % #key) + 1
            local a, b = data:byte(i), key:byte(ki)
            local res, bit_val = 0, 1
            while a > 0 or b > 0 do
                local ab, bb = a % 2, b % 2
                if ab ~= bb then res = res + bit_val end
                a = math.floor(a / 2); b = math.floor(b / 2); bit_val = bit_val * 2
            end
            result[i] = string.char(res)
        end
        return table.concat(result)
    end

    local function stripPfx(name) return name:match("^%[%d+%](.+)$") or name end

    local function parseEntry(entry)
        local parts = {}
        for part in (entry .. "|"):gmatch("([^|]*)|") do
            table.insert(parts, part)
        end
        local nick   = parts[1] or entry
        local ts     = tonumber(parts[2]) or 0
        local prefix = (parts[3] and parts[3] ~= "") and parts[3] or nil
        local color  = (parts[4] and parts[4] ~= "") and parts[4] or nil
        return nick, ts, prefix, color
    end

    local url = "https://raw.githubusercontent.com/SaportBati/report1/main/users_encrypted.txt"
    local ok, res = pcall(function()
        return requests.get(url, { headers = { ["User-Agent"] = "MoonLoader" } })
    end)
    if not ok or not res or res.status_code ~= 200 then
        return { status = "error", code = (res and res.status_code or 0) }
    end

    local cleanPlayer = stripPfx(playerName):lower()
    local found    = false
    local expireTs = 0
    local prefix   = nil
    local color    = nil

    for line in (res.text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            local decoded      = b64dec(trimmed)
            local decrypted    = xorDecCompat(decoded, xorKey)
            local entryNick, entryExpire, entryPrefix, entryColor = parseEntry(decrypted)

            if stripPfx(entryNick):lower() == cleanPlayer then
                local now = os.time()
                if entryExpire == 0 or now <= entryExpire then
                    found    = true
                    expireTs = entryExpire
                    prefix   = entryPrefix
                    color    = entryColor
                end
                break
            end
        end
    end

    return { status = "success", found = found, expireTs = expireTs, prefix = prefix, color = color }
end)

-- ===================== SITE CHECK THREAD =====================
local siteCheckThread = effil.thread(function(workerUrl, playerName)
    local requests = require 'requests'
    local ok, res = pcall(function()
        return requests.get(workerUrl .. "/check-user?nick=" .. playerName, {
            headers = { ["User-Agent"] = "MoonLoader" }
        })
    end)
    if not ok or not res then
        return { error = true, status = 0 }
    end
    local body = res.text or ""
    local found = body:find('"found"%s*:%s*true') ~= nil
    return { error = false, status = res.status_code, found = found and "yes" or "no" }
end)

-- ===================== VERSION / SCRIPT THREADS =====================
local versionCheckThread = effil.thread(function()
    local requests = require 'requests'
    local url = "https://raw.githubusercontent.com/SaportBati/report1/main/version.txt"
    local ok, res = pcall(function()
        return requests.get(url, { headers = { ["User-Agent"] = "MoonLoader" } })
    end)
    if not ok or not res or res.status_code ~= 200 then return { error = true } end
    return { version = res.text:match("^%s*(.-)%s*$") }
end)

local LUAC_URL = "https://raw.githubusercontent.com/SaportBati/report1/main/!load.luac"

-- ===================== STATS THREAD =====================
local statsUpdateThread = effil.thread(function(
        workerUrl,
        playerName, cachedSha,
        pingAvg, caughtDelta, missedDelta, activeSecsDelta)

    local requests = require 'requests'

    local cur_sha = cachedSha or ""
    local cur_caught, cur_missed, cur_time_sec, cur_avg_ping = 0, 0, 0, 0
    local get_s = 0

    local rok, rres = pcall(function()
        return requests.get(workerUrl .. "/stats?nick=" .. playerName, {
            headers = { ["User-Agent"] = "MoonLoader" }
        })
    end)
    if rok and rres then
        get_s = rres.status_code or 0
        if rres.status_code == 200 then
            local sha_found = rres.text:match('"sha"%s*:%s*"([^"]+)"')
            if sha_found then cur_sha = sha_found end
            if rres.text:find('"found"%s*:%s*true') then
                local function getNum(k) return tonumber(rres.text:match('"' .. k .. '"%s*:%s*([%d%.]+)')) or 0 end
                cur_caught   = getNum("total_caught")
                cur_missed   = getNum("total_missed")
                cur_time_sec = getNum("total_time_sec")
                cur_avg_ping = getNum("avg_ping")
            end
        end
    end

    local new_caught   = cur_caught   + caughtDelta
    local new_missed   = cur_missed   + missedDelta
    local new_time_sec = cur_time_sec + activeSecsDelta
    local new_ping     = pingAvg > 0 and math.floor((cur_avg_ping + pingAvg) / 2 + 0.5) or cur_avg_ping
    local now_ts       = math.floor(os.time())

    local shaField = (cur_sha ~= "") and (',"sha":"' .. cur_sha .. '"') or ""
    local postBody = string.format(
        '{"nick":"%s"%s,"data":{"total_caught":%d,"total_missed":%d,"total_time_sec":%d,"avg_ping":%d,"last_updated":%d}}',
        playerName, shaField, new_caught, new_missed, new_time_sec, new_ping, now_ts
    )

    local post_s = 0
    local new_sha = ""
    local wok, wres = pcall(function()
        return requests.post(workerUrl .. "/stats", {
            headers = { ["User-Agent"] = "MoonLoader", ["Content-Type"] = "application/json" },
            data = postBody
        })
    end)
    if wok and wres then
        post_s = wres.status_code or 0
        new_sha = wres.text:match('"sha"%s*:%s*"([^"]+)"') or ""
    end

    return { get_s = get_s, post_s = post_s, sha = new_sha }
end)

local function runStatsUpdate(playerName, pingAvg, caughtDelta, missedDelta, activeSecsDelta)
    local t = statsUpdateThread(
        WORKER_SITE_URL,
        playerName, statsCachedSha or "",
        pingAvg, caughtDelta, missedDelta, activeSecsDelta)
    lua_thread.create(function()
        local t0 = os.clock()
        while true do
            wait(300)
            local s = t:status()
            if s == "completed" then
                local ok2, r = pcall(function() return t:get() end)
                if ok2 and r then
                    if r.sha and r.sha ~= "" then statsCachedSha = r.sha end
                end
                return
            elseif s == "failed" then return end
            if os.clock() - t0 > 25 then return end
        end
    end)
end

local function runWhitelistCheck(playerName)
    local t = whitelistThread(v103, playerName)
    local start = os.clock()
    while true do
        wait(100)
        local s = t:status()
        if s == "completed" then return t:get()
        elseif s == "failed" then return nil end
        if os.clock() - start > 12 then return nil end
    end
end

-- ===================== IMGUI ОКНО =====================
local showWindow = imgui.new.bool(false)
local font_title, font_info, font_missed = nil, nil, nil

local window = {
    x = 100, y = 100,
    w = 250, h = 68,
    isInitialized = false
}

imgui.OnInitialize(function()
    local glyph_ranges = imgui.GetIO().Fonts:GetGlyphRangesCyrillic()

    local chosen_font
    if doesFileExist(FONT_PATH) then
        chosen_font = FONT_PATH
    else
        chosen_font = getFolderPath(0x14) .. '\\trebuc.ttf'
    end

    font_title  = imgui.GetIO().Fonts:AddFontFromFileTTF(chosen_font, 19.0, nil, glyph_ranges)
    font_info   = imgui.GetIO().Fonts:AddFontFromFileTTF(chosen_font, 16.0, nil, glyph_ranges)
    font_missed = imgui.GetIO().Fonts:AddFontFromFileTTF(chosen_font, 26.0, nil, glyph_ranges)
    imgui.GetStyle().WindowRounding = 12.0
    imgui.GetStyle().Colors[imgui.Col.WindowBg] = imgui.ImVec4(0.06, 0.06, 0.06, 0.94)
    window.isInitialized = true
end)

local function BuildRoundedRectPath(pos, size, radius, segments)
    segments = segments or 8
    local x, y = pos.x, pos.y
    local w, h = size.x, size.y
    local r = math.min(radius, w/2, h/2)
    local points = {}
    local corners = {
        {x + w - r, y + r,     -math.pi*0.5, 0           },
        {x + w - r, y + h - r, 0,            math.pi*0.5 },
        {x + r,     y + h - r, math.pi*0.5,  math.pi     },
        {x + r,     y + r,     math.pi,      math.pi*1.5 },
    }
    for _, c in ipairs(corners) do
        local cx, cy, a1, a2 = c[1], c[2], c[3], c[4]
        for i = 0, segments do
            local a = a1 + (a2 - a1) * (i / segments)
            points[#points+1] = {cx + math.cos(a) * r, cy + math.sin(a) * r}
        end
    end
    points[#points+1] = points[1]
    return points
end

local function BuildPathLengths(path)
    local lens, total = {}, 0
    for i = 1, #path - 1 do
        local dx = path[i+1][1] - path[i][1]
        local dy = path[i+1][2] - path[i][2]
        local l  = math.sqrt(dx*dx + dy*dy)
        lens[#lens+1] = l
        total = total + l
    end
    return lens, total
end

local function DrawDashedBorder(dl, pos, size, time, alpha)
    alpha = alpha or 1.0
    local borderColor
    if freeMode then
        borderColor = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1.0, 0.55, 0.0, alpha))
    else
        borderColor = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.6, 0.6, 0.6, alpha))
    end
    local dashLen, gapLen, speed, thickness, radius = 10.0, 8.0, 25.0, 1.5, 10.0
    local step = dashLen + gapLen
    local m = 1.0
    local mpos  = imgui.ImVec2(pos.x + m, pos.y + m)
    local msize = imgui.ImVec2(size.x - m*2, size.y - m*2)
    local path = BuildRoundedRectPath(mpos, msize, radius, 8)
    local lens, total = BuildPathLengths(path)
    local animPos = (time * speed) % total
    local walked  = 0
    for i = 1, #path - 1 do
        local p1, p2, len = path[i], path[i+1], lens[i]
        if len < 0.001 then
            walked = walked + len
        else
            local dx, dy = (p2[1] - p1[1]) / len, (p2[2] - p1[2]) / len
            local offset = (animPos - walked) % step
            local curr   = -offset
            while curr < len do
                local ss = math.max(0, curr)
                local ee = math.min(len, curr + dashLen)
                if ee > ss then
                    dl:AddLine(
                        imgui.ImVec2(p1[1] + dx * ss, p1[2] + dy * ss),
                        imgui.ImVec2(p1[1] + dx * ee, p1[2] + dy * ee),
                        borderColor, thickness
                    )
                end
                curr = curr + step
            end
            walked = walked + len
        end
    end
end

-- ===================== DRAW FLIP DIGIT =====================
-- Рисует один символ с эффектом перелистывания (сверху вниз)
-- prev уходит вниз, cur появляется сверху
local function DrawFlipChar(dl, font, x, y, charData, baseColor, clipMin, clipMax)
    local ch  = charData.cur
    local prv = charData.prev
    local t   = charData.t

    -- Плавная кривая
    local ease = t * t * (3 - 2 * t)
    local charH = 16  -- высота символа (примерно)

    -- Прогресс анимации — t идёт 0?1
    -- prev: смещается вниз на charH
    -- cur:  приходит сверху, смещение charH*(1-ease) ? 0

    if t < 1.0 then
        -- Уходящий символ (prev) — съезжает вниз
        local prevOffY = charH * ease
        local prevAlpha = 1.0 - ease
        dl:PushClipRect(clipMin, clipMax, true)
        dl:AddText(
            imgui.ImVec2(x, y + prevOffY),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(baseColor[1], baseColor[2], baseColor[3], baseColor[4] * prevAlpha)),
            prv
        )
        -- Новый символ (cur) — приезжает сверху
        local curOffY = charH * (1.0 - ease)
        local curAlpha = ease
        dl:AddText(
            imgui.ImVec2(x, y - curOffY),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(baseColor[1], baseColor[2], baseColor[3], baseColor[4] * curAlpha)),
            ch
        )
        dl:PopClipRect()
    else
        -- Статичный символ
        dl:PushClipRect(clipMin, clipMax, true)
        dl:AddText(
            imgui.ImVec2(x, y),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(baseColor[1], baseColor[2], baseColor[3], baseColor[4])),
            ch
        )
        dl:PopClipRect()
    end
end
-- ===========================================================

local function DrawContent(drawList, pos, time, isGlowPass, globalAlpha)
    local colMult = isGlowPass and globalAlpha or 1.0

    local textFade = 1.0
    if catchAnim.active then
        local elapsed = (os.clock() - catchAnim.startTime) * 1000
        if elapsed < 500 then
            textFade = 1.0
        elseif elapsed < 1200 then
            local t = (elapsed - 500) / 700
            textFade = 1.0 - t * t * (3 - 2 * t)
        else
            textFade = 0.0
        end
    end

    local function GetCol(r, g, b, a)
        return imgui.ColorConvertFloat4ToU32(imgui.ImVec4(r, g, b, a * colMult))
    end
    local function GetColText(r, g, b, a)
        return imgui.ColorConvertFloat4ToU32(imgui.ImVec4(r, g, b, a * colMult * textFade))
    end

    -- ===== ЗАГОЛОВОК: "Ловля.." =====
    imgui.PushFont(font_title)
    local titleText = u8"Ловля.."
    drawList:AddText(
        imgui.ImVec2(pos.x + 95, pos.y + 12),
        isGlowPass and GetColText(1,1,1,1) or (freeMode and GetColText(1,0.55,0,1) or GetColText(0.6,0.6,0.6,1)),
        titleText
    )

    -- ===== PING: метка "Ping: " + flip-анимация цифр =====
    do
        local ping = currentPing
        local pr, pg, pb
        if ping < 70 then
            pr, pg, pb = 0.2, 1.0, 0.2
        elseif ping <= 100 then
            pr, pg, pb = 1.0, 0.85, 0.1
        else
            pr, pg, pb = 1.0, 0.2, 0.2
        end

        -- Инициализируем если пусто
        if #pingFlip == 0 then
            initPingFlip(tostring(ping))
        end

        -- Отрисовываем "Ping: " статичным текстом
        local charW_ping = 11
        local labelText  = "Ping: "
        local pingStartX = pos.x + 18

        local pingLabelColor = isGlowPass
            and GetColText(1,1,1,1)
            or  imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.6, 0.6, 0.6, 1.0 * colMult * textFade))

        drawList:AddText(
            imgui.ImVec2(pingStartX, pos.y + 12),
            pingLabelColor,
            labelText
        )

        -- Цифры пинга начинаются сразу после надписи "Ping: " + 2px отступ
        local labelPixelW  = imgui.CalcTextSize(labelText).x
        local digitsStartX = pingStartX + labelPixelW + 2
        local digitsW      = #pingFlip * charW_ping

        local pingDigitColor = { pr, pg, pb, 1.0 * colMult * textFade }
        local clipMinP = imgui.ImVec2(digitsStartX - 2, pos.y + 10)
        local clipMaxP = imgui.ImVec2(digitsStartX + digitsW + 4, pos.y + 30)

        local dX = digitsStartX
        for i, cd in ipairs(pingFlip) do
            DrawFlipChar(drawList, font_title, dX, pos.y + 12, cd, pingDigitColor, clipMinP, clipMaxP)
            dX = dX + charW_ping
        end
    end
    imgui.PopFont()

    -- ===== СТРОКА ИНФОРМАЦИИ (таймер + попытки) =====
    imgui.PushFont(font_info)
    local diff  = startTime ~= 0 and (os.time() - startTime) or 0
    local textY = pos.y + 38

    -- Цвет таймера
    local tr, tg, tb = 0.0, 0.8, 0.0
    if     diff >= 90 then tr, tg, tb = 1.0, 0.0, 0.0
    elseif diff >= 30 then tr, tg, tb = 1.0, 0.8, 0.0 end

    local timerBaseColor = { tr, tg, tb, 1.0 * colMult * textFade }

    -- Обновляем строку таймера и анимацию flip
    local newTimerStr = string.format("%02d:%02d", math.floor(diff/60), diff%60)
    if #timerFlip == 0 then
        initTimerFlip(newTimerStr)
    else
        updateTimerFlip(newTimerStr)
    end

    -- Обновляем скорость flip-анимации (60fps логика через os.clock delta)
    local flipSpeed = 8.0  -- скорость перелистывания (единиц в секунду)
    -- (обновление t происходит в главном цикле, но тут мы рисуем)

    -- Рисуем каждый символ таймера с flip-анимацией
    local charW = 10  -- примерная ширина символа для font_info 16px
    local curX  = pos.x + 18
    local clipMin = imgui.ImVec2(curX - 2, textY - 2)
    local clipMax = imgui.ImVec2(curX + charW * #timerFlip + 4, textY + 18)

    for i, cd in ipairs(timerFlip) do
        DrawFlipChar(drawList, font_info, curX, textY, cd, timerBaseColor, clipMin, clipMax)
        curX = curX + charW
        -- Разделитель ':' чуть уже
        if i == 2 then curX = curX - -1 end
        if i == 3 then curX = curX - 4 end
    end

    -- ===== ПОПЫТКИ с плавной анимацией =====
    -- Обновляем плавное значение
    local now = os.clock()
    local animElapsed = now - attemptsAnimStart
    if animElapsed < attemptsAnimDur then
        local t2 = animElapsed / attemptsAnimDur
        local ease2 = t2 * t2 * (3 - 2 * t2)
        attemptsDisplay = attemptsFrom + (attemptsTo - attemptsFrom) * ease2
    else
        attemptsDisplay = attemptsTo
    end

    -- Округляем для отображения
    local attemptsShown = math.floor(attemptsDisplay + 0.5)

    -- Мигание при изменении: лёгкая вспышка
    local attemptsAlpha = 1.0
    if animElapsed < attemptsAnimDur then
        local pulse = math.sin((animElapsed / attemptsAnimDur) * math.pi)
        attemptsAlpha = 1.0 + pulse * 0.4  -- чуть ярче в момент смены
        if attemptsAlpha > 1.0 then attemptsAlpha = 1.0 end
    end

    local attX = pos.x + 18 + charW * #timerFlip + 10

    -- Цвет счётчика попыток
    local ar, ag, ab
    if attemptsShown <= 3 then
        ar, ag, ab = 0.2, 1.0, 0.2
    elseif attemptsShown <= 5 then
        ar, ag, ab = 1.0, 0.85, 0.1
    else
        ar, ag, ab = 1.0, 0.2, 0.2
    end

    -- Считаем ширину лейбла пока font_info активен (мы уже внутри PushFont(font_info))
    local labelW2 = imgui.CalcTextSize(u8"Попыток: ").x

    -- "Попыток: " серым
    drawList:AddText(
        imgui.ImVec2(attX, textY),
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.6, 0.6, 0.6, attemptsAlpha * colMult * textFade)),
        u8"Попыток: "
    )
    -- Цифра цветная
    drawList:AddText(
        imgui.ImVec2(attX + labelW2, textY),
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(ar, ag, ab, attemptsAlpha * colMult * textFade)),
        tostring(attemptsShown)
    )
    imgui.PopFont()

    -- ===== ВОЛНА И АНИМАЦИЯ ПОИМКИ (без изменений) =====
    if catchAnim.active then
        local elapsed = (os.clock() - catchAnim.startTime) * 1000
        local cx = pos.x + window.w - 35
        local cy = pos.y + window.h / 2 + 4

        local function drawCheckmark(cx2, cy2, scale, alpha)
            local s = scale
            drawList:AddLine(imgui.ImVec2(cx2-7*s, cy2+1*s), imgui.ImVec2(cx2-2*s, cy2+6*s), GetCol(1,1,1,alpha), 2.5)
            drawList:AddLine(imgui.ImVec2(cx2-2*s, cy2+6*s), imgui.ImVec2(cx2+7*s, cy2-5*s), GetCol(1,1,1,alpha), 2.5)
        end

        if elapsed < 500 then
            local t = elapsed / 500
            local ease = t * t * (3 - 2 * t)
            local waveFade = 1.0 - ease
            local waveX, waveY, waveWidth = pos.x + 165, pos.y + 38, 70
            local function drawWave(wSpeed, opacity)
                local off = math.sin(time * wSpeed) * 15
                local p1  = imgui.ImVec2(waveX,                    waveY)
                local p2  = imgui.ImVec2(waveX + waveWidth * 0.5,  waveY)
                local p3  = imgui.ImVec2(waveX + waveWidth,        waveY)
                local cp1 = imgui.ImVec2(waveX + waveWidth * 0.25, waveY - off)
                local cp2 = imgui.ImVec2(waveX + waveWidth * 0.75, waveY + off)
                drawList:AddBezierCurve(p1, cp1, cp1, p2, GetCol(1,1,1, opacity * waveFade), 2.2)
                drawList:AddBezierCurve(p2, cp2, cp2, p3, GetCol(1,1,1, opacity * waveFade), 2.2)
            end
            drawWave(3.5, 0.2); drawWave(2.5, 0.4); drawWave(1.8, 0.6)
            local r = 14 * ease
            if r > 0.5 then
                drawList:AddCircleFilled(imgui.ImVec2(cx, cy), r, GetCol(0, 0.85, 0.3, ease), 32)
            end
            if ease > 0.3 then
                drawCheckmark(cx, cy, ease * 0.85 + 0.15, (ease - 0.3) / 0.7)
            end

        elseif elapsed < 1500 then
            local t = (elapsed - 500) / 1000
            local ease = t * t * (3 - 2 * t)
            local circleAlpha = 1.0 - ease
            drawList:AddCircleFilled(imgui.ImVec2(cx, cy), 14, GetCol(0, 0.85, 0.3, circleAlpha), 32)
            if circleAlpha > 0.05 then
                drawCheckmark(cx, cy, 1.0, circleAlpha)
            end
            imgui.PushFont(font_title)
            drawList:AddText(
                imgui.ImVec2(pos.x + window.w/2 - 38, pos.y + window.h/2 - 9),
                GetCol(1, 1, 1, ease),
                u8"Поймал!"
            )
            imgui.PopFont()

        elseif elapsed < 2500 then
            local t = (elapsed - 1500) / 1000
            local alpha = 1.0 - t * t * (3 - 2 * t)
            imgui.PushFont(font_title)
            drawList:AddText(
                imgui.ImVec2(pos.x + window.w/2 - 38, pos.y + window.h/2 - 9),
                GetCol(1, 1, 1, alpha),
                u8"Поймал!"
            )
            imgui.PopFont()
        end
    else
        local waveX, waveY, waveWidth = pos.x + 165, pos.y + 36, 70
        local function drawWave(wSpeed, opacity)
            local off = math.sin(time * wSpeed) * 15
            local p1  = imgui.ImVec2(waveX,                    waveY)
            local p2  = imgui.ImVec2(waveX + waveWidth * 0.5,  waveY)
            local p3  = imgui.ImVec2(waveX + waveWidth,        waveY)
            local cp1 = imgui.ImVec2(waveX + waveWidth * 0.25, waveY - off)
            local cp2 = imgui.ImVec2(waveX + waveWidth * 0.75, waveY + off)
            local c   = isGlowPass and GetCol(1,1,1,1) or GetCol(1,1,1,opacity)
            drawList:AddBezierCurve(p1, cp1, cp1, p2, c, 2.2)
            drawList:AddBezierCurve(p2, cp2, cp2, p3, c, 2.2)
        end
        drawWave(3.5, 0.2); drawWave(2.5, 0.4); drawWave(1.8, 0.6)
    end
end

imgui.OnFrame(
    function() return showWindow[0] or settingPosition or catchAnim.active or slideOutAnim.active or notifyAnim.active or notifyAnim.ending or notifyAnim2.active or notifyAnim2.ending end,
    function(self)
        self.HideCursor = not settingPosition

        -- Обновляем t для flip-анимаций (таймер + пинг)
        local dt = 1.0 / 60.0
        for i, cd in ipairs(timerFlip) do
            if cd.t < 1.0 then cd.t = math.min(1.0, cd.t + dt * 8.0) end
        end
        for i, cd in ipairs(pingFlip) do
            if cd.t < 1.0 then cd.t = math.min(1.0, cd.t + dt * 8.0) end
        end

        if settingPosition then
            local cur = imgui.GetMousePos()
            window.x = cur.x - window.w / 2
            window.y = cur.y - 20
            if imgui.IsMouseClicked(0) then
                settingPosition = false
                if not active then showWindow[0] = false end
                saveSettings()
                sampAddChatMessage("Позиция окна сохранена!", 0xFF8C00)
            end
        end

        local bgR, bgG, bgB, bgA = 0.06, 0.06, 0.06, 0.94
        if catchAnim.active then
            local elapsed = (os.clock() - catchAnim.startTime) * 1000
            if elapsed < 500 then
                -- фаза 1: фон без изменений
            elseif elapsed < 1500 then
                local t = (elapsed - 500) / 1000
                local ease = t * t * (3 - 2 * t)
                bgR = 0.06 + (0.0  - 0.06) * ease
                bgG = 0.06 + (0.78 - 0.06) * ease
                bgB = 0.06 + (0.28 - 0.06) * ease
                bgA = 0.94
            elseif elapsed < 2500 then
                local t = (elapsed - 1500) / 1000
                local alpha = 1.0 - t * t * (3 - 2 * t)
                bgR = 0.0
                bgG = 0.78
                bgB = 0.28
                bgA = 0.94 * alpha
            else
                catchAnim.active = false
                showWindow[0] = false
                imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.06, 0.06, 0.06, 0))
                imgui.SetNextWindowSize(imgui.ImVec2(window.w, window.h), imgui.Cond.Always)
                imgui.SetNextWindowPos(imgui.ImVec2(window.x, window.y), imgui.Cond.Always)
                imgui.Begin('##CatchWindow', showWindow, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove)
                imgui.PopStyleColor()
                imgui.End()
                return
            end
        end
        imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(bgR, bgG, bgB, bgA))

        local slideOffX, slideOffY = 0, 0
        if slideAnim.active then
            local elapsed = (os.clock() - slideAnim.startTime) * 1000
            if elapsed < slideAnim.duration then
                local t = elapsed / slideAnim.duration
                local ease = 1.0 - (1.0 - t) * (1.0 - t) * (1.0 - t)
                slideOffX = slideAnim.offsetX * (1.0 - ease)
                slideOffY = slideAnim.offsetY * (1.0 - ease)
            else
                slideAnim.active = false
            end
        end
        if slideOutAnim.active then
            local elapsed = (os.clock() - slideOutAnim.startTime) * 1000
            if elapsed < slideOutAnim.duration then
                local t = elapsed / slideOutAnim.duration
                local ease = t * t * t
                slideOffX = slideOutAnim.offsetX * ease
                slideOffY = slideOutAnim.offsetY * ease
            else
                slideOutAnim.active = false
                showWindow[0] = false
                imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0,0,0,0))
                imgui.SetNextWindowSize(imgui.ImVec2(0, 0), imgui.Cond.Always)
                imgui.SetNextWindowPos(imgui.ImVec2(-9999, -9999), imgui.Cond.Always)
                imgui.Begin('##CatchWindow', showWindow, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove)
                imgui.PopStyleColor()
                imgui.End()
                return
            end
        end

        imgui.SetNextWindowSize(imgui.ImVec2(window.w, window.h), imgui.Cond.Always)
        imgui.SetNextWindowPos(imgui.ImVec2(window.x + slideOffX, window.y + slideOffY), imgui.Cond.Always)
        imgui.Begin('##CatchWindow', showWindow,
            imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove)

        imgui.PopStyleColor()

        local drawList = imgui.GetWindowDrawList()
        local fgList   = imgui.GetForegroundDrawList()
        local pos      = imgui.GetWindowPos()
        local size     = imgui.GetWindowSize()
        local time     = os.clock()

        DrawContent(drawList, pos, time, false)
        local borderAlpha = 1.0
        if catchAnim.active then
            local elapsed = (os.clock() - catchAnim.startTime) * 1000
            if elapsed >= 1500 then
                local t = (elapsed - 1500) / 1000
                borderAlpha = 1.0 - t * t * (3 - 2 * t)
            end
        end
        DrawDashedBorder(fgList, pos, size, time, borderAlpha)

        local speed, beamWidth, tilt, pause = 250.0, 50.0, 25.0, 3.0
        local cycleTime = (size.x + beamWidth + tilt) / speed + pause
        local progress  = (time % cycleTime) * speed
        local beamStart = pos.x - beamWidth - tilt + progress

        if not catchAnim.active and beamStart < pos.x + size.x + beamWidth then
            for i = 1, 10 do
                local intensity = math.pow(math.sin((i / 10) * math.pi), 2) * 0.7
                local clipMin   = imgui.ImVec2(beamStart + (i-1)*(beamWidth/10), pos.y)
                local clipMax   = imgui.ImVec2(clipMin.x + (beamWidth/10) + tilt, pos.y + size.y)
                if clipMax.x > pos.x and clipMin.x < pos.x + size.x then
                    imgui.PushClipRect(clipMin, clipMax, true)
                    DrawContent(drawList, pos, time, true, intensity)
                    imgui.PopClipRect()
                end
            end
        end

        imgui.End()
    end
)

imgui.OnFrame(
    function() return notifyAnim.active end,
    function(self)
        self.HideCursor = true
        if notifyAnim.active then
            local elapsed = (os.clock() - notifyAnim.startTime) * 1000
            local totalDuration = 400 + 2000 + 400
            local slideH = 26
            local offsetY, alpha

            if notifyAnim.duration > 0 then
                if elapsed >= totalDuration then
                    notifyAnim.active = false
                    return
                end
                if elapsed < 400 then
                    local t = elapsed / 400
                    local ease = t * t * (3 - 2 * t)
                    offsetY = slideH * (1.0 - ease)
                    alpha = ease
                elseif elapsed < 2400 then
                    offsetY = 0
                    alpha = 1.0
                else
                    local t = (elapsed - 2400) / 400
                    local ease = t * t * (3 - 2 * t)
                    offsetY = slideH * ease
                    alpha = 1.0 - ease
                end
            else
                if notifyAnim.ending then
                    local t = (os.clock() - notifyAnim.endTime) * 1000 / 400
                    if t >= 1.0 then
                        notifyAnim.active = false
                        notifyAnim.ending = false
                        return
                    end
                    local ease = t * t * (3 - 2 * t)
                    offsetY = 36 * ease
                    alpha = 1.0 - ease
                elseif elapsed < 400 then
                    local t = elapsed / 400
                    local ease = t * t * (3 - 2 * t)
                    offsetY = slideH * (1.0 - ease)
                    alpha = ease
                else
                    offsetY = 0
                    alpha = 1.0
                end
            end

            local winY = window.y - slideH - 3 + offsetY

            imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0, 0, 0, 0))
            imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(0, 0, 0, 0))
            imgui.SetNextWindowPos(imgui.ImVec2(window.x, winY), imgui.Cond.Always)
            imgui.SetNextWindowSize(imgui.ImVec2(window.w, slideH), imgui.Cond.Always)
            imgui.Begin('##NotifyWindow', imgui.new.bool(true),
                imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize +
                imgui.WindowFlags.NoMove + imgui.WindowFlags.NoScrollbar +
                imgui.WindowFlags.NoInputs + imgui.WindowFlags.NoNav +
                imgui.WindowFlags.NoBackground)
            imgui.PopStyleColor(2)

            local dl = imgui.GetWindowDrawList()
            local wpos = imgui.GetWindowPos()
            local activeFont = notifyAnim.useSmallFont and font_title or font_missed
            imgui.PushFont(activeFont)
            local txt = notifyAnim.text
            local textWidth = imgui.CalcTextSize(txt).x
            local textX = wpos.x + (window.w - textWidth) / 2
            local textY = winY + 4

            dl:PushClipRect(
                imgui.ImVec2(window.x - 10, window.y - slideH - 3),
                imgui.ImVec2(window.x + window.w + 10, window.y),
                false
            )
            dl:AddText(
                imgui.ImVec2(textX + 2, textY + 2),
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0, 0, 0, 0.6 * alpha)),
                txt
            )
            dl:AddText(
                imgui.ImVec2(textX, textY),
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(notifyAnim.r, notifyAnim.g, notifyAnim.b, alpha)),
                txt
            )
            dl:PopClipRect()
            imgui.PopFont()
            imgui.End()
        end
    end
)

imgui.OnFrame(
    function() return notifyAnim2.active or notifyAnim2.ending end,
    function(self)
        self.HideCursor = true
        if notifyAnim2.active or notifyAnim2.ending then
            local elapsed = (os.clock() - notifyAnim2.startTime) * 1000
            local slideH = 26
            local offsetY, alpha

            if notifyAnim2.duration > 0 then
                local totalDuration = 400 + 2000 + 400
                if elapsed >= totalDuration then
                    notifyAnim2.active = false
                    return
                end
                if elapsed < 400 then
                    local t = elapsed / 400
                    local ease = t * t * (3 - 2 * t)
                    offsetY = -slideH * (1.0 - ease)
                    alpha = ease
                elseif elapsed < 2400 then
                    offsetY = 0; alpha = 1.0
                else
                    local t = (elapsed - 2400) / 400
                    local ease = t * t * (3 - 2 * t)
                    offsetY = -slideH * ease
                    alpha = 1.0 - ease
                end
            else
                if notifyAnim2.ending then
                    local t = (os.clock() - notifyAnim2.endTime) * 1000 / 400
                    if t >= 1.0 then
                        notifyAnim2.active = false
                        notifyAnim2.ending = false
                        return
                    end
                    local ease = t * t * (3 - 2 * t)
                    offsetY = -slideH * ease
                    alpha = 1.0 - ease
                elseif elapsed < 400 then
                    local t = elapsed / 400
                    local ease = t * t * (3 - 2 * t)
                    offsetY = -slideH * (1.0 - ease)
                    alpha = ease
                else
                    offsetY = 0; alpha = 1.0
                end
            end

            local winY = window.y + window.h + 3 + offsetY

            imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0, 0, 0, 0))
            imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(0, 0, 0, 0))
            imgui.SetNextWindowPos(imgui.ImVec2(window.x, winY), imgui.Cond.Always)
            imgui.SetNextWindowSize(imgui.ImVec2(window.w, slideH), imgui.Cond.Always)
            imgui.Begin('##NotifyWindow2', imgui.new.bool(true),
                imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize +
                imgui.WindowFlags.NoMove + imgui.WindowFlags.NoScrollbar +
                imgui.WindowFlags.NoInputs + imgui.WindowFlags.NoNav +
                imgui.WindowFlags.NoBackground)
            imgui.PopStyleColor(2)

            local dl = imgui.GetWindowDrawList()
            local wpos = imgui.GetWindowPos()
            local activeFont = notifyAnim2.useSmallFont and font_title or font_missed
            imgui.PushFont(activeFont)
            local txt = notifyAnim2.text
            local textWidth = imgui.CalcTextSize(txt).x
            local textX = wpos.x + (window.w - textWidth) / 2
            local textY = window.y + window.h - 5 + offsetY

            dl:PushClipRect(
                imgui.ImVec2(window.x - 10, window.y + window.h),
                imgui.ImVec2(window.x + window.w + 10, window.y + window.h + slideH + 10),
                false
            )
            dl:AddText(
                imgui.ImVec2(textX + 2, textY + 2),
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0, 0, 0, 0.6 * alpha)),
                txt
            )
            dl:AddText(
                imgui.ImVec2(textX, textY),
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(notifyAnim2.r, notifyAnim2.g, notifyAnim2.b, alpha)),
                txt
            )
            dl:PopClipRect()
            imgui.PopFont()
            imgui.End()
        end
    end
)

local SETTINGS_FILE = getWorkingDirectory() .. "\\spam_settings.ini"

local function isReportCaught()
    local ok, val = pcall(function() return _G["var_0_77"] end)
    if ok and type(val) == "table" then return val.ok ~= nil end
    return false
end

local function isReportWindowOpen()
    local ok, val = pcall(function() return _G["win"] end)
    if ok and type(val) == "table" and val.report then return val.report.v == true end
    return false
end

local function doUpdate()
    sampAddChatMessage("{FFD700}[Update] Скачиваю новую версию...", 0xFFD700)

    -- Пути старого и нового файла
    local oldPath = thisScript().path
    local newPath = oldPath
    if not newPath:find("%.luac$") then
        newPath = newPath:gsub("%.lua$", ".luac")
    end

    -- Удаляем старый файл перед скачиванием
    if doesFileExist(oldPath) then
        os.remove(oldPath)
    end
    if oldPath ~= newPath and doesFileExist(newPath) then
        os.remove(newPath)
    end

    local dlstatus = require('moonloader').download_status
    local done   = false
    local failed = false
    downloadUrlToFile(LUAC_URL, newPath, function(id, status, p1, p2)
        if status == dlstatus.STATUS_ENDDOWNLOADDATA then
            done = true
        elseif status == dlstatus.STATUS_DOWNLOADFAILED then
            failed = true
            done   = true
        end
    end)
    local t0 = os.clock()
    while not done do
        wait(200)
        if os.clock() - t0 > 30 then
            sampAddChatMessage("{FF0000}[Update] Таймаут загрузки!", 0xFF0000)
            return
        end
    end
    if failed then
        sampAddChatMessage("{FF0000}[Update] Ошибка при скачивании файла!", 0xFF0000)
        return
    end
    sampAddChatMessage("{00FF00}[Update] Обновление установлено! Перезагрузка...", 0x00FF00)
    wait(1500)
    thisScript():reload()
end

local function startVersionChecker()
    lua_thread.create(function()
        while true do
            local t = versionCheckThread()
            local t0 = os.clock()
            local timedOut = false
            while true do
                wait(300)
                local s = t:status()
                if s == "completed" or s == "failed" then break end
                if os.clock() - t0 > 15 then
                    timedOut = true
                    break
                end
            end
            if not timedOut and t:status() == "completed" then
                local ok2, r = pcall(function() return t:get() end)
                if ok2 and r and not r.error and r.version then
                    if r.version ~= CURRENT_VERSION then
                        sampAddChatMessage("{FFD700}[Update] Доступна новая версия: " .. r.version .. "! Скачиваю автоматически...", 0xFFD700)
                        lua_thread.create(doUpdate)
                        return
                    end
                end
            end
            wait(180000)
        end
    end)
end

local function triggerCatchAnimation()
    catchAnim.active = true
    catchAnim.startTime = os.clock()
    notifyAnim.active = false
    notifyAnim.ending = false
    notifyAnim2.active = false
    notifyAnim2.ending = false
    showWindow[0] = true
    playSound(sounds.caught)
end

local function triggerSlideAnim()
    local sw, sh = getScreenResolution()
    local dLeft   = window.x
    local dRight  = sw - (window.x + window.w)
    local dTop    = window.y
    local dBottom = sh - (window.y + window.h)
    local minD = math.min(dLeft, dRight, dTop, dBottom)
    local ox, oy = 0, 0
    if minD == dLeft then
        ox = -(window.w + 20)
    elseif minD == dRight then
        ox = (window.w + 20)
    elseif minD == dTop then
        oy = -(window.h + 20)
    else
        oy = (window.h + 20)
    end
    slideAnim.active    = true
    slideAnim.startTime = os.clock()
    slideAnim.offsetX   = ox
    slideAnim.offsetY   = oy
end

local function triggerSlideOutAnim()
    local sw, sh = getScreenResolution()
    local dLeft   = window.x
    local dRight  = sw - (window.x + window.w)
    local dTop    = window.y
    local dBottom = sh - (window.y + window.h)
    local minD = math.min(dLeft, dRight, dTop, dBottom)
    local ox, oy = 0, 0
    if minD == dLeft then
        ox = -(window.w + 20)
    elseif minD == dRight then
        ox = (window.w + 20)
    elseif minD == dTop then
        oy = -(window.h + 20)
    else
        oy = (window.h + 20)
    end
    slideOutAnim.active    = true
    slideOutAnim.startTime = os.clock()
    slideOutAnim.offsetX   = ox
    slideOutAnim.offsetY   = oy
end

function sampev.onShowDialog(id, type, title, button1, button2, text)
    if id == 1334 and active then
        active = false
        statsCaughtDelta = statsCaughtDelta + 1
        if spamThread then spamThread.status = "dead"; spamThread = nil end
        sampAddChatMessage("Репорт {FFD700}пойман! {FF8C00}Ловля остановлена.", 0xFF8C00)
        notifyIfMinimized()
        triggerCatchAnimation()
    end
end

function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then
        print("Ожидание загрузки SAMP...")
        while not isSampAvailable() do wait(100) end
    end

    wait(3000)
    while not isSampAvailable() do wait(100) end
    while not sampIsLocalPlayerSpawned() do wait(100) end
    wait(500)

    -- ===== СКАЧИВАНИЕ ШРИФТА =====
    ensureSoundDir()
    if not doesFileExist(FONT_PATH) then
        local dlstatus = require('moonloader').download_status
        local fontDone = false

        downloadUrlToFile(FONT_URL, FONT_PATH, function(id, status)
            if status == dlstatus.STATUS_ENDDOWNLOADDATA then
                fontDone = true
            end
        end)
        local t = os.clock()
        while not fontDone and os.clock() - t < 10 do
            wait(100)
        end
        if doesFileExist(FONT_PATH) then
            wait(500)
            thisScript():reload()
            return
        end
    end
    -- ======================================================

    local myId = select(2, sampGetPlayerIdByCharHandle(playerPed))
    local playerName = sampGetPlayerNickname(myId)

    -- Загрузка звуков в фоне
    lua_thread.create(function()
        initSounds()
    end)

    -- ===== ОБНОВЛЕНИЕ ПИНГА каждые 2 секунды =====
    lua_thread.create(function()
        while true do
            updatePing()
            if currentPing > 0 then
                statsPingSum     = statsPingSum + currentPing
                statsPingSamples = statsPingSamples + 1
            end
            wait(2000)
        end
    end)

    -- ===== НАКОПЛЕНИЕ АКТИВНОГО ВРЕМЕНИ =====
    statsLastActiveCheck = os.clock()
    lua_thread.create(function()
        while true do
            wait(1000)
            local now = os.clock()
            local delta = math.floor(now - statsLastActiveCheck + 0.5)
            statsLastActiveCheck = now
            if active then statsActiveSeconds = statsActiveSeconds + delta end
        end
    end)

    -- ===== ФОНОВАЯ ОТПРАВКА СТАТИСТИКИ каждые 60 секунд =====
    lua_thread.create(function()
        wait(10000)
        while true do
            local pingAvg     = statsPingSamples > 0 and math.floor(statsPingSum / statsPingSamples + 0.5) or 0
            local caughtSnap  = statsCaughtDelta
            local missedSnap  = statsMissedDelta
            local activeSnap  = statsActiveSeconds
            statsPingSum = 0; statsPingSamples = 0
            statsCaughtDelta = 0; statsMissedDelta = 0; statsActiveSeconds = 0
            runStatsUpdate(playerName, pingAvg, caughtSnap, missedSnap, activeSnap)
            wait(STATS_INTERVAL * 1000)
        end
    end)
    -- =========================================================


    -- Запускаем оба потока параллельно
    local whitelistDone = false
    lua_thread.create(function()
        local ok, res = pcall(runWhitelistCheck, playerName)
        if not ok or not res then
            freeMode = true
        elseif not res.found then
            freeMode = true
        else
            local prefixTag = ""
            if res.prefix then
                if res.color then
                    local sampColor = res.color:gsub("^#", "")
                    prefixTag = " {00FF00}— {" .. sampColor .. "}[" .. res.prefix .. "]"
                else
                    prefixTag = " {00FF00}— {FFFFFF}[" .. res.prefix .. "]"
                end
            end
            if res.expireTs and res.expireTs ~= 0 then
                local expireDate  = os.date("%d.%m.%Y %H:%M", res.expireTs)
                local secondsLeft = res.expireTs - os.time()
                local daysLeft    = math.floor(secondsLeft / 86400)
                local hoursLeft   = math.floor((secondsLeft % 86400) / 3600)
                local timeStr
                if daysLeft > 0 then
                    timeStr = daysLeft .. "д " .. hoursLeft .. "ч"
                elseif hoursLeft > 0 then
                    timeStr = hoursLeft .. "ч " .. math.floor((secondsLeft % 3600) / 60) .. "м"
                else
                    timeStr = math.floor(secondsLeft / 60) .. "м"
                end
            else
            end
            freeMode = false
        end
        whitelistDone = true
    end)

    -- Запускаем siteCheck параллельно с whitelist — у каждого свой таймаут
    local tSite = siteCheckThread(WORKER_SITE_URL, playerName)

    -- Ждём whitelist (до 15 сек)
    local wlTimeout = os.clock() + 15
    while not whitelistDone and os.clock() < wlTimeout do
        wait(100)
    end
    if not whitelistDone then
        freeMode = true
    end

    -- Ждём siteCheck отдельно (ещё до 15 сек)
    local siteTimeout = os.clock() + 15
    while tSite:status() == "running" and os.clock() < siteTimeout do
        wait(100)
    end

    -- Читаем результат siteCheck
    do
        local siteFound = false
        local s = tSite:status()
        if s == "completed" then
            local ok, r = pcall(function() return tSite:get() end)
            if ok and r and not r.error and r.status == 200 then
                siteFound = (r.found == "yes")
            end
        end
        if not siteFound then
            sampAddChatMessage("{FF0000}[Load] Аккаунт на сайте не найден! Зарегистрируйся: {FFD700}/loadsite", 0xFF0000)
            wait(3000)
            thisScript():unload()
            return
        end
    end

    startVersionChecker()
    sampRegisterChatCommand("loadsite", function()
        sampAddChatMessage("{FFD700}[Load] Открываю {FF8C00}Load Report {FFD700}в браузере...", 0xFFD700)
        os.execute('start "" "' .. SITE_URL .. '"')
    end)

    if not freeMode then
        lua_thread.create(function()
            while true do
                wait(10000)
                local ok, r = pcall(runWhitelistCheck, playerName)
                if ok and r and r.status == "success" and not r.found then
                    sampAddChatMessage("{FF0000}[Whitelist] Ваш ник удалён из списка или подписка истекла. Переход в {FFD700}FREE{FF0000} режим.", 0xFF0000)
                    freeMode = true
                    if active then
                        if spamThread then spamThread.status = "dead"; spamThread = nil end
                        spamThread = lua_thread.create(spamFunction)
                    end
                end
            end
        end)
    end

    loadSettings()

    sampAddChatMessage("Скрипт активирован! Нажми {FFD700}"..vkeys.id_to_name(SPAM_KEY).."{FF8C00} для включения", 0xFF8C00)
    sampAddChatMessage("{FFD700}/setkey{FF8C00} - сменить клавишу | {FFD700}/setpos{FF8C00} - позиция окна | {FFD700}/loadsite{FF8C00} - сайт", 0xFF8C00)

    sampRegisterChatCommand("setkey", cmdSetKey)
    sampRegisterChatCommand("setpos", cmdSetPos)
    sampRegisterChatCommand("loadup", function()
        sampAddChatMessage("{FF8C00}[Stats] Ручная отправка данных...", 0xFF8C00)
        local pingAvg    = statsPingSamples > 0 and math.floor(statsPingSum / statsPingSamples + 0.5) or currentPing
        local caughtSnap = statsCaughtDelta
        local missedSnap = statsMissedDelta
        local activeSnap = statsActiveSeconds
        statsPingSum = 0; statsPingSamples = 0
        statsCaughtDelta = 0; statsMissedDelta = 0; statsActiveSeconds = 0
        runStatsUpdate(playerName, pingAvg, caughtSnap, missedSnap, activeSnap)
    end)

    lua_thread.create(function()
        while true do
            wait(0)
            if not sampIsChatInputActive() then
                if waitingForKey then
                    local key = getPressedKey()
                    if key then
                        SPAM_KEY = key
                        saveSettings()
                        waitingForKey = false
                        sampAddChatMessage("Клавиша активации изменена на: {FFD700}"..vkeys.id_to_name(SPAM_KEY), 0xFF8C00)
                    end
                elseif wasKeyPressed(SPAM_KEY) then
                    if checkAndWarn() then needToggle = true end
                end
            end
        end
    end)

    lua_thread.create(function()
        local prevCaught, prevWinOpen = false, false
        while true do
            wait(100)
            if active then
                local caught  = isReportCaught()
                local winOpen = isReportWindowOpen()
                if (caught and not prevCaught) or (winOpen and not prevWinOpen) then
                    active = false
                    if spamThread then spamThread.status = "dead"; spamThread = nil end
                    sampAddChatMessage("Репорт {FFD700}пойман! {FF8C00}Ловля остановлена автоматически.", 0xFF8C00)
                    notifyIfMinimized()
                    triggerCatchAnimation()
                end
                prevCaught  = caught
                prevWinOpen = winOpen
            else
                prevCaught  = false
                prevWinOpen = false
            end
        end
    end)

    while true do
        wait(0)
        if needToggle then
            needToggle = false
            active = not active
            if active then
                startTime     = os.time()
                commandCount  = 0
                attemptsCount = 0
                attemptsDisplay   = 0
                attemptsFrom      = 0
                attemptsTo        = 0
                antifloodPause = false
                catchAnim.active = false
                initTimerFlip("00:00")
                initPingFlip(tostring(currentPing))
                showWindow[0] = true
                triggerSlideAnim()
                playSound(sounds.enable)
                lastSpamTime = getTickCount()
                spamThread = lua_thread.create(spamFunction)
            else
                catchAnim.active = false
                notifyAnim.active = false
                notifyAnim.ending = false
                notifyAnim2.active = false
                notifyAnim2.ending = false
                if spamThread then spamThread.status = "dead"; spamThread = nil end
                triggerSlideOutAnim()
                playSound(sounds.disable)
            end
        end
    end
end

function cmdSetPos()
    settingPosition = true
    showWindow[0] = true
    sampAddChatMessage("Переместите окно мышью и нажмите ЛКМ для сохранения позиции", 0xFF8C00)
end

function cmdSetKey()
    if not checkAndWarn() then return end
    waitingForKey = true
    sampAddChatMessage("Нажмите клавишу, которую хотите назначить для активации...", 0xFF8C00)
end

function loadSettings()
    if doesFileExist(SETTINGS_FILE) then
        local file = io.open(SETTINGS_FILE, "r")
        if file then
            for line in file:lines() do
                local key, value = line:match("^([^=]+)=(.+)$")
                if key and value then
                    key   = key:gsub("^%s*(.-)%s*$", "%1")
                    value = value:gsub("^%s*(.-)%s*$", "%1")
                    if     key == "WINDOW_X" then window.x = tonumber(value) or window.x
                    elseif key == "WINDOW_Y" then window.y = tonumber(value) or window.y
                    elseif key == "SPAM_KEY" then SPAM_KEY = tonumber(value) or SPAM_KEY
                    end
                end
            end
            file:close()
        end
    end
end

function saveSettings()
    local file = io.open(SETTINGS_FILE, "w")
    if file then
        file:write("WINDOW_X=" .. window.x .. "\n")
        file:write("WINDOW_Y=" .. window.y .. "\n")
        file:write("SPAM_KEY=" .. SPAM_KEY .. "\n")
        file:close()
    end
end

function getPressedKey()
    for key = 1, 256 do
        if isKeyDown(key) then
            while isKeyDown(key) do wait(0) end
            return key
        end
    end
    return nil
end

function sampev.onServerMessage(color, text)
    if not freeMode then
        if text:find('Сейчас нет вопросов в репорт') then return false end
    end

    if active then
        if not freeMode then
            if text:find('Не флуди') or text:find('флуд') or (text:find('%[Ошибка%]') and text:find('флуд')) then
                if not antifloodPause then
                    antifloodPause = true
                    local afSlot = (notifyAnim.active or notifyAnim.ending) and notifyAnim2 or notifyAnim
                    showNotify(u8"пауза: анти-флуд", 1.0, 0.8, 0.0, 0, false)
                    lua_thread.create(function()
                        wait(1500)
                        antifloodPause = false
                        hideNotify(afSlot)
                        lastSpamTime = getTickCount()
                    end)
                end
                return false
            end
            if text:find('%[(%W+)%] от (%w+_%w+)%[(%d+)%]:') then
                if not antifloodPause then
                    attemptsCount = attemptsCount + 1
                    triggerAttemptsAnim(attemptsCount)
                    local snapCount = attemptsCount
                    lua_thread.create(function()
                        wait(100)
                        if active and attemptsCount == snapCount and not catchAnim.active then
                            statsMissedDelta = statsMissedDelta + 1
                            showNotify(u8"пропустили репорт", 1.0, 0.32, 0.32, 2800, false)
                        end
                    end)
                    sampSendChat(SPAM_CMD)
                    commandCount = commandCount + 1
                end
            end
        else
            if text:find('%[(%W+)%] от (%w+_%w+)%[(%d+)%]:') then
                lua_thread.create(function()
                    wait(100)
                    if active then
                        attemptsCount = attemptsCount + 1
                        triggerAttemptsAnim(attemptsCount)
                        local snapCount = attemptsCount
                        lua_thread.create(function()
                            wait(100)
                            if active and attemptsCount == snapCount and not catchAnim.active then
                                statsMissedDelta = statsMissedDelta + 1
                                showNotify(u8"пропустили репорт", 1.0, 0.32, 0.32, 2800, false)
                            end
                        end)
                        sampSendChat(SPAM_CMD)
                        commandCount = commandCount + 1
                    end
                end)
            end
        end
    end
end

function spamFunction()
    local spamCount    = freeMode and FREE_SPAM_COUNT    or SPAM_COUNT
    local spamDelay    = freeMode and FREE_SPAM_DELAY    or SPAM_DELAY
    local spamInterval = freeMode and FREE_SPAM_INTERVAL or SPAM_INTERVAL

    while active do
        local canSpam = freeMode or (not antifloodPause)
        if canSpam then
            local currentTime = getTickCount()
            if currentTime - lastSpamTime >= spamInterval then
                lastSpamTime = currentTime
                for i = 1, spamCount do
                    if not active then break end
                    sampSendChat(SPAM_CMD)
                    commandCount = commandCount + 1
                    if i < spamCount then wait(spamDelay) end
                end
                local startWait = getTickCount()
                while active and (getTickCount() - startWait) < spamInterval do wait(50) end
            end
        end
        wait(0)
    end
end

function wasKeyPressed(key)
    if isKeyDown(key) then
        while isKeyDown(key) do wait(0) end
        return true
    end
    return false
end

function getTickCount()
    return os.clock() * 1000
end