-- Persisted settings for the dedicated PRS master and colony clients.
local M = { VERSION = "4.1.0", PATH = "/colony/network.cfg",
    DISPLAY = {blocksWide=5,blocksHigh=3,textScale=.5,columns=100,rows=38} }
local fields = {
    {key="automationEnabled",label="Run supply automation",type="boolean",default=true,roles={master=true}},
    {key="masterId",label="Master computer ID",type="number",default=-1,min=-1,max=2147483647,integer=true,roles={supply=true}},
    {key="playerBridgeName",label="PRS Bridge",type="string",default="",roles={master=true}},
    {key="colonyBridgeName",label="Colony RS Bridge",type="string",default="",roles={supply=true}},
    {key="colonyIntegratorName",label="Colony Integrator",type="string",default="",roles={supply=true}},
    {key="monitorName",label="Monitor",type="string",default=""},
    {key="deliveryChestName",label="Delivery Ender Chest",type="string",default="",roles={supply=true}},
    {key="returnChestName",label="Return Ender Chest",type="string",default="",roles={supply=true}},
    {key="deliveryChannel",label="Delivery chest colors",type="string",default="",roles={supply=true}},
    {key="returnChannel",label="Return chest colors",type="string",default="",roles={supply=true}},
    {key="usePeripheralTransfer",label="Transfer by peripheral name",type="boolean",default=true},
    {key="colonyImportDirection",label="CRS import direction",type="string",default="east",roles={supply=true}},
    {key="colonyExportDirection",label="CRS export direction",type="string",default="east",roles={supply=true}},
    {key="autoCraftEnabled",label="Autocrafting",type="boolean",default=true},
    {key="overflowEnabled",label="Return overflow",type="boolean",default=false,roles={supply=true}},
    {key="pollIntervalSeconds",label="Processor interval (s)",type="number",default=1,min=.1,max=3600},
    {key="helloSeconds",label="Hello interval (s)",type="number",default=5,min=1,max=3600},
    {key="telemetryIntervalSeconds",label="Dashboard update interval (s)",type="number",default=5,min=1,max=3600},
    {key="telemetryStaleSeconds",label="Dashboard stale timeout (s)",type="number",default=20,min=2,max=86400},
    {key="telemetryOfflineSeconds",label="Dashboard offline timeout (s)",type="number",default=60,min=2,max=604800},
    {key="telemetryMaxRequests",label="Dashboard request limit",type="number",default=128,min=1,max=1024,integer=true},
    {key="telemetryHistoryEntries",label="Dashboard history limit",type="number",default=40,min=1,max=200,integer=true},
    {key="telemetryErrorEntries",label="Dashboard error limit",type="number",default=20,min=1,max=100,integer=true},
    {key="colonyResponseTimeoutSeconds",label="Colony response timeout (s)",type="number",default=30,min=1,max=86400},
    {key="batchRetrySeconds",label="Message retry interval (s)",type="number",default=5,min=1,max=3600},
    {key="messageTimeoutSeconds",label="Master response timeout (s)",type="number",default=30,min=1,max=86400},
    {key="onHandTimeoutSeconds",label="On-hand delivery timeout (s)",type="number",default=120,min=1,max=604800},
    {key="craftingTimeoutSeconds",label="Crafting timeout (s)",type="number",default=600,min=1,max=604800},
    {key="acknowledgementTimeoutSeconds",label="MineColonies ACK timeout (s)",type="number",default=600,min=1,max=604800},
    {key="transferVerifyTimeoutSeconds",label="Chest verification timeout (s)",type="number",default=5,min=.1,max=3600},
    {key="transferSettleSeconds",label="Transfer settle time (s)",type="number",default=.25,min=0,max=60},
    {key="transferPollSeconds",label="Verification interval (s)",type="number",default=.25,min=.05,max=60},
    {key="craftCooldownSeconds",label="Craft cooldown (s)",type="number",default=30,min=1,max=86400},
    {key="craftPollSeconds",label="Craft output check interval (s)",type="number",default=15,min=1,max=86400},
    {key="craftStableReadsRequired",label="Stable craft output observations",type="number",default=2,min=2,max=20,integer=true},
    {key="retryCooldownSeconds",label="Failure retry cooldown (s)",type="number",default=30,min=1,max=86400},
    {key="desyncProbeSeconds",label="Recovery probe interval (s)",type="number",default=30,min=1,max=86400},
    {key="updateCheckSeconds",label="Update check interval (s)",type="number",default=1800,min=60,max=604800},
    {key="maxRequestsPerTurn",label="Requests per turn",type="number",default=8,min=1,max=64,integer=true},
    {key="maxItemsPerTurn",label="Items per master turn",type="number",default=256,min=1,max=65536,integer=true},
    {key="maxTransferChunk",label="Items per transfer",type="number",default=64,min=1,max=4096,integer=true},
    {key="maxCraftBatch",label="Items per craft",type="number",default=64,min=1,max=65536,integer=true},
    {key="maxConcurrentCrafts",label="Concurrent crafts",type="number",default=4,min=1,max=64,integer=true},
    {key="maxCraftsPerTurn",label="New crafts per turn",type="number",default=1,min=1,max=64,integer=true},
    {key="maxImportsPerTurn",label="Delivery imports per turn",type="number",default=256,min=1,max=65536,integer=true,roles={supply=true}},
    {key="maxReturnItemsPerTurn",label="Overflow items per turn",type="number",default=128,min=1,max=65536,integer=true},
    {key="chestReserveSlots",label="Reserved empty chest slots",type="number",default=1,min=0,max=256,integer=true},
    {key="defaultItemKeep",label="Default warehouse keep count",type="number",default=128,min=0,max=1048576,integer=true,roles={supply=true}},
    {key="buildingItemKeep",label="Building item keep count",type="number",default=1024,min=0,max=1048576,integer=true,roles={supply=true}},
    {key="maxHistoryEntries",label="History entries",type="number",default=400,min=10,max=10000,integer=true},
    {key="maxErrorEntries",label="Error entries",type="number",default=100,min=10,max=10000,integer=true},
    {key="requestRetentionSeconds",label="Completed request retention (s)",type="number",default=86400,min=60,max=31536000},
    {key="maxCompletedRequests",label="Retained completed requests",type="number",default=1000,min=10,max=10000,integer=true},
    {key="monitorTextScale",label="Monitor text scale (5 x 3 screens)",type="number",default=.5,min=.5,max=.5,hidden=true},
    {key="chestTestItem",label="Chest test item",type="string",default="minecraft:cobblestone"},
    {key="chestTestTimeoutSeconds",label="Chest test response timeout (s)",type="number",default=30,min=1,max=3600},
}
local byKey = {}
local directions={north=true,south=true,east=true,west=true,up=true,down=true,top=true,bottom=true,left=true,right=true,front=true,back=true}
for _, field in ipairs(fields) do byKey[field.key] = field end
local localOnly={automationEnabled=true,usePeripheralTransfer=true,monitorTextScale=true,telemetryIntervalSeconds=true,telemetryStaleSeconds=true,telemetryOfflineSeconds=true,telemetryMaxRequests=true,telemetryHistoryEntries=true,telemetryErrorEntries=true,maxHistoryEntries=true,maxErrorEntries=true,maxCompletedRequests=true,requestRetentionSeconds=true,updateCheckSeconds=true,chestTestTimeoutSeconds=true,masterId=true}
function M.isPolicyKey(key)
    return byKey[key]~=nil and byKey[key].type~="string" and not localOnly[key]
