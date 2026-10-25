-- Hardware boundary. Only the master is allowed to discover or call PRS.
local Protocol=require("colony.network.protocol")
local Config=require("colony.network.config")
local M={}
local function integer(value) return math.max(0,math.floor(tonumber(value) or 0)) end
local function whole(value,minimum)
    return type(value)=="number" and value==value and value~=math.huge and value~=-math.huge
        and value%1==0 and value>=(minimum or 0)
end
local function copy(value,seen)
    if type(value)~="table" then return value end
    seen=seen or {}; if seen[value] then return seen[value] end
    local out={};seen[value]=out
    for key,child in pairs(value) do out[copy(key,seen)]=copy(child,seen) end
    return out
end
local function call(device,method,...)
    if not device or type(device[method])~="function" then return nil,"Missing peripheral method "..method end
    local ok,value,detail=pcall(device[method],...)
    if not ok then return nil,tostring(value) end
    return value,detail
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
    function self.monitor(nameOverride)
        local mon,name=resolve(nameOverride or config.monitorName,"monitor")
        if not mon then return nil,nil end
        if mon.setTextScale then pcall(mon.setTextScale,Config.DISPLAY.textScale) end
        return mon,name
    end
    function self.monitors()
        local out={}
        for _,name in ipairs(peripheral.getNames()) do
            if peripheral.hasType(name,"monitor") then
                local mon=peripheral.wrap(name)
                if mon and mon.setTextScale then pcall(mon.setTextScale,Config.DISPLAY.textScale) end
                local width,height
                if mon and type(mon.getSize)=="function" then
                    local ok,w,h=pcall(mon.getSize); if ok then width,height=w,h end
                end
                local color=call(mon,"isColor")
                local assigned=name==config.monitorName and "overview" or "unassigned"
                for _,route in ipairs(config.colonies or {}) do
                    if name==route.monitorName then assigned="colony "..tostring(route.id).." ("..tostring(route.label or route.id)..")" end
                end
                out[#out+1]={name=name,width=width,height=height,color=color==true,assigned=assigned,
                    sizeOK=width==Config.DISPLAY.columns and height==Config.DISPLAY.rows}
            end
        end
        table.sort(out,function(a,b) return a.name<b.name end)
        return out
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
                if type(detail)~="table" or detail.name~=item.name or detail.count~=item.count
                    or matcher.canonicalNBT(detail.nbt)~=matcher.canonicalNBT(item.nbt) then
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
    -- AP exposes full NBT tables; CC exposes a different, opaque NBT hash.
    -- Capture physical identities before the exact AP export instead of
    -- trying to translate one representation into the other.
    local function physicalItem(entry)
        local nbt=entry.nbt
        if matcher.canonicalNBT(nbt)=="" then nbt=nil end
        return {name=entry.name,nbt=copy(nbt)}
    end
    local function normalizedBaseline(baseline)
        if type(baseline)~="table" or baseline.version~=1 or type(baseline.totals)~="table" then
            return nil,"The original physical inventory baseline is unavailable"
        end
        local normalized={version=1,totals={}}
        for key,total in pairs(baseline.totals) do
            if type(key)~="string" or type(total)~="table" or type(total.item)~="table"
                or type(total.item.name)~="string" or total.item.name=="" or not whole(total.count,1)
                or (total.item.nbt~=nil and type(total.item.nbt)~="string" and type(total.item.nbt)~="table")
                or not matcher.itemIdentityKeyMatches(total.item,key) then
                return nil,"Invalid original physical inventory baseline"
            end
            local identity=matcher.itemIdentity(total.item)
            local merged=normalized.totals[identity] or {item=physicalItem(total.item),count=0}
            merged.count=merged.count+total.count
            if not whole(merged.count,1) then return nil,"Invalid physical inventory total" end
            normalized.totals[identity]=merged
        end
        return normalized
    end
    function self.exportBaseline(items)
        if type(items)~="table" then return nil,"Physical inventory is unavailable" end
        local baseline={version=1,totals={}}
        for slot,entry in pairs(items) do
            if not whole(slot,1) or type(entry)~="table" or type(entry.name)~="string" or entry.name==""
                or not whole(entry.count,1)
                or (entry.nbt~=nil and type(entry.nbt)~="string" and type(entry.nbt)~="table") then
                return nil,"Invalid physical inventory identity or quantity"
            end
            local key=matcher.itemIdentity(entry)
            local total=baseline.totals[key] or {item=physicalItem(entry),count=0}
            total.count=total.count+entry.count
            if not whole(total.count,1) then return nil,"Invalid physical inventory total" end
            baseline.totals[key]=total
        end
        return baseline
    end
    function self.sameExportBaseline(before,after)
        local original,err=normalizedBaseline(before);if not original then return false,err end
        local current,currentErr=normalizedBaseline(after);if not current then return false,currentErr end
        for key,total in pairs(original.totals) do
            if not current.totals[key] or current.totals[key].count~=total.count then return false end
        end
        for key in pairs(current.totals) do if not original.totals[key] then return false end end
        return true
    end
    function self.exportEvidence(baseline,items,source,reported,selectionMode)
        if not whole(reported,1) then return nil,"A known positive bridge result is required to bind physical item data" end
        if type(source)~="table" or type(source.name)~="string" or source.name=="" then return nil,"Export item identity is unavailable" end
        local original,baselineError=normalizedBaseline(baseline)
        if not original then return nil,baselineError end
        baseline=original
        local current,err=self.exportBaseline(items);if not current then return nil,err end
        local gained
        for key,total in pairs(baseline.totals) do
            local now=current.totals[key]
            if (now and now.count or 0)<total.count then return nil,"Another physical inventory quantity decreased during export" end
        end
        for key,total in pairs(current.totals) do
            local before=baseline.totals[key]
            local delta=total.count-(before and before.count or 0)
            if delta>0 then
                if gained or total.item.name~=source.name or delta~=reported then
                    return nil,"Physical inventory changes do not identify one exact exported variant"
                end
                gained=copy(total.item)
            end
        end
        if not gained then return nil,"No physical item increase agrees with the bridge result" end
        if selectionMode=="plain-name" and matcher.canonicalNBT(gained.nbt)~="" then
            return nil,"Plain-item export produced tagged physical inventory; transfer remains held"
        end
        return gained,reported
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
    function self.bridgeStatus()
        local rs,name=bridge(config.role)
        if not rs then return {connected=false,error=name} end
        if type(rs.isConnected)~="function" then
            return {name=name,error="Bridge lacks isConnected; RS connection unknown"}
        end
        local connected,err=call(rs,"isConnected")
        if type(connected)~="boolean" then
            return {name=name,error=err or "Invalid RS Bridge connection status; connection unknown"}
        end
        return {name=name,connected=connected,error=err or (not connected and "NOT_CONNECTED" or nil)}
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
        return value,err
    end
    local function transferPath(role,export,chest,route)
        local inventory,inventoryErr=self.inventory(chest); if not inventory then return nil,inventoryErr end
        local method=export and "exportItemToPeripheral" or "importItemFromPeripheral"
        local destination=chest
        if config.usePeripheralTransfer==false then
            method=export and "exportItem" or "importItem"
            if role=="master" then
                if export then destination=route and route.outputDirection
                else destination=route and route.returnDirection end
            elseif export then destination=config.colonyExportDirection
            else destination=config.colonyImportDirection end
            if type(destination)~="string" or destination=="" then return nil,"Directional transfer path is not configured" end
        end
        return method,destination
    end
    local function move(role,export,filter,count,chest,route)
        local rs,err=bridge(role); if not rs then return nil,err end
        local method,destination=transferPath(role,export,chest,route)
        if not method then return nil,destination end
        filter.count=integer(count)
        if filter.count<1 then return 0 end
        local value,transferErr=call(rs,method,filter,destination)
        return settled(value,transferErr)
    end
    -- Explicit operator inspection only. AP validates its target handler
    -- before a count-zero name filter performs no item extraction/insertion.
    function self.inspectExportTarget(chest,route,itemName)
        if config.role~="master" then return nil,"Only the master may inspect PRS export targets" end
        if type(itemName)~="string" or itemName=="" or #itemName>256 or itemName:find("%c") then
            return nil,"Export target inspection requires the held item name"
        end
        if type(route)=="table" and route.deliveryChest~=nil and route.deliveryChest~=chest then
            return nil,"Held export chest does not match its configured colony route"
        end
        local rs,bridgeName=bridge("master"); if not rs then return nil,bridgeName end
        local method,destination=transferPath("master",true,chest,route)
        if not method then return nil,destination end
        local report={bridge=bridgeName,method=method,destination=destination,accepted=false}
        local connected,connectionError=call(rs,"isConnected")
        if type(connected)=="boolean" then
            report.connected=connected
            report.connectionError=connectionError or (not connected and "NOT_CONNECTED" or nil)
        else
            report.connectionError=connectionError or "Invalid RS Bridge connection status; connection unknown"
        end
        local value,err=call(rs,method,{name=itemName,count=0},destination)
        if value==0 then
            report.value=0;report.error=err;report.accepted=err==nil
        else
            report.error=err or (value==nil and "Export target result unknown" or "Invalid zero-count export target result: "..tostring(value))
        end
        return report
    end
    local function importFilter(item,chest,importing)
        if type(item.name)~="string" or item.name=="" then return nil,"Import has no item name" end
        local nbt=matcher.canonicalNBT(item.nbt)
        local transientNameImport=item.transientNameImport==true
        if item.transientNameImport~=nil and not transientNameImport then
            return nil,"Invalid transient-name import marker"
        end
        if transientNameImport and (type(matcher.isTransientTransportName)~="function"
            or not matcher.isTransientTransportName(item.name) or item.fingerprint~=nil) then
            return nil,"Transient-name import is only valid for a supported unbound transport variant"
        end
        -- AP fingerprints describe the stack, not its RS network. AP tests
        -- this signature on the source chest stack before extracting it.
        local filter={name=item.name}
        if item.fingerprint~=nil and not transientNameImport then
            if type(item.fingerprint)~="string" or item.fingerprint=="" or #item.fingerprint>256 then
                return nil,"Invalid exact AP item fingerprint"
            end
            if not importing or nbt~="" then filter={fingerprint=item.fingerprint} end
        end
        if nbt~="" and not filter.fingerprint and not transientNameImport then
            return nil,"Exact NBT transfer needs an AP fingerprint; CC inventory hashes are not AP NBT filters"
        end
        if importing then
            local items,err=self.snapshot(chest);if not items then return nil,err end
            local selected
            for slot,entry in pairs(items) do
                if self.same(entry,item) and whole(slot,1) and whole(entry.count,1)
                    and (not selected or slot<selected) then selected=slot end
            end
            if not selected then return nil,"The exact physical import item is absent from the source chest" end
            -- AP fingerprint matching calls getOrCreateTag even on unrelated
            -- source stacks. Anchor every import to its verified physical
            -- slot, keeping tagged-item scans away from plain deliveries.
            -- Forge inventory indices are zero based; the next import can
            -- select another matching slot after this stack is consumed.
            filter.fromSlot=selected-1
        end
        return filter
    end
    function self.exportSelection(candidate,variant,items)
        local filter,err=matcher.exportFilterForVariant(candidate,variant,1)
        if not filter then return nil,err end

        -- Ancient Tomes are a registry-ID exact transport exception. A freshly
        -- crafted minecolonies:ancienttome has no NBT, while MineColonies may
        -- add raidWillHappen after a player-inventory tick. AP fingerprint
        -- comparison can mutate/cache the fresh empty tag and then return zero.
        -- Use the exact namespaced registry ID instead; this can never select
        -- Quark's distinct Ancient Tome registry entry.
        if type(candidate)=="table" and type(variant)=="table"
            and candidate.name==variant.name
            and type(matcher.isRegistryNBTRelaxed)=="function"
            and matcher.isRegistryNBTRelaxed(candidate.name) then
            return {name=variant.name},"transient-name"
        end

        if type(variant)~="table" or type(variant.fingerprint)~="string" or variant.fingerprint=="" or #variant.fingerprint>256 then
            return nil,"The selected export variant needs an exact AP fingerprint"
        end
        -- AP 0.7.48r fingerprint predicates can mutate the live RS cache tag
        -- for an item. Avoid them entirely for ordinary non-NBT items. The
        -- exact namespaced registry ID is already a safe selector as long as
        -- every visible positive-count stack with that same registry ID is
        -- also plain. Different AP fingerprints caused only by empty-tag cache
        -- state do NOT make these different Minecraft items.
        local plain=type(items)=="table"
            and not candidate.toolClass
            and not candidate.hasNBT
            and candidate.name==variant.name
            and matcher.canonicalNBT(candidate.nbt)==""
            and matcher.canonicalNBT(variant.nbt)==""
        local found=false
        if plain then
            for _,entry in pairs(items) do
                if type(entry)~="table"
                    or type(entry.name)~="string"
                    or not whole(entry.amount,0) then
                    plain=false
                    break
                end
                if entry.name==variant.name and entry.amount>0 then
                    if matcher.canonicalNBT(entry.nbt)~="" then
                        plain=false
                        break
                    end
                    found=true
                end
            end
        end
        if plain and found then
            return {name=variant.name},"registry-name"
        end

        -- AP 0.7.48r computes fingerprints by calling getOrCreateTag() on the
        -- live RS cache stack. A freshly crafted untagged clock/compass or
        -- Ancient Tome can
        -- therefore become an empty-tag cache entry just before COMPARE_NBT,
        -- making a valid export return zero. A name selector avoids that bug,
        -- but only when the complete same-name stock is proven to contain no
        -- variant except untagged items and the exact harmless transport
        -- metadata recognized by the matcher.
        local transient=type(items)=="table" and not candidate.toolClass and not candidate.hasNBT
            and candidate.name==variant.name
            and type(matcher.isTransientTransportName)=="function"
            and matcher.isTransientTransportName(variant.name)
            and (matcher.canonicalNBT(variant.nbt)==""
                or matcher.isTransientComputedVariant(variant))
        found=false
        if transient then
            for _,entry in pairs(items) do
                if type(entry)~="table" or type(entry.name)~="string" or not whole(entry.amount,0) then
                    transient=false;break
                end
                if entry.name==variant.name and entry.amount>0 then
                    if matcher.canonicalNBT(entry.nbt)~="" and not matcher.isTransientComputedVariant(entry) then
                        transient=false;break
                    end
                    found=true
                end
            end
        end
        if transient and found then return {name=variant.name},"transient-name" end
        return {fingerprint=variant.fingerprint},"fingerprint"
    end
    function self.exportPRS(candidate,variant,count,chest,route,items)
        local filter,err=self.exportSelection(candidate,variant,items)
        if not filter then return nil,err end
        return move("master",true,filter,count,chest,route)
    end
    function self.importPRS(item,count,chest,route)
        local filter,err=importFilter(item,chest,true); if not filter then return nil,err end
        return move("master",false,filter,count,chest,route)
    end
    function self.importColony(item,count,chest)
        local filter,err=importFilter(item,chest,true); if not filter then return nil,err end
        return move("supply",false,filter,count,chest)
    end
    function self.exportColony(item,count,chest)
        local filter,err=importFilter(item,chest,false); if not filter then return nil,err end
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
        local rs,err=bridge(config.role); out.checks.bridge={ok=rs~=nil,detail=rs and "Bridge peripheral visible; use diag to check RS connection" or err}
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