-- MineColonies Control Suite v3 - verified transactional PRS/CRS transfer layer
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

local function hasType(name, wanted)
    if not name or not peripheral.isPresent(name) then return false end
    local ok, result = pcall(peripheral.hasType, name, wanted)
    if ok then return result == true end
    for _, t in ipairs({peripheral.getType(name)}) do
        if t == wanted then return true end
    end
    return false
end

function M.new(config, store, matcher)
    local self = {
        playerRS = nil,
        colonyRS = nil,
        colony = nil,
        monitor = nil,
        transferChestName = nil,
        playerBridgeName = nil,
        colonyBridgeName = nil,
        colonyName = "Unknown Colony",
        health = {
            colony = false,
            playerRS = false,
            colonyRS = false,
            warehouse = false,
            transferChest = false,
            transferChestItemCount = nil,
            transferChestStackCount = nil,
        },
    }

    function self.safeCall(obj, method, ...)
        if not obj then return false, nil, "peripheral unavailable" end
        local fn = obj[method]
        if type(fn) ~= "function" then return false, nil, "missing method " .. tostring(method) end
        local ok, a, b, c, d = pcall(fn, ...)
        if not ok then return false, nil, tostring(a) end
        return true, a, b, c, d
    end

    local function supportsPeripheralTransfer(bridge)
        return bridge
            and type(bridge.exportItemToPeripheral) == "function"
            and type(bridge.importItemFromPeripheral) == "function"
    end

    local function bridgeInfo(bridge)
        local disk, external = 0, 0
        local okDisk, vDisk = self.safeCall(bridge, "getMaxItemDiskStorage")
        if okDisk then disk = tonumber(vDisk) or 0 end
        local okExt, vExt = self.safeCall(bridge, "getMaxItemExternalStorage")
        if okExt then external = tonumber(vExt) or 0 end
        return disk, external
    end

    local function resolveBridgeByName(name)
        if not name or not peripheral.isPresent(name) or not hasType(name, "rsBridge") then return nil, nil end
        return peripheral.wrap(name), name
    end

    local function allBridges()
        local list = { peripheral.find("rsBridge") }
        local out = {}
        for _, bridge in ipairs(list) do
            local okName, name = pcall(peripheral.getName, bridge)
            local disk, external = bridgeInfo(bridge)
            out[#out + 1] = { bridge = bridge, name = okName and name or nil, disk = disk, external = external }
        end
        return out
    end

    local function resolveBridges()
        local p, pn = resolveBridgeByName(config.playerBridgeName)
        local c, cn = resolveBridgeByName(config.colonyBridgeName)
        local all = allBridges()

        if not p then
            for _, b in ipairs(all) do
                if b.disk > 0 and (not p or b.disk > (p.disk or -1)) then
                    p, pn = b.bridge, b.name
                end
            end
        end
        if not c then
            for _, b in ipairs(all) do
                if b.disk == 0 and b.external > 0 and b.name ~= pn then
                    c, cn = b.bridge, b.name
                    break
                end
            end
        end
        if p and not c then
            local other
            for _, b in ipairs(all) do
                if b.name ~= pn then
                    if other then other = nil break else other = b end
                end
            end
            if other then c, cn = other.bridge, other.name end
        end
        if c and not p then
            local other
            for _, b in ipairs(all) do
                if b.name ~= cn then
                    if other then other = nil break else other = b end
                end
            end
            if other then p, pn = other.bridge, other.name end
        end

        self.playerRS, self.playerBridgeName = p, pn
        self.colonyRS, self.colonyBridgeName = c, cn
        return p ~= nil and c ~= nil and pn ~= cn
    end

    local function resolveColony()
        local c
        if config.colonyIntegratorName and peripheral.isPresent(config.colonyIntegratorName)
            and hasType(config.colonyIntegratorName, "colonyIntegrator") then
            c = peripheral.wrap(config.colonyIntegratorName)
        else
            c = peripheral.find("colonyIntegrator")
        end
        if not c then self.colony = nil return false end
        local okInside, inside = self.safeCall(c, "isInColony")
        if not okInside or inside ~= true then self.colony = nil return false end
        self.colony = c
        local okName, name = self.safeCall(c, "getColonyName")
        if okName and name then self.colonyName = tostring(name) end
        return true
    end

    local function looksLikeBarrel(name)
        if not name then return false end
        local text = tostring(name):lower()
        local types = table.concat({peripheral.getType(name)}, ","):lower()
        return text:find("barrel",1,true) ~= nil
            or text:find("sophisticated",1,true) ~= nil
            or types:find("barrel",1,true) ~= nil
            or types:find("sophisticated",1,true) ~= nil
    end

    local function resolveChest()
        local candidates = {}
        local saved = store.data.settings and store.data.settings.transferChestName or nil
        local preferred = config.transferChestName or saved
        if preferred and peripheral.isPresent(preferred) and hasType(preferred, "inventory") then
            self.transferChestName = preferred
            return true
        end
        for _, name in ipairs(peripheral.getNames()) do
            if hasType(name, "inventory") and looksLikeBarrel(name) then
                candidates[#candidates + 1] = name
            end
        end
        if #candidates == 1 then
            self.transferChestName = candidates[1]
            store.data.settings.transferChestName = candidates[1]
            store.save()
            return true
        end
        self.transferChestName = nil
        return false
    end

    function self.getChest()
        if not self.transferChestName or not peripheral.isPresent(self.transferChestName) then resolveChest() end
        if not self.transferChestName then return nil end
        return peripheral.wrap(self.transferChestName)
    end

    function self.refresh()
        local colonyOK = resolveColony()
        local bridgesOK = resolveBridges()
        local chestOK = resolveChest()
        self.health.colony = colonyOK
        self.health.playerRS = false
        self.health.colonyRS = false
        self.health.warehouse = false
        self.health.transferChest = chestOK
        self.health.transferChestItemCount = nil
        self.health.transferChestStackCount = nil

        if chestOK then
            local list = self.chestContents()
            if type(list) == "table" then
                local items, stacks = 0, 0
                for _, item in pairs(list) do
                    if type(item) == "table" then
                        items = items + floor(item.count)
                        stacks = stacks + 1
                    end
                end
                self.health.transferChestItemCount = items
                self.health.transferChestStackCount = stacks
            end
        end

        if bridgesOK and self.playerRS then
            self.health.playerRS =
                select(1, self.safeCall(
                    self.playerRS, "getEnergyStorage"))
        end
        if bridgesOK and self.colonyRS then
            self.health.colonyRS =
                select(1, self.safeCall(
                    self.colonyRS, "getEnergyStorage"))
            if self.health.colonyRS then
                local _, ext = bridgeInfo(self.colonyRS)
                self.health.warehouse = ext > 0
            end
        end

        if config.usePeripheralTransfer then
            local peripheralOK =
                supportsPeripheralTransfer(self.playerRS)
                and supportsPeripheralTransfer(self.colonyRS)
            if not peripheralOK then
                self.health.playerRS = false
                self.health.colonyRS = false
                store.log(
                    "ERROR exact peripheral transfer enabled but one or " ..
                    "both RS Bridges lack import/export peripheral methods"
                )
            end
        end

        return colonyOK and bridgesOK
            and self.health.playerRS
            and self.health.colonyRS
            and chestOK
    end

    function self.chestContents()
        local chest = self.getChest()
        if not chest then return nil, "transfer chest unavailable" end
        local ok, list = pcall(chest.list)
        if not ok or type(list) ~= "table" then return nil, tostring(list) end
        return list
    end

    function self.chestEmpty()
        local list, err = self.chestContents()
        if not list then return false, err end
        return next(list) == nil
    end

    function self.chestSnapshot()
        local list, err = self.chestContents()
        if not list then return nil, err end

        local chest = self.getChest()
        local entries = {}
        local signatureParts = {}

        for slot, item in pairs(list) do
            if type(item) == "table" and item.name then
                local detail = item
                if chest and type(chest.getItemDetail) == "function" then
                    local okDetail, full = pcall(chest.getItemDetail, slot)
                    if okDetail and type(full) == "table" then detail = full end
                end

                if detail.name == nil then detail.name = item.name end
                if detail.count == nil then detail.count = item.count end

                local count = floor(item.count or detail.count)
                local nbtCanonical = matcher.canonicalNBT(detail.nbt)
                entries[#entries + 1] = {
                    slot = slot,
                    name = tostring(item.name),
                    count = count,
                    detail = detail,
                    identity = tostring(item.name) .. "|NBT|" .. tostring(nbtCanonical),
                }
                signatureParts[#signatureParts + 1] =
                    tostring(item.name) .. "|" .. tostring(nbtCanonical) ..
                    "|" .. tostring(count)
            end
        end

        table.sort(signatureParts)
        table.sort(entries, function(a, b)
            if a.name ~= b.name then return a.name < b.name end
            return tostring(a.identity) < tostring(b.identity)
        end)

        return {
            entries = entries,
            signature = table.concat(signatureParts, ";"),
        }
    end

    function self.rebindTransferChest(name, reason)
        name = tostring(name or "")
        if name == ""
            or not peripheral.isPresent(name)
            or not hasType(name, "inventory") then
            return false, "invalid transfer chest peripheral"
        end

        self.transferChestName = name
        store.data.settings = store.data.settings or {}
        store.data.settings.transferChestName = name
        store.save()
        store.log(
            "TRANSFER CHEST rebound to " .. tostring(name) ..
            (reason and (" reason=" .. tostring(reason)) or "")
        )
        return true, "transfer chest rebound to " .. tostring(name)
    end

    function self.findAlternateChestContainingName(itemName)
        itemName = tostring(itemName or "")
        if itemName == "" then return nil, "pending item name unavailable" end

        local matches = {}
        for _, name in ipairs(peripheral.getNames()) do
            if name ~= self.transferChestName
                and hasType(name, "inventory")
                and looksLikeBarrel(name) then

                local inv = peripheral.wrap(name)
                local okList, list = pcall(inv.list)
                if okList and type(list) == "table" then
                    local count = 0
                    for _, item in pairs(list) do
                        if type(item) == "table"
                            and tostring(item.name or "") == itemName then
                            count = count + floor(item.count)
                        end
                    end
                    if count > 0 then
                        matches[#matches + 1] = {
                            name = name,
                            count = count,
                        }
                    end
                end
            end
        end

        table.sort(matches, function(a,b)
            return tostring(a.name) < tostring(b.name)
        end)

        if #matches == 0 then return nil, nil end
        if #matches > 1 then
            local names = {}
            for _, entry in ipairs(matches) do
                names[#names + 1] =
                    tostring(entry.name) .. "(" ..
                    tostring(entry.count) .. ")"
            end
            return nil,
                "multiple alternate chests contain pending item " ..
                itemName .. ": " .. table.concat(names, ", ")
        end

        return matches[1], nil
    end

    function self.findAlternateRequestedChest(activeRequests)
        activeRequests =
            type(activeRequests) == "table" and activeRequests or {}

        local byName = {}

        for _, name in ipairs(peripheral.getNames()) do
            if name ~= self.transferChestName
                and hasType(name, "inventory")
                and looksLikeBarrel(name) then

                local inv = peripheral.wrap(name)
                local okList, list = pcall(inv.list)
                if okList and type(list) == "table"
                    and next(list) ~= nil then

                    for slot, item in pairs(list) do
                        if type(item) == "table" and item.name then
                            local detail = item
                            if type(inv.getItemDetail) == "function" then
                                local okDetail, full =
                                    pcall(inv.getItemDetail, slot)
                                if okDetail and type(full) == "table" then
                                    detail = full
                                end
                            end
                            if detail.name == nil then
                                detail.name = item.name
                            end
                            if detail.count == nil then
                                detail.count = item.count
                            end

                            for _, request in ipairs(activeRequests) do
                                local accepted, candidate, why =
                                    matcher.requestAcceptsItem(
                                        request, detail)
                                if accepted and candidate then
                                    local entry = byName[name]
                                    if not entry then
                                        entry = {
                                            name = name,
                                            matches = {},
                                        }
                                        byName[name] = entry
                                    end
                                    entry.matches[#entry.matches + 1] = {
                                        request = request,
                                        candidate = candidate,
                                        slot = slot,
                                        item = detail,
                                        reason = why,
                                    }
                                end
                            end
                        end
                    end
                end
            end
        end

        local candidates = {}
        for _, entry in pairs(byName) do
            candidates[#candidates + 1] = entry
        end
        table.sort(candidates, function(a,b)
            return tostring(a.name) < tostring(b.name)
        end)

        if #candidates == 0 then return nil, nil end
        if #candidates > 1 then
            local names = {}
            for _, entry in ipairs(candidates) do
                names[#names + 1] = tostring(entry.name)
            end
            return nil,
                "multiple alternate transfer-chest candidates contain " ..
                "active-request items: " .. table.concat(names, ", ")
        end

        return candidates[1], nil
    end

    function self.chestCount(candidate)
        local list, err = self.chestContents()
        if not list then return nil, err end
        local total = 0
        for slot, item in pairs(list) do
            if type(item) == "table" and item.name == candidate.name then
                local exact = not candidate.hasNBT
                if candidate.hasNBT then
                    local chest = self.getChest()
                    local okDetail, detail = pcall(chest.getItemDetail, slot)
                    if okDetail and type(detail) == "table" then
                        exact = matcher.exactlyMatches(candidate.raw, detail)
                    end
                end
                if exact then total = total + floor(item.count) end
            end
        end
        return total
    end

    local function rsAmount(bridge, candidate)
        local ok, items = self.safeCall(bridge, "listItems")
        if not ok or type(items) ~= "table" then return nil, "listItems failed" end
        local total = 0
        for _, item in pairs(items) do
            if type(item) == "table" and item.name == candidate.name then
                if matcher.exactlyMatches(candidate.raw, item) then
                    total = total + floor(item.amount)
                end
            end
        end
        return total
    end

    function self.playerAmount(candidate)
        return rsAmount(self.playerRS, candidate)
    end

    function self.colonyAmount(candidate)
        return rsAmount(self.colonyRS, candidate)
    end

    local function exportDirectional(bridge, filter, direction)
        local ok, moved, err = self.safeCall(bridge, "exportItem", filter, direction)
        if not ok then return 0, err or moved end
        return floor(moved), nil
    end

    local function importDirectional(bridge, filter, direction)
        local ok, moved, err = self.safeCall(bridge, "importItem", filter, direction)
        if not ok then return 0, err or moved end
        return floor(moved), nil
    end

    local function exportPeripheral(bridge, filter, chestName)
        local ok, moved, err = self.safeCall(bridge, "exportItemToPeripheral", filter, chestName)
        if not ok then return 0, err or moved end
        return floor(moved), nil
    end

    local function importPeripheral(bridge, filter, chestName)
        local ok, moved, err = self.safeCall(bridge, "importItemFromPeripheral", filter, chestName)
        if not ok then return 0, err or moved end
        return floor(moved), nil
    end

    local function sourceExport(bridge, filter, direction)
        if config.usePeripheralTransfer then
            if not self.transferChestName then
                return 0, "transfer chest peripheral name unavailable"
            end
            return exportPeripheral(
                bridge, filter, self.transferChestName)
        end
        return exportDirectional(bridge, filter, direction)
    end

    local function destinationImport(bridge, filter, direction)
        if config.usePeripheralTransfer then
            if not self.transferChestName then
                return 0, "transfer chest peripheral name unavailable"
            end
            return importPeripheral(
                bridge, filter, self.transferChestName)
        end
        return importDirectional(bridge, filter, direction)
    end

    local function verifyDestination(bridge, candidate, baseline, expected)
        local maxSeen = floor(baseline)
        local reads = math.max(1, math.min(5, floor(config.destinationConfirmReads or 3)))
        for i = 1, reads do
            local amount = rsAmount(bridge, candidate)
            if amount ~= nil and amount > maxSeen then maxSeen = amount end
            if math.max(0, maxSeen - baseline) >= expected then break end
            if i < reads then sleep(tonumber(config.destinationConfirmDelay) or 0.15) end
        end
        return math.min(expected, math.max(0, maxSeen - baseline)), maxSeen
    end

    local function setPending(p)
        p.updated = nowSeconds()
        store.setPending(p)
    end

    local function clearPending()
        store.setPending(nil)
    end

    local function rsNameAmount(bridge, name)
        local ok, items = self.safeCall(bridge, "listItems")
        if not ok or type(items) ~= "table" then return nil end
        local total = 0
        for _, item in pairs(items) do
            if type(item) == "table" and item.name == name then
                total = total + floor(item.amount)
            end
        end
        return total
    end

    function self.returnEntireChestToPlayer()
        if type(store.data.pending) == "table" then
            return false, "pending transaction exists; orphan cleanup refused"
        end

        local snapshot, err = self.chestSnapshot()
        if not snapshot then
            return false, "cannot inspect transfer chest: " .. tostring(err)
        end
        if #snapshot.entries == 0 then
            return true, {
                moved = 0,
                items = {},
                detail = "transfer chest already empty",
            }
        end

        local byName = {}
        for _, entry in ipairs(snapshot.entries) do
            byName[entry.name] = (byName[entry.name] or 0) + floor(entry.count)
        end

        local before = {}
        for name in pairs(byName) do
            before[name] = rsNameAmount(self.playerRS, name)
        end

        local movedTotal = 0
        local movedByName = {}
        for name, expected in pairs(byName) do
            local remaining = expected
            local moved = 0

            for _ = 1, math.max(1, floor(config.transferImportRetries or 3)) do
                if remaining <= 0 then break end
                local n = destinationImport(
                    self.playerRS,
                    { name = name, count = remaining },
                    config.chestToPlayerDirection
                )
                moved = moved + floor(n)
                sleep(tonumber(config.transferRetryDelay) or 0.25)

                local nowList = self.chestContents()
                if type(nowList) ~= "table" then break end
                remaining = 0
                for _, item in pairs(nowList) do
                    if type(item) == "table" and item.name == name then
                        remaining = remaining + floor(item.count)
                    end
                end
            end

            movedByName[name] = moved
            movedTotal = movedTotal + moved
        end

        local afterSnapshot, afterErr = self.chestSnapshot()
        if not afterSnapshot then
            return false, "cannot verify transfer chest after cleanup: " ..
                tostring(afterErr)
        end

        if #afterSnapshot.entries > 0 then
            local leftovers = {}
            for _, entry in ipairs(afterSnapshot.entries) do
                leftovers[#leftovers + 1] =
                    tostring(entry.count) .. "x " .. tostring(entry.name)
            end
            return false,
                "orphan cleanup incomplete; chest still contains " ..
                    table.concat(leftovers, ", ")
        end

        local verification = {}
        for name, expected in pairs(byName) do
            local after = rsNameAmount(self.playerRS, name)
            local gained = (after ~= nil and before[name] ~= nil)
                and math.max(0, after - before[name]) or nil
            verification[#verification + 1] =
                tostring(expected) .. "x " .. tostring(name) ..
                (gained ~= nil and (" (PRS +" .. tostring(gained) .. ")") or "")
        end
        table.sort(verification)

        return true, {
            moved = movedTotal,
            items = byName,
            detail = "returned orphan chest contents to PRS: " ..
                table.concat(verification, ", "),
        }
    end

    function self.rollbackChestToPlayer(candidate, expected)
        local chestBefore = self.chestCount(candidate)
        if chestBefore == nil then return false, "cannot read transfer chest" end
        if chestBefore <= 0 then return true, "nothing to rollback" end
        local playerBefore = self.playerAmount(candidate)
        if playerBefore == nil then return false, "cannot read PRS before rollback" end

        -- The transfer chest is the isolation boundary. The exact variant was
        -- already selected before it entered the chest, so do not pass AP's
        -- listItems NBT/hash value back as an import filter.
        local filter = {
            name = candidate.name,
            count = math.min(
                chestBefore,
                floor(expected) > 0 and floor(expected) or chestBefore
            )
        }

        local moved = 0
        for _ = 1, math.max(1, floor(config.transferImportRetries or 3)) do
            local n = destinationImport(self.playerRS, filter, config.chestToPlayerDirection)
            moved = moved + floor(n)
            local left = self.chestCount(candidate) or chestBefore
            if left <= 0 then break end
            sleep(tonumber(config.transferRetryDelay) or 0.25)
        end

        local playerAfter = self.playerAmount(candidate)
        local chestAfter = self.chestCount(candidate)
        local gained = playerAfter and math.max(0, playerAfter - playerBefore) or 0
        if chestAfter == 0 and gained >= math.min(chestBefore, floor(expected) > 0 and floor(expected) or chestBefore) then
            return true, "rollback verified"
        end
        return false, "rollback incomplete: chest=" .. tostring(chestAfter) .. " PRS gain=" .. tostring(gained) .. " bridge=" .. tostring(moved)
    end

    function self.adoptChestToColony(candidate, count, meta)
        meta = meta or {}
        if type(store.data.pending) == "table" then
            return false, "pending transaction exists; requested chest recovery refused"
        end

        count = math.min(
            math.max(1, floor(count)),
            floor(config.maxTransferChunk or 64)
        )

        local chestBefore = self.chestCount(candidate)
        if chestBefore == nil then
            return false, "cannot read requested item in transfer chest"
        end
        if chestBefore <= 0 then
            return false, "requested transfer-chest item is no longer present"
        end

        local quantity = math.min(count, chestBefore)
        local colonyBefore = self.colonyAmount(candidate)
        if colonyBefore == nil then
            return false, "cannot read CRS baseline before chest recovery"
        end

        local pending = {
            schema = 3,
            direction = "CHEST>CRS",
            stage = "staged",
            item = candidate.name,
            identity = candidate.identity,
            amount = quantity,
            requestId = meta.requestId,
            started = nowSeconds(),
            recovery = true,
        }
        setPending(pending)

        -- The physical item in the transfer chest has already been inspected
        -- and accepted against the active request. Import by registry name;
        -- AP may expose an NBT hash that is valid for identity comparison but
        -- not valid as importItemFromPeripheral()'s nbt filter.
        local importFilter = {
            name = candidate.name,
            count = quantity,
        }

        for _ = 1, math.max(1, floor(config.transferImportRetries or 3)) do
            destinationImport(
                self.colonyRS,
                importFilter,
                config.chestToColonyDirection
            )
            sleep(tonumber(config.transferRetryDelay) or 0.25)

            local left = self.chestCount(candidate)
            if left ~= nil and left <= math.max(0, chestBefore - quantity) then
                break
            end
        end

        local chestAfter = self.chestCount(candidate)
        if chestAfter == nil then
            return false, "cannot verify transfer chest after requested-item recovery"
        end

        local physicalAccepted =
            math.max(0, math.min(quantity, chestBefore - chestAfter))
        if physicalAccepted <= 0 then
            clearPending()
            return false,
                "CRS did not import requested transfer-chest item"
        end

        pending.stage = "confirming"
        pending.physicalAccepted = physicalAccepted
        setPending(pending)

        local confirmed = verifyDestination(
            self.colonyRS,
            candidate,
            colonyBefore,
            physicalAccepted
        )
        if confirmed < physicalAccepted then
            return false,
                "requested chest item moved but CRS confirmation failed: physical=" ..
                tostring(physicalAccepted) ..
                " confirmed=" .. tostring(confirmed)
        end

        clearPending()
        store.addHistory(
            "RECOVERY",
            {
                direction = "CHEST>CRS",
                item = candidate.name,
                amount = confirmed,
                requestId = meta.requestId,
                detail = tostring(
                    meta.detail
                    or "recovered active-request item from transfer chest into CRS"
                ),
            }
        )

        return true, {
            moved = confirmed,
            baselineCRS = colonyBefore,
            item = candidate.name,
            detail = "recovered " .. tostring(confirmed) .. "x " ..
                tostring(candidate.name) .. " from transfer chest into CRS",
        }
    end

    function self.playerToColony(candidate, count, meta)
        count = math.min(math.max(1, floor(count)), floor(config.maxTransferChunk or 64))
        meta = meta or {}

        local empty, emptyErr = self.chestEmpty()
        if not empty then return false, "transfer chest not empty: " .. tostring(emptyErr or "occupied") end

        local variants, stock = matcher.findStoredVariants(self.playerRS, candidate, function(...) return self.safeCall(...) end)
        if stock <= 0 or #variants == 0 then return false, "exact PRS variant not stored" end

        local quantity = math.min(count, stock)
        local filter, filterMode = matcher.exportFilterForVariant(candidate, variants[1], quantity)
        if not filter then return false, filterMode end

        local colonyBefore = self.colonyAmount(candidate)
        if colonyBefore == nil then return false, "cannot read CRS baseline" end

        local pending = {
            schema = 3,
            direction = "PRS>CRS",
            stage = "exporting",
            item = candidate.name,
            identity = candidate.identity,
            amount = quantity,
            requestId = meta.requestId,
            started = nowSeconds(),
            filterMode = filterMode,
        }
        setPending(pending)

        local chestBefore = self.chestCount(candidate) or 0
        local exported, exportErr = sourceExport(self.playerRS, filter, config.playerToChestDirection)
        sleep(tonumber(config.transferSettleDelay) or 0.25)
        local chestAfterExport = self.chestCount(candidate)
        local physicallyExported = chestAfterExport and math.max(0, chestAfterExport - chestBefore) or 0

        if exported <= 0 or physicallyExported <= 0 then
            clearPending()
            return false,
                "PRS export failed: item=" .. tostring(candidate.name) ..
                " mode=" .. tostring(filterMode) ..
                " direction=" .. tostring(config.playerToChestDirection) ..
                " requested=" .. tostring(quantity) ..
                " bridge=" .. tostring(exported) ..
                " chestBefore=" .. tostring(chestBefore) ..
                " chestAfter=" .. tostring(chestAfterExport) ..
                " chestDelta=" .. tostring(physicallyExported) ..
                (exportErr and (" error=" .. tostring(exportErr)) or "")
        end

        pending.stage = "staged"
        pending.amount = physicallyExported
        setPending(pending)

        -- Exactness was enforced on PRS->chest (fingerprint for equipment/NBT).
        -- The chest started empty, so the staged item is already isolated.
        -- Import by name only; destination verification below still confirms
        -- that the exact candidate appeared in CRS.
        local importFilter = {
            name = candidate.name,
            count = physicallyExported,
        }

        for _ = 1, math.max(1, floor(config.transferImportRetries or 3)) do
            destinationImport(self.colonyRS, importFilter, config.chestToColonyDirection)
            sleep(tonumber(config.transferRetryDelay) or 0.25)
            local left = self.chestCount(candidate)
            if left ~= nil and left <= 0 then break end
        end

        local chestAfterImport = self.chestCount(candidate)
        local physicalAccepted = math.max(0, physicallyExported - floor(chestAfterImport))
        if physicalAccepted <= 0 then
            -- Fail closed. The exact requested item is safely staged in the
            -- transfer chest, so do not bounce it back to PRS and trigger a
            -- duplicate request/craft cycle during an RS/AP fault.
            pending.stage = "staged"
            pending.amount = physicallyExported
            pending.lastError =
                "CRS import moved 0; staged item retained for diagnosis/recovery"
            setPending(pending)
            return false,
                "CRS import moved 0; requested item retained in transfer chest"
        end

        pending.stage = "confirming"
        pending.physicalAccepted = physicalAccepted
        setPending(pending)

        local confirmed = verifyDestination(self.colonyRS, candidate, colonyBefore, physicalAccepted)
        if confirmed < physicalAccepted then
            local left = self.chestCount(candidate) or 0
            if left > 0 then
                self.rollbackChestToPlayer(candidate, left)
            end
            return false, "CRS destination unconfirmed: physical=" .. tostring(physicalAccepted) .. " confirmed=" .. tostring(confirmed)
        end

        clearPending()
        store.addHistory("TRANSFER", {
            direction = "PRS>CRS",
            item = candidate.name,
            amount = confirmed,
            requestId = meta.requestId,
            detail = tostring(meta.detail or "verified exact transfer"),
        })
        return true, confirmed
    end

    function self.colonyToPlayer(candidate, count, meta)
        count = math.min(math.max(1, floor(count)), floor(config.maxOverstockChunk or 64))
        meta = meta or {}
        local empty, err = self.chestEmpty()
        if not empty then return false, "transfer chest not empty: " .. tostring(err or "occupied") end

        local variants, stock = matcher.findStoredVariants(self.colonyRS, candidate, function(...) return self.safeCall(...) end)
        if stock <= 0 or #variants == 0 then return false, "exact CRS variant not stored" end

        local quantity = math.min(count, stock)
        local filter, mode = matcher.exportFilterForVariant(candidate, variants[1], quantity)
        if not filter then return false, mode end
        local playerBefore = self.playerAmount(candidate)
        if playerBefore == nil then return false, "cannot read PRS baseline" end

        local pending = {
            schema = 3,
            direction = "CRS>PRS",
            stage = "exporting",
            item = candidate.name,
            identity = candidate.identity,
            amount = quantity,
            requestId = meta.requestId,
            started = nowSeconds(),
            filterMode = mode,
        }
        setPending(pending)

        local beforeChest = self.chestCount(candidate) or 0
        local exported, exportErr =
            sourceExport(
                self.colonyRS,
                filter,
                config.colonyToChestDirection
            )
        sleep(tonumber(config.transferSettleDelay) or 0.25)
        local afterChest = self.chestCount(candidate)
        local staged = afterChest
            and math.max(0, afterChest - beforeChest) or 0
        if floor(exported) <= 0 or staged <= 0 then
            clearPending()
            return false,
                "CRS export failed: item=" .. tostring(candidate.name) ..
                " mode=" .. tostring(mode) ..
                " target=" ..
                    tostring(
                        config.usePeripheralTransfer
                            and self.transferChestName
                            or config.colonyToChestDirection
                    ) ..
                " requested=" .. tostring(quantity) ..
                " bridge=" .. tostring(exported) ..
                " chestBefore=" .. tostring(beforeChest) ..
                " chestAfter=" .. tostring(afterChest) ..
                " chestDelta=" .. tostring(staged) ..
                (exportErr and
                    (" error=" .. tostring(exportErr)) or "")
        end

        pending.stage = "staged"
        pending.amount = staged
        setPending(pending)

        -- Exactness was enforced on CRS->chest before staging. The chest
        -- started empty, so import the isolated staged item by registry name
        -- and verify the exact candidate in PRS afterward.
        local importFilter = {
            name = candidate.name,
            count = staged,
        }

        local importMoved = 0
        local lastImportErr
        for _ = 1, math.max(
            1, floor(config.transferImportRetries or 3)) do
            local n, importErr =
                destinationImport(
                    self.playerRS,
                    importFilter,
                    config.chestToPlayerDirection
                )
            importMoved = importMoved + floor(n)
            if importErr then lastImportErr = importErr end
            sleep(tonumber(config.transferRetryDelay) or 0.25)
            local left = self.chestCount(candidate)
            if left ~= nil and left <= 0 then break end
        end

        local chestAfter = self.chestCount(candidate)
        local physicalAccepted =
            math.max(0, staged - floor(chestAfter))

        pending.stage = "confirming"
        pending.physicalAccepted = physicalAccepted
        setPending(pending)

        local confirmed, maxSeen =
            verifyDestination(
                self.playerRS,
                candidate,
                playerBefore,
                physicalAccepted
            )

        if chestAfter == 0
            and confirmed >= physicalAccepted
            and physicalAccepted > 0 then
            clearPending()
            store.addHistory("TRANSFER", {
                direction = "CRS>PRS",
                item = candidate.name,
                amount = physicalAccepted,
                requestId = meta.requestId,
                detail = tostring(
                    meta.detail or "verified overstock return"),
            })
            return true, physicalAccepted
        end

        return false,
            "PRS destination unconfirmed: staged=" ..
            tostring(staged) ..
            " physical=" .. tostring(physicalAccepted) ..
            " confirmed=" .. tostring(confirmed) ..
            " PRS baseline=" .. tostring(playerBefore) ..
            " PRS maxSeen=" .. tostring(maxSeen) ..
            " bridgeImported=" .. tostring(importMoved) ..
            " chest=" .. tostring(chestAfter) ..
            " target=" ..
                tostring(
                    config.usePeripheralTransfer
                        and self.transferChestName
                        or config.chestToPlayerDirection
                ) ..
            (lastImportErr and
                (" error=" .. tostring(lastImportErr)) or "")
    end

    function self.findSafeProbeCandidate()
        local ok, items = self.safeCall(self.playerRS, "listItems")
        if not ok or type(items) ~= "table" then return nil, "PRS listItems unavailable" end

        local preferred = tostring(config.startupProbePreferredItem or "")
        local function usable(item)
            if type(item) ~= "table" or floor(item.amount) < 1 then return false end
            local ns = tostring(item.name or ""):match("^([^:]+):")
            if not ns or config.startupProbeNamespaces[ns] ~= true then return false end
            local nbt = item.nbt
            local noNBT = nbt == nil or nbt == "" or nbt == "{}" or (type(nbt) == "table" and next(nbt) == nil)
            return noNBT
        end

        local selected
        for _, item in pairs(items) do
            if usable(item) and item.name == preferred then selected = item break end
        end
        if not selected then
            for _, item in pairs(items) do
                if usable(item) then selected = item break end
            end
        end
        if not selected then return nil, "no plain PRS item available for startup probe" end

        return {
            name = selected.name,
            displayName = selected.displayName or selected.name,
            nbt = nil,
            nbtCanonical = "",
            hasNBT = false,
            identity = tostring(selected.name) .. "|NBT|",
            namespace = tostring(selected.name):match("^([^:]+):") or "",
            raw = { name = selected.name, nbt = nil },
        }
    end

    function self.startupRoundTrip()
        local candidate, err = self.findSafeProbeCandidate()
        if not candidate then return false, err end
        local beforePRS = self.playerAmount(candidate)
        local beforeCRS = self.colonyAmount(candidate)
        if beforePRS == nil or beforeCRS == nil then return false, "cannot read startup probe baselines" end

        local okForward, movedForward = self.playerToColony(candidate, floor(config.startupProbeCount or 1), {
            detail = "startup forward validation",
        })
        if not okForward then return false, "PRS->CRS startup probe failed: " .. tostring(movedForward) end

        local okBack, movedBack = self.colonyToPlayer(candidate, floor(movedForward), {
            detail = "startup reverse validation",
        })
        if not okBack then
            return false, "CRS->PRS startup probe failed after forward success: " .. tostring(movedBack)
        end

        local afterPRS = self.playerAmount(candidate)
        local afterCRS = self.colonyAmount(candidate)
        if afterPRS ~= beforePRS or afterCRS ~= beforeCRS then
            return false, "startup round trip did not restore baseline: PRS " ..
                tostring(beforePRS) .. "->" .. tostring(afterPRS) .. ", CRS " ..
                tostring(beforeCRS) .. "->" .. tostring(afterCRS)
        end
        return true, "round trip verified with " .. candidate.name
    end

    function self.recoverPending()
        local p = store.data.pending
        if type(p) ~= "table" then return true, "nothing pending" end

        -- v3 only auto-recovers a staged PRS->CRS transaction by returning the
        -- visible barrel contents to PRS. It never guesses that an empty barrel
        -- means the colony accepted a prior shipment.
        local list, err = self.chestContents()
        if not list then return false, "cannot inspect pending transfer chest: " .. tostring(err) end
        if next(list) == nil then
            -- Before treating a later-stage empty chest as ambiguous, check
            -- whether a stale saved chest binding caused us to read the wrong
            -- inventory. Rebind only when exactly one alternate barrel-like
            -- inventory contains the pending registry item.
            if tostring(p.stage or "") ~= "exporting"
                and p.item ~= nil then
                local alternate, alternateErr =
                    self.findAlternateChestContainingName(p.item)

                if alternate then
                    local okRebind, rebindDetail =
                        self.rebindTransferChest(
                            alternate.name,
                            "pending " .. tostring(p.direction or "?") ..
                            " item found in alternate chest"
                        )
                    if not okRebind then
                        return false,
                            "pending alternate chest found but rebind failed: " ..
                            tostring(rebindDetail)
                    end
                    store.addHistory("RECOVERY", {
                        direction = "CHEST_REBIND",
                        item = p.item,
                        amount = alternate.count,
                        requestId = p.requestId,
                        detail = tostring(rebindDetail),
                    })
                    return self.recoverPending()
                elseif alternateErr then
                    return false,
                        "pending transfer chest identity ambiguous: " ..
                        tostring(alternateErr)
                end
            end

            -- If the persisted transaction never advanced beyond the exporting
            -- stage, no item was ever positively observed in the transfer chest.
            -- This is exactly the state left by a bridge export that returned 0.
            -- Clear that pre-staged marker automatically instead of permanently
            -- blocking startup. Later stages remain fail-closed because an empty
            -- chest there can mean the destination consumed the item.
            if tostring(p.stage or "") == "exporting" then
                local detail =
                    "cleared pre-staged pending " .. tostring(p.direction or "?") ..
                    " " .. tostring(p.item or "?") ..
                    "; transfer chest is empty and no staged item was confirmed"
                clearPending()
                store.addHistory("RECOVERY", {
                    direction = tostring(p.direction or "?"),
                    item = tostring(p.item or "?"),
                    amount = floor(p.amount),
                    requestId = p.requestId,
                    detail = detail,
                })
                return true, detail
            end

            return false,
                "pending transaction stage=" .. tostring(p.stage or "?") ..
                " exists but transfer chest is empty; outcome is ambiguous and manual diagnosis is required"
        end

        local one
        for _, item in pairs(list) do
            if type(item) == "table" then
                if one and one.name ~= item.name then
                    return false, "pending recovery found mixed transfer chest contents"
                end
                one = item
            end
        end
        if not one then return false, "pending recovery could not identify barrel item" end

        local candidate = {
            name = one.name,
            displayName = one.name,
            nbt = nil,
            nbtCanonical = "",
            hasNBT = false,
            identity = tostring(one.name) .. "|NBT|",
            namespace = tostring(one.name):match("^([^:]+):") or "",
            raw = { name = one.name, nbt = nil },
        }
        local ok, detail = self.rollbackChestToPlayer(candidate, floor(one.count))
        if ok then
            clearPending()
            store.addHistory("RECOVERY", {
                direction = "CHEST>PRS",
                item = one.name,
                amount = floor(one.count),
                detail = "recovered persisted pending transfer",
            })
            return true, detail
        end
        return false, detail
    end

    return self
end

return M
