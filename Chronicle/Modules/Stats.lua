-- Вкладка «Статистика»: сбор игровых показателей и их показ за сессию, день, неделю и месяц.
local ADDON, ns = ...
local L = ns.L
local UI = ns.UI

local S = {}
ns.Stats = S

local KEEP_DAYS = 90        -- дневные корзины старше этого сворачиваются в месячные
local TICK = 30             -- как часто учитывать время в игре, секунд
local PERIOD_DAYS = { day = 1, week = 7, month = 30 }
local PERIODS = { "session", "day", "week", "month" }
local RARE_COLORS = {       -- цвета ссылок на предметы: редкий и выше
    ["0070dd"] = true, ["a335ee"] = true, ["ff8000"] = true, ["e6cc80"] = true, ["00ccff"] = true,
}

---------------------------------------------------------------------------
-- Сбор данных
---------------------------------------------------------------------------

local cur = {}              -- cur.day — ключ дня, cur.bucket — корзина этого дня
local dirty = false         -- данные изменились, экран надо обновить

local function RefreshDay()
    local day = ns.DayKeyBack(0)
    if day == cur.day then return end
    cur.day = day
    local days = ns.db.stats.days
    days[ns.charKey] = days[ns.charKey] or {}
    local bucket = days[ns.charKey][day]
    if not bucket then
        bucket = {}
        days[ns.charKey][day] = bucket
    end
    cur.bucket = bucket
end

-- Прибавить к дневной корзине и к сессии. Здесь только запись в таблицы, без создания строк.
local function Add(field, n)
    local b = cur.bucket
    if not b then return end
    b[field] = (b[field] or 0) + n
    local s = ns.cdb.session
    s[field] = (s[field] or 0) + n
    dirty = true
end
S.Add = Add

local function NewSession()
    ns.cdb.session = { startTime = GetServerTime() }
    dirty = true
end

function S.ResetSession()
    NewSession()
    ns.Say(L["stats_session_reset"])
end

-- Сворачивание старых дней в месяцы, чтобы файл не рос
local function Prune()
    local cutoff = ns.DayKeyBack(KEEP_DAYS)
    for char, days in pairs(ns.db.stats.days) do
        for day, bucket in pairs(days) do
            if day < cutoff then
                local months = ns.db.stats.months
                months[char] = months[char] or {}
                local ym = day:sub(1, 7)
                local m = months[char][ym] or {}
                months[char][ym] = m
                for field, v in pairs(bucket) do m[field] = (m[field] or 0) + v end
                days[day] = nil
            end
        end
    end
end

-- Состояние для расчёта разницы
local last = { xp = 0, xpMax = 0, money = 0, tick = 0 }
local maxLevel = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60

local function AtMaxLevel()
    return UnitLevel("player") >= maxLevel
end

local function Baseline()
    last.xp, last.xpMax, last.money = UnitXP("player"), UnitXPMax("player"), GetMoney()
end

local function FlushPlayed()
    local now = GetTime()
    local dt = now - last.tick
    last.tick = now
    if dt > 0 and dt < 3600 then Add("played", dt) end
end

