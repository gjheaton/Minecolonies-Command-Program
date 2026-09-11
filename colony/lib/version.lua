-- MineColonies Control Suite - shared version helpers
-- Component version: 1.0.0
local M = {}
M.COMPONENT_VERSION = "1.0.0"

function M.parts(version)
    local out = {}
    for n in tostring(version or ""):gmatch("(%d+)") do
        out[#out + 1] = tonumber(n) or 0
    end
    return out
end

function M.compare(a, b)
    local av = M.parts(a)
    local bv = M.parts(b)
    local count = math.max(#av, #bv)
    if count == 0 then return 0 end
    for i = 1, count do
        local aa = av[i] or 0
        local bb = bv[i] or 0
        if aa < bb then return -1 end
        if aa > bb then return 1 end
    end
    return 0
end

function M.isNewer(remoteVersion, localVersion)
    return M.compare(remoteVersion, localVersion) > 0
end

function M.extractProgramVersion(source)
    if type(source) ~= "string" then return nil end
    return source:match("local%s+PROGRAM_VERSION%s*=%s*[\"']([^\"']+)[\"']")
        or source:match("local%s+VERSION%s*=%s*[\"']([^\"']+)[\"']")
end

function M.safe(version)
    return tostring(version or "unknown"):gsub("[^%w%-_%.]", "_")
end

return M
