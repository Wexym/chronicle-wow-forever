-- Вкладка «Игроки»: заметки на игроков, подсказка, предупреждение в группе.
local ADDON, ns = ...
local L = ns.L
local UI = ns.UI

local P = {}
ns.Players = P

local MARKS = {
    good    = { key = "mark_good",    r = 0.2, g = 0.9,  b = 0.2 },
    neutral = { key = "mark_neutral", r = 1.0, g = 0.82, b = 0.0 },
    bad     = { key = "mark_bad",     r = 1.0, g = 0.2,  b = 0.2 },
}
local MARK_ORDER = { "good", "neutral", "bad" }
local ROLES = { "tank", "healer", "dps" }
local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local NOTE_LIMIT = 4000
local ROW_H = 20

---------------------------------------------------------------------------
-- Данные
---------------------------------------------------------------------------

-- Область сервера без пробелов и дефисов (так её возвращает UnitName)
local function NormRealm(realm)
    if not realm or realm == "" then
        realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName() or ""
    end
    return (realm:gsub("[%s%-]", ""))
end

-- Ключ записи «Имя-Сервер». Если сервер не указан — текущий.
function P.MakeKey(name, realm)
    if not name then return end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return end
    local n, r = name:match("^([^%-]+)%-(.+)$")
    if n then name, realm = n, r end
    return name .. "-" .. NormRealm(realm)
end

function P.KeyFromUnit(unit)
    if not UnitIsPlayer(unit) then return end
    local name, realm = UnitName(unit)
    if not name or name == UNKNOWNOBJECT then return end
    return P.MakeKey(name, realm)
end

-- Имя без сервера, если сервер свой
local function DisplayName(key)
    local n, r = key:match("^(.-)%-(.+)$")
    if n and r == NormRealm() then return n end
    return key
end

-- «Зона» или «Подземелье (Зона)»
function P.CurrentPlace()
    local zone = GetRealZoneText() or GetZoneText() or ""
    local inInstance = IsInInstance()
    if inInstance then
        local name = GetInstanceInfo()
        if name and name ~= zone then return name .. " (" .. zone .. ")" end
    end
    return zone
end

local function NewRecord()
    return { tags = "", note = "", roles = {} }
end

-- Обновляет данные уже существующей записи по юниту (создавать записи автоматически не нужно)
function P.UpdateFromUnit(unit)
    if not ns.db or not UnitIsPlayer(unit) or UnitIsUnit(unit, "player") then return end
    local key = P.KeyFromUnit(unit)
    local rec = key and ns.db.players[key]
    if not rec then return end
    local _, classFile = UnitClass(unit)
    if classFile then rec.class = classFile end
    local level = UnitLevel(unit)
    if level and level > 0 then rec.level = level end
    local race = UnitRace(unit)
    if race then rec.race = race end
    local guild = GetGuildInfo(unit)
    if guild then rec.guild = guild end
    rec.lastSeen = time()
    if not rec.metZone or rec.metZone == "" then rec.metZone = P.CurrentPlace() end
    if P.OnDataChanged then P.OnDataChanged() end
end

local function FirstLine(note)
    return note and note:match("[^\r\n]+") or ""
end

---------------------------------------------------------------------------
-- Интеграция с игрой
---------------------------------------------------------------------------

-- Строки в подсказке над игроком
local function AddTooltipInfo(tooltip)
    if not ns.db or tooltip ~= GameTooltip then return end
    local _, unit = tooltip:GetUnit()
    if not unit then return end
    local key = P.KeyFromUnit(unit)
    local rec = key and ns.db.players[key]
    if not rec then return end
    local m = MARKS[rec.mark]
    if m then
        tooltip:AddLine(L["tooltip_line"]:format(L[m.key]), m.r, m.g, m.b)
    else
        tooltip:AddLine(L["addon_title"], 0.6, 0.6, 0.6)
    end
    local line = FirstLine(rec.note)
    if line ~= "" then tooltip:AddLine(line, 1, 1, 1, true) end
    tooltip:Show()
end

