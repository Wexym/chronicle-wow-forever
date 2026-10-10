-- Вкладка «Цели»: долгие цели с прогрессом (золото, навык профессии, уровень, свой счётчик).
local ADDON, ns = ...
local L = ns.L
local UI = ns.UI

local G = {}
ns.Goals = G

local TYPES = { "gold", "prof", "level", "manual" }
local ROW_H = 48
local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"

---------------------------------------------------------------------------
-- Данные и прогресс
---------------------------------------------------------------------------

local function CharName(key)
    return key and (key:match("^(.-)%-") or key) or "?"
end

local function NeedsChar(g)
    return g.type == "prof" or g.type == "level" or (g.type == "gold" and g.scope == "char")
end

-- Текущее значение прогресса и цель в тех же единицах (золото считаем в меди)
local function Progress(g)
    local chars = ns.db.characters
    if g.type == "manual" then
        return g.current or 0, g.target
    elseif g.type == "gold" then
        local sum = 0
        if g.scope == "char" then
            sum = (g.char == ns.charKey) and GetMoney() or ((chars[g.char] or {}).money or 0)
        else
            for key, rec in pairs(chars) do
                sum = sum + ((key == ns.charKey) and GetMoney() or (rec.money or 0))
            end
        end
        return sum, g.target * 10000
    elseif g.type == "level" then
        local lvl = (g.char == ns.charKey) and UnitLevel("player") or ((chars[g.char] or {}).level or 0)
        return lvl, g.target
    elseif g.type == "prof" then
        local rec = chars[g.char]
        local want = ns.Lower(g.prof or "")
        for _, p in ipairs(rec and rec.profs or {}) do
            if ns.Lower(p.name) == want then return p.rank or 0, g.target end
        end
        return 0, g.target
    end
    return 0, g.target
end

local function NewId()
    local goals = ns.db.goals
    goals.nextId = goals.nextId + 1
    return goals.nextId - 1
end

-- Достигнутая цель остаётся выполненной, даже если золото потом потратили
local function Complete(g)
    g.done = true
    g.doneAt = GetServerTime()
    ns.Say(L["goal_done"]:format(g.title))
    if ns.db.settings.journalAuto.goal and ns.Journal then
        ns.Journal.Add("goal", L["j_goal"]:format(g.title), "", "")
    end
end

function G.Check()
    if not ns.db or not ns.charKey then return end
    local changed = false
    for _, g in ipairs(ns.db.goals.list) do
        if not g.done then
            local cur, target = Progress(g)
            if cur >= target and target > 0 then
                Complete(g)
                changed = true
            end
        end
    end
    if changed and G.OnChanged then G.OnChanged() end
end

ns:OnLogin(function()
    G.Check()
    C_Timer.NewTicker(30, G.Check)
end)

---------------------------------------------------------------------------
-- Интерфейс
---------------------------------------------------------------------------

local state = { show = "active" }   -- active | done | all
local ui = {}
local view = {}
local editing, draft

