-- Вкладка «Чеклист»: задачи на день, неделю и месяц с автоматическим сбросом.
local ADDON, ns = ...
local L = ns.L
local UI = ns.UI

local C = {}
ns.Checklist = C

local PERIODS = { "day", "week", "month" }
local SCOPES = { "char", "account" }
local ROW_H = 26
local HISTORY_LIMIT = 400

local state = { period = "day", alts = false }
local ui = {}
local view = {}   -- задачи выбранного периода в порядке показа

---------------------------------------------------------------------------
-- Данные
---------------------------------------------------------------------------

-- Хранилище задач по области: аккаунт (ChronicleDB) или персонаж (ChronicleCharDB)
local function Container(scope)
    return scope == "account" and ns.db.checklist or ns.cdb.checklist
end

local function SetCount(task, n)
    n = math.max(0, math.min(n, task.target))
    task.count = n
    task.done = n >= task.target
end

local function Toggle(task)
    if task.target then
        SetCount(task, task.done and 0 or task.target)
    else
        task.done = not task.done
    end
end

local function NewTask(data)
    local acc = ns.db.checklist
    acc.orderSeq = acc.orderSeq + 1
    local scope = data.scope or "char"
    local task = {
        title = data.title, period = data.period or "day", scope = scope,
        target = data.target, count = 0, done = false, note = data.note or "",
        order = acc.orderSeq,
    }
    local list = Container(scope).tasks
    list[#list + 1] = task
    return task
end

local function RemoveTask(task)
    local list = Container(task.scope).tasks
    for i, t in ipairs(list) do
        if t == task then table.remove(list, i) return end
    end
end

-- Копия состояния задач персонажа для режима «Альты» (другие персонажи читают её из ChronicleDB)
local function Publish()
    local rec = ns.charKey and ns.db.characters[ns.charKey]
    if not rec then return end
    local snap = { tasks = {}, nextReset = {} }
    for _, t in ipairs(ns.cdb.checklist.tasks) do
        snap.tasks[#snap.tasks + 1] = {
            title = t.title, period = t.period, target = t.target, count = t.count, done = t.done,
        }
    end
    for p, v in pairs(ns.cdb.checklist.nextReset) do snap.nextReset[p] = v end
    rec.checklist = snap
end

local function AddHistory(scopeKey, period, done, total)
    local h = ns.db.checklistHistory
    h[scopeKey] = h[scopeKey] or {}
    local list = h[scopeKey]
    list[#list + 1] = { day = ns.ServerDayKey(), period = period, done = done, total = total }
    while #list > HISTORY_LIMIT do table.remove(list, 1) end
end

local function ResetPeriod(cont, scopeKey, period)
    local done, total = 0, 0
    for _, t in ipairs(cont.tasks) do
        if t.period == period then
            total = total + 1
            if t.done then done = done + 1 end
            t.done, t.count = false, 0
        end
    end
    if total > 0 then AddHistory(scopeKey, period, done, total) end
end

function C.Refresh()
    if ui.root and ui.root:IsVisible() then C.UpdateView() end
end

-- Проверка сбросов: при входе и раз в минуту. Пропущенные сбросы применяются сразу.
function C.CheckResets()
    if not ns.db or not ns.cdb or not ns.charKey then return end
    local now = GetServerTime()
    local changed = false
    local targets = { { ns.db.checklist, "account" }, { ns.cdb.checklist, ns.charKey } }
    for _, entry in ipairs(targets) do
        local cont, scopeKey = entry[1], entry[2]
        for _, period in ipairs(PERIODS) do
            local nextReset = cont.nextReset[period]
            if not nextReset then
                cont.nextReset[period] = now + ns.SecondsUntil(period)
                changed = true
            elseif now >= nextReset then
                ResetPeriod(cont, scopeKey, period)
                cont.nextReset[period] = now + ns.SecondsUntil(period)
                changed = true
            end
        end
    end
    if changed then
        Publish()
        C.Refresh()
    end
end

-- Запасной день и час недельного сброса (нужны, только если клиент не даёт время до сброса сам)
function C.SetWeekly(day, hour)
    if not day or not hour or day < 1 or day > 7 or hour < 0 or hour > 23 then return false end
    ns.db.settings.weeklyDay, ns.db.settings.weeklyHour = day, hour
    local nextReset = GetServerTime() + ns.SecondsUntil("week")
    ns.db.checklist.nextReset.week = nextReset
    ns.cdb.checklist.nextReset.week = nextReset
    Publish()
    C.Refresh()
    ns.Say(L["weekly_set"]:format(day, hour))
    return true
end

-- Шаблоны по умолчанию создаются один раз; дальше список редактируется пользователем
ns:OnInit(function()
    local acc = ns.db.checklist
    if not acc.templatesSeeded then
        acc.templates = {
            { title = L["tpl_daily_quests"],  period = "day",  scope = "char" },
            { title = L["tpl_profession_cd"], period = "day",  scope = "char" },
            { title = L["tpl_weekly_raid"],   period = "week", scope = "char" },
        }
        acc.templatesSeeded = true
    end
end)

ns:OnLogin(function()
    local rec = ns.db.characters[ns.charKey]
    local _, classFile = UnitClass("player")
    rec.class, rec.level = classFile, UnitLevel("player")
    C.CheckResets()
    Publish()
    C_Timer.NewTicker(60, C.CheckResets)
end)

---------------------------------------------------------------------------
-- Редактор задачи и шаблоны
---------------------------------------------------------------------------

local editing   -- редактируемая задача (nil — новая)
local draft     -- черновик полей

local function ClassColored(key)
    local rec = ns.db.characters[key]
    local name = key:match("^(.-)%-") or key
    local c = rec and rec.class and RAID_CLASS_COLORS[rec.class]
    if c then return string.format("|cff%02x%02x%02x%s|r", c.r * 255, c.g * 255, c.b * 255, name) end
    return name
end

StaticPopupDialogs["CHRONICLE_DELETE_TASK"] = {
    text = L["confirm_delete_task"],
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, task)
        RemoveTask(task)
        if ui.editor then ui.editor:Hide() end
        Publish()
        C.UpdateView()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function SolidPopup(parent, w, h)
    local f = UI.CreateBox(parent)
    f:SetSize(w, h)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:EnableMouse(true)
    if f.SetBackdropColor then f:SetBackdropColor(0.05, 0.05, 0.05, 0.97) end
    f:Hide()
    return f
end

local function UpdateEditor()
    local e = ui.editor
    e.btnPeriod:SetText(L["editor_period"]:format(L["period_" .. draft.period]))
    e.btnScope:SetText(L["editor_scope"]:format(L["scope_" .. draft.scope]))
end

local function ShowEditor(task)
    editing = task
    draft = task and { period = task.period, scope = task.scope } or { period = state.period, scope = "char" }
    local e = ui.editor
    e.header:SetText(task and L["editor_edit"] or L["editor_new"])
    e.title:SetText(task and task.title or "")
    e.target:SetText(task and task.target and tostring(task.target) or "")
    e.note:SetText(task and task.note or "")
    e.btnDelete:SetShown(task ~= nil)
    UpdateEditor()
    e:Show()
end

local function ReadEditor()
    local e = ui.editor
    local title = e.title:GetText():gsub("^%s+", ""):gsub("%s+$", "")
    local target = tonumber(e.target:GetText())
    target = target and math.floor(target) or nil
    if target and target < 2 then target = nil end   -- счётчик 0/1 равен обычной галочке
    return title, target, e.note:GetText()
end

local function SaveEditor()
    local title, target, note = ReadEditor()
    if title == "" then ns.Say(L["err_task_title"]) return end
    if editing then
        local t = editing
        if t.scope ~= draft.scope then
            RemoveTask(t)
            t.scope = draft.scope
            local list = Container(t.scope).tasks
            list[#list + 1] = t
        end
        t.title, t.period, t.note = title, draft.period, note
        t.target = target
        if target then SetCount(t, t.count or 0) else t.count = 0 end
    else
        NewTask({ title = title, period = draft.period, scope = draft.scope, target = target, note = note })
    end
    ui.editor:Hide()
    Publish()
    C.UpdateView()
end

local function CreateEditor(parent)
    local e = SolidPopup(parent, 380, 300)
    ui.editor = e

    e.header = e:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    e.header:SetPoint("TOP", 0, -12)

    local function Label(text, y)
        local fs = e:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("TOPLEFT", 16, y)
        fs:SetText(text)
    end

    Label(L["editor_title"], -40)
    e.title = UI.CreateEditBox(e, 100)
    e.title:SetPoint("TOPLEFT", 20, -56)
    e.title:SetPoint("TOPRIGHT", -16, -56)
    e.title:SetMaxLetters(100)

    e.btnPeriod = UI.CreateButton(e, "", 170, 22, function()
        local i = 1
        for n, p in ipairs(PERIODS) do if p == draft.period then i = n end end
        draft.period = PERIODS[i % #PERIODS + 1]
        UpdateEditor()
    end)
    e.btnPeriod:SetPoint("TOPLEFT", 16, -88)
    e.btnScope = UI.CreateButton(e, "", 170, 22, function()
        draft.scope = draft.scope == "char" and "account" or "char"
        UpdateEditor()
    end)
    e.btnScope:SetPoint("LEFT", e.btnPeriod, "RIGHT", 4, 0)

    Label(L["editor_target"], -122)
    e.target = UI.CreateEditBox(e, 80)
    e.target:SetPoint("TOPLEFT", 20, -138)
    e.target:SetNumeric(true)
    e.target:SetMaxLetters(3)

    Label(L["editor_note"], -166)
    e.note = UI.CreateEditBox(e, 100)
    e.note:SetPoint("TOPLEFT", 20, -182)
    e.note:SetPoint("TOPRIGHT", -16, -182)
    e.note:SetMaxLetters(200)

    e.btnSave = UI.CreateButton(e, L["btn_save"], 100, 22, SaveEditor)
    e.btnSave:SetPoint("BOTTOMLEFT", 16, 40)
    e.btnCancel = UI.CreateButton(e, L["btn_cancel"], 100, 22, function() e:Hide() end)
    e.btnCancel:SetPoint("LEFT", e.btnSave, "RIGHT", 4, 0)
    e.btnDelete = UI.CreateButton(e, L["btn_delete"], 100, 22, function()
        if editing then StaticPopup_Show("CHRONICLE_DELETE_TASK", editing.title, nil, editing) end
    end)
    e.btnDelete:SetPoint("LEFT", e.btnCancel, "RIGHT", 4, 0)
    e.btnTpl = UI.CreateButton(e, L["editor_save_tpl"], 130, 22, function()
        local title, target = ReadEditor()
        if title == "" then ns.Say(L["err_task_title"]) return end
        local tpls = ns.db.checklist.templates
        tpls[#tpls + 1] = { title = title, period = draft.period, scope = draft.scope, target = target }
        ns.Say(L["editor_tpl_saved"])
        if ui.tplList then ui.tplList:SetCount(#tpls) end
    end)
    e.btnTpl:SetPoint("BOTTOMLEFT", 16, 12)
end

local function CreateTemplates(parent)
    local w = SolidPopup(parent, 380, 320)
    ui.templates = w
    local header = w:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOP", 0, -12)
    header:SetText(L["templates_title"])
    local hint = w:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 16, -38)
    hint:SetPoint("TOPRIGHT", -16, -38)
    hint:SetText(L["templates_hint"])

    ui.tplList = UI.CreateList(w, 22,
        function(row)
            row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            row.text:SetPoint("LEFT", 4, 0)
            row.text:SetPoint("RIGHT", -26, 0)
            row.text:SetJustifyH("LEFT")
            row.del = CreateFrame("Button", nil, row, "UIPanelCloseButton")
            row.del:SetSize(22, 22)
            row.del:SetPoint("RIGHT", 0, 0)
            row.del:SetScript("OnClick", function()
                table.remove(ns.db.checklist.templates, row.idx)
                ui.tplList:SetCount(#ns.db.checklist.templates)
            end)
            row:SetScript("OnClick", function()
                local t = ns.db.checklist.templates[row.idx]
                if t then
                    NewTask({ title = t.title, period = t.period, scope = t.scope, target = t.target })
                    state.period = t.period
                    Publish()
                    C.UpdateView()
                end
            end)
        end,
        function(row, idx)
            local t = ns.db.checklist.templates[idx]
            row.idx = idx
            row.text:SetText(t.title .. "  |cff888888" .. L["period_" .. t.period] .. "|r")
        end)
    ui.tplList.frame:SetPoint("TOPLEFT", 12, -60)
    ui.tplList.frame:SetPoint("BOTTOMRIGHT", -12, 44)
    ui.tplEmpty = ui.tplList.frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    ui.tplEmpty:SetPoint("CENTER")
    ui.tplEmpty:SetText(L["templates_empty"])

    local close = UI.CreateButton(w, L["btn_close"], 100, 22, function() w:Hide() end)
    close:SetPoint("BOTTOM", 0, 12)
    w:SetScript("OnShow", function() ui.tplList:SetCount(#ns.db.checklist.templates) end)
    ui.tplList.Refresh0 = ui.tplList.Refresh
    function ui.tplList:Refresh()
        self:Refresh0()
        ui.tplEmpty:SetShown(self.count == 0)
    end
end

---------------------------------------------------------------------------
-- Список задач
---------------------------------------------------------------------------

local function BuildView()
    wipe(view)
    for _, scope in ipairs(SCOPES) do
        for _, t in ipairs(Container(scope).tasks) do
            if t.period == state.period then view[#view + 1] = t end
        end
    end
    -- Выполненные уходят вниз, внутри группы — по порядку
    table.sort(view, function(a, b)
        if a.done ~= b.done then return not a.done end
        return (a.order or 0) < (b.order or 0)
    end)
end

local function Move(task, dir)
    local idx
    for i, t in ipairs(view) do if t == task then idx = i end end
    local other = idx and view[idx + dir]
    if not other or other.done ~= task.done then return end
    task.order, other.order = other.order, task.order
    C.UpdateView()
end

local function InitRow(row)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.check:SetSize(24, 24)
    row.check:SetPoint("LEFT", 2, 0)
    row.check:SetScript("OnClick", function()
        Toggle(row.task)
        Publish()
        C.UpdateView()
    end)

    row.edit = UI.CreateButton(row, L["checklist_edit"], 44, 20, function() ShowEditor(row.task) end)
    row.edit:SetPoint("RIGHT", -2, 0)

    local function Arrow(dir, anchor, name)
        local b = CreateFrame("Button", nil, row)
        b:SetSize(20, 20)
        b:SetPoint("RIGHT", anchor, "LEFT", -2, 0)
        local base = "Interface\\Buttons\\UI-ScrollBar-Scroll" .. name .. "Button-"
        b:SetNormalTexture(base .. "Up")
        b:SetPushedTexture(base .. "Down")
        b:SetDisabledTexture(base .. "Disabled")
        b:SetHighlightTexture(base .. "Highlight")
        b:SetScript("OnClick", function() Move(row.task, dir) end)
        return b
    end
    row.down = Arrow(1, row.edit, "Down")
    row.up = Arrow(-1, row.down, "Up")

    row.plus = UI.CreateButton(row, "+", 22, 20, function()
        SetCount(row.task, (row.task.count or 0) + 1)
        Publish()
        C.UpdateView()
    end)
    row.plus:SetPoint("RIGHT", row.up, "LEFT", -8, 0)
    row.count = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.count:SetPoint("RIGHT", row.plus, "LEFT", -2, 0)
    row.count:SetWidth(44)
    row.count:SetJustifyH("CENTER")
    row.minus = UI.CreateButton(row, "-", 22, 20, function()
        SetCount(row.task, (row.task.count or 0) - 1)
        Publish()
        C.UpdateView()
    end)
    row.minus:SetPoint("RIGHT", row.count, "LEFT", -2, 0)

    row.title = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.title:SetPoint("LEFT", row.check, "RIGHT", 2, 0)
    row.title:SetPoint("RIGHT", row.minus, "LEFT", -6, 0)
    row.title:SetJustifyH("LEFT")
    row.title:SetWordWrap(false)

    -- Линия поверх выполненной задачи («зачёркнуто»)
    row.strike = row:CreateTexture(nil, "OVERLAY")
    row.strike:SetHeight(1)
    row.strike:SetColorTexture(0.6, 0.6, 0.6, 0.9)
    row.strike:SetPoint("LEFT", row.title, "LEFT", 0, 0)
end

local function SetupRow(row, idx)
    local t = view[idx]
    row.task = t
    row.check:SetChecked(t.done)
    local text = t.title
    if t.scope == "account" then text = text .. "  |cff88aaff" .. L["scope_account_tag"] .. "|r" end
    row.title:SetText(text)
    if t.done then
        row.title:SetTextColor(0.55, 0.55, 0.55)
        row.strike:SetWidth(math.min(row.title:GetStringWidth(), math.max(row:GetWidth() - 190, 20)))
        row.strike:Show()
    else
        row.title:SetTextColor(1, 1, 1)
        row.strike:Hide()
    end
    row.minus:SetShown(t.target ~= nil)
    row.plus:SetShown(t.target ~= nil)
    row.count:SetShown(t.target ~= nil)
    if t.target then row.count:SetText((t.count or 0) .. "/" .. t.target) end
    local prev, nxt = view[idx - 1], view[idx + 1]
    row.up:SetEnabled(prev ~= nil and prev.done == t.done)
    row.down:SetEnabled(nxt ~= nil and nxt.done == t.done)
end

---------------------------------------------------------------------------
-- Режим «Альты»: задачи × персонажи
---------------------------------------------------------------------------

local CELL_W, NAME_W, ALT_ROW_H = 90, 220, 22
local altCells = {}   -- пул текстовых полей

local function AltCell(i)
    local fs = altCells[i]
    if not fs then
        fs = ui.altsChild:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        altCells[i] = fs
    end
    fs:Show()
    return fs
end

local READY = "|TInterface\\RaidFrame\\ReadyCheck-Ready:16|t"
local NOTREADY = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:16|t"

local function BuildAlts()
    local now = GetServerTime()
    local chars = {}
    for key, rec in pairs(ns.db.characters) do
        if rec.checklist then chars[#chars + 1] = key end
    end
    table.sort(chars, function(a, b)
        if (a == ns.charKey) ~= (b == ns.charKey) then return a == ns.charKey end
        return a < b
    end)

    -- Строки: название → { account = задача } или { [персонаж] = снимок задачи }
    local rows, byTitle = {}, {}
    local function RowFor(title, account)
        local k = title .. (account and "\1a" or "")
        if not byTitle[k] then
            byTitle[k] = { title = title, account = account, cells = {} }
            rows[#rows + 1] = byTitle[k]
        end
        return byTitle[k]
    end
    for _, t in ipairs(ns.db.checklist.tasks) do
        if t.period == state.period then RowFor(t.title, true).task = t end
    end
    for _, key in ipairs(chars) do
        local snap = ns.db.characters[key].checklist
        local stale = now >= (snap.nextReset[state.period] or math.huge)   -- сброс уже был, а персонаж не заходил
        for _, t in ipairs(snap.tasks) do
            if t.period == state.period then
                RowFor(t.title, false).cells[key] = { target = t.target, done = t.done and not stale,
                                                       count = stale and 0 or t.count }
            end
        end
    end

    for _, fs in ipairs(altCells) do fs:Hide() end
    ui.altsEmpty:SetShown(#rows == 0 or #chars == 0)
    local n = 0
    local function Put(text, x, y, width, justify)
        n = n + 1
        local fs = AltCell(n)
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", ui.altsChild, "TOPLEFT", x, y)
        fs:SetWidth(width)
        fs:SetJustifyH(justify or "CENTER")
        fs:SetText(text)
    end

    for c, key in ipairs(chars) do
        Put(ClassColored(key), NAME_W + (c - 1) * CELL_W, -4, CELL_W - 4)
    end
    for r, row in ipairs(rows) do
        local y = -4 - r * ALT_ROW_H
        Put(row.title .. (row.account and "  |cff88aaff" .. L["scope_account_tag"] .. "|r" or ""), 4, y, NAME_W - 10, "LEFT")
        for c, key in ipairs(chars) do
            local cell = row.account and row.task or row.cells[key]
            local x = NAME_W + (c - 1) * CELL_W
            if not cell then
                Put("|cff666666—|r", x, y, CELL_W - 4)
            elseif cell.target then
                local color = cell.done and "|cff33ff33" or "|cffffffff"
                Put(color .. (cell.count or 0) .. "/" .. cell.target .. "|r", x, y, CELL_W - 4)
            else
                Put(cell.done and READY or NOTREADY, x, y, CELL_W - 4)
            end
        end
    end
    ui.altsChild:SetSize(NAME_W + #chars * CELL_W, 8 + (#rows + 1) * ALT_ROW_H)
end

---------------------------------------------------------------------------
-- Экран вкладки
---------------------------------------------------------------------------

local function UpdateTimer()
    local nextReset = ns.db.checklist.nextReset[state.period]
    if nextReset then
        ui.timer:SetText(L["checklist_reset_in"]:format(ns.FormatDuration(nextReset - GetServerTime())))
        ui.timer2:SetText(L["reset_at"]:format(ns.FormatBoth(nextReset, "%d.%m %H:%M")))
    else
        ui.timer:SetText("")
        ui.timer2:SetText("")
    end
end

function C.UpdateView()
    if not ui.root then return end
    for _, p in ipairs(PERIODS) do
        if p == state.period then ui.periodBtn[p]:LockHighlight() else ui.periodBtn[p]:UnlockHighlight() end
    end
    ui.btnAlts:SetText(state.alts and L["checklist_tasks"] or L["checklist_alts"])
    ui.list.frame:SetShown(not state.alts)
    ui.altsBox:SetShown(state.alts)
    ui.btnAdd:SetEnabled(not state.alts)
    UpdateTimer()
    if state.alts then
        BuildAlts()
    else
        BuildView()
        ui.list:SetCount(#view)
        ui.empty:SetShown(#view == 0)
    end
end

local function Create(frame)
    ui.root = frame

    -- Период и таймер
    ui.periodBtn = {}
    local prev
    for _, p in ipairs(PERIODS) do
        local b = UI.CreateButton(frame, L["period_" .. p], 90, 22, function()
            state.period = p
            C.UpdateView()
        end)
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 2, 0) else b:SetPoint("TOPLEFT", 4, -4) end
        ui.periodBtn[p] = b
        prev = b
    end
    ui.timer = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ui.timer:SetPoint("LEFT", prev, "RIGHT", 12, 0)

    ui.timer2 = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.timer2:SetPoint("TOPLEFT", 8, -57)

    -- Действия
    ui.btnAdd = UI.CreateButton(frame, L["checklist_add"], 110, 22, function() ShowEditor(nil) end)
    ui.btnAdd:SetPoint("TOPLEFT", 4, -30)
    ui.btnTemplates = UI.CreateButton(frame, L["checklist_templates"], 110, 22, function()
        ui.templates:SetShown(not ui.templates:IsShown())
    end)
    ui.btnTemplates:SetPoint("LEFT", ui.btnAdd, "RIGHT", 2, 0)
    ui.btnAlts = UI.CreateButton(frame, L["checklist_alts"], 110, 22, function()
        state.alts = not state.alts
        C.UpdateView()
    end)
    ui.btnAlts:SetPoint("LEFT", ui.btnTemplates, "RIGHT", 2, 0)

    -- Список задач
    ui.list = UI.CreateList(frame, ROW_H, InitRow, SetupRow)
    ui.list.frame:SetPoint("TOPLEFT", 4, -74)
    ui.list.frame:SetPoint("BOTTOMRIGHT", -4, 4)
    ui.empty = ui.list.frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    ui.empty:SetPoint("CENTER")
    ui.empty:SetText(L["checklist_empty"])

    -- Таблица альтов
    ui.altsBox = UI.CreateBox(frame)
    ui.altsBox:SetPoint("TOPLEFT", 4, -74)
    ui.altsBox:SetPoint("BOTTOMRIGHT", -4, 4)
    local sf = CreateFrame("ScrollFrame", nil, ui.altsBox, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 6, -6)
    sf:SetPoint("BOTTOMRIGHT", -28, 6)
    ui.altsChild = CreateFrame("Frame", nil, sf)
    ui.altsChild:SetSize(10, 10)
    sf:SetScrollChild(ui.altsChild)
    ui.altsEmpty = ui.altsBox:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    ui.altsEmpty:SetPoint("CENTER")
    ui.altsEmpty:SetText(L["checklist_alts_empty"])
    ui.altsBox:Hide()

    CreateEditor(frame)
    CreateTemplates(frame)

    -- Таймер обновляется, пока вкладка видна
    local acc = 0
    frame:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + elapsed
        if acc >= 1 then
            acc = 0
            UpdateTimer()
        end
    end)
    frame:SetScript("OnShow", function()
        C.CheckResets()
        C.UpdateView()
    end)

    C.UpdateView()
end

ns.refresh.checklist = function()
    for _, rec in pairs(ns.db.characters) do rec.checklist = nil end   -- копии для режима «Альты»
    Publish()
    C.UpdateView()
end

ns:RegisterModule("checklist", "tab_checklist", nil, Create)