local function HookTooltip()
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tt)
            pcall(AddTooltipInfo, tt)
        end)
    else
        GameTooltip:HookScript("OnTooltipSetUnit", function(tt) pcall(AddTooltipInfo, tt) end)
    end
end

local function Warn(text)
    print("|cffff4444" .. L["addon_title"] .. ":|r " .. text)
end

-- Предупреждение о красных отметках в группе. warned сбрасывается, когда группа распалась.
local warned = {}
local function ScanGroup()
    if not IsInGroup() then wipe(warned) return end
    local units = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do units[#units + 1] = "raid" .. i end
    else
        for i = 1, GetNumSubgroupMembers() do units[#units + 1] = "party" .. i end
    end
    for _, unit in ipairs(units) do
        if UnitExists(unit) and UnitIsPlayer(unit) then
            P.UpdateFromUnit(unit)
            local key = P.KeyFromUnit(unit)
            local rec = key and ns.db.players[key]
            if rec and rec.mark == "bad" and not warned[key] then
                warned[key] = true
                if ns.db.settings.warnGroup then
                    Warn(L["warn_group"]:format(DisplayName(key), L["mark_bad"], FirstLine(rec.note)))
                end
            end
        end
    end
end

local whisperSeen = {}
local function OnWhisper(sender)
    if not ns.db.settings.warnWhisper or not sender then return end
    local key = P.MakeKey(sender)
    local rec = key and ns.db.players[key]
    if not rec or whisperSeen[key] then return end
    whisperSeen[key] = true
    local m = MARKS[rec.mark]
    Warn(L["warn_whisper"]:format(DisplayName(key), m and L[m.key] or "—", FirstLine(rec.note)))
end

-- Пункт в контекстном меню по правому клику на игроке (если клиент даёт Menu.ModifyMenu)
local function HookMenus()
    if not (Menu and Menu.ModifyMenu) then return end
    local tags = { "MENU_UNIT_PLAYER", "MENU_UNIT_PARTY", "MENU_UNIT_RAID_PLAYER", "MENU_UNIT_FRIEND",
                   "MENU_UNIT_TARGET", "MENU_UNIT_FOCUS", "MENU_UNIT_ENEMY_PLAYER", "MENU_UNIT_CHAT_ROSTER" }
    for _, tag in ipairs(tags) do
        pcall(Menu.ModifyMenu, tag, function(_, root, ctx)
            if not ctx then return end
            local name = ctx.name
            if name and ctx.server and ctx.server ~= "" then name = name .. "-" .. ctx.server end
            if not name and ctx.unit and UnitIsPlayer(ctx.unit) then
                local n, r = UnitName(ctx.unit)
                name = (r and r ~= "") and (n .. "-" .. r) or n
            end
            if not name then return end
            root:CreateDivider()
            root:CreateButton(L["menu_note"], function() P.OpenFor(name) end)
        end)
    end
end

ns:OnLogin(function()
    HookTooltip()
    HookMenus()
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_TARGET_CHANGED")
    f:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
    f:RegisterEvent("GROUP_ROSTER_UPDATE")
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:RegisterEvent("CHAT_MSG_WHISPER")
    f:SetScript("OnEvent", function(_, event, arg1, arg2)
        if event == "PLAYER_TARGET_CHANGED" then
            P.UpdateFromUnit("target")
        elseif event == "UPDATE_MOUSEOVER_UNIT" then
            P.UpdateFromUnit("mouseover")
        elseif event == "CHAT_MSG_WHISPER" then
            OnWhisper(arg2)
        elseif event == "PLAYER_ENTERING_WORLD" then
            C_Timer.After(3, ScanGroup)   -- имена участников подгружаются не сразу
        else
            ScanGroup()
        end
    end)
end)

---------------------------------------------------------------------------
-- Интерфейс вкладки
---------------------------------------------------------------------------

local state = {
    search = "", mark = nil, role = nil, class = nil, sort = "name",
    key = nil,        -- выбранная запись
    pending = nil,    -- новая запись, ещё не сохранённая
}
local ui = {}         -- элементы интерфейса, заполняются при первом открытии
local view = {}       -- отфильтрованный и отсортированный список ключей

local function NextValue(list, current)
    if current == nil then return list[1] end
    for i, v in ipairs(list) do
        if v == current then return list[i + 1] end   -- после последнего — nil («все»)
    end
end

local function Rebuild()
    if not ui.list then return end
    local q = ns.Lower(state.search)
    local items = {}
    for key, rec in pairs(ns.db.players) do
        local ok = true
        if state.mark and rec.mark ~= state.mark then ok = false end
        if ok and state.role and not (rec.roles and rec.roles[state.role]) then ok = false end
        if ok and state.class and rec.class ~= state.class then ok = false end
        local lname = ns.Lower(DisplayName(key))
        if ok and q ~= "" then
            local hay = lname .. " " .. ns.Lower(rec.tags) .. " " .. ns.Lower(rec.note)
            ok = hay:find(q, 1, true) ~= nil
        end
        if ok then items[#items + 1] = { key = key, lname = lname, seen = rec.lastSeen or 0 } end
    end
    if state.sort == "seen" then
        table.sort(items, function(a, b)
            if a.seen ~= b.seen then return a.seen > b.seen end
            return a.lname < b.lname
        end)
    else
        table.sort(items, function(a, b) return a.lname < b.lname end)
    end
    wipe(view)
    for i, it in ipairs(items) do view[i] = it.key end
    ui.list:SetCount(#view)
    ui.empty:SetShown(#view == 0)
end

-- Текущая редактируемая запись
local function Current()
    if state.pending then return state.pending end
    return state.key and ns.db.players[state.key] or nil
end

local function UpdateFilterButtons()
    ui.btnMark:SetText(L["players_filter_mark"]:format(state.mark and L[MARKS[state.mark].key] or L["all"]))
    ui.btnRole:SetText(L["players_filter_role"]:format(state.role and L["role_" .. state.role] or L["all"]))
    ui.btnClass:SetText(L["players_filter_class"]:format(
        state.class and (LOCALIZED_CLASS_NAMES_MALE[state.class] or state.class) or L["all"]))
    ui.btnSort:SetText(L["players_sort"]:format(L["sort_" .. state.sort]))
end

local loading = false   -- true, пока поля заполняются из записи (чтобы не писать обратно)

local function LoadDetail()
    local rec = Current()
    loading = true
    if not rec then
        ui.body:Hide()
        ui.hint:Show()
        loading = false
        return
    end
    ui.hint:Hide()
    ui.body:Show()
    local isNew = state.pending ~= nil
    ui.nameEdit:SetShown(isNew)
    ui.info:SetShown(not isNew)
    ui.btnSave:SetShown(isNew)
    ui.btnCancel:SetShown(isNew)
    ui.btnDelete:SetShown(not isNew)

    if isNew then
        ui.title:SetText(L["players_new"])
    else
        ui.title:SetText(DisplayName(state.key))
        local c = rec.class and RAID_CLASS_COLORS[rec.class]
        if c then ui.title:SetTextColor(c.r, c.g, c.b) else ui.title:SetTextColor(1, 0.82, 0) end
        local parts = {}
        if rec.class then parts[#parts + 1] = LOCALIZED_CLASS_NAMES_MALE[rec.class] or rec.class end
        if rec.level then parts[#parts + 1] = tostring(rec.level) end
        if rec.race then parts[#parts + 1] = rec.race end
        local text = table.concat(parts, ", ")
        if rec.guild then text = text .. " <" .. rec.guild .. ">" end
        ui.info:SetText(text)
    end
    if isNew then ui.title:SetTextColor(1, 0.82, 0) end

    for _, mk in ipairs(MARK_ORDER) do
        if rec.mark == mk then ui.markBtn[mk]:LockHighlight() else ui.markBtn[mk]:UnlockHighlight() end
    end
    for _, role in ipairs(ROLES) do
        ui.roleCheck[role]:SetChecked(rec.roles and rec.roles[role] or false)
    end
    ui.tags:SetText(rec.tags or "")
    ui.tags:SetCursorPosition(0)
    ui.note.edit:SetText(rec.note or "")
    ui.note.edit:SetCursorPosition(0)
    ui.met:SetText(L["field_met"]:format(rec.metZone ~= nil and rec.metZone ~= "" and rec.metZone or L["unknown"]))
    ui.seen:SetText(L["field_seen"]:format(rec.lastSeen and ns.FormatBoth(rec.lastSeen, "%d.%m.%Y %H:%M") or L["unknown"]))
    ui.met:SetShown(not isNew)
    ui.seen:SetShown(not isNew)
    loading = false
end

function P.Select(key)
    state.pending = nil
    state.key = key
    LoadDetail()
    if ui.list then ui.list:Refresh() end
end

local function StartNew(prefill)
    state.pending = NewRecord()
    state.key = nil
    LoadDetail()
    ui.nameEdit:SetText(prefill or "")
    ui.list:Refresh()
end

local function SaveNew()
    local key = P.MakeKey(ui.nameEdit:GetText())
    if not key then ns.Say(L["err_name"]) return end
    if ns.db.players[key] then
        ns.Say(L["err_exists"])
        P.Select(key)
        Rebuild()
        return
    end
    local rec = state.pending
    rec.metZone = P.CurrentPlace()
    rec.lastSeen = time()
    ns.db.players[key] = rec
    state.pending, state.key = nil, key
    -- Подтягиваем класс, уровень и гильдию, если игрок сейчас в цели или под курсором
    for _, unit in ipairs({ "target", "mouseover", "focus" }) do
        if UnitExists(unit) and P.KeyFromUnit(unit) == key then P.UpdateFromUnit(unit) break end
    end
    Rebuild()
    LoadDetail()
end

StaticPopupDialogs["CHRONICLE_DELETE_PLAYER"] = {
    text = L["confirm_delete"],
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, key)
        ns.db.players[key] = nil
        if state.key == key then state.key = nil end
        Rebuild()
        LoadDetail()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function Create(frame)
    -- Первая строка: поиск и «Добавить»
    ui.search = UI.CreateEditBox(frame, 200, function(self, byUser)
        if byUser then state.search = self:GetText(); Rebuild() end
    end)
    ui.search:SetPoint("TOPLEFT", 8, -4)
    UI.SetEditHint(ui.search, L["players_search"])
    ui.search.hint:Show()

    ui.btnAdd = UI.CreateButton(frame, L["players_add"], 100, 22, function()
        local prefill
        if UnitExists("target") and UnitIsPlayer("target") and not UnitIsUnit("target", "player") then
            local key = P.KeyFromUnit("target")
            if key and ns.db.players[key] then P.Select(key) return end
            local n, r = UnitName("target")
            prefill = (r and r ~= "") and (n .. "-" .. r) or n
        end
        StartNew(prefill)
    end)
    ui.btnAdd:SetPoint("TOPRIGHT", -4, -3)

    -- Вторая строка: фильтры и сортировка (кнопки переключают значения по кругу)
    local function FilterButton(width, onClick)
        local b = UI.CreateButton(frame, "", width, 22, onClick)
        return b
    end
    ui.btnMark = FilterButton(130, function()
        state.mark = NextValue(MARK_ORDER, state.mark); UpdateFilterButtons(); Rebuild()
    end)
    ui.btnRole = FilterButton(110, function()
        state.role = NextValue(ROLES, state.role); UpdateFilterButtons(); Rebuild()
    end)
    ui.btnClass = FilterButton(130, function()
        state.class = NextValue(CLASSES, state.class); UpdateFilterButtons(); Rebuild()
    end)
    ui.btnSort = FilterButton(150, function()
        state.sort = state.sort == "name" and "seen" or "name"; UpdateFilterButtons(); Rebuild()
    end)
    ui.btnMark:SetPoint("TOPLEFT", 4, -30)
    ui.btnRole:SetPoint("LEFT", ui.btnMark, "RIGHT", 2, 0)
    ui.btnClass:SetPoint("LEFT", ui.btnRole, "RIGHT", 2, 0)
    ui.btnSort:SetPoint("LEFT", ui.btnClass, "RIGHT", 2, 0)

    -- Список слева
    ui.list = UI.CreateList(frame, ROW_H,
        function(row)
            row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            row.sel = row:CreateTexture(nil, "BACKGROUND")
            row.sel:SetAllPoints()
            row.sel:SetColorTexture(1, 1, 1, 0.15)
            row.mark = row:CreateTexture(nil, "ARTWORK")
            row.mark:SetSize(8, 8)
            row.mark:SetPoint("LEFT", 4, 0)
            row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            row.text:SetPoint("LEFT", row.mark, "RIGHT", 6, 0)
            row.text:SetPoint("RIGHT", -2, 0)
            row.text:SetJustifyH("LEFT")
            row:SetScript("OnClick", function(self) P.Select(self.key) end)
        end,
        function(row, idx)
            local key = view[idx]
            local rec = ns.db.players[key]
            row.key = key
            local m = MARKS[rec.mark]
            if m then row.mark:SetColorTexture(m.r, m.g, m.b, 1) else row.mark:SetColorTexture(0.4, 0.4, 0.4, 1) end
            row.text:SetText(DisplayName(key))
            local c = rec.class and RAID_CLASS_COLORS[rec.class]
            if c then row.text:SetTextColor(c.r, c.g, c.b) else row.text:SetTextColor(1, 1, 1) end
            row.sel:SetShown(key == state.key and not state.pending)
        end)
    ui.list.frame:SetPoint("TOPLEFT", 4, -58)
    ui.list.frame:SetPoint("BOTTOMLEFT", 4, 4)
    ui.list.frame:SetWidth(220)
    ui.empty = ui.list.frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    ui.empty:SetPoint("CENTER")
    ui.empty:SetText(L["players_empty"])

    -- Карточка справа
    local detail = UI.CreateBox(frame)
    detail:SetPoint("TOPLEFT", ui.list.frame, "TOPRIGHT", 6, 0)
    detail:SetPoint("BOTTOMRIGHT", -4, 4)
    ui.detail = detail

    ui.hint = detail:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    ui.hint:SetPoint("CENTER")
    ui.hint:SetText(L["players_hint"])

    local body = CreateFrame("Frame", nil, detail)
    body:SetAllPoints()
    ui.body = body

    ui.title = body:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    ui.title:SetPoint("TOPLEFT", 12, -10)
    ui.title:SetPoint("TOPRIGHT", -12, -10)
    ui.title:SetJustifyH("LEFT")

    ui.nameEdit = UI.CreateEditBox(body, 220)
    ui.nameEdit:SetPoint("TOPLEFT", 16, -34)
    UI.SetEditHint(ui.nameEdit, L["field_name"])

    ui.info = body:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    ui.info:SetPoint("TOPLEFT", 12, -36)
    ui.info:SetPoint("TOPRIGHT", -12, -36)
    ui.info:SetJustifyH("LEFT")

    -- Отметка
    local markLabel = body:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    markLabel:SetPoint("TOPLEFT", 12, -62)
    markLabel:SetText(L["field_mark"])
    ui.markBtn = {}
    local prev
    for _, mk in ipairs(MARK_ORDER) do
        local m = MARKS[mk]
        local b = UI.CreateButton(body, L[m.key], 100, 22, function()
            if loading then return end
            local rec = Current()
            if not rec then return end
            rec.mark = (rec.mark ~= mk) and mk or nil   -- повторный клик снимает отметку
            LoadDetail()
            Rebuild()
        end)
        b:GetFontString():SetTextColor(m.r, m.g, m.b)
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 2, 0) else b:SetPoint("TOPLEFT", 12, -80) end
        ui.markBtn[mk] = b
        prev = b
    end

    -- Роли
    local roleLabel = body:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    roleLabel:SetPoint("TOPLEFT", 12, -110)
    roleLabel:SetText(L["field_roles"])
    ui.roleCheck = {}
    local x = 12
    for _, role in ipairs(ROLES) do
        local cb = CreateFrame("CheckButton", nil, body, "UICheckButtonTemplate")
        cb:SetSize(24, 24)
        cb:SetPoint("TOPLEFT", x, -124)
        local lbl = body:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        lbl:SetPoint("LEFT", cb, "RIGHT", 0, 1)
        lbl:SetText(L["role_" .. role])
        cb:SetScript("OnClick", function(self)
            if loading then return end
            local rec = Current()
            if not rec then return end
            rec.roles = rec.roles or {}
            rec.roles[role] = self:GetChecked() and true or nil
            Rebuild()
        end)
        ui.roleCheck[role] = cb
        x = x + 100
    end

    -- Теги
    local tagLabel = body:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    tagLabel:SetPoint("TOPLEFT", 12, -156)
    tagLabel:SetText(L["field_tags"])
    ui.tags = UI.CreateEditBox(body, 100, function(self, byUser)
        local rec = Current()
        if byUser and not loading and rec then rec.tags = self:GetText() end
    end)
    ui.tags:SetPoint("TOPLEFT", 16, -172)
    ui.tags:SetPoint("TOPRIGHT", -12, -172)
    ui.tags:SetMaxLetters(200)
    ui.tags:HookScript("OnEditFocusLost", Rebuild)

    -- Заметка
    local noteLabel = body:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    noteLabel:SetPoint("TOPLEFT", 12, -200)
    noteLabel:SetText(L["field_note"])
    ui.note = UI.CreateMultiline(body, NOTE_LIMIT, function(self, byUser)
        local rec = Current()
        if byUser and not loading and rec then rec.note = self:GetText() end
    end)
    ui.note:SetPoint("TOPLEFT", 12, -216)
    ui.note:SetPoint("BOTTOMRIGHT", -12, 76)
    ui.note.edit:HookScript("OnEditFocusLost", Rebuild)

    -- Нижняя часть: сведения и кнопки
    ui.met = body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.met:SetPoint("BOTTOMLEFT", 12, 54)
    ui.met:SetPoint("BOTTOMRIGHT", -12, 54)
    ui.met:SetJustifyH("LEFT")
    ui.seen = body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.seen:SetPoint("BOTTOMLEFT", 12, 38)
    ui.seen:SetJustifyH("LEFT")

    ui.btnSave = UI.CreateButton(body, L["btn_save"], 100, 22, SaveNew)
    ui.btnSave:SetPoint("BOTTOMLEFT", 12, 10)
    ui.btnCancel = UI.CreateButton(body, L["btn_cancel"], 100, 22, function()
        state.pending = nil
        LoadDetail()
        ui.list:Refresh()
    end)
    ui.btnCancel:SetPoint("LEFT", ui.btnSave, "RIGHT", 4, 0)
    ui.btnDelete = UI.CreateButton(body, L["btn_delete"], 100, 22, function()
        if state.key then
            StaticPopup_Show("CHRONICLE_DELETE_PLAYER", DisplayName(state.key), nil, state.key)
        end
    end)
    ui.btnDelete:SetPoint("BOTTOMLEFT", 12, 10)

    UpdateFilterButtons()
    LoadDetail()
    Rebuild()
    P.OnDataChanged = function()
        if frame:IsVisible() then
            Rebuild()
            if state.key and not state.pending then LoadDetail() end
        end
    end
end

-- Открыть вкладку на заметке игрока (из команды, меню или кнопки). Без имени — игрок в цели.
function P.OpenFor(name)
    ns:ToggleMain(true)
    ns:SelectTab("players")
    if not name or name == "" then
        if UnitExists("target") and UnitIsPlayer("target") and not UnitIsUnit("target", "player") then
            local n, r = UnitName("target")
            name = (r and r ~= "") and (n .. "-" .. r) or n
        else
            StartNew("")
            return
        end
    end
    local key = P.MakeKey(name)
    if key and ns.db.players[key] then
        state.search = ""
        ui.search:SetText("")
        Rebuild()
        P.Select(key)
    else
        StartNew(name)
    end
end

ns.refresh.players = function()
    state.key, state.pending = nil, nil
    if ui.list then
        LoadDetail()
        Rebuild()
    end
end

ns:RegisterModule("players", "tab_players", nil, Create)
