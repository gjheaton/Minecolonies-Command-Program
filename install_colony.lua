-- MineColonies Control Suite Installer
-- Suite package version 4.0.0
-- Download this one file to install, update, or repair any suite role.
-- A clean installation removes previous SUITE data after the entire package
-- has been downloaded and validated. Updates and repairs preserve all data.

local mode, arg2, arg3 = ...

-- Keep this literal before any access to globals: the shared updater evaluates
-- --metadata in an empty environment without executing installation code.
local SUITE_INFO = {
    suiteVersion = "4.0.0", installerVersion = "4.0.0", installationSchema = 4,
    apps = {
        master = { version = "4.0.0", program = "/colony_master.lua", displayName = "MineColonies Supply Master" },
        supply = { version = "4.0.0", program = "/colony_supply.lua", displayName = "MineColonies Colony Supply" },
        command = { version = "3.0.7", program = "/colony_command.lua", displayName = "MineColonies Command Center" },
    },
    components = {
        startup = "1.1.0", installer = "4.0.0", util = "1.1.0", ui = "1.1.0",
        version = "1.0.0", updater = "1.2.0", network = "4.0.0",
    },
    files = {
        { path = "/install_colony.lua", app = "common", remote = "install_colony.lua" },
        { path = "/startup.lua", app = "common", remote = "startup.lua" },
        { path = "/colony/manifest.lua", app = "common", remote = "colony/manifest.lua" },
        { path = "/colony/lib/util.lua", app = "common", remote = "colony/lib/util.lua" },
        { path = "/colony/lib/ui.lua", app = "common", remote = "colony/lib/ui.lua" },
        { path = "/colony/lib/version.lua", app = "common", remote = "colony/lib/version.lua" },
        { path = "/colony/lib/updater.lua", app = "common", remote = "colony/lib/updater.lua" },
        { path = "/colony/network/config.lua", app = "network", remote = "colony/network/config.lua" },
        { path = "/colony/network/store.lua", app = "network", remote = "colony/network/store.lua" },
        { path = "/colony/network/io.lua", app = "network", remote = "colony/network/io.lua" },
        { path = "/colony/network/protocol.lua", app = "network", remote = "colony/network/protocol.lua" },
        { path = "/colony/network/telemetry.lua", app = "network", remote = "colony/network/telemetry.lua" },
        { path = "/colony/network/displays.lua", app = "network", remote = "colony/network/displays.lua" },
        { path = "/colony/network/setup.lua", app = "network", remote = "colony/network/setup.lua" },
        { path = "/colony/network/setup_ui.lua", app = "network", remote = "colony/network/setup_ui.lua" },
        { path = "/colony/network/runtime.lua", app = "network", remote = "colony/network/runtime.lua" },
        { path = "/colony/network/ui.lua", app = "network", remote = "colony/network/ui.lua" },
        { path = "/colony/network/diagnostics.lua", app = "network", remote = "colony/network/diagnostics.lua" },
        { path = "/colony/supply/matcher.lua", app = "network", remote = "colony/supply/matcher.lua" },
        { path = "/colony_master.lua", app = "master", remote = "colony_master.lua" },
        { path = "/colony/network/master.lua", app = "master", remote = "colony/network/master.lua" },
        { path = "/colony_supply.lua", app = "supply", remote = "colony_supply.lua" },
        { path = "/colony/network/client.lua", app = "supply", remote = "colony/network/client.lua" },
        { path = "/colony_command.lua", app = "command", remote = "colony_command.lua" },
        { path = "/colony/command/visitor_jobs.lua", app = "command", remote = "colony/command/visitor_jobs.lua" },
    },
}
if mode == "--metadata" then return SUITE_INFO end

local DEFAULT_OWNER = "gjheaton"
local DEFAULT_REPOSITORY = "Minecolonies-Command-Program"
local DEFAULT_BRANCH = "supply-master-colony"
local DEFAULT_SOURCE = "https://raw.githubusercontent.com/" .. DEFAULT_OWNER .. "/" ..
    DEFAULT_REPOSITORY .. "/" .. DEFAULT_BRANCH .. "/install_colony.lua"
local CONFIG_PATH = "/colony/app.cfg"
local INSTALLER_PATH = "/install_colony.lua"
local TRANSACTION = "/.colony_install_transaction"
local TRANSACTION_MARKER = "MineColonies Control Suite Install Transaction v1\n"

