-- Dedicated PRS owner. No colony receives permission to touch this bridge.
-- A turn is a durable chest handoff, not a timed lease: an overdue client may
-- finish its drain, but the master will not export until that exact batch arrives.
local Config = require("colony.network.config")
local M = {}

local function integer(value)
    return math.max(0, math.floor(tonumber(value) or 0))
end

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then error("cyclic network data") end
    seen[value] = true
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item, seen) end
    seen[value] = nil
    return result
end

local function requestCount(request)
    local count = integer(request.count or request.minCount)
    if count == 0 then
        for _, item in pairs(request.items or {}) do
            if type(item) == "table" then count = math.max(count, integer(item.count)) end
        end
    end
    return count
end

local function signature(request, matcher)
    local identities = {}
    for _, item in pairs(request.items or {}) do
        if type(item) == "table" then identities[#identities + 1] = matcher.itemIdentity(item) end
    end
    table.sort(identities)
    return table.concat(identities, "\n")
end

local function activeCraft(job)
    return job and (job.state == "crafting" or job.state == "timed out" or job.state == "uncertain")
end

local function channel(value)
    return tostring(value or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
end

local function routeSignature(colony)
    return table.concat({tostring(colony.deliveryChest), tostring(colony.returnChest),
        channel(colony.deliveryChannel), channel(colony.returnChannel),
        tostring(colony.outputDirection), tostring(colony.returnDirection)}, "\n")
end

local function craftIdentity(candidate)
    return candidate.hasNBT and candidate.identity or candidate.name .. "|NBT|"
end

function M.new(config, store, io, matcher)
    local self = {}
    local d = store.data
    d.master = type(d.master) == "table" and d.master or {}
    local state = d.master
    state.colonies = state.colonies or {}
    state.craftJobs = state.craftJobs or {}
    state.sessionCounter = integer(state.sessionCounter) + 1
    state.turnCounter = integer(state.turnCounter)
    state.shipmentCounter = integer(state.shipmentCounter)
    state.colonyCursor = integer(state.colonyCursor)
    local session = "master-" .. tostring(state.sessionCounter)
    local work = nil
    local nextTurnAt = io.now()
    local defaultPolicy = {
        pollIntervalSeconds=1, colonyResponseTimeoutSeconds=30,
        batchRetrySeconds=5, messageTimeoutSeconds=30,
        onHandTimeoutSeconds=120, craftingTimeoutSeconds=600,
        acknowledgementTimeoutSeconds=600, transferVerifyTimeoutSeconds=5,
        transferSettleSeconds=0.25, transferPollSeconds=0.25,
        craftCooldownSeconds=30, craftPollSeconds=15, craftStableReadsRequired=2,
        retryCooldownSeconds=30, desyncProbeSeconds=30,
        maxRequestsPerTurn=8, maxItemsPerTurn=256, maxTransferChunk=64,
        maxCraftBatch=64, maxConcurrentCrafts=4, maxCraftsPerTurn=1,
        maxReturnItemsPerTurn=128, chestReserveSlots=1,
        autoCraftEnabled=true,
    }

    local function save()
        local ok, err = store.save()
        if ok ~= true then error("Master state could not be saved: " .. tostring(err)) end
    end

    local function policy(colony)
        local result = Config.policy(config, colony)
        for key, fallback in pairs(defaultPolicy) do
            local value = colony and colony.overrides and colony.overrides[key]
            if value == nil then value = config[key] end
            if value == nil then value = fallback end
            result[key] = value
        end
        return result
    end

    local function definition(id)
        for _, colony in ipairs(config.colonies or {}) do
            if tostring(colony.id) == tostring(id) then return colony end
        end
    end

    local function colonyState(colony)
        local key = tostring(colony.id)
        local cs = state.colonies[key]
        if not cs then
            cs = {id=colony.id, requests={}, shipments={}, requestCursor=0}
            state.colonies[key] = cs
        end
        cs.requests = cs.requests or {}
        cs.shipments = cs.shipments or {}
        return cs
    end

    local function errorEvent(code, message, context)
        store.error(code, message, context)
    end

    local function quarantine(code, message, context)
        if not state.quarantine then
            state.quarantine = {code=code, message=message, context=copy(context or {}), at=io.now()}
            save()
            errorEvent(code, message, context)
        end
    end

    local function clearQuarantine()
        state.quarantine = nil
        for _, cs in pairs(state.colonies) do
            for _, record in pairs(cs.requests or {}) do
                if record.errorCode == "PRS_QUARANTINE" then
                    record.status, record.detail, record.errorCode = "requested", "PRS recovery verified; resuming outstanding quantity", nil
                end
            end
        end
        save()
    end

    local function shipmentsFor(cs)
        local result = {}
        for _, shipment in ipairs(cs.shipments) do
            if shipment.verified then
                local entry = copy(shipment)
                entry.remaining = math.max(0, integer(entry.count) - integer(entry.imported))
                result[#result + 1] = entry
            end
        end
        return result
    end

    local function totals(cs, record)
        local shipped, imported = 0, 0
        for _, shipment in ipairs(cs.shipments) do
            if shipment.requestId == record.id and shipment.generation == record.generation and shipment.verified then
                shipped = shipped + integer(shipment.count)
                imported = imported + integer(shipment.imported)
            end
        end
        return shipped, imported
    end

    local function publicRecord(record)
        local result = {}
        for _, key in ipairs({"id","requestId","generation","name","displayName","status",
            "requested","shipped","imported","detail","createdAt","lastSeenAt",
            "firstShipmentAt","completedAt","craftIdentity"}) do
            if record[key] ~= nil then result[key] = copy(record[key]) end
        end
        return result
    end

    local function pruneCompleted(cs)
        local retained, ownsShipment = {}, {}
        for _, shipment in ipairs(cs.shipments) do
            local record = cs.requests[shipment.requestId]
            local completed = record and (record.status == "delivered" or record.generation ~= shipment.generation)
            if not (completed and integer(shipment.imported) == integer(shipment.count)) then
                retained[#retained + 1] = shipment
                ownsShipment[shipment.requestId] = true
            end
        end
        cs.shipments = retained
        local completed = {}
        for id, record in pairs(cs.requests) do
            if record.status == "delivered" and not ownsShipment[id] then
                completed[#completed + 1] = record
            end
        end
        table.sort(completed, function(a,b) return (a.completedAt or 0) < (b.completedAt or 0) end)
        local retention = tonumber(config.requestRetentionSeconds) or 86400
        local maximum = integer(config.maxCompletedRequests or 1000)
        for index, record in ipairs(completed) do
            if io.now() - (record.completedAt or io.now()) >= retention or index <= #completed - maximum then
                cs.requests[record.id] = nil
            end
        end
    end

    local function statusRecord(cs, record, p)
        local shipped, imported = totals(cs, record)
        record.shipped, record.imported = shipped, imported
        if record.status == "delivered" or record.status == "error" then return end
        local job = record.craftIdentity and state.craftJobs[record.craftIdentity]
        if activeCraft(job) and shipped < integer(record.requested) then
            record.status = job.state == "uncertain" and "error" or "crafting"
            if job.state == "uncertain" then record.errorCode = "CRAFT_UNCERTAIN" end
            record.detail = job.state == "uncertain" and "Craft submission outcome is uncertain; no retry" or "Waiting for existing PRS craft"
            if io.now() - (job.createdAt or io.now()) >= p.craftingTimeoutSeconds then
                record.status, record.detail = "timed out", "Craft deadline expired; existing job remains reserved"
            end
        elseif shipped > 0 then
            record.status, record.detail = "in progress", "Waiting for MineColonies to remove the request"
            if io.now() - (record.firstShipmentAt or io.now()) >= p.acknowledgementTimeoutSeconds then
                record.status, record.detail = "timed out", "MineColonies acknowledgement overdue; verified quantities are not resent"
            end
        elseif record.status ~= "missing" and io.now() - record.createdAt >= p.onHandTimeoutSeconds then
            record.status, record.detail = "timed out", "On-hand delivery deadline expired"
        end
    end

    local function sendTurn(colony, cs)
        local turn = cs.turn
        if not turn then return end
        turn.lastSentAt = io.now()
        save()
        if turn.phase == "WAIT_BATCH" then
            io.send(colony.id, {kind="turn", session=turn.session, turn=turn.id,
                policy=copy(turn.policy), deliveries=shipmentsFor(cs)})
        elseif turn.phase == "RESULT" then
            io.send(colony.id, copy(turn.result))
        end
    end

    local function finishTurn(colony, cs)
        local turn = cs.turn
        local rows = {}
        for _, record in pairs(cs.requests) do
            if record.status ~= "delivered" or record.completedTurn == turn.id then
                if (cs.error or cs.routeError) and record.status ~= "delivered"
                    and record.errorCode ~= "CRAFT_UNCERTAIN" and record.errorCode ~= "PRS_QUARANTINE"
                    and record.errorCode ~= "REQUEST_CHANGED" then
                    record.status, record.detail, record.errorCode = "error", cs.error or cs.routeError, "CLIENT"
                end
                statusRecord(cs, record, turn.policy)
                rows[#rows + 1] = publicRecord(record)
            end
        end
        table.sort(rows, function(a,b) return tostring(a.id) < tostring(b.id) end)
        turn.result = {kind="result", session=turn.session, turn=turn.id,
            requests=rows, deliveries=shipmentsFor(cs),
            masterError=cs.error or cs.routeError or (state.quarantine and state.quarantine.message) or nil}
        turn.phase, turn.finishedAt = "RESULT", io.now()
        save()
        sendTurn(colony, cs)
        work = nil
        nextTurnAt = io.now() + turn.policy.pollIntervalSeconds
    end

    local function checkRoutes(colony, cs)
        if type(colony.deliveryChest) ~= "string" or colony.deliveryChest == ""
            or type(colony.returnChest) ~= "string" or colony.returnChest == "" then
            cs.routeError = "Delivery and return chest peripheral names must both be configured"
            return false
        end
        if colony.deliveryChest == colony.returnChest then
            cs.routeError = "Delivery and return routes must use separate Ender Chest channels"
            return false
        end
        if not cs.routeConfirmed then
            cs.routeError = cs.routeError or "Waiting for matching delivery and return color labels from colony"
            return false
        end
        if cs.turn and cs.turn.routeSignature and cs.turn.routeSignature ~= routeSignature(colony) then
            cs.routeError = "Routes changed during an outstanding chest handoff; restore original routes first"
            return false
        end
        cs.routeError = nil
        return true
    end

    local function stock()
        local items, err = io.stock()
        if type(items) ~= "table" then
            quarantine("PRS_READ", "Cannot read PRS inventory: " .. tostring(err), {})
            return nil
        end
        return items
    end

    local function stockCount(items, item)
        local count = 0
        for _, entry in pairs(items) do
            if matcher.exactlyMatches(item, entry) then count = count + integer(entry.amount or entry.count) end
        end
        return count
    end

    local function observeCrafts(items, p)
        for _, job in pairs(state.craftJobs) do
            if activeCraft(job) and io.now() >= (job.nextPollAt or 0) then
                job.nextPollAt = io.now() + (job.pollSeconds or p.craftPollSeconds)
                local produced = stockCount(items, job.item) + integer(job.exported) - integer(job.baseline)
                job.proven = math.max(integer(job.proven), produced)
                if produced >= integer(job.count) then
                    job.outputReads = integer(job.outputReads) + 1
                    -- A phantom PRS list must not immediately free an accepted
                    -- recipe reservation. Require physical extraction or two
                    -- separate, bounded output observations.
                    if integer(job.exported) >= integer(job.count)
                        or job.outputReads >= (job.stableReadsRequired or p.craftStableReadsRequired or 2) then
                        job.state, job.completedAt = "complete", io.now()
                    end
                else
                    job.outputReads = 0
                end
                if job.state == "complete" then
                    for _, cs in pairs(state.colonies) do
                        for _, record in pairs(cs.requests or {}) do
                            if record.craftIdentity == job.identity and record.errorCode == "CRAFT_UNCERTAIN" then
                                record.status, record.detail, record.errorCode = "requested", "Previously uncertain craft output verified", nil
                            end
                        end
                    end
                    store.event("CRAFT_OUTPUT", "Craft output observed", {item=job.item.name, count=job.count})
                elseif io.now() - job.createdAt >= (job.timeoutSeconds or p.craftingTimeoutSeconds) and job.state == "crafting" then
                    job.state = "timed out"
                    errorEvent("CRAFT_TIMEOUT", "Craft overdue; reserved identity will not be crafted again", {item=job.item.name, count=job.count})
                end
            end
        end
        save()
    end

    local function matchingPendingChest(pending)
        local items, err = io.snapshot(pending.chest)
        if type(items) ~= "table" then return nil, tostring(err) end
        local count = integer(io.count(items, pending.item))
        local delta = pending.kind == "export" and count - pending.before or pending.before - count
        return delta, nil
    end

    local function creditTransfer(pending, count)
        local cs = state.colonies[tostring(pending.colonyId)]
        if pending.kind == "export" then
            state.shipmentCounter = state.shipmentCounter + 1
            local shipment = {id="shipment-" .. tostring(state.shipmentCounter),
                requestId=pending.requestId, generation=pending.generation,
                item=copy(pending.item), count=count, imported=0, verified=true,
                createdAt=io.now(), turn=pending.turn, session=pending.session}
            cs.shipments[#cs.shipments + 1] = shipment
            local record = cs.requests[pending.requestId]
            if record then
                record.firstShipmentAt = record.firstShipmentAt or io.now()
                record.status, record.detail = "in progress", "Verified in delivery chest; awaiting colony import"
            end
            for _, job in pairs(state.craftJobs) do
                if activeCraft(job) and matcher.exactlyMatches(job.item, pending.item) then
                    job.exported = integer(job.exported) + count
                end
            end
            if cs.turn and cs.turn.id == pending.turn and cs.turn.session == pending.session then
                cs.turn.itemsShipped = integer(cs.turn.itemsShipped) + count
            end
            if work and tostring(work.colony.id) == tostring(pending.colonyId) then work.items = work.items + count end
        else
            if cs.turn and cs.turn.id == pending.turn and cs.turn.session == pending.session then
                cs.turn.itemsReturned = integer(cs.turn.itemsReturned) + count
            end
            if work and tostring(work.colony.id) == tostring(pending.colonyId) then work.returned = work.returned + count end
        end
        state.pendingTransfer = nil
        save()
        store.event(pending.kind == "export" and "CHEST_VERIFIED" or "RETURN_IMPORTED",
            pending.kind == "export" and "Delivery chest delta verified" or "Return chest decrease verified",
            {colonyId=pending.colonyId, requestId=pending.requestId, item=pending.item.name, count=count})
    end

    local function verifyPending(manual)
        local pending = state.pendingTransfer
        if not pending then return true end
        if not manual and io.now() < (pending.nextReadAt or 0) then return false end
        local delta, err = matchingPendingChest(pending)
        pending.nextReadAt = io.now() + (pending.pollSeconds or 0.25)
        if delta and delta > 0 and delta <= pending.count then
            -- The chest proves actual movement. A nonzero API result must agree
            -- before releasing it; mismatches may represent an unfinished move.
            if (pending.reported == nil and delta == pending.count)
                or (pending.reported ~= nil and pending.reported > 0 and delta == integer(pending.reported))
                or (pending.reported == 0 and delta == pending.count) then
                creditTransfer(pending, delta)
                if pending.uncertain or pending.recoveryProbe then
                    clearQuarantine()
                    store.event("PRS_RECOVERED", "Held transfer verified from physical chest delta", {colonyId=pending.colonyId})
                end
                return true
            end
        end
        if io.now() - pending.startedAt < pending.verifySeconds and not pending.uncertain then
            save()
            return false
        end
        pending.uncertain = true
        pending.lastDelta, pending.lastError = delta, err
        local reason = err and "Cannot verify transfer inventory: " .. err
            or "Transfer inventory delta does not agree with the export/import outcome"
        if pending.reported == 0 and delta == 0 then
            reason = pending.kind == "export" and "PRS reported stock but exported zero; possible desync"
                or "PRS accepted no return items; check storage capacity or possible desync"
            pending.definiteZero = true
        end
        quarantine("TRANSFER_VERIFY", reason, {colonyId=pending.colonyId,
            requestId=pending.requestId, item=pending.item.name, expected=pending.count,
            reported=pending.reported, actual=delta, error=err})
        local cs = state.colonies[tostring(pending.colonyId)]
        local record = cs and cs.requests[pending.requestId]
        if record then record.status, record.detail, record.errorCode = "error", reason, "PRS_QUARANTINE" end
        save()
        return false
    end

    local function beginTransfer(kind, colony, cs, item, candidate, variant, count, before, record, recovery)
        local p = cs.turn.policy
        state.pendingTransfer = {kind=kind, colonyId=colony.id,
            requestId=record and record.id or nil, generation=record and record.generation or nil,
            chest=kind == "export" and colony.deliveryChest or colony.returnChest,
            item=copy(item), candidate=candidate and copy(candidate) or nil,
            variant=variant and copy(variant) or nil, count=count, before=before,
            session=cs.turn.session, turn=cs.turn.id, startedAt=io.now(),
            verifySeconds=p.transferVerifyTimeoutSeconds, pollSeconds=p.transferPollSeconds,
            nextReadAt=io.now() + p.transferSettleSeconds, intent=true,
            recoveryProbe=recovery == true}
        -- Durable intent MUST precede the single mutating bridge call. A crash
        -- in that call is reconciled from inventory, never blindly retried.
        save()
        local moved, err
        if kind == "export" then
            moved, err = io.exportPRS(candidate, variant, count, colony.deliveryChest, colony)
        else
            moved, err = io.importPRS(item, count, colony.returnChest, colony)
        end
        state.pendingTransfer.reported = moved
        state.pendingTransfer.callError = err
        state.pendingTransfer.intent = nil
        save()
    end

    local function processReturns(colony, cs)
        local p = cs.turn.policy
        if work.returned >= p.maxReturnItemsPerTurn then work.returnDone = true; return end
        local items, err = io.snapshot(colony.returnChest)
        if type(items) ~= "table" then
            cs.error = "Cannot inspect return chest: " .. tostring(err)
            errorEvent("RETURN_CHEST", cs.error, {colonyId=colony.id})
            work.returnDone = true
            return
        end
        local slots = {}
        for slot, item in pairs(items) do
            if type(item) == "table" and integer(item.count or item.amount) > 0 then slots[#slots + 1] = slot end
        end
        table.sort(slots, function(a,b) return tostring(a) < tostring(b) end)
        if #slots == 0 then work.returnDone = true; return end
        local item = items[slots[1]]
        local count = math.min(integer(item.count or item.amount), p.maxTransferChunk,
            p.maxReturnItemsPerTurn - work.returned)
        if count <= 0 then work.returnDone = true; return end
        beginTransfer("import", colony, cs, item, nil, nil, count,
            integer(io.count(items, item)), nil, false)
    end

    local function processRequest(colony, cs, request)
        local record = cs.requests[tostring(request.id)]
        local p = cs.turn.policy
        if not record or record.status == "delivered" or record.status == "error" then return end
        statusRecord(cs, record, p)
        local shipped = totals(cs, record)
        local remaining = math.max(0, record.requested - shipped)
        if remaining == 0 or work.items >= p.maxItemsPerTurn then return end
        local linkedCraft = record.craftIdentity and state.craftJobs[record.craftIdentity]
        if activeCraft(linkedCraft) and io.now() < (linkedCraft.nextPollAt or 0) then
            save()
            return
        end
        local items = stock()
        if not items then return end
        observeCrafts(items, p)
        local queryError = nil
        local candidate, _, why = matcher.chooseFromSnapshot(request, items, function(c)
            local job = state.craftJobs[craftIdentity(c)]
            if activeCraft(job) then return true, "existing shared craft", true end
            if p.autoCraftEnabled ~= true then return false, "autocrafting disabled", true end
            local craftable, err = io.craftable(c)
            if craftable == nil then queryError = err; return nil, tostring(err), false end
            return craftable == true, err, true
        end, remaining)
        if not candidate then
            record.status, record.detail = "missing", why or "No acceptable item alternative"
            save()
            return
        end
        if candidate.stock > 0 then
            local variant = candidate.variants[1]
            local filter, filterError = matcher.exportFilterForVariant(candidate, variant, 1)
            if not filter then
                record.status, record.detail = "error", filterError
                record.retryAt = io.now() + p.retryCooldownSeconds
                errorEvent("UNSAFE_VARIANT", filterError, {colonyId=colony.id, requestId=record.id})
                save()
                return
            end
            local item = {name=variant.name, nbt=copy(variant.nbt), fingerprint=variant.fingerprint,
                displayName=variant.displayName or candidate.displayName,
                toolClass=candidate.toolClass,
                maxCount=variant.raw and (variant.raw.maxCount or variant.raw.maxStackSize)
                    or (candidate.toolClass and 1) or nil}
            local chest, chestErr = io.snapshot(colony.deliveryChest)
            if not chest then
                record.status, record.detail = "error", "Cannot inspect delivery chest: " .. tostring(chestErr)
                record.retryAt = io.now() + p.retryCooldownSeconds
                errorEvent("DELIVERY_CHEST", record.detail, {colonyId=colony.id, requestId=record.id})
                save()
                return
            end
            local capacity, capacityErr = io.capacity(colony.deliveryChest, chest, item, p.chestReserveSlots)
            if capacity == nil then
                record.status, record.detail = "error", "Cannot establish chest capacity: " .. tostring(capacityErr)
                record.retryAt = io.now() + p.retryCooldownSeconds
                save()
                return
            end
            local count = math.min(remaining, integer(variant.amount), p.maxTransferChunk,
                p.maxItemsPerTurn - work.items, integer(capacity))
            if count <= 0 then
                record.status, record.detail = "in progress", "Delivery chest has no reserved capacity"
                save()
                return
            end
            record.selectedItem = copy(item)
            beginTransfer("export", colony, cs, item, candidate, variant, count,
                integer(io.count(chest, item)), record, false)
            return
        end

        local identity = craftIdentity(candidate)
        local job = state.craftJobs[identity]
        if activeCraft(job) then
            record.craftIdentity = identity
            statusRecord(cs, record, p)
            save()
            return
        end
        if queryError then
            record.status, record.detail = "error", "Cannot determine exact craftability: " .. tostring(queryError)
            record.retryAt = io.now() + p.retryCooldownSeconds
            errorEvent("CRAFTABILITY", record.detail, {colonyId=colony.id, requestId=record.id})
            save()
            return
        end
        if p.autoCraftEnabled ~= true or candidate.craftable ~= true then
            record.status, record.detail = "missing", p.autoCraftEnabled ~= true and "Not in PRS; autocrafting disabled" or "Not in PRS; no usable exact recipe"
            save()
            return
        end
        local craftCount = 0
        for _, existing in pairs(state.craftJobs) do if activeCraft(existing) then craftCount = craftCount + 1 end end
        if craftCount >= p.maxConcurrentCrafts or work.crafts >= p.maxCraftsPerTurn then
            record.status, record.detail = "requested", "Waiting for available craft limit"
            save()
            return
        end
        if job and io.now() - (job.completedAt or job.createdAt) < math.max(p.craftCooldownSeconds, p.retryCooldownSeconds) then
            record.status, record.detail = "requested", "Waiting for craft retry cooldown"
            save()
            return
        end
        local count = math.min(remaining, p.maxCraftBatch)
        if count <= 0 then return end
        local craftItem = copy(candidate.raw)
        if not candidate.hasNBT then craftItem.nbt = nil end
        job = {identity=identity, item=craftItem, count=count,
            baseline=stockCount(items, candidate.raw), exported=0, proven=0,
            createdAt=io.now(), nextPollAt=io.now()+p.craftPollSeconds,
            timeoutSeconds=p.craftingTimeoutSeconds, pollSeconds=p.craftPollSeconds,
            stableReadsRequired=p.craftStableReadsRequired,
            state="uncertain", colonyId=colony.id, requestId=record.id}
        state.craftJobs[identity] = job
        record.craftIdentity = identity
        cs.turn.craftsSubmitted = integer(cs.turn.craftsSubmitted) + 1
        save()
        local accepted, craftErr = io.craft(candidate, count)
        work.crafts = work.crafts + 1
        if accepted == true then
            job.state = "crafting"
            record.status, record.detail = "crafting", "PRS accepted craft; exact identity reserved globally"
            store.event("CRAFT_ACCEPTED", "PRS accepted craft", {colonyId=colony.id, requestId=record.id, item=candidate.name, count=count})
        elseif accepted == false then
            job.state, job.completedAt = "rejected", io.now()
            record.status, record.detail = "missing", "PRS declined crafting: " .. tostring(craftErr or "unavailable")
        else
            record.status, record.detail = "error", "Craft outcome uncertain; automatic resubmission disabled"
            record.errorCode = "CRAFT_UNCERTAIN"
            job.error = tostring(craftErr)
            errorEvent("CRAFT_UNCERTAIN", record.detail, {colonyId=colony.id, requestId=record.id, item=candidate.name})
        end
        save()
    end

    local function acknowledgeImports(cs, imports)
        if type(imports) ~= "table" then return false, "Cumulative imports are missing" end
        for _, shipment in ipairs(cs.shipments) do
            local reported = imports[shipment.id]
            if reported ~= nil then
                if type(reported) ~= "number" or reported ~= integer(reported)
                    or reported < integer(shipment.imported) or reported > integer(shipment.count) then
                    return false, "Invalid cumulative shipment acknowledgement: " .. shipment.id
                end
            end
        end
        for _, shipment in ipairs(cs.shipments) do
            if imports[shipment.id] ~= nil then shipment.imported = imports[shipment.id] end
        end
        return true
    end

    local function acceptBatch(colony, cs, message)
        local turn = cs.turn
        if message.session ~= turn.session or message.turn ~= turn.id then return false end
        if turn.phase == "RESULT" then sendTurn(colony, cs); return true end
        if turn.phase ~= "WAIT_BATCH" then return true end
        if message.authoritative == false or (message.clientError and type(message.activeIds) ~= "table") then
            turn.batch = {requests={}, clientError=tostring(message.clientError or "MineColonies request snapshot unavailable")}
            local imported, importError = acknowledgeImports(cs, message.imports)
            if not imported then turn.batch.clientError = turn.batch.clientError .. "; " .. importError end
            cs.error = turn.batch.clientError
            turn.phase = "READY"
            save()
            return true
        end
        if type(message.requests) ~= "table" or type(message.activeIds) ~= "table" or type(message.imports) ~= "table" then
            errorEvent("BAD_BATCH", "Batch is missing requests, activeIds, or cumulative imports", {colonyId=colony.id})
            return false
        end
        if #message.requests > integer(turn.policy.maxRequestsPerTurn) then
            errorEvent("BAD_BATCH", "Batch exceeds negotiated request limit", {colonyId=colony.id})
            return false
        end
        local active, seen = {}, {}
        for key, id in pairs(message.activeIds) do
            if type(id) == "boolean" then id = key end
            if type(id) ~= "string" and type(id) ~= "number" then return false end
            active[tostring(id)] = true
        end
        for _, request in ipairs(message.requests) do
            if type(request) ~= "table" or request.id == nil or type(request.items) ~= "table" then return false end
            local id = tostring(request.id)
            if seen[id] or not active[id] or requestCount(request) <= 0 then return false end
            seen[id] = true
        end
        local imported, importError = acknowledgeImports(cs, message.imports)
        if not imported then
            cs.error = importError
            errorEvent("IMPORT_ACK", importError, {colonyId=colony.id})
            turn.batch = {requests={}, clientError=importError}
            turn.phase = "READY"
            save()
            return true
        end
        turn.batch = copy(message)
        cs.colonyName = message.colonyName or cs.colonyName
        cs.error = message.clientError and tostring(message.clientError) or nil
        if message.authoritative ~= false then
            for id, record in pairs(cs.requests) do
                if not active[id] and record.status ~= "delivered" then
                    record.status, record.detail = "delivered", "Request no longer appears in MineColonies"
                    record.completedAt, record.completedTurn = io.now(), turn.id
                    store.event("REQUEST_DELIVERED", record.detail, {colonyId=colony.id, requestId=id})
                end
            end
            for _, request in ipairs(message.requests) do
                local id, sig = tostring(request.id), signature(request, matcher)
                local record = cs.requests[id]
                if not record or record.status == "delivered" then
                    record = {id=id, requestId=id, generation=record and integer(record.generation) + 1 or 1,
                        createdAt=io.now(), requested=requestCount(request), shipped=0, imported=0,
                        status="requested", detail="Received from colony", signature=sig}
                    cs.requests[id] = record
                elseif record.signature ~= sig then
                    record.status, record.detail, record.errorCode = "error", "Active request identity changed; prior deliveries need reconciliation", "REQUEST_CHANGED"
                    errorEvent("REQUEST_CHANGED", record.detail, {colonyId=colony.id, requestId=id})
                else
                    record.requested = math.max(integer(record.requested), requestCount(request))
                    if record.status == "error" and record.retryAt and io.now() >= record.retryAt then
                        record.status, record.detail, record.retryAt = "requested", "Retrying safe inventory inspection", nil
                    end
                    if record.errorCode == "CLIENT" then
                        record.status, record.detail, record.errorCode = "requested", "Colony reports a healthy handoff", nil
                    end
                end
                record.name = request.name or request.displayName or id
                record.displayName = record.name
                record.lastSeenAt = io.now()
                record.request = copy(request)
            end
        end
        turn.phase = "READY"
        save()
        return true
    end

    function self.onMessage(sender, message)
        if type(message) ~= "table" or (message.version ~= nil and message.version ~= 1) then return false end
        local colony = definition(sender)
        if not colony then return false end
        local cs = colonyState(colony)
        cs.lastSeen = io.now()
        local kind = message.kind or message.type
        if kind == "hello" or kind == "heartbeat" then
            if kind == "hello" then
                local confirmed = channel(message.deliveryChannel) ~= ""
                    and channel(message.deliveryChannel) == channel(colony.deliveryChannel)
                    and channel(message.returnChannel) ~= ""
                    and channel(message.returnChannel) == channel(colony.returnChannel)
                cs.routeConfirmed = confirmed
                if not confirmed then
                    local detail = "Colony color labels disagree with configured delivery/return routes"
                    if cs.routeError ~= detail then errorEvent("CHANNEL_MISMATCH", detail, {colonyId=colony.id}) end
                    cs.routeError = detail
                    save()
                    return true
                end
                cs.routeError = nil
            end
            save()
            if cs.turn and (cs.turn.phase == "RESULT" or (cs.turn.phase == "WAIT_BATCH" and checkRoutes(colony, cs))) then sendTurn(colony, cs) end
            return true
        end
        if not cs.turn or message.session ~= cs.turn.session or message.turn ~= cs.turn.id then return false end
        if kind == "batch" then return acceptBatch(colony, cs, message) end
        if kind == "received" and cs.turn.phase == "RESULT" then
            cs.lastCompletedTurn = cs.turn.id
            cs.turn = nil
            pruneCompleted(cs)
            save()
            return true
        end
        return false
    end

    local function startWork(colony, cs)
        local turn = cs.turn
        turn.phase = "PROCESS"
        local requests = turn.batch and turn.batch.requests or {}
        -- Both peers rotate their request cursors. This rotation also prevents
        -- a large partial request from monopolising a small item-per-turn budget.
        local ordered = turn.orderedRequests or {}
        if not turn.orderedRequests and #requests > 0 then
            local start = integer(cs.requestCursor) % #requests
            for offset=1,#requests do ordered[#ordered + 1] = requests[((start + offset - 1) % #requests) + 1] end
            cs.requestCursor = (start + 1) % #requests
        end
        turn.orderedRequests = ordered
        work = {colony=colony, cs=cs, requests=ordered, index=integer(turn.nextRequestIndex) > 0 and turn.nextRequestIndex or 1,
            items=integer(turn.itemsShipped), returned=integer(turn.itemsReturned),
            crafts=integer(turn.craftsSubmitted), returnDone=false}
        save()
    end

    function self.tick()
        local now = io.now()
        if state.pendingTransfer then
            verifyPending(false)
            if state.pendingTransfer and not state.pendingTransfer.uncertain then return end
            if state.pendingTransfer and state.pendingTransfer.uncertain then
                if work and tostring(work.colony.id) == tostring(state.pendingTransfer.colonyId) then finishTurn(work.colony, work.cs) end
            end
        end
        if work then
            local colony, cs = work.colony, work.cs
            if state.quarantine or cs.error or (cs.turn.batch and cs.turn.batch.clientError) then
                for _, request in ipairs(work.requests) do
                    local record = cs.requests[tostring(request.id)]
                    if record and record.status ~= "delivered" then
                        record.status, record.detail = "error", cs.error or cs.routeError
                            or (cs.turn.batch and cs.turn.batch.clientError)
                            or (state.quarantine and state.quarantine.message) or "Colony transfer paused"
                        record.errorCode = state.quarantine and "PRS_QUARANTINE" or "CLIENT"
                    end
                end
                finishTurn(colony, cs)
                return
            end
            if not work.returnDone then processReturns(colony, cs); return end
            local request = work.requests[work.index]
            if request then
                work.index = work.index + 1
                cs.turn.nextRequestIndex = work.index
                save()
                processRequest(colony, cs, request)
                return
            end
            finishTurn(colony, cs)
            return
        end

        local colonies = config.colonies or {}
        if #colonies == 0 then return end
        if not state.pendingTransfer and not state.quarantine then
            local due = false
            for _, job in pairs(state.craftJobs) do
                if activeCraft(job) and now >= (job.nextPollAt or 0) then due = true; break end
            end
            if due then
                local items = stock()
                if items then observeCrafts(items, policy(nil)) else return end
            end
        end
        -- Existing handoffs are always serviced before a new grant. Retry only
        -- messages; no retry timer authorises another inventory operation.
        local awaitingClient = false
        for _, colony in ipairs(colonies) do
            local cs = colonyState(colony)
            local turn = cs.turn
            if turn then
                if turn.phase == "READY" or turn.phase == "PROCESS" then
                    if checkRoutes(colony, cs) then
                        startWork(colony, cs)
                    else
                        cs.error = cs.routeError
                        finishTurn(colony, cs)
                    end
                    return
                end
                if now - (turn.lastSentAt or 0) >= turn.policy.batchRetrySeconds then sendTurn(colony, cs) end
                if turn.phase == "WAIT_BATCH" and now - turn.createdAt >= turn.policy.colonyResponseTimeoutSeconds then
                    if not turn.timedOut then
                        turn.timedOut = true
                        save()
                        errorEvent("COLONY_TIMEOUT", "Colony response overdue; original chest handoff retained", {colonyId=colony.id, turn=turn.id})
                    end
                end
                if turn.phase == "WAIT_BATCH" and not turn.timedOut then awaitingClient = true end
                if turn.phase == "RESULT" and now - turn.finishedAt >= turn.policy.messageTimeoutSeconds and not turn.ackTimedOut then
                    turn.ackTimedOut = true
                    save()
                    errorEvent("RESULT_ACK_TIMEOUT", "Colony result acknowledgement overdue; retained result will be resent", {colonyId=colony.id})
                end
                if turn.phase == "RECOVERY" and not state.pendingTransfer then
                    cs.turn = nil
                    save()
                end
            end
        end
        if config.automationEnabled == false or awaitingClient then return end
        if now < nextTurnAt then return end
        for _=1,#colonies do
            state.colonyCursor = (state.colonyCursor % #colonies) + 1
            local colony = colonies[state.colonyCursor]
            local cs = colonyState(colony)
            local ownsUncertainChest = state.pendingTransfer and tostring(state.pendingTransfer.colonyId) == tostring(colony.id)
            if not cs.turn and not ownsUncertainChest and checkRoutes(colony, cs) then
                state.turnCounter = state.turnCounter + 1
                cs.turn = {session=session, id=state.turnCounter, phase="WAIT_BATCH", createdAt=now,
                    policy=policy(colony), routeSignature=routeSignature(colony)}
                save()
                sendTurn(colony, cs)
                nextTurnAt = now + cs.turn.policy.pollIntervalSeconds
                return
            end
        end
        save()
    end

    function self.reconcile()
        local pending = state.pendingTransfer
        if not pending then
            if state.quarantine and state.quarantine.code == "PRS_READ" then
                local items, err = io.stock()
                if not items then return false, "PRS inventory remains unreadable: " .. tostring(err) end
                clearQuarantine()
                return true, "PRS inventory access restored"
            end
            return false, "No ambiguous transfer to reconcile; craft identities remain reserved until output is observed"
        end
        if verifyPending(true) then
            clearQuarantine()
            return true, "Original transfer verified from chest inventory"
        end
        -- A definite zero return plus unchanged chest can be recovered with one
        -- explicitly requested, journalled diagnostic item. Exceptions never
        -- take this path because the original transfer may still arrive.
        if pending.definiteZero and pending.reported == 0 and pending.lastDelta == 0 then
            local colony = definition(pending.colonyId)
            local cs = colony and colonyState(colony)
            if cs and cs.turn and cs.turn.phase == "RECOVERY" and pending.recoveryProbe then
                -- This internal marker was never granted to the client.
                cs.turn = nil
                save()
            end
            if not colony or not cs or cs.turn then
                return false, "Wait for the colony to acknowledge the paused result before a recovery probe"
            end
            if not checkRoutes(colony, cs) then return false, cs.routeError end
            local p = policy(colony)
            if state.lastRecoveryProbeAt and io.now()-state.lastRecoveryProbeAt < p.desyncProbeSeconds then
                return false, "Wait for configured recovery probe interval before trying again"
            end
            -- Client acknowledged RESULT and is idle. Retain a master turn
            -- solely for recovery; no turn message permits it to drain.
            cs.turn = {session=pending.session, id=pending.turn, phase="RECOVERY", policy=p}
            local record = cs.requests[pending.requestId]
            local candidate
            local variant
            if pending.kind == "export" then
                local items = stock()
                if not items then cs.turn=nil; save(); return false, "PRS stock remains unreadable" end
                candidate = copy(pending.candidate)
                for _, entry in pairs(items) do
                    if matcher.itemIdentity(entry) == matcher.itemIdentity(pending.item) and integer(entry.amount) > 0 then
                        variant = copy(entry)
                        break
                    end
                end
                if not candidate or not variant then cs.turn=nil; save(); return false, "Original exact item unavailable for recovery" end
                local filter = matcher.exportFilterForVariant(candidate, variant, 1)
                if not filter then cs.turn=nil; save(); return false, "Original exact export filter unavailable for recovery" end
            else
                local chest, err = io.snapshot(pending.chest)
                if not chest or integer(io.count(chest, pending.item)) < 1 then
                    cs.turn=nil; save(); return false, "Original return item unavailable: " .. tostring(err)
                end
            end
            local item = copy(pending.item)
            state.lastRecoveryProbeAt = io.now()
            beginTransfer(pending.kind, colony, cs, item, candidate, variant, 1, pending.before, record, true)
            store.event("PRS_PROBE", "Explicit guarded recovery transfer started", {colonyId=colony.id, item=item.name, direction=pending.kind})
            return true, "Guarded recovery probe started; chest verification must succeed"
        end
        return false, "Transfer remains uncertain; chest held and no replacement sent"
    end

    -- Poll an already journaled probe without submitting another bridge call.
    -- The CLI uses this while waiting for physical inventory visibility.
    function self.verifyHeldTransfer()
        if not state.pendingTransfer then return true, "No held transfer remains" end
        local owner=state.pendingTransfer.colonyId
        if not verifyPending(true) then return false,"Transfer verification pending; existing intent retained" end
        clearQuarantine()
        local cs=state.colonies[tostring(owner)]
        if cs and cs.turn and cs.turn.phase=="RECOVERY" then cs.turn=nil; save() end
        return true,"Held transfer verified from physical chest quantities"
    end

    function self.busy()
        if work or state.pendingTransfer then return true end
        for _, cs in pairs(state.colonies) do if cs.turn then return true end end
        return false
    end

    function self.canUpdate()
        return not self.busy() and not state.quarantine
    end

    function self.snapshot()
        local requests, colonies, crafts = {}, {}, {}
        for _, colony in ipairs(config.colonies or {}) do
            local cs = colonyState(colony)
            local p = policy(colony)
            colonies[#colonies + 1] = {id=colony.id, label=colony.label or cs.colonyName or tostring(colony.id),
                state=(cs.error or cs.routeError) and "error" or cs.turn and cs.turn.phase or "idle", lastSeen=cs.lastSeen,
                session=cs.turn and cs.turn.session, turn=cs.turn and cs.turn.id, detail=cs.error or cs.routeError}
            for _, record in pairs(cs.requests) do
                if record.status ~= "delivered" then
                    statusRecord(cs, record, p)
                    local row = publicRecord(record)
                    row.colonyId, row.colonyLabel = colony.id, colony.label or cs.colonyName or tostring(colony.id)
                    requests[#requests + 1] = row
                end
            end
        end
        for _, job in pairs(state.craftJobs) do if activeCraft(job) then crafts[#crafts + 1] = copy(job) end end
        table.sort(requests, function(a,b) return tostring(a.colonyId) .. ":" .. a.id < tostring(b.colonyId) .. ":" .. b.id end)
        local status = state.quarantine and "PRS quarantined: " .. state.quarantine.message
            or work and "Processing colony " .. tostring(work.colony.id)
            or #colonies == 0 and "Configure colony routes in Settings"
            or "Polling colonies; dedicated PRS owner"
        return {role="master", statusMessage=status, requests=requests, colonies=colonies,
            crafts=crafts, quarantine=copy(state.quarantine), pendingTransfer=copy(state.pendingTransfer),
            history=d.history or {}, errors=d.errors or {},
            health={{label="Dedicated PRS owner", ok=true, detail="Only this computer calls the player RS Bridge"},
                {label="Transfer integrity", ok=state.quarantine == nil, detail=state.quarantine and state.quarantine.message or "No uncertain transfer"}},
            stats={active=#requests, crafting=#crafts, colonies=#colonies}}
    end

    -- Preserve old in-flight turn sessions across reboot. Changing their ID
    -- strands a client still legally draining its previous grant.
    for _, cs in pairs(state.colonies) do
        cs.routeConfirmed = false
        if cs.turn and cs.turn.phase == "PROCESS" then cs.turn.phase = "READY" end
    end
    if state.pendingTransfer and state.pendingTransfer.intent then
        state.pendingTransfer.reported = nil
    end
    save()
    return self
end

return M
