-- MineColonies Control Suite Installer
-- Suite package version 1.1.28
--
-- Modular GitHub installer.
-- The repository layout mirrors the CC:Tweaked filesystem.
-- This installer downloads managed files from the same repository/branch as itself.
-- Fresh installs, Repair, and application updates use the configured source automatically.

local mode, arg2, arg3 = ...

local SUITE_INFO = {
    suiteVersion = "1.1.28",
    installerVersion = "1.1.28",
    apps = {
        command = { version = "2.16", program = "/colony_command.lua", displayName = "MineColonies Command Center" },
        supply = { version = "2.63", program = "/colony_supply.lua", displayName = "MineColonies Supply Manager" },
    },
    components = {
        startup = "1.0.0", util = "1.1.0", ui = "1.1.0",
        version = "1.0.0", updater = "1.1.1", installer = "1.1.28",
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
    { path = "/startup.lua",            app = "common",  remote = "startup.lua" },
    { path = "/colony/manifest.lua",    app = "common",  remote = "colony/manifest.lua" },
    { path = "/colony/lib/util.lua",    app = "common",  remote = "colony/lib/util.lua" },
    { path = "/colony/lib/ui.lua",      app = "common",  remote = "colony/lib/ui.lua" },
    { path = "/colony/lib/version.lua", app = "common",  remote = "colony/lib/version.lua" },
    { path = "/colony/lib/updater.lua", app = "common",  remote = "colony/lib/updater.lua" },
    { path = "/colony_command.lua",     app = "command", remote = "colony_command.lua" },
    { path = "/colony_supply.lua",      app = "supply",  remote = "colony_supply.lua" },
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

local function repositoryBaseUrl(sourceUrl)
    sourceUrl = normalizeSuiteSource(sourceUrl)
    if not sourceUrl then return nil end
    sourceUrl = sourceUrl:gsub("[?#].*$", "")
    return sourceUrl:match("^(.*)/[^/]+$")
end

local function fetchManagedFile(sourceUrl, entry)
    if type(http) ~= "table" or type(http.get) ~= "function" then
        return nil, "HTTP API unavailable"
    end
    local base = repositoryBaseUrl(sourceUrl)
    if not base then return nil, "could not determine repository base URL" end

    local remote = tostring(entry.remote or ""):gsub("^/+", "")
    if remote == "" then return nil, "remote path is missing for " .. tostring(entry.path) end

    local url = base .. "/" .. remote
    local ok, response = pcall(http.get, cacheBust(url), {
        ["Cache-Control"] = "no-cache",
        ["User-Agent"] = "MineColonies-Control-Suite-Installer/" .. SUITE_INFO.installerVersion,
    })
    if not ok then return nil, "HTTP request failed: " .. tostring(response) end
    if not response then return nil, "remote source returned no response: " .. remote end

    local okRead, body = pcall(response.readAll)
    pcall(response.close)
    if not okRead or type(body) ~= "string" or body == "" then
        return nil, "could not read " .. remote
    end
    return body
end

local function readFileSource(path)
    if not fs.exists(path) then return false end
    local h = fs.open(path, "r")
    if not h then return nil, "cannot read existing " .. tostring(path) end
    local body = h.readAll()
    h.close()
    return body
end

local function restoreFileSource(path, oldSource)
    local ok, err = pcall(function()
        if fs.exists(path) then fs.delete(path) end
        if oldSource ~= false then
            ensureDirFor(path)
            local h = fs.open(path, "w")
            if not h then error("cannot recreate " .. tostring(path), 0) end
            h.write(oldSource)
            h.close()
        end
    end)
    if not ok then return false, tostring(err) end
    return true
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

    sourceUrl = normalizeSuiteSource(sourceUrl)
    if not sourceUrl then return false, "No valid suite source URL configured" end

    removeManagedArtifacts(INSTALLER_PATH)
    local selected = {}
    for _, entry in ipairs(PACKAGE_FILES) do
        if entry.app == "common" or entry.app == appId then
            selected[#selected + 1] = entry
            removeManagedArtifacts(entry.path)
        end
    end

    header(repair and "Repair Existing Installation" or ("Install " .. app.displayName))
    print("Source: " .. sourceLabel(sourceUrl))
    print()

    -- Download every required file before modifying the live installation.
    -- This prevents a transient GitHub/network failure from leaving a mixed suite.
    local downloaded = {}
    for i, entry in ipairs(selected) do
        setColor(colors.cyan)
        print("Downloading [" .. tostring(i) .. "/" .. tostring(#selected) .. "] " .. entry.path .. "...")
        local body, err = fetchManagedFile(sourceUrl, entry)
        if not body then
            setColor(colors.red)
            print("DOWNLOAD FAILED: " .. entry.path)
            print(tostring(err))
            setColor(colors.white)
            return false, err
        end

        local okSyntax, syntaxErr = syntaxCheck(entry.path, body)
        if not okSyntax then
            setColor(colors.red)
            print("VALIDATION FAILED: " .. entry.path)
            print(tostring(syntaxErr))
            setColor(colors.white)
            return false, syntaxErr
        end
        downloaded[entry.path] = body
    end

    -- Keep current managed files in memory so an unexpected write failure can
    -- restore the previous working installation without consuming disk space.
    local previous = {}
    for _, entry in ipairs(selected) do
        local old, readErr = readFileSource(entry.path)
        if old == nil then
            setColor(colors.red)
            print("Could not preserve current file before update: " .. entry.path)
            print(tostring(readErr))
            setColor(colors.white)
            return false, readErr
        end
        previous[entry.path] = old
    end
    local previousConfig, configReadErr = readFileSource(CONFIG_PATH)
    if previousConfig == nil then
        setColor(colors.red)
        print("Could not preserve current configuration.")
        print(tostring(configReadErr))
        setColor(colors.white)
        return false, configReadErr
    end

    local function rollback()
        setColor(colors.orange)
        print("Restoring previous installation...")
        for _, entry in ipairs(selected) do
            local okRestore, restoreErr = restoreFileSource(entry.path, previous[entry.path])
            if not okRestore then
                print("WARNING: restore failed for " .. entry.path .. ": " .. tostring(restoreErr))
            end
        end
        local okRestoreCfg, restoreCfgErr = restoreFileSource(CONFIG_PATH, previousConfig)
        if not okRestoreCfg then
            print("WARNING: configuration restore failed: " .. tostring(restoreCfgErr))
        end
        setColor(colors.white)
    end

    local installed = 0
    for _, entry in ipairs(selected) do
        setColor(colors.cyan)
        print((repair and "Repairing " or "Installing ") .. entry.path .. "...")
        local ok, err = writeTransactional(entry.path, downloaded[entry.path])
        if not ok then
            setColor(colors.red)
            print("FAILED: " .. entry.path)
            print(tostring(err))
            rollback()
            setColor(colors.white)
            return false, err
        end
        installed = installed + 1
    end

    local okCfg, cfgErr = writeConfig(appId, sourceUrl)
    if not okCfg then
        setColor(colors.red)
        print("FAILED: " .. CONFIG_PATH)
        print(tostring(cfgErr))
        rollback()
        setColor(colors.white)
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