local function Rebuild()
    if not ui.list then return end
    wipe(view)
    for _, g in ipairs(ns.db.goals.list) do
        if state.show == "all" or (state.show == "done") == (g.done == true) then
            view[#view + 1] = g
        end
    end
    table.sort(view, function(a, b)
        if a.done ~= b.done then return not a.done end
        if a.done then return (a.doneAt or 0) > (b.doneAt or 0) end
        return a.id < b.id
    end)
    ui.list:SetCount(#view)
    ui.empty:SetShown(#view == 0)
    local key = state.show == "active" and "goals_show_active" or state.show == "done" and "goals_show_done" or "goals_show_all"
    ui.btnShow:SetText(L[key])
end

function G.Refresh()
    if ui.root and ui.root:IsVisible() then Rebuild() end
end

local function ProgressText(g, cur, target)
    if g.type == "gold" then
        return ns.FormatMoney(cur) .. " / " .. ns.FormatNumber(g.target) .. GOLD_ICON
    end
    return ("%s / %s"):format(ns.FormatNumber(cur), ns.FormatNumber(target))
end

local function SetupRow(row, idx)
    local g = view[idx]
    row.goal = g
    local cur, target = Progress(g)
    local pct = target > 0 and math.min(1, cur / target) or 0
    if g.done then pct = 1 end

    local tag = ""
    if NeedsChar(g) then tag = "  |cff888888" .. CharName(g.char) .. "|r" end
    if g.type == "prof" then tag = "  |cff888888" .. (g.prof or "") .. " · " .. CharName(g.char) .. "|r" end
    if g.type == "gold" and g.scope ~= "char" then tag = "  |cff888888" .. L["scope_account"] .. "|r" end
    row.title:SetText(g.title .. tag)

    row.bar:SetValue(pct)
    if g.done then row.bar:SetStatusBarColor(0.2, 0.8, 0.2) else row.bar:SetStatusBarColor(0.2, 0.5, 1) end
    if g.done then
        row.text:SetText(L["goal_done_at"]:format(ns.FormatBoth(g.doneAt or 0, "%d.%m.%Y")))
    else
        row.text:SetText(ProgressText(g, cur, target) .. string.format("  (%d%%)", pct * 100))
    end
    local manual = g.type == "manual" and not g.done
    row.minus:SetShown(manual)
    row.plus:SetShown(manual)
end

local function ChangeManual(g, delta)
    g.current = math.max(0, (g.current or 0) + delta)
    G.Check()
    Rebuild()
end

-- Редактор цели
local function UpdateEditor()
    local e = ui.editor
    e.btnType:SetText(L["goal_type"]:format(L["goal_type_" .. draft.type]))
    e.btnScope:SetText(L["goal_scope"]:format(draft.scope == "char" and L["scope_char"] or L["scope_account"]))
    e.btnScope:SetShown(draft.type == "gold")
    local needChar = draft.type ~= "manual" and (draft.type ~= "gold" or draft.scope == "char")
    e.btnChar:SetShown(needChar)
    e.btnChar:SetText(L["goal_char"]:format(CharName(draft.char)))
    e.profLabel:SetShown(draft.type == "prof")
    e.prof:SetShown(draft.type == "prof")
    e.targetLabel:SetText(L["goal_target_" .. draft.type])
end

local function ShowEditor(goal)
    editing = goal
    draft = goal and { type = goal.type, scope = goal.scope or "account", char = goal.char or ns.charKey }
        or { type = "gold", scope = "account", char = ns.charKey }
    local e = ui.editor
    e.header:SetText(goal and L["goal_edit"] or L["goal_new"])
    e.title:SetText(goal and goal.title or "")
    e.prof:SetText(goal and goal.prof or "")
    e.target:SetText(goal and tostring(goal.target) or "")
    e.btnDelete:SetShown(goal ~= nil)
    e.btnReopen:SetShown(goal ~= nil and goal.done == true)
    UpdateEditor()
    e:Show()
end

local function SaveEditor()
    local e = ui.editor
    local title = e.title:GetText():gsub("^%s+", ""):gsub("%s+$", "")
    local target = tonumber(e.target:GetText())
    if title == "" then ns.Say(L["goal_err_title"]) return end
    if not target or target < 1 then ns.Say(L["goal_err_target"]) return end
    local prof = e.prof:GetText():gsub("^%s+", ""):gsub("%s+$", "")
    if draft.type == "prof" and prof == "" then ns.Say(L["goal_err_prof"]) return end
    local g = editing
    if not g then
        g = { id = NewId(), current = 0 }
        ns.db.goals.list[#ns.db.goals.list + 1] = g
    end
    g.title, g.type, g.target = title, draft.type, math.floor(target)
    g.scope = draft.type == "gold" and draft.scope or (draft.type == "manual" and "account" or "char")
    g.char = NeedsChar(g) and draft.char or nil
    g.prof = draft.type == "prof" and prof or nil
    e:Hide()
    G.Check()
    Rebuild()
end

StaticPopupDialogs["CHRONICLE_DELETE_GOAL"] = {
    text = L["goal_delete_confirm"],
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, goal)
        local list = ns.db.goals.list
        for i, g in ipairs(list) do
            if g == goal then table.remove(list, i) break end
        end
        if ui.editor then ui.editor:Hide() end
        Rebuild()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function CharList()
    local list, seen = {}, {}
    if ns.charKey then list[1], seen[ns.charKey] = ns.charKey, true end
    local rest = {}
    for key in pairs(ns.db.characters) do
        if not seen[key] then rest[#rest + 1] = key end
    end
    table.sort(rest)
    for _, k in ipairs(rest) do list[#list + 1] = k end
    return list
end

local function CreateEditor(parent)
    local e = UI.SolidPopup(parent, 400, 330)
    ui.editor = e
    e.header = e:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    e.header:SetPoint("TOP", 0, -12)

    local function Label(y)
        local fs = e:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("TOPLEFT", 16, y)
        return fs
    end
    Label(-40):SetText(L["goal_title"])
    e.title = UI.CreateEditBox(e, 100)
    e.title:SetPoint("TOPLEFT", 20, -56)
    e.title:SetPoint("TOPRIGHT", -16, -56)
    e.title:SetMaxLetters(100)

    e.btnType = UI.CreateButton(e, "", 200, 22, function()
        local i = 1
        for n, t in ipairs(TYPES) do if t == draft.type then i = n end end
        draft.type = TYPES[i % #TYPES + 1]
        UpdateEditor()
    end)
    e.btnType:SetPoint("TOPLEFT", 16, -88)
    e.btnScope = UI.CreateButton(e, "", 170, 22, function()
        draft.scope = draft.scope == "char" and "account" or "char"
        UpdateEditor()
    end)
    e.btnScope:SetPoint("LEFT", e.btnType, "RIGHT", 4, 0)
    e.btnChar = UI.CreateButton(e, "", 250, 22, function()
        local list = CharList()
        local idx = 1
        for i, k in ipairs(list) do if k == draft.char then idx = i end end
        draft.char = list[idx % #list + 1]
        UpdateEditor()
    end)
    e.btnChar:SetPoint("TOPLEFT", 16, -118)

    e.profLabel = Label(-148)
    e.profLabel:SetText(L["goal_prof"])
    e.prof = UI.CreateEditBox(e, 100)
    e.prof:SetPoint("TOPLEFT", 20, -164)
    e.prof:SetPoint("TOPRIGHT", -16, -164)
    e.prof:SetMaxLetters(60)

    e.targetLabel = Label(-194)
    e.target = UI.CreateEditBox(e, 120)
    e.target:SetPoint("TOPLEFT", 20, -210)
    e.target:SetNumeric(true)
    e.target:SetMaxLetters(9)

    e.btnSave = UI.CreateButton(e, L["btn_save"], 100, 22, SaveEditor)
    e.btnSave:SetPoint("BOTTOMLEFT", 16, 40)
    e.btnCancel = UI.CreateButton(e, L["btn_cancel"], 100, 22, function() e:Hide() end)
    e.btnCancel:SetPoint("LEFT", e.btnSave, "RIGHT", 4, 0)
    e.btnDelete = UI.CreateButton(e, L["btn_delete"], 100, 22, function()
        if editing then StaticPopup_Show("CHRONICLE_DELETE_GOAL", editing.title, nil, editing) end
    end)
    e.btnDelete:SetPoint("LEFT", e.btnCancel, "RIGHT", 4, 0)
    e.btnReopen = UI.CreateButton(e, L["goal_reopen"], 200, 22, function()
        if editing then
            editing.done, editing.doneAt = false, nil
            e:Hide()
            G.Check()
            Rebuild()
        end
    end)
    e.btnReopen:SetPoint("BOTTOMLEFT", 16, 12)
end

local function Create(frame)
    ui.root = frame

    ui.btnAdd = UI.CreateButton(frame, L["goal_add"], 110, 22, function() ShowEditor(nil) end)
    ui.btnAdd:SetPoint("TOPLEFT", 4, -4)
    ui.btnShow = UI.CreateButton(frame, "", 150, 22, function()
        state.show = state.show == "active" and "done" or state.show == "done" and "all" or "active"
        Rebuild()
    end)
    ui.btnShow:SetPoint("LEFT", ui.btnAdd, "RIGHT", 2, 0)

    ui.list = UI.CreateList(frame, ROW_H,
        function(row)
            row.bg = row:CreateTexture(nil, "BACKGROUND")
            row.bg:SetPoint("TOPLEFT", 0, -1)
            row.bg:SetPoint("BOTTOMRIGHT", 0, 1)
            row.bg:SetColorTexture(1, 1, 1, 0.05)

            row.title = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.title:SetPoint("TOPLEFT", 8, -5)
            row.title:SetPoint("TOPRIGHT", -8, -5)
            row.title:SetJustifyH("LEFT")
            row.title:SetWordWrap(false)

            row.bar = CreateFrame("StatusBar", nil, row)
            row.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
            row.bar:SetMinMaxValues(0, 1)
            row.bar:SetPoint("BOTTOMLEFT", 8, 6)
            row.bar:SetPoint("BOTTOMRIGHT", -104, 6)
            row.bar:SetHeight(16)
            row.barBg = row.bar:CreateTexture(nil, "BACKGROUND")
            row.barBg:SetAllPoints()
            row.barBg:SetColorTexture(0, 0, 0, 0.5)
            row.text = row.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.text:SetPoint("CENTER")

            row.edit = UI.CreateButton(row, L["checklist_edit"], 44, 20, function() ShowEditor(row.goal) end)
            row.edit:SetPoint("BOTTOMRIGHT", -2, 8)
            row.plus = UI.CreateButton(row, "+", 22, 20, function() ChangeManual(row.goal, 1) end)
            row.plus:SetPoint("RIGHT", row.edit, "LEFT", -2, 0)
            row.minus = UI.CreateButton(row, "-", 22, 20, function() ChangeManual(row.goal, -1) end)
            row.minus:SetPoint("RIGHT", row.plus, "LEFT", -2, 0)
        end,
        SetupRow)
    ui.list.frame:SetPoint("TOPLEFT", 4, -32)
    ui.list.frame:SetPoint("BOTTOMRIGHT", -4, 4)
    ui.empty = ui.list.frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    ui.empty:SetPoint("CENTER")
    ui.empty:SetText(L["goals_empty"])

    CreateEditor(frame)
    G.OnChanged = G.Refresh

    -- Прогресс меняется сам (золото, навык), поэтому обновляем раз в несколько секунд, пока вкладка видна
    local acc = 0
    frame:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + elapsed
        if acc >= 3 then
            acc = 0
            ui.list:Refresh()
        end
    end)
    frame:SetScript("OnShow", function()
        G.Check()
        Rebuild()
    end)
    Rebuild()
end

ns:RegisterModule("goals", "tab_goals", nil, Create)
