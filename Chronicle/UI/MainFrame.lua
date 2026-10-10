-- Главное окно: рамка, вкладки сверху, кнопка у миникарты.
local ADDON, ns = ...
local L = ns.L
local UI = ns.UI

local FRAME_NAME = "ChronicleMainFrame"   -- имя нужно для UISpecialFrames (закрытие по Esc)
local MIN_W, MIN_H = 600, 420
local TAB_ROW_Y = -30                      -- отступ ряда вкладок от верха окна
local CONTENT_TOP = -58                    -- отступ области вкладки от верха окна

local main            -- главное окно (создаётся при первом открытии)
local tabs = {}       -- tabs[key] = кнопка вкладки
local activeKey

---------------------------------------------------------------------------
-- Окно
---------------------------------------------------------------------------

local function CreateFrameWithFallback()
    -- Стандартная рамка Blizzard; если шаблона нет в клиенте — обычная рамка с фоном
    local f, ok = UI.TryCreate("Frame", FRAME_NAME, UIParent, "BasicFrameTemplateWithInset")
    if ok then
        ns.frameTemplateUsed = "BasicFrameTemplateWithInset"
        return f
    end
    f = CreateFrame("Frame", FRAME_NAME, UIParent, "BackdropTemplate")
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    f.CloseButton = close
    ns.frameTemplateUsed = "BackdropTemplate (запасной)"
    return f
end

local function SaveWindow()
    local w = ns.cdb.window
    local point, _, relPoint, x, y = main:GetPoint(1)
    w.point, w.relPoint, w.x, w.y = point, relPoint, x, y
    w.width, w.height = main:GetWidth(), main:GetHeight()
end

local function RestoreWindow()
    local w = ns.cdb.window
    main:ClearAllPoints()
    main:SetPoint(w.point, UIParent, w.relPoint, w.x, w.y)
    main:SetSize(math.max(w.width, MIN_W), math.max(w.height, MIN_H))
end

function ns:ApplyScale()
    if not main then return end
    local s = ns.db.settings.scale or 1
    main:SetScale(math.min(1.3, math.max(0.8, s)))
end

function ns:ResetWindow()
    local d = ns.charDefaults.window
    local w = ns.cdb.window
    w.point, w.relPoint, w.x, w.y, w.width, w.height = d.point, d.relPoint, d.x, d.y, d.width, d.height
    if main then RestoreWindow() end
end

---------------------------------------------------------------------------
-- Вкладки
---------------------------------------------------------------------------

-- Переворачивает текстуры нижней вкладки, чтобы она «висела» сверху
local function FlipTabVertically(tab)
    for _, region in ipairs({ tab:GetRegions() }) do
        if region:GetObjectType() == "Texture" and region.GetTexCoord then
            local ulx, uly, llx, lly, urx, ury, lrx, lry = region:GetTexCoord()
            if ulx then
                region:SetTexCoord(llx, lly, ulx, uly, lrx, lry, urx, ury)
            end
        end
    end
end

local function CreateTabButton(parent, mod)
    -- Порядок: верхний шаблон → нижний шаблон (перевёрнутый) → обычная кнопка
    local btn, ok = UI.TryCreate("Button", nil, parent, "PanelTopTabButtonTemplate")
    if ok then
        ns.tabTemplateUsed = "PanelTopTabButtonTemplate"
    else
        btn, ok = UI.TryCreate("Button", nil, parent, "CharacterFrameTabButtonTemplate")
        if ok then
            FlipTabVertically(btn)
            ns.tabTemplateUsed = "CharacterFrameTabButtonTemplate (перевёрнут)"
        else
            btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
            btn:SetHeight(24)
            ns.tabTemplateUsed = "UIPanelButtonTemplate (запасной)"
        end
    end
    local text = L[mod.labelKey]
    if mod.icon then text = "|T" .. mod.icon .. ":14|t " .. text end
    btn:SetText(text)
    if btn.GetFontString and PanelTemplates_TabResize then
        pcall(PanelTemplates_TabResize, btn, 0)
    elseif btn:GetFontString() then
        btn:SetWidth(btn:GetFontString():GetStringWidth() + 30)
    end
    return btn
end

local function SetTabSelected(btn, selected)
    if PanelTemplates_SelectTab and PanelTemplates_DeselectTab and btn.Left then
        pcall(selected and PanelTemplates_SelectTab or PanelTemplates_DeselectTab, btn)
    elseif selected then
        btn:Disable()
    else
        btn:Enable()
    end
end

function ns:SelectTab(key)
    local mod = ns.modules[key]
    if not mod or not main then return end
    -- Фрейм вкладки создаётся при первом открытии
    if not mod.frame then
        mod.frame = CreateFrame("Frame", nil, main.content)
        mod.frame:SetAllPoints()
        mod.create(mod.frame)
    end
    for k, m in pairs(ns.modules) do
        if m.frame then m.frame:SetShown(k == key) end
        if tabs[k] then SetTabSelected(tabs[k], k == key) end
    end
    activeKey = key
    ns.cdb.lastTab = key
end

-- Раскладка вкладок: если ряд не помещается по ширине окна, лишние вкладки переносятся на следующий ряд,
-- а область содержимого сдвигается вниз.
local TAB_ROW_H = 26

