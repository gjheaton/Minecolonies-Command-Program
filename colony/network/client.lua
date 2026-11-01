-- Dedicated supply client. Only the master owns player Refined Storage.
local M = {}

local function amount(value)
    return math.max(0, math.floor(tonumber(value) or 0))
end
local function yieldNow(io)
    if io and type(io.wait)=="function" then io.wait(0) end
end

local MAX_RETURN_SELECTORS = 1024
local function validFingerprint(value)
    return type(value) == "string" and value ~= "" and #value <= 256
end

local function sameExportBaseline(io, matcher, before, after)
    if type(io.sameExportBaseline) == "function" then return io.sameExportBaseline(before, after) end
    return matcher.canonicalNBT(before) == matcher.canonicalNBT(after)
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

-- An operator may acknowledge an unknown overflow call only as ZERO movement.
-- This never credits returned stock or repeats the interrupted bridge call.
function M.zeroReturnRecovery(config, store, io, matcher)
    local self, previewGuard = {}, nil
    local allowed = { TRANSFER_DESYNC=true, TRANSFER_UNCERTAIN=true, IMPORT_UNCERTAIN=true }
    local function quantity(n, minimum)
        return type(n)=="number" and n==n and n~=math.huge and n~=-math.huge
            and n%1==0 and n>=(minimum or 0)
    end
    local function inspect()
        local data=store.data.client
        if config.role~="supply" or type(data)~="table" or type(data.intent)~="table" then
            return nil,"No interrupted colony overflow return is held"
        end
        local intent=data.intent
        if intent.kind~="return" or intent.reported~=nil or type(data.fault)~="table" or not allowed[data.fault.code] then
            return nil,"Only a held overflow return with an unknown bridge result can be acknowledged here"
        end
        if type(data.turn)~="table" or data.turn.phase~="finished" then
            return nil,"Wait for the master result to close the reserved turn before repairing"
        end
        if type(config.returnChestName)~="string" or config.returnChestName==""
            or config.returnChestName==config.deliveryChestName or intent.chest~=config.returnChestName then
            return nil,"Restore the original separate return chest configuration first"
        end
        if type(intent.item)~="table" or type(intent.item.name)~="string" or intent.item.name==""
            or #intent.item.name>256 or not validFingerprint(intent.item.fingerprint)
            or not quantity(intent.count,1) or not quantity(intent.beforeChest)
            or type(intent.physicalBefore)~="table" then
            return nil,"The held return lacks valid original quantities, identity, or physical chest evidence"
        end
        local bridge=io.bridgeStatus()
        if type(bridge)~="table" or bridge.connected~=true then return nil,"Restore the colony RS connection first" end
        local stock,err=io.colonyStock()
        if type(stock)~="table" then return nil,"Cannot read the restored colony warehouse: "..tostring(err) end
        local items,chestError=io.snapshot(intent.chest)
        if type(items)~="table" then return nil,"Cannot inspect the original return chest: "..tostring(chestError) end
        local physical,physicalError=io.exportBaseline(items)
        if type(physical)~="table" then return nil,"Cannot verify physical return items: "..tostring(physicalError) end
        if not sameExportBaseline(io,matcher,intent.physicalBefore,physical) then
            return nil,"The physical return chest changed; zero-movement acknowledgment is unsafe"
        end
        local current=io.count(items,intent.item)
        if not quantity(current) or current~=intent.beforeChest then return nil,"The original return item quantity changed" end
        if type(data.shipments)~="table" then return nil,"The delivery ledger is invalid" end
        local delivery,deliveryError=io.snapshot(config.deliveryChestName)
        if type(delivery)~="table" then return nil,"Cannot verify outstanding deliveries: "..tostring(deliveryError) end
        local outstanding={}
        for id,shipment in pairs(data.shipments) do
            if type(shipment)~="table" or shipment.verified~=true or shipment.id~=id
                or type(shipment.item)~="table" or type(shipment.item.name)~="string"
                or not quantity(shipment.count,1) or not quantity(shipment.imported) or shipment.imported>shipment.count then
                return nil,"A retained delivery has invalid identity or quantities"
            end
            local key=matcher.itemIdentity(shipment.item)
            outstanding[key]=outstanding[key] or {item=shipment.item,count=0}
            outstanding[key].count=outstanding[key].count+shipment.count-shipment.imported
        end
        for _,entry in pairs(outstanding) do
            local present=io.count(delivery,entry.item)
            if not quantity(present) or present<entry.count then return nil,"An outstanding delivery is missing; restore it first" end
        end
        local preview={item=copy(intent.item),count=intent.count,chest=intent.chest,beforeChest=intent.beforeChest,
            currentChest=current,confirmation="ZERO"}
        local guard=matcher.canonicalNBT({intent=intent,fault=data.fault,turn=data.turn,shipments=data.shipments,
            selectors=data.returnSelectors,bridgeName=bridge.name,configuredBridge=config.colonyBridgeName,
            deliveryChest=config.deliveryChestName,returnChest=config.returnChestName})
        return preview,guard
    end
    local function checkedInspect()
        local ok,preview,guard=pcall(inspect)
        if not ok then return nil,"Cannot verify the held return: "..tostring(preview) end
        return preview,guard
    end
    local function persist()
        local ok,saved,err=pcall(store.save)
        if not ok then return false,tostring(saved) end
        return saved==true,tostring(err or "Journal durability was not confirmed")
    end
    function self.previewZeroReturn()
        previewGuard=nil
        local preview,guard=checkedInspect()
        if not preview then return nil,guard end
        previewGuard=guard
        return preview
    end
    function self.reconcileZeroReturn(confirmation)
        if not previewGuard then return false,"Preview the held return first" end
        local preview,guard=checkedInspect()
        if not preview then return false,guard end
        if guard~=previewGuard then return false,"The held return changed after preview; inspect a fresh preview" end
        if confirmation~=preview.confirmation then return false,"Exact zero-movement confirmation required" end
        if type(store.data.history)~="table" then return false,"Audit history is invalid" end
        local data,oldHistory=store.data.client,store.data.history
        local nextHistory=copy(oldHistory)
        nextHistory[#nextHistory+1]={time=io.now(),kind="OPERATOR_ZERO_RETURN",
            message="Operator confirmed master remained paused and no items moved or were replaced; no returned quantity credited",
            context={item={name=preview.item.name},count=preview.count,chest=preview.chest,
                beforeChest=preview.beforeChest,currentChest=preview.currentChest,operatorConfirmation=confirmation}}
        while #nextHistory>math.max(1,amount(config.maxHistoryEntries or 400)) do table.remove(nextHistory,1) end
        store.data.history=nextHistory
        local audited,err=persist()
        if not audited then store.data.history=oldHistory;return false,"Cannot persist acknowledgment: "..err end
        local intent,fault=data.intent,data.fault
        data.intent,data.fault=nil,nil
        local saved,saveError=persist()
        if not saved then data.intent,data.fault=intent,fault;return false,"Acknowledgment recorded, but return remains held: "..saveError end
        previewGuard=nil
        return true,"Zero return movement acknowledged; no items moved or credited. Restart the colony program before resuming automation."
    end
    return self