-- Префиксы строк о своей добыче берём из глобальных строк клиента, чтобы не зависеть от языка
local lootPrefixes = {}
for _, name in ipairs({ "LOOT_ITEM_SELF", "LOOT_ITEM_PUSHED_SELF", "LOOT_ITEM_CREATED_SELF" }) do
    local fmt = _G[name]
    local prefix = fmt and fmt:match("^(.-)%%[%d%$]*s")
    if prefix and prefix ~= "" then lootPrefixes[#lootPrefixes + 1] = prefix end
end

-- Другие модули подписываются на свою добычу: fn(сообщение, цвет ссылки)
S.lootHooks = {}

local function OnLoot(msg)
    for _, prefix in ipairs(lootPrefixes) do
        if msg:find(prefix, 1, true) == 1 then
            local count = tonumber(msg:match("|rx(%d+)")) or 1
            Add("loot", count)
            local color = msg:match("|c%x%x(%x%x%x%x%x%x)|Hitem")
            if color and RARE_COLORS[color] then Add("lootRare", count) end
            for _, fn in ipairs(S.lootHooks) do fn(msg, color) end
            return
        end
    end
end

local playerGUID

ns:OnLogin(function()
    playerGUID = UnitGUID("player")
    RefreshDay()
    Prune()
    Baseline()
    last.tick = GetTime()
    if not ns.cdb.session.startTime then NewSession() end

    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:RegisterEvent("PLAYER_XP_UPDATE")
    f:RegisterEvent("PLAYER_MONEY")
    f:RegisterEvent("QUEST_TURNED_IN")
    f:RegisterEvent("CHAT_MSG_LOOT")
    f:RegisterEvent("PLAYER_DEAD")
    f:RegisterEvent("PLAYER_LOGOUT")
    f:RegisterEvent("TIME_PLAYED_MSG")
    f:SetScript("OnEvent", function(_, event, arg1, arg2, _, _, _, _, _, _, _, _, _, guid)
        if event == "PLAYER_XP_UPDATE" then
            if AtMaxLevel() then return end
            local xp, xpMax = UnitXP("player"), UnitXPMax("player")
            local gain
            if xp < last.xp or xpMax ~= last.xpMax then
                gain = last.xpMax - last.xp + xp        -- перешли на новый уровень
            else
                gain = xp - last.xp
            end
            last.xp, last.xpMax = xp, xpMax
            if gain > 0 then Add("xp", gain) end
        elseif event == "PLAYER_MONEY" then
            local money = GetMoney()
            local diff = money - last.money
            last.money = money
            if diff > 0 then Add("goldIn", diff) elseif diff < 0 then Add("goldOut", -diff) end
        elseif event == "QUEST_TURNED_IN" then
            Add("quests", 1)
        elseif event == "CHAT_MSG_LOOT" then
            if guid == playerGUID then OnLoot(arg1) end
        elseif event == "PLAYER_DEAD" then
            Add("deaths", 1)
        elseif event == "PLAYER_ENTERING_WORLD" then
            -- arg1 — первый вход в игру, arg2 — /reload. Сессию прерывает только новый вход.
            if arg1 then NewSession() end
            RefreshDay()
            Baseline()
            local _, instType, _, _, _, _, _, instID = GetInstanceInfo()
            local s = ns.cdb.session
            if instType == "party" or instType == "raid" then
                if s.inInstance ~= instID then
                    s.inInstance = instID
                    Add("instances", 1)
                end
            else
                s.inInstance = nil
            end
        elseif event == "PLAYER_LOGOUT" then
            FlushPlayed()
        elseif event == "TIME_PLAYED_MSG" then
            ns.cdb.timePlayed = { total = arg1, at = GetServerTime() }
        end
    end)

    -- Убитые мобы. Обработчик журнала боя вызывается на каждое событие, поэтому он минимален:
    -- сравнение GUID и счётчик.
    if CombatLogGetCurrentEventInfo then
        local cl = CreateFrame("Frame")
        cl:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
        cl:SetScript("OnEvent", function()
            local _, sub, _, src, srcName, _, _, dest, _, _, _, extra = CombatLogGetCurrentEventInfo()
            if sub == "PARTY_KILL" then
                if src == playerGUID then Add("kills", 1) end
            elseif dest == playerGUID then
                -- Запоминаем, кто бил игрока последним: нужно журналу для записи о смерти
                if sub == "ENVIRONMENTAL_DAMAGE" then
                    S.lastDamager, S.lastDamagerTime = extra, GetTime()
                elseif srcName and sub:find("_DAMAGE", 1, true) then
                    S.lastDamager, S.lastDamagerTime = srcName, GetTime()
                end
            end
        end)
    else
        ns.Say(L["stats_no_clog"])
    end

    C_Timer.NewTicker(TICK, function()
        RefreshDay()
        FlushPlayed()
    end)
end)

---------------------------------------------------------------------------
-- Расчёт показателей
---------------------------------------------------------------------------

local state = { period = "day", char = nil, metric = "played", range = 7 }
local ui = {}

local function CharList()
    local list, seen = {}, {}
    if ns.charKey then list[1], seen[ns.charKey] = ns.charKey, true end
    local rest = {}
    for key in pairs(ns.db.stats.days) do
        if not seen[key] then rest[#rest + 1] = key end
    end
    table.sort(rest)
    for _, k in ipairs(rest) do list[#list + 1] = k end
    return list
end

local function SelectedChars()
    if state.char == "ALL" then return CharList() end
    return { state.char or ns.charKey }
end

-- Сколько задач чеклиста выполнено за дни keys (из истории сбросов)
local function TasksDone(keys, chars, includeAccount)
    local set = {}
    for _, k in ipairs(keys) do set[k] = true end
    local sum = 0
    local scopes = {}
    for _, c in ipairs(chars) do scopes[#scopes + 1] = c end
    if includeAccount then scopes[#scopes + 1] = "account" end
    for _, scope in ipairs(scopes) do
        for _, e in ipairs(ns.db.checklistHistory[scope] or {}) do
            if set[e.day] then sum = sum + e.done end
        end
    end
    return sum
end

-- Функция get(поле) → сумма за указанные дни по выбранным персонажам
local function DaysGetter(keys)
    local chars = SelectedChars()
    local all = state.char == "ALL"
    local tasks
    return function(field)
        if field == "tasks" then
            tasks = tasks or TasksDone(keys, chars, all)
            return tasks
        end
        local sum = 0
        for _, c in ipairs(chars) do
            local days = ns.db.stats.days[c]
            if days then
                for _, k in ipairs(keys) do
                    local t = days[k]
                    if t then sum = sum + (t[field] or 0) end
                end
            end
        end
        return sum
    end
end

local function PeriodGetter()
    if state.period == "session" then
        local s = ns.cdb.session
        return function(field) return s[field] or 0 end
    end
    local keys = {}
    for i = 0, PERIOD_DAYS[state.period] - 1 do keys[#keys + 1] = ns.DayKeyBack(i) end
    return DaysGetter(keys)
end

local function Xph(get)
    local played = get("played")
    if played < 60 then return 0 end
    return get("xp") / (played / 3600)
end

-- Показатели. value(get) → число; fmt — как показывать; hideAtMax — скрывать на максимальном уровне.
local METRICS = {
    { key = "played",    fmt = "time",  value = function(g) return g("played") end },
    { key = "xp",        fmt = "num",   xp = true, value = function(g) return g("xp") end },
    { key = "xph",       fmt = "num",   xp = true, value = Xph },
    { key = "ttl",       fmt = "ttl",   xp = true, noChart = true },
    { key = "goldIn",    fmt = "money", value = function(g) return g("goldIn") end },
    { key = "goldOut",   fmt = "money", value = function(g) return g("goldOut") end },
    { key = "goldNet",   fmt = "money", value = function(g) return g("goldIn") - g("goldOut") end },
    { key = "kills",     fmt = "num",   value = function(g) return g("kills") end },
    { key = "quests",    fmt = "num",   value = function(g) return g("quests") end },
    { key = "loot",      fmt = "num",   value = function(g) return g("loot") end },
    { key = "lootRare",  fmt = "num",   value = function(g) return g("lootRare") end },
    { key = "deaths",    fmt = "num",   value = function(g) return g("deaths") end },
    { key = "dangers",   fmt = "num",   value = function(g) return g("dangers") end },
    { key = "instances", fmt = "num",   value = function(g) return g("instances") end },
    { key = "tasks",     fmt = "num",   value = function(g) return g("tasks") end },
}

local FormatNumber = ns.FormatNumber
local FormatMoney = ns.FormatMoney

local function FormatTime(secs)
    secs = math.floor(secs)
    local h, m = math.floor(secs / 3600), math.floor(secs % 3600 / 60)
    if h > 0 then return L["hours_minutes"]:format(h, m) end
    return L["minutes"]:format(m)
end

local function FormatValue(metric, v)
    if v == nil then return "—" end
    if metric.fmt == "time" then return FormatTime(v) end
    if metric.fmt == "money" then return FormatMoney(v) end
    if metric.fmt == "ttl" then return FormatTime(v) end
    return FormatNumber(v)
end

-- «До уровня»: оставшийся опыт, делённый на опыт в час за выбранный период (только для текущего персонажа)
local function TimeToLevel(get)
    if state.char == "ALL" or (state.char and state.char ~= ns.charKey) or AtMaxLevel() then return nil end
    local rate = Xph(get)
    if rate <= 0 then return nil end
    local left = UnitXPMax("player") - UnitXP("player")
    return left / rate * 3600
end

local function MetricVisible(m)
    if not m.xp then return true end
    local isCurrent = state.char == nil or state.char == ns.charKey
    if m.key == "ttl" then return isCurrent and not AtMaxLevel() end
    return not (isCurrent and AtMaxLevel())   -- на максимальном уровне опыт не показываем
end

---------------------------------------------------------------------------
-- Экран
---------------------------------------------------------------------------

local COLS, CARD_H = 5, 50

local function MetricByKey(key)
    for _, m in ipairs(METRICS) do if m.key == key then return m end end
end

local function UpdateChart()
    local m = MetricByKey(state.metric)
    local chart = ui.chart
    if not chart then return end
    for _, bar in ipairs(chart.bars) do bar:Hide() end
    if not m or not MetricVisible(m) or m.noChart then
        chart.title:SetText(L["stats_no_chart"])
        return
    end
    local n = state.range
    chart.title:SetText(L["stats_chart"]:format(L["stat_" .. m.key], n))
    local values, maxV = {}, 0
    for i = 1, n do
        local day = ns.DayKeyBack(n - i)
        local v = m.value(DaysGetter({ day }))
        values[i] = { day = day, v = v }
        if v > maxV then maxV = v end
    end
    local w = chart.area:GetWidth()
    local h = chart.area:GetHeight()
    local bw = math.max(2, (w - 4) / n - 2)
    for i = 1, n do
        local bar = chart.bars[i]
        if not bar then
            bar = CreateFrame("Frame", nil, chart.area)
            bar.tex = bar:CreateTexture(nil, "ARTWORK")
            bar.tex:SetAllPoints()
            bar.label = bar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            bar.label:SetPoint("TOP", bar, "BOTTOM", 0, -1)
            bar:EnableMouse(true)
            bar:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:AddLine(self.day)
                GameTooltip:AddLine(self.text, 1, 1, 1)
                GameTooltip:Show()
            end)
            bar:SetScript("OnLeave", function() GameTooltip:Hide() end)
            chart.bars[i] = bar
        end
        local d = values[i]
        local pos = d.v > 0 and d.v or 0
        local bh = maxV > 0 and math.max(1, (h - 16) * pos / maxV) or 1
        bar:ClearAllPoints()
        bar:SetPoint("BOTTOMLEFT", chart.area, "BOTTOMLEFT", 2 + (i - 1) * (bw + 2), 14)
        bar:SetSize(bw, bh)
        bar.tex:SetColorTexture(d.v < 0 and 0.8 or 0.2, d.v < 0 and 0.3 or 0.6, d.v < 0 and 0.3 or 1, 0.9)
        bar.day = d.day
        bar.text = FormatValue(m, d.v)
        bar.label:SetText(n <= 7 and d.day:sub(9, 10) or ((i % 2 == 1) and d.day:sub(9, 10) or ""))
        bar:Show()
    end
end

local function UpdateAll()
    if not ui.root then return end
    dirty = false
    if not state.char then state.char = ns.charKey end

    for _, p in ipairs(PERIODS) do
        if p == state.period then ui.periodBtn[p]:LockHighlight() else ui.periodBtn[p]:UnlockHighlight() end
    end
    local charName = state.char == "ALL" and L["stats_all_chars"] or (state.char:match("^(.-)%-") or state.char)
    ui.btnChar:SetText(L["stats_char"]:format(charName))
    ui.btnRange:SetText(L["stats_range"]:format(state.range))

    local get = PeriodGetter()
    local shown = 0
    for _, m in ipairs(METRICS) do
        local card = ui.cards[m.key]
        if MetricVisible(m) then
            local v
            if m.key == "ttl" then v = TimeToLevel(get) else v = m.value(get) end
            card.value:SetText(FormatValue(m, v))
            card:ClearAllPoints()
            local col, row = shown % COLS, math.floor(shown / COLS)
            card:SetPoint("TOPLEFT", ui.cardsArea, "TOPLEFT", col * ui.cardW, -row * (CARD_H + 4))
            card:SetWidth(ui.cardW - 4)
            card:Show()
            shown = shown + 1
            if card.SetBackdropBorderColor then
                if m.key == state.metric then card:SetBackdropBorderColor(1, 0.82, 0)
                else card:SetBackdropBorderColor(0.6, 0.6, 0.6) end
            end
        else
            card:Hide()
        end
    end

    local tp = ns.cdb.timePlayed
    if tp and (state.char == nil or state.char == ns.charKey) then
        ui.total:SetText(L["stats_total_played"]:format(FormatTime(tp.total), ns.FormatBoth(tp.at, "%d.%m.%Y")))
    else
        ui.total:SetText("")
    end
    UpdateChart()
end

local function Create(frame)
    ui.root = frame
    state.char = state.char or ns.charKey

    -- Период
    ui.periodBtn = {}
    local prev
    for _, p in ipairs(PERIODS) do
        local b = UI.CreateButton(frame, L["stats_" .. p], 85, 22, function()
            state.period = p
            UpdateAll()
        end)
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 2, 0) else b:SetPoint("TOPLEFT", 4, -4) end
        ui.periodBtn[p] = b
        prev = b
    end

    -- Выбор персонажа: по кругу «текущий → остальные → все»
    ui.btnChar = UI.CreateButton(frame, "", 190, 22, function()
        local list = CharList()
        list[#list + 1] = "ALL"
        local idx = 1
        for i, k in ipairs(list) do if k == state.char then idx = i end end
        state.char = list[idx % #list + 1]
        UpdateAll()
    end)
    ui.btnChar:SetPoint("LEFT", prev, "RIGHT", 8, 0)

    ui.btnReset = UI.CreateButton(frame, L["stats_reset_session"], 150, 22, function()
        S.ResetSession()
        UpdateAll()
    end)
    ui.btnReset:SetPoint("TOPLEFT", 4, -30)
    ui.btnRange = UI.CreateButton(frame, "", 110, 22, function()
        state.range = state.range == 7 and 30 or 7
        UpdateAll()
    end)
    ui.btnRange:SetPoint("LEFT", ui.btnReset, "RIGHT", 2, 0)
    ui.total = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.total:SetPoint("LEFT", ui.btnRange, "RIGHT", 10, 0)

    -- Карточки
    ui.cardsArea = CreateFrame("Frame", nil, frame)
    ui.cardsArea:SetPoint("TOPLEFT", 4, -58)
    ui.cardsArea:SetPoint("TOPRIGHT", -4, -58)
    ui.cardsArea:SetHeight(3 * (CARD_H + 4))
    ui.cardW = 110
    ui.cards = {}
    for _, m in ipairs(METRICS) do
        local card = UI.CreateBox(ui.cardsArea)
        card:EnableMouse(true)
        card:SetHeight(CARD_H)
        card.title = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        card.title:SetPoint("TOPLEFT", 6, -6)
        card.title:SetPoint("TOPRIGHT", -6, -6)
        card.title:SetJustifyH("LEFT")
        card.title:SetText(L["stat_" .. m.key])
        card.value = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
        card.value:SetPoint("BOTTOMLEFT", 6, 8)
        card.value:SetPoint("BOTTOMRIGHT", -6, 8)
        card.value:SetJustifyH("LEFT")
        card:SetScript("OnMouseUp", function()
            state.metric = m.key
            UpdateAll()
        end)
        ui.cards[m.key] = card
    end
    ui.cardsArea:SetScript("OnSizeChanged", function(self, w)
        ui.cardW = math.floor(w / COLS)
        UpdateAll()
    end)

    -- График
    local chart = UI.CreateBox(frame)
    chart:SetPoint("TOPLEFT", 4, -58 - 3 * (CARD_H + 4) - 2)
    chart:SetPoint("BOTTOMRIGHT", -4, 4)
    chart.title = chart:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    chart.title:SetPoint("TOPLEFT", 8, -6)
    chart.area = CreateFrame("Frame", nil, chart)
    chart.area:SetPoint("TOPLEFT", 6, -24)
    chart.area:SetPoint("BOTTOMRIGHT", -6, 4)
    chart.bars = {}
    chart.area:SetScript("OnSizeChanged", function() if ui.root:IsVisible() then UpdateChart() end end)
    ui.chart = chart

    -- Обновление, пока вкладка видна
    local acc = 0
    frame:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + elapsed
        if acc >= 2 then
            acc = 0
            if dirty then UpdateAll() end
        end
    end)
    frame:SetScript("OnShow", UpdateAll)
    UpdateAll()
end

ns.refresh.stats = function()
    cur.day = nil          -- старые корзины удалены, заводим новую на сегодня
    RefreshDay()
    NewSession()
    UpdateAll()
end

ns:RegisterModule("stats", "tab_stats", nil, Create)
