--[[
MineColonies Supply Manager v3.0.1
Architectural rewrite for multi-colony serialized access to shared Player Refined Storage (PRS).

Terms:
  PRS = Player Refined Storage
  CRS = Colony Refined Storage

Core guarantees:
  * Multiple colony computers coordinate as one fail-closed cluster.
  * Lowest computer ID is master; PRS turns rotate in sorted computer-ID order.
  * Loss of any known cluster member blocks new PRS access until contact returns.
  * Exactly one colony computer may access PRS at a time.
  * Equipment alternatives are restricted to minecraft / minecolonies namespaces.
  * Stored request fulfillment requires exact item + NBT identity.
  * Crafting is attempted only when exact stored stock is absent.
  * Startup verifies pending state, empty transfer chest, both movement directions,
    required API functions, cluster health, and an RS consistency heuristic.
  * Overstock return is optional and serialized through the same PRS turn.
  * History, health, and error/debug details are persistent and visible in the UI.
]]

local CONFIG = require("colony.supply.config")
local State = require("colony.supply.state")
local Cluster = require("colony.supply.cluster")
local Matcher = require("colony.supply.matcher")
local Transfer = require("colony.supply.transfer")
local Engine = require("colony.supply.engine")
local SupplyUI = require("colony.supply.ui")
local SuiteUpdater = require("colony.lib.updater")

local store = State.new(CONFIG)
store.load()

local cluster = Cluster.new(CONFIG, store)
local matcher = Matcher.new(CONFIG, store)
local transfer = Transfer.new(CONFIG, store, matcher)
transfer.refresh()

local updater
local ui
local engine

updater = SuiteUpdater.new({
    appId = "supply",
    appVersion = CONFIG.PROGRAM_VERSION,
    suiteVersion = CONFIG.SUITE_VERSION,
    displayName = "SUPPLY MANAGER",
    checkSeconds = CONFIG.updateCheckSeconds,
    drawMessage = function(title, message, color)
        if transfer.monitor then
            local SharedUI = require("colony.lib.ui")
            local ctx = SharedUI.newMonitor({monitor=transfer.monitor})
            ctx.drawMessagePanel({title=title,message=message,titleColor=color})
        else
            term.setTextColor(color or colors.white)
            print(tostring(title) .. ": " .. tostring(message))
            term.setTextColor(colors.white)
        end
    end,
})

engine = Engine.new(CONFIG, store, cluster, matcher, transfer)
ui = SupplyUI.new(CONFIG, store, cluster, transfer, engine, updater)

local mode, arg2 = ...

local function printDiagnostic()
    transfer.refresh()
    local h = engine.healthSnapshot()
    local cs = h.cluster
    print("MineColonies Supply Manager v" .. CONFIG.PROGRAM_VERSION)
    print("Suite v" .. CONFIG.SUITE_VERSION)
    print("Computer ID: " .. tostring(cs.id))
    print("Colony: " .. tostring(transfer.colonyName))
    print("Cluster: " .. tostring(cs.ok) .. " role=" .. tostring(cs.role) ..
        " master=" .. tostring(cs.masterId) .. " turn=" .. tostring(cs.turnId))
    print("Active IDs: " .. table.concat(cs.activeIds or {}, ","))
    print("Expected IDs: " .. table.concat(cs.expectedIds or {}, ","))
    if cs.fault then print("Cluster fault: " .. tostring(cs.fault)) end
    print("PRS: " .. tostring(h.playerRS) .. " [" .. tostring(transfer.playerBridgeName) .. "]")
    print("CRS: " .. tostring(h.colonyRS) .. " [" .. tostring(transfer.colonyBridgeName) .. "]")
    print("Warehouse: " .. tostring(h.warehouse))
    print("Transfer chest: " .. tostring(h.transferChest) .. " [" .. tostring(transfer.transferChestName) .. "]")
    print("Pending: " .. textutils.serialize(h.pending))
    print("Desync heuristic: " .. textutils.serialize(h.desync))
    print("Startup ready: " .. tostring(h.startupReady))
    print("Errors recorded: " .. tostring(#(store.data.errors or {})))
end

if mode == "diag" or mode == "diagnostics" then
    printDiagnostic()
    return
elseif mode == "startupcheck" then
    local ok = engine.runStartupChecks()
    print("Startup checks: " .. (ok and "PASSED" or "BLOCKED"))
    for id, check in pairs(store.data.startup.checks or {}) do
        print(tostring(id) .. ": " .. (check.ok and "OK" or "FAIL") .. " - " .. tostring(check.detail))
    end
    return
elseif mode == "errors" then
    for i, e in ipairs(store.data.errors or {}) do
        print(tostring(i) .. ". " .. tostring(e.time) .. " [" .. tostring(e.severity) .. "] " ..
            tostring(e.code) .. ": " .. tostring(e.message))
        if arg2 == "full" and e.context then print(textutils.serialize(e.context)) end
    end
    return
end

local function processorLoop()
    sleep(1)
    while true do
        local ok, err = pcall(function()
            engine.scan()
        end)
        if not ok then
            store.addError("PROCESSOR_CRASH", "Supply processor iteration crashed",
                {error=tostring(err)}, "ERROR")
            cluster.broadcastFault("processor iteration crashed: " .. tostring(err))
        end
        pcall(ui.renderTerminal)
        pcall(ui.draw)
        sleep(math.max(1, tonumber(CONFIG.scanIntervalSeconds) or 5))
    end
end

local function updateLoop()
    pcall(updater.check)
    while true do
        sleep(math.max(60, tonumber(CONFIG.updateCheckSeconds) or 1800))
        pcall(updater.check)
        pcall(ui.renderTerminal)
        pcall(ui.draw)
    end
end

local function terminalLoop()
    while true do
        pcall(ui.renderTerminal)
        sleep(1)
    end
end

store.log("Supply Manager v3.0.1 starting computer=" ..
    tostring(os.getComputerID and os.getComputerID() or "?"))

parallel.waitForAll(
    function() cluster.loop() end,
    processorLoop,
    function() ui.eventLoop() end,
    updateLoop,
    terminalLoop
)
