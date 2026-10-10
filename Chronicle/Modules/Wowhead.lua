-- Ссылки на Wowhead Forever. Сайт из игры не открыть, поэтому показываем окно с готовой ссылкой для Ctrl+C.
local ADDON, ns = ...
local L = ns.L
local UI = ns.UI

local W = {}
ns.Wowhead = W

local BASE = "https://www.wowhead.com/forever"
local BASE_RU = "https://www.wowhead.com/forever/ru"

local TYPES = { "item", "quest", "npc", "spell", "zone", "object" }
local KEYS = { "CTRL-SHIFT-W", "ALT-W", "CTRL-W", "SHIFT-ALT-W" }
-- Гайды по специализациям, существующие на сайте на момент проверки (адреса проверены запросами к сайту).
-- Новые гайды появляются со временем: тогда сюда нужно добавить строку.
local CLASS_GUIDES = {
    WARRIOR = { { "arms", "dps" }, { "fury", "dps" }, { "protection", "tank" } },
    PALADIN = { { "holy", "healer" }, { "protection", "tank" }, { "retribution", "dps" } },
    HUNTER  = { { "beast-mastery", "dps" }, { "marksmanship", "dps" }, { "survival", "dps" } },
    ROGUE   = { { "assassination", "dps" }, { "combat", "dps" }, { "subtlety", "dps" } },
    PRIEST  = { { "discipline", "healer" }, { "holy", "healer" }, { "shadow", "dps" } },
    SHAMAN  = { { "elemental", "dps" }, { "enhancement", "dps" }, { "restoration", "healer" } },
    MAGE    = { { "arcane", "dps" }, { "fire", "dps" }, { "frost", "dps" } },
    WARLOCK = { { "affliction", "dps" }, { "demonology", "dps" }, { "destruction", "dps" } },
    DRUID   = { { "balance", "dps" }, { "feral", "dps" }, { "feral", "tank" }, { "restoration", "healer" } },
}

-- Профессии: название в адресе, ID навыка для страницы навыка и есть ли гайд по прокачке (overview-leveling)
local PROFESSIONS = {
    { "alchemy", 171, false }, { "blacksmithing", 164, false }, { "enchanting", 333, false },
    { "engineering", 202, false }, { "herbalism", 182, true }, { "leatherworking", 165, false },
    { "mining", 186, true }, { "skinning", 393, false }, { "tailoring", 197, false },
    { "cooking", 185, true }, { "first-aid", 129, false }, { "fishing", 356, true },
}

---------------------------------------------------------------------------
-- Ссылки
---------------------------------------------------------------------------

local function Base()
    return ns.db.settings.wowheadRu and BASE_RU or BASE
end

-- Ссылка на страницу по типу и ID. Название в конце адреса сайту не нужно.
function W.Url(kind, id)
    return ("%s/%s=%d"):format(Base(), kind, id)
end

function W.PageUrl(path)
    return Base() .. (path ~= "" and ("/" .. path) or "")
end

-- Из ссылки на предмет, квест, заклинание или числа получаем тип и ID
local function Parse(text, defaultKind)
    text = text or ""
    for _, kind in ipairs({ "item", "quest", "spell" }) do
        local id = tonumber(text:match(kind .. ":(%d+)"))
        if id then return kind, id end
    end
    local id = tonumber(text:match("^%s*(%d+)%s*$"))
    if id then return defaultKind, id end
end

---------------------------------------------------------------------------
-- Окно со ссылкой
---------------------------------------------------------------------------

local popup

