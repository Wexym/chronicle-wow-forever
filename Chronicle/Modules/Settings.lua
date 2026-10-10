-- Вкладка «Настройки»: масштаб, предупреждения, автозаписи журнала, очистка данных вкладок.
local ADDON, ns = ...
local L = ns.L
local UI = ns.UI

local SCALE_MIN, SCALE_MAX, SCALE_STEP = 0.8, 1.3, 0.05
local CLEAR_TABS = { "players", "checklist", "stats", "journal", "goals", "wishlist", "hardcore" }
local AUTO_KINDS = { "level", "death", "boss", "epic", "goal", "wish" }

local sync = {}   -- функции, подтягивающие значения из базы в элементы управления

-- Очистка данных по вкладкам. Выполняется только после подтверждения.
local clear = {
    players = function()
        wipe(ns.db.players)
    end,
    checklist = function()
        wipe(ns.db.checklist.tasks)
        wipe(ns.cdb.checklist.tasks)
        wipe(ns.db.checklistHistory)
        ns.db.checklist.orderSeq = 0
    end,
    stats = function()
        wipe(ns.db.stats.days)
        wipe(ns.db.stats.months)
        wipe(ns.cdb.session)
        ns.cdb.timePlayed = nil
    end,
    hardcore = function()
        local cfg = ns.cdb.hardcore
        wipe(cfg.log)
        wipe(cfg.byDay)
        cfg.total = 0
    end,
    wishlist = function()
        wipe(ns.db.wishlist.list)
        ns.db.wishlist.nextId = 1
    end,
    goals = function()
        wipe(ns.db.goals.list)
        ns.db.goals.nextId = 1
    end,
    journal = function()
        wipe(ns.db.journal.entries)
        wipe(ns.db.journal.firsts)
        ns.db.journal.nextId = 1
    end,
}

StaticPopupDialogs["CHRONICLE_CLEAR_TAB"] = {
    text = L["set_clear_confirm"],
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, key)
        clear[key]()
        if ns.refresh[key] then ns.refresh[key]() end
        ns.Say(L["set_clear_done"]:format(L["tab_" .. key]))
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function Header(parent, y, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:SetPoint("TOPLEFT", 4, y)
    fs:SetText(text)
    return fs
end

local function Check(parent, y, text, get, set)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", 4, y)
    local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    lbl:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    lbl:SetPoint("RIGHT", parent, "RIGHT", -4, 0)
    lbl:SetJustifyH("LEFT")
    lbl:SetText(text)
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    sync[#sync + 1] = function() cb:SetChecked(get()) end
    return cb
end

local function Create(frame)
    local left = CreateFrame("Frame", nil, frame)
    left:SetPoint("TOPLEFT", 4, -4)
    left:SetPoint("BOTTOMRIGHT", frame, "BOTTOM", -4, 4)
    local right = CreateFrame("Frame", nil, frame)
    right:SetPoint("TOPLEFT", frame, "TOP", 4, -4)
    right:SetPoint("BOTTOMRIGHT", -4, 4)

    -- Окно: масштаб и кнопка у миникарты
    Header(left, 0, L["set_window"])
    local scaleText = left:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    local function SetScale(v)
        v = math.min(SCALE_MAX, math.max(SCALE_MIN, math.floor(v * 100 + 0.5) / 100))
        ns.db.settings.scale = v
        ns:ApplyScale()
        scaleText:SetText(L["set_scale"]:format(v * 100))
    end
    local minus = UI.CreateButton(left, "-", 26, 22, function() SetScale(ns.db.settings.scale - SCALE_STEP) end)
    minus:SetPoint("TOPLEFT", 8, -26)
    scaleText:SetPoint("LEFT", minus, "RIGHT", 8, 0)
    scaleText:SetWidth(110)
    scaleText:SetJustifyH("CENTER")
    local plus = UI.CreateButton(left, "+", 26, 22, function() SetScale(ns.db.settings.scale + SCALE_STEP) end)
    plus:SetPoint("LEFT", scaleText, "RIGHT", 8, 0)
    sync[#sync + 1] = function() scaleText:SetText(L["set_scale"]:format(ns.db.settings.scale * 100)) end

    Check(left, -56, L["set_minimap"],
        function() return not ns.db.minimap.hide end,
        function(v)
            ns.db.minimap.hide = not v
            ns:UpdateMinimapButton()
        end)

    -- Игроки
    Header(left, -86, L["set_warnings"])
    Check(left, -112, L["set_warn_group"],
        function() return ns.db.settings.warnGroup end,
        function(v) ns.db.settings.warnGroup = v end)
    Check(left, -142, L["set_warn_whisper"],
        function() return ns.db.settings.warnWhisper end,
        function(v) ns.db.settings.warnWhisper = v end)

    -- Автозаписи журнала
    Header(left, -172, L["set_journal"])
    for i, kind in ipairs(AUTO_KINDS) do
        Check(left, -198 - (i - 1) * 20, L["j_auto_" .. kind],
            function() return ns.db.settings.journalAuto[kind] end,
            function(v) ns.db.settings.journalAuto[kind] = v end)
    end

    -- Очистка данных
    Header(right, 0, L["set_data"])
    for i, key in ipairs(CLEAR_TABS) do
        local b = UI.CreateButton(right, L["set_clear"]:format(L["tab_" .. key]), 220, 24, function()
            StaticPopup_Show("CHRONICLE_CLEAR_TAB", L["tab_" .. key], nil, key)
        end)
        b:SetPoint("TOPLEFT", 8, -26 - (i - 1) * 30)
    end
    local note = right:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", 8, -154)
    note:SetPoint("TOPRIGHT", -4, -154)
    note:SetJustifyH("LEFT")
    note:SetText(L["set_clear_note"])

    frame:SetScript("OnShow", function()
        for _, fn in ipairs(sync) do fn() end
    end)
    for _, fn in ipairs(sync) do fn() end
end

ns:RegisterModule("settings", "tab_settings", nil, Create, { right = true, icon = "Interface\\Buttons\\UI-OptionsButton" })
