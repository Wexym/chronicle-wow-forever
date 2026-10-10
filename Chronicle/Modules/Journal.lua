-- Вкладка «Журнал»: личные записи и автоматические отметки о событиях.
local ADDON, ns = ...
local L = ns.L
local UI = ns.UI

local J = {}
ns.Journal = J

local TEXT_LIMIT = 4000
local ROW_H = 20
local MINSK_OFFSET = 3 * 3600
local EPIC_COLORS = { ["a335ee"] = true, ["ff8000"] = true, ["e6cc80"] = true, ["00ccff"] = true }

-- Значок и цвет по типу записи; у автозаписей свои
local KINDS = {
    manual = { icon = "Interface\\Icons\\INV_Misc_Note_01",            r = 1,   g = 0.82, b = 0 },
    level  = { icon = "Interface\\Icons\\Spell_Holy_SurgeOfLight",     r = 0.4, g = 0.8,  b = 1 },
    death  = { icon = "Interface\\Icons\\Ability_Rogue_FeignDeath",    r = 1,   g = 0.4,  b = 0.4 },
    boss   = { icon = "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01", r = 1,   g = 0.6,  b = 0.2 },
    goal   = { icon = "Interface\\Icons\\Achievement_Quests_Completed_08", r = 0.3, g = 0.9, b = 0.3 },
    wish   = { icon = "Interface\\Icons\\INV_Misc_Gift_01", r = 1, g = 0.5, b = 0.8 },
    epic   = { icon = "Interface\\Icons\\INV_Misc_Gem_Amethyst_02",    r = 0.64, g = 0.21, b = 0.93 },
}
local AUTO_KINDS = { "level", "death", "boss", "epic", "goal", "wish" }

---------------------------------------------------------------------------
-- Данные
---------------------------------------------------------------------------

local function FirstLine(text)
    return text and text:match("[^\r\n]+") or ""
end