function W.ShowLink(url, title)
    if not popup then
        popup = UI.CreateBox(UIParent)
        popup:SetSize(560, 100)
        popup:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
        popup:SetFrameStrata("FULLSCREEN_DIALOG")
        popup:EnableMouse(true)
        popup:SetMovable(true)
        popup:RegisterForDrag("LeftButton")
        popup:SetScript("OnDragStart", popup.StartMoving)
        popup:SetScript("OnDragStop", popup.StopMovingOrSizing)
        if popup.SetBackdropColor then popup:SetBackdropColor(0.05, 0.05, 0.05, 0.97) end
        -- Имя нужно для UISpecialFrames, чтобы Esc закрывал окно
        _G.ChronicleLinkFrame = popup
        tinsert(UISpecialFrames, "ChronicleLinkFrame")

        popup.title = popup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        popup.title:SetPoint("TOP", 0, -12)
        popup.edit = UI.CreateEditBox(popup, 100)
        popup.edit:SetPoint("TOPLEFT", 20, -38)
        popup.edit:SetPoint("TOPRIGHT", -16, -38)
        popup.edit:SetMaxLetters(500)
        -- После Ctrl+C окно закрывается само
        popup.edit:SetScript("OnKeyDown", function(_, key)
            if key == "C" and IsControlKeyDown() then C_Timer.After(0.15, function() popup:Hide() end) end
        end)
        popup.edit:SetScript("OnTextChanged", function(self)
            if popup.url and self:GetText() ~= popup.url then self:SetText(popup.url) end   -- ссылку править нельзя
            self:HighlightText()
        end)
        local close = UI.CreateButton(popup, L["btn_close"], 100, 22, function() popup:Hide() end)
        close:SetPoint("BOTTOM", 0, 12)
    end
    popup.url = url
    popup.title:SetText(title or L["wh_popup_title"])
    popup.edit:SetText(url)
    popup:Show()
    popup.edit:SetFocus()
    popup.edit:HighlightText()
end

function W.ShowItem(id)
    W.ShowLink(W.Url("item", id))
end

---------------------------------------------------------------------------
-- Клавиша «ссылка на то, что под курсором»
---------------------------------------------------------------------------

local function NpcIdFromGuid(guid)
    if type(guid) ~= "string" then return nil end
    local kind, _, _, _, _, id = strsplit("-", guid)
    if (kind == "Creature" or kind == "Vehicle") and id then return tonumber(id) end
end

-- Что показывает открытая подсказка: тип и ID
local function TooltipTarget(tt)
    if not tt:IsShown() then return nil end
    local T = Enum and Enum.TooltipDataType
    local data = tt.GetPrimaryTooltipData and tt:GetPrimaryTooltipData()
    if data and T and data.type then
        if data.type == T.Item and data.id then return "item", data.id end
        if data.type == T.Spell and data.id then return "spell", data.id end
        if T.Quest and data.type == T.Quest and data.id then return "quest", data.id end
        if data.type == T.Unit then
            local npc = NpcIdFromGuid(data.guid)
            if npc then return "npc", npc end
        end
    end
    -- Запасные способы для подсказок без данных
    if tt.GetItem then
        local _, link = tt:GetItem()
        local id = link and tonumber(link:match("item:(%d+)"))
        if id then return "item", id end
    end
    if tt.GetUnit then
        local _, unit = tt:GetUnit()
        if unit then
            local npc = NpcIdFromGuid(UnitGUID(unit))
            if npc then return "npc", npc end
        end
    end
end

local function CurrentTarget()
    for _, tt in ipairs({ ItemRefTooltip, GameTooltip }) do
        if tt then
            local ok, kind, id = pcall(TooltipTarget, tt)
            if ok and kind then return kind, id end
        end
    end
    for _, unit in ipairs({ "mouseover", "target" }) do
        local npc = UnitExists(unit) and NpcIdFromGuid(UnitGUID(unit))
        if npc then return "npc", npc end
    end
end

function W.LinkUnderCursor()
    local kind, id = CurrentTarget()
    if kind then W.ShowLink(W.Url(kind, id)) else ns.Say(L["wh_nothing"]) end
end

local MODIFIER_KEYS = { LCTRL = true, RCTRL = true, LSHIFT = true, RSHIFT = true, LALT = true, RALT = true }

