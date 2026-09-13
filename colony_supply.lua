--[[
  colony_supply.lua
  Version 2.53
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
  - Only the exact failed request shows RS STALE. Other requests blocked by the
    global extraction-safety latch show RS PAUSED.

  v2.30 RS recovery countdown:
  - RS STALE/RS PAUSED status cells show a live seconds countdown to the next
    one-item Player-RS recovery probe. The monitor redraws the countdown every second.
  v2.31 craft/desync separation:
  - craftItem() Java exceptions are quarantined per item but no longer trigger
    the global Player-RS extraction safety latch.
  - RS STALE / RS PAUSED are reserved for verified source extraction failures.
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

  v2.37 RS stale-cache recovery:
  - A single export=0 no longer globally pauses Supply. The affected item is isolated
    as RS STALE while unrelated requests continue normally.
  - Before quarantining an item, Supply invalidates its RS snapshot and performs three
    fresh listItems() reads. A disappearing or changing stock count is treated as a
    transient cache refresh and retried without latching stale state.
  - RS STALE entries clear automatically when stock changes, disappears, or a retry
    export succeeds. Retries remain rate-limited to avoid hammering the RS Bridge.
  - Stale tracking is memory-bounded: inactive records expire and a hard maximum of
    64 entries is enforced, preventing long-running worlds from accumulating state.
  - The short-lived listItems() cache is keyed by stable peripheral name instead of
    bridge wrapper tables, preventing wrapper churn from retaining old cache entries.

  v2.38 transfer confirmation hardening:
  - Import success is no longer trusted solely from the RS Bridge return value.
  - When the modem-visible transfer barrel is available, Supply measures the requested
    item before and after each import and credits only the quantity that physically
    disappeared from the barrel.
  - A positive RS Bridge return with no matching barrel movement is treated as a false
    positive, left pending, and retried instead of being written to transfer history.
  - Verification uses only scalar locals during the existing bounded retry loop; it
    adds no persistent snapshots, queues, timers, or unbounded memory structures.

  v2.39 overflow threshold correctness and visibility:
  - The configured OVERFLOW value is now the hard return floor. Overflow return will
    never drain an item below that displayed threshold.
  - Active MineColonies demand may raise the temporary safe floor above OVERFLOW; this
    is reported as HELD instead of silently looking like the over-limit check failed.
  - Settings highlight over-limit current stock, and overflow diagnostics now show the
    effective floor plus transfer-path blockers such as a non-empty shared barrel.
  - Overflow transfer failures are no longer overwritten by a generic ONLINE message
    at the end of the same scan. No new persistent tables, timers, or queues are added.

  v2.40 reverse-transfer hardening:
  - Overflow exports are physically verified against the modem-visible transfer barrel.
  - If the normal Colony-RS directional export moves nothing, Supply retries that leg
    with Advanced Peripherals exportItemToPeripheral() using the resolved barrel name.
  - A bridge-reported export is never credited when the barrel count does not increase.
  - The fallback is bounded to one alternate source-export attempt per transaction and
    stores no new history/cache structures, so it cannot create long-running memory growth.

  v2.41 compile-safety refactor:
  - Diagnostic and command-only helpers are grouped under one DIAG table instead of
    consuming many permanent top-level local slots in the main Lua chunk.
  - This restores a wide margin below CC:Tweaked/Lua's 200-local-variable ceiling.
  - Runtime transfer, overflow, crafting, and persisted state behavior are unchanged.
  - The refactor adds no queues, caches, timers, histories, or long-lived allocations.

  v2.42 WH->Player path diagnostic:
  - Adds `overflowtest` / `whtest` to exercise the exact production overflow transfer path.
  - The diagnostic moves a small real quantity from Colony/Warehouse RS to Player RS,
    reports before/after Colony, barrel, and Player counts, and records normal WH>P history
    only when the production transfer physically succeeds.
  - It refuses to run with a pending transaction or non-empty/unreadable transfer barrel.
  - The diagnostic adds no persistent queues, timers, caches, or background allocations.

  v2.43 manual History navigation:
  - History pages no longer auto-advance.
  - The History footer uses fixed PREV / REFRESH / NEXT touch controls.
  - The current page number is shown in the History header.
  - Refreshing or receiving new transfer history keeps the currently selected page.

  v2.44 request tool-token recognition:
  - Tool-class detection now matches complete normalized words/phrases instead of raw
    substrings. This prevents ordinary items such as minecraft:bowl from being
    misclassified as a Bow request merely because "bowl" contains "bow".
  - Existing underscore/hyphen forms such as fishing_rod remain recognized after
    normalization. No transfer, overflow, history, or persistent-state logic changed.


  v2.45 alternative-request selection:
  - Re-ranks every acceptable non-tool request item on each scan.
  - Stocked alternatives outrank zero-stock alternatives that merely report craftable.
  - Keeps the previously selected alternative only as a tie-breaker to avoid churn.

  v2.46 Flint and Steel request/NBT safety fix:
  - Recognizes the literal MineColonies request phrase "Flint and Steel" as the
    lighter tool class so it uses the exact equipment-selection path.
  - Treats minecraft:flint_and_steel as a real durability-bearing tool for safe
    default MineColonies NBT handling, preventing normal default NBT from being
    rejected before stock/craftability checks.
  - Does not relax NBT safety for enchanted, damaged, or customized variants.

  v2.47 partial-stock craft-first safety:
  - When Player RS has some stock but less than the remaining MineColonies request,
    and that candidate is craftable, Supply no longer exports the partial stock and
    then immediately starts a craft for the shortage.
  - It leaves the partial stock untouched, crafts only the shortage, waits for enough
    stock to exist, and then starts the normal verified transfer path.
  - This avoids the observed Advanced Peripherals/Refined Storage stale-disk condition
    triggered by interleaving a partial export with crafting the same item.
  - Adds no queue, cache, timer, or persistent allocation.

  v2.48 pristine-equipment craft fingerprint workaround:
  - When damaged/enchanted equipment with the requested registry name is already stored,
    Advanced Peripherals/Refined Storage can refuse a name-only craft even though the
    same recipe crafts normally from the RS Grid. Supply now asks listCraftableItems()
    for the clean pattern output fingerprint and submits that exact fingerprint instead.
  - The workaround is limited to pristine-equipment requests with rejected stored copies;
    ordinary item crafting remains registry-name-only.
  - If no safe craftable fingerprint is exposed, Supply falls back to the existing path.

  v2.49 equipment-pattern fingerprint recovery:
  - Distinguishes stored equipment NBT safety from crafting-pattern identity. Stored
    opaque-NBT equipment remains unusable unless pristine can be proven, but a unique
    fingerprint exposed by a craftable pattern may be used to start a clean equipment craft.
  - Falls back to getPattern() outputs when listCraftableItems() is unavailable/incomplete.

  v2.50 P>WH destination confirmation:
  - Player->Warehouse supply transfers are no longer credited merely because the shared
    transfer barrel became empty. Supply now requires fresh Colony-RS destination evidence
    before incrementing request supplied counts or writing P>WH transfer history.
  - An empty barrel with no Colony-RS gain becomes DESTINATION UNCONFIRMED and is held
    briefly for delayed RS visibility/request acknowledgement instead of being false-credited.
  - Recovery no longer treats an empty barrel during a supply import as automatic proof of
    success. Existing full-request credits are reconciled when the live MineColonies request
    remains active and Colony RS has none of the item after the confirmation grace period.
  - Refuses to guess when multiple distinct craftable fingerprints exist for the same item.
  - Request diagnostics no longer abort when MineColonies returns repeated/shared tables.

  v2.51 shared-RS partial-request serialization:
  - Reverses the v2.47 craft-first policy for partial stock. When Player RS has some
    stock but less than the live MineColonies request, Supply transfers the available
    stock first and NEVER starts the shortage craft from that same request snapshot.
  - After a partial shipment, Supply waits for MineColonies to reduce/replace the
    request before crafting. This lets MineColonies provide the authoritative remainder
    and avoids two colonies reserving the same visible Player-RS stock concurrently.
  - If the same request ID is reused with a changed quantity, old local supplied credit
    is reset because the new MineColonies quantity already represents the new remainder.
  - No timeout silently bypasses this gate; a stuck request remains visibly WAITING
    rather than risking another partial-stock/craft race.

  v2.52 shared-helper cleanup:
  - Reuses shared utility/UI helpers for trimming, clock text, serialized-table reads,
    terminal setup/color, and update-message rendering.
  - Removes unused legacy helpers and consolidates repeated page-wrap logic.
  - No request, crafting, transfer, NBT, overflow, or recovery behavior changes.

  v2.53 damaged-equipment craft guard:
  - Prevents automatic craftItem() calls for pristine-equipment candidates when
    same-name Player-RS copies exist but are rejected as damaged/enchanted/unsafe.
  - Such conflicted candidates no longer count as craft-usable during tool selection,
    allowing a safer acceptable tool candidate to win when MineColonies provides one.
  - If no safe alternative exists, the request reports BLOCKED instead of entering
    Refined Storage's crafting calculator. This contains observed / by zero failures.
  - Removes the experimental pristine-pattern fingerprint craft workaround; stored
    bad variants are treated as a hard autocrafting conflict rather than bypassed.

  v2.54 stranded-barrel rollback recovery:
  - Bounds repeated Player->Warehouse barrel->Colony import failures instead of
    leaving one pending transaction alive forever and blocking the shared barrel.
  - After repeated failed Colony imports, any remainder still physically present in
    the dedicated transfer barrel is returned to Player RS without crediting the
    MineColonies request; the live request may then retry from authoritative state.
  - A pending transaction is cleared only after rollback physically empties the barrel.
  - If the program starts with no pending transaction but finds exactly one item type
    orphaned in the dedicated transfer barrel, it safely returns that item to Player RS.
    Mixed/ambiguous barrel contents remain blocked for manual inspection.
--]]

local PROGRAM_VERSION = "2.54"
local SUITE_VERSION = "1.1.19"

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

    -- P>WH destination confirmation. The barrel becoming empty proves only that
    -- the source inventory lost the item; it does not prove Colony RS/Warehouse
    -- retained it. Use fresh Colony-RS snapshots before crediting the request.
    destinationConfirmReads = 3,
    destinationConfirmDelay = 0.15,
    destinationConfirmTimeout = 20,

    -- A Player->Warehouse import that repeatedly leaves the same items physically
    -- in the dedicated transfer barrel must not block the entire suite forever.
    -- One recovery cycle already performs transferImportRetries import attempts.
    -- After this many failed recovery cycles, roll the stranded remainder back to
    -- Player RS and let the still-live MineColonies request retry cleanly.
    pendingImportRollbackAttempts = 8,

    requestRetentionSeconds = 3600,
    enableAutoCrafting = true,
    craftCooldownSeconds = 30,

    -- If Advanced Peripherals/Refined Storage throws a Java exception while
    -- starting a craft, quarantine that exact item/variant instead of
    -- repeatedly calling craftItem() every scan. This is specifically meant
    -- to protect against RS CraftingCalculator failures such as / by zero.
    craftErrorCooldownSeconds = 300,
    craftErrorMaxCooldownSeconds = 3600,

    -- If Player RS reports stock but exportItem() moves 0, do not immediately
    -- trust either side of the contradiction. Invalidate the cached listItems()
    -- snapshot and require several stable fresh reads before quarantining only
    -- that item as RS STALE. Unrelated requests continue normally.
    rsDesyncProbeSeconds = 30,
    rsStaleVerifyReads = 3,
    rsStaleVerifyDelay = 0.10,
    rsStaleRetentionSeconds = 3600,
    rsStaleMaxEntries = 64,

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