local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function ensureDir(path)
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
end

local function readFile(path)
    if not fs.exists(path) then return nil end
    if fs.isDir(path) then return nil, "Expected a file: " .. path end
    local h, err = fs.open(path, "r")
    if not h then return nil, err or ("Cannot read " .. path) end
    local ok, body = pcall(h.readAll)
    pcall(h.close)
    if not ok then return nil, tostring(body) end
    return body
end

local function writeFile(path, body)
    ensureDir(path)
    local h, err = fs.open(path, "w")
    if not h then error(err or ("Cannot write " .. path), 0) end
    local ok, writeErr = pcall(h.write, body)
    pcall(h.close)
    if not ok then error(tostring(writeErr), 0) end
    local written, readErr = readFile(path)
    if written ~= body then error(readErr or ("Write verification failed: " .. path), 0) end
end

local function readTable(path)
    local body = readFile(path)
    if not body then return nil end
    local ok, value = pcall(textutils.unserialize, body)
    if ok and type(value) == "table" then return value end
    return nil
end

local function colour(value)
    if term and term.isColor and term.isColor() then term.setTextColor(value) end
end

local function header(title)
    if term then
        term.setBackgroundColor(colors.black)
        colour(colors.white)
        term.clear()
        term.setCursorPos(1, 1)
    end
    print("MineColonies Control Suite v" .. SUITE_INFO.suiteVersion)
    print(tostring(title or "Installer"))
    print()
end

local function sourceURL(value)
    value = trim(value)
    if value == "" then return nil end
    local owner, repo, ref = value:match("^https://github%.com/([^/]+)/([^/]+)/blob/([^/]+)/install_colony%.lua$")
    if owner then return "https://raw.githubusercontent.com/" .. owner .. "/" .. repo .. "/" .. ref .. "/install_colony.lua" end
    owner, repo = value:match("^https://github%.com/([^/]+)/([^/#]+)/?$")
    if not owner then owner, repo = value:match("^([^/%s]+)/([^/%s]+)$") end
    if owner then
        return "https://raw.githubusercontent.com/" .. owner .. "/" .. repo:gsub("%.git$", "") ..
            "/" .. DEFAULT_BRANCH .. "/install_colony.lua"
    end
    if not value:find("/", 1, true) and not value:find(":", 1, true) then
        return "https://raw.githubusercontent.com/" .. value .. "/" .. DEFAULT_REPOSITORY ..
            "/" .. DEFAULT_BRANCH .. "/install_colony.lua"
    end
    if value:match("^https://") and value:gsub("[?#].*$", ""):match("/install_colony%.lua$") then return value end
    return nil
end

local function fetch(url)
    if type(http) ~= "table" or type(http.get) ~= "function" then return nil, "HTTP API is unavailable." end
    local ok, response, message = pcall(http.get, url, {
        ["Cache-Control"] = "no-cache",
        ["User-Agent"] = "MineColonies-Control-Suite-Installer/" .. SUITE_INFO.installerVersion,
    })
    if not ok then return nil, tostring(response) end
    if not response then return nil, tostring(message or ("No response from " .. url)) end
    local readOK, body = pcall(response.readAll)
    pcall(response.close)
    if not readOK or type(body) ~= "string" or body == "" then return nil, "Empty/unreadable response: " .. url end
    return body
end

local function immutableSource(source)
    local plain = source:gsub("[?#].*$", "")
    local owner, repo, ref = plain:match("^https://raw%.githubusercontent%.com/([^/]+)/([^/]+)/([^/]+)/install_colony%.lua$")
    if not owner then
        return nil, "Use a raw.githubusercontent.com installer URL for this release; an immutable Git commit is required."
    end
    if #ref == 40 and ref:match("^%x+$") then return plain end
    -- Resolve the moving branch ONCE; every file below comes from that same
    -- immutable commit, including the installer and manifest.
    local encodedRef = ref:gsub("[^%w%._%-]", function(c) return string.format("%%%02X", string.byte(c)) end)
    local body, err = fetch("https://api.github.com/repos/" .. owner .. "/" .. repo .. "/git/ref/heads/" .. encodedRef)
    if not body then
        return nil, "Cannot resolve branch to a commit: " .. tostring(err) ..
            ". Allow api.github.com, or supply a raw installer URL containing its full 40-character commit SHA."
    end
    local ok, data = pcall(textutils.unserializeJSON, body)
    local sha = ok and type(data) == "table" and type(data.object) == "table" and data.object.sha or nil
    if type(sha) ~= "string" or #sha ~= 40 or not sha:match("^%x+$") or data.object.type ~= "commit" then
        return nil, "GitHub returned an invalid branch commit. No installation files were changed."
    end
    return "https://raw.githubusercontent.com/" .. owner .. "/" .. repo .. "/" .. sha .. "/install_colony.lua"
