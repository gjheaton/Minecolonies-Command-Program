-- MineColonies Command Center
-- Minecraft 1.20.1
-- Requires: CC:Tweaked + Advanced Peripherals + MineColonies
-- Display: Advanced Monitor
-- v2.14: Suppress the sick-colony alarm when a staffed hospital can treat citizens.

local REFRESH_SECONDS = 10
local RAID_BLINK_SECONDS = 0.75
local TEXT_SCALE = 0.5
local PROGRAM_VERSION = "2.14"
local SUITE_VERSION = "1.1.2"

local Util = require("colony.lib.util")
local SharedUI = require("colony.lib.ui")
local SuiteUpdater = require("colony.lib.updater")

-- Suite update settings.
local UPDATE_CHECK_SECONDS = 1800  -- Recheck suite package every 30 minutes

-- Sick-citizen trigger settings.
-- Prefer an Advanced Peripherals Redstone Integrator when one is available.
-- If no usable integrator exists, fall back to the Advanced Computer.
-- TOP is the default output side for either device.
local SICK_TRIGGER_INTEGRATOR_SIDE = "top"
local SICK_TRIGGER_COMPUTER_SIDE = "top"

-- =========================
-- Peripheral discovery
-- =========================

local monitor = peripheral.find("monitor")
if not monitor then
    error("No monitor found. Attach an Advanced Monitor to this computer/network.")
end

local monitorName = peripheral.getName(monitor)
local colony = peripheral.find("colonyIntegrator")
if not colony then
    error("No colonyIntegrator found. Attach an Advanced Peripherals Colony Integrator.")
end
local colonyPeripheralName = peripheral.getName(colony)

-- Prefer the Advanced Peripherals Redstone Integrator. AP 0.7 uses the
-- peripheral type "redstoneIntegrator"; the underscore form is also checked
-- for compatibility with newer naming.
local sickRedstoneIntegrator = nil
local sickRedstoneIntegratorName = nil

local function resolveSickRedstoneIntegrator()
    local integrator = peripheral.find("redstoneIntegrator")
    if not integrator then
        integrator = peripheral.find("redstone_integrator")
    end

    sickRedstoneIntegrator = integrator
    sickRedstoneIntegratorName =
        integrator and peripheral.getName(integrator) or nil

    return integrator
end

local function hasSickTriggerHardware()
    -- The computer's built-in redstone API is always the fallback.
    return true
end

local function sickTriggerHardwareText(sickCount, alarmSuppressed)
    local sick = (tonumber(sickCount) or 0) > 0
    local powered = sick and alarmSuppressed ~= true
    local state = powered and "ON" or "OFF"
    local suffix = (sick and alarmSuppressed == true) and " (HOSPITAL+DOCTOR)" or ""

    local integrator = resolveSickRedstoneIntegrator()
    if integrator then
        return "INTEGRATOR [" ..
            tostring(sickRedstoneIntegratorName or "?") ..
            "] TOP " .. state .. suffix
    end

    return "COMPUTER TOP " .. state .. suffix
end

monitor.setTextScale(TEXT_SCALE)
monitor.setCursorBlink(false)

if not monitor.isColor() then
    error("This program requires an Advanced (color) Monitor.")
end

-- =========================
-- Theme
-- =========================

local C = SharedUI.theme()
local monitorUI = SharedUI.newMonitor({ monitor = monitor, theme = C, protected = false })

-- =========================
-- Small helpers
-- =========================

local function nvl(v, fallback)
    if v == nil then return fallback end
    return v
end

local function tostr(v, fallback)
    if v == nil then return fallback or "" end
    return tostring(v)
end

local function yesno(v)
    return v and "YES" or "NO"
end

local function posText(p)
    if type(p) ~= "table" then return "N/A" end
    if p.x == nil or p.y == nil or p.z == nil then return "N/A" end
    return string.format("%s, %s, %s", tostring(p.x), tostring(p.y), tostring(p.z))
end

local clip = Util.clip
local pad = Util.padRight

local function cleanJobName(job)
    local s = job

    -- Depending on the MineColonies/AP build, the job can be returned
    -- as a string or a small table. Normalize both forms first.
    if type(s) == "table" then
        s = s.job or s.name or s.id or s.type or ""
    end
    s = tostring(s or "")

    -- Prefer the portion AFTER com.minecolonies.job. wherever it appears.
    -- Example: com.minecolonies.job.builder -> builder
    local packaged = s:match("com%.minecolonies%.job%.([%w_%-]+)")
    if packaged then
        s = packaged
    else
        s = s:gsub("com%.minecolonies%.job%.", "")
        s = s:gsub("^minecolonies:", "")
    end

    -- Make identifiers human-readable.
    s = s:gsub("_", " ")
    s = s:gsub("%-", " ")
    s = s:gsub("(%l)(%u)", "%1 %2")
    s = s:gsub("^%l", string.upper)

    if s == "" then return "Worker" end
    return s
end

local function cleanBuildingName(value)
    local s = value
    if type(s) == "table" then
        s = s.name or s.type or s.id or ""
    end
    s = tostring(s or "")

    -- MineColonies building identifiers may be returned as packaged names.
    -- Example: com.minecolonies.building.builder -> builder
    local packaged = s:match("com%.minecolonies%.building%.([%w_%-]+)")
    if packaged then
        s = packaged
    else
        s = s:gsub("com%.minecolonies%.building%.", "")
        s = s:gsub("^minecolonies:", "")
    end

    -- If another Java-style package still remains, use its final identifier.
    if s:find("%.") then
        s = s:match("([^.]+)$") or s
    end

    s = s:gsub("_", " ")
    s = s:gsub("%-", " ")
    s = s:gsub("(%l)(%u)", "%1 %2")
    s = s:gsub("^%l", string.upper)

    if s == "" then return "Unknown" end
    return s
end

-- Post Boxes are utility blocks rather than useful command-center building
-- entries, so hide them from the Buildings screen. Keep them in D.buildings
-- internally so construction/work-order matching still has the complete
-- MineColonies building dataset available.
local function isIgnoredBuilding(building)
    if type(building) ~= "table" then return false end

    local candidates = {
        building.name,
        building.type,
        building.id,
    }

    for _, value in ipairs(candidates) do
        if value ~= nil then
            local cleaned = cleanBuildingName(value):lower()
            local compact = cleaned:gsub("[%s_%-]", "")
            if compact == "postbox" then
                return true
            end

            local raw = tostring(value):lower():gsub("[%s_%-]", "")
            if raw:find("postbox", 1, true) ~= nil then
                return true
            end
        end
    end

    return false
end

