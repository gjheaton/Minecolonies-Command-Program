-- MineColonies Command Center v3 - visitor/job suitability analysis
-- Skill pairs are based on MineColonies 1.20.1 worker module definitions.
-- Suitability is a Command Center heuristic: 65% primary skill, 35% secondary.

local M = {}

M.COMPONENT_VERSION = "1.0.0"
M.PRIMARY_WEIGHT = 0.65
M.SECONDARY_WEIGHT = 0.35

local JOBS = {
    {id="composter", label="Composter", primary="Stamina", secondary="Athletics", buildings={"composter"}},
    {id="farmer", label="Farmer", primary="Stamina", secondary="Athletics", buildings={"farmer","farm"}},
    {id="planter", label="Planter", primary="Agility", secondary="Dexterity", buildings={"plantation","planter"}},
    {id="florist", label="Florist", primary="Dexterity", secondary="Agility", buildings={"florist"}},
    {id="beekeeper", label="Beekeeper", primary="Dexterity", secondary="Adaptability", buildings={"beekeeper","apiary"}},
    {id="chickenherder", label="Chicken Herder", primary="Adaptability", secondary="Agility", buildings={"chickenherder","chickenfarmer"}},
    {id="cowboy", label="Cow Herder", primary="Athletics", secondary="Stamina", buildings={"cowherder","cowboy"}},
    {id="stablemaster", label="Stablemaster", primary="Athletics", secondary="Dexterity", buildings={"stable"}},
    {id="fisherman", label="Fisher", primary="Focus", secondary="Agility", buildings={"fisherman","fisher"}},
    {id="rabbitherder", label="Rabbit Herder", primary="Agility", secondary="Athletics", buildings={"rabbitherder"}},
    {id="shepherd", label="Shepherd", primary="Focus", secondary="Strength", buildings={"shepherd"}},
    {id="swineherder", label="Swine Herder", primary="Strength", secondary="Athletics", buildings={"swineherder"}},

    {id="alchemist", label="Alchemist", primary="Dexterity", secondary="Mana", buildings={"alchemist"}},
    {id="baker", label="Baker", primary="Knowledge", secondary="Dexterity", buildings={"baker","bakery"}},
    {id="blacksmith", label="Blacksmith", primary="Strength", secondary="Focus", buildings={"blacksmith"}},
    {id="concretemixer", label="Concrete Mixer", primary="Stamina", secondary="Dexterity", buildings={"concretemixer"}},
    {id="crusher", label="Crusher", primary="Stamina", secondary="Strength", buildings={"crusher"}},
    {id="dyer", label="Dyer", primary="Creativity", secondary="Dexterity", buildings={"dyer"}},
    {id="fletcher", label="Fletcher", primary="Dexterity", secondary="Creativity", buildings={"fletcher"}},
    {id="glassblower", label="Glassblower", primary="Creativity", secondary="Focus", buildings={"glassblower"}},
    {id="mechanic", label="Mechanic", primary="Knowledge", secondary="Agility", buildings={"mechanic"}},
    {id="sawmill", label="Sawmill Worker", primary="Knowledge", secondary="Dexterity", buildings={"sawmill"}},
    {id="sifter", label="Sifter", primary="Focus", secondary="Strength", buildings={"sifter"}},
    {id="smelter", label="Smelter", primary="Athletics", secondary="Strength", buildings={"smelter","smeltery"}},
    {id="stonemason", label="Stonemason", primary="Creativity", secondary="Dexterity", buildings={"stonemason"}},
    {id="stonesmelter", label="Stone Smelter", primary="Athletics", secondary="Dexterity", buildings={"stonesmelter","stonesmeltery","brickyard"}},

    {id="courier", label="Courier", primary="Agility", secondary="Adaptability", buildings={"courier","courierhut","deliveryman"}},
    {id="teacher", label="Teacher", primary="Knowledge", secondary="Mana", buildings={"school"}},
    {id="researcher", label="Researcher", primary="Knowledge", secondary="Mana", buildings={"university"}},
    {id="builder", label="Builder", primary="Adaptability", secondary="Athletics", buildings={"builder","builderhut"}},
    {id="cook", label="Cook", primary="Adaptability", secondary="Knowledge", buildings={"cook","restaurant"}},
    {id="chef", label="Chef", primary="Creativity", secondary="Knowledge", buildings={"chef","kitchen","cookery"}},
    {id="lumberjack", label="Forester", primary="Strength", secondary="Focus", buildings={"forester","lumberjack"}},
    {id="healer", label="Healer", primary="Mana", secondary="Knowledge", buildings={"hospital","healer"}},
    {id="miner", label="Miner", primary="Strength", secondary="Stamina", buildings={"miner","mine"}},
    {id="quarrier", label="Quarrier", primary="Strength", secondary="Stamina", buildings={"miner","mine"}},
    {id="enchanter", label="Enchanter", primary="Mana", secondary="Knowledge", buildings={"enchanter"}},
    {id="undertaker", label="Undertaker", primary="Strength", secondary="Mana", buildings={"undertaker","graveyard"}},
    {id="netherworker", label="Nether Miner", primary="Adaptability", secondary="Strength", buildings={"netherworker","nethermine"}},

    {id="knight", label="Knight", primary="Adaptability", secondary="Stamina", buildings={"guardtower","barrackstower","barracks","guardgate","gate"}},
    {id="ranger", label="Ranger", primary="Agility", secondary="Adaptability", buildings={"guardtower","barrackstower","barracks","guardgate","gate"}},
    {id="druid", label="Druid", primary="Mana", secondary="Focus", buildings={"guardtower","barrackstower","barracks"}},
    {id="marksman", label="Marksman", primary="Agility", secondary="Adaptability", buildings={"guardtower","barrackstower","barracks"}},
    {id="huscarl", label="Huscarl", primary="Adaptability", secondary="Stamina", buildings={"guardtower","barrackstower","barracks"}},
    {id="cavalry", label="Cavalry", primary="Adaptability", secondary="Stamina", buildings={"stable"}},

    -- Training jobs are useful only when the colony actually has an opening
    -- in one of these training buildings. They are intentionally excluded from
    -- the visitor's overall "best job" list to avoid recommending training in
    -- place of a productive job with the same skill pair.
    {id="archertrainee", label="Archer Trainee", primary="Agility", secondary="Adaptability", buildings={"archery"}, openOnly=true},
    {id="knighttrainee", label="Knight Trainee", primary="Adaptability", secondary="Stamina", buildings={"combatacademy"}, openOnly=true},
}

