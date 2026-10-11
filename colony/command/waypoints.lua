-- JourneyMap's documented chat location format. Chat acceptance does not
-- establish that a player clicked it or created a client-side waypoint.
local M={}
local function label(value,fallback)
    local text=tostring(value or ""):gsub("§.",""):gsub("[%c,%[%]]"," "):gsub('"',""):gsub("%s+"," ")
    text=text:match("^%s*(.-)%s*$")
    return text~="" and text:sub(1,80) or fallback
end
local function coordinate(value)
    return type(value)=="number" and value==value and value~=math.huge and value~=-math.huge
        and value%1==0 and math.abs(value)<=30000000
end
function M.message(colonyName,buildingName,position)
    if type(position)~="table" or not coordinate(position.x) or not coordinate(position.y) or not coordinate(position.z) then
        return nil,"Hut coordinates are unavailable or invalid."
    end
    return string.format("[name:%s - %s, x:%d, y:%d, z:%d]",label(colonyName,"Colony"),
        label(buildingName,"Hut"),position.x,position.y,position.z)
end
-- Work orders expose a builder location, not necessarily the target hut.
-- Only mark a uniquely identified target; never guess among duplicate huts.
function M.orderHut(order,buildings)
    local found
    for _,hut in ipairs(buildings or {}) do
        local matches=(order.buildingName and (order.buildingName==hut.name or order.buildingName==hut.type))
            or (order.type and (order.type==hut.type or order.type==hut.name))
        if matches then
            if found then return nil end
            found=hut
        end
    end
    return found
end
function M.share(colonyName,buildingName,position)
    local message,reason=M.message(colonyName,buildingName,position)
    if not message then return false,reason end
    local found,chat=pcall(peripheral.find,"chatBox")
    if not found or not chat or type(chat.sendMessage)~="function" then
        return false,"Connect an Advanced Peripherals Chat Box to share a waypoint."
    end
    local called,sent,err=pcall(chat.sendMessage,message,"Colony Command")
    if not called then return false,"Chat Box error: "..tostring(sent) end
    if sent~=true then return false,"Waypoint was not sent: "..tostring(err or "Chat Box busy or unavailable; try again.") end
    return true,"Waypoint shared in public chat. Click it in your colony's dimension to create the JourneyMap beacon."
end
return M
