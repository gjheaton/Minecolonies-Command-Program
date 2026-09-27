-- MineColonies Control Suite v3 - Supply state/history/error store
local Util = require("colony.lib.util")

local M = {}

local function nowSeconds()
    if os.epoch then
        local ok, value = pcall(os.epoch, "utc")
        if ok and value then return math.floor(value / 1000) end
    end
    return math.floor(os.clock())
end

local function ensureDir(path)
    local dir = fs.getDir(path)
    if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
end

local function safeValue(value, depth, seen)
    depth = depth or 0
    seen = seen or {}
    local t = type(value)
    if t == "nil" or t == "boolean" or t == "number" or t == "string" then
        return value
    end
    if t ~= "table" then return tostring(value) end
    if depth >= 3 then return "<table>" end
    if seen[value] then return "<shared/cyclic table>" end
    seen[value] = true
    local out = {}
    local count = 0
    for k, v in pairs(value) do
        count = count + 1
        if count > 30 then
            out["..."] = "truncated"
            break
        end
        out[tostring(k)] = safeValue(v, depth + 1, seen)
    end
    seen[value] = nil
    return out
end

local function defaultData(config)
    return {
        schema = 3,
        created = nowSeconds(),
        pending = nil,
        requestLedger = {},
        craftJobs = {},
        craftFailures = {},
        recovery = {
            orphanChest = nil,
        },
        history = {},
        errors = {},
        cluster = {
            knownIds = {},
            lastMasterId = nil,
            lastTurnId = nil,
        },
        settings = {
            overstockEnabled = config.overstockEnabledDefault == true,
            overstockKeep = {},
            stackSizes = {},
            autoCraftEnabled = true,
            transferChestName = nil,
        },
        startup = {
            complete = false,
            checks = {},
            lastRun = nil,
        },
        desync = {
            suspected = false,
            detail = nil,
            time = nil,
        },
        migration = {},
    }
end

local function mergeDefaults(data, config)
    local base = defaultData(config)
    if type(data) ~= "table" then return base end
    data.schema = 3
    data.pending = data.pending
    data.requestLedger = type(data.requestLedger) == "table" and data.requestLedger or {}
    data.craftJobs = type(data.craftJobs) == "table" and data.craftJobs or {}
    data.craftFailures = type(data.craftFailures) == "table" and data.craftFailures or {}
    data.recovery = type(data.recovery) == "table" and data.recovery or base.recovery
    data.recovery.orphanChest = data.recovery.orphanChest
    data.history = type(data.history) == "table" and data.history or {}
    data.errors = type(data.errors) == "table" and data.errors or {}
    data.cluster = type(data.cluster) == "table" and data.cluster or base.cluster
    data.cluster.knownIds = type(data.cluster.knownIds) == "table" and data.cluster.knownIds or {}
    data.settings = type(data.settings) == "table" and data.settings or base.settings
    if data.settings.overstockEnabled == nil then data.settings.overstockEnabled = base.settings.overstockEnabled end
    data.settings.overstockKeep = type(data.settings.overstockKeep) == "table" and data.settings.overstockKeep or {}
    data.settings.stackSizes = type(data.settings.stackSizes) == "table" and data.settings.stackSizes or {}
    if data.settings.autoCraftEnabled == nil then data.settings.autoCraftEnabled = true end
    data.startup = type(data.startup) == "table" and data.startup or base.startup
    data.startup.checks = type(data.startup.checks) == "table" and data.startup.checks or {}
    data.desync = type(data.desync) == "table" and data.desync or base.desync
    data.migration = type(data.migration) == "table" and data.migration or {}
    return data
end

