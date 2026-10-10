-- Вкладка «Хардкор»: счётчик опасных моментов и предупреждения о мобах выше уровнем.
local ADDON, ns = ...
local L = ns.L
local UI = ns.UI

local H = {}
ns.Hardcore = H

local LOG_LIMIT = 50
local DAY_KEEP = 60          -- сколько дней хранить счётчики по дням
local REARM_MARGIN = 20      -- после опасного момента следующий засчитывается, когда здоровье поднялось на столько % выше порога
local DAMAGER_WINDOW = 8     -- кого считать виновником: бил игрока не раньше чем столько секунд назад
local WARN_COOLDOWN = 30     -- не предупреждать об одном и том же мобе чаще, чем раз в столько секунд

---------------------------------------------------------------------------
-- Опасные моменты
---------------------------------------------------------------------------

local armed = true

local function RecordDanger(pct)
    local cfg = ns.cdb.hardcore
    cfg.total = cfg.total + 1
    local day = ns.DayKeyBack(0)
    cfg.byDay[day] = (cfg.byDay[day] or 0) + 1
    if ns.Stats and ns.Stats.Add then ns.Stats.Add("dangers", 1) end

    local by
    local S = ns.Stats
    if S and S.lastDamager and S.lastDamagerTime and GetTime() - S.lastDamagerTime <= DAMAGER_WINDOW then
        by = S.lastDamager
    end
    cfg.log[#cfg.log + 1] = { ts = GetServerTime(), pct = math.floor(pct), zone = ns.Players.CurrentPlace(), by = by }
    while #cfg.log > LOG_LIMIT do table.remove(cfg.log, 1) end

    if cfg.warnHealth then ns.Alert(L["hc_danger"]:format(pct), 1, 0.2, 0.2) end
    if H.OnChanged then H.OnChanged() end
end

-- Вызывается на каждое изменение здоровья, поэтому только арифметика и сравнение
local function OnHealth()
    local cfg = ns.cdb.hardcore
    if not cfg.enabled then return end
    if UnitIsDeadOrGhost("player") then armed = false return end
    local max = UnitHealthMax("player")
    if max <= 0 then return end
    local pct = UnitHealth("player") / max * 100
    if armed then
        if pct < cfg.dangerPct then
            armed = false
            RecordDanger(pct)
        end
    elseif pct >= math.min(100, cfg.dangerPct + REARM_MARGIN) then
        armed = true
    end
end

---------------------------------------------------------------------------
-- Мобы выше уровнем
---------------------------------------------------------------------------

-- На сколько уровней моб выше игрока (99 для «черепа» ??), либо nil, если юнит нам не интересен
local function LevelGap(unit)
    if not UnitExists(unit) or UnitIsPlayer(unit) or not UnitCanAttack("player", unit) or UnitIsDead(unit) then
        return nil
    end
    local level = UnitLevel(unit)
    if not level then return nil end
    if level == -1 then return 99 end
    return level - UnitLevel("player")
end

local warnedAt = {}
local warnedCount = 0

local function CheckUnit(unit)
    local cfg = ns.cdb.hardcore
    if not cfg.enabled or not cfg.warnTarget then return end
    local gap = LevelGap(unit)
    if not gap or gap < cfg.levelDiff then return end
    local guid = UnitGUID(unit)
    if not guid then return end
    local now = GetTime()
    if warnedAt[guid] and now - warnedAt[guid] < WARN_COOLDOWN then return end
    if warnedCount > 200 then wipe(warnedAt); warnedCount = 0 end   -- чтобы таблица не росла бесконечно
    warnedAt[guid] = now
    warnedCount = warnedCount + 1
    local name = UnitName(unit) or "?"
    if gap == 99 then
        ns.Alert(L["hc_mob_skull"]:format(name), 1, 0.2, 0.2)
    else
        ns.Alert(L["hc_mob_high"]:format(name, UnitLevel(unit), gap), 1, 0.6, 0.1)
    end
end

local function AddTooltipInfo(tooltip)
    if not ns.cdb or not ns.cdb.hardcore.enabled or tooltip ~= GameTooltip then return end
    local _, unit = tooltip:GetUnit()
    if not unit then return end
    local gap = LevelGap(unit)
    if gap and gap >= ns.cdb.hardcore.levelDiff then
        tooltip:AddLine(gap == 99 and L["hc_tip_skull"] or L["hc_tip"]:format(gap), 1, 0.3, 0.3)
        tooltip:Show()
    end
end

ns:OnLogin(function()
    local cfg = ns.cdb.hardcore
    -- Если клиент сам знает про хардкор — включаем режим, пока игрок не выбрал сам
    if cfg.enabled == nil then
        local ok, active = pcall(function() return C_GameRules and C_GameRules.IsHardcoreActive and C_GameRules.IsHardcoreActive() end)
        cfg.enabled = (ok and active) and true or false
    end
    -- Старые счётчики по дням не копим
    local cutoff = ns.DayKeyBack(DAY_KEEP)
    for day in pairs(cfg.byDay) do
        if day < cutoff then cfg.byDay[day] = nil end
    end

    local f = CreateFrame("Frame")
    if f.RegisterUnitEvent then f:RegisterUnitEvent("UNIT_HEALTH", "player") else f:RegisterEvent("UNIT_HEALTH") end
    f:RegisterEvent("PLAYER_TARGET_CHANGED")
    f:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:SetScript("OnEvent", function(_, event, unit)
        if event == "UNIT_HEALTH" then
            if unit == nil or unit == "player" then OnHealth() end
        elseif event == "PLAYER_TARGET_CHANGED" then
            CheckUnit("target")
        elseif event == "UPDATE_MOUSEOVER_UNIT" then
            CheckUnit("mouseover")
        else
            -- Вход в мир: считаем, что здоровье в порядке, и ждём следующего падения
            armed = true
        end
    end)

    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tt)
            pcall(AddTooltipInfo, tt)
        end)
    else
        GameTooltip:HookScript("OnTooltipSetUnit", function(tt) pcall(AddTooltipInfo, tt) end)
    end