M.JOBS = JOBS

local function norm(value)
    return tostring(value or ""):lower():gsub("[^%w]", "")
end

local function levelValue(value)
    if type(value) == "table" then
        value = value.level or value.Level or value.value or value.current
    end
    return math.max(0, tonumber(value) or 0)
end

function M.skillLevel(visitor, skillName)
    local skills = type(visitor) == "table" and visitor.skills or nil
    if type(skills) ~= "table" then return 0 end

    local wanted = norm(skillName)
    for key, value in pairs(skills) do
        if norm(key) == wanted then return levelValue(value) end
        if type(value) == "table" then
            local embedded = value.name or value.skill or value.id
            if embedded and norm(embedded) == wanted then
                return levelValue(value)
            end
        end
    end
    return 0
end

function M.score(visitor, job)
    if type(job) ~= "table" then return 0, 0, 0 end
    local primary = M.skillLevel(visitor, job.primary)
    local secondary = M.skillLevel(visitor, job.secondary)
    local score
    if norm(job.primary) == norm(job.secondary) then
        score = primary
    else
        score = primary * M.PRIMARY_WEIGHT + secondary * M.SECONDARY_WEIGHT
    end
    return score, primary, secondary
end

function M.fitBand(score)
    score = tonumber(score) or 0
    if score >= 50 then return "EXCELLENT" end
    if score >= 30 then return "STRONG" end
    if score >= 15 then return "FAIR" end
    return "WEAK"
end

local function jobMatchesBuilding(job, buildingKey)
    local wanted = norm(buildingKey)
    if wanted == "" then return false end
    for _, alias in ipairs(job.buildings or {}) do
        if norm(alias) == wanted then return true end
    end
    return false