function M.new(config)
    local self = {
        config = config,
        data = nil,
    }

    function self.log(message)
        ensureDir(config.logFile)
        if fs.exists(config.logFile) then
            local ok, size = pcall(fs.getSize, config.logFile)
            if ok and size and size >= (tonumber(config.maxLogBytes) or 65536) then
                local old = config.logFile .. ".old"
                if fs.exists(old) then pcall(fs.delete, old) end
                pcall(fs.move, config.logFile, old)
            end
        end
        local h = fs.open(config.logFile, "a")
        if h then
            h.writeLine("[" .. Util.timeString() .. "] " .. tostring(message))
            h.close()
        end
    end

    function self.save()
        if not self.data then return false, "state not loaded" end
        ensureDir(config.stateFile)
        local tmp = config.stateFile .. ".tmp"
        local bak = config.stateFile .. ".bak"
        local okSerialize, body = pcall(textutils.serialize, self.data)
        if not okSerialize then
            self.log("ERROR state serialization failed: " .. tostring(body))
            return false, tostring(body)
        end
        local h = fs.open(tmp, "w")
        if not h then return false, "cannot open state temp file" end
        h.write(body)
        h.close()
        if fs.exists(bak) then pcall(fs.delete, bak) end
        if fs.exists(config.stateFile) then
            local okMove = pcall(fs.move, config.stateFile, bak)
            if not okMove then pcall(fs.delete, config.stateFile) end
        end
        local okMove, err = pcall(fs.move, tmp, config.stateFile)
        if not okMove then
            self.log("ERROR state replace failed: " .. tostring(err))
            return false, tostring(err)
        end
        if fs.exists(bak) then pcall(fs.delete, bak) end
        return true
    end

    local function migrateLegacy(data)
        if data.migration and data.migration.v2Examined then return end
        data.migration = data.migration or {}
        data.migration.v2Examined = true
        if not config.legacyStateFile or not fs.exists(config.legacyStateFile) then return end
        local legacy = Util.readSerializedTable(config.legacyStateFile)
        if type(legacy) ~= "table" then
            data.migration.v2ReadError = true
            return
        end
        data.migration.v2Detected = true
        if legacy.pending ~= nil then
            data.migration.legacyPendingDetected = safeValue(legacy.pending)
        end
        if type(legacy.settings) == "table" then
            if type(legacy.settings.stackSizes) == "table" then
                for k, v in pairs(legacy.settings.stackSizes) do
                    if data.settings.stackSizes[k] == nil then data.settings.stackSizes[k] = v end
                end
            end
            if legacy.settings.autoCraftEnabled ~= nil then
                data.settings.autoCraftEnabled = legacy.settings.autoCraftEnabled == true
            end
            if legacy.settings.transferChestName then
                data.settings.transferChestName = tostring(legacy.settings.transferChestName)
            end
        end
        if type(legacy.history) == "table" then
            local max = math.min(#legacy.history, math.floor((tonumber(config.maxHistoryEntries) or 400) / 2))
            for i = max, 1, -1 do
                local e = legacy.history[i]
                if type(e) == "table" then
                    table.insert(data.history, 1, {
                        epoch = tonumber(e.epoch) or nowSeconds(),
                        time = tostring(e.time or "--:--:--"),
                        kind = "LEGACY",
                        direction = tostring(e.direction or "?"),
                        item = tostring(e.item or "?"),
                        amount = tonumber(e.amount) or 0,
                        requestId = e.requestId and tostring(e.requestId) or nil,
                        detail = e.note and tostring(e.note) or "Imported from v2 history",
                    })
                end
            end
        end
    end

    function self.load()
        local data = Util.readSerializedTable(config.stateFile)
        if not data then data = Util.readSerializedTable(config.stateFile .. ".bak") end
        self.data = mergeDefaults(data, config)
        migrateLegacy(self.data)
        self.save()
        self.log("State loaded schema=3")
        return self.data
    end

    function self.addHistory(kind, fields)
        local d = self.data
        d.history = d.history or {}
        fields = fields or {}
        local e = {
            epoch = nowSeconds(),
            time = Util.timeString(),
            kind = tostring(kind or "EVENT"),
            direction = fields.direction and tostring(fields.direction) or nil,
            item = fields.item and tostring(fields.item) or nil,
            amount = tonumber(fields.amount) or nil,
            requestId = fields.requestId and tostring(fields.requestId) or nil,
            detail = fields.detail and tostring(fields.detail) or nil,
            computerId = os.getComputerID and os.getComputerID() or nil,
        }
        table.insert(d.history, 1, e)
        local max = math.max(20, tonumber(config.maxHistoryEntries) or 400)
        while #d.history > max do table.remove(d.history) end
        self.save()
        self.log("HISTORY " .. e.kind .. " " .. tostring(e.direction or "") .. " " ..
            tostring(e.item or "") .. " x" .. tostring(e.amount or "") .. " " .. tostring(e.detail or ""))
        return e
    end

    function self.addError(code, message, context, severity)
        local d = self.data
        d.errors = d.errors or {}
        local e = {
            epoch = nowSeconds(),
            time = Util.timeString(),
            code = tostring(code or "ERROR"),
            message = tostring(message or "Unknown error"),
            severity = tostring(severity or "ERROR"),
            context = safeValue(context),
        }
        table.insert(d.errors, 1, e)
        local max = math.max(20, tonumber(config.maxErrorEntries) or 100)
        while #d.errors > max do table.remove(d.errors) end
        self.save()
        self.log(e.severity .. " " .. e.code .. ": " .. e.message)
        return e
    end

    function self.clearErrors()
        self.data.errors = {}
        self.save()
    end

    function self.setPending(pending)
        self.data.pending = pending and safeValue(pending) or nil
        return self.save()
    end

    function self.setStartupCheck(id, ok, detail, severity)
        self.data.startup = self.data.startup or { checks = {} }
        self.data.startup.checks = self.data.startup.checks or {}
        self.data.startup.checks[id] = {
            ok = ok == true,
            detail = tostring(detail or ""),
            severity = tostring(severity or (ok and "OK" or "ERROR")),
            time = Util.timeString(),
            epoch = nowSeconds(),
        }
        self.data.startup.lastRun = nowSeconds()
        return self.save()
    end

    function self.markStartupComplete(ok)
        self.data.startup.complete = ok == true
        self.data.startup.lastRun = nowSeconds()
        return self.save()
    end

    function self.setDesync(suspected, detail)
        self.data.desync = {
            suspected = suspected == true,
            detail = tostring(detail or ""),
            time = nowSeconds(),
        }
        return self.save()
    end

    return self
end

return M
