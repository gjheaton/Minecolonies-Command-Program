-- Dedicated supply client. Only the master owns player Refined Storage.
local M = {}

local function amount(value)
    return math.max(0, math.floor(tonumber(value) or 0))
end

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local out = {}
    seen[value] = out
    for key, child in pairs(value) do out[copy(key, seen)] = copy(child, seen) end
    return out
end

local function requestCount(request)
    local count = amount(request.count)
    if count == 0 then count = amount(request.minCount) end
    if count == 0 then
        for _, item in pairs(type(request.items) == "table" and request.items or {}) do
            if type(item) == "table" then count = math.max(count, amount(item.count)) end
        end
    end
    return count
end

local STATUSES = {
    requested = true, ["in progress"] = true, ["timed out"] = true,
    missing = true, crafting = true, error = true,
}

local BUILDING_PATTERNS = {
    "^cobblestone$", "_cobblestone$", "^stone$", "^sandstone$", "_sandstone$",
    "^bricks$", "_bricks$", "_brick$", "_planks$", "_log$", "_wood$", "_stem$", "_hyphae$",
    "^dirt$", "_dirt$", "^mud$", "_mud$", "^sand$", "_sand$", "^gravel$", "_gravel$",
    "^glass$", "_glass$", "_glass_pane$", "^terracotta$", "_terracotta$", "_concrete$",
    "_concrete_powder$", "^deepslate$", "_deepslate$", "^tuff$", "_tuff$", "^blackstone$",
    "_blackstone$", "^netherrack$", "^end_stone$", "_slab$", "_stairs$", "_wall$",
}