local function LayoutTabs()
    if not main or not main.content then return end
    local width = main:GetWidth() - 24
    local rightBtn
    for _, key in ipairs(ns.moduleOrder) do
        if ns.modules[key].right and tabs[key] then rightBtn = tabs[key] end
    end
    local firstRowWidth = width - (rightBtn and (rightBtn:GetWidth() + 8) or 0)
    local x, row = 0, 0
    for _, key in ipairs(ns.moduleOrder) do
        local btn = tabs[key]
        if btn and not ns.modules[key].right then
            local w = btn:GetWidth()
            local avail = row == 0 and firstRowWidth or width
            if x > 0 and x + w > avail then
                row, x = row + 1, 0
            end
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", main, "TOPLEFT", 12 + x, TAB_ROW_Y - row * TAB_ROW_H)
            x = x + w - 4
        end
    end
    if rightBtn then
        rightBtn:ClearAllPoints()
        rightBtn:SetPoint("TOPRIGHT", main, "TOPRIGHT", -12, TAB_ROW_Y)
    end
    main.content:ClearAllPoints()
    main.content:SetPoint("TOPLEFT", 10, CONTENT_TOP - row * TAB_ROW_H)
    main.content:SetPoint("BOTTOMRIGHT", -10, 24)
end

local function BuildTabs()
    for _, key in ipairs(ns.moduleOrder) do
        local btn = CreateTabButton(main, ns.modules[key])
        btn:SetScript("OnClick", function() ns:SelectTab(key) end)
        tabs[key] = btn
    end
    LayoutTabs()
    main:HookScript("OnSizeChanged", LayoutTabs)
end

---------------------------------------------------------------------------
-- Создание, показ и скрытие
---------------------------------------------------------------------------

local function CreateMain()
    main = CreateFrameWithFallback()
    main:SetFrameStrata("HIGH")
    main:SetClampedToScreen(true)
    main:SetMovable(true)
    main:SetResizable(true)
    if main.SetResizeBounds then
        main:SetResizeBounds(MIN_W, MIN_H)
    elseif main.SetMinResize then
        main:SetMinResize(MIN_W, MIN_H)
    end
    RestoreWindow()
    ns:ApplyScale()

    -- Заголовок (у шаблона Blizzard есть своя строка, иначе создаём)
    local title = main.TitleText or (main.TitleContainer and main.TitleContainer.TitleText)
    if not title then
        title = main:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOP", 0, -8)
    end
    title:SetText(L["addon_title"])

    -- Перетаскивание за верхнюю полосу
    local drag = CreateFrame("Frame", nil, main)
    drag:SetPoint("TOPLEFT", 0, 0)
    drag:SetPoint("TOPRIGHT", -28, 0)
    drag:SetHeight(24)
    drag:EnableMouse(true)
    drag:RegisterForDrag("LeftButton")
    drag:SetScript("OnDragStart", function() main:StartMoving() end)
    drag:SetScript("OnDragStop", function()
        main:StopMovingOrSizing()
        SaveWindow()
    end)

    -- Изменение размера за правый нижний угол
    local grip = CreateFrame("Button", nil, main)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -4, 4)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() main:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        main:StopMovingOrSizing()
        SaveWindow()
    end)

    -- Область содержимого вкладок
    local content = CreateFrame("Frame", nil, main)
    content:SetPoint("TOPLEFT", 10, CONTENT_TOP)
    content:SetPoint("BOTTOMRIGHT", -10, 24)
    main.content = content

    -- Esc закрывает окно
    tinsert(UISpecialFrames, FRAME_NAME)

    BuildTabs()
    local first = ns.cdb.lastTab
    if not first or not ns.modules[first] then first = ns.moduleOrder[1] end
    main:Show()
    ns:SelectTab(first)
end

-- Открыть/закрыть окно. onlyShow = true — только открыть (для диагностики).
function ns:ToggleMain(onlyShow)
    if not main then
        CreateMain()
    elseif main:IsShown() then
        if not onlyShow then main:Hide() end
    else
        main:Show()
    end
end

---------------------------------------------------------------------------
-- Кнопка у миникарты (без библиотек)
---------------------------------------------------------------------------

local function PositionMinimapButton(btn)
    local rad = math.rad(ns.db.minimap.angle)
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(rad) * 80, math.sin(rad) * 80)
end

local function CreateMinimapButton()
    local btn = CreateFrame("Button", "ChronicleMinimapButton", Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:RegisterForClicks("LeftButtonUp")
    btn:RegisterForDrag("LeftButton")

    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 1)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    btn:SetScript("OnClick", function() ns:ToggleMain() end)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(L["minimap_tooltip"])
        GameTooltip:AddLine(L["minimap_hint"], 1, 1, 1, true)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Перетаскивание по окружности вокруг миникарты
    btn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local scale = Minimap:GetEffectiveScale()
            local cx, cy = GetCursorPosition()
            ns.db.minimap.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
            PositionMinimapButton(self)
        end)
    end)
    btn:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

    PositionMinimapButton(btn)
    btn:SetShown(not ns.db.minimap.hide)
end

function ns:UpdateMinimapButton()
    local btn = _G.ChronicleMinimapButton
    if btn then btn:SetShown(not ns.db.minimap.hide) end
end

ns:OnLogin(CreateMinimapButton)
