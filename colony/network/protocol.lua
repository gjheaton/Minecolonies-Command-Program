-- Explicit master identity; no election or distributed PRS ownership.
local M={NAME="minecolonies_prs_master_v4",VERSION=1}
function M.open()
    local count=0
    for _,name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name,"modem") then
            local ok=pcall(rednet.open,name); if ok and rednet.isOpen(name) then count=count+1 end
        end
    end
    return count>0,count
end
local function bounded(value,depth,seen,budget)
    budget[1]=budget[1]+1
    if depth>12 or budget[1]>30000 then return false end
    local kind=type(value)
    if kind=="string" then return #value<=4096 end
    if kind=="number" then return value==value and value~=math.huge and value~=-math.huge end
    if kind=="nil" or kind=="boolean" then return true end
    if kind~="table" or seen[value] then return false end
    seen[value]=true
    for key,entry in pairs(value) do if not bounded(key,depth+1,seen,budget) or not bounded(entry,depth+1,seen,budget) then return false end end
    seen[value]=nil; return true
end
function M.valid(message)
    return type(message)=="table" and message.version==M.VERSION and type(message.kind)=="string"
        and bounded(message,0,{}, {0})
end
function M.send(id,message)
    local wire={}; for key,value in pairs(message) do wire[key]=value end
    wire.version=M.VERSION
    if not M.valid(wire) then return false,"Message exceeds protocol limits" end
    local ok,result=pcall(rednet.send,id,wire,M.NAME)
    return ok and result~=false, not ok and tostring(result) or nil
end
return M