end
local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}; for k,v in pairs(value) do out[k] = copy(v) end; return out
end
local function checked(field, value)
    if type(value) ~= field.type then return false, field.label .. " must be " .. field.type end
    if field.type == "number" then
        if value ~= value or value < field.min or value > field.max then
            return false, field.label .. " must be between " .. field.min .. " and " .. field.max
        end
        if field.integer and value % 1 ~= 0 then return false, field.label .. " must be an integer" end
    elseif field.type == "string" and (#value > 128 or value:find("[%c]")) then
        return false, field.label .. " is too long or contains control characters"
    end
    return true
end
local function validRoutes(routes,primaryMonitor)
    if type(routes) ~= "table" then return false, "Colonies must be a list" end
    local ids, chests, channels, monitors = {}, {}, {}, {}
    for k, route in pairs(routes) do
        if type(k) ~= "number" or k < 1 or k % 1 ~= 0 or k > #routes then return false, "Colonies must be a dense list" end
        if type(route) ~= "table" or type(route.id) ~= "number" or route.id < 0 or route.id % 1 ~= 0 then
            return false, "Each colony needs a nonnegative computer ID"
        end
        if ids[route.id] then return false, "Duplicate colony ID " .. route.id end
        ids[route.id] = true
        if route.label~=nil and (type(route.label)~="string" or #route.label>128 or route.label:find("[%c]")) then return false,"Invalid colony label" end
        if route.monitorName~=nil then
            local name=route.monitorName
            if type(name)~="string" or #name>128 or name:find("[%c]") then return false,"Invalid colony dashboard monitor" end
            if name~="" then
                if name==primaryMonitor then return false,"Colony dashboard monitor must differ from the master overview monitor" end
                if monitors[name] then return false,"Duplicate colony dashboard monitor "..name end
                monitors[name]=true
            end
        end
        for _,key in ipairs({"outputDirection","returnDirection"}) do
            if route[key]~=nil and route[key]~="" and not directions[route[key]] then return false,"Invalid transfer direction "..tostring(route[key]) end
        end
        for _, key in ipairs({"deliveryChest","returnChest","deliveryChannel","returnChannel"}) do
            local value = route[key]
            if type(value) ~= "string" or value == "" or #value > 128 or value:find("[%c]") then
                return false, "Colony " .. route.id .. " needs " .. key
            end
            local seen = key:find("Channel") and channels or chests
            local identity = value:lower()
            if seen[identity] then return false, "Chest names and color channels must be exclusive: " .. value end
            seen[identity] = true
        end
        if route.overrides ~= nil then
            if type(route.overrides) ~= "table" then return false, "Colony overrides must be a table" end
            for key,value in pairs(route.overrides) do
                local field = byKey[key]
                if not M.isPolicyKey(key) then return false, "Invalid policy override " .. tostring(key) end
                local ok,err = checked(field,value); if not ok then return false,err end
            end
        end
    end
    return true
end
function M.fields(role)
    local out = {}; for _,field in ipairs(fields) do
        if not field.hidden and (not field.roles or field.roles[role]) then out[#out+1] = copy(field) end
    end; return out
end
function M.defaults(role)
    local config = {schema=4,role=role or "supply",colonies={},keepCounts={},equipmentAllowedNamespaces={minecraft=true,minecolonies=true}}
    for _,field in ipairs(fields) do config[field.key] = field.default end
    return config
end
function M.validate(config)
    if type(config) ~= "table" or config.schema ~= 4 then return false,"Configuration schema must be 4" end
    if config.role ~= "master" and config.role ~= "supply" then return false,"Role must be master or supply" end
    for _,field in ipairs(fields) do local ok,err=checked(field,config[field.key]); if not ok then return false,err end end
    if config.monitorTextScale*2%1~=0 then return false,"Monitor text scale must use increments of 0.5" end
    for _,key in ipairs({"colonyImportDirection","colonyExportDirection"}) do if not directions[config[key]] then return false,"Invalid "..key end end
    local ok,err=validRoutes(config.colonies,config.monitorName); if not ok then return false,err end
    if type(config.keepCounts) ~= "table" then return false,"Keep counts must be a table" end
    for name,value in pairs(config.keepCounts) do
        if type(name) ~= "string" or type(value) ~= "number" or value < 0 or value%1~=0 then return false,"Invalid per-item keep count" end
    end
    if config.role=="supply" then
        if config.deliveryChestName ~= "" and config.deliveryChestName == config.returnChestName then return false,"Delivery and return inventories must differ" end
        if config.deliveryChannel ~= "" and config.deliveryChannel:lower()==config.returnChannel:lower() then return false,"Delivery and return color channels must differ" end
    end
    return true
end
function M.load(role)
    local config = M.defaults(role)
    if not fs.exists(M.PATH) and fs.exists(M.PATH..".bak") then fs.move(M.PATH..".bak",M.PATH) end
    if fs.exists(M.PATH) then
        local h=assert(fs.open(M.PATH,"r"),"Cannot read network configuration")
        local saved=textutils.unserialize(h.readAll()); h.close()
        if type(saved)~="table" or saved.schema~=4 then error("Invalid network configuration; run installer clean installation",0) end
        for key,value in pairs(saved) do config[key]=value end
        -- v4.1 standardises all supply displays without touching transfer state.
        config.monitorTextScale=M.DISPLAY.textScale
        if config.role~=role then error("Installed role differs from saved network role",0) end
    end
    local ok,err=M.validate(config); if not ok then error(err,0) end
    return config
end
function M.save(config)
    local ok,err=M.validate(config); if not ok then error(err,0) end
    if not fs.exists("/colony") then fs.makeDir("/colony") end
    -- Keep a recoverable backup until the new file has been read back.
    local temp=M.PATH..".tmp"; local backup=M.PATH..".bak"
    if fs.exists(temp) then fs.delete(temp) end
    local text=textutils.serialize(config)
    local h=assert(fs.open(temp,"w"),"Cannot write network configuration"); h.write(text); h.close()
    local check=assert(fs.open(temp,"r")); local written=check.readAll(); check.close()
    if written~=text then error("Configuration verification failed",0) end
    if fs.exists(backup) then fs.delete(backup) end
    if fs.exists(M.PATH) then fs.move(M.PATH,backup) end
    local moved,moveErr=pcall(fs.move,temp,M.PATH)
    if not moved then if fs.exists(backup) then fs.move(backup,M.PATH) end; error(moveErr,0) end
    if fs.exists(backup) then fs.delete(backup) end
    return true
end
function M.set(config,key,value)
    if key~="colonies" and key~="keepCounts" and not byKey[key] then return false,"Unknown setting "..tostring(key) end
    local changed=copy(config); changed[key]=copy(value)
    local ok,err=M.validate(changed); if not ok then return false,err end
    config[key]=copy(value); return true
end
function M.setColony(config,route)
    local routes=copy(config.colonies); local replaced=false
    for i,v in ipairs(routes) do if v.id==route.id then routes[i]=copy(route); replaced=true end end
    if not replaced then routes[#routes+1]=copy(route) end
    return M.set(config,"colonies",routes)
end
function M.removeColony(config,id)
    local routes={}; for _,v in ipairs(config.colonies) do if v.id~=id then routes[#routes+1]=copy(v) end end
    return M.set(config,"colonies",routes)
end
function M.policy(config,route)
    local out={}
    for _,field in ipairs(fields) do
        local key=field.key
        if M.isPolicyKey(key) and (not field.roles or field.roles.master) then out[key]=config[key] end
    end
    for key,value in pairs(route and route.overrides or {}) do out[key]=value end
    return out
end
return M
