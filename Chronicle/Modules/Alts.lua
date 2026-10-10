-- Вкладка «Альты»: сводка по всем персонажам аккаунта.
local ADDON, ns = ...
local L = ns.L
local UI = ns.UI

local A = {}
ns.Alts = A

local ROW_H = 62
local REST_PER_HOUR_INN = 5 / 8      -- бонус отдыха в % уровня за час, если вышли из игры в городе или таверне
local REST_PER_HOUR_FIELD = 5 / 32   -- то же, если вышли «в поле»
local REST_CAP = 1.5                 -- бонус отдыха копится до 150% уровня

---------------------------------------------------------------------------
-- Сбор данных о текущем персонаже
---------------------------------------------------------------------------

-- Профессии: [{ name, rank, max }]. Клиент может отдавать их по-разному, поэтому пробуем оба способа.
local function ReadProfessions()
    local out = {}
    if GetProfessions and GetProfessionInfo then
        local a, b, c, d, e = GetProfessions()
        for _, idx in ipairs({ a or 0, b or 0, c or 0, d or 0, e or 0 }) do
            if idx > 0 then
                local name, _, rank, max = GetProfessionInfo(idx)
                if name then out[#out + 1] = { name = name, rank = rank, max = max } end
            end
        end
        return out
    elseif GetNumSkillLines and GetSkillLineInfo then
        local inProfessions = false
        for i = 1, GetNumSkillLines() do
            local name, isHeader, _, rank, _, _, max = GetSkillLineInfo(i)
            if isHeader then
                inProfessions = (name == TRADE_SKILLS or name == SECONDARY_SKILLS)
            elseif inProfessions and name then
                out[#out + 1] = { name = name, rank = rank, max = max }
            end
        end
        return out
    end
    return nil
end

local function Snapshot()
    local rec = ns.charKey and ns.db.characters[ns.charKey]
    if not rec then return end
    local _, classFile = UnitClass("player")
    rec.class = classFile
    rec.level = UnitLevel("player")
    rec.money = GetMoney()
    rec.place = ns.Players.CurrentPlace()
    rec.xpMax = UnitXPMax("player")
    rec.restXP = (GetXPExhaustion and GetXPExhaustion()) or 0
    rec.resting = IsResting() and true or false
    local profs = ReadProfessions()
    if profs then rec.profs = profs end
    if A.OnChanged then A.OnChanged() end
end

ns:OnLogin(function()
    local rec = ns.db.characters[ns.charKey]
    rec.loggedOut = nil      -- сейчас в игре
    Snapshot()
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_LOGOUT")
    f:RegisterEvent("PLAYER_LEVEL_UP")
    f:RegisterEvent("SKILL_LINES_CHANGED")
    f:RegisterEvent("PLAYER_UPDATE_RESTING")
    f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    f:SetScript("OnEvent", function(_, event)
        Snapshot()
        if event == "PLAYER_LOGOUT" then rec.loggedOut = GetServerTime() end
    end)
    C_Timer.NewTicker(60, Snapshot)
end)

---------------------------------------------------------------------------
-- Расчёты для показа
---------------------------------------------------------------------------

-- Бонус отдыха в процентах от уровня и признак «оценка». Для вышедших из игры — прогноз.
local function RestPercent(rec, isCurrent)
    if not rec.xpMax or rec.xpMax <= 0 then return nil end
    local rest = rec.restXP or 0
    if isCurrent then return rest / rec.xpMax * 100, false end
    if rec.loggedOut then
        local hours = math.max(0, GetServerTime() - rec.loggedOut) / 3600
        rest = rest + rec.xpMax * (rec.resting and REST_PER_HOUR_INN or REST_PER_HOUR_FIELD) / 100 * hours
    end
    return math.min(rest, rec.xpMax * REST_CAP) / rec.xpMax * 100, true
end

local function ClassColored(key)
    local rec = ns.db.characters[key]
    local name = key:match("^(.-)%-") or key
    local c = rec and rec.class and RAID_CLASS_COLORS[rec.class]
    if c then return string.format("|cff%02x%02x%02x%s|r", c.r * 255, c.g * 255, c.b * 255, name) end
    return name
end

local function SortedChars()
    local list = {}
    for key, rec in pairs(ns.db.characters) do
        if rec.level then list[#list + 1] = key end
    end
    table.sort(list, function(a, b)
        if (a == ns.charKey) ~= (b == ns.charKey) then return a == ns.charKey end
        local la, lb = ns.db.characters[a].level or 0, ns.db.characters[b].level or 0
        if la ~= lb then return la > lb end
        return a < b
    end)
    return list
end

---------------------------------------------------------------------------
-- Экран
---------------------------------------------------------------------------

local ui = {}
local view = {}

StaticPopupDialogs["CHRONICLE_FORGET_CHAR"] = {
    text = L["alts_forget_confirm"],
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, key)
        ns.db.characters[key] = nil
        if A.Refresh then A.Refresh() end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

function A.Refresh()
    if not ui.list then return end
    view = SortedChars()
    ui.list:SetCount(#view)
    ui.empty:SetShown(#view == 0)
    local total = 0
    for _, key in ipairs(view) do total = total + (ns.db.characters[key].money or 0) end
    ui.total:SetText(L["alts_total"]:format(ns.FormatMoney(total)))
end

local function SetupRow(row, idx)
    local key = view[idx]
    local rec = ns.db.characters[key]
    local isCurrent = key == ns.charKey
    row.key = key

    row.head:SetText(ClassColored(key) .. "  |cffffffff" .. L["alts_level"]:format(rec.level or 0) .. "|r"
        .. (isCurrent and ("  |cff888888" .. L["alts_current"] .. "|r") or ""))
    row.money:SetText(rec.money and ns.FormatMoney(rec.money) or "—")

    local place = (rec.place and rec.place ~= "") and rec.place or L["unknown"]
    if isCurrent then
        row.where:SetText(L["alts_online"]:format(place))
    elseif rec.loggedOut then
        row.where:SetText(L["alts_logout"]:format(place, ns.FormatBoth(rec.loggedOut, "%d.%m %H:%M")))
    else
        row.where:SetText(L["alts_logout_unknown"]:format(place))
    end

    local pct, estimate = RestPercent(rec, isCurrent)
    if pct then
        row.rest:SetText((estimate and L["alts_rest_est"] or L["alts_rest"]):format(pct))
    else
        row.rest:SetText("")
    end

    if rec.profs and #rec.profs > 0 then
        local parts = {}
        for _, p in ipairs(rec.profs) do
            parts[#parts + 1] = ("%s %d/%d"):format(p.name, p.rank or 0, p.max or 0)
        end
        row.profs:SetText(L["alts_profs"]:format(table.concat(parts, ", ")))
    else
        row.profs:SetText(L["alts_profs_none"])
    end
    row.forget:SetShown(not isCurrent)
end

local function Create(frame)
    ui.list = UI.CreateList(frame, ROW_H,
        function(row)
            row.bg = row:CreateTexture(nil, "BACKGROUND")
            row.bg:SetPoint("TOPLEFT", 0, -1)
            row.bg:SetPoint("BOTTOMRIGHT", 0, 1)
            row.bg:SetColorTexture(1, 1, 1, 0.05)

            row.head = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.head:SetPoint("TOPLEFT", 8, -6)
            row.head:SetJustifyH("LEFT")
            row.money = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            row.money:SetPoint("TOPRIGHT", -30, -6)
            row.money:SetJustifyH("RIGHT")

            row.where = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.where:SetPoint("TOPLEFT", 8, -24)
            row.where:SetJustifyH("LEFT")
            row.rest = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.rest:SetPoint("TOPRIGHT", -30, -24)
            row.rest:SetJustifyH("RIGHT")
            row.rest:SetTextColor(0.5, 0.7, 1)

            row.profs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.profs:SetPoint("TOPLEFT", 8, -42)
            row.profs:SetPoint("TOPRIGHT", -30, -42)
            row.profs:SetJustifyH("LEFT")
            row.profs:SetWordWrap(false)
            row.profs:SetTextColor(0.75, 0.75, 0.75)

            row.forget = CreateFrame("Button", nil, row, "UIPanelCloseButton")
            row.forget:SetSize(22, 22)
            row.forget:SetPoint("TOPRIGHT", 0, -2)
            row.forget:SetScript("OnClick", function()
                StaticPopup_Show("CHRONICLE_FORGET_CHAR", row.key:match("^(.-)%-") or row.key, nil, row.key)
            end)
        end,
        SetupRow)
    ui.list.frame:SetPoint("TOPLEFT", 4, -4)
    ui.list.frame:SetPoint("BOTTOMRIGHT", -4, 28)
    ui.empty = ui.list.frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    ui.empty:SetPoint("CENTER")
    ui.empty:SetText(L["alts_empty"])

    ui.total = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ui.total:SetPoint("BOTTOMLEFT", 8, 8)

    A.OnChanged = function()
        if frame:IsVisible() then A.Refresh() end
    end
    frame:SetScript("OnShow", A.Refresh)
    A.Refresh()
end

ns:RegisterModule("alts", "tab_alts", nil, Create)
