-- Вкладка «Хотелки»: список нужных предметов с источником, пометка в подсказке, авто-галочка при получении.
local ADDON, ns = ...
local L = ns.L
local UI = ns.UI

local W = {}
ns.Wishlist = W

local ROW_H = 40

---------------------------------------------------------------------------
-- Данные
---------------------------------------------------------------------------

local function Trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function ItemNameByID(id)
    if C_Item and C_Item.GetItemNameByID then return C_Item.GetItemNameByID(id) end
    if GetItemInfo then return (GetItemInfo(id)) end
end

-- Из ссылки на предмет, числа (ID) или названия получаем ID и название
local function Parse(text)
    text = Trim(text or "")
    local id = tonumber(text:match("item:(%d+)"))
    local name = text:match("|h%[(.-)%]|h") or text:match("^%[(.-)%]$")
    if not id and text:match("^%d+$") then id = tonumber(text) end
    if not name then
        if id then name = ItemNameByID(id) else name = text end
    end
    return id, name
end

local function Find(id, name)
    local lname = name and ns.Lower(name)
    for _, w in ipairs(ns.db.wishlist.list) do
        if (id and w.itemId == id) or (lname and ns.Lower(w.name) == lname) then return w end
    end
end

-- Добавляет хотелку. Возвращает запись или nil и ключ ошибки.
function W.Add(text, source)
    local id, name = Parse(text)
    if not id and (not name or name == "") then return nil, "wish_err_item" end
    local pending = false
    if not name then
        name = L["wish_item_id"]:format(id)   -- название ещё не загружено клиентом
        pending = true
        if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
    end
    if Find(id, not pending and name or nil) then return nil, "wish_err_exists" end
    local wl = ns.db.wishlist
    local w = { id = wl.nextId, itemId = id, name = name, source = Trim(source or ""), got = false, pending = pending }
    wl.nextId = wl.nextId + 1
    wl.list[#wl.list + 1] = w
    return w
end

function W.AddFromCommand(text)
    local w, err = W.Add(text, "")
    if w then ns.Say(L["wish_added"]:format(w.name)) else ns.Say(L[err]) end
    if W.OnChanged then W.OnChanged() end
end

local function MarkGot(w)
    w.got = true
    w.gotAt = GetServerTime()
    ns.Say(L["wish_got"]:format(w.name))
    if ns.db.settings.journalAuto.wish and ns.Journal then
        ns.Journal.Add("wish", L["j_wish"]:format(w.name), w.source, "")
    end
    if W.OnChanged then W.OnChanged() end
end

---------------------------------------------------------------------------
-- Интеграция с игрой
---------------------------------------------------------------------------

local function AddTooltipInfo(tooltip)
    if not ns.db or not tooltip.GetItem then return end
    local name, link = tooltip:GetItem()
    if not link then return end
    local w = Find(tonumber(link:match("item:(%d+)")), name)
    if w and not w.got then
        tooltip:AddLine(L["wish_tip"]:format(w.source ~= "" and w.source or "—"), 0.4, 0.8, 1)
        tooltip:Show()
    end
end

ns:OnLogin(function()
    -- Подсказка предмета
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt)
            if tt == GameTooltip or tt == ItemRefTooltip then pcall(AddTooltipInfo, tt) end
        end)
    else
        GameTooltip:HookScript("OnTooltipSetItem", function(tt) pcall(AddTooltipInfo, tt) end)
    end

    -- Получение предмета: разбор своей добычи даёт статистика
    if ns.Stats and ns.Stats.lootHooks then
        table.insert(ns.Stats.lootHooks, function(msg)
            local w = Find(tonumber(msg:match("item:(%d+)")), msg:match("|h%[(.-)%]|h"))
            if w and not w.got then MarkGot(w) end
        end)
    end

    -- Название предмета по ID приходит от сервера не сразу
    local f = CreateFrame("Frame")
    f:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    f:SetScript("OnEvent", function(_, _, itemID)
        for _, w in ipairs(ns.db.wishlist.list) do
            if w.pending and w.itemId == itemID then
                local name = ItemNameByID(itemID)
                if name then
                    w.name, w.pending = name, nil
                    if W.OnChanged then W.OnChanged() end
                end
            end
        end
    end)
end)

---------------------------------------------------------------------------
-- Интерфейс
---------------------------------------------------------------------------

local state = { show = "active" }
local ui = {}
local view = {}
local editing

