-- Вкладка «Напоминалки»: сообщения на экране о баффах, сумках, прочности и перезарядках.
local ADDON, ns = ...
local L = ns.L
local UI = ns.UI

local R = {}
ns.Reminders = R

local ALERT_SECONDS = 6

---------------------------------------------------------------------------
-- Сообщение на экране
---------------------------------------------------------------------------

local alertFrame
local alerts = {}   -- { text, r, g, b, expire }

local function RenderAlerts()
    local lines = {}
    for _, a in ipairs(alerts) do
        lines[#lines + 1] = string.format("|cff%02x%02x%02x%s|r", a.r * 255, a.g * 255, a.b * 255, a.text)
    end
    alertFrame.text:SetText(table.concat(lines, "\n"))
end

-- Показывает сообщение по центру сверху. Несколько сообщений складываются в столбик.
function ns.Alert(text, r, g, b, silent)
    if not alertFrame then
        alertFrame = CreateFrame("Frame", "ChronicleAlertFrame", UIParent)
        alertFrame:SetSize(700, 120)
        alertFrame:SetPoint("TOP", UIParent, "TOP", 0, -160)
        alertFrame:SetFrameStrata("FULLSCREEN_DIALOG")
        alertFrame.text = alertFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        alertFrame.text:SetPoint("TOP")
        alertFrame.text:SetJustifyH("CENTER")
        alertFrame.text:SetSpacing(6)
        alertFrame:SetScale(1.4)
        alertFrame:SetScript("OnUpdate", function(self)
            local now = GetTime()
            local changed = false
            for i = #alerts, 1, -1 do
                if alerts[i].expire <= now then
                    table.remove(alerts, i)
                    changed = true
                end
            end
            if #alerts == 0 then self:Hide() return end
            if changed then RenderAlerts() end
            -- Плавное исчезновение в последнюю секунду
            local left = alerts[#alerts].expire - now
            self:SetAlpha(left < 1 and left or 1)
        end)
    end
    alerts[#alerts + 1] = { text = text, r = r or 1, g = g or 0.82, b = b or 0, expire = GetTime() + ALERT_SECONDS }
    RenderAlerts()
    alertFrame:SetAlpha(1)
    alertFrame:Show()
    if not silent and ns.db.reminders.sound then
        pcall(PlaySound, (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959)
    end
end

---------------------------------------------------------------------------
-- Проверки
---------------------------------------------------------------------------

-- Названия баффов на игроке в нижнем регистре
local function BuffSet()
    local set = {}
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        for i = 1, 40 do
            local aura = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
            if not aura then break end
            if aura.name then set[ns.Lower(aura.name)] = true end
        end
    elseif UnitBuff then
        for i = 1, 40 do
            local name = UnitBuff("player", i)
            if not name then break end
            set[ns.Lower(name)] = true
        end
    end
    return set
end

local buffWas = {}   -- был ли бафф на прошлой проверке

local function BaselineBuffs()
    local set = BuffSet()
    wipe(buffWas)
    for _, name in ipairs(ns.db.reminders.buffs) do buffWas[name] = set[ns.Lower(name)] or false end
end

local function CheckBuffs()
    local rem = ns.db.reminders
    if not rem.buffsOn or UnitIsDeadOrGhost("player") then return end
    local set = BuffSet()
    for _, name in ipairs(rem.buffs) do
        local now = set[ns.Lower(name)] or false
        if buffWas[name] and not now then ns.Alert(L["rem_buff_end"]:format(name), 1, 0.5, 0.2) end
        buffWas[name] = now
    end
end

-- Свободные слоты в обычных сумках (особые сумки — колчаны, сумки душ — не считаем)
local function FreeSlots()
    local getFree = (C_Container and C_Container.GetContainerNumFreeSlots) or GetContainerNumFreeSlots
    if not getFree then return nil end
    local free = 0
    for bag = 0, NUM_BAG_SLOTS or 4 do
        local n, bagType = getFree(bag)
        if n and (bagType == nil or bagType == 0) then free = free + n end
    end
    return free
end

local bagsWarned = false
local function CheckBags()
    local rem = ns.db.reminders
    if not rem.bagsOn then return end
    local free = FreeSlots()
    if not free then return end
    if free <= rem.bagsFree then
        if not bagsWarned then
            bagsWarned = true
            ns.Alert(L["rem_bags_full"]:format(free), 1, 0.6, 0.2)
        end
    elseif free > rem.bagsFree + 2 then
        bagsWarned = false
    end
end

-- Минимальная прочность надетых предметов в процентах
local function MinDurability()
    local lowest
    for slot = 1, 19 do
        local cur, max = GetInventoryItemDurability(slot)
        if cur and max and max > 0 then
            local pct = cur / max * 100
            if not lowest or pct < lowest then lowest = pct end
        end
    end
    return lowest
end

local durWarned = false
local function CheckDurability()
    local rem = ns.db.reminders
    if not rem.durOn then return end
    local pct = MinDurability()
    if not pct then return end
    if pct <= rem.durPct then
        if not durWarned then
            durWarned = true
            ns.Alert(L["rem_dur_low"]:format(pct), 1, 0.3, 0.3)
        end
    elseif pct > rem.durPct + 10 then
        durWarned = false
    end
end

-- Перезарядка заклинания: старт и длительность; название или ID заклинания
local function SpellCooldown(spell)
    local key = tonumber(spell) or spell
    if C_Spell and C_Spell.GetSpellCooldown then
        local cd = C_Spell.GetSpellCooldown(key)
        if cd then return cd.startTime, cd.duration end
    elseif GetSpellCooldown then
        return GetSpellCooldown(key)
    end
end

local onCooldown = {}
local function CheckCooldowns()
    local rem = ns.db.reminders
    if not rem.cdOn then return end
    for _, spell in ipairs(rem.spells) do
        local ok, start, duration = pcall(SpellCooldown, spell)
        if ok and start then
            -- Перезарядка короче трёх секунд — это общий интервал, а не настоящий кулдаун
            local busy = duration and duration > 3 and start > 0 and (start + duration) > GetTime()
            if onCooldown[spell] and not busy then ns.Alert(L["rem_cd_ready"]:format(spell), 0.4, 1, 0.4) end
            onCooldown[spell] = busy and true or false
        end
    end
end

ns:OnLogin(function()
    local f = CreateFrame("Frame")
    f:RegisterEvent("UNIT_AURA")
    f:RegisterEvent("BAG_UPDATE_DELAYED")
    f:RegisterEvent("UPDATE_INVENTORY_DURABILITY")
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:RegisterEvent("PLAYER_ALIVE")
    f:RegisterEvent("PLAYER_UNGHOST")
    f:SetScript("OnEvent", function(_, event, unit)
        if event == "UNIT_AURA" then
            if unit == "player" then CheckBuffs() end
        elseif event == "BAG_UPDATE_DELAYED" then
            CheckBags()
        elseif event == "UPDATE_INVENTORY_DURABILITY" then
            CheckDurability()
        else
            -- Вход в мир или воскрешение: баффы могли пропасть не по времени, запоминаем заново
            BaselineBuffs()
            C_Timer.After(2, function()
                CheckBags()
                CheckDurability()
            end)
        end
    end)
    BaselineBuffs()
    C_Timer.NewTicker(5, CheckCooldowns)
end)

---------------------------------------------------------------------------
-- Интерфейс
---------------------------------------------------------------------------

local sync = {}

local function Header(parent, y, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:SetPoint("TOPLEFT", 4, y)
    fs:SetText(text)
end

local function Check(parent, y, text, field)
    local cb = UI.CreateCheck(parent, 4, y, text, function(v) ns.db.reminders[field] = v end)
    sync[#sync + 1] = function() cb:SetChecked(ns.db.reminders[field]) end
end

-- Строка «текст  [−] [+]» для числового порога
local function Stepper(parent, y, fmt, field, min, max, step)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    local function Set(v)
        v = math.min(max, math.max(min, v))
        ns.db.reminders[field] = v
        label:SetText(fmt:format(v))
    end
    local minus = UI.CreateButton(parent, "-", 26, 22, function() Set(ns.db.reminders[field] - step) end)
    minus:SetPoint("TOPLEFT", 8, y)
    label:SetPoint("LEFT", minus, "RIGHT", 8, 0)
    label:SetWidth(170)
    label:SetJustifyH("CENTER")
    local plus = UI.CreateButton(parent, "+", 26, 22, function() Set(ns.db.reminders[field] + step) end)
    plus:SetPoint("LEFT", label, "RIGHT", 8, 0)
    sync[#sync + 1] = function() label:SetText(fmt:format(ns.db.reminders[field])) end
end

-- Список названий с кнопками удаления и полем добавления
local function NameList(parent, y, field, hint)
    local list
    list = UI.CreateList(parent, 20,
        function(row)
            row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            row.text:SetPoint("LEFT", 4, 0)
            row.text:SetPoint("RIGHT", -22, 0)
            row.text:SetJustifyH("LEFT")
            row.del = CreateFrame("Button", nil, row, "UIPanelCloseButton")
            row.del:SetSize(20, 20)
            row.del:SetPoint("RIGHT", 0, 0)
            row.del:SetScript("OnClick", function()
                table.remove(ns.db.reminders[field], row.idx)
                list:SetCount(#ns.db.reminders[field])
            end)
        end,
        function(row, idx)
            row.idx = idx
            row.text:SetText(ns.db.reminders[field][idx])
        end)
    list.frame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
    list.frame:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, y)
    list.frame:SetHeight(96)

    local edit = UI.CreateEditBox(parent, 100)
    edit:SetPoint("TOPLEFT", 8, y - 104)
    edit:SetPoint("TOPRIGHT", -100, y - 104)
    edit:SetMaxLetters(60)
    UI.SetEditHint(edit, hint)
    edit.hint:Show()
    local function Add()
        local text = edit:GetText():gsub("^%s+", ""):gsub("%s+$", "")
        if text == "" then return end
        local items = ns.db.reminders[field]
        for _, v in ipairs(items) do
            if ns.Lower(v) == ns.Lower(text) then return end
        end
        items[#items + 1] = text
        edit:SetText("")
        list:SetCount(#items)
        if field == "buffs" then BaselineBuffs() end
    end
    edit:SetScript("OnEnterPressed", function(self) Add(); self:ClearFocus() end)
    local btn = UI.CreateButton(parent, L["players_add"], 92, 22, Add)
    btn:SetPoint("TOPRIGHT", 0, y - 103)
    sync[#sync + 1] = function() list:SetCount(#ns.db.reminders[field]) end
end

local function Create(frame)
    local left = CreateFrame("Frame", nil, frame)
    left:SetPoint("TOPLEFT", 4, -4)
    left:SetPoint("BOTTOMRIGHT", frame, "BOTTOM", -4, 4)
    local right = CreateFrame("Frame", nil, frame)
    right:SetPoint("TOPLEFT", frame, "TOP", 4, -4)
    right:SetPoint("BOTTOMRIGHT", -4, 4)

    Header(left, 0, L["rem_buffs"])
    Check(left, -22, L["rem_buffs_on"], "buffsOn")
    NameList(left, -50, "buffs", L["rem_buff_hint"])

    Header(left, -190, L["rem_bags"])
    Check(left, -212, L["rem_bags_on"], "bagsOn")
    Stepper(left, -240, L["rem_bags_value"], "bagsFree", 0, 30, 1)

    Header(right, 0, L["rem_cd"])
    Check(right, -22, L["rem_cd_on"], "cdOn")
    NameList(right, -50, "spells", L["rem_spell_hint"])

    Header(right, -190, L["rem_dur"])
    Check(right, -212, L["rem_dur_on"], "durOn")
    Stepper(right, -240, L["rem_dur_value"], "durPct", 5, 90, 5)

    local snd = UI.CreateCheck(left, 4, -270, L["rem_sound"], function(v) ns.db.reminders.sound = v end)
    sync[#sync + 1] = function() snd:SetChecked(ns.db.reminders.sound) end
    local test = UI.CreateButton(right, L["rem_test_btn"], 160, 22, function() ns.Alert(L["rem_test"], 0.4, 0.8, 1) end)
    test:SetPoint("TOPLEFT", 8, -272)

    frame:SetScript("OnShow", function()
        for _, fn in ipairs(sync) do fn() end
    end)
    for _, fn in ipairs(sync) do fn() end
end

ns:RegisterModule("reminders", "tab_reminders", nil, Create)
