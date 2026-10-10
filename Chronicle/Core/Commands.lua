-- Слэш-команды /chron и /летопись.
local ADDON, ns = ...
local L = ns.L

local function Say(msg)
    print("|cff33ff99" .. L["addon_title"] .. ":|r " .. msg)
end
ns.Say = Say

local function Help()
    print("|cff33ff99" .. L["cmd_help_header"] .. "|r")
    print("  " .. L["cmd_help_toggle"])
    print("  " .. L["cmd_help_note"])
    print("  " .. L["cmd_help_journal"])
    print("  " .. L["cmd_help_auto"])
    print("  " .. L["cmd_help_want"])
    print("  " .. L["cmd_help_wh"])
    print("  " .. L["cmd_help_stream"])
    print("  " .. L["cmd_help_weekly"])
    print("  " .. L["cmd_help_diag"])
    print("  " .. L["cmd_help_reset"])
end

-- Диагностика: что есть в клиенте. Результат нужен, чтобы не гадать про API и шаблоны.
local function Diag()
    local version, build, _, toc = GetBuildInfo()
    Say(("клиент %s (сборка %s), интерфейс %s, локаль %s"):format(version, build, tostring(toc), GetLocale()))
    local apis = {
        "C_DateAndTime.GetCurrentCalendarTime",
        "C_DateAndTime.GetSecondsUntilWeeklyReset",
        "GetQuestResetTime",
        "GetServerTime",
        "Menu.ModifyMenu",
        "UnitPopup_ShowMenu",
        "Settings.OpenToCategory",
        "C_GameRules.IsHardcoreActive",
        "GetProfessions",
        "GetProfessionInfo",
        "GetNumSkillLines",
        "GetXPExhaustion",
    }
    for _, path in ipairs(apis) do
        print(("  API %s: %s"):format(path, ns.HasAPI(path) and "|cff00ff00есть|r" or "|cffff0000нет|r"))
    end
    local templates = {
        "BasicFrameTemplateWithInset", "PanelTopTabButtonTemplate", "CharacterFrameTabButtonTemplate",
        "PanelTabButtonTemplate", "UIPanelButtonTemplate", "UIPanelScrollFrameTemplate",
        "InputBoxTemplate", "UIPanelCloseButton", "BackdropTemplate",
    }
    -- Шаблоны не создаём (кнопочные шаблоны в обычном Frame падают), а спрашиваем у клиента
    for _, name in ipairs(templates) do
        local state
        if C_XMLUtil and C_XMLUtil.GetTemplateInfo then
            state = C_XMLUtil.GetTemplateInfo(name) and "|cff00ff00есть|r" or "|cffff0000нет|r"
        else
            state = "не проверено"
        end
        print(("  шаблон %s: %s"):format(name, state))
    end
    local now = GetServerTime()
    print("  время: " .. ns.FormatBoth(now, "%d.%m.%Y %H:%M") .. ", сдвиг сервера от UTC: " .. ns.ServerOffset() / 3600 .. " ч")
    print("  вкладки: " .. (ns.tabTemplateUsed or "главное окно ещё не создавалось"))
end

SLASH_CHRONICLE1 = "/chron"
SLASH_CHRONICLE2 = "/летопись"
SlashCmdList["CHRONICLE"] = function(msg)
    local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    if cmd == "" then
        ns:ToggleMain()
    elseif cmd == "note" then
        ns.Players.OpenFor(rest)
    elseif cmd == "j" then
        ns.Journal.Quick(rest)
    elseif cmd == "wh" then
        ns.Wowhead.OpenFromText(rest)
    elseif cmd == "want" then
        ns.Wishlist.AddFromCommand(rest)
    elseif cmd == "stream" then
        ns.Stream.Toggle()
    elseif cmd == "auto" then
        ns.Journal.SetAuto(rest)
    elseif cmd == "weekly" then
        local d, h = rest:match("^(%d+)%s+(%d+)$")
        if not ns.Checklist.SetWeekly(tonumber(d), tonumber(h)) then Say(L["weekly_usage"]) end
    elseif cmd == "diag" then
        ns:ToggleMain(true)
        Diag()
    elseif cmd == "reset" then
        ns:ResetWindow()
        Say(L["cmd_reset_done"])
    else
        Help()
    end
end
