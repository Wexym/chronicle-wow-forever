-- Общие функции: время сервера, ключи дней.
local ADDON, ns = ...

-- Ключ дня ГГГГ-ММ-ДД по времени сервера.
-- date() считает по часовому поясу компьютера, поэтому берём календарь сервера.
function ns.ServerDayKey()
    if C_DateAndTime and C_DateAndTime.GetCurrentCalendarTime then
        local t = C_DateAndTime.GetCurrentCalendarTime()
        if t and t.year then
            return string.format("%04d-%02d-%02d", t.year, t.month, t.monthDay)
        end
    end
    -- Запасной вариант: UTC. Может отличаться от серверной даты на несколько часов.
    return date("!%Y-%m-%d", GetServerTime())
end

-- Нижний регистр с учётом кириллицы в UTF-8 (string.lower её не понимает)
function ns.Lower(s)
    if not s or s == "" then return "" end
    s = s:gsub("\208([\144-\159])", function(c) return "\208" .. string.char(c:byte() + 32) end) -- А–П
    s = s:gsub("\208([\160-\175])", function(c) return "\209" .. string.char(c:byte() - 32) end) -- Р–Я
    s = s:gsub("\208\129", "\209\145")                                                          -- Ё
    return s:lower()
end

-- Безопасная проверка наличия функции API по пути вроде "C_DateAndTime.GetSecondsUntilWeeklyReset"
function ns.HasAPI(path)
    local obj = _G
    for part in path:gmatch("[^%.]+") do
        if type(obj) ~= "table" then return false end
        obj = obj[part]
        if obj == nil then return false end
    end
    return type(obj) == "function"
end

---------------------------------------------------------------------------
-- Время до сбросов
---------------------------------------------------------------------------

-- Календарь сервера: год, месяц, число, день недели (1 = воскресенье), час, минута
local function ServerClock()
    local t = C_DateAndTime and C_DateAndTime.GetCurrentCalendarTime and C_DateAndTime.GetCurrentCalendarTime()
    if t and t.year then return t.year, t.month, t.monthDay, t.weekday, t.hour, t.minute end
    local u = date("!*t", GetServerTime())   -- запасной вариант: UTC
    return u.year, u.month, u.day, u.wday, u.hour, u.min
end

local function DaysInMonth(y, m)
    if m == 2 and (y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)) then return 29 end
    return ({ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 })[m]
end

-- Секунд до ближайшего сброса периода: "day", "week" или "month".
-- Сначала берём игровые функции, если их нет — считаем по календарю сервера и настройкам.
function ns.SecondsUntil(period)
    if period == "day" and GetQuestResetTime then
        local s = GetQuestResetTime()
        if s and s > 0 then return s end
    elseif period == "week" and C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset then
        local s = C_DateAndTime.GetSecondsUntilWeeklyReset()
        if s and s > 0 then return s end
    end
    local y, m, d, wd, h, mi = ServerClock()
    local sinceMidnight = h * 3600 + mi * 60 + GetServerTime() % 60
    local resetHour = ns.db and ns.db.settings.weeklyHour or 4
    if period == "day" then
        local diff = resetHour * 3600 - sinceMidnight
        if diff <= 0 then diff = diff + 86400 end
        return diff
    elseif period == "week" then
        local resetDay = ns.db and ns.db.settings.weeklyDay or 4
        local diff = (resetDay - 1) * 86400 + resetHour * 3600 - ((wd - 1) * 86400 + sinceMidnight)
        if diff <= 0 then diff = diff + 604800 end
        return diff
    else
        return (DaysInMonth(y, m) - d) * 86400 + 86400 - sinceMidnight
    end
end

-- Сдвиг серверного времени от UTC в секундах (по календарю сервера)
function ns.ServerOffset()
    local _, _, _, _, h, mi = ServerClock()
    local u = date("!*t", GetServerTime())
    local diff = (h * 3600 + mi * 60) - (u.hour * 3600 + u.min * 60)
    if diff > 43200 then diff = diff - 86400 elseif diff < -43200 then diff = diff + 86400 end
    return diff
end

local MINSK_OFFSET = 3 * 3600   -- Минск: UTC+3 круглый год

-- Момент времени (unix) в двух видах: по Минску и по серверу
function ns.FormatBoth(ts, fmt)
    local minsk = date("!" .. fmt, ts + MINSK_OFFSET)
    local server = date("!" .. fmt, ts + ns.ServerOffset())
    return ns.L["time_both"]:format(minsk, server)
end

-- Ключ дня ГГГГ-ММ-ДД по времени сервера, i дней назад (0 — сегодня)
function ns.DayKeyBack(i)
    return date("!%Y-%m-%d", GetServerTime() + ns.ServerOffset() - i * 86400)
end

-- Число с пробелами между тысячами: 1 234 567
function ns.FormatNumber(n)
    local s = tostring(math.floor(n + 0.5))
    local r
    repeat s, r = s:gsub("^(-?%d+)(%d%d%d)", "%1 %2") until r == 0
    return s
end

-- Деньги значками золота, серебра и меди (GetCoinTextureString в этом клиенте нет)
local function CoinString(c)
    local g = math.floor(c / 10000)
    local sv = math.floor(c % 10000 / 100)
    local cp = c % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = ns.FormatNumber(g) .. "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t" end
    if sv > 0 or g > 0 then parts[#parts + 1] = sv .. "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t" end
    parts[#parts + 1] = cp .. "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"
    return table.concat(parts, " ")
end

function ns.FormatMoney(c)
    c = math.floor(c + 0.5)
    if c == 0 then return "0" end
    if c < 0 then return "-" .. CoinString(-c) end
    return CoinString(c)
end

-- «1 д 6 ч», «6 ч 12 мин», «12 мин»
function ns.FormatDuration(secs)
    secs = math.max(0, math.floor(secs))
    local d = math.floor(secs / 86400)
    local h = math.floor((secs % 86400) / 3600)
    local m = math.floor((secs % 3600) / 60)
    local L = ns.L
    if d > 0 then return L["dur_dh"]:format(d, h) end
    if h > 0 then return L["dur_hm"]:format(h, m) end
    return L["dur_m"]:format(math.max(1, m))
end