local clamp = Util.clamp
local trim = Util.trim
local timeString = Util.timeString

local function roundDown(n)
    return math.floor(tonumber(n) or 0)
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
        or path == "flint_and_steel"

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

local function loadState()
    local loaded = Util.readSerializedTable(CONFIG.stateFile)
    if not loaded then
        loaded = Util.readSerializedTable(CONFIG.stateFile .. ".bak")
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
function NBTX.rsListCacheKey(bridge)
    if not bridge then return nil end
    local ok, name = pcall(peripheral.getName, bridge)
    if ok and type(name) == "string" and name ~= "" then return name end
    -- Do not cache an unnamed wrapper. resolveRSBridges() may create fresh
    -- wrapper tables during later scans, and using those tables as keys would
    -- retain obsolete wrappers indefinitely.
    return nil
end

function NBTX.getRSListItems(bridge, force)
    if not bridge then return nil end
    NBTX.rsListCache = NBTX.rsListCache or {}

    local now = nowMs()
    local cacheKey = NBTX.rsListCacheKey(bridge)
    local cached = cacheKey and NBTX.rsListCache[cacheKey] or nil
    if not force and type(cached) == "table"
        and type(cached.items) == "table"
        and now - (tonumber(cached.time) or 0) <= 500 then
        return cached.items
    end

    local ok, items = safeCall(bridge, "listItems")
    if not ok or type(items) ~= "table" then return nil end

    if cacheKey then
        NBTX.rsListCache[cacheKey] = { time = now, items = items }
    end
    return items
end

function NBTX.invalidateRSList(bridge)
    if NBTX.rsListCache and bridge then
        local cacheKey = NBTX.rsListCacheKey(bridge)
        if cacheKey then NBTX.rsListCache[cacheKey] = nil end
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

-- Force a new listItems() snapshot and return the raw stored amount. This is
-- deliberately separate from the normal 500 ms cache because destination
-- confirmation must not validate a transfer from the same pre-import snapshot.
function NBTX.getFreshRSAmount(bridge, itemName)
    NBTX.invalidateRSList(bridge)
    return math.max(0, math.floor(tonumber(getRSAmount(bridge, itemName)) or 0))
end

