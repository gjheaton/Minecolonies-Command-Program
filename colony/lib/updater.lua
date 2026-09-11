-- MineColonies Control Suite - shared suite updater
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
