--[[
MineColonies Supply Manager v3.0.29
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

v3.0.20 acknowledgement hardening:
  * ACK states require persisted verified-delivery proof.
  * Stock still visible in CRS is reported as CRS RECEIVED, not ACK STALLED.
  * A courier-consumption grace window prevents immediate duplicate retries.
  * Requests now display SENT/QTY so a proven 1/1 delivery cannot look like 0/1.

v3.0.21 PRS desync detection:
  * A stock-positive/export-zero event is confirmed with repeated exact-stock reads.
  * A separate safe one-item PRS->chest->PRS probe distinguishes item-stale from
    global PRS extraction desync.
  * Item-stale requests are quarantined while unrelated requests continue.
  * Confirmed global desync holds the shared PRS turn and probes for recovery.
  * Health now reports PRS extraction state and quarantined stale-item count.
  * A cooldown-protected redstone reset hook is included but disabled by default pending field validation.

v3.0.22 matcher correction:
  * Tool-class matching now uses complete normalized tokens.
  * "Bowl" is no longer misclassified as "Bow", so minecraft:bowl remains a
    normal supply candidate and can be fulfilled from PRS stock.

v3.0.23 MineColonies warehouse visibility refresh:
  * CRS visibility is no longer assumed to mean MineColonies has refreshed its
    warehouse/request cache.
  * If a verified delivery remains in CRS while the request stays unchanged,
    Supply performs a bounded exact CRS->transfer-chest->CRS touch.
  * The touch does not involve PRS and does not increment SENT/QTY or resend
    additional stock; it only recreates the inventory change that manual
    remove/reinsert testing proved wakes MineColonies.
  * v3.0.24 makes the touch transaction crash-safe so a reboot between the
    reinsert and state-clear cannot leave an ambiguous pending transfer.

v3.0.25 monitor update control:
  * CHECK UPDATE is always visible in the upper-right header on every Supply tab.
  * The same control becomes UPDATE when a newer suite is available.
  * The old Home-only update row/button has been removed.

v3.0.26 updater validation:
  * Update checks compare the running app version and suite version independently.
  * A newer Command/Supply app can no longer be hidden by an equal/stale suite value.
  * Shared-file-only suite updates remain supported as UPDATE SUITE.

v3.0.27 selective PRS desync recovery:
  * A requested item that remains visible but cannot export is now treated as
    a real selective PRS desync even when a different generic item can export.
  * The failing colony holds the shared PRS turn and probes the exact failed
    item instead of allowing the other colony to continue using a broken PRS.
  * One failed exact-item recovery probe after the original failure is enough
    to trigger the gated redstone reset hook when automatic reset is enabled.
  * Existing v3.0.26 PRS_ITEM_STALE state migrates directly to SELECTIVE.

v3.0.28 cluster PRS fault visibility:
  * The turn owner broadcasts SELECTIVE/GLOBAL PRS desync to all Supply nodes.
  * Peer colonies show the reporting colony and failed item without probing PRS.
  * Only the turn owner performs exact-item recovery or a future reset pulse.
  * Recovery clears the shared PRS fault across the cluster.

v3.0.29 automatic PRS reset:
  * Supply auto-discovers one Advanced Peripherals Redstone Integrator.
  * Confirmed selective/global PRS desync immediately sends RS15 on the
    integrator's bottom side for exactly 2 seconds, then forces it back to 0.
  * Only the colony that actually confirmed the desync may send the pulse.
  * A 120-second cooldown prevents repeated reset cycling.
  * Health shows the discovered reset integrator and configured pulse.
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

-- Do not touch either RS Bridge before cluster ownership is established.
-- Engine.scan()/runStartupChecks() resolve peripherals only after the token's
-- handoff quiet window has completed.
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

store.log("Supply Manager v3.0.29 starting computer=" ..
    tostring(os.getComputerID and os.getComputerID() or "?"))

parallel.waitForAll(
    function() cluster.loop() end,
    processorLoop,
    function() ui.eventLoop() end,
    updateLoop,
    terminalLoop
)