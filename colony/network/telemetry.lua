-- Read-only supply dashboards. Telemetry never acquires new inventory data.
local Config = require("colony.network.config")
local M = {}

local SETTINGS = {
    "masterId", "colonyBridgeName", "colonyIntegratorName", "monitorName",
    "deliveryChestName", "returnChestName", "deliveryChannel", "returnChannel",
    "usePeripheralTransfer", "colonyImportDirection", "colonyExportDirection",
    "autoCraftEnabled", "overflowEnabled", "pollIntervalSeconds", "helloSeconds",
    "colonyResponseTimeoutSeconds", "batchRetrySeconds", "messageTimeoutSeconds",
    "onHandTimeoutSeconds", "craftingTimeoutSeconds", "acknowledgementTimeoutSeconds",
    "transferVerifyTimeoutSeconds", "transferSettleSeconds", "transferPollSeconds",
    "craftCooldownSeconds", "craftPollSeconds", "craftStableReadsRequired", "retryCooldownSeconds", "desyncProbeSeconds",
    "updateCheckSeconds", "maxRequestsPerTurn", "maxItemsPerTurn", "maxTransferChunk",
    "maxCraftBatch", "maxConcurrentCrafts", "maxCraftsPerTurn", "maxImportsPerTurn",
    "maxReturnItemsPerTurn", "chestReserveSlots", "defaultItemKeep", "buildingItemKeep",
    "maxHistoryEntries", "maxErrorEntries", "requestRetentionSeconds", "maxCompletedRequests",
    "monitorTextScale", "chestTestItem", "chestTestTimeoutSeconds", "telemetryIntervalSeconds",
    "telemetryStaleSeconds", "telemetryOfflineSeconds", "telemetryMaxRequests", "telemetryHistoryEntries", "telemetryErrorEntries",
}
local REQUEST_FIELDS = {
    "name", "displayName", "status", "phase", "count", "requested", "shipped", "imported",
    "staged", "detail", "firstSeen", "lastSeen", "lastResponse", "phaseSince",
    "craftStartedAt", "deliveryStartedAt", "completedAt", "deadline",
}
local EVENT_FIELDS = {
    "kind", "code", "message", "severity", "time", "epoch", "detail", "item",
    "count", "amount", "requestId", "direction", "computerId", "programVersion",
}
local CONTEXT_FIELDS = {
    "requestId", "shipmentId", "colonyId", "computerId", "item", "count", "amount",
    "reported", "actualDelta", "error", "reason", "expected", "observed", "kind", "direction", "beforeChest", "afterChest",
}
local INTENT_FIELDS={"kind","count","chest","reported","beforeChest","callError"}

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function integer(value, fallback)
    return finite(value) and math.max(0, math.floor(value)) or fallback or 0
end

local function text(value, maximum)
    if type(value) == "number" and finite(value) then value = tostring(value) end
    if type(value) ~= "string" then return nil end
    return value:gsub("[%c]", " "):sub(1, maximum or 512)
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, child in pairs(value) do out[key] = copy(child) end
    return out
end

