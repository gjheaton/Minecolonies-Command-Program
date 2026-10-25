-- Dedicated PRS owner. No colony receives permission to touch this bridge.
-- A turn is a durable chest handoff, not a timed lease: an overdue client may
-- finish its drain, but the master will not export until that exact batch arrives.
local Config = require("colony.network.config")
local M = { MODULE_VERSION = "4.0.33" }

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

local function equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for key, value in pairs(a) do if not equal(value, b[key]) then return false end end
    for key in pairs(b) do if a[key] == nil then return false end end
    return true
end

local function restore(target, saved)
    for key in pairs(target) do if saved[key] == nil then target[key] = nil end end
    for key, value in pairs(saved) do
        if type(value) == "table" and type(target[key]) == "table" then restore(target[key], value)
        else target[key] = copy(value) end
    end
end

local function validFingerprint(value)
    return type(value) == "string" and value ~= "" and #value <= 256
end

local function denseArray(value)
    if type(value) ~= "table" then return false end
    local length = #value
    for key in pairs(value) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > length then return false end
    end
    for index=1,length do if value[index] == nil then return false end end
    return true
end

local function validateReturnSelectors(selectors,matcher,retainedAliases)
    if selectors == nil then return {} end -- Older clients may return plain items.
    if not denseArray(selectors) then return nil, "Return selectors are not a dense array" end
    local result, seen, rawSeen, length = {}, {}, {}, #selectors
    if length > 1024 then return nil, "Too many return selectors" end
    for _, selector in ipairs(selectors) do
        local item = type(selector) == "table" and selector.item
        local nbt = type(item) == "table" and item.nbt
        local originalNBT=nbt
        if matcher.canonicalNBT(nbt)=="" then nbt = nil end
        if type(item) ~= "table" or type(item.name) ~= "string" or item.name == "" or #item.name > 256
            or (nbt ~= nil and (type(nbt) ~= "string" or #nbt > 256))
            or not validFingerprint(selector.fingerprint) then
            return nil, "Invalid physical return selector"
        end
        local normalized={name=item.name,nbt=nbt}
        local identity = matcher.itemIdentity(normalized)
        local rawIdentity=identity.."\n"..type(originalNBT)..":"
            ..(type(originalNBT)=="table" and "{}" or tostring(originalNBT))
        if rawSeen[rawIdentity] and not (retainedAliases and nbt==nil) then
            return nil,"Duplicate physical return selector"
        end
        rawSeen[rawIdentity]=true
        if seen[identity] then
            if seen[identity]~=selector.fingerprint then return nil,"Equivalent physical return selectors have conflicting AP fingerprints" end
            if nbt~=nil then return nil,"Duplicate physical return selector" end
        else
            seen[identity] = selector.fingerprint
            result[#result + 1] = {item=normalized, fingerprint=selector.fingerprint}
        end
    end
    return result
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

    local function transferColonyLabel(pending)
        local colony = definition(pending.colonyId)
        local cs = state.colonies[tostring(pending.colonyId)]
        return colony and colony.label or cs and cs.colonyName or tostring(pending.colonyId)
    end

    local function transferItemLabel(pending)
        local item = type(pending.item) == "table" and pending.item or {}
        return tostring(item.displayName or item.name or "UNKNOWN")
    end

    local function deliveryDrainLockedFor(colony)
        local pending=state.pendingTransfer
        return type(pending)=="table"
            and pending.kind=="export"
            and tostring(pending.colonyId)==tostring(colony.id)
            and tostring(pending.chest or "")==tostring(colony.deliveryChest or "")
    end

    local function zeroTransferReason(pending)
        local operation = pending.kind == "export" and "export" or "import"
        local reason = "PRS " .. operation .. " returned 0; chest unchanged. Transfer held."
        if pending.callError ~= nil and tostring(pending.callError) ~= "" then
            reason = reason .. " Bridge reason: " .. tostring(pending.callError)
        end
        return reason
    end

    local function verificationReason(pending,delta,err)
        if pending.reported == 0 and delta == 0 then return zeroTransferReason(pending) end
        return err and "Cannot verify transfer inventory: " .. err
            or "Transfer inventory delta does not agree with the export/import outcome"
    end

    local function currentTransferReason()
        local fault, pending = state.quarantine, state.pendingTransfer
        if not fault then return "No uncertain transfer" end
        -- Older journals labelled every zero as a possible storage desync.
        -- Present the evidence accurately without changing those durable holds.
        if fault.code == "TRANSFER_VERIFY" and type(pending) == "table"
            and (pending.lastDelta ~= nil or pending.lastError ~= nil) then
            -- A guarded probe retains the original quarantine. Its latest
            -- physical verification may now fail for a different reason.
            return verificationReason(pending,pending.lastDelta,pending.lastError)
        end
        return tostring(fault.message)
    end

    local function transferFaultDetail()
        local fault, pending = state.quarantine, state.pendingTransfer
        if not fault then return "No uncertain transfer" end
        local detail = currentTransferReason()
        if type(pending) ~= "table" then return detail end
        local item = type(pending.item) == "table" and pending.item or {}
        local function value(raw) return raw == nil and "UNKNOWN" or tostring(raw) end
        return detail .. "\nItem: " .. transferItemLabel(pending)
            .. "\nID: " .. value(item.name)
            .. "\nQuantity: " .. value(pending.count) .. " (PRS " .. value(pending.kind) .. ")"
            .. "\nBridge reason: " .. (pending.callError ~= nil and value(pending.callError) or "not recorded")
            .. "\nColony: " .. transferColonyLabel(pending) .. " [" .. value(pending.colonyId) .. "]"
            .. "\nChest: " .. value(pending.chest)
            .. "\nReported / chest change: " .. value(pending.reported) .. " / " .. value(pending.lastDelta)
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
        if record.errorCode == "PRS_QUARANTINE" and state.quarantine then
            result.detail = currentTransferReason()
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
            masterError=cs.error or cs.routeError or (state.quarantine and currentTransferReason()) or nil}
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

    local function retainedRegistryRecoveryEligible(pending)
        if type(pending)~="table"
            or pending.kind~="export"
            or pending.reported~=0
            or pending.lastDelta~=0
            or type(pending.item)~="table"
            or type(pending.item.name)~="string"
            or type(pending.candidate)~="table" then
            return false,"not a retained plain export"
        end

        local items,err=io.stock()
        if type(items)~="table" then
            return false,"PRS inventory unreadable: "..tostring(err)
        end

        for _,entry in pairs(items) do
            if type(entry)=="table"
                and entry.name==pending.item.name
                and integer(entry.amount or entry.count)>0
                and type(io.exportSelection)=="function" then
                local _,mode=io.exportSelection(pending.candidate,entry,items)
                if mode=="registry-name" or mode=="transient-name" or mode=="single-variant-name" then
                    return true,mode
                end
            end
        end
        return false,"current stock does not prove registry-ID export safe"
    end

    local function zeroResetEligible(pending)
        if type(pending)~="table"
            or pending.kind~="export"
            or pending.reported~=0
            or pending.lastDelta~=0 then
            return false,"not a confirmed zero export"
        end

        local bridge=type(io.bridgeStatus)=="function" and io.bridgeStatus() or nil
        if type(bridge)=="table" and bridge.connected==false then
            return false,"PRS bridge is not connected"
        end

        local items,err=io.stock()
        if type(items)~="table" then
            return false,"PRS inventory unreadable after zero export: "..tostring(err)
        end

        local mode=tostring(pending.selectionMode or "")
        local wanted=tostring(pending.item and pending.item.name or "")

        if mode=="fingerprint" then
            local fingerprint=pending.item and pending.item.fingerprint
                or pending.variant and pending.variant.fingerprint
            local failedNBT=matcher.canonicalNBT(
                pending.variant and pending.variant.nbt
                    or pending.item and pending.item.nbt
            )

            local exactVisible=0
            local identityVisible=0
            local sameNameVisible=0
            for _,entry in pairs(items) do
                if type(entry)=="table"
                    and entry.name==wanted
                    and integer(entry.amount or entry.count)>0 then
                    local amount=integer(entry.amount or entry.count)
                    sameNameVisible=sameNameVisible+amount
                    if type(fingerprint)=="string" and fingerprint~=""
                        and entry.fingerprint==fingerprint then
                        exactVisible=exactVisible+amount
                    end
                    if matcher.canonicalNBT(entry.nbt)==failedNBT then
                        identityVisible=identityVisible+amount
                    end
                end
            end

            -- The AP/RS ghost-item bug can mutate the fingerprint itself.
            -- Registry ID + canonical NBT is the stable variant identity used
            -- here only to decide whether a reset is warranted; no item is
            -- moved until recovery rebinds to a currently observed fingerprint.
            if exactVisible<=0 and identityVisible<=0 then
                return false,"failed fingerprint/NBT variant is no longer visible in PRS"
            end
            return true,
                "selective variant desync: failed variant still visible x"..
                tostring(math.max(exactVisible,identityVisible))..
                " (same-name total "..tostring(sameNameVisible)..")"
        end

        if mode~="registry-name"
            and mode~="transient-name"
            and mode~="single-variant-name"
            and mode~="plain-name" then
            return false,"selector is "..(mode~="" and mode or "unknown")..
                ", not a confirmed reset-safe selector"
        end

        local visible=0
        for _,entry in pairs(items) do
            if type(entry)=="table"
                and entry.name==wanted
                and integer(entry.amount or entry.count)>0 then
                visible=visible+integer(entry.amount or entry.count)
            end
        end

        if visible<=0 then
            return false,"source item is no longer visible in PRS"
        end
        return true,"registry item still visible in PRS x"..tostring(visible)
    end

    local function maybeAutoResetPRS(pending)
        if config.prsAutoResetEnabled~=true then
            return false,"automatic PRS reset disabled"
        end
        if pending.resetPulseAt then
            return pending.resetPulseOK==true,tostring(pending.resetPulseDetail or "reset already attempted")
        end

        local eligible,why=zeroResetEligible(pending)
        if not eligible then return false,why end

        local cooldown=tonumber(config.prsResetCooldownSeconds) or 120
        local now=io.now()
        if state.lastPrsResetAt and now-state.lastPrsResetAt<cooldown then
            return false,"PRS reset cooldown "..tostring(math.ceil(cooldown-(now-state.lastPrsResetAt))).."s"
        end

        pending.resetPulseAt=now
        pending.resetReason=why
        save()

        local ok,detail=io.pulsePRSReset(
            "confirmed ghost item: "..tostring(pending.item and pending.item.name or "?")..
            " | "..tostring(why)
        )
        pending.resetPulseOK=ok==true
        pending.resetPulseDetail=tostring(detail or "")
        if ok then
            state.lastPrsResetAt=io.now()
            pending.autoRecoveryAt=io.now()+(tonumber(config.prsResetRecoveryDelaySeconds) or 10)
            pending.nextAutoRecoveryAt=pending.autoRecoveryAt
            store.event("PRS_DESYNC_RESET","Confirmed registry-name ghost item reset triggered",{
                colonyId=pending.colonyId,item=pending.item and pending.item.name,
                selectionMode=pending.selectionMode,detail=detail
            })
        else
            errorEvent("PRS_RESET_FAILED","Automatic PRS reset failed",{
                colonyId=pending.colonyId,item=pending.item and pending.item.name,
                selectionMode=pending.selectionMode,detail=detail
            })
        end
        save()
        return ok==true,detail
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
        if pending.kind == "export" and pending.physicalBefore then
            if type(io.exportEvidence) ~= "function" or type(io.exportBaseline) ~= "function" then
                return nil, "Physical export verification is unavailable"
            end
            if type(pending.reported) == "number" and pending.reported > 0 then
                local physical, delta = io.exportEvidence(pending.physicalBefore, items, pending.item, pending.reported,pending.selectionMode)
                if not physical then return nil, tostring(delta) end
                return delta, nil, physical
            end
            -- An unknown/zero result cannot establish a new physical identity.
            -- Still accept the old exact-identity/full-count proof, checking the
            -- complete chest to reject concurrent inventory changes.
            local current, baselineError = io.exportBaseline(items)
            if not current then return nil, tostring(baselineError) end
            local unchanged,baselineError
            if type(io.sameExportBaseline)=="function" then unchanged,baselineError=io.sameExportBaseline(pending.physicalBefore,current)
            else unchanged=equal(current,pending.physicalBefore) end
            if baselineError then return nil,tostring(baselineError) end
            if unchanged then return 0, nil end
            local physical, delta = io.exportEvidence(pending.physicalBefore, items, pending.item, pending.count,pending.selectionMode)
            if not physical then return nil, tostring(delta) end
            if physical.name ~= pending.item.name
                or (pending.selectionMode~="transient-name"
                    and matcher.canonicalNBT(physical.nbt) ~= matcher.canonicalNBT(pending.item.nbt)) then
                return nil, "Unknown transfer result cannot bind a different physical item identity"
            end
            return delta, nil, physical
        end
        local count = integer(io.count(items, pending.item))
        local delta = pending.kind == "export" and count - pending.before or pending.before - count
        return delta, nil
    end

    local function creditTransfer(pending, count, physical)
        local cs = state.colonies[tostring(pending.colonyId)]
        if pending.kind == "export" then
            local shipmentItem = copy(pending.item)
            if physical then
                shipmentItem.name, shipmentItem.nbt = physical.name, physical.nbt
                if pending.selectionMode=="transient-name" then
                    shipmentItem.fingerprint=nil
                    shipmentItem.transientNameImport=true
                else
                    shipmentItem.fingerprint = pending.item.fingerprint
                end
            end
            state.shipmentCounter = state.shipmentCounter + 1
            local shipment = {id="shipment-" .. tostring(state.shipmentCounter),
                requestId=pending.requestId, generation=pending.generation,
                item=shipmentItem, count=count, imported=0, verified=true,
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
        local delta, err, physical = matchingPendingChest(pending)
        pending.nextReadAt = io.now() + (pending.pollSeconds or 0.25)
        if delta and delta > 0 and delta <= pending.count then
            -- The chest proves actual movement. A nonzero API result must agree
            -- before releasing it; mismatches may represent an unfinished move.
            if (pending.reported == nil and delta == pending.count)
                or (pending.reported ~= nil and pending.reported > 0 and delta == integer(pending.reported))
                or (pending.reported == 0 and delta == pending.count) then
                creditTransfer(pending, delta, physical)
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
        local reason = verificationReason(pending,delta,err)
        if pending.reported == 0 and delta == 0 then
            pending.definiteZero = true
        end
        quarantine("TRANSFER_VERIFY", reason, {colonyId=pending.colonyId,
            colonyLabel=transferColonyLabel(pending), chest=pending.chest,
            requestId=pending.requestId, item=pending.item.name, displayName=pending.item.displayName,
            expected=pending.count,
            reported=pending.reported, actual=delta, error=err, callError=pending.callError,selectionMode=pending.selectionMode})
        local cs = state.colonies[tostring(pending.colonyId)]
        local record = cs and cs.requests[pending.requestId]
        if record then record.status, record.detail, record.errorCode = "error", reason, "PRS_QUARANTINE" end

        if pending.definiteZero then
            local resetOK,resetDetail=maybeAutoResetPRS(pending)
            if resetOK then
                reason=reason.." Automatic PRS reset sent; guarded recovery will retry after settle."
                if record then record.detail=reason end
            elseif pending.resetPulseAt then
                reason=reason.." PRS reset attempt failed: "..tostring(resetDetail)
                if record then record.detail=reason end
            end
        end

        save()
        return false
    end

    local function beginTransfer(kind, colony, cs, item, candidate, variant, count, before, record, recovery, chestSnapshot,stockSnapshot)
        local p = cs.turn.policy
        local physicalBefore
        local selectionMode
        if kind == "export" then
            local err
            if not validFingerprint(item.fingerprint) then
                err = "Exact export has no valid Advanced Peripherals fingerprint"
            elseif type(io.exportBaseline) ~= "function" then
                err = "Physical export verification is unavailable"
            else
                physicalBefore, err = io.exportBaseline(chestSnapshot)
            end
            if not physicalBefore then
                if record then
                    record.status, record.detail = "error", tostring(err)
                    record.retryAt = io.now() + p.retryCooldownSeconds
                end
                errorEvent("EXPORT_BASELINE", tostring(err), {colonyId=colony.id, requestId=record and record.id})
                save()
                return false
            end
        end
        if kind=="export" and type(io.exportSelection)=="function" then
            local filter
            filter,selectionMode=io.exportSelection(candidate,variant,stockSnapshot)
            if not filter then
                if record then record.status,record.detail="error",tostring(selectionMode) end
                errorEvent("UNSAFE_VARIANT",tostring(selectionMode),{colonyId=colony.id,requestId=record and record.id})
                save()
                return false
            end
        end
        state.pendingTransfer = {kind=kind, colonyId=colony.id,
            requestId=record and record.id or nil, generation=record and record.generation or nil,
            chest=kind == "export" and colony.deliveryChest or colony.returnChest,
            item=copy(item), candidate=candidate and copy(candidate) or nil,
            variant=variant and copy(variant) or nil, count=count, before=before, physicalBefore=physicalBefore,
            selectionMode=selectionMode,
            session=cs.turn.session, turn=cs.turn.id, startedAt=io.now(),
            verifySeconds=p.transferVerifyTimeoutSeconds, pollSeconds=p.transferPollSeconds,
            nextReadAt=io.now() + p.transferSettleSeconds, intent=true,
            recoveryProbe=recovery == true}
        -- Durable intent MUST precede the single mutating bridge call. A crash
        -- in that call is reconciled from inventory, never blindly retried.
        save()
        local moved, err
        if kind == "export" then
            moved, err = io.exportPRS(candidate, variant, count, colony.deliveryChest, colony,stockSnapshot)
        else
            moved, err = io.importPRS(item, count, colony.returnChest, colony)
        end
        state.pendingTransfer.reported = moved
        state.pendingTransfer.callError = err
        state.pendingTransfer.intent = nil
        save()
        return true
    end

    local function processReturns(colony, cs)
        local p = cs.turn.policy
        if work.returned >= p.maxReturnItemsPerTurn then work.returnDone = true; return end
        local items, err = io.snapshot(colony.returnChest)
        if type(items) ~= "table" then
            cs.error = "Cannot inspect return chest: " .. tostring(err)
            cs.errorSource = "master"
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
        local item = copy(items[slots[1]])
        item.fingerprint = nil
        for _, selector in ipairs(cs.turn.batch.returnSelectors or {}) do
            if selector.item.name == item.name and selector.item.nbt == item.nbt then
                item.fingerprint = selector.fingerprint
                break
            end
        end
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
                integer(io.count(chest, item)), record, false, chest,items)
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
        local selectors, selectorError = validateReturnSelectors(message.returnSelectors,matcher)
        if not selectors then
            errorEvent("BAD_BATCH", selectorError, {colonyId=colony.id})
            return false
        end
        -- Validate the persisted keys against their original item descriptors
        -- before normalizing a read-only view. Old empty-tag keys may coalesce;
        -- their fingerprints must still agree before any map is replaced.
        local retained={}
        for key,row in pairs(cs.returnSelectors or {}) do
            local item=type(row)=="table" and row.item
            local keyMatches=type(item)=="table" and type(key)=="string" and
                (type(matcher.itemIdentityKeyMatches)=="function" and matcher.itemIdentityKeyMatches(item,key)
                    or key==matcher.itemIdentity(item))
            if not keyMatches then
                errorEvent("BAD_BATCH","A retained return selector has an invalid physical identity key",{colonyId=colony.id})
                return false
            end
            retained[#retained+1]=row
            if #retained>1024 then
                errorEvent("BAD_BATCH","Retained return selectors exceed the safe bound",{colonyId=colony.id})
                return false
            end
        end
        local previousRows,previousError=validateReturnSelectors(retained,matcher,true)
        if not previousRows then
            errorEvent("BAD_BATCH",previousError,{colonyId=colony.id})
            return false
        end
        local previousMap={}
        for _,row in ipairs(previousRows) do previousMap[matcher.itemIdentity(row.item)]=row end
        local selectorMap, changed = {}, {}
        for _, selector in ipairs(selectors) do
            local identity = matcher.itemIdentity(selector.item)
            selectorMap[identity] = copy(selector)
        end
        for identity, previous in pairs(previousMap) do
            local incoming = selectorMap[identity]
            if not incoming or previous.fingerprint ~= incoming.fingerprint then
                changed[#changed + 1] = {previous=previous, incoming=incoming, identity=identity}
            end
        end
        if #changed > 0 then
            local items, err = io.snapshot(colony.returnChest)
            if type(items) ~= "table" then
                errorEvent("BAD_BATCH", "Cannot verify changed return selector: " .. tostring(err), {colonyId=colony.id})
                return false
            end
            for _, change in ipairs(changed) do
                if io.count(items, change.previous.item) > 0 then
                    if change.incoming then
                        errorEvent("BAD_BATCH", "Return selector changed while its physical item remains present", {colonyId=colony.id})
                        return false
                    end
                    -- Omitted metadata cannot discard a still-present binding.
                    selectorMap[change.identity] = copy(change.previous)
                    selectors[#selectors + 1] = copy(change.previous)
                end
            end
            if #selectors > 1024 then
                errorEvent("BAD_BATCH", "Retained return selectors exceed the safe bound", {colonyId=colony.id})
                return false
            end
        end
        if message.authoritative == false or (message.clientError and type(message.activeIds) ~= "table") then
            turn.batch = {requests={}, returnSelectors=selectors,
                clientError=tostring(message.clientError or "MineColonies request snapshot unavailable")}
            local imported, importError = acknowledgeImports(cs, message.imports)
            if not imported then turn.batch.clientError = turn.batch.clientError .. "; " .. importError end
            cs.error = turn.batch.clientError
            cs.errorSource = imported and "client" or "master"
            cs.returnSelectors = selectorMap
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
            cs.errorSource = "master"
            errorEvent("IMPORT_ACK", importError, {colonyId=colony.id})
            turn.batch = {requests={}, clientError=importError}
            turn.phase = "READY"
            save()
            return true
        end
        turn.batch = copy(message)
        turn.batch.returnSelectors = selectors
        cs.returnSelectors = selectorMap
        cs.colonyName = message.colonyName or cs.colonyName
        cs.error = message.clientError and tostring(message.clientError) or nil
        cs.errorSource = cs.error and "client" or nil
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
                else
                    cs.routeError = nil
                end
                if confirmed and type(message.deliveryDrainLocked)=="boolean" then
                    cs.deliveryDrainLockedAck = message.deliveryDrainLocked
                    cs.deliveryDrainLockAckAt = io.now()
                end

                if confirmed and type(message.imports)=="table" then
                    local imported,importError=acknowledgeImports(cs,message.imports)
                    if not imported then
                        cs.error="Heartbeat import receipt rejected: "..tostring(importError)
                        cs.errorSource="master"
                        errorEvent("IMPORT_ACK",cs.error,{colonyId=colony.id})
                    end
                end

                if confirmed and (message.clientError == nil or type(message.clientError) == "string") then
                    -- Connection messages report the current colony fault even
                    -- while paused. Never release a master-detected hold here.
                    -- Older journals lack provenance: migrate only these exact
                    -- known colony transfer messages, leaving other errors held.
                    local legacyClient = cs.errorSource == nil and (
                        cs.error == "Colony bridge result does not match the chest inventory change"
                        or cs.error == "An interrupted chest transfer needs reconciliation; automatic transfers are paused"
                        or cs.error == "Turn preparation was interrupted; transfers need reconciliation")
                    if cs.error == nil or cs.errorSource == "client" or legacyClient then
                        cs.error = message.clientError
                        cs.errorSource = cs.error and "client" or nil
                    end
                end
            end
            save()
            if kind == "hello" then
                -- A paused master still confirms connectivity. This receipt
                -- cannot grant permission to touch either Ender Chest.
                local drainLocked=deliveryDrainLockedFor(colony)
                if not drainLocked then
                    cs.deliveryDrainLockedAck=false
                    cs.deliveryDrainLockAckAt=nil
                end
                io.send(colony.id, {kind="hello_ack", routeConfirmed=cs.routeConfirmed == true,
                    automationEnabled=config.automationEnabled ~= false,
                    deliveryDrainLocked=drainLocked, error=cs.routeError})
                if not cs.routeConfirmed then return true end
            end
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
                if work and tostring(work.colony.id) == tostring(state.pendingTransfer.colonyId) then
                    finishTurn(work.colony, work.cs)
                end

                local pending=state.pendingTransfer

                -- Legacy v4 fingerprint holds for ordinary items are safe to
                -- migrate automatically. We only do this after the original
                -- call returned zero, the chest stayed unchanged, the current
                -- PRS snapshot still contains the item, and exportSelection()
                -- proves the exact namespaced registry ID is safe.
                if pending and pending.definiteZero and pending.reported==0
                    and pending.lastDelta==0 and pending.resetPulseOK~=true
                    and now>=(pending.nextRegistryRecoveryAt or 0) then
                    local eligible,mode=retainedRegistryRecoveryEligible(pending)
                    if eligible then
                        pending.nextRegistryRecoveryAt=now+2
                        save()
                        local ok,msg=self.reconcile()
                        if ok then
                            store.event("PRS_AUTO_RECOVERY",
                                "Automatic registry-ID recovery started for retained plain export",{
                                    colonyId=pending.colonyId,
                                    item=pending.item and pending.item.name,
                                    selectionMode=mode,
                                    detail=msg
                                })
                        end
                    else
                        pending.nextRegistryRecoveryAt=now+5
                        save()
                    end
                end

                pending=state.pendingTransfer
                if pending and pending.resetPulseOK==true
                    and pending.autoRecoveryAt
                    and now>=pending.autoRecoveryAt
                    and now>=(pending.nextAutoRecoveryAt or 0) then
                    pending.nextAutoRecoveryAt=now+2
                    save()
                    local ok,msg=self.reconcile()
                    if ok then
                        store.event("PRS_AUTO_RECOVERY","Automatic guarded recovery started after reset",{
                            colonyId=pending.colonyId,item=pending.item and pending.item.name,detail=msg
                        })
                    end
                end
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
                            or (state.quarantine and currentTransferReason()) or "Colony transfer paused"
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
                        cs.errorSource = "route"
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
        if config.automationEnabled == false or self.updateWaiting or awaitingClient then return end
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
            if pending.kind=="export" and deliveryDrainLockedFor(colony)
                and cs.deliveryDrainLockedAck~=true then
                return false, "Wait for the colony to acknowledge the delivery-chest verification lock"
            end
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
            local exportChest
            local exportStock
            if pending.kind == "export" then
                local items = stock()
                if not items then cs.turn=nil; save(); return false, "PRS stock remains unreadable" end
                candidate = copy(pending.candidate)
                local matchingIdentity
                local registryRelaxed =
                    type(matcher.isRegistryNBTRelaxed)=="function"
                    and matcher.isRegistryNBTRelaxed(pending.item.name)
                local registrySafeVariant
                local registrySafeMode
                local fingerprintVariant
                local nbtIdentityVariant
                local failedNBT=matcher.canonicalNBT(
                    pending.variant and pending.variant.nbt
                        or pending.item and pending.item.nbt
                )

                for _, entry in pairs(items) do
                    if entry.name==pending.item.name and integer(entry.amount)>0 then
                        if matcher.itemIdentity(entry) == matcher.itemIdentity(pending.item) then
                            matchingIdentity = true
                        end

                        -- Prefer the current safe registry-ID path for every
                        -- plain/non-NBT item. Do this even when the old AP
                        -- fingerprint still exists: that fingerprint selector
                        -- is exactly what may have produced the zero export.
                        if candidate and not registrySafeVariant and type(io.exportSelection)=="function" then
                            local _,mode=io.exportSelection(candidate,entry,items)
                            if mode=="registry-name" or mode=="transient-name" then
                                registrySafeVariant=copy(entry)
                                registrySafeMode=mode
                            end
                        end

                        if entry.fingerprint == pending.item.fingerprint then
                            fingerprintVariant=copy(entry)
                        end

                        if not nbtIdentityVariant
                            and matcher.canonicalNBT(entry.nbt)==failedNBT
                            and type(entry.fingerprint)=="string"
                            and entry.fingerprint~="" then
                            nbtIdentityVariant=copy(entry)
                        end

                        if registryRelaxed and not variant then
                            variant = copy(entry)
                        end
                    end
                end

                -- Safe registry-ID export always wins for a retained plain
                -- transfer. Fingerprint recovery is the fallback only when
                -- current stock proves registry-name export is unsafe.
                if registrySafeVariant then
                    variant=registrySafeVariant
                elseif fingerprintVariant then
                    variant=fingerprintVariant
                elseif tostring(pending.selectionMode or "")=="fingerprint"
                    and nbtIdentityVariant then
                    -- Rebind a selective ghost variant to its CURRENT AP
                    -- fingerprint after reset. Registry ID + canonical NBT
                    -- keeps a no-NBT pot distinct from NBT-bearing pots.
                    variant=nbtIdentityVariant
                    pending.item.fingerprint=variant.fingerprint
                    pending.variant=copy(variant)
                    store.event("PRS_VARIANT_REBOUND",
                        "Selective desync recovery rebound to current fingerprint",{
                            colonyId=pending.colonyId,
                            item=pending.item.name,
                            nbt=failedNBT
                        })
                end

                if not candidate then
                    cs.turn=nil; save()
                    return false, "Original request candidate unavailable for recovery"
                end

                if registrySafeVariant then
                    pending.item.fingerprint=variant.fingerprint
                    pending.selectionMode=registrySafeMode
                    matchingIdentity=true
                    if pending.reboundSelectionMode~=registrySafeMode then
                        pending.reboundSelectionMode=registrySafeMode
                        store.event("PRS_RECOVERY_REBOUND",
                            "Retained export rebound to safe registry-ID selector",{
                                colonyId=pending.colonyId,
                                item=pending.item.name,
                                selectionMode=registrySafeMode
                            })
                    end
                end

                if not matchingIdentity and not registryRelaxed then
                    cs.turn=nil; save()
                    return false, "Original exact item unavailable for recovery"
                end
                if not variant or (not registryRelaxed
                    and not registrySafeVariant
                    and not validFingerprint(pending.item.fingerprint)) then
                    cs.turn=nil; save()
                    return false, "Original exact AP fingerprint unavailable for recovery; transfer remains held"
                end
                if registryRelaxed then
                    -- beginTransfer still journals a concrete observed source
                    -- fingerprint for diagnostics, while io.exportSelection()
                    -- uses the exact namespaced registry selector.
                    pending.item.fingerprint = variant.fingerprint
                end
                local filter = matcher.exportFilterForVariant(candidate, variant, 1)
                if not filter then cs.turn=nil; save(); return false, "Original exact export filter unavailable for recovery" end
                local chest, err = io.snapshot(pending.chest)
                if type(chest) ~= "table" then
                    cs.turn=nil; save(); return false, "Cannot inspect original delivery chest: " .. tostring(err)
                end
                -- Stock reads may yield while the original export becomes
                -- visible. Never replace its durable baseline with a changed
                -- chest and thereby lose the original shipment's evidence.
                local unchanged
                if pending.physicalBefore and type(io.exportBaseline) == "function" then
                    local fresh = io.exportBaseline(chest)
                    if fresh and type(io.sameExportBaseline)=="function" then unchanged=io.sameExportBaseline(pending.physicalBefore,fresh)
                    else unchanged=fresh and equal(fresh,pending.physicalBefore) end
                elseif not pending.physicalBefore then
                    unchanged = integer(io.count(chest, pending.item)) == pending.before
                end
                if not unchanged then
                    cs.turn=nil; save(); return false, "Original delivery chest changed during recovery checks; transfer remains held"
                end
                exportChest = chest
                exportStock = items
            else
                local chest, err = io.snapshot(pending.chest)
                if not chest or integer(io.count(chest, pending.item)) < 1 then
                    cs.turn=nil; save(); return false, "Original return item unavailable: " .. tostring(err)
                end
            end
            local item = copy(pending.item)
            state.lastRecoveryProbeAt = io.now()
            if not beginTransfer(pending.kind, colony, cs, item, candidate, variant, 1, pending.before, record, true, exportChest,exportStock) then
                cs.turn=nil; save(); return false, "Recovery transfer could not establish its physical baseline"
            end
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
        if not verifyPending(true) then
            -- A completed verification can fail with definite zero movement,
            -- unreadable inventory, or a mismatched delta. Preserve the hold
            -- and report that evidence instead of calling every failure pending.
            if state.pendingTransfer.uncertain and state.quarantine then
                return false,transferFaultDetail()
            end
            return false,"Transfer verification pending; existing intent retained"
        end
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
        if state.pendingTransfer or state.quarantine then return false,"Held PRS fault requires recovery before updating" end
        if self.busy() then return false,"Waiting for reserved colony turns to finish" end
        return true
    end

    function self.holdNewTurns(enabled) self.updateWaiting=enabled==true end

    function self.canWaitForUpdate()
        local pending=state.pendingTransfer
        return not state.quarantine and (not pending or (not pending.uncertain and not pending.intent))
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
        local heldItem = state.quarantine and state.pendingTransfer
            and transferItemLabel(state.pendingTransfer) .. " x" .. tostring(state.pendingTransfer.count) .. "; " or ""
        local status = state.quarantine and "PRS transfer held: " .. heldItem .. currentTransferReason()
            or work and "Processing colony " .. tostring(work.colony.id)
            or #colonies == 0 and "Configure colony routes in Settings"
            or "Polling colonies; dedicated PRS owner"
        return {role="master", statusMessage=status, requests=requests, colonies=colonies,
            crafts=crafts, quarantine=copy(state.quarantine), pendingTransfer=copy(state.pendingTransfer),
            history=d.history or {}, errors=d.errors or {},
            health={{label="Dedicated PRS owner", ok=true, detail="Only this computer calls the player RS Bridge"},
                {label="Transfer integrity", ok=state.quarantine == nil, detail=transferFaultDetail()}},
            stats={active=#requests, crafting=#crafts, colonies=#colonies}}
    end

    -- Preserve old in-flight turn sessions across reboot. Changing their ID
    -- strands a client still legally draining its previous grant.
    for _, cs in pairs(state.colonies) do
        cs.routeConfirmed = false
        if cs.turn and cs.turn.phase == "PROCESS" then cs.turn.phase = "READY" end
        -- RECOVERY is a Master-internal reservation only; the client never
        -- receives it. If the Master restarts while a held transfer still
        -- exists, retaining this marker can deadlock explicit reconciliation.
        if cs.turn and cs.turn.phase == "RECOVERY" then cs.turn = nil end
    end
    if state.pendingTransfer and state.pendingTransfer.intent then
        state.pendingTransfer.reported = nil
    end
    save()
    return self
end

-- This factory deliberately does not start the processor or change sessions.
-- It binds one already-present legacy export after explicit operator review;
-- none of its paths calls an inventory/PRS mutation or sends a turn grant.
function M.legacyExportRecovery(config, store, io, matcher)
    local self, reviewed = {}, nil

    local function inspect(colonyId)
        if config.role ~= "master" then return nil, "Only the master can bind a held PRS export" end
        local data, colony = store.data
        local state = type(data) == "table" and data.master
        if type(state) ~= "table" then return nil, "No master journal exists" end
        local pending = state.pendingTransfer
        if type(pending) ~= "table" or pending.kind ~= "export" or pending.physicalBefore ~= nil
            or pending.count ~= 1 or pending.reported ~= 1 or pending.before ~= 0
            or pending.intent or not pending.uncertain then
            return nil, "Only a held legacy single-item export with a known result can be bound"
        end
        if tostring(pending.colonyId) ~= tostring(colonyId) then return nil, "The held export belongs to another colony" end
        if type(pending.item) ~= "table" or type(pending.item.name) ~= "string" or pending.item.name == "" or #pending.item.name > 256
            or not validFingerprint(pending.item.fingerprint) then
            return nil, "The held export has no exact Advanced Peripherals fingerprint"
        end
        if type(pending.requestId) ~= "string" or pending.requestId == "" or #pending.requestId > 256 then
            return nil, "The held export request ID cannot be recorded safely"
        end
        for _, entry in ipairs(config.colonies or {}) do
            if tostring(entry.id) == tostring(colonyId) then
                if colony then return nil, "Colony route ID is ambiguous" end
                colony = entry
            end
        end
        if not colony or type(colony.deliveryChest) ~= "string" or colony.deliveryChest == ""
            or #colony.deliveryChest > 256
            or type(colony.returnChest) ~= "string" or colony.returnChest == ""
            or #colony.returnChest > 256
            or colony.deliveryChest == colony.returnChest or colony.deliveryChest ~= pending.chest
            or channel(colony.deliveryChannel) == "" or channel(colony.returnChannel) == ""
            or channel(colony.deliveryChannel) == channel(colony.returnChannel) then
            return nil, "The configured route does not match the held delivery chest"
        end
        if (type(colony.id) ~= "string" and type(colony.id) ~= "number")
            or #tostring(colony.id) > 256 or #("BIND " .. tostring(colony.id)) > 256 then
            return nil, "The colony ID cannot be recorded safely"
        end
        if data.chestTest then return nil, "Finish the retained chest test before binding a delivery" end
        local cs = state.colonies and state.colonies[tostring(colonyId)]
        if type(cs) ~= "table" or cs.turn then return nil, "Wait for the colony's outstanding handoff to finish" end
        if cs.routeError then return nil, "Correct the colony route error before binding: " .. tostring(cs.routeError) end
        local record = cs.requests and cs.requests[pending.requestId]
        if type(record) ~= "table" or record.status == "delivered" or record.generation ~= pending.generation
            or record.errorCode ~= "PRS_QUARANTINE" then
            return nil, "The held export no longer matches its blocked request generation"
        end
        local quarantine = state.quarantine
        local context = type(quarantine) == "table" and quarantine.context
        if type(quarantine) ~= "table" or quarantine.code ~= "TRANSFER_VERIFY" or type(context) ~= "table"
            or tostring(context.colonyId) ~= tostring(colonyId) or context.requestId ~= pending.requestId
            or context.item ~= pending.item.name or context.expected ~= 1 or context.reported ~= 1 then
            return nil, "The active quarantine does not belong to this single-item export"
        end
        if type(io.bridgeStatus) ~= "function" then return nil, "PRS connection verification is unavailable" end
        local status = io.bridgeStatus()
        if type(status) ~= "table" or status.connected ~= true then
            return nil, "PRS connection is not confirmed: " .. tostring(type(status) == "table" and status.error or "unknown")
        end
        if type(status.name) ~= "string" or status.name == "" or #status.name > 256 then
            return nil, "The connected PRS bridge identity is unavailable"
        end
        local stock, stockError = io.stock()
        if type(stock) ~= "table" then return nil, "PRS stock is unreadable: " .. tostring(stockError) end
        local items, chestError = io.snapshot(pending.chest)
        if type(items) ~= "table" then return nil, "Delivery chest is unreadable: " .. tostring(chestError) end
        if type(io.exportBaseline) ~= "function" then return nil, "Physical inventory verification is unavailable" end
        local physicalInventory, inventoryError = io.exportBaseline(items)
        if not physicalInventory then return nil, "Invalid physical chest inventory: " .. tostring(inventoryError) end
        local physical, nameCount = nil, 0
        for _, total in pairs(physicalInventory.totals) do
            if total.item.name == pending.item.name then
                if physical then return nil, "The chest contains multiple variants of the held item" end
                physical, nameCount = copy(total.item), total.count
            end
        end
        if not physical or nameCount ~= 1 or (physical.nbt ~= nil and (type(physical.nbt) ~= "string" or #physical.nbt > 256)) then
            return nil, "The chest must contain exactly one physical item with the held name"
        end
        local required = {}
        if not denseArray(cs.shipments or {}) then return nil, "Existing shipments are not a complete array" end
        for _, shipment in ipairs(cs.shipments or {}) do
            if type(shipment) ~= "table" or shipment.verified ~= true or type(shipment.item) ~= "table"
                or type(shipment.count) ~= "number" or shipment.count < 1 or shipment.count % 1 ~= 0
                or type(shipment.imported) ~= "number" or shipment.imported < 0 or shipment.imported % 1 ~= 0
                or shipment.imported > shipment.count then
                return nil, "An existing shipment cannot be accounted for safely"
            end
            local remaining = shipment.count - shipment.imported
            if remaining > 0 then
                local identity = matcher.itemIdentity(shipment.item)
                if not identity then return nil, "An outstanding shipment has no exact item identity" end
                local total = required[identity] or {item=shipment.item, count=0}
                total.count = total.count + remaining
                required[identity] = total
            end
        end
        for identity, total in pairs(required) do
            local present = physicalInventory.totals[identity]
            if not present or present.count < total.count then return nil, "An older outstanding shipment is not covered by the chest" end
            if total.item.name == physical.name and total.item.nbt == physical.nbt then
                return nil, "The physical item is already needed by an outstanding shipment"
            end
        end
        if type(state.shipmentCounter) ~= "number" or state.shipmentCounter < 0 or state.shipmentCounter % 1 ~= 0
            or state.shipmentCounter == math.huge then return nil, "The shipment safety counter is invalid" end
        local nextId = "shipment-" .. tostring(state.shipmentCounter + 1)
        for _, other in pairs(state.colonies or {}) do
            if not denseArray(other.shipments or {}) then return nil, "Existing shipments are not a complete array" end
            for _, shipment in ipairs(other.shipments or {}) do
                if shipment.id == nextId then return nil, "The next shipment ID already exists" end
            end
        end
        local review = {colonyId=colony.id, item=physical,
            sourceItem={name=pending.item.name,nbt=copy(pending.item.nbt),fingerprint=pending.item.fingerprint},
            chest=pending.chest,count=1,before=0,reported=1,currentNameCount=nameCount,
            confirmation="BIND " .. tostring(colony.id)}
        -- Keep durable state, routes and the physical chest fixed throughout
        -- confirmation. Other PRS stock may change, but this exact bridge must
        -- remain connected and its inventory must still be readable.
        local guard = {master=copy(state),config=copy(config),chestTest=copy(data.chestTest),
            revision=data.revision,inventory=physicalInventory,
            bridge={name=status.name,connected=true,readable=true}}
        return {review=review,guard=guard}
    end

    function self.previewBindExport(colonyId)
        reviewed = nil
        local ok, result, err = pcall(inspect, colonyId)
        if not ok then return false, "Cannot review held export: " .. tostring(result) end
        if not result then return false, err end
        reviewed = result
        return true, copy(result.review)
    end

    function self.reconcileBindExport(colonyId, confirmation)
        if not reviewed or tostring(reviewed.review.colonyId) ~= tostring(colonyId)
            or confirmation ~= reviewed.review.confirmation then
            return false, "Review the held export and type its exact BIND confirmation"
        end
        local ok, fresh, err = pcall(inspect, colonyId)
        if not ok then return false, "Cannot recheck held export: " .. tostring(fresh) end
        if not fresh then reviewed=nil; return false, err end
        if not equal(fresh.guard, reviewed.guard) then
            reviewed=nil
            return false, "The journal, route, PRS bridge or chest changed after review; review the export again"
        end
        reviewed=nil
        local data = store.data
        local state = data.master
        local pending = state.pendingTransfer
        local physical = fresh.review.item
        local cs = state.colonies[tostring(colonyId)]
        local held = copy(state)
        local previousHistory = copy(data.history or {})
        local previousRevision = data.revision
        local function persist()
            local saved, saveError = store.save()
            if saved ~= true then error("Operator binding could not be saved: " .. tostring(saveError), 0) end
        end
        local audited, auditError = pcall(function()
            data.history = data.history or {}
            data.history[#data.history + 1] = {time=io.now(),kind="OPERATOR_BIND_EXPORT",
                message="Operator confirmed one existing legacy export; no additional item moved",
                context={colonyId=fresh.review.colonyId,requestId=pending.requestId,item=pending.item.name,count=1,
                    chest=pending.chest,sourceFingerprint=pending.item.fingerprint,physicalNBT=physical.nbt,
                    confirmation=confirmation}}
            local maximum = math.max(1, integer(config.maxHistoryEntries or 400))
            while #data.history > maximum do table.remove(data.history, 1) end
            persist()
        end)
        if not audited then
            restore(state, held)
            data.history, data.revision = previousHistory, previousRevision
            return false, "Binding audit could not be saved; export remains held: " .. tostring(auditError)
        end
        local auditedRevision = data.revision
        local saved, saveError = pcall(function()
            state.shipmentCounter = state.shipmentCounter + 1
            local shipmentItem = copy(pending.item)
            shipmentItem.name, shipmentItem.nbt = physical.name, physical.nbt
            cs.shipments = cs.shipments or {}
            cs.shipments[#cs.shipments + 1] = {id="shipment-" .. tostring(state.shipmentCounter),
                requestId=pending.requestId,generation=pending.generation,item=shipmentItem,
                count=1,imported=0,verified=true,createdAt=io.now(),turn=pending.turn,session=pending.session,
                operatorBound=true}
            -- Clear the global quarantine exactly as ordinary recovery does.
            -- Other requests can have different details while sharing this
            -- error code; retaining any of them would prevent future service.
            local heldReason = state.quarantine.message
            for _, other in pairs(state.colonies) do
                for _, blocked in pairs(other.requests or {}) do
                    if blocked.errorCode == "PRS_QUARANTINE" then
                        blocked.status,blocked.detail,blocked.errorCode = "requested",
                            "PRS recovery verified; resuming outstanding quantity",nil
                    end
                end
                if other.error == heldReason then other.error=nil end
            end
            local record = cs.requests[pending.requestId]
            record.firstShipmentAt = record.firstShipmentAt or io.now()
            record.status,record.detail,record.errorCode = "in progress",
                "Operator-bound existing delivery; awaiting colony import",nil
            for _, job in pairs(state.craftJobs or {}) do
                if activeCraft(job) and matcher.exactlyMatches(job.item, pending.item) then
                    job.exported = integer(job.exported) + 1
                end
            end
            state.pendingTransfer, state.quarantine = nil,nil
            persist()
        end)
        if not saved then
            restore(state, held)
            data.revision = auditedRevision
            return false, "Binding could not be saved; audited export remains held: " .. tostring(saveError)
        end
        return true, "Existing item bound as one verified shipment; no additional PRS transfer was made"
    end

    return self
end

-- Explicit operator recovery for a held PRS export that definitely returned
-- zero but whose original full-chest baseline became unusable because unrelated
-- verified deliveries were drained before the delivery-lock protocol existed.
-- This path moves no items and credits no shipment.
function M.zeroExportRecovery(config, store, io, matcher)
    local self, reviewed = {}, nil

    local function quantity(value, minimum)
        return type(value)=="number" and value==value and value~=math.huge
            and value~=-math.huge and value%1==0 and value>=(minimum or 0)
    end

    local function findColony(id)
        local found
        for _,colony in ipairs(config.colonies or {}) do
            if tostring(colony.id)==tostring(id) then
                if found then return nil,"Colony route ID is ambiguous" end
                found=colony
            end
        end
        return found,found and nil or "Held colony route is no longer configured"
    end

    local function inspect()
        if config.role~="master" then return nil,"Zero-export acknowledgment is only available on the PRS Master" end
        local data=store.data
        local state=type(data)=="table" and data.master
        local pending=type(state)=="table" and state.pendingTransfer
        local quarantine=type(state)=="table" and state.quarantine
        if type(pending)~="table" or pending.kind~="export" then
            return nil,"No held PRS export exists"
        end
        if pending.reported~=0 or pending.intent then
            return nil,"Only a completed bridge call that explicitly returned 0 can use zero-export acknowledgment"
        end
        if pending.uncertain~=true or type(quarantine)~="table" or quarantine.code~="TRANSFER_VERIFY" then
            return nil,"The held export is not the active transfer-verification quarantine"
        end
        if type(pending.requestId)~="string" or pending.requestId=="" then
            return nil,"The held export has no stable request ID"
        end
        local colony,routeError=findColony(pending.colonyId)
        if not colony then return nil,routeError end
        if type(colony.deliveryChest)~="string" or colony.deliveryChest==""
            or colony.deliveryChest~=pending.chest then
            return nil,"The configured delivery route no longer matches the held export"
        end
        local cs=state.colonies and state.colonies[tostring(pending.colonyId)]
        if type(cs)~="table" then return nil,"The held colony ledger is missing" end
        if cs.turn then
            local internalRecovery =
                cs.turn.phase=="RECOVERY"
                and tostring(cs.turn.session)==tostring(pending.session)
                and tostring(cs.turn.id)==tostring(pending.turn)
            if not internalRecovery then
                return nil,"Wait for the colony's outstanding turn to finish before clearing the stale export"
            end
        end
        local record=cs.requests and cs.requests[pending.requestId]
        if type(record)~="table" or record.generation~=pending.generation
            or record.status=="delivered" then
            return nil,"The held export no longer matches its blocked request generation"
        end

        local items,chestError=io.snapshot(pending.chest)
        if type(items)~="table" then return nil,"Delivery chest is unreadable: "..tostring(chestError) end
        local total=0
        for slot,entry in pairs(items) do
            if type(slot)~="number" or not quantity(slot,1)
                or type(entry)~="table" or type(entry.count)~="number"
                or not quantity(entry.count,1) then
                return nil,"Delivery chest returned invalid inventory data"
            end
            total=total+entry.count
        end
        if total~=0 then
            return nil,"Delivery chest is not empty; zero-export acknowledgment would be unsafe"
        end

        if type(io.bridgeStatus)~="function" then return nil,"PRS connection verification is unavailable" end
        local bridge=io.bridgeStatus()
        if type(bridge)~="table" or bridge.connected~=true then
            return nil,"PRS connection is not confirmed: "..tostring(type(bridge)=="table" and bridge.error or "unknown")
        end
        local stock,stockError=io.stock()
        if type(stock)~="table" then return nil,"PRS stock is unreadable: "..tostring(stockError) end

        local review={
            colonyId=pending.colonyId,
            requestId=pending.requestId,
            item={name=pending.item and pending.item.name,nbt=copy(pending.item and pending.item.nbt)},
            count=pending.count,
            chest=pending.chest,
            reported=0,
            chestItems=0,
            confirmation="ZERO EXPORT",
        }
        local guard={
            master=copy(state),
            chestTest=copy(data.chestTest),
            config=copy(config),
            bridge={name=bridge.name,connected=true},
            chestEmpty=true,
        }
        return {review=review,guard=guard}
    end

    function self.previewZeroExport()
        reviewed=nil
        local ok,result,err=pcall(inspect)
        if not ok then return nil,"Cannot review held export: "..tostring(result) end
        if not result then return nil,err end
        reviewed=result
        return copy(result.review)
    end

    function self.reconcileZeroExport(confirmation)
        if not reviewed or confirmation~=reviewed.review.confirmation then
            return false,"Review the held export and type the exact ZERO EXPORT confirmation"
        end
        local ok,fresh,err=pcall(inspect)
        if not ok then return false,"Cannot recheck held export: "..tostring(fresh) end
        if not fresh then reviewed=nil;return false,err end
        if not equal(fresh.guard,reviewed.guard) then
            reviewed=nil
            return false,"The master journal, route, bridge or chest changed after review; review again"
        end
        reviewed=nil

        local data,state=store.data,store.data.master
        local pending=state.pendingTransfer
        local held=copy(state)
        local oldHistory=copy(data.history or {})
        local oldRevision=data.revision
        local function persist()
            local saved,saveError=store.save()
            if saved~=true then error("Zero-export acknowledgment could not be saved: "..tostring(saveError),0) end
        end

        local saved,saveError=pcall(function()
            data.history=data.history or {}
            data.history[#data.history+1]={
                time=tonumber(pending.startedAt) or 0,kind="OPERATOR_ZERO_EXPORT",
                message="Operator confirmed held PRS export moved zero items; stale chest baseline discarded",
                context={
                    colonyId=pending.colonyId,requestId=pending.requestId,
                    item=pending.item and pending.item.name,count=pending.count,
                    chest=pending.chest,reported=0,confirmation=confirmation
                }
            }
            while #data.history>math.max(1,integer(config.maxHistoryEntries or 400)) do
                table.remove(data.history,1)
            end

            local heldReason=state.quarantine and state.quarantine.message
            if cs.turn and cs.turn.phase=="RECOVERY" then cs.turn=nil end
            for _,other in pairs(state.colonies or {}) do
                for _,blocked in pairs(other.requests or {}) do
                    if blocked.errorCode=="PRS_QUARANTINE" then
                        blocked.status,blocked.detail,blocked.errorCode=
                            "requested","Zero-movement export acknowledged; retrying from a clean chest",nil
                    end
                end
                if other.error==heldReason then other.error=nil;other.errorSource=nil end
            end
            state.pendingTransfer,state.quarantine=nil,nil
            persist()
        end)

        if not saved then
            restore(state,held)
            data.history,data.revision=oldHistory,oldRevision
            return false,"Zero-export acknowledgment was not saved; hold retained: "..tostring(saveError)
        end
        return true,"Zero export acknowledged; no shipment credited. Restart the Master to retry from the empty chest."
    end

    return self
end

return M