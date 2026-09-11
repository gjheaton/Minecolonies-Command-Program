-- MineColonies Control Suite - shared utility helpers
-- Component version: 1.0.1
local M = {}
M.COMPONENT_VERSION = "1.0.1"

function M.clamp(n, lo, hi)
    if n < lo then return lo end
    if n > hi then return hi end
    return n
end

function M.trim(s)
    s = tostring(s or "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.clip(s, width)
    s = tostring(s or "")
    width = math.max(0, tonumber(width) or 0)
    if #s <= width then return s end
    if width <= 3 then return s:sub(1, width) end
    return s:sub(1, width - 3) .. "..."
end

M.truncateText = M.clip

function M.healthWord(ok)
    return ok and "ONLINE" or "OFFLINE"
end

function M.padRight(s, width)
    s = M.clip(s, width)
    return s .. string.rep(" ", math.max(0, width - #s))
end

function M.padLeft(s, width)
    s = tostring(s or "")
    if #s > width then s = s:sub(#s - width + 1) end
    return string.rep(" ", math.max(0, width - #s)) .. s
end

function M.centerText(s, width)
    s = M.clip(s, width)
    local left = math.floor((width - #s) / 2)
    return string.rep(" ", left) .. s .. string.rep(" ", math.max(0, width - #s - left))
end

function M.wrapText(text, width)
    text = tostring(text or "")
    width = math.max(1, tonumber(width) or 1)
    local lines = {}
    for paragraph in (text .. "\n"):gmatch("(.-)\n") do
        if paragraph == "" then
            lines[#lines + 1] = ""
        else
            local line = ""
            for word in paragraph:gmatch("%S+") do
                if #word > width then
                    if #line > 0 then
                        lines[#lines + 1] = line
                        line = ""
                    end
                    while #word > width do
                        lines[#lines + 1] = word:sub(1, width)
                        word = word:sub(width + 1)
                    end
                    line = word
                elseif line == "" then
                    line = word
                elseif #line + 1 + #word <= width then
                    line = line .. " " .. word
                else
                    lines[#lines + 1] = line
                    line = word
                end
            end
            if line ~= "" then lines[#lines + 1] = line end
        end
    end
    return lines
end

return M