-- Создаёт запись. Дата, персонаж, уровень и зона заполняются автоматически.
function J.Add(kind, title, text, tags)
    local j = ns.db.journal
    local e = {
        id = j.nextId, ts = GetServerTime(),
        title = title or "", text = text or "", tags = tags or "",
        kind = kind, auto = kind ~= "manual",
        char = ns.charKey, level = UnitLevel("player"), zone = ns.Players.CurrentPlace(),
    }
    j.nextId = j.nextId + 1
    j.entries[#j.entries + 1] = e
    if J.OnChanged then J.OnChanged() end
    return e
end

local function AutoEnabled(kind)
    return ns.db.settings.journalAuto[kind]
end

-- /chron auto level on|off
function J.SetAuto(arg)
    local kind, state = (arg or ""):match("^(%S+)%s+(%S+)$")
    if not kind or (state ~= "on" and state ~= "off") then
        ns.Say(L["auto_usage"])
        return
    end
    local known = false
    for _, k in ipairs(AUTO_KINDS) do if k == kind then known = true end end
    if not known then ns.Say(L["auto_usage"]) return end
    ns.db.settings.journalAuto[kind] = state == "on"
    ns.Say(L["auto_state"]:format(L["j_auto_" .. kind], state == "on" and L["on"] or L["off"]))
end

function J.Quick(text)
    if not text or text == "" then
        J.OpenQuick()
        return
    end
    J.Add("manual", "", text:sub(1, TEXT_LIMIT), "")
    ns.Say(L["j_quick_saved"])
end

---------------------------------------------------------------------------
-- Автозаписи
---------------------------------------------------------------------------

local seenBoss = {}   -- защита от двойного срабатывания ENCOUNTER_END и BOSS_KILL

local function OnBossKilled(id, name)
    if not AutoEnabled("boss") or not name then return end
    local now = GetTime()
    if seenBoss[id or name] and now - seenBoss[id or name] < 60 then return end
    seenBoss[id or name] = now
    local _, instType = GetInstanceInfo()
    if instType ~= "raid" and instType ~= "party" then return end
    -- Записываем только первое убийство каждого босса персонажем
    local firsts = ns.db.journal.firsts
    local key = ns.charKey .. ":" .. tostring(id or name)
    if firsts[key] then return end
    firsts[key] = true
    local fmt = instType == "raid" and L["j_boss_raid"] or L["j_boss_dungeon"]
    J.Add("boss", fmt:format(name), "", "")
end

ns:OnLogin(function()
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_LEVEL_UP")
    f:RegisterEvent("PLAYER_DEAD")
    f:RegisterEvent("ENCOUNTER_END")
    f:RegisterEvent("BOSS_KILL")
    f:SetScript("OnEvent", function(_, event, arg1, arg2, _, _, arg5)
        if event == "PLAYER_LEVEL_UP" then
            if AutoEnabled("level") then J.Add("level", L["j_level"]:format(arg1), "", "") end
        elseif event == "PLAYER_DEAD" then
            if not AutoEnabled("death") then return end
            local S = ns.Stats
            local killer = S and S.lastDamager
            if killer and S.lastDamagerTime and GetTime() - S.lastDamagerTime <= 15 then
                J.Add("death", L["j_death_by"]:format(killer), "", "")
            else
                J.Add("death", L["j_death"], "", "")
            end
        elseif event == "ENCOUNTER_END" then
            if arg5 == 1 then OnBossKilled(arg1, arg2) end   -- arg5 — успех
        elseif event == "BOSS_KILL" then
            OnBossKilled(arg1, arg2)
        end
    end)

    -- Эпические предметы: используем разбор своей добычи из статистики
    if ns.Stats and ns.Stats.lootHooks then
        table.insert(ns.Stats.lootHooks, function(msg, color)
            if AutoEnabled("epic") and color and EPIC_COLORS[color] then
                local name = msg:match("|h%[(.-)%]|h") or "?"
                J.Add("epic", L["j_epic"]:format(name), "", "")
            end
        end)
    end
end)

---------------------------------------------------------------------------
-- Интерфейс
---------------------------------------------------------------------------

local state = { search = "", kind = nil, char = nil, key = nil, pending = nil }
local ui = {}
local view = {}      -- строки списка: { header = "дата" } или { entry = запись }

local function MinskDay(ts)
    return date("!%d.%m.%Y", ts + MINSK_OFFSET)
end

local function DisplayTitle(e)
    if e.title and e.title ~= "" then return e.title end
    local line = FirstLine(e.text)
    return line ~= "" and line or L["j_untitled"]
end

local function CharName(key)
    return key and (key:match("^(.-)%-") or key) or "?"
end

local function Current()
    if state.pending then return state.pending end
    return state.key and J.Find(state.key) or nil
end

function J.Find(id)
    for _, e in ipairs(ns.db.journal.entries) do
        if e.id == id then return e end
    end
end

local function KnownChars()
    local list, seen = {}, {}
    if ns.charKey then list[1], seen[ns.charKey] = ns.charKey, true end
    local rest = {}
    for _, e in ipairs(ns.db.journal.entries) do
        if e.char and not seen[e.char] then seen[e.char] = true; rest[#rest + 1] = e.char end
    end
    table.sort(rest)
    for _, k in ipairs(rest) do list[#list + 1] = k end
    return list
end

local function UpdateFilterButtons()
    local kindText = state.kind == "manual" and L["j_kind_manual"] or state.kind == "auto" and L["j_kind_auto"] or L["j_kind_all"]
    ui.btnKind:SetText(L["j_filter_kind"]:format(kindText))
    ui.btnChar:SetText(L["j_filter_char"]:format(state.char and CharName(state.char) or L["all"]))
end

local function Rebuild()
    if not ui.list then return end
    local q = ns.Lower(state.search)
    local items = {}
    for _, e in ipairs(ns.db.journal.entries) do
        local ok = true
        if state.kind == "manual" and e.auto then ok = false end
        if state.kind == "auto" and not e.auto then ok = false end
        if ok and state.char and e.char ~= state.char then ok = false end
        if ok and q ~= "" then
            local hay = ns.Lower(e.title .. " " .. e.tags .. " " .. e.text .. " " .. CharName(e.char))
            ok = hay:find(q, 1, true) ~= nil
        end
        if ok then items[#items + 1] = e end
    end
    table.sort(items, function(a, b)
        if a.ts ~= b.ts then return a.ts > b.ts end
        return a.id > b.id
    end)
    wipe(view)
    local lastDay
    for _, e in ipairs(items) do
        local day = MinskDay(e.ts)
        if day ~= lastDay then
            view[#view + 1] = { header = day }
            lastDay = day
        end
        view[#view + 1] = { entry = e }
    end
    ui.list:SetCount(#view)
    ui.empty:SetShown(#items == 0)
end

local loading = false

local function LoadDetail()
    local e = Current()
    loading = true
    if not e then
        ui.body:Hide()
        ui.hint:Show()
        loading = false
        return
    end
    ui.hint:Hide()
    ui.body:Show()
    local isNew = state.pending ~= nil
    ui.btnSave:SetShown(isNew)
    ui.btnCancel:SetShown(isNew)
    ui.btnDelete:SetShown(not isNew)
    ui.btnExportOne:SetShown(not isNew)
    ui.meta1:SetShown(not isNew)
    ui.meta2:SetShown(not isNew)
    ui.header:SetText(isNew and L["j_new"] or L["j_untitled"])
    ui.header:SetShown(isNew)
    if not isNew then
        local k = KINDS[e.kind] or KINDS.manual
        ui.meta1:SetText(ns.FormatBoth(e.ts, "%d.%m.%Y %H:%M"))
        ui.meta2:SetText(L["j_meta"]:format(e.auto and L["j_type_auto"] or L["j_type_manual"],
            CharName(e.char), tostring(e.level or "?"), e.zone ~= "" and e.zone or L["unknown"]))
        ui.meta2:SetTextColor(k.r, k.g, k.b)
    end
    ui.title:SetText(e.title or "")
    ui.title:SetCursorPosition(0)
    ui.tags:SetText(e.tags or "")
    ui.tags:SetCursorPosition(0)
    ui.text.edit:SetText(e.text or "")
    ui.text.edit:SetCursorPosition(0)
    loading = false
end

function J.Select(id)
    state.pending = nil
    state.key = id
    LoadDetail()
    if ui.list then ui.list:Refresh() end
end

local function StartNew()
    state.pending = { title = "", tags = "", text = "" }
    state.key = nil
    LoadDetail()
    ui.list:Refresh()
    ui.title:SetFocus()
end

local function SaveNew()
    local p = state.pending
    if (p.title or "") == "" and (p.text or "") == "" then return end
    local e = J.Add("manual", p.title, p.text, p.tags)
    state.pending = nil
    J.Select(e.id)
    Rebuild()
end

-- Текст записи для экспорта
local function EntryText(e)
    local lines = {}
    lines[#lines + 1] = ("[%s] %s"):format(ns.FormatBoth(e.ts, "%d.%m.%Y %H:%M"), DisplayTitle(e))
    lines[#lines + 1] = L["j_export_meta"]:format(CharName(e.char), tostring(e.level or "?"),
        e.zone ~= "" and e.zone or L["unknown"], e.auto and (" · " .. L["j_type_auto"]) or "")
    if e.tags ~= "" then lines[#lines + 1] = "#" .. e.tags end
    if e.text ~= "" then lines[#lines + 1] = e.text end
    return table.concat(lines, "\n")
end

local function ShowExport(text)
    local w = ui.export
    w.edit.edit:SetText(text)
    w:Show()
    w.edit.edit:SetFocus()
    w.edit.edit:HighlightText()
end

local function ExportAll()
    local items = {}
    for _, e in ipairs(ns.db.journal.entries) do items[#items + 1] = e end
    if #items == 0 then ShowExport(L["j_export_empty"]) return end
    table.sort(items, function(a, b) return a.ts < b.ts end)   -- в файле удобнее от старых к новым
    local parts = {}
    for _, e in ipairs(items) do parts[#parts + 1] = EntryText(e) end
    ShowExport(table.concat(parts, "\n\n"))
end

StaticPopupDialogs["CHRONICLE_DELETE_ENTRY"] = {
    text = L["confirm_delete_entry"],
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, id)
        local list = ns.db.journal.entries
        for i, e in ipairs(list) do
            if e.id == id then table.remove(list, i) break end
        end
        if state.key == id then state.key = nil end
        Rebuild()
        LoadDetail()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function CreatePopups(parent)
    -- Окно быстрой записи
    local q = UI.SolidPopup(parent, 420, 110)
    ui.quick = q
    local title = q:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -12)
    title:SetText(L["j_quick_title"])
    q.edit = UI.CreateEditBox(q, 100)
    q.edit:SetPoint("TOPLEFT", 20, -36)
    q.edit:SetPoint("TOPRIGHT", -16, -36)
    q.edit:SetMaxLetters(TEXT_LIMIT)
    UI.SetEditHint(q.edit, L["j_quick_hint"])
    local function Save()
        local text = q.edit:GetText()
        if text ~= "" then
            J.Add("manual", "", text, "")
            ns.Say(L["j_quick_saved"])
        end
        q.edit:SetText("")
        q:Hide()
    end
    q.edit:SetScript("OnEnterPressed", Save)
    local save = UI.CreateButton(q, L["btn_save"], 100, 22, Save)
    save:SetPoint("BOTTOMLEFT", 16, 12)
    local cancel = UI.CreateButton(q, L["btn_cancel"], 100, 22, function() q.edit:SetText(""); q:Hide() end)
    cancel:SetPoint("LEFT", save, "RIGHT", 4, 0)
    q:SetScript("OnShow", function() q.edit:SetFocus() end)

    -- Окно экспорта
    local w = UI.SolidPopup(parent, 520, 380)
    ui.export = w
    local t = w:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    t:SetPoint("TOP", 0, -12)
    t:SetText(L["j_export_title"])
    w.edit = UI.CreateMultiline(w, 0)
    w.edit:SetPoint("TOPLEFT", 12, -34)
    w.edit:SetPoint("BOTTOMRIGHT", -12, 44)
    local close = UI.CreateButton(w, L["btn_close"], 100, 22, function() w:Hide() end)
    close:SetPoint("BOTTOM", 0, 12)
end

function J.OpenQuick()
    ns:ToggleMain(true)
    ns:SelectTab("journal")
    ui.quick:Show()
end

local function Create(frame)
    -- Первая строка: поиск и кнопки
    ui.search = UI.CreateEditBox(frame, 160, function(self, byUser)
        if byUser then state.search = self:GetText(); Rebuild() end
    end)
    ui.search:SetPoint("TOPLEFT", 8, -4)
    UI.SetEditHint(ui.search, L["j_search"])
    ui.search.hint:Show()

    ui.btnExport = UI.CreateButton(frame, L["j_export_all"], 130, 22, ExportAll)
    ui.btnExport:SetPoint("TOPRIGHT", -4, -3)
    ui.btnQuick = UI.CreateButton(frame, L["j_quick"], 130, 22, function() ui.quick:Show() end)
    ui.btnQuick:SetPoint("RIGHT", ui.btnExport, "LEFT", -2, 0)
    ui.btnAdd = UI.CreateButton(frame, L["j_add"], 90, 22, StartNew)
    ui.btnAdd:SetPoint("RIGHT", ui.btnQuick, "LEFT", -2, 0)

    -- Вторая строка: фильтры
    ui.btnKind = UI.CreateButton(frame, "", 120, 22, function()
        state.kind = state.kind == nil and "manual" or state.kind == "manual" and "auto" or nil
        UpdateFilterButtons()
        Rebuild()
    end)
    ui.btnKind:SetPoint("TOPLEFT", 4, -30)
    ui.btnChar = UI.CreateButton(frame, "", 200, 22, function()
        local list = KnownChars()
        local nextChar
        if state.char == nil then
            nextChar = list[1]
        else
            for i, k in ipairs(list) do if k == state.char then nextChar = list[i + 1] end end
        end
        state.char = nextChar
        UpdateFilterButtons()
        Rebuild()
    end)
    ui.btnChar:SetPoint("LEFT", ui.btnKind, "RIGHT", 2, 0)

    -- Список слева
    ui.list = UI.CreateList(frame, ROW_H,
        function(row)
            row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            row.sel = row:CreateTexture(nil, "BACKGROUND")
            row.sel:SetAllPoints()
            row.sel:SetColorTexture(1, 1, 1, 0.15)
            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(16, 16)
            row.icon:SetPoint("LEFT", 2, 0)
            row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            row.text:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
            row.text:SetPoint("RIGHT", -2, 0)
            row.text:SetJustifyH("LEFT")
            row.text:SetWordWrap(false)
            row:SetScript("OnClick", function(self)
                if self.id then J.Select(self.id) end
            end)
        end,
        function(row, idx)
            local item = view[idx]
            if item.header then
                row.id = nil
                row.icon:Hide()
                row.sel:Hide()
                row.text:ClearAllPoints()
                row.text:SetPoint("LEFT", 4, 0)
                row.text:SetPoint("RIGHT", -2, 0)
                row.text:SetText(item.header)
                row.text:SetTextColor(1, 0.82, 0)
                row:EnableMouse(false)
            else
                local e = item.entry
                local k = KINDS[e.kind] or KINDS.manual
                row.id = e.id
                row:EnableMouse(true)
                row.icon:SetTexture(k.icon)
                row.icon:Show()
                row.text:ClearAllPoints()
                row.text:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
                row.text:SetPoint("RIGHT", -2, 0)
                row.text:SetText(DisplayTitle(e))
                if e.auto then row.text:SetTextColor(k.r, k.g, k.b) else row.text:SetTextColor(1, 1, 1) end
                row.sel:SetShown(e.id == state.key and not state.pending)
            end
        end)
    ui.list.frame:SetPoint("TOPLEFT", 4, -58)
    ui.list.frame:SetPoint("BOTTOMLEFT", 4, 4)
    ui.list.frame:SetWidth(220)
    ui.empty = ui.list.frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    ui.empty:SetPoint("CENTER")
    ui.empty:SetText(L["j_empty"])

    -- Карточка справа
    local detail = UI.CreateBox(frame)
    detail:SetPoint("TOPLEFT", ui.list.frame, "TOPRIGHT", 6, 0)
    detail:SetPoint("BOTTOMRIGHT", -4, 4)
    ui.hint = detail:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    ui.hint:SetPoint("CENTER")
    ui.hint:SetText(L["j_hint"])

    local body = CreateFrame("Frame", nil, detail)
    body:SetAllPoints()
    ui.body = body

    ui.header = body:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    ui.header:SetPoint("TOPLEFT", 12, -10)
    ui.meta1 = body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.meta1:SetPoint("TOPLEFT", 12, -12)
    ui.meta1:SetPoint("TOPRIGHT", -12, -12)
    ui.meta1:SetJustifyH("LEFT")
    ui.meta2 = body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.meta2:SetPoint("TOPLEFT", 12, -28)
    ui.meta2:SetPoint("TOPRIGHT", -12, -28)
    ui.meta2:SetJustifyH("LEFT")

    local function Label(text, y)
        local fs = body:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("TOPLEFT", 12, y)
        fs:SetText(text)
    end
    Label(L["j_field_title"], -48)
    ui.title = UI.CreateEditBox(body, 100, function(self, byUser)
        local e = Current()
        if byUser and not loading and e then e.title = self:GetText() end
    end)
    ui.title:SetPoint("TOPLEFT", 16, -64)
    ui.title:SetPoint("TOPRIGHT", -12, -64)
    ui.title:SetMaxLetters(100)
    ui.title:HookScript("OnEditFocusLost", Rebuild)

    Label(L["j_field_tags"], -92)
    ui.tags = UI.CreateEditBox(body, 100, function(self, byUser)
        local e = Current()
        if byUser and not loading and e then e.tags = self:GetText() end
    end)
    ui.tags:SetPoint("TOPLEFT", 16, -108)
    ui.tags:SetPoint("TOPRIGHT", -12, -108)
    ui.tags:SetMaxLetters(200)
    ui.tags:HookScript("OnEditFocusLost", Rebuild)

    Label(L["j_field_text"], -136)
    ui.text = UI.CreateMultiline(body, TEXT_LIMIT, function(self, byUser)
        local e = Current()
        if byUser and not loading and e then e.text = self:GetText() end
    end)
    ui.text:SetPoint("TOPLEFT", 12, -152)
    ui.text:SetPoint("BOTTOMRIGHT", -12, 44)
    ui.text.edit:HookScript("OnEditFocusLost", Rebuild)

    ui.btnSave = UI.CreateButton(body, L["btn_save"], 100, 22, SaveNew)
    ui.btnSave:SetPoint("BOTTOMLEFT", 12, 12)
    ui.btnCancel = UI.CreateButton(body, L["btn_cancel"], 100, 22, function()
        state.pending = nil
        LoadDetail()
        ui.list:Refresh()
    end)
    ui.btnCancel:SetPoint("LEFT", ui.btnSave, "RIGHT", 4, 0)
    ui.btnDelete = UI.CreateButton(body, L["btn_delete"], 100, 22, function()
        local e = Current()
        if e then StaticPopup_Show("CHRONICLE_DELETE_ENTRY", DisplayTitle(e), nil, e.id) end
    end)
    ui.btnDelete:SetPoint("BOTTOMLEFT", 12, 12)
    ui.btnExportOne = UI.CreateButton(body, L["j_export_one"], 130, 22, function()
        local e = Current()
        if e then ShowExport(EntryText(e)) end
    end)
    ui.btnExportOne:SetPoint("LEFT", ui.btnDelete, "RIGHT", 4, 0)

    CreatePopups(frame)
    J.OnChanged = function()
        if frame:IsVisible() then Rebuild() end
    end
    UpdateFilterButtons()
    LoadDetail()
    Rebuild()
end

ns.refresh.journal = function()
    state.key, state.pending = nil, nil
    if ui.list then
        LoadDetail()
        Rebuild()
    end
end

ns:RegisterModule("journal", "tab_journal", nil, Create)
