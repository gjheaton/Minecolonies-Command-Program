-- Hardware boundary. Only the master is allowed to discover or call PRS.
local Protocol=require("colony.network.protocol")
local M={}
local function integer(value) return math.max(0,math.floor(tonumber(value) or 0)) end
local function call(device,method,...)
    if not device or type(device[method])~="function" then return nil,"Missing peripheral method "..method end
    local ok,value=pcall(device[method],...)
    if not ok then return nil,tostring(value) end
    return value
end
local function resolve(name,wanted)
    if name and name~="" then
        if not peripheral.isPresent(name) then return nil,"Peripheral missing: "..name end
        if wanted and not peripheral.hasType(name,wanted) then return nil,name.." is not "..wanted end
        return peripheral.wrap(name),name
    end
    local found={}
    for _,id in ipairs(peripheral.getNames()) do if peripheral.hasType(id,wanted) then found[#found+1]=id end end
    if #found~=1 then return nil,"Configure one "..wanted.." peripheral; found "..#found end
    return peripheral.wrap(found[1]),found[1]
end
function M.new(config,store,matcher)
    local self={}
    local stackLimits={}
    function self.now() return os.epoch and os.epoch("utc")/1000 or os.clock() end
    function self.wait(seconds) sleep(seconds) end
    self.send=Protocol.send
    function self.monitor()
        local mon,name=resolve(config.monitorName,"monitor")
        if not mon then return nil,nil end
        if mon.setTextScale then pcall(mon.setTextScale,config.monitorTextScale) end
        return mon,name
    end
    function self.inventory(name)
        if type(name)~="string" or name=="" then return nil,"Inventory peripheral name is not configured" end
        if not peripheral.isPresent(name) then return nil,"Inventory missing: "..name end
        local chest=peripheral.wrap(name)
        if not chest or type(chest.list)~="function" or type(chest.size)~="function" then
            return nil,name.." does not expose the CC:Tweaked inventory API"
        end
        return chest
    end
    function self.describe(name)
        local chest,err=self.inventory(name); if not chest then return nil,err end
        local size,sizeErr=call(chest,"size"); if type(size)~="number" then return nil,sizeErr or "Invalid inventory size" end
        local contents,listErr=self.snapshot(name); if not contents then return nil,listErr end
        return {name=name,size=size,contents=contents,pushItems=type(chest.pushItems)=="function",pullItems=type(chest.pullItems)=="function"}
    end
    function self.snapshot(name)
        local chest,err=self.inventory(name); if not chest then return nil,err end
        local items,listErr=call(chest,"list"); if type(items)~="table" then return nil,listErr or "Inventory list failed" end
        local out={}
        for slot,item in pairs(items) do
            if type(slot)~="number" or type(item)~="table" or type(item.name)~="string" or type(item.count)~="number" then
                return nil,"Malformed inventory slot data"
            end
            local entry={}; for key,value in pairs(item) do entry[key]=value end
            -- Detailed fields allow equipment matching and accurate stack limits.
            if type(chest.getItemDetail)=="function" then
                local detail,detailErr=call(chest,"getItemDetail",slot)
                if type(detail)~="table" or detail.name~=item.name or detail.count~=item.count then
                    return nil,detailErr or "Inventory changed during snapshot; retry before moving items"
                end
                for key,value in pairs(detail) do entry[key]=value end
            end
            out[slot]=entry
            local maximum=entry.maxCount or entry.maxStackSize
            if type(maximum)=="number" and maximum>=1 then
                stackLimits[matcher.itemIdentity(entry)]=integer(maximum)
            end
        end
        return out
    end
    function self.same(a,b)
        return type(a)=="table" and type(b)=="table" and a.name==b.name
            and matcher.canonicalNBT(a.nbt)==matcher.canonicalNBT(b.nbt)
    end
    function self.count(items,item)
        local total=0
        for _,entry in pairs(items or {}) do if self.same(entry,item) then total=total+integer(entry.count or entry.amount) end end
        return total
    end
    function self.capacity(name,items,item,reserveSlots)
        local chest,err=self.inventory(name); if not chest then return nil,err end
        local size,sizeErr=call(chest,"size"); if type(size)~="number" then return nil,sizeErr or "Inventory size unavailable" end
        local free,partial,empty=0,0,0
        -- Until a physical detail/source API proves a stack limit, use one
        -- item per empty slot. Assuming 64 would fill reserved slots for
        -- pearls, buckets and other items whose actual stack limit is lower.
        local stack=integer(item.maxCount or item.maxStackSize or (item.toolClass and 1)
            or stackLimits[matcher.itemIdentity(item)] or 1)
        if stack<1 then stack=1 end
        for slot=1,size do
            local limit=stack
            if type(chest.getItemLimit)=="function" then
                local value,limitErr=call(chest,"getItemLimit",slot)
                if type(value)~="number" then return nil,limitErr or "Inventory slot limit unavailable" end
                limit=math.min(limit,integer(value))
            end
            local current=items[slot]
            if not current then empty=empty+1; free=free+limit
            elseif self.same(current,item) then partial=partial+math.max(0,math.min(limit,integer(current.maxCount or stack))-integer(current.count)) end
        end
        -- Reserve empty slots conservatively even when their slot limits differ.
        return math.max(0,free-math.min(empty,integer(reserveSlots))*stack)+partial
    end
    local function bridge(role)
        if role=="master" and config.role~="master" then return nil,"Colony clients cannot access PRS" end
        return resolve(role=="master" and config.playerBridgeName or config.colonyBridgeName,"rsBridge")
    end
    local function stock(role)
        local rs,err=bridge(role); if not rs then return nil,err end
        local items,listErr=call(rs,"listItems")
        if type(items)~="table" then return nil,listErr or "RS inventory unavailable" end
        for _,item in pairs(items) do
            if type(item)~="table" or type(item.name)~="string" or type(item.amount)~="number" then return nil,"Malformed RS inventory" end
        end
        return items
    end
    function self.stock() return stock("master") end
    function self.colonyStock() return stock("supply") end
    function self.requests()
        local colony,err=resolve(config.colonyIntegratorName,"colonyIntegrator"); if not colony then return nil,err end
        if type(colony.isInColony)=="function" then
            local inside,insideErr=call(colony,"isInColony")
            if inside~=true then return nil,insideErr or "Colony Integrator is outside a colony" end
        end
        local requests,requestErr=call(colony,"getRequests")
        if type(requests)~="table" then return nil,requestErr or "MineColonies requests unavailable" end
        return requests
    end
    function self.colonyName()
        local colony,err=resolve(config.colonyIntegratorName,"colonyIntegrator"); if not colony then return nil,err end
        return call(colony,"getColonyName")
    end
    local function settled(value,err)
        if config.transferSettleSeconds>0 then sleep(config.transferSettleSeconds) end
        if value==nil then return nil,err or "Transfer result unknown" end
        if type(value)~="number" or value<0 or value%1~=0 then return nil,"Invalid transfer result" end
        return value
    end
    local function move(role,export,filter,count,chest,route)
        local rs,err=bridge(role); if not rs then return nil,err end
        local inventory,inventoryErr=self.inventory(chest); if not inventory then return nil,inventoryErr end
        local method=export and "exportItemToPeripheral" or "importItemFromPeripheral"
        local destination=chest
        if config.usePeripheralTransfer==false then
            method=export and "exportItem" or "importItem"
            destination=role=="master" and (export and route and route.outputDirection or route and route.returnDirection)
                or (export and config.colonyExportDirection or config.colonyImportDirection)
            if type(destination)~="string" or destination=="" then return nil,"Directional transfer path is not configured" end
        end
        filter.count=integer(count)
        if filter.count<1 then return 0 end
        local value,transferErr=call(rs,method,filter,destination)
        return settled(value,transferErr)
    end
    local function importFilter(item,allowFingerprint)
        if type(item.name)~="string" or item.name=="" then return nil,"Import has no item name" end
        -- RS fingerprints belong to the source network. An item received from
        -- PRS must be imported into CRS by its physical name/NBT identity.
        if allowFingerprint and type(item.fingerprint)=="string" and item.fingerprint~="" then return {fingerprint=item.fingerprint} end
        local filter={name=item.name}
        local nbt=matcher.canonicalNBT(item.nbt)
        if nbt~="" then
            if type(item.nbt)=="string" then filter.nbt=item.nbt
            elseif type(item.nbt)=="table" then
                local ok,encoded=pcall(textutils.serializeJSON,item.nbt)
                if not ok then return nil,"Cannot represent exact import NBT" end
                filter.nbt=encoded
            else return nil,"Cannot represent exact import NBT" end
        end
        return filter
    end
    function self.exportPRS(candidate,variant,count,chest,route)
        local filter,err=matcher.exportFilterForVariant(candidate,variant,count)
        if not filter then return nil,err end
        return move("master",true,filter,count,chest,route)
    end
    function self.importPRS(item,count,chest,route)
        local filter,err=importFilter(item); if not filter then return nil,err end
        return move("master",false,filter,count,chest,route)
    end
    function self.importColony(item,count,chest)
        local filter,err=importFilter(item); if not filter then return nil,err end
        return move("supply",false,filter,count,chest)
    end
    function self.exportColony(item,count,chest)
        local filter,err=importFilter(item,true); if not filter then return nil,err end
        return move("supply",true,filter,count,chest)
    end
    function self.craftable(candidate)
        local rs,err=bridge("master"); if not rs then return nil,err end
        local lastError,readable
        local possible,detail=matcher.craftable(rs,candidate,function(device,method,...)
            local value,callErr=call(device,method,...)
            if value==nil and callErr then lastError=callErr end
            if value~=nil then readable=true end
            return value~=nil,value
        end)
        if not possible and not readable and lastError then return nil,lastError end
        return possible,lastError or detail
    end
    function self.craft(candidate,count)
        local rs,err=bridge("master"); if not rs then return nil,err end
        return call(rs,"craftItem",matcher.craftFilter(candidate,count))
    end
    function self.moveInventory(source,destination,slot,count)
        local chest,err=self.inventory(source); if not chest then return nil,err end
        local target,targetErr=self.inventory(destination); if not target then return nil,targetErr end
        local moved,moveErr=call(chest,"pushItems",destination,slot,integer(count))
        return settled(moved,moveErr)
    end
    function self.health()
        local out={checks={}}
        local modem=false
        for _,name in ipairs(peripheral.getNames()) do if peripheral.hasType(name,"modem") and rednet.isOpen(name) then modem=true end end
        out.checks.modem={ok=modem,detail=modem and "Rednet modem open" or "Attach/open a wired or wireless modem"}
        local rs,err=bridge(config.role); out.checks.bridge={ok=rs~=nil,detail=rs and "Bridge connected" or err}
        if rs then
            local needed=config.usePeripheralTransfer and {"listItems","importItemFromPeripheral","exportItemToPeripheral"} or {"listItems","importItem","exportItem"}
            for _,method in ipairs(needed) do if type(rs[method])~="function" then out.checks.bridge={ok=false,detail="Bridge lacks "..method} end end
        end
        if config.role=="supply" then
            local colony,colonyErr=resolve(config.colonyIntegratorName,"colonyIntegrator")
            out.checks.colony={ok=colony~=nil,detail=colony and "Integrator connected" or colonyErr}
            for _,key in ipairs({"deliveryChestName","returnChestName"}) do
                local chest,chestErr=self.describe(config[key]); out.checks[key]={ok=chest~=nil,detail=chest and (chest.name.." ("..chest.size.." slots)") or chestErr}
            end
            out.checks.master={ok=config.masterId>=0,detail="Master ID "..config.masterId}
        else
            out.checks.routes={ok=#config.colonies>0,detail=tostring(#config.colonies).." colony routes"}
            for _,route in ipairs(config.colonies) do for _,key in ipairs({"deliveryChest","returnChest"}) do
                local chest,chestErr=self.describe(route[key]); out.checks[tostring(route.id).." "..key]={ok=chest~=nil,detail=chest and chest.name or chestErr}
            end end
        end
        return out
    end
    return self
end
return M
