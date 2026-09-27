-- MineColonies Control Suite v3 - Supply Manager configuration
local C = {}

C.PROGRAM_VERSION = "3.0.7"
C.SUITE_VERSION = "3.0.8"

-- Peripheral overrides. Leave nil for auto-detection.
C.playerBridgeName = nil
C.colonyBridgeName = nil
C.colonyIntegratorName = nil
C.monitorName = nil
C.transferChestName = nil

-- Physical transfer layout. These directions are relative to the RS bridges.
C.playerToChestDirection = "west"
C.chestToColonyDirection = "east"
C.colonyToChestDirection = "east"
C.chestToPlayerDirection = "west"
C.usePeripheralTransfer = false

-- Runtime cadence.
C.scanIntervalSeconds = 5
C.turnIdleDelaySeconds = 0.25
C.maxTransferChunk = 64
C.transferSettleDelay = 0.25
C.transferImportRetries = 3
C.transferRetryDelay = 0.25

-- If the transfer chest contains no item matching an active MineColonies
-- request and there is no pending transaction, quarantine the unchanged chest
-- contents for this long before returning them to PRS automatically.
C.orphanChestRecoverySeconds = 180

C.destinationConfirmReads = 3
C.destinationConfirmDelay = 0.15
-- MineColonies acknowledgement reconciliation.
-- A verified transfer first waits normally, then enters a non-blocking
-- verification window. At the retry deadline, one bounded retry is allowed
-- only when the originally delivered stock is no longer visible above the
-- pre-transfer CRS baseline. After that retry, an unchanged request becomes
-- ACK STALLED and is recorded in the Errors tab; no unlimited resend loop.
C.requestAckWaitSeconds = 60
C.requestAckRetrySeconds = 180
C.requestAckMaxRetries = 1
C.requestAckPostRetrySeconds = 60
C.requestAckRetryCraftWaitSeconds = 180

-- Craft submission safety. Once a craft is accepted, do not submit the same
-- exact item again merely because it has not appeared in PRS yet. After this
-- window the request is blocked and logged rather than duplicate-crafted.
C.craftOutputWaitSeconds = 180
C.craftErrorCooldownSeconds = 300
C.updateCheckSeconds = 1800

-- Cluster / PRS arbitration.
-- Every Supply Manager learns peers it has seen and persists them. Once a peer
-- has joined the cluster, losing it is a hard cluster fault and ALL PRS access
-- stops until contact is restored. You can optionally predeclare IDs here.
C.clusterEnabled = true
C.clusterProtocol = "minecolonies_supply_v3_cluster"
C.clusterMinimumSize = 2
C.clusterExpectedComputerIds = {}
C.clusterHelloSeconds = 1
C.clusterPeerTimeoutSeconds = 8
C.clusterMasterTimeoutSeconds = 5
C.clusterMembershipSettleSeconds = 3
C.clusterTurnTimeoutSeconds = 45
C.clusterStateBroadcastSeconds = 0.75

-- Request matching.
-- Equipment/tool/weapon/armor alternatives are restricted to these namespaces.
C.equipmentAllowedNamespaces = {
    minecraft = true,
    minecolonies = true,
}

-- Overstock defaults. The feature can be enabled/disabled from persisted settings.
-- When enabled, CRS stock above these keep levels is returned to PRS.
C.overstockEnabledDefault = false
C.defaultItemKeepStacks = 2
C.defaultBuildingKeepCount = 1024
C.defaultStackSize = 64
C.maxOverstockChunk = 64
C.buildingItemPatterns = {
    "^cobblestone$", "_cobblestone$",
    "^stone$", "_stone$", "^sandstone$", "_sandstone$",
    "^bricks$", "_bricks$", "_brick$",
    "_planks$", "_log$", "_wood$", "_stem$", "_hyphae$",
    "^dirt$", "_dirt$", "^mud$", "_mud$",
    "^sand$", "_sand$", "^gravel$", "_gravel$",
    "^glass$", "_glass$", "_glass_pane$",
    "^terracotta$", "_terracotta$", "_concrete$", "_concrete_powder$",
    "^deepslate$", "_deepslate$", "^tuff$", "_tuff$",
    "^blackstone$", "_blackstone$", "^netherrack$", "^end_stone$",
    "_slab$", "_stairs$", "_wall$",
}

-- Startup round-trip health probe. One plain, non-NBT item is moved PRS->CRS
-- and then CRS->PRS while this computer owns its cluster turn. If the preferred
-- item is unavailable, the program chooses another safe plain item.
C.startupProbePreferredItem = "minecraft:cobblestone"
C.startupProbeNamespaces = { minecraft = true, minecolonies = true }
C.startupProbeCount = 1

-- Persistence / UI.
C.stateFile = "/colony/supply_v3_state.txt"
C.legacyStateFile = "/colony_supply_state.txt"
C.logFile = "/colony/supply_v3.log"
C.maxLogBytes = 65536
C.maxHistoryEntries = 400
C.maxErrorEntries = 100
C.monitorTextScale = 0.5

return C
