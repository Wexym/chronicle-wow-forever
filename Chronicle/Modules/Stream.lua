-- Режим стрима: маленькое прозрачное окно поверх экрана с крупными цифрами,
-- и вкладка «Стрим» для его настройки.
local ADDON, ns = ...
local L = ns.L
local UI = ns.UI

local S = {}
ns.Stream = S

local LINES = {
    { key = "deaths", label = "stream_deaths" },
    { key = "wipes",  label = "stream_wipes" },
    { key = "fight",  label = "stream_fight" },
    { key = "gold",   label = "stream_gold" },
}
local LINE_H = 50
local WIDTH = 220

local win
local fight = { start = nil, last = 0 }   -- таймер боя: идущий и последний

---------------------------------------------------------------------------
-- Окно на экране
---------------------------------------------------------------------------

local function FormatFight(secs)
    secs = math.floor(secs)
    return string.format("%d:%02d", math.floor(secs / 60), secs % 60)
end

local function LineValue(key)
    local s = ns.cdb.session
    if key == "deaths" then return tostring(s.deaths or 0) end
    if key == "wipes" then return tostring(s.wipes or 0) end
    if key == "fight" then
        if fight.start then return FormatFight(GetTime() - fight.start), true end
        return FormatFight(fight.last), false
    end
    if key == "gold" then return ns.FormatMoney((s.goldIn or 0) - (s.goldOut or 0)) end
end

local function SavePosition()
    local cfg = ns.cdb.stream
    local point, _, relPoint, x, y = win:GetPoint(1)
    cfg.point, cfg.relPoint, cfg.x, cfg.y = point, relPoint, x, y
end

-- Пересчитывает, какие строки показаны, и размер окна
function S.Layout()
    if not win then return end
    local cfg = ns.cdb.stream
    local n = 0
    for _, line in ipairs(win.lines) do
        if cfg[line.key] then
            line.frame:ClearAllPoints()
            line.frame:SetPoint("TOPLEFT", win, "TOPLEFT", 8, -8 - n * LINE_H)
            line.frame:SetPoint("TOPRIGHT", win, "TOPRIGHT", -8, -8 - n * LINE_H)
            line.frame:Show()
            n = n + 1
        else
            line.frame:Hide()
        end
    end
    win:SetSize(WIDTH, math.max(1, n) * LINE_H + 16)
    win:SetScale(cfg.scale)
    win.bg:SetColorTexture(0, 0, 0, cfg.alpha)
    win:EnableMouse(not cfg.locked)
end

local function CreateWindow()
    local cfg = ns.cdb.stream
    win = CreateFrame("Frame", "ChronicleStreamFrame", UIParent)
    win:SetFrameStrata("MEDIUM")
    win:SetClampedToScreen(true)
    win:SetMovable(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", function(self) if not ns.cdb.stream.locked then self:StartMoving() end end)
    win:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)
    win:ClearAllPoints()
    win:SetPoint(cfg.point, UIParent, cfg.relPoint, cfg.x, cfg.y)

    win.bg = win:CreateTexture(nil, "BACKGROUND")
    win.bg:SetAllPoints()

    -- Шрифт крупных цифр берём от стандартного, чтобы подошёл к клиенту
    local fontPath = GameFontNormalLarge:GetFont()
    win.lines = {}
    for i, def in ipairs(LINES) do
        local f = CreateFrame("Frame", nil, win)
        f:SetHeight(LINE_H - 4)
        f.label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        f.label:SetPoint("TOPLEFT", 0, 0)
        f.label:SetTextColor(0.8, 0.8, 0.8)
        f.label:SetText(L[def.label])
        f.value = f:CreateFontString(nil, "OVERLAY")
        f.value:SetFont(fontPath, 28, "OUTLINE")
        f.value:SetPoint("TOPLEFT", f.label, "BOTTOMLEFT", 0, -1)
        f.value:SetTextColor(1, 1, 1)
        win.lines[i] = { key = def.key, frame = f }
    end

    local acc = 0
    win:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + elapsed
        if acc < 0.25 then return end
        acc = 0
        for _, line in ipairs(win.lines) do
            if ns.cdb.stream[line.key] then
                local text, active = LineValue(line.key)
                line.frame.value:SetText(text)
                if line.key == "fight" then
                    if active then line.frame.value:SetTextColor(1, 0.4, 0.4) else line.frame.value:SetTextColor(1, 1, 1) end
                end
            end
        end
    end)
    S.Layout()
end