end)

---------------------------------------------------------------------------
-- Интерфейс
---------------------------------------------------------------------------

local ui = {}
local sync = {}
local view = {}

local function Stepper(parent, y, fmt, field, min, max, step)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    local function Set(v)
        local cfg = ns.cdb.hardcore
        v = math.min(max, math.max(min, v))
        cfg[field] = v
        label:SetText(fmt:format(v))
    end
    local minus = UI.CreateButton(parent, "-", 26, 22, function() Set(ns.cdb.hardcore[field] - step) end)
    minus:SetPoint("TOPLEFT", 8, y)
    label:SetPoint("LEFT", minus, "RIGHT", 8, 0)
    label:SetWidth(170)
    label:SetJustifyH("CENTER")
    local plus = UI.CreateButton(parent, "+", 26, 22, function() Set(ns.cdb.hardcore[field] + step) end)
    plus:SetPoint("LEFT", label, "RIGHT", 8, 0)
    sync[#sync + 1] = function() label:SetText(fmt:format(ns.cdb.hardcore[field])) end
end

local function Check(parent, y, text, field)
    local cb = UI.CreateCheck(parent, 4, y, text, function(v)
        ns.cdb.hardcore[field] = v
        if H.OnChanged then H.OnChanged() end
    end)
    sync[#sync + 1] = function() cb:SetChecked(ns.cdb.hardcore[field]) end
end

function H.Refresh()
    if not ui.list then return end
    local cfg = ns.cdb.hardcore
    for _, fn in ipairs(sync) do fn() end
    ui.counts:SetText(L["hc_count_total"]:format(cfg.total) .. "\n"
        .. L["hc_count_today"]:format(cfg.byDay[ns.DayKeyBack(0)] or 0) .. "\n"
        .. L["hc_count_session"]:format(ns.cdb.session.dangers or 0))
    ui.off:SetShown(not cfg.enabled)
    wipe(view)
    for i = #cfg.log, 1, -1 do view[#view + 1] = cfg.log[i] end   -- новые сверху
    ui.list:SetCount(#view)
    ui.empty:SetShown(#view == 0)
end

local function SetupRow(row, idx)
    local e = view[idx]
    row.when:SetText(ns.FormatBoth(e.ts, "%d.%m %H:%M"))
    local text = L["hc_log_line"]:format(e.pct, (e.zone and e.zone ~= "") and e.zone or L["unknown"])
    if e.by then text = text .. L["hc_log_by"]:format(e.by) end
    row.what:SetText(text)
end

local function Create(frame)
    local left = CreateFrame("Frame", nil, frame)
    left:SetPoint("TOPLEFT", 4, -4)
    left:SetPoint("BOTTOMRIGHT", frame, "BOTTOM", -4, 4)
    local right = CreateFrame("Frame", nil, frame)
    right:SetPoint("TOPLEFT", frame, "TOP", 4, -4)
    right:SetPoint("BOTTOMRIGHT", -4, 4)

    Check(left, 0, L["hc_enable"], "enabled")
    Check(left, -30, L["hc_warn_health"], "warnHealth")
    Stepper(left, -60, L["hc_danger_value"], "dangerPct", 5, 50, 5)
    Check(left, -94, L["hc_warn_target"], "warnTarget")
    Stepper(left, -124, L["hc_diff_value"], "levelDiff", 1, 10, 1)

    ui.counts = left:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ui.counts:SetPoint("TOPLEFT", 8, -168)
    ui.counts:SetJustifyH("LEFT")
    ui.counts:SetSpacing(4)

    ui.off = left:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ui.off:SetPoint("TOPLEFT", 8, -234)
    ui.off:SetPoint("TOPRIGHT", -4, -234)
    ui.off:SetJustifyH("LEFT")
    ui.off:SetText(L["hc_off_hint"])

    local clear = UI.CreateButton(left, L["hc_clear"], 200, 24, function()
        local cfg = ns.cdb.hardcore
        wipe(cfg.log)
        wipe(cfg.byDay)
        cfg.total = 0
        H.Refresh()
    end)
    clear:SetPoint("TOPLEFT", 8, -290)

    local header = right:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", 4, 0)
    header:SetText(L["hc_log"])
    ui.list = UI.CreateList(right, 40,
        function(row)
            row.bg = row:CreateTexture(nil, "BACKGROUND")
            row.bg:SetPoint("TOPLEFT", 0, -1)
            row.bg:SetPoint("BOTTOMRIGHT", 0, 1)
            row.bg:SetColorTexture(1, 0.2, 0.2, 0.07)
            row.when = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.when:SetPoint("TOPLEFT", 6, -5)
            row.when:SetPoint("TOPRIGHT", -4, -5)
            row.when:SetJustifyH("LEFT")
            row.what = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            row.what:SetPoint("TOPLEFT", 6, -21)
            row.what:SetPoint("TOPRIGHT", -4, -21)
            row.what:SetJustifyH("LEFT")
            row.what:SetWordWrap(false)
        end,
        SetupRow)
    ui.list.frame:SetPoint("TOPLEFT", 0, -26)
    ui.list.frame:SetPoint("BOTTOMRIGHT", 0, 0)
    ui.empty = ui.list.frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    ui.empty:SetPoint("CENTER")
    ui.empty:SetText(L["hc_log_empty"])

    H.OnChanged = function()
        if frame:IsVisible() then H.Refresh() end
    end
    frame:SetScript("OnShow", H.Refresh)
    H.Refresh()
end

ns.refresh.hardcore = function()
    if ui.list then H.Refresh() end
end

ns:RegisterModule("hardcore", "tab_hardcore", nil, Create)