-- Explicit operator recovery is separate from engine startup: inspecting or
-- cancelling a preview must not rewrite a held intent or its fault.
function M.zeroImportRecovery(config, store, io, matcher)
    local self, previewGuard = {}, nil
    local allowedFaults = { IMPORT_UNCERTAIN = true, TRANSFER_DESYNC = true, TRANSFER_UNCERTAIN = true }
    local function quantity(value, minimum)
        return type(value) == "number" and value == value
            and value ~= math.huge and value ~= -math.huge
            and value % 1 == 0 and value >= (minimum or 0)
    end
    local function equal(a, b, seen)
        if type(a) ~= type(b) then return false end
        if type(a) ~= "table" then return a == b end
        seen = seen or {}
        if seen[a] and seen[a][b] then return true end
        seen[a] = seen[a] or {}; seen[a][b] = true
        for key, value in pairs(a) do if not equal(value, b[key], seen) then return false end end
        for key in pairs(b) do if a[key] == nil then return false end end
        return true
    end
    local function inspect(shipmentId)
        if config.role ~= "supply" then return nil, "Zero-import acknowledgment is only available on colony supply computers" end
        if (type(shipmentId) ~= "string" and type(shipmentId) ~= "number") or tostring(shipmentId) == "" then
            return nil, "Supply the exact held shipment ID"
        end
        local id, data = tostring(shipmentId), store.data.client
        if #id > 256 then return nil, "The held shipment ID exceeds the recovery limit" end
        if type(data) ~= "table" or type(data.intent) ~= "table" then return nil, "No interrupted colony import is held" end
        local intent, fault = data.intent, data.fault
        if intent.kind ~= "import" or intent.reported ~= nil or tostring(intent.shipmentId) ~= id then
            return nil, "Only the exact held import with an unknown bridge return can receive this acknowledgment"
        end
        if type(fault) ~= "table" or not allowedFaults[fault.code] then
            return nil, "The active fault is not this interrupted import; reconcile it separately"
        end
        if type(data.turn) ~= "table" or data.turn.phase ~= "finished" then
            return nil, "Wait for the master result to close the reserved turn before repairing"
        end
        if type(config.deliveryChestName) ~= "string" or config.deliveryChestName == ""
            or intent.chest ~= config.deliveryChestName then
            return nil, "The configured delivery chest differs from the original import chest"
        end
        if not quantity(intent.count, 1) or not quantity(intent.beforeChest)
            or intent.beforeChest < intent.count or not quantity(intent.beforeImported) then
            return nil, "The interrupted import has invalid original quantities"
        end
        local shipments = data.shipments
        local shipment = type(shipments) == "table" and shipments[id]
        if type(shipment) ~= "table" or type(shipment.id) ~= "string" or shipment.id ~= id or shipment.verified ~= true
            or type(shipment.requestId) ~= "string" or shipment.requestId == ""
            or not quantity(shipment.count, 1) or not quantity(shipment.imported)
            or shipment.imported ~= intent.beforeImported or intent.count > shipment.count - shipment.imported then
            return nil, "The retained shipment ledger no longer agrees with the original import"
        end
        if type(intent.item) ~= "table" or type(intent.item.name) ~= "string" or intent.item.name == ""
            or type(shipment.item) ~= "table" or type(shipment.item.name) ~= "string"
            or matcher.itemIdentity(intent.item) ~= matcher.itemIdentity(shipment.item) then
            return nil, "The interrupted import does not match the verified shipment's exact item and NBT"
        end
        if type(io.bridgeStatus) ~= "function" then return nil, "Cannot verify the colony RS connection" end
        local bridge = io.bridgeStatus()
        if type(bridge) ~= "table" or bridge.connected ~= true then
            return nil, "Restore the colony RS connection first: " .. tostring(type(bridge) == "table" and bridge.error or "connection unknown")
        end
        local stock, stockError = io.colonyStock()
        if type(stock) ~= "table" then return nil, "Cannot read the restored colony warehouse: " .. tostring(stockError) end
        local items, chestError = io.snapshot(intent.chest)
        if type(items) ~= "table" then return nil, "Cannot inspect the original delivery chest: " .. tostring(chestError) end
        local current = io.count(items, intent.item)
        if not quantity(current) or current ~= intent.beforeChest then
            return nil, "The exact source item quantity changed; a zero-movement acknowledgment is unsafe"
        end
        local outstanding = {}
        for key, delivery in pairs(shipments) do
            if type(delivery) ~= "table" or delivery.verified ~= true
                or type(key) ~= "string" or type(delivery.id) ~= "string" or key ~= delivery.id
                or type(delivery.requestId) ~= "string" or delivery.requestId == ""
                or not quantity(delivery.count, 1) or not quantity(delivery.imported)
                or delivery.imported > delivery.count or type(delivery.item) ~= "table"
                or type(delivery.item.name) ~= "string" or delivery.item.name == "" then
                return nil, "A retained shipment has an invalid item or quantity; inspect its ledger separately"
            end
            local key = matcher.itemIdentity(delivery.item)
            local required = outstanding[key] or { item = delivery.item, count = 0 }
            required.count = required.count + delivery.count - delivery.imported
            outstanding[key] = required
        end
        for _, required in pairs(outstanding) do
            local present = io.count(items, required.item)
            if not quantity(present) or not quantity(required.count) or present < required.count then
                return nil, "A verified shipment is missing from the delivery chest; restore it before acknowledging zero movement"
            end
        end
        local preview = {
            shipmentId = id, requestId = shipment.requestId, chest = intent.chest,
            item = { name = intent.item.name, displayName = intent.item.displayName, nbt = copy(intent.item.nbt) },
            count = intent.count, beforeChest = intent.beforeChest, currentChest = current,
            beforeImported = intent.beforeImported, imported = shipment.imported,
            bridgeName = bridge.name, session = intent.session, turn = intent.turn,
            confirmation = "ZERO " .. id,
        }
        local guard = { intent = copy(intent), shipment = copy(shipment), fault = copy(fault),
            chest = config.deliveryChestName, configuredBridge = config.colonyBridgeName, bridgeName = bridge.name }
        return preview, guard
    end
    local function checkedInspect(shipmentId)
        local ok, preview, guard = pcall(inspect, shipmentId)
        if not ok then return nil, "Cannot verify the held import: " .. tostring(preview) end
        return preview, guard
    end
    local function persist()
        local ok, result, err = pcall(store.save)
        if not ok then return false, tostring(result) end
        if result ~= true then return false, tostring(err or "Journal save did not confirm durability") end
        return true
    end
    function self.previewZeroImport(shipmentId)
        previewGuard = nil
        local preview, guard = checkedInspect(shipmentId)
        if not preview then return nil, guard end
        previewGuard = guard
        return preview
    end
    function self.reconcileZeroImport(shipmentId, confirmation)
        if not previewGuard or type(confirmation) ~= "string" or confirmation ~= "ZERO " .. tostring(shipmentId) then
            return false, "Preview the exact held shipment and enter its zero-movement confirmation first"
        end
        local preview, guard = checkedInspect(shipmentId)
        if not preview then return false, guard end
        if not equal(guard, previewGuard) then return false, "The held import changed after preview; inspect a fresh preview" end
        local data, history = store.data.client, store.data.history
        if type(history) ~= "table" then return false, "The audit history is invalid; restore persistence before repairing" end
        local function auditValue(value)
            if type(value) == "string" then return value:sub(1, 256) end
            if type(value) == "number" or type(value) == "boolean" then return value end
        end
        local identity = matcher.itemIdentity(preview.item)
        local nextHistory = copy(history)
        nextHistory[#nextHistory + 1] = {
            time = io.now(), kind = "OPERATOR_ZERO_IMPORT",
            message = "Operator acknowledged zero movement for a held colony import; no imported quantity credited",
            context = { shipmentId = preview.shipmentId, requestId = auditValue(preview.requestId), chest = auditValue(preview.chest),
                item = { name = auditValue(preview.item.name) }, itemIdentity = identity:sub(1, 256),
                itemIdentityLength = #identity, itemIdentityTruncated = #identity > 256,
                count = preview.count, beforeChest = preview.beforeChest,
                currentChest = preview.currentChest, beforeImported = preview.beforeImported,
                session = auditValue(preview.session), turn = auditValue(preview.turn), bridgeName = auditValue(preview.bridgeName),
                operatorConfirmation = confirmation },
        }
        while #nextHistory > math.max(1, amount(config.maxHistoryEntries or 400)) do table.remove(nextHistory, 1) end
        store.data.history = nextHistory
        local audited, auditError = persist()
        if not audited then store.data.history = history; return false, "Cannot persist the operator acknowledgment: " .. auditError end
        local intent, fault = data.intent, data.fault
        data.intent, data.fault = nil, nil
        local cleared, clearError = persist()
        if not cleared then
            data.intent, data.fault = intent, fault
            return false, "Operator acknowledgment saved; import remains held because clearing it could not be persisted: " .. clearError
        end
        previewGuard = nil
        return true, "Zero movement acknowledged; shipment quantities unchanged and the next normal turn may import the retained items"
    end
    return self