end

function M.new(config, store, io, matcher)
    local self = {}
    store.data.client = type(store.data.client) == "table" and store.data.client or {}
    local data = store.data.client
    data.requests = type(data.requests) == "table" and data.requests or {}
    data.shipments = type(data.shipments) == "table" and data.shipments or {}
    data.returnSelectors = type(data.returnSelectors) == "table" and data.returnSelectors or {}
    data.retiredSessions = type(data.retiredSessions) == "table" and data.retiredSessions or {}
    data.seenTurns = type(data.seenTurns) == "table" and data.seenTurns or {}
    data.cursor = amount(data.cursor)
    local nextHello, nextRetry, nextAutoReconcile = 0, 0, 0
    local lastContact
    local masterConnection
    local persistenceError
    local startupPreparationPending =
        type(data.turn) == "table" and data.turn.phase == "preparing"
    local startupInterruptedPending =
        type(data.fault) == "table"
        and data.fault.code == "TURN_INTERRUPTED"

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
    -- Startup recovery owns PREPARING/TURN_INTERRUPTED states until tick()
    -- has reconciled the local journal before the first hello.
    if type(data.intent) == "table"
        and not startupPreparationPending
        and not startupInterruptedPending then
        fault("IMPORT_UNCERTAIN", "An interrupted chest transfer needs reconciliation; automatic transfers are paused", data.intent)
    end

    local function sameItem(a, b)
        return type(a) == "table" and type(b) == "table"
            and matcher.itemIdentity(a) == matcher.itemIdentity(b)
            and a.transientNameImport == b.transientNameImport
    end

    local function validTransientNameImport(item)
        return type(item)=="table" and item.transientNameImport==true
            and item.fingerprint==nil
            and type(matcher.isTransientTransportName)=="function"
            and matcher.isTransientTransportName(item.name)
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
                or shipment.item.name == "" or amount(shipment.count) == 0
                or (shipment.item.transientNameImport~=nil and not validTransientNameImport(shipment.item))
                or (shipment.item.fingerprint ~= nil and not validFingerprint(shipment.item.fingerprint))
                or (shipment.item.fingerprint == nil and matcher.canonicalNBT(shipment.item.nbt) ~= ""
                    and not validTransientNameImport(shipment.item)) then
                fault("BAD_DELIVERY", "Master supplied an unverified or incomplete delivery record")
                return false
            end
            local id = tostring(shipment.id)
            local current = data.shipments[id]
            if current and (not sameItem(current.item, shipment.item)
                or current.item.fingerprint ~= shipment.item.fingerprint
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
                current.imported = math.min(current.count, amount(shipment.imported))
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
        local scanned=0
        for _, request in pairs(requests) do
            scanned=scanned+1
            if scanned%16==0 then yieldNow(io) end
            if type(request) ~= "table" or request.id == nil then
                return nil, "getRequests contains a request without a stable ID"
            end
            local id = tostring(request.id)
            if id == "" or active[id] then return nil, "getRequests contains an invalid or duplicate request ID" end
            active[id] = request
        end
        local updated=0
        for id, request in pairs(active) do
            updated=updated+1
            if updated%16==0 then yieldNow(io) end
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

    local function selectorItem(item)
        if type(item) ~= "table" or type(item.name) ~= "string" or item.name == "" or #item.name > 256 then
            return nil, "Return item name is invalid or exceeds the selector limit"
        end
        local nbt = item.nbt
        if matcher.canonicalNBT(nbt) == "" then nbt = nil
        elseif type(nbt) ~= "string" or #nbt > 256 then
            return nil, "Return items require the exact bounded physical CC NBT identity"
        end
        return { name = item.name, nbt = nbt }
    end

    local function returnSelectorRows()
        local rows,seen,count = {},{},0
        for key, row in pairs(data.returnSelectors) do
            local original=type(row)=="table" and row.item
            local item, err = selectorItem(original)
            local keyMatches=item and type(key)=="string" and
                (type(matcher.itemIdentityKeyMatches)=="function" and matcher.itemIdentityKeyMatches(original,key)
                    or key==matcher.itemIdentity(original))
            if not item or not keyMatches
                or not validFingerprint(row.fingerprint) then
                return nil, err or "A retained return selector is invalid"
            end
            count=count+1
            if count > MAX_RETURN_SELECTORS then return nil, "Retained return selectors exceed the protocol limit" end
            local identity=matcher.itemIdentity(item)
            local previous=seen[identity]
            if previous and previous.fingerprint~=row.fingerprint then
                return nil,"Equivalent physical return selectors have conflicting AP fingerprints"
            elseif not previous then
                local entry={item=item,fingerprint=row.fingerprint}
                rows[#rows+1]=entry;seen[identity]=entry
            end
        end
        table.sort(rows, function(a, b) return matcher.itemIdentity(a.item) < matcher.itemIdentity(b.item) end)
        return rows
    end

    local function pruneReturnSelectors()
        if next(data.returnSelectors) == nil then return true end
        local rows, rowError = returnSelectorRows()
        if not rows then fault("RETURN_SELECTOR", rowError); return false end
        local items, err = chestSnapshot(config.returnChestName)
        if not items then fault("RETURN_CHEST", "Cannot inspect retained return selectors", { error = err }); return false end
        local kept, changed = {}, false
        for key,row in pairs(data.returnSelectors) do
            local normalized=selectorItem(row.item)
            if key~=matcher.itemIdentity(normalized) or row.item.nbt~=normalized.nbt then changed=true end
        end
        for _, row in ipairs(rows) do
            local present = io.count(items, row.item)
            if type(present) ~= "number" or present ~= amount(present) or present == math.huge then
                fault("RETURN_CHEST", "Return inventory did not provide a reliable physical quantity")
                return false
            end
            if present > 0 then kept[matcher.itemIdentity(row.item)] = row else changed = true end
        end
        if changed then
            local previous = data.returnSelectors
            data.returnSelectors = kept
            if not save() then data.returnSelectors = previous; return false end
        end
        return true
    end

    local function bindReturnSelector(physical, source)
        local item, itemError = selectorItem(physical)
        if not item then return nil, itemError end
        if not validFingerprint(source.fingerprint) then return nil, "The source AP fingerprint is missing or invalid" end
        local key = matcher.itemIdentity(item)
        local rows, rowError = returnSelectorRows()
        if not rows then return nil, rowError end
        -- Check all legacy and canonical keys before selecting a write key.
        -- A compatible legacy binding can remain unchanged until normal pruning
        -- saves its canonical view; never overwrite a conflicting old selector.
        local existingKey
        for storedKey,row in pairs(data.returnSelectors) do
            if matcher.itemIdentity(row.item)==key then
                if row.fingerprint~=source.fingerprint then
                    return nil,"A retained physical return identity already has a different AP fingerprint"
                end
                if not existingKey or storedKey==key then existingKey=storedKey end
            end
        end
        if existingKey and existingKey~=key then return existingKey,data.returnSelectors[existingKey] end
        local previous = data.returnSelectors[key]
        if not previous and #rows >= MAX_RETURN_SELECTORS then return nil, "Return selector limit reached; retain the held export" end
        data.returnSelectors[key] = { item = item, fingerprint = source.fingerprint }
        return key, previous
    end

    local function returnEvidence(intent, after, reported)
        if reported == 0 then
            local physicalAfter, err = io.exportBaseline(after)
            if not physicalAfter then return nil, nil, err end
            local unchanged,baselineError=sameExportBaseline(io,matcher,intent.physicalBefore,physicalAfter)
            if unchanged then return 0 end
            if baselineError then return nil,nil,baselineError end
            return nil, nil, "A zero return export changed the physical chest inventory"
        end
        if type(reported) ~= "number" or reported <= 0 then return nil, nil, "The return export has no reliable positive result" end
        local physical, delta = io.exportEvidence(intent.physicalBefore, after, intent.item, reported)
        if not physical then return nil, nil, delta end
        if type(delta) ~= "number" or delta ~= reported then return nil, nil, "Physical return evidence differs from the bridge result" end
        return delta, physical
    end

    local function transfer(kind, shipment, item, count, chest)
        local before, err = chestSnapshot(chest)
        if not before then return nil, err end
        local physicalBefore
        if kind == "return" then
            if not validFingerprint(item.fingerprint) then return nil, "Overflow export requires the source AP fingerprint" end
            if type(item.name) ~= "string" or item.name == "" or #item.name > 256 then return nil, "Overflow item name exceeds the selector limit" end
            local rows, rowError = returnSelectorRows()
            if not rows then return nil, rowError end
            if #rows >= MAX_RETURN_SELECTORS then return nil, "Return selector limit reached; wait for the master to drain the chest" end
            physicalBefore, err = io.exportBaseline(before)
            if not physicalBefore then return nil, err end
        end
        local baseline = amount(io.count(before, item))
        local intent = {
            kind = kind, shipmentId = shipment and shipment.id,
            item = copy(item), count = count, chest = chest,
            beforeChest = baseline, startedAt = io.now(),
            physicalBefore = physicalBefore,
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
        local delta, physicalItem, evidenceError
        local function observe()
            delta, physicalItem, evidenceError = nil, nil, nil
            if not after then return end
            if kind == "return" then
                delta, physicalItem, evidenceError = returnEvidence(intent, after, reported)
            else
                delta = baseline - amount(io.count(after, item))
            end
        end
        observe()
        -- Inventory events can trail the bridge's synchronous return. Only
        -- read during this wait; never repeat the source mutation.
        while type(io.wait) == "function" and remainingReads > 0 and io.now() < deadline
            and type(reported) == "number" and reported == amount(reported) and reported <= count do
            if delta == reported or (delta and (delta < 0 or delta > reported)) then break end
            io.wait(math.min(interval, math.max(0, deadline - io.now())))
            remainingReads = remainingReads - 1
            after, snapshotError = chestSnapshot(chest)
            observe()
        end
        if not after then
            fault("TRANSFER_UNCERTAIN", "Unable to verify chest after colony transfer", { intent = intent, error = snapshotError })
            return nil, snapshotError
        end
        if type(reported) ~= "number" or reported ~= amount(reported)
            or reported > count or not delta or delta < 0 or delta ~= reported then
            fault("TRANSFER_DESYNC", "Colony bridge result does not match the chest inventory change", {
                intent = intent, reported = reported, actualDelta = delta, error = evidenceError or callError,
            })
            return nil, "unverified transfer"
        end
        local selectorKey, previousSelector
        if kind == "return" and delta > 0 then
            selectorKey, previousSelector = bindReturnSelector(physicalItem, item)
            if not selectorKey then
                fault("TRANSFER_DESYNC", previousSelector, { intent = intent })
                return nil, previousSelector
            end
        end
        if shipment then shipment.imported = amount(shipment.imported) + delta end
        data.intent = nil
        local persisted, saved = pcall(save)
        if not persisted or not saved then
            -- Retain the marker in memory as well; a retry cannot mutate the
            -- chest merely because the final accounting write failed.
            data.intent = intent
            if selectorKey then data.returnSelectors[selectorKey] = previousSelector end
            if not persisted then persistenceError = "Cannot persist supply state: " .. tostring(saved) end
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

        -- Incoming delivery chests are drained by a native Refined Storage
        -- Importer. The Supply computer never mutates CRS for deliveries.
        -- Because Master now stages only one shipment into an empty chest,
        -- the physical decrease of that reserved item is the import receipt.
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

        if #shipments == 0 then return end
        if #shipments > 1 then
            fault("DELIVERY_LEDGER",
                "More than one unimported shipment is reserved for a single-buffer delivery chest",
                { count = #shipments })
            return
        end

        local shipment = shipments[1]
        yieldNow(io)
        local items, err = chestSnapshot(config.deliveryChestName)
        if not items then
            fault("DELIVERY_CHEST", "Cannot read the delivery chest", { error = err })
            return
        end

        local remaining = math.max(0, amount(shipment.count) - amount(shipment.imported))
        local observed = amount(io.count(items, shipment.item))
        if observed > remaining then
            fault("DELIVERY_CHEST",
                "Delivery chest contains more of the reserved item than the shipment ledger allows",
                {
                    shipmentId = shipment.id, requestId = shipment.requestId,
                    item = shipment.item.name, expected = remaining, observed = observed,
                })
            return
        end

        local importedNow = remaining - observed
        if importedNow <= 0 then return end

        shipment.imported = amount(shipment.imported) + importedNow
        if not save() then
            shipment.imported = shipment.imported - importedNow
            return
        end

        store.event("IMPORTED",
            "Native RS Importer drained verified delivery from staging chest",
            {
                shipmentId = shipment.id, requestId = shipment.requestId,
                item = shipment.item.name, count = importedNow,
                chest = config.deliveryChestName,
            })
    end

    local function protects(item, active)
        for _, request in pairs(active) do
            if matcher.requestAcceptsItem(request, item) then return true end
        end
        return false
    end

    local function keepCount(item)
        local keep = setting("keepCounts", {})
        local explicit
        if type(keep)=="table" then
            local keys=type(matcher.itemIdentityKeys)=="function" and matcher.itemIdentityKeys(item)
                or {matcher.itemIdentity(item)}
            -- Empty-tag aliases may have had separate keep overrides in an
            -- older config. Retain the larger floor before returning stock.
            for _,key in ipairs(keys) do
                if keep[key]~=nil then explicit=math.max(explicit or 0,amount(keep[key])) end
            end
            if explicit==nil then explicit=keep[item.name] end
        end
        if explicit ~= nil then return amount(explicit) end
        local path = tostring(item.name):match("^[^:]+:(.+)$") or tostring(item.name)
        for _, pattern in ipairs(config.buildingItemPatterns or BUILDING_PATTERNS) do
            if path:match(pattern) then return amount(setting("buildingItemKeep", 1024)) end
        end
        return amount(setting("defaultItemKeep", 128))
    end

    local function stageOverflow(active)
        -- Supply is deliberately read-only against CRS. AP/RS bridge mutations
        -- have repeatedly desynchronized the colony network, so overflow
        -- staging is disabled here even if an older config still has the
        -- setting enabled. Native RS components may be used for future return
        -- handling, but the computer will not export from CRS.
        return
    end

    local function selectorsForBatch()
        local rows, err = returnSelectorRows()
        if not rows and not clientError() then fault("RETURN_SELECTOR", err) end
        return rows or {}
    end

    local function batchForTurn()
        if not clientError() and not data.intent then pruneReturnSelectors() end
        yieldNow(io)
        drainDeliveries()
        yieldNow(io)
        local active, err = readRequests()
        if not active then
            -- No activeIds is intentional: an unsuccessful scan must never
            -- tell the master that all requests disappeared.
            local selectors = selectorsForBatch()
            return {
                kind = "batch", session = data.turn.session, turn = data.turn.turn,
                requests = {}, imports = imports(), clientError = clientError() or tostring(err),
                authoritative = false, returnSelectors = selectors,
            }
        end
        yieldNow(io)
        stageOverflow(active)
        yieldNow(io)
        local name = io.colonyName()
        data.colonyName = type(name) == "string" and name or data.colonyName
        local selectors = selectorsForBatch()
        return {
            kind = "batch", session = data.turn.session, turn = data.turn.turn,
            requests = selectedRequests(active), activeIds = activeIds(active),
            imports = imports(), colonyName = data.colonyName,
            authoritative = true, returnSelectors = selectors, clientError = clientError(),
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
                or (message.deliveryDrainLocked ~= nil and type(message.deliveryDrainLocked) ~= "boolean")
                or (message.startupResetAccepted ~= nil and type(message.startupResetAccepted) ~= "boolean")
                or message.error ~= nil and (type(message.error) ~= "string" or #message.error > 512) then return false end
            lastContact = io.now()
            masterConnection = {
                routeConfirmed = message.routeConfirmed,
                automationEnabled = message.automationEnabled,
                deliveryDrainLocked = message.deliveryDrainLocked == true,
                startupResetAccepted = message.startupResetAccepted == true,
                error = message.error,
                receivedAt = lastContact,
            }
            if message.startupResetAccepted == true then
                data.intent = nil
                data.fault = nil
                data.turn = nil
                data.session = nil
                data.seenTurns = {}
                data.highestTurn = nil
                data.shipments = {}
                data.returnSelectors = {}
                data.bootResetPending = false
                startupPreparationPending = false
                startupInterruptedPending = false
                if save() then
                    store.event("BOOT_RESET",
                        "Startup staging reset completed; fresh turns may resume")
                end
            end
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
        if self.updateWaiting then return false end
        if data.session ~= session then
            if data.session then
                local retired=tostring(data.session)
                data.retiredSessions[retired]=io.now()
                local rows={}
                for id,when in pairs(data.retiredSessions) do
                    rows[#rows+1]={id=id,when=tonumber(when) or 0}
                end
                table.sort(rows,function(a,b) return a.when>b.when end)
                for index=17,#rows do data.retiredSessions[rows[index].id]=nil end
            end
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
            -- Persist the grant's delivery ledger with the PREPARING marker.
            -- A restart can then reconstruct the turn locally before it talks
            -- to the master again.
            deliveries = message.deliveries ~= nil and copy(message.deliveries) or nil,
            phase = "preparing", startedAt = io.now(),
        }
        -- Persist the reservation and the complete preparation input before
        -- touching either Ender Chest.
        if not save() then return false end
        yieldNow(io)
        shipmentList(data.turn.deliveries)
        yieldNow(io)
        data.turn.batch = batchForTurn()
        data.turn.phase = "waiting"
        data.turn.deliveries = nil
        if save() then
            send(copy(data.turn.batch))
            nextRetry = io.now() + math.max(0.1, tonumber(setting("batchRetrySeconds", 5)) or 5)
        end
        return true
    end

    local function recoverInterruptedPreparation()
        if not startupPreparationPending then return true end
        if not data.turn or data.turn.phase ~= "preparing" then
            startupPreparationPending = false
            return true
        end

        -- A transfer journal with a numeric bridge result can be reconciled
        -- from the physical chest delta without repeating the mutation.  Do
        -- this before the first hello so a clean local restart stays invisible
        -- to the master.
        if type(data.intent) == "table" then
            local reported = data.intent.reported
            if type(reported) == "number"
                and reported == amount(reported)
                and reported <= amount(data.intent.count) then
                local ok, detail = self.reconcile({ allowPreparing = true })
                if not ok then
                    fault(
                        "TURN_INTERRUPTED",
                        "Turn preparation was interrupted; local reconciliation failed: " ..
                            tostring(detail)
                    )
                    startupPreparationPending = false
                    return false
                end
            else
                fault(
                    "TURN_INTERRUPTED",
                    "Turn preparation was interrupted with an unknown bridge result; transfers need reconciliation"
                )
                startupPreparationPending = false
                return false
            end
        end

        -- Reapply only durable/idempotent preparation work.  shipmentList()
        -- merges exact verified delivery records, while batchForTurn() resumes
        -- from the persisted import/return ledgers and therefore does not
        -- repeat any already-accounted chest mutation.
        if data.turn.deliveries ~= nil
            and not shipmentList(data.turn.deliveries) then
            fault(
                "TURN_INTERRUPTED",
                "Turn preparation was interrupted; saved delivery records could not be restored"
            )
            startupPreparationPending = false
            return false
        end

        data.turn.batch = batchForTurn()
        data.turn.phase = "waiting"
        data.turn.deliveries = nil
        if not save() then
            fault(
                "TURN_INTERRUPTED",
                "Turn preparation was reconciled locally but the rebuilt batch could not be persisted"
            )
            startupPreparationPending = false
            return false
        end

        startupPreparationPending = false
        store.event(
            "STARTUP_RECONCILED",
            "Interrupted turn preparation was reconstructed locally before master contact",
            { session = data.turn.session, turn = data.turn.turn }
        )
        return true
    end

    function self.tick()
        local now = io.now()

        if data.bootResetPending == true then
            if now >= nextHello then
                send({
                    kind = "hello", role = "supply", colonyName = data.colonyName,
                    deliveryChestName = config.deliveryChestName,
                    returnChestName = config.returnChestName,
                    deliveryChannel = config.deliveryChannel,
                    returnChannel = config.returnChannel,
                    startupReset = true,
                    clientError = clientError(),
                    imports = imports(),
                })
                nextHello = now + math.max(0.1, tonumber(setting("helloSeconds", 5)) or 5)
            end
            return
        end

        -- Local startup reconciliation always runs before the first hello.
        -- Older clients persisted an interrupted preparation as WAITING plus
        -- TURN_INTERRUPTED, so key recovery off the durable fault as well as
        -- the newer PREPARING marker.
        if startupPreparationPending then
            recoverInterruptedPreparation()
        elseif startupInterruptedPending then
            local turn = data.turn
            local phase = type(turn) == "table" and tostring(turn.phase or "") or ""
            local allowActive =
                phase == "waiting" or phase == "finished"

            if type(data.intent) == "table" then
                local reported = data.intent.reported
                if type(reported) == "number"
                    and reported == amount(reported)
                    and reported <= amount(data.intent.count) then
                    local ok, detail = self.reconcile({
                        allowPreparing = phase == "preparing",
                        allowInterruptedActive = allowActive,
                    })
                    if ok then
                        startupInterruptedPending = false
                    else
                        fault(
                            "TURN_INTERRUPTED",
                            "Startup reconciliation failed: " .. tostring(detail)
                        )
                        startupInterruptedPending = false
                    end
                else
                    -- Unknown bridge outcomes still require operator evidence.
                    startupInterruptedPending = false
                end
            else
                local ok, detail = self.reconcile({
                    allowPreparing = phase == "preparing",
                    allowInterruptedActive = allowActive,
                })
                if ok then
                    -- Rebuild the active waiting batch so a legacy
                    -- clientError is not retransmitted after the fault clears.
                    if type(data.turn) == "table" and data.turn.phase == "waiting" then
                        data.turn.batch = batchForTurn()
                        save()
                    end
                    startupInterruptedPending = false
                    store.event(
                        "STARTUP_RECONCILED",
                        "Stale interrupted turn was reconciled locally before master contact",
                        { session = data.turn and data.turn.session, turn = data.turn and data.turn.turn }
                    )
                else
                    fault(
                        "TURN_INTERRUPTED",
                        "Startup reconciliation failed: " .. tostring(detail)
                    )
                    startupInterruptedPending = false
                end
            end
        end

        -- A forced update/reboot can interrupt the program after the bridge
        -- returned but before the normal accounting path cleared its durable
        -- intent. When that numeric bridge result is still present, the normal
        -- reconcile() routine can prove the physical chest delta and repair the
        -- ledger without repeating the mutation. Do this automatically once
        -- the master has closed the turn. Unknown bridge results remain held
        -- for explicit operator zero-movement confirmation.
        if data.fault and data.turn
            and data.turn.phase=="finished"
            and now>=nextAutoReconcile then
            nextAutoReconcile=now+5

            local shouldReconcile = false
            if data.intent then
                local reported=data.intent.reported
                shouldReconcile =
                    type(reported)=="number"
                    and reported==amount(reported)
                    and reported<=amount(data.intent.count)
            elseif data.fault.code=="TURN_INTERRUPTED" then
                -- Legacy/current interrupted PREPARING turns can leave a
                -- fault after the master has safely closed the reservation,
                -- even when no bridge mutation was in flight.  At that point
                -- reconcile() can prove all retained deliveries from the
                -- physical chest ledger and clear the stale live fault.
                shouldReconcile = true
            end

            if shouldReconcile then
                local ok,detail=self.reconcile()
                if ok then
                    store.event("AUTO_RECONCILED",
                        "Interrupted colony turn reconciled automatically",{
                            kind=data.intent and data.intent.kind or "turn",
                            detail=detail
                        })
                end
            end
        end

        -- Verified deliveries no longer depend on a fresh master turn. Once
        -- PRS has already placed an item in this colony's delivery chest, the
        -- colony may safely import that retained shipment into CRS even while
        -- the master is quarantined on an unrelated PRS export. Never do this
        -- during a live turn or while any client fault/intent is held.
        if data.turn and data.turn.phase=="finished"
            and not clientError() and not data.intent
            and not (masterConnection and masterConnection.deliveryDrainLocked==true) then
            drainDeliveries()
        end

        if now >= nextHello then
            send({ kind = "hello", role = "supply", colonyName = data.colonyName,
                deliveryChestName = config.deliveryChestName, returnChestName = config.returnChestName,
                deliveryChannel = config.deliveryChannel, returnChannel = config.returnChannel,
                startupReset = false,
                clientError = clientError(), session = data.turn and data.turn.session,
                turn = data.turn and data.turn.turn,
                imports = imports(),
                deliveryDrainLocked = masterConnection and masterConnection.deliveryDrainLocked == true })
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

    -- Volatile admission control only: retain the active reservation and
    -- receipts, and continue processing its duplicate grants and result.
    function self.holdNewTurns(enabled)
        self.updateWaiting=enabled==true
    end

    function self.canWaitForUpdate()
        return data.intent==nil and persistenceError==nil
            and data.turn~=nil and data.turn.phase~="finished"
    end

    function self.canUpdate()
        if self.busy() then return false, "Finish or reconcile the reserved colony turn before updating" end
        return true
    end

    function self.canProbe()
        if clientError() then return false, clientError() end
        return self.canUpdate()
    end

    function self.reconcile(options)
        local allowPreparing =
            type(options) == "table" and options.allowPreparing == true
        local allowInterruptedActive =
            type(options) == "table" and options.allowInterruptedActive == true
        if data.turn and data.turn.phase ~= "finished"
            and not (allowPreparing and data.turn.phase == "preparing")
            and not (
                allowInterruptedActive
                and type(data.fault) == "table"
                and data.fault.code == "TURN_INTERRUPTED"
                and (data.turn.phase == "waiting" or data.turn.phase == "preparing")
            ) then
            return false, "Wait for the master result to close the reserved turn before repairing"
        end
        local intent = data.intent
        local shipment, oldImported, returnPhysical
        if intent then
            local reported = intent.reported
            if type(reported) ~= "number" or reported ~= amount(reported) or reported > amount(intent.count) then
                return false, "The interrupted bridge call has no reliable return value; inspect the chest and warehouse manually"
            end
            local items, err = chestSnapshot(intent.chest)
            if not items then return false, "Cannot inspect interrupted transfer chest: " .. tostring(err) end
            local delta, evidenceError
            if intent.kind == "return" and intent.physicalBefore then
                delta, returnPhysical, evidenceError = returnEvidence(intent, items, reported)
            else
                local current = amount(io.count(items, intent.item))
                delta = intent.kind == "import" and amount(intent.beforeChest) - current or current - amount(intent.beforeChest)
            end
            if delta ~= reported then
                return false, evidenceError or "The bridge result still differs from the physical chest quantity; automatic repair is unsafe"
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
        for id, delivery in pairs(data.shipments) do
            local key = matcher.itemIdentity(delivery.item)
            local row = outstanding[key]
            if not row then
                row = {
                    item = delivery.item,
                    count = 0,
                    shipments = {},
                    requests = {},
                }
                outstanding[key] = row
            end
            local remaining =
                math.max(0, amount(delivery.count) - amount(delivery.imported))
            row.count = row.count + remaining
            if remaining > 0 then
                row.shipments[#row.shipments + 1] = tostring(delivery.id or id)
                row.requests[#row.requests + 1] = tostring(delivery.requestId or "?")
            end
        end
        for _, required in pairs(outstanding) do
            local observed = amount(io.count(items, required.item))
            if observed < required.count then
                if shipment then shipment.imported = oldImported end
                return false,
                    "Verified delivery missing from chest: item=" ..
                    tostring(required.item and required.item.name or "?") ..
                    " expected=" .. tostring(required.count) ..
                    " observed=" .. tostring(observed) ..
                    " shipment=" .. table.concat(required.shipments, ",") ..
                    " request=" .. table.concat(required.requests, ",")
            end
        end
        local selectorKey, previousSelector
        if returnPhysical then
            selectorKey, previousSelector = bindReturnSelector(returnPhysical, intent.item)
            if not selectorKey then return false, previousSelector end
        end
        local previousFault = data.fault
        data.intent, data.fault = nil, nil
        local persisted, saved = pcall(save)
        if not persisted or not saved then
            data.intent, data.fault = intent, previousFault
            if shipment then shipment.imported = oldImported end
            if selectorKey then data.returnSelectors[selectorKey] = previousSelector end
            return false, persistenceError or tostring(saved)
        end
        store.event("RECONCILED", "Physical chest quantities agree with the retained shipment ledger; transfers may resume")
        return true, "Chest quantities reconciled without repeating any transfer"
    end

    function self.snapshot()
        -- UI/telemetry snapshots are read-only views, not transaction backups.
        -- Never deep-copy raw MineColonies requests, retained master results,
        -- turn batches, or shipment internals here.
        local rows = {}
        for id, record in pairs(data.requests) do
            if record.active ~= false then
                local imported, staged = shipmentTotals(id)
                rows[#rows + 1] = {
                    id = tostring(record.id or id),
                    requestId = tostring(record.requestId or record.id or id),
                    name = record.name,
                    displayName = record.displayName or record.name,
                    item = type(record.item)=="table" and record.item.name or record.item,
                    status = record.status,
                    phase = record.phase,
                    count = record.count,
                    requested = record.count,
                    shipped = imported + staged,
                    imported = imported,
                    staged = staged,
                    detail = record.status == "timed out" and record.timeoutDetail or record.detail,
                    firstSeen = record.firstSeen,
                    lastSeen = record.lastSeen,
                    lastResponse = record.lastResponse,
                    phaseSince = record.phaseSince,
                    craftStartedAt = record.craftStartedAt,
                    deliveryStartedAt = record.deliveryStartedAt,
                    completedAt = record.completedAt,
                    deadline = record.deadline,
                }
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
            elseif masterConnection and masterConnection.deliveryDrainLocked==true then
                detail = "Master connected; delivery drain locked for PRS transfer verification"
            else detail = "Master connected; waiting for turns" end
        end
        local turn
        if type(data.turn)=="table" then
            turn = {
                phase = data.turn.phase,
                session = data.turn.session,
                turn = data.turn.turn,
                id = data.turn.id,
                startedAt = data.turn.startedAt,
                finishedAt = data.turn.finishedAt,
                policy = type(data.turn.policy)=="table" and copy(data.turn.policy) or nil,
            }
        end
        local intent
        if type(data.intent)=="table" then
            intent = {
                kind=data.intent.kind,
                count=data.intent.count,
                chest=data.intent.chest,
                reported=data.intent.reported,
                beforeChest=data.intent.beforeChest,
                callError=data.intent.callError,
            }
        end
        return {
            role = "supply", colonyName = data.colonyName,
            health = { ok = connected == true and not clientError() and routeConfirmed ~= false,
                connected = connected == true, detail = detail,
                routeConfirmed = routeConfirmed, automationEnabled = automationEnabled },
            status = clientError() and "error" or (data.turn and data.turn.phase or "waiting"),
            statusMessage = detail,
            requests = rows, colonies = {}, history = store.data.history or {}, errors = store.data.errors or {},
            settings = store.data.settings or config, turn = turn, intent = intent,
            masterId = config.masterId, lastContact = lastContact,
        }
    end

    do
        -- Do not mutate CRS during startup. The colony RS Bridge is read-only
        -- from this program; startup recovery is coordinated with Master
        -- without pulling the return chest back into CRS.
        data.bootResetPending = true
        save()
        store.event("BOOT_RESET",
            "Supply startup reset armed without mutating CRS",
            { returnChest = config.returnChestName })
    end

    return self
end

return M