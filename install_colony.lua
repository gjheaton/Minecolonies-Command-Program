-- MineColonies Control Suite Installer
-- Suite package version 1.1.0
--
-- This single file is both the interactive installer and the remote update package.
-- Canonical remote update package: GitHub raw installer URL.
-- Fresh installs, Repair, and application updates use the configured source automatically.

local mode, arg2, arg3 = ...

local SUITE_INFO = {
    suiteVersion = "1.1.0",
    installerVersion = "1.1.0",
    apps = {
        command = { version = "2.13", program = "/colony_command.lua", displayName = "MineColonies Command Center" },
        supply = { version = "2.36", program = "/colony_supply.lua", displayName = "MineColonies Supply Manager" },
    },
    components = {
        startup = "1.0.0", util = "1.0.1", ui = "1.0.0",
        version = "1.0.0", updater = "1.1.0", installer = "1.1.0",
    },
}

-- The shared updater executes only this branch in a restricted environment.
if mode == "--metadata" then return SUITE_INFO end

local DEFAULT_GITHUB_REPOSITORY = "Minecolonies-Command-Program"
local DEFAULT_GITHUB_BRANCH = "main"
local DEFAULT_INSTALLER_FILENAME = "install_colony.lua"
-- Leave nil in the public package. On first interactive install the user enters
-- the GitHub owner/username (or a complete repository/raw URL), and the resolved
-- raw installer URL is stored in /colony/app.cfg for all future updates.
local DEFAULT_SUITE_SOURCE_URL = nil
local CONFIG_PATH = "/colony/app.cfg"
local INSTALLER_PATH = "/install_colony.lua"

local function absolutePath(path)
    path = tostring(path or "")
    if path == "" then return nil end
    if path:sub(1, 1) ~= "/" then path = "/" .. path end
    return path
end

local PACKAGE_FILES = {
    { path = "/startup.lua", app = "common", source = [====[-- MineColonies Control Suite generic startup launcher
-- Component version: 1.0.0
local CONFIG_PATH = "/colony/app.cfg"
local RESTART_DELAY = 5

local function banner(message, color)
    term.setBackgroundColor(colors.black)
    term.setTextColor(color or colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("MineColonies Control Suite")
    print("--------------------------")
    print(message or "")
    print()
end

local function loadConfig()
    if not fs.exists(CONFIG_PATH) then return nil, "Missing " .. CONFIG_PATH end
    local h = fs.open(CONFIG_PATH, "r")
    if not h then return nil, "Cannot read " .. CONFIG_PATH end
    local text = h.readAll()
    h.close()
    local ok, cfg = pcall(textutils.unserialize, text)
    if not ok or type(cfg) ~= "table" then return nil, "Invalid " .. CONFIG_PATH end
    if not cfg.program or cfg.program == "" then return nil, "No program configured in " .. CONFIG_PATH end
    return cfg
end

sleep(1)
while true do
    local cfg, cfgError = loadConfig()
    if not cfg then
        banner("STARTUP CONFIG ERROR", colors.red)
        print(cfgError)
        print("Run /install_colony.lua to install or repair the suite.")
        print("Retrying in " .. RESTART_DELAY .. " seconds...")
        sleep(RESTART_DELAY)
    elseif not fs.exists(cfg.program) then
        banner("APPLICATION MISSING", colors.red)
        print("Configured app: " .. tostring(cfg.app or "unknown"))
        print("Missing: " .. tostring(cfg.program))
        print("Run /install_colony.lua and choose Repair Existing Installation.")
        print("Retrying in " .. RESTART_DELAY .. " seconds...")
        sleep(RESTART_DELAY)
    else
        banner("Starting " .. tostring(cfg.displayName or cfg.app or cfg.program) .. "...", colors.white)
        local ok, err = pcall(function()
            local ran = shell.run(cfg.program)
            if not ran then error(tostring(cfg.program) .. " returned an error.", 0) end
        end)
        term.setTextColor(ok and colors.yellow or colors.red)
        print()
        if ok then
            print(tostring(cfg.program) .. " exited.")
        else
            print("Program stopped with an error:")
            print(tostring(err))
        end
        term.setTextColor(colors.white)
        print("Restarting in " .. RESTART_DELAY .. " seconds...")
        sleep(RESTART_DELAY)
    end
end
]====] },
    { path = "/colony/manifest.lua", app = "common", source = [====[-- MineColonies Control Suite local manifest
return {
    suiteVersion = "1.1.0",
    components = {
        startup = "1.0.0",
        installer = "1.1.0",
        util = "1.0.1",
        ui = "1.0.0",
        version = "1.0.0",
        updater = "1.1.0",
    },
    apps = {
        command = { version = "2.13", program = "/colony_command.lua" },
        supply = { version = "2.36", program = "/colony_supply.lua" },
    },
}
]====] },
    { path = "/colony/lib/util.lua", app = "common", source = [====[-- MineColonies Control Suite - shared utility helpers
-- Component version: 1.0.1
local M = {}
M.COMPONENT_VERSION = "1.0.1"

function M.clamp(n, lo, hi)
    if n < lo then return lo end
    if n > hi then return hi end
    return n
end

function M.trim(s)
    s = tostring(s or "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.clip(s, width)
    s = tostring(s or "")
    width = math.max(0, tonumber(width) or 0)
    if #s <= width then return s end
    if width <= 3 then return s:sub(1, width) end
    return s:sub(1, width - 3) .. "..."
end

M.truncateText = M.clip

function M.healthWord(ok)
    return ok and "ONLINE" or "OFFLINE"
end

function M.padRight(s, width)
    s = M.clip(s, width)
    return s .. string.rep(" ", math.max(0, width - #s))
end

function M.padLeft(s, width)
    s = tostring(s or "")
    if #s > width then s = s:sub(#s - width + 1) end
    return string.rep(" ", math.max(0, width - #s)) .. s
end

function M.centerText(s, width)
    s = M.clip(s, width)
    local left = math.floor((width - #s) / 2)
    return string.rep(" ", left) .. s .. string.rep(" ", math.max(0, width - #s - left))
end

function M.wrapText(text, width)
    text = tostring(text or "")
    width = math.max(1, tonumber(width) or 1)
    local lines = {}
    for paragraph in (text .. "\n"):gmatch("(.-)\n") do
        if paragraph == "" then
            lines[#lines + 1] = ""
        else
            local line = ""
            for word in paragraph:gmatch("%S+") do
                if #word > width then
                    if #line > 0 then
                        lines[#lines + 1] = line
                        line = ""
                    end
                    while #word > width do
                        lines[#lines + 1] = word:sub(1, width)
                        word = word:sub(width + 1)
                    end
                    line = word
                elseif line == "" then
                    line = word
                elseif #line + 1 + #word <= width then
                    line = line .. " " .. word
                else
                    lines[#lines + 1] = line
                    line = word
                end
            end
            if line ~= "" then lines[#lines + 1] = line end
        end
    end
    return lines
end

return M
]====] },
    { path = "/colony/lib/ui.lua", app = "common", source = [====[-- MineColonies Control Suite - shared monitor UI framework
-- Component version: 1.0.0
local Util = require("colony.lib.util")

local M = {}
M.COMPONENT_VERSION = "1.0.0"

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
]====] },
    { path = "/colony/lib/version.lua", app = "common", source = [====[-- MineColonies Control Suite - shared version helpers
-- Component version: 1.0.0
local M = {}
M.COMPONENT_VERSION = "1.0.0"

function M.parts(version)
    local out = {}
    for n in tostring(version or ""):gmatch("(%d+)") do
        out[#out + 1] = tonumber(n) or 0
    end
    return out
end

function M.compare(a, b)
    local av = M.parts(a)
    local bv = M.parts(b)
    local count = math.max(#av, #bv)
    if count == 0 then return 0 end
    for i = 1, count do
        local aa = av[i] or 0
        local bb = bv[i] or 0
        if aa < bb then return -1 end
        if aa > bb then return 1 end
    end
    return 0
end

function M.isNewer(remoteVersion, localVersion)
    return M.compare(remoteVersion, localVersion) > 0
end

function M.extractProgramVersion(source)
    if type(source) ~= "string" then return nil end
    return source:match("local%s+PROGRAM_VERSION%s*=%s*[\"']([^\"']+)[\"']")
        or source:match("local%s+VERSION%s*=%s*[\"']([^\"']+)[\"']")
end

function M.safe(version)
    return tostring(version or "unknown"):gsub("[^%w%-_%.]", "_")
end

return M
]====] },
    { path = "/colony/lib/updater.lua", app = "common", source = [====[-- MineColonies Control Suite - shared suite updater
-- Component version: 1.1.0
local Version = require("colony.lib.version")

local M = {}
M.COMPONENT_VERSION = "1.1.0"

local function readTable(path)
    if not fs.exists(path) then return nil end
    local h = fs.open(path, "r")
    if not h then return nil end
    local text = h.readAll()
    h.close()
    local ok, value = pcall(textutils.unserialize, text)
    if ok and type(value) == "table" then return value end
    return nil
end

local function nowText()
    if os.date then return os.date("%H:%M:%S") end
    return textutils.formatTime(os.time(), true)
end

local function cacheBust(url)
    url = tostring(url or "")
    if url == "" then return url end
    local stamp
    if os.epoch then
        local ok, value = pcall(os.epoch, "utc")
        if ok then stamp = value end
    end
    stamp = stamp or math.floor((os.clock and os.clock() or 0) * 1000)
    return url .. (url:find("?", 1, true) and "&" or "?") .. "cc_cache=" .. tostring(stamp)
end

local function fetchRaw(url, userAgent)
    if not url or url == "" then return nil, "Suite source URL not configured" end
    if type(http) ~= "table" or type(http.get) ~= "function" then
        return nil, "HTTP API unavailable"
    end
    local ok, response = pcall(http.get, cacheBust(url), {
        ["Cache-Control"] = "no-cache",
        ["User-Agent"] = userAgent or "MineColonies-Control-Suite",
    })
    if not ok then return nil, "HTTP request failed: " .. tostring(response) end
    if not response then return nil, "Remote source returned no response" end
    local okRead, body = pcall(response.readAll)
    pcall(response.close)
    if not okRead or type(body) ~= "string" or body == "" then
        return nil, "Could not read suite package"
    end
    return body
end

local function packageMetadata(source)
    if type(source) ~= "string" or source == "" then return nil, "Suite package is empty" end
    if not source:find("MineColonies Control Suite Installer", 1, true) then
        return nil, "Remote source is not the Control Suite installer"
    end
    local loader, err = load(source, "@colony_suite_package_check", "t", {})
    if not loader then return nil, "Suite package failed syntax check: " .. tostring(err) end
    local ok, metadata = pcall(loader, "--metadata")
    if not ok then return nil, "Could not read suite metadata: " .. tostring(metadata) end
    if type(metadata) ~= "table" or not metadata.suiteVersion or type(metadata.apps) ~= "table" then
        return nil, "Suite metadata is incomplete"
    end
    return metadata
end

local function sourceLabel(url)
    url = tostring(url or "")
    if url == "" then return "NOT CONFIGURED" end
    local owner, repo, branch = url:match("^https://raw%.githubusercontent%.com/([^/]+)/([^/]+)/([^/]+)/")
    if owner and repo and branch then
        return "github/" .. owner .. "/" .. repo .. "@" .. branch
    end
    return url
end

function M.new(opts)
    opts = opts or {}
    local self = {
        appId = assert(opts.appId, "updater appId required"),
        appVersion = assert(opts.appVersion, "updater appVersion required"),
        suiteVersion = assert(opts.suiteVersion, "updater suiteVersion required"),
        displayName = opts.displayName or opts.appId,
        configPath = opts.configPath or "/colony/app.cfg",
        installerPath = opts.installerPath or "/install_colony.lua",
        checkSeconds = tonumber(opts.checkSeconds) or 1800,
        drawMessage = opts.drawMessage,
        availableVersion = nil,
        remoteVersion = nil,
        remoteSuiteVersion = nil,
        checkError = nil,
        lastCheckedText = nil,
    }

    function self.getSourceUrl()
        local cfg = readTable(self.configPath) or {}
        return cfg.suiteSourceUrl or opts.suiteSourceUrl
    end

    function self.sourceLabel()
        return sourceLabel(self.getSourceUrl())
    end

    function self.fetchSource()
        return fetchRaw(self.getSourceUrl(),
            "MineColonies-" .. tostring(self.appId) .. "/" .. tostring(self.appVersion))
    end

    function self.readMetadata(source)
        return packageMetadata(source)
    end

    function self.check()
        self.lastCheckedText = nowText()
        self.availableVersion = nil
        self.remoteVersion = nil
        self.remoteSuiteVersion = nil
        self.checkError = nil

        local source, fetchError = self.fetchSource()
        if not source then
            self.checkError = fetchError
            return false, fetchError
        end
        local meta, metaError = self.readMetadata(source)
        if not meta then
            self.checkError = metaError
            return false, metaError
        end

        self.remoteSuiteVersion = tostring(meta.suiteVersion)
        local appMeta = meta.apps[self.appId] or {}
        self.remoteVersion = tostring(appMeta.version or self.appVersion)

        if Version.isNewer(self.remoteSuiteVersion, self.suiteVersion) then
            self.availableVersion = self.remoteVersion
            return true, self.remoteVersion
        end
        return false, self.remoteVersion
    end

    function self.statusText(checking)
        if checking then return "CHECKING..." end
        if self.availableVersion then
            local suffix = ""
            if tostring(self.availableVersion) == tostring(self.appVersion) then suffix = " (shared files)" end
            return "UPDATE AVAILABLE: v" .. tostring(self.availableVersion) .. suffix
        end
        if self.checkError then return "ERROR: " .. tostring(self.checkError) end
        if self.remoteSuiteVersion then
            return "CURRENT (suite v" .. tostring(self.remoteSuiteVersion) .. ")"
        end
        return "NOT CHECKED"
    end

    function self.terminalStatus()
        local checked = self.lastCheckedText and (" @ " .. self.lastCheckedText) or ""
        if self.checkError then return "ERROR" .. checked .. " - " .. tostring(self.checkError), colors.red end
        if self.availableVersion then
            return "UPDATE AVAILABLE v" .. tostring(self.availableVersion) .. checked, colors.yellow
        end
        if self.remoteSuiteVersion then
            return "CURRENT (suite v" .. tostring(self.remoteSuiteVersion) .. ")" .. checked, colors.lime
        end
        return "NOT CHECKED", colors.lightGray
    end

    function self.buttonLabel()
        if not self.availableVersion then return nil end
        if tostring(self.availableVersion) == tostring(self.appVersion) then return "UPDATE SUITE" end
        return "UPDATE v" .. tostring(self.availableVersion)
    end

    function self.buttonGeometry(w)
        local label = self.buttonLabel()
        if not label then return nil, nil, nil end
        local width = math.min(math.max(14, #label + 2), math.max(1, w))
        local x1 = math.max(1, w - width + 1)
        return x1, w, width
    end

    local function message(title, body, color)
        if type(self.drawMessage) == "function" then
            self.drawMessage(title, body, color)
        else
            term.setTextColor(color or colors.white)
            print(tostring(title) .. ": " .. tostring(body))
            term.setTextColor(colors.white)
        end
    end

    function self.install()
        message(self.displayName .. " UPDATE", "Downloading suite package...", colors.cyan)
        local sourceUrl = self.getSourceUrl()
        if not sourceUrl or sourceUrl == "" then
            message("UPDATE FAILED", "Suite source URL is not configured.", colors.red)
            sleep(2)
            return false
        end
        local source, fetchError = self.fetchSource()
        if not source then message("UPDATE FAILED", fetchError, colors.red); sleep(2); return false end
        local meta, metaError = self.readMetadata(source)
        if not meta then message("UPDATE FAILED", metaError, colors.red); sleep(2); return false end
        if not Version.isNewer(meta.suiteVersion, self.suiteVersion) then
            self.availableVersion = nil
            message("NO UPDATE", "Installed suite is already current.", colors.lime)
            sleep(1)
            return false
        end

        -- Managed code is recoverable from the suite package, so do not keep a
        -- second full-size on-disk backup. CC:Tweaked computers commonly have a
        -- ~1 MB filesystem and the self-contained installer is large enough that
        -- old + temp + backup can exhaust it.
        local temp = self.installerPath .. ".update_tmp"
        local stale = {
            self.installerPath .. ".bak",
            self.installerPath .. ".install_tmp",
            temp,
        }
        for _, path in ipairs(stale) do
            if fs.exists(path) then pcall(fs.delete, path) end
        end

        local function writeDirect()
            if fs.exists(self.installerPath) then fs.delete(self.installerPath) end
            local h = fs.open(self.installerPath, "w")
            if not h then return false, "cannot create installer file" end
            h.write(source)
            h.close()
            if not fs.exists(self.installerPath) or fs.getSize(self.installerPath) <= 0 then
                return false, "installer write produced an empty file"
            end
            return true
        end

        local free = math.huge
        local dir = fs.getDir(self.installerPath)
        local okFree, freeValue = pcall(fs.getFreeSpace, (dir and dir ~= "") and dir or "/")
        if okFree and type(freeValue) == "number" then free = freeValue end
        local needed = #source + 4096

        local okReplace, replaceErr
        if free >= needed then
            okReplace, replaceErr = pcall(function()
                local h = fs.open(temp, "w")
                if not h then error("cannot create installer temporary file", 0) end
                h.write(source)
                h.close()
                if fs.getSize(temp) <= 0 then error("installer temporary file is empty", 0) end
                if fs.exists(self.installerPath) then fs.delete(self.installerPath) end
                fs.move(temp, self.installerPath)
            end)
        else
            okReplace, replaceErr = pcall(function()
                local okDirect, directErr = writeDirect()
                if not okDirect then error(directErr, 0) end
            end)
        end
        if not okReplace then
            if fs.exists(temp) then pcall(fs.delete, temp) end
            message("UPDATE FAILED", "Could not update installer: " .. tostring(replaceErr), colors.red)
            return false
        end

        message("INSTALLER UPDATED", "Updating application and shared files...", colors.cyan)
        local okRun = shell.run(self.installerPath, "--update", self.appId, sourceUrl)
        if not okRun then
            message("UPDATE FAILED", "Installer could not complete suite update.", colors.red)
            return false
        end
        message("UPDATE COMPLETE", "Rebooting into updated suite...", colors.lime)
        sleep(1)
        os.reboot()
        return true
    end

    function self.touchIsButton(x, y, w)
        if not self.availableVersion or y ~= 3 then return false end
        local x1, x2 = self.buttonGeometry(w)
        return x1 and x >= x1 and x <= x2
    end

    function self.loop(onChanged)
        while true do
            sleep(math.max(60, self.checkSeconds))
            local oldAvailable = self.availableVersion
            local oldError = self.checkError
            local oldRemote = self.remoteSuiteVersion
            self.check()
            if (oldAvailable ~= self.availableVersion or oldError ~= self.checkError or oldRemote ~= self.remoteSuiteVersion)
                and type(onChanged) == "function" then
                pcall(onChanged)
            end
        end
    end

    return self
end

return M
]====] },
    { path = "/colony_command.lua", app = "command", source = [====[-- MineColonies Command Center
-- Minecraft 1.20.1
-- Requires: CC:Tweaked + Advanced Peripherals + MineColonies
-- Display: Advanced Monitor
-- v2.13: Adds Help Wanted staffing view with MineColonies-aware capacity rules.

local REFRESH_SECONDS = 10
local RAID_BLINK_SECONDS = 0.75
local TEXT_SCALE = 0.5
local PROGRAM_VERSION = "2.13"
local SUITE_VERSION = "1.1.0"

local Util = require("colony.lib.util")
local SharedUI = require("colony.lib.ui")
local SuiteUpdater = require("colony.lib.updater")

-- Suite update settings.
local UPDATE_CHECK_SECONDS = 1800  -- Recheck suite package every 30 minutes

-- Sick-citizen trigger settings.
-- Prefer an Advanced Peripherals Redstone Integrator when one is available.
-- If no usable integrator exists, fall back to the Advanced Computer.
-- TOP is the default output side for either device.
local SICK_TRIGGER_INTEGRATOR_SIDE = "top"
local SICK_TRIGGER_COMPUTER_SIDE = "top"

-- =========================
-- Peripheral discovery
-- =========================

local monitor = peripheral.find("monitor")
if not monitor then
    error("No monitor found. Attach an Advanced Monitor to this computer/network.")
end

local monitorName = peripheral.getName(monitor)
local colony = peripheral.find("colonyIntegrator")
if not colony then
    error("No colonyIntegrator found. Attach an Advanced Peripherals Colony Integrator.")
end
local colonyPeripheralName = peripheral.getName(colony)

-- Prefer the Advanced Peripherals Redstone Integrator. AP 0.7 uses the
-- peripheral type "redstoneIntegrator"; the underscore form is also checked
-- for compatibility with newer naming.
local sickRedstoneIntegrator = nil
local sickRedstoneIntegratorName = nil

local function resolveSickRedstoneIntegrator()
    local integrator = peripheral.find("redstoneIntegrator")
    if not integrator then
        integrator = peripheral.find("redstone_integrator")
    end

    sickRedstoneIntegrator = integrator
    sickRedstoneIntegratorName =
        integrator and peripheral.getName(integrator) or nil

    return integrator
end

local function hasSickTriggerHardware()
    -- The computer's built-in redstone API is always the fallback.
    return true
end

local function sickTriggerHardwareText(sickCount)
    local powered = (tonumber(sickCount) or 0) > 0
    local state = powered and "ON" or "OFF"

    local integrator = resolveSickRedstoneIntegrator()
    if integrator then
        return "INTEGRATOR [" ..
            tostring(sickRedstoneIntegratorName or "?") ..
            "] TOP " .. state
    end

    return "COMPUTER TOP " .. state
end

monitor.setTextScale(TEXT_SCALE)
monitor.setCursorBlink(false)

if not monitor.isColor() then
    error("This program requires an Advanced (color) Monitor.")
end

-- =========================
-- Theme
-- =========================

local C = SharedUI.theme()
local monitorUI = SharedUI.newMonitor({ monitor = monitor, theme = C, protected = false })

-- =========================
-- Small helpers
-- =========================

local function nvl(v, fallback)
    if v == nil then return fallback end
    return v
end

local function tostr(v, fallback)
    if v == nil then return fallback or "" end
    return tostring(v)
end

local function yesno(v)
    return v and "YES" or "NO"
end

local function posText(p)
    if type(p) ~= "table" then return "N/A" end
    if p.x == nil or p.y == nil or p.z == nil then return "N/A" end
    return string.format("%s, %s, %s", tostring(p.x), tostring(p.y), tostring(p.z))
end

local clip = Util.clip
local pad = Util.padRight

local function cleanJobName(job)
    local s = job

    -- Depending on the MineColonies/AP build, the job can be returned
    -- as a string or a small table. Normalize both forms first.
    if type(s) == "table" then
        s = s.job or s.name or s.id or s.type or ""
    end
    s = tostring(s or "")

    -- Prefer the portion AFTER com.minecolonies.job. wherever it appears.
    -- Example: com.minecolonies.job.builder -> builder
    local packaged = s:match("com%.minecolonies%.job%.([%w_%-]+)")
    if packaged then
        s = packaged
    else
        s = s:gsub("com%.minecolonies%.job%.", "")
        s = s:gsub("^minecolonies:", "")
    end

    -- Make identifiers human-readable.
    s = s:gsub("_", " ")
    s = s:gsub("%-", " ")
    s = s:gsub("(%l)(%u)", "%1 %2")
    s = s:gsub("^%l", string.upper)

    if s == "" then return "Worker" end
    return s
end

local function cleanBuildingName(value)
    local s = value
    if type(s) == "table" then
        s = s.name or s.type or s.id or ""
    end
    s = tostring(s or "")

    -- MineColonies building identifiers may be returned as packaged names.
    -- Example: com.minecolonies.building.builder -> builder
    local packaged = s:match("com%.minecolonies%.building%.([%w_%-]+)")
    if packaged then
        s = packaged
    else
        s = s:gsub("com%.minecolonies%.building%.", "")
        s = s:gsub("^minecolonies:", "")
    end

    -- If another Java-style package still remains, use its final identifier.
    if s:find("%.") then
        s = s:match("([^.]+)$") or s
    end

    s = s:gsub("_", " ")
    s = s:gsub("%-", " ")
    s = s:gsub("(%l)(%u)", "%1 %2")
    s = s:gsub("^%l", string.upper)

    if s == "" then return "Unknown" end
    return s
end

-- Post Boxes are utility blocks rather than useful command-center building
-- entries, so hide them from the Buildings screen. Keep them in D.buildings
-- internally so construction/work-order matching still has the complete
-- MineColonies building dataset available.
local function isIgnoredBuilding(building)
    if type(building) ~= "table" then return false end

    local candidates = {
        building.name,
        building.type,
        building.id,
    }

    for _, value in ipairs(candidates) do
        if value ~= nil then
            local cleaned = cleanBuildingName(value):lower()
            local compact = cleaned:gsub("[%s_%-]", "")
            if compact == "postbox" then
                return true
            end

            local raw = tostring(value):lower():gsub("[%s_%-]", "")
            if raw:find("postbox", 1, true) ~= nil then
                return true
            end
        end
    end

    return false
end

local function visibleBuildings(buildings)
    local out = {}
    for _, building in ipairs(buildings or {}) do
        if not isIgnoredBuilding(building) then
            out[#out + 1] = building
        end
    end
    return out
end

local function samePosition(a, b)
    return type(a) == "table" and type(b) == "table"
        and a.x ~= nil and a.y ~= nil and a.z ~= nil
        and b.x ~= nil and b.y ~= nil and b.z ~= nil
        and a.x == b.x and a.y == b.y and a.z == b.z
end

local function citizenJob(citizen)
    if citizen.age == "child" then return "Child" end

    local raw = citizen.job
    if type(citizen.work) == "table" then
        raw = citizen.work.job or citizen.work.name or citizen.work.id or raw
    elseif citizen.work ~= nil and raw == nil then
        raw = citizen.work
    end

    if raw == nil or tostring(raw) == "" then
        return "No job"
    end

    return cleanJobName(raw)
end

-- Military citizens are kept in a separate section at the bottom of the
-- Citizens page. MineColonies 1.20.1 uses Ranger as the internal Archer job
-- name in some releases. Known defensive jobs include Guard, Archer/Ranger,
-- Knight, Druid, and (in later 1.20.1 builds) Cavalry. Training students are
-- intentionally not included because they do not defend the colony.
local MILITARY_JOBS = {
    guard = true,
    archer = true,
    ranger = true,
    knight = true,
    druid = true,
    cavalry = true,
}

local function isMilitaryCitizen(citizen)
    -- Use exact normalized job-name matching. Substring matching is unsafe:
    -- for example, "researcher" contains the letters "archer" and was
    -- incorrectly classified as military in v17.
    local job = citizenJob(citizen):lower()
    job = job:gsub("^%s+", ""):gsub("%s+$", "")
    job = job:gsub("[%s_%-]", "")

    return MILITARY_JOBS[job] == true
end

local function citizenNameLess(a, b)
    return tostring(a.name or ""):lower() < tostring(b.name or ""):lower()
end

-- Sort buildings from least complete to most complete. This uses level/maxLevel
-- rather than raw level alone, and alphabetizes buildings which have the same
-- completion percentage.
local function buildingCompletion(building)
    local level = tonumber(building.level) or 0
    local maxLevel = tonumber(building.maxLevel) or 0

    if level <= 0 then return 0 end
    if maxLevel > 0 then
        return math.max(0, math.min(1, level / maxLevel))
    end

    return building.built and 1 or 0
end

local function sortBuildingsByCompletion(list)
    table.sort(list, function(a, b)
        local ac = buildingCompletion(a)
        local bc = buildingCompletion(b)
        if math.abs(ac - bc) > 0.000001 then
            return ac < bc
        end

        local an = cleanBuildingName(a.name or a.type or "Unknown"):lower()
        local bn = cleanBuildingName(b.name or b.type or "Unknown"):lower()
        if an ~= bn then return an < bn end

        return tostring(a.name or a.type or ""):lower() < tostring(b.name or b.type or ""):lower()
    end)
end

local function buildCitizenDisplayRows(citizens)
    local civilians, military = {}, {}

    for _, citizen in ipairs(citizens or {}) do
        if isMilitaryCitizen(citizen) then
            military[#military + 1] = citizen
        else
            civilians[#civilians + 1] = citizen
        end
    end

    table.sort(civilians, citizenNameLess)
    table.sort(military, citizenNameLess)

    local rows = {}
    for _, citizen in ipairs(civilians) do rows[#rows + 1] = citizen end

    if #military > 0 then
        rows[#rows + 1] = { _sectionHeader = true, _sectionTitle = "MILITARY", _sectionCount = #military }
        for _, citizen in ipairs(military) do rows[#rows + 1] = citizen end
    end

    return rows
end

local function isCitizenSick(citizen)
    -- Advanced Peripherals documents a citizen.state string, but does not
    -- expose a dedicated sickness boolean on 1.20.1. Some builds/modpacks
    -- may expose one anyway, so check those first and then inspect state.
    if citizen.isSick == true or citizen.sick == true then
        return true
    end

    local state = tostring(citizen.state or ""):lower()

    -- MineColonies 1.20.1 reports sickness through the citizen AI/state
    -- text. Matching the word "sick" also catches packaged/internal state
    -- identifiers which contain the same term.
    if state:find("sick", 1, true) then
        return true
    end

    return false
end

local function citizenStatus(citizen)
    -- Sickness is deliberately the highest-priority warning.
    if isCitizenSick(citizen) then
        return "SICK", C.danger
    end
    if type(citizen.health) == "number" and type(citizen.maxHealth) == "number"
        and citizen.health < citizen.maxHealth then
        return "INJURED", C.danger
    end
    if citizen.betterFood then return "FOOD", C.warn end
    if citizen.isAsleep then return "IN BED", C.info end
    if citizen.isIdle then return "IDLE", C.title end
    if citizen.age == "child" then return "CHILD", C.accent end
    return "OK", C.good
end

local function normalizeList(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for _, v in pairs(t) do
        if type(v) == "table" then
            out[#out + 1] = v
        end
    end
    return out
end

-- Preserve the sequence of array-style API results. This matters for
-- MineColonies work orders because their list order represents the queue.
local function normalizeOrderedList(t)
    local out = {}
    if type(t) ~= "table" then return out end

    local used = {}
    for i, v in ipairs(t) do
        if type(v) == "table" then
            out[#out + 1] = v
            used[i] = true
        end
    end

    -- Fallback for tables with numeric keys which are not a perfect Lua array.
    local numericKeys = {}
    for k, v in pairs(t) do
        if type(k) == "number" and not used[k] and type(v) == "table" then
            numericKeys[#numericKeys + 1] = k
        end
    end
    table.sort(numericKeys)
    for _, k in ipairs(numericKeys) do
        out[#out + 1] = t[k]
    end

    -- Last-resort support for non-numeric keyed result tables.
    if #out == 0 then
        for _, v in pairs(t) do
            if type(v) == "table" then out[#out + 1] = v end
        end
    end

    return out
end

local function countTable(t)
    local n = 0
    if type(t) ~= "table" then return 0 end
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function sortByName(list, field)
    table.sort(list, function(a, b)
        local av = tostring(a[field] or a.name or a.type or ""):lower()
        local bv = tostring(b[field] or b.name or b.type or ""):lower()
        return av < bv
    end)
end

local apiErrors = {}
local function api(method, default, ...)
    local fn = colony[method]
    if type(fn) ~= "function" then
        apiErrors[method] = "method unavailable"
        return default
    end
    local ok, result = pcall(fn, ...)
    if not ok then
        apiErrors[method] = tostring(result)
        return default
    end
    apiErrors[method] = nil
    if result == nil then return default end
    return result
end

local function errorCount()
    local n = 0
    for _ in pairs(apiErrors) do n = n + 1 end
    return n
end

-- =========================
-- Monitor drawing helpers
-- =========================

local size = monitorUI.size
local setColors = monitorUI.setColors
local fill = monitorUI.fill
local writeAt = monitorUI.writeAt
local center = monitorUI.center
local clear = monitorUI.clear
local wrapText = Util.wrapText

-- =========================
-- Buttons / touch handling
-- =========================

local resetButtons = monitorUI.resetButtons
local addButton = monitorUI.addButton
local addTouchArea = monitorUI.addTouchArea
local hitButton = monitorUI.hitButton

-- =========================
-- Data model
-- =========================

local D = {
    citizens = {}, buildings = {}, requests = {}, workOrders = {}, visitors = {},
    helpWanted = {}, helpWantedOpenings = 0
}

local function buildingWorkers(building)
    local workers = {}
    local seen = {}

    -- A worker belongs to THIS specific building only when the citizen's
    -- documented work location matches the building location exactly.
    --
    -- IMPORTANT: Do not fall back to work-building name/type here. Multiple
    -- buildings of the same type share those values, which would make the
    -- same citizen appear on every building of that type.
    --
    -- We also intentionally do not use building.citizens for the WORKER(S)
    -- column. That table represents citizens associated with the building,
    -- while citizen.work.location specifically identifies the workplace.
    for _, citizen in ipairs(D.citizens or {}) do
        if type(citizen.work) == "table"
            and samePosition(citizen.work.location, building.location) then

            local key = tostring(citizen.id or citizen.name or (#workers + 1))
            if not seen[key] then
                workers[#workers + 1] = citizen
                seen[key] = true
            end
        end
    end

    table.sort(workers, function(a, b)
        return tostring(a.name or ""):lower() < tostring(b.name or ""):lower()
    end)
    return workers
end

local function buildingWorkerSummary(building, width)
    local workers = buildingWorkers(building)
    if #workers == 0 then return "None" end

    local names = {}
    for _, citizen in ipairs(workers) do
        names[#names + 1] = tostring(citizen.name or "Unknown")
    end

    local full = table.concat(names, ", ")
    if #full <= width then return full end

    -- Prefer useful names over a blind truncation when several citizens work
    -- in the same building.
    local first = names[1] or "Unknown"
    if #names == 1 then return clip(first, width) end
    local suffix = " (+" .. tostring(#names - 1) .. ")"
    return clip(first, math.max(1, width - #suffix)) .. suffix
end

-- MineColonies/Advanced Peripherals 0.7 does not expose a building's maximum
-- worker count directly. Keep a conservative table for standard work huts and
-- explicit formulas for buildings whose staffing scales with level.
--
-- Guard Towers are intentionally capped at ONE worker even though some
-- MineColonies screens/AP structures can expose multiple guard job choices.
-- Only one guard can actually occupy a normal Guard Tower.
local SINGLE_WORKER_BUILDINGS = {
    alchemist = true,
    apiary = true, beekeeper = true,
    baker = true, bakery = true,
    blacksmith = true,
    builder = true, builderhut = true,
    chickenherder = true, chickenfarmer = true,
    composter = true,
    concretemixer = true,
    cook = true, restaurant = true, kitchen = true, cookery = true,
    crusher = true,
    deliveryman = true, courier = true, courierhut = true,
    dyer = true,
    enchanter = true,
    farmer = true, farm = true,
    fisherman = true,
    fletcher = true,
    florist = true,
    forester = true, lumberjack = true,
    glassblower = true,
    guardtower = true,
    hospital = true, healer = true,
    mechanic = true,
    miner = true, mine = true,
    netherworker = true, nethermine = true,
    plantation = true,
    rabbitherder = true,
    sawmill = true,
    school = true, -- teacher slot only; pupil seats are not Help Wanted jobs
    shepherd = true,
    smeltery = true,
    stonemason = true, stonesmeltery = true, brickyard = true,
    swineherder = true,
    undertaker = true, graveyard = true,
}

local function compactBuildingKey(value)
    return cleanBuildingName(value):lower():gsub("[^%w]", "")
end

local function staffingBuildingKey(building)
    if type(building) ~= "table" then return "" end
    local candidates = { building.type, building.name, building.id }
    for _, value in ipairs(candidates) do
        if value ~= nil then
            local key = compactBuildingKey(value)
            if key ~= "" and key ~= "unknown" then return key end
        end
    end
    return ""
end

local function buildingStaffCapacity(building)
    if type(building) ~= "table" then return 0 end

    local level = math.max(0, tonumber(building.level) or 0)
    if level <= 0 then return 0 end

    local key = staffingBuildingKey(building)

    -- Explicit MineColonies multi-worker rules.
    if key == "guardtower" then
        return 1
    elseif key == "barrackstower" then
        return level
    elseif key == "university" then
        return level
    elseif key == "library" then
        return level * 2
    elseif key == "archery" or key == "combatacademy" then
        return level
    elseif key == "stable" then
        -- One Stablemaster plus one Cavalry slot per building level.
        return 1 + level
    elseif SINGLE_WORKER_BUILDINGS[key] then
        return 1
    end

    return 0
end

local function staffingWorkers(building)
    local workers = buildingWorkers(building)
    local key = staffingBuildingKey(building)

    -- Pupils also use the School as their work location, but Help Wanted is
    -- intended to report the actual Teacher vacancy rather than pupil seats.
    if key == "school" then
        local teachers = {}
        for _, citizen in ipairs(workers) do
            local job = citizenJob(citizen):lower():gsub("[^%w]", "")
            if job == "teacher" then teachers[#teachers + 1] = citizen end
        end
        return teachers
    end

    return workers
end

local function buildHelpWantedList()
    local rows = {}
    local totalOpen = 0

    for _, building in ipairs(D.buildings or {}) do
        if not isIgnoredBuilding(building) then
            local capacity = buildingStaffCapacity(building)
            if capacity > 0 then
                local workers = staffingWorkers(building)
                local filled = math.min(capacity, #workers)
                local openings = math.max(0, capacity - filled)

                if openings > 0 then
                    rows[#rows + 1] = {
                        building = building,
                        capacity = capacity,
                        filled = filled,
                        openings = openings,
                        workers = workers,
                    }
                    totalOpen = totalOpen + openings
                end
            end
        end
    end

    table.sort(rows, function(a, b)
        if a.openings ~= b.openings then
            return a.openings > b.openings
        end
        local an = cleanBuildingName(a.building.name or a.building.type or "Unknown"):lower()
        local bn = cleanBuildingName(b.building.name or b.building.type or "Unknown"):lower()
        if an ~= bn then return an < bn end
        local ap = a.building.location or {}
        local bp = b.building.location or {}
        if (ap.x or 0) ~= (bp.x or 0) then return (ap.x or 0) < (bp.x or 0) end
        if (ap.z or 0) ~= (bp.z or 0) then return (ap.z or 0) < (bp.z or 0) end
        return (ap.y or 0) < (bp.y or 0)
    end)

    return rows, totalOpen
end

-- Resolve the MineColonies builder assigned to a construction work order.
-- Advanced Peripherals exposes workOrder.builder as a position, not a name.
-- We match that position to citizen workplace locations first, then use the
-- Builder Hut building assignment as a fallback.
local function workOrderBuilders(order)
    local workers = {}
    local seen = {}
    local builderPos = type(order) == "table" and order.builder or nil

    local function addCitizen(citizen)
        if type(citizen) ~= "table" then return end
        local key = tostring(citizen.id or citizen.name or "")
        if key == "" or seen[key] then return end
        workers[#workers + 1] = citizen
        seen[key] = true
    end

    if type(builderPos) == "table" then
        -- Most reliable match: the citizen's work location is the Builder Hut
        -- position carried by the work order.
        for _, citizen in ipairs(D.citizens or {}) do
            if type(citizen.work) == "table" and samePosition(citizen.work.location, builderPos) then
                addCitizen(citizen)
            end
        end

        -- Some MineColonies/AP builds may expose a live builder position.
        -- Use an exact citizen-location match as a secondary fallback.
        if #workers == 0 then
            for _, citizen in ipairs(D.citizens or {}) do
                if samePosition(citizen.location, builderPos) then
                    addCitizen(citizen)
                end
            end
        end

        -- Final fallback: find the building at the work-order builder position
        -- and use its assigned workers.
        if #workers == 0 then
            for _, building in ipairs(D.buildings or {}) do
                if samePosition(building.location, builderPos) then
                    for _, citizen in ipairs(buildingWorkers(building)) do
                        addCitizen(citizen)
                    end
                    break
                end
            end
        end
    end

    table.sort(workers, function(a, b)
        return tostring(a.name or ""):lower() < tostring(b.name or ""):lower()
    end)
    return workers
end

local function workOrderBuilderSummary(order, width)
    local workers = workOrderBuilders(order)
    if #workers == 0 then
        return order.isClaimed and "Assigned" or "Unassigned"
    end

    local names = {}
    for _, citizen in ipairs(workers) do
        names[#names + 1] = tostring(citizen.name or "Unknown")
    end

    local full = table.concat(names, ", ")
    if #full <= width then return full end

    local first = names[1] or "Unknown"
    if #names == 1 then return clip(first, width) end
    local suffix = " (+" .. tostring(#names - 1) .. ")"
    return clip(first, math.max(1, width - #suffix)) .. suffix
end

-- Best-effort mapping from a work order to its target building. Advanced
-- Peripherals exposes the builder position, but not the target building
-- position, so duplicate building types can be ambiguous. We prefer exact
-- name/type matches and a building MineColonies says is currently worked on.
local function workOrderTargetBuilding(order)
    local best, bestScore = nil, -1
    local orderName = tostring(order.buildingName or "")
    local orderType = tostring(order.type or "")
    local cleanOrderName = cleanBuildingName(orderName):lower()
    local cleanOrderType = cleanBuildingName(orderType):lower()

    for _, building in ipairs(D.buildings or {}) do
        local score = 0
        local bName = tostring(building.name or "")
        local bType = tostring(building.type or "")
        local cleanBName = cleanBuildingName(bName):lower()
        local cleanBType = cleanBuildingName(bType):lower()

        if orderName ~= "" and bName == orderName then score = score + 6 end
        if orderType ~= "" and bType == orderType then score = score + 6 end
        if cleanOrderName ~= "unknown" and cleanOrderName ~= ""
            and cleanBName == cleanOrderName then score = score + 3 end
        if cleanOrderType ~= "unknown" and cleanOrderType ~= ""
            and cleanBType == cleanOrderType then score = score + 3 end
        if building.isWorkingOn then score = score + 4 end

        local target = tonumber(order.targetLevel)
        local current = tonumber(building.level)
        if target and current then
            if target == current + 1 then score = score + 2 end
            if target == current then score = score + 1 end
        end

        if score > bestScore and score > 0 then
            best, bestScore = building, score
        end
    end

    return best
end

local function workOrderBuilderKey(order)
    if type(order) ~= "table" then return nil end

    -- AP normally exposes the assigned Builder Hut position here. This is the
    -- best key for detecting two work orders assigned to the same builder.
    local p = order.builder
    if type(p) == "table" and p.x ~= nil and p.y ~= nil and p.z ~= nil then
        return "HUT:" ..
            tostring(p.x) .. ":" ..
            tostring(p.y) .. ":" ..
            tostring(p.z)
    end

    -- Fallback to the resolved builder citizen(s) if the work-order builder
    -- position is unavailable.
    local builders = workOrderBuilders(order)
    if #builders > 0 then
        local ids = {}
        for _, citizen in ipairs(builders) do
            ids[#ids + 1] = tostring(citizen.id or citizen.name or "?")
        end
        table.sort(ids)
        return "CITIZEN:" .. table.concat(ids, ",")
    end

    return nil
end

local function rawWorkOrderStatus(order)
    local building = workOrderTargetBuilding(order)

    -- This is only the raw AP/MineColonies candidate state. refreshData()
    -- later enforces that one builder can have only one ACTIVE work order.
    if order.isClaimed and building and building.isWorkingOn then
        return "ACTIVE", C.good, building
    end

    if order.isClaimed then
        return "CLAIMED", C.info, building
    end

    return "QUEUED", C.warn, building
end

local function workOrderStatus(order)
    local building = workOrderTargetBuilding(order)

    -- refreshData() assigns the display status after resolving conflicts where
    -- one builder has multiple claimed construction jobs.
    local state = type(order) == "table" and order._displayStatus or nil
    if state == "ACTIVE" then
        return "ACTIVE", C.good, building
    elseif state == "CLAIMED" then
        return "CLAIMED", C.info, building
    elseif state == "QUEUED" then
        return "QUEUED", C.warn, building
    end

    return rawWorkOrderStatus(order)
end

-- Advanced Peripherals documents priority on both work orders and buildings,
-- but some 1.20.1 combinations report workOrder.priority as 0 for every order.
-- Prefer a meaningful work-order priority; otherwise fall back to the matched
-- target building's construction priority. Return nil when neither source is
-- useful so the UI does not display a misleading zero.
local function workOrderQueueNumber(order)
    -- Display queue number is assigned after ACTIVE orders are separated out.
    -- ACTIVE construction is not waiting in the queue, so it intentionally
    -- has no queue number and displays as "-".
    return tonumber(order and order._displayQueue)
end

-- Sort construction orders by operational state first, then by the actual
-- MineColonies priority value. An order already being actively built remains
-- above claimed/queued work even if another order has a numerically higher
-- queue priority, because the builder is already committed to that job.
local function sortWorkOrdersForDisplay(orders)
    local stateRank = { ACTIVE = 1, CLAIMED = 2, QUEUED = 3 }

    table.sort(orders, function(a, b)
        local aState = workOrderStatus(a)
        local bState = workOrderStatus(b)
        local aRank = stateRank[aState] or 9
        local bRank = stateRank[bState] or 9

        -- Operational state first:
        -- ACTIVE, then CLAIMED, then QUEUED.
        if aRank ~= bRank then
            return aRank < bRank
        end

        -- Within each state group, preserve the original MineColonies/AP
        -- work-order sequence. _apiOrder is captured before display sorting.
        return (tonumber(a and a._apiOrder) or 999999)
            < (tonumber(b and b._apiOrder) or 999999)
    end)
end

local function refreshData()
    apiErrors = {}

    D.name = api("getColonyName", "Unknown Colony")
    D.id = api("getColonyID", "?")
    D.style = api("getColonyStyle", "Unknown")
    D.location = api("getLocation", {})
    D.happiness = api("getHappiness", 0)
    D.active = api("isActive", false)
    D.underAttack = api("isUnderAttack", false)
    D.population = api("amountOfCitizens", 0)
    D.maxPopulation = api("maxOfCitizens", 0)
    D.graves = api("amountOfGraves", 0)
    D.constructionSites = api("amountOfConstructionSites", 0)

    D.citizens = normalizeList(api("getCitizens", {}))
    D.buildings = normalizeList(api("getBuildings", {}))
    D.requests = normalizeList(api("getRequests", {}))
    D.workOrders = normalizeOrderedList(api("getWorkOrders", {}))
    D.visitors = normalizeList(api("getVisitors", {}))

    -- Preserve the original getWorkOrders() sequence for sorting.
    for i, o in ipairs(D.workOrders) do
        o._apiOrder = i
        o._displayQueue = nil
        o._displayStatus = nil
    end

    -- A builder can physically work only one construction job at a time.
    -- MineColonies/AP may report multiple claimed target buildings as
    -- isWorkingOn=true when the same builder has several manually assigned
    -- work orders. Keep only the first ACTIVE candidate for each builder in
    -- the authoritative work-order sequence. Additional jobs for that builder
    -- remain CLAIMED and therefore stay in the displayed queue.
    local activeBuilderKeys = {}

    for _, o in ipairs(D.workOrders) do
        local rawState = rawWorkOrderStatus(o)

        if rawState == "ACTIVE" then
            local builderKey = workOrderBuilderKey(o)

            if builderKey and activeBuilderKeys[builderKey] then
                o._displayStatus = "CLAIMED"
            else
                o._displayStatus = "ACTIVE"
                if builderKey then
                    activeBuilderKeys[builderKey] = true
                end
            end
        else
            o._displayStatus = rawState
        end
    end

    sortWorkOrdersForDisplay(D.workOrders)

    -- ACTIVE work is already under construction and is therefore not waiting
    -- in the queue. Number every remaining order sequentially in the exact
    -- order shown on the Construction tab: 1, 2, 3, ...
    local displayQueue = 0
    for _, o in ipairs(D.workOrders) do
        local state = workOrderStatus(o)
        if state == "ACTIVE" then
            o._displayQueue = nil
        else
            displayQueue = displayQueue + 1
            o._displayQueue = displayQueue
        end
    end

    -- Citizens are displayed as civilians first and military at the bottom.
    -- The Buildings screen hides Post Boxes, then orders the remaining
    -- buildings from least complete to fully complete.
    sortByName(D.citizens, "name")
    D.citizenDisplayRows = buildCitizenDisplayRows(D.citizens)
    D.displayBuildings = visibleBuildings(D.buildings)
    sortBuildingsByCompletion(D.displayBuildings)
    D.helpWanted, D.helpWantedOpenings = buildHelpWantedList()
    sortByName(D.requests, "name")
    sortByName(D.visitors, "name")

    D.idle = 0
    D.needFood = 0
    D.injured = 0
    D.noJob = 0
    D.children = 0
    D.asleep = 0
    D.sick = 0
    D.sickNames = {}

    for _, c in ipairs(D.citizens) do
        if c.isIdle then D.idle = D.idle + 1 end
        if c.betterFood then D.needFood = D.needFood + 1 end
        if c.isAsleep then D.asleep = D.asleep + 1 end
        if isCitizenSick(c) then
            D.sick = D.sick + 1
            D.sickNames[#D.sickNames + 1] = tostring(c.name or "Unknown")
        end
        if c.age == "child" then
            D.children = D.children + 1
        elseif c.age == "adult" and c.work == nil then
            D.noJob = D.noJob + 1
        end
        if type(c.health) == "number" and type(c.maxHealth) == "number" and c.health < c.maxHealth then
            D.injured = D.injured + 1
        end
    end

    D.unclaimedOrders = 0
    D.activeOrders = 0
    for _, o in ipairs(D.workOrders) do
        if not o.isClaimed then D.unclaimedOrders = D.unclaimedOrders + 1 end
        local state = workOrderStatus(o)
        if state == "ACTIVE" then D.activeOrders = D.activeOrders + 1 end
    end
end

-- =========================
-- Sick-citizen redstone trigger
-- =========================

local function setSickTrigger(powered)
    powered = powered == true

    local integrator = resolveSickRedstoneIntegrator()

    if integrator then
        -- Ensure the fallback computer output is not accidentally left on
        -- after an integrator is attached.
        pcall(function()
            redstone.setOutput(SICK_TRIGGER_COMPUTER_SIDE, false)
        end)

        local ok = pcall(function()
            integrator.setOutput(SICK_TRIGGER_INTEGRATOR_SIDE, powered)
        end)

        if ok then
            return true, "integrator"
        end

        -- If the detected integrator is disabled/unusable, immediately fall
        -- back to the computer output instead of losing the alarm.
        sickRedstoneIntegrator = nil
        sickRedstoneIntegratorName = nil
    end

    local ok = pcall(function()
        redstone.setOutput(SICK_TRIGGER_COMPUTER_SIDE, powered)
    end)

    return ok, "computer"
end

local function updateSickTrigger()
    local sickCount = tonumber(D.sick) or 0
    setSickTrigger(sickCount > 0)
end

-- =========================
-- Update check / terminal startup summary
-- =========================

local function terminalColor(color)
    if term.isColor and term.isColor() then term.setTextColor(color) end
end

local UPDATE = SuiteUpdater.new({
    appId = "command",
    appVersion = PROGRAM_VERSION,
    suiteVersion = SUITE_VERSION,
    displayName = "COMMAND CENTER",
    checkSeconds = UPDATE_CHECK_SECONDS,
    drawMessage = function(title, message, color)
        local w, h = size()
        local mid = math.max(5, math.floor(h / 2))
        fill(1, mid - 1, w, mid + 1, C.panel)
        center(mid - 1, tostring(title or "UPDATE"), color or C.title, C.panel)
        center(mid, clip(tostring(message or ""), math.max(1, w - 2)), C.text, C.panel)
    end,
})

local function checkForUpdate() return UPDATE.check() end
local function updateStatusText(checking) return UPDATE.statusText(checking) end
local function installAvailableUpdate() return UPDATE.install() end

local function renderTerminalStartup(updateText, statusText)
    local monitorW, monitorH = monitor.getSize()
    local errors = errorCount()

    term.setBackgroundColor(colors.black)
    terminalColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)

    print("MineColonies Command Center v" .. PROGRAM_VERSION)
    print("Control Suite: v" .. SUITE_VERSION)
    print("Colony:       " .. tostring(D.name or "Unknown Colony"))
    print("Monitor:      ONLINE [" .. tostring(monitorName or "?") .. "] " ..
        tostring(monitorW) .. "x" .. tostring(monitorH))
    print("Integrator:   ONLINE [" .. tostring(colonyPeripheralName or "?") .. "]")
    print("Citizens:     " .. tostring(D.population or 0) .. "/" ..
        tostring(D.maxPopulation or 0))
    print("Sick trigger: " .. sickTriggerHardwareText(D.sick))

    if errors == 0 then
        terminalColor(colors.lime)
        print("Health:       OK")
    else
        terminalColor(colors.orange)
        print("Health:       WARNING (" .. tostring(errors) .. " API error(s))")
    end

    local updateLine = tostring(updateText or "NOT CHECKED")
    if updateLine:find("UPDATE AVAILABLE", 1, true) then
        terminalColor(colors.yellow)
    elseif updateLine:find("ERROR:", 1, true) then
        terminalColor(colors.orange)
    elseif updateLine:find("CURRENT", 1, true) then
        terminalColor(colors.lime)
    elseif updateLine:find("LOCAL NEWER", 1, true) then
        terminalColor(colors.cyan)
    else
        terminalColor(colors.cyan)
    end
    print("Update check: " .. updateLine)

    terminalColor(colors.white)
    print("Status:       " .. tostring(statusText or "RUNNING"))
    print(string.rep("-", 50))
end

-- =========================
-- UI state
-- =========================

local pages = {
    { id = "home", label = "HOME" },
    { id = "citizens", label = "CITIZENS" },
    { id = "buildings", label = "BUILDINGS" },
    { id = "help", label = "HELP WANTED" },
    { id = "requests", label = "REQUESTS" },
    { id = "orders", label = "CONSTRUCTION" },
}

local currentPage = "home"
local detail = nil
local listPage = {
    citizens = 1,
    buildings = 1,
    help = 1,
    requests = 1,
    orders = 1,
}
local detailScroll = 1
local raidBlink = false
local lastRefreshLabel = "just now"

local function pageTitle()
    for _, p in ipairs(pages) do
        if p.id == currentPage then return p.label end
    end
    return "COMMAND CENTER"
end

-- =========================
-- Frame / navigation
-- =========================

local function drawHeader()
    local headBg = C.header
    if D.underAttack then headBg = raidBlink and C.danger or C.bg end

    local status
    local statusBg = C.panel
    local statusFg = D.active and C.good or C.warn
    local button = nil

    if D.underAttack then
        status = "!!! COLONY UNDER ATTACK !!!"
        statusBg = C.danger
        statusFg = C.headerText
    else
        status = (D.active and "ACTIVE" or "INACTIVE")
            .. "  |  " .. pageTitle()
            .. "  |  Refresh: " .. lastRefreshLabel
        if errorCount() > 0 then status = status .. "  |  API ERRORS: " .. errorCount() end
        if UPDATE.availableVersion then
            button = {
                id = "program_update",
                label = UPDATE.buttonLabel(),
                bg = C.navActive, fg = C.navText,
                action = installAvailableUpdate,
            }
        end
    end

    monitorUI.drawHeader({
        title = "MINECOLONIES COMMAND CENTER",
        subtitle = (D.name or "Unknown Colony") .. "  [COMMAND-v" .. PROGRAM_VERSION .. "]",
        headerBg = headBg,
        status = status, statusBg = statusBg, statusFg = statusFg,
        button = button,
    })
end

local function drawNav()
    local active = (detail == nil) and currentPage or nil
    monitorUI.drawNav(active, pages, nil, function(pageId)
        currentPage = pageId
        detail = nil
        detailScroll = 1
    end)
end

local function drawSubBar(text)
    local w, h = size()
    fill(1, h - 1, w, h - 1, C.panel)
    center(h - 1, text, C.dim, C.panel)
end

-- =========================
-- Home dashboard
-- =========================

local function statColor(kind, value)
    if kind == "danger" then return value > 0 and C.danger or C.good end
    if kind == "warn" then return value > 0 and C.warn or C.good end
    return C.info
end

local function drawTile(x1, y1, x2, y2, label, value, valueColor)
    fill(x1, y1, x2, y2, C.panel)
    center(y1, label, C.dim, C.panel, x1, x2)
    center(math.min(y2, y1 + 1), tostring(value), valueColor or C.text, C.panel, x1, x2)
end

local function drawHome()
    local w, h = size()
    local bodyTop = 5
    local bodyBottom = h - 2

    center(4, "COLONY STATUS", C.title, C.bg)

    -- Health warning banner. It appears only when at least one citizen is
    -- currently reporting a sickness-related MineColonies state.
    if (D.sick or 0) > 0 then
        local citizenWord = (D.sick == 1) and "CITIZEN" or "CITIZENS"
        local banner = "!!! HEALTH WARNING: " .. tostring(D.sick) .. " SICK " .. citizenWord .. " !!!"
        fill(1, 5, w, 5, C.danger)
        center(5, banner, C.headerText, C.danger)

        -- If space permits, show the affected names on a second line.
        local names = table.concat(D.sickNames or {}, ", ")
        fill(1, 6, w, 6, C.bg)
        local alarmState = sickTriggerHardwareText(D.sick)
        if names ~= "" then
            center(6, "Sick: " .. names .. "  |  TRIGGER: " .. alarmState,
                hasSickTriggerHardware() and C.danger or C.warn, C.bg)
        else
            center(6, "TRIGGER: " .. alarmState,
                hasSickTriggerHardware() and C.danger or C.warn, C.bg)
        end

        -- Touching either warning line jumps directly to the citizen list.
        addTouchArea("sick_banner", 1, 5, w, 6, function()
            currentPage = "citizens"
            detail = nil
            detailScroll = 1
            listPage.citizens = 1
        end)

        bodyTop = 8
    end

    local cols = (w >= 72) and 4 or 2
    local gap = 1
    local tileW = math.floor((w - (cols - 1) * gap) / cols)
    local tileH = 2

    local stats = {
        {"POPULATION", tostring(D.population) .. "/" .. tostring(D.maxPopulation), C.good},
        {"HAPPINESS", string.format("%.2f", tonumber(D.happiness) or 0), C.info},
        {"REQUESTS", #D.requests, statColor("warn", #D.requests)},
        {"WORK ORDERS", #D.workOrders, statColor("warn", #D.workOrders)},
        {"IDLE", D.idle, statColor("warn", D.idle)},
        {"FOOD ALERTS", D.needFood, statColor("danger", D.needFood)},
        {"INJURED", D.injured, statColor("danger", D.injured)},
        {"NO JOB", D.noJob, statColor("warn", D.noJob)},
        {"HELP WANTED", D.helpWantedOpenings or 0, statColor("warn", D.helpWantedOpenings or 0)},
        {"CHILDREN", D.children, C.accent},
        {"VISITORS", #D.visitors, C.accent},
        {"CONSTRUCTION", D.constructionSites, statColor("warn", D.constructionSites)},
        {"GRAVES", D.graves, statColor("danger", D.graves)},
    }

    local maxRows = math.floor((bodyBottom - bodyTop + 1) / (tileH + 1))
    local maxTiles = maxRows * cols
    local count = math.min(#stats, maxTiles)

    for i = 1, count do
        local idx = i - 1
        local col = idx % cols
        local row = math.floor(idx / cols)
        local x1 = 1 + col * (tileW + gap)
        local x2 = math.min(w, x1 + tileW - 1)
        local y1 = bodyTop + row * (tileH + 1)
        local y2 = y1 + tileH - 1
        local s = stats[i]
        drawTile(x1, y1, x2, y2, s[1], s[2], s[3])
    end

    local infoY = bodyTop + math.ceil(count / cols) * (tileH + 1)
    if infoY <= bodyBottom then
        local line = "ID " .. tostring(D.id)
            .. "  |  Style " .. tostring(D.style)
            .. "  |  Town Hall " .. posText(D.location)
        center(infoY, line, C.dim, C.bg)
    end

    fill(1, h - 1, w, h - 1, C.panel)
    local refreshStart = math.max(1, w - 10)
    writeAt(2, h - 1, "Auto-refresh: " .. REFRESH_SECONDS .. "s", C.dim, C.panel)
    addButton("refresh", refreshStart, h - 1, w, h - 1, "REFRESH", C.navActive, C.navText, function()
        refreshData()
        updateSickTrigger()
        lastRefreshLabel = "just now"
    end)
end

-- =========================
-- List pages
-- =========================

local function listForPage(page)
    if page == "citizens" then return D.citizenDisplayRows or D.citizens end
    if page == "buildings" then return D.displayBuildings or visibleBuildings(D.buildings) end
    if page == "help" then return D.helpWanted or {} end
    if page == "requests" then return D.requests end
    if page == "orders" then return D.workOrders end
    return {}
end

local function listRowText(page, item, width)
    if page == "citizens" then
        local status = item.state or ""
        return clip((item.name or "Unknown") .. " | " .. citizenJob(item) .. " | " .. status, width)
    elseif page == "buildings" then
        local status = (not item.built) and "BUILDING" or (item.isWorkingOn and "UPGRADE" or "READY")
        return clip(cleanBuildingName(item.name or item.type or "Unknown") .. " | L" .. tostring(item.level or "?")
            .. "/" .. tostring(item.maxLevel or "?") .. " | " .. status, width)
    elseif page == "help" then
        local building = item.building or {}
        return clip(cleanBuildingName(building.name or building.type or "Unknown")
            .. " | L" .. tostring(building.level or "?")
            .. " | " .. tostring(item.filled or 0) .. "/" .. tostring(item.capacity or "?")
            .. " | OPEN " .. tostring(item.openings or 0), width)
    elseif page == "requests" then
        return clip(tostring(item.count or item.minCount or "?") .. "x "
            .. tostring(item.name or "Request") .. " | " .. tostring(item.target or ""), width)
    elseif page == "orders" then
        local status = workOrderStatus(item)
        local qn = workOrderQueueNumber(item)
        return clip("Q" .. tostring(qn or "-") .. " | "
            .. cleanBuildingName(item.buildingName or item.type or "Build") .. " | L"
            .. tostring(item.targetLevel or "?") .. " | " .. workOrderBuilderSummary(item, math.max(8, math.floor(width * 0.3)))
            .. " | " .. status, width)
    end
    return ""
end

local function listRowColor(page, item)
    if page == "citizens" then
        if type(item.health) == "number" and type(item.maxHealth) == "number" and item.health < item.maxHealth then return C.danger end
        if item.betterFood then return C.warn end
        if item.isIdle then return C.title end
        if item.age == "child" then return C.accent end
        return C.text
    elseif page == "buildings" then
        if not item.built then return C.warn end
        if item.isWorkingOn then return C.title end
        return C.good
    elseif page == "help" then
        return C.warn
    elseif page == "requests" then
        return C.warn
    elseif page == "orders" then
        local _, color = workOrderStatus(item)
        return color
    end
    return C.text
end

local function drawListPage(page)
    local w, h = size()
    local list = listForPage(page)
    local citizenTable = (page == "citizens")
    local buildingTable = (page == "buildings")
    local helpTable = (page == "help")
    local requestTable = (page == "requests")
    local orderTable = (page == "orders")
    local fixedTable = citizenTable or buildingTable or helpTable or requestTable or orderTable
    local top = fixedTable and 6 or 5
    local bottom = h - 2
    local rows = math.max(1, bottom - top + 1)
    local pagesTotal = math.max(1, math.ceil(#list / rows))
    listPage[page] = math.max(1, math.min(listPage[page] or 1, pagesTotal))
    local pg = listPage[page]
    local first = (pg - 1) * rows + 1
    local last = math.min(#list, first + rows - 1)

    if page == "orders" then
        center(4, pageTitle() .. "  (" .. #list .. ")  ACTIVE: " .. tostring(D.activeOrders or 0), C.title, C.bg)
    elseif page == "help" then
        center(4, pageTitle() .. "  (" .. #list .. " BUILDINGS | "
            .. tostring(D.helpWantedOpenings or 0) .. " OPENINGS)", C.title, C.bg)
    elseif page == "citizens" then
        center(4, pageTitle() .. "  (" .. #D.citizens .. ")", C.title, C.bg)
    else
        center(4, pageTitle() .. "  (" .. #list .. ")", C.title, C.bg)
    end

    local columns = nil
    if citizenTable then
        -- Fixed four-column citizen layout tuned for the 5x3 monitor.
        local usable = w - 2
        local separatorCount = 3
        local content = math.max(20, usable - separatorCount)

        local nameW = math.max(12, math.floor(content * 0.31))
        local jobW = math.max(10, math.floor(content * 0.25))
        local stateW = math.max(10, math.floor(content * 0.25))
        local statusW = content - nameW - jobW - stateW

        while statusW < 7 and (nameW > 12 or jobW > 10 or stateW > 10) do
            if nameW > 12 then nameW = nameW - 1
            elseif stateW > 10 then stateW = stateW - 1
            elseif jobW > 10 then jobW = jobW - 1 end
            statusW = content - nameW - jobW - stateW
        end
        statusW = math.max(1, statusW)

        local nameX = 2
        local sep1X = nameX + nameW
        local jobX = sep1X + 1
        local sep2X = jobX + jobW
        local stateX = sep2X + 1
        local sep3X = stateX + stateW
        local statusX = sep3X + 1

        columns = {
            nameX = nameX, nameW = nameW, sep1X = sep1X,
            jobX = jobX, jobW = jobW, sep2X = sep2X,
            stateX = stateX, stateW = stateW, sep3X = sep3X,
            statusX = statusX, statusW = math.max(1, w - statusX + 1),
        }

        fill(1, 5, w, 5, C.panel2)
        writeAt(columns.nameX, 5, pad("NAME", columns.nameW), colors.black, C.panel2)
        writeAt(columns.sep1X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.jobX, 5, pad("JOB", columns.jobW), colors.black, C.panel2)
        writeAt(columns.sep2X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.stateX, 5, pad("STATE", columns.stateW), colors.black, C.panel2)
        writeAt(columns.sep3X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.statusX, 5, pad("STATUS", columns.statusW), colors.black, C.panel2)

    elseif buildingTable then
        -- Clean fixed-column building table. The WORKER(S) column shows names
        -- directly; tapping the row opens the complete worker list.
        local usable = w - 2
        local separatorCount = 3
        local content = math.max(24, usable - separatorCount)

        local buildingW = math.max(15, math.floor(content * 0.31))
        local levelW = 7
        local statusW = 9
        local workersW = content - buildingW - levelW - statusW

        while workersW < 14 and buildingW > 15 do
            buildingW = buildingW - 1
            workersW = content - buildingW - levelW - statusW
        end
        workersW = math.max(1, workersW)

        local buildingX = 2
        local sep1X = buildingX + buildingW
        local levelX = sep1X + 1
        local sep2X = levelX + levelW
        local workersX = sep2X + 1
        local sep3X = workersX + workersW
        local statusX = sep3X + 1

        columns = {
            buildingX = buildingX, buildingW = buildingW, sep1X = sep1X,
            levelX = levelX, levelW = levelW, sep2X = sep2X,
            workersX = workersX, workersW = workersW, sep3X = sep3X,
            statusX = statusX, statusW = math.max(1, w - statusX + 1),
        }

        fill(1, 5, w, 5, C.panel2)
        writeAt(columns.buildingX, 5, pad("BUILDING", columns.buildingW), colors.black, C.panel2)
        writeAt(columns.sep1X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.levelX, 5, pad("LEVEL", columns.levelW), colors.black, C.panel2)
        writeAt(columns.sep2X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.workersX, 5, pad("WORKER(S)", columns.workersW), colors.black, C.panel2)
        writeAt(columns.sep3X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.statusX, 5, pad("STATUS", columns.statusW), colors.black, C.panel2)

    elseif helpTable then
        -- Help Wanted: BUILDING | LEVEL | FILLED | OPEN
        local usable = w - 2
        local separatorCount = 3
        local content = math.max(24, usable - separatorCount)

        local levelW = 7
        local filledW = 9
        local openW = 7
        local buildingW = math.max(16, content - levelW - filledW - openW)

        local buildingX = 2
        local sep1X = buildingX + buildingW
        local levelX = sep1X + 1
        local sep2X = levelX + levelW
        local filledX = sep2X + 1
        local sep3X = filledX + filledW
        local openX = sep3X + 1

        columns = {
            buildingX = buildingX, buildingW = buildingW, sep1X = sep1X,
            levelX = levelX, levelW = levelW, sep2X = sep2X,
            filledX = filledX, filledW = filledW, sep3X = sep3X,
            openX = openX, openW = math.max(1, w - openX + 1),
        }

        fill(1, 5, w, 5, C.panel2)
        writeAt(columns.buildingX, 5, pad("BUILDING", columns.buildingW), colors.black, C.panel2)
        writeAt(columns.sep1X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.levelX, 5, pad("LEVEL", columns.levelW), colors.black, C.panel2)
        writeAt(columns.sep2X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.filledX, 5, pad("FILLED", columns.filledW), colors.black, C.panel2)
        writeAt(columns.sep3X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.openX, 5, pad("OPEN", columns.openW), colors.black, C.panel2)

    elseif requestTable then
        -- Fixed-column request table tuned for the 5x3 monitor.
        -- REQUEST | QTY | TARGET | STATUS
        local usable = w - 2
        local separatorCount = 3
        local content = math.max(24, usable - separatorCount)

        local qtyW = 7
        local statusW = 12
        local requestW = math.max(16, math.floor(content * 0.34))
        local targetW = content - requestW - qtyW - statusW

        while targetW < 14 and requestW > 16 do
            requestW = requestW - 1
            targetW = content - requestW - qtyW - statusW
        end
        targetW = math.max(1, targetW)

        local requestX = 2
        local sep1X = requestX + requestW
        local qtyX = sep1X + 1
        local sep2X = qtyX + qtyW
        local targetX = sep2X + 1
        local sep3X = targetX + targetW
        local statusX = sep3X + 1

        columns = {
            requestX = requestX, requestW = requestW, sep1X = sep1X,
            qtyX = qtyX, qtyW = qtyW, sep2X = sep2X,
            targetX = targetX, targetW = targetW, sep3X = sep3X,
            statusX = statusX, statusW = math.max(1, w - statusX + 1),
        }

        fill(1, 5, w, 5, C.panel2)
        writeAt(columns.requestX, 5, pad("REQUEST", columns.requestW), colors.black, C.panel2)
        writeAt(columns.sep1X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.qtyX, 5, pad("QTY", columns.qtyW), colors.black, C.panel2)
        writeAt(columns.sep2X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.targetX, 5, pad("TARGET", columns.targetW), colors.black, C.panel2)
        writeAt(columns.sep3X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.statusX, 5, pad("STATUS", columns.statusW), colors.black, C.panel2)

    elseif orderTable then
        -- Fixed-column construction/work-order table tuned for the 5x3 monitor.
        -- Q# | BUILDING | TARGET | BUILDER | STATUS
        local usable = w - 2
        local separatorCount = 4
        local content = math.max(28, usable - separatorCount)

        local orderW = 4
        local targetW = 7
        local statusW = 9
        local buildingW = math.max(14, math.floor(content * 0.28))
        local builderW = content - orderW - buildingW - targetW - statusW

        while builderW < 12 and buildingW > 14 do
            buildingW = buildingW - 1
            builderW = content - orderW - buildingW - targetW - statusW
        end
        builderW = math.max(1, builderW)

        local orderX = 2
        local sep0X = orderX + orderW
        local buildingX = sep0X + 1
        local sep1X = buildingX + buildingW
        local targetX = sep1X + 1
        local sep2X = targetX + targetW
        local builderX = sep2X + 1
        local sep3X = builderX + builderW
        local statusX = sep3X + 1

        columns = {
            orderX = orderX, orderW = orderW, sep0X = sep0X,
            buildingX = buildingX, buildingW = buildingW, sep1X = sep1X,
            targetX = targetX, targetW = targetW, sep2X = sep2X,
            builderX = builderX, builderW = builderW, sep3X = sep3X,
            statusX = statusX, statusW = math.max(1, w - statusX + 1),
        }

        fill(1, 5, w, 5, C.panel2)
        writeAt(columns.orderX, 5, pad("Q#", columns.orderW), colors.black, C.panel2)
        writeAt(columns.sep0X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.buildingX, 5, pad("BUILDING", columns.buildingW), colors.black, C.panel2)
        writeAt(columns.sep1X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.targetX, 5, pad("TARGET", columns.targetW), colors.black, C.panel2)
        writeAt(columns.sep2X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.builderX, 5, pad("BUILDER", columns.builderW), colors.black, C.panel2)
        writeAt(columns.sep3X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.statusX, 5, pad("STATUS", columns.statusW), colors.black, C.panel2)
    end

    if #list == 0 then
        center(math.floor((top + bottom) / 2), "Nothing to display", C.dim, C.bg)
    else
        local y = top
        for i = first, last do
            local rowIndex = i
            local item = list[rowIndex]
            local bg = (y % 2 == 0) and C.bg or C.panel
            fill(1, y, w, y, bg)

            if citizenTable then
                if item._sectionHeader then
                    fill(1, y, w, y, C.panel2)
                    local header = "-- " .. tostring(item._sectionTitle or "SECTION")
                        .. " (" .. tostring(item._sectionCount or 0) .. ") --"
                    center(y, header, C.title, C.panel2)
                else
                    local statusText, statusColor = citizenStatus(item)
                    writeAt(columns.nameX, y, pad(item.name or "Unknown", columns.nameW), C.text, bg)
                    writeAt(columns.sep1X, y, "|", C.dim, bg)
                    writeAt(columns.jobX, y, pad(citizenJob(item), columns.jobW), C.accent, bg)
                    writeAt(columns.sep2X, y, "|", C.dim, bg)
                    writeAt(columns.stateX, y, pad(item.state or "", columns.stateW), C.dim, bg)
                    writeAt(columns.sep3X, y, "|", C.dim, bg)
                    writeAt(columns.statusX, y, pad(statusText, columns.statusW), statusColor, bg)
                end

            elseif buildingTable then
                local statusText = (not item.built) and "BUILDING" or (item.isWorkingOn and "UPGRADE" or "READY")
                local statusColor = (not item.built) and C.warn or (item.isWorkingOn and C.title or C.good)
                local displayName = cleanBuildingName(item.name or item.type or "Unknown")
                local levelText = tostring(item.level or "?") .. "/" .. tostring(item.maxLevel or "?")
                local workerText = buildingWorkerSummary(item, columns.workersW)

                writeAt(columns.buildingX, y, pad(displayName, columns.buildingW), C.text, bg)
                writeAt(columns.sep1X, y, "|", C.dim, bg)
                writeAt(columns.levelX, y, pad(levelText, columns.levelW), C.accent, bg)
                writeAt(columns.sep2X, y, "|", C.dim, bg)
                writeAt(columns.workersX, y, pad(workerText, columns.workersW),
                    workerText == "None" and C.dim or C.info, bg)
                writeAt(columns.sep3X, y, "|", C.dim, bg)
                writeAt(columns.statusX, y, pad(statusText, columns.statusW), statusColor, bg)

            elseif helpTable then
                local building = item.building or {}
                local displayName = cleanBuildingName(building.name or building.type or "Unknown")
                local levelText = tostring(building.level or "?") .. "/" .. tostring(building.maxLevel or "?")
                local filledText = tostring(item.filled or 0) .. "/" .. tostring(item.capacity or "?")
                local openText = tostring(item.openings or 0)

                writeAt(columns.buildingX, y, pad(displayName, columns.buildingW), C.text, bg)
                writeAt(columns.sep1X, y, "|", C.dim, bg)
                writeAt(columns.levelX, y, pad(levelText, columns.levelW), C.accent, bg)
                writeAt(columns.sep2X, y, "|", C.dim, bg)
                writeAt(columns.filledX, y, pad(filledText, columns.filledW), C.info, bg)
                writeAt(columns.sep3X, y, "|", C.dim, bg)
                writeAt(columns.openX, y, pad(openText, columns.openW), C.warn, bg)

            elseif requestTable then
                local requestName = tostring(item.name or "Request")
                local amount = item.count
                if amount == nil then amount = item.minCount end
                local qtyText = tostring(amount or "?")
                local targetText = tostring(item.target or "")
                local statusText = tostring(item.state or "OPEN")
                local statusLower = statusText:lower()
                local statusColor = C.warn
                if statusLower:find("complete", 1, true) or statusLower:find("fulfilled", 1, true) then
                    statusColor = C.good
                elseif statusLower:find("cancel", 1, true) then
                    statusColor = C.danger
                elseif statusLower:find("progress", 1, true) or statusLower:find("assign", 1, true) then
                    statusColor = C.info
                end

                writeAt(columns.requestX, y, pad(requestName, columns.requestW), C.text, bg)
                writeAt(columns.sep1X, y, "|", C.dim, bg)
                writeAt(columns.qtyX, y, pad(qtyText, columns.qtyW), C.accent, bg)
                writeAt(columns.sep2X, y, "|", C.dim, bg)
                writeAt(columns.targetX, y, pad(targetText, columns.targetW), C.dim, bg)
                writeAt(columns.sep3X, y, "|", C.dim, bg)
                writeAt(columns.statusX, y, pad(statusText, columns.statusW), statusColor, bg)

            elseif orderTable then
                local statusText, statusColor = workOrderStatus(item)
                local displayName = cleanBuildingName(item.buildingName or item.type or "Build")
                local targetText = "L" .. tostring(item.targetLevel or "?")
                local builderText = workOrderBuilderSummary(item, columns.builderW)
                local builderColor = (#workOrderBuilders(item) > 0) and C.info or C.dim
                local queueNumber = workOrderQueueNumber(item)
                local orderText = queueNumber and tostring(queueNumber) or "-"

                writeAt(columns.orderX, y, pad(orderText, columns.orderW), statusText == "ACTIVE" and C.good or C.accent, bg)
                writeAt(columns.sep0X, y, "|", C.dim, bg)
                writeAt(columns.buildingX, y, pad(displayName, columns.buildingW), C.text, bg)
                writeAt(columns.sep1X, y, "|", C.dim, bg)
                writeAt(columns.targetX, y, pad(targetText, columns.targetW), C.accent, bg)
                writeAt(columns.sep2X, y, "|", C.dim, bg)
                writeAt(columns.builderX, y, pad(builderText, columns.builderW), builderColor, bg)
                writeAt(columns.sep3X, y, "|", C.dim, bg)
                writeAt(columns.statusX, y, pad(statusText, columns.statusW), statusColor, bg)

            else
                writeAt(2, y, listRowText(page, item, w - 3), listRowColor(page, item), bg)
            end

            if not item._sectionHeader then
                addTouchArea("row_" .. rowIndex, 1, y, w, y, function()
                    detail = { page = page, index = rowIndex }
                    detailScroll = 1
                end)
            end
            y = y + 1
        end
    end

    local sub = "Page " .. pg .. "/" .. pagesTotal
    if pagesTotal > 1 then
        local prevX2 = math.min(10, math.floor(w / 4))
        addButton("prev", 1, h - 1, prevX2, h - 1, "< PREV", C.panel, C.text, function()
            listPage[page] = math.max(1, (listPage[page] or 1) - 1)
        end)
        local nextX1 = math.max(prevX2 + 1, w - 9)
        addButton("next", nextX1, h - 1, w, h - 1, "NEXT >", C.panel, C.text, function()
            listPage[page] = math.min(pagesTotal, (listPage[page] or 1) + 1)
        end)
        center(h - 1, sub, C.dim, C.panel, prevX2 + 1, nextX1 - 1)
    else
        drawSubBar(sub .. " | Touch a row for details")
    end
end

-- =========================
-- Detail screens
-- =========================

local function addDetailLine(lines, label, value, color)
    lines[#lines + 1] = { label = label, value = tostr(value, "N/A"), color = color or C.text }
end

local function detailLines(page, item)
    local lines = {}

    if page == "citizens" then
        local statusText, statusColor = citizenStatus(item)
        addDetailLine(lines, "Name", item.name)
        addDetailLine(lines, "Status", statusText, statusColor)
        addDetailLine(lines, "Sick", yesno(isCitizenSick(item)), isCitizenSick(item) and C.danger or C.good)
        addDetailLine(lines, "Age", item.age)
        addDetailLine(lines, "Gender", item.gender)
        addDetailLine(lines, "State", item.state)
        if item.health ~= nil and item.maxHealth ~= nil then
            addDetailLine(lines, "Health", tostring(item.health) .. "/" .. tostring(item.maxHealth),
                item.health < item.maxHealth and C.danger or C.good)
        end
        addDetailLine(lines, "Happiness", item.happiness)
        addDetailLine(lines, "Saturation", item.saturation)
        addDetailLine(lines, "Idle", yesno(item.isIdle), item.isIdle and C.warn or C.good)
        addDetailLine(lines, "In bed", yesno(item.isAsleep), item.isAsleep and C.info or C.text)
        addDetailLine(lines, "Needs better food", yesno(item.betterFood), item.betterFood and C.danger or C.good)
        if type(item.work) == "table" then
            addDetailLine(lines, "Job", cleanJobName(item.work.job or "Worker"))
            addDetailLine(lines, "Workplace", item.work.name or item.work.type)
            addDetailLine(lines, "Work level", item.work.level)
            addDetailLine(lines, "Work location", posText(item.work.location))
        else
            addDetailLine(lines, "Job", item.age == "child" and "Child" or "No job", C.warn)
        end
        addDetailLine(lines, "Current location", posText(item.location))
        addDetailLine(lines, "Bed", posText(item.bedPos))
        if type(item.home) == "table" then
            addDetailLine(lines, "Home", item.home.type)
            addDetailLine(lines, "Home level", item.home.level)
            addDetailLine(lines, "Home location", posText(item.home.location))
        end

    elseif page == "buildings" then
        local workers = buildingWorkers(item)
        local statusText = (not item.built) and "BUILDING" or (item.isWorkingOn and "UPGRADE" or "READY")
        local statusColor = (not item.built) and C.warn or (item.isWorkingOn and C.title or C.good)

        addDetailLine(lines, "Building", cleanBuildingName(item.name or item.type or "Unknown"))
        addDetailLine(lines, "Type", cleanBuildingName(item.type or item.name or "Unknown"))
        addDetailLine(lines, "Status", statusText, statusColor)
        addDetailLine(lines, "Level", tostring(item.level or "?") .. "/" .. tostring(item.maxLevel or "?"))
        addDetailLine(lines, "Style", item.style)

        addDetailLine(lines, "Assigned workers", #workers, #workers > 0 and C.info or C.dim)
        if #workers == 0 then
            addDetailLine(lines, "Workers", "None assigned", C.dim)
        else
            for i, citizen in ipairs(workers) do
                local workerName = tostring(citizen.name or "Unknown")
                local job = citizenJob(citizen)
                if job ~= "No job" and job ~= "Child" then
                    workerName = workerName .. " (" .. job .. ")"
                end
                addDetailLine(lines, "Worker " .. i, workerName, C.info)
            end
        end

        addDetailLine(lines, "Built", yesno(item.built), item.built and C.good or C.warn)
        addDetailLine(lines, "Being worked on", yesno(item.isWorkingOn), item.isWorkingOn and C.warn or C.good)
        addDetailLine(lines, "Guarded", yesno(item.guarded), item.guarded and C.good or C.warn)
        addDetailLine(lines, "Priority", item.priority)
        addDetailLine(lines, "Storage blocks", item.storageBlocks)
        addDetailLine(lines, "Storage slots", item.storageSlots)
        addDetailLine(lines, "Location", posText(item.location))
        if type(item.structure) == "table" then
            addDetailLine(lines, "Structure A", posText(item.structure.cornerA))
            addDetailLine(lines, "Structure B", posText(item.structure.cornerB))
            addDetailLine(lines, "Rotation", item.structure.rotation)
            addDetailLine(lines, "Mirrored", yesno(item.structure.mirror))
        end

    elseif page == "help" then
        local building = item.building or {}
        local workers = item.workers or buildingWorkers(building)
        addDetailLine(lines, "Building", cleanBuildingName(building.name or building.type or "Unknown"))
        addDetailLine(lines, "Level", tostring(building.level or "?") .. "/" .. tostring(building.maxLevel or "?"))
        addDetailLine(lines, "Filled positions", item.filled or #workers, C.info)
        addDetailLine(lines, "Staffing capacity", item.capacity, C.text)
        addDetailLine(lines, "Open positions", item.openings, C.warn)
        if staffingBuildingKey(building) == "guardtower" then
            addDetailLine(lines, "Guard Tower rule", "1 fillable guard position", C.accent)
        end
        if #workers == 0 then
            addDetailLine(lines, "Current workers", "None", C.dim)
        else
            for i, citizen in ipairs(workers) do
                addDetailLine(lines, "Worker " .. i, tostring(citizen.name or "Unknown")
                    .. " (" .. citizenJob(citizen) .. ")", C.info)
            end
        end
        addDetailLine(lines, "Location", posText(building.location))

    elseif page == "requests" then
        addDetailLine(lines, "Request", item.name)
        addDetailLine(lines, "State", item.state)
        addDetailLine(lines, "Count", item.count)
        addDetailLine(lines, "Minimum", item.minCount)
        addDetailLine(lines, "Target", item.target)
        lines[#lines + 1] = { label = "Description", value = tostring(item.desc or ""), wrap = true, color = C.text }
        if type(item.items) == "table" then
            local items = normalizeList(item.items)
            for i, it in ipairs(items) do
                local name = it.displayName or it.name or "Item"
                addDetailLine(lines, "Item " .. i, tostring(it.count or "?") .. "x " .. tostring(name), C.accent)
            end
        end

    elseif page == "orders" then
        local builders = workOrderBuilders(item)
        addDetailLine(lines, "Building", cleanBuildingName(item.buildingName or item.type or "Build"))
        addDetailLine(lines, "Type", cleanBuildingName(item.type or item.buildingName or "Build"))
        local orderStatus, orderStatusColor, targetBuilding = workOrderStatus(item)
        addDetailLine(lines, "Queue position", workOrderQueueNumber(item) or "-", C.accent)
        addDetailLine(lines, "Raw AP work PRI", item.priority ~= nil and item.priority or "-", C.dim)
        addDetailLine(lines, "Target level", item.targetLevel)
        addDetailLine(lines, "Status", orderStatus, orderStatusColor)
        if targetBuilding then
            addDetailLine(lines, "Target worked on", yesno(targetBuilding.isWorkingOn), targetBuilding.isWorkingOn and C.good or C.dim)
        end
        addDetailLine(lines, "Order type", cleanBuildingName(item.workOrderType or "Construction"))

        addDetailLine(lines, "Assigned builder(s)", #builders, #builders > 0 and C.info or C.dim)
        if #builders == 0 then
            addDetailLine(lines, "Builder", item.isClaimed and "Assigned (name unresolved)" or "Unassigned", C.dim)
        else
            for i, citizen in ipairs(builders) do
                local label = (#builders == 1) and "Builder" or ("Builder " .. i)
                local value = tostring(citizen.name or "Unknown")
                local job = citizenJob(citizen)
                if job ~= "No job" and job ~= "Child" then
                    value = value .. " (" .. job .. ")"
                end
                addDetailLine(lines, label, value, C.info)
            end
        end

        addDetailLine(lines, "Builder/Hut pos", posText(item.builder))
        addDetailLine(lines, "Changed", yesno(item.changed))
        addDetailLine(lines, "Order ID", item.id)
    end

    return lines
end

local function flattenDetailLines(lines, width)
    local out = {}
    for _, line in ipairs(lines) do
        local prefix = tostring(line.label or "") .. ": "
        if line.wrap then
            local wrapped = wrapText(line.value or "", math.max(1, width - 2))
            out[#out + 1] = { text = line.label .. ":", color = C.dim }
            for _, s in ipairs(wrapped) do
                out[#out + 1] = { text = "  " .. s, color = line.color or C.text }
            end
        else
            out[#out + 1] = { text = prefix .. tostring(line.value or ""), color = line.color or C.text }
        end
    end
    return out
end

local function drawDetail()
    local w, h = size()
    local list = listForPage(detail.page)
    local item = list[detail.index]
    if not item then
        detail = nil
        return
    end

    local names = { citizens = "CITIZEN", buildings = "BUILDING", requests = "REQUEST", orders = "CONSTRUCTION ORDER" }
    center(4, names[detail.page] .. " DETAILS", C.title, C.bg)

    local lines = flattenDetailLines(detailLines(detail.page, item), w - 4)
    local top = 5
    local bottom = h - 2
    local rows = math.max(1, bottom - top + 1)
    local maxScroll = math.max(1, #lines - rows + 1)
    detailScroll = math.max(1, math.min(detailScroll, maxScroll))

    local y = top
    for i = detailScroll, math.min(#lines, detailScroll + rows - 1) do
        writeAt(2, y, clip(lines[i].text, w - 3), lines[i].color, C.bg)
        y = y + 1
    end

    fill(1, h - 1, w, h - 1, C.panel)
    local backEnd = math.min(10, w)
    addButton("back", 1, h - 1, backEnd, h - 1, "< BACK", C.panel, C.text, function()
        detail = nil
        detailScroll = 1
    end)

    if #lines > rows then
        local upX1 = math.max(backEnd + 2, w - 19)
        local upX2 = math.min(w - 10, upX1 + 8)
        local downX1 = math.max(upX2 + 1, w - 9)
        addButton("up", upX1, h - 1, upX2, h - 1, "UP", C.panel, C.text, function()
            detailScroll = math.max(1, detailScroll - rows)
        end)
        addButton("down", downX1, h - 1, w, h - 1, "DOWN", C.panel, C.text, function()
            detailScroll = math.min(maxScroll, detailScroll + rows)
        end)
    else
        center(h - 1, "Touch BACK to return", C.dim, C.panel, backEnd + 1, w)
    end
end

-- =========================
-- Main draw
-- =========================

local function drawTooSmall()
    local w, h = size()
    clear()
    center(math.max(1, math.floor(h / 2) - 1), "MONITOR TOO SMALL", C.danger, C.bg)
    center(math.max(1, math.floor(h / 2)), "Use a larger Advanced Monitor", C.text, C.bg)
    center(math.min(h, math.floor(h / 2) + 1), "or lower TEXT_SCALE", C.dim, C.bg)
end

local function draw()
    local w, h = size()
    resetButtons()
    clear()

    if w < 38 or h < 14 then
        drawTooSmall()
        return
    end

    drawHeader()

    if detail then
        drawDetail()
    elseif currentPage == "home" then
        drawHome()
    else
        drawListPage(currentPage)
    end

    drawNav()
end

-- =========================
-- Startup validation
-- =========================

local inColony = api("isInColony", false)
if not inColony then
    clear()
    local w, h = size()
    center(math.max(1, math.floor(h / 2) - 1), "COLONY INTEGRATOR ERROR", C.danger, C.bg)
    center(math.floor(h / 2), "Integrator is not inside a MineColonies colony.", C.text, C.bg)
    error("Colony Integrator is not inside a colony.")
end

refreshData()
updateSickTrigger()

-- Show the update check explicitly on the computer terminal during startup.
renderTerminalStartup(updateStatusText(true), "STARTING")
checkForUpdate()
renderTerminalStartup(updateStatusText(false), "RUNNING")

draw()

local refreshTimer = os.startTimer(REFRESH_SECONDS)
local blinkTimer = os.startTimer(RAID_BLINK_SECONDS)
local updateTimer = os.startTimer(UPDATE_CHECK_SECONDS)

-- =========================
-- Event loop
-- =========================

while true do
    local event, p1, p2, p3 = os.pullEvent()

    if event == "monitor_touch" then
        local touchedMonitor, x, y = p1, p2, p3
        if touchedMonitor == monitorName then
            local b = hitButton(x, y)
            if b and b.action then
                b.action()
                draw()
            end
        end

    elseif event == "timer" then
        if p1 == refreshTimer then
            refreshData()
            updateSickTrigger()
            lastRefreshLabel = "just now"
            draw()
            refreshTimer = os.startTimer(REFRESH_SECONDS)
        elseif p1 == blinkTimer then
            raidBlink = not raidBlink
            if D.underAttack then draw() end
            blinkTimer = os.startTimer(RAID_BLINK_SECONDS)

        elseif p1 == updateTimer then
            local previousVersion = UPDATE.availableVersion
            local previousError = UPDATE.checkError
            local previousRemote = UPDATE.remoteSuiteVersion

            checkForUpdate()

            -- Redraw immediately if update state changed so the UPDATE button
            -- appears/disappears without requiring a restart.
            if previousVersion ~= UPDATE.availableVersion
                or previousError ~= UPDATE.checkError
                or previousRemote ~= UPDATE.remoteSuiteVersion then
                draw()
            end

            -- Keep the terminal startup/status summary current as well.
            renderTerminalStartup(updateStatusText(false), "RUNNING")

            updateTimer = os.startTimer(UPDATE_CHECK_SECONDS)
        end

    elseif event == "monitor_resize" then
        local changedMonitor = p1
        if changedMonitor == monitorName then
            monitor.setTextScale(TEXT_SCALE)
            draw()
        end

    elseif event == "peripheral_detach" then
        if p1 == monitorName then
            error("Command Center monitor was detached.")
        end

        -- If a Redstone Integrator disappears, immediately move the alarm
        -- output to the computer TOP fallback.
        updateSickTrigger()
        draw()

    elseif event == "peripheral" then
        -- If a Redstone Integrator appears, immediately prefer it and clear
        -- the computer TOP fallback.
        updateSickTrigger()
        draw()
    end
end
]====] },
    { path = "/colony_supply.lua", app = "supply", source = [====[--[[
  colony_supply.lua
  Version 2.36
  Minecraft 1.20.1
  CC:Tweaked + Advanced Peripherals + MineColonies + Refined Storage

  Architecture
  ------------
  RS Network A (PLAYER): normal player storage + optional autocrafting
       RS Bridge A
           |
      Transfer Chest
           |
       RS Bridge B
  RS Network B (COLONY): NO disks; External Storage attached to the
                         MineColonies Warehouse block

  The computer reads MineColonies requests, pulls requested items from
  Network A, stages them through the transfer chest, and imports them into
  Network B. Because Network B has no native disks, imported items are
  intended to land in the Warehouse through its External Storage link.

  IMPORTANT:
  - For Minecraft 1.20.1 Advanced Peripherals, peripheral names are
      rsBridge
      colonyIntegrator
  - exportItem()/importItem() directions are relative/cardinal from the
    RS BRIDGE, not from the computer.
  - For maximum crash recovery safety, attach the transfer barrel to the
    CC wired-modem network and set CONFIG.transferChestName.
  - The modem-connected barrel is used for inspection/recovery only unless
    CONFIG.usePeripheralTransfer is explicitly set true.

  v2.20 RS autocrafting safety:
  - Logs exact item/count before every craftItem() call.
  - Quarantines an item/variant for 5 minutes after a Java/RS craft exception.
  - Persists quarantine across restarts and shows the real craft error.

  v2.21 self-update support:
  - Checks the configured GitHub suite package at startup and every 30 minutes.
  - Shows an UPDATE button only when a newer version is available.
  - Re-downloads and validates the update before installation.
  - Syntax-checks, backs up the running program, installs a versioned target,
    leaves a startup-compatible redirect, and reboots.

  v2.22 terminal status:
  - Permanently shows overall system health on the computer terminal.
  - Permanently shows update-check state, remote version, and check time.

  v2.23 Refined Storage desync safety:
  - Never autocrafts when Player RS reports stock but exportItem() moves 0.
  - Marks that exact item/variant as RS DESYNC instead of ghost stock.
  - Probes one item periodically and clears the desync automatically when
    Player RS extraction works again.
  - Verifies extraction before crafting shortages whenever visible stock exists.
  - Distinguishes source extraction failure from colony-side import stalls.


  v2.25 RS hardening:
  - A confirmed Player-RS extraction failure now latches a GLOBAL RS safety pause.
  - All Colony Supply autocrafting pauses while the latch is active.
  - Health recovery uses a one-item name-only extraction/return probe that is
    persisted as a recoverable transaction.
  - Ordinary exports/crafts remain registry-name-only; exact NBT is used only
    when the MineColonies request genuinely requires that exact variant.
  - Any export=0 after a positive stock reading is treated as desync, even if
    the next inventory query fluctuates to zero.
  - Craft Java-error quarantine uses exponential backoff and also trips the
    global RS safety pause.
  - Empty-barrel crash recovery now respects transfer stage before crediting or
    clearing ambiguous transactions.
  - Overall health now includes transfer/desync state.
  - Self-update installs a correctly versioned file and leaves a redirect at
    the previous running filename for startup compatibility.

  v2.26 Control Suite refactor:
  - Uses shared UI, utility, version, updater, installer, and startup components.
  - Application updates now update the complete installed Control Suite.
  - Repair rewrites all managed files while preserving Supply state/config data.

  v2.27 shared-helper fix:
  - Restores the shared healthWord helper used by terminal and diagnostic status output.

  v2.28 scope hardening:
  - Moves getTransferChest() before refreshPeripherals() so Lua binds the local
    function correctly instead of resolving a nil global in peripheral-transfer mode.

  v2.29 RS status clarity:
  - Only the exact failed request shows RS DESYNC. Other requests blocked by the
    global extraction-safety latch show RS PAUSED.

  v2.30 RS recovery countdown:
  - RS DESYNC/RS PAUSED status cells show a live seconds countdown to the next
    one-item Player-RS recovery probe. The monitor redraws the countdown every second.
  v2.31 craft/desync separation:
  - craftItem() Java exceptions are quarantined per item but no longer trigger
    the global Player-RS extraction safety latch.
  - RS DESYNC / RS PAUSED are reserved for verified source extraction failures.
  - crafttest calls the RS Bridge directly and reports the raw craftItem() result
    without modifying normal RS safety/desync state.
  - On first run, legacy safety latches created specifically by a craftItem Java
    error are cleared; genuine extraction-desync latches are preserved.

  v2.32 Advanced Peripherals 0.7 RS Bridge workarounds:
  - Operational stock counts no longer use getItem(). AP 0.7.x on Minecraft
    1.20.1 can report phantom amounts for craftable items with zero stored,
    causing Supply to export phantom stock and falsely trip RS DESYNC.
  - Stock now comes from listItems(), which reports the actually stored stacks.
  - Never calls getItem() with NBT; AP 0.7.x can lock that RS stack and make
    later exportItem() return 0. Exact-NBT lookup scans listItems() instead.
  - Craftability no longer trusts getItem().isCraftable; dedicated
    isItemCraftable/getPattern/listCraftableItems checks are used instead.

  v2.33 per-item RS desync isolation:
  - A single item export failure no longer keeps every request globally paused
    after an independent Player-RS extraction probe proves the bridge healthy.
  - The failed item keeps its own 60-second RS DESYNC retry timer while other
    requests continue processing normally.
  - A new item failure requests a generic health probe on the next scan instead
    of delaying that classification for a full probe interval.
  - Generic probe recovery no longer deletes per-item desync evidence.
  - Generic health probes exclude all currently desynced item names, so the
    known-bad item cannot be mistaken for evidence that the whole RS bridge is bad.
  - Craftable desynced items remain quarantined while RS still reports stored
    stock; once stored stock reaches zero, the stale desync clears and crafting
    is allowed to start normally.
  v2.34 probe-return recovery:
  - A persisted RS health probe with an item already exported into the barrel
    immediately proves Player-RS source extraction healthy and clears the global latch.
  - Barrel -> Player probe recovery falls back to importItemFromPeripheral() when
    directional importItem() returns 0 and the modem-visible barrel is known.
  - Generic health-probe selection prefers clean items but can fall back to another
    ordinary stocked item (never the latch-causing item) instead of sitting at NOW.

  v2.35 probe cleanup + atomic dashboard refresh:
  - Once a health probe successfully exports from Player RS, the global source
    latch stays cleared even if returning the test item to Player RS is blocked.
  - A failed probe return becomes separate probeCleanup state instead of a normal
    pending transfer. Supply keeps evaluating requests; crafting can continue while
    stock transfers wait for the occupied barrel to be cleared.
  - Probe cleanup retries automatically and recognizes manual removal of the probe
    item from the barrel as successful cleanup.
  - Request rows are now built in an off-screen snapshot and swapped onto the
    monitor only after the complete scan finishes, eliminating partial-list refreshes.

  v2.36 pristine equipment safety:
  - Tools, weapons, shields, bows, fishing rods, and armor are supplied from stored
    Player RS stock only when the exact stored variant is provably pristine: zero
    damage and no enchantments. Unknown/opaque equipment NBT is rejected.
  - Clean stored equipment is exported by its Advanced Peripherals fingerprint so
    Refined Storage cannot substitute a damaged or enchanted copy with the same name.
  - If no provably clean stored copy is available, normal RS autocrafting is preferred.

--]]

local PROGRAM_VERSION = "2.36"
local SUITE_VERSION = "1.1.0"

local Util = require("colony.lib.util")
local SharedUI = require("colony.lib.ui")
local SuiteUpdater = require("colony.lib.updater")

local CONFIG = {
    --------------------------------------------------------------------
    -- Control Suite updates
    --------------------------------------------------------------------
    updateCheckSeconds = 1800,

    --------------------------------------------------------------------
    -- Peripheral names
    -- Leave nil to auto-detect where possible.
    -- If auto-detection is ambiguous, run: colony_supply.lua diag
    --------------------------------------------------------------------
    playerBridgeName = nil,      -- Example: "rsBridge_0"
    colonyBridgeName = nil,      -- Example: "rsBridge_1"
    colonyIntegratorName = nil,  -- Example: "colonyIntegrator_0"
    monitorName = nil,           -- Example: "monitor_0"

    --------------------------------------------------------------------
    -- Transfer barrel
    --
    -- IMPORTANT:
    -- transferChestName is for INSPECTION / RECOVERY ONLY by default.
    -- Connecting the barrel by modem must NOT change the proven physical
    -- bridge-transfer path.
    --
    -- Your physical layout:
    -- [Bridge Colony] [Barrel] [Bridge Player]
    --
    -- Actual movement normally uses directional exportItem()/importItem().
    --
    -- Set transferChestName to the modem peripheral name so the computer
    -- can inspect the barrel, verify it is empty, learn stack sizes, and
    -- safely recover interrupted transactions.
    --
    -- usePeripheralTransfer should remain FALSE for this installation.
    -- It exists only as an optional compatibility mode.
    --------------------------------------------------------------------
    -- Optional manual override. If nil, v2.4 auto-detects a modem-connected
    -- inventory and strongly prefers Sophisticated Storage/barrel peripherals.
    -- The resolved name is saved in the state file so upgrades do not require
    -- re-entering it every time.
    transferChestName = nil,
    usePeripheralTransfer = false,
    -- Physical layout when standing south and facing north:
    -- [Bridge Colony] [Barrel] [Bridge Player]
    playerToChestDirection = "west",
    chestToColonyDirection = "east",
    colonyToChestDirection = "east",
    chestToPlayerDirection = "west",

    --------------------------------------------------------------------
    -- Processing
    --------------------------------------------------------------------
    scanInterval = 5,
    maxTransferChunk = 64,       -- One transaction at a time; 64 is safest

    -- Allow the shared barrel / Forge inventory capability to update before
    -- the opposite RS Bridge tries to import. The four-way diagnostic test
    -- already used a 0.25 second delay and passed reliably.
    transferSettleDelay = 0.25,
    transferImportRetries = 3,
    transferRetryDelay = 0.25,

    requestRetentionSeconds = 3600,
    enableAutoCrafting = true,
    craftCooldownSeconds = 30,

    -- If Advanced Peripherals/Refined Storage throws a Java exception while
    -- starting a craft, quarantine that exact item/variant instead of
    -- repeatedly calling craftItem() every scan. This is specifically meant
    -- to protect against RS CraftingCalculator failures such as / by zero.
    craftErrorCooldownSeconds = 300,
    craftErrorMaxCooldownSeconds = 3600,

    -- If Player RS reports stock but exportItem() moves 0, treat it as a
    -- storage/extraction desync. A confirmed failure latches a GLOBAL safety
    -- pause for Player-RS source extraction and all Colony Supply autocrafting.
    -- Recovery is proven with a one-item name-only extraction/return probe.
    rsDesyncProbeSeconds = 60,

    -- MineColonies getRequests() is already the authoritative list of
    -- outstanding requests. Warehouse stock is therefore DISPLAYED but
    -- is NOT subtracted from a request by default. Subtracting it can
    -- race with couriers which remove items while the request is still
    -- visible. Leave false unless you specifically want that behavior.
    subtractWarehouseStock = false,

    -- MineColonies item requests containing meaningful NBT can be unsafe
    -- to match by registry name alone. Most building materials are fine.
    allowNBTNameOnly = false,

    -- Some normal MineColonies utility/tool requests include implementation
    -- or default durability NBT even though the colony is simply asking for
    -- the ordinary registry item. These items may be matched by registry name
    -- ONLY when the NBT looks benign/default. Meaningful customization such as
    -- enchantments, custom names/lore, or non-zero damage remains rejected.
    safeDefaultNBTNameOnlyItems = {
        ["minecraft:fishing_rod"] = true,
    },

    -- These mods encode the requested block/material variant in NBT.
    -- Preserve and match the exact request NBT for these namespaces.
    exactRequestNBTNamespaces = {
        ["domum_ornamentum"] = true,
    },

    --------------------------------------------------------------------
    -- MineColonies equipment/tool candidate selection
    --------------------------------------------------------------------
    preferExactToolClass = true,

    -- MineColonies tool levels:
    -- 0 Wood/Gold, 1 Stone, 2 Iron, 3 Diamond, 4 Netherite.
    -- Add modded real-tool overrides here when their tier is known.
    toolTierOverrides = {
        -- ["mekanismtools:refined_obsidian_axe"] = 5,
    },

    --------------------------------------------------------------------
    -- 5x3 Advanced Monitor
    --------------------------------------------------------------------
    monitorTextScale = 0.5,
    monitorAutoPage = true,
    monitorPageSeconds = 10,
    mirrorTerminal = true,

    --------------------------------------------------------------------
    -- Warehouse target settings (monitor Settings page)
    -- Target is player-adjustable. Overflow is always calculated as:
    --     target + (overflowStacks * item stack size)
    -- The RS Bridge API does not expose max stack size, so unknown items
    -- use defaultStackSize until a real stack size can be learned.
    --------------------------------------------------------------------
    -- General fallback for specialized/unknown items.
    defaultWarehouseTarget = 64,

    -- Bulk building materials default to 1,024. This category default is
    -- applied by item registry-name patterns below unless a per-item default
    -- or player monitor override exists.
    defaultBuildingTarget = 1024,

    warehouseDefaultTargets = {
        -- Explicit defaults take precedence over building-material patterns.
        -- Add exceptions here if a particular item should use another value.
        ["minecraft:cobblestone"] = 1024,
        ["minecraft:stone"] = 1024,
        ["minecraft:stone_bricks"] = 1024,
        ["minecraft:bricks"] = 1024,
        ["minecraft:dirt"] = 1024,
        ["minecraft:gravel"] = 1024,
        ["minecraft:sand"] = 1024,
        ["minecraft:red_sand"] = 1024,
        ["minecraft:glass"] = 1024,
    },

    -- Lua patterns are matched against the registry path (the part after
    -- namespace:). They make modded/common variants inherit the 1,024
    -- building-material target without having to enumerate every block.
    buildingItemPatterns = {
        "^cobblestone$", "_cobblestone$",
        "^stone$", "_stone$", "^sandstone$", "_sandstone$",
        "^bricks$", "_bricks$",
        "_planks$", "_log$", "_wood$", "_stem$", "_hyphae$",
        "^dirt$", "_dirt$", "^mud$", "_mud$",
        "^sand$", "_sand$", "^gravel$", "_gravel$",
        "^glass$", "_glass$", "_glass_pane$",
        "^terracotta$", "_terracotta$", "_concrete$",
        "^deepslate$", "_deepslate$", "^tuff$", "_tuff$",
        "^blackstone$", "_blackstone$", "^netherrack$", "^end_stone$",
    },
    defaultStackSize = 64,
    overflowStacks = 2,
    overflowReturnDefault = false,
    maxOverflowChunk = 64,

    --------------------------------------------------------------------
    -- Persistence / diagnostics
    --------------------------------------------------------------------
    stateFile = "/colony_supply_state.txt",
    logFile = "/colony_supply.log",
    maxLogBytes = 65536,
    maxHistoryEntries = 200,
    debugRequestsFile = "/colony_requests_debug.txt",
    debug = false,
}

--------------------------------------------------------------------------
-- Globals
--------------------------------------------------------------------------

local colony = nil
local playerRS = nil
local colonyRS = nil
local monitor = nil

local colonyName = "Unknown Colony"
local playerBridgeResolvedName = nil
local colonyBridgeResolvedName = nil
local monitorResolvedName = nil
local transferChestResolvedName = nil
local transferChestResolution = "none"

local state = {
    requests = {},
    pending = nil,
    probeCleanup = nil,
    craftJobs = {},
    craftFailures = {},
    rsDesync = {},
    rsSafety = { latched = false },
    history = {},
    settings = {
        targets = {},
        stackSizes = {},
        overflowEnabled = nil,
        autoCraftEnabled = nil,
        transferChestName = nil,
    },
}

local dashboardRows = {}
local dashboardBuildRows = nil
local statsBuild = nil
local settingsRows = {}
local currentPage = 1
local settingsPage = 1
local historyPage = 1
local monitorView = "main"
local selectedSettingItem = nil
local editTarget = nil
local editTargetInput = nil
local editInputMessage = nil
local editInputFresh = false
local lastManualPageChange = 0
local lastScanEpoch = 0
local lastScanText = "--:--:--"
local startedClock = os.clock()

local health = {
    colony = false,
    playerRS = false,
    colonyRS = false,
    warehouse = false,
    transfer = true,
    message = "Starting...",
}

local stats = {
    active = 0,
    supplied = 0,
    missing = 0,
    crafting = 0,
    ready = 0,
    errors = 0,
}

--------------------------------------------------------------------------
-- Basic utility functions
--------------------------------------------------------------------------

local function nowMs()
    return os.epoch("utc")
end

local function nowSeconds()
    return math.floor(nowMs() / 1000)
end

local function timeString()
    return os.date("%H:%M:%S")
end

local clamp = Util.clamp

local function roundDown(n)
    return math.floor(tonumber(n) or 0)
end

local function shallowCopy(t)
    local out = {}
    if type(t) == "table" then
        for k, v in pairs(t) do out[k] = v end
    end
    return out
end

local function trim(s)
    s = tostring(s or "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local truncateText = Util.truncateText
local healthWord = Util.healthWord

local padRight = Util.padRight

local padLeft = Util.padLeft

local centerText = Util.centerText

local function formatNumber(n)
    n = roundDown(n)
    local sign = ""
    if n < 0 then
        sign = "-"
        n = math.abs(n)
    end
    local s = tostring(n)
    local out = s
    while true do
        local replaced, count = out:gsub("^(%d+)(%d%d%d)", "%1,%2")
        out = replaced
        if count == 0 then break end
    end
    return sign .. out
end

local function nonEmptyTable(t)
    if type(t) ~= "table" then return false end
    return next(t) ~= nil
end

local function itemHasNBT(item)
    if type(item) ~= "table" then return false end
    local nbt = item.nbt
    if nbt == nil then return false end
    if type(nbt) == "table" then return next(nbt) ~= nil end
    if type(nbt) == "string" then return nbt ~= "" and nbt ~= "{}" end
    return true
end

local function serializedNBTText(nbt)
    if nbt == nil then return "" end

    if type(nbt) == "table" then
        local ok, serialized = pcall(textutils.serialize, nbt)
        if ok and serialized then
            return tostring(serialized)
        end
    end

    return tostring(nbt)
end

local function requestNBTIsSafeDefault(item)
    if type(item) ~= "table" then return false end
    if not itemHasNBT(item) then return true end

    local allowed = CONFIG.safeDefaultNBTNameOnlyItems or {}
    local explicitlyAllowed = allowed[item.name] == true

    ------------------------------------------------------------------
    -- MineColonies commonly attaches default durability NBT to normal
    -- equipment candidates. That NBT must not cause a real Axe/Pickaxe/etc.
    -- to disappear before tool ranking.
    --
    -- Only registry names which clearly identify the actual requested
    -- equipment class are eligible here. Generic tools such as Portable
    -- Drill/Paxel/MultiTool are NOT matched by these suffixes.
    ------------------------------------------------------------------
    local registryName = tostring(item.name or ""):lower()
    local path = registryName:match("^[^:]+:(.+)$") or registryName

    local looksLikeRealTool =
        path:match("_axe$") ~= nil
        or path:match("_pickaxe$") ~= nil
        or path:match("_shovel$") ~= nil
        or path:match("_hoe$") ~= nil
        or path:match("_sword$") ~= nil
        or path:match("_fishing_rod$") ~= nil
        or path == "fishing_rod"
        or path == "shears"
        or path:match("_shears$") ~= nil
        or path == "bow"
        or path:match("_bow$") ~= nil
        or path == "crossbow"
        or path:match("_crossbow$") ~= nil
        or path == "shield"
        or path:match("_shield$") ~= nil
        or path == "helmet"
        or path:match("_helmet$") ~= nil
        or path == "chestplate"
        or path:match("_chestplate$") ~= nil
        or path == "leggings"
        or path:match("_leggings$") ~= nil
        or path == "boots"
        or path:match("_boots$") ~= nil

    if not explicitlyAllowed and not looksLikeRealTool then
        return false
    end

    local raw = serializedNBTText(item.nbt)
    local lower = raw:lower()

    -- Never name-match obvious customized/special variants.
    local unsafeWords = {
        "enchant",
        "display",
        "customname",
        "custom_name",
        "lore",
        "stored_enchant",
        "potion",
        "attribute",
        "unbreakable",
        "skull",
        "trim",
    }

    for _, word in ipairs(unsafeWords) do
        if lower:find(word, 1, true) then
            return false
        end
    end

    -- Non-zero durability/repair metadata is meaningful and should not be
    -- collapsed to a name-only match. Support both Lua serialization
    -- ("Damage = 0") and SNBT-ish ("Damage:0") representations.
    local damage =
        lower:match("damage%s*=%s*(-?%d+)")
        or lower:match("damage%s*:%s*(-?%d+)")

    if damage and tonumber(damage) ~= 0 then
        return false
    end

    local repairCost =
        lower:match("repaircost%s*=%s*(-?%d+)")
        or lower:match("repaircost%s*:%s*(-?%d+)")

    if repairCost and tonumber(repairCost) ~= 0 then
        return false
    end

    -- The item is either explicitly whitelisted or is clearly a real tool
    -- registry item, and its NBT contains no known meaningful customization.
    -- Name-only matching is therefore safe for this default tool variant.
    return true
end

local NBTX = {}

function NBTX.exactRequestNBTAllowed(item)
    if type(item) ~= "table" or type(item.name) ~= "string" then
        return false
    end

    local namespace = item.name:match("^([^:]+):")
    return namespace ~= nil
        and CONFIG.exactRequestNBTNamespaces ~= nil
        and CONFIG.exactRequestNBTNamespaces[namespace] == true
        and itemHasNBT(item)
end

function NBTX.requestNBTFilterValue(item)
    if type(item) ~= "table" or item.nbt == nil then return nil end

    if type(item.nbt) == "string" then
        local s = item.nbt
        if s ~= "" and s ~= "{}" and s ~= "nil" then return s end
        return nil
    end

    if type(item.nbt) == "table" then
        local ok, s = pcall(textutils.serializeJSON, item.nbt)
        if ok and type(s) == "string" and s ~= "" and s ~= "{}" then
            return s
        end
    end

    return nil
end

local function requestCandidateRejectionReason(item)
    if type(item) ~= "table" then return "not an item table" end
    if type(item.name) ~= "string" or item.name == "" then
        return "missing registry name"
    end

    if not itemHasNBT(item) then return nil end
    if NBTX.exactRequestNBTAllowed(item) and NBTX.requestNBTFilterValue(item) then
        return nil
    end
    if CONFIG.allowNBTNameOnly then return nil end
    if requestNBTIsSafeDefault(item) then return nil end

    return "meaningful/unsupported NBT"
end

local function safeCall(obj, method, ...)
    if not obj then
        return false, nil, "Peripheral unavailable"
    end
    local fn = obj[method]
    if type(fn) ~= "function" then
        return false, nil, "Missing method: " .. tostring(method)
    end
    local ok, a, b, c, d = pcall(fn, ...)
    if not ok then
        return false, nil, tostring(a)
    end
    return true, a, b, c, d
end

local function hasPeripheralType(name, wanted)
    if not name or not peripheral.isPresent(name) then return false end
    local ok, result = pcall(peripheral.hasType, name, wanted)
    if ok then return result == true end

    -- Fallback for environments where hasType() is not available.
    local types = { peripheral.getType(name) }
    for _, t in ipairs(types) do
        if t == wanted then return true end
    end
    return false
end

--------------------------------------------------------------------------
-- Logging and state persistence
--------------------------------------------------------------------------

local function rotateLogIfNeeded()
    if not fs.exists(CONFIG.logFile) then return end
    local ok, size = pcall(fs.getSize, CONFIG.logFile)
    if not ok or not size or size < CONFIG.maxLogBytes then return end

    local old = CONFIG.logFile .. ".old"
    if fs.exists(old) then pcall(fs.delete, old) end
    pcall(fs.move, CONFIG.logFile, old)
end

local function writeLog(message)
    rotateLogIfNeeded()
    local h = fs.open(CONFIG.logFile, "a")
    if not h then return end
    h.writeLine("[" .. timeString() .. "] " .. tostring(message))
    h.close()
end

local function historyDisplayName(itemName)
    local raw = tostring(itemName or "?")
    local path = raw:match("^[^:]+:(.+)$") or raw
    path = path:gsub("_", " ")
    path = path:gsub("(%a)([%w']*)", function(a, b)
        return a:upper() .. b
    end)
    return path
end

local function recordTransferHistory(direction, itemName, amount, requestId, note)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then return end

    state.history = state.history or {}

    table.insert(state.history, 1, {
        epoch = nowSeconds(),
        time = timeString(),
        direction = tostring(direction or "?"),
        item = tostring(itemName or "?"),
        displayName = historyDisplayName(itemName),
        amount = amount,
        requestId = requestId and tostring(requestId) or nil,
        note = note and tostring(note) or nil,
    })

    local maxEntries = math.max(10, tonumber(CONFIG.maxHistoryEntries) or 200)
    while #state.history > maxEntries do
        table.remove(state.history)
    end
end

local function saveState()
    local temp = CONFIG.stateFile .. ".tmp"
    local backup = CONFIG.stateFile .. ".bak"

    local h = fs.open(temp, "w")
    if not h then
        writeLog("ERROR unable to write state temp file")
        return false
    end
    h.write(textutils.serialize(state))
    h.close()

    if fs.exists(backup) then pcall(fs.delete, backup) end
    if fs.exists(CONFIG.stateFile) then
        local ok = pcall(fs.move, CONFIG.stateFile, backup)
        if not ok then pcall(fs.delete, CONFIG.stateFile) end
    end

    local okMove = pcall(fs.move, temp, CONFIG.stateFile)
    if not okMove then
        writeLog("ERROR unable to replace state file")
        return false
    end

    if fs.exists(backup) then pcall(fs.delete, backup) end
    return true
end

local function readSerializedFile(path)
    if not fs.exists(path) then return nil end
    local h = fs.open(path, "r")
    if not h then return nil end
    local raw = h.readAll()
    h.close()
    local ok, data = pcall(textutils.unserialize, raw)
    if not ok or type(data) ~= "table" then return nil end
    return data
end

local function loadState()
    local loaded = readSerializedFile(CONFIG.stateFile)
    if not loaded then
        loaded = readSerializedFile(CONFIG.stateFile .. ".bak")
    end

    if type(loaded) == "table" then
        state = loaded
        state.requests = state.requests or {}
        -- v2.35 keeps a stranded health-probe return separate from ordinary
        -- supply/overflow transactions so it cannot masquerade as RS DESYNC.
        if state.probeCleanup ~= nil and type(state.probeCleanup) ~= "table" then
            state.probeCleanup = nil
        end
        state.craftJobs = state.craftJobs or {}
        state.craftFailures = state.craftFailures or {}
        state.rsDesync = state.rsDesync or {}
        state.rsSafety = state.rsSafety or { latched = false }
        if state.rsSafety.latched == nil then state.rsSafety.latched = false end
        state.history = state.history or {}
        state.settings = state.settings or {}
        state.settings.targets = state.settings.targets or {}
        state.settings.stackSizes = state.settings.stackSizes or {}
        if state.settings.overflowEnabled == nil then
            state.settings.overflowEnabled = CONFIG.overflowReturnDefault == true
        end
        if state.settings.autoCraftEnabled == nil then
            state.settings.autoCraftEnabled = CONFIG.enableAutoCrafting == true
        end
        writeLog("State loaded")
    else
        state = {
            requests = {},
            pending = nil,
            probeCleanup = nil,
            craftJobs = {},
            craftFailures = {},
            rsDesync = {},
            rsSafety = { latched = false },
            history = {},
            settings = {
                targets = {},
                stackSizes = {},
                overflowEnabled = CONFIG.overflowReturnDefault == true,
                autoCraftEnabled = CONFIG.enableAutoCrafting == true,
                transferChestName = nil,
            },
        }
        writeLog("Starting with new state")
    end
end

local function autoCraftEnabled()
    return state
        and state.settings
        and state.settings.autoCraftEnabled == true
end

--------------------------------------------------------------------------
-- Peripheral discovery
--------------------------------------------------------------------------

local function bridgeInfo(bridge)
    local disk = 0
    local external = 0

    local okDisk, diskValue = safeCall(bridge, "getMaxItemDiskStorage")
    if okDisk then disk = tonumber(diskValue) or 0 end

    local okExt, extValue = safeCall(bridge, "getMaxItemExternalStorage")
    if okExt then external = tonumber(extValue) or 0 end

    return disk, external
end

local function allRSBridges()
    local list = { peripheral.find("rsBridge") }
    local out = {}
    for _, b in ipairs(list) do
        local name = nil
        local ok, result = pcall(peripheral.getName, b)
        if ok then name = result end
        local disk, external = bridgeInfo(b)
        out[#out + 1] = {
            name = name or "unknown",
            bridge = b,
            disk = disk,
            external = external,
        }
    end
    return out
end

local function resolveBridgeByName(name)
    if not name then return nil, nil end
    if not peripheral.isPresent(name) then return nil, nil end
    if not hasPeripheralType(name, "rsBridge") then return nil, nil end
    return peripheral.wrap(name), name
end

local function resolveRSBridges()
    local configuredPlayer, configuredPlayerName = resolveBridgeByName(CONFIG.playerBridgeName)
    local configuredColony, configuredColonyName = resolveBridgeByName(CONFIG.colonyBridgeName)

    if configuredPlayer and configuredColony then
        playerRS = configuredPlayer
        colonyRS = configuredColony
        playerBridgeResolvedName = configuredPlayerName
        colonyBridgeResolvedName = configuredColonyName
        return true
    end

    local bridges = allRSBridges()
    if #bridges < 2 then
        playerRS = configuredPlayer
        colonyRS = configuredColony
        return false
    end

    local playerCandidate = configuredPlayer and {
        bridge = configuredPlayer,
        name = configuredPlayerName,
    } or nil
    local colonyCandidate = configuredColony and {
        bridge = configuredColony,
        name = configuredColonyName,
    } or nil

    if not playerCandidate then
        -- Prefer a network with actual disk storage.
        for _, info in ipairs(bridges) do
            if info.disk > 0 then
                if not playerCandidate or info.disk > (playerCandidate.disk or -1) then
                    playerCandidate = info
                end
            end
        end
    end

    if not colonyCandidate then
        -- Prefer the no-disk network with external storage.
        for _, info in ipairs(bridges) do
            if info.disk == 0 and info.external > 0 then
                colonyCandidate = info
                break
            end
        end
    end

    -- Fallback: if we know A, and exactly one other bridge exists, use it as B.
    if playerCandidate and not colonyCandidate then
        for _, info in ipairs(bridges) do
            if info.name ~= playerCandidate.name then
                if not colonyCandidate then
                    colonyCandidate = info
                else
                    colonyCandidate = nil -- ambiguous
                    break
                end
            end
        end
    end

    -- Fallback in the other direction.
    if colonyCandidate and not playerCandidate then
        for _, info in ipairs(bridges) do
            if info.name ~= colonyCandidate.name then
                if not playerCandidate then
                    playerCandidate = info
                else
                    playerCandidate = nil -- ambiguous
                    break
                end
            end
        end
    end

    if playerCandidate and colonyCandidate and playerCandidate.name ~= colonyCandidate.name then
        playerRS = playerCandidate.bridge
        colonyRS = colonyCandidate.bridge
        playerBridgeResolvedName = playerCandidate.name
        colonyBridgeResolvedName = colonyCandidate.name
        return true
    end

    return false
end

local function resolveColonyIntegrator()
    if CONFIG.colonyIntegratorName and peripheral.isPresent(CONFIG.colonyIntegratorName)
       and hasPeripheralType(CONFIG.colonyIntegratorName, "colonyIntegrator") then
        colony = peripheral.wrap(CONFIG.colonyIntegratorName)
    else
        colony = peripheral.find("colonyIntegrator")
    end

    if not colony then return false end

    local okInside, inside = safeCall(colony, "isInColony")
    if not okInside or not inside then
        return false
    end

    local okName, name = safeCall(colony, "getColonyName")
    if okName and name then colonyName = tostring(name) end
    return true
end

local function resolveMonitor()
    local newMonitor = nil

    if CONFIG.monitorName and peripheral.isPresent(CONFIG.monitorName)
       and hasPeripheralType(CONFIG.monitorName, "monitor") then
        newMonitor = peripheral.wrap(CONFIG.monitorName)
    else
        newMonitor = peripheral.find("monitor")
    end

    if not newMonitor then
        monitor = nil
        monitorResolvedName = nil
        return false
    end

    monitor = newMonitor
    local okName, name = pcall(peripheral.getName, monitor)
    if okName then monitorResolvedName = name end

    pcall(monitor.setTextScale, CONFIG.monitorTextScale)
    pcall(monitor.setBackgroundColor, colors.black)
    pcall(monitor.setTextColor, colors.white)
    return true
end


-- Resolve the modem-connected transfer barrel used for inspection/recovery.
-- Priority:
--   1. Explicit CONFIG.transferChestName
--   2. Previously auto-detected/saved state.settings.transferChestName
--   3. Auto-detect exactly one barrel-like inventory peripheral
--   4. Auto-detect exactly one generic inventory peripheral
local function resolveTransferChest()
    local function validInventory(name)
        return name
            and peripheral.isPresent(name)
            and hasPeripheralType(name, "inventory")
    end

    local function looksLikeBarrel(name)
        if not name then return false end
        local nameText = tostring(name):lower()
        local typeParts = { peripheral.getType(name) }
        local typeText = table.concat(typeParts, ","):lower()

        return nameText:find("barrel", 1, true) ~= nil
            or nameText:find("sophisticated", 1, true) ~= nil
            or typeText:find("barrel", 1, true) ~= nil
            or typeText:find("sophisticated", 1, true) ~= nil
    end

    if validInventory(CONFIG.transferChestName) then
        transferChestResolvedName = CONFIG.transferChestName
        transferChestResolution = "config"
        return true
    end

    state.settings = state.settings or {}
    local saved = state.settings.transferChestName

    if state.settings.transferChestManual == true and validInventory(saved) then
        transferChestResolvedName = saved
        transferChestResolution = "saved-manual"
        return true
    end

    -- Do not trust an old auto-saved generic inventory unless it still
    -- clearly identifies as a barrel/Sophisticated Storage inventory.
    if validInventory(saved) and looksLikeBarrel(saved) then
        transferChestResolvedName = saved
        transferChestResolution = "saved-barrel"
        return true
    end

    local barrelLike = {}
    for _, name in ipairs(peripheral.getNames()) do
        if validInventory(name) and looksLikeBarrel(name) then
            barrelLike[#barrelLike + 1] = name
        end
    end

    if #barrelLike == 1 then
        transferChestResolvedName = barrelLike[1]
        transferChestResolution = "auto-barrel"

        state.settings.transferChestName = transferChestResolvedName
        state.settings.transferChestManual = false
        saveState()

        writeLog("Transfer barrel auto-detected: " ..
            tostring(transferChestResolvedName))
        return true
    end

    transferChestResolvedName = nil
    transferChestResolution =
        (#barrelLike == 0)
        and "not-configured"
        or ("ambiguous-barrels-" .. tostring(#barrelLike))

    return false
end

local function getTransferChest()
    local name = transferChestResolvedName

    -- This function may be called from diagnostics before a normal scan has
    -- refreshed peripherals, so resolve lazily if necessary.
    if not name or not peripheral.isPresent(name) then
        resolveTransferChest()
        name = transferChestResolvedName
    end

    if not name then return nil end
    if not peripheral.isPresent(name) then return nil end
    if not hasPeripheralType(name, "inventory") then return nil end
    return peripheral.wrap(name)
end

local function refreshPeripherals()
    local colonyOk = resolveColonyIntegrator()
    local bridgesOk = resolveRSBridges()
    resolveMonitor()
    resolveTransferChest()

    health.colony = colonyOk
    health.playerRS = false
    health.colonyRS = false
    health.warehouse = false
    health.transfer = false

    if bridgesOk and playerRS then
        local ok = safeCall(playerRS, "getEnergyStorage")
        health.playerRS = ok
    end

    if bridgesOk and colonyRS then
        local ok = safeCall(colonyRS, "getEnergyStorage")
        health.colonyRS = ok
        if ok then
            local _, external = bridgeInfo(colonyRS)
            health.warehouse = external > 0
        end
    end

    -- In the normal/recommended directional mode, transfer hardware is
    -- available whenever both RS Bridges are online. The modem-connected
    -- barrel is used for inspection/recovery and is not required to move
    -- items. Only peripheral-transfer compatibility mode requires the barrel
    -- peripheral itself to be present.
    if health.playerRS and health.colonyRS then
        if CONFIG.usePeripheralTransfer then
            health.transfer = getTransferChest() ~= nil
        else
            health.transfer = true
        end
    end

    return colonyOk and bridgesOk and health.playerRS and health.colonyRS
end

--------------------------------------------------------------------------
-- Refined Storage helpers
--------------------------------------------------------------------------

-- Advanced Peripherals 0.7.x / Minecraft 1.20.1 has two important
-- getItem() bugs for RS Bridge:
--   1. craftable-but-not-stored items can report phantom nonzero amounts;
--   2. getItem() with NBT can lock the matching RS stack so exportItem() returns 0.
-- Use listItems() as the source of truth for ACTUALLY STORED stock. Cache the
-- snapshot briefly because a request scan asks for the same bridge repeatedly.
function NBTX.getRSListItems(bridge, force)
    if not bridge then return nil end
    NBTX.rsListCache = NBTX.rsListCache or {}

    local now = nowMs()
    local cached = NBTX.rsListCache[bridge]
    if not force and type(cached) == "table"
        and type(cached.items) == "table"
        and now - (tonumber(cached.time) or 0) <= 500 then
        return cached.items
    end

    local ok, items = safeCall(bridge, "listItems")
    if not ok or type(items) ~= "table" then return nil end

    NBTX.rsListCache[bridge] = { time = now, items = items }
    return items
end

function NBTX.invalidateRSList(bridge)
    if NBTX.rsListCache and bridge then
        NBTX.rsListCache[bridge] = nil
    end
end

local function getRSItem(bridge, name)
    if not bridge or not name then return nil end
    local items = NBTX.getRSListItems(bridge, false)
    if type(items) ~= "table" then return nil end

    local matched = nil
    local total = 0
    for _, item in pairs(items) do
        if type(item) == "table" and item.name == name then
            if not matched then
                matched = {}
                for k, v in pairs(item) do matched[k] = v end
            end
            total = total + math.max(0, tonumber(item.amount) or 0)
        end
    end

    if matched then matched.amount = total end
    return matched
end

local function getRSAmount(bridge, name)
    local item = getRSItem(bridge, name)
    return item and (tonumber(item.amount) or 0) or 0
end

function NBTX.getRSItemByCandidate(bridge, candidate)
    if not bridge or type(candidate) ~= "table" or not candidate.name then
        return nil
    end

    if not candidate.exactRequestNBT or not candidate.nbtFilter then
        return getRSItem(bridge, candidate.name)
    end

    local items = NBTX.getRSListItems(bridge, false)
    if type(items) ~= "table" then return nil end

    local wantedNBT = tostring(candidate.nbtFilter)
    local matched = nil
    local total = 0

    for _, item in pairs(items) do
        if type(item) == "table"
            and item.name == candidate.name
            and item.nbt ~= nil
            and tostring(item.nbt) == wantedNBT then

            if not matched then
                matched = {}
                for k, v in pairs(item) do matched[k] = v end
            end
            total = total + math.max(0, tonumber(item.amount) or 0)
        end
    end

    if matched then matched.amount = total end
    return matched
end

function NBTX.getRSAmountByCandidate(bridge, candidate)
    local item = NBTX.getRSItemByCandidate(bridge, candidate)
    return item and (tonumber(item.amount) or 0) or 0
end

local function registryPath(itemName)
    local name = tostring(itemName or "")
    return name:match("^[^:]+:(.+)$") or name
end

local function isDefaultBuildingItem(itemName)
    local path = registryPath(itemName)
    for _, pattern in ipairs(CONFIG.buildingItemPatterns or {}) do
        if path:match(pattern) then return true end
    end
    return false
end

local function getWarehouseTarget(itemName)
    state.settings = state.settings or { targets = {}, stackSizes = {} }
    state.settings.targets = state.settings.targets or {}

    -- Player-set monitor override always wins.
    local override = tonumber(state.settings.targets[itemName])
    if override ~= nil then return math.max(0, math.floor(override)) end

    -- Then explicit per-item defaults.
    local configured = CONFIG.warehouseDefaultTargets and tonumber(CONFIG.warehouseDefaultTargets[itemName])
    if configured ~= nil then return math.max(0, math.floor(configured)) end

    -- Common building materials use the bulk-building default.
    if isDefaultBuildingItem(itemName) then
        return math.max(0, math.floor(tonumber(CONFIG.defaultBuildingTarget) or 1024))
    end

    -- Everything else uses the conservative general fallback.
    return math.max(0, math.floor(tonumber(CONFIG.defaultWarehouseTarget) or 64))
end

local function getKnownStackSize(itemName)
    state.settings = state.settings or { targets = {}, stackSizes = {} }
    state.settings.stackSizes = state.settings.stackSizes or {}
    local n = tonumber(state.settings.stackSizes[itemName])
    if n and n > 0 then return math.floor(n), true end
    return math.max(1, math.floor(tonumber(CONFIG.defaultStackSize) or 64)), false
end

local function getOverflowAt(itemName)
    local target = getWarehouseTarget(itemName)
    local stackSize = getKnownStackSize(itemName)
    return target + (stackSize * math.max(0, math.floor(tonumber(CONFIG.overflowStacks) or 2)))
end

local function rememberStackSize(itemName, stackSize)
    stackSize = tonumber(stackSize)
    if not itemName or not stackSize or stackSize <= 0 then return false end
    stackSize = math.floor(stackSize)
    state.settings = state.settings or { targets = {}, stackSizes = {} }
    state.settings.stackSizes = state.settings.stackSizes or {}
    if state.settings.stackSizes[itemName] ~= stackSize then
        state.settings.stackSizes[itemName] = stackSize
        return true
    end
    return false
end

function NBTX.craftFilter(name, count)
    -- Ordinary crafting must remain registry-name-only. Do not silently copy
    -- NBT returned by getItem(); that can turn a normal request into a stale or
    -- over-specific RS crafting calculation. Exact-NBT requests use
    -- NBTX.candidateCraftFilter() instead.
    return {
        name = name,
        count = count,
    }
end

-- Determine whether Player RS can craft an item.
-- Advanced Peripherals 0.7 had API differences across builds, so use several
-- compatible detection paths instead of depending on only isItemCraftable().
--
-- Returns:
--   craftable:boolean
--   source:string        -- which API confirmed it
function NBTX.getCraftability(name)
    if not playerRS then return false, "player bridge unavailable" end

    -- Do not trust getItem().isCraftable on AP 0.7.x: it can be wrong and its
    -- amount can represent a pattern output rather than actually stored stock.
    -- 0.7.3r+ supports isItemCraftable().
    local ok, value = safeCall(playerRS, "isItemCraftable", NBTX.craftFilter(name, nil))
    if ok and value == true then
        return true, "isItemCraftable"
    end

    -- Some 0.7 builds expose getPattern(). A returned pattern is definitive.
    local patternOK, pattern = safeCall(playerRS, "getPattern", { name = name })
    if patternOK and type(pattern) == "table" then
        return true, "getPattern"
    end

    -- listCraftableItems() exists on some older/newer 0.7 builds but was
    -- absent from part of the 0.7 series. safeCall makes this harmless.
    local listOK, craftables = safeCall(playerRS, "listCraftableItems")
    if listOK and type(craftables) == "table" then
        for _, craftItem in pairs(craftables) do
            if type(craftItem) == "table" and craftItem.name == name then
                return true, "listCraftableItems"
            end
        end
    end

    return false, "not reported craftable"
end

function NBTX.isCraftable(name)
    local craftable = NBTX.getCraftability(name)
    return craftable == true
end

function NBTX.isCrafting(name)
    if not playerRS then return false end
    local ok, value = safeCall(playerRS, "isItemCrafting", NBTX.craftFilter(name, nil))
    return ok and value == true
end

-- Refined Storage 1.12.4 can throw Java exceptions from CraftingCalculator
-- when Advanced Peripherals calls craftItem(). CC:Tweaked catches that Java
-- exception, but immediately retrying the same item can hammer the server.
-- Keep a per-item/variant quarantine in persistent state so a reboot does not
-- immediately resume the failing craft loop.
function NBTX.craftFailureRemaining(key)
    if not state then return 0, nil end
    state.craftFailures = state.craftFailures or {}

    local entry = state.craftFailures[key]
    if entry == nil then return 0, nil end

    local stamp
    local reason
    if type(entry) == "table" then
        stamp = tonumber(entry.time) or 0
        reason = tostring(entry.reason or "previous RS craft error")
    else
        -- Backward/defensive support if a numeric timestamp is ever stored.
        stamp = tonumber(entry) or 0
        reason = "previous RS craft error"
    end

    local base = math.max(30, tonumber(CONFIG.craftErrorCooldownSeconds) or 300)
    local cap = math.max(base, tonumber(CONFIG.craftErrorMaxCooldownSeconds) or 3600)
    local failures = type(entry) == "table" and math.max(1, tonumber(entry.failures) or 1) or 1
    local cooldown = type(entry) == "table" and tonumber(entry.cooldown) or nil
    if not cooldown then cooldown = math.min(cap, base * (2 ^ math.max(0, failures - 1))) end

    local elapsed = math.max(0, nowSeconds() - stamp)
    local left = math.ceil(cooldown - elapsed)
    if left <= 0 then return 0, nil end
    return left, reason
end

function NBTX.clearCraftFailure(key)
    if state and state.craftFailures and state.craftFailures[key] ~= nil then
        state.craftFailures[key] = nil
    end
end

function NBTX.quarantineCraft(key, itemName, amount, reason)
    state.craftFailures = state.craftFailures or {}

    local why = tostring(reason or "unknown craftItem Java error")
    local qty = math.max(1, math.floor(tonumber(amount) or 1))
    local previous = state.craftFailures[key]
    local failures = type(previous) == "table" and (tonumber(previous.failures) or 0) + 1 or 1
    local base = math.max(30, tonumber(CONFIG.craftErrorCooldownSeconds) or 300)
    local cap = math.max(base, tonumber(CONFIG.craftErrorMaxCooldownSeconds) or 3600)
    local seconds = math.min(cap, base * (2 ^ math.max(0, failures - 1)))

    state.craftFailures[key] = {
        time = nowSeconds(),
        item = tostring(itemName or key or "?"),
        amount = qty,
        reason = why,
        failures = failures,
        cooldown = seconds,
    }
    saveState()

    -- A craft calculation/bridge exception is isolated to this item/variant.
    -- It does NOT prove that Player-RS extraction is unhealthy, so do not
    -- activate the global RS DESYNC / RS PAUSED safety latch here.

    local msg = "CRAFT ERROR: " .. tostring(itemName or key or "?") ..
        " x" .. tostring(qty) ..
        " quarantined " .. tostring(seconds) .. "s" ..
        " (failure " .. tostring(failures) .. ")"

    writeLog(
        "CRAFT QUARANTINE item=" .. tostring(itemName or key or "?") ..
        " amount=" .. tostring(qty) ..
        " key=" .. tostring(key) ..
        " seconds=" .. tostring(seconds) ..
        " reason=" .. why
    )

    health.message = msg
    return msg
end

function NBTX.craftErrorDisplay(message, fallback)
    local text = tostring(message or "")
    if text:find("^CRAFT ERROR:") or text:find("^CRAFT ERROR COOLDOWN:") then
        return text
    end
    return tostring(fallback or "craft retry pending")
end

-- Global Player-RS EXTRACTION safety latch. Only a confirmed source
-- extraction failure pauses Colony Supply autocrafting. craftItem() errors
-- are handled separately by the per-item craft quarantine.
function NBTX.rsSafetyState()
    state.rsSafety = state.rsSafety or { latched = false }
    if state.rsSafety.latched == nil then state.rsSafety.latched = false end

    -- v2.31 migration: versions 2.25-2.30 incorrectly used this extraction
    -- safety latch for craftItem() Java exceptions. Clear ONLY that legacy
    -- condition. Genuine export/extraction desync reasons remain latched.
    if state.rsSafety.latched == true then
        local legacyReason = tostring(state.rsSafety.reason or "")
        if legacyReason:find("^craftItem Java error:") then
            local oldItem = tostring(state.rsSafety.item or "?")
            state.rsSafety = {
                latched = false,
                lastRecovered = nowSeconds(),
                lastDetail = "v2.31 cleared legacy craftItem error latch",
            }
            saveState()
            writeLog("RS SAFETY LEGACY CRAFT LATCH CLEARED item=" .. oldItem)
        end
    end

    return state.rsSafety
end

function NBTX.isRSSafetyLatched()
    local safety = NBTX.rsSafetyState()
    return safety.latched == true
end

function NBTX.rsSafetyProbeStatus()
    local safety = NBTX.rsSafetyState()
    if safety.latched ~= true then return false, 0 end
    local interval = math.max(5, tonumber(CONFIG.rsDesyncProbeSeconds) or 60)
    local last = tonumber(safety.lastProbe or safety.time) or 0
    local wait = math.max(0, math.ceil(interval - math.max(0, nowSeconds() - last)))
    return wait <= 0, wait
end

function NBTX.latchRSSafety(candidate, reportedStock, requestedCount, reason, sourceAttemptOccurred)
    local safety = NBTX.rsSafetyState()
    local now = nowSeconds()
    safety.latched = true
    safety.time = tonumber(safety.time) or now
    -- An item-specific export=0 is the fault that REQUESTS an independent
    -- generic probe; it is not itself that generic probe. Make the independent
    -- probe due immediately. A failure of the generic probe passes true here
    -- and therefore waits the normal interval before another global probe.
    if sourceAttemptOccurred == false then
        safety.lastProbe = 0
    else
        safety.lastProbe = now
    end
    safety.item = tostring(candidate and candidate.name or safety.item or "?")
    safety.reported = math.max(0, math.floor(tonumber(reportedStock) or 0))
    safety.requested = math.max(0, math.floor(tonumber(requestedCount) or 0))
    safety.reason = tostring(reason or "Player RS safety fault")
    safety.faults = (tonumber(safety.faults) or 0) + 1
    saveState()
    health.transfer = false
    health.message = "RS SAFETY PAUSE: " .. tostring(safety.item) .. " - " .. tostring(safety.reason)
    writeLog("RS SAFETY LATCH item=" .. tostring(safety.item) ..
        " reported=" .. tostring(safety.reported) ..
        " requested=" .. tostring(safety.requested) ..
        " faults=" .. tostring(safety.faults) ..
        " reason=" .. tostring(safety.reason))
    return safety
end

function NBTX.noteRSSafetyProbeAttempt(itemName)
    local safety = NBTX.rsSafetyState()
    safety.lastProbe = nowSeconds()
    safety.probeItem = tostring(itemName or "?")
    saveState()
    writeLog("RS SAFETY PROBE ATTEMPT item=" .. tostring(itemName or "?") .. " amount=1")
end

function NBTX.clearRSSafety(detail)
    local safety = NBTX.rsSafetyState()
    local wasLatched = safety.latched == true
    local recoveredAt = nowSeconds()
    state.rsSafety = {
        latched = false,
        lastRecovered = recoveredAt,
        lastDetail = tostring(detail or "Player RS extraction proven healthy"),
    }

    -- A successful generic probe proves the BRIDGE is healthy; it does not
    -- prove that the specific item which returned export=0 is healthy. Keep
    -- those per-item records and mark them as item-specific so they can retry
    -- independently without re-latching every other request.
    state.rsDesync = state.rsDesync or {}
    for _, entry in pairs(state.rsDesync) do
        if type(entry) == "table" then
            entry.sourceHealthy = true
            entry.sourceHealthyAt = recoveredAt
        end
    end
    saveState()
    if wasLatched then
        writeLog("RS SAFETY CLEARED detail=" .. tostring(detail or "source extraction recovered"))
    end
    health.message = "RS extraction healthy"
    return wasLatched
end

function NBTX.autoCraftSafetyAllowed()
    return not NBTX.isRSSafetyLatched()
end

-- Refined Storage source-extraction desync tracking. Keep these helpers on
-- NBTX rather than adding more top-level locals; this program has previously
-- approached Lua/CC:Tweaked's local-variable limit.
function NBTX.desyncKey(candidate)
    return "RS_DESYNC|" .. tostring(NBTX.candidateCraftStateKey(candidate))
end

function NBTX.getRSDesync(candidate)
    if not state then return nil, nil, false, 0 end
    state.rsDesync = state.rsDesync or {}

    local key = NBTX.desyncKey(candidate)
    local entry = state.rsDesync[key]
    if type(entry) ~= "table" then
        return nil, key, false, 0
    end

    local probeEvery = math.max(5, tonumber(CONFIG.rsDesyncProbeSeconds) or 60)
    local lastProbe = tonumber(entry.lastProbe or entry.time) or 0
    local elapsed = math.max(0, nowSeconds() - lastProbe)
    local wait = math.max(0, math.ceil(probeEvery - elapsed))
    return entry, key, wait <= 0, wait
end

function NBTX.markRSDesync(candidate, reportedStock, requestedCount, reason, globalProbeFailure)
    state.rsDesync = state.rsDesync or {}
    local key = NBTX.desyncKey(candidate)
    local now = nowSeconds()
    local previous = state.rsDesync[key]
    local itemSpecific = type(previous) == "table" and previous.sourceHealthy == true

    state.rsDesync[key] = {
        time = type(previous) == "table" and (tonumber(previous.time) or now) or now,
        lastProbe = now,
        item = tostring(candidate and candidate.name or "?"),
        reported = math.max(0, math.floor(tonumber(reportedStock) or 0)),
        requested = math.max(0, math.floor(tonumber(requestedCount) or 0)),
        reason = tostring(reason or "Player RS reported stock but exportItem moved 0"),
        sourceHealthy = itemSpecific,
        sourceHealthyAt = itemSpecific and tonumber(previous.sourceHealthyAt) or nil,
    }
    saveState()

    -- First failure: briefly pause and independently prove general Player-RS
    -- extraction. Once that generic probe has succeeded, later failures of the
    -- SAME item remain isolated to that item. If the generic probe itself
    -- fails, keep the true global latch and use the normal probe interval.
    if not itemSpecific then
        NBTX.latchRSSafety(candidate, reportedStock, requestedCount,
            reason or "Player RS reported stock but exportItem moved 0",
            globalProbeFailure == true)
    end

    health.transfer = false
    health.message = "RS DESYNC: " .. tostring(candidate and candidate.name or "?") ..
        " stock=" .. tostring(reportedStock or 0) .. " export=0"

    writeLog(
        "RS DESYNC DETECTED item=" .. tostring(candidate and candidate.name or "?") ..
        " key=" .. tostring(key) ..
        " reported=" .. tostring(reportedStock or 0) ..
        " requested=" .. tostring(requestedCount or 0) ..
        " export=0" ..
        " reason=" .. tostring(reason or "none")
    )

    return key
end

function NBTX.noteRSDesyncProbe(candidate)
    state.rsDesync = state.rsDesync or {}
    local key = NBTX.desyncKey(candidate)
    local entry = state.rsDesync[key]
    if type(entry) == "table" then
        entry.lastProbe = nowSeconds()
        saveState()
        writeLog("RS DESYNC PROBE item=" .. tostring(candidate and candidate.name or "?") ..
            " amount=1")
    end
end

function NBTX.clearRSDesync(candidate, detail)
    if not state then return false end
    state.rsDesync = state.rsDesync or {}
    local key = NBTX.desyncKey(candidate)
    local entry = state.rsDesync[key]
    if entry == nil then return false end

    state.rsDesync[key] = nil
    saveState()
    writeLog("RS DESYNC CLEARED item=" .. tostring(candidate and candidate.name or "?") ..
        " detail=" .. tostring(detail or "source extraction recovered"))
    return true
end

-- Start a craft job. If RS refuses the entire requested quantity, try
-- progressively smaller batches. This is useful when a pattern exists but
-- there are only enough ingredients for part of a large colony request.
--
-- Returns:
--   success:boolean
--   message:string
--   startedCount:number
function NBTX.submitCraft(name, count)
    count = math.max(0, math.floor(tonumber(count) or 0))

    if not autoCraftEnabled() then
        return false, "AutoCraft is OFF", 0
    end
    if not NBTX.autoCraftSafetyAllowed() then
        local safety = NBTX.rsSafetyState()
        return false, "RS SAFETY PAUSE: " .. tostring(safety.reason or "extraction health unproven"), 0
    end
    if count <= 0 then
        return false, "Requested craft quantity is zero", 0
    end

    local failureLeft, failureReason = NBTX.craftFailureRemaining(name)
    if failureLeft > 0 then
        return false,
            "CRAFT ERROR COOLDOWN: " .. tostring(name) ..
            " " .. tostring(failureLeft) .. "s; " .. tostring(failureReason),
            0
    end

    if not NBTX.isCraftable(name) then
        return false, "No RS crafting pattern", 0
    end
    if NBTX.isCrafting(name) then
        return true, "Craft already running", 0
    end

    local last = tonumber(state.craftJobs[name]) or 0
    if nowSeconds() - last < CONFIG.craftCooldownSeconds then
        return true, "Craft cooldown", 0
    end

    -- Try the full request first, then progressively smaller batches.
    local attempts = {}
    local seen = {}
    local n = count
    while n >= 1 do
        n = math.max(1, math.floor(n))
        if not seen[n] then
            attempts[#attempts + 1] = n
            seen[n] = true
        end
        if n == 1 then break end
        n = math.floor(n / 2)
    end

    local lastReason = "RS refused craft"
    for _, amount in ipairs(attempts) do
        -- Log BEFORE entering Advanced Peripherals so the exact offending
        -- item/count survives even if RS throws a Java exception.
        writeLog(
            "CRAFT REQUEST item=" .. tostring(name) ..
            " amount=" .. tostring(amount) ..
            " requested=" .. tostring(count) ..
            " key=" .. tostring(name)
        )

        local ok, started, reason = safeCall(
            playerRS,
            "craftItem",
            NBTX.craftFilter(name, amount)
        )

        if not ok then
            lastReason = tostring(reason or started or "craftItem error")
            local quarantineMessage = NBTX.quarantineCraft(
                name,
                name,
                amount,
                lastReason
            )
            return false, quarantineMessage, 0
        end

        if started == true then
            NBTX.clearCraftFailure(name)
            state.craftJobs[name] = nowSeconds()
            saveState()

            local msg
            if amount < count then
                msg = "Crafting " .. tostring(amount) ..
                    " of " .. tostring(count)
            else
                msg = "Crafting " .. tostring(amount)
            end

            writeLog("CRAFT started " .. tostring(amount) ..
                "/" .. tostring(count) .. " " .. tostring(name))
            return true, msg, amount
        end

        lastReason = tostring(reason or "RS returned false")
        writeLog("CRAFT refused " .. tostring(amount) ..
            " " .. tostring(name) ..
            " reason=" .. lastReason)

        -- The RS crafting calculation may report an existing task slightly
        -- after isItemCrafting() was checked. Treat that as success.
        if NBTX.isCrafting(name) then
            return true, "Craft already running", 0
        end
    end

    return false, lastReason, 0
end


function NBTX.candidateCraftFilter(candidate, count)
    if not candidate.exactRequestNBT then
        return NBTX.craftFilter(candidate.name, count)
    end

    local filter = {
        name = candidate.name,
        count = count,
    }

    if candidate.nbtFilter then
        filter.nbt = candidate.nbtFilter
    end

    return filter
end

function NBTX.getCandidateCraftability(candidate)
    if type(candidate) ~= "table" or not candidate.name then
        return false, "invalid candidate"
    end

    if not candidate.exactRequestNBT then
        return NBTX.getCraftability(candidate.name)
    end

    if not playerRS then
        return false, "player bridge unavailable"
    end

    -- listItems() is used for exact-variant stock, but craftability is checked
    -- with the dedicated APIs below rather than trusting an item record flag.
    local ok, value = safeCall(
        playerRS,
        "isItemCraftable",
        NBTX.candidateCraftFilter(candidate, nil)
    )
    if ok and value == true then
        return true, "isItemCraftable(exact NBT)"
    end

    local patternOK, pattern = safeCall(
        playerRS,
        "getPattern",
        NBTX.candidateCraftFilter(candidate, nil)
    )
    if patternOK and type(pattern) == "table" then
        return true, "getPattern(exact NBT)"
    end

    return false, "exact NBT variant not reported craftable"
end

function NBTX.isCandidateCraftable(candidate)
    local craftable = NBTX.getCandidateCraftability(candidate)
    return craftable == true
end

function NBTX.isCandidateCrafting(candidate)
    if not playerRS or type(candidate) ~= "table" then return false end

    local ok, value = safeCall(
        playerRS,
        "isItemCrafting",
        NBTX.candidateCraftFilter(candidate, nil)
    )
    return ok and value == true
end

function NBTX.candidateCraftStateKey(candidate)
    if not candidate or not candidate.name then return "?" end
    if candidate.exactRequestNBT and candidate.nbtFilter then
        return candidate.name .. "|NBT|" .. tostring(candidate.nbtFilter)
    end
    return candidate.name
end

function NBTX.submitCandidateCraft(candidate, count)
    if type(candidate) ~= "table" or not candidate.name then
        return false, "Invalid craft candidate", 0
    end

    if not candidate.exactRequestNBT then
        return NBTX.submitCraft(candidate.name, count)
    end

    count = math.max(0, math.floor(tonumber(count) or 0))

    if not autoCraftEnabled() then
        return false, "AutoCraft is OFF", 0
    end
    if not NBTX.autoCraftSafetyAllowed() then
        local safety = NBTX.rsSafetyState()
        return false, "RS SAFETY PAUSE: " .. tostring(safety.reason or "extraction health unproven"), 0
    end
    if count <= 0 then
        return false, "Requested craft quantity is zero", 0
    end

    local key = NBTX.candidateCraftStateKey(candidate)
    local failureLeft, failureReason = NBTX.craftFailureRemaining(key)
    if failureLeft > 0 then
        return false,
            "CRAFT ERROR COOLDOWN: " .. tostring(candidate.name) ..
            " " .. tostring(failureLeft) .. "s; " .. tostring(failureReason),
            0
    end

    if not NBTX.isCandidateCraftable(candidate) then
        return false, "No RS pattern for exact NBT variant", 0
    end
    if NBTX.isCandidateCrafting(candidate) then
        return true, "Craft already running", 0
    end

    local last = tonumber(state.craftJobs[key]) or 0
    if nowSeconds() - last < CONFIG.craftCooldownSeconds then
        return true, "Craft cooldown", 0
    end

    local attempts = {}
    local seen = {}
    local n = count
    while n >= 1 do
        n = math.max(1, math.floor(n))
        if not seen[n] then
            attempts[#attempts + 1] = n
            seen[n] = true
        end
        if n == 1 then break end
        n = math.floor(n / 2)
    end

    local lastReason = "RS refused exact-NBT craft"

    for _, amount in ipairs(attempts) do
        writeLog(
            "CRAFT REQUEST item=" .. tostring(candidate.name) ..
            " amount=" .. tostring(amount) ..
            " requested=" .. tostring(count) ..
            " key=" .. tostring(key) ..
            " exactNBT=true"
        )

        local ok, started, reason = safeCall(
            playerRS,
            "craftItem",
            NBTX.candidateCraftFilter(candidate, amount)
        )

        if not ok then
            local why = tostring(reason or started or "craftItem error")
            local quarantineMessage = NBTX.quarantineCraft(
                key,
                candidate.name,
                amount,
                why
            )
            return false, quarantineMessage, 0
        end

        if started == true then
            NBTX.clearCraftFailure(key)
            state.craftJobs[key] = nowSeconds()
            saveState()

            local msg
            if amount < count then
                msg = "Crafting " .. tostring(amount) ..
                    " of " .. tostring(count)
            else
                msg = "Crafting " .. tostring(amount)
            end

            writeLog(
                "CRAFT exact-NBT started " .. tostring(amount) ..
                "/" .. tostring(count) .. " " .. tostring(candidate.name)
            )
            return true, msg, amount
        end

        if NBTX.isCandidateCrafting(candidate) then
            return true, "Craft already running", 0
        end
    end

    return false, lastReason, 0
end

-- Build the source-side RS export filter.
--
-- IMPORTANT for Advanced Peripherals 0.7 / Minecraft 1.20.1:
-- Use a plain registry-name filter for ordinary items. Do not use a
-- fingerprint merely because getItem() returns one.
--
-- Only use an exact NBT/fingerprint filter when the item genuinely has
-- meaningful NBT and therefore requires variant-specific matching.
function NBTX.buildSourceFilter(bridge, itemName, count, candidate)
    if type(candidate) == "table"
        and candidate.exactRequestNBT
        and candidate.nbtFilter then

        local info = NBTX.getRSItemByCandidate(bridge, candidate)
        return {
            name = itemName,
            count = count,
            nbt = candidate.nbtFilter,
        }, info, "request-nbt"
    end

    -- v2.25: ordinary items MUST stay name-only. Do not infer fingerprint/NBT
    -- specificity from getItem(), because a broad stock query followed by an
    -- over-specific export can manufacture a false export=0/desync signature.
    local info = getRSItem(bridge, itemName)
    return {
        name = itemName,
        count = count,
    }, info, "name"
end

function NBTX.exportPristineEquipmentFromPlayer(candidate, count)
    local variants, total = NBTX.getPristineEquipmentVariants(playerRS, candidate)
    local wanted = math.max(0, math.floor(tonumber(count) or 0))
    local movedTotal = 0
    local lastErr = nil

    if total <= 0 or #variants == 0 then
        return 0, "No provably pristine stored equipment variant"
    end

    for _, variant in ipairs(variants) do
        if movedTotal >= wanted then break end
        local take = math.min(wanted - movedTotal, tonumber(variant.amount) or 0)
        if take > 0 then
            local filter = { fingerprint = variant.fingerprint, count = take }
            local ok, moved, err
            if CONFIG.usePeripheralTransfer and CONFIG.transferChestName then
                ok, moved, err = safeCall(
                    playerRS, "exportItemToPeripheral", filter, CONFIG.transferChestName)
            else
                ok, moved, err = safeCall(
                    playerRS, "exportItem", filter, CONFIG.playerToChestDirection)
            end
            if ok then
                moved = tonumber(moved) or 0
                movedTotal = movedTotal + moved
                if moved > 0 then NBTX.invalidateRSList(playerRS) end
            else
                lastErr = moved or err
            end
        end
    end

    writeLog("PRISTINE EXPORT item=" .. tostring(candidate.name) ..
        " requested=" .. tostring(wanted) .. " moved=" .. tostring(movedTotal))
    return movedTotal, lastErr
end

function NBTX.exportFromPlayer(itemName, count, candidate)
    if type(candidate) == "table" and candidate.requiresPristine then
        return NBTX.exportPristineEquipmentFromPlayer(candidate, count)
    end

    local filter, _, filterMode =
        NBTX.buildSourceFilter(playerRS, itemName, count, candidate)

    writeLog("EXPORT FILTER A item=" .. tostring(itemName) ..
        " mode=" .. tostring(filterMode) ..
        " count=" .. tostring(count))

    if CONFIG.usePeripheralTransfer and CONFIG.transferChestName then
        local ok, moved = safeCall(
            playerRS,
            "exportItemToPeripheral",
            filter,
            CONFIG.transferChestName
        )
        if ok then
            moved = tonumber(moved) or 0
            if moved > 0 then NBTX.invalidateRSList(playerRS) end
            return moved, nil
        end
        return 0, moved
    end

    local ok, moved, err = safeCall(
        playerRS,
        "exportItem",
        filter,
        CONFIG.playerToChestDirection
    )
    if ok then
        moved = tonumber(moved) or 0
        if moved > 0 then NBTX.invalidateRSList(playerRS) end
        return moved, err
    end
    return 0, moved
end

function NBTX.importToColony(itemName, count)
    local filter = { name = itemName, count = count }

    if CONFIG.usePeripheralTransfer and CONFIG.transferChestName then
        local ok, moved = safeCall(
            colonyRS,
            "importItemFromPeripheral",
            filter,
            CONFIG.transferChestName
        )
        if ok then
            moved = tonumber(moved) or 0
            if moved > 0 then NBTX.invalidateRSList(colonyRS) end
            return moved, nil
        end
        return 0, moved
    end

    local ok, moved, err = safeCall(
        colonyRS,
        "importItem",
        filter,
        CONFIG.chestToColonyDirection
    )
    if ok then
        moved = tonumber(moved) or 0
        if moved > 0 then NBTX.invalidateRSList(colonyRS) end
        return moved, err
    end
    return 0, moved
end

function NBTX.exportFromColony(itemName, count)
    local filter, _, filterMode = NBTX.buildSourceFilter(colonyRS, itemName, count)

    writeLog("EXPORT FILTER B item=" .. tostring(itemName) ..
        " mode=" .. tostring(filterMode) ..
        " count=" .. tostring(count))

    if CONFIG.usePeripheralTransfer and CONFIG.transferChestName then
        local ok, moved = safeCall(
            colonyRS,
            "exportItemToPeripheral",
            filter,
            CONFIG.transferChestName
        )
        if ok then
            moved = tonumber(moved) or 0
            if moved > 0 then NBTX.invalidateRSList(colonyRS) end
            return moved, nil
        end
        return 0, moved
    end

    local ok, moved, err = safeCall(
        colonyRS,
        "exportItem",
        filter,
        CONFIG.colonyToChestDirection
    )
    if ok then
        moved = tonumber(moved) or 0
        if moved > 0 then NBTX.invalidateRSList(colonyRS) end
        return moved, err
    end
    return 0, moved
end

function NBTX.importToPlayer(itemName, count)
    local filter = { name = itemName, count = count }

    -- Explicit peripheral-transfer mode remains the first choice when configured.
    if CONFIG.usePeripheralTransfer and CONFIG.transferChestName then
        local ok, moved = safeCall(
            playerRS,
            "importItemFromPeripheral",
            filter,
            CONFIG.transferChestName
        )
        if ok then
            moved = tonumber(moved) or 0
            if moved > 0 then NBTX.invalidateRSList(playerRS) end
            return moved, nil
        end
        return 0, moved
    end

    -- Normal installation uses the side relative to the Player RS Bridge.
    local ok, moved, err = safeCall(
        playerRS,
        "importItem",
        filter,
        CONFIG.chestToPlayerDirection
    )
    if ok then
        moved = tonumber(moved) or 0
        if moved > 0 then
            NBTX.invalidateRSList(playerRS)
            return moved, err
        end
    else
        err = moved
        moved = 0
    end

    -- v2.34 recovery fallback: if the transfer barrel is visible on the wired
    -- CC network, ask the RS Bridge to import directly from that peripheral.
    -- This is especially important for the one-item health probe: source
    -- extraction may already be proven by the item sitting in the barrel even
    -- if the directional return path refuses the import.
    local barrelName = transferChestResolvedName
    if barrelName and peripheral.isPresent(barrelName) then
        local okPeripheral, movedPeripheral, peripheralErr = safeCall(
            playerRS,
            "importItemFromPeripheral",
            filter,
            barrelName
        )
        if okPeripheral then
            movedPeripheral = tonumber(movedPeripheral) or 0
            if movedPeripheral > 0 then
                NBTX.invalidateRSList(playerRS)
                writeLog("PLAYER IMPORT FALLBACK succeeded item=" .. tostring(itemName) ..
                    " count=" .. tostring(movedPeripheral) ..
                    " barrel=" .. tostring(barrelName))
                return movedPeripheral, nil
            end
        end
        local detail = tostring(peripheralErr or movedPeripheral or err or "import returned 0")
        return 0, "directional and peripheral barrel import returned 0: " .. detail
    end

    return 0, err or "Player RS import returned 0"
end



--------------------------------------------------------------------------
-- Optional transfer chest inspection
--------------------------------------------------------------------------

local function chestItemCount(itemName)
    local chest = getTransferChest()
    if not chest then return nil end

    local ok, list = safeCall(chest, "list")
    if not ok or type(list) ~= "table" then return nil end

    local total = 0
    for _, stack in pairs(list) do
        if type(stack) == "table" and stack.name == itemName then
            total = total + (tonumber(stack.count) or 0)
        end
    end
    return total
end

local function chestIsEmpty()
    local chest = getTransferChest()
    if not chest then return nil end
    local ok, list = safeCall(chest, "list")
    if not ok or type(list) ~= "table" then return nil end
    return next(list) == nil
end

local function chestContentsSummary(maxItems)
    local chest = getTransferChest()
    if not chest then return nil end

    local ok, list = safeCall(chest, "list")
    if not ok or type(list) ~= "table" then return nil end

    local parts = {}
    local limit = math.max(1, tonumber(maxItems) or 3)

    for _, stack in pairs(list) do
        if type(stack) == "table" and stack.name then
            parts[#parts + 1] =
                tostring(stack.name) .. " x" .. tostring(stack.count or 0)
            if #parts >= limit then break end
        end
    end

    if #parts == 0 then return "EMPTY" end
    return table.concat(parts, ", ")
end

local function learnStackSizeFromChest(itemName)
    local chest = getTransferChest()
    if not chest then return false end

    local ok, list = safeCall(chest, "list")
    if not ok or type(list) ~= "table" then return false end

    for slot, stack in pairs(list) do
        if type(stack) == "table" and stack.name == itemName then
            local okDetail, detail = safeCall(chest, "getItemDetail", slot)
            if okDetail and type(detail) == "table" and tonumber(detail.maxCount) then
                if rememberStackSize(itemName, detail.maxCount) then
                    saveState()
                end
                return true
            end
        end
    end
    return false
end

--------------------------------------------------------------------------
-- MineColonies request helpers
--------------------------------------------------------------------------

local function isRequestActive(request)
    if type(request) ~= "table" then return false end
    if type(request.id) ~= "string" or request.id == "" then return false end

    local stateName = tostring(request.state or ""):lower()
    local rejected = {
        "cancel", "complete", "completed", "resolve", "resolved",
        "fulfill", "fulfilled", "done", "closed"
    }
    for _, word in ipairs(rejected) do
        if stateName:find(word, 1, true) then return false end
    end

    return true
end

local function getRequestedCount(request)
    local n = tonumber(request.count) or 0
    if n <= 0 then n = tonumber(request.minCount) or 0 end

    if n <= 0 and type(request.items) == "table" then
        for _, item in pairs(request.items) do
            if type(item) == "table" then
                n = math.max(n, tonumber(item.count) or 0)
            end
        end
    end

    return math.max(0, math.floor(n))
end


function NBTX.cleanMinecraftText(value)
    local s = tostring(value or "")

    -- Strip standard Minecraft formatting codes such as:
    --   §ePortable Drill
    --   §6Diamond Axe
    s = s:gsub("§.", "")

    -- Strip a literal escaped section sign form if one appears in serialized
    -- text/debug output.
    s = s:gsub("\\194\\167.", "")

    return s
end

function NBTX.requestToolClass(request)
    if type(request) ~= "table" then return nil end

    local haystack =
        (" " .. NBTX.cleanMinecraftText(request.desc) ..
         " " .. NBTX.cleanMinecraftText(request.name) ..
         " " .. NBTX.cleanMinecraftText(request.type) ..
         " " .. NBTX.cleanMinecraftText(request.toolType) ..
         " " .. NBTX.cleanMinecraftText(request.toolClass) ..
         " "):lower()

    -- Common MineColonies/tool-action spellings.
    if haystack:find("axe_dig", 1, true)
        or haystack:find("axe dig", 1, true)
        or haystack:find("axes", 1, true) then
        return "axe"
    end

    if haystack:find("pickaxe_dig", 1, true)
        or haystack:find("pickaxe dig", 1, true) then
        return "pickaxe"
    end

    if haystack:find("shovel_dig", 1, true)
        or haystack:find("shovel dig", 1, true) then
        return "shovel"
    end

    local classes = {
        "fishing rod", "crossbow", "pickaxe", "shovel", "sword",
        "shears", "shield", "helmet", "leggings", "chestplate",
        "boots", "lighter", "lead", "spear", "axe", "hoe", "bow",
    }

    for _, class in ipairs(classes) do
        if haystack:find(class, 1, true) then
            if class == "fishing rod" then return "fishing_rod" end
            return class
        end
    end

    return nil
end

function NBTX.tagContains(candidate, wanted)
    if type(candidate) ~= "table" or type(candidate.tags) ~= "table" then
        return false
    end

    wanted = tostring(wanted or ""):lower()

    for k, v in pairs(candidate.tags) do
        local s
        if type(k) == "string" and v == true then
            s = k
        else
            s = v
        end

        if tostring(s or ""):lower() == wanted then
            return true
        end
    end

    return false
end

function NBTX.candidateLooksLikeEquipment(candidate)
    if type(candidate) ~= "table" then return false end
    local name = tostring(candidate.name or ""):lower()
    local path = name:match("^[^:]+:(.+)$") or name

    if path:match("_axe$") or path:match("_pickaxe$")
        or path:match("_shovel$") or path:match("_hoe$")
        or path:match("_sword$") or path == "fishing_rod"
        or path:match("_fishing_rod$") or path == "shears"
        or path:match("_shears$") or path == "bow"
        or path:match("_bow$") or path == "crossbow"
        or path:match("_crossbow$") or path == "shield"
        or path:match("_shield$") or path == "trident"
        or path:match("_trident$") or path == "spear"
        or path:match("_spear$") or path == "flint_and_steel"
        or path == "helmet" or path:match("_helmet$")
        or path == "chestplate" or path:match("_chestplate$")
        or path == "leggings" or path:match("_leggings$")
        or path == "boots" or path:match("_boots$") then
        return true
    end

    local equipmentTags = {
        "minecraft:axes", "minecraft:pickaxes", "minecraft:shovels",
        "minecraft:hoes", "minecraft:swords",
        "forge:tools/axes", "forge:tools/pickaxes", "forge:tools/shovels",
        "forge:tools/hoes", "forge:tools/swords",
    }
    for _, tag in ipairs(equipmentTags) do
        if NBTX.tagContains(candidate, tag) then return true end
    end
    return false
end

function NBTX.candidateIsExactToolClass(candidate, toolClass)
    if type(candidate) ~= "table" or not toolClass then return false end

    local name = tostring(candidate.name or ""):lower()
    local display =
        NBTX.cleanMinecraftText(candidate.displayName or ""):lower()
    local path = name:match("^[^:]+:(.+)$") or name

    local function genericMultiTool()
        return path:find("drill", 1, true)
            or path:find("paxel", 1, true)
            or path:find("multitool", 1, true)
            or path:find("multi_tool", 1, true)
            or display:find("portable drill", 1, true)
            or display:find("drill", 1, true)
            or display:find("paxel", 1, true)
            or display:find("multi tool", 1, true)
            or display:find("multitool", 1, true)
    end

    if toolClass == "axe" then
        if path:find("pickaxe", 1, true) or genericMultiTool() then
            return false
        end
        return path:match("_axe$") ~= nil
            or path == "axe"
            or NBTX.tagContains(candidate, "minecraft:axes")
            or NBTX.tagContains(candidate, "forge:tools/axes")
            or display:match("%f[%a]axe%f[%A]") ~= nil

    elseif toolClass == "pickaxe" then
        if genericMultiTool() then return false end
        return path:match("_pickaxe$") ~= nil
            or path == "pickaxe"
            or NBTX.tagContains(candidate, "minecraft:pickaxes")
            or NBTX.tagContains(candidate, "forge:tools/pickaxes")
            or display:match("%f[%a]pickaxe%f[%A]") ~= nil

    elseif toolClass == "shovel" then
        if genericMultiTool() then return false end
        return path:match("_shovel$") ~= nil
            or path == "shovel"
            or NBTX.tagContains(candidate, "minecraft:shovels")
            or NBTX.tagContains(candidate, "forge:tools/shovels")
            or display:match("%f[%a]shovel%f[%A]") ~= nil

    elseif toolClass == "hoe" then
        if genericMultiTool() then return false end
        return path:match("_hoe$") ~= nil
            or path == "hoe"
            or NBTX.tagContains(candidate, "minecraft:hoes")
            or NBTX.tagContains(candidate, "forge:tools/hoes")
            or display:match("%f[%a]hoe%f[%A]") ~= nil

    elseif toolClass == "sword" then
        return path:match("_sword$") ~= nil
            or path == "sword"
            or NBTX.tagContains(candidate, "minecraft:swords")
            or NBTX.tagContains(candidate, "forge:tools/swords")

    elseif toolClass == "fishing_rod" then
        return path == "fishing_rod"
            or path:match("_fishing_rod$") ~= nil
            or display:find("fishing rod", 1, true) ~= nil

    elseif toolClass == "shears" then
        return path == "shears"
            or path:match("_shears$") ~= nil

    elseif toolClass == "bow" then
        return path == "bow"
            or (path:match("_bow$") ~= nil
                and not path:find("crossbow", 1, true))

    elseif toolClass == "crossbow" then
        return path == "crossbow" or path:match("_crossbow$") ~= nil

    elseif toolClass == "shield" then
        return path == "shield" or path:match("_shield$") ~= nil

    elseif toolClass == "helmet"
        or toolClass == "leggings"
        or toolClass == "chestplate"
        or toolClass == "boots" then
        return path == toolClass or path:match("_" .. toolClass .. "$") ~= nil

    elseif toolClass == "lighter" then
        return path == "flint_and_steel"
            or display:find("flint and steel", 1, true) ~= nil

    elseif toolClass == "lead" then
        return path == "lead"

    elseif toolClass == "spear" then
        return path == "spear" or path:match("_spear$") ~= nil
    end

    return false
end

function NBTX.candidateToolTier(candidate)
    if type(candidate) ~= "table" then return -1 end

    local override = CONFIG.toolTierOverrides
        and tonumber(CONFIG.toolTierOverrides[candidate.name])

    if override ~= nil then return override end

    local name = tostring(candidate.name or ""):lower()
    local display =
        NBTX.cleanMinecraftText(candidate.displayName or ""):lower()
    local path = name:match("^[^:]+:(.+)$") or name
    local haystack = path .. " " .. display

    if haystack:find("netherite", 1, true) then return 4 end
    if haystack:find("diamond", 1, true) then return 3 end
    if haystack:find("iron", 1, true) then return 2 end
    if haystack:find("stone", 1, true) then return 1 end

    if haystack:find("golden", 1, true)
        or haystack:find("gold ", 1, true)
        or haystack:find("wooden", 1, true)
        or haystack:find("wood ", 1, true) then
        return 0
    end

    return 0
end

-- Equipment supplied to MineColonies must be pristine. For stored RS items we
-- deliberately require positive proof: no durability loss and no enchant/custom
-- metadata. AP 0.7 commonly exposes NBT as an opaque hash; an opaque non-empty NBT
-- value cannot prove the item is pristine, so it is conservatively rejected and the
-- crafting path is used instead.
function NBTX.toolClassRequiresPristine(toolClass)
    return toolClass ~= nil and toolClass ~= "lead"
end

function NBTX.storedEquipmentStackIsPristine(item)
    if type(item) ~= "table" then return false, "invalid stack" end

    -- Prefer explicit fields when a bridge/mod exposes them.
    local damage = tonumber(item.damage or item.Damage)
    if damage ~= nil and damage ~= 0 then return false, "damaged" end

    local raw = serializedNBTText(item.nbt)
    local lower = raw:lower()
    if raw == "" or raw == "{}" or raw == "nil" then
        return true, "no NBT"
    end

    -- If the bridge exposes enchantment fields directly, reject any content.
    if item.isEnchanted == true then return false, "enchanted" end
    if type(item.enchantments) == "table" and next(item.enchantments) ~= nil then
        return false, "enchanted"
    end

    -- AP 0.7 may expose the NBT identity as an opaque MD5-like hash. We cannot
    -- prove damage/enchantment state from such a value, so reject it.
    if raw:match("^[0-9a-fA-F]+$") and #raw >= 16 then
        return false, "opaque NBT hash"
    end

    -- For readable NBT, enchantment data is disqualifying. Other customization
    -- is allowed as long as durability remains zero and no enchantments exist.
    if lower:find("enchant", 1, true) or lower:find("stored_enchant", 1, true) then
        return false, "enchanted"
    end

    local nbtDamage =
        lower:match("damage%s*=%s*(-?%d+)")
        or lower:match("damage%s*:%s*(-?%d+)")
    if nbtDamage and tonumber(nbtDamage) ~= 0 then
        return false, "damaged"
    end

    -- In Minecraft, an absent Damage tag is equivalent to zero durability loss.
    -- At this point the NBT is readable and contains no enchantment marker, so it
    -- satisfies the requested policy whether Damage=0 is explicit or omitted.
    return true, nbtDamage and "Damage=0" or "readable clean NBT"
end

function NBTX.getPristineEquipmentVariants(bridge, candidate)
    local variants = {}
    local total = 0
    local rejected = 0
    local matching = 0
    local items = NBTX.getRSListItems(bridge, false)
    if type(items) ~= "table" then return variants, 0, 0, 0 end

    for _, item in pairs(items) do
        if type(item) == "table" and item.name == candidate.name then
            local amount = math.max(0, tonumber(item.amount) or 0)
            if amount > 0 then
                matching = matching + amount
                local pristine, reason = NBTX.storedEquipmentStackIsPristine(item)
                if pristine and type(item.fingerprint) == "string" and item.fingerprint ~= "" then
                    variants[#variants + 1] = {
                        fingerprint = item.fingerprint,
                        amount = amount,
                        displayName = item.displayName,
                    }
                    total = total + amount
                elseif pristine then
                    -- Without a fingerprint, a name-only export could select a
                    -- different damaged/enchanted variant. Do not count it unless
                    -- every same-name stored item is later proven clean; AP normally
                    -- provides fingerprints, so this is intentionally conservative.
                    rejected = rejected + amount
                    writeLog("PRISTINE REJECT no fingerprint item=" .. tostring(candidate.name) ..
                        " amount=" .. tostring(amount))
                else
                    rejected = rejected + amount
                    writeLog("PRISTINE REJECT item=" .. tostring(candidate.name) ..
                        " amount=" .. tostring(amount) .. " reason=" .. tostring(reason))
                end
            end
        end
    end

    table.sort(variants, function(a, b)
        return (tonumber(a.amount) or 0) > (tonumber(b.amount) or 0)
    end)
    return variants, total, rejected, matching
end

function NBTX.populateCandidateAvailability(candidate)
    if candidate.requiresPristine then
        local playerVariants, playerClean, playerRejected, playerMatching =
            NBTX.getPristineEquipmentVariants(playerRS, candidate)
        local _, warehouseClean = NBTX.getPristineEquipmentVariants(colonyRS, candidate)
        candidate.pristinePlayerVariants = playerVariants
        candidate.playerStock = playerClean
        candidate.warehouseStock = warehouseClean
        candidate.rejectedEquipmentStock = playerRejected
        candidate.totalEquipmentStock = playerMatching
    else
        candidate.playerStock =
            NBTX.getRSAmountByCandidate(playerRS, candidate)
        candidate.warehouseStock =
            NBTX.getRSAmountByCandidate(colonyRS, candidate)
    end

    local craftable, craftSource =
        NBTX.getCandidateCraftability(candidate)

    candidate.rawCraftable = craftable
    candidate.craftable = autoCraftEnabled() and craftable
    candidate.craftSource = craftSource
end

function NBTX.candidateAvailabilityTier(candidate, remaining)
    if candidate.playerStock >= remaining and remaining > 0 then
        return 4
    elseif candidate.playerStock > 0 then
        return 3
    elseif candidate.craftable then
        return 2
    elseif candidate.warehouseStock > 0 then
        return 1
    end
    return 0
end

function NBTX.chooseBestToolCandidate(request, candidates, remaining)
    local toolClass = NBTX.requestToolClass(request)
    if not toolClass then return nil, nil end

    local exactUsable = {}
    local exactAll = {}

    for _, c in ipairs(candidates) do
        c.requestedToolClass = toolClass
        c.requiresPristine = NBTX.toolClassRequiresPristine(toolClass)
            or NBTX.candidateLooksLikeEquipment(c)
        NBTX.populateCandidateAvailability(c)

        c.exactToolClass = NBTX.candidateIsExactToolClass(c, toolClass)
        c.toolTier = NBTX.candidateToolTier(c)
        c.availabilityTier = NBTX.candidateAvailabilityTier(c, remaining)

        if c.exactToolClass then
            exactAll[#exactAll + 1] = c

            if c.availabilityTier > 0 then
                exactUsable[#exactUsable + 1] = c
            end
        elseif NBTX.cleanMinecraftText(c.displayName or ""):lower()
            :find("portable drill", 1, true) then
            writeLog(
                "TOOL REJECT request=" .. tostring(request.id or "?") ..
                " class=" .. tostring(toolClass) ..
                " rejected=" .. tostring(c.name) ..
                " display=" .. tostring(NBTX.cleanMinecraftText(c.displayName))
            )
        end
    end

    -- For an identified tool-class request, NEVER substitute a non-matching
    -- multi-tool. Choose among real tools only.
    local pool = (#exactUsable > 0) and exactUsable or exactAll

    if #pool == 0 then
        return nil, toolClass
    end

    table.sort(pool, function(a, b)
        -- Highest tool tier is the primary rule.
        if a.toolTier ~= b.toolTier then
            return a.toolTier > b.toolTier
        end

        -- At equal tier, prefer an immediately usable/craftable candidate.
        if a.availabilityTier ~= b.availabilityTier then
            return a.availabilityTier > b.availabilityTier
        end

        if a.playerStock ~= b.playerStock then
            return a.playerStock > b.playerStock
        end

        return tostring(a.name) < tostring(b.name)
    end)

    return pool[1], toolClass
end

local function requestCandidates(request)
    local out = {}
    local seen = {}

    if type(request.items) ~= "table" then return out end

    for _, item in pairs(request.items) do
        if type(item) == "table"
            and type(item.name) == "string"
            and item.name ~= "" then

            local hasNBT = itemHasNBT(item)
            local safeDefaultNBT = requestNBTIsSafeDefault(item)
            local exactRequestNBT =
                NBTX.exactRequestNBTAllowed(item)
                and NBTX.requestNBTFilterValue(item) ~= nil

            local unsafeNBT =
                hasNBT
                and not CONFIG.allowNBTNameOnly
                and not safeDefaultNBT
                and not exactRequestNBT

            local candidateIdentity =
                item.name ..
                (exactRequestNBT
                    and ("|NBT|" .. tostring(NBTX.requestNBTFilterValue(item)))
                    or "")

            if not unsafeNBT and not seen[candidateIdentity] then
                seen[candidateIdentity] = true

                local observedStackSize =
                    tonumber(item.maxCount)
                    or tonumber(item.maxStackSize)

                if observedStackSize and observedStackSize > 0 then
                    rememberStackSize(item.name, observedStackSize)
                end

                out[#out + 1] = {
                    name = item.name,
                    displayName = item.displayName or item.name,
                    count = tonumber(item.count) or 0,
                    nbt = item.nbt,
                    nbtFilter = exactRequestNBT
                        and NBTX.requestNBTFilterValue(item) or nil,
                    requestHasNBT = hasNBT,
                    safeDefaultNBT = safeDefaultNBT,
                    exactRequestNBT = exactRequestNBT,
                    tags = item.tags,
                    requiresPristine = NBTX.candidateLooksLikeEquipment({
                        name = item.name,
                        displayName = item.displayName,
                        tags = item.tags,
                    }),
                }

                if exactRequestNBT then
                    writeLog(
                        "EXACT REQUEST NBT candidate item=" ..
                        tostring(item.name) ..
                        " request=" ..
                        tostring(request.id or "?")
                    )
                elseif hasNBT and safeDefaultNBT then
                    writeLog(
                        "SAFE DEFAULT NBT candidate item=" ..
                        tostring(item.name) ..
                        " request=" ..
                        tostring(request.id or "?")
                    )
                end
            elseif unsafeNBT then
                local requestedToolClass = NBTX.requestToolClass(request)
                if requestedToolClass
                    and NBTX.candidateIsExactToolClass({
                        name = item.name,
                        displayName = item.displayName,
                        tags = item.tags,
                    }, requestedToolClass) then
                    writeLog(
                        "TOOL NBT REJECT request=" ..
                        tostring(request.id or "?") ..
                        " class=" .. tostring(requestedToolClass) ..
                        " item=" .. tostring(item.name) ..
                        " display=" ..
                        tostring(NBTX.cleanMinecraftText(item.displayName))
                    )
                end
            end
        end
    end

    return out
end

local function candidateExists(candidates, name)
    for _, c in ipairs(candidates) do
        if c.name == name then return c end
    end
    return nil
end

local function chooseCandidate(request, requestState, remaining)
    local candidates = requestCandidates(request)
    if #candidates == 0 then return nil end

    local toolCandidate, toolClass =
        NBTX.chooseBestToolCandidate(request, candidates, remaining)

    if toolClass then
        if toolCandidate then
            if requestState
                and requestState.item
                and requestState.item ~= toolCandidate.name then
                writeLog(
                    "TOOL RESELECT request=" .. tostring(request.id or "?") ..
                    " class=" .. tostring(toolClass) ..
                    " old=" .. tostring(requestState.item) ..
                    " new=" .. tostring(toolCandidate.name) ..
                    " tier=" .. tostring(toolCandidate.toolTier)
                )
            end

            return toolCandidate
        end

        -- Never let a recognized Axe/Pickaxe/etc request fall through to
        -- generic candidate scoring. That is how Portable Drill was selected.
        writeLog(
            "TOOL REQUEST has no exact candidate request=" ..
            tostring(request.id or "?") ..
            " class=" .. tostring(toolClass)
        )
        return nil
    end

    -- Sticky alternatives only apply to normal non-tool requests.
    if not toolClass and requestState and requestState.item then
        local existing = candidateExists(candidates, requestState.item)
        if existing then
            NBTX.populateCandidateAvailability(existing)

            if existing.playerStock > 0 or existing.craftable then
                return existing
            end
        end
    end

    local best = nil
    local bestTier = -1
    local bestScore = -1

    for _, c in ipairs(candidates) do
        if c.playerStock == nil then
            NBTX.populateCandidateAvailability(c)
        end

        local tier = NBTX.candidateAvailabilityTier(c, remaining)

        local score
        if tier == 4 or tier == 3 then
            score = c.playerStock
        else
            score = c.warehouseStock
        end

        if tier > bestTier or (tier == bestTier and score > bestScore) then
            bestTier = tier
            bestScore = score
            best = c
        end
    end

    return best
end

local function getColonyRequests()
    local ok, requests = safeCall(colony, "getRequests")
    if not ok or type(requests) ~= "table" then
        return nil, tostring(requests or "getRequests failed")
    end

    if CONFIG.debug then
        local h = fs.open(CONFIG.debugRequestsFile, "w")
        if h then
            h.write(textutils.serialize(requests))
            h.close()
        end
    end

    return requests, nil
end

--------------------------------------------------------------------------
-- Transfer timing / retry helpers
--------------------------------------------------------------------------

local function transferSleep(seconds)
    local delay = tonumber(seconds) or 0
    if delay > 0 then sleep(delay) end
end

local function retryImport(importFunction, itemName, count, destinationLabel)
    local attempts = math.max(1, math.floor(tonumber(CONFIG.transferImportRetries) or 1))
    local lastErr = nil

    for attempt = 1, attempts do
        local moved, err = importFunction(itemName, count)
        moved = tonumber(moved) or 0

        if moved > 0 then
            if attempt > 1 then
                writeLog("IMPORT retry succeeded attempt=" .. tostring(attempt) ..
                    " item=" .. tostring(itemName) ..
                    " moved=" .. tostring(moved) ..
                    " destination=" .. tostring(destinationLabel))
            end
            return moved, nil
        end

        lastErr = err
        writeLog("IMPORT retry " .. tostring(attempt) .. "/" .. tostring(attempts) ..
            " moved=0 item=" .. tostring(itemName) ..
            " destination=" .. tostring(destinationLabel) ..
            " reason=" .. tostring(err or "none"))

        if attempt < attempts then
            transferSleep(CONFIG.transferRetryDelay)
        end
    end

    return 0, lastErr or "Import returned 0 after retries"
end

--------------------------------------------------------------------------
-- Transaction handling
--------------------------------------------------------------------------

local function requestStateFor(id)
    local rs = state.requests[id]
    if type(rs) ~= "table" then
        rs = {
            supplied = 0,
            firstSeen = nowSeconds(),
            lastSeen = nowSeconds(),
        }
        state.requests[id] = rs
    end
    rs.supplied = tonumber(rs.supplied) or 0
    rs.lastSeen = nowSeconds()
    return rs
end

local function finishImportedAmount(requestId, itemName, amount)
    if amount <= 0 then return end
    local rs = requestStateFor(requestId)
    rs.item = rs.item or itemName
    rs.supplied = (tonumber(rs.supplied) or 0) + amount
    rs.lastTransfer = nowSeconds()
end

local function clearPending(reason)
    if state.pending and reason then
        writeLog("PENDING CLEARED: " .. tostring(reason))
    end
    state.pending = nil
    saveState()
end

-- A successful health-probe export proves Player-RS source extraction. If the
-- one test item cannot be returned to Player RS, keep that cleanup separate
-- from the normal transfer transaction lock. This lets crafting continue and
-- prevents an already-proven source from remaining globally RS PAUSED.
function NBTX.setProbeCleanup(itemName, exported, imported, detail)
    state.probeCleanup = {
        item = tostring(itemName or "?"),
        exported = math.max(0, math.floor(tonumber(exported) or 0)),
        imported = math.max(0, math.floor(tonumber(imported) or 0)),
        started = nowSeconds(),
        lastAttempt = nowSeconds(),
        attempts = 0,
        lastError = detail and tostring(detail) or nil,
    }
    saveState()
    writeLog("RS PROBE CLEANUP queued item=" .. tostring(itemName) ..
        " remaining=" .. tostring(math.max(0,
            (tonumber(exported) or 0) - (tonumber(imported) or 0))))
end

function NBTX.clearProbeCleanup(detail)
    if type(state.probeCleanup) == "table" then
        writeLog("RS PROBE CLEANUP cleared item=" ..
            tostring(state.probeCleanup.item or "?") ..
            " detail=" .. tostring(detail or "complete"))
    end
    state.probeCleanup = nil
    saveState()
end

function NBTX.probeCleanupStatus()
    local p = state.probeCleanup
    if type(p) ~= "table" then return nil, 0 end
    local remaining = math.max(0,
        (tonumber(p.exported) or 0) - (tonumber(p.imported) or 0))
    return p, remaining
end

function NBTX.tryProbeCleanup()
    local p, remaining = NBTX.probeCleanupStatus()
    if not p then return true, "none" end

    local itemName = tostring(p.item or "")
    if itemName == "" or itemName == "?" or remaining <= 0 then
        NBTX.clearProbeCleanup("invalid/complete cleanup state")
        return true, "cleared"
    end

    local observed = chestItemCount(itemName)
    if observed ~= nil and observed <= 0 then
        -- Manual removal is a valid cleanup action. Source extraction was
        -- already proven when the probe export succeeded.
        NBTX.clearProbeCleanup("probe item no longer present in barrel")
        health.transfer = true
        health.message = "Probe cleanup completed"
        return true, "barrel cleared"
    end

    local attemptCount = remaining
    if observed ~= nil then attemptCount = math.min(attemptCount, observed) end
    if attemptCount <= 0 then
        NBTX.clearProbeCleanup("nothing left to return")
        return true, "nothing left"
    end

    local moved, err = retryImport(NBTX.importToPlayer, itemName, attemptCount, "player")
    moved = tonumber(moved) or 0
    if moved > 0 then
        p.imported = (tonumber(p.imported) or 0) + moved
        p.lastAttempt = nowSeconds()
        p.lastError = nil
        saveState()
        local left = math.max(0, (tonumber(p.exported) or 0) - (tonumber(p.imported) or 0))
        if left <= 0 or chestItemCount(itemName) == 0 then
            NBTX.clearProbeCleanup("automatic return completed")
            health.transfer = true
            health.message = "RS probe item returned"
            return true, "returned"
        end
        remaining = left
    end

    p.attempts = (tonumber(p.attempts) or 0) + 1
    p.lastAttempt = nowSeconds()
    p.lastError = tostring(err or "Player RS probe return moved 0")
    saveState()

    health.transfer = false
    health.message = "PROBE ITEM STUCK: " .. tostring(itemName) ..
        " x" .. tostring(remaining)
    return false, p.lastError
end

local function recoverPendingTransfer()
    local p = state.pending
    if type(p) ~= "table" then return true end

    local kind = p.kind or "supply"
    health.transfer = false
    health.message = kind == "overflow" and "Recovering overflow return" or "Recovering pending transfer"

    local requestId = p.requestId
    local itemName = p.item
    local planned = tonumber(p.planned) or 0
    local exported = tonumber(p.exported) or 0
    local imported = tonumber(p.imported) or 0

    -- v2.35 migration/recovery: once a probe has exported successfully, the
    -- source is proven healthy. Move its return leg out of state.pending so a
    -- stranded probe cannot keep every request waiting behind a transaction
    -- whose only purpose is cleanup.
    if kind == "probe" and exported > 0 then
        if NBTX.isRSSafetyLatched() then
            NBTX.clearRSSafety("persisted probe already extracted: " .. tostring(itemName))
        end
        NBTX.setProbeCleanup(
            itemName,
            exported,
            imported,
            p.lastError or "migrated persisted probe return"
        )
        state.pending = nil
        saveState()
        health.message = "RS source healthy; probe cleanup pending"
        writeLog("RS PROBE pending transaction migrated to cleanup item=" ..
            tostring(itemName) .. " exported=" .. tostring(exported) ..
            " imported=" .. tostring(imported))
        return true
    end

    if not itemName or planned <= 0 or (kind == "supply" and not requestId) then
        clearPending("invalid pending transaction")
        health.transfer = true
        return true
    end

    -- If the modem-connected barrel can be inspected and is empty, recovery
    -- must consider the persisted stage. An empty barrel during "importing"
    -- can confirm the destination already consumed the item; an empty barrel
    -- during "exported" is ambiguous and must NOT be auto-credited or resent.
    local verifiedEmpty = chestIsEmpty()
    if verifiedEmpty == true then
        local stage = tostring(p.stage or "")
        local ambiguous = math.max(0, exported - imported)

        if stage == "importing" and exported > 0 and ambiguous > 0 then
            -- We had already started the destination import and the monitored
            -- barrel is now empty. This is the crash window after the import
            -- completed but before p.imported was persisted. Credit only this
            -- stage; do NOT blindly clear an exported-but-never-imported item.
            if kind == "supply" then
                finishImportedAmount(requestId, itemName, ambiguous)
                recordTransferHistory("P>WH", itemName, ambiguous, requestId, "recovered-empty")
            elseif kind == "overflow" then
                recordTransferHistory("WH>P", itemName, ambiguous, nil, "recovered-empty")
            elseif kind == "probe" then
                -- Probe item was being returned to Player RS; no colony accounting.
                NBTX.clearRSSafety("recovered completed extraction probe")
            end
            p.imported = exported
            saveState()
            clearPending("empty barrel confirms importing stage completed")
            health.transfer = true
            health.message = kind == "probe" and "Recovered RS probe" or "Recovered completed import"
            writeLog("RECOVER credited importing-stage empty barrel kind=" ..
                tostring(kind) .. " item=" .. tostring(itemName) ..
                " amount=" .. tostring(ambiguous))
            return true
        elseif stage == "exported" and exported > imported then
            -- The source export was persisted, but destination import had not
            -- yet begun. An empty barrel here is ambiguous (manual removal,
            -- external automation, or inconsistent inventory state). Refuse to
            -- duplicate the shipment automatically.
            health.transfer = false
            health.message = "TRANSFER UNKNOWN: " .. tostring(itemName) ..
                " - exported item missing before import"
            p.attempts = (tonumber(p.attempts) or 0) + 1
            p.lastError = "barrel empty in exported stage; destination import unproven"
            p.lastAttempt = nowSeconds()
            saveState()
            return false
        else
            clearPending("barrel verified empty; no completed import to credit")
            health.transfer = true
            health.message = "Cleared stale transfer; barrel is empty"
            writeLog("RECOVER verified empty barrel; cleared pending " ..
                tostring(kind) .. " item=" .. tostring(itemName) ..
                " stage=" .. tostring(stage))
            return true
        end
    end

    local remainingInChest
    if exported > 0 then
        remainingInChest = math.max(0, exported - imported)
    else
        local observed = chestItemCount(itemName)

        if observed ~= nil then
            if observed <= 0 then
                clearPending("stale pre-export transaction; barrel is empty")
                health.transfer = true
                health.message = "Cleared stale transfer; retrying request"
                return true
            end

            p.exported = math.min(planned, observed)
            exported = p.exported
            remainingInChest = math.max(0, exported - imported)
            p.stage = "exported"
            saveState()
            writeLog("RECOVER reconstructed exported=" .. tostring(exported) ..
                " from monitored barrel for " .. tostring(itemName))
        else
            -- Without a modem on the barrel we cannot prove whether an
            -- interrupted export happened. Do not pretend planned==exported.
            if tostring(p.stage) == "prepared" then
                clearPending("stale prepared transaction")
                health.transfer = true
                health.message = "Cleared stale prepared transfer"
                return true
            end

            health.transfer = false
            health.message = "TRANSFER UNKNOWN: " .. tostring(itemName) ..
                " - barrel modem needed for crash recovery"
            p.attempts = (tonumber(p.attempts) or 0) + 1
            p.lastError = "export quantity unknown; transfer barrel not connected to CC"
            p.lastAttempt = nowSeconds()
            saveState()
            return false
        end
    end

    if remainingInChest <= 0 then
        clearPending("nothing remains in transfer chest")
        if kind == "probe" then
            NBTX.clearRSSafety("probe recovery found nothing remaining in barrel")
        end
        health.transfer = true
        return true
    end

    p.stage = "importing"
    p.lastAttempt = nowSeconds()
    saveState()

    local moved, err
    if kind == "overflow" or kind == "probe" then
        moved, err = retryImport(NBTX.importToPlayer, itemName, remainingInChest, "player")
    else
        moved, err = retryImport(NBTX.importToColony, itemName, remainingInChest, "colony")
    end

    if moved > 0 then
        if kind == "supply" then
            finishImportedAmount(requestId, itemName, moved)
            recordTransferHistory("P>WH", itemName, moved, requestId, "recovered")
        elseif kind == "overflow" then
            recordTransferHistory("WH>P", itemName, moved, nil, "recovered")
        end
        p.imported = imported + moved

        if exported <= 0 then
            p.exported = p.imported
            exported = p.exported
        end

        writeLog("RECOVER imported " .. moved .. " " .. itemName ..
            ((kind == "overflow" or kind == "probe")
                and " into player network" or " into colony network"))
        saveState()
    end

    exported = tonumber(p.exported) or 0
    imported = tonumber(p.imported) or 0

    if exported > 0 and imported >= exported then
        clearPending("recovery completed")
        health.transfer = true
        if kind == "overflow" then
            health.message = "Overflow return recovered"
        elseif kind == "probe" then
            health.message = "RS extraction probe recovered"
            NBTX.clearRSSafety("recovered probe transaction completed")
        else
            health.message = "Pending transfer recovered"
        end
        return true
    end

    local observed = chestItemCount(itemName)
    if observed ~= nil and observed == 0 and exported > imported and p.stage == "importing" then
        local ambiguous = exported - imported
        if kind == "supply" then
            finishImportedAmount(requestId, itemName, ambiguous)
            recordTransferHistory("P>WH", itemName, ambiguous, requestId, "recovered-empty")
        elseif kind == "overflow" then
            recordTransferHistory("WH>P", itemName, ambiguous, nil, "recovered-empty")
        elseif kind == "probe" then
            NBTX.clearRSSafety("empty barrel confirms probe return completed")
        end
        p.imported = exported
        writeLog("RECOVER credited " .. ambiguous .. " " .. itemName .. " after empty-chest crash check")
        saveState()
        clearPending("empty chest confirms import likely completed")
        health.transfer = true
        health.message = "Recovered completed import"
        return true
    end

    p.attempts = (tonumber(p.attempts) or 0) + 1
    p.lastError = err or "import returned 0"
    p.lastAttempt = nowSeconds()
    saveState()

    health.transfer = false
    local remaining = math.max(0, (tonumber(p.exported) or planned) - (tonumber(p.imported) or 0))
    if kind == "overflow" then
        health.message = "BLOCKED chest->player: " .. tostring(itemName) .. " x" .. tostring(remaining)
    elseif kind == "probe" then
        health.message = "BLOCKED RS probe return->player: " .. tostring(itemName) .. " x" .. tostring(remaining)
    else
        health.message = "BLOCKED chest->colony: " .. tostring(itemName) .. " x" .. tostring(remaining)
    end
    writeLog("RECOVER import blocked item=" .. tostring(itemName) ..
        " remaining=" .. tostring(remaining) ..
        " attempt=" .. tostring(p.attempts) ..
        " reason=" .. tostring(p.lastError))
    return false
end

local function performTransfer(requestId, itemName, amount, candidate)
    amount = math.min(roundDown(amount), CONFIG.maxTransferChunk)
    if amount <= 0 then return 0, "Nothing to transfer", "not_started" end

    if state.pending then
        return 0, "Another transfer is pending", "not_started"
    end

    -- If the chest is visible as a CC inventory, refuse to start a new
    -- transaction while it contains anything. This prevents mixing items.
    local empty = chestIsEmpty()
    if empty == false then
        health.transfer = false
        local contents = chestContentsSummary(2) or "unknown contents"
        health.message = "BARREL BLOCKED: " .. tostring(contents)
        writeLog(health.message)
        return 0, health.message, "not_started"
    elseif empty == nil then
        writeLog("Barrel inspection unavailable; continuing directional transfer")
    end

    local p = {
        kind = "supply",
        requestId = requestId,
        item = itemName,
        planned = amount,
        exported = 0,
        imported = 0,
        stage = "prepared",
        started = nowSeconds(),
    }
    state.pending = p
    saveState()

    p.stage = "exporting"
    saveState()

    local exported, exportErr =
        NBTX.exportFromPlayer(itemName, amount, candidate)
    exported = tonumber(exported) or 0

    if exported <= 0 then
        clearPending("player export returned 0")
        local fresh = candidate
            and NBTX.getRSAmountByCandidate(playerRS, candidate)
            or getRSAmount(playerRS, itemName)
        health.transfer = false
        health.message = "SOURCE BLOCKED: " .. tostring(itemName) ..
            " stock=" .. tostring(fresh) ..
            " A->barrel moved=0"
        writeLog(health.message .. " err=" .. tostring(exportErr or "none"))
        return 0, exportErr or ("Player RS reports " .. tostring(fresh) ..
            " but exported 0 to barrel"), "source_export_zero"
    end

    p.exported = exported
    p.stage = "exported"
    saveState()
    learnStackSizeFromChest(itemName)
    writeLog("EXPORT A->BARREL " .. exported .. " " .. itemName ..
        " request=" .. requestId ..
        " mode=" .. ((CONFIG.usePeripheralTransfer and CONFIG.transferChestName)
            and "peripheral" or "directional"))

    -- Match the known-good diagnostic behavior: let the barrel and the
    -- second RS network observe the inventory change before importing.
    transferSleep(CONFIG.transferSettleDelay)

    p.stage = "importing"
    saveState()

    local imported, importErr = retryImport(NBTX.importToColony, itemName, exported, "colony")
    imported = tonumber(imported) or 0

    if imported > 0 then
        p.imported = imported
        finishImportedAmount(requestId, itemName, imported)
        recordTransferHistory("P>WH", itemName, imported, requestId, "supply")
        saveState()
        writeLog("IMPORT BARREL->B " .. imported .. " " .. itemName ..
        " request=" .. requestId ..
        " mode=" .. ((CONFIG.usePeripheralTransfer and CONFIG.transferChestName)
            and "peripheral" or "directional"))
    end

    if imported >= exported then
        clearPending("transaction completed")
        health.transfer = true
        return imported, nil, "ok"
    end

    -- Leave pending transaction on disk. The next cycle will retry the
    -- chest -> colony leg before doing any more player exports.
    health.transfer = false
    local left = math.max(0, exported - imported)
    health.message = "TRANSFER " .. tostring(itemName) ..
        " barrel->colony " .. tostring(imported) .. "/" .. tostring(exported) ..
        " (" .. tostring(left) .. " left)"
    saveState()
    return imported, importErr or "Partial/blocked colony import", "source_export_ok"
end

local function performOverflowReturn(itemName, amount)
    amount = math.min(roundDown(amount), tonumber(CONFIG.maxOverflowChunk) or 64)
    if amount <= 0 then return 0, "Nothing to return" end
    if state.pending then return 0, "Another transfer is pending" end

    local empty = chestIsEmpty()
    if empty == false then
        health.transfer = false
        local contents = chestContentsSummary(2) or "unknown contents"
        health.message = "BARREL BLOCKED: " .. tostring(contents)
        writeLog(health.message)
        return 0, health.message
    elseif empty == nil then
        writeLog("Barrel inspection unavailable; continuing directional transfer")
    end

    local p = {
        kind = "overflow",
        item = itemName,
        planned = amount,
        exported = 0,
        imported = 0,
        stage = "prepared",
        started = nowSeconds(),
    }
    state.pending = p
    saveState()

    p.stage = "exporting"
    saveState()

    local exported, exportErr = NBTX.exportFromColony(itemName, amount)
    exported = tonumber(exported) or 0
    if exported <= 0 then
        clearPending("colony overflow export returned 0")
        local fresh = getRSAmount(colonyRS, itemName)
        health.transfer = false
        health.message = "OVERFLOW SOURCE BLOCKED: " .. tostring(itemName) ..
            " stock=" .. tostring(fresh) ..
            " B->barrel moved=0"
        writeLog(health.message .. " err=" .. tostring(exportErr or "none"))
        return 0, exportErr or ("Colony RS reports " .. tostring(fresh) ..
            " but exported 0 to barrel")
    end

    p.exported = exported
    p.stage = "exported"
    saveState()
    learnStackSizeFromChest(itemName)
    writeLog("OVERFLOW B->CHEST " .. exported .. " " .. itemName)

    transferSleep(CONFIG.transferSettleDelay)

    p.stage = "importing"
    saveState()

    local imported, importErr = retryImport(NBTX.importToPlayer, itemName, exported, "player")
    imported = tonumber(imported) or 0
    if imported > 0 then
        p.imported = imported
        recordTransferHistory("WH>P", itemName, imported, nil, "overflow")
        saveState()
        writeLog("OVERFLOW CHEST->A " .. imported .. " " .. itemName)
    end

    if imported >= exported then
        clearPending("overflow transaction completed")
        health.transfer = true
        return imported, nil
    end

    health.transfer = false
    local left = math.max(0, exported - imported)
    health.message = "OVERFLOW TRANSFER " .. tostring(itemName) ..
        " barrel->player " .. tostring(imported) .. "/" .. tostring(exported) ..
        " (" .. tostring(left) .. " left)"
    saveState()
    return imported, importErr or "Partial/blocked player import"
end
-- Prove Player-RS source extraction independently of MineColonies requests.
-- Pick an ordinary, non-NBT item with stock, export exactly one to the barrel,
-- then import it back to Player RS. The probe itself is persisted as a pending
-- transaction, so a crash cannot strand the test item without recovery data.
function NBTX.runRSSafetyProbe()
    if not NBTX.isRSSafetyLatched() then return true, "not latched" end
    local due, wait = NBTX.rsSafetyProbeStatus()
    if not due then return false, "probe in " .. tostring(wait) .. "s" end
    if state.pending then return false, "transfer pending" end

    local empty = chestIsEmpty()
    if empty == false then return false, "barrel is not empty" end
    if empty == nil then return false, "barrel inspection unavailable" end

    local ok, items = safeCall(playerRS, "listItems")
    if not ok or type(items) ~= "table" then
        return false, "Player RS listItems unavailable"
    end

    -- Never use the item which caused the current global latch as the generic
    -- health test. Prefer a completely clean item first. If old per-item
    -- desync records cover everything else, fall back to another ordinary
    -- stocked item rather than leaving the countdown stuck at NOW forever.
    local safety = NBTX.rsSafetyState()
    local latchItem = tostring(safety.item or "")
    local blockedProbeNames = {}
    state.rsDesync = state.rsDesync or {}
    for _, entry in pairs(state.rsDesync) do
        if type(entry) == "table" and type(entry.item) == "string" then
            blockedProbeNames[entry.item] = true
        end
    end

    local function chooseProbe(allowHistoricalDesync)
        local bestName = nil
        local bestAmount = -1
        for _, item in pairs(items) do
            local amount = type(item) == "table" and (tonumber(item.amount) or 0) or 0
            local name = type(item) == "table" and item.name or nil
            if type(name) == "string"
                and name ~= ""
                and name ~= latchItem
                and amount > 0
                and not itemHasNBT(item)
                and (allowHistoricalDesync or not blockedProbeNames[name])
                and amount > bestAmount then
                bestName = name
                bestAmount = amount
            end
        end
        return bestName, bestAmount
    end

    local probeItem, probeAmount = chooseProbe(false)
    if not probeItem then
        probeItem, probeAmount = chooseProbe(true)
        if probeItem then
            writeLog("RS SAFETY PROBE fallback using historically desynced item=" ..
                tostring(probeItem) .. " stock=" .. tostring(probeAmount))
        end
    end
    if not probeItem then
        NBTX.noteRSSafetyProbeAttempt("no-candidate")
        return false, "no ordinary stocked item other than latch item available for probe"
    end

    state.pending = {
        kind = "probe",
        item = probeItem,
        planned = 1,
        exported = 0,
        imported = 0,
        stage = "prepared",
        started = nowSeconds(),
    }
    saveState()
    state.pending.stage = "exporting"
    saveState()

    local exported, exportErr = NBTX.exportFromPlayer(probeItem, 1, nil)
    exported = tonumber(exported) or 0
    -- Update the timer only after an actual export call was made.
    NBTX.noteRSSafetyProbeAttempt(probeItem)

    if exported <= 0 then
        clearPending("RS safety probe export returned 0")
        local reported = getRSAmount(playerRS, probeItem)
        NBTX.markRSDesync({ name = probeItem }, reported, 1,
            exportErr or "global safety probe export returned 0", true)
        return false, "probe extraction returned 0"
    end

    state.pending.exported = exported
    state.pending.stage = "importing"
    saveState()
    writeLog("RS SAFETY PROBE EXTRACTED " .. tostring(exported) .. " " .. tostring(probeItem))

    -- Extraction itself is now proven. Clear the global source/crafting latch
    -- before returning the item; a failed return remains a normal pending
    -- transfer and prevents new work until recovery finishes.
    NBTX.clearRSSafety("one-item Player-RS extraction probe succeeded: " .. tostring(probeItem))

    local imported, importErr = retryImport(NBTX.importToPlayer, probeItem, exported, "player")
    imported = tonumber(imported) or 0
    if imported > 0 then
        state.pending.imported = imported
        saveState()
    end
    if imported >= exported then
        clearPending("RS safety probe returned to Player RS")
        health.transfer = true
        health.message = "RS extraction probe passed"
        writeLog("RS SAFETY PROBE PASSED item=" .. tostring(probeItem))
        return true, "probe passed"
    end

    -- The source-health decision is complete. A failed return is cleanup, not
    -- an RS source fault and not a normal pending transfer.
    NBTX.setProbeCleanup(
        probeItem,
        exported,
        imported,
        importErr or "probe return import returned 0"
    )
    state.pending = nil
    saveState()
    health.transfer = false
    health.message = "PROBE ITEM STUCK: " .. tostring(probeItem) ..
        " x" .. tostring(math.max(0, exported - imported))
    return true, "source healthy; probe cleanup pending"
end


--------------------------------------------------------------------------
-- Dashboard row building
--------------------------------------------------------------------------

local STATUS_PRIORITY = {
    ERROR = 1,
    ["RS DESYNC"] = 2,
    ["RS PAUSED"] = 3,
    BLOCKED = 4,
    MISSING = 4,
    PARTIAL = 5,
    CRAFTING = 6,
    READY = 7,
    TRANSFER = 8,
    WAITING = 9,
    SUPPLIED = 10,
    ["IN STOCK"] = 11,
}

local STATUS_COLORS = {
    ERROR = colors.red,
    ["RS DESYNC"] = colors.orange,
    ["RS PAUSED"] = colors.yellow,
    BLOCKED = colors.red,
    MISSING = colors.red,
    PARTIAL = colors.yellow,
    CRAFTING = colors.lightBlue,
    READY = colors.lime,
    TRANSFER = colors.cyan,
    WAITING = colors.orange,
    SUPPLIED = colors.green,
    ["IN STOCK"] = colors.green,
}

local function newStats()
    return {
        active = 0,
        supplied = 0,
        missing = 0,
        crafting = 0,
        ready = 0,
        errors = 0,
    }
end

local function resetStats()
    stats = newStats()
end

local function addRow(row)
    -- While a scan is running, build the next dashboard completely off-screen.
    -- monitorRefreshLoop() continues rendering the previous complete snapshot.
    local rows = dashboardBuildRows or dashboardRows
    local targetStats = statsBuild or stats

    rows[#rows + 1] = row
    targetStats.active = targetStats.active + 1
    if row.status == "SUPPLIED" or row.status == "IN STOCK" then targetStats.supplied = targetStats.supplied + 1 end
    if row.status == "MISSING" then targetStats.missing = targetStats.missing + 1 end
    if row.status == "CRAFTING" then targetStats.crafting = targetStats.crafting + 1 end
    if row.status == "READY" or row.status == "TRANSFER" then targetStats.ready = targetStats.ready + 1 end
    if row.status == "ERROR" or row.status == "BLOCKED" or row.status == "RS DESYNC" then
        targetStats.errors = targetStats.errors + 1
    end
end

local function sortDashboardRows(rows)
    rows = rows or dashboardRows
    table.sort(rows, function(a, b)
        local pa = STATUS_PRIORITY[a.status] or 99
        local pb = STATUS_PRIORITY[b.status] or 99
        if pa ~= pb then return pa < pb end
        return tostring(a.displayName):lower() < tostring(b.displayName):lower()
    end)
end

local function buildSettingsRows()
    local byName = {}

    if colonyRS then
        local ok, items = safeCall(colonyRS, "listItems")
        if ok and type(items) == "table" then
            for _, item in pairs(items) do
                if type(item) == "table" and type(item.name) == "string" and item.name ~= "" then
                    if not itemHasNBT(item) then
                        local entry = byName[item.name]
                        if not entry then
                            entry = {
                                item = item.name,
                                displayName = item.displayName or item.name,
                                current = 0,
                            }
                            byName[item.name] = entry
                        end
                        entry.current = entry.current + (tonumber(item.amount) or 0)
                    end
                end
            end
        end
    end

    for _, row in ipairs(dashboardRows) do
        if row.item and not byName[row.item] then
            byName[row.item] = {
                item = row.item,
                displayName = row.displayName or row.item,
                current = tonumber(row.warehouseStock) or 0,
            }
        end
    end

    state.settings = state.settings or { targets = {}, stackSizes = {} }
    state.settings.targets = state.settings.targets or {}
    for itemName, _ in pairs(state.settings.targets) do
        if not byName[itemName] then
            local info = getRSItem(playerRS, itemName) or getRSItem(colonyRS, itemName)
            byName[itemName] = {
                item = itemName,
                displayName = info and info.displayName or itemName,
                current = getRSAmount(colonyRS, itemName),
            }
        end
    end

    settingsRows = {}
    for itemName, entry in pairs(byName) do
        local stackSize, stackKnown = getKnownStackSize(itemName)
        settingsRows[#settingsRows + 1] = {
            item = itemName,
            displayName = entry.displayName or itemName,
            target = getWarehouseTarget(itemName),
            overflow = getOverflowAt(itemName),
            current = tonumber(entry.current) or 0,
            stackSize = stackSize,
            stackKnown = stackKnown,
        }
    end

    table.sort(settingsRows, function(a, b)
        return tostring(a.displayName):lower() < tostring(b.displayName):lower()
    end)
end

-- Return excess Warehouse stock to Player RS.
--
-- Earlier versions excluded an item from overflow whenever it appeared in ANY
-- active MineColonies request. Common building materials therefore tended to
-- stay in the Warehouse forever. v1.3 instead protects only the quantity that
-- is still actively needed, while allowing genuine surplus to return.
--
-- Baseline overflow remains exactly what the Settings page shows:
--     target + two item stacks
-- Active demand is an additional temporary safety reserve.
local function getActiveProtectedDemand()
    local demand = {}
    for _, row in ipairs(dashboardRows) do
        if row.item then
            local remaining = math.max(0, tonumber(row.remaining) or 0)
            -- Requests already satisfied by the program / Warehouse do not
            -- need additional protection.
            if row.status == "SUPPLIED" or row.status == "IN STOCK" then
                remaining = 0
            end
            if remaining > 0 then
                demand[row.item] = (demand[row.item] or 0) + remaining
            end
        end
    end
    return demand
end

local function processWarehouseOverflow()
    if not (state.settings and state.settings.overflowEnabled == true) then return 0, "disabled" end
    if state.pending then return 0, "pending transfer" end

    local activeDemand = getActiveProtectedDemand()
    local best = nil

    for _, row in ipairs(settingsRows) do
        local protectedDemand = activeDemand[row.item] or 0
        local safeFloor = row.target + protectedDemand

        -- The player's configured overflow threshold remains Target + 2 stacks.
        -- If there is active demand, never drain below Target + that demand.
        if row.current > row.overflow then
            local excess = row.current - safeFloor
            if excess > 0 and (not best or excess > best.excess) then
                best = {
                    row = row,
                    excess = excess,
                    protectedDemand = protectedDemand,
                    safeFloor = safeFloor,
                }
            end
        end
    end

    if not best then return 0, "no eligible overflow" end

    local amount = math.min(best.excess, tonumber(CONFIG.maxOverflowChunk) or 64)
    local moved, err = performOverflowReturn(best.row.item, amount)
    if moved > 0 then
        health.message = "Returned " .. moved .. " " .. best.row.displayName .. " to player RS"
        writeLog("OVERFLOW returned " .. moved .. " " .. best.row.item ..
            " current=" .. tostring(best.row.current) ..
            " target=" .. tostring(best.row.target) ..
            " protectedDemand=" .. tostring(best.protectedDemand))
        buildSettingsRows()
    elseif err then
        writeLog("OVERFLOW blocked " .. best.row.item .. ": " .. tostring(err))
    end
    return moved, err
end

--------------------------------------------------------------------------
-- Request processing
--------------------------------------------------------------------------

local function effectiveRemaining(requested, supplied, warehouseStock)
    local remaining = math.max(0, requested - supplied)
    if CONFIG.subtractWarehouseStock then
        remaining = math.max(0, remaining - warehouseStock)
    end
    return remaining
end

local function processSingleRequest(request)
    local id = request.id
    local requested = getRequestedCount(request)
    local rs = requestStateFor(id)

    if requested <= 0 then
        addRow({
            id = id,
            displayName = request.name or "Unknown request",
            requested = 0,
            supplied = rs.supplied,
            playerStock = 0,
            warehouseStock = 0,
            status = "ERROR",
            message = "Request quantity is 0",
        })
        return
    end

    local supplied = tonumber(rs.supplied) or 0
    local provisionalRemaining = math.max(0, requested - supplied)
    local candidate = chooseCandidate(request, rs, provisionalRemaining)

    if not candidate then
        local reason = "No usable item candidate"

        if type(request.items) ~= "table" then
            reason = "Request has no item candidate list"
        else
            local itemCount = 0
            local rejectedNBT = 0

            for _, item in pairs(request.items) do
                itemCount = itemCount + 1
                if requestCandidateRejectionReason(item) ==
                    "meaningful/unsupported NBT" then
                    rejectedNBT = rejectedNBT + 1
                end
            end

            if itemCount > 0 and rejectedNBT == itemCount then
                reason = "All candidates rejected by NBT safety"
            elseif itemCount == 0 then
                reason = "Request item candidate list is empty"
            end
        end

        local requestedToolClass = NBTX.requestToolClass(request)
        if requestedToolClass and reason == "No usable item candidate" then
            reason = "No usable " .. tostring(requestedToolClass) .. " candidate"
        end

        addRow({
            id = id,
            displayName = request.name or request.desc or "Unsupported request",
            requested = requested,
            supplied = supplied,
            playerStock = 0,
            warehouseStock = 0,
            status = "ERROR",
            message = reason,
        })

        writeLog(
            "REQUEST CANDIDATE ERROR id=" .. tostring(id) ..
            " name=" .. tostring(request.name or request.desc or "?") ..
            " reason=" .. tostring(reason)
        )
        return
    end

    rs.item = candidate.name
    rs.displayName = candidate.displayName

    local playerStock = candidate.playerStock or NBTX.getRSAmountByCandidate(playerRS, candidate)
    local warehouseStock = candidate.warehouseStock or NBTX.getRSAmountByCandidate(colonyRS, candidate)
    local remaining = effectiveRemaining(requested, supplied, warehouseStock)

    local row = {
        id = id,
        item = candidate.name,
        displayName = candidate.displayName or candidate.name,
        requested = requested,
        supplied = supplied,
        remaining = remaining,
        playerStock = playerStock,
        warehouseStock = warehouseStock,
        target = request.target,
        requestState = request.state,
        status = "WAITING",
        message = "",
    }

    -- Log the selected request option whenever that decision changes.
    local decisionKey = table.concat({
        tostring(candidate.name),
        tostring(candidate.rawCraftable == true),
        tostring(autoCraftEnabled()),
    }, "|")

    if rs.lastDecisionKey ~= decisionKey then
        rs.lastDecisionKey = decisionKey
        writeLog(
            "REQUEST DECISION id=" .. tostring(id) ..
            " item=" .. tostring(candidate.name) ..
            " playerStock=" .. tostring(playerStock) ..
            " warehouseStock=" .. tostring(warehouseStock) ..
            " craftable=" .. tostring(candidate.rawCraftable == true) ..
            " craftSource=" .. tostring(candidate.craftSource or "?") ..
            " autoCraft=" .. tostring(autoCraftEnabled()) ..
            " pristineRequired=" .. tostring(candidate.requiresPristine == true) ..
            " rejectedEquipmentStock=" .. tostring(candidate.rejectedEquipmentStock or 0)
        )
        saveState()
    end

    if remaining <= 0 then
        if supplied >= requested then
            row.status = "SUPPLIED"
            row.message = "Program has supplied request"
        else
            row.status = "IN STOCK"
            row.message = "Warehouse stock covers request"
        end
        addRow(row)
        return
    end

    if state.pending and state.pending.requestId == id then
        row.status = "TRANSFER"
        local p = state.pending
        local exported = tonumber(p.exported) or 0
        local imported = tonumber(p.imported) or 0
        local left = math.max(0, exported - imported)

        if exported > 0 then
            row.message = "Barrel->Colony " .. tostring(imported) ..
                "/" .. tostring(exported) .. " (" .. tostring(left) .. " left)"
        else
            row.message = "Preparing Player->Barrel"
        end

        addRow(row)
        return
    end

    -- The system intentionally uses one transfer barrel transaction at a time.
    -- A pending transaction for some OTHER request is not a failure of this
    -- request, so report WAITING rather than BLOCKED.
    if state.pending then
        row.status = "WAITING"
        local pendingItem = tostring(state.pending.item or "another item")
        row.message = "Waiting for transfer of " .. pendingItem
        addRow(row)
        return
    end

    ------------------------------------------------------------------
    -- Global RS source-safety latch. While active, normal requests may not
    -- export from Player RS and may not autocraft. scanAndProcess() owns the
    -- independent one-item extraction/return probe.
    ------------------------------------------------------------------
    if NBTX.isRSSafetyLatched() then
        local due, wait = NBTX.rsSafetyProbeStatus()
        local safety = NBTX.rsSafetyState()
        local desyncEntry = select(1, NBTX.getRSDesync(candidate))

        -- Only the exact item/variant that failed extraction is itself
        -- desynced. Other requests are paused by the global safety latch,
        -- but labeling them RS DESYNC makes it look as though every item
        -- failed its own extraction test. Keep the safety behavior global
        -- while reporting the per-request cause accurately.
        if desyncEntry then
            local _, _, itemDue, itemWait = NBTX.getRSDesync(candidate)
            row.status = "RS DESYNC"
            row.rsCountdown = itemDue and 0 or itemWait
            row.message = "Player RS extraction failed for this item; " ..
                (due and "generic recovery probe pending" or ("generic probe in " .. tostring(wait) .. "s"))
        else
            row.status = "RS PAUSED"
            row.rsCountdown = due and 0 or wait
            row.message = due
                and "Global RS safety pause; recovery probe pending"
                or ("Global RS safety pause; probe in " .. tostring(wait) .. "s")
        end

        health.transfer = false
        health.message = "RS SAFETY PAUSE: " .. tostring(safety.reason or candidate.name)
        addRow(row)
        return
    end

    ------------------------------------------------------------------
    -- Per-item source desync quarantine. A successful generic RS probe may
    -- have proven the bridge healthy while one particular item still refuses
    -- export. Keep only that item out of service until its own retry timer is
    -- due; do NOT pause unrelated requests.
    ------------------------------------------------------------------
    local itemDesync, _, itemRetryDue, itemRetryWait = NBTX.getRSDesync(candidate)
    if itemDesync then
        if playerStock <= 0 then
            -- The stock that originally failed extraction is no longer present.
            -- The request may now legitimately need crafting, so retire the stale
            -- source-desync record instead of blocking that craft forever.
            NBTX.clearRSDesync(candidate, "reported source stock no longer present")
        elseif not itemRetryDue then
            row.status = "RS DESYNC"
            row.rsCountdown = itemRetryWait
            row.message = "Item-specific Player RS export failure; retry in " ..
                tostring(itemRetryWait) .. "s" ..
                (candidate.craftable and "; craftable once stored stock is gone" or "")
            addRow(row)
            return
        else
            row.rsCountdown = 0
            writeLog("RS ITEM RETRY due item=" .. tostring(candidate.name) ..
                " stock=" .. tostring(playerStock))
        end
    end

    ------------------------------------------------------------------
    -- A stranded health-probe item occupies the shared transfer barrel, so
    -- stock transfers cannot safely start until cleanup succeeds. This is NOT
    -- an RS source desync: allow independent autocrafting to continue so work
    -- can be prepared while the probe item is being returned or manually removed.
    ------------------------------------------------------------------
    local probeCleanup, probeRemaining = NBTX.probeCleanupStatus()
    if probeCleanup and playerStock > 0 then
        local shortage = math.max(0, remaining - playerStock)
        if shortage > 0
            and autoCraftEnabled()
            and NBTX.isCandidateCraftable(candidate) then
            local craftOK, craftMessage, craftStarted =
                NBTX.submitCandidateCraft(candidate, shortage)
            if craftOK then
                row.status = "CRAFTING"
                row.message = "Probe item stuck in barrel; " ..
                    tostring(craftMessage or ("crafting " .. tostring(craftStarted or shortage))) ..
                    "; transfer waiting"
            else
                row.status = "BLOCKED"
                row.message = "Probe item stuck in barrel; transfer waiting; " ..
                    NBTX.craftErrorDisplay(craftMessage, "craft retry pending")
            end
        else
            row.status = "BLOCKED"
            row.message = "Probe item stuck in barrel: " ..
                tostring(probeCleanup.item or "?") .. " x" .. tostring(probeRemaining) ..
                "; transfer waiting"
        end
        addRow(row)
        return
    end

    ------------------------------------------------------------------
    -- v2.25 safety policy: if Player RS reports any stock, prove that the
    -- stock is actually extractable BEFORE asking Refined Storage to craft a
    -- shortage. This prevents an extraction-desync condition from feeding
    -- directly into CraftingCalculator. After a successful transfer below,
    -- the normal partial-stock path may safely start the remaining craft.
    ------------------------------------------------------------------
    if playerStock > 0 then
        row.status = supplied > 0 and "PARTIAL" or "READY"

        local transferAmount = math.min(remaining, playerStock, CONFIG.maxTransferChunk)
        local moved, err, transferState =
            performTransfer(id, candidate.name, transferAmount, candidate)

        row.supplied = tonumber(requestStateFor(id).supplied) or supplied
        row.remaining = effectiveRemaining(requested, row.supplied, NBTX.getRSAmountByCandidate(colonyRS, candidate))
        if candidate.requiresPristine then
            NBTX.populateCandidateAvailability(candidate)
            row.playerStock = candidate.playerStock or 0
            row.warehouseStock = candidate.warehouseStock or 0
        else
            row.playerStock = NBTX.getRSAmountByCandidate(playerRS, candidate)
            row.warehouseStock = NBTX.getRSAmountByCandidate(colonyRS, candidate)
        end

        if moved > 0 then
            if itemDesync then
                NBTX.clearRSDesync(candidate, "item export retry succeeded")
            end
            if row.remaining <= 0 then
                row.status = "SUPPLIED"
                row.message = "Imported into colony network"
            else
                local shortage = math.max(
                    0,
                    (tonumber(row.remaining) or 0) -
                    (tonumber(row.playerStock) or 0)
                )

                if shortage > 0
                    and autoCraftEnabled()
                    and NBTX.isCandidateCraftable(candidate) then

                    local craftOK, craftMessage, craftStarted =
                        NBTX.submitCandidateCraft(candidate, shortage)

                    if craftOK then
                        row.status = "CRAFTING"
                        row.message = "Moved " .. tostring(moved) ..
                            "; " .. tostring(craftMessage or
                                ("crafting " .. tostring(craftStarted or shortage)))
                    else
                        -- This is not a failed request. We already transferred
                        -- available stock, and the item remains craftable.
                        -- Leave it PARTIAL and retry crafting on later scans.
                        row.status = "PARTIAL"
                        row.message = "Moved " .. tostring(moved) ..
                            "; " .. NBTX.craftErrorDisplay(craftMessage, "craft retry pending")
                        writeLog(
                            "CRAFT RETRY pending item=" .. tostring(candidate.name) ..
                            " shortage=" .. tostring(shortage) ..
                            " reason=" .. tostring(craftMessage or "RS returned false")
                        )
                    end
                else
                    row.status = "PARTIAL"
                    row.message = "Transferred " .. moved
                end
            end
        else
            local freshStock
            if candidate.requiresPristine then
                local _, cleanStock = NBTX.getPristineEquipmentVariants(playerRS, candidate)
                freshStock = cleanStock
            else
                freshStock = NBTX.getRSAmountByCandidate(playerRS, candidate)
            end

            if transferState == "source_export_ok" then
                -- Player RS extraction succeeded. Any failure now is on the
                -- barrel -> colony side, so never classify it as RS source desync
                -- and never start another craft while the pending transfer exists.
                row.status = "TRANSFER"
                row.message = err or "Player extraction succeeded; colony import pending"

            elseif transferState == "not_started" then
                -- No source-export test actually occurred (barrel blocked, another
                -- transfer pending, etc.). Do not infer stock health and do not craft.
                row.status = "BLOCKED"
                row.message = err or "Transfer did not start; source extraction untested"
                health.message =
                    "BLOCKED " .. tostring(candidate.name) ..
                    ": " .. tostring(row.message)
                writeLog(
                    "TRANSFER BLOCKED id=" .. tostring(id) ..
                    " item=" .. tostring(candidate.name) ..
                    " playerStock=" .. tostring(freshStock) ..
                    " transferState=not_started" ..
                    " reason=" .. tostring(row.message)
                )

            elseif transferState == "source_export_zero" then
                -- playerStock was positive before this real export attempt. Any
                -- export=0 is therefore a source-health fault, even if the next
                -- inventory query fluctuates to zero. Never craft from this path.
                NBTX.markRSDesync(
                    candidate,
                    math.max(tonumber(freshStock) or 0, tonumber(playerStock) or 0),
                    remaining,
                    err or "Player RS export returned 0 after positive stock reading"
                )
                row.status = "RS DESYNC"
                local _, _, retryDue, retryWait = NBTX.getRSDesync(candidate)
                row.rsCountdown = retryDue and 0 or retryWait
                row.message = itemDesync and
                    "Item-specific Player RS export still returns 0; retry timer reset" or
                    "Player RS extraction moved 0; generic source probe scheduled"

            else
                -- Defensive fallback: an unknown transfer result must never cause
                -- a craft. Require a known source-export result first.
                row.status = "BLOCKED"
                row.message = "Unknown transfer state; source extraction unverified"
                health.transfer = false
                health.message = "BLOCKED " .. tostring(candidate.name) ..
                    ": " .. tostring(row.message)
                writeLog(
                    "TRANSFER BLOCKED id=" .. tostring(id) ..
                    " item=" .. tostring(candidate.name) ..
                    " playerStock=" .. tostring(freshStock) ..
                    " transferState=" .. tostring(transferState or "nil")
                )
            end
        end

        addRow(row)
        return
    end

    if autoCraftEnabled() and candidate.craftable then
        local craftOK, craftMessage, craftStarted =
            NBTX.submitCandidateCraft(candidate, remaining)

        if craftOK then
            row.status = "CRAFTING"
            local prefix = ""
            if candidate.requiresPristine and (tonumber(candidate.rejectedEquipmentStock) or 0) > 0 then
                prefix = "Stored copies damaged/enchanted; "
            end
            row.message = prefix .. (craftMessage or
                ("Crafting " .. tostring(craftStarted or remaining)))
        else
            -- The item is confirmed craftable. A temporary craftItem(false)
            -- result should be retried instead of marking the colony request
            -- failed/error.
            row.status = "WAITING"
            row.message = NBTX.craftErrorDisplay(
                craftMessage,
                "Craft start retry pending"
            )
            writeLog(
                "CRAFT RETRY item=" .. tostring(candidate.name) ..
                " need=" .. tostring(remaining) ..
                " reason=" .. tostring(craftMessage or "RS returned false")
            )
        end

        addRow(row)
        return
    end

    row.status = "MISSING"

    local rawCraftable, craftSource = NBTX.getCraftability(candidate.name)
    if rawCraftable and not autoCraftEnabled() then
        row.message = "Craftable, but AutoCraft is OFF"
    elseif rawCraftable then
        row.message = "Craftable option was not started"
    else
        row.message = "Not available/craftable in Player RS"
    end

    local noCraftKey = table.concat({
        tostring(candidate.name),
        tostring(rawCraftable),
        tostring(autoCraftEnabled()),
        tostring(craftSource),
    }, "|")

    if rs.lastNoCraftKey ~= noCraftKey then
        rs.lastNoCraftKey = noCraftKey
        writeLog(
            "NO CRAFT id=" .. tostring(id) ..
            " item=" .. tostring(candidate.name) ..
            " playerStock=" .. tostring(playerStock) ..
            " rawCraftable=" .. tostring(rawCraftable) ..
            " autoCraft=" .. tostring(autoCraftEnabled()) ..
            " source=" .. tostring(craftSource)
        )
        saveState()
    end

    addRow(row)
end

local function cleanupOldRequestState(activeIds)
    local cutoff = nowSeconds() - CONFIG.requestRetentionSeconds
    for id, rs in pairs(state.requests) do
        if not activeIds[id] and id ~= (state.pending and state.pending.requestId) then
            local lastSeen = tonumber(rs.lastSeen) or 0
            if lastSeen < cutoff then
                state.requests[id] = nil
            end
        end
    end
end

local function scanAndProcess()
    -- Double-buffer the request dashboard. The one-second render loop keeps
    -- showing the previous complete snapshot while this scan builds the next.
    dashboardBuildRows = {}
    statsBuild = newStats()

    if not refreshPeripherals() then
        health.message = "Waiting for required peripherals"
        dashboardBuildRows = nil
        statsBuild = nil
        return false
    end

    -- Probe-return cleanup is independent of RS source health. Retry it every
    -- scan; a manually emptied barrel is recognized immediately.
    if state.probeCleanup then
        NBTX.tryProbeCleanup()
    end

    if state.pending then
        if not recoverPendingTransfer() then
            -- Still show requests, but do not perform new A->chest exports.
            -- recoverPendingTransfer() sets a detailed health.message which
            -- identifies the direction/item that is actually blocked.
        end
    end

    -- A global RS safety fault is cleared by a real one-item Player-RS
    -- extraction test. Returning the probe item is cleanup and cannot re-latch
    -- or keep the source globally paused once extraction has succeeded.
    if NBTX.isRSSafetyLatched() and not state.pending then
        local probeOK, probeMessage = NBTX.runRSSafetyProbe()
        if not probeOK then
            health.transfer = false
            health.message = "RS SAFETY PAUSE: " .. tostring(probeMessage)
        end
    end

    local requests, err = getColonyRequests()
    if not requests then
        health.message = "Colony request read failed: " .. tostring(err)
        health.colony = false
        writeLog("ERROR " .. health.message)
        dashboardBuildRows = nil
        statsBuild = nil
        return false
    end

    local activeIds = {}

    for _, request in pairs(requests) do
        if isRequestActive(request) then
            activeIds[request.id] = true
            local ok, processErr = pcall(processSingleRequest, request)
            if not ok then
                writeLog("REQUEST ERROR id=" .. tostring(request.id) .. " " .. tostring(processErr))
                addRow({
                    id = request.id,
                    displayName = request.name or "Request error",
                    requested = getRequestedCount(request),
                    supplied = 0,
                    playerStock = 0,
                    warehouseStock = 0,
                    status = "ERROR",
                    message = tostring(processErr),
                })
            end
        end
    end

    cleanupOldRequestState(activeIds)

    -- Finish the new request snapshot off-screen, then atomically publish it.
    sortDashboardRows(dashboardBuildRows)
    dashboardRows = dashboardBuildRows
    stats = statsBuild
    dashboardBuildRows = nil
    statsBuild = nil

    buildSettingsRows()
    local overflowMoved = 0
    if not state.pending and not state.probeCleanup and not NBTX.isRSSafetyLatched() then
        overflowMoved = select(1, processWarehouseOverflow()) or 0
    end
    saveState()

    lastScanEpoch = nowSeconds()
    lastScanText = timeString()
    if not state.pending then
        local transferBlocked = nil
        local requestError = nil
        local desyncRow = nil

        for _, row in ipairs(dashboardRows) do
            if row.status == "RS DESYNC" and not desyncRow then
                desyncRow = row
            elseif row.status == "BLOCKED" and not transferBlocked then
                transferBlocked = row
            elseif row.status == "ERROR" and not requestError then
                requestError = row
            end
        end

        if NBTX.isRSSafetyLatched() then
            local safety = NBTX.rsSafetyState()
            health.transfer = false
            health.message = "RS SAFETY PAUSE: " .. tostring(safety.reason or
                "source extraction unproven")
        elseif state.probeCleanup then
            local cleanup, remaining = NBTX.probeCleanupStatus()
            health.transfer = false
            health.message = "PROBE ITEM STUCK: " ..
                tostring(cleanup and cleanup.item or "?") ..
                " x" .. tostring(remaining)
        elseif desyncRow then
            -- Per-item desync is isolated after the generic source probe passes.
            -- Keep overall transfer health online if the bridge itself is healthy.
            health.transfer = health.playerRS and health.colonyRS
            health.message = "ITEM RS DESYNC: " ..
                tostring(desyncRow.item or desyncRow.displayName or "?")
        elseif transferBlocked then
            health.transfer = false
            health.message = "BLOCKED: " ..
                tostring(transferBlocked.item or transferBlocked.displayName or "?") ..
                " - " .. tostring(transferBlocked.message or "unknown reason")
        else
            -- Hardware is not enough: transfer health remains ONLINE only when
            -- no source-safety or transfer failure was detected this scan.
            health.transfer = health.playerRS and health.colonyRS

            if requestError then
                health.message = "REQUEST ERROR: " ..
                    tostring(requestError.item or requestError.displayName or "?") ..
                    " - " .. tostring(requestError.message or "unknown reason")
            elseif overflowMoved <= 0 and health.transfer then
                health.message = "Online"
            end
        end
    end
    return true
end

--------------------------------------------------------------------------
-- Monitor rendering
--------------------------------------------------------------------------

-- Visual palette matched to the MineColonies Command Center:
-- black base, yellow title, blue headers/tabs, white body text,
-- cyan/light-blue accents, and lime/orange/red status colors.
local UI = SharedUI.theme()

local monitorUI = SharedUI.newMonitor({
    getMonitor = function() return monitor end,
    theme = UI,
    protected = true,
    onFailure = function()
        monitor = nil
        monitorResolvedName = nil
    end,
})

local function statusColor(status)
    return STATUS_COLORS[status] or colors.white
end

-- Keep the underlying row.status stable for sorting, colors, statistics, and
-- safety logic. Only the rendered label gets the live RS recovery countdown.
function NBTX.dashboardStatusText(status, width, row)
    status = tostring(status or "")
    width = math.max(1, math.floor(tonumber(width) or #status))

    if status == "RS PAUSED" or status == "RS DESYNC" then
        local due, wait
        if status == "RS DESYNC" and type(row) == "table" and row.rsCountdown ~= nil then
            wait = math.max(0, math.floor(tonumber(row.rsCountdown) or 0))
            due = wait <= 0
        else
            due, wait = NBTX.rsSafetyProbeStatus()
        end
        local suffix = due and " NOW" or (" " .. tostring(wait) .. "s")
        local full = status .. suffix
        if #full <= width then return full end

        local shortBase = status == "RS PAUSED" and "PAUSED" or "DESYNC"
        local short = shortBase .. suffix
        if #short <= width then return short end
        return Util.clip(short, width)
    end

    return Util.clip(status, width)
end

local monitorWrite = monitorUI.writeAt
local clearMonitor = monitorUI.clear
local monitorFillRow = monitorUI.fillRow
local monitorCenter = monitorUI.centerRow

--------------------------------------------------------------------------
-- Shared suite updater
--------------------------------------------------------------------------

local UPDATE = SuiteUpdater.new({
    appId = "supply",
    appVersion = PROGRAM_VERSION,
    suiteVersion = SUITE_VERSION,
    displayName = "SUPPLY MANAGER",
    checkSeconds = CONFIG.updateCheckSeconds,
    drawMessage = function(title, message, color)
        if not monitor then return end
        local w, h = monitorUI.size()
        if not w or not h then return end
        local mid = math.max(5, math.floor(h / 2))
        monitorFillRow(mid - 1, UI.panel, UI.text)
        monitorFillRow(mid, UI.panel, UI.text)
        monitorFillRow(mid + 1, UI.panel, UI.text)
        monitorCenter(mid - 1, tostring(title or "UPDATE"), color or UI.title, UI.panel, w)
        monitorCenter(mid, tostring(message or ""), UI.text, UI.panel, w)
    end,
})

local SUPPLY_TABS = {
    { id = "main", label = "REQUESTS" },
    { id = "history", label = "HISTORY" },
    { id = "settings", label = "SETTINGS" },
}

local function drawSupplyHeader(w, pageTitleText, statusText, statusColorValue)
    monitorUI.resetButtons()
    local button = nil
    if UPDATE.availableVersion then
        button = {
            id = "program_update", label = UPDATE.buttonLabel(),
            bg = UI.navActiveBg, fg = UI.navFg, action = UPDATE.install,
        }
    end
    monitorUI.drawHeader({
        title = "MINECOLONIES SUPPLY MANAGER",
        subtitle = tostring(colonyName or "Unknown Colony") .. "  [SUPPLY-v" .. PROGRAM_VERSION .. "]",
        status = tostring(statusText or ""),
        statusFg = statusColorValue or UI.muted,
        pageTitle = tostring(pageTitleText or ""),
        button = button,
    })
end

local function drawSupplyNav(activeView, w, h)
    monitorUI.drawNav(activeView, SUPPLY_TABS, h)
end

local function supplyNavViewAtX(x, w)
    local base = math.floor(w / 3)
    if x <= base then return "main" end
    if x <= base * 2 then return "history" end
    return "settings"
end

local function pageSubBarGeometry(w)
    local prevX2 = math.min(10, math.floor(w / 4))
    local nextX1 = math.max(prevX2 + 1, w - 9)
    return prevX2, nextX1
end

local function drawSupplySubBar(page, pages, middleText, w, h)
    monitorWrite(1, h - 1, string.rep(" ", w), UI.muted, UI.panel)

    local pageText = "Page " .. tostring(page) .. "/" .. tostring(pages)
    local centerTextValue = pageText
    if middleText and middleText ~= "" then
        centerTextValue = pageText .. " | " .. tostring(middleText)
    end

    if pages > 1 then
        local prevX2, nextX1 = pageSubBarGeometry(w)

        monitorWrite(
            1, h - 1,
            padRight(centerText("< PREV", prevX2), prevX2),
            UI.text,
            UI.panel
        )

        local centerWidth = math.max(1, nextX1 - prevX2 - 1)
        monitorWrite(
            prevX2 + 1, h - 1,
            padRight(centerText(centerTextValue, centerWidth), centerWidth),
            UI.muted,
            UI.panel
        )

        local nextWidth = w - nextX1 + 1
        monitorWrite(
            nextX1, h - 1,
            padRight(centerText("NEXT >", nextWidth), nextWidth),
            UI.text,
            UI.panel
        )
    else
        monitorCenter(h - 1, centerTextValue, UI.muted, UI.panel, w)
    end
end

local function alternatingRowBackground(y)
    return (y % 2 == 0) and UI.bg or UI.panel
end

local function renderMainMonitor()
    if not monitor then
        resolveMonitor()
        if not monitor then return end
    end

    pcall(monitor.setTextScale, CONFIG.monitorTextScale)
    local okSize, w, h = pcall(monitor.getSize)
    if not okSize or not w or not h then
        monitor = nil
        return
    end

    clearMonitor()
    if not monitor then return end

    local transferPathOnline = health.playerRS and health.colonyRS and health.transfer
    local allSystemsOnline =
        health.playerRS
        and health.colonyRS
        and health.warehouse
        and transferPathOnline

    local systemState = allSystemsOnline and "ONLINE" or "DEGRADED"
    local statusText =
        systemState ..
        "  |  REQUESTS  |  Scan: " .. tostring(lastScanText or "?") ..
        "  |  Craft: " .. (autoCraftEnabled()
            and (NBTX.isRSSafetyLatched() and "PAUSED" or "ON")
            or "OFF")

    drawSupplyHeader(
        w,
        "SUPPLY REQUESTS  (" .. tostring(#dashboardRows) .. ")",
        statusText,
        allSystemsOnline and UI.ok or UI.warn
    )

    local top = 6
    local bottom = h - 2
    local rowsPerPage = math.max(1, bottom - top + 1)
    local totalPages = math.max(1, math.ceil(#dashboardRows / rowsPerPage))
    currentPage = clamp(currentPage, 1, totalPages)

    local compact = w < 58
    local columns = {}

    if compact then
        local usable = w - 2
        local separatorCount = 2
        local content = math.max(20, usable - separatorCount)

        local needW = 7
        local statusW = 11
        local itemW = math.max(10, content - needW - statusW)

        local itemX = 2
        local sep1X = itemX + itemW
        local needX = sep1X + 1
        local sep2X = needX + needW
        local statusX = sep2X + 1

        columns = {
            itemX = itemX, itemW = itemW, sep1X = sep1X,
            needX = needX, needW = needW, sep2X = sep2X,
            statusX = statusX, statusW = math.max(1, w - statusX + 1),
        }

        monitorWrite(1, 5, string.rep(" ", w), colors.black, UI.panel2)
        monitorWrite(columns.itemX, 5, padRight("ITEM", columns.itemW), colors.black, UI.panel2)
        monitorWrite(columns.sep1X, 5, "|", colors.gray, UI.panel2)
        monitorWrite(columns.needX, 5, padRight("NEED", columns.needW), colors.black, UI.panel2)
        monitorWrite(columns.sep2X, 5, "|", colors.gray, UI.panel2)
        monitorWrite(columns.statusX, 5, padRight("STATUS", columns.statusW), colors.black, UI.panel2)

    else
        local usable = w - 2
        local separatorCount = 5
        local content = math.max(32, usable - separatorCount)

        local needW = 7
        local sentW = 7
        local playerW = 10
        local whW = 9
        local statusW = 13
        local itemW = content - needW - sentW - playerW - whW - statusW

        while itemW < 14 do
            if playerW > 8 then
                playerW = playerW - 1
            elseif statusW > 9 then
                statusW = statusW - 1
            elseif whW > 7 then
                whW = whW - 1
            elseif sentW > 6 then
                sentW = sentW - 1
            elseif needW > 6 then
                needW = needW - 1
            else
                break
            end
            itemW = content - needW - sentW - playerW - whW - statusW
        end
        itemW = math.max(1, itemW)

        local itemX = 2
        local sep1X = itemX + itemW
        local needX = sep1X + 1
        local sep2X = needX + needW
        local sentX = sep2X + 1
        local sep3X = sentX + sentW
        local playerX = sep3X + 1
        local sep4X = playerX + playerW
        local whX = sep4X + 1
        local sep5X = whX + whW
        local statusX = sep5X + 1

        columns = {
            itemX = itemX, itemW = itemW, sep1X = sep1X,
            needX = needX, needW = needW, sep2X = sep2X,
            sentX = sentX, sentW = sentW, sep3X = sep3X,
            playerX = playerX, playerW = playerW, sep4X = sep4X,
            whX = whX, whW = whW, sep5X = sep5X,
            statusX = statusX, statusW = math.max(1, w - statusX + 1),
        }

        monitorWrite(1, 5, string.rep(" ", w), colors.black, UI.panel2)
        monitorWrite(columns.itemX, 5, padRight("ITEM", columns.itemW), colors.black, UI.panel2)
        monitorWrite(columns.sep1X, 5, "|", colors.gray, UI.panel2)
        monitorWrite(columns.needX, 5, padRight("NEED", columns.needW), colors.black, UI.panel2)
        monitorWrite(columns.sep2X, 5, "|", colors.gray, UI.panel2)
        monitorWrite(columns.sentX, 5, padRight("SENT", columns.sentW), colors.black, UI.panel2)
        monitorWrite(columns.sep3X, 5, "|", colors.gray, UI.panel2)
        monitorWrite(columns.playerX, 5, padRight("PLAYER", columns.playerW), colors.black, UI.panel2)
        monitorWrite(columns.sep4X, 5, "|", colors.gray, UI.panel2)
        monitorWrite(columns.whX, 5, padRight("WH", columns.whW), colors.black, UI.panel2)
        monitorWrite(columns.sep5X, 5, "|", colors.gray, UI.panel2)
        monitorWrite(columns.statusX, 5, padRight("STATUS", columns.statusW), colors.black, UI.panel2)
    end

    if #dashboardRows == 0 then
        monitorCenter(
            math.floor((top + bottom) / 2),
            "Nothing to display",
            UI.muted,
            UI.bg,
            w
        )
    else
        local startIndex = (currentPage - 1) * rowsPerPage + 1
        local endIndex = math.min(#dashboardRows, startIndex + rowsPerPage - 1)
        local y = top

        for i = startIndex, endIndex do
            local row = dashboardRows[i]
            local bg = alternatingRowBackground(y)

            monitorWrite(1, y, string.rep(" ", w), UI.text, bg)

            if compact then
                monitorWrite(columns.itemX, y, padRight(row.displayName, columns.itemW), UI.text, bg)
                monitorWrite(columns.sep1X, y, "|", UI.muted, bg)
                monitorWrite(columns.needX, y, padRight(formatNumber(row.requested), columns.needW), UI.accent, bg)
                monitorWrite(columns.sep2X, y, "|", UI.muted, bg)
                monitorWrite(columns.statusX, y, padRight(NBTX.dashboardStatusText(row.status, columns.statusW, row), columns.statusW), statusColor(row.status), bg)
            else
                monitorWrite(columns.itemX, y, padRight(row.displayName, columns.itemW), UI.text, bg)
                monitorWrite(columns.sep1X, y, "|", UI.muted, bg)
                monitorWrite(columns.needX, y, padRight(formatNumber(row.requested), columns.needW), UI.accent, bg)
                monitorWrite(columns.sep2X, y, "|", UI.muted, bg)
                monitorWrite(columns.sentX, y, padRight(formatNumber(row.supplied), columns.sentW), UI.info, bg)
                monitorWrite(columns.sep3X, y, "|", UI.muted, bg)
                monitorWrite(columns.playerX, y, padRight(formatNumber(row.playerStock), columns.playerW), UI.text, bg)
                monitorWrite(columns.sep4X, y, "|", UI.muted, bg)
                monitorWrite(columns.whX, y, padRight(formatNumber(row.warehouseStock), columns.whW), UI.muted, bg)
                monitorWrite(columns.sep5X, y, "|", UI.muted, bg)
                monitorWrite(columns.statusX, y, padRight(NBTX.dashboardStatusText(row.status, columns.statusW, row), columns.statusW), statusColor(row.status), bg)
            end

            y = y + 1
        end
    end

    local summary =
        "Supplied " .. tostring(stats.supplied) ..
        " | Ready " .. tostring(stats.ready) ..
        " | Missing " .. tostring(stats.missing) ..
        " | Err " .. tostring(stats.errors)

    drawSupplySubBar(currentPage, totalPages, summary, w, h)
    drawSupplyNav("main", w, h)
end

local function settingsRowsPerPage()
    if not monitor then return 1, 1 end
    local ok, _, h = pcall(monitor.getSize)
    if not ok then return 1, 1 end

    local firstRow = 6
    local lastRow = h - 2
    local rows = math.max(1, lastRow - firstRow + 1)
    local pages = math.max(1, math.ceil(#settingsRows / rows))
    return rows, pages
end

local function renderSettingsMonitor()
    if not monitor then
        resolveMonitor()
        if not monitor then return end
    end

    pcall(monitor.setTextScale, CONFIG.monitorTextScale)
    local okSize, w, h = pcall(monitor.getSize)
    if not okSize or not w or not h then
        monitor = nil
        return
    end

    clearMonitor()
    if not monitor then return end

    local overflowState =
        state.settings and state.settings.overflowEnabled and "ON" or "OFF"
    local craftState = autoCraftEnabled() and "ON" or "OFF"

    local statusText =
        "OVERFLOW:" .. overflowState .. " [TOGGLE]" ..
        "  |  " ..
        "AUTOCRAFT:" .. craftState .. " [TOGGLE]"

    drawSupplyHeader(
        w,
        "WAREHOUSE SETTINGS  (" .. tostring(#settingsRows) .. ")",
        statusText,
        UI.muted
    )

    local usable = w - 2
    local separatorCount = 3
    local content = math.max(24, usable - separatorCount)

    local targetW = 10
    local overflowW = 11
    local currentW = 10
    local itemW = content - targetW - overflowW - currentW

    while itemW < 14 do
        if overflowW > 9 then
            overflowW = overflowW - 1
        elseif currentW > 8 then
            currentW = currentW - 1
        elseif targetW > 8 then
            targetW = targetW - 1
        else
            break
        end
        itemW = content - targetW - overflowW - currentW
    end
    itemW = math.max(1, itemW)

    local itemX = 2
    local sep1X = itemX + itemW
    local targetX = sep1X + 1
    local sep2X = targetX + targetW
    local overflowX = sep2X + 1
    local sep3X = overflowX + overflowW
    local currentX = sep3X + 1

    local columns = {
        itemX = itemX, itemW = itemW, sep1X = sep1X,
        targetX = targetX, targetW = targetW, sep2X = sep2X,
        overflowX = overflowX, overflowW = overflowW, sep3X = sep3X,
        currentX = currentX, currentW = math.max(1, w - currentX + 1),
    }

    monitorWrite(1, 5, string.rep(" ", w), colors.black, UI.panel2)
    monitorWrite(columns.itemX, 5, padRight("ITEM", columns.itemW), colors.black, UI.panel2)
    monitorWrite(columns.sep1X, 5, "|", colors.gray, UI.panel2)
    monitorWrite(columns.targetX, 5, padRight("TARGET", columns.targetW), colors.black, UI.panel2)
    monitorWrite(columns.sep2X, 5, "|", colors.gray, UI.panel2)
    monitorWrite(columns.overflowX, 5, padRight("OVERFLOW", columns.overflowW), colors.black, UI.panel2)
    monitorWrite(columns.sep3X, 5, "|", colors.gray, UI.panel2)
    monitorWrite(columns.currentX, 5, padRight("CURRENT", columns.currentW), colors.black, UI.panel2)

    local rowsPerPage, totalPages = settingsRowsPerPage()
    settingsPage = clamp(settingsPage, 1, totalPages)

    local startIndex = (settingsPage - 1) * rowsPerPage + 1
    local endIndex = math.min(#settingsRows, startIndex + rowsPerPage - 1)
    local y = 6

    for i = startIndex, endIndex do
        local row = settingsRows[i]
        local bg = alternatingRowBackground(y)

        monitorWrite(1, y, string.rep(" ", w), UI.text, bg)
        monitorWrite(columns.itemX, y, padRight(row.displayName, columns.itemW), UI.text, bg)
        monitorWrite(columns.sep1X, y, "|", UI.muted, bg)
        monitorWrite(columns.targetX, y, padRight(formatNumber(row.target), columns.targetW), UI.accent, bg)
        monitorWrite(columns.sep2X, y, "|", UI.muted, bg)
        monitorWrite(columns.overflowX, y, padRight(formatNumber(row.overflow), columns.overflowW), UI.info, bg)
        monitorWrite(columns.sep3X, y, "|", UI.muted, bg)
        monitorWrite(columns.currentX, y, padRight(formatNumber(row.current), columns.currentW), UI.text, bg)

        y = y + 1
    end

    local footer =
        "Touch row to edit | General " ..
        formatNumber(CONFIG.defaultWarehouseTarget) ..
        " | Building " ..
        formatNumber(CONFIG.defaultBuildingTarget)

    drawSupplySubBar(settingsPage, totalPages, footer, w, h)
    drawSupplyNav("settings", w, h)
end

local function historyRowsPerPage()
    if not monitor then return 1, 1 end
    local ok, _, h = pcall(monitor.getSize)
    if not ok then return 1, 1 end

    local firstRow = 6
    local lastRow = h - 2
    local rows = math.max(1, lastRow - firstRow + 1)
    local count = state.history and #state.history or 0
    local pages = math.max(1, math.ceil(count / rows))
    return rows, pages
end

local function renderHistoryMonitor()
    if not monitor then
        resolveMonitor()
        if not monitor then return end
    end

    pcall(monitor.setTextScale, CONFIG.monitorTextScale)
    local okSize, w, h = pcall(monitor.getSize)
    if not okSize or not w or not h then
        monitor = nil
        return
    end

    clearMonitor()
    if not monitor then return end

    local history = state.history or {}

    drawSupplyHeader(
        w,
        "TRANSFER HISTORY  (" .. tostring(#history) .. ")",
        "P>WH = SUPPLY  |  WH>P = OVERFLOW  |  Newest first",
        UI.muted
    )

    local usable = w - 2
    local separatorCount = 3
    local content = math.max(24, usable - separatorCount)

    local timeW = 9
    local dirW = 7
    local qtyW = 10
    local itemW = content - timeW - dirW - qtyW

    while itemW < 16 do
        if qtyW > 8 then
            qtyW = qtyW - 1
        elseif timeW > 8 then
            timeW = timeW - 1
        elseif dirW > 6 then
            dirW = dirW - 1
        else
            break
        end
        itemW = content - timeW - dirW - qtyW
    end
    itemW = math.max(1, itemW)

    local timeX = 2
    local sep1X = timeX + timeW
    local dirX = sep1X + 1
    local sep2X = dirX + dirW
    local itemX = sep2X + 1
    local sep3X = itemX + itemW
    local qtyX = sep3X + 1

    local columns = {
        timeX = timeX, timeW = timeW, sep1X = sep1X,
        dirX = dirX, dirW = dirW, sep2X = sep2X,
        itemX = itemX, itemW = itemW, sep3X = sep3X,
        qtyX = qtyX, qtyW = math.max(1, w - qtyX + 1),
    }

    monitorWrite(1, 5, string.rep(" ", w), colors.black, UI.panel2)
    monitorWrite(columns.timeX, 5, padRight("TIME", columns.timeW), colors.black, UI.panel2)
    monitorWrite(columns.sep1X, 5, "|", colors.gray, UI.panel2)
    monitorWrite(columns.dirX, 5, padRight("DIR", columns.dirW), colors.black, UI.panel2)
    monitorWrite(columns.sep2X, 5, "|", colors.gray, UI.panel2)
    monitorWrite(columns.itemX, 5, padRight("ITEM", columns.itemW), colors.black, UI.panel2)
    monitorWrite(columns.sep3X, 5, "|", colors.gray, UI.panel2)
    monitorWrite(columns.qtyX, 5, padRight("QTY", columns.qtyW), colors.black, UI.panel2)

    local rowsPerPage, totalPages = historyRowsPerPage()
    historyPage = clamp(historyPage, 1, totalPages)

    local startIndex = (historyPage - 1) * rowsPerPage + 1
    local endIndex = math.min(#history, startIndex + rowsPerPage - 1)

    if #history == 0 then
        monitorCenter(
            math.floor((6 + (h - 2)) / 2),
            "No successful transfers recorded yet.",
            UI.muted,
            UI.bg,
            w
        )
    else
        local y = 6
        for i = startIndex, endIndex do
            local row = history[i]
            local bg = alternatingRowBackground(y)
            local dir = tostring(row.direction or "?")
            local dirColor = dir == "P>WH" and UI.ok or UI.accent

            monitorWrite(1, y, string.rep(" ", w), UI.text, bg)
            monitorWrite(columns.timeX, y, padRight(tostring(row.time or "--:--:--"), columns.timeW), UI.muted, bg)
            monitorWrite(columns.sep1X, y, "|", UI.muted, bg)
            monitorWrite(columns.dirX, y, padRight(dir, columns.dirW), dirColor, bg)
            monitorWrite(columns.sep2X, y, "|", UI.muted, bg)
            monitorWrite(columns.itemX, y, padRight(tostring(row.displayName or row.item or "?"), columns.itemW), UI.text, bg)
            monitorWrite(columns.sep3X, y, "|", UI.muted, bg)
            monitorWrite(columns.qtyX, y, padRight(formatNumber(row.amount or 0), columns.qtyW), UI.accent, bg)

            y = y + 1
        end
    end

    drawSupplySubBar(
        historyPage,
        totalPages,
        "Entries " .. tostring(#history) .. "/" ..
            tostring(tonumber(CONFIG.maxHistoryEntries) or 200),
        w,
        h
    )
    drawSupplyNav("history", w, h)
end

local function findSettingsRow(itemName)
    for _, row in ipairs(settingsRows) do
        if row.item == itemName then return row end
    end
    return nil
end

local function syncEditTargetFromInput()
    local digits = tostring(editTargetInput or ""):gsub("%D", "")
    if digits == "" then
        editTarget = 0
        editTargetInput = ""
        return
    end
    -- Keep input bounded to the same practical maximum as button edits.
    if #digits > 9 then digits = digits:sub(1, 9) end
    local n = tonumber(digits) or 0
    n = math.max(0, math.min(999999999, math.floor(n)))
    editTarget = n
    editTargetInput = tostring(n)
end

local function setEditTarget(n, fresh)
    n = math.max(0, math.min(999999999, math.floor(tonumber(n) or 0)))
    editTarget = n
    editTargetInput = tostring(n)
    editInputMessage = nil
    editInputFresh = fresh == true
end

local function appendEditDigit(digit)
    if not tostring(digit):match("^%d$") then return end
    local current = tostring(editTargetInput or "")
    -- The first typed/touched digit replaces the existing target so the
    -- player can simply enter 4096 without clearing 1024 first.
    if editInputFresh then current = "" end
    editInputFresh = false
    if current == "0" then current = "" end
    if #current >= 9 then
        editInputMessage = "Maximum target is 999,999,999"
        return
    end
    editTargetInput = current .. tostring(digit)
    syncEditTargetFromInput()
    editInputMessage = nil
end

local function backspaceEditDigit()
    editInputFresh = false
    local current = tostring(editTargetInput or "")
    if #current > 0 then current = current:sub(1, -2) end
    editTargetInput = current
    syncEditTargetFromInput()
    editInputMessage = nil
end

local function clearEditInput()
    editInputFresh = false
    editTargetInput = ""
    editTarget = 0
    editInputMessage = nil
end

local function editKeypadLayout(w, h)
    local startY = math.min(12, math.max(8, h - 7))
    local rows = {
        { {"[ 1 ]", "1"}, {"[ 2 ]", "2"}, {"[ 3 ]", "3"} },
        { {"[ 4 ]", "4"}, {"[ 5 ]", "5"}, {"[ 6 ]", "6"} },
        { {"[ 7 ]", "7"}, {"[ 8 ]", "8"}, {"[ 9 ]", "9"} },
        { {"[ C ]", "clear"}, {"[ 0 ]", "0"}, {"[ <-]", "back"} },
    }
    local buttons = {}
    for r, defs in ipairs(rows) do
        local gap = 2
        local total = 0
        for _, d in ipairs(defs) do total = total + #d[1] end
        total = total + gap * (#defs - 1)
        local x = math.max(1, math.floor((w - total) / 2) + 1)
        for _, d in ipairs(defs) do
            buttons[#buttons + 1] = {
                label = d[1], action = d[2],
                x1 = x, x2 = x + #d[1] - 1, y = startY + r - 1,
            }
            x = x + #d[1] + gap
        end
    end
    return buttons, startY
end

local function saveEditedTarget()
    local row = selectedSettingItem and findSettingsRow(selectedSettingItem) or nil
    if not row then return false end
    syncEditTargetFromInput()
    state.settings.targets[row.item] = math.max(0, math.floor(tonumber(editTarget) or 0))
    saveState()
    buildSettingsRows()
    monitorView = "settings"
    selectedSettingItem = nil
    editTarget = nil
    editTargetInput = nil
    editInputMessage = nil
    editInputFresh = false
    return true
end

local function renderEditMonitor()
    if not monitor then return end
    local okSize, w, h = pcall(monitor.getSize)
    if not okSize then return end

    clearMonitor()

    local row =
        selectedSettingItem and findSettingsRow(selectedSettingItem) or nil

    if not row then
        monitorView = "settings"
        renderSettingsMonitor()
        return
    end

    if editTargetInput == nil then
        setEditTarget(editTarget ~= nil and editTarget or row.target or 0, true)
    else
        syncEditTargetFromInput()
    end

    local stackSize, stackKnown = getKnownStackSize(row.item)
    local overflow =
        editTarget +
        (stackSize * math.max(
            0,
            math.floor(tonumber(CONFIG.overflowStacks) or 2)
        ))

    local buttons, keypadStart = editKeypadLayout(w, h)

    drawSupplyHeader(
        w,
        "EDIT WAREHOUSE TARGET",
        truncateText(row.item, w - 4),
        UI.muted
    )

    monitorCenter(5, row.displayName, UI.title, UI.bg, w)
    monitorCenter(
        6,
        "Current: " .. formatNumber(row.current) ..
        "  |  Stack: " .. formatNumber(stackSize) ..
        (stackKnown and "" or "*"),
        stackKnown and UI.text or UI.warn,
        UI.bg,
        w
    )
    monitorCenter(
        7,
        "Target: " .. formatNumber(editTarget) ..
        "  |  Overflow: " .. formatNumber(overflow),
        UI.ok,
        UI.bg,
        w
    )

    local shownInput =
        editTargetInput == "" and "_" or (tostring(editTargetInput) .. "_")

    monitorCenter(
        keypadStart - 2,
        "New Target: [ " .. shownInput .. " ]",
        UI.title,
        UI.bg,
        w
    )

    for _, button in ipairs(buttons) do
        monitorWrite(button.x1, button.y, button.label, UI.info, UI.bg)
    end

    local stackRow = keypadStart + 4
    local minusStack = "< -STACK"
    local plusStack = "+STACK >"

    monitorWrite(2, stackRow, minusStack, UI.accent, UI.bg)
    monitorWrite(
        math.max(1, w - #plusStack),
        stackRow,
        plusStack,
        UI.accent,
        UI.bg
    )

    if stackRow + 1 < h - 1 then
        monitorCenter(
            stackRow + 1,
            editInputMessage
                or "Touch keypad or type on computer; Enter saves",
            editInputMessage and UI.warn or UI.muted,
            UI.bg,
            w
        )
    end

    local base = math.floor(w / 3)
    local resetW = base
    local backW = base
    local saveW = w - resetW - backW

    monitorWrite(
        1, h,
        padRight(centerText("RESET", resetW), resetW),
        UI.warn,
        UI.navBg
    )
    monitorWrite(
        resetW + 1, h,
        padRight(centerText("BACK", backW), backW),
        UI.navFg,
        UI.navBg
    )
    monitorWrite(
        resetW + backW + 1, h,
        padRight(centerText("SAVE", saveW), saveW),
        UI.navFg,
        UI.navActiveBg
    )
end

local function renderMonitor()
    if monitorView == "settings" then
        renderSettingsMonitor()
    elseif monitorView == "history" then
        renderHistoryMonitor()
    elseif monitorView == "edit" then
        renderEditMonitor()
    else
        renderMainMonitor()
    end
end

--------------------------------------------------------------------------
-- Terminal rendering
--------------------------------------------------------------------------

local function terminalColor(color)
    if term.isColor and term.isColor() then term.setTextColor(color) end
end

local function renderTerminal()
    if not CONFIG.mirrorTerminal then return end

    term.setBackgroundColor(colors.black)
    terminalColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)

    local transferPathOnline = health.playerRS and health.colonyRS and health.transfer
    local overallHealthy =
        health.playerRS
        and health.colonyRS
        and health.warehouse
        and transferPathOnline

    print("MineColonies Supply Manager v" .. PROGRAM_VERSION)
    print("Control Suite: v" .. SUITE_VERSION)
    print("Colony: " .. tostring(colonyName or "Unknown Colony"))

    terminalColor(overallHealthy and colors.lime or colors.orange)
    print("HEALTH:      " .. (overallHealthy and "ONLINE" or "DEGRADED"))

    terminalColor(colors.white)
    print("Player RS:   " .. healthWord(health.playerRS) ..
        "  [" .. tostring(playerBridgeResolvedName or "?") .. "]")
    print("Colony RS:   " .. healthWord(health.colonyRS) ..
        "  [" .. tostring(colonyBridgeResolvedName or "?") .. "]")
    print("Warehouse:   " .. healthWord(health.warehouse))
    print("Transfer:    " .. healthWord(transferPathOnline))
    print("Barrel:      " .. tostring(transferChestResolvedName or "NOT DETECTED"))
    print("Status:      " .. tostring(health.message))

    local updateText, updateColor = UPDATE.terminalStatus()
    terminalColor(updateColor)
    print("UPDATE:      " .. tostring(updateText))

    terminalColor(colors.white)
    print("Suite source: " .. tostring(UPDATE.sourceLabel()))
    print(string.rep("-", 50))

    local maxRows = 10
    for i = 1, math.min(#dashboardRows, maxRows) do
        local row = dashboardRows[i]
        terminalColor(statusColor(row.status))
        print(string.format(
            "%-22s %5d/%-5d %-13s",
            truncateText(row.displayName, 22),
            row.supplied or 0,
            row.requested or 0,
            NBTX.dashboardStatusText(row.status, 13, row)
        ))
    end

    terminalColor(colors.white)
end

--------------------------------------------------------------------------
-- Monitor paging and events
--------------------------------------------------------------------------

local function monitorRowsPerPage()
    if not monitor then return 1, 1 end
    local ok, _, h = pcall(monitor.getSize)
    if not ok then return 1, 1 end

    local firstRowLine = 6
    local lastRowLine = h - 2
    local rows = math.max(1, lastRowLine - firstRowLine + 1)
    local pages = math.max(1, math.ceil(#dashboardRows / rows))
    return rows, pages
end

local function nextPage()
    local _, pages = monitorRowsPerPage()
    currentPage = currentPage + 1
    if currentPage > pages then currentPage = 1 end
    lastManualPageChange = nowSeconds()
end

local function previousPage()
    local _, pages = monitorRowsPerPage()
    currentPage = currentPage - 1
    if currentPage < 1 then currentPage = pages end
    lastManualPageChange = nowSeconds()
end

local function nextHistoryPage()
    local _, pages = historyRowsPerPage()
    historyPage = historyPage + 1
    if historyPage > pages then historyPage = 1 end
    lastManualPageChange = nowSeconds()
end

local function previousHistoryPage()
    local _, pages = historyRowsPerPage()
    historyPage = historyPage - 1
    if historyPage < 1 then historyPage = pages end
    lastManualPageChange = nowSeconds()
end

local function nextSettingsPage()
    local _, pages = settingsRowsPerPage()
    settingsPage = settingsPage + 1
    if settingsPage > pages then settingsPage = 1 end
    lastManualPageChange = nowSeconds()
end

local function previousSettingsPage()
    local _, pages = settingsRowsPerPage()
    settingsPage = settingsPage - 1
    if settingsPage < 1 then settingsPage = pages end
    lastManualPageChange = nowSeconds()
end

local function settingsRowAtMonitorY(y)
    local rowsPerPage = settingsRowsPerPage()
    if y < 6 then return nil end
    local offset = y - 6
    if offset < 0 or offset >= rowsPerPage then return nil end
    local index = (settingsPage - 1) * rowsPerPage + offset + 1
    return settingsRows[index]
end

local function eventLoop()
    while true do
        local event, p1, p2, p3 = os.pullEvent()

        if event == "monitor_touch" then
            local side, x, y = p1, p2, p3
            if monitor and (not monitorResolvedName or side == monitorResolvedName) then
                local ok, w, h = pcall(monitor.getSize)
                if ok then
                    if UPDATE.touchIsButton(x, y, w) then
                        UPDATE.install()
                        renderMonitor()
                    elseif monitorView == "main" then
                        local _, totalPages = (function()
                            local top = 6
                            local bottom = h - 2
                            local rows = math.max(1, bottom - top + 1)
                            return rows, math.max(1, math.ceil(#dashboardRows / rows))
                        end)()

                        if y == h then
                            local view = supplyNavViewAtX(x, w)
                            monitorView = view
                            if view == "history" then historyPage = 1 end
                            if view == "settings" then settingsPage = 1 end
                            renderMonitor()

                        elseif y == h - 1 and totalPages > 1 then
                            local prevX2, nextX1 = pageSubBarGeometry(w)
                            if x <= prevX2 then
                                previousPage()
                            elseif x >= nextX1 then
                                nextPage()
                            end
                            renderMonitor()
                        end

                    elseif monitorView == "settings" then
                        local _, totalPages = settingsRowsPerPage()

                        if y == 3 then
                            local toggleRight = w
                            if UPDATE.availableVersion then
                                local updateX = UPDATE.buttonGeometry(w)
                                toggleRight = math.max(1, (updateX or w) - 1)
                            end
                            local toggleMid = math.floor(toggleRight / 2)
                            if x <= toggleMid then
                                state.settings.overflowEnabled = not (state.settings.overflowEnabled == true)
                                writeLog("Overflow return " .. (state.settings.overflowEnabled and "enabled" or "disabled") .. " from monitor")
                            elseif x <= toggleRight then
                                state.settings.autoCraftEnabled = not autoCraftEnabled()
                                writeLog("AutoCraft " .. (state.settings.autoCraftEnabled and "enabled" or "disabled") .. " from monitor")
                            end
                            saveState()
                            renderMonitor()

                        elseif y == h then
                            local view = supplyNavViewAtX(x, w)
                            monitorView = view
                            if view == "history" then historyPage = 1 end
                            renderMonitor()

                        elseif y == h - 1 and totalPages > 1 then
                            local prevX2, nextX1 = pageSubBarGeometry(w)
                            if x <= prevX2 then
                                previousSettingsPage()
                            elseif x >= nextX1 then
                                nextSettingsPage()
                            end
                            renderMonitor()

                        else
                            local row = settingsRowAtMonitorY(y)
                            if row then
                                selectedSettingItem = row.item
                                editTarget = row.target
                                editTargetInput = tostring(row.target or 0)
                                editInputMessage = nil
                                editInputFresh = true
                                monitorView = "edit"
                                renderMonitor()
                            end
                        end

                    elseif monitorView == "history" then
                        local _, totalPages = historyRowsPerPage()

                        if y == h then
                            local view = supplyNavViewAtX(x, w)
                            monitorView = view
                            if view == "settings" then settingsPage = 1 end
                            renderMonitor()

                        elseif y == h - 1 and totalPages > 1 then
                            local prevX2, nextX1 = pageSubBarGeometry(w)
                            if x <= prevX2 then
                                previousHistoryPage()
                            elseif x >= nextX1 then
                                nextHistoryPage()
                            end
                            renderMonitor()
                        end

                    elseif monitorView == "edit" then
                        local row = selectedSettingItem and findSettingsRow(selectedSettingItem) or nil
                        if row then
                            local stackSize = getKnownStackSize(row.item)
                            local buttons, keypadStart = editKeypadLayout(w, h)
                            local handled = false

                            for _, button in ipairs(buttons) do
                                if y == button.y and x >= button.x1 and x <= button.x2 then
                                    if button.action == "clear" then
                                        clearEditInput()
                                    elseif button.action == "back" then
                                        backspaceEditDigit()
                                    else
                                        appendEditDigit(button.action)
                                    end
                                    handled = true
                                    break
                                end
                            end

                            if not handled and y == keypadStart + 4 then
                                local minusStack = "< -STACK"
                                local plusStack = "+STACK >"
                                local minusX = 2
                                local plusX = math.max(1, w - #plusStack)

                                if x >= minusX and x < minusX + #minusStack then
                                    setEditTarget((editTarget or 0) - stackSize, false)
                                    handled = true
                                elseif x >= plusX and x < plusX + #plusStack then
                                    setEditTarget((editTarget or 0) + stackSize, false)
                                    handled = true
                                end
                            end

                            if not handled and y == h then
                                local base = math.floor(w / 3)

                                if x <= base then
                                    state.settings.targets[row.item] = nil
                                    saveState()
                                    buildSettingsRows()
                                    row = findSettingsRow(row.item) or row
                                    setEditTarget(getWarehouseTarget(row.item), true)
                                    editInputMessage = "Reset to default"
                                    handled = true

                                elseif x <= base * 2 then
                                    monitorView = "settings"
                                    selectedSettingItem = nil
                                    editTarget = nil
                                    editTargetInput = nil
                                    editInputMessage = nil
                                    editInputFresh = false
                                    handled = true

                                else
                                    saveEditedTarget()
                                    handled = true
                                end
                            end

                            if handled then renderMonitor() end
                        end
                    end
                end
            end

        elseif event == "char" and monitorView == "edit" then
            local ch = tostring(p1 or "")
            if ch:match("^%d$") then
                appendEditDigit(ch)
                renderMonitor()
            end

        elseif event == "paste" and monitorView == "edit" then
            local pasted = tostring(p1 or "")
            local digits = pasted:gsub("%D", "")
            if digits ~= "" then
                editTargetInput = digits:sub(1, 9)
                syncEditTargetFromInput()
                editInputMessage = nil
                editInputFresh = false
                renderMonitor()
            end

        elseif event == "key" and monitorView == "edit" then
            local keyCode = p1
            if keyCode == keys.backspace then
                backspaceEditDigit()
                renderMonitor()
            elseif keyCode == keys.delete then
                clearEditInput()
                renderMonitor()
            elseif keyCode == keys.enter or (keys.numPadEnter and keyCode == keys.numPadEnter) then
                if saveEditedTarget() then renderMonitor() end
            elseif keyCode == keys.escape then
                monitorView = "settings"
                selectedSettingItem = nil
                editTarget = nil
                editTargetInput = nil
                editInputMessage = nil
                editInputFresh = false
                renderMonitor()
            end

        elseif event == "monitor_resize" then
            resolveMonitor()
            currentPage = 1
            renderMonitor()

        elseif event == "peripheral" or event == "peripheral_detach" then
            refreshPeripherals()
            renderMonitor()
        end
    end
end

local function monitorRefreshLoop()
    local lastAuto = nowSeconds()

    while true do
        if not monitor then resolveMonitor() end

        if CONFIG.monitorAutoPage and monitor then
            local now = nowSeconds()

            if monitorView == "main" then
                local _, pages = monitorRowsPerPage()
                if pages > 1
                   and now - lastAuto >= CONFIG.monitorPageSeconds
                   and now - lastManualPageChange >= CONFIG.monitorPageSeconds then
                    currentPage = currentPage + 1
                    if currentPage > pages then currentPage = 1 end
                    lastAuto = now
                end
            elseif monitorView == "history" then
                local _, pages = historyRowsPerPage()
                if pages > 1
                   and now - lastAuto >= CONFIG.monitorPageSeconds
                   and now - lastManualPageChange >= CONFIG.monitorPageSeconds then
                    historyPage = historyPage + 1
                    if historyPage > pages then historyPage = 1 end
                    lastAuto = now
                end
            end
        end

        renderMonitor()
        sleep(1)
    end
end

--------------------------------------------------------------------------
-- Main processing loop
--------------------------------------------------------------------------

local function processorLoop()
    while true do
        local ok, err = pcall(scanAndProcess)
        if not ok then
            health.message = "Processor error: " .. tostring(err)
            health.transfer = false
            writeLog("FATAL CYCLE ERROR " .. tostring(err))
        end

        renderTerminal()
        renderMonitor()
        sleep(CONFIG.scanInterval)
    end
end

--------------------------------------------------------------------------
-- Diagnostics (5x3 monitor viewer)
--------------------------------------------------------------------------

-- Diagnostics are displayed on the same Advanced Monitor used by the main
-- dashboard. Long output is wrapped and paginated. The computer terminal is
-- retained only as a fallback if no monitor can be found.

local function wrapDiagnosticLine(text, width)
    text = tostring(text or "")
    width = math.max(1, math.floor(tonumber(width) or 1))
    local out = {}

    if text == "" then
        out[1] = ""
        return out
    end

    while #text > width do
        local chunk = text:sub(1, width)
        local splitAt = chunk:match("^.*() %S")
        if splitAt and splitAt > math.floor(width * 0.45) then
            out[#out + 1] = text:sub(1, splitAt - 1)
            text = text:sub(splitAt + 1)
        else
            out[#out + 1] = text:sub(1, width)
            text = text:sub(width + 1)
        end
    end

    out[#out + 1] = text
    return out
end

local function buildDiagnosticDisplayLines(lines, width)
    local wrapped = {}
    for _, line in ipairs(lines or {}) do
        for _, part in ipairs(wrapDiagnosticLine(line, width)) do
            wrapped[#wrapped + 1] = part
        end
    end
    if #wrapped == 0 then wrapped[1] = "No diagnostic messages." end
    return wrapped
end

local function renderDiagnosticMonitor(title, lines, page)
    if not monitor and not resolveMonitor() then return nil, 1, 1 end
    pcall(monitor.setTextScale, CONFIG.monitorTextScale)

    local ok, w, h = pcall(monitor.getSize)
    if not ok or not w or not h then
        monitor = nil
        monitorResolvedName = nil
        return nil, 1, 1
    end

    local contentWidth = math.max(1, w)
    local displayLines = buildDiagnosticDisplayLines(lines, contentWidth)
    local firstLine = 3
    local lastLine = math.max(firstLine, h - 2)
    local rowsPerPage = math.max(1, lastLine - firstLine + 1)
    local totalPages = math.max(1, math.ceil(#displayLines / rowsPerPage))
    page = clamp(math.floor(tonumber(page) or 1), 1, totalPages)

    clearMonitor()
    monitorWrite(1, 1, centerText(truncateText(title, w), w), colors.white)
    monitorWrite(1, 2, string.rep("-", w), colors.gray)

    local startIndex = (page - 1) * rowsPerPage + 1
    local endIndex = math.min(#displayLines, startIndex + rowsPerPage - 1)
    local y = firstLine
    for i = startIndex, endIndex do
        local line = displayLines[i]
        local color = colors.white
        local upper = string.upper(line)
        if upper:find("PASS", 1, true) or upper:find("ONLINE", 1, true) or upper:find("YES", 1, true) then
            color = colors.lime
        elseif upper:find("FAIL", 1, true) or upper:find("ERROR", 1, true) or upper:find("OFFLINE", 1, true) then
            color = colors.red
        elseif upper:find("WARN", 1, true) or upper:find("BLOCK", 1, true) or upper:find("MISSING", 1, true) then
            color = colors.orange
        elseif upper:find("MOVED=", 1, true) or upper:find("CURRENT", 1, true) then
            color = colors.cyan
        end
        monitorWrite(1, y, padRight(line, w), color)
        y = y + 1
    end

    monitorWrite(1, h - 1, padRight(string.format("Diagnostic page %d/%d", page, totalPages), w), colors.lightGray)

    local prevButton = "[ < PREV ]"
    local exitButton = "[ EXIT ]"
    local nextButton = "[ NEXT > ]"
    monitorWrite(1, h, prevButton, totalPages > 1 and colors.cyan or colors.gray)
    monitorWrite(math.max(1, math.floor((w - #exitButton) / 2) + 1), h, exitButton, colors.yellow)
    monitorWrite(math.max(1, w - #nextButton + 1), h, nextButton, totalPages > 1 and colors.cyan or colors.gray)

    return { width = w, height = h, rows = rowsPerPage }, page, totalPages
end

local function terminalDiagnosticFallback(title, lines)
    term.setBackgroundColor(colors.black)
    terminalColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("=== " .. tostring(title) .. " ===")
    for _, line in ipairs(lines or {}) do print(tostring(line)) end
end

local function showDiagnosticViewer(title, lines)
    local info, page, totalPages = renderDiagnosticMonitor(title, lines, 1)
    if not info then
        terminalDiagnosticFallback(title, lines)
        return
    end

    if CONFIG.mirrorTerminal then
        term.clear()
        term.setCursorPos(1, 1)
        print("Diagnostics are displayed on the 5x3 monitor.")
        print("Touch EXIT on the monitor, or press Q/Esc here, to close.")
    end

    while true do
        local event, p1, p2, p3 = os.pullEvent()

        if event == "monitor_touch" then
            local side, x, y = p1, p2, p3
            if not monitorResolvedName or side == monitorResolvedName then
                local ok, w, h = pcall(monitor.getSize)
                if ok and y == h then
                    local exitButton = "[ EXIT ]"
                    local exitX = math.max(1, math.floor((w - #exitButton) / 2) + 1)
                    if x <= 12 then
                        page = page - 1
                        if page < 1 then page = totalPages end
                    elseif x >= w - 11 then
                        page = page + 1
                        if page > totalPages then page = 1 end
                    elseif x >= exitX and x < exitX + #exitButton then
                        break
                    end
                    info, page, totalPages = renderDiagnosticMonitor(title, lines, page)
                    if not info then break end
                end
            end
        elseif event == "key" then
            if p1 == keys.q or p1 == keys.escape then break end
            if p1 == keys.left then
                page = page - 1
                if page < 1 then page = totalPages end
                info, page, totalPages = renderDiagnosticMonitor(title, lines, page)
            elseif p1 == keys.right then
                page = page + 1
                if page > totalPages then page = 1 end
                info, page, totalPages = renderDiagnosticMonitor(title, lines, page)
            end
        elseif event == "peripheral_detach" and monitorResolvedName and p1 == monitorResolvedName then
            terminalDiagnosticFallback(title, lines)
            break
        elseif event == "monitor_resize" then
            info, page, totalPages = renderDiagnosticMonitor(title, lines, page)
            if not info then break end
        end
    end
end

-- Non-blocking diagnostic refresh used while the four-stage transfer test is
-- actively running. The completed test enters showDiagnosticViewer() so the
-- player can page through the result afterward.
local function updateDiagnosticMonitor(title, lines)
    if not monitor then resolveMonitor() end
    if monitor then renderDiagnosticMonitor(title, lines, 1) end
end

local function peripheralDiagnosticLines()
    local lines = {}
    local function add(s) lines[#lines + 1] = tostring(s or "") end

    local integrators = { peripheral.find("colonyIntegrator") }
    add("Colony Integrators: " .. #integrators)
    for _, p in ipairs(integrators) do
        local name = peripheral.getName(p)
        local okColony, inColony = safeCall(p, "isInColony")
        local okName, cName = safeCall(p, "getColonyName")
        add("  " .. name .. "  inColony=" .. tostring(okColony and inColony))
        add("    colony=" .. tostring(okName and cName or "?"))
    end

    add("")
    local bridges = allRSBridges()
    add("RS Bridges: " .. #bridges)
    for _, info in ipairs(bridges) do
        add("  " .. info.name)
        add("    disk=" .. formatNumber(info.disk) .. "  external=" .. formatNumber(info.external))
    end

    add("")
    local monitors = { peripheral.find("monitor") }
    add("Monitors: " .. #monitors)
    for _, p in ipairs(monitors) do
        local name = peripheral.getName(p)
        local okSize, w, h = pcall(p.getSize)
        add("  " .. name .. "  size=" .. (okSize and (tostring(w) .. "x" .. tostring(h)) or "?"))
    end

    add("")
    add("Transfer movement mode: " ..
        ((CONFIG.usePeripheralTransfer and CONFIG.transferChestName)
            and "PERIPHERAL"
            or "DIRECTIONAL"))

    add("Player -> barrel: " .. CONFIG.playerToChestDirection)
    add("Barrel -> Colony: " .. CONFIG.chestToColonyDirection)
    add("Colony -> barrel: " .. CONFIG.colonyToChestDirection)
    add("Barrel -> Player: " .. CONFIG.chestToPlayerDirection)
    add("Transfer path: " .. healthWord(health.playerRS and health.colonyRS))
    add("Transaction: " .. (state.pending and "PENDING" or "IDLE"))

    add("")
    resolveTransferChest()
    if transferChestResolvedName then
        add("Barrel inspection: " .. tostring(transferChestResolvedName))
        add("Detection: " .. tostring(transferChestResolution))
        add("Present: " ..
            tostring(peripheral.isPresent(transferChestResolvedName)))
        add("Inventory peripheral: " ..
            tostring(hasPeripheralType(transferChestResolvedName, "inventory")))
        add("Barrel empty: " .. tostring(chestIsEmpty()))
    else
        add("Barrel inspection: NOT RESOLVED")
        add("Detection: " .. tostring(transferChestResolution))
        add("If ambiguous, set CONFIG.transferChestName manually.")
    end

    add("")
    add("Expected auto-detection:")
    add("Player RS = disk storage > 0")
    add("Colony RS = disk 0 + external > 0")
    return lines
end

local function printPeripheralDiagnostics()
    showDiagnosticViewer("PERIPHERAL DIAGNOSTICS v" .. PROGRAM_VERSION, peripheralDiagnosticLines())
end

local function printRequestDiagnostics()
    local lines = {}
    local function add(s) lines[#lines + 1] = tostring(s or "") end

    refreshPeripherals()
    if not colony then
        add("ERROR: No colonyIntegrator found/in colony.")
        showDiagnosticViewer("REQUEST DIAGNOSTICS v" .. PROGRAM_VERSION, lines)
        return
    end

    local requests, err = getColonyRequests()
    if not requests then
        add("ERROR: getRequests failed: " .. tostring(err))
        showDiagnosticViewer("REQUEST DIAGNOSTICS v" .. PROGRAM_VERSION, lines)
        return
    end

    local count = 0
    for _ in pairs(requests) do count = count + 1 end
    add("Requests returned: " .. tostring(count))
    add("")

    local index = 0
    for _, request in pairs(requests) do
        index = index + 1
        add("REQUEST " .. tostring(index))
        add("ID: " .. tostring(request.id or "?"))
        add("Name: " .. tostring(request.name or request.desc or "?"))
        add("State: " .. tostring(request.state or "?"))
        add("Count: " .. tostring(request.count or "?") .. "  Min: " .. tostring(request.minCount or "?"))
        add("Target: " .. tostring(request.target or "?"))
        if type(request.items) == "table" then
            add("Candidate safety:")
            for _, item in pairs(request.items) do
                if type(item) == "table" then
                    local reject = requestCandidateRejectionReason(item)
                    local safeDefault = requestNBTIsSafeDefault(item)
                    add(
                        "  " .. tostring(item.name or "?") ..
                        " | NBT=" .. tostring(itemHasNBT(item)) ..
                        " | SafeDefault=" .. tostring(safeDefault) ..
                        " | ExactNBT=" ..
                            tostring(
                                NBTX.exactRequestNBTAllowed(item)
                                and NBTX.requestNBTFilterValue(item) ~= nil
                            ) ..
                        " | " .. tostring(reject or "ACCEPT")
                    )
                end
            end
        end
        add("Raw:")
        local raw = textutils.serialize(request)
        for rawLine in tostring(raw):gmatch("[^\n]+") do add("  " .. rawLine) end
        add("")
    end

    showDiagnosticViewer("REQUEST DIAGNOSTICS v" .. PROGRAM_VERSION, lines)
end

-- Performs a one-item round-trip through the complete transfer path:
-- Player RS -> barrel -> Colony RS/Warehouse -> barrel -> Player RS.
local function printSourceDiagnostic(itemName)
    local lines = {}
    local function add(s)
        lines[#lines + 1] = tostring(s or "")
    end

    loadState()

    if not refreshPeripherals() or not playerRS then
        add("ERROR: Player RS Bridge unavailable.")
        showDiagnosticViewer("SOURCE v" .. PROGRAM_VERSION, lines)
        return
    end

    if not itemName or itemName == "" then
        add("Usage:")
        add("colony_supply.lua source minecraft:honey_bottle")
        showDiagnosticViewer("SOURCE v" .. PROGRAM_VERSION, lines)
        return
    end

    local _, info, mode = NBTX.buildSourceFilter(playerRS, itemName, 1)

    add("PLAYER RS SOURCE DIAGNOSTIC")
    add("Item: " .. tostring(itemName))
    add("Stock: " .. tostring(getRSAmount(playerRS, itemName)))
    add("Export filter: " .. tostring(mode))
    add("Direction: " .. tostring(CONFIG.playerToChestDirection))
    add("Transfer mode: " ..
        ((CONFIG.usePeripheralTransfer and CONFIG.transferChestName)
            and "PERIPHERAL"
            or "DIRECTIONAL"))
    add("")

    if type(info) == "table" then
        add("Display: " .. tostring(info.displayName or "?"))
        add("Craftable: " .. tostring(info.isCraftable))
        add("Fingerprint: " .. tostring(info.fingerprint or "none"))
        add("NBT: " .. tostring(info.nbt or "none"))
    else
        add("listItems(): no stored item record")
    end

    local barrel = getTransferChest()
    add("")
    add("Barrel visible: " .. tostring(barrel ~= nil))
    if barrel then
        add("Barrel empty: " .. tostring(chestIsEmpty()))
        add("Barrel contents: " ..
            tostring(chestContentsSummary(4) or "unavailable"))
    end

    add("")
    add("Expected for ordinary Honey Bottle:")
    add("Export filter: name")

    showDiagnosticViewer("SOURCE v" .. PROGRAM_VERSION, lines)
end

local function printTransferTest(itemName)
    local lines = {}
    local function add(s)
        lines[#lines + 1] = tostring(s or "")
        updateDiagnosticMonitor("TRANSFER TEST v" .. PROGRAM_VERSION, lines)
    end
    local function finish()
        showDiagnosticViewer("TRANSFER TEST v" .. PROGRAM_VERSION, lines)
    end

    loadState()
    local ready = refreshPeripherals()
    add("Player bridge: " .. tostring(playerBridgeResolvedName or "NOT FOUND"))
    add("Colony bridge: " .. tostring(colonyBridgeResolvedName or "NOT FOUND"))
    add("Player RS: " .. tostring(health.playerRS and "ONLINE" or "OFFLINE"))
    add("Colony RS: " .. tostring(health.colonyRS and "ONLINE" or "OFFLINE"))
    add("Warehouse ext: " .. tostring(health.warehouse and "VISIBLE" or "NOT VISIBLE"))
    add("")

    if not ready then
        add("ERROR: Required peripherals/networks are not ready.")
        add("Run the diag command and verify bridge detection.")
        finish()
        return
    end

    if not itemName or itemName == "" then
        local requests = getColonyRequests()
        if type(requests) == "table" then
            for _, request in pairs(requests) do
                if isRequestActive(request) then
                    for _, candidate in ipairs(requestCandidates(request)) do
                        if getRSAmount(playerRS, candidate.name) > 0 then
                            itemName = candidate.name
                            break
                        end
                    end
                end
                if itemName then break end
            end
        end
    end

    if not itemName then
        add("ERROR: No test item supplied and no stocked active-request item was found.")
        add("Example: colony_supply.lua test minecraft:cobblestone")
        finish()
        return
    end

    local playerBefore = getRSAmount(playerRS, itemName)
    local colonyBefore = getRSAmount(colonyRS, itemName)
    add("Test item: " .. itemName)
    add("Player before: " .. formatNumber(playerBefore))
    add("Colony before: " .. formatNumber(colonyBefore))
    add("")

    if playerBefore < 1 then
        add("FAIL: Player RS does not contain this item.")
        finish()
        return
    end

    add("1/4 Player RS -> barrel (" .. CONFIG.playerToChestDirection .. ")")
    local a, aerr = NBTX.exportFromPlayer(itemName, 1)
    add("    moved=" .. tostring(a) .. (aerr and (" error=" .. tostring(aerr)) or ""))
    if a < 1 then
        add("FAIL at stage 1: Player RS -> barrel")
        add("Check barrel direction and side I/O.")
        finish()
        return
    end

    sleep(0.25)
    add("2/4 Barrel -> Colony RS (" .. CONFIG.chestToColonyDirection .. ")")
    local b, berr = NBTX.importToColony(itemName, 1)
    add("    moved=" .. tostring(b) .. (berr and (" error=" .. tostring(berr)) or ""))
    if b < 1 then
        add("FAIL at stage 2: barrel -> Colony RS")
        add("Attempting recovery to Player RS...")
        local recovered, rerr = NBTX.importToPlayer(itemName, 1)
        add("Recovery moved=" .. tostring(recovered) .. (rerr and (" error=" .. tostring(rerr)) or ""))
        add("Check Warehouse External Storage insert access/filter.")
        finish()
        return
    end

    sleep(0.25)
    add("3/4 Colony RS -> barrel (" .. CONFIG.colonyToChestDirection .. ")")
    local c, cerr = NBTX.exportFromColony(itemName, 1)
    add("    moved=" .. tostring(c) .. (cerr and (" error=" .. tostring(cerr)) or ""))
    if c < 1 then
        add("FAIL at stage 3: Colony RS -> barrel")
        add("Check Warehouse External Storage extraction/filter.")
        finish()
        return
    end

    sleep(0.25)
    add("4/4 Barrel -> Player RS (" .. CONFIG.chestToPlayerDirection .. ")")
    local d, derr = NBTX.importToPlayer(itemName, 1)
    add("    moved=" .. tostring(d) .. (derr and (" error=" .. tostring(derr)) or ""))
    if d < 1 then
        add("FAIL at stage 4: barrel -> Player RS")
        add("One test item remains in the transfer barrel.")
        finish()
        return
    end

    local playerAfter = getRSAmount(playerRS, itemName)
    local colonyAfter = getRSAmount(colonyRS, itemName)
    add("")
    add("PASS: All four transfer stages worked.")
    add("Player after: " .. formatNumber(playerAfter))
    add("Colony after: " .. formatNumber(colonyAfter))
    finish()
end

-- Tests Player RS autocrafting directly without MineColonies request logic.
-- This WILL submit a real crafting job when the item is craftable and not
-- already being crafted.
local function printCraftTest(itemName, requestedCount)
    local lines = {}
    local function add(s)
        lines[#lines + 1] = tostring(s or "")
        updateDiagnosticMonitor("CRAFT TEST v" .. PROGRAM_VERSION, lines)
    end
    local function finish()
        showDiagnosticViewer("CRAFT TEST v" .. PROGRAM_VERSION, lines)
    end

    loadState()

    if not refreshPeripherals() or not playerRS then
        add("ERROR: Player RS Bridge is not available.")
        finish()
        return
    end

    local count = math.max(1, math.floor(tonumber(requestedCount) or 1))

    add("Player bridge: " .. tostring(playerBridgeResolvedName or "NOT FOUND"))
    add("AutoCraft setting: " .. (autoCraftEnabled() and "ON" or "OFF"))
    local safety = NBTX.rsSafetyState()
    add("RS safety latch: " .. (safety.latched and "ACTIVE" or "clear"))
    if safety.latched then
        local due, wait = NBTX.rsSafetyProbeStatus()
        add("RS safety reason: " .. tostring(safety.reason or "?"))
        add("Health probe: " .. (due and "due now" or ("in " .. tostring(wait) .. "s")))
    end
    add("")

    if not itemName or itemName == "" then
        add("ERROR: Specify an item registry name.")
        add("Example:")
        add("colony_supply.lua crafttest minecraft:glass 64")
        finish()
        return
    end

    local stock = getRSAmount(playerRS, itemName)
    add("Item: " .. itemName)
    add("Player stock: " .. formatNumber(stock))
    add("Requested craft: " .. formatNumber(count))

    local okCraftable, craftable, craftableErr = safeCall(
        playerRS,
        "isItemCraftable",
        { name = itemName }
    )

    add("isItemCraftable: " ..
        (okCraftable and tostring(craftable) or ("ERROR " .. tostring(craftableErr or craftable))))

    if not okCraftable or craftable ~= true then
        add("")
        add("FAIL: Player RS does not report a crafting pattern for this item.")
        add("Check the pattern, crafter connection, and RS crafting setup.")
        finish()
        return
    end

    local okCrafting, crafting, craftingErr = safeCall(
        playerRS,
        "isItemCrafting",
        { name = itemName }
    )

    add("isItemCrafting: " ..
        (okCrafting and tostring(crafting) or ("ERROR " .. tostring(craftingErr or crafting))))

    if okCrafting and crafting == true then
        add("")
        add("PASS: A crafting job for this item is already running.")
        finish()
        return
    end

    add("")
    add("Submitting direct craftItem() diagnostic...")
    add("This test does NOT change RS safety/desync state.")

    local okStart, started, startErr = safeCall(
        playerRS,
        "craftItem",
        {
            name = itemName,
            count = count,
        }
    )

    if okStart and started == true then
        add("PASS: craftItem() returned true.")
        add("The Player RS network accepted the crafting job.")
    elseif not okStart then
        add("FAIL: craftItem() raised an error:")
        add(tostring(startErr or started or "unknown craftItem error"))
        add("")
        add("RS DESYNC state was NOT changed by this diagnostic.")
    else
        add("FAIL: craftItem() returned false.")
        add("RS sees the pattern but did not accept the job.")
        add("Check ingredients, processing machines,")
        add("pattern validity, and RS crafting availability.")
    end

    finish()
end

-- Shows every acceptable MineColonies item option and exactly how the
-- supply manager sees it from Player RS. This diagnostic does NOT craft or
-- transfer anything.
local function printCraftDiagnostics()
    local lines = {}
    local function add(s)
        lines[#lines + 1] = tostring(s or "")
    end

    loadState()

    if not refreshPeripherals() then
        add("ERROR: Required peripherals are unavailable.")
        showDiagnosticViewer("CRAFT DIAG v" .. PROGRAM_VERSION, lines)
        return
    end

    local requests, err = getColonyRequests()
    if not requests then
        add("ERROR reading colony requests:")
        add(tostring(err))
        showDiagnosticViewer("CRAFT DIAG v" .. PROGRAM_VERSION, lines)
        return
    end

    add("CRAFT DECISION DIAGNOSTIC")
    add("Version: " .. tostring(PROGRAM_VERSION))
    add("AutoCraft: " .. (autoCraftEnabled() and "ON" or "OFF"))
    local safety = NBTX.rsSafetyState()
    add("RS safety: " .. (safety.latched and "PAUSED" or "healthy"))
    add("Player bridge: " .. tostring(playerBridgeResolvedName or "?"))
    add("Craft policy: VERIFY EXTRACTION FIRST; RS DESYNC NEVER CRAFTS")

    local quarantined = 0
    for key, entry in pairs(state.craftFailures or {}) do
        local left, why = NBTX.craftFailureRemaining(key)
        if left > 0 then
            quarantined = quarantined + 1
            local itemName = type(entry) == "table" and entry.item or key
            local amount = type(entry) == "table" and entry.amount or "?"
            add("QUARANTINE: " .. tostring(itemName) ..
                " x" .. tostring(amount) ..
                " " .. tostring(left) .. "s")
            add("  " .. tostring(why))
        end
    end
    if quarantined > 0 then
        add("")
    end

    local desynced = 0
    for key, entry in pairs(state.rsDesync or {}) do
        if type(entry) == "table" then
            desynced = desynced + 1
            local candidate = {
                name = entry.item or key,
                exactRequestNBT = key:find("|NBT|", 1, true) ~= nil,
                nbtFilter = key:match("|NBT|(.*)$"),
            }
            local _, _, due, wait = NBTX.getRSDesync(candidate)
            add("RS DESYNC: " .. tostring(entry.item or key) ..
                " reported=" .. tostring(entry.reported or "?") ..
                " probe=" .. (due and "DUE" or (tostring(wait) .. "s")))
            add("  " .. tostring(entry.reason or "source export returned 0"))
        end
    end
    if desynced > 0 then
        add("")
    end
    add("")

    local requestCount = 0

    for _, request in pairs(requests) do
        if isRequestActive(request) then
            local requested = getRequestedCount(request)
            local rs = requestStateFor(request.id)
            local supplied = tonumber(rs.supplied) or 0
            local remaining = math.max(0, requested - supplied)
            local candidates = requestCandidates(request)
            local selected = chooseCandidate(request, rs, remaining)

            requestCount = requestCount + 1
            add("REQUEST: " .. tostring(request.name or request.desc or request.id))
            add("Need=" .. tostring(requested) ..
                " Supplied=" .. tostring(supplied) ..
                " Remaining=" .. tostring(remaining))

            if #candidates == 0 then
                add("  NO ITEM CANDIDATES")
            else
                for _, c in ipairs(candidates) do
                    local player = getRSAmount(playerRS, c.name)
                    local wh = getRSAmount(colonyRS, c.name)
                    local craftable, source = NBTX.getCraftability(c.name)
                    local mark = selected and selected.name == c.name and ">" or " "
                    add(mark .. " " .. tostring(c.name))
                    add("    Player=" .. tostring(player) ..
                        " WH=" .. tostring(wh) ..
                        " Craft=" .. tostring(craftable))
                    add("    Craft source: " .. tostring(source))
                    if c.requestHasNBT then
                        local nbtMode = c.exactRequestNBT
                            and "EXACT MATCH"
                            or (c.safeDefaultNBT
                                and "SAFE DEFAULT"
                                or "PRESENT")
                        add("    Request NBT: " .. nbtMode)
                    end
                end
            end
            add("")
        end
    end

    if requestCount == 0 then
        add("No active MineColonies requests.")
    else
        add("> marks the option the program selected.")
    end

    showDiagnosticViewer("CRAFT DIAG v" .. PROGRAM_VERSION, lines)
end

-- Explains which current requests are likely to fail at the source side.
-- This diagnostic does NOT move any items.
local function printBlockedDiagnostics()
    local lines = {}
    local function add(s)
        lines[#lines + 1] = tostring(s or "")
    end

    loadState()

    if not refreshPeripherals() then
        add("ERROR: Required peripherals are not available.")
        showDiagnosticViewer("BLOCKED v" .. PROGRAM_VERSION, lines)
        return
    end

    local requests, err = getColonyRequests()
    if not requests then
        add("ERROR reading requests: " .. tostring(err))
        showDiagnosticViewer("BLOCKED v" .. PROGRAM_VERSION, lines)
        return
    end

    add("SOURCE/BLOCKED DIAGNOSTIC")
    add("Version: " .. tostring(PROGRAM_VERSION))
    add("Player bridge: " .. tostring(playerBridgeResolvedName or "?"))
    add("A -> barrel direction: " .. tostring(CONFIG.playerToChestDirection))
    add("")

    local chest = getTransferChest()
    if chest then
        add("Barrel modem: CONNECTED")
        add("Barrel empty: " .. tostring(chestIsEmpty()))
    else
        add("Barrel modem: NOT CONNECTED")
        add("Barrel contents/locks cannot be inspected by CC.")
    end
    add("")

    local found = 0
    for _, request in pairs(requests) do
        if isRequestActive(request) then
            local id = request.id
            local rsState = requestStateFor(id)
            local requested = getRequestedCount(request)
            local supplied = tonumber(rsState.supplied) or 0
            local remaining = math.max(0, requested - supplied)
            local candidate = chooseCandidate(request, rsState, remaining)

            if candidate and remaining > 0 then
                local stock = getRSAmount(playerRS, candidate.name)
                local craftable = NBTX.isCraftable(candidate.name)
                if stock > 0 or craftable then
                    found = found + 1
                    add(candidate.displayName or candidate.name)
                    add("  id: " .. tostring(candidate.name))
                    add("  need: " .. tostring(remaining) ..
                        "  player: " .. tostring(stock) ..
                        "  craftable: " .. tostring(craftable))
                    local _, info, filterMode =
                        NBTX.buildSourceFilter(playerRS, candidate.name, 1)

                    add("  export filter: " .. tostring(filterMode))

                    if type(info) == "table" then
                        add("  fingerprint: " .. tostring(info.fingerprint or "none"))
                        add("  nbt: " .. tostring(info.nbt or "none"))
                    end
                    add("")
                end
            end
        end
    end

    if found == 0 then
        add("No active request currently has player stock")
        add("or a craftable candidate.")
    end

    add("TIP: run the normal test command with the")
    add("exact blocked registry name, not cobblestone:")
    add("  colony_supply.lua test <item>")

    showDiagnosticViewer("BLOCKED v" .. PROGRAM_VERSION, lines)
end

-- Shows only transfer-barrel discovery/inspection state.
-- Persist the exact modem-connected transfer barrel.
local function setTransferBarrelName(name)
    loadState()

    if not name or name == "" then
        print("Usage: colony_supply.lua setbarrel <peripheral_name>")
        return
    end

    if not peripheral.isPresent(name) then
        print("ERROR: Peripheral is not present: " .. tostring(name))
        return
    end

    if not hasPeripheralType(name, "inventory") then
        print("ERROR: Peripheral is not an inventory: " .. tostring(name))
        return
    end

    state.settings = state.settings or {}
    state.settings.transferChestName = name
    state.settings.transferChestManual = true
    saveState()

    print("Transfer barrel saved:")
    print(name)
end

local function clearTransferBarrelName()
    loadState()
    state.settings = state.settings or {}
    state.settings.transferChestName = nil
    state.settings.transferChestManual = nil
    saveState()

    print("Saved transfer barrel cleared.")
end

local function printBarrelDiagnostics()
    local lines = {}
    local function add(s) lines[#lines + 1] = tostring(s or "") end

    loadState()
    resolveTransferChest()

    add("TRANSFER BARREL DIAGNOSTIC")
    add("Version: " .. tostring(PROGRAM_VERSION))
    add("")
    add("Config name: " .. tostring(CONFIG.transferChestName or "nil"))
    add("Saved name: " ..
        tostring(state.settings and state.settings.transferChestName or "nil"))
    add("Resolved name: " .. tostring(transferChestResolvedName or "NONE"))
    add("Resolution: " .. tostring(transferChestResolution))

    local chest = getTransferChest()
    if chest then
        add("Inventory access: OK")
        add("Empty: " .. tostring(chestIsEmpty()))
        local ok, list = safeCall(chest, "list")
        if ok and type(list) == "table" then
            local stacks = 0
            for _ in pairs(list) do stacks = stacks + 1 end
            add("Occupied slots: " .. tostring(stacks))
            for slot, stack in pairs(list) do
                if type(stack) == "table" then
                    add("  " .. tostring(slot) .. ": " ..
                        tostring(stack.name) .. " x" ..
                        tostring(stack.count or 0))
                end
            end
            if stacks == 0 then
                add("")
                add("NOTE: Empty does not prove the barrel")
                add("accepts every item. Sophisticated Storage")
                add("slot memory/locks or filter upgrades can")
                add("reject an item while the barrel looks empty.")
            end
        end
    else
        add("Inventory access: FAILED")
        add("")
        add("If Resolution is ambiguous-N, set")
        add("CONFIG.transferChestName to the barrel name.")
    end

    showDiagnosticViewer("BARREL v" .. PROGRAM_VERSION, lines)
end

-- Shows the single transaction which is currently holding the transfer barrel.
-- This diagnostic does not move or clear items.
local function printPendingDiagnostics()
    local lines = {}
    local function add(s)
        lines[#lines + 1] = tostring(s or "")
    end

    loadState()
    refreshPeripherals()

    add("TRANSFER/PENDING DIAGNOSTIC")
    add("Version: " .. tostring(PROGRAM_VERSION))
    add("")

    local p = state.pending
    if type(p) ~= "table" then
        add("No pending transaction.")
        add("")
        add("The transfer barrel is not logically locked.")
        showDiagnosticViewer("PENDING v" .. PROGRAM_VERSION, lines)
        return
    end

    add("Kind:       " .. tostring(p.kind or "supply"))
    add("Item:       " .. tostring(p.item or "?"))
    add("Stage:      " .. tostring(p.stage or "?"))
    add("Planned:    " .. tostring(p.planned or 0))
    add("Exported:   " .. tostring(p.exported or 0))
    add("Imported:   " .. tostring(p.imported or 0))
    add("Remaining:  " .. tostring(math.max(
        0,
        (tonumber(p.exported) or tonumber(p.planned) or 0) -
        (tonumber(p.imported) or 0)
    )))
    add("Attempts:   " .. tostring(p.attempts or 0))
    add("Last error: " .. tostring(p.lastError or "none"))
    if p.requestId then add("Request ID: " .. tostring(p.requestId)) end
    add("")

    if p.item then
        add("Player RS:    " .. formatNumber(getRSAmount(playerRS, p.item)))
        add("Colony RS:    " .. formatNumber(getRSAmount(colonyRS, p.item)))
    end

    local chest = getTransferChest()
    if chest then
        add("Barrel modem: CONNECTED")
        add("Barrel name: " .. tostring(transferChestResolvedName))
        add("Detection: " .. tostring(transferChestResolution))
        add("Barrel empty: " .. tostring(chestIsEmpty()))
        add("Barrel item count: " .. tostring(chestItemCount(p.item) or 0))
    else
        add("Barrel modem: NOT RESOLVED")
        add("Detection: " .. tostring(transferChestResolution))
        add("Barrel contents cannot be verified by CC.")
    end

    add("")
    add("If Stage=importing and Remaining>0,")
    add("the destination RS network is refusing")
    add("or unable to accept the remaining items.")

    showDiagnosticViewer("PENDING v" .. PROGRAM_VERSION, lines)
end

-- Warehouse overflow eligibility without moving anything.
local function printOverflowDiagnostics()
    local lines = {}
    local function add(s) lines[#lines + 1] = tostring(s or "") end

    loadState()
    if not refreshPeripherals() then
        add("ERROR: Required RS bridges / colony network are not ready.")
        showDiagnosticViewer("OVERFLOW DIAGNOSTICS v" .. PROGRAM_VERSION, lines)
        return
    end

    local requests = getColonyRequests()
    dashboardRows = {}
    resetStats()

    if type(requests) == "table" then
        for _, request in pairs(requests) do
            if isRequestActive(request) then
                local requested = getRequestedCount(request)
                local rs = requestStateFor(request.id)
                local supplied = tonumber(rs.supplied) or 0
                local provisionalRemaining = math.max(0, requested - supplied)
                local candidate = chooseCandidate(request, rs, provisionalRemaining)
                if candidate then
                    local wh = getRSAmount(colonyRS, candidate.name)
                    local remaining = effectiveRemaining(requested, supplied, wh)
                    dashboardRows[#dashboardRows + 1] = {
                        id = request.id,
                        item = candidate.name,
                        displayName = candidate.displayName or candidate.name,
                        requested = requested,
                        supplied = supplied,
                        remaining = remaining,
                        warehouseStock = wh,
                        playerStock = getRSAmount(playerRS, candidate.name),
                        status = remaining <= 0 and (supplied >= requested and "SUPPLIED" or "IN STOCK") or "WAITING",
                    }
                end
            end
        end
    end
    sortDashboardRows()
    buildSettingsRows()

    local activeDemand = getActiveProtectedDemand()
    local enabled = state.settings and state.settings.overflowEnabled == true
    add("Overflow Return: " .. (enabled and "ON" or "OFF"))
    add("Threshold: Target + " .. tostring(CONFIG.overflowStacks) .. " stacks")
    add("")

    -- Fixed-width columns sized for the normal 5x3 monitor. The generic
    -- viewer wraps only if a smaller monitor is used.
    add(string.format("%-24s %8s %8s %8s %8s %10s",
        "ITEM", "CURRENT", "TARGET", "OVERFLOW", "PROTECT", "ELIGIBLE"))
    add(string.rep("-", 72))

    local eligibleCount = 0
    for _, row in ipairs(settingsRows) do
        local protect = activeDemand[row.item] or 0
        local safeFloor = row.target + protect
        local excess = math.max(0, row.current - safeFloor)
        local eligible = enabled and row.current > row.overflow and excess > 0
        if eligible then eligibleCount = eligibleCount + 1 end
        add(string.format("%-24s %8d %8d %8d %8d %10s",
            truncateText(row.displayName, 24),
            math.floor(row.current or 0),
            math.floor(row.target or 0),
            math.floor(row.overflow or 0),
            math.floor(protect),
            eligible and ("YES " .. tostring(excess)) or "NO"))
    end

    add("")
    add("Eligible items: " .. eligibleCount)
    if not enabled then
        add("Overflow Return is OFF. Enable it on Settings.")
    elseif eligibleCount == 0 then
        add("Nothing exceeds overflow after protected demand.")
    else
        add("Normal mode returns up to " .. tostring(CONFIG.maxOverflowChunk) .. " items per scan.")
    end

    showDiagnosticViewer("OVERFLOW DIAGNOSTICS v" .. PROGRAM_VERSION, lines)
end

local function printHistoryDiagnostics()
    loadState()

    local history = state.history or {}
    print("Transfer History v" .. PROGRAM_VERSION)
    print("Newest first. P>WH=supply, WH>P=overflow")
    print(string.rep("-", 60))

    if #history == 0 then
        print("No successful transfers recorded.")
        return
    end

    for i = 1, math.min(#history, 30) do
        local row = history[i]
        print(string.format(
            "%-8s %-5s %-32s %8d",
            tostring(row.time or "--:--:--"),
            tostring(row.direction or "?"),
            truncateText(row.item or "?", 32),
            tonumber(row.amount) or 0
        ))
    end
end

--------------------------------------------------------------------------
-- Startup
--------------------------------------------------------------------------

local args = { ... }
if args[1] == "diag" then
    printPeripheralDiagnostics()
    return
elseif args[1] == "requests" then
    printRequestDiagnostics()
    return
elseif args[1] == "source" then
    printSourceDiagnostic(args[2])
    return
elseif args[1] == "test" then
    printTransferTest(args[2])
    return
elseif args[1] == "crafttest" then
    printCraftTest(args[2], args[3])
    return
elseif args[1] == "craftdiag" then
    printCraftDiagnostics()
    return
elseif args[1] == "blocked" then
    printBlockedDiagnostics()
    return
elseif args[1] == "setbarrel" then
    setTransferBarrelName(args[2])
    return
elseif args[1] == "clearbarrel" then
    clearTransferBarrelName()
    return
elseif args[1] == "barrel" then
    printBarrelDiagnostics()
    return
elseif args[1] == "pending" then
    printPendingDiagnostics()
    return
elseif args[1] == "overflow" then
    printOverflowDiagnostics()
    return
elseif args[1] == "history" then
    printHistoryDiagnostics()
    return
elseif args[1] == "reset" then
    if fs.exists(CONFIG.stateFile) then fs.delete(CONFIG.stateFile) end
    if fs.exists(CONFIG.stateFile .. ".bak") then fs.delete(CONFIG.stateFile .. ".bak") end
    print("State reset. Transfer chest should be EMPTY before restarting.")
    return
end

loadState()
writeLog("=== Colony Supply Manager starting ===")
refreshPeripherals()

local updateFound, updateResult = UPDATE.check()
if updateFound then
    print("Supply Manager update available: v" .. tostring(PROGRAM_VERSION) .. " -> v" .. tostring(updateResult))
    writeLog("Update available: " .. tostring(PROGRAM_VERSION) .. " -> " .. tostring(updateResult))
elseif UPDATE.checkError then
    print("Update check: " .. tostring(UPDATE.checkError))
    writeLog("Update check failed: " .. tostring(UPDATE.checkError))
else
    print("Supply Manager is current: v" .. tostring(PROGRAM_VERSION))
end

renderTerminal()
renderMonitor()

parallel.waitForAny(
    processorLoop,
    monitorRefreshLoop,
    eventLoop,
    function() UPDATE.loop(renderMonitor) end
)
]====] },
}

local function setColor(c)
    if term.isColor and term.isColor() then term.setTextColor(c) end
end

local function header(title)
    term.setBackgroundColor(colors.black)
    setColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("========================================")
    print(" MineColonies Control Suite")
    print(" " .. tostring(title or "Installer"))
    print(" Suite v" .. SUITE_INFO.suiteVersion)
    print("========================================")
    print()
end

local function versionParts(version)
    local t = {}
    for n in tostring(version or ""):gmatch("(%d+)") do t[#t+1] = tonumber(n) or 0 end
    return t
end

local function versionNewer(remote, current)
    local a, b = versionParts(remote), versionParts(current)
    for i = 1, math.max(#a, #b) do
        local aa, bb = a[i] or 0, b[i] or 0
        if aa > bb then return true end
        if aa < bb then return false end
    end
    return false
end

local function readTable(path)
    if not fs.exists(path) then return nil end
    local h = fs.open(path, "r")
    if not h then return nil end
    local text = h.readAll(); h.close()
    local ok, value = pcall(textutils.unserialize, text)
    if ok and type(value) == "table" then return value end
    return nil
end

local function ensureDirFor(path)
    local dir = fs.getDir(path)
    if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
end

local function syntaxCheck(path, source)
    if not tostring(path):match("%.lua$") then return true end
    local loader, err = load(source, "@" .. tostring(path), "t", {})
    if not loader then return false, tostring(err) end
    return true
end

local function removeManagedArtifacts(path)
    for _, stale in ipairs({ path .. ".bak", path .. ".install_tmp", path .. ".update_tmp" }) do
        if fs.exists(stale) then pcall(fs.delete, stale) end
    end
end

local function canonicalizeInstaller()
    local running = nil
    if shell.getRunningProgram then running = absolutePath(shell.getRunningProgram()) end
    if not running or running == INSTALLER_PATH or not fs.exists(running) then return true end

    removeManagedArtifacts(INSTALLER_PATH)
    if fs.exists(INSTALLER_PATH) then pcall(fs.delete, INSTALLER_PATH) end
    local ok, err = pcall(fs.move, running, INSTALLER_PATH)
    if not ok then
        setColor(colors.orange)
        print("WARNING: Could not rename installer to " .. INSTALLER_PATH .. ": " .. tostring(err))
        setColor(colors.white)
        return false
    end
    setColor(colors.lightGray)
    print("Installer normalized to " .. INSTALLER_PATH)
    setColor(colors.white)
    return true
end

local function writeTransactional(path, source)
    ensureDirFor(path)
    local okSyntax, syntaxErr = syntaxCheck(path, source)
    if not okSyntax then return false, "syntax check failed: " .. tostring(syntaxErr) end

    -- Managed suite code is always recoverable from the published installer.
    -- Avoid a second full-size .bak copy: old + temp + backup can exceed the
    -- normal CC:Tweaked computer filesystem limit even when the final install fits.
    local temp = path .. ".install_tmp"
    removeManagedArtifacts(path)

    local function verifyWritten(target)
        return fs.exists(target) and fs.getSize(target) > 0
    end

    local free = math.huge
    local dir = fs.getDir(path)
    local okFree, freeValue = pcall(fs.getFreeSpace, (dir and dir ~= "") and dir or "/")
    if okFree and type(freeValue) == "number" then free = freeValue end
    local needed = #source + 4096

    if free >= needed then
        local h = fs.open(temp, "w")
        if not h then return false, "cannot create temporary file" end
        h.write(source); h.close()
        if not verifyWritten(temp) then
            pcall(fs.delete, temp)
            return false, "temporary file is empty"
        end

        local ok, err = pcall(function()
            if fs.exists(path) then fs.delete(path) end
            fs.move(temp, path)
        end)
        if not ok then
            if fs.exists(temp) then pcall(fs.delete, temp) end
            return false, "replace failed: " .. tostring(err)
        end
        return true
    end

    -- Low-space fallback. Source has already been syntax checked in memory, so
    -- release the old managed file before writing its replacement.
    local ok, err = pcall(function()
        if fs.exists(path) then fs.delete(path) end
        local h = fs.open(path, "w")
        if not h then error("cannot create replacement file", 0) end
        h.write(source); h.close()
        if not verifyWritten(path) then error("replacement file is empty", 0) end
    end)
    if not ok then return false, "low-space replace failed: " .. tostring(err) end
    return true
end

local function trim(value)
    value = tostring(value or "")
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function githubRawUrl(owner, repository, branch, filename)
    owner = trim(owner)
    repository = trim(repository)
    branch = trim(branch)
    filename = trim(filename)
    if owner == "" or repository == "" or branch == "" or filename == "" then return nil end
    return "https://raw.githubusercontent.com/" .. owner .. "/" .. repository .. "/" .. branch .. "/" .. filename
end

local function normalizeSuiteSource(value)
    value = trim(value)
    if value == "" then return nil end

    -- Raw GitHub URL: already exactly what CC:Tweaked should request.
    if value:match("^https://raw%.githubusercontent%.com/") then
        return value
    end

    -- Normal GitHub file URL -> raw URL.
    local owner, repo, branch, file = value:match("^https://github%.com/([^/]+)/([^/]+)/blob/([^/]+)/(.+)$")
    if owner then
        repo = repo:gsub("%.git$", "")
        return githubRawUrl(owner, repo, branch, file)
    end

    -- GitHub repository URL -> stable raw installer path.
    owner, repo = value:match("^https://github%.com/([^/]+)/([^/#]+)")
    if owner then
        repo = repo:gsub("%.git$", "")
        return githubRawUrl(owner, repo, DEFAULT_GITHUB_BRANCH, DEFAULT_INSTALLER_FILENAME)
    end

    -- owner/repository shorthand.
    owner, repo = value:match("^([^/%s]+)/([^/%s]+)$")
    if owner then
        repo = repo:gsub("%.git$", "")
        return githubRawUrl(owner, repo, DEFAULT_GITHUB_BRANCH, DEFAULT_INSTALLER_FILENAME)
    end

    -- Owner/username alone: use the suite's known repository name.
    if not value:find("://", 1, true) and not value:find("/", 1, true) then
        return githubRawUrl(value, DEFAULT_GITHUB_REPOSITORY, DEFAULT_GITHUB_BRANCH, DEFAULT_INSTALLER_FILENAME)
    end

    -- Also permit another HTTPS host if the suite is later mirrored elsewhere.
    if value:match("^https://") then return value end
    return nil
end

local function cacheBust(url)
    local stamp
    if os.epoch then
        local ok, value = pcall(os.epoch, "utc")
        if ok then stamp = value end
    end
    stamp = stamp or math.floor((os.clock and os.clock() or 0) * 1000)
    return url .. (url:find("?", 1, true) and "&" or "?") .. "cc_cache=" .. tostring(stamp)
end

local function fetchRemoteInstaller(sourceUrl)
    sourceUrl = normalizeSuiteSource(sourceUrl)
    if not sourceUrl then return nil, "no valid suite source URL configured" end
    if type(http) ~= "table" or type(http.get) ~= "function" then return nil, "HTTP API unavailable" end
    local ok, response = pcall(http.get, cacheBust(sourceUrl), {
        ["Cache-Control"] = "no-cache",
        ["User-Agent"] = "MineColonies-Control-Suite-Installer/" .. SUITE_INFO.installerVersion,
    })
    if not ok then return nil, tostring(response) end
    if not response then return nil, "remote source returned no response" end
    local okRead, body = pcall(response.readAll); pcall(response.close)
    if not okRead or type(body) ~= "string" or body == "" then return nil, "could not read remote installer" end
    if not body:find("MineColonies Control Suite Installer", 1, true) then return nil, "remote source is not suite installer" end
    local loader, err = load(body, "@remote_colony_installer", "t", {})
    if not loader then return nil, "remote installer syntax error: " .. tostring(err) end
    local okMeta, meta = pcall(loader, "--metadata")
    if not okMeta or type(meta) ~= "table" or not meta.suiteVersion then return nil, "remote metadata invalid" end
    return body, meta, sourceUrl
end

local function sourceLabel(url)
    url = tostring(url or "")
    local owner, repo, branch = url:match("^https://raw%.githubusercontent%.com/([^/]+)/([^/]+)/([^/]+)/")
    if owner and repo and branch then return "github/" .. owner .. "/" .. repo .. "@" .. branch end
    return url ~= "" and url or "NOT CONFIGURED"
end

local function askSuiteSource(existing)
    local resolved = normalizeSuiteSource(existing) or normalizeSuiteSource(DEFAULT_SUITE_SOURCE_URL)
    if resolved then return resolved end

    while true do
        print()
        setColor(colors.lightGray)
        print("GitHub update source")
        print("Repository: " .. DEFAULT_GITHUB_REPOSITORY)
        print("Branch:     " .. DEFAULT_GITHUB_BRANCH)
        print("Enter your GitHub username/owner.")
        print("You may also paste owner/repository, a GitHub repository URL,")
        print("or the raw install_colony.lua URL.")
        setColor(colors.white)
        write("> ")
        local entered = trim(read())
        local url = normalizeSuiteSource(entered)
        if url then
            setColor(colors.lightGray)
            print("Suite source: " .. sourceLabel(url))
            setColor(colors.white)
            return url
        end
        setColor(colors.red)
        print("A valid GitHub owner or HTTPS source is required for automatic updates.")
        setColor(colors.white)
    end
end

local function writeConfig(appId, sourceUrl)
    sourceUrl = normalizeSuiteSource(sourceUrl) or normalizeSuiteSource(DEFAULT_SUITE_SOURCE_URL)
    local app = SUITE_INFO.apps[appId]
    if not app then return false, "unknown app " .. tostring(appId) end
    local existing = readTable(CONFIG_PATH) or {}
    local cfg = {}
    for k, v in pairs(existing) do cfg[k] = v end
    cfg.app = appId
    cfg.program = app.program
    cfg.displayName = app.displayName
    cfg.appVersion = app.version
    cfg.suiteVersion = SUITE_INFO.suiteVersion
    cfg.suiteSourceUrl = sourceUrl
    cfg.suiteSourceType = sourceUrl and sourceUrl:match("^https://raw%.githubusercontent%.com/") and "github" or "https"
    -- Remove the retired Pastebin setting during migration.
    cfg.suitePastebinId = nil
    ensureDirFor(CONFIG_PATH)
    return writeTransactional(CONFIG_PATH, textutils.serialize(cfg))
end

local function installFiles(appId, sourceUrl, repair)
    local app = SUITE_INFO.apps[appId]
    if not app then return false, "Unknown application: " .. tostring(appId) end

    -- Reclaim space left by older suite installers before writing anything large.
    removeManagedArtifacts(INSTALLER_PATH)
    for _, entry in ipairs(PACKAGE_FILES) do
        if entry.app == "common" or entry.app == appId then removeManagedArtifacts(entry.path) end
    end

    header(repair and "Repair Existing Installation" or ("Install " .. app.displayName))
    local installed = 0
    for _, entry in ipairs(PACKAGE_FILES) do
        if entry.app == "common" or entry.app == appId then
            setColor(colors.cyan)
            print((repair and "Repairing " or "Installing ") .. entry.path .. "...")
            local ok, err = writeTransactional(entry.path, entry.source)
            if not ok then
                setColor(colors.red)
                print("FAILED: " .. entry.path)
                print(tostring(err))
                setColor(colors.white)
                return false, err
            end
            installed = installed + 1
        end
    end
    local okCfg, cfgErr = writeConfig(appId, sourceUrl)
    if not okCfg then
        setColor(colors.red); print("FAILED: " .. CONFIG_PATH); print(tostring(cfgErr)); setColor(colors.white)
        return false, cfgErr
    end
    setColor(colors.lime)
    print()
    print((repair and "Repair" or "Installation") .. " complete: " .. tostring(installed) .. " managed files written.")
    print("Configured app: " .. app.displayName .. " v" .. app.version)
    print("Control Suite: v" .. SUITE_INFO.suiteVersion)
    print("Update source: " .. sourceLabel(sourceUrl))
    setColor(colors.white)
    return true
end

local function maybeSelfRefresh()
    local cfg = readTable(CONFIG_PATH) or {}
    local sourceUrl = normalizeSuiteSource(cfg.suiteSourceUrl) or normalizeSuiteSource(DEFAULT_SUITE_SOURCE_URL)
    if not sourceUrl then return false end
    setColor(colors.lightGray)
    print("Checking installer version...")
    local source, metaOrErr = fetchRemoteInstaller(sourceUrl)
    if not source then
        setColor(colors.orange); print("Installer update check skipped: " .. tostring(metaOrErr)); setColor(colors.white)
        return false
    end
    local meta = metaOrErr
    if not versionNewer(meta.suiteVersion, SUITE_INFO.suiteVersion) then return false end
    setColor(colors.yellow)
    print("Newer suite installer found: v" .. tostring(meta.suiteVersion))
    local ok, err = writeTransactional(INSTALLER_PATH, source)
    if not ok then
        setColor(colors.red); print("Could not update installer: " .. tostring(err)); setColor(colors.white)
        return false
    end
    setColor(colors.lime); print("Installer updated. Relaunching..."); setColor(colors.white)
    sleep(1)
    shell.run(INSTALLER_PATH)
    return true
end

local function repairExisting(nonInteractiveSourceUrl)
    local cfg = readTable(CONFIG_PATH)
    if not cfg or not SUITE_INFO.apps[cfg.app] then
        setColor(colors.red)
        print("No valid existing Control Suite installation was detected.")
        print("Choose an Install option instead.")
        setColor(colors.white)
        return false
    end
    local sourceUrl = normalizeSuiteSource(nonInteractiveSourceUrl)
        or normalizeSuiteSource(cfg.suiteSourceUrl)
        or normalizeSuiteSource(DEFAULT_SUITE_SOURCE_URL)
    if not sourceUrl then sourceUrl = askSuiteSource(nil) end
    return installFiles(cfg.app, sourceUrl, true)
end

-- Non-interactive path used by the shared updater after it has already replaced
-- this installer with the newly downloaded package.
if mode == "--update" then
    local appId = arg2
    local sourceUrl = normalizeSuiteSource(arg3)
    if not sourceUrl then return false end
    local ok = installFiles(appId, sourceUrl, false)
    if not ok then return false end
    return true
elseif mode == "--repair" then
    return repairExisting(arg2)
end

canonicalizeInstaller()
header("Installer")
if maybeSelfRefresh() then return end

local existing = readTable(CONFIG_PATH)
if existing and SUITE_INFO.apps[existing.app] then
    setColor(colors.lightGray)
    print("Existing installation: " .. tostring(existing.displayName or existing.app) ..
        "  app v" .. tostring(existing.appVersion or "?") ..
        "  suite v" .. tostring(existing.suiteVersion or "?"))
    local existingSource = normalizeSuiteSource(existing.suiteSourceUrl)
    if existingSource then print("Update source: " .. sourceLabel(existingSource)) end
    print()
    setColor(colors.white)
end

print("[1] Install Colony Command Center")
print("[2] Install Colony Supply Manager")
print("[3] Repair Existing Installation")
print("[4] Cancel")
print()
write("Selection: ")
local choice = read()

if choice == "4" then
    print("Cancelled.")
    return
elseif choice == "3" then
    local ok = repairExisting()
    if ok then print("Rebooting..."); sleep(1); os.reboot() end
    return
end

local appId = (choice == "1") and "command" or ((choice == "2") and "supply" or nil)
if not appId then
    setColor(colors.red); print("Invalid selection."); setColor(colors.white); return
end

local currentSource = existing and existing.suiteSourceUrl or nil
local sourceUrl = askSuiteSource(currentSource)
local ok = installFiles(appId, sourceUrl, false)
if ok then
    print("Rebooting...")
    sleep(1)
    os.reboot()
end
