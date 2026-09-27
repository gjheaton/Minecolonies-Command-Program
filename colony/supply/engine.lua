-- MineColonies Control Suite v3 - supply processing engine
local Util = require("colony.lib.util")
local M = {}

local function floor(n)
    return math.max(0, math.floor(tonumber(n) or 0))
end

local function nowSeconds()
    if os.epoch then
        local ok, value = pcall(os.epoch, "utc")
        if ok and value then return math.floor(value / 1000) end
    end
    return math.floor(os.clock())
end

local function requestCount(request)
    local n = floor(request and request.count)
    if n <= 0 then n = floor(request and request.minCount) end
    if n <= 0 and type(request and request.items) == "table" then
        for _, item in pairs(request.items) do
            if type(item) == "table" then n = math.max(n, floor(item.count)) end
        end
    end
    return n
end

local function requestActive(request)
    if type(request) ~= "table" or request.id == nil then return false end
    local state = tostring(request.state or ""):lower()
    for _, word in ipairs({"cancel","complete","completed","resolve","resolved","fulfill","fulfilled","done","closed"}) do
        if state:find(word,1,true) then return false end
    end
    return requestCount(request) > 0
end

local function requestSignature(request, count, canonicalNBT)
    local parts = {
        tostring(request.id or "?"),
        tostring(count or 0),
        tostring(request.name or ""),
    }
    if type(request.items) == "table" then
        local names = {}
        for _, item in pairs(request.items) do
            if type(item) == "table" and item.name then
                local nbt = type(canonicalNBT) == "function"
                    and canonicalNBT(item.nbt) or tostring(item.nbt or "")
                names[#names + 1] = tostring(item.name) .. "|" .. tostring(nbt)
            end
        end
        table.sort(names)
        for _, value in ipairs(names) do parts[#parts + 1] = value end
    end
    return table.concat(parts, "#")
end

local function registryPath(name)
    return tostring(name or ""):match("^[^:]+:(.+)$") or tostring(name or "")
end

function M.new(config, store, cluster, matcher, transfer)
    local self = {
        rows = {},
        requestRows = {},
        missingRequests = {},
        currentWork = nil,
        health = {},
        lastScan = nil,
        lastScanText = "--:--:--",
        startupRunning = false,
        startupReady = false,
        stats = { active=0, ready=0, crafting=0, waiting=0, blocked=0, errors=0 },
        statusMessage = "Starting",
    }

    -- REQUESTS is display/diagnostic data. Keep it deliberately low-pressure
    -- so adding the page does not turn into a burst of PRS/AP calls every
    -- processor tick.
    local requestStatusLastBuild = 0
    local requestStatusSignature = ""
    local craftableCache = {
        lastAttempt = 0,
        lastSuccess = 0,
        ok = false,
        names = {},
    }

    local recoverRequestedChestToCRS

    local function safeCall(obj, method, ...)
        return transfer.safeCall(obj, method, ...)
    end

    local function setCheck(id, ok, detail, severity)
        store.setStartupCheck(id, ok, detail, severity)
        return ok
    end

    local function requireMethod(obj, name)
        return obj and type(obj[name]) == "function"
    end

    local function functionChecks()
        local missing = {}
        local function need(obj, label, methods)
            for _, method in ipairs(methods) do
                if not requireMethod(obj, method) then missing[#missing + 1] = label .. "." .. method end
            end
        end
        need(
            transfer.playerRS,
            "PRS",
            {"listItems","exportItem","importItem","craftItem"}
        )
        need(
            transfer.colonyRS,
            "CRS",
            {"listItems","exportItem","importItem"}
        )

        if config.usePeripheralTransfer then
            need(
                transfer.playerRS,
                "PRS",
                {"exportItemToPeripheral","importItemFromPeripheral"}
            )
            need(
                transfer.colonyRS,
                "CRS",
                {"exportItemToPeripheral","importItemFromPeripheral"}
            )
        end
        need(transfer.colony, "COLONY", {"getRequests","getColonyName"})
        local chest = transfer.getChest()
        need(chest, "CHEST", {"list","getItemDetail"})
        if #missing > 0 then
            return false, "missing API function(s): " .. table.concat(missing, ", ")
        end
        return true, "required peripheral functions available"
    end

    local function activeRequestArray(requests)
        local out = {}
        for _, request in pairs(type(requests) == "table" and requests or {}) do
            if requestActive(request) then out[#out + 1] = request end
        end
        return out
    end

    local function chestSummary(snapshot)
        local totals = {}
        for _, entry in ipairs(
            type(snapshot) == "table" and snapshot.entries or {}
        ) do
            totals[entry.name] = (totals[entry.name] or 0) + floor(entry.count)
        end

        local parts = {}
        local total = 0
        for name, count in pairs(totals) do
            total = total + count
            parts[#parts + 1] = tostring(count) .. "x " .. tostring(name)
        end
        table.sort(parts)
        return table.concat(parts, ", "), total
    end

    local function chestContainsActiveRequest(snapshot, requests)
        local active = activeRequestArray(requests)

        for _, request in ipairs(active) do
            local count = requestCount(request)
            local signature = requestSignature(
                request, count, matcher.canonicalNBT)
            local ledger = store.data.requestLedger[tostring(request.id)] or {}
            local locallySent = ledger.signature == signature
                and floor(ledger.sentTotal or ledger.lastSent)
                or 0

            -- If this request has already been fully delivered according to the
            -- verified local ledger, do not treat extra chest contents as part
            -- of that same request.
            if locallySent < count then
                for _, entry in ipairs(snapshot.entries or {}) do
                    if type(entry.detail) == "table" then
                        local accepted, candidate, reason =
                            matcher.requestAcceptsItem(
                                request, entry.detail)
                        if accepted and candidate then
                            return request, candidate, entry,
                                tostring(entry.count) .. "x " ..
                                    tostring(entry.name) ..
                                    " matches active request " ..
                                    tostring(request.id) ..
                                    " (" .. tostring(reason or "accepted") .. ")"
                        end
                    end
                end
            end
        end

        return nil, nil, nil, nil
    end

    local function clearOrphanChestState()
        store.data.recovery = store.data.recovery or {}
        if store.data.recovery.orphanChest ~= nil then
            store.data.recovery.orphanChest = nil
            store.save()
        end
    end

    local function handleOrphanChest(requests)
        if type(store.data.pending) == "table" then
            clearOrphanChestState()

            -- A persisted/runtime pending transaction owns the transfer chest.
            -- Try to resume it in its original direction instead of treating
            -- the staged item as an orphan or waiting for a reboot.
            local okPending, pendingDetail =
                transfer.recoverPending()

            if okPending then
                return handleOrphanChest(requests)
            end

            return false,
                "pending transfer recovery: " ..
                    tostring(pendingDetail),
                "PENDING"
        end

        local snapshot, snapshotErr = transfer.chestSnapshot()
        if not snapshot then
            return false,
                "cannot inspect transfer chest: " .. tostring(snapshotErr),
                "ERROR"
        end

        if #(snapshot.entries or {}) == 0 then
            local alternate, alternateErr =
                transfer.findAlternateRequestedChest(
                    activeRequestArray(requests))

            if alternate then
                local okRebind, rebindDetail =
                    transfer.rebindTransferChest(
                        alternate.name,
                        "selected chest read empty while alternate chest " ..
                        "contained active-request item"
                    )
                if not okRebind then
                    return false,
                        "alternate transfer chest detected but rebind failed: " ..
                        tostring(rebindDetail),
                        "ERROR"
                end

                store.addHistory(
                    "RECOVERY",
                    {
                        direction = "CHEST_REBIND",
                        detail = tostring(rebindDetail),
                    }
                )

                -- Re-read through the newly persisted chest identity. If the
                -- staged item belongs to an active request, the normal recovery
                -- path below will import it into CRS.
                return handleOrphanChest(requests)
            end

            if alternateErr then
                return false,
                    "transfer chest identity ambiguous: " ..
                    tostring(alternateErr),
                    "ERROR"
            end

            clearOrphanChestState()
            return true, "transfer chest empty", "EMPTY"
        end

        local requestedRequest, requestedCandidate,
            requestedEntry, requestedDetail =
            chestContainsActiveRequest(snapshot, requests)

        if requestedRequest and requestedCandidate and requestedEntry then
            clearOrphanChestState()

            if type(recoverRequestedChestToCRS) ~= "function" then
                return false,
                    "requested transfer-chest item detected but recovery " ..
                    "handler is unavailable: " .. tostring(requestedDetail),
                    "ERROR"
            end

            local okRecover, recoverDetail =
                recoverRequestedChestToCRS(
                    requestedRequest,
                    requestedCandidate,
                    requestedEntry
                )

            if not okRecover then
                return false,
                    "requested transfer-chest recovery failed: " ..
                    tostring(recoverDetail),
                    "ERROR"
            end

            -- A chest can contain more than one stack/type. Re-evaluate after
            -- each verified requested-item recovery so requested contents flow
            -- to CRS while unrelated leftovers enter the normal quarantine.
            return handleOrphanChest(requests)
        end

        store.data.recovery = store.data.recovery or {}
        local quarantine = store.data.recovery.orphanChest
        local signature = tostring(snapshot.signature or "")
        local summary, total = chestSummary(snapshot)
        local now = nowSeconds()
        local waitSeconds =
            math.max(30, floor(config.orphanChestRecoverySeconds or 180))

        if type(quarantine) ~= "table"
            or tostring(quarantine.signature or "") ~= signature then
            quarantine = {
                signature = signature,
                firstSeen = now,
                lastSeen = now,
                summary = summary,
                amount = total,
            }
            store.data.recovery.orphanChest = quarantine
            store.save()
            store.addError(
                "ORPHAN_CHEST_QUARANTINE",
                "Unrequested item found in transfer chest; automatic PRS return timer started",
                {
                    detail = summary,
                    amount = total,
                    recoverySeconds = waitSeconds,
                },
                "WARNING"
            )
        else
            quarantine.lastSeen = now
            quarantine.summary = summary
            quarantine.amount = total
            store.save()
        end

        local elapsed = math.max(
            0, now - (tonumber(quarantine.firstSeen) or now))
        if elapsed < waitSeconds then
            return false,
                "unrequested transfer chest contents quarantined " ..
                tostring(elapsed) .. "/" .. tostring(waitSeconds) ..
                "s: " .. tostring(summary),
                "QUARANTINE"
        end

        local okReturn, result = transfer.returnEntireChestToPlayer()
        if not okReturn then
            quarantine.lastAttempt = now
            quarantine.lastError = tostring(result)
            store.save()
            return false,
                "orphan chest auto-return failed: " .. tostring(result),
                "ERROR"
        end

        clearOrphanChestState()
        result = type(result) == "table" and result or {}
        store.addHistory(
            "RECOVERY",
            {
                direction = "CHEST>PRS",
                amount = tonumber(result.moved) or total,
                detail = tostring(
                    result.detail
                    or ("returned orphan chest contents to PRS: " .. summary)
                ),
            }
        )
        return true,
            tostring(result.detail or "orphan chest returned to PRS"),
            "RECOVERED"
    end

    local function desyncHeuristic()
        local ok1, first = safeCall(transfer.playerRS, "listItems")
        sleep(0.15)
        local ok2, second = safeCall(transfer.playerRS, "listItems")
        if not ok1 or not ok2 or type(first) ~= "table" or type(second) ~= "table" then
            store.setDesync(true, "PRS listItems read failed during startup consistency check")
            return false, "PRS listItems consistency check failed"
        end

        local function summarize(list)
            local total, stacks = 0, 0
            for _, item in pairs(list) do
                if type(item) == "table" then
                    total = total + floor(item.amount)
                    stacks = stacks + 1
                end
            end
            return total, stacks
        end
        local aTotal, aStacks = summarize(first)
        local bTotal, bStacks = summarize(second)
        local delta = math.abs(aTotal - bTotal)
        -- A live RS can legitimately change between reads. This is a warning-only
        -- heuristic; the real startup movement probe is authoritative.
        if aStacks == 0 and bStacks == 0 then
            store.setDesync(false, "PRS consistency reads completed; network empty")
            return true, "PRS consistency reads completed (empty network)"
        end
        if delta > 4096 then
            local detail = "PRS inventory changed unusually between startup reads: " ..
                tostring(aTotal) .. " -> " .. tostring(bTotal)
            store.setDesync(true, detail)
            return true, "WARNING: " .. detail
        end
        store.setDesync(false, "no obvious PRS listItems inconsistency")
        return true, "no obvious PRS desync signature"
    end

    function self.runStartupChecks()
        if self.startupRunning then return false, "already running" end
        self.startupRunning = true

        local function blockedSignature()
            local parts = {}
            local checks = store.data.startup and store.data.startup.checks or {}
            for id, check in pairs(checks) do
                if type(check) == "table"
                    and check.ok ~= true
                    and check.severity ~= "WARNING"
                    and check.severity ~= "WAITING" then
                    parts[#parts + 1] =
                        tostring(id) .. "=" .. tostring(check.detail or "")
                end
            end
            table.sort(parts)
            return table.concat(parts, " | ")
        end

        local function recordBlockedOnce()
            local signature = blockedSignature()
            if signature == "" then signature = "startup blocked" end
            store.data.startup = store.data.startup or { checks = {} }

            if store.data.startup.lastBlockedSignature ~= signature then
                store.data.startup.lastBlockedSignature = signature
                store.save()
                store.addError(
                    "STARTUP_BLOCKED",
                    "Supply v3 startup health checks did not pass",
                    { checks = store.data.startup.checks },
                    "ERROR"
                )
            end
            cluster.broadcastFault("startup checks failed: " .. signature)
        end

        -- Cluster ownership is checked before touching PRS. A healthy computer
        -- which is simply waiting for another colony's turn is not failed and
        -- must not run PRS reads or movement tests out of turn.
        local clusterStatus = cluster.status()
        setCheck(
            "cluster",
            clusterStatus.ok,
            clusterStatus.ok
                and ("cluster online; master=" .. tostring(clusterStatus.masterId) ..
                    " active=" .. table.concat(clusterStatus.activeIds, ","))
                or tostring(clusterStatus.fault),
            clusterStatus.ok and "OK" or "ERROR"
        )

        if not clusterStatus.ok then
            self.startupReady = false
            store.markStartupComplete(false)
            setCheck(
                "movement",
                false,
                "not attempted because cluster is not healthy",
                "WAITING"
            )
            recordBlockedOnce()
            self.startupRunning = false
            return false, tostring(clusterStatus.fault or "cluster unhealthy")
        end

        local canPRS, turnStatus = cluster.canAccessPRS()
        if not canPRS then
            local turnId = turnStatus and turnStatus.turnId or clusterStatus.turnId
            setCheck(
                "movement",
                false,
                "waiting for PRS turn " .. tostring(turnId or "?") ..
                    "; this computer is " .. tostring(clusterStatus.id),
                "WAITING"
            )
            self.statusMessage =
                "Waiting for computer " .. tostring(turnId or "?") .. " PRS turn"
            self.startupRunning = false
            return nil, "WAITING"
        end

        -- We own the PRS turn. Revalidate the full startup suite.
        self.startupReady = false
        store.markStartupComplete(false)

        local okRefresh = transfer.refresh()
        setCheck(
            "peripherals",
            okRefresh,
            okRefresh
                and "PRS, CRS, colony integrator, warehouse and transfer chest online"
                or "one or more required peripherals are unavailable"
        )

        local okFunctions, functionDetail = functionChecks()
        setCheck("functions", okFunctions, functionDetail)

        local legacyPending =
            store.data.migration and store.data.migration.legacyPendingDetected
        if legacyPending then
            setCheck(
                "legacy_pending",
                false,
                "v2 pending transaction detected in legacy state; v3 will not assume its outcome",
                "WARNING"
            )
        else
            setCheck(
                "legacy_pending",
                true,
                "no legacy v2 pending transaction detected"
            )
        end

        local okPending, pendingDetail = transfer.recoverPending()
        setCheck("pending", okPending, pendingDetail)

        local empty, emptyDetail = transfer.chestEmpty()
        local chestState = empty and "EMPTY" or "OCCUPIED"

        if okPending and not empty then
            -- Before deciding an occupied chest is permanently blocking
            -- startup, compare its exact contents with the colony's current
            -- requests. Only genuinely unrequested contents are eligible for
            -- the timed automatic return to PRS.
            local okRequests, startupRequests =
                safeCall(transfer.colony, "getRequests")
            if okRequests and type(startupRequests) == "table" then
                local recovered, recoveryDetail, recoveryState =
                    handleOrphanChest(startupRequests)
                empty = recovered == true
                emptyDetail = recoveryDetail
                chestState = recoveryState or "OCCUPIED"
            else
                empty = false
                chestState = "ERROR"
                emptyDetail =
                    "transfer chest occupied; active requests could not be " ..
                    "verified, so automatic cleanup is suppressed"
            end
        elseif empty then
            clearOrphanChestState()
        end

        setCheck(
            "chest_empty",
            empty,
            empty
                and tostring(emptyDetail or "transfer chest empty")
                or tostring(emptyDetail or "transfer chest occupied"),
            chestState == "QUARANTINE" and "WAITING"
                or (empty and "OK" or "ERROR")
        )

        if chestState == "QUARANTINE" then
            setCheck(
                "movement",
                false,
                "waiting for orphan transfer chest quarantine to expire",
                "WAITING"
            )
            self.startupReady = false
            store.markStartupComplete(false)
            self.statusMessage = tostring(emptyDetail)
            self.startupRunning = false
            return nil, "WAITING"
        end

        local movementOK = false
        local movementDetail = "movement test prerequisites did not pass"
        if okRefresh and okFunctions and okPending and empty then
            movementOK, movementDetail = transfer.startupRoundTrip()
        end
        setCheck("movement", movementOK, movementDetail)

        -- Desync probing also reads PRS and therefore only runs while we own the turn.
        local desyncOK, desyncDetail = desyncHeuristic()
        setCheck(
            "desync",
            desyncOK,
            desyncDetail,
            store.data.desync and store.data.desync.suspected and "WARNING" or "OK"
        )

        local fatal = not (
            okRefresh
            and okFunctions
            and okPending
            and empty
            and movementOK
        )

        self.startupReady = not fatal
        store.markStartupComplete(self.startupReady)

        if fatal then
            recordBlockedOnce()
        else
            store.data.startup.lastBlockedSignature = nil
            store.save()
            store.addHistory(
                "STARTUP",
                { detail = "all required startup checks passed" }
            )
        end

        self.startupRunning = false
        return self.startupReady, movementDetail
    end

    local function craftFailureKey(candidate)
        return candidate.identity or candidate.name
    end

    local function craftCooldownRemaining(candidate)
        local e = store.data.craftFailures[craftFailureKey(candidate)]
        if type(e) ~= "table" then return 0, nil end
        local elapsed = nowSeconds() - (tonumber(e.time) or 0)
        local cooldown = tonumber(e.cooldown) or tonumber(config.craftErrorCooldownSeconds) or 300
        return math.max(0, math.ceil(cooldown - elapsed)), e.reason
    end

    local function clearCraftJob(candidate)
        local key = craftFailureKey(candidate)
        if store.data.craftJobs[key] ~= nil then
            store.data.craftJobs[key] = nil
            store.save()
        end
    end

    local function startCraft(candidate, count, requestId)
        local key = craftFailureKey(candidate)
        local left, reason = craftCooldownRemaining(candidate)
        if left > 0 then
            return false,
                "craft error cooldown " .. tostring(left) ..
                    "s: " .. tostring(reason),
                false
        end

        local pending = store.data.craftJobs[key]
        if type(pending) == "number" then
            pending = {
                startedAt = pending,
                count = math.max(1, floor(count)),
                requestId = requestId and tostring(requestId) or nil,
                legacy = true,
            }
            store.data.craftJobs[key] = pending
            store.save()
        end

        if type(pending) == "table" then
            local startedAt = tonumber(pending.startedAt or pending.time) or 0
            local age = math.max(0, nowSeconds() - startedAt)
            local waitSeconds =
                math.max(30, floor(config.craftOutputWaitSeconds or 180))
            local queryFilter = matcher.craftFilter(candidate, nil)

            local okCrafting, crafting = safeCall(
                transfer.playerRS, "isItemCrafting", queryFilter)

            if okCrafting and crafting == true then
                return true,
                    "craft in progress; duplicate craft suppressed",
                    false
            end

            if age < waitSeconds then
                return true,
                    "waiting for crafted output; duplicate craft suppressed (" ..
                        tostring(math.max(0, waitSeconds - age)) .. "s)",
                    false
            end

            if pending.stalledRecorded ~= true then
                pending.stalledRecorded = true
                pending.stalledAt = nowSeconds()
                store.save()
                store.addError(
                    "CRAFT_OUTPUT_STALLED",
                    "Craft was accepted but exact output did not become visible in PRS",
                    {
                        requestId = requestId or pending.requestId,
                        item = candidate.name,
                        identity = candidate.identity,
                        requestedCraft = pending.count,
                        startedAt = startedAt,
                        ageSeconds = age,
                        isItemCrafting = okCrafting and crafting or "unavailable",
                        detail = "Automatic duplicate craft suppressed",
                    },
                    "WARNING"
                )
            end

            return false,
                "craft output not visible after " .. tostring(age) ..
                    "s; duplicate craft suppressed",
                false
        end

        local craftable, source =
            matcher.craftable(transfer.playerRS, candidate, safeCall)
        if not craftable then return false, source, false end

        local craftCount = math.max(1, floor(count))
        local filter = matcher.craftFilter(candidate, craftCount)
        if candidate.hasNBT and filter.nbt == nil then
            return false,
                "exact NBT cannot be represented for crafting",
                false
        end

        local ok, started, err =
            safeCall(transfer.playerRS, "craftItem", filter)

        if not ok then
            local previous = store.data.craftFailures[key]
            local failures =
                type(previous) == "table"
                    and floor(previous.failures) + 1
                    or 1
            local base = tonumber(config.craftErrorCooldownSeconds) or 300
            local cooldown =
                math.min(3600, base * (2 ^ math.max(0, failures - 1)))

            store.data.craftFailures[key] = {
                time = nowSeconds(),
                reason = tostring(err or started),
                failures = failures,
                cooldown = cooldown,
            }
            store.save()
            store.addError(
                "CRAFT_EXCEPTION",
                "PRS craftItem failed for " .. candidate.name,
                {
                    candidate = candidate,
                    count = craftCount,
                    error = err or started,
                    failures = failures,
                },
                "ERROR"
            )
            return false,
                "craftItem error: " .. tostring(err or started),
                true
        end

        if started == true then
            store.data.craftJobs[key] = {
                startedAt = nowSeconds(),
                count = craftCount,
                requestId = requestId and tostring(requestId) or nil,
                stalledRecorded = false,
                leaseState = "blackout",
                nextPollAt =
                    nowSeconds() +
                    math.max(
                        5,
                        floor(config.craftInitialBlackoutSeconds or 30)
                    ),
                candidate = {
                    name = candidate.name,
                    displayName = candidate.displayName,
                    nbt = candidate.nbt,
                    nbtCanonical = candidate.nbtCanonical,
                    hasNBT = candidate.hasNBT == true,
                    identity = candidate.identity,
                    namespace = candidate.namespace,
                    toolClass = candidate.toolClass,
                    raw = {
                        name = candidate.raw
                            and candidate.raw.name or candidate.name,
                        nbt = candidate.raw
                            and candidate.raw.nbt or candidate.nbt,
                    },
                },
            }
            store.data.craftFailures[key] = nil
            store.save()
            store.addHistory(
                "CRAFT",
                {
                    item = candidate.name,
                    amount = craftCount,
                    requestId = requestId,
                    detail = "started via " .. tostring(source),
                }
            )
            return true, "craft started", true
        end

        return false, tostring(err or "RS refused craft"), true
    end

    local function ledgerFor(requestId)
        local key = tostring(requestId or "?")
        store.data.requestLedger[key] = store.data.requestLedger[key] or {}
        return store.data.requestLedger[key], key
    end

    local function cleanLedger(active)
        for id in pairs(store.data.requestLedger) do
            if not active[id] then store.data.requestLedger[id] = nil end
        end

        -- A craft gate belongs to the MineColonies request that caused it.
        -- Keep it fail-closed while that request is active, but remove stale
        -- gates after the request disappears so a future unrelated request is
        -- not blocked forever.
        for key, job in pairs(store.data.craftJobs or {}) do
            if type(job) == "table"
                and job.requestId ~= nil
                and not active[tostring(job.requestId)] then
                store.data.craftJobs[key] = nil
            end
        end
    end

    local function requestForCraftJob(activeRequests, requestId)
        requestId = tostring(requestId or "")
        for _, request in ipairs(activeRequests or {}) do
            if tostring(request.id or "") == requestId then
                return request
            end
        end
        return nil
    end

    local function candidateForCraftJob(key, job, activeRequests)
        if type(job) ~= "table" then return nil end

        local candidate = job.candidate
        if type(candidate) == "table"
            and type(candidate.name) == "string"
            and candidate.name ~= "" then
            candidate.raw = type(candidate.raw) == "table"
                and candidate.raw
                or { name = candidate.name, nbt = candidate.nbt }
            candidate.identity = candidate.identity
                or tostring(key)
            candidate.nbtCanonical = candidate.nbtCanonical
                or matcher.canonicalNBT(candidate.nbt)
            return candidate
        end

        -- Upgrade an older persisted craft job from the still-active request
        -- without touching PRS.
        local request =
            requestForCraftJob(activeRequests, job.requestId)
        if request then
            local candidates = matcher.requestCandidates(request)
            for _, value in ipairs(candidates or {}) do
                if tostring(value.identity or "") == tostring(key)
                    or tostring(value.name or "")
                        == tostring(job.item or "") then
                    job.candidate = {
                        name = value.name,
                        displayName = value.displayName,
                        nbt = value.nbt,
                        nbtCanonical = value.nbtCanonical,
                        hasNBT = value.hasNBT == true,
                        identity = value.identity,
                        namespace = value.namespace,
                        toolClass = value.toolClass,
                        raw = {
                            name = value.raw
                                and value.raw.name or value.name,
                            nbt = value.raw
                                and value.raw.nbt or value.nbt,
                        },
                    }
                    store.save()
                    return job.candidate
                end
            end
        end

        return nil
    end

    local function localCraftLeaseJob()
        local keys = {}
        for key, job in pairs(store.data.craftJobs or {}) do
            if type(job) == "table"
                and job.leaseState ~= "stalled"
                and type(job.candidate) == "table"
                and type(job.candidate.name) == "string"
                and job.candidate.name ~= "" then
                keys[#keys + 1] = tostring(key)
            end
        end
        table.sort(keys)

        for _, key in ipairs(keys) do
            local job = store.data.craftJobs[key]
            local candidate = job.candidate
            candidate.raw = type(candidate.raw) == "table"
                and candidate.raw
                or { name = candidate.name, nbt = candidate.nbt }
            candidate.identity = candidate.identity or tostring(key)
            candidate.nbtCanonical = candidate.nbtCanonical
                or matcher.canonicalNBT(candidate.nbt)
            return key, job, candidate
        end

        return nil, nil, nil
    end

    local function activeLeaseCraftJob(activeRequests)
        local activeIds = {}
        for _, request in ipairs(activeRequests or {}) do
            activeIds[tostring(request.id)] = true
        end

        local keys = {}
        for key, job in pairs(store.data.craftJobs or {}) do
            if type(job) == "table"
                and job.leaseState ~= "stalled"
                and job.requestId ~= nil
                and activeIds[tostring(job.requestId)] then
                keys[#keys + 1] = tostring(key)
            end
        end
        table.sort(keys)

        for _, key in ipairs(keys) do
            local job = store.data.craftJobs[key]
            local candidate =
                candidateForCraftJob(key, job, activeRequests)
            if candidate then return key, job, candidate end
        end
        return nil, nil, nil
    end

    local function manageCraftLease(activeRequests)
        local key, job, candidate =
            activeLeaseCraftJob(activeRequests)
        if not job or not candidate then
            return false, false, nil
        end

        if job.readyForTransfer == true
            or tostring(job.leaseState or "") == "ready" then
            return false, true,
                "Crafted output ready for transfer: " ..
                tostring(candidate.name)
        end

        -- Runtime fallback. Normal craft lifecycle polling is performed before
        -- transfer.refresh(), so reaching here means we must remain fail-closed
        -- without adding another PRS query.
        cluster.holdTurn(
            "AutoCraft waiting " .. tostring(candidate.name))
        return true, false,
            "AutoCraft waiting without PRS polling: " ..
            tostring(candidate.name)
    end

    local function manageCraftBlackout()
        local key, job, candidate = localCraftLeaseJob()
        if not job or not candidate then
            return false, false, nil
        end

        if job.readyForTransfer == true
            or tostring(job.leaseState or "") == "ready" then
            return false, true,
                "Crafted output ready for transfer: " ..
                tostring(candidate.name)
        end

        local now = nowSeconds()
        local startedAt =
            tonumber(job.startedAt or job.time) or now
        local age = math.max(0, now - startedAt)
        local blackout =
            math.max(
                5,
                floor(config.craftInitialBlackoutSeconds or 30)
            )
        local pollSeconds =
            math.max(
                5,
                floor(config.craftOutputPollSeconds or 15)
            )
        local waitSeconds =
            math.max(
                blackout,
                floor(config.craftOutputWaitSeconds or 180)
            )

        cluster.holdTurn(
            "AutoCraft PRS blackout " .. tostring(candidate.name))

        if age >= waitSeconds then
            job.leaseState = "stalled"
            if job.stalledRecorded ~= true then
                job.stalledRecorded = true
                job.stalledAt = now
                store.addError(
                    "CRAFT_OUTPUT_STALLED",
                    "Craft output was not observed before AutoCraft timeout",
                    {
                        requestId = job.requestId,
                        item = candidate.name,
                        identity = candidate.identity,
                        ageSeconds = age,
                        detail =
                            "No duplicate craft submitted; PRS polling remained throttled",
                    },
                    "WARNING"
                )
            end
            store.save()
            return false, false,
                "AutoCraft output timed out for " ..
                tostring(candidate.name)
        end

        local nextPollAt =
            tonumber(job.nextPollAt)
            or (startedAt + blackout)

        if now < nextPollAt then
            job.leaseState = "blackout"
            job.nextPollAt = nextPollAt
            store.save()
            return true, false,
                "AutoCraft PRS blackout: " ..
                tostring(candidate.name) .. " " ..
                tostring(math.max(0, math.ceil(nextPollAt - now))) ..
                "s"
        end

        -- One deliberately sparse PRS read. Do not call isItemCrafting().
        if not transfer.playerRS then
            -- This can occur only after a program restart. Allow normal
            -- peripheral resolution once rather than polling a nil bridge.
            return false, false,
                "AutoCraft bridge needs re-resolution"
        end

        local _, stock =
            matcher.findStoredVariants(
                transfer.playerRS,
                candidate,
                safeCall
            )

        job.nextPollAt = now + pollSeconds

        if stock <= 0 then
            job.leaseState = "awaiting_output"
            job.outputSeenAt = nil
            job.stableReads = 0
            store.save()
            return true, false,
                "AutoCraft output not visible; next PRS check in " ..
                tostring(pollSeconds) .. "s: " ..
                tostring(candidate.name)
        end

        if not job.outputSeenAt then
            job.outputSeenAt = now
            job.stableReads = 1
        else
            job.stableReads = floor(job.stableReads) + 1
        end
        job.leaseState = "stabilizing"

        local stableRequired =
            math.max(
                1,
                floor(config.craftStableReadsRequired or 2)
            )

        if floor(job.stableReads) < stableRequired then
            store.save()
            return true, false,
                "Crafted output seen; confirming on next low-rate PRS check: " ..
                tostring(candidate.name)
        end

        job.readyForTransfer = true
        job.leaseState = "ready"
        store.save()
        return false, true,
            "Crafted output stable and ready: " ..
            tostring(candidate.name)
    end

    local function resetLedger(ledger)
        for k in pairs(ledger) do ledger[k] = nil end
    end

    local function candidateSnapshot(candidate)
        return {
            name = candidate.name,
            displayName = candidate.displayName,
            nbt = candidate.nbt,
            nbtCanonical = candidate.nbtCanonical,
            hasNBT = candidate.hasNBT == true,
            identity = candidate.identity,
            namespace = candidate.namespace,
            raw = {
                name = candidate.raw and candidate.raw.name or candidate.name,
                nbt = candidate.raw and candidate.raw.nbt or candidate.nbt,
            },
        }
    end

    local function candidateFromLedger(ledger)
        local candidate = ledger and ledger.candidate
        if type(candidate) ~= "table" or not candidate.name then return nil end
        candidate.raw = type(candidate.raw) == "table"
            and candidate.raw or { name = candidate.name, nbt = candidate.nbt }
        candidate.identity = candidate.identity
            or (tostring(candidate.name) .. "|NBT|" .. matcher.canonicalNBT(candidate.nbt))
        candidate.nbtCanonical = candidate.nbtCanonical
            or matcher.canonicalNBT(candidate.nbt)
        return candidate
    end

    local function recordAckStalled(request, ledger, detail, context)
        ledger.phase = "ACK_STALLED"
        ledger.stalledAt = ledger.stalledAt or nowSeconds()
        ledger.stallDetail = tostring(detail or "MineColonies acknowledgement did not change")

        if ledger.stallRecorded ~= true then
            ledger.stallRecorded = true
            store.addError(
                "ACK_STALLED",
                "MineColonies request remained unchanged after bounded delivery reconciliation",
                {
                    requestId = request.id,
                    requestName = request.name,
                    signature = ledger.signature,
                    item = ledger.item,
                    identity = ledger.identity,
                    firstSentAt = ledger.firstSentAt,
                    ackStartedAt = ledger.ackStartedAt,
                    lastSentAt = ledger.lastSentAt,
                    sentTotal = ledger.sentTotal,
                    lastSent = ledger.lastSent,
                    retryCount = ledger.retryCount,
                    baselineCRS = ledger.baselineCRS,
                    peakCRS = ledger.peakCRS,
                    lastObservedCRS = ledger.lastObservedCRS,
                    detail = ledger.stallDetail,
                    extra = context,
                },
                "WARNING"
            )
        else
            store.save()
        end

        return {
            id = tostring(request.id),
            name = tostring(request.name or "Request"),
            requested = requestCount(request),
            item = tostring(ledger.item or "?"),
            status = "ACK STALLED",
            detail = ledger.stallDetail,
            usedPRSTurn = false,
        }
    end

    local function workCandidate(request, row, ledger)
        local fromLedger = candidateFromLedger(ledger)
        if fromLedger and tostring(fromLedger.name) == tostring(row.item) then
            return fromLedger
        end

        local candidates = matcher.requestCandidates(request)
        for _, candidate in ipairs(candidates or {}) do
            if tostring(candidate.name) == tostring(row.item) then
                return candidate
            end
        end
        return nil
    end

    local function captureWorkSnapshot(
        request, row, skipStorageReads)
        local requested = requestCount(request)
        local ledger = store.data.requestLedger[tostring(request.id)] or {}
        local signature = requestSignature(
            request, requested, matcher.canonicalNBT)

        local sent = 0
        if ledger.signature == signature then
            sent = floor(ledger.sentTotal or ledger.lastSent)
        end

        local candidate = workCandidate(request, row, ledger)
        local prsStock, crsStock
        local displayName = tostring(row.item or request.name or "Request")

        if candidate then
            displayName = tostring(candidate.displayName or candidate.name)
            if not skipStorageReads then
                local _, exactStock = matcher.findStoredVariants(
                    transfer.playerRS, candidate, safeCall)
                prsStock = floor(exactStock)
                local colonyAmount =
                    transfer.colonyAmount(candidate)
                if colonyAmount ~= nil then
                    crsStock = floor(colonyAmount)
                end
            end
        end

        return {
            id = tostring(request.id),
            requestName = tostring(request.name or "Request"),
            item = tostring(row.item or "-"),
            displayName = displayName,
            requested = requested,
            sent = sent,
            remaining = math.max(0, requested - sent),
            prsStock = prsStock,
            crsStock = crsStock,
            status = tostring(row.status or "UNKNOWN"),
            detail = tostring(row.detail or ""),
            usedPRSTurn = row.usedPRSTurn == true,
            capturedAt = Util.timeString(),
        }
    end

    local function noteVerifiedSend(ledger, signature, candidate, moved, baselineCRS, retry)
        local stamp = nowSeconds()
        if not ledger.firstSentAt then ledger.firstSentAt = stamp end
        ledger.signature = signature
        ledger.item = candidate.name
        ledger.identity = candidate.identity
        ledger.candidate = candidateSnapshot(candidate)
        ledger.lastSent = floor(moved)
        ledger.sentTotal = floor(ledger.sentTotal) + floor(moved)
        ledger.lastSentAt = stamp
        ledger.sentAt = stamp
        if ledger.baselineCRS == nil then ledger.baselineCRS = floor(baselineCRS) end

        local currentCRS = transfer.colonyAmount(candidate)
        if currentCRS ~= nil then
            ledger.lastObservedCRS = floor(currentCRS)
            ledger.peakCRS = math.max(floor(ledger.peakCRS), floor(currentCRS))
        end

        if retry then
            ledger.retryCount = floor(ledger.retryCount) + 1
            ledger.phase = "RETRY_WAIT"
            ledger.retryCraftRequestedAt = nil
        else
            ledger.retryCount = floor(ledger.retryCount)
            ledger.phase = "DELIVERING"
        end

        ledger.stallRecorded = nil
        ledger.stalledAt = nil
        ledger.stallDetail = nil
        store.save()
    end

    recoverRequestedChestToCRS = function(request, candidate, entry)
        local count = requestCount(request)
        local signature = requestSignature(
            request, count, matcher.canonicalNBT)
        local ledger = ledgerFor(request.id)

        if ledger.signature and ledger.signature ~= signature then
            resetLedger(ledger)
        end

        local alreadySent = ledger.signature == signature
            and floor(ledger.sentTotal or ledger.lastSent)
            or 0
        local remaining = math.max(0, count - alreadySent)
        if remaining <= 0 then
            return false, "request already fully delivered locally"
        end

        local amount = math.min(
            remaining,
            floor(entry and entry.count),
            floor(config.maxTransferChunk or 64)
        )
        if amount <= 0 then
            return false, "requested chest item has no transferable quantity"
        end

        local ok, result = transfer.adoptChestToColony(
            candidate,
            amount,
            {
                requestId = request.id,
                detail = "active MineColonies request recovered from " ..
                    "transfer chest",
            }
        )
        if not ok then return false, result end

        result = type(result) == "table" and result or {}
        local moved = floor(result.moved)
        if moved <= 0 then
            return false, "requested chest recovery reported zero moved"
        end

        noteVerifiedSend(
            ledger,
            signature,
            candidate,
            moved,
            floor(result.baselineCRS),
            false
        )
        clearCraftJob(candidate)

        if floor(ledger.sentTotal) >= count then
            ledger.ackStartedAt = nowSeconds()
            ledger.phase = "WAITING_ACK"
        else
            ledger.phase = "DELIVERING"
        end
        store.save()

        return true,
            tostring(
                result.detail
                or ("recovered " .. tostring(moved) .. "x " ..
                    tostring(candidate.name) .. " into CRS")
            )
    end

    local function continueOutstandingDelivery(request, signature, ledger)
        local candidate = candidateFromLedger(ledger)
        if not candidate then
            return recordAckStalled(
                request, ledger,
                "Cannot reconstruct exact item identity while completing a partial delivery")
        end

        local requested = requestCount(request)
        local sentTotal = floor(ledger.sentTotal or ledger.lastSent)
        local remaining = math.max(0, requested - sentTotal)

        if remaining <= 0 then
            if not ledger.ackStartedAt then
                ledger.ackStartedAt = tonumber(ledger.lastSentAt) or nowSeconds()
                ledger.phase = "WAITING_ACK"
                store.save()
            end
            return nil
        end

        local variants, exactStock = matcher.findStoredVariants(
            transfer.playerRS, candidate, safeCall)

        if exactStock > 0 and #variants > 0 then
            local amount = math.min(
                remaining,
                exactStock,
                floor(config.maxTransferChunk or 64)
            )
            local baselineCRS = transfer.colonyAmount(candidate)
            if baselineCRS == nil then
                return {
                    id=tostring(request.id),
                    name=tostring(request.name or "Request"),
                    requested=requested,
                    item=candidate.name,
                    status="ERROR",
                    detail="cannot read CRS baseline while continuing partial delivery",
                    usedPRSTurn=false,
                }
            end

            local ok, movedOrErr = transfer.playerToColony(candidate, amount, {
                requestId=request.id,
                detail="continuing verified request delivery; local sent=" ..
                    tostring(sentTotal) .. "/" .. tostring(requested)
            })

            if not ok then
                store.addError(
                    "PARTIAL_DELIVERY_TRANSFER",
                    "Failed while continuing a verified multi-chunk request delivery",
                    {
                        requestId=request.id,
                        item=candidate.name,
                        requested=requested,
                        alreadySent=sentTotal,
                        attempted=amount,
                        detail=movedOrErr,
                    },
                    "ERROR"
                )
                return {
                    id=tostring(request.id),
                    name=tostring(request.name or "Request"),
                    requested=requested,
                    item=candidate.name,
                    status="ERROR",
                    detail=tostring(movedOrErr),
                    usedPRSTurn=true,
                }
            end

            noteVerifiedSend(
                ledger, signature, candidate, movedOrErr, baselineCRS, false)
            -- Crafted output becoming visible is not enough to release the
            -- duplicate-craft gate. Release it only after a verified transfer
            -- into CRS succeeds.
            clearCraftJob(candidate)

            local newSent = floor(ledger.sentTotal)
            if newSent >= requested then
                ledger.ackStartedAt = nowSeconds()
                ledger.phase = "WAITING_ACK"
                store.save()
                return {
                    id=tostring(request.id),
                    name=tostring(request.name or "Request"),
                    requested=requested,
                    item=candidate.name,
                    status="WAITING ACK",
                    detail="full requested quantity physically delivered (" ..
                        tostring(newSent) .. "/" .. tostring(requested) ..
                        "); acknowledgement timer started",
                    usedPRSTurn=true,
                }
            end

            return {
                id=tostring(request.id),
                name=tostring(request.name or "Request"),
                requested=requested,
                item=candidate.name,
                status="SUPPLYING",
                detail="verified physical delivery " .. tostring(newSent) ..
                    "/" .. tostring(requested) ..
                    "; remaining=" .. tostring(math.max(0, requested - newSent)),
                usedPRSTurn=true,
            }
        end

        if store.data.settings.autoCraftEnabled == true then
            local craftable = matcher.craftable(
                transfer.playerRS, candidate, safeCall)
            if craftable then
                local craftAmount = math.min(
                    remaining, floor(config.maxTransferChunk or 64))
                local okCraft, craftDetail, usedTurn =
                    startCraft(candidate, craftAmount, request.id)
                return {
                    id=tostring(request.id),
                    name=tostring(request.name or "Request"),
                    requested=requested,
                    item=candidate.name,
                    status=okCraft and "CRAFTING" or "BLOCKED",
                    detail="partial delivery " .. tostring(sentTotal) .. "/" ..
                        tostring(requested) .. "; " .. tostring(craftDetail),
                    usedPRSTurn=usedTurn == true,
                }
            end
        end

        return {
            id=tostring(request.id),
            name=tostring(request.name or "Request"),
            requested=requested,
            item=candidate.name,
            status="MISSING",
            detail="partial delivery " .. tostring(sentTotal) .. "/" ..
                tostring(requested) ..
                "; exact remaining stock unavailable and no craft path available",
            usedPRSTurn=false,
        }
    end

    local function reconcileAcknowledgement(request, signature, ledger)
        local candidate = candidateFromLedger(ledger)
        if not candidate then
            return recordAckStalled(
                request, ledger,
                "Cannot reconstruct exact delivered item identity for reconciliation")
        end

        local stamp = nowSeconds()
        local firstSentAt = tonumber(ledger.firstSentAt or ledger.sentAt) or stamp
        local ackStartedAt = tonumber(ledger.ackStartedAt or ledger.lastSentAt or ledger.sentAt) or stamp
        local lastSentAt = tonumber(ledger.lastSentAt or ledger.sentAt) or ackStartedAt
        local retryCount = floor(ledger.retryCount)
        local maxRetries = math.max(0, floor(config.requestAckMaxRetries or 1))
        local waitSeconds = math.max(1, floor(config.requestAckWaitSeconds or 60))
        local retrySeconds = math.max(waitSeconds, floor(config.requestAckRetrySeconds or 180))
        local postRetrySeconds = math.max(1, floor(config.requestAckPostRetrySeconds or 60))
        local craftWaitSeconds = math.max(
            postRetrySeconds, floor(config.requestAckRetryCraftWaitSeconds or 180))

        local currentCRS, crsErr = transfer.colonyAmount(candidate)
        if currentCRS ~= nil then
            ledger.lastObservedCRS = floor(currentCRS)
            ledger.peakCRS = math.max(floor(ledger.peakCRS), floor(currentCRS))
        end

        if retryCount >= maxRetries and maxRetries > 0 then
            local retryAge = stamp - lastSentAt
            if retryAge < postRetrySeconds then
                store.save()
                return {
                    id=tostring(request.id),
                    name=tostring(request.name or "Request"),
                    requested=requestCount(request),
                    item=tostring(ledger.item or "?"),
                    status="WAITING ACK",
                    detail="retry " .. tostring(retryCount) .. "/" ..
                        tostring(maxRetries) .. " verified; awaiting acknowledgement " ..
                        tostring(retryAge) .. "/" .. tostring(postRetrySeconds) .. "s",
                    usedPRSTurn=false,
                }
            end
            return recordAckStalled(
                request, ledger,
                "Request unchanged after " .. tostring(retryCount) ..
                    " verified retry; automatic resends stopped")
        end

        local age = stamp - ackStartedAt
        if age < waitSeconds then
            store.save()
            return {
                id=tostring(request.id),
                name=tostring(request.name or "Request"),
                requested=requestCount(request),
                item=tostring(ledger.item or "?"),
                status="WAITING ACK",
                detail="verified sent " .. tostring(ledger.sentTotal or ledger.lastSent or 0) ..
                    "; waiting " .. tostring(age) .. "/" .. tostring(waitSeconds) .. "s",
                usedPRSTurn=false,
            }
        end

        if age < retrySeconds then
            ledger.phase = "VERIFYING"
            store.save()
            return {
                id=tostring(request.id),
                name=tostring(request.name or "Request"),
                requested=requestCount(request),
                item=tostring(ledger.item or "?"),
                status="VERIFYING DELIVERY",
                detail="request unchanged; CRS baseline=" ..
                    tostring(ledger.baselineCRS or "?") .. " current=" ..
                    tostring(ledger.lastObservedCRS or "?") ..
                    " retry check at " .. tostring(retrySeconds) .. "s",
                usedPRSTurn=false,
            }
        end

        if currentCRS == nil then
            return recordAckStalled(
                request, ledger,
                "Retry deadline reached but CRS stock could not be read safely",
                { crsError = crsErr })
        end

        local baseline = floor(ledger.baselineCRS)
        if floor(currentCRS) > baseline then
            return recordAckStalled(
                request, ledger,
                "Request unchanged, but delivered stock is still visible in CRS above baseline; duplicate retry suppressed",
                { baselineCRS = baseline, currentCRS = floor(currentCRS) })
        end

        if maxRetries <= 0 then
            return recordAckStalled(
                request, ledger,
                "Request unchanged at reconciliation deadline; retries disabled")
        end

        local variants, exactStock = matcher.findStoredVariants(
            transfer.playerRS, candidate, safeCall)

        if exactStock > 0 and #variants > 0 then
            local retryAmount = math.min(
                math.max(1, floor(ledger.lastSent or ledger.sentTotal or 1)),
                requestCount(request),
                exactStock,
                floor(config.maxTransferChunk or 64)
            )
            local retryBaseline = floor(currentCRS)
            local ok, movedOrErr = transfer.playerToColony(candidate, retryAmount, {
                requestId=request.id,
                detail="bounded ACK reconciliation retry " ..
                    tostring(retryCount + 1) .. "/" .. tostring(maxRetries)
            })

            if ok then
                noteVerifiedSend(
                    ledger, signature, candidate, movedOrErr, retryBaseline, true)
                return {
                    id=tostring(request.id),
                    name=tostring(request.name or "Request"),
                    requested=requestCount(request),
                    item=candidate.name,
                    status="WAITING ACK",
                    detail="bounded retry " .. tostring(ledger.retryCount) .. "/" ..
                        tostring(maxRetries) ..
                        " verified; awaiting acknowledgement",
                    usedPRSTurn=true,
                }
            end

            store.addError(
                "ACK_RETRY_TRANSFER",
                "Bounded acknowledgement retry transfer failed",
                {
                    requestId=request.id,
                    item=candidate.name,
                    count=retryAmount,
                    detail=movedOrErr,
                },
                "ERROR"
            )
            return {
                id=tostring(request.id),
                name=tostring(request.name or "Request"),
                requested=requestCount(request),
                item=candidate.name,
                status="ERROR",
                detail="ACK retry failed: " .. tostring(movedOrErr),
                usedPRSTurn=true,
            }
        end

        if store.data.settings.autoCraftEnabled == true then
            local craftable = matcher.craftable(
                transfer.playerRS, candidate, safeCall)

            if craftable then
                local retryAmount = math.min(
                    math.max(1, floor(ledger.lastSent or ledger.sentTotal or 1)),
                    requestCount(request),
                    floor(config.maxTransferChunk or 64)
                )

                if ledger.retryCraftRequestedAt then
                    local filter = matcher.craftFilter(candidate, nil)
                    local crafting = false
                    if not candidate.hasNBT or filter.nbt ~= nil then
                        local okCrafting, value = safeCall(
                            transfer.playerRS, "isItemCrafting", filter)
                        crafting = okCrafting and value == true
                    end

                    local craftAge = stamp -
                        (tonumber(ledger.retryCraftRequestedAt) or stamp)

                    if crafting or craftAge < craftWaitSeconds then
                        store.save()
                        return {
                            id=tostring(request.id),
                            name=tostring(request.name or "Request"),
                            requested=requestCount(request),
                            item=candidate.name,
                            status="CRAFTING RETRY",
                            detail=crafting
                                and "crafting exact replacement for bounded retry"
                                or ("waiting for retry craft output " ..
                                    tostring(craftAge) .. "/" ..
                                    tostring(craftWaitSeconds) .. "s"),
                            usedPRSTurn=false,
                        }
                    end

                    return recordAckStalled(
                        request, ledger,
                        "Bounded retry craft did not produce exact replacement stock",
                        { craftAge = craftAge })
                end

                local okCraft, craftDetail, usedTurn =
                    startCraft(candidate, retryAmount, request.id)

                if usedTurn then
                    ledger.retryCraftRequestedAt = stamp
                    ledger.phase = "RETRY_CRAFTING"
                    store.save()
                end

                return {
                    id=tostring(request.id),
                    name=tostring(request.name or "Request"),
                    requested=requestCount(request),
                    item=candidate.name,
                    status=okCraft and "CRAFTING RETRY" or "BLOCKED",
                    detail="ACK retry: " .. tostring(craftDetail),
                    usedPRSTurn=usedTurn == true,
                }
            end
        end

        return recordAckStalled(
            request, ledger,
            "Retry deadline reached, delivered stock is no longer visible, and no exact replacement is available or craftable")
    end

    local function processRequest(request)
        local count = requestCount(request)
        local signature = requestSignature(request, count, matcher.canonicalNBT)
        local ledger = ledgerFor(request.id)

        if ledger.signature and ledger.signature ~= signature then
            store.addHistory("ACK", {
                item = ledger.item,
                amount = ledger.sentTotal or ledger.lastSent,
                requestId = request.id,
                detail = "MineColonies request changed after delivery; acknowledgement accepted",
            })
            store.log(
                "REQUEST changed id=" .. tostring(request.id) ..
                "; clearing acknowledgement reconciliation state")
            resetLedger(ledger)
        end

        if ledger.signature == signature
            and floor(ledger.sentTotal or ledger.lastSent) > 0 then
            local sentTotal = floor(ledger.sentTotal or ledger.lastSent)
            if sentTotal < count then
                local row = continueOutstandingDelivery(
                    request, signature, ledger)
                if row then return row end
            end
            if not ledger.ackStartedAt then
                ledger.ackStartedAt = tonumber(ledger.lastSentAt) or nowSeconds()
                ledger.phase = "WAITING_ACK"
                store.save()
            end
            return reconcileAcknowledgement(request, signature, ledger)
        end

        local candidate, class, chooseErr = matcher.choose(
            request, transfer.playerRS, safeCall, count)

        if not candidate then
            return {
                id=tostring(request.id),
                name=tostring(request.name or "Request"),
                requested=count,
                item="-",
                status="BLOCKED",
                detail=tostring(chooseErr or
                    ("no acceptable " .. tostring(class or "item") .. " candidate")),
                usedPRSTurn=false,
            }
        end

        if candidate.stock > 0 then
            local amount = math.min(
                count, candidate.stock, floor(config.maxTransferChunk or 64))
            local baselineCRS = transfer.colonyAmount(candidate)

            if baselineCRS == nil then
                return {
                    id=tostring(request.id),
                    name=tostring(request.name or "Request"),
                    requested=count,
                    item=candidate.name,
                    status="ERROR",
                    detail="cannot read CRS baseline before transfer",
                    usedPRSTurn=false,
                }
            end

            local ok, movedOrErr = transfer.playerToColony(candidate, amount, {
                requestId=request.id,
                detail="MineColonies request " ..
                    tostring(request.name or request.id)
            })

            if ok then
                noteVerifiedSend(
                    ledger, signature, candidate, movedOrErr, baselineCRS, false)
                -- Keep the craft lock through visibility/desync windows. A
                -- successful, verified CRS transfer is the release point.
                clearCraftJob(candidate)

                if floor(ledger.sentTotal) >= count then
                    ledger.ackStartedAt = nowSeconds()
                    ledger.phase = "WAITING_ACK"
                    store.save()
                    return {
                        id=tostring(request.id),
                        name=tostring(request.name or "Request"),
                        requested=count,
                        item=candidate.name,
                        status="WAITING ACK",
                        detail="full requested quantity physically delivered (" ..
                            tostring(ledger.sentTotal) .. "/" .. tostring(count) ..
                            "); acknowledgement timer started",
                        usedPRSTurn=true,
                    }
                end

                return {
                    id=tostring(request.id),
                    name=tostring(request.name or "Request"),
                    requested=count,
                    item=candidate.name,
                    status="SUPPLYING",
                    detail="verified physical delivery " ..
                        tostring(ledger.sentTotal) .. "/" .. tostring(count) ..
                        "; remaining=" ..
                        tostring(math.max(0, count - floor(ledger.sentTotal))),
                    usedPRSTurn=true,
                }
            end

            store.addError(
                "SUPPLY_TRANSFER",
                "PRS->CRS request transfer failed",
                {
                    requestId=request.id,
                    item=candidate.name,
                    count=amount,
                    detail=movedOrErr,
                },
                "ERROR"
            )
            return {
                id=tostring(request.id),
                name=tostring(request.name or "Request"),
                requested=count,
                item=candidate.name,
                status="ERROR",
                detail=tostring(movedOrErr),
                usedPRSTurn=true,
            }
        end

        if candidate.craftable
            and store.data.settings.autoCraftEnabled == true then
            local craftAmount = math.min(
                count, floor(config.maxTransferChunk or 64))
            local ok, detail, usedTurn =
                startCraft(candidate, craftAmount, request.id)
            return {
                id=tostring(request.id),
                name=tostring(request.name or "Request"),
                requested=count,
                item=candidate.name,
                status=ok and "CRAFTING" or "BLOCKED",
                detail=tostring(detail),
                usedPRSTurn=usedTurn == true,
            }
        end

        if candidate.craftable then
            return {
                id=tostring(request.id),
                name=tostring(request.name or "Request"),
                requested=count,
                item=candidate.name,
                status="WAITING",
                detail="exact item is craftable; AutoCraft is disabled",
                usedPRSTurn=false,
            }
        end

        return {
            id=tostring(request.id),
            name=tostring(request.name or "Request"),
            requested=count,
            item=candidate.name,
            status="MISSING",
            detail=tostring(candidate.craftSource or
                "no exact stock or recipe"),
            usedPRSTurn=false,
        }
    end

    local function displayRequestStatus(status)
        status = tostring(status or "WAITING"):upper()
        if status == "SUPPLYING"
            or status == "CRAFTING"
            or status == "CRAFTING RETRY"
            or status == "DELIVERING"
            or status == "RETRY_CRAFTING"
            or status == "RETRY_WAIT" then
            return "IN PROGRESS"
        end
        if status == "VERIFYING DELIVERY" or status == "VERIFYING" then
            return "WAITING"
        end
        return status
    end

    local function requestStatusActiveSignature(activeRequests)
        local parts = {}
        for _, request in ipairs(activeRequests or {}) do
            parts[#parts + 1] =
                tostring(request.id or "?") .. ":" ..
                tostring(requestCount(request)) .. ":" ..
                tostring(request.name or "")
        end
        table.sort(parts)
        return table.concat(parts, "|")
    end

    local function refreshCraftableCache(now)
        local refreshSeconds =
            math.max(30, floor(config.requestCraftableRefreshSeconds or 60))

        if craftableCache.lastAttempt > 0
            and now - craftableCache.lastAttempt < refreshSeconds then
            return
        end

        craftableCache.lastAttempt = now
        local ok, list = safeCall(
            transfer.playerRS, "listCraftableItems")

        if ok and type(list) == "table" then
            local names = {}
            for _, item in pairs(list) do
                if type(item) == "table" and item.name then
                    names[tostring(item.name)] = true
                end
            end
            craftableCache.names = names
            craftableCache.ok = true
            craftableCache.lastSuccess = now
        elseif craftableCache.lastSuccess <= 0 then
            craftableCache.ok = false
            craftableCache.names = {}
        end
    end

    local function buildRequestStatusRows(activeRequests)
        local now = nowSeconds()
        local activeSignature =
            requestStatusActiveSignature(activeRequests)
        local refreshSeconds =
            math.max(10, floor(config.requestStatusRefreshSeconds or 15))

        if activeSignature == requestStatusSignature
            and requestStatusLastBuild > 0
            and now - requestStatusLastBuild < refreshSeconds then
            return self.requestRows
        end

        requestStatusLastBuild = now
        requestStatusSignature = activeSignature

        local rows = {}
        local okItems, inventory =
            safeCall(transfer.playerRS, "listItems")
        if not okItems or type(inventory) ~= "table" then
            inventory = {}
        end

        refreshCraftableCache(now)

        local function craftLookup(candidate)
            -- Exact-NBT craftability is intentionally left to the normal
            -- processing path. Probing isItemCraftable/getPattern for every
            -- NBT request just to paint the monitor can hammer RS.
            if candidate.hasNBT then
                return nil,
                    "exact-NBT craftability checked during processing",
                    false
            end

            if craftableCache.ok then
                local craftable =
                    craftableCache.names[tostring(candidate.name)] == true
                return craftable,
                    "cached listCraftableItems",
                    true
            end

            return nil, "craftable list unavailable", false
        end

        local pending = store.data.pending

        for _, request in ipairs(activeRequests or {}) do
            local count = requestCount(request)
            local signature = requestSignature(
                request, count, matcher.canonicalNBT)
            local ledger =
                store.data.requestLedger[tostring(request.id)] or {}
            local sent = ledger.signature == signature
                and floor(ledger.sentTotal or ledger.lastSent)
                or 0
            local remaining = math.max(0, count - sent)

            local candidate, class, chooseErr =
                matcher.chooseFromSnapshot(
                    request,
                    inventory,
                    craftLookup,
                    math.max(1, remaining)
                )

            local row = {
                id = tostring(request.id),
                name = tostring(request.name or "Request"),
                requested = count,
                sent = sent,
                remaining = remaining,
                item = candidate and tostring(candidate.name) or "-",
                displayName = candidate and tostring(
                    candidate.displayName or candidate.name)
                    or tostring(request.name or "Request"),
                prsStock =
                    candidate and floor(candidate.stock) or 0,
                craftable =
                    candidate and candidate.craftable == true or false,
                craftabilityKnown =
                    candidate
                    and candidate.craftabilityKnown == true
                    or false,
                status = "WAITING",
                detail = "",
                class = class,
            }

            if not okItems then
                row.status = "ERROR"
                row.detail = "PRS inventory list unavailable"
            elseif not candidate then
                row.status = "MISSING"
                row.detail = tostring(
                    chooseErr
                    or ("no acceptable " ..
                        tostring(class or "item") ..
                        " candidate"))
            elseif type(pending) == "table"
                and tostring(pending.requestId or "")
                    == tostring(request.id) then
                row.status = "IN PROGRESS"
                row.detail = "transfer chest stage " ..
                    tostring(pending.stage or "unknown")
            elseif ledger.signature == signature and sent > 0 then
                local phase = tostring(
                    ledger.phase or "DELIVERING")
                row.status = displayRequestStatus(phase)
                if row.status == "DELIVERING" then
                    row.status = "IN PROGRESS"
                end
                row.detail = tostring(
                    ledger.stallDetail
                    or ("verified sent " .. tostring(sent) ..
                        "/" .. tostring(count) ..
                        "; phase=" .. tostring(phase)))
            else
                local craftKey =
                    candidate.identity or candidate.name
                local craftJob =
                    store.data.craftJobs[craftKey]

                if type(craftJob) == "table"
                    or type(craftJob) == "number" then
                    row.status = "IN PROGRESS"
                    row.detail =
                        "craft job active; waiting for exact PRS output"
                elseif floor(candidate.stock) > 0 then
                    row.status = "WAITING"
                    row.detail = "exact PRS stock available (" ..
                        tostring(floor(candidate.stock)) .. ")"
                elseif candidate.craftable == true then
                    row.status = "WAITING"
                    row.detail =
                        store.data.settings.autoCraftEnabled == true
                        and "exact item craftable; waiting for processing turn"
                        or "exact item craftable; AutoCraft is disabled"
                elseif candidate.craftabilityKnown == false then
                    row.status = "WAITING"
                    row.detail = tostring(
                        candidate.craftSource
                        or "craftability check pending")
                else
                    row.status = "MISSING"
                    row.detail =
                        "no exact PRS inventory and no exact craft path"
                end
            end

            rows[#rows + 1] = row
        end

        return rows
    end

    local function updateRequestRowFromProcess(row)
        if type(row) ~= "table" or row.id == nil then return end
        local id = tostring(row.id)

        for _, requestRow in ipairs(self.requestRows or {}) do
            if tostring(requestRow.id) == id then
                local status = displayRequestStatus(row.status)

                -- A read-only status scan may already have proven this request
                -- genuinely missing. Do not replace that with a generic
                -- BLOCKED label from a later action path.
                if status == "BLOCKED"
                    and requestRow.status == "MISSING" then
                    status = "MISSING"
                end

                requestRow.status = status
                requestRow.item = tostring(row.item or requestRow.item or "-")
                requestRow.displayName =
                    tostring(row.item or requestRow.displayName or requestRow.name)
                requestRow.detail = tostring(row.detail or requestRow.detail or "")

                -- Sent/remaining are refreshed from the authoritative ledger.
                local ledger = store.data.requestLedger[id] or {}
                local sent = floor(ledger.sentTotal or ledger.lastSent)
                requestRow.sent = math.max(requestRow.sent or 0, sent)
                requestRow.remaining = math.max(
                    0,
                    floor(requestRow.requested) - floor(requestRow.sent)
                )
                return
            end
        end
    end

    local function refreshMissingRequests()
        self.missingRequests = {}
        for _, row in ipairs(self.requestRows or {}) do
            if tostring(row.status or "") == "MISSING" then
                self.missingRequests[#self.missingRequests + 1] = row
            end
        end
    end

    local function isBuildingItem(name)
        local p = registryPath(name)
        for _, pattern in ipairs(config.buildingItemPatterns or {}) do
            if p:match(pattern) then return true end
        end
        return false
    end

    local function defaultKeepLevel(item)
        item = type(item) == "table" and item or {}
        if isBuildingItem(item.name) then
            return floor(config.defaultBuildingKeepCount or 1024)
        end
        local stackSize = floor(
            item.maxCount
            or item.maxStackSize
            or store.data.settings.stackSizes[item.name]
            or config.defaultStackSize
            or 64
        )
        if stackSize <= 0 then stackSize = floor(config.defaultStackSize or 64) end
        return stackSize * floor(config.defaultItemKeepStacks or 2)
    end

    local function keepLevel(item)
        local overrides = store.data.settings.overstockKeep or {}
        local explicit = tonumber(overrides[item.name])
        if explicit ~= nil then return math.max(0, floor(explicit)) end
        return defaultKeepLevel(item)
    end

    function self.defaultOverstockKeep(item)
        return defaultKeepLevel(item)
    end

    function self.overstockKeep(item)
        return keepLevel(item)
    end

    function self.listOverstockItems()
        local byName = {}
        local ok, items = safeCall(transfer.colonyRS, "listItems")
        if ok and type(items) == "table" then
            for _, item in pairs(items) do
                if type(item) == "table"
                    and type(item.name) == "string"
                    and item.name ~= "" then
                    local entry = byName[item.name]
                    if not entry then
                        entry = {
                            name = item.name,
                            displayName = item.displayName or item.name,
                            amount = 0,
                            maxCount = item.maxCount or item.maxStackSize,
                        }
                        byName[item.name] = entry
                    end
                    entry.amount = entry.amount + floor(item.amount)
                    if not entry.maxCount then
                        entry.maxCount = item.maxCount or item.maxStackSize
                    end
                end
            end
        end

        for name in pairs(store.data.settings.overstockKeep or {}) do
            if not byName[name] then
                byName[name] = {
                    name = name,
                    displayName = name,
                    amount = 0,
                }
            end
        end

        local out = {}
        for _, item in pairs(byName) do
            item.defaultKeep = defaultKeepLevel(item)
            item.overrideKeep = tonumber(
                (store.data.settings.overstockKeep or {})[item.name]
            )
            item.keep = keepLevel(item)
            out[#out + 1] = item
        end

        table.sort(out, function(a, b)
            local ad = tostring(a.displayName or a.name):lower()
            local bd = tostring(b.displayName or b.name):lower()
            if ad == bd then return tostring(a.name) < tostring(b.name) end
            return ad < bd
        end)

        return out, ok and nil or "CRS item list unavailable"
    end

    function self.setOverstockOverride(name, count)
        name = tostring(name or "")
        if name == "" then return false end
        store.data.settings.overstockKeep = store.data.settings.overstockKeep or {}
        store.data.settings.overstockKeep[name] = math.max(0, floor(count))
        store.save()
        return true
    end

    function self.clearOverstockOverride(name)
        name = tostring(name or "")
        if name == "" then return false end
        store.data.settings.overstockKeep = store.data.settings.overstockKeep or {}
        store.data.settings.overstockKeep[name] = nil
        store.save()
        return true
    end

    local function processOneOverstock()
        if store.data.settings.overstockEnabled ~= true then return nil end
        local ok, items = safeCall(transfer.colonyRS, "listItems")
        if not ok or type(items) ~= "table" then return "CRS listItems unavailable" end

        for _, item in pairs(items) do
            if type(item) == "table" and item.name and floor(item.amount) > 0 then
                local keep = keepLevel(item)
                local amount = floor(item.amount)
                if amount > keep then
                    local candidate = {
                        name=item.name, displayName=item.displayName or item.name, nbt=item.nbt,
                        nbtCanonical=matcher.canonicalNBT(item.nbt),
                        hasNBT=(item.nbt ~= nil and tostring(item.nbt) ~= "" and tostring(item.nbt) ~= "{}"),
                        identity=tostring(item.name) .. "|NBT|" .. matcher.canonicalNBT(item.nbt),
                        namespace=tostring(item.name):match("^([^:]+):") or "",
                        raw={name=item.name, nbt=item.nbt},
                    }
                    local returnCount = math.min(amount - keep, floor(config.maxOverstockChunk or 64))
                    local okReturn, detail = transfer.colonyToPlayer(candidate, returnCount, {
                        detail="overstock return; keep=" .. tostring(keep)
                    })
                    if not okReturn then
                        store.addError("OVERSTOCK_TRANSFER", "CRS->PRS overstock return failed",
                            {item=item.name, amount=returnCount, keep=keep, detail=detail}, "WARNING")
                        return tostring(detail)
                    end
                    return "returned " .. tostring(detail) .. " " .. item.name
                end
            end
        end
        return nil
    end

    function self.scan()
        self.rows = {}
        self.stats = {
            active=0, ready=0, crafting=0,
            waiting=0, blocked=0, errors=0
        }
        self.lastScan = nowSeconds()
        self.lastScanText = Util.timeString()

        -- AutoCraft is intentionally hands-off with PRS after craftItem().
        -- This check runs before transfer.refresh() so even health/API reads
        -- cannot hammer the RS network during the blackout window.
        local localCraftKey, localCraftJob =
            localCraftLeaseJob()
        if localCraftJob then
            local clusterOK, clusterStatus =
                cluster.canAccessPRS()
            if not clusterStatus.ok then
                self.statusMessage =
                    "CLUSTER ERROR: " ..
                    tostring(clusterStatus.fault)
                return false
            end
            if not clusterOK then
                self.statusMessage =
                    "Waiting for computer " ..
                    tostring(clusterStatus.turnId) .. " turn"
                return true
            end

            local craftBlocked, _, craftDetail =
                manageCraftBlackout()
            if craftBlocked then
                self.statusMessage = tostring(craftDetail)
                self.stats.crafting = 1
                return true
            end
        end

        if not transfer.refresh() then
            self.statusMessage = "Required peripheral offline"
            self.stats.errors = self.stats.errors + 1
            return false
        end
        cluster.setLocalName(transfer.colonyName)

        local clusterOK, clusterStatus = cluster.canAccessPRS()
        if not clusterStatus.ok then
            self.statusMessage = "CLUSTER ERROR: " .. tostring(clusterStatus.fault)
            return false
        end
        if not clusterOK then
            self.statusMessage = "Waiting for computer " .. tostring(clusterStatus.turnId) .. " turn"
            return true
        end

        if not self.startupReady then
            self.runStartupChecks()
            if not self.startupReady then
                self.statusMessage = "STARTUP CHECKS BLOCKED"
                cluster.releaseTurn("startup blocked")
                return false
            end
        end

        local okReq, requests = safeCall(transfer.colony, "getRequests")
        if not okReq or type(requests) ~= "table" then
            store.addError("REQUEST_API", "MineColonies getRequests failed", {detail=requests}, "ERROR")
            self.statusMessage = "MineColonies request API error"
            cluster.releaseTurn("request API error")
            return false
        end

        local active = {}
        local activeRequests = {}

        -- Build the complete authoritative active set before processing
        -- anything. The Requests page must represent every active request even
        -- though an actual PRS mutation ends this colony's turn early.
        for _, request in pairs(requests) do
            if requestActive(request) then
                local id = tostring(request.id)
                active[id] = true
                activeRequests[#activeRequests + 1] = request
            end
        end

        table.sort(activeRequests, function(a, b)
            return tostring(a.id or "") < tostring(b.id or "")
        end)

        self.stats.active = #activeRequests

        -- A stray transfer-chest item can appear after startup as well. Active
        -- requested contents are recovered into CRS first; only truly unrelated
        -- leftovers enter the 180-second PRS-return quarantine.
        local chestReady, chestDetail = handleOrphanChest(requests)
        if not chestReady then
            self.requestRows = buildRequestStatusRows(activeRequests)
            refreshMissingRequests()
            self.statusMessage = "TRANSFER CHEST: " .. tostring(chestDetail)
            self.stats.blocked = self.stats.blocked + 1

            -- If this chest state belongs to an AutoCraft request, keep the
            -- shared PRS lease while the pending movement becomes visible or
            -- resumes. Do not hand PRS to another colony mid-craft/transfer.
            local _, leaseJob =
                activeLeaseCraftJob(activeRequests)
            if leaseJob then
                cluster.holdTurn("AutoCraft pending transfer")
            else
                cluster.releaseTurn("transfer chest blocked")
            end
            return false
        end

        local craftBlocked, craftReady, craftDetail =
            manageCraftLease(activeRequests)

        if craftBlocked then
            self.statusMessage = tostring(craftDetail)
            self.stats.crafting = self.stats.crafting + 1
            cluster.holdTurn("AutoCraft stabilization")
            return true
        end

        if craftReady then
            self.statusMessage = tostring(craftDetail)
        end

        self.requestRows = buildRequestStatusRows(activeRequests)
        refreshMissingRequests()

        local currentWorkRequest
        local currentWorkRow
        for _, request in ipairs(activeRequests) do
            local row = processRequest(request)
            self.rows[#self.rows + 1] = row
            updateRequestRowFromProcess(row)

            -- Choose which request to display now, but defer the PRS/CRS stock
            -- snapshot until processing is finished. This keeps the Home
            -- dashboard to one extra exact-stock read per owned colony turn.
            if not currentWorkRow or row.usedPRSTurn == true then
                currentWorkRequest = request
                currentWorkRow = row
            end

            if row.status == "WAITING ACK"
                or row.status == "VERIFYING DELIVERY" then
                self.stats.waiting = self.stats.waiting + 1
            elseif row.status == "CRAFTING"
                or row.status == "CRAFTING RETRY"
                or row.status == "SUPPLYING" then
                self.stats.crafting = self.stats.crafting + 1
            elseif row.status == "ERROR" then
                self.stats.errors = self.stats.errors + 1
            elseif row.status == "BLOCKED"
                or row.status == "MISSING"
                or row.status == "ACK STALLED" then
                self.stats.blocked = self.stats.blocked + 1
            else
                self.stats.ready = self.stats.ready + 1
            end

            -- WAITING ACK, VERIFYING DELIVERY, and ACK STALLED are local to
            -- that request. They do not block unrelated construction requests.
            -- End this colony's turn only after this scan actually touched PRS.
            if row.usedPRSTurn == true then break end
        end

        if currentWorkRequest and currentWorkRow then
            local skipStorageReads =
                currentWorkRow.status == "CRAFTING"
                or currentWorkRow.status == "CRAFTING RETRY"
                or currentWorkRow.status == "RETRY_CRAFTING"
            self.currentWork = captureWorkSnapshot(
                currentWorkRequest,
                currentWorkRow,
                skipStorageReads
            )
        elseif #activeRequests == 0 then
            self.currentWork = nil
        end

        refreshMissingRequests()
        cleanLedger(active)

        if self.stats.active == 0 then
            processOneOverstock()
        end

        store.save()
        self.statusMessage =
            self.stats.errors > 0 and "DEGRADED" or "ONLINE"

        local _, leaseJob =
            activeLeaseCraftJob(activeRequests)
        if leaseJob then
            cluster.holdTurn("AutoCraft lease active")
        else
            cluster.releaseTurn("scan complete")
        end
        return true
    end

    function self.healthSnapshot()
        local cs = cluster.status()
        local checks = store.data.startup and store.data.startup.checks or {}
        return {
            overall = self.startupReady and cs.ok and transfer.health.playerRS and transfer.health.colonyRS
                and transfer.health.colony and transfer.health.transferChest,
            colony = transfer.health.colony,
            playerRS = transfer.health.playerRS,
            colonyRS = transfer.health.colonyRS,
            warehouse = transfer.health.warehouse,
            transferChest = transfer.health.transferChest,
            transferChestItemCount =
                transfer.health.transferChestItemCount,
            transferChestStackCount =
                transfer.health.transferChestStackCount,
            cluster = cs,
            startupReady = self.startupReady,
            startupChecks = checks,
            pending = store.data.pending,
            desync = store.data.desync,
            errors = store.data.errors,
            overstockEnabled = store.data.settings.overstockEnabled == true,
            autoCraftEnabled = store.data.settings.autoCraftEnabled == true,
            statusMessage = self.statusMessage,
            lastScanText = self.lastScanText,
            requestRows = self.requestRows,
            missingRequests = self.missingRequests,
            currentWork = self.currentWork,
        }
    end

    return self
end

return M
