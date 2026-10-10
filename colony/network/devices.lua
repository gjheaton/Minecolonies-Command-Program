-- Discover compatible peripherals without reading storage or invoking hardware.
-- The setup wizard and live configuration picker share assignment rules.
local M={}
local globalFields={
    playerBridgeName={kind="rsBridge",allowNone=true,noneLabel="Automatic bridge discovery"},
    colonyBridgeName={kind="rsBridge",allowNone=true,noneLabel="Automatic bridge discovery"},
    colonyIntegratorName={kind="colonyIntegrator",allowNone=true,noneLabel="Automatic integrator discovery"},
    monitorName={kind="monitor",allowNone=true,noneLabel="Automatic / computer screen"},
    deliveryChestName={kind="inventory"},returnChestName={kind="inventory"},
}
local routeFields={
    monitorName={kind="monitor",allowNone=true,noneLabel="No extra colony dashboard"},
    deliveryChest={kind="inventory"},returnChest={kind="inventory"},
}
function M.spec(key,isRoute)
    local source=(isRoute and routeFields or globalFields)[key]
    if not source then return nil end
    local out={};for k,v in pairs(source) do out[k]=v end;return out
end
local function reserve(assigned,value)
    if type(value)=="string" and value~="" then assigned[value:lower()]=true end
end
local function reserved(config,key,options)
    local assigned={}
    local editingRoute=type(options.route)=="table"
    for field in pairs(globalFields) do
        if editingRoute or field~=key then reserve(assigned,config[field]) end
    end
    for _,route in ipairs(config.colonies or {}) do
        if not (editingRoute and options.routeId~=nil and route.id==options.routeId) then
            for field in pairs(routeFields) do reserve(assigned,route[field]) end
        end
    end
    if editingRoute then
        for field in pairs(routeFields) do if field~=key then reserve(assigned,options.route[field]) end end
    end
    return assigned
end
local function compatible(name,kind)
    if kind=="inventory" then
        local device=peripheral.wrap(name)
        return device and type(device.list)=="function" and type(device.size)=="function"
    end
    return peripheral.hasType(name,kind)
end
function M.choices(config,key,options)
    options=options or {}
    local spec=M.spec(key,type(options.route)=="table")
    if not spec then return {} end
    local assigned=reserved(config,key,options)
    local current
    if type(options.route)=="table" then current=options.route[key] else current=config[key] end
    local ok,found=pcall(peripheral.getNames)
    if not ok or type(found)~="table" then return {} end
    local names={}
    for _,name in ipairs(found) do
        if type(name)=="string" and #name<=128 and not name:find("[%c]") then names[#names+1]=name end
    end
    table.sort(names)
    local out={}
    for _,name in ipairs(names) do
        if not assigned[name:lower()] then
            local matched,valid=pcall(compatible,name,spec.kind)
            if matched and valid then
                local types={pcall(peripheral.getType,name)}
                local detail={}
                if types[1] then for i=2,#types do if type(types[i])=="string" then detail[#detail+1]=types[i] end end end
                out[#out+1]={label=name,value=name,detail=table.concat(detail," / "),current=name==current}
            end
        end
    end
    return out
end
function M.available(config,key,value,options)
    local spec=M.spec(key,options and type(options.route)=="table")
    if not spec then return false,"This setting does not select a peripheral." end
    if value=="" and spec.allowNone then return true end
    for _,choice in ipairs(M.choices(config,key,options)) do if choice.value==value then return true end end
    return false,"Device is disconnected or assigned elsewhere. Choose an available peripheral."
end
return M
