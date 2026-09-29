-- MineColonies Control Suite v3 - exact request identity and candidate selection
local M = {}

local TOOL_WORDS = {
    axe = "axe",
    pickaxe = "pickaxe",
    shovel = "shovel",
    hoe = "hoe",
    sword = "sword",
    fishing_rod = "fishing rod",
    shears = "shears",
    bow = "bow",
    crossbow = "crossbow",
    shield = "shield",
    helmet = "helmet",
    chestplate = "chestplate",
    leggings = "leggings",
    boots = "boots",
    lighter = "flint and steel",
    lead = "lead",
    spear = "spear",
}

local function cleanText(value)
    local s = tostring(value or "")
    s = s:gsub("§.", "")
    s = s:gsub("_", " "):gsub("-", " ")
    s = s:gsub("%s+", " ")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function namespace(name)
    return tostring(name or ""):match("^([^:]+):") or ""
end

local function path(name)
    return tostring(name or ""):match("^[^:]+:(.+)$") or tostring(name or "")
end

local function canonical(value)
    if value == nil then return "" end
    if type(value) == "string" then
        if value == "{}" or value == "nil" then return "" end
        return value
    end
    if type(value) ~= "table" then return tostring(value) end

    -- MineColonies commonly exposes ordinary items as nbt = {}, while
    -- Advanced Peripherals / Refined Storage may expose the same item with
    -- nbt = nil. Both mean "no NBT" and must be the same exact identity.
    if next(value) == nil then return "" end

    local function encode(v, seen)
        local t = type(v)
        if t == "nil" then return "nil" end
        if t == "boolean" or t == "number" then return tostring(v) end
        if t == "string" then return string.format("%q", v) end
        if t ~= "table" then return "<" .. t .. ":" .. tostring(v) .. ">" end
        if seen[v] then return "<cycle>" end
        seen[v] = true
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a,b) return tostring(a) < tostring(b) end)
        local out = {"{"}
        for i, k in ipairs(keys) do
            if i > 1 then out[#out + 1] = "," end
            out[#out + 1] = canonical(k)
            out[#out + 1] = "="
            out[#out + 1] = canonical(v[k])
        end
        out[#out + 1] = "}"
        seen[v] = nil
        return table.concat(out)
    end

    return encode(value, {})
end

local function isOpaqueNBTHash(nbt)
    if type(nbt) ~= "string" then return false end
    local s = tostring(nbt):lower()
    -- CC:Tweaked / Advanced Peripherals commonly expose item NBT as an
    -- opaque 32-character hex identity hash. That proves variant identity but
    -- does not by itself mean the item is enchanted or carries a specific NBT
    -- requirement that MineColonies asked for.
    return #s == 32 and s:match("^[0-9a-f]+$") ~= nil
end

local function hasMeaningfulNBT(item)
    if type(item) ~= "table" then return false end
    local nbt = item.nbt
    if nbt == nil then return false end
    if type(nbt) == "table" then return next(nbt) ~= nil end
    if isOpaqueNBTHash(nbt) then return false end
    local s = tostring(nbt)
    return s ~= "" and s ~= "{}" and s ~= "nil"
end

local function identityFrom(item)
    return tostring(item.name or "") .. "|NBT|" .. canonical(item.nbt)
end

local function textHasToolToken(text, token)
    local normalized = cleanText(text or ""):lower():gsub("[^%w]+", " ")
    local wanted = cleanText(token or ""):lower():gsub("[^%w]+", " ")
    normalized =
        (" " .. normalized:gsub("^%s+", ""):gsub("%s+$", "") .. " ")
    wanted = wanted:gsub("^%s+", ""):gsub("%s+$", "")
    return wanted ~= ""
        and normalized:find(" " .. wanted .. " ", 1, true) ~= nil
end

local function requestToolClass(request)
    local text =
        tostring(request and request.name or "") .. " " ..
        tostring(request and request.displayName or "") .. " " ..
        tostring(request and request.description or "") .. " " ..
        tostring(request and request.desc or "") .. " " ..
        tostring(request and request.type or "") .. " " ..
        tostring(request and request.toolType or "") .. " " ..
        tostring(request and request.toolClass or "")

    -- Match complete normalized tokens, never arbitrary substrings.  In
    -- particular, "Bowl" must not be interpreted as a "Bow" equipment request.
    if textHasToolToken(text, "flint and steel")
        or textHasToolToken(text, "flint_and_steel") then
        return "lighter"
    end
    if textHasToolToken(text, "fishing rod") then return "fishing_rod" end
    if textHasToolToken(text, "crossbow") then return "crossbow" end
    if textHasToolToken(text, "pickaxe") then return "pickaxe" end
    if textHasToolToken(text, "chestplate") then return "chestplate" end
    if textHasToolToken(text, "leggings") then return "leggings" end
    if textHasToolToken(text, "helmet") then return "helmet" end
    if textHasToolToken(text, "boots") then return "boots" end
    if textHasToolToken(text, "shears") then return "shears" end
    if textHasToolToken(text, "shield") then return "shield" end
    if textHasToolToken(text, "sword") then return "sword" end
    if textHasToolToken(text, "shovel") then return "shovel" end
    if textHasToolToken(text, "spear") then return "spear" end
    if textHasToolToken(text, "lead") then return "lead" end
    if textHasToolToken(text, "bow") then return "bow" end
    if textHasToolToken(text, "axe") then return "axe" end
    if textHasToolToken(text, "hoe") then return "hoe" end
    return nil
end

local function candidateMatchesClass(candidate, class)
    local p = path(candidate.name):lower()
    local display = cleanText(candidate.displayName or ""):lower()

    if class == "pickaxe" then return p == "pickaxe" or p:match("_pickaxe$") ~= nil end
    if class == "axe" then
        return not p:find("pickaxe", 1, true) and (p == "axe" or p:match("_axe$") ~= nil)
    end
    if class == "shovel" then return p == "shovel" or p:match("_shovel$") ~= nil end
    if class == "hoe" then return p == "hoe" or p:match("_hoe$") ~= nil end
    if class == "sword" then return p == "sword" or p:match("_sword$") ~= nil end
    if class == "fishing_rod" then return p == "fishing_rod" or p:match("_fishing_rod$") ~= nil end
    if class == "shears" then return p == "shears" or p:match("_shears$") ~= nil end
    if class == "bow" then return p == "bow" or (p:match("_bow$") ~= nil and not p:find("crossbow",1,true)) end
    if class == "crossbow" then return p == "crossbow" or p:match("_crossbow$") ~= nil end
    if class == "shield" then return p == "shield" or p:match("_shield$") ~= nil end
    if class == "helmet" or class == "chestplate" or class == "leggings" or class == "boots" then
        return p == class or p:match("_" .. class .. "$") ~= nil
    end
    if class == "lighter" then return p == "flint_and_steel" or display:find("flint and steel",1,true) ~= nil end
    if class == "lead" then return p == "lead" end
    if class == "spear" then return p == "spear" or p:match("_spear$") ~= nil end
    return false
end

local function toolTier(candidate)
    local text = (path(candidate.name) .. " " .. cleanText(candidate.displayName or "")):lower()
    if text:find("netherite",1,true) then return 4 end
    if text:find("diamond",1,true) then return 3 end
    if text:find("iron",1,true) then return 2 end
    if text:find("stone",1,true) then return 1 end
    return 0
end

function M.new(config, store)
    local self = {}

    function self.canonicalNBT(nbt)
        return canonical(nbt)
    end

    function self.requestIdentity(item)
        if type(item) ~= "table" then return nil end
        return identityFrom(item)
    end

    function self.itemIdentity(item)
        if type(item) ~= "table" then return nil end
        return identityFrom(item)
    end

    function self.exactlyMatches(requestItem, storedItem)
        if type(requestItem) ~= "table" or type(storedItem) ~= "table" then
            return false
        end
        if requestItem.name ~= storedItem.name then return false end

        local requestSpecific = hasMeaningfulNBT(requestItem)
        local storedSpecific = hasMeaningfulNBT(storedItem)

        -- A generic/no-specific-NBT request may be compared with an item whose
        -- inventory API only exposes an opaque NBT hash. Do not let that hash
        -- turn an otherwise ordinary tool into a false mismatch.
        if not requestSpecific and not storedSpecific then
            return true
        end

        return canonical(requestItem.nbt) == canonical(storedItem.nbt)
    end

    function self.requestAcceptsItem(request, physicalItem)
        if type(request) ~= "table" or type(physicalItem) ~= "table"
            or type(physicalItem.name) ~= "string"
            or physicalItem.name == "" then
            return false, nil, "invalid request or physical item"
        end

        local candidates, class = self.requestCandidates(request)
        local hasSpecificNBT = false
        for _, candidate in ipairs(candidates or {}) do
            if candidate.hasNBT then hasSpecificNBT = true end
        end

        -- First prefer the strict exact alternative identity used everywhere
        -- else in Supply.
        for _, candidate in ipairs(candidates or {}) do
            if self.exactlyMatches(candidate.raw, physicalItem) then
                local accepted = {
                    name = physicalItem.name,
                    displayName = physicalItem.displayName
                        or candidate.displayName
                        or physicalItem.name,
                    nbt = physicalItem.nbt,
                    nbtCanonical = canonical(physicalItem.nbt),
                    hasNBT = hasMeaningfulNBT(physicalItem),
                    identity = identityFrom(physicalItem),
                    namespace = namespace(physicalItem.name),
                    toolClass = class,
                    toolTier = toolTier({
                        name = physicalItem.name,
                        displayName = physicalItem.displayName,
                    }),
                    exactClass = true,
                    raw = {
                        name = physicalItem.name,
                        nbt = physicalItem.nbt,
                    },
                }
                return true, accepted, "exact request alternative"
            end
        end

        -- Equipment requests are class requests in MineColonies. The physical
        -- item may be a valid vanilla/MineColonies tool even when that exact
        -- registry name was not present in the request's serialized alternative
        -- list. Use the same class + namespace rules as normal Supply matching.
        if class and not hasSpecificNBT then
            -- A generic MineColonies equipment request is still a plain-item
            -- request. Do not silently substitute an enchanted/damaged NBT
            -- variant merely because it belongs to the same equipment class.
            if hasMeaningfulNBT(physicalItem) then
                return false, nil,
                    "generic equipment request does not accept NBT variant"
            end

            local ns = namespace(physicalItem.name)
            local physicalCandidate = {
                name = physicalItem.name,
                displayName = physicalItem.displayName or physicalItem.name,
                nbt = physicalItem.nbt,
                nbtCanonical = canonical(physicalItem.nbt),
                hasNBT = hasMeaningfulNBT(physicalItem),
                identity = identityFrom(physicalItem),
                namespace = ns,
                toolClass = class,
                toolTier = 0,
                exactClass = true,
                raw = {
                    name = physicalItem.name,
                    nbt = physicalItem.nbt,
                },
            }

            if config.equipmentAllowedNamespaces[ns] ~= true then
                return false, nil, "equipment namespace not allowed"
            end
            if not candidateMatchesClass(physicalCandidate, class) then
                return false, nil, "physical item is not requested equipment class"
            end

            physicalCandidate.toolTier = toolTier(physicalCandidate)
            physicalCandidate.genericClassAcceptance = true
            return true, physicalCandidate,
                "accepted " .. tostring(TOOL_WORDS[class] or class) ..
                " equipment alternative"
        end

        return false, nil, "physical item does not match request"
    end

    function self.requestCandidates(request)
        local out = {}
        local seen = {}
        local class = requestToolClass(request)

        for _, item in pairs(type(request) == "table" and type(request.items) == "table" and request.items or {}) do
            if type(item) == "table" and type(item.name) == "string" and item.name ~= "" then
                local candidate = {
                    name = item.name,
                    displayName = item.displayName or item.name,
                    nbt = item.nbt,
                    nbtCanonical = canonical(item.nbt),
                    hasNBT = hasMeaningfulNBT(item),
                    identity = identityFrom(item),
                    namespace = namespace(item.name),
                    toolClass = class,
                    toolTier = 0,
                    exactClass = true,
                    raw = item,
                }

                if class then
                    candidate.exactClass = candidateMatchesClass(candidate, class)
                    candidate.toolTier = toolTier(candidate)
                    if config.equipmentAllowedNamespaces[candidate.namespace] ~= true then
                        candidate.rejected = "equipment namespace not allowed"
                    elseif not candidate.exactClass then
                        candidate.rejected = "not exact " .. tostring(TOOL_WORDS[class] or class) .. " class"
                    end
                end

                if not candidate.rejected and not seen[candidate.identity] then
                    seen[candidate.identity] = true
                    out[#out + 1] = candidate
                elseif candidate.rejected then
                    store.log("MATCH reject request=" .. tostring(request.id or "?") ..
                        " item=" .. tostring(candidate.name) .. " reason=" .. candidate.rejected)
                end
            end
        end
        return out, class
    end

    function self.findStoredVariants(bridge, candidate, safeCall)
        local ok, items = safeCall(bridge, "listItems")
        if not ok or type(items) ~= "table" then return {}, 0 end
        local variants, total = {}, 0
        for _, item in pairs(items) do
            if type(item) == "table" and item.name == candidate.name and self.exactlyMatches(candidate.raw, item) then
                local amount = math.max(0, math.floor(tonumber(item.amount) or 0))
                if amount > 0 then
                    variants[#variants + 1] = {
                        name = item.name,
                        amount = amount,
                        nbt = item.nbt,
                        fingerprint = item.fingerprint,
                        displayName = item.displayName,
                        raw = item,
                    }
                    total = total + amount
                end
            end
        end
        table.sort(variants, function(a,b) return a.amount > b.amount end)
        return variants, total
    end

    function self.exportFilterForVariant(candidate, variant, count)
        count = math.max(1, math.floor(tonumber(count) or 1))

        -- Equipment must be exported by the exact stored variant, even when
        -- MineColonies made a generic/non-NBT class request. A name-only export
        -- such as minecraft:iron_hoe can otherwise let RS substitute an
        -- enchanted/damaged hoe with the same registry name.
        if candidate.toolClass then
            if variant
                and type(variant.fingerprint) == "string"
                and variant.fingerprint ~= "" then
                return {
                    fingerprint = variant.fingerprint,
                    count = count,
                }, "equipment-fingerprint"
            end

            return nil,
                "selected equipment variant has no fingerprint; " ..
                "refusing unsafe name-only export"
        end

        -- Ordinary non-NBT items keep the proven AP/RS registry-name path.
        -- Exact NBT variants remain fingerprint-only so RS cannot substitute
        -- another same-name stack.
        if not candidate.hasNBT then
            return { name = candidate.name, count = count }, "name"
        end

        if variant
            and type(variant.fingerprint) == "string"
            and variant.fingerprint ~= "" then
            return {
                fingerprint = variant.fingerprint,
                count = count,
            }, "fingerprint"
        end

        return nil, "exact NBT variant has no export fingerprint"
    end

    function self.craftFilter(candidate, count)
        local filter = { name = candidate.name }
        if count ~= nil then filter.count = math.max(1, math.floor(tonumber(count) or 1)) end

        -- For NBT-bearing requests, pass the exact NBT only if AP exposed it in a
        -- serializable form. If the bridge cannot craft by exact NBT, the engine
        -- treats that as not craftable rather than weakening the match.
        if candidate.hasNBT then
            if type(candidate.nbt) == "string" then
                filter.nbt = candidate.nbt
            elseif type(candidate.nbt) == "table" then
                local ok, encoded = pcall(textutils.serializeJSON, candidate.nbt)
                if ok and encoded then filter.nbt = encoded end
            end
        end
        return filter
    end

    function self.craftable(bridge, candidate, safeCall)
        local filter = self.craftFilter(candidate, nil)
        if candidate.hasNBT and filter.nbt == nil then
            return false, "exact NBT cannot be represented for crafting"
        end

        local ok, value = safeCall(bridge, "isItemCraftable", filter)
        if ok and value == true then return true, "isItemCraftable" end

        local okPattern, pattern = safeCall(bridge, "getPattern", filter)
        if okPattern and type(pattern) == "table" then return true, "getPattern" end

        if not candidate.hasNBT then
            local okList, craftables = safeCall(bridge, "listCraftableItems")
            if okList and type(craftables) == "table" then
                for _, item in pairs(craftables) do
                    if type(item) == "table" and item.name == candidate.name then
                        return true, "listCraftableItems"
                    end
                end
            end
        end

        return false, "no exact crafting recipe reported"
    end

    function self.chooseFromSnapshot(request, inventoryItems, craftableLookup, remaining)
        local candidates, class = self.requestCandidates(request)
        if #candidates == 0 then
            return nil, class, "no acceptable candidates"
        end

        inventoryItems = type(inventoryItems) == "table" and inventoryItems or {}

        for _, candidate in ipairs(candidates) do
            local variants, total = {}, 0
            for _, item in pairs(inventoryItems) do
                if type(item) == "table"
                    and item.name == candidate.name
                    and self.exactlyMatches(candidate.raw, item) then
                    local amount = math.max(
                        0, math.floor(tonumber(item.amount) or 0))
                    if amount > 0 then
                        variants[#variants + 1] = {
                            name = item.name,
                            amount = amount,
                            nbt = item.nbt,
                            fingerprint = item.fingerprint,
                            displayName = item.displayName,
                            raw = item,
                        }
                        total = total + amount
                    end
                end
            end

            table.sort(variants, function(a, b)
                return a.amount > b.amount
            end)

            candidate.variants = variants
            candidate.stock = total

            if total > 0 then
                -- Stock already proves the request is fillable. Avoid any
                -- crafting API call for status-only inspection.
                candidate.craftable = false
                candidate.craftabilityKnown = true
                candidate.craftSource = "exact stock available"
            elseif type(craftableLookup) == "function" then
                local ok, source, known = craftableLookup(candidate)
                candidate.craftable = ok == true
                candidate.craftabilityKnown =
                    known == true or ok == true or ok == false
                candidate.craftSource = source
            else
                candidate.craftable = false
                candidate.craftabilityKnown = false
                candidate.craftSource = "craftability not checked"
            end
        end

        table.sort(candidates, function(a, b)
            if class and a.toolTier ~= b.toolTier then
                return a.toolTier > b.toolTier
            end

            local aFull = a.stock >= remaining and remaining > 0
            local bFull = b.stock >= remaining and remaining > 0
            if aFull ~= bFull then return aFull end

            local aAny = a.stock > 0
            local bAny = b.stock > 0
            if aAny ~= bAny then return aAny end

            if a.craftable ~= b.craftable then return a.craftable end
            if a.craftabilityKnown ~= b.craftabilityKnown then
                return a.craftabilityKnown == false
            end
            if a.stock ~= b.stock then return a.stock > b.stock end
            return a.identity < b.identity
        end)

        return candidates[1], class, nil
    end

    function self.choose(request, playerBridge, safeCall, remaining)
        local candidates, class = self.requestCandidates(request)
        if #candidates == 0 then
            return nil, class, "no acceptable candidates"
        end

        for _, c in ipairs(candidates) do
            c.variants, c.stock = self.findStoredVariants(playerBridge, c, safeCall)
            c.craftable, c.craftSource = self.craftable(playerBridge, c, safeCall)
        end

        table.sort(candidates, function(a,b)
            if class and a.toolTier ~= b.toolTier then return a.toolTier > b.toolTier end

            local aFull = a.stock >= remaining and remaining > 0
            local bFull = b.stock >= remaining and remaining > 0
            if aFull ~= bFull then return aFull end

            local aAny = a.stock > 0
            local bAny = b.stock > 0
            if aAny ~= bAny then return aAny end

            if a.craftable ~= b.craftable then return a.craftable end
            if a.stock ~= b.stock then return a.stock > b.stock end
            return a.identity < b.identity
        end)

        return candidates[1], class, nil
    end

    return self
end

return M