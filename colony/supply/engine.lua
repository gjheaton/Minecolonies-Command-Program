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

local function requestSignature(request, count)
    local parts = { tostring(request.id or "?"), tostring(count or 0), tostring(request.name or "") }
    if type(request.items) == "table" then
        local names = {}
        for _, item in pairs(request.items) do
            if type(item) == "table" and item.name then
                names[#names + 1] = tostring(item.name) .. "|" .. tostring(item.nbt or "")
            end
        end
        table.sort(names)
        for _, v in ipairs(names) do parts[#parts + 1] = v end
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
        if self.startupRunning then return false end
        self.startupRunning = true
        self.startupReady = false
        store.markStartupComplete(false)

        local okRefresh = transfer.refresh()
        setCheck("peripherals", okRefresh,
            okRefresh and "PRS, CRS, colony integrator, warehouse and transfer chest online"
                or "one or more required peripherals are unavailable")

        local okFunctions, functionDetail = functionChecks()
        setCheck("functions", okFunctions, functionDetail)

        local legacyPending = store.data.migration and store.data.migration.legacyPendingDetected
        if legacyPending then
            setCheck("legacy_pending", false,
                "v2 pending transaction detected in legacy state; v3 will not assume its outcome",
                "WARNING")
        else
            setCheck("legacy_pending", true, "no legacy v2 pending transaction detected")
        end

        local okPending, pendingDetail = transfer.recoverPending()
        setCheck("pending", okPending, pendingDetail)

        local empty, emptyDetail = transfer.chestEmpty()
        setCheck("chest_empty", empty, empty and "transfer chest empty" or tostring(emptyDetail or "transfer chest occupied"))

        local clusterStatus = cluster.status()
        setCheck("cluster", clusterStatus.ok,
            clusterStatus.ok
                and ("cluster online; master=" .. tostring(clusterStatus.masterId) ..
                    " active=" .. table.concat(clusterStatus.activeIds, ","))
                or tostring(clusterStatus.fault))

        local canPRS = cluster.canAccessPRS()
        local movementOK, movementDetail = false, "waiting for this computer's PRS turn"
        if canPRS and okRefresh and okFunctions and okPending and empty then
            movementOK, movementDetail = transfer.startupRoundTrip()
        end
        setCheck("movement", movementOK, movementDetail)

        local desyncOK, desyncDetail = desyncHeuristic()
        setCheck("desync", desyncOK, desyncDetail,
            store.data.desync and store.data.desync.suspected and "WARNING" or "OK")

        local fatal = not (okRefresh and okFunctions and okPending and empty and clusterStatus.ok and movementOK)
        self.startupReady = not fatal
        store.markStartupComplete(self.startupReady)
        if fatal then
            store.addError("STARTUP_BLOCKED", "Supply v3 startup health checks did not pass",
                { checks = store.data.startup.checks }, "ERROR")
            cluster.broadcastFault("startup checks failed")
        else
            store.addHistory("STARTUP", { detail = "all required startup checks passed" })
        end

        self.startupRunning = false
        return self.startupReady
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
        if left > 0 then return false, "craft error cooldown " .. tostring(left) .. "s: " .. tostring(reason) end

        local last = tonumber(store.data.craftJobs[key]) or 0
        if nowSeconds() - last < (tonumber(config.craftCooldownSeconds) or 30) then
            return true, "craft cooldown"
        end

        local craftable, source = matcher.craftable(transfer.playerRS, candidate, safeCall)
        if not craftable then return false, source end

        local filter = matcher.craftFilter(candidate, math.max(1, floor(count)))
        if candidate.hasNBT and filter.nbt == nil then return false, "exact NBT cannot be represented for crafting" end

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
            return false, "craftItem error: " .. tostring(err or started)
        end
        if started == true then
            store.data.craftJobs[key] = nowSeconds()
            store.data.craftFailures[key] = nil
            store.save()
            store.addHistory("CRAFT", { item=candidate.name, amount=count, detail="started via " .. tostring(source) })
            return true, "craft started"
        end
        return false, tostring(err or "RS refused craft")
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

    local function processRequest(request)
        local count = requestCount(request)
        local signature = requestSignature(request, count)
        local ledger = ledgerFor(request.id)

        if ledger.signature and ledger.signature ~= signature then
            store.log("REQUEST changed id=" .. tostring(request.id) .. "; clearing WAITING ACK gate")
            ledger.signature = nil
            ledger.sent = nil
            ledger.sentAt = nil
            ledger.item = nil
        end

        if ledger.signature == signature and floor(ledger.sent) > 0 then
            local age = nowSeconds() - (tonumber(ledger.sentAt) or nowSeconds())
            local detail = "WAITING ACK; sent " .. tostring(ledger.sent) ..
                " " .. tostring(ledger.item or "") .. " " .. tostring(age) .. "s ago"
            if age >= (tonumber(config.requestAckWarnSeconds) or 120) then
                detail = detail .. " (acknowledgement delayed)"
            end
            return {
                id=tostring(request.id), name=tostring(request.name or "Request"), requested=count,
                item=tostring(ledger.item or "?"), status="WAITING ACK", detail=detail,
            }
        end

        local candidate, class, chooseErr = matcher.choose(request, transfer.playerRS, safeCall, count)
        if not candidate then
            return {
                id=tostring(request.id), name=tostring(request.name or "Request"), requested=count,
                item="-", status="BLOCKED",
                detail=tostring(chooseErr or ("no acceptable " .. tostring(class or "item") .. " candidate")),
            }
        end

        if candidate.stock > 0 then
            local amount = math.min(count, candidate.stock, floor(config.maxTransferChunk or 64))
            local ok, movedOrErr = transfer.playerToColony(candidate, amount, {
                requestId=request.id, detail="MineColonies request " .. tostring(request.name or request.id)
            })
            if ok then
                ledger.signature = signature
                ledger.sent = floor(movedOrErr)
                ledger.sentAt = nowSeconds()
                ledger.item = candidate.name
                ledger.identity = candidate.identity
                store.save()
                return {
                    id=tostring(request.id), name=tostring(request.name or "Request"), requested=count,
                    item=candidate.name, status="WAITING ACK",
                    detail="verified sent " .. tostring(movedOrErr) .. "; awaiting MineColonies acknowledgement",
                }
            end
            store.addError("SUPPLY_TRANSFER", "PRS->CRS request transfer failed",
                { requestId=request.id, item=candidate.name, count=amount, detail=movedOrErr }, "ERROR")
            return {
                id=tostring(request.id), name=tostring(request.name or "Request"), requested=count,
                item=candidate.name, status="ERROR", detail=tostring(movedOrErr),
            }
        end

        if candidate.craftable and store.data.settings.autoCraftEnabled == true then
            local ok, detail = startCraft(candidate, count)
            return {
                id=tostring(request.id), name=tostring(request.name or "Request"), requested=count,
                item=candidate.name, status=ok and "CRAFTING" or "BLOCKED", detail=tostring(detail),
            }
        end

        return {
            id=tostring(request.id), name=tostring(request.name or "Request"), requested=count,
            item=candidate.name, status="MISSING",
            detail=candidate.craftable and "AutoCraft disabled" or tostring(candidate.craftSource or "no exact stock or recipe"),
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
        for _, request in pairs(requests) do
            if requestActive(request) then
                local id = tostring(request.id)
                active[id] = true
                self.stats.active = self.stats.active + 1
                local row = processRequest(request)
                self.rows[#self.rows + 1] = row
                if row.status == "WAITING ACK" then self.stats.waiting = self.stats.waiting + 1
                elseif row.status == "CRAFTING" then self.stats.crafting = self.stats.crafting + 1
                elseif row.status == "ERROR" then self.stats.errors = self.stats.errors + 1
                elseif row.status == "BLOCKED" or row.status == "MISSING" then self.stats.blocked = self.stats.blocked + 1
                else self.stats.ready = self.stats.ready + 1 end

                -- Exactly one PRS mutation per turn. A transfer or craft consumes
                -- this colony's turn, which prevents same-turn multi-request races.
                if row.status == "WAITING ACK" or row.status == "CRAFTING" or row.status == "ERROR" then
                    break
                end
            end
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