local function visibleBuildings(buildings)
    local out = {}
    for _, building in ipairs(buildings or {}) do
        if not isIgnoredBuilding(building) then
            out[#out + 1] = building
        end
    end
    return out
end

local function samePosition(a, b)
    return type(a) == "table" and type(b) == "table"
        and a.x ~= nil and a.y ~= nil and a.z ~= nil
        and b.x ~= nil and b.y ~= nil and b.z ~= nil
        and a.x == b.x and a.y == b.y and a.z == b.z
end

local function citizenJob(citizen)
    if citizen.age == "child" then return "Child" end

    local raw = citizen.job
    if type(citizen.work) == "table" then
        raw = citizen.work.job or citizen.work.name or citizen.work.id or raw
    elseif citizen.work ~= nil and raw == nil then
        raw = citizen.work
    end

    if raw == nil or tostring(raw) == "" then
        return "No job"
    end

    return cleanJobName(raw)
end

-- Military citizens are kept in a separate section at the bottom of the
-- Citizens page. MineColonies 1.20.1 uses Ranger as the internal Archer job
-- name in some releases. Known defensive jobs include Guard, Archer/Ranger,
-- Knight, Druid, and (in later 1.20.1 builds) Cavalry. Training students are
-- intentionally not included because they do not defend the colony.
local MILITARY_JOBS = {
    guard = true,
    archer = true,
    ranger = true,
    knight = true,
    druid = true,
    cavalry = true,
}

local function isMilitaryCitizen(citizen)
    -- Use exact normalized job-name matching. Substring matching is unsafe:
    -- for example, "researcher" contains the letters "archer" and was
    -- incorrectly classified as military in v17.
    local job = citizenJob(citizen):lower()
    job = job:gsub("^%s+", ""):gsub("%s+$", "")
    job = job:gsub("[%s_%-]", "")

    return MILITARY_JOBS[job] == true
end

local function citizenNameLess(a, b)
    return tostring(a.name or ""):lower() < tostring(b.name or ""):lower()
end

-- Sort buildings from least complete to most complete. This uses level/maxLevel
-- rather than raw level alone, and alphabetizes buildings which have the same
-- completion percentage.
local function buildingCompletion(building)
    local level = tonumber(building.level) or 0
    local maxLevel = tonumber(building.maxLevel) or 0

    if level <= 0 then return 0 end
    if maxLevel > 0 then
        return math.max(0, math.min(1, level / maxLevel))
    end

    return building.built and 1 or 0
end

local function sortBuildingsByCompletion(list)
    table.sort(list, function(a, b)
        local ac = buildingCompletion(a)
        local bc = buildingCompletion(b)
        if math.abs(ac - bc) > 0.000001 then
            return ac < bc
        end

        local an = cleanBuildingName(a.name or a.type or "Unknown"):lower()
        local bn = cleanBuildingName(b.name or b.type or "Unknown"):lower()
        if an ~= bn then return an < bn end

        return tostring(a.name or a.type or ""):lower() < tostring(b.name or b.type or ""):lower()
    end)
end

local function buildCitizenDisplayRows(citizens)
    local civilians, military = {}, {}

    for _, citizen in ipairs(citizens or {}) do
        if isMilitaryCitizen(citizen) then
            military[#military + 1] = citizen
        else
            civilians[#civilians + 1] = citizen
        end
    end

    table.sort(civilians, citizenNameLess)
    table.sort(military, citizenNameLess)

    local rows = {}
    for _, citizen in ipairs(civilians) do rows[#rows + 1] = citizen end

    if #military > 0 then
        rows[#rows + 1] = { _sectionHeader = true, _sectionTitle = "MILITARY", _sectionCount = #military }
        for _, citizen in ipairs(military) do rows[#rows + 1] = citizen end
    end

    return rows
end

local function isCitizenSick(citizen)
    -- Advanced Peripherals documents a citizen.state string, but does not
    -- expose a dedicated sickness boolean on 1.20.1. Some builds/modpacks
    -- may expose one anyway, so check those first and then inspect state.
    if citizen.isSick == true or citizen.sick == true then
        return true
    end

    local state = tostring(citizen.state or ""):lower()

    -- MineColonies 1.20.1 reports sickness through the citizen AI/state
    -- text. Matching the word "sick" also catches packaged/internal state
    -- identifiers which contain the same term.
    if state:find("sick", 1, true) then
        return true
    end

    return false
end

local function citizenStatus(citizen)
    -- Sickness is deliberately the highest-priority warning.
    if isCitizenSick(citizen) then
        return "SICK", C.danger
    end
    if type(citizen.health) == "number" and type(citizen.maxHealth) == "number"
        and citizen.health < citizen.maxHealth then
        return "INJURED", C.danger
    end
    if citizen.betterFood then return "FOOD", C.warn end
    if citizen.isAsleep then return "IN BED", C.info end
    if citizen.isIdle then return "IDLE", C.title end
    if citizen.age == "child" then return "CHILD", C.accent end
    return "OK", C.good
end

local function normalizeList(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for _, v in pairs(t) do
        if type(v) == "table" then
            out[#out + 1] = v
        end
    end
    return out
end

-- Preserve the sequence of array-style API results. This matters for
-- MineColonies work orders because their list order represents the queue.
local function normalizeOrderedList(t)
    local out = {}
    if type(t) ~= "table" then return out end

    local used = {}
    for i, v in ipairs(t) do
        if type(v) == "table" then
            out[#out + 1] = v
            used[i] = true
        end
    end

    -- Fallback for tables with numeric keys which are not a perfect Lua array.
    local numericKeys = {}
    for k, v in pairs(t) do
        if type(k) == "number" and not used[k] and type(v) == "table" then
            numericKeys[#numericKeys + 1] = k
        end
    end
    table.sort(numericKeys)
    for _, k in ipairs(numericKeys) do
        out[#out + 1] = t[k]
    end

    -- Last-resort support for non-numeric keyed result tables.
    if #out == 0 then
        for _, v in pairs(t) do
            if type(v) == "table" then out[#out + 1] = v end
        end
    end

    return out
end

local function countTable(t)
    local n = 0
    if type(t) ~= "table" then return 0 end
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function sortByName(list, field)
    table.sort(list, function(a, b)
        local av = tostring(a[field] or a.name or a.type or ""):lower()
        local bv = tostring(b[field] or b.name or b.type or ""):lower()
        return av < bv
    end)
end

local apiErrors = {}
local function api(method, default, ...)
    local fn = colony[method]
    if type(fn) ~= "function" then
        apiErrors[method] = "method unavailable"
        return default
    end
    local ok, result = pcall(fn, ...)
    if not ok then
        apiErrors[method] = tostring(result)
        return default
    end
    apiErrors[method] = nil
    if result == nil then return default end
    return result
end

local function errorCount()
    local n = 0
    for _ in pairs(apiErrors) do n = n + 1 end
    return n
end

-- =========================
-- Monitor drawing helpers
-- =========================

local size = monitorUI.size
local setColors = monitorUI.setColors
local fill = monitorUI.fill
local writeAt = monitorUI.writeAt
local center = monitorUI.center
local clear = monitorUI.clear
local wrapText = Util.wrapText

-- =========================
-- Buttons / touch handling
-- =========================

local resetButtons = monitorUI.resetButtons
local addButton = monitorUI.addButton
local addTouchArea = monitorUI.addTouchArea
local hitButton = monitorUI.hitButton

-- =========================
-- Data model
-- =========================

local D = {
    citizens = {}, buildings = {}, requests = {}, workOrders = {}, visitors = {},
    helpWanted = {}, helpWantedOpenings = 0
}

local function buildingWorkers(building)
    local workers = {}
    local seen = {}

    -- A worker belongs to THIS specific building only when the citizen's
    -- documented work location matches the building location exactly.
    --
    -- IMPORTANT: Do not fall back to work-building name/type here. Multiple
    -- buildings of the same type share those values, which would make the
    -- same citizen appear on every building of that type.
    --
    -- We also intentionally do not use building.citizens for the WORKER(S)
    -- column. That table represents citizens associated with the building,
    -- while citizen.work.location specifically identifies the workplace.
    for _, citizen in ipairs(D.citizens or {}) do
        if type(citizen.work) == "table"
            and samePosition(citizen.work.location, building.location) then

            local key = tostring(citizen.id or citizen.name or (#workers + 1))
            if not seen[key] then
                workers[#workers + 1] = citizen
                seen[key] = true
            end
        end
    end

    table.sort(workers, function(a, b)
        return tostring(a.name or ""):lower() < tostring(b.name or ""):lower()
    end)
    return workers
end

local function buildingWorkerSummary(building, width)
    local workers = buildingWorkers(building)
    if #workers == 0 then return "None" end

    local names = {}
    for _, citizen in ipairs(workers) do
        names[#names + 1] = tostring(citizen.name or "Unknown")
    end

    local full = table.concat(names, ", ")
    if #full <= width then return full end

    -- Prefer useful names over a blind truncation when several citizens work
    -- in the same building.
    local first = names[1] or "Unknown"
    if #names == 1 then return clip(first, width) end
    local suffix = " (+" .. tostring(#names - 1) .. ")"
    return clip(first, math.max(1, width - #suffix)) .. suffix
end

-- MineColonies/Advanced Peripherals 0.7 does not expose a building's maximum
-- worker count directly. Keep a conservative table for standard work huts and
-- explicit formulas for buildings whose staffing scales with level.
--
-- Guard Towers are intentionally capped at ONE worker even though some
-- MineColonies screens/AP structures can expose multiple guard job choices.
-- Only one guard can actually occupy a normal Guard Tower.
local SINGLE_WORKER_BUILDINGS = {
    alchemist = true,
    apiary = true, beekeeper = true,
    baker = true, bakery = true,
    blacksmith = true,
    builder = true, builderhut = true,
    chickenherder = true, chickenfarmer = true,
    composter = true,
    concretemixer = true,
    cook = true, restaurant = true, kitchen = true, cookery = true,
    crusher = true,
    deliveryman = true, courier = true, courierhut = true,
    dyer = true,
    enchanter = true,
    farmer = true, farm = true,
    fisherman = true,
    fletcher = true,
    florist = true,
    forester = true, lumberjack = true,
    glassblower = true,
    guardtower = true,
    hospital = true, healer = true,
    mechanic = true,
    miner = true, mine = true,
    netherworker = true, nethermine = true,
    plantation = true,
    rabbitherder = true,
    sawmill = true,
    school = true, -- teacher slot only; pupil seats are not Help Wanted jobs
    shepherd = true,
    smeltery = true,
    stonemason = true, stonesmeltery = true, brickyard = true,
    swineherder = true,
    undertaker = true, graveyard = true,
}

local function compactBuildingKey(value)
    return cleanBuildingName(value):lower():gsub("[^%w]", "")
end

local function staffingBuildingKey(building)
    if type(building) ~= "table" then return "" end
    local candidates = { building.type, building.name, building.id }
    for _, value in ipairs(candidates) do
        if value ~= nil then
            local key = compactBuildingKey(value)
            if key ~= "" and key ~= "unknown" then return key end
        end
    end
    return ""
end

-- Return whether the colony has an operational Hospital and an assigned
-- medical worker. MineColonies calls the Hospital worker a Healer in some
-- APIs/UI versions; matching the worker by the Hospital's exact work location
-- is more reliable than depending on the localized/display job name.
--
-- This is recomputed from the current refresh snapshot and retains no history,
-- so it cannot grow memory usage over time.
local function colonyMedicalCoverage()
    local hospitalAvailable = false
    local doctorAvailable = false

    for _, building in ipairs(D.buildings or {}) do
        local key = staffingBuildingKey(building)
        if key == "hospital" or key == "healer" then
            local level = tonumber(building.level) or 0
            local operational = level > 0 and building.built ~= false

            if operational then
                hospitalAvailable = true
                if #buildingWorkers(building) > 0 then
                    doctorAvailable = true
                    break
                end
            end
        end
    end

    return hospitalAvailable, doctorAvailable
end

local function buildingStaffCapacity(building)
    if type(building) ~= "table" then return 0 end

    local level = math.max(0, tonumber(building.level) or 0)
    if level <= 0 then return 0 end

    local key = staffingBuildingKey(building)

    -- Explicit MineColonies multi-worker rules.
    if key == "guardtower" then
        return 1
    elseif key == "barrackstower" then
        return level
    elseif key == "university" then
        return level
    elseif key == "library" then
        return level * 2
    elseif key == "archery" or key == "combatacademy" then
        return level
    elseif key == "stable" then
        -- One Stablemaster plus one Cavalry slot per building level.
        return 1 + level
    elseif SINGLE_WORKER_BUILDINGS[key] then
        return 1
    end

    return 0
end

local function staffingWorkers(building)
    local workers = buildingWorkers(building)
    local key = staffingBuildingKey(building)

    -- Pupils also use the School as their work location, but Help Wanted is
    -- intended to report the actual Teacher vacancy rather than pupil seats.
    if key == "school" then
        local teachers = {}
        for _, citizen in ipairs(workers) do
            local job = citizenJob(citizen):lower():gsub("[^%w]", "")
            if job == "teacher" then teachers[#teachers + 1] = citizen end
        end
        return teachers
    end

    return workers
end

local function buildHelpWantedList()
    local rows = {}
    local totalOpen = 0

    for _, building in ipairs(D.buildings or {}) do
        if not isIgnoredBuilding(building) then
            local capacity = buildingStaffCapacity(building)
            if capacity > 0 then
                local workers = staffingWorkers(building)
                local filled = math.min(capacity, #workers)
                local openings = math.max(0, capacity - filled)

                if openings > 0 then
                    rows[#rows + 1] = {
                        building = building,
                        capacity = capacity,
                        filled = filled,
                        openings = openings,
                        workers = workers,
                    }
                    totalOpen = totalOpen + openings
                end
            end
        end
    end

    table.sort(rows, function(a, b)
        if a.openings ~= b.openings then
            return a.openings > b.openings
        end
        local an = cleanBuildingName(a.building.name or a.building.type or "Unknown"):lower()
        local bn = cleanBuildingName(b.building.name or b.building.type or "Unknown"):lower()
        if an ~= bn then return an < bn end
        local ap = a.building.location or {}
        local bp = b.building.location or {}
        if (ap.x or 0) ~= (bp.x or 0) then return (ap.x or 0) < (bp.x or 0) end
        if (ap.z or 0) ~= (bp.z or 0) then return (ap.z or 0) < (bp.z or 0) end
        return (ap.y or 0) < (bp.y or 0)
    end)

    return rows, totalOpen
end

-- Resolve the MineColonies builder assigned to a construction work order.
-- Advanced Peripherals exposes workOrder.builder as a position, not a name.
-- We match that position to citizen workplace locations first, then use the
-- Builder Hut building assignment as a fallback.
local function workOrderBuilders(order)
    local workers = {}
    local seen = {}
    local builderPos = type(order) == "table" and order.builder or nil

    local function addCitizen(citizen)
        if type(citizen) ~= "table" then return end
        local key = tostring(citizen.id or citizen.name or "")
        if key == "" or seen[key] then return end
        workers[#workers + 1] = citizen
        seen[key] = true
    end

    if type(builderPos) == "table" then
        -- Most reliable match: the citizen's work location is the Builder Hut
        -- position carried by the work order.
        for _, citizen in ipairs(D.citizens or {}) do
            if type(citizen.work) == "table" and samePosition(citizen.work.location, builderPos) then
                addCitizen(citizen)
            end
        end

        -- Some MineColonies/AP builds may expose a live builder position.
        -- Use an exact citizen-location match as a secondary fallback.
        if #workers == 0 then
            for _, citizen in ipairs(D.citizens or {}) do
                if samePosition(citizen.location, builderPos) then
                    addCitizen(citizen)
                end
            end
        end

        -- Final fallback: find the building at the work-order builder position
        -- and use its assigned workers.
        if #workers == 0 then
            for _, building in ipairs(D.buildings or {}) do
                if samePosition(building.location, builderPos) then
                    for _, citizen in ipairs(buildingWorkers(building)) do
                        addCitizen(citizen)
                    end
                    break
                end
            end
        end
    end

    table.sort(workers, function(a, b)
        return tostring(a.name or ""):lower() < tostring(b.name or ""):lower()
    end)
    return workers
end

local function workOrderBuilderSummary(order, width)
    local workers = workOrderBuilders(order)
    if #workers == 0 then
        return order.isClaimed and "Assigned" or "Unassigned"
    end

    local names = {}
    for _, citizen in ipairs(workers) do
        names[#names + 1] = tostring(citizen.name or "Unknown")
    end

    local full = table.concat(names, ", ")
    if #full <= width then return full end

    local first = names[1] or "Unknown"
    if #names == 1 then return clip(first, width) end
    local suffix = " (+" .. tostring(#names - 1) .. ")"
    return clip(first, math.max(1, width - #suffix)) .. suffix
end

-- Best-effort mapping from a work order to its target building. Advanced
-- Peripherals exposes the builder position, but not the target building
-- position, so duplicate building types can be ambiguous. We prefer exact
-- name/type matches and a building MineColonies says is currently worked on.
local function workOrderTargetBuilding(order)
    local best, bestScore = nil, -1
    local orderName = tostring(order.buildingName or "")
    local orderType = tostring(order.type or "")
    local cleanOrderName = cleanBuildingName(orderName):lower()
    local cleanOrderType = cleanBuildingName(orderType):lower()

    for _, building in ipairs(D.buildings or {}) do
        local score = 0
        local bName = tostring(building.name or "")
        local bType = tostring(building.type or "")
        local cleanBName = cleanBuildingName(bName):lower()
        local cleanBType = cleanBuildingName(bType):lower()

        if orderName ~= "" and bName == orderName then score = score + 6 end
        if orderType ~= "" and bType == orderType then score = score + 6 end
        if cleanOrderName ~= "unknown" and cleanOrderName ~= ""
            and cleanBName == cleanOrderName then score = score + 3 end
        if cleanOrderType ~= "unknown" and cleanOrderType ~= ""
            and cleanBType == cleanOrderType then score = score + 3 end
        if building.isWorkingOn then score = score + 4 end

        local target = tonumber(order.targetLevel)
        local current = tonumber(building.level)
        if target and current then
            if target == current + 1 then score = score + 2 end
            if target == current then score = score + 1 end
        end

        if score > bestScore and score > 0 then
            best, bestScore = building, score
        end
    end

    return best
end

local function workOrderBuilderKey(order)
    if type(order) ~= "table" then return nil end

    -- AP normally exposes the assigned Builder Hut position here. This is the
    -- best key for detecting two work orders assigned to the same builder.
    local p = order.builder
    if type(p) == "table" and p.x ~= nil and p.y ~= nil and p.z ~= nil then
        return "HUT:" ..
            tostring(p.x) .. ":" ..
            tostring(p.y) .. ":" ..
            tostring(p.z)
    end

    -- Fallback to the resolved builder citizen(s) if the work-order builder
    -- position is unavailable.
    local builders = workOrderBuilders(order)
    if #builders > 0 then
        local ids = {}
        for _, citizen in ipairs(builders) do
            ids[#ids + 1] = tostring(citizen.id or citizen.name or "?")
        end
        table.sort(ids)
        return "CITIZEN:" .. table.concat(ids, ",")
    end

    return nil
end

local function rawWorkOrderStatus(order)
    local building = workOrderTargetBuilding(order)

    -- This is only the raw AP/MineColonies candidate state. refreshData()
    -- later enforces that one builder can have only one ACTIVE work order.
    if order.isClaimed and building and building.isWorkingOn then
        return "ACTIVE", C.good, building
    end

    if order.isClaimed then
        return "CLAIMED", C.info, building
    end

    return "QUEUED", C.warn, building
end

local function workOrderStatus(order)
    local building = workOrderTargetBuilding(order)

    -- refreshData() assigns the display status after resolving conflicts where
    -- one builder has multiple claimed construction jobs.
    local state = type(order) == "table" and order._displayStatus or nil
    if state == "ACTIVE" then
        return "ACTIVE", C.good, building
    elseif state == "CLAIMED" then
        return "CLAIMED", C.info, building
    elseif state == "QUEUED" then
        return "QUEUED", C.warn, building
    end

    return rawWorkOrderStatus(order)
end

-- Advanced Peripherals documents priority on both work orders and buildings,
-- but some 1.20.1 combinations report workOrder.priority as 0 for every order.
-- Prefer a meaningful work-order priority; otherwise fall back to the matched
-- target building's construction priority. Return nil when neither source is
-- useful so the UI does not display a misleading zero.
local function workOrderQueueNumber(order)
    -- Display queue number is assigned after ACTIVE orders are separated out.
    -- ACTIVE construction is not waiting in the queue, so it intentionally
    -- has no queue number and displays as "-".
    return tonumber(order and order._displayQueue)
end

-- Sort construction orders by operational state first, then by the actual
-- MineColonies priority value. An order already being actively built remains
-- above claimed/queued work even if another order has a numerically higher
-- queue priority, because the builder is already committed to that job.
local function sortWorkOrdersForDisplay(orders)
    local stateRank = { ACTIVE = 1, CLAIMED = 2, QUEUED = 3 }

    table.sort(orders, function(a, b)
        local aState = workOrderStatus(a)
        local bState = workOrderStatus(b)
        local aRank = stateRank[aState] or 9
        local bRank = stateRank[bState] or 9

        -- Operational state first:
        -- ACTIVE, then CLAIMED, then QUEUED.
        if aRank ~= bRank then
            return aRank < bRank
        end

        -- Within each state group, preserve the original MineColonies/AP
        -- work-order sequence. _apiOrder is captured before display sorting.
        return (tonumber(a and a._apiOrder) or 999999)
            < (tonumber(b and b._apiOrder) or 999999)
    end)
end

local function refreshData()
    apiErrors = {}

    D.name = api("getColonyName", "Unknown Colony")
    D.id = api("getColonyID", "?")
    D.style = api("getColonyStyle", "Unknown")
    D.location = api("getLocation", {})
    D.happiness = api("getHappiness", 0)
    D.active = api("isActive", false)
    D.underAttack = api("isUnderAttack", false)
    D.population = api("amountOfCitizens", 0)
    D.maxPopulation = api("maxOfCitizens", 0)
    D.graves = api("amountOfGraves", 0)
    D.constructionSites = api("amountOfConstructionSites", 0)

    D.citizens = normalizeList(api("getCitizens", {}))
    D.buildings = normalizeList(api("getBuildings", {}))
    D.requests = normalizeList(api("getRequests", {}))
    D.workOrders = normalizeOrderedList(api("getWorkOrders", {}))
    D.visitors = normalizeList(api("getVisitors", {}))

    -- Preserve the original getWorkOrders() sequence for sorting.
    for i, o in ipairs(D.workOrders) do
        o._apiOrder = i
        o._displayQueue = nil
        o._displayStatus = nil
    end

    -- A builder can physically work only one construction job at a time.
    -- MineColonies/AP may report multiple claimed target buildings as
    -- isWorkingOn=true when the same builder has several manually assigned
    -- work orders. Keep only the first ACTIVE candidate for each builder in
    -- the authoritative work-order sequence. Additional jobs for that builder
    -- remain CLAIMED and therefore stay in the displayed queue.
    local activeBuilderKeys = {}

    for _, o in ipairs(D.workOrders) do
        local rawState = rawWorkOrderStatus(o)

        if rawState == "ACTIVE" then
            local builderKey = workOrderBuilderKey(o)

            if builderKey and activeBuilderKeys[builderKey] then
                o._displayStatus = "CLAIMED"
            else
                o._displayStatus = "ACTIVE"
                if builderKey then
                    activeBuilderKeys[builderKey] = true
                end
            end
        else
            o._displayStatus = rawState
        end
    end

    sortWorkOrdersForDisplay(D.workOrders)

    -- ACTIVE work is already under construction and is therefore not waiting
    -- in the queue. Number every remaining order sequentially in the exact
    -- order shown on the Construction tab: 1, 2, 3, ...
    local displayQueue = 0
    for _, o in ipairs(D.workOrders) do
        local state = workOrderStatus(o)
        if state == "ACTIVE" then
            o._displayQueue = nil
        else
            displayQueue = displayQueue + 1
            o._displayQueue = displayQueue
        end
    end

    -- Citizens are displayed as civilians first and military at the bottom.
    -- The Buildings screen hides Post Boxes, then orders the remaining
    -- buildings from least complete to fully complete.
    sortByName(D.citizens, "name")
    D.citizenDisplayRows = buildCitizenDisplayRows(D.citizens)
    D.displayBuildings = visibleBuildings(D.buildings)
    sortBuildingsByCompletion(D.displayBuildings)
    D.helpWanted, D.helpWantedOpenings = buildHelpWantedList()
    sortByName(D.requests, "name")
    sortByName(D.visitors, "name")

    D.idle = 0
    D.needFood = 0
    D.injured = 0
    D.noJob = 0
    D.children = 0
    D.asleep = 0
    D.sick = 0
    D.sickNames = {}

    for _, c in ipairs(D.citizens) do
        if c.isIdle then D.idle = D.idle + 1 end
        if c.betterFood then D.needFood = D.needFood + 1 end
        if c.isAsleep then D.asleep = D.asleep + 1 end
        if isCitizenSick(c) then
            D.sick = D.sick + 1
            D.sickNames[#D.sickNames + 1] = tostring(c.name or "Unknown")
        end
        if c.age == "child" then
            D.children = D.children + 1
        elseif c.age == "adult" and c.work == nil then
            D.noJob = D.noJob + 1
        end
        if type(c.health) == "number" and type(c.maxHealth) == "number" and c.health < c.maxHealth then
            D.injured = D.injured + 1
        end
    end

    D.hospitalAvailable, D.doctorAvailable = colonyMedicalCoverage()
    D.sickAlarmSuppressed = (D.sick > 0)
        and D.hospitalAvailable
        and D.doctorAvailable
    D.sickAlarmActive = (D.sick > 0) and not D.sickAlarmSuppressed

    D.unclaimedOrders = 0
    D.activeOrders = 0
    for _, o in ipairs(D.workOrders) do
        if not o.isClaimed then D.unclaimedOrders = D.unclaimedOrders + 1 end
        local state = workOrderStatus(o)
        if state == "ACTIVE" then D.activeOrders = D.activeOrders + 1 end
    end
end

-- =========================
-- Sick-citizen redstone trigger
-- =========================

local function setSickTrigger(powered)
    powered = powered == true

    local integrator = resolveSickRedstoneIntegrator()

    if integrator then
        -- Ensure the fallback computer output is not accidentally left on
        -- after an integrator is attached.
        pcall(function()
            redstone.setOutput(SICK_TRIGGER_COMPUTER_SIDE, false)
        end)

        local ok = pcall(function()
            integrator.setOutput(SICK_TRIGGER_INTEGRATOR_SIDE, powered)
        end)

        if ok then
            return true, "integrator"
        end

        -- If the detected integrator is disabled/unusable, immediately fall
        -- back to the computer output instead of losing the alarm.
        sickRedstoneIntegrator = nil
        sickRedstoneIntegratorName = nil
    end

    local ok = pcall(function()
        redstone.setOutput(SICK_TRIGGER_COMPUTER_SIDE, powered)
    end)

    return ok, "computer"
end

local function updateSickTrigger()
    setSickTrigger(D.sickAlarmActive == true)
end

-- =========================
-- Update check / terminal startup summary
-- =========================

local function terminalColor(color)
    if term.isColor and term.isColor() then term.setTextColor(color) end
end

local UPDATE = SuiteUpdater.new({
    appId = "command",
    appVersion = PROGRAM_VERSION,
    suiteVersion = SUITE_VERSION,
    displayName = "COMMAND CENTER",
    checkSeconds = UPDATE_CHECK_SECONDS,
    drawMessage = function(title, message, color)
        local w, h = size()
        local mid = math.max(5, math.floor(h / 2))
        fill(1, mid - 1, w, mid + 1, C.panel)
        center(mid - 1, tostring(title or "UPDATE"), color or C.title, C.panel)
        center(mid, clip(tostring(message or ""), math.max(1, w - 2)), C.text, C.panel)
    end,
})

local function checkForUpdate() return UPDATE.check() end
local function updateStatusText(checking) return UPDATE.statusText(checking) end
local function installAvailableUpdate() return UPDATE.install() end

local function renderTerminalStartup(updateText, statusText)
    local monitorW, monitorH = monitor.getSize()
    local errors = errorCount()

    term.setBackgroundColor(colors.black)
    terminalColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)

    print("MineColonies Command Center v" .. PROGRAM_VERSION)
    print("Control Suite: v" .. SUITE_VERSION)
    print("Colony:       " .. tostring(D.name or "Unknown Colony"))
    print("Monitor:      ONLINE [" .. tostring(monitorName or "?") .. "] " ..
        tostring(monitorW) .. "x" .. tostring(monitorH))
    print("Integrator:   ONLINE [" .. tostring(colonyPeripheralName or "?") .. "]")
    print("Citizens:     " .. tostring(D.population or 0) .. "/" ..
        tostring(D.maxPopulation or 0))
    print("Sick trigger: " .. sickTriggerHardwareText(D.sick, D.sickAlarmSuppressed))

    if errors == 0 then
        terminalColor(colors.lime)
        print("Health:       OK")
    else
        terminalColor(colors.orange)
        print("Health:       WARNING (" .. tostring(errors) .. " API error(s))")
    end

    local updateLine = tostring(updateText or "NOT CHECKED")
    if updateLine:find("UPDATE AVAILABLE", 1, true) then
        terminalColor(colors.yellow)
    elseif updateLine:find("ERROR:", 1, true) then
        terminalColor(colors.orange)
    elseif updateLine:find("CURRENT", 1, true) then
        terminalColor(colors.lime)
    elseif updateLine:find("LOCAL NEWER", 1, true) then
        terminalColor(colors.cyan)
    else
        terminalColor(colors.cyan)
    end
    print("Update check: " .. updateLine)

    terminalColor(colors.white)
    print("Status:       " .. tostring(statusText or "RUNNING"))
    print(string.rep("-", 50))
end

-- =========================
-- UI state
-- =========================

local pages = {
    { id = "home", label = "HOME" },
    { id = "citizens", label = "CITIZENS" },
    { id = "buildings", label = "BUILDINGS" },
    { id = "help", label = "HELP WANTED" },
    { id = "requests", label = "REQUESTS" },
    { id = "orders", label = "CONSTRUCTION" },
}

local currentPage = "home"
local detail = nil
local listPage = {
    citizens = 1,
    buildings = 1,
    help = 1,
    requests = 1,
    orders = 1,
}
local detailScroll = 1
local raidBlink = false
local lastRefreshLabel = "just now"

local function pageTitle()
    for _, p in ipairs(pages) do
        if p.id == currentPage then return p.label end
    end
    return "COMMAND CENTER"
end

-- =========================
-- Frame / navigation
-- =========================

local function drawHeader()
    local headBg = C.header
    if D.underAttack then headBg = raidBlink and C.danger or C.bg end

    local status
    local statusBg = C.panel
    local statusFg = D.active and C.good or C.warn
    local button = nil

    if D.underAttack then
        status = "!!! COLONY UNDER ATTACK !!!"
        statusBg = C.danger
        statusFg = C.headerText
    else
        status = (D.active and "ACTIVE" or "INACTIVE")
            .. "  |  " .. pageTitle()
            .. "  |  Refresh: " .. lastRefreshLabel
        if errorCount() > 0 then status = status .. "  |  API ERRORS: " .. errorCount() end
        if UPDATE.availableVersion then
            button = {
                id = "program_update",
                label = UPDATE.buttonLabel(),
                bg = C.navActive, fg = C.navText,
                action = installAvailableUpdate,
            }
        end
    end

    monitorUI.drawHeader({
        title = "MINECOLONIES COMMAND CENTER",
        subtitle = (D.name or "Unknown Colony") .. "  [COMMAND-v" .. PROGRAM_VERSION .. "]",
        headerBg = headBg,
        status = status, statusBg = statusBg, statusFg = statusFg,
        button = button,
    })
end

local function drawNav()
    local active = (detail == nil) and currentPage or nil
    monitorUI.drawNav(active, pages, nil, function(pageId)
        currentPage = pageId
        detail = nil
        detailScroll = 1
    end)
end

local function drawSubBar(text)
    local w, h = size()
    fill(1, h - 1, w, h - 1, C.panel)
    center(h - 1, text, C.dim, C.panel)
end

-- =========================
-- Home dashboard
-- =========================

local function statColor(kind, value)
    if kind == "danger" then return value > 0 and C.danger or C.good end
    if kind == "warn" then return value > 0 and C.warn or C.good end
    return C.info
end

local function drawTile(x1, y1, x2, y2, label, value, valueColor)
    fill(x1, y1, x2, y2, C.panel)
    center(y1, label, C.dim, C.panel, x1, x2)
    center(math.min(y2, y1 + 1), tostring(value), valueColor or C.text, C.panel, x1, x2)
end

local function drawHome()
    local w, h = size()
    local bodyTop = 5
    local bodyBottom = h - 2

    center(4, "COLONY STATUS", C.title, C.bg)

    -- Health warning banner. It appears only when at least one citizen is
    -- currently reporting a sickness-related MineColonies state.
    if (D.sick or 0) > 0 then
        local citizenWord = (D.sick == 1) and "CITIZEN" or "CITIZENS"
        local banner = "!!! HEALTH WARNING: " .. tostring(D.sick) .. " SICK " .. citizenWord .. " !!!"
        fill(1, 5, w, 5, C.danger)
        center(5, banner, C.headerText, C.danger)

        -- If space permits, show the affected names on a second line.
        local names = table.concat(D.sickNames or {}, ", ")
        fill(1, 6, w, 6, C.bg)
        local alarmState = sickTriggerHardwareText(D.sick, D.sickAlarmSuppressed)
        local triggerColor = D.sickAlarmSuppressed and C.good
            or (hasSickTriggerHardware() and C.danger or C.warn)
        if names ~= "" then
            center(6, "Sick: " .. names .. "  |  TRIGGER: " .. alarmState,
                triggerColor, C.bg)
        else
            center(6, "TRIGGER: " .. alarmState, triggerColor, C.bg)
        end

        -- Touching either warning line jumps directly to the citizen list.
        addTouchArea("sick_banner", 1, 5, w, 6, function()
            currentPage = "citizens"
            detail = nil
            detailScroll = 1
            listPage.citizens = 1
        end)

        bodyTop = 8
    end

    local cols = (w >= 72) and 4 or 2
    local gap = 1
    local tileW = math.floor((w - (cols - 1) * gap) / cols)
    local tileH = 2

    local stats = {
        {"POPULATION", tostring(D.population) .. "/" .. tostring(D.maxPopulation), C.good},
        {"HAPPINESS", string.format("%.2f", tonumber(D.happiness) or 0), C.info},
        {"REQUESTS", #D.requests, statColor("warn", #D.requests)},
        {"WORK ORDERS", #D.workOrders, statColor("warn", #D.workOrders)},
        {"IDLE", D.idle, statColor("warn", D.idle)},
        {"FOOD ALERTS", D.needFood, statColor("danger", D.needFood)},
        {"INJURED", D.injured, statColor("danger", D.injured)},
        {"NO JOB", D.noJob, statColor("warn", D.noJob)},
        {"HELP WANTED", D.helpWantedOpenings or 0, statColor("warn", D.helpWantedOpenings or 0)},
        {"CHILDREN", D.children, C.accent},
        {"VISITORS", #D.visitors, C.accent},
        {"CONSTRUCTION", D.constructionSites, statColor("warn", D.constructionSites)},
        {"GRAVES", D.graves, statColor("danger", D.graves)},
    }

    local maxRows = math.floor((bodyBottom - bodyTop + 1) / (tileH + 1))
    local maxTiles = maxRows * cols
    local count = math.min(#stats, maxTiles)

    for i = 1, count do
        local idx = i - 1
        local col = idx % cols
        local row = math.floor(idx / cols)
        local x1 = 1 + col * (tileW + gap)
        local x2 = math.min(w, x1 + tileW - 1)
        local y1 = bodyTop + row * (tileH + 1)
        local y2 = y1 + tileH - 1
        local s = stats[i]
        drawTile(x1, y1, x2, y2, s[1], s[2], s[3])
    end

    local infoY = bodyTop + math.ceil(count / cols) * (tileH + 1)
    if infoY <= bodyBottom then
        local line = "ID " .. tostring(D.id)
            .. "  |  Style " .. tostring(D.style)
            .. "  |  Town Hall " .. posText(D.location)
        center(infoY, line, C.dim, C.bg)
    end

    fill(1, h - 1, w, h - 1, C.panel)
    local refreshStart = math.max(1, w - 10)
    writeAt(2, h - 1, "Auto-refresh: " .. REFRESH_SECONDS .. "s", C.dim, C.panel)
    addButton("refresh", refreshStart, h - 1, w, h - 1, "REFRESH", C.navActive, C.navText, function()
        refreshData()
        updateSickTrigger()
        lastRefreshLabel = "just now"
    end)
end

-- =========================
-- List pages
-- =========================

local function listForPage(page)
    if page == "citizens" then return D.citizenDisplayRows or D.citizens end
    if page == "buildings" then return D.displayBuildings or visibleBuildings(D.buildings) end
    if page == "help" then return D.helpWanted or {} end
    if page == "requests" then return D.requests end
    if page == "orders" then return D.workOrders end
    return {}
end

local function listRowText(page, item, width)
    if page == "citizens" then
        local status = item.state or ""
        return clip((item.name or "Unknown") .. " | " .. citizenJob(item) .. " | " .. status, width)
    elseif page == "buildings" then
        local status = (not item.built) and "BUILDING" or (item.isWorkingOn and "UPGRADE" or "READY")
        return clip(cleanBuildingName(item.name or item.type or "Unknown") .. " | L" .. tostring(item.level or "?")
            .. "/" .. tostring(item.maxLevel or "?") .. " | " .. status, width)
    elseif page == "help" then
        local building = item.building or {}
        return clip(cleanBuildingName(building.name or building.type or "Unknown")
            .. " | L" .. tostring(building.level or "?")
            .. " | " .. tostring(item.filled or 0) .. "/" .. tostring(item.capacity or "?")
            .. " | OPEN " .. tostring(item.openings or 0), width)
    elseif page == "requests" then
        return clip(tostring(item.count or item.minCount or "?") .. "x "
            .. tostring(item.name or "Request") .. " | " .. tostring(item.target or ""), width)
    elseif page == "orders" then
        local status = workOrderStatus(item)
        local qn = workOrderQueueNumber(item)
        return clip("Q" .. tostring(qn or "-") .. " | "
            .. cleanBuildingName(item.buildingName or item.type or "Build") .. " | L"
            .. tostring(item.targetLevel or "?") .. " | " .. workOrderBuilderSummary(item, math.max(8, math.floor(width * 0.3)))
            .. " | " .. status, width)
    end
    return ""
end

local function listRowColor(page, item)
    if page == "citizens" then
        if type(item.health) == "number" and type(item.maxHealth) == "number" and item.health < item.maxHealth then return C.danger end
        if item.betterFood then return C.warn end
        if item.isIdle then return C.title end
        if item.age == "child" then return C.accent end
        return C.text
    elseif page == "buildings" then
        if not item.built then return C.warn end
        if item.isWorkingOn then return C.title end
        return C.good
    elseif page == "help" then
        return C.warn
    elseif page == "requests" then
        return C.warn
    elseif page == "orders" then
        local _, color = workOrderStatus(item)
        return color
    end
    return C.text
end

local function drawListPage(page)
    local w, h = size()
    local list = listForPage(page)
    local citizenTable = (page == "citizens")
    local buildingTable = (page == "buildings")
    local helpTable = (page == "help")
    local requestTable = (page == "requests")
    local orderTable = (page == "orders")
    local fixedTable = citizenTable or buildingTable or helpTable or requestTable or orderTable
    local top = fixedTable and 6 or 5
    local bottom = h - 2
    local rows = math.max(1, bottom - top + 1)
    local pagesTotal = math.max(1, math.ceil(#list / rows))
    listPage[page] = math.max(1, math.min(listPage[page] or 1, pagesTotal))
    local pg = listPage[page]
    local first = (pg - 1) * rows + 1
    local last = math.min(#list, first + rows - 1)

    if page == "orders" then
        center(4, pageTitle() .. "  (" .. #list .. ")  ACTIVE: " .. tostring(D.activeOrders or 0), C.title, C.bg)
    elseif page == "help" then
        center(4, pageTitle() .. "  (" .. #list .. " BUILDINGS | "
            .. tostring(D.helpWantedOpenings or 0) .. " OPENINGS)", C.title, C.bg)
    elseif page == "citizens" then
        center(4, pageTitle() .. "  (" .. #D.citizens .. ")", C.title, C.bg)
    else
        center(4, pageTitle() .. "  (" .. #list .. ")", C.title, C.bg)
    end

    local columns = nil
    if citizenTable then
        -- Fixed four-column citizen layout tuned for the 5x3 monitor.
        local usable = w - 2
        local separatorCount = 3
        local content = math.max(20, usable - separatorCount)

        local nameW = math.max(12, math.floor(content * 0.31))
        local jobW = math.max(10, math.floor(content * 0.25))
        local stateW = math.max(10, math.floor(content * 0.25))
        local statusW = content - nameW - jobW - stateW

        while statusW < 7 and (nameW > 12 or jobW > 10 or stateW > 10) do
            if nameW > 12 then nameW = nameW - 1
            elseif stateW > 10 then stateW = stateW - 1
            elseif jobW > 10 then jobW = jobW - 1 end
            statusW = content - nameW - jobW - stateW
        end
        statusW = math.max(1, statusW)

        local nameX = 2
        local sep1X = nameX + nameW
        local jobX = sep1X + 1
        local sep2X = jobX + jobW
        local stateX = sep2X + 1
        local sep3X = stateX + stateW
        local statusX = sep3X + 1

        columns = {
            nameX = nameX, nameW = nameW, sep1X = sep1X,
            jobX = jobX, jobW = jobW, sep2X = sep2X,
            stateX = stateX, stateW = stateW, sep3X = sep3X,
            statusX = statusX, statusW = math.max(1, w - statusX + 1),
        }

        fill(1, 5, w, 5, C.panel2)
        writeAt(columns.nameX, 5, pad("NAME", columns.nameW), colors.black, C.panel2)
        writeAt(columns.sep1X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.jobX, 5, pad("JOB", columns.jobW), colors.black, C.panel2)
        writeAt(columns.sep2X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.stateX, 5, pad("STATE", columns.stateW), colors.black, C.panel2)
        writeAt(columns.sep3X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.statusX, 5, pad("STATUS", columns.statusW), colors.black, C.panel2)

    elseif buildingTable then
        -- Clean fixed-column building table. The WORKER(S) column shows names
        -- directly; tapping the row opens the complete worker list.
        local usable = w - 2
        local separatorCount = 3
        local content = math.max(24, usable - separatorCount)

        local buildingW = math.max(15, math.floor(content * 0.31))
        local levelW = 7
        local statusW = 9
        local workersW = content - buildingW - levelW - statusW

        while workersW < 14 and buildingW > 15 do
            buildingW = buildingW - 1
            workersW = content - buildingW - levelW - statusW
        end
        workersW = math.max(1, workersW)

        local buildingX = 2
        local sep1X = buildingX + buildingW
        local levelX = sep1X + 1
        local sep2X = levelX + levelW
        local workersX = sep2X + 1
        local sep3X = workersX + workersW
        local statusX = sep3X + 1

        columns = {
            buildingX = buildingX, buildingW = buildingW, sep1X = sep1X,
            levelX = levelX, levelW = levelW, sep2X = sep2X,
            workersX = workersX, workersW = workersW, sep3X = sep3X,
            statusX = statusX, statusW = math.max(1, w - statusX + 1),
        }

        fill(1, 5, w, 5, C.panel2)
        writeAt(columns.buildingX, 5, pad("BUILDING", columns.buildingW), colors.black, C.panel2)
        writeAt(columns.sep1X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.levelX, 5, pad("LEVEL", columns.levelW), colors.black, C.panel2)
        writeAt(columns.sep2X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.workersX, 5, pad("WORKER(S)", columns.workersW), colors.black, C.panel2)
        writeAt(columns.sep3X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.statusX, 5, pad("STATUS", columns.statusW), colors.black, C.panel2)

    elseif helpTable then
        -- Help Wanted: BUILDING | LEVEL | FILLED | OPEN
        local usable = w - 2
        local separatorCount = 3
        local content = math.max(24, usable - separatorCount)

        local levelW = 7
        local filledW = 9
        local openW = 7
        local buildingW = math.max(16, content - levelW - filledW - openW)

        local buildingX = 2
        local sep1X = buildingX + buildingW
        local levelX = sep1X + 1
        local sep2X = levelX + levelW
        local filledX = sep2X + 1
        local sep3X = filledX + filledW
        local openX = sep3X + 1

        columns = {
            buildingX = buildingX, buildingW = buildingW, sep1X = sep1X,
            levelX = levelX, levelW = levelW, sep2X = sep2X,
            filledX = filledX, filledW = filledW, sep3X = sep3X,
            openX = openX, openW = math.max(1, w - openX + 1),
        }

        fill(1, 5, w, 5, C.panel2)
        writeAt(columns.buildingX, 5, pad("BUILDING", columns.buildingW), colors.black, C.panel2)
        writeAt(columns.sep1X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.levelX, 5, pad("LEVEL", columns.levelW), colors.black, C.panel2)
        writeAt(columns.sep2X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.filledX, 5, pad("FILLED", columns.filledW), colors.black, C.panel2)
        writeAt(columns.sep3X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.openX, 5, pad("OPEN", columns.openW), colors.black, C.panel2)

    elseif requestTable then
        -- Fixed-column request table tuned for the 5x3 monitor.
        -- REQUEST | QTY | TARGET | STATUS
        local usable = w - 2
        local separatorCount = 3
        local content = math.max(24, usable - separatorCount)

        local qtyW = 7
        local statusW = 12
        local requestW = math.max(16, math.floor(content * 0.34))
        local targetW = content - requestW - qtyW - statusW

        while targetW < 14 and requestW > 16 do
            requestW = requestW - 1
            targetW = content - requestW - qtyW - statusW
        end
        targetW = math.max(1, targetW)

        local requestX = 2
        local sep1X = requestX + requestW
        local qtyX = sep1X + 1
        local sep2X = qtyX + qtyW
        local targetX = sep2X + 1
        local sep3X = targetX + targetW
        local statusX = sep3X + 1

        columns = {
            requestX = requestX, requestW = requestW, sep1X = sep1X,
            qtyX = qtyX, qtyW = qtyW, sep2X = sep2X,
            targetX = targetX, targetW = targetW, sep3X = sep3X,
            statusX = statusX, statusW = math.max(1, w - statusX + 1),
        }

        fill(1, 5, w, 5, C.panel2)
        writeAt(columns.requestX, 5, pad("REQUEST", columns.requestW), colors.black, C.panel2)
        writeAt(columns.sep1X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.qtyX, 5, pad("QTY", columns.qtyW), colors.black, C.panel2)
        writeAt(columns.sep2X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.targetX, 5, pad("TARGET", columns.targetW), colors.black, C.panel2)
        writeAt(columns.sep3X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.statusX, 5, pad("STATUS", columns.statusW), colors.black, C.panel2)

    elseif orderTable then
        -- Fixed-column construction/work-order table tuned for the 5x3 monitor.
        -- Q# | BUILDING | TARGET | BUILDER | STATUS
        local usable = w - 2
        local separatorCount = 4
        local content = math.max(28, usable - separatorCount)

        local orderW = 4
        local targetW = 7
        local statusW = 9
        local buildingW = math.max(14, math.floor(content * 0.28))
        local builderW = content - orderW - buildingW - targetW - statusW

        while builderW < 12 and buildingW > 14 do
            buildingW = buildingW - 1
            builderW = content - orderW - buildingW - targetW - statusW
        end
        builderW = math.max(1, builderW)

        local orderX = 2
        local sep0X = orderX + orderW
        local buildingX = sep0X + 1
        local sep1X = buildingX + buildingW
        local targetX = sep1X + 1
        local sep2X = targetX + targetW
        local builderX = sep2X + 1
        local sep3X = builderX + builderW
        local statusX = sep3X + 1

        columns = {
            orderX = orderX, orderW = orderW, sep0X = sep0X,
            buildingX = buildingX, buildingW = buildingW, sep1X = sep1X,
            targetX = targetX, targetW = targetW, sep2X = sep2X,
            builderX = builderX, builderW = builderW, sep3X = sep3X,
            statusX = statusX, statusW = math.max(1, w - statusX + 1),
        }

        fill(1, 5, w, 5, C.panel2)
        writeAt(columns.orderX, 5, pad("Q#", columns.orderW), colors.black, C.panel2)
        writeAt(columns.sep0X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.buildingX, 5, pad("BUILDING", columns.buildingW), colors.black, C.panel2)
        writeAt(columns.sep1X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.targetX, 5, pad("TARGET", columns.targetW), colors.black, C.panel2)
        writeAt(columns.sep2X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.builderX, 5, pad("BUILDER", columns.builderW), colors.black, C.panel2)
        writeAt(columns.sep3X, 5, "|", colors.gray, C.panel2)
        writeAt(columns.statusX, 5, pad("STATUS", columns.statusW), colors.black, C.panel2)
    end

    if #list == 0 then
        center(math.floor((top + bottom) / 2), "Nothing to display", C.dim, C.bg)
    else
        local y = top
        for i = first, last do
            local rowIndex = i
            local item = list[rowIndex]
            local bg = (y % 2 == 0) and C.bg or C.panel
            fill(1, y, w, y, bg)

            if citizenTable then
                if item._sectionHeader then
                    fill(1, y, w, y, C.panel2)
                    local header = "-- " .. tostring(item._sectionTitle or "SECTION")
                        .. " (" .. tostring(item._sectionCount or 0) .. ") --"
                    center(y, header, C.title, C.panel2)
                else
                    local statusText, statusColor = citizenStatus(item)
                    writeAt(columns.nameX, y, pad(item.name or "Unknown", columns.nameW), C.text, bg)
                    writeAt(columns.sep1X, y, "|", C.dim, bg)
                    writeAt(columns.jobX, y, pad(citizenJob(item), columns.jobW), C.accent, bg)
                    writeAt(columns.sep2X, y, "|", C.dim, bg)
                    writeAt(columns.stateX, y, pad(item.state or "", columns.stateW), C.dim, bg)
                    writeAt(columns.sep3X, y, "|", C.dim, bg)
                    writeAt(columns.statusX, y, pad(statusText, columns.statusW), statusColor, bg)
                end

            elseif buildingTable then
                local statusText = (not item.built) and "BUILDING" or (item.isWorkingOn and "UPGRADE" or "READY")
                local statusColor = (not item.built) and C.warn or (item.isWorkingOn and C.title or C.good)
                local displayName = cleanBuildingName(item.name or item.type or "Unknown")
                local levelText = tostring(item.level or "?") .. "/" .. tostring(item.maxLevel or "?")
                local workerText = buildingWorkerSummary(item, columns.workersW)

                writeAt(columns.buildingX, y, pad(displayName, columns.buildingW), C.text, bg)
                writeAt(columns.sep1X, y, "|", C.dim, bg)
                writeAt(columns.levelX, y, pad(levelText, columns.levelW), C.accent, bg)
                writeAt(columns.sep2X, y, "|", C.dim, bg)
                writeAt(columns.workersX, y, pad(workerText, columns.workersW),
                    workerText == "None" and C.dim or C.info, bg)
                writeAt(columns.sep3X, y, "|", C.dim, bg)
                writeAt(columns.statusX, y, pad(statusText, columns.statusW), statusColor, bg)

            elseif helpTable then
                local building = item.building or {}
                local displayName = cleanBuildingName(building.name or building.type or "Unknown")
                local levelText = tostring(building.level or "?") .. "/" .. tostring(building.maxLevel or "?")
                local filledText = tostring(item.filled or 0) .. "/" .. tostring(item.capacity or "?")
                local openText = tostring(item.openings or 0)

                writeAt(columns.buildingX, y, pad(displayName, columns.buildingW), C.text, bg)
                writeAt(columns.sep1X, y, "|", C.dim, bg)
                writeAt(columns.levelX, y, pad(levelText, columns.levelW), C.accent, bg)
                writeAt(columns.sep2X, y, "|", C.dim, bg)
                writeAt(columns.filledX, y, pad(filledText, columns.filledW), C.info, bg)
                writeAt(columns.sep3X, y, "|", C.dim, bg)
                writeAt(columns.openX, y, pad(openText, columns.openW), C.warn, bg)

            elseif requestTable then
                local requestName = tostring(item.name or "Request")
                local amount = item.count
                if amount == nil then amount = item.minCount end
                local qtyText = tostring(amount or "?")
                local targetText = tostring(item.target or "")
                local statusText = tostring(item.state or "OPEN")
                local statusLower = statusText:lower()
                local statusColor = C.warn
                if statusLower:find("complete", 1, true) or statusLower:find("fulfilled", 1, true) then
                    statusColor = C.good
                elseif statusLower:find("cancel", 1, true) then
                    statusColor = C.danger
                elseif statusLower:find("progress", 1, true) or statusLower:find("assign", 1, true) then
                    statusColor = C.info
                end

                writeAt(columns.requestX, y, pad(requestName, columns.requestW), C.text, bg)
                writeAt(columns.sep1X, y, "|", C.dim, bg)
                writeAt(columns.qtyX, y, pad(qtyText, columns.qtyW), C.accent, bg)
                writeAt(columns.sep2X, y, "|", C.dim, bg)
                writeAt(columns.targetX, y, pad(targetText, columns.targetW), C.dim, bg)
                writeAt(columns.sep3X, y, "|", C.dim, bg)
                writeAt(columns.statusX, y, pad(statusText, columns.statusW), statusColor, bg)

            elseif orderTable then
                local statusText, statusColor = workOrderStatus(item)
                local displayName = cleanBuildingName(item.buildingName or item.type or "Build")
                local targetText = "L" .. tostring(item.targetLevel or "?")
                local builderText = workOrderBuilderSummary(item, columns.builderW)
                local builderColor = (#workOrderBuilders(item) > 0) and C.info or C.dim
                local queueNumber = workOrderQueueNumber(item)
                local orderText = queueNumber and tostring(queueNumber) or "-"

                writeAt(columns.orderX, y, pad(orderText, columns.orderW), statusText == "ACTIVE" and C.good or C.accent, bg)
                writeAt(columns.sep0X, y, "|", C.dim, bg)
                writeAt(columns.buildingX, y, pad(displayName, columns.buildingW), C.text, bg)
                writeAt(columns.sep1X, y, "|", C.dim, bg)
                writeAt(columns.targetX, y, pad(targetText, columns.targetW), C.accent, bg)
                writeAt(columns.sep2X, y, "|", C.dim, bg)
                writeAt(columns.builderX, y, pad(builderText, columns.builderW), builderColor, bg)
                writeAt(columns.sep3X, y, "|", C.dim, bg)
                writeAt(columns.statusX, y, pad(statusText, columns.statusW), statusColor, bg)

            else
                writeAt(2, y, listRowText(page, item, w - 3), listRowColor(page, item), bg)
            end

            if not item._sectionHeader then
                addTouchArea("row_" .. rowIndex, 1, y, w, y, function()
                    detail = { page = page, index = rowIndex }
                    detailScroll = 1
                end)
            end
            y = y + 1
        end
    end

    local sub = "Page " .. pg .. "/" .. pagesTotal
    if pagesTotal > 1 then
        local prevX2 = math.min(10, math.floor(w / 4))
        addButton("prev", 1, h - 1, prevX2, h - 1, "< PREV", C.panel, C.text, function()
            listPage[page] = math.max(1, (listPage[page] or 1) - 1)
        end)
        local nextX1 = math.max(prevX2 + 1, w - 9)
        addButton("next", nextX1, h - 1, w, h - 1, "NEXT >", C.panel, C.text, function()
            listPage[page] = math.min(pagesTotal, (listPage[page] or 1) + 1)
        end)
        center(h - 1, sub, C.dim, C.panel, prevX2 + 1, nextX1 - 1)
    else
        drawSubBar(sub .. " | Touch a row for details")
    end
end

-- =========================
-- Detail screens
-- =========================

local function addDetailLine(lines, label, value, color)
    lines[#lines + 1] = { label = label, value = tostr(value, "N/A"), color = color or C.text }
end

local function detailLines(page, item)
    local lines = {}

    if page == "citizens" then
        local statusText, statusColor = citizenStatus(item)
        addDetailLine(lines, "Name", item.name)
        addDetailLine(lines, "Status", statusText, statusColor)
        addDetailLine(lines, "Sick", yesno(isCitizenSick(item)), isCitizenSick(item) and C.danger or C.good)
        addDetailLine(lines, "Age", item.age)
        addDetailLine(lines, "Gender", item.gender)
        addDetailLine(lines, "State", item.state)
        if item.health ~= nil and item.maxHealth ~= nil then
            addDetailLine(lines, "Health", tostring(item.health) .. "/" .. tostring(item.maxHealth),
                item.health < item.maxHealth and C.danger or C.good)
        end
        addDetailLine(lines, "Happiness", item.happiness)
        addDetailLine(lines, "Saturation", item.saturation)
        addDetailLine(lines, "Idle", yesno(item.isIdle), item.isIdle and C.warn or C.good)
        addDetailLine(lines, "In bed", yesno(item.isAsleep), item.isAsleep and C.info or C.text)
        addDetailLine(lines, "Needs better food", yesno(item.betterFood), item.betterFood and C.danger or C.good)
        if type(item.work) == "table" then
            addDetailLine(lines, "Job", cleanJobName(item.work.job or "Worker"))
            addDetailLine(lines, "Workplace", item.work.name or item.work.type)
            addDetailLine(lines, "Work level", item.work.level)
            addDetailLine(lines, "Work location", posText(item.work.location))
        else
            addDetailLine(lines, "Job", item.age == "child" and "Child" or "No job", C.warn)
        end
        addDetailLine(lines, "Current location", posText(item.location))
        addDetailLine(lines, "Bed", posText(item.bedPos))
        if type(item.home) == "table" then
            addDetailLine(lines, "Home", item.home.type)
            addDetailLine(lines, "Home level", item.home.level)
            addDetailLine(lines, "Home location", posText(item.home.location))
        end

    elseif page == "buildings" then
        local workers = buildingWorkers(item)
        local statusText = (not item.built) and "BUILDING" or (item.isWorkingOn and "UPGRADE" or "READY")
        local statusColor = (not item.built) and C.warn or (item.isWorkingOn and C.title or C.good)

        addDetailLine(lines, "Building", cleanBuildingName(item.name or item.type or "Unknown"))
        addDetailLine(lines, "Type", cleanBuildingName(item.type or item.name or "Unknown"))
        addDetailLine(lines, "Status", statusText, statusColor)
        addDetailLine(lines, "Level", tostring(item.level or "?") .. "/" .. tostring(item.maxLevel or "?"))
        addDetailLine(lines, "Style", item.style)

        addDetailLine(lines, "Assigned workers", #workers, #workers > 0 and C.info or C.dim)
        if #workers == 0 then
            addDetailLine(lines, "Workers", "None assigned", C.dim)
        else
            for i, citizen in ipairs(workers) do
                local workerName = tostring(citizen.name or "Unknown")
                local job = citizenJob(citizen)
                if job ~= "No job" and job ~= "Child" then
                    workerName = workerName .. " (" .. job .. ")"
                end
                addDetailLine(lines, "Worker " .. i, workerName, C.info)
            end
        end

        addDetailLine(lines, "Built", yesno(item.built), item.built and C.good or C.warn)
        addDetailLine(lines, "Being worked on", yesno(item.isWorkingOn), item.isWorkingOn and C.warn or C.good)
        addDetailLine(lines, "Guarded", yesno(item.guarded), item.guarded and C.good or C.warn)
        addDetailLine(lines, "Priority", item.priority)
        addDetailLine(lines, "Storage blocks", item.storageBlocks)
        addDetailLine(lines, "Storage slots", item.storageSlots)
        addDetailLine(lines, "Location", posText(item.location))
        if type(item.structure) == "table" then
            addDetailLine(lines, "Structure A", posText(item.structure.cornerA))
            addDetailLine(lines, "Structure B", posText(item.structure.cornerB))
            addDetailLine(lines, "Rotation", item.structure.rotation)
            addDetailLine(lines, "Mirrored", yesno(item.structure.mirror))
        end

    elseif page == "help" then
        local building = item.building or {}
        local workers = item.workers or buildingWorkers(building)
        addDetailLine(lines, "Building", cleanBuildingName(building.name or building.type or "Unknown"))
        addDetailLine(lines, "Level", tostring(building.level or "?") .. "/" .. tostring(building.maxLevel or "?"))
        addDetailLine(lines, "Filled positions", item.filled or #workers, C.info)
        addDetailLine(lines, "Staffing capacity", item.capacity, C.text)
        addDetailLine(lines, "Open positions", item.openings, C.warn)
        if staffingBuildingKey(building) == "guardtower" then
            addDetailLine(lines, "Guard Tower rule", "1 fillable guard position", C.accent)
        end
        if #workers == 0 then
            addDetailLine(lines, "Current workers", "None", C.dim)
        else
            for i, citizen in ipairs(workers) do
                addDetailLine(lines, "Worker " .. i, tostring(citizen.name or "Unknown")
                    .. " (" .. citizenJob(citizen) .. ")", C.info)
            end
        end
        addDetailLine(lines, "Location", posText(building.location))

    elseif page == "requests" then
        addDetailLine(lines, "Request", item.name)
        addDetailLine(lines, "State", item.state)
        addDetailLine(lines, "Count", item.count)
        addDetailLine(lines, "Minimum", item.minCount)
        addDetailLine(lines, "Target", item.target)
        lines[#lines + 1] = { label = "Description", value = tostring(item.desc or ""), wrap = true, color = C.text }
        if type(item.items) == "table" then
            local items = normalizeList(item.items)
            for i, it in ipairs(items) do
                local name = it.displayName or it.name or "Item"
                addDetailLine(lines, "Item " .. i, tostring(it.count or "?") .. "x " .. tostring(name), C.accent)
            end
        end

    elseif page == "orders" then
        local builders = workOrderBuilders(item)
        addDetailLine(lines, "Building", cleanBuildingName(item.buildingName or item.type or "Build"))
        addDetailLine(lines, "Type", cleanBuildingName(item.type or item.buildingName or "Build"))
        local orderStatus, orderStatusColor, targetBuilding = workOrderStatus(item)
        addDetailLine(lines, "Queue position", workOrderQueueNumber(item) or "-", C.accent)
        addDetailLine(lines, "Raw AP work PRI", item.priority ~= nil and item.priority or "-", C.dim)
        addDetailLine(lines, "Target level", item.targetLevel)
        addDetailLine(lines, "Status", orderStatus, orderStatusColor)
        if targetBuilding then
            addDetailLine(lines, "Target worked on", yesno(targetBuilding.isWorkingOn), targetBuilding.isWorkingOn and C.good or C.dim)
        end
        addDetailLine(lines, "Order type", cleanBuildingName(item.workOrderType or "Construction"))

        addDetailLine(lines, "Assigned builder(s)", #builders, #builders > 0 and C.info or C.dim)
        if #builders == 0 then
            addDetailLine(lines, "Builder", item.isClaimed and "Assigned (name unresolved)" or "Unassigned", C.dim)
        else
            for i, citizen in ipairs(builders) do
                local label = (#builders == 1) and "Builder" or ("Builder " .. i)
                local value = tostring(citizen.name or "Unknown")
                local job = citizenJob(citizen)
                if job ~= "No job" and job ~= "Child" then
                    value = value .. " (" .. job .. ")"
                end
                addDetailLine(lines, label, value, C.info)
            end
        end

        addDetailLine(lines, "Builder/Hut pos", posText(item.builder))
        addDetailLine(lines, "Changed", yesno(item.changed))
        addDetailLine(lines, "Order ID", item.id)
    end

    return lines
end

local function flattenDetailLines(lines, width)
    local out = {}
    for _, line in ipairs(lines) do
        local prefix = tostring(line.label or "") .. ": "
        if line.wrap then
            local wrapped = wrapText(line.value or "", math.max(1, width - 2))
            out[#out + 1] = { text = line.label .. ":", color = C.dim }
            for _, s in ipairs(wrapped) do
                out[#out + 1] = { text = "  " .. s, color = line.color or C.text }
            end
        else
            out[#out + 1] = { text = prefix .. tostring(line.value or ""), color = line.color or C.text }
        end
    end
    return out
end

local function drawDetail()
    local w, h = size()
    local list = listForPage(detail.page)
    local item = list[detail.index]
    if not item then
        detail = nil
        return
    end

    local names = { citizens = "CITIZEN", buildings = "BUILDING", requests = "REQUEST", orders = "CONSTRUCTION ORDER" }
    center(4, names[detail.page] .. " DETAILS", C.title, C.bg)

    local lines = flattenDetailLines(detailLines(detail.page, item), w - 4)
    local top = 5
    local bottom = h - 2
    local rows = math.max(1, bottom - top + 1)
    local maxScroll = math.max(1, #lines - rows + 1)
    detailScroll = math.max(1, math.min(detailScroll, maxScroll))

    local y = top
    for i = detailScroll, math.min(#lines, detailScroll + rows - 1) do
        writeAt(2, y, clip(lines[i].text, w - 3), lines[i].color, C.bg)
        y = y + 1
    end

    fill(1, h - 1, w, h - 1, C.panel)
    local backEnd = math.min(10, w)
    addButton("back", 1, h - 1, backEnd, h - 1, "< BACK", C.panel, C.text, function()
        detail = nil
        detailScroll = 1
    end)

    if #lines > rows then
        local upX1 = math.max(backEnd + 2, w - 19)
        local upX2 = math.min(w - 10, upX1 + 8)
        local downX1 = math.max(upX2 + 1, w - 9)
        addButton("up", upX1, h - 1, upX2, h - 1, "UP", C.panel, C.text, function()
            detailScroll = math.max(1, detailScroll - rows)
        end)
        addButton("down", downX1, h - 1, w, h - 1, "DOWN", C.panel, C.text, function()
            detailScroll = math.min(maxScroll, detailScroll + rows)
        end)
    else
        center(h - 1, "Touch BACK to return", C.dim, C.panel, backEnd + 1, w)
    end
end

-- =========================
-- Main draw
-- =========================

local function drawTooSmall()
    local w, h = size()
    clear()
    center(math.max(1, math.floor(h / 2) - 1), "MONITOR TOO SMALL", C.danger, C.bg)
    center(math.max(1, math.floor(h / 2)), "Use a larger Advanced Monitor", C.text, C.bg)
    center(math.min(h, math.floor(h / 2) + 1), "or lower TEXT_SCALE", C.dim, C.bg)
end

local function draw()
    local w, h = size()
    resetButtons()
    clear()

    if w < 38 or h < 14 then
        drawTooSmall()
        return
    end

    drawHeader()

    if detail then
        drawDetail()
    elseif currentPage == "home" then
        drawHome()
    else
        drawListPage(currentPage)
    end

    drawNav()
end

-- =========================
-- Startup validation
-- =========================

local inColony = api("isInColony", false)
if not inColony then
    clear()
    local w, h = size()
    center(math.max(1, math.floor(h / 2) - 1), "COLONY INTEGRATOR ERROR", C.danger, C.bg)
    center(math.floor(h / 2), "Integrator is not inside a MineColonies colony.", C.text, C.bg)
    error("Colony Integrator is not inside a colony.")
end

refreshData()
updateSickTrigger()

-- Show the update check explicitly on the computer terminal during startup.
renderTerminalStartup(updateStatusText(true), "STARTING")
checkForUpdate()
renderTerminalStartup(updateStatusText(false), "RUNNING")

draw()

local refreshTimer = os.startTimer(REFRESH_SECONDS)
local blinkTimer = os.startTimer(RAID_BLINK_SECONDS)
local updateTimer = os.startTimer(UPDATE_CHECK_SECONDS)

-- =========================
-- Event loop
-- =========================

while true do
    local event, p1, p2, p3 = os.pullEvent()

    if event == "monitor_touch" then
        local touchedMonitor, x, y = p1, p2, p3
        if touchedMonitor == monitorName then
            local b = hitButton(x, y)
            if b and b.action then
                b.action()
                draw()
            end
        end

    elseif event == "timer" then
        if p1 == refreshTimer then
            refreshData()
            updateSickTrigger()
            lastRefreshLabel = "just now"
            draw()
            refreshTimer = os.startTimer(REFRESH_SECONDS)
        elseif p1 == blinkTimer then
            raidBlink = not raidBlink
            if D.underAttack then draw() end
            blinkTimer = os.startTimer(RAID_BLINK_SECONDS)

        elseif p1 == updateTimer then
            local previousVersion = UPDATE.availableVersion
            local previousError = UPDATE.checkError
            local previousRemote = UPDATE.remoteSuiteVersion

            checkForUpdate()

            -- Redraw immediately if update state changed so the UPDATE button
            -- appears/disappears without requiring a restart.
            if previousVersion ~= UPDATE.availableVersion
                or previousError ~= UPDATE.checkError
                or previousRemote ~= UPDATE.remoteSuiteVersion then
                draw()
            end

            -- Keep the terminal startup/status summary current as well.
            renderTerminalStartup(updateStatusText(false), "RUNNING")

            updateTimer = os.startTimer(UPDATE_CHECK_SECONDS)
        end

    elseif event == "monitor_resize" then
        local changedMonitor = p1
        if changedMonitor == monitorName then
            monitor.setTextScale(TEXT_SCALE)
            draw()
        end

    elseif event == "peripheral_detach" then
        if p1 == monitorName then
            error("Command Center monitor was detached.")
        end

        -- If a Redstone Integrator disappears, immediately move the alarm
        -- output to the computer TOP fallback.
        updateSickTrigger()
        draw()

    elseif event == "peripheral" then
        -- If a Redstone Integrator appears, immediately prefer it and clear
        -- the computer TOP fallback.
        updateSickTrigger()
        draw()
    end
end