end

local function collectOpenJobs(helpWanted)
    local result = {}

    for _, row in ipairs(helpWanted or {}) do
        if type(row) == "table" and (tonumber(row.openings) or 0) > 0 then
            local key = row.buildingKey
            local building = row.building or {}
            if not key then
                key = building.type or building.name or building.id
            end

            for _, job in ipairs(JOBS) do
                if jobMatchesBuilding(job, key) then
                    local entry = result[job.id]
                    if not entry then
                        entry = { openings = 0, buildings = {} }
                        result[job.id] = entry
                    end
                    entry.openings = entry.openings + (tonumber(row.openings) or 0)
                    entry.buildings[#entry.buildings + 1] =
                        tostring(building.name or building.type or key or "Unknown")
                end
            end
        end
    end

    return result
end

local function ranked(visitor, openJobs, openOnly)
    local rows = {}
    for _, job in ipairs(JOBS) do
        local include = true
        local open = openJobs and openJobs[job.id] or nil

        if openOnly then
            include = open ~= nil
        elseif job.openOnly then
            include = false
        end

        if include then
            local score, primaryLevel, secondaryLevel = M.score(visitor, job)
            rows[#rows + 1] = {
                id = job.id,
                label = job.label,
                primary = job.primary,
                secondary = job.secondary,
                primaryLevel = primaryLevel,
                secondaryLevel = secondaryLevel,
                score = score,
                band = M.fitBand(score),
                openings = open and open.openings or 0,
                buildings = open and open.buildings or {},
            }
        end
    end

    table.sort(rows, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        if a.primaryLevel ~= b.primaryLevel then
            return a.primaryLevel > b.primaryLevel
        end
        if a.secondaryLevel ~= b.secondaryLevel then
            return a.secondaryLevel > b.secondaryLevel
        end
        return tostring(a.label):lower() < tostring(b.label):lower()
    end)

    return rows
end

local function topN(rows, count)
    local out = {}
    for i = 1, math.min(count or 3, #rows) do out[#out + 1] = rows[i] end
    return out
end

function M.recommend(visitor, helpWanted)
    local openJobs = collectOpenJobs(helpWanted)
    local overall = ranked(visitor, openJobs, false)
    local open = ranked(visitor, openJobs, true)

    return {
        visitor = visitor,
        overall = topN(overall, 3),
        open = topN(open, 3),
        best = overall[1],
        bestOpen = open[1],
    }
end

function M.evaluateAll(visitors, helpWanted)
    local out = {}
    for _, visitor in ipairs(visitors or {}) do
        out[#out + 1] = M.recommend(visitor, helpWanted)
    end
    table.sort(out, function(a, b)
        return tostring(a.visitor and a.visitor.name or ""):lower()
            < tostring(b.visitor and b.visitor.name or ""):lower()
    end)
    return out
end

local function costItemText(item)
    if type(item) ~= "table" then return nil end
    local name = item.displayName or item.name
    if not name then return nil end
    return tostring(math.max(1, math.floor(tonumber(item.count) or 1)))
        .. "x " .. tostring(name)
end

function M.formatRecruitCost(visitor)
    local cost = type(visitor) == "table" and visitor.recruitCost or nil
    if type(cost) ~= "table" then return "Unknown" end

    local one = costItemText(cost)
    if one then return one end

    local parts = {}
    for _, item in pairs(cost) do
        local text = costItemText(item)
        if text then parts[#parts + 1] = text end
    end
    table.sort(parts)
    if #parts == 0 then return "Unknown" end
    return table.concat(parts, ", ")
end

function M.skillsDescending(visitor)
    local out = {}
    local skills = type(visitor) == "table" and visitor.skills or nil
    if type(skills) ~= "table" then return out end

    for key, value in pairs(skills) do
        local name = tostring(
            type(value) == "table" and (value.name or value.skill) or key
        )
        local level = levelValue(value)
        out[#out + 1] = { name = name, level = level }
    end

    table.sort(out, function(a, b)
        if a.level ~= b.level then return a.level > b.level end
        return tostring(a.name):lower() < tostring(b.name):lower()
    end)
    return out
end

return M
