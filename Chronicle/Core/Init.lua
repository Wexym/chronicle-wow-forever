-- Ядро: пространство имён, база данных, миграции, реестр модулей, события.
local ADDON, ns = ...
local L = ns.L

-- Единственные глобальные: пространство имён и две SavedVariables
_G.Chronicle = ns

ns.DB_VERSION = 1

-- Значения по умолчанию задаются только здесь и подставляются при загрузке
ns.defaults = {
    version = ns.DB_VERSION,
    settings = {
        scale = 1.0,                -- масштаб окна 0.8–1.3
        wowheadKey = "CTRL-SHIFT-W",    -- клавиша «ссылка Wowhead на то, что под курсором»
        wowheadRu = (GetLocale() == "ruRU"),   -- русская версия сайта (для русского клиента по умолчанию)
        warnGroup = true,           -- предупреждать о красной отметке в группе
        warnWhisper = false,        -- сообщать о заметке на того, кто пишет в личку
        journalAuto = {             -- какие автозаписи вести в журнале
            level = true, death = true, boss = true, epic = true, goal = true, wish = true,
        },
        weeklyDay = 4,              -- запасной день недели сброса (1 = воскресенье), если нет игровой функции
        weeklyHour = 4,             -- запасной час сброса по времени сервера
    },
    checklist = {                   -- задачи «весь аккаунт»
        tasks = {},
        nextReset = {},             -- момент ближайшего сброса по периодам (unix-время)
        templates = {},
        templatesSeeded = false,
        orderSeq = 0,
    },
    wishlist = {
        list = {},                  -- хотелки: { id, itemId, name, source, got, gotAt }
        nextId = 1,
    },
    reminders = {
        buffsOn = true, buffs = {},         -- названия баффов, окончание которых надо заметить
        bagsOn = true, bagsFree = 4,        -- предупреждать, когда свободных слотов не больше
        durOn = true, durPct = 25,          -- предупреждать, когда прочность не выше, %
        cdOn = true, spells = {},           -- заклинания, у которых ждём окончание перезарядки
        sound = true,
    },
    goals = {
        list = {},                  -- долгие цели: { id, title, type, target, ... }
        nextId = 1,
    },
    journal = {
        entries = {},               -- записи журнала
        nextId = 1,
        firsts = {},                -- ["Имя-Сервер:код"] = true: первые убийства боссов
    },
    stats = {
        days = {},                  -- ["Имя-Сервер"]["ГГГГ-ММ-ДД"] = { played, xp, goldIn, ... }
        months = {},                -- свёрнутые итоги старше 90 дней: ["Имя-Сервер"]["ГГГГ-ММ"]
    },
    checklistHistory = {},          -- ["Имя-Сервер" или "account"] = список { day, period, done, total }
    players = {},                   -- заметки на игроков: ["Имя-Сервер"] = { ... }
    minimap = {
        angle = 215,                -- положение кнопки на окружности, градусы
        hide = false,
    },
    characters = {},                -- список персонажей: ["Имя-Сервер"] = { ... }
}

ns.charDefaults = {
    window = {
        point = "CENTER", relPoint = "CENTER", x = 0, y = 0,
        width = 760, height = 520,
    },
    lastTab = nil,
    stream = {                      -- режим стрима: окно с крупными цифрами
        shown = false, locked = false, scale = 1, alpha = 0.35,
        point = "CENTER", relPoint = "CENTER", x = 0, y = 200,
        deaths = true, wipes = true, fight = true, gold = true,
    },
    hardcore = {                    -- хардкор-панель; enabled заполняется при первом входе
        dangerPct = 20, levelDiff = 3, warnHealth = true, warnTarget = true,
        total = 0, byDay = {}, log = {},
    },
    session = {},                   -- счётчики текущей сессии (переживают /reload)
    checklist = {                   -- задачи «этот персонаж»
        tasks = {},
        nextReset = {},
    },
}

-- Дополняет t недостающими полями из defaults (существующие значения не трогает)
local function FillDefaults(t, defaults)
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            if type(t[k]) ~= "table" then t[k] = {} end
            FillDefaults(t[k], v)
        elseif t[k] == nil then
            t[k] = v
        end
    end
end

-- Миграции: migrations[n] переводит данные с версии n-1 на версию n.
-- Данные никогда не удаляются без миграции.
local migrations = {
    -- [2] = function(db) ... end,
}

local function Migrate(db)
    local from = db.version or 0
    if from > ns.DB_VERSION then
        print("|cffff8800" .. L["addon_title"] .. ":|r " .. L["db_too_new"]:format(from))
        return
    end
    for v = from + 1, ns.DB_VERSION do
        if migrations[v] then migrations[v](db) end
    end
    if from ~= 0 and from < ns.DB_VERSION then
        print("|cff33ff99" .. L["addon_title"] .. ":|r " .. L["db_migrated"]:format(ns.DB_VERSION))
    end
    db.version = ns.DB_VERSION
end

-- Реестр модулей. Новая вкладка = один вызов RegisterModule, ядро править не нужно.
-- key — внутреннее имя, labelKey — ключ строки для названия вкладки,
-- icon — текстура (необязательно), createFn(frame) вызывается при первом открытии вкладки.
ns.modules = {}
ns.moduleOrder = {}
ns.refresh = {}     -- ns.refresh[модуль]() — перерисовать вкладку после очистки данных

function ns:RegisterModule(key, labelKey, icon, createFn, opts)
    local mod = { key = key, labelKey = labelKey, icon = icon, create = createFn }
    if opts then for k, v in pairs(opts) do mod[k] = v end end
    self.modules[key] = mod
    self.moduleOrder[#self.moduleOrder + 1] = key
    return mod
end

-- Очереди обратных вызовов: OnInit — после загрузки БД, OnLogin — при входе в мир
local initHooks, loginHooks = {}, {}
function ns:OnInit(fn) initHooks[#initHooks + 1] = fn end
function ns:OnLogin(fn) loginHooks[#loginHooks + 1] = fn end

local function CharKey()
    return (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        ChronicleDB = ChronicleDB or {}
        ChronicleCharDB = ChronicleCharDB or {}
        Migrate(ChronicleDB)
        FillDefaults(ChronicleDB, ns.defaults)
        FillDefaults(ChronicleCharDB, ns.charDefaults)
        ns.db = ChronicleDB
        ns.cdb = ChronicleCharDB
        for _, fn in ipairs(initHooks) do fn() end
    elseif event == "PLAYER_LOGIN" then
        ns.charKey = CharKey()
        if not ns.db.characters[ns.charKey] then
            ns.db.characters[ns.charKey] = {}
        end
        for _, fn in ipairs(loginHooks) do fn() end
    end
end)
