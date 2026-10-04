-- MineColonies Control Suite v3 - deterministic multi-colony PRS turn coordinator
local M = {}

local function now()
    if os.epoch then
        local ok, value = pcall(os.epoch, "utc")
        if ok and value then return value / 1000 end
    end
    return os.clock()
end

local function copySortedIds(set)
    local ids = {}
    for id, present in pairs(set or {}) do
        id = tonumber(id)
        if present and id then ids[#ids + 1] = id end
    end
    table.sort(ids)
    return ids
end

local function contains(ids, wanted)
    wanted = tonumber(wanted)
    for _, id in ipairs(ids or {}) do
        if id == wanted then return true end
    end
    return false
end

local function nextId(ids, current)
    if #ids == 0 then return nil end
    current = tonumber(current)
    for i, id in ipairs(ids) do
        if id == current then
            return ids[(i % #ids) + 1]
        end
    end
    return ids[1]
end

function M.new(config, store)
    local self = {
        id = tonumber(os.getComputerID and os.getComputerID() or 0) or 0,
        peers = {},
        memberNames = {},
        localName = nil,
        active = {},
        expected = {},
        masterId = nil,
        turnId = nil,
        generation = 0,
        initialized = false,
        modemCount = 0,
        lastHello = 0,
        lastStateBroadcast = 0,
        lastMasterSeen = 0,
        lastMembershipSignature = "",
        blockedUntil = 0,
        currentTurnStarted = 0,
        observedTurnId = nil,
        turnEligibleAt = 0,
        lastFault = nil,
        sharedPrsFault = nil,
    }

    local function setTurn(id)
        id = tonumber(id)
        if self.observedTurnId ~= id then
            self.observedTurnId = id
            local delay = math.max(
                0,
                tonumber(config.clusterTurnHandoffDelaySeconds) or 5
            )
            self.turnEligibleAt = now() + delay
            if id then
                store.log(
                    "CLUSTER turn=" .. tostring(id) ..
                    " handoff settle=" .. tostring(delay) .. "s"
                )
            end
        end
        self.turnId = id
    end

    local function rememberKnown(id)
        id = tonumber(id)
        if not id then return end
        store.data.cluster = store.data.cluster or { knownIds = {} }
        store.data.cluster.knownIds = store.data.cluster.knownIds or {}
        if store.data.cluster.knownIds[tostring(id)] ~= true then
            store.data.cluster.knownIds[tostring(id)] = true
            store.save()
        end
    end

    local function loadExpected()
        local expected = {}
        expected[self.id] = true
        for _, id in ipairs(config.clusterExpectedComputerIds or {}) do
            id = tonumber(id)
            if id then expected[id] = true end
        end
        local known = store.data.cluster and store.data.cluster.knownIds or {}
        for id, present in pairs(known) do
            id = tonumber(id)
            if present and id then expected[id] = true end
        end
        self.expected = expected
    end

    local function cleanName(value)
        local name = tostring(value or "")
        name = name:gsub("^%s+", ""):gsub("%s+$", "")
        if name == "" then return nil end
        return name
    end

    function self.setLocalName(name)
        name = cleanName(name)
        if not name then return false end
        self.localName = name
        self.memberNames[self.id] = name
        return true
    end

    local function namesSnapshot()
        local names = {}
        for id, name in pairs(self.memberNames or {}) do
            id = tonumber(id)
            name = cleanName(name)
            if id and name then names[tostring(id)] = name end
        end
        if self.localName then names[tostring(self.id)] = self.localName end
        return names
    end

    local function mergeNames(names)
        if type(names) ~= "table" then return end
        for id, name in pairs(names) do
            id = tonumber(id)
            name = cleanName(name)
            if id and name then self.memberNames[id] = name end
        end
    end

    function self.openModems()
        local count = 0
        for _, name in ipairs(peripheral.getNames()) do
            local types = { peripheral.getType(name) }
            local modem = false
            for _, t in ipairs(types) do
                if t == "modem" then modem = true break end
            end
            if modem then
                local ok = pcall(rednet.open, name)
                if ok then
                    local okOpen, opened = pcall(rednet.isOpen, name)
                    if okOpen and opened then count = count + 1 end
                end
            end
        end
        self.modemCount = count
        return count > 0
    end

    local function send(id, msg)
        if self.modemCount <= 0 then return false end
        local ok, sent = pcall(rednet.send, tonumber(id), msg, config.clusterProtocol)
        return ok and sent == true
    end

    local function broadcast(msg)
        if self.modemCount <= 0 then return false end
        local ok, sent = pcall(rednet.broadcast, msg, config.clusterProtocol)
        return ok and sent == true
    end

    local function activeSet()
        local t = now()
        local timeout = math.max(2, tonumber(config.clusterPeerTimeoutSeconds) or 8)
        local active = {[self.id] = true}
        for id, seen in pairs(self.peers) do
            id = tonumber(id)
            seen = tonumber(seen) or 0
            if id and (t - seen) <= timeout then
                active[id] = true
            end
        end
        self.active = active
        return active
    end

    local function prunePrsFault()
        local fault = self.sharedPrsFault
        if type(fault) ~= "table" then
            self.sharedPrsFault = nil
            return
        end

        local ttl = math.max(
            30,
            tonumber(config.clusterPrsFaultTimeoutSeconds) or 90
        )
        if now() - (tonumber(fault.time) or 0) > ttl then
            self.sharedPrsFault = nil
        end
    end

    local function recomputeMembership()
        prunePrsFault()
        loadExpected()
        local active = activeSet()
        local ids = copySortedIds(active)
        local signature = table.concat(ids, ",")
        if signature ~= self.lastMembershipSignature then
            self.lastMembershipSignature = signature
            self.blockedUntil = now() + math.max(0, tonumber(config.clusterMembershipSettleSeconds) or 3)
            self.generation = self.generation + 1
            store.log("CLUSTER membership=" .. signature .. " generation=" .. tostring(self.generation))
        end
        self.masterId = ids[1]
        return ids
    end

    local function faultStatus()
        if config.clusterEnabled ~= true then return nil end
        if self.modemCount <= 0 then return "no rednet modem open" end

        local ids = recomputeMembership()
        local minimum = math.max(1, math.floor(tonumber(config.clusterMinimumSize) or 2))
        if #ids < minimum then
            return "cluster has " .. tostring(#ids) .. "/" .. tostring(minimum) .. " required member(s)"
        end

        local missing = {}
        for id, expected in pairs(self.expected) do
            if expected and not self.active[id] then missing[#missing + 1] = tonumber(id) end
        end
        table.sort(missing)
        if #missing > 0 then
            local s = {}
            for _, id in ipairs(missing) do s[#s + 1] = tostring(id) end
            return "lost contact with computer(s): " .. table.concat(s, ",")
        end

        local settle = self.blockedUntil - now()
        if settle > 0 then
            return "cluster membership settling " .. tostring(math.ceil(settle)) .. "s"
        end

        if not self.masterId then return "no cluster master" end

        if self.id ~= self.masterId then
            local masterSeen = self.peers[self.masterId]
            local timeout = math.max(2, tonumber(config.clusterMasterTimeoutSeconds) or 5)
            if not masterSeen or (now() - masterSeen) > timeout then
                return "master computer " .. tostring(self.masterId) .. " not responding"
            end
        end
        return nil
    end

    local function masterAdvance(reason)
        if self.id ~= self.masterId then return end
        local ids = copySortedIds(self.active)
        if #ids == 0 then return end
        if not self.turnId or not contains(ids, self.turnId) then
            setTurn(ids[1])
        else
            setTurn(nextId(ids, self.turnId))
        end
        self.currentTurnStarted = now()
        store.data.cluster.lastMasterId = self.masterId
        store.data.cluster.lastTurnId = self.turnId
        store.save()
        broadcast({
            kind = "state",
            version = 3,
            masterId = self.masterId,
            turnId = self.turnId,
            generation = self.generation,
            memberNames = namesSnapshot(),
            reason = tostring(reason or "advance"),
        })
    end

    function self.handle(sender, msg)
        sender = tonumber(sender)
        if not sender or sender == self.id or type(msg) ~= "table" then return end
        self.peers[sender] = now()
        local incomingName = cleanName(msg.colonyName)
        if incomingName then self.memberNames[sender] = incomingName end
        mergeNames(msg.memberNames)
        rememberKnown(sender)
        recomputeMembership()

        local kind = tostring(msg.kind or "")
        if kind == "hello" then
            if self.id == self.masterId then
                if not self.turnId then
                    setTurn(copySortedIds(self.active)[1])
                    self.currentTurnStarted = now()
                end
                broadcast({
                    kind = "state",
                    version = 3,
                    masterId = self.masterId,
                    turnId = self.turnId,
                    generation = self.generation,
                    memberNames = namesSnapshot(),
                    reason = "hello-sync",
                })
            end
        elseif kind == "state" then
            if sender == self.masterId and tonumber(msg.masterId) == self.masterId then
                setTurn(msg.turnId)
                self.generation = math.max(self.generation, tonumber(msg.generation) or self.generation)
                mergeNames(msg.memberNames)
                self.lastMasterSeen = now()
            end
        elseif kind == "release_turn" then
            if self.id == self.masterId and sender == self.turnId then
                masterAdvance("release from " .. tostring(sender))
            end
        elseif kind == "hold_turn" then
            -- The current turn owner may hold the shared PRS lease while an
            -- asynchronous RS craft is running/settling. Refreshing the lease
            -- prevents the master timeout from handing PRS to another colony.
            if self.id == self.masterId and sender == self.turnId then
                self.currentTurnStarted = now()
            end
        elseif kind == "fault" then
            self.lastFault = {
                id = sender,
                detail = tostring(msg.detail or "peer fault"),
                time = now(),
            }
        elseif kind == "prs_fault" then
            self.sharedPrsFault = {
                id = sender,
                name = incomingName
                    or self.memberNames[sender]
                    or ("Computer " .. tostring(sender)),
                scope = tostring(msg.scope or "PRS"),
                item = tostring(msg.item or "?"),
                detail = tostring(msg.detail or "shared PRS desync"),
                time = now(),
            }
        elseif kind == "prs_clear" then
            local current = self.sharedPrsFault
            if type(current) == "table"
                and tonumber(current.id) == sender then
                self.sharedPrsFault = nil
            end
        end
    end

    function self.tick()
        if config.clusterEnabled ~= true then
            self.masterId = self.id
            setTurn(self.id)
            return
        end
        if self.modemCount <= 0 then self.openModems() end
        local t = now()
        if t - self.lastHello >= math.max(0.5, tonumber(config.clusterHelloSeconds) or 1) then
            self.lastHello = t
            broadcast({
                kind = "hello",
                version = 3,
                id = self.id,
                colonyName = self.localName,
                memberNames = namesSnapshot(),
                programVersion = config.PROGRAM_VERSION,
            })
        end

        recomputeMembership()
        local fault = faultStatus()
        if fault then
            if self.lastFault ~= fault then
                self.lastFault = fault
                store.log("CLUSTER BLOCKED: " .. fault)
            end
            if self.id == self.masterId then
                setTurn(nil)
                broadcast({
                    kind = "state",
                    version = 3,
                    masterId = self.masterId,
                    turnId = nil,
                    generation = self.generation,
                    memberNames = namesSnapshot(),
                    reason = "fault: " .. fault,
                })
            end
            return
        end

        if self.id == self.masterId then
            if not self.turnId or not self.active[self.turnId] then
                setTurn(copySortedIds(self.active)[1])
                self.currentTurnStarted = t
            end

            local timeout = math.max(10, tonumber(config.clusterTurnTimeoutSeconds) or 45)
            if self.currentTurnStarted > 0 and (t - self.currentTurnStarted) > timeout then
                store.addError(
                    "TURN_TIMEOUT",
                    "Computer " .. tostring(self.turnId) .. " exceeded its PRS turn timeout",
                    { masterId = self.masterId, turnId = self.turnId, seconds = t - self.currentTurnStarted },
                    "WARNING"
                )
                masterAdvance("turn timeout")
            elseif t - self.lastStateBroadcast >= math.max(0.25, tonumber(config.clusterStateBroadcastSeconds) or 0.75) then
                self.lastStateBroadcast = t
                broadcast({
                    kind = "state",
                    version = 3,
                    masterId = self.masterId,
                    turnId = self.turnId,
                    generation = self.generation,
                    memberNames = namesSnapshot(),
                    reason = "heartbeat",
                })
            end
        end
    end

    function self.status()
        self.tick()
        local fault = faultStatus()
        local activeIds = copySortedIds(self.active)
        local expectedIds = copySortedIds(self.expected)
        local names = namesSnapshot()
        local members = {}
        for _, id in ipairs(activeIds) do
            members[#members + 1] = {
                id = id,
                name = names[tostring(id)] or ("Computer " .. tostring(id)),
            }
        end
        return {
            id = self.id,
            ok = fault == nil,
            fault = fault,
            masterId = self.masterId,
            turnId = self.turnId,
            role = self.masterId == self.id and "MASTER" or "MEMBER",
            activeIds = activeIds,
            expectedIds = expectedIds,
            memberNames = names,
            members = members,
            activeCount = #activeIds,
            expectedCount = #expectedIds,
            turnSettleRemaining =
                (self.turnId == self.id)
                and math.max(0, self.turnEligibleAt - now())
                or 0,
            prsFault = self.sharedPrsFault,
        }
    end

    function self.canAccessPRS()
        if config.clusterEnabled ~= true then return true, self.status() end
        local s = self.status()
        local settled =
            (tonumber(s.turnSettleRemaining) or 0) <= 0
        return s.ok
            and s.turnId == self.id
            and settled,
            s
    end

    function self.releaseTurn(reason)
        if config.clusterEnabled ~= true then return true end
        local s = self.status()
        if not s.ok or s.turnId ~= self.id then return false end
        if self.id == self.masterId then
            masterAdvance(reason or "local release")
        else
            send(self.masterId, {
                kind = "release_turn",
                version = 3,
                id = self.id,
                reason = tostring(reason or "release"),
            })
        end
        return true
    end

    function self.holdTurn(reason)
        if config.clusterEnabled ~= true then return true end
        local s = self.status()
        if not s.ok or s.turnId ~= self.id then return false end

        if self.id == self.masterId then
            self.currentTurnStarted = now()
        else
            send(self.masterId, {
                kind = "hold_turn",
                version = 3,
                id = self.id,
                reason = tostring(reason or "PRS busy"),
            })
        end
        return true
    end

    function self.broadcastFault(detail)
        broadcast({ kind = "fault", version = 3, id = self.id, detail = tostring(detail or "fault") })
    end

    function self.broadcastPRSFault(scope, item, detail)
        self.sharedPrsFault = {
            id = self.id,
            name = self.localName or ("Computer " .. tostring(self.id)),
            scope = tostring(scope or "PRS"),
            item = tostring(item or "?"),
            detail = tostring(detail or "shared PRS desync"),
            time = now(),
        }
        broadcast({
            kind = "prs_fault",
            version = 3,
            id = self.id,
            colonyName = self.localName,
            scope = self.sharedPrsFault.scope,
            item = self.sharedPrsFault.item,
            detail = self.sharedPrsFault.detail,
        })
        return true
    end

    function self.clearPRSFault(detail)
        local prior = self.sharedPrsFault
        if type(prior) == "table"
            and tonumber(prior.id) == self.id then
            self.sharedPrsFault = nil
        end
        broadcast({
            kind = "prs_clear",
            version = 3,
            id = self.id,
            colonyName = self.localName,
            detail = tostring(detail or "PRS recovered"),
        })
        return true
    end

    function self.loop()
        self.openModems()
        rememberKnown(self.id)
        self.initialized = true
        while true do
            self.tick()
            local timer = os.startTimer(0.25)
            while true do
                local ev, a, b, c = os.pullEvent()
                if ev == "rednet_message" and c == config.clusterProtocol then
                    self.handle(a, b)
                elseif ev == "peripheral" or ev == "peripheral_detach" then
                    self.openModems()
                elseif ev == "timer" and a == timer then
                    break
                end
            end
        end
    end

    return self
end

return M