end

function M.new(config, store, io, matcher)
    local self = {}
    store.data.client = type(store.data.client) == "table" and store.data.client or {}
    local data = store.data.client
    data.requests = type(data.requests) == "table" and data.requests or {}
    data.shipments = type(data.shipments) == "table" and data.shipments or {}
    data.retiredSessions = type(data.retiredSessions) == "table" and data.retiredSessions or {}
    data.seenTurns = type(data.seenTurns) == "table" and data.seenTurns or {}
    data.cursor = amount(data.cursor)
    local nextHello, nextRetry = 0, 0
    local lastContact
    local masterConnection
    local persistenceError

    local function setting(key, default)
        local policy = data.turn and data.turn.policy
        if type(policy) == "table" and policy[key] ~= nil then return policy[key] end
        local settings = store.data.settings
        if type(settings) == "table" and settings[key] ~= nil then return settings[key] end
        if config[key] ~= nil then return config[key] end
        return default
    end

    local function save()
        local ok, err = store.save()
        if ok == false or ok == nil then
            persistenceError = "Cannot persist supply state: " .. tostring(err or "unknown failure")
            return false
        end
        persistenceError = nil
        return true
    end

    local function fault(code, message, context)
        data.fault = { code = code, message = tostring(message), time = io.now() }
        store.error(code, message, context)
        save()
    end

    local function send(message)
        message.version = 1
        return io.send(tonumber(config.masterId), message)
    end

    local function clientError()
        return persistenceError or (data.fault and data.fault.message)
    end

    -- An interrupted call cannot safely be replayed: a courier may already
    -- have consumed warehouse stock, hiding its destination inventory delta.
    if type(data.intent) == "table" then
        fault("IMPORT_UNCERTAIN", "An interrupted chest transfer needs reconciliation; automatic transfers are paused", data.intent)
    end

    local function sameItem(a, b)
        return type(a) == "table" and type(b) == "table"
            and matcher.itemIdentity(a) == matcher.itemIdentity(b)
    end

    local function shipmentList(deliveries)
        if deliveries == nil then return true end
        if type(deliveries) ~= "table" then
            fault("BAD_DELIVERY", "Master supplied invalid delivery records")
            return false
        end
        for _, shipment in pairs(deliveries) do
            if type(shipment) ~= "table" or shipment.id == nil
                or shipment.requestId == nil or shipment.verified ~= true
                or type(shipment.item) ~= "table" or type(shipment.item.name) ~= "string"
                or shipment.item.name == "" or amount(shipment.count) == 0 then
                fault("BAD_DELIVERY", "Master supplied an unverified or incomplete delivery record")
                return false
            end
            local id = tostring(shipment.id)
            local current = data.shipments[id]
            if current and (not sameItem(current.item, shipment.item)
                or current.count ~= amount(shipment.count)
                or current.requestId ~= tostring(shipment.requestId)) then
                fault("DELIVERY_CHANGED", "A verified shipment identity or quantity changed", { id = id })
                return false
            end
            if not current then
                current = copy(shipment)
                current.id = id
                current.requestId = tostring(shipment.requestId)
                current.count = amount(shipment.count)
                current.imported = 0
                current.createdAt = tonumber(shipment.createdAt) or io.now()
                data.shipments[id] = current
            end
        end
        return save()
    end

    local function shipmentTotals(requestId)
        local imported, staged = 0, 0
        for _, shipment in pairs(data.shipments) do
            if shipment.requestId == requestId then
                imported = imported + amount(shipment.imported)
                staged = staged + math.max(0, shipment.count - amount(shipment.imported))
            end
        end
        return imported, staged
    end

    local function imports()
        local out = {}
        for id, shipment in pairs(data.shipments) do out[id] = amount(shipment.imported) end
        return out
    end

    local function readRequests()
        local requests, err = io.requests()
        if type(requests) ~= "table" then return nil, err or "getRequests returned no authoritative snapshot" end
        local active, now = {}, io.now()
        for _, request in pairs(requests) do
            if type(request) ~= "table" or request.id == nil then
                return nil, "getRequests contains a request without a stable ID"
            end
            local id = tostring(request.id)
            if id == "" or active[id] then return nil, "getRequests contains an invalid or duplicate request ID" end
            active[id] = request
        end
        for id, request in pairs(active) do
            local record = data.requests[id]
            if not record or record.active == false then
                -- IDs are expected to identify one MineColonies request. If an
                -- ID is reused, its physical ledger stays intact and blocks
                -- automatic replenishment rather than duplicating shipments.
                record = record or { id = id, firstSeen = now, status = "requested", phase = "requested", phaseSince = now }
                if record.active == false then
                    record.status, record.phase = "error", "error"
                    record.detail = "MineColonies reused a completed request ID; inspect its retained delivery ledger"
                end
                data.requests[id] = record
            end
            record.active = true
            record.raw = copy(request)
            record.raw.id = id
            record.count = requestCount(request)
            record.totalCount = math.max(amount(record.totalCount), record.count)
            record.name = tostring(request.name or request.displayName or id)
            record.lastSeen = now
        end
        for id, record in pairs(data.requests) do
            if record.active ~= false and not active[id] then
                record.active = false
                record.status, record.phase = "delivered", "delivered"
                record.completedAt = now
                record.detail = "Request disappeared from an authoritative MineColonies snapshot"
                store.event("DELIVERED", record.detail, { requestId = id })
            end
        end
        data.lastRequestScan = now
        if not save() then return nil, persistenceError end
        return active
    end

    local function activeIds(active)
        local ids = {}
        for id in pairs(active) do ids[#ids + 1] = id end
        table.sort(ids)
        return ids
    end

    local function selectedRequests(active)
        local ids = activeIds(active)
        local eligible = {}
        for _, id in ipairs(ids) do
            if data.requests[id].count > 0 then eligible[#eligible + 1] = id end
        end
        local out = {}
        if #eligible == 0 then return out end
        local limit = math.min(#eligible, amount(setting("maxRequestsPerTurn", 8)))
        local start = data.cursor % #eligible
        for offset = 1, limit do
            local id = eligible[(start + offset - 1) % #eligible + 1]
            local record = data.requests[id]
            local request = copy(record.raw)
            request.firstSeen = record.firstSeen
            request.totalCount = record.totalCount
            request.imported, request.staged = shipmentTotals(id)
            out[#out + 1] = request
        end
        data.cursor = (start + limit) % #eligible
        return out
    end

    local function chestSnapshot(name)
        local items, err = io.snapshot(name)
        if type(items) ~= "table" then return nil, err or "inventory unavailable" end
        return items
    end

    local function transfer(kind, shipment, item, count, chest)
        local before, err = chestSnapshot(chest)
        if not before then return nil, err end
        local baseline = amount(io.count(before, item))
        local intent = {
            kind = kind, shipmentId = shipment and shipment.id,
            item = copy(item), count = count, chest = chest,
            beforeChest = baseline, startedAt = io.now(),
            beforeImported = shipment and amount(shipment.imported),
            session = data.turn.session, turn = data.turn.turn,
        }
        data.intent = intent
        if not save() then return nil, persistenceError end
        local fn = kind == "import" and io.importColony or io.exportColony
        local ok, reported, callError = pcall(fn, item, count, chest)
        if not ok then callError, reported = reported, nil end
        intent.reported = type(reported) == "number" and reported or nil
        intent.callError = callError and tostring(callError) or nil
        -- This second save preserves the return value if physical verification
        -- fails. Never clear the write-ahead intent before quantity accounting.
        if not save() then return nil, persistenceError end
        local after, snapshotError = chestSnapshot(chest)
        local timeout = math.max(0, tonumber(setting("transferVerifyTimeoutSeconds", 5)) or 5)
        local interval = math.max(0.05, tonumber(setting("transferPollSeconds", 0.25)) or 0.25)
        local deadline = io.now() + timeout
        local remainingReads = math.ceil(timeout / interval)
        -- Inventory events can trail the bridge's synchronous return. Only
        -- read during this wait; never repeat the source mutation.
        while type(io.wait) == "function" and remainingReads > 0 and io.now() < deadline
            and type(reported) == "number" and reported == amount(reported) and reported <= count do
            local observed = after and amount(io.count(after, item))
            local delta = observed and (kind == "import" and baseline - observed or observed - baseline)
            if delta == reported or (delta and (delta < 0 or delta > reported)) then break end
            io.wait(math.min(interval, math.max(0, deadline - io.now())))
            remainingReads = remainingReads - 1
            after, snapshotError = chestSnapshot(chest)
        end
        if not after then
            fault("TRANSFER_UNCERTAIN", "Unable to verify chest after colony transfer", { intent = intent, error = snapshotError })
            return nil, snapshotError
        end
        local physical = amount(io.count(after, item))
        local delta = kind == "import" and baseline - physical or physical - baseline
        if type(reported) ~= "number" or reported ~= amount(reported)
            or reported > count or delta < 0 or delta ~= reported then
            fault("TRANSFER_DESYNC", "Colony bridge result does not match the chest inventory change", {
                intent = intent, reported = reported, actualDelta = delta, error = callError,
            })
            return nil, "unverified transfer"
        end
        if shipment then shipment.imported = amount(shipment.imported) + delta end
        data.intent = nil
        if not save() then
            -- Retain the marker in memory as well; a retry cannot mutate the
            -- chest merely because the final accounting write failed.
            data.intent = intent
            return nil, persistenceError
        end
        if delta > 0 then
            store.event(kind == "import" and "IMPORTED" or "RETURN_STAGED", "Verified colony chest transfer", {
                shipmentId = shipment and shipment.id, requestId = shipment and shipment.requestId,
                item = item.name, count = delta,
            })
        end
        return delta
    end

    local function drainDeliveries()
        if clientError() or data.intent then return end
        local left = amount(setting("maxImportsPerTurn", 256))
        local shipments = {}
        for _, shipment in pairs(data.shipments) do
            if shipment.verified == true and amount(shipment.imported) < shipment.count then
                shipments[#shipments + 1] = shipment
            end
        end
        table.sort(shipments, function(a, b)
            if a.createdAt ~= b.createdAt then return a.createdAt < b.createdAt end
            return a.id < b.id
        end)
        for _, shipment in ipairs(shipments) do
            if left <= 0 then break end
            local items, err = chestSnapshot(config.deliveryChestName)
            if not items then
                fault("DELIVERY_CHEST", "Cannot read the delivery chest", { error = err })
                return
            end
            local available = amount(io.count(items, shipment.item))
            if available == 0 then
                -- Absence is not proof of import: somebody may have removed it.
                fault("DELIVERY_MISSING", "A verified delivery is missing from its reserved chest", { shipmentId = shipment.id })
                return
            end
            local count = math.min(left, amount(setting("maxTransferChunk", 64)), available,
                shipment.count - amount(shipment.imported))
            if count > 0 then
                local moved, transferError = transfer("import", shipment, shipment.item, count, config.deliveryChestName)
                if moved == nil then
                    if not clientError() then fault("COLONY_IMPORT", transferError or "Colony import failed", { shipmentId = shipment.id }) end
                    return
                end
                left = left - moved
            end
        end
    end

    local function protects(item, active)
        for _, request in pairs(active) do
            if matcher.requestAcceptsItem(request, item) then return true end
        end
        return false
    end

    local function keepCount(item)
        local keep = setting("keepCounts", {})
        local explicit = type(keep) == "table" and (keep[matcher.itemIdentity(item)] or keep[item.name])
        if explicit ~= nil then return amount(explicit) end
        local path = tostring(item.name):match("^[^:]+:(.+)$") or tostring(item.name)
        for _, pattern in ipairs(config.buildingItemPatterns or BUILDING_PATTERNS) do
            if path:match(pattern) then return amount(setting("buildingItemKeep", 1024)) end
        end
        return amount(setting("defaultItemKeep", 128))
    end

    local function stageOverflow(active)
        if setting("overflowEnabled", false) ~= true or clientError() or data.intent then return end
        if not config.returnChestName or config.returnChestName == config.deliveryChestName then
            fault("RETURN_CHANNEL", "Overflow needs a separate return chest channel")
            return
        end
        local stock, err = io.colonyStock()
        if type(stock) ~= "table" then
            fault("COLONY_STOCK", "Cannot safely inspect colony stock for overflow", { error = err })
            return
        end
        local left = amount(setting("maxReturnItemsPerTurn", 128))
        local entries = {}
        for _, item in pairs(stock) do if type(item) == "table" and item.name then entries[#entries + 1] = item end end
        table.sort(entries, function(a, b) return matcher.itemIdentity(a) < matcher.itemIdentity(b) end)
        for _, item in ipairs(entries) do
            if left <= 0 then break end
            local surplus = math.max(0, amount(item.amount or item.count) - keepCount(item))
            if surplus > 0 and not protects(item, active) then
                local chest, chestError = chestSnapshot(config.returnChestName)
                if not chest then fault("RETURN_CHEST", "Cannot inspect the return chest", { error = chestError }); return end
                local free = amount(io.capacity(config.returnChestName, chest, item, amount(setting("chestReserveSlots", 1))))
                local count = math.min(surplus, left, free, amount(setting("maxTransferChunk", 64)))
                if count > 0 then
                    local moved, transferError = transfer("return", nil, item, count, config.returnChestName)
                    if moved == nil then
                        if not clientError() then fault("COLONY_RETURN", transferError or "Colony return failed") end
                        return
                    end
                    left = left - moved
                end
            end
        end
    end

    local function batchForTurn()
        drainDeliveries()
        local active, err = readRequests()
        if not active then
            -- No activeIds is intentional: an unsuccessful scan must never
            -- tell the master that all requests disappeared.
            return {
                kind = "batch", session = data.turn.session, turn = data.turn.turn,
                requests = {}, imports = imports(), clientError = clientError() or tostring(err),
                authoritative = false,
            }
        end
        stageOverflow(active)
        local name = io.colonyName()
        data.colonyName = type(name) == "string" and name or data.colonyName
        return {
            kind = "batch", session = data.turn.session, turn = data.turn.turn,
            requests = selectedRequests(active), activeIds = activeIds(active),
            imports = imports(), colonyName = data.colonyName,
            authoritative = true, clientError = clientError(),
        }
    end

    local function acknowledge(turn)
        send({ kind = "received", session = turn.session, turn = turn.turn })
    end

    local function applyResults(results)
        if type(results) ~= "table" then return end
        for key, response in pairs(results) do
            if type(response) == "table" then
                local id = tostring(response.requestId or response.id or key)
                local record = data.requests[id]
                if record and record.active ~= false then
                    local status = tostring(response.status or "error")
                    if not STATUSES[status] then status = "error" end
                    if record.phase ~= status then record.phaseSince = io.now() end
                    record.phase, record.status = status, status
                    record.detail = tostring(response.detail or response.message or "")
                    record.lastResponse = io.now()
                    record.master = copy(response)
                    if status == "crafting" and not record.craftStartedAt then record.craftStartedAt = io.now() end
                    if status == "in progress" and not record.deliveryStartedAt then record.deliveryStartedAt = io.now() end
                end
            end
        end
    end

    local function compactCompleted(results)
        -- A delivered result proves the master durably accepted both the
        -- authoritative disappearance and our cumulative import receipts.
        -- Keep active and partially imported shipments even if they are old.
        for key, response in pairs(type(results) == "table" and results or {}) do
            if type(response) == "table" and response.status == "delivered" then
                local id = tostring(response.requestId or response.id or key)
                local record = data.requests[id]
                if record and record.active == false then record.masterCompletedSeen = true end
            end
        end
        for id, shipment in pairs(data.shipments) do
            local record = data.requests[shipment.requestId]
            if record and record.active == false and record.masterCompletedSeen
                and amount(shipment.imported) == shipment.count then
                data.shipments[id] = nil
            end
        end
        local withShipments = {}
        for _, shipment in pairs(data.shipments) do withShipments[shipment.requestId] = true end
        local completed = {}
        for id, record in pairs(data.requests) do
            if record.active == false and record.masterCompletedSeen and not withShipments[id] then
                completed[#completed + 1] = record
            end
        end
        table.sort(completed, function(a, b)
            local aTime, bTime = tonumber(a.completedAt) or io.now(), tonumber(b.completedAt) or io.now()
            if aTime ~= bTime then return aTime < bTime end
            return a.id < b.id
        end)
        local retention = math.max(0, tonumber(setting("requestRetentionSeconds", 86400)) or 86400)
        local maximum = amount(setting("maxCompletedRequests", 1000))
        local excess = math.max(0, #completed - maximum)
        for index, record in ipairs(completed) do
            if index <= excess or io.now() - (tonumber(record.completedAt) or io.now()) >= retention then
                data.requests[record.id] = nil
            end
        end
    end

    function self.onMessage(sender, message)
        if tonumber(sender) ~= tonumber(config.masterId) or type(message) ~= "table" or message.version ~= 1 then return false end
        if message.kind == "hello_ack" then
            if type(message.routeConfirmed) ~= "boolean" or type(message.automationEnabled) ~= "boolean"
                or message.error ~= nil and (type(message.error) ~= "string" or #message.error > 512) then return false end
            lastContact = io.now()
            masterConnection = {
                routeConfirmed = message.routeConfirmed,
                automationEnabled = message.automationEnabled,
                error = message.error,
                receivedAt = lastContact,
            }
            return true
        end
        local session = message.session and tostring(message.session)
        local turnId = message.turn and tostring(message.turn)
        if message.kind ~= "turn" and message.kind ~= "result" then return false end
        if not session or session == "" or not turnId or turnId == "" then return false end
        lastContact, data.lastContact = io.now(), io.now()
        if message.kind == "result" then
            local turn = data.turn
            if not turn or tostring(turn.session) ~= session or tostring(turn.turn) ~= turnId then return false end
            if turn.phase == "finished" then
                compactCompleted(turn.result and turn.result.requests)
                if save() then acknowledge(turn) end
                return true
            end
            if turn.phase ~= "waiting" then return false end
            if not shipmentList(message.deliveries) then return false end
            applyResults(message.requests)
            turn.result = copy(message)
            turn.phase, turn.finishedAt = "finished", io.now()
            if save() then
                compactCompleted(message.requests)
                if save() then acknowledge(turn) end
            end
            return true
        end
        if data.retiredSessions[session] then return false end
        local current = data.turn
        if current and tostring(current.session) == session and tostring(current.turn) == turnId then
            if current.phase == "waiting" and current.batch and save() then send(copy(current.batch)) end
            if current.phase == "finished" and save() then acknowledge(current) end
            return true
        end
        if current and current.phase ~= "finished" then
            -- A new grant cannot revoke a live reservation safely. Finish the
            -- existing handshake first, including across master restarts.
            return false
        end
        if data.session ~= session then
            if data.session then data.retiredSessions[tostring(data.session)] = true end
            data.session, data.seenTurns = session, {}
            data.highestTurn = nil
        end
        if data.seenTurns[turnId] then return false end
        local numericTurn = tonumber(turnId)
        if numericTurn and data.highestTurn and numericTurn <= data.highestTurn then return false end
        if numericTurn then data.highestTurn = numericTurn
        else data.seenTurns[turnId] = true end
        data.turn = {
            session = message.session, turn = message.turn,
            policy = type(message.policy) == "table" and copy(message.policy) or {},
            phase = "preparing", startedAt = io.now(),
        }
        -- Persist the reservation before touching either Ender Chest. A
        -- restarted preparing turn is blocked instead of repeating mutations.
        if not save() then return false end
        shipmentList(message.deliveries)
        data.turn.batch = batchForTurn()
        data.turn.phase = "waiting"
        if save() then
            send(copy(data.turn.batch))
            nextRetry = io.now() + math.max(0.1, tonumber(setting("batchRetrySeconds", 5)) or 5)
        end
        return true
    end

    -- An interrupted preparation may have completed an import but not its
    -- batch. Never repeat the preparation; send a read-only error batch.
    if data.turn and data.turn.phase == "preparing" then
        fault("TURN_INTERRUPTED", "Turn preparation was interrupted; transfers need reconciliation")
        data.turn.batch = {
            kind = "batch", session = data.turn.session, turn = data.turn.turn,
            requests = {}, imports = imports(), authoritative = false,
            clientError = clientError(),
        }
        data.turn.phase = "waiting"
        save()
    end

    function self.tick()
        local now = io.now()
        if now >= nextHello then
            send({ kind = "hello", role = "supply", colonyName = data.colonyName,
                deliveryChestName = config.deliveryChestName, returnChestName = config.returnChestName,
                deliveryChannel = config.deliveryChannel, returnChannel = config.returnChannel,
                clientError = clientError(), session = data.turn and data.turn.session,
                turn = data.turn and data.turn.turn })
            nextHello = now + math.max(0.1, tonumber(setting("helloSeconds", 5)) or 5)
        end
        local turn = data.turn
        if turn and turn.phase == "waiting" and turn.batch and now >= nextRetry then
            if save() then send(copy(turn.batch)) end
            nextRetry = now + math.max(0.1, tonumber(setting("batchRetrySeconds", 5)) or 5)
        end
        for _, record in pairs(data.requests) do
            if record.active ~= false then
                local phase = record.phase or "requested"
                local since, timeout
                if phase == "crafting" then
                    since = record.craftStartedAt or record.phaseSince
                    timeout = tonumber(setting("craftingTimeoutSeconds", 600))
                elseif phase == "in progress" then
                    since = record.deliveryStartedAt or record.phaseSince
                    timeout = tonumber(setting("acknowledgementTimeoutSeconds", 600))
                    local imported, staged = shipmentTotals(record.id)
                    if imported == 0 or staged > 0 then timeout = tonumber(setting("onHandTimeoutSeconds", 120)) end
                elseif phase == "requested" then
                    since = record.phaseSince or record.firstSeen
                    timeout = tonumber(setting("onHandTimeoutSeconds", 120))
                end
                record.status = phase
                if timeout and timeout > 0 and since and now - since >= timeout then
                    record.status = "timed out"
                    record.timeoutDetail = phase == "crafting" and "Crafting deadline exceeded; existing work retained"
                        or "Delivery acknowledgement deadline exceeded; existing quantities retained"
                end
            end
        end
    end

    function self.busy()
        return data.intent ~= nil or (data.turn ~= nil and data.turn.phase ~= "finished")
    end

    function self.canUpdate()
        if self.busy() then return false, "Finish or reconcile the reserved colony turn before updating" end
        return true
    end

    function self.canProbe()
        if clientError() then return false, clientError() end
        return self.canUpdate()
    end

    function self.reconcile()
        if data.turn and data.turn.phase ~= "finished" then
            return false, "Wait for the master result to close the reserved turn before repairing"
        end
        local intent = data.intent
        local shipment, oldImported
        if intent then
            local reported = intent.reported
            if type(reported) ~= "number" or reported ~= amount(reported) or reported > amount(intent.count) then
                return false, "The interrupted bridge call has no reliable return value; inspect the chest and warehouse manually"
            end
            local items, err = chestSnapshot(intent.chest)
            if not items then return false, "Cannot inspect interrupted transfer chest: " .. tostring(err) end
            local current = amount(io.count(items, intent.item))
            local delta = intent.kind == "import" and amount(intent.beforeChest) - current or current - amount(intent.beforeChest)
            if delta ~= reported then
                return false, "The bridge result still differs from the physical chest quantity; automatic repair is unsafe"
            end
            if intent.kind == "import" then
                shipment = data.shipments[tostring(intent.shipmentId)]
                if not shipment or not sameItem(shipment.item, intent.item) or intent.beforeImported == nil then
                    return false, "The interrupted import lacks its original shipment ledger; inspect it manually"
                end
                local before = amount(intent.beforeImported)
                oldImported = amount(shipment.imported)
                if oldImported ~= before and oldImported ~= before + reported then
                    return false, "The retained shipment ledger does not agree with the interrupted import"
                end
                if before + reported > shipment.count then return false, "Repair would exceed the verified shipment quantity" end
                shipment.imported = before + reported
            elseif intent.kind ~= "return" then
                return false, "Unknown interrupted transfer kind; automatic repair is unsafe"
            end
        end
        -- Without a write-ahead intent, clearing a read/verification fault is
        -- safe only if every acknowledged-but-unimported shipment still exists.
        local items, err = chestSnapshot(config.deliveryChestName)
        if not items then
            if shipment then shipment.imported = oldImported end
            return false, "Cannot inspect the delivery chest: " .. tostring(err)
        end
        local outstanding = {}
        for _, delivery in pairs(data.shipments) do
            local key = matcher.itemIdentity(delivery.item)
            outstanding[key] = outstanding[key] or { item = delivery.item, count = 0 }
            outstanding[key].count = outstanding[key].count + math.max(0, delivery.count - amount(delivery.imported))
        end
        for _, required in pairs(outstanding) do
            if amount(io.count(items, required.item)) < required.count then
                if shipment then shipment.imported = oldImported end
                return false, "A verified shipment is still missing; restore or manually reconcile it before repairing"
            end
        end
        local previousFault = data.fault
        data.intent, data.fault = nil, nil
        if not save() then
            data.intent, data.fault = intent, previousFault
            if shipment then shipment.imported = oldImported end
            return false, persistenceError
        end
        store.event("RECONCILED", "Physical chest quantities agree with the retained shipment ledger; transfers may resume")
        return true, "Chest quantities reconciled without repeating any transfer"
    end

    function self.snapshot()
        local rows = {}
        for id, record in pairs(data.requests) do
            if record.active ~= false then
                local row = copy(record)
                row.imported, row.staged = shipmentTotals(id)
                row.shipped = row.imported + row.staged
                row.requested = row.count
                row.detail = row.status == "timed out" and row.timeoutDetail or row.detail
                rows[#rows + 1] = row
            end
        end
        table.sort(rows, function(a, b) return a.id < b.id end)
        local connected = lastContact and io.now() - lastContact <= (tonumber(setting("messageTimeoutSeconds", 30)) or 30)
        local routeConfirmed = masterConnection and masterConnection.routeConfirmed
        local automationEnabled = masterConnection and masterConnection.automationEnabled
        local detail = clientError()
        if not detail then
            if not connected then detail = "Waiting for master connection"
            elseif routeConfirmed == false then detail = masterConnection.error or "Master connected; colony route mismatch"
            elseif automationEnabled == false then detail = "Master connected; automation paused"
            else detail = "Master connected; waiting for turns" end
        end
        return {
            role = "supply", colonyName = data.colonyName,
            health = { ok = connected == true and not clientError() and routeConfirmed ~= false,
                connected = connected == true, detail = detail,
                routeConfirmed = routeConfirmed, automationEnabled = automationEnabled },
            status = clientError() and "error" or (data.turn and data.turn.phase or "waiting"),
            statusMessage = detail,
            requests = rows, colonies = {}, history = store.data.history or {}, errors = store.data.errors or {},
            settings = store.data.settings or config, turn = copy(data.turn), intent = copy(data.intent),
            masterId = config.masterId, lastContact = lastContact,
        }
    end

    return self
end

return M