ns:OnLogin(function()
    local kf = CreateFrame("Frame", nil, UIParent)
    kf:EnableKeyboard(true)
    pcall(kf.SetPropagateKeyboardInput, kf, true)   -- клавиши идут дальше в игру
    kf:SetScript("OnKeyDown", function(_, key)
        if MODIFIER_KEYS[key] then return end
        local combo = (IsControlKeyDown() and "CTRL-" or "") .. (IsShiftKeyDown() and "SHIFT-" or "")
            .. (IsAltKeyDown() and "ALT-" or "") .. key
        if combo == ns.db.settings.wowheadKey then W.LinkUnderCursor() end
    end)
end)

-- /chron wh item 286989, /chron wh [ссылка из игры]
function W.OpenFromText(text)
    text = text or ""
    local kindWord, rest = text:match("^(%a+)%s+(.+)$")
    local kind, id
    if kindWord and ({ item = true, quest = true, npc = true, spell = true })[kindWord:lower()] then
        id = tonumber(rest)
        kind = kindWord:lower()
    else
        kind, id = Parse(text, "item")
    end
    if kind and id then
        W.ShowLink(W.Url(kind, id))
    else
        ns:ToggleMain(true)
        ns:SelectTab("wowhead")
    end
end

---------------------------------------------------------------------------
-- Вкладка
---------------------------------------------------------------------------

local ui = {}
local state = { kind = "item", prof = 1, spec = 1 }

local function ClassFile()
    local _, classFile = UnitClass("player")
    return classFile
end

local function ClassSlug()
    local classFile = ClassFile()
    return classFile and classFile:lower() or nil
end