end

local function compile(path, body)
    local chunk, err = load(body, "@" .. path, "t", {})
    if not chunk then return nil, "Syntax error in " .. path .. ": " .. tostring(err) end
    return chunk
end

local function metadata(body)
    if not body:find("MineColonies Control Suite Installer", 1, true) then return nil, "Source is not the suite installer." end
    local chunk, err = compile("remote_install_colony.lua", body)
    if not chunk then return nil, err end
    local ok, info = pcall(chunk, "--metadata")
    if not ok or type(info) ~= "table" or type(info.apps) ~= "table" or
        type(info.files) ~= "table" or type(info.components) ~= "table" or
        info.installationSchema ~= 4 or type(info.suiteVersion) ~= "string" or
        type(info.installerVersion) ~= "string" then
        return nil, "Remote installer metadata is incompatible with installation schema 4."
    end
    return info
end

local function selectFiles(info, appId)
    if type(info.apps[appId]) ~= "table" then return nil, "Unknown application: " .. tostring(appId) end
    local selected, seen = {}, {}
    for _, entry in ipairs(info.files) do
        if type(entry) ~= "table" then return nil, "Invalid package file entry." end
        local path, remote = entry.path, entry.remote
        if type(path) ~= "string" or type(remote) ~= "string" or path ~= "/" .. remote or
            remote:find("..", 1, true) or not remote:match("^[%w_/%.-]+%.lua$") or
            (not path:match("^/colony/") and path ~= "/startup.lua" and path ~= INSTALLER_PATH and
                path ~= "/colony_master.lua" and path ~= "/colony_supply.lua" and path ~= "/colony_command.lua") or seen[path] then
            return nil, "Invalid or duplicate managed path: " .. tostring(path)
        end
        seen[path] = true
        if entry.app == "common" or entry.app == appId or
            (entry.app == "network" and (appId == "master" or appId == "supply")) then
            selected[#selected + 1] = entry
        end
    end
    local app = info.apps[appId]
    if type(app.version) ~= "string" or type(app.displayName) ~= "string" or
        app.program ~= ({ master = "/colony_master.lua", supply = "/colony_supply.lua", command = "/colony_command.lua" })[appId] then
        return nil, "Invalid role metadata."
    end
    local required = { [INSTALLER_PATH] = false, ["/startup.lua"] = false,
        ["/colony/manifest.lua"] = false, [app.program] = false }
    for _, entry in ipairs(selected) do if required[entry.path] ~= nil then required[entry.path] = true end end
    for path, exists in pairs(required) do if not exists then return nil, "Package is missing " .. path end end
    return selected
end

local function validateManifest(body, info)
    local chunk, err = compile("/colony/manifest.lua", body)
    if not chunk then return false, err end
    local ok, manifest = pcall(chunk)
    if not ok or type(manifest) ~= "table" or manifest.suiteVersion ~= info.suiteVersion or
        manifest.installationSchema ~= info.installationSchema or type(manifest.apps) ~= "table" or
        type(manifest.components) ~= "table" or type(manifest.files) ~= "table" then
        return false, "Manifest and installer metadata disagree."
    end
    for id, app in pairs(info.apps) do
        local other = manifest.apps[id]
        if type(other) ~= "table" or other.version ~= app.version or other.program ~= app.program then
            return false, "Manifest application metadata disagrees for " .. id
        end
    end
    for id, version in pairs(info.components) do
        if manifest.components[id] ~= version then return false, "Manifest component metadata disagrees for " .. id end
    end
    if #manifest.files ~= #info.files then return false, "Manifest package file list disagrees." end
    for i, entry in ipairs(info.files) do
        local other = manifest.files[i]
        if type(other) ~= "table" or other.path ~= entry.path or other.app ~= entry.app then
            return false, "Manifest package file entry disagrees at " .. tostring(i)
        end
    end
    return true
end

local function safeLivePath(path)
    if type(path) ~= "string" or path:find("..", 1, true) then return false end
    if path == "/colony" or path:match("^/colony/") then return true end
    local root = path:gsub("%.bak$", ""):gsub("%.old$", ""):gsub("%.tmp$", ""):
        gsub("%.install_tmp$", ""):gsub("%.update_tmp$", "")
    return root == INSTALLER_PATH or root == "/startup.lua" or root == "/colony_master.lua" or
        root == "/colony_supply.lua" or root == "/colony_command.lua" or root == "/colony_supply_state.txt" or
        root == "/colony_supply.log" or root == "/colony_requests_debug.txt"
end

local function recoverTransaction()
    if not fs.exists(TRANSACTION) then return true end
    if readFile(TRANSACTION .. "/marker.txt") ~= TRANSACTION_MARKER then
        return false, "Unrecognized " .. TRANSACTION .. "; refusing to remove unrelated files."
    end
    local plan = readTable(TRANSACTION .. "/plan.cfg")
    if readFile(TRANSACTION .. "/committed.txt") == "committed\n" then
        fs.delete(TRANSACTION)
        return true
    end
    if fs.exists(TRANSACTION .. "/applying.txt") then
        if type(plan) ~= "table" or plan.schema ~= 1 or type(plan.paths) ~= "table" then
            return false, "Installation recovery plan is unreadable; preserve " .. TRANSACTION .. " for recovery."
        end
        for _, entry in ipairs(plan.paths) do
            if type(entry) ~= "table" or not safeLivePath(entry.path) or type(entry.existed) ~= "boolean" then
                return false, "Invalid installation recovery plan; no recovery files were deleted."
            end
        end
        print("Recovering interrupted installation...")
        for i = #plan.paths, 1, -1 do
            local entry = plan.paths[i]
            local backup = TRANSACTION .. "/old" .. entry.path
            if fs.exists(backup) then
                if fs.exists(entry.path) then fs.delete(entry.path) end
                ensureDir(entry.path)
                fs.move(backup, entry.path)
            elseif not entry.existed and fs.exists(entry.path) then
                fs.delete(entry.path)
            end
        end
    end
    fs.delete(TRANSACTION)
    return true
end

-- Legacy paths were found in the published suite's complete Git history.
-- Never clear the filesystem, Ender Chest contents, or other people's files.
local CLEAN_ROOTS = {
    "/colony", "/colony_master.lua", "/colony_supply.lua", "/colony_command.lua",
    "/colony_supply_state.txt", "/colony_supply.log", "/colony_requests_debug.txt",
}

local function cleanConfirmation(appId)
    colour(colors.red)
    print("CLEAN INSTALL: " .. SUITE_INFO.apps[appId].displayName)
    print("This removes ALL previous Control Suite configuration, request state,")
    print("logs and managed programs on THIS computer, including /colony and")
    print("legacy supply state/log/debug files. /startup.lua will be replaced.")
    print("Other files and Minecraft/Ender Chest items are not removed.")
    colour(colors.yellow)
    print("First v4 installation requires this reset. Future --update and --repair")
    print("preserve settings and request records. Stop old colony PRS controllers")
    print("before connecting the new single master to PRS.")
    colour(colors.white)
    write("Type CLEAN to continue: ")
    return trim(read()) == "CLEAN"
end

local function install(appId, requestedSource, clean)
    local recovered, recoveryError = recoverTransaction()
    if not recovered then return false, recoveryError end
    local cfg = readTable(CONFIG_PATH)
    if not clean and (type(cfg) ~= "table" or cfg.installationSchema ~= 4 or cfg.app ~= appId or cfg.role ~= appId) then
        return false, "Update/repair requires an existing v4 installation of the same role. Run --install " ..
            tostring(appId) .. " for the required clean migration."
    end
    if not SUITE_INFO.apps[appId] then return false, "Unknown application: " .. tostring(appId) end
    -- Never silently replace a startup program belonging to another application.
    local oldStartup, startupReadError = readFile("/startup.lua")
    if fs.exists("/startup.lua") and not oldStartup then
        return false, startupReadError or "Cannot verify ownership of /startup.lua."
    end
    if oldStartup and not oldStartup:find("MineColonies Control Suite", 1, true) then
        return false, "Existing /startup.lua belongs to another program. Move it aside before installing this suite."
    end
    if clean and not cleanConfirmation(appId) then return false, "Clean installation cancelled; existing data was preserved." end
    -- The v3 configuration may still point at main's legacy package. A clean
    -- migration must use this installer's v4 source unless explicitly supplied.
    local existingSource = cfg and cfg.installationSchema == 4 and cfg.suiteSourceUrl or nil
    local source = sourceURL(requestedSource) or sourceURL(existingSource) or DEFAULT_SOURCE
    if requestedSource and not sourceURL(requestedSource) then return false, "Invalid HTTPS installer source." end
    header(clean and "Clean installation" or "Update / repair (data preserved)")
    print("Update source: " .. source)
    local pinned, pinError = immutableSource(source)
    if not pinned then return false, pinError end
    print("Package source: " .. pinned)
    local installer, fetchError = fetch(pinned)
    if not installer then return false, fetchError end
    local info, metadataError = metadata(installer)
    if not info then return false, metadataError end
    local selected, selectionError = selectFiles(info, appId)
    if not selected then return false, selectionError end
    local base = pinned:match("^(.*)/install_colony%.lua$")
    local downloaded = {}
    for i, entry in ipairs(selected) do
        colour(colors.cyan)
        print("Downloading [" .. i .. "/" .. #selected .. "] " .. entry.path)
        local body, err
        if entry.path == INSTALLER_PATH then body = installer else body, err = fetch(base .. "/" .. entry.remote) end
        if not body then return false, "Download failed for " .. entry.path .. ": " .. tostring(err) end
        local chunk, syntaxError = compile(entry.path, body)
        if not chunk then return false, syntaxError end
        downloaded[entry.path] = body
    end
    colour(colors.white)
    local valid, manifestError = validateManifest(downloaded["/colony/manifest.lua"], info)
    if not valid then return false, manifestError end
    local newCfg = {}
    if not clean then for key, value in pairs(cfg) do newCfg[key] = value end end
    local app = info.apps[appId]
    newCfg.schema, newCfg.installationSchema, newCfg.role = 4, 4, appId
    newCfg.app, newCfg.program, newCfg.displayName = appId, app.program, app.displayName
    newCfg.appVersion, newCfg.suiteVersion = app.version, info.suiteVersion
    newCfg.suiteSourceUrl, newCfg.installedSourceUrl, newCfg.suiteSourceType = source, pinned, "github"
    newCfg.suitePastebinId = nil
    downloaded[CONFIG_PATH] = textutils.serialize(newCfg)

    local paths, seen = {}, {}
    local function include(path)
        if seen[path] then return end
        seen[path] = true
        paths[#paths + 1] = { path = path, existed = fs.exists(path) }
    end
    -- Install the launcher first so it can recognize an interrupted transaction.
    include("/startup.lua")
    if clean then
        for _, path in ipairs(CLEAN_ROOTS) do
            include(path)
            if path ~= "/colony" then
                for _, suffix in ipairs({ ".bak", ".old", ".tmp", ".install_tmp", ".update_tmp" }) do include(path .. suffix) end
            end
        end
        include(INSTALLER_PATH)
        for _, suffix in ipairs({ ".bak", ".old", ".tmp", ".install_tmp", ".update_tmp" }) do include(INSTALLER_PATH .. suffix) end
    else
        for _, entry in ipairs(selected) do include(entry.path) end
        include(CONFIG_PATH)
    end

    -- Staged files are renamed into place, not duplicated. Retain only a second
    -- installer copy so startup can always run recovery after an interruption.
    local requiredBytes = 16384 + #installer + 512
    for _, body in pairs(downloaded) do requiredBytes = requiredBytes + #body + 512 end
    local free = fs.getFreeSpace("/")
    if type(free) == "number" and free < requiredBytes then
        return false, "Not enough free space to stage a safe installation (need " .. requiredBytes ..
            " bytes, have " .. free .. "). Existing files and data were preserved."
    end
    local ok, err = pcall(function()
        fs.makeDir(TRANSACTION)
        writeFile(TRANSACTION .. "/marker.txt", TRANSACTION_MARKER)
        for path, body in pairs(downloaded) do writeFile(TRANSACTION .. "/new" .. path, body) end
        writeFile(TRANSACTION .. "/plan.cfg", textutils.serialize({ schema = 1, paths = paths }))
        if not readTable(TRANSACTION .. "/plan.cfg") then error("Recovery plan verification failed.", 0) end
        writeFile(TRANSACTION .. "/applying.txt", "applying\n")
        for _, entry in ipairs(paths) do
            if entry.existed then
                local backup = TRANSACTION .. "/old" .. entry.path
                ensureDir(backup)
                fs.move(entry.path, backup)
            end
            -- The launcher is replaced immediately; remaining files are written
            -- only after all previous data/code has been safely renamed aside.
            if entry.path == "/startup.lua" then fs.move(TRANSACTION .. "/new/startup.lua", entry.path) end
        end
        for _, entry in ipairs(selected) do
            if entry.path ~= "/startup.lua" then
                ensureDir(entry.path)
                if entry.path == INSTALLER_PATH then
                    fs.copy(TRANSACTION .. "/new" .. entry.path, entry.path)
                else
                    fs.move(TRANSACTION .. "/new" .. entry.path, entry.path)
                end
                if readFile(entry.path) ~= downloaded[entry.path] then error("Copy verification failed: " .. entry.path, 0) end
            end
        end
        ensureDir(CONFIG_PATH)
        fs.move(TRANSACTION .. "/new" .. CONFIG_PATH, CONFIG_PATH)
        if readFile(CONFIG_PATH) ~= downloaded[CONFIG_PATH] then error("Configuration write verification failed.", 0) end
        writeFile(TRANSACTION .. "/committed.txt", "committed\n")
    end)
    if not ok then
        local restored, restoreError = pcall(recoverTransaction)
        if not restored or restoreError ~= true then
            return false, "Installation failed: " .. tostring(err) .. "; recovery requires running " ..
                TRANSACTION .. "/new/install_colony.lua --recover. Keep the transaction directory."
        end
        return false, "Installation failed and the previous installation was restored: " .. tostring(err)
    end
    -- A committed transaction is safe to remove; recovery also handles a reboot
    -- between this commit marker and cleanup without undoing the new package.
    local cleaned, cleanupError = pcall(recoverTransaction)
    if not cleaned or cleanupError ~= true then
        print("Installation committed. Transaction cleanup will be retried by startup.")
    end
    colour(colors.lime)
    print("Installed " .. app.displayName .. " v" .. app.version .. "; suite v" .. info.suiteVersion)
    print(clean and "Previous suite data was removed." or "Settings and request records were preserved.")
    colour(colors.white)
    if appId == "master" or appId == "supply" then
        print("Start " .. app.program .. " setup to configure peripherals and routing,")
        print("or reboot to start the configuration wizard.")
    end
    return true
end

local function requireSuccess(ok, err)
    if not ok then error(tostring(err or "Installation failed."), 0) end
    return true
end

if mode == "--recover" then
    return requireSuccess(recoverTransaction())
elseif mode == "--install" then
    return requireSuccess(install(arg2, arg3, true))
elseif mode == "--update" then
    return requireSuccess(install(arg2, arg3, false))
elseif mode == "--repair" then
    local recovered, err = recoverTransaction()
    if not recovered then return requireSuccess(false, err) end
    local cfg = readTable(CONFIG_PATH)
    return requireSuccess(install(cfg and cfg.app, arg2, false))
elseif mode ~= nil then
    error("Usage: install_colony [--install master|supply|command [sourceURL] | --update role [sourceURL] | --repair [sourceURL] | --recover]", 0)
end

local recovered, recoveryError = recoverTransaction()
if not recovered then return requireSuccess(false, recoveryError) end
header("Installer")
local existing = readTable(CONFIG_PATH)
if existing then
    print("Existing role: " .. tostring(existing.app) .. ", suite " .. tostring(existing.suiteVersion))
    print("Use Update or Repair to preserve a v4 installation's data.")
    print()
end
print("[1] CLEAN install Supply Master (single PRS computer)")
print("[2] CLEAN install Colony Supply (one per colony)")
print("[3] CLEAN install Command Center")
print("[4] Update existing v4 installation (preserve data)")
print("[5] Repair existing v4 installation (preserve data)")
print("[6] Cancel")
write("Selection: ")
local choice = trim(read())
if choice == "6" then print("Cancelled."); return end
local appId = ({ ["1"] = "master", ["2"] = "supply", ["3"] = "command" })[choice]
local clean = appId ~= nil
if choice == "4" or choice == "5" then appId = existing and existing.app end
if not appId then return requireSuccess(false, "No valid role selected or installed.") end
local ok, err = install(appId, nil, clean)
if not ok then colour(colors.red); print(tostring(err)); colour(colors.white); return false end
print("Rebooting...")
sleep(1)
os.reboot()