local function entries(value)
    local out = {}
    for key, child in pairs(type(value) == "table" and value or {}) do
        if type(child) == "table" then out[#out + 1] = { key = key, value = child } end
    end
    table.sort(out, function(a, b)
        if type(a.key) == "number" and type(b.key) == "number" then return a.key < b.key end
        return tostring(a.key) < tostring(b.key)
    end)
    return out
end

local function compact(source, config)
    -- Protocol.valid counts both keys and values. Reserve ample space below
    -- its 30,000-node limit for packet metadata and truncation reporting.
    local remaining = 24000
    local function map()
        remaining = remaining - 1
        return {}
    end
    local function put(target, key, value, maximum)
        if value == nil or remaining < 2 then return false end
        if type(value) == "string" then value = text(value, maximum)
        elseif type(value) == "number" then if not finite(value) then return false end
        elseif type(value) ~= "boolean" then return false end
        remaining = remaining - 2
        target[key] = value
        return true
    end
    local function fields(target, raw, names)
        for _, name in ipairs(names) do
            put(target, name, raw[name], (name == "detail" or name == "message" or name == "error") and 512 or 256)
        end
    end
    local function attach(target, key, child)
        remaining = remaining - 1
        target[key] = child
    end
    local function total(key, observed)
        return math.max(observed, integer(type(source.totals) == "table" and source.totals[key]))
    end
    local view = map()
    put(view, "role", "supply")
    for _, key in ipairs({"programVersion", "colonyName", "status", "statusMessage", "masterId", "lastContact", "lastRequestScan"}) do
        put(view, key, source[key])
    end
    attach(view, "colonies", map())

    local health = map()
    local rawHealth = type(source.health) == "table" and source.health or {}
    fields(health, rawHealth, {"ok", "connected", "detail", "overall"})
    local checks, checkEntries, shownChecks = map(), entries(rawHealth.checks), 0
    for index = 1, math.min(64, #checkEntries) do
        local entry = checkEntries[index]
        local label = text(entry.key, 128)
        if label and not checks[label] then
            local check = map()
            fields(check, entry.value, {"ok", "detail", "label", "name", "status"})
            attach(checks, label, check)
            shownChecks = shownChecks + 1
        end
    end
    attach(health, "checks", checks)
    attach(view, "health", health)

    local settings = map()
    local rawSettings = type(source.settings) == "table" and source.settings or {}
    fields(settings, rawSettings, SETTINGS)
    local keepCounts, names = map(), {}
    for name, count in pairs(type(rawSettings.keepCounts) == "table" and rawSettings.keepCounts or {}) do
        if type(name) == "string" and finite(count) and count >= 0 then names[#names + 1] = name end
    end
    table.sort(names)
    local shownKeep = 0
    for index = 1, math.min(128, #names) do
        local name = text(names[index], 256)
        if keepCounts[name] == nil and put(keepCounts, name, rawSettings.keepCounts[names[index]]) then shownKeep = shownKeep + 1 end
    end
    attach(settings, "keepCounts", keepCounts)
    attach(view, "settings", settings)

    local policy = map()
    local rawTurn = type(source.turn) == "table" and source.turn or {}
    local rawPolicy = type(source.effectivePolicy) == "table" and source.effectivePolicy
        or type(rawTurn.policy) == "table" and rawTurn.policy or {}
    for _, key in ipairs(SETTINGS) do
        if Config.isPolicyKey(key) then put(policy, key, rawPolicy[key]) end
    end
    attach(view, "effectivePolicy", policy)
    local turn = map()
    fields(turn, rawTurn, {"phase", "session", "turn", "id", "startedAt", "finishedAt"})
    attach(view, "turn", turn)

    local shown = { healthChecks = shownChecks, keepCounts = shownKeep }
    local totals = { healthChecks = total("healthChecks", #checkEntries), keepCounts = total("keepCounts", #names) }
    for _, listName in ipairs({"history", "errors"}) do
        local list, raw = map(), entries(source[listName])
        local key = listName == "history" and "telemetryHistoryEntries" or "telemetryErrorEntries"
        local fallback = listName == "history" and 40 or 20
        local maximum = listName == "history" and 200 or 100
        local limit = math.max(1, math.min(maximum, integer(config[key], fallback)))
        for index = math.max(1, #raw - limit + 1), #raw do
            if remaining < 100 then break end
            local event = map()
            fields(event, raw[index].value, EVENT_FIELDS)
            local rawContext = raw[index].value.context
            if type(rawContext) == "table" then
                local context = map()
                fields(context, rawContext, CONTEXT_FIELDS)
                if type(rawContext.item) == "table" then put(context, "item", rawContext.item.name) end
                if type(rawContext.intent)=="table" then
                    local intent=map()
                    fields(intent,rawContext.intent,INTENT_FIELDS)
                    local item=rawContext.intent.item
                    local itemName=type(item)=="table" and item.name or item
                    if type(itemName)=="string" then put(intent,"item",itemName) end
                    attach(context,"intent",intent)
                end
                attach(event, "context", context)
            end
            remaining = remaining - 1
            list[#list + 1] = event
        end
        shown[listName], totals[listName] = #list, total(listName, #raw)
        attach(view, listName, list)
    end

    local requests, rawRequests = map(), entries(source.requests)
    local limit = math.max(1, math.min(1024, integer(config.telemetryMaxRequests, 128)))
    for index = 1, math.min(limit, #rawRequests) do
        if remaining < 50 then break end
        local raw = rawRequests[index]
        local row = map()
        put(row, "id", text(raw.value.id or raw.value.requestId or raw.key, 128), 128)
        fields(row, raw.value, REQUEST_FIELDS)
        if type(raw.value.item) == "table" then put(row, "item", raw.value.item.name)
        else put(row, "item", raw.value.item) end
        remaining = remaining - 1
        requests[#requests + 1] = row
    end
    attach(view, "requests", requests)
    shown.requests, totals.requests = #requests, total("requests", #rawRequests)
    view.totals, view.shown = totals, shown
    local truncated = {}
    for key, count in pairs(totals) do
        if count > shown[key] then truncated[key] = count - shown[key] end
    end
    view.truncated = next(truncated) and truncated or false
    return view
end

function M.new(config, store, io, engine)
    local self = {}
    local caches, retired, startup = {}, {}, {}
    local counters = { received = 0, published = 0, rejected = 0, rejectedReasons = {} }
    local nextPublish, pending, sequence, bootId = 0, false, 0, nil

    local function interval()
        return math.max(1, math.min(3600, tonumber(config.telemetryIntervalSeconds) or 5))
    end
    local function route(id)
        for _, colony in ipairs(config.colonies or {}) do
            if tonumber(colony.id) == tonumber(id) then return colony end
        end
    end
    local function reject(reason, sender)
        counters.rejected = counters.rejected + 1
        counters.rejectedReasons[reason] = (counters.rejectedReasons[reason] or 0) + 1
        counters.lastRejected = { reason = reason, sender = sender, time = io.now() }
        if caches[tostring(sender)] then caches[tostring(sender)].lastRejected = copy(counters.lastRejected) end
        return false, reason
    end

    if config.role == "supply" then
        store.data.telemetry = type(store.data.telemetry) == "table" and store.data.telemetry or {}
        local state = store.data.telemetry
        state.bootCounter = integer(state.bootCounter) + 1
        local ok, err = store.save()
        if ok ~= true then error("Cannot persist telemetry boot identity: " .. tostring(err), 0) end
        local computerId = 0
        if os.getComputerID then
            local found, id = pcall(os.getComputerID)
            if found and finite(id) then computerId = id end
        end
        bootId = tostring(computerId) .. ":" .. string.format("%.0f", io.now() * 1000) .. ":" .. tostring(state.bootCounter)
    end

    function self.tick()
        local now = io.now()
        if config.role == "supply" then
            if now < nextPublish then return end
            nextPublish = now + interval()
            pending = false
            -- engine.snapshot is the cached domain view; the runtime adds its
            -- normal hardware checks. No bridge/request call is made here.
            local view = compact(engine.snapshot(), config)
            sequence = sequence + 1
            local ok, err = io.send(tonumber(config.masterId), {
                kind = "telemetry", version = 1, bootId = bootId,
                sequence = sequence, generatedAt = io.now(), snapshot = view,
            })
            counters.published = counters.published + 1
            counters.lastPublished = now
            counters.lastSendOk, counters.lastSendError = ok ~= false, err
            return
        end
        if config.role == "master" then
            local configured = {}
            for _, colony in ipairs(config.colonies or {}) do
                local id = tostring(colony.id)
                configured[id] = true
                if not startup[id] or startup[id].retryAt and now >= startup[id].retryAt then
                    local ok = io.send(colony.id, { kind = "telemetry_request", version = 1 })
                    startup[id] = ok ~= false and { sent = true } or { retryAt = now + interval() }
                end
            end
            for id in pairs(caches) do if not configured[id] then caches[id], retired[id] = nil, nil end end
            for id in pairs(startup) do if not configured[id] then startup[id] = nil end end
        end
    end

    function self.onMessage(sender, message)
        if type(message) ~= "table" or message.version ~= 1 then return false end
        if config.role == "supply" then
            if message.kind ~= "telemetry_request" or tonumber(sender) ~= tonumber(config.masterId) then return false end
            -- Repeated refresh clicks cannot cause repeated snapshots or
            -- inventory traffic. The next interval publishes one fresh view.
            pending = true
            return true
        end
        if config.role ~= "master" or message.kind ~= "telemetry" then return false end
        if not route(sender) then return reject("unknown colony", sender) end
        if type(message.bootId) ~= "string" or message.bootId == "" or #message.bootId > 256
            or not finite(message.sequence) or message.sequence < 1 or message.sequence % 1 ~= 0
            or not finite(message.generatedAt) or type(message.snapshot) ~= "table"
            or message.snapshot.role ~= "supply" then return reject("invalid telemetry", sender) end
        local id = tostring(tonumber(sender))
        local previous = caches[id]
        retired[id] = retired[id] or { ids = {}, order = {} }
        if retired[id].ids[message.bootId] then return reject("retired boot replay", sender) end
        if previous then
            if previous.bootId == message.bootId and message.sequence <= previous.sequence then
                return reject("stale sequence", sender)
            end
            if previous.bootId ~= message.bootId then
                -- Our boot IDs include epoch and persistent counter. The
                -- epoch allows deliberate clean reinstalls to reset counters.
                local _, incomingEpoch, incomingCounter = message.bootId:match("^(%d+):(%d+):(%d+)$")
                local _, previousEpoch, previousCounter = previous.bootId:match("^(%d+):(%d+):(%d+)$")
                if incomingEpoch and previousEpoch then
                    incomingEpoch, previousEpoch = tonumber(incomingEpoch), tonumber(previousEpoch)
                    incomingCounter, previousCounter = tonumber(incomingCounter), tonumber(previousCounter)
                    if incomingEpoch < previousEpoch or incomingEpoch == previousEpoch and incomingCounter <= previousCounter then
                        return reject("older boot replay", sender)
                    end
                elseif message.generatedAt <= previous.generatedAt then
                    return reject("older boot replay", sender)
                end
            end
        end
        local view = compact(message.snapshot, config)
        if previous and previous.bootId ~= message.bootId then
            local history = retired[id]
            history.ids[previous.bootId] = true
            history.order[#history.order + 1] = previous.bootId
            if #history.order > 32 then history.ids[table.remove(history.order, 1)] = nil end
        end
        caches[id] = {
            snapshot = view, receivedAt = io.now(), generatedAt = message.generatedAt,
            bootId = message.bootId, sequence = message.sequence,
            lastRejected = previous and previous.lastRejected,
        }
        counters.received = counters.received + 1
        return true
    end

    function self.get(colonyId)
        if config.role ~= "master" then return nil, "Remote colony telemetry is available on the master" end
        local colony = route(colonyId)
        if not colony then return nil, "Colony is not configured" end
        local id = tostring(tonumber(colony.id))
        local cached = caches[id]
        if not cached then
            return {
                role = "supply", colonyName = colony.name or colony.label or "Colony " .. id,
                health = { ok = false, connected = false, detail = "Waiting for the first colony telemetry snapshot", checks = {} },
                status = "waiting", requests = {}, colonies = {}, history = {}, errors = {},
                settings = {}, effectivePolicy = {}, turn = {}, totals = { requests = 0, history = 0, errors = 0 },
                shown = { requests = 0, history = 0, errors = 0 }, truncated = false,
                stale = false, offline = false, telemetry = { state = "waiting", computerId = colony.id,
                    colonyId = colony.id, stale = false, offline = false, truncated = false },
            }
        end
        local view = copy(cached.snapshot)
        local age = math.max(0, io.now() - cached.receivedAt)
        local sourceAge = math.max(0, io.now() - cached.generatedAt)
        local staleSeconds = math.max(2, tonumber(config.telemetryStaleSeconds) or 20)
        local stale = math.max(age, sourceAge) > staleSeconds
        local offlineSeconds = math.max(staleSeconds, tonumber(config.telemetryOfflineSeconds) or 60)
        local offline = math.max(age, sourceAge) > offlineSeconds
        view.receivedAt, view.generatedAt, view.stale, view.offline = cached.receivedAt, cached.generatedAt, stale, offline
        view.telemetry = {
            state = offline and "offline" or stale and "stale" or "online",
            computerId = colony.id, colonyId = colony.id, receivedAt = cached.receivedAt,
            generatedAt = cached.generatedAt, age = age, sourceAge = sourceAge,
            bootId = cached.bootId, sequence = cached.sequence, stale = stale, offline = offline,
            truncated = copy(view.truncated), lastRejected = copy(cached.lastRejected),
        }
        return view
    end

    function self.status()
        local out = copy(counters)
        out.role, out.pending, out.bootId, out.sequence = config.role, pending, bootId, sequence
        out.cachedColonies = 0
        for id in pairs(caches) do if route(id) then out.cachedColonies = out.cachedColonies + 1 end end
        out.retiredBoots = 0
        for _, history in pairs(retired) do out.retiredBoots = out.retiredBoots + #history.order end
        return out
    end

    return self
end

return M
