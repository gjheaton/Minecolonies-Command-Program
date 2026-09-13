-- MineColonies Control Suite - shared monitor UI framework
-- Component version: 1.1.0
local Util = require("colony.lib.util")

local M = {}
M.COMPONENT_VERSION = "1.1.0"

local BASE = {
    bg = colors.black,
    panel = colors.gray,
    panel2 = colors.lightGray,
    header = colors.blue,
    headerBg = colors.blue,
    headerText = colors.white,
    headerFg = colors.white,
    title = colors.yellow,
    text = colors.white,
    dim = colors.lightGray,
    muted = colors.lightGray,
    good = colors.lime,
    ok = colors.lime,
    warn = colors.orange,
    danger = colors.red,
    error = colors.red,
    info = colors.cyan,
    accent = colors.lightBlue,
    nav = colors.gray,
    navBg = colors.gray,
    navActive = colors.blue,
    navActiveBg = colors.blue,
    navText = colors.white,
    navFg = colors.white,
    selected = colors.lightBlue,
    subheader = colors.yellow,
    rule = colors.gray,
    accent2 = colors.lightBlue,
    tabBg = colors.gray,
    tabActiveBg = colors.blue,
    tabFg = colors.white,
}

function M.theme()
    local out = {}
    for k, v in pairs(BASE) do out[k] = v end
    return out
end

function M.setTerminalColor(color)
    if term.isColor and term.isColor() then term.setTextColor(color) end
end