-- Confirm that a Player->Warehouse import actually became visible in Colony RS.
-- The transfer barrel delta is necessary but not sufficient: AP/RS can consume an
-- item from the barrel while the destination network fails to retain/expose it.
-- Return only the quantity positively evidenced by fresh Colony-RS snapshots.
function NBTX.confirmColonyArrival(itemName, beforeStock, expectedMoved, priorMaxSeen)
    local expected = math.max(0, math.floor(tonumber(expectedMoved) or 0))
    local baseline = math.max(0, math.floor(tonumber(beforeStock) or 0))
    local maxSeen = math.max(baseline, math.floor(tonumber(priorMaxSeen) or baseline))
    local reads = math.max(1, math.min(5, math.floor(tonumber(CONFIG.destinationConfirmReads) or 3)))
    local delay = math.max(0, math.min(1, tonumber(CONFIG.destinationConfirmDelay) or 0.15))
    local samples = {}

    for i = 1, reads do
        local current = NBTX.getFreshRSAmount(colonyRS, itemName)
        samples[#samples + 1] = tostring(current)
        if current > maxSeen then maxSeen = current end
        if math.max(0, maxSeen - baseline) >= expected then break end
        if i < reads and delay > 0 then sleep(delay) end
    end

    local confirmed = math.min(expected, math.max(0, maxSeen - baseline))
    return confirmed, maxSeen, table.concat(samples, ",")
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
    -- activate the global RS STALE / RS PAUSED safety latch here.

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
        elseif not legacyReason:find("global safety probe", 1, true)
            and not legacyReason:find("generic source probe", 1, true) then
            local oldItem = tostring(state.rsSafety.item or "?")
            state.rsSafety = {
                latched = false,
                lastRecovered = nowSeconds(),
                lastDetail = "v2.37 converted legacy item latch to per-item RS STALE",
            }
            saveState()
            writeLog("RS SAFETY LEGACY ITEM LATCH CLEARED item=" .. oldItem)
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

-- Refined Storage source-extraction stale tracking (legacy rsDesync state name kept
-- for upgrade compatibility). Keep these helpers on
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
        lastSeen = now,
        failures = (type(previous) == "table" and (tonumber(previous.failures) or 0) or 0) + 1,
        item = tostring(candidate and candidate.name or "?"),
        reported = math.max(0, math.floor(tonumber(reportedStock) or 0)),
        requested = math.max(0, math.floor(tonumber(requestedCount) or 0)),
        reason = tostring(reason or "Player RS reported stable stock but exportItem moved 0"),
        sourceHealthy = itemSpecific,
        sourceHealthyAt = itemSpecific and tonumber(previous.sourceHealthyAt) or nil,
    }
    saveState()

    -- Ordinary item failures are isolated. A global latch is reserved only for
    -- an explicit generic source-health probe which itself fails. This prevents
    -- one stale RS item/cache entry from freezing unrelated colony requests.
    if globalProbeFailure == true then
        NBTX.latchRSSafety(candidate, reportedStock, requestedCount,
            reason or "Player RS generic source probe returned 0", true)
    end

    health.transfer = false
    health.message = "RS STALE: " .. tostring(candidate and candidate.name or "?") ..
        " stock=" .. tostring(reportedStock or 0) .. " export=0"

    writeLog(
        "RS STALE DETECTED item=" .. tostring(candidate and candidate.name or "?") ..
        " key=" .. tostring(key) ..
        " reported=" .. tostring(reportedStock or 0) ..
        " requested=" .. tostring(requestedCount or 0) ..
        " failures=" .. tostring(state.rsDesync[key].failures) ..
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
        writeLog("RS STALE RETRY item=" .. tostring(candidate and candidate.name or "?") ..
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
    writeLog("RS STALE CLEARED item=" .. tostring(candidate and candidate.name or "?") ..
        " detail=" .. tostring(detail or "source extraction recovered"))
    return true
end

-- Bound persistent stale-item state so a long-running server cannot accumulate
-- one table entry for every item ever encountered. This operates only on the
-- small quarantine table and saves state only when something was actually pruned.
function NBTX.pruneRSDesync()
    state.rsDesync = state.rsDesync or {}
    local now = nowSeconds()
    local ttl = math.max(300, tonumber(CONFIG.rsStaleRetentionSeconds) or 3600)
    local maxEntries = math.max(8, math.floor(tonumber(CONFIG.rsStaleMaxEntries) or 64))
    local count = 0
    local changed = false

    for key, entry in pairs(state.rsDesync) do
        if type(entry) ~= "table" then
            state.rsDesync[key] = nil
            changed = true
        else
            local touched = tonumber(entry.lastProbe or entry.lastSeen or entry.time) or 0
            if touched > 0 and (now - touched) > ttl then
                state.rsDesync[key] = nil
                changed = true
                writeLog("RS STALE EXPIRED key=" .. tostring(key))
            else
                count = count + 1
            end
        end
    end

    -- Allocate/sort an age list only in the exceptional case where the hard
    -- bound was exceeded. Normal scans therefore create no per-entry tables.
    if count > maxEntries then
        local entries = {}
        for key, entry in pairs(state.rsDesync) do
            entries[#entries + 1] = {
                key = key,
                touched = tonumber(entry.lastProbe or entry.lastSeen or entry.time) or 0,
            }
        end
        table.sort(entries, function(a, b) return a.touched < b.touched end)
        for i = 1, #entries - maxEntries do
            state.rsDesync[entries[i].key] = nil
            changed = true
            writeLog("RS STALE PRUNED key=" .. tostring(entries[i].key))
        end
    end

    if changed then saveState() end
    return changed
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

        -- Ordinary autocrafting intentionally stays registry-name-only. Pristine
        -- equipment with conflicting stored variants is blocked before reaching here.
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

    -- v2.53: Refined Storage 1.12.4 can throw CraftingCalculator / by zero
    -- when a pristine tool/armor craft is requested while damaged/enchanted
    -- copies with the same registry name already exist in storage. Do not try
    -- to outsmart that state with a fingerprint craft: avoid craftItem() entirely.
    if candidate.requiresPristine
        and (tonumber(candidate.rejectedEquipmentStock) or 0) > 0
        and (tonumber(candidate.playerStock) or 0) <= 0 then
        local rejected = math.max(1, math.floor(tonumber(candidate.rejectedEquipmentStock) or 1))
        local msg = "EQUIPMENT VARIANT CONFLICT: " .. tostring(rejected) ..
            " damaged/enchanted " .. tostring(candidate.name) ..
            " in Player RS; autocraft blocked"
        writeLog("CRAFT BLOCKED variant-conflict item=" .. tostring(candidate.name) ..
            " rejectedStored=" .. tostring(rejected))
        return false, msg, 0
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

-- v2.51: Shared-RS partial request serialization.
--
-- When two colonies share one Player RS network, a scan that sees partial stock must
-- not both leave that stock visible and start a shortage craft. Each colony could make
-- the same allocation decision against the same snapshot. Instead, ship available
-- stock first, then wait for MineColonies to publish the authoritative remainder.
function NBTX.markAwaitingRequestRefresh(rs, requested, candidate, moved)
    if type(rs) ~= "table" or type(candidate) ~= "table" then return end
    rs.awaitingRequestRefresh = {
        requested = math.max(0, math.floor(tonumber(requested) or 0)),
        item = tostring(candidate.name or ""),
        moved = math.max(0, math.floor(tonumber(moved) or 0)),
        since = nowSeconds(),
    }
end

function NBTX.clearAwaitingRequestRefresh(rs, reason)
    if type(rs) ~= "table" or type(rs.awaitingRequestRefresh) ~= "table" then
        return false
    end
    local gate = rs.awaitingRequestRefresh
    writeLog(
        "REQUEST REFRESH gate cleared item=" .. tostring(gate.item or "?") ..
        " oldRequested=" .. tostring(gate.requested or "?") ..
        " reason=" .. tostring(reason or "request changed")
    )
    rs.awaitingRequestRefresh = nil
    return true
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

-- Match tool names as complete normalized tokens, never as arbitrary substrings.
-- This is important for names such as "bowl": a raw search for "bow" would
-- incorrectly turn an ordinary Bowl request into a Bow equipment request.
function NBTX.textHasToolToken(text, token)
    local normalized = tostring(text or ""):lower():gsub("[^%w]+", " ")
    local wanted = tostring(token or ""):lower():gsub("[^%w]+", " ")

    normalized = (" " .. normalized:gsub("^%s+", ""):gsub("%s+$", "") .. " ")
    wanted = wanted:gsub("^%s+", ""):gsub("%s+$", "")

    return wanted ~= "" and normalized:find(" " .. wanted .. " ", 1, true) ~= nil
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

    -- Common MineColonies/tool-action spellings. These use the same token-aware
    -- matcher so unrelated words cannot accidentally trigger an equipment class.
    if NBTX.textHasToolToken(haystack, "axe dig")
        or NBTX.textHasToolToken(haystack, "axes") then
        return "axe"
    end

    if NBTX.textHasToolToken(haystack, "pickaxe dig") then
        return "pickaxe"
    end

    if NBTX.textHasToolToken(haystack, "shovel dig") then
        return "shovel"
    end

    -- MineColonies normally names this request literally rather than using
    -- the internal class name "lighter". Map the displayed/requested item
    -- phrase to the existing lighter tool class.
    if NBTX.textHasToolToken(haystack, "flint and steel")
        or NBTX.textHasToolToken(haystack, "flint_and_steel") then
        return "lighter"
    end

    local classes = {
        "fishing rod", "crossbow", "pickaxe", "shovel", "sword",
        "shears", "shield", "helmet", "leggings", "chestplate",
        "boots", "lighter", "lead", "spear", "axe", "hoe", "bow",
    }

    for _, class in ipairs(classes) do
        if NBTX.textHasToolToken(haystack, class) then
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

-- Return a fresh Player-RS stock count for a request candidate. Cache is
-- explicitly invalidated first, so every call below corresponds to a new
-- listItems() snapshot rather than the normal 500 ms shared scan cache.
function NBTX.getFreshPlayerStock(candidate)
    NBTX.invalidateRSList(playerRS)
    if type(candidate) == "table" and candidate.requiresPristine then
        local _, cleanStock = NBTX.getPristineEquipmentVariants(playerRS, candidate)
        return math.max(0, tonumber(cleanStock) or 0)
    end
    return math.max(0, tonumber(NBTX.getRSAmountByCandidate(playerRS, candidate)) or 0)
end

-- Verify an apparent export=0 contradiction without retaining snapshots. The
-- stock value must remain positive and unchanged across all fresh reads to be
-- classified as an RS STALE item. Any change means RS is actively refreshing,
-- so the caller simply retries on a later scan instead of creating a latch.
function NBTX.confirmRSStale(candidate, baselineStock)
    local reads = math.max(2, math.min(5, math.floor(tonumber(CONFIG.rsStaleVerifyReads) or 3)))
    local delay = math.max(0, math.min(1, tonumber(CONFIG.rsStaleVerifyDelay) or 0.10))
    local baseline = math.max(0, math.floor(tonumber(baselineStock) or 0))
    local previous = baseline
    local current = baseline
    local samples = ""

    for i = 1, reads do
        current = math.floor(NBTX.getFreshPlayerStock(candidate))
        samples = samples .. (i > 1 and "," or "") .. tostring(current)

        if current <= 0 then
            return false, current, "fresh stock disappeared; samples=" .. samples
        end
        if previous > 0 and current ~= previous then
            return false, current, "fresh stock changed; samples=" .. samples
        end

        previous = current
        if i < reads and delay > 0 then sleep(delay) end
    end

    return true, current, "stable positive stock across " .. tostring(reads) ..
        " fresh reads; samples=" .. samples
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
    candidate.equipmentCraftConflict = candidate.requiresPristine == true
        and (tonumber(candidate.rejectedEquipmentStock) or 0) > 0
        and (tonumber(candidate.playerStock) or 0) <= 0
end

function NBTX.candidateAvailabilityTier(candidate, remaining)
    if candidate.playerStock >= remaining and remaining > 0 then
        return 4
    elseif candidate.playerStock > 0 then
        return 3
    elseif candidate.craftable and not candidate.equipmentCraftConflict then
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

    -- Normal non-tool requests may contain multiple acceptable alternatives
    -- (for example raw cod OR tropical fish). Always rank every candidate on
    -- the current scan instead of pinning a zero-stock candidate merely because
    -- Refined Storage says it is craftable. A previously selected alternative
    -- is retained only as a tie-breaker between equally useful choices.
    local stickyName = requestState and requestState.item or nil
    local best = nil
    local bestTier = -1
    local bestScore = -1
    local bestIsSticky = false

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

        local isSticky = stickyName ~= nil and c.name == stickyName
        if tier > bestTier
            or (tier == bestTier and score > bestScore)
            or (tier == bestTier and score == bestScore and isSticky and not bestIsSticky) then
            bestTier = tier
            bestScore = score
            bestIsSticky = isSticky
            best = c
        end
    end

    if stickyName and best and best.name ~= stickyName then
        writeLog(
            "ALTERNATIVE RESELECT request=" .. tostring(request.id or "?") ..
            " old=" .. tostring(stickyName) ..
            " new=" .. tostring(best.name) ..
            " tier=" .. tostring(bestTier) ..
            " stock=" .. tostring(best.playerStock or 0) ..
            " craftable=" .. tostring(best.craftable == true)
        )
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
            local serializedOK, serialized = pcall(textutils.serialize, requests)
            if serializedOK then
                h.write(serialized)
            else
                h.write("Raw request serialization omitted: " .. tostring(serialized))
            end
            h.close()
        end
    end

    return requests, nil
end

-- Used only for destination-confirmation recovery. A request disappearing is
-- acknowledgement enough to release an unconfirmed transaction without falsely
-- incrementing local supplied/history counters.
function NBTX.isColonyRequestActive(requestId)
    if not requestId then return false end
    local requests = getColonyRequests()
    if type(requests) ~= "table" then return true end -- fail closed
    for _, request in pairs(requests) do
        if type(request) == "table" and request.id == requestId and isRequestActive(request) then
            return true
        end
    end
    return false
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
        -- If the transfer barrel is visible over the wired modem, use it as the
        -- authoritative transaction boundary. Advanced Peripherals/RS can return
        -- a positive import count even when the inventory movement has not actually
        -- occurred. Measuring the barrel prevents those false positives from being
        -- credited to requests or transfer history.
        local beforeBarrel = chestItemCount(itemName)

        local reported, err = importFunction(itemName, count)
        reported = math.max(0, math.floor(tonumber(reported) or 0))
        local moved = reported

        if beforeBarrel ~= nil then
            -- Give the inventory/peripheral view the same short settling period used
            -- by the normal transfer path, then verify the physical barrel delta.
            transferSleep(CONFIG.transferSettleDelay)
            local afterBarrel = chestItemCount(itemName)

            if afterBarrel ~= nil then
                local physicalMoved = math.max(0, beforeBarrel - afterBarrel)
                physicalMoved = math.min(physicalMoved, math.max(0, math.floor(tonumber(count) or 0)))

                if physicalMoved ~= reported then
                    writeLog(
                        "IMPORT VERIFY mismatch item=" .. tostring(itemName) ..
                        " destination=" .. tostring(destinationLabel) ..
                        " reported=" .. tostring(reported) ..
                        " physical=" .. tostring(physicalMoved) ..
                        " barrel=" .. tostring(beforeBarrel) .. "->" .. tostring(afterBarrel)
                    )
                end

                moved = physicalMoved
                if reported > 0 and moved <= 0 then
                    lastErr = "RS Bridge reported " .. tostring(reported) ..
                        " imported, but transfer barrel did not change"
                elseif moved > 0 then
                    err = nil
                end
            else
                -- We began with a verifiable barrel, so do not downgrade to trusting
                -- the bridge return value if the post-import observation disappears.
                moved = 0
                lastErr = "Transfer barrel verification unavailable after import"
                writeLog(
                    "IMPORT VERIFY unavailable-after item=" .. tostring(itemName) ..
                    " destination=" .. tostring(destinationLabel) ..
                    " reported=" .. tostring(reported) ..
                    " barrelBefore=" .. tostring(beforeBarrel)
                )
            end
        end

        if moved > 0 then
            if attempt > 1 then
                writeLog("IMPORT retry succeeded attempt=" .. tostring(attempt) ..
                    " item=" .. tostring(itemName) ..
                    " moved=" .. tostring(moved) ..
                    " destination=" .. tostring(destinationLabel))
            end
            return moved, nil
        end

        if not lastErr then lastErr = err end
        writeLog("IMPORT retry " .. tostring(attempt) .. "/" .. tostring(attempts) ..
            " moved=0 item=" .. tostring(itemName) ..
            " destination=" .. tostring(destinationLabel) ..
            " reported=" .. tostring(reported) ..
            " reason=" .. tostring(lastErr or err or "none"))

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

-- Return the one distinct item currently present in the dedicated transfer barrel.
-- Multiple stacks of the same registry item are combined. Mixed contents are
-- intentionally not guessed at because an orphan recovery must be fail-closed.
function NBTX.singleBarrelItem()
    local chest = getTransferChest()
    if not chest then return nil, nil, "barrel inspection unavailable" end

    local ok, list = safeCall(chest, "list")
    if not ok or type(list) ~= "table" then
        return nil, nil, "barrel list unavailable"
    end

    local itemName = nil
    local total = 0
    for _, stack in pairs(list) do
        if type(stack) == "table" and stack.name and (tonumber(stack.count) or 0) > 0 then
            if itemName and itemName ~= stack.name then
                return nil, nil, "mixed barrel contents"
            end
            itemName = stack.name
            total = total + math.max(0, math.floor(tonumber(stack.count) or 0))
        end
    end

    if not itemName then return nil, 0, nil end
    return itemName, total, nil
end

-- Once a supply transaction has proven unable to import its stranded remainder
-- into Colony RS, fail safely back toward the source. This never increments the
-- MineColonies supplied counter: items returned here were never destination-confirmed.
function NBTX.rollbackPendingSupplyToPlayer(p)
    if type(p) ~= "table" or (p.kind or "supply") ~= "supply" then
        return false, "not a supply transaction"
    end

    local itemName = tostring(p.item or "")
    if itemName == "" then return false, "rollback item missing" end

    local before = chestItemCount(itemName)
    if before == nil then
        p.rollbackToPlayer = true
        p.stage = "rollback"
        p.lastError = "rollback waiting for barrel inspection"
        p.lastAttempt = nowSeconds()
        saveState()
        health.transfer = false
        health.message = "ROLLBACK WAIT: barrel inspection unavailable"
        return false, p.lastError
    end

    if before <= 0 then
        clearPending("rollback found barrel already empty")
        health.transfer = true
        health.message = "Stranded transfer cleared; request may retry"
        return true, "barrel already empty"
    end

    p.rollbackToPlayer = true
    p.stage = "rollback"
    p.rollbackAttempts = (tonumber(p.rollbackAttempts) or 0) + 1
    p.lastAttempt = nowSeconds()
    saveState()

    local moved, err = retryImport(NBTX.importToPlayer, itemName, before, "player-rollback")
    moved = tonumber(moved) or 0
    transferSleep(CONFIG.transferSettleDelay)

    local after = chestItemCount(itemName)
    local physicalMoved = moved
    if after ~= nil then
        physicalMoved = math.max(0, before - after)
    end

    writeLog("SUPPLY ROLLBACK item=" .. tostring(itemName) ..
        " barrel=" .. tostring(before) .. "->" .. tostring(after) ..
        " apiMoved=" .. tostring(moved) ..
        " physicalMoved=" .. tostring(physicalMoved) ..
        " attempt=" .. tostring(p.rollbackAttempts) ..
        " reason=" .. tostring(err or "none"))

    if after ~= nil and after <= 0 then
        clearPending("stranded supply remainder rolled back to Player RS")
        health.transfer = true
        health.message = "ROLLED BACK: " .. tostring(itemName) ..
            " returned to Player RS; request may retry"
        return true, "rolled back"
    end

    p.lastError = "rollback to Player RS incomplete; barrel " ..
        tostring(after ~= nil and after or "?") .. " remains"
    saveState()
    health.transfer = false
    health.message = "ROLLBACK BLOCKED: " .. tostring(itemName) ..
        " x" .. tostring(after ~= nil and after or before)
    return false, p.lastError
end

-- A dedicated transfer barrel should never contain an item when there is no
-- transaction record. This can occur after older recovery code releases the
-- software lock before the physical item is resolved. Recover one unambiguous
-- item type back to Player RS; never guess when mixed contents are present.
function NBTX.recoverOrphanedBarrel()
    if state.pending then return true end

    local itemName, count, reason = NBTX.singleBarrelItem()
    if count == 0 then return true end
    if not itemName or not count then
        if reason then
            health.transfer = false
            health.message = "BARREL ORPHAN BLOCKED: " .. tostring(reason)
            writeLog(health.message)
        end
        return false
    end

    local before = count
    local moved, err = retryImport(NBTX.importToPlayer, itemName, before, "player-orphan-recovery")
    moved = tonumber(moved) or 0
    transferSleep(CONFIG.transferSettleDelay)
    local after = chestItemCount(itemName)
    local physicalMoved = after ~= nil and math.max(0, before - after) or moved

    writeLog("ORPHAN BARREL RECOVERY item=" .. tostring(itemName) ..
        " barrel=" .. tostring(before) .. "->" .. tostring(after) ..
        " apiMoved=" .. tostring(moved) ..
        " physicalMoved=" .. tostring(physicalMoved) ..
        " reason=" .. tostring(err or "none"))

    if after ~= nil and after <= 0 then
        health.transfer = true
        health.message = "Recovered orphaned barrel item to Player RS: " ..
            tostring(itemName) .. " x" .. tostring(before)
        return true
    end

    health.transfer = false
    health.message = "BARREL ORPHAN BLOCKED: " .. tostring(itemName) ..
        " x" .. tostring(after ~= nil and after or before)
    return false
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

    -- v2.54: once recovery has switched a failed supply transaction into
    -- rollback mode, never try the Colony destination again from this snapshot.
    -- Keep returning the stranded barrel remainder to Player RS until the barrel
    -- is physically empty, then release the transaction for a clean request retry.
    if kind == "supply" and p.rollbackToPlayer == true then
        return NBTX.rollbackPendingSupplyToPlayer(p)
    end

    -- v2.50: a supply import whose barrel leg completed but destination gain was
    -- not confirmed must stay in a short acknowledgement window. Never convert
    -- "barrel empty" into success by itself.
    if kind == "supply" and tostring(p.stage or "") == "confirming" then
        local expected = math.max(0, math.floor(tonumber(p.destinationExpected) or exported))
        local baseline = math.max(0, math.floor(tonumber(p.destinationBefore) or 0))
        local already = math.max(0, math.floor(tonumber(p.imported) or 0))
        local confirmed, maxSeen, samples = NBTX.confirmColonyArrival(
            itemName, baseline, expected, p.destinationMaxSeen)
        p.destinationMaxSeen = maxSeen

        if confirmed > already then
            local newlyConfirmed = confirmed - already
            p.imported = confirmed
            finishImportedAmount(requestId, itemName, newlyConfirmed)
            recordTransferHistory("P>WH", itemName, newlyConfirmed, requestId, "recovered-confirmed")
            writeLog("RECOVER DEST CONFIRMED item=" .. tostring(itemName) ..
                " request=" .. tostring(requestId) ..
                " newly=" .. tostring(newlyConfirmed) ..
                " total=" .. tostring(confirmed) .. "/" .. tostring(expected) ..
                " samples=" .. tostring(samples))
            saveState()
        end

        if confirmed >= expected and expected > 0 then
            clearPending("destination confirmation completed")
            health.transfer = true
            health.message = "Pending transfer destination confirmed"
            return true
        end

        if not NBTX.isColonyRequestActive(requestId) then
            clearPending("MineColonies request resolved while destination confirmation was pending")
            health.transfer = true
            health.message = "Request acknowledged by colony"
            return true
        end

        local since = tonumber(p.destinationUnconfirmedSince) or tonumber(p.lastAttempt) or nowSeconds()
        local timeout = math.max(5, math.floor(tonumber(CONFIG.destinationConfirmTimeout) or 20))
        if nowSeconds() - since >= timeout then
            writeLog("DESTINATION CONFIRM TIMEOUT item=" .. tostring(itemName) ..
                " request=" .. tostring(requestId) ..
                " confirmed=" .. tostring(confirmed) .. "/" .. tostring(expected) ..
                " colonyBaseline=" .. tostring(baseline) ..
                " maxSeen=" .. tostring(maxSeen) ..
                " - clearing pending WITHOUT credit so live request can retry")
            clearPending("destination unconfirmed timeout; request remains active")
            health.transfer = false
            health.message = "DESTINATION UNCONFIRMED: retrying live request"
            return true
        end

        p.lastAttempt = nowSeconds()
        p.lastError = "waiting for Colony RS destination confirmation; " ..
            tostring(confirmed) .. "/" .. tostring(expected) ..
            " samples=" .. tostring(samples)
        saveState()
        health.transfer = false
        health.message = "DESTINATION UNCONFIRMED: " .. tostring(itemName) ..
            " " .. tostring(confirmed) .. "/" .. tostring(expected)
        return false
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
            -- v2.50: empty barrel alone is NOT proof that Colony RS retained a
            -- supply item. Convert supply recovery to destination-confirmation
            -- state instead of false-crediting it. Overflow/probe keep their
            -- destination-specific recovery behavior.
            if kind == "supply" then
                p.stage = "confirming"
                p.destinationBefore = math.max(0, math.floor(tonumber(p.destinationBefore) or 0))
                p.destinationMaxSeen = math.max(p.destinationBefore, math.floor(tonumber(p.destinationMaxSeen) or p.destinationBefore))
                p.destinationExpected = math.max(ambiguous, math.floor(tonumber(p.destinationExpected) or 0))
                p.destinationUnconfirmedSince = p.destinationUnconfirmedSince or nowSeconds()
                p.lastAttempt = nowSeconds()
                p.lastError = "empty barrel after supply import; Colony RS destination unconfirmed"
                saveState()
                health.transfer = false
                health.message = "DESTINATION UNCONFIRMED: " .. tostring(itemName)
                writeLog("RECOVER supply empty-barrel converted to destination confirmation item=" ..
                    tostring(itemName) .. " request=" .. tostring(requestId) ..
                    " amount=" .. tostring(ambiguous))
                return false
            elseif kind == "overflow" then
                recordTransferHistory("WH>P", itemName, ambiguous, nil, "recovered-empty")
            elseif kind == "probe" then
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
        -- v2.54: counters are never allowed to release a supply transaction
        -- while the dedicated barrel still physically contains that item. Older
        -- false-positive bookkeeping can otherwise orphan the item and hard-block
        -- every later request. Roll the physical remainder back to Player RS.
        if kind == "supply" then
            local physicalRemaining = chestItemCount(itemName)
            if physicalRemaining ~= nil and physicalRemaining > 0 then
                p.rollbackToPlayer = true
                p.stage = "rollback"
                p.lastError = "bookkeeping complete but barrel still contains " ..
                    tostring(physicalRemaining)
                saveState()
                writeLog("SUPPLY COUNTER/PHYSICAL MISMATCH item=" .. tostring(itemName) ..
                    " exported=" .. tostring(exported) ..
                    " imported=" .. tostring(imported) ..
                    " barrel=" .. tostring(physicalRemaining))
                return NBTX.rollbackPendingSupplyToPlayer(p)
            end
        end

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
            -- For supply recovery, `moved` proves only that the barrel lost items.
            -- Derive the cumulative amount removed from the barrel when possible,
            -- then require fresh Colony-RS growth above the pre-import baseline.
            local baseline = tonumber(p.destinationBefore)
            if baseline == nil then
                -- Old pending state may predate v2.50. If some import could already
                -- have happened, establishing a new baseline now cannot prove it;
                -- fail closed and let the live request retry after timeout.
                baseline = NBTX.getFreshRSAmount(colonyRS, itemName)
                p.destinationBefore = baseline
            end

            local barrelRemaining = chestItemCount(itemName)
            local expectedArrival
            if barrelRemaining ~= nil then
                expectedArrival = math.max(0, exported - barrelRemaining)
            else
                expectedArrival = math.min(exported, imported + moved)
            end

            local confirmed, maxSeen, samples = NBTX.confirmColonyArrival(
                itemName, baseline, expectedArrival, p.destinationMaxSeen)
            p.destinationMaxSeen = maxSeen
            local newlyConfirmed = math.max(0, confirmed - imported)
            if newlyConfirmed > 0 then
                finishImportedAmount(requestId, itemName, newlyConfirmed)
                recordTransferHistory("P>WH", itemName, newlyConfirmed, requestId, "recovered-confirmed")
            end
            p.imported = math.max(imported, confirmed)

            if barrelRemaining ~= nil and barrelRemaining == 0 and p.imported < exported then
                p.stage = "confirming"
                p.destinationExpected = exported
                p.destinationUnconfirmedSince = p.destinationUnconfirmedSince or nowSeconds()
                p.lastError = "barrel empty after recovery import; Colony RS confirmed " ..
                    tostring(p.imported) .. "/" .. tostring(exported) ..
                    " samples=" .. tostring(samples)
            else
                p.stage = "importing"
                p.lastError = nil
            end

            writeLog("RECOVER supply destination check item=" .. tostring(itemName) ..
                " barrelMoved=" .. tostring(moved) ..
                " confirmed=" .. tostring(p.imported) .. "/" .. tostring(exported) ..
                " barrelRemaining=" .. tostring(barrelRemaining) ..
                " samples=" .. tostring(samples))
        elseif kind == "overflow" then
            recordTransferHistory("WH>P", itemName, moved, nil, "recovered")
            p.imported = imported + moved
        else
            p.imported = imported + moved
        end

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
            p.stage = "confirming"
            p.destinationBefore = math.max(0, math.floor(tonumber(p.destinationBefore) or 0))
            p.destinationMaxSeen = math.max(p.destinationBefore, math.floor(tonumber(p.destinationMaxSeen) or p.destinationBefore))
            p.destinationExpected = math.max(ambiguous, math.floor(tonumber(p.destinationExpected) or 0))
            p.destinationUnconfirmedSince = p.destinationUnconfirmedSince or nowSeconds()
            p.lastAttempt = nowSeconds()
            p.lastError = "barrel empty after recovery import; Colony RS destination unconfirmed"
            saveState()
            health.transfer = false
            health.message = "DESTINATION UNCONFIRMED: " .. tostring(itemName)
            writeLog("RECOVER refused empty-barrel supply credit item=" .. tostring(itemName) ..
                " request=" .. tostring(requestId) .. " amount=" .. tostring(ambiguous))
            return false
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

    -- v2.54: a real supply item that remains physically in the barrel after
    -- repeated Colony-import recovery cycles is safe to roll back to Player RS.
    -- This prevents one destination-side failure from wedging the shared barrel
    -- and turning every unrelated request into WAITING/BLOCKED indefinitely.
    if kind == "supply" then
        local rollbackAfter = math.max(2, math.floor(tonumber(CONFIG.pendingImportRollbackAttempts) or 8))
        local barrelCount = chestItemCount(itemName)
        if barrelCount ~= nil and barrelCount > 0 and p.attempts >= rollbackAfter then
            p.rollbackToPlayer = true
            p.stage = "rollback"
            p.lastError = "Colony import failed " .. tostring(p.attempts) ..
                " recovery cycles; rolling stranded remainder back to Player RS"
            saveState()
            writeLog("SUPPLY ROLLBACK ARMED item=" .. tostring(itemName) ..
                " barrel=" .. tostring(barrelCount) ..
                " attempts=" .. tostring(p.attempts))
            return NBTX.rollbackPendingSupplyToPlayer(p)
        end
    end

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

    -- Capture a fresh destination baseline immediately before the import.
    -- Only a later increase above this value may be credited as P>WH success.
    local colonyBefore = NBTX.getFreshRSAmount(colonyRS, itemName)
    p.destinationBefore = colonyBefore
    p.destinationMaxSeen = colonyBefore
    p.destinationExpected = exported
    p.stage = "importing"
    saveState()

    local barrelMoved, importErr = retryImport(NBTX.importToColony, itemName, exported, "colony")
    barrelMoved = tonumber(barrelMoved) or 0
    local imported = 0

    if barrelMoved > 0 then
        local confirmed, maxSeen, samples = NBTX.confirmColonyArrival(
            itemName, colonyBefore, barrelMoved, p.destinationMaxSeen)
        p.destinationMaxSeen = maxSeen
        imported = math.max(0, math.floor(tonumber(confirmed) or 0))

        if imported > 0 then
            p.imported = imported
            finishImportedAmount(requestId, itemName, imported)
            recordTransferHistory("P>WH", itemName, imported, requestId, "supply-confirmed")
            writeLog("IMPORT DEST CONFIRMED item=" .. tostring(itemName) ..
                " request=" .. tostring(requestId) ..
                " barrelMoved=" .. tostring(barrelMoved) ..
                " colony=" .. tostring(colonyBefore) .. "->" .. tostring(maxSeen) ..
                " confirmed=" .. tostring(imported) ..
                " samples=" .. tostring(samples))
        end

        if imported < barrelMoved then
            local barrelRemaining = chestItemCount(itemName)
            if barrelRemaining ~= nil and barrelRemaining > 0 then
                -- A partial destination import still has real items in the barrel.
                -- Keep the transaction in importing state; recovery will retry only
                -- what the barrel can actually provide and will destination-verify
                -- each cumulative result before crediting it.
                p.stage = "importing"
                p.destinationExpected = math.max(0, exported - barrelRemaining)
                p.lastError = "partial barrel import destination unconfirmed; barrelRemaining=" ..
                    tostring(barrelRemaining) .. " colony " ..
                    tostring(colonyBefore) .. "->" .. tostring(maxSeen) ..
                    " samples=" .. tostring(samples)
            else
                -- The barrel is empty (or became unreadable) but Colony RS has not
                -- evidenced the complete shipment. Hold for delayed destination
                -- visibility/request acknowledgement; never credit from emptiness.
                p.stage = "confirming"
                p.destinationExpected = exported
                p.destinationUnconfirmedSince = p.destinationUnconfirmedSince or nowSeconds()
                p.lastError = "barrel emptied but Colony RS gain unconfirmed; colony " ..
                    tostring(colonyBefore) .. "->" .. tostring(maxSeen) ..
                    " samples=" .. tostring(samples)
            end
            p.lastAttempt = nowSeconds()
            saveState()
            health.transfer = false
            health.message = "DESTINATION UNCONFIRMED: " .. tostring(itemName) ..
                " " .. tostring(imported) .. "/" .. tostring(exported)
            writeLog("IMPORT DEST UNCONFIRMED item=" .. tostring(itemName) ..
                " request=" .. tostring(requestId) ..
                " barrelMoved=" .. tostring(barrelMoved) ..
                " confirmed=" .. tostring(imported) ..
                " reason=" .. tostring(p.lastError))
            -- Return zero to the request processor while the transaction remains
            -- pending. Any positively confirmed amount has already been credited;
            -- this prevents the caller from starting a craft or reporting completion.
            return 0, p.lastError, "source_export_ok"
        end

        saveState()
        writeLog("IMPORT BARREL->B " .. imported .. " " .. itemName ..
        " request=" .. requestId ..
        " mode=" .. ((CONFIG.usePeripheralTransfer and CONFIG.transferChestName)
            and "peripheral" or "directional"))
    end

    if imported >= exported then
        clearPending("transaction completed with destination confirmation")
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

    -- The overflow path is the reverse of normal supply. Verify the source
    -- export at the shared barrel instead of trusting only the RS Bridge return.
    -- This also gives us a safe condition for trying the named-peripheral API:
    -- if the barrel count did not increase, the first export did not physically
    -- stage this item and a bounded fallback cannot duplicate it.
    local barrelBefore = chestItemCount(itemName)

    local exported, exportErr = NBTX.exportFromColony(itemName, amount)
    exported = math.max(0, math.floor(tonumber(exported) or 0))

    if barrelBefore ~= nil then
        transferSleep(CONFIG.transferSettleDelay)
        local barrelAfter = chestItemCount(itemName)

        if barrelAfter ~= nil then
            local physicalExported = math.max(0, barrelAfter - barrelBefore)
            physicalExported = math.min(physicalExported, amount)

            if physicalExported ~= exported then
                writeLog(
                    "OVERFLOW EXPORT VERIFY mismatch item=" .. tostring(itemName) ..
                    " reported=" .. tostring(exported) ..
                    " physical=" .. tostring(physicalExported) ..
                    " barrel=" .. tostring(barrelBefore) .. "->" .. tostring(barrelAfter)
                )
            end

            exported = physicalExported

            -- v2.40: the Player->Colony direction was already proven in normal
            -- operation, but the reverse Colony->barrel leg may fail with the
            -- directional API. The barrel is on the wired peripheral network,
            -- so try AP's named-container export exactly once when the verified
            -- directional movement is zero.
            if exported <= 0 then
                local barrelName = transferChestResolvedName
                if barrelName and peripheral.isPresent(barrelName) then
                    local fallbackFilter = { name = itemName, count = amount }
                    local okFallback, fallbackMoved, fallbackErr = safeCall(
                        colonyRS,
                        "exportItemToPeripheral",
                        fallbackFilter,
                        barrelName
                    )

                    fallbackMoved = math.max(0, math.floor(tonumber(fallbackMoved) or 0))
                    transferSleep(CONFIG.transferSettleDelay)

                    local barrelAfterFallback = chestItemCount(itemName)
                    if barrelAfterFallback ~= nil then
                        local fallbackPhysical =
                            math.max(0, barrelAfterFallback - barrelBefore)
                        fallbackPhysical = math.min(fallbackPhysical, amount)

                        writeLog(
                            "OVERFLOW EXPORT FALLBACK item=" .. tostring(itemName) ..
                            " barrel=" .. tostring(barrelName) ..
                            " apiOK=" .. tostring(okFallback) ..
                            " reported=" .. tostring(fallbackMoved) ..
                            " physical=" .. tostring(fallbackPhysical)
                        )

                        if fallbackPhysical > 0 then
                            exported = fallbackPhysical
                            exportErr = nil
                            NBTX.invalidateRSList(colonyRS)
                        else
                            exportErr = fallbackErr or fallbackMoved or exportErr or
                                "named-barrel export moved 0"
                        end
                    else
                        -- We started from a verifiable barrel. If verification
                        -- disappears after the fallback, do not trust the bridge
                        -- return and do not claim the overflow moved.
                        exported = 0
                        exportErr = "Transfer barrel verification unavailable after overflow export fallback"
                    end
                end
            end
        else
            -- A visible barrel became unreadable during the export. Do not
            -- convert an unverified bridge return into a successful overflow.
            exported = 0
            exportErr = "Transfer barrel verification unavailable after colony export"
        end
    elseif exported <= 0 then
        -- If inventory inspection itself is unavailable but the barrel still has
        -- a resolved peripheral name, retain a best-effort named-container
        -- fallback. This path cannot physically verify the move, so it is used
        -- only when the normal directional call already moved zero.
        local barrelName = transferChestResolvedName
        if barrelName and peripheral.isPresent(barrelName) then
            local okFallback, fallbackMoved, fallbackErr = safeCall(
                colonyRS,
                "exportItemToPeripheral",
                { name = itemName, count = amount },
                barrelName
            )
            if okFallback then
                fallbackMoved = math.max(0, math.floor(tonumber(fallbackMoved) or 0))
                if fallbackMoved > 0 then
                    exported = fallbackMoved
                    exportErr = nil
                    NBTX.invalidateRSList(colonyRS)
                    writeLog("OVERFLOW EXPORT FALLBACK unverified item=" ..
                        tostring(itemName) .. " moved=" .. tostring(exported))
                else
                    exportErr = fallbackErr or exportErr
                end
            else
                exportErr = fallbackMoved or fallbackErr or exportErr
            end
        end
    end

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
    ["RS STALE"] = 2,
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
    ["RS STALE"] = colors.orange,
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
    if row.status == "ERROR" or row.status == "BLOCKED" or row.status == "RS STALE" or row.status == "RS DESYNC" then
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

-- Return scalar overflow metrics without allocating per-item tracking tables.
-- The configured OVERFLOW threshold is always the minimum floor. Active demand
-- may temporarily raise that floor so overflow return cannot strip stock needed
-- for an in-flight colony request.
local function overflowMetrics(row, activeDemand)
    local current = math.max(0, tonumber(row and row.current) or 0)
    local target = math.max(0, tonumber(row and row.target) or 0)
    local overflowFloor = math.max(target, tonumber(row and row.overflow) or target)
    local protectedDemand = math.max(0,
        tonumber(activeDemand and row and activeDemand[row.item]) or 0)
    local demandFloor = target + protectedDemand
    local safeFloor = math.max(overflowFloor, demandFloor)
    local overLimit = current > overflowFloor
    local returnable = overLimit and math.max(0, current - safeFloor) or 0
    return protectedDemand, overflowFloor, demandFloor, safeFloor, overLimit, returnable
end

local function passiveOverflowReason(err)
    err = tostring(err or "")
    return err == ""
        or err == "disabled"
        or err == "no eligible overflow"
        or err:find("^held for active demand", 1, false) ~= nil
end

local function processWarehouseOverflow()
    if not (state.settings and state.settings.overflowEnabled == true) then return 0, "disabled" end
    if state.pending then return 0, "pending transfer" end

    local activeDemand = getActiveProtectedDemand()
    local best = nil
    local held = nil

    for _, row in ipairs(settingsRows) do
        local protectedDemand, overflowFloor, demandFloor, safeFloor, overLimit, returnable =
            overflowMetrics(row, activeDemand)

        if overLimit and returnable > 0 then
            if not best or returnable > best.excess then
                best = {
                    row = row,
                    excess = returnable,
                    protectedDemand = protectedDemand,
                    overflowFloor = overflowFloor,
                    demandFloor = demandFloor,
                    safeFloor = safeFloor,
                }
            end
        elseif overLimit and protectedDemand > 0 and not held then
            held = {
                row = row,
                protectedDemand = protectedDemand,
                overflowFloor = overflowFloor,
                demandFloor = demandFloor,
                safeFloor = safeFloor,
            }
        end
    end

    if not best then
        if held then
            return 0, "held for active demand: " .. tostring(held.row.item) ..
                " floor=" .. tostring(math.floor(held.safeFloor))
        end
        return 0, "no eligible overflow"
    end

    local amount = math.min(best.excess, tonumber(CONFIG.maxOverflowChunk) or 64)
    local moved, err = performOverflowReturn(best.row.item, amount)
    if moved > 0 then
        health.message = "Returned " .. moved .. " " .. best.row.displayName .. " to player RS"
        writeLog("OVERFLOW returned " .. moved .. " " .. best.row.item ..
            " current=" .. tostring(best.row.current) ..
            " target=" .. tostring(best.row.target) ..
            " overflowFloor=" .. tostring(best.overflowFloor) ..
            " safeFloor=" .. tostring(best.safeFloor) ..
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

    -- v2.51: If MineColonies reuses the same request ID but changes the requested
    -- quantity after a partial delivery, the new quantity is already the authoritative
    -- remainder. Clear the old local supplied credit before candidate selection so we
    -- never subtract the same delivery twice.
    if type(rs.awaitingRequestRefresh) == "table" then
        local oldRequested = math.max(0, math.floor(tonumber(rs.awaitingRequestRefresh.requested) or 0))
        if requested ~= oldRequested then
            NBTX.clearAwaitingRequestRefresh(
                rs,
                "MineColonies quantity changed " .. tostring(oldRequested) ..
                    "->" .. tostring(requested)
            )
            rs.supplied = 0
            rs.lastTransfer = nil
            saveState()
        end
    end

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

    if type(rs.awaitingRequestRefresh) == "table"
        and tostring(rs.awaitingRequestRefresh.item or "") ~= tostring(candidate.name or "") then
        NBTX.clearAwaitingRequestRefresh(
            rs,
            "selected candidate changed to " .. tostring(candidate.name or "?")
        )
        rs.supplied = 0
        rs.lastTransfer = nil
        supplied = 0
        saveState()
    end

    rs.item = candidate.name
    rs.displayName = candidate.displayName

    local playerStock = candidate.playerStock or NBTX.getRSAmountByCandidate(playerRS, candidate)
    local warehouseStock = candidate.warehouseStock or NBTX.getRSAmountByCandidate(colonyRS, candidate)

    -- v2.50 recovery for credits created by older barrel-only confirmation. If
    -- Supply believes it fully satisfied this still-active request, Colony RS
    -- contains none of the item, and the grace period has elapsed, the local
    -- credit is stale. Drop only that request's credit so the live request can
    -- retry; settings/history and unrelated request state are untouched.
    if supplied >= requested and requested > 0 and warehouseStock <= 0
        and not state.pending and tonumber(rs.lastTransfer) then
        local age = nowSeconds() - tonumber(rs.lastTransfer)
        local grace = math.max(5, math.floor(tonumber(CONFIG.destinationConfirmTimeout) or 20))
        if age >= grace then
            writeLog("REQUEST CREDIT RECONCILE id=" .. tostring(id) ..
                " item=" .. tostring(candidate.name) ..
                " supplied=" .. tostring(supplied) ..
                " requested=" .. tostring(requested) ..
                " warehouse=0 age=" .. tostring(age) ..
                " - live request still active; clearing stale local credit")
            rs.supplied = 0
            rs.lastTransfer = nil
            supplied = 0
            saveState()
        end
    end

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
            " rejectedEquipmentStock=" .. tostring(candidate.rejectedEquipmentStock or 0) ..
            " equipmentCraftConflict=" .. tostring(candidate.equipmentCraftConflict == true)
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

    -- A partial shipment from this exact MineColonies request snapshot has already
    -- completed. Do not transfer more or start a craft until MineColonies changes
    -- the request quantity/replaces the request. This is the serialization point
    -- for multiple colonies sharing one Player RS network.
    if type(rs.awaitingRequestRefresh) == "table" then
        local gate = rs.awaitingRequestRefresh
        local age = math.max(0, nowSeconds() - (tonumber(gate.since) or nowSeconds()))
        row.status = "WAITING"
        row.message = "Partial shipment sent; waiting for MineColonies request refresh" ..
            " (" .. tostring(age) .. "s)"
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
            row.status = "RS STALE"
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
        local staleReported = math.max(0, math.floor(tonumber(itemDesync.reported) or 0))
        if playerStock <= 0 then
            -- The stock that originally failed extraction is no longer present.
            -- The request may now legitimately need crafting.
            NBTX.clearRSDesync(candidate, "reported source stock no longer present")
            itemDesync = nil
        elseif staleReported > 0 and math.floor(playerStock) ~= staleReported then
            -- A quantity change proves the snapshot is no longer the same stale
            -- condition. Clear immediately and let this scan retry normally.
            NBTX.clearRSDesync(candidate,
                "reported source stock changed " .. tostring(staleReported) ..
                "->" .. tostring(math.floor(playerStock)))
            itemDesync = nil
        elseif not itemRetryDue then
            row.status = "RS STALE"
            row.rsCountdown = itemRetryWait
            row.message = "Player RS item appears stale; retry in " ..
                tostring(itemRetryWait) .. "s; other requests continue"
            addRow(row)
            return
        else
            row.rsCountdown = 0
            writeLog("RS STALE RETRY due item=" .. tostring(candidate.name) ..
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
        row.status = "BLOCKED"
        row.message = "Probe item stuck in barrel: " ..
            tostring(probeCleanup.item or "?") .. " x" .. tostring(probeRemaining) ..
            "; partial stock must transfer before shortage crafting"
        addRow(row)
        return
    end

    ------------------------------------------------------------------
    -- v2.51 shared-RS policy:
    -- Partial stock is transferred first. If Player RS has less than the live
    -- request, do not craft the shortage from this same request snapshot. After
    -- the shipment is confirmed, wait for MineColonies to publish the reduced
    -- remainder before any craft decision is made.
    ------------------------------------------------------------------

    ------------------------------------------------------------------
    -- Source-stock transfer path. At this point either enough stock exists to
    -- satisfy the remaining request, or the item is not currently craftable.
    -- A positive stock reading is still verified by the real export operation,
    -- with the existing RS STALE protections if that export contradicts RS.
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
                -- If the Player RS snapshot did not contain enough stock to cover
                -- this live MineColonies request, serialize the handoff: ship what
                -- exists, then wait for MineColonies to publish the new remainder.
                -- Do not predict/craft the shortage from this old snapshot.
                if playerStock < remaining then
                    NBTX.markAwaitingRequestRefresh(rs, requested, candidate, moved)
                    saveState()
                    row.status = "PARTIAL"
                    row.message = "Moved " .. tostring(moved) ..
                        "; waiting for MineColonies request refresh before crafting"
                    writeLog(
                        "PARTIAL WAIT request=" .. tostring(id) ..
                        " item=" .. tostring(candidate.name) ..
                        " requested=" .. tostring(requested) ..
                        " moved=" .. tostring(moved) ..
                        " playerSnapshot=" .. tostring(playerStock)
                    )
                else
                    row.status = "PARTIAL"
                    row.message = "Transferred " .. tostring(moved)
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
                -- A real export contradicted the positive stock snapshot. Do not
                -- globally latch on one contradiction. First require multiple
                -- stable, uncached listItems() reads. If RS changes underneath us,
                -- treat it as a transient refresh and retry on the next scan.
                local baseline = math.max(tonumber(freshStock) or 0, tonumber(playerStock) or 0)
                local staleConfirmed, verifiedStock, verifyDetail =
                    NBTX.confirmRSStale(candidate, baseline)

                if staleConfirmed then
                    NBTX.markRSDesync(
                        candidate,
                        verifiedStock,
                        remaining,
                        err or verifyDetail or "Player RS export returned 0 with stable positive stock"
                    )
                    row.status = "RS STALE"
                    local _, _, retryDue, retryWait = NBTX.getRSDesync(candidate)
                    row.rsCountdown = retryDue and 0 or retryWait
                    local entry = select(1, NBTX.getRSDesync(candidate))
                    local failures = type(entry) == "table" and (tonumber(entry.failures) or 1) or 1
                    row.message = "Player RS reports " .. tostring(verifiedStock) ..
                        " but export moved 0; stale retry " .. tostring(failures) ..
                        "; other requests continue" ..
                        (failures >= 3 and "; reseat RS storage disk if persistent" or "")
                else
                    NBTX.clearRSDesync(candidate, verifyDetail or "fresh RS stock changed")
                    row.status = "WAITING"
                    row.rsCountdown = nil
                    row.message = "RS inventory refreshed after export=0; retrying next scan"
                    writeLog("RS STALE NOT CONFIRMED item=" .. tostring(candidate.name) ..
                        " baseline=" .. tostring(baseline) ..
                        " verified=" .. tostring(verifiedStock) ..
                        " detail=" .. tostring(verifyDetail or "none"))
                end

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
            if tostring(craftMessage or ""):find("^EQUIPMENT VARIANT CONFLICT:") then
                row.status = "BLOCKED"
                row.message = tostring(craftMessage)
                health.message = "CRAFT BLOCKED " .. tostring(candidate.name) ..
                    ": damaged/enchanted same-name copies in Player RS"
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
    NBTX.pruneRSDesync()
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

    -- v2.54 migration/recovery: older versions could release state.pending while
    -- the dedicated transfer barrel still contained a stranded supply item.
    -- Recover one unambiguous orphan back to Player RS before processing requests.
    if not state.pending then
        NBTX.recoverOrphanedBarrel()
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
    local overflowErr = nil
    if not state.pending and not state.probeCleanup and not NBTX.isRSSafetyLatched() then
        overflowMoved, overflowErr = processWarehouseOverflow()
        overflowMoved = tonumber(overflowMoved) or 0
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
            local overflowFailure = overflowErr and not passiveOverflowReason(overflowErr)

            if overflowFailure then
                -- performOverflowReturn() sets the most specific transfer message
                -- (for example BARREL BLOCKED). Preserve it instead of replacing
                -- it with the generic Online text at the end of this scan.
                health.transfer = false
                if not health.message or health.message == "" or health.message == "Online" then
                    health.message = "OVERFLOW BLOCKED: " .. tostring(overflowErr)
                end
            else
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

    if status == "RS PAUSED" or status == "RS STALE" or status == "RS DESYNC" then
        local due, wait
        if (status == "RS STALE" or status == "RS DESYNC")
            and type(row) == "table" and row.rsCountdown ~= nil then
            wait = math.max(0, math.floor(tonumber(row.rsCountdown) or 0))
            due = wait <= 0
        else
            due, wait = NBTX.rsSafetyProbeStatus()
        end
        local suffix = due and " NOW" or (" " .. tostring(wait) .. "s")
        local full = status .. suffix
        if #full <= width then return full end

        local shortBase = status == "RS PAUSED" and "PAUSED" or "STALE"
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
        monitorUI.drawMessagePanel({
            title = title, message = message, titleColor = color or UI.title,
            bg = UI.panel, fg = UI.text,
        })
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
        local currentColor =
            (state.settings and state.settings.overflowEnabled == true and
             (tonumber(row.current) or 0) > (tonumber(row.overflow) or 0))
            and UI.warn or UI.text
        monitorWrite(columns.currentX, y, padRight(formatNumber(row.current), columns.currentW), currentColor, bg)

        y = y + 1
    end

    local footer =
        "Touch row to edit | Orange CURRENT = over limit | General " ..
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
    local rowsPerPage, totalPages = historyRowsPerPage()
    historyPage = clamp(historyPage, 1, totalPages)

    drawSupplyHeader(
        w,
        "TRANSFER HISTORY  (" .. tostring(#history) .. ")  PAGE " ..
            tostring(historyPage) .. "/" .. tostring(totalPages),
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

    -- History navigation is deliberately manual.  Unlike the request pages,
    -- History never auto-advances: PREV and NEXT are the only page-changing
    -- controls.  REFRESH redraws the current page without changing it.
    monitorWrite(1, h - 1, string.rep(" ", w), UI.muted, UI.panel)
    local third = math.max(1, math.floor(w / 3))
    local rightStart = math.min(w, third * 2 + 1)
    monitorWrite(
        1, h - 1,
        padRight(centerText("< PREV", third), third),
        UI.text, UI.panel
    )
    local middleWidth = math.max(1, rightStart - third - 1)
    monitorWrite(
        third + 1, h - 1,
        padRight(centerText("REFRESH", middleWidth), middleWidth),
        UI.accent, UI.panel
    )
    local rightWidth = math.max(1, w - rightStart + 1)
    monitorWrite(
        rightStart, h - 1,
        padRight(centerText("NEXT >", rightWidth), rightWidth),
        UI.text, UI.panel
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


local function renderTerminal()
    if not CONFIG.mirrorTerminal then return end

    SharedUI.resetTerminal(colors.white, colors.black)

    local transferPathOnline = health.playerRS and health.colonyRS and health.transfer
    local overallHealthy =
        health.playerRS
        and health.colonyRS
        and health.warehouse
        and transferPathOnline

    print("MineColonies Supply Manager v" .. PROGRAM_VERSION)
    print("Control Suite: v" .. SUITE_VERSION)
    print("Colony: " .. tostring(colonyName or "Unknown Colony"))

    SharedUI.setTerminalColor(overallHealthy and colors.lime or colors.orange)
    print("HEALTH:      " .. (overallHealthy and "ONLINE" or "DEGRADED"))

    SharedUI.setTerminalColor(colors.white)
    print("Player RS:   " .. healthWord(health.playerRS) ..
        "  [" .. tostring(playerBridgeResolvedName or "?") .. "]")
    print("Colony RS:   " .. healthWord(health.colonyRS) ..
        "  [" .. tostring(colonyBridgeResolvedName or "?") .. "]")
    print("Warehouse:   " .. healthWord(health.warehouse))
    print("Transfer:    " .. healthWord(transferPathOnline))
    print("Barrel:      " .. tostring(transferChestResolvedName or "NOT DETECTED"))
    print("Status:      " .. tostring(health.message))

    local updateText, updateColor = UPDATE.terminalStatus()
    SharedUI.setTerminalColor(updateColor)
    print("UPDATE:      " .. tostring(updateText))

    SharedUI.setTerminalColor(colors.white)
    print("Suite source: " .. tostring(UPDATE.sourceLabel()))
    print(string.rep("-", 50))

    local maxRows = 10
    for i = 1, math.min(#dashboardRows, maxRows) do
        local row = dashboardRows[i]
        SharedUI.setTerminalColor(statusColor(row.status))
        print(string.format(
            "%-22s %5d/%-5d %-13s",
            truncateText(row.displayName, 22),
            row.supplied or 0,
            row.requested or 0,
            NBTX.dashboardStatusText(row.status, 13, row)
        ))
    end

    SharedUI.setTerminalColor(colors.white)
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

local function shiftedPage(page, pages, delta)
    pages = math.max(1, tonumber(pages) or 1)
    return ((tonumber(page) or 1) - 1 + delta) % pages + 1
end

local function nextPage()
    local _, pages = monitorRowsPerPage()
    currentPage = shiftedPage(currentPage, pages, 1)
    lastManualPageChange = nowSeconds()
end

local function previousPage()
    local _, pages = monitorRowsPerPage()
    currentPage = shiftedPage(currentPage, pages, -1)
    lastManualPageChange = nowSeconds()
end

local function nextHistoryPage()
    local _, pages = historyRowsPerPage()
    historyPage = shiftedPage(historyPage, pages, 1)
    lastManualPageChange = nowSeconds()
end

local function previousHistoryPage()
    local _, pages = historyRowsPerPage()
    historyPage = shiftedPage(historyPage, pages, -1)
    lastManualPageChange = nowSeconds()
end

local function nextSettingsPage()
    local _, pages = settingsRowsPerPage()
    settingsPage = shiftedPage(settingsPage, pages, 1)
    lastManualPageChange = nowSeconds()
end

local function previousSettingsPage()
    local _, pages = settingsRowsPerPage()
    settingsPage = shiftedPage(settingsPage, pages, -1)
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

                        elseif y == h - 1 then
                            local third = math.max(1, math.floor(w / 3))
                            if x <= third then
                                if totalPages > 1 then previousHistoryPage() end
                            elseif x > third * 2 then
                                if totalPages > 1 then nextHistoryPage() end
                            else
                                -- REFRESH intentionally keeps historyPage unchanged.
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

local DIAG = {}

function DIAG.wrapDiagnosticLine(text, width)
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

function DIAG.buildDiagnosticDisplayLines(lines, width)
    local wrapped = {}
    for _, line in ipairs(lines or {}) do
        for _, part in ipairs(DIAG.wrapDiagnosticLine(line, width)) do
            wrapped[#wrapped + 1] = part
        end
    end
    if #wrapped == 0 then wrapped[1] = "No diagnostic messages." end
    return wrapped
end

function DIAG.renderDiagnosticMonitor(title, lines, page)
    if not monitor and not resolveMonitor() then return nil, 1, 1 end
    pcall(monitor.setTextScale, CONFIG.monitorTextScale)

    local ok, w, h = pcall(monitor.getSize)
    if not ok or not w or not h then
        monitor = nil
        monitorResolvedName = nil
        return nil, 1, 1
    end

    local contentWidth = math.max(1, w)
    local displayLines = DIAG.buildDiagnosticDisplayLines(lines, contentWidth)
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

function DIAG.terminalDiagnosticFallback(title, lines)
    SharedUI.resetTerminal(colors.white, colors.black)
    print("=== " .. tostring(title) .. " ===")
    for _, line in ipairs(lines or {}) do print(tostring(line)) end
end

function DIAG.showDiagnosticViewer(title, lines)
    local info, page, totalPages = DIAG.renderDiagnosticMonitor(title, lines, 1)
    if not info then
        DIAG.terminalDiagnosticFallback(title, lines)
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
                    info, page, totalPages = DIAG.renderDiagnosticMonitor(title, lines, page)
                    if not info then break end
                end
            end
        elseif event == "key" then
            if p1 == keys.q or p1 == keys.escape then break end
            if p1 == keys.left then
                page = page - 1
                if page < 1 then page = totalPages end
                info, page, totalPages = DIAG.renderDiagnosticMonitor(title, lines, page)
            elseif p1 == keys.right then
                page = page + 1
                if page > totalPages then page = 1 end
                info, page, totalPages = DIAG.renderDiagnosticMonitor(title, lines, page)
            end
        elseif event == "peripheral_detach" and monitorResolvedName and p1 == monitorResolvedName then
            DIAG.terminalDiagnosticFallback(title, lines)
            break
        elseif event == "monitor_resize" then
            info, page, totalPages = DIAG.renderDiagnosticMonitor(title, lines, page)
            if not info then break end
        end
    end
end

-- Non-blocking diagnostic refresh used while the four-stage transfer test is
-- actively running. The completed test enters DIAG.showDiagnosticViewer() so the
-- player can page through the result afterward.
function DIAG.updateDiagnosticMonitor(title, lines)
    if not monitor then resolveMonitor() end
    if monitor then DIAG.renderDiagnosticMonitor(title, lines, 1) end
end

function DIAG.peripheralDiagnosticLines()
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

function DIAG.printPeripheralDiagnostics()
    DIAG.showDiagnosticViewer("PERIPHERAL DIAGNOSTICS v" .. PROGRAM_VERSION, DIAG.peripheralDiagnosticLines())
end

function DIAG.printRequestDiagnostics()
    local lines = {}
    local function add(s) lines[#lines + 1] = tostring(s or "") end

    refreshPeripherals()
    if not colony then
        add("ERROR: No colonyIntegrator found/in colony.")
        DIAG.showDiagnosticViewer("REQUEST DIAGNOSTICS v" .. PROGRAM_VERSION, lines)
        return
    end

    local requests, err = getColonyRequests()
    if not requests then
        add("ERROR: getRequests failed: " .. tostring(err))
        DIAG.showDiagnosticViewer("REQUEST DIAGNOSTICS v" .. PROGRAM_VERSION, lines)
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
        local rawOK, raw = pcall(textutils.serialize, request)
        if rawOK then
            for rawLine in tostring(raw):gmatch("[^\n]+") do add("  " .. rawLine) end
        else
            add("  <omitted: repeated/shared table references>")
            add("  " .. tostring(raw))
        end
        add("")
    end

    DIAG.showDiagnosticViewer("REQUEST DIAGNOSTICS v" .. PROGRAM_VERSION, lines)
end

-- Performs a one-item round-trip through the complete transfer path:
-- Player RS -> barrel -> Colony RS/Warehouse -> barrel -> Player RS.
function DIAG.printSourceDiagnostic(itemName)
    local lines = {}
    local function add(s)
        lines[#lines + 1] = tostring(s or "")
    end

    loadState()

    if not refreshPeripherals() or not playerRS then
        add("ERROR: Player RS Bridge unavailable.")
        DIAG.showDiagnosticViewer("SOURCE v" .. PROGRAM_VERSION, lines)
        return
    end

    if not itemName or itemName == "" then
        add("Usage:")
        add("colony_supply.lua source minecraft:honey_bottle")
        DIAG.showDiagnosticViewer("SOURCE v" .. PROGRAM_VERSION, lines)
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

    DIAG.showDiagnosticViewer("SOURCE v" .. PROGRAM_VERSION, lines)
end

function DIAG.printTransferTest(itemName)
    local lines = {}
    local function add(s)
        lines[#lines + 1] = tostring(s or "")
        DIAG.updateDiagnosticMonitor("TRANSFER TEST v" .. PROGRAM_VERSION, lines)
    end
    local function finish()
        DIAG.showDiagnosticViewer("TRANSFER TEST v" .. PROGRAM_VERSION, lines)
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
    local colonyStage2Before = NBTX.getFreshRSAmount(colonyRS, itemName)
    local b, berr = NBTX.importToColony(itemName, 1)
    local bConfirmed, colonyStage2After, bSamples = NBTX.confirmColonyArrival(
        itemName, colonyStage2Before, tonumber(b) or 0, colonyStage2Before)
    add("    bridge moved=" .. tostring(b) ..
        " confirmed=" .. tostring(bConfirmed) ..
        " colony=" .. tostring(colonyStage2Before) .. "->" .. tostring(colonyStage2After) ..
        (berr and (" error=" .. tostring(berr)) or ""))
    if bConfirmed < 1 then
        add("FAIL at stage 2: barrel emptied/import reported, but Colony RS did not gain item")
        add("Colony samples: " .. tostring(bSamples))
        add("Check Warehouse External Storage insert access/filter and Colony RS refresh state.")
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
function DIAG.printCraftTest(itemName, requestedCount)
    local lines = {}
    local function add(s)
        lines[#lines + 1] = tostring(s or "")
        DIAG.updateDiagnosticMonitor("CRAFT TEST v" .. PROGRAM_VERSION, lines)
    end
    local function finish()
        DIAG.showDiagnosticViewer("CRAFT TEST v" .. PROGRAM_VERSION, lines)
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
function DIAG.printCraftDiagnostics()
    local lines = {}
    local function add(s)
        lines[#lines + 1] = tostring(s or "")
    end

    loadState()

    if not refreshPeripherals() then
        add("ERROR: Required peripherals are unavailable.")
        DIAG.showDiagnosticViewer("CRAFT DIAG v" .. PROGRAM_VERSION, lines)
        return
    end

    local requests, err = getColonyRequests()
    if not requests then
        add("ERROR reading colony requests:")
        add(tostring(err))
        DIAG.showDiagnosticViewer("CRAFT DIAG v" .. PROGRAM_VERSION, lines)
        return
    end

    add("CRAFT DECISION DIAGNOSTIC")
    add("Version: " .. tostring(PROGRAM_VERSION))
    add("AutoCraft: " .. (autoCraftEnabled() and "ON" or "OFF"))
    local safety = NBTX.rsSafetyState()
    add("RS safety: " .. (safety.latched and "PAUSED" or "healthy"))
    add("Player bridge: " .. tostring(playerBridgeResolvedName or "?"))
    add("Craft policy: VERIFY EXTRACTION FIRST; RS STALE NEVER CRAFTS")

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
            local failures = tonumber(entry.failures) or 1
            add("RS STALE: " .. tostring(entry.item or key) ..
                " reported=" .. tostring(entry.reported or "?") ..
                " failures=" .. tostring(failures) ..
                " retry=" .. (due and "DUE" or (tostring(wait) .. "s")))
            add("  " .. tostring(entry.reason or "source export returned 0"))
            if failures >= 3 then add("  Recovery: reseat the Player RS storage disk if this persists.") end
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

    DIAG.showDiagnosticViewer("CRAFT DIAG v" .. PROGRAM_VERSION, lines)
end

-- Explains which current requests are likely to fail at the source side.
-- This diagnostic does NOT move any items.
function DIAG.printBlockedDiagnostics()
    local lines = {}
    local function add(s)
        lines[#lines + 1] = tostring(s or "")
    end

    loadState()

    if not refreshPeripherals() then
        add("ERROR: Required peripherals are not available.")
        DIAG.showDiagnosticViewer("BLOCKED v" .. PROGRAM_VERSION, lines)
        return
    end

    local requests, err = getColonyRequests()
    if not requests then
        add("ERROR reading requests: " .. tostring(err))
        DIAG.showDiagnosticViewer("BLOCKED v" .. PROGRAM_VERSION, lines)
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

    DIAG.showDiagnosticViewer("BLOCKED v" .. PROGRAM_VERSION, lines)
end

-- Shows only transfer-barrel discovery/inspection state.
-- Persist the exact modem-connected transfer barrel.
function DIAG.setTransferBarrelName(name)
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

function DIAG.clearTransferBarrelName()
    loadState()
    state.settings = state.settings or {}
    state.settings.transferChestName = nil
    state.settings.transferChestManual = nil
    saveState()

    print("Saved transfer barrel cleared.")
end

function DIAG.printBarrelDiagnostics()
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

    DIAG.showDiagnosticViewer("BARREL v" .. PROGRAM_VERSION, lines)
end

-- Shows the single transaction which is currently holding the transfer barrel.
-- This diagnostic does not move or clear items.
function DIAG.printPendingDiagnostics()
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
        DIAG.showDiagnosticViewer("PENDING v" .. PROGRAM_VERSION, lines)
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

    DIAG.showDiagnosticViewer("PENDING v" .. PROGRAM_VERSION, lines)
end

-- Warehouse overflow eligibility without moving anything.
function DIAG.printOverflowDiagnostics()
    local lines = {}
    local function add(s) lines[#lines + 1] = tostring(s or "") end

    loadState()
    if not refreshPeripherals() then
        add("ERROR: Required RS bridges / colony network are not ready.")
        DIAG.showDiagnosticViewer("OVERFLOW DIAGNOSTICS v" .. PROGRAM_VERSION, lines)
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
    add("Configured limit: Target + " .. tostring(CONFIG.overflowStacks) .. " stacks")

    if state.pending then
        add("Transfer path: BLOCKED - pending " ..
            tostring(state.pending.kind or "transfer") .. " of " ..
            tostring(state.pending.item or "unknown item"))
    else
        local empty = chestIsEmpty()
        if empty == false then
            add("Transfer path: BLOCKED - barrel contains " ..
                tostring(chestContentsSummary(2) or "items"))
        elseif empty == true then
            add("Transfer path: READY - barrel empty")
        else
            add("Transfer path: UNKNOWN - barrel inspection unavailable")
        end
    end
    add("")

    add(string.format("%-20s %7s %7s %7s %7s %12s",
        "ITEM", "CURRENT", "TARGET", "LIMIT", "FLOOR", "RESULT"))
    add(string.rep("-", 68))

    local eligibleCount = 0
    local heldCount = 0
    for _, row in ipairs(settingsRows) do
        local protect, overflowFloor, _, safeFloor, overLimit, returnable =
            overflowMetrics(row, activeDemand)
        local result
        if not enabled then
            result = "OFF"
        elseif not overLimit then
            result = "NO"
        elseif returnable > 0 then
            eligibleCount = eligibleCount + 1
            result = "YES " .. tostring(math.floor(returnable))
        elseif protect > 0 then
            heldCount = heldCount + 1
            result = "HELD " .. tostring(math.floor(protect))
        else
            result = "NO"
        end

        add(string.format("%-20s %7d %7d %7d %7d %12s",
            truncateText(row.displayName, 20),
            math.floor(row.current or 0),
            math.floor(row.target or 0),
            math.floor(overflowFloor or 0),
            math.floor(safeFloor or 0),
            result))
    end

    add("")
    add("Eligible items: " .. eligibleCount)
    if heldCount > 0 then add("Held for active demand: " .. heldCount) end
    if not enabled then
        add("Overflow Return is OFF. Enable it on Settings.")
    elseif eligibleCount == 0 and heldCount == 0 then
        add("Nothing exceeds the configured overflow limit.")
    elseif eligibleCount == 0 and heldCount > 0 then
        add("Over-limit stock exists, but active demand raises the safe floor.")
    else
        add("Normal mode returns up to " .. tostring(CONFIG.maxOverflowChunk) .. " items per scan.")
    end

    DIAG.showDiagnosticViewer("OVERFLOW DIAGNOSTICS v" .. PROGRAM_VERSION, lines)
end

-- Exercise the exact production Warehouse/Colony -> Player overflow path.
-- This is intentionally a real one-way transfer test: on success the requested
-- test quantity remains in Player RS and is recorded as a normal WH>P history row.
-- No target/overflow settings are changed.
function DIAG.printOverflowTransferTest(itemName, requestedCount)
    local lines = {}
    local function add(text)
        lines[#lines + 1] = tostring(text or "")
        DIAG.updateDiagnosticMonitor("WH>P PATH TEST v" .. PROGRAM_VERSION, lines)
    end
    local function finish()
        DIAG.showDiagnosticViewer("WH>P PATH TEST v" .. PROGRAM_VERSION, lines)
    end

    loadState()
    local ready = refreshPeripherals()

    add("Production overflow path test")
    add("This moves a REAL item Colony/Warehouse -> Player RS.")
    add("")
    add("Player bridge: " .. tostring(playerBridgeResolvedName or "NOT FOUND"))
    add("Colony bridge: " .. tostring(colonyBridgeResolvedName or "NOT FOUND"))
    add("Transfer barrel: " .. tostring(transferChestResolvedName or CONFIG.transferChestName or "NOT FOUND"))

    if not ready then
        add("")
        add("FAIL: Required peripherals/networks are not ready.")
        add("Run: colony_supply.lua diag")
        finish()
        return
    end

    if not itemName or itemName == "" then
        add("")
        add("Usage:")
        add("  colony_supply.lua overflowtest minecraft:cobblestone")
        add("  colony_supply.lua overflowtest minecraft:cobblestone 1")
        finish()
        return
    end

    local count = math.floor(tonumber(requestedCount) or 1)
    count = math.max(1, math.min(count, tonumber(CONFIG.maxOverflowChunk) or 64))

    if state.pending then
        add("")
        add("FAIL: A transfer is already pending.")
        add("Pending item: " .. tostring(state.pending.item or "?"))
        add("Run: colony_supply.lua pending")
        finish()
        return
    end

    local barrelEmpty = chestIsEmpty()
    if barrelEmpty == nil then
        add("")
        add("FAIL: Transfer barrel cannot be inspected.")
        add("The WH>P test requires modem-visible barrel verification.")
        add("Run: colony_supply.lua barrel")
        finish()
        return
    elseif barrelEmpty == false then
        add("")
        add("FAIL: Transfer barrel is not empty.")
        add("Contents: " .. tostring(chestContentsSummary(3) or "unknown"))
        add("Empty/recover the barrel before running this test.")
        finish()
        return
    end

    local colonyBefore = getRSAmount(colonyRS, itemName)
    local playerBefore = getRSAmount(playerRS, itemName)
    local barrelBefore = chestItemCount(itemName) or 0

    add("")
    add("Item: " .. tostring(itemName))
    add("Requested test count: " .. tostring(count))
    add("Colony before: " .. formatNumber(colonyBefore))
    add("Barrel before: " .. formatNumber(barrelBefore))
    add("Player before: " .. formatNumber(playerBefore))

    if colonyBefore < count then
        add("")
        add("FAIL: Colony RS does not contain enough of this item.")
        finish()
        return
    end

    add("")
    add("Running exact performOverflowReturn() production path...")
    local moved, err = performOverflowReturn(itemName, count)
    moved = math.max(0, math.floor(tonumber(moved) or 0))

    transferSleep(CONFIG.transferSettleDelay)
    NBTX.invalidateRSList(colonyRS)
    NBTX.invalidateRSList(playerRS)

    local colonyAfter = getRSAmount(colonyRS, itemName)
    local playerAfter = getRSAmount(playerRS, itemName)
    local barrelAfter = chestItemCount(itemName)

    add("Result moved: " .. tostring(moved))
    if err then add("Result error: " .. tostring(err)) end
    add("Health: " .. tostring(health.message or ""))
    add("")
    add("Colony after: " .. formatNumber(colonyAfter))
    add("Barrel after: " .. tostring(barrelAfter == nil and "UNREADABLE" or formatNumber(barrelAfter)))
    add("Player after: " .. formatNumber(playerAfter))
    add("Observed colony delta: " .. tostring(math.max(0, colonyBefore - colonyAfter)))
    add("Observed player delta: +" .. tostring(math.max(0, playerAfter - playerBefore)))

    if moved >= count and barrelAfter == 0 and playerAfter > playerBefore then
        add("")
        add("PASS: WH>P production transfer path is working.")
        add("A WH>P entry should now appear in transfer history.")
    else
        add("")
        add("FAIL: WH>P production transfer did not complete.")
        if barrelAfter and barrelAfter > 0 then
            add("Item reached the barrel but did not fully reach Player RS.")
        elseif colonyAfter >= colonyBefore then
            add("Item did not leave Colony/Warehouse RS.")
            add("Check Colony RS External Storage extraction access/filter.")
        else
            add("Item left Colony RS but was not confirmed in Player RS.")
        end
        add("Run: colony_supply.lua barrel")
        add("Run: colony_supply.lua history")
    end

    finish()
end

function DIAG.printHistoryDiagnostics()
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
    DIAG.printPeripheralDiagnostics()
    return
elseif args[1] == "requests" then
    DIAG.printRequestDiagnostics()
    return
elseif args[1] == "source" then
    DIAG.printSourceDiagnostic(args[2])
    return
elseif args[1] == "test" then
    DIAG.printTransferTest(args[2])
    return
elseif args[1] == "crafttest" then
    DIAG.printCraftTest(args[2], args[3])
    return
elseif args[1] == "craftdiag" then
    DIAG.printCraftDiagnostics()
    return
elseif args[1] == "blocked" then
    DIAG.printBlockedDiagnostics()
    return
elseif args[1] == "setbarrel" then
    DIAG.setTransferBarrelName(args[2])
    return
elseif args[1] == "clearbarrel" then
    DIAG.clearTransferBarrelName()
    return
elseif args[1] == "barrel" then
    DIAG.printBarrelDiagnostics()
    return
elseif args[1] == "pending" then
    DIAG.printPendingDiagnostics()
    return
elseif args[1] == "overflow" then
    DIAG.printOverflowDiagnostics()
    return
elseif args[1] == "overflowtest" or args[1] == "whtest" then
    DIAG.printOverflowTransferTest(args[2], args[3])
    return
elseif args[1] == "history" then
    DIAG.printHistoryDiagnostics()
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