local function Rebuild()
    if not ui.list then return end
    wipe(view)
    for _, w in ipairs(ns.db.wishlist.list) do
        if state.show == "all" or (state.show == "got") == (w.got == true) then view[#view + 1] = w end
    end
    table.sort(view, function(a, b)
        if a.got ~= b.got then return not a.got end
        return a.id < b.id
    end)
    ui.list:SetCount(#view)
    ui.empty:SetShown(#view == 0)
    local key = state.show == "active" and "wish_show_active" or state.show == "got" and "wish_show_got" or "wish_show_all"
    ui.btnShow:SetText(L[key])
end

local function ShowEditor(w)
    editing = w
    local e = ui.editor
    e.header:SetText(w and L["wish_edit"] or L["wish_new"])
    e.item:SetText(w and (w.itemId and ("%s (%d)"):format(w.name, w.itemId) or w.name) or "")
    e.item:SetCursorPosition(0)
    e.source:SetText(w and w.source or "")
    e.btnDelete:SetShown(w ~= nil)
    e.btnWowhead:SetShown(w ~= nil and w.itemId ~= nil)
    e:Show()
end

local function SaveEditor()
    local e = ui.editor
    local text, source = e.item:GetText(), e.source:GetText()
    if editing then
        local id, name = Parse(text:gsub("%s*%(%d+%)$", ""))
        editing.source = Trim(source)
        if name and name ~= "" then editing.name, editing.pending = name, nil end
        if id then editing.itemId = id end
    else
        local w, err = W.Add(text, source)
        if not w then ns.Say(L[err]) return end
    end
    e:Hide()
    Rebuild()
end

StaticPopupDialogs["CHRONICLE_DELETE_WISH"] = {
    text = L["wish_delete_confirm"],
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, wish)
        local list = ns.db.wishlist.list
        for i, w in ipairs(list) do
            if w == wish then table.remove(list, i) break end
        end
        if ui.editor then ui.editor:Hide() end
        Rebuild()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function CreateEditor(parent)
    local e = UI.SolidPopup(parent, 420, 230)
    ui.editor = e
    e.header = e:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    e.header:SetPoint("TOP", 0, -12)

    local function Label(y, text)
        local fs = e:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("TOPLEFT", 16, y)
        fs:SetText(text)
    end
    Label(-40, L["wish_field_item"])
    e.item = UI.CreateEditBox(e, 100)
    e.item:SetPoint("TOPLEFT", 20, -56)
    e.item:SetPoint("TOPRIGHT", -16, -56)
    e.item:SetMaxLetters(300)
    Label(-90, L["wish_field_source"])
    e.source = UI.CreateEditBox(e, 100)
    e.source:SetPoint("TOPLEFT", 20, -106)
    e.source:SetPoint("TOPRIGHT", -16, -106)
    e.source:SetMaxLetters(200)

    local hint = e:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 16, -138)
    hint:SetPoint("TOPRIGHT", -16, -138)
    hint:SetJustifyH("LEFT")
    hint:SetText(L["wish_hint"])

    e.btnSave = UI.CreateButton(e, L["btn_save"], 100, 22, SaveEditor)
    e.btnSave:SetPoint("BOTTOMLEFT", 16, 14)
    e.btnCancel = UI.CreateButton(e, L["btn_cancel"], 100, 22, function() e:Hide() end)
    e.btnCancel:SetPoint("LEFT", e.btnSave, "RIGHT", 4, 0)
    e.btnDelete = UI.CreateButton(e, L["btn_delete"], 100, 22, function()
        if editing then StaticPopup_Show("CHRONICLE_DELETE_WISH", editing.name, nil, editing) end
    end)
    e.btnDelete:SetPoint("LEFT", e.btnCancel, "RIGHT", 4, 0)
    e.btnWowhead = UI.CreateButton(e, L["wh_btn"], 100, 22, function()
        if editing and editing.itemId then ns.Wowhead.ShowItem(editing.itemId) end
    end)
    e.btnWowhead:SetPoint("BOTTOMRIGHT", -16, 14)
end

local function SetupRow(row, idx)
    local w = view[idx]
    row.wish = w
    row.check:SetChecked(w.got)
    row.name:SetText(w.name)
    if w.got then row.name:SetTextColor(0.55, 0.55, 0.55) else row.name:SetTextColor(1, 1, 1) end
    if w.got then
        row.source:SetText(L["wish_got_at"]:format(ns.FormatBoth(w.gotAt or 0, "%d.%m.%Y")))
    else
        row.source:SetText(w.source ~= "" and (L["wish_source"]:format(w.source)) or "")
    end
end

local function Create(frame)
    ui.btnAdd = UI.CreateButton(frame, L["wish_add"], 110, 22, function() ShowEditor(nil) end)
    ui.btnAdd:SetPoint("TOPLEFT", 4, -4)
    ui.btnShow = UI.CreateButton(frame, "", 160, 22, function()
        state.show = state.show == "active" and "got" or state.show == "got" and "all" or "active"
        Rebuild()
    end)
    ui.btnShow:SetPoint("LEFT", ui.btnAdd, "RIGHT", 2, 0)

    ui.list = UI.CreateList(frame, ROW_H,
        function(row)
            row.bg = row:CreateTexture(nil, "BACKGROUND")
            row.bg:SetPoint("TOPLEFT", 0, -1)
            row.bg:SetPoint("BOTTOMRIGHT", 0, 1)
            row.bg:SetColorTexture(1, 1, 1, 0.05)
            row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
            row.check:SetSize(26, 26)
            row.check:SetPoint("LEFT", 4, 0)
            row.check:SetScript("OnClick", function(self)
                local w = row.wish
                if self:GetChecked() then
                    MarkGot(w)
                else
                    w.got, w.gotAt = false, nil
                    Rebuild()
                end
            end)
            row.edit = UI.CreateButton(row, L["checklist_edit"], 44, 20, function() ShowEditor(row.wish) end)
            row.edit:SetPoint("RIGHT", -2, 0)
            row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.name:SetPoint("TOPLEFT", row.check, "TOPRIGHT", 4, -3)
            row.name:SetPoint("RIGHT", row.edit, "LEFT", -6, 0)
            row.name:SetJustifyH("LEFT")
            row.name:SetWordWrap(false)
            row.source = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.source:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
            row.source:SetPoint("RIGHT", row.edit, "LEFT", -6, 0)
            row.source:SetJustifyH("LEFT")
            row.source:SetWordWrap(false)
            row.source:SetTextColor(0.7, 0.7, 0.7)
        end,
        SetupRow)
    ui.list.frame:SetPoint("TOPLEFT", 4, -32)
    ui.list.frame:SetPoint("BOTTOMRIGHT", -4, 4)
    ui.empty = ui.list.frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    ui.empty:SetPoint("CENTER")
    ui.empty:SetText(L["wish_empty"])

    CreateEditor(frame)
    W.OnChanged = function()
        if frame:IsVisible() then Rebuild() end
    end
    frame:SetScript("OnShow", Rebuild)
    Rebuild()
end

ns:RegisterModule("wishlist", "tab_wishlist", nil, Create)