function S.SetShown(shown)
    ns.cdb.stream.shown = shown
    if shown and not win then CreateWindow() end
    if win then win:SetShown(shown) end
    if S.OnChanged then S.OnChanged() end
end

function S.Toggle()
    S.SetShown(not ns.cdb.stream.shown)
end

---------------------------------------------------------------------------
-- События боя
---------------------------------------------------------------------------

ns:OnLogin(function()
    local f = CreateFrame("Frame")
    f:RegisterEvent("ENCOUNTER_START")
    f:RegisterEvent("ENCOUNTER_END")
    f:RegisterEvent("PLAYER_REGEN_DISABLED")
    f:RegisterEvent("PLAYER_REGEN_ENABLED")
    f:SetScript("OnEvent", function(_, event, _, _, _, _, success)
        if event == "ENCOUNTER_START" or event == "PLAYER_REGEN_DISABLED" then
            -- Бой с боссом перезапускает таймер, обычный бой — только если он ещё не идёт
            if event == "ENCOUNTER_START" or not fight.start then fight.start = GetTime() end
        elseif event == "ENCOUNTER_END" then
            if fight.start then fight.last = GetTime() - fight.start end
            fight.start = nil
            if success == 0 and ns.Stats and ns.Stats.Add then ns.Stats.Add("wipes", 1) end
        elseif event == "PLAYER_REGEN_ENABLED" then
            if fight.start then fight.last = GetTime() - fight.start end
            fight.start = nil
        end
    end)
    if ns.cdb.stream.shown then CreateWindow() end
end)

---------------------------------------------------------------------------
-- Вкладка настройки
---------------------------------------------------------------------------

local sync = {}

local function Create(frame)
    local cfg = ns.cdb.stream

    local btnShow = UI.CreateButton(frame, "", 200, 24, function() S.Toggle() end)
    btnShow:SetPoint("TOPLEFT", 8, -8)
    local function UpdateShow()
        btnShow:SetText(cfg.shown and L["stream_hide"] or L["stream_show"])
    end
    sync[#sync + 1] = UpdateShow
    S.OnChanged = UpdateShow

    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", btnShow, "BOTTOMLEFT", 0, -6)
    hint:SetPoint("RIGHT", frame, "RIGHT", -8, 0)
    hint:SetJustifyH("LEFT")
    hint:SetText(L["stream_hint"])

    local lock = UI.CreateCheck(frame, 4, -62, L["stream_lock"], function(v)
        cfg.locked = v
        S.Layout()
    end)
    sync[#sync + 1] = function() lock:SetChecked(cfg.locked) end

    -- Масштаб и прозрачность фона
    local function Stepper(y, fmt, field, min, max, step, scale100)
        local label = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        local function Show()
            label:SetText(fmt:format(scale100 and cfg[field] * 100 or cfg[field]))
        end
        local function Set(v)
            v = math.floor(math.min(max, math.max(min, v)) * 100 + 0.5) / 100
            cfg[field] = v
            Show()
            S.Layout()
        end
        local minus = UI.CreateButton(frame, "-", 26, 22, function() Set(cfg[field] - step) end)
        minus:SetPoint("TOPLEFT", 8, y)
        label:SetPoint("LEFT", minus, "RIGHT", 8, 0)
        label:SetWidth(180)
        label:SetJustifyH("CENTER")
        local plus = UI.CreateButton(frame, "+", 26, 22, function() Set(cfg[field] + step) end)
        plus:SetPoint("LEFT", label, "RIGHT", 8, 0)
        sync[#sync + 1] = Show
    end
    Stepper(-96, L["stream_scale"], "scale", 0.5, 2.5, 0.1, true)
    Stepper(-126, L["stream_alpha"], "alpha", 0, 1, 0.1, true)

    local header = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", 4, -164)
    header:SetText(L["stream_lines"])
    for i, def in ipairs(LINES) do
        local cb = UI.CreateCheck(frame, 4, -188 - (i - 1) * 26, L[def.label], function(v)
            cfg[def.key] = v
            S.Layout()
        end)
        sync[#sync + 1] = function() cb:SetChecked(cfg[def.key]) end
    end

    local reset = UI.CreateButton(frame, L["stream_reset"], 220, 24, function()
        ns.Stats.ResetSession()
        fight.start, fight.last = nil, 0
    end)
    reset:SetPoint("TOPLEFT", 8, -296)

    frame:SetScript("OnShow", function()
        for _, fn in ipairs(sync) do fn() end
    end)
    for _, fn in ipairs(sync) do fn() end
end

ns:RegisterModule("stream", "tab_stream", nil, Create)