local function SpecGuide()
    local list = CLASS_GUIDES[ClassFile() or ""]
    if not list then return nil end
    return list[(state.spec - 1) % #list + 1]
end

local function SpecLabel()
    local g = SpecGuide()
    if not g then return L["wh_no_guides"] end
    return L["wh_spec"]:format(L["spec_" .. g[1]] .. " · " .. L["role_" .. g[2]])
end

local function SetLink(url)
    ui.link:SetText(url)
    ui.link:SetFocus()
    ui.link:HighlightText()
end

local function Create(frame)
    local function Label(y, text)
        local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("TOPLEFT", 8, y)
        fs:SetText(text)
    end

    -- Ссылка по ID
    Label(-6, L["wh_id_label"])
    ui.btnType = UI.CreateButton(frame, "", 170, 22, function()
        local i = 1
        for n, k in ipairs(TYPES) do if k == state.kind then i = n end end
        state.kind = TYPES[i % #TYPES + 1]
        ui.btnType:SetText(L["wh_type"]:format(L["wh_type_" .. state.kind]))
    end)
    ui.btnType:SetPoint("TOPLEFT", 8, -26)
    ui.id = UI.CreateEditBox(frame, 200)
    ui.id:SetPoint("LEFT", ui.btnType, "RIGHT", 10, 0)
    ui.id:SetMaxLetters(300)
    local function Show()
        local kind, id = Parse(ui.id:GetText(), state.kind)
        if kind and id then SetLink(W.Url(kind, id)) end
    end
    ui.id:SetScript("OnEnterPressed", function(self) self:ClearFocus(); Show() end)
    ui.btnShow = UI.CreateButton(frame, L["wh_show"], 130, 22, Show)
    ui.btnShow:SetPoint("LEFT", ui.id, "RIGHT", 8, 0)

    -- Поле со ссылкой
    Label(-60, L["wh_link_label"])
    ui.link = UI.CreateEditBox(frame, 100)
    ui.link:SetPoint("TOPLEFT", 12, -78)
    ui.link:SetPoint("TOPRIGHT", -8, -78)
    ui.link:SetMaxLetters(500)
    ui.link:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)

    -- Страницы сайта
    Label(-112, L["wh_pages"])
    local function PageButton(text, x, y, width, getUrl)
        local b = UI.CreateButton(frame, text, width, 22, function()
            local url = getUrl()
            if url then SetLink(url) end
        end)
        b:SetPoint("TOPLEFT", x, y)
        return b
    end
    PageButton(L["wh_home"], 8, -134, 180, function() return W.PageUrl("") end)
    PageButton(L["wh_talents"], 192, -134, 180, function() return W.PageUrl("talent-calc") end)
    PageButton(L["wh_my_talents"], 376, -134, 190, function()
        local slug = ClassSlug()
        return slug and W.PageUrl("talent-calc/" .. slug) or W.PageUrl("talent-calc")
    end)

    -- Гайды класса: общий раздел класса и гайд по выбранной специализации
    PageButton(L["wh_class_hub"], 8, -162, 180, function()
        local slug = ClassSlug()
        return W.PageUrl(slug and ("guides/classes/" .. slug) or "guides/classes")
    end)
    ui.btnSpec = UI.CreateButton(frame, "", 250, 22, function()
        local list = CLASS_GUIDES[ClassFile() or ""]
        if list then state.spec = state.spec % #list + 1 end
        ui.btnSpec:SetText(SpecLabel())
    end)
    ui.btnSpec:SetPoint("TOPLEFT", 192, -162)
    PageButton(L["wh_open"], 446, -162, 120, function()
        local g, slug = SpecGuide(), ClassSlug()
        if not g or not slug then return nil end
        return W.PageUrl(("guide/classes/%s/%s/overview-pve-%s"):format(slug, g[1], g[2]))
    end)

    -- Профессии: страница навыка и гайд по прокачке (гайды есть не для всех профессий)
    ui.btnProf = UI.CreateButton(frame, "", 230, 22, function()
        state.prof = state.prof % #PROFESSIONS + 1
        ui.btnProf:SetText(L["wh_prof"]:format(L["prof_" .. PROFESSIONS[state.prof][1]]))
    end)
    ui.btnProf:SetPoint("TOPLEFT", 8, -194)
    PageButton(L["wh_prof_page"], 242, -194, 150, function()
        return ("%s/skill=%d"):format(Base(), PROFESSIONS[state.prof][2])
    end)
    PageButton(L["wh_prof_guide"], 396, -194, 170, function()
        local p = PROFESSIONS[state.prof]
        if p[3] then return W.PageUrl("guide/professions/" .. p[1] .. "/overview-leveling") end
        return W.PageUrl("guides/professions")   -- гайда по прокачке нет: даём раздел всех гайдов
    end)

    -- Клавиша и версия сайта
    ui.btnKey = UI.CreateButton(frame, "", 240, 22, function()
        local i = 1
        for n, k in ipairs(KEYS) do if k == ns.db.settings.wowheadKey then i = n end end
        ns.db.settings.wowheadKey = KEYS[i % #KEYS + 1]
        ui.btnKey:SetText(L["wh_key"]:format(ns.db.settings.wowheadKey))
    end)
    ui.btnKey:SetPoint("TOPLEFT", 8, -236)
    ui.ru = UI.CreateCheck(frame, 256, -235, L["wh_ru"], function(v) ns.db.settings.wowheadRu = v end)

    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 8, -268)
    hint:SetPoint("TOPRIGHT", -8, -268)
    hint:SetJustifyH("LEFT")
    hint:SetText(L["wh_hint"])

    local function Sync()
        ui.btnType:SetText(L["wh_type"]:format(L["wh_type_" .. state.kind]))
        ui.btnProf:SetText(L["wh_prof"]:format(L["prof_" .. PROFESSIONS[state.prof][1]]))
        ui.btnSpec:SetText(SpecLabel())
        ui.btnKey:SetText(L["wh_key"]:format(ns.db.settings.wowheadKey))
        ui.ru:SetChecked(ns.db.settings.wowheadRu)
    end
    frame:SetScript("OnShow", Sync)
    Sync()
end

ns:RegisterModule("wowhead", "tab_wowhead", nil, Create)
