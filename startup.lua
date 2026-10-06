-- MineColonies Control Suite generic startup launcher
-- Component version: 1.1.0
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

-- Recover an interrupted replacement before loading modules from a partially
-- updated installation. The verified recovery installer lives outside /colony.
local TRANSACTION = "/.colony_install_transaction"
if fs.exists(TRANSACTION .. "/marker.txt") then
    banner("RECOVERING SUITE INSTALLATION", colors.yellow)
    local recovery = TRANSACTION .. "/new/install_colony.lua"
    if not fs.exists(recovery) then recovery = "/install_colony.lua" end
    local ok, err = pcall(function()
        if not shell.run(recovery, "--recover") then error("Installer recovery failed.", 0) end
    end)
    if not ok then
        banner("INSTALLATION RECOVERY REQUIRED", colors.red)
        print(tostring(err))
        print("Keep " .. TRANSACTION .. " and run its installer --recover.")
        return
    end
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