function M.resetTerminal(fg, bg)
    term.setBackgroundColor(bg or colors.black)
    M.setTerminalColor(fg or colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

function M.newMonitor(options)
    options = options or {}
    local theme = options.theme or M.theme()
    local buttons = {}

    local function getMonitor()
        if type(options.getMonitor) == "function" then
            return options.getMonitor()
        end
        return options.monitor
    end

    local function failed(err)
        if type(options.onFailure) == "function" then
            pcall(options.onFailure, err)
        end
    end

    local function withMonitor(fn)
        local mon = getMonitor()
        if not mon then return false, "monitor unavailable" end
        if options.protected == false then
            return true, fn(mon)
        end
        local ok, a, b = pcall(fn, mon)
        if not ok then failed(a) end
        return ok, a, b
    end

    local ctx = {}
    ctx.theme = theme

    function ctx.size()
        local ok, w, h = withMonitor(function(mon) return mon.getSize() end)
        if not ok then return nil, nil end
        return w, h
    end

    function ctx.setColors(fg, bg)
        withMonitor(function(mon)
            mon.setTextColor(fg or theme.text)
            mon.setBackgroundColor(bg or theme.bg)
        end)
    end

    function ctx.writeAt(x, y, text, fg, bg)
        local w, h = ctx.size()
        if not w or not h or y < 1 or y > h or x > w then return end
        x = math.max(1, x)
        text = Util.clip(text, w - x + 1)
        withMonitor(function(mon)
            mon.setTextColor(fg or theme.text)
            mon.setBackgroundColor(bg or theme.bg)
            mon.setCursorPos(x, y)
            mon.write(text)
        end)
    end

    function ctx.fill(x1, y1, x2, y2, bg, fg)
        local w, h = ctx.size()
        if not w or not h then return end
        x1 = math.max(1, math.min(w, x1))
        x2 = math.max(1, math.min(w, x2))
        y1 = math.max(1, math.min(h, y1))
        y2 = math.max(1, math.min(h, y2))
        if x2 < x1 or y2 < y1 then return end
        local line = string.rep(" ", x2 - x1 + 1)
        withMonitor(function(mon)
            mon.setTextColor(fg or theme.text)
            mon.setBackgroundColor(bg or theme.bg)
            for y = y1, y2 do
                mon.setCursorPos(x1, y)
                mon.write(line)
            end
        end)
    end

    function ctx.fillRow(y, bg, fg)
        local w = ctx.size()
        if not w then return end
        ctx.writeAt(1, y, string.rep(" ", w), fg or theme.text, bg or theme.bg)
    end

    function ctx.center(y, text, fg, bg, x1, x2)
        local w = ctx.size()
        if not w then return end
        x1 = x1 or 1
        x2 = x2 or w
        local usable = math.max(1, x2 - x1 + 1)
        text = Util.clip(text, usable)
        local x = x1 + math.floor((usable - #text) / 2)
        ctx.writeAt(x, y, text, fg, bg)
    end

    function ctx.centerRow(y, text, fg, bg, width)
        width = width or ctx.size()
        if not width then return end
        ctx.writeAt(1, y, Util.padRight(Util.centerText(text, width), width), fg, bg)
    end

    function ctx.clear()
        withMonitor(function(mon)
            mon.setBackgroundColor(theme.bg)
            mon.setTextColor(theme.text)
            mon.clear()
            mon.setCursorPos(1, 1)
        end)
    end

    function ctx.resetButtons()
        buttons = {}
    end

    function ctx.addTouchArea(id, x1, y1, x2, y2, action)
        buttons[#buttons + 1] = {id=id, x1=x1, y1=y1, x2=x2, y2=y2, action=action}
    end

    function ctx.addButton(id, x1, y1, x2, y2, label, bg, fg, action)
        ctx.addTouchArea(id, x1, y1, x2, y2, action)
        ctx.fill(x1, y1, x2, y2, bg, fg)
        ctx.center(math.floor((y1 + y2) / 2), label, fg or theme.navText, bg, x1, x2)
    end

    function ctx.hitButton(x, y)
        for i = #buttons, 1, -1 do
            local b = buttons[i]
            if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then return b end
        end
        return nil
    end

    function ctx.drawMessagePanel(opts)
        opts = opts or {}
        local w, h = ctx.size()
        if not w or not h then return false end
        local mid = opts.midY or math.max(5, math.floor(h / 2))
        local bg = opts.bg or theme.panel
        local fg = opts.fg or theme.text
        ctx.fill(1, math.max(1, mid - 1), w, math.min(h, mid + 1), bg, fg)
        ctx.center(mid - 1, tostring(opts.title or "UPDATE"),
            opts.titleColor or theme.title, bg)
        ctx.center(mid, tostring(opts.message or ""), fg, bg, 1, w)
        return true
    end

    function ctx.drawHeader(opts)
        opts = opts or {}
        local w = ctx.size()
        if not w then return end
        local headBg = opts.headerBg or theme.header
        ctx.fill(1, 1, w, 2, headBg)
        ctx.center(1, opts.title or "MINECOLONIES", opts.headerFg or theme.headerText, headBg)
        ctx.center(2, opts.subtitle or "", opts.subtitleFg or theme.title, headBg)
        ctx.fill(1, 3, w, 3, opts.statusBg or theme.panel)

        local rightWidth = 0
        if opts.button and opts.button.label then
            rightWidth = math.min(w, math.max(opts.button.minWidth or 14, #opts.button.label + 2))
            local bx = math.max(1, w - rightWidth + 1)
            ctx.addButton(opts.button.id or "header_button", bx, 3, w, 3,
                opts.button.label, opts.button.bg or theme.navActive,
                opts.button.fg or theme.navText, opts.button.action)
            rightWidth = w - bx + 1
        end

        local statusRight = math.max(1, w - rightWidth)
        ctx.center(3, opts.status or "", opts.statusFg or theme.dim,
            opts.statusBg or theme.panel, 1, statusRight)

        if opts.pageTitle ~= nil then
            ctx.center(4, opts.pageTitle, opts.pageTitleFg or theme.title, opts.pageTitleBg or theme.bg)
        end
    end

    function ctx.drawNav(activeId, tabs, y, onSelect)
        local w, h = ctx.size()
        if not w then return end
        y = y or h
        local count = #tabs
        if count == 0 then return end
        local base = math.floor(w / count)
        local x = 1
        for i, tab in ipairs(tabs) do
            local x2 = (i == count) and w or (x + base - 1)
            local id = tab.id
            ctx.addButton("nav_" .. tostring(id), x, y, x2, y, tab.label or tostring(id),
                id == activeId and theme.navActive or theme.nav,
                theme.navText,
                function() if onSelect then onSelect(id, tab) end end)
            x = x2 + 1
        end
    end

    return ctx
end

return M
