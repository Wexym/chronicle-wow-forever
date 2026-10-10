-- Общие элементы интерфейса: кнопка, поле ввода, многострочное поле, список с прокруткой.
local ADDON, ns = ...

local UI = {}
ns.UI = UI

-- Создаёт фрейм по шаблону без ошибки, если шаблона нет в клиенте.
-- Возвращает фрейм и true, либо nil и false.
function UI.TryCreate(frameType, name, parent, template)
    local ok, f = pcall(CreateFrame, frameType, name, parent, template)
    if ok then return f, true end
    return nil, false
end

-- Текст-заглушка по центру фрейма
function UI.Placeholder(parent, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:SetPoint("CENTER")
    fs:SetText(text)
    return fs
end

-- Рамка с тёмным фоном (если backdrop в клиенте недоступен — просто пустой фрейм)
function UI.CreateBox(parent)
    local f = UI.TryCreate("Frame", nil, parent, "BackdropTemplate") or CreateFrame("Frame", nil, parent)
    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        f:SetBackdropColor(0, 0, 0, 0.4)
        f:SetBackdropBorderColor(0.6, 0.6, 0.6)
    end
    return f
end

function UI.CreateButton(parent, text, width, height, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width or 100, height or 22)
    b:SetText(text)
    if onClick then b:SetScript("OnClick", onClick) end
    return b
end

-- Однострочное поле ввода. onChange(editBox, byUser) вызывается при изменении текста.
function UI.CreateEditBox(parent, width, onChange)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetSize(width, 20)
    e:SetAutoFocus(false)
    e:SetTextInsets(0, 0, 0, 0)
    e:SetScript("OnEscapePressed", e.ClearFocus)
    e:SetScript("OnEnterPressed", e.ClearFocus)
    e:SetScript("OnTextChanged", function(self, byUser)
        if self.hint then self.hint:SetShown(self:GetText() == "" and not self:HasFocus()) end
        if onChange then onChange(self, byUser) end
    end)
    return e
end

-- Серая подсказка внутри пустого поля ввода
function UI.SetEditHint(e, text)
    local hint = e:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", 2, 0)
    hint:SetText(text)
    e.hint = hint
    e:HookScript("OnEditFocusGained", function() hint:Hide() end)
    e:HookScript("OnEditFocusLost", function(self) hint:SetShown(self:GetText() == "") end)
end

-- Многострочное поле с прокруткой. Возвращает рамку; поле ввода — frame.edit.
function UI.CreateMultiline(parent, maxLetters, onChange)
    local box = UI.CreateBox(parent)
    local sf = CreateFrame("ScrollFrame", nil, box, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 6, -6)
    sf:SetPoint("BOTTOMRIGHT", -28, 6)

    local e = CreateFrame("EditBox", nil, sf)
    e:SetMultiLine(true)
    e:SetAutoFocus(false)
    e:SetFontObject("ChatFontNormal")
    e:SetMaxLetters(maxLetters or 4000)
    e:SetWidth(sf:GetWidth() > 0 and sf:GetWidth() or 200)
    sf:SetScrollChild(e)
    sf:SetScript("OnSizeChanged", function(self, w) e:SetWidth(math.max(w, 50)) end)
    -- Клик по пустому месту ставит курсор в поле
    sf:EnableMouse(true)
    sf:SetScript("OnMouseDown", function() e:SetFocus() end)

    e:SetScript("OnEscapePressed", e.ClearFocus)
    e:SetScript("OnTextChanged", function(self, byUser)
        if onChange then onChange(self, byUser) end
    end)
    -- Прокрутка вслед за курсором
    e:SetScript("OnCursorChanged", function(_, _, y, _, h)
        local top, bottom = -y, -y + h
        local scroll, height = sf:GetVerticalScroll(), sf:GetHeight()
        if top < scroll then
            sf:SetVerticalScroll(top)
        elseif bottom > scroll + height then
            sf:SetVerticalScroll(bottom - height)
        end
    end)
    box.edit, box.scroll = e, sf
    return box
end

-- Список с прокруткой (FauxScrollFrame). initRow(row) вызывается один раз для новой строки,
-- setupRow(row, index) — при каждом обновлении. Возвращает объект со SetCount и Refresh.
local listCounter = 0
function UI.CreateList(parent, rowH, initRow, setupRow)
    listCounter = listCounter + 1
    local list = { rows = {}, count = 0, visible = 0 }
    local box = UI.CreateBox(parent)
    list.frame = box

    -- Имя нужно, потому что FauxScrollFrame ищет полосу прокрутки по имени
    local sf = CreateFrame("ScrollFrame", "ChronicleListScroll" .. listCounter, box, "FauxScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 4, -4)
    sf:SetPoint("BOTTOMRIGHT", -26, 4)
    list.scroll = sf

    function list:Refresh()
        FauxScrollFrame_Update(sf, self.count, self.visible, rowH)
        local offset = FauxScrollFrame_GetOffset(sf)
        for i, row in ipairs(self.rows) do
            local idx = offset + i
            if i <= self.visible and idx <= self.count then
                row:Show()
                setupRow(row, idx)
            else
                row:Hide()
            end
        end
    end

    function list:SetCount(n)
        self.count = n
        self:Refresh()
    end

    sf:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, rowH, function() list:Refresh() end)
    end)

    box:EnableMouseWheel(true)
    box:SetScript("OnMouseWheel", function(_, delta)
        local bar = sf.ScrollBar or _G[sf:GetName() .. "ScrollBar"]
        if bar then bar:SetValue(bar:GetValue() - delta * rowH * 2) end
    end)

    -- Число строк зависит от высоты списка
    box:SetScript("OnSizeChanged", function(self, _, h)
        local n = math.max(1, math.floor((h - 8) / rowH))
        for i = #list.rows + 1, n do
            local row = CreateFrame("Button", nil, box)
            row:SetHeight(rowH)
            row:SetPoint("TOPLEFT", box, "TOPLEFT", 4, -4 - (i - 1) * rowH)
            row:SetPoint("TOPRIGHT", box, "TOPRIGHT", -26, -4 - (i - 1) * rowH)
            initRow(row)
            list.rows[i] = row
        end
        list.visible = n
        list:Refresh()
    end)
    return list
end

-- Окно-диалог поверх главного: сплошной тёмный фон, по центру родителя, скрыто
function UI.SolidPopup(parent, width, height)
    local f = UI.CreateBox(parent)
    f:SetSize(width, height)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:EnableMouse(true)
    if f.SetBackdropColor then f:SetBackdropColor(0.05, 0.05, 0.05, 0.97) end
    f:Hide()
    return f
end

-- Галочка с подписью справа. Возвращает галочку и подпись; onClick(checked) вызывается при нажатии.
function UI.CreateCheck(parent, x, y, text, onClick)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", x, y)
    local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    lbl:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    lbl:SetPoint("RIGHT", parent, "RIGHT", -4, 0)
    lbl:SetJustifyH("LEFT")
    lbl:SetText(text)
    cb:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
    return cb, lbl
end
