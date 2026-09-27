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
        health = {},
        lastScan = nil,
        lastScanText = "--:--:--",
        startupRunning = false,
        startupReady = false,
        stats = { active=0, ready=0, crafting=0, waiting=0, blocked=0, errors=0 },
        statusMessage = "Starting",
    }

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
        need(transfer.playerRS, "PRS", {"listItems","exportItem","importItem","craftItem"})
        need(transfer.colonyRS, "CRS", {"listItems","exportItem","importItem"})
        need(transfer.colony, "COLONY", {"getRequests","getColonyName"})
        local chest = transfer.getChest()
        need(chest, "CHEST", {"list","getItemDetail"})
        if #missing > 0 then
            return false, "missing API function(s): " .. table.concat(missing, ", ")
        end
        return true, "required peripheral functions available"
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
        setCheck(
            "chest_empty",
            empty,
            empty
                and "transfer chest empty"
                or tostring(emptyDetail or "transfer chest occupied")
        )

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

    local function startCraft(candidate, count)
        local key = craftFailureKey(candidate)
        local left, reason = craftCooldownRemaining(candidate)
        if left > 0 then return false, "craft error cooldown " .. tostring(left) .. "s: " .. tostring(reason), false end

        local last = tonumber(store.data.craftJobs[key]) or 0
        if nowSeconds() - last < (tonumber(config.craftCooldownSeconds) or 30) then
            return true, "craft cooldown", false
        end

        local craftable, source = matcher.craftable(transfer.playerRS, candidate, safeCall)
        if not craftable then return false, source, false end

        local filter = matcher.craftFilter(candidate, math.max(1, floor(count)))
        if candidate.hasNBT and filter.nbt == nil then return false, "exact NBT cannot be represented for crafting", false end

        local ok, started, err = safeCall(transfer.playerRS, "craftItem", filter)
        if not ok then
            local previous = store.data.craftFailures[key]
            local failures = type(previous) == "table" and floor(previous.failures) + 1 or 1
            local base = tonumber(config.craftErrorCooldownSeconds) or 300
            local cooldown = math.min(3600, base * (2 ^ math.max(0, failures - 1)))
            store.data.craftFailures[key] = {
                time = nowSeconds(), reason = tostring(err or started), failures = failures, cooldown = cooldown,
            }
            store.save()
            store.addError("CRAFT_EXCEPTION", "PRS craftItem failed for " .. candidate.name,
                { candidate = candidate, count = count, error = err or started, failures = failures }, "ERROR")
            return false, "craftItem error: " .. tostring(err or started), true
        end
        if started == true then
            store.data.craftJobs[key] = nowSeconds()
            store.data.craftFailures[key] = nil
            store.save()
            store.addHistory("CRAFT", { item=candidate.name, amount=count, detail="started via " .. tostring(source) })
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
                    startCraft(candidate, craftAmount)
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
                    startCraft(candidate, retryAmount)

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
            local ok, detail, usedTurn = startCraft(candidate, craftAmount)
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

        return {
            id=tostring(request.id),
            name=tostring(request.name or "Request"),
            requested=count,
            item=candidate.name,
            status="MISSING",
            detail=candidate.craftable and "AutoCraft disabled"
                or tostring(candidate.craftSource or "no exact stock or recipe"),
            usedPRSTurn=false,
        }
    end

    local function isBuildingItem(name)
        local p = registryPath(name)
        for _, pattern in ipairs(config.buildingItemPatterns or {}) do
            if p:match(pattern) then return true end
        end
        return false
    end

    local function keepLevel(item)
        local overrides = store.data.settings.overstockKeep or {}
        local explicit = tonumber(overrides[item.name])
        if explicit ~= nil then return math.max(0, floor(explicit)) end
        if isBuildingItem(item.name) then return floor(config.defaultBuildingKeepCount or 1024) end
        local stackSize = floor(item.maxCount or item.maxStackSize or store.data.settings.stackSizes[item.name] or config.defaultStackSize or 64)
        if stackSize <= 0 then stackSize = floor(config.defaultStackSize or 64) end
        return stackSize * floor(config.defaultItemKeepStacks or 2)
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
        self.stats = { active=0, ready=0, crafting=0, waiting=0, blocked=0, errors=0 }
        self.lastScan = nowSeconds()
        self.lastScanText = Util.timeString()

        if not transfer.refresh() then
            self.statusMessage = "Required peripheral offline"
            self.stats.errors = self.stats.errors + 1
            return false
        end

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

        -- Build the complete authoritative active set before processing anything.
        -- A turn-ending mutation must never cause later active request ledgers to
        -- be pruned simply because this scan did not reach them.
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

        for _, request in ipairs(activeRequests) do
            local row = processRequest(request)
            self.rows[#self.rows + 1] = row

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

        cleanLedger(active)

        if self.stats.active == 0 then
            processOneOverstock()
        end

        store.save()
        self.statusMessage = self.stats.errors > 0 and "DEGRADED" or "ONLINE"
        cluster.releaseTurn("scan complete")
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
        }
    end

    return self
end

return M
