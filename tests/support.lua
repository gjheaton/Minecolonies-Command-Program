-- Deterministic CC:Tweaked hardware model. Production engines, matcher, IO,
-- protocol, and journal run unchanged. Only the Minecraft boundary is modeled.
local S = {}
function S.copy(value)
    if type(value) ~= "table" then return value end
    local out = {}; for key, child in pairs(value) do out[S.copy(key)] = S.copy(child) end
    return out
end
local function encoded(value,options)
    -- Match CC:Tweaked textutils.serialize's tracking semantics. The official
    -- mc-1.20.x textutils.lua serialize_impl keeps completed tables as false
    -- by default, or clears them only when allow_repetitions is enabled.
    -- Both modes reject a table reached while its ancestor is still active.
    assert(options==nil or type(options)=="table","bad serialization options")
    options=options or {}
    for _,key in ipairs({"compact","allow_repetitions"}) do assert(options[key]==nil or type(options[key])=="boolean","bad serialization option "..key) end
    local tracking={}
    local function encode(current,depth)
        depth=depth or 0
        local kind=type(current)
        if kind=="string" then return string.format("%q",current) end
        if kind=="number" then
            if current~=current then return "0/0" end
            if current==math.huge then return "1/0" end
            if current==-math.huge then return "-1/0" end
            return tostring(current)
        end
        if kind=="nil" or kind=="boolean" then return tostring(current) end
        if kind~="table" then error("Cannot serialize type "..kind,0) end
        if tracking[current]~=nil then
            error(tracking[current] and "Cannot serialize table with recursive entries" or "Cannot serialize table with repeated entries",0)
        end
        tracking[current]=true
        local keys={};for key in pairs(current) do keys[#keys+1]=key end
        table.sort(keys,function(a,b) return tostring(a)<tostring(b) end)
        local entries={}
        for _,key in ipairs(keys) do
            local prefix=options.compact and "" or string.rep("  ",depth+1)
            local separator=options.compact and "=" or " = "
            entries[#entries+1]=prefix.."["..encode(key,depth+1).."]"..separator..encode(current[key],depth+1)
        end
        if options.allow_repetitions then tracking[current]=nil else tracking[current]=false end
        if options.compact or #entries==0 then return "{"..table.concat(entries,",").."}" end
        return "{\n"..table.concat(entries,",\n")..",\n"..string.rep("  ",depth).."}"
    end
    return encode(value)
end
local function json(value)
    if type(value)=="string" then return '"'..value:gsub('\\','\\\\'):gsub('"','\\"')..'"' end
    if type(value)~="table" then return tostring(value) end
    local keys={}; for key in pairs(value) do keys[#keys+1]=key end; table.sort(keys,function(a,b) return tostring(a)<tostring(b) end)
    local entries={}; for _,key in ipairs(keys) do entries[#entries+1]=json(tostring(key))..":"..json(value[key]) end
    return "{"..table.concat(entries,",").."}"
end
local Test = {cases={}}
function Test.case(name, fn) Test.cases[#Test.cases+1]={name=name,fn=fn} end
function Test.equal(actual, expected, detail)
    assert(actual==expected,(detail or "unexpected value")..": expected "..tostring(expected)..", got "..tostring(actual))
end
function Test.run()
    local passed, failed=0,0
    for _,case in ipairs(Test.cases) do
        local ok,err=xpcall(case.fn,debug.traceback)
        if ok then passed=passed+1;print("PASS "..case.name)
        else failed=failed+1;print("FAIL "..case.name.."\n"..tostring(err)) end
    end
    return passed,failed
end
_G.Test=Test

function S.world()
    local w={now=100,id=1,computers={},devices={},channels={},files={},dirs={},queue={},sent={},calls={},events={},drop={},masterId=1}
    _G.textutils={serialize=encoded,unserialize=function(source)
        local chunk=load("return "..source,"journal","t",{}); if chunk then local ok,value=pcall(chunk); if ok then return value end end
    end,serializeJSON=json}
    _G.os.epoch=function() return math.floor(w.now*1000) end
    _G.os.getComputerID=function() return w.id end
    _G.sleep=function(seconds) w.advance(seconds) end
    _G.fs={exists=function(path) return w.files[path]~=nil or w.dirs[path]==true end,
        getDir=function(path) return path:match("^(.*)/[^/]+$") or "" end,
        getSize=function(path) assert(w.files[path]~=nil,"missing file");return #w.files[path] end,
        getFreeSpace=function() return math.huge end,
        makeDir=function(path) w.dirs[path]=true end,
        delete=function(path) w.files[path]=nil;w.dirs[path]=nil end,
        move=function(source,target) assert(w.files[source]~=nil,"missing source");assert(w.files[target]==nil,"target exists");w.files[target]=w.files[source];w.files[source]=nil end,
        open=function(path,mode)
            if mode=="r" then if w.files[path]==nil then return nil end;return {readAll=function() return w.files[path] end,close=function() end} end
            if w.writeFail then return nil end
            return {write=function(source) w.files[path]=source end,close=function() end}
        end}
    _G.peripheral={getNames=function()
        local names={};for name in pairs(w.devices[w.id] or {}) do names[#names+1]=name end;table.sort(names);return names
    end,isPresent=function(name) return (w.devices[w.id] or {})[name]~=nil end,
        hasType=function(name,wanted) local device=(w.devices[w.id] or {})[name];return device and device.types[wanted]==true or false end,
        getType=function(name) local device=(w.devices[w.id] or {})[name];return device and device.kind end,
        wrap=function(name) local device=(w.devices[w.id] or {})[name];return device and device.api end}
    _G.rednet={open=function() end,isOpen=function() return true end,send=function(id,message,protocol)
        local packet={from=w.id,to=id,message=S.copy(message),protocol=protocol}
        w.sent[#w.sent+1]=S.copy(packet)
        local kind=message.kind
        if (w.drop[kind] or 0)>0 then w.drop[kind]=w.drop[kind]-1;return true end
        w.queue[#w.queue+1]=packet;return true
    end}
    function rednet.receive(protocol,timeout)
        local receiver=w.id
        for _=1,100 do
            if #w.queue==0 then w.advance(timeout or 1);return nil end
            local packet=w.queue[1]
            if packet.to==receiver and packet.protocol==protocol then table.remove(w.queue,1);return packet.from,S.copy(packet.message),packet.protocol end
            w.deliver()
        end
        error("receive exceeded simulation budget")
    end
    function w.advance(seconds)
        w.now=w.now+seconds
        for i=#w.events,1,-1 do if w.events[i].at<=w.now then local event=table.remove(w.events,i);event.fn() end end
    end
    function w.at(id,fn,...)
        local previous=w.id;w.id=id
        local values={pcall(fn,...)};w.id=previous
        if not values[1] then error(values[2],0) end
        table.remove(values,1);return table.unpack(values)
    end
    function w.device(id,name,kind,api)
        w.devices[id]=w.devices[id] or {};w.devices[id][name]={kind=kind,types={[kind]=true},api=api}
    end
    function w.channel(channel,size)
        w.channels[channel]=w.channels[channel] or {slots={},size=size or 27}
        return w.channels[channel]
    end
    function w.chest(id,name,channel,size)
        local inventory=w.channel(channel,size)
        local api={size=function() return inventory.size end,getItemLimit=function() return 64 end}
        local function visible() return inventory.hiddenUntil and w.now<inventory.hiddenUntil and inventory.oldSlots or inventory.slots end
        function api.list() return S.copy(visible()) end
        function api.getItemDetail(slot) return S.copy(visible()[slot]) end
        function api.pushItems(target,slot,count)
            local destination=w.devices[w.id][target];assert(destination and destination.channel,"inventory destination missing")
            local current=inventory.slots[slot];if not current then return 0 end
            local moved=w.insert(destination.channel,current,math.min(count,current.count));current.count=current.count-moved
            if current.count==0 then inventory.slots[slot]=nil end;return moved
        end
        function api.pullItems(source,slot,count) return w.devices[w.id][source].api.pushItems(name,slot,count) end
        w.device(id,name,"inventory",api);w.devices[id][name].channel=inventory
        return inventory,api
    end
    function w.identity(item) return item.name.."|"..encoded(item.nbt or "") end
    function w.count(inventory,item)
        local n=0;for _,current in pairs(inventory.slots) do if w.identity(current)==w.identity(item) then n=n+current.count end end;return n
    end
    function w.insert(inventory,item,count)
        local left=count;local max=item.maxCount or 64
        for _,current in pairs(inventory.slots) do
            if w.identity(current)==w.identity(item) then local moved=math.min(left,max-current.count);current.count=current.count+moved;left=left-moved end
        end
        for slot=1,inventory.size do if left>0 and not inventory.slots[slot] then
            local moved=math.min(left,max);local entry=S.copy(item);entry.count=moved;entry.amount=nil;entry.fingerprint=nil;inventory.slots[slot]=entry;left=left-moved
        end end
        return count-left
    end
    function w.take(inventory,item,count)
        local left=count
        for slot,current in pairs(inventory.slots) do if w.identity(current)==w.identity(item) then
            local moved=math.min(left,current.count);current.count=current.count-moved;left=left-moved
            if current.count==0 then inventory.slots[slot]=nil end
        end end
        return count-left
    end
    function w.bridge(id,name,isPRS)
        local rs={items={},recipes={},crafts={},exportLimit=math.huge,importLimit=math.huge,craftDelay=2,visibilityDelay=0}
        local function record(method,filter,chest)
            if isPRS then assert(w.id==w.masterId,"PRS touched by a colony computer") end
            w.calls[#w.calls+1]={computer=w.id,prs=isPRS,method=method,filter=S.copy(filter),chest=chest,time=w.now}
        end
        function rs.add(item,count)
            local identity=w.identity(item)
            local current=rs.items[identity] or S.copy(item);current.fingerprint=current.fingerprint or "fp:"..identity
            current.amount=(current.amount or 0)+count;current.count=nil;rs.items[identity]=current;return current
        end
        local function matches(item,filter)
            if filter.fingerprint then return item.fingerprint==filter.fingerprint end
            if filter.name~=item.name then return false end
            if filter.nbt then return filter.nbt==(type(item.nbt)=="table" and json(item.nbt) or item.nbt) end
            return true
        end
        local function inventory(chest) local device=(w.devices[w.id] or {})[chest];assert(device and device.channel,"bridge inventory not connected");return device.channel end
        local function hide(chest)
            if rs.visibilityDelay>0 then chest.oldSlots=S.copy(chest.slots);chest.hiddenUntil=w.now+rs.visibilityDelay end
        end
        local api={}
        function api.listItems() record("listItems");local out={};for _,item in pairs(rs.items) do if item.amount>0 then out[#out+1]=S.copy(item) end end;return out end
        function api.exportItemToPeripheral(filter,name)
            record("export",filter,name);if rs.zeroExport then return 0 end
            local chest=inventory(name);hide(chest)
            local left=math.min(filter.count,rs.exportLimit)
            local moved=0
            for _,item in pairs(rs.items) do if matches(item,filter) and left>0 then
                local q=math.min(left,item.amount);local n=rs.phantomExport and q or w.insert(chest,item,q)
                if not rs.phantomExport then item.amount=item.amount-n end
                left=left-n;moved=moved+n
            end end
            if rs.unknownExport then return nil end
            return moved
        end
        function api.importItemFromPeripheral(filter,name)
            record("import",filter,name);local chest=inventory(name);hide(chest)
            local left=math.min(filter.count,rs.importLimit);local moved=0
            for slot,item in pairs(S.copy(chest.slots)) do if matches(item,filter) and left>0 then
                local q=math.min(left,item.count);local n=rs.phantomImport and q or w.take(chest,item,q)
                if not rs.phantomImport then rs.add(item,n) end
                moved=moved+n;left=left-n
            end end
            return moved
        end
        api.exportItem=api.exportItemToPeripheral;api.importItem=api.importItemFromPeripheral
        function api.isItemCraftable(filter) record("isItemCraftable",filter);return rs.recipes[filter.name]==true end
        function api.getPattern(filter) record("getPattern",filter);return rs.recipes[filter.name] and {name=filter.name} or nil end
        function api.listCraftableItems() record("listCraftableItems");local out={};for item in pairs(rs.recipes) do out[#out+1]={name=item} end;return out end
        function api.craftItem(filter)
            record("craft",filter);if not rs.recipes[filter.name] or rs.rejectCraft then return false end
            rs.crafts[#rs.crafts+1]=S.copy(filter)
            if not rs.neverFinishCraft then w.events[#w.events+1]={at=w.now+rs.craftDelay,fn=function() rs.add({name=filter.name,nbt=filter.nbt},filter.count) end} end
            if rs.unknownCraft then return nil end
            return true
        end
        w.device(id,name,"rsBridge",api);return rs
    end
    function w.integrator(id,name)
        local integrator={requests={},name="Colony "..id}
        w.device(id,name,"colonyIntegrator",{isInColony=function() return true end,
            getRequests=function() if integrator.failed then error("integrator unavailable") end;return S.copy(integrator.requests) end,
            getColonyName=function() return integrator.name end})
        return integrator
    end
    function w.callsFor(method,prs)
        local out={};for _,call in ipairs(w.calls) do if (method==nil or call.method==method) and (prs==nil or call.prs==prs) then out[#out+1]=call end end;return out
    end
    function w.packet(kind,to)
        for i=#w.sent,1,-1 do if w.sent[i].message.kind==kind and (not to or w.sent[i].to==to) then return S.copy(w.sent[i]) end end
    end
    function w.deliver(index)
        local packet=table.remove(w.queue,index or 1);if not packet then return false end
        local computer=w.computers[packet.to]
        if computer and computer.handler then w.at(packet.to,computer.handler,packet.from,S.copy(packet.message))
        elseif computer and computer.engine then w.at(packet.to,computer.engine.onMessage,packet.from,S.copy(packet.message)) end
        return packet
    end
    function w.flush(limit)
        for _=1,limit or 100 do if #w.queue==0 then return end;w.deliver() end
        assert(#w.queue==0,"message loop exceeded simulation budget")
    end
    function w.tick(id) local computer=assert(w.computers[id]);return w.at(id,computer.engine.tick) end
    return w
end

-- Optional writable-mount model for disk tests. ComputerCraft charges at least
-- 500 bytes per file and directory; opening an existing file in "w" refunds
-- its previous size before subsequent writes enforce the remaining quota.
-- See CC:Tweaked WritableFileMount.java createDirectory/openForWrite/write.
function S.quota(w,capacity)
    local q={capacity=capacity,stats={writeOpens=0,writes=0,mkdirs=0,deletes=0}}
    function q.used()
        local used=0
        for _,source in pairs(w.files) do used=used+math.max(500,#source) end
        for path,present in pairs(w.dirs) do if present and path~="" and path~="/" then used=used+500 end end
        return used
    end
    function q.free() return q.capacity-q.used() end
    function q.reset() for key in pairs(q.stats) do q.stats[key]=0 end end
    local originalOpen,originalDelete=fs.open,fs.delete
    fs.getFreeSpace=function() return q.free() end
    fs.makeDir=function(path)
        if path=="" or path=="/" or w.dirs[path] then return end
        local parent=fs.getDir(path);if parent~="" and parent~="/" and not w.dirs[parent] then fs.makeDir(parent) end
        assert(q.free()>=500,"Out of space")
        q.stats.mkdirs=q.stats.mkdirs+1;w.dirs[path]=true
    end
    fs.open=function(path,mode)
        if mode=="r" then return originalOpen(path,mode) end
        assert(mode=="w","quota fixture only supports r/w")
        q.stats.writeOpens=q.stats.writeOpens+1
        if w.writeFail then return nil,"Write failure" end
        local parent=fs.getDir(path)
        if parent~="" and parent~="/" and not w.dirs[parent] then return nil,"No such directory" end
        local previous=w.files[path]
        if previous==nil and q.free()<500 then return nil,"Out of space" end
        w.files[path]=""
        local closed=false
        return {write=function(source)
            assert(not closed,"Closed file")
            local nextSource=w.files[path]..tostring(source)
            local extra=math.max(500,#nextSource)-math.max(500,#w.files[path])
            assert(q.free()>=extra,"Out of space")
            q.stats.writes=q.stats.writes+1;w.files[path]=nextSource
        end,close=function() closed=true end}
    end
    fs.delete=function(path) q.stats.deletes=q.stats.deletes+1;return originalDelete(path) end
    return q
end

function S.request(id,name,count,nbt)
    return {id=id,name=name,count=count,items={{name=name,count=count,nbt=nbt}}}
end
function S.computer(w,id,role)
    local Config=require("colony.network.config")
    local Store=require("colony.network.store")
    local Matcher=require("colony.supply.matcher")
    local IO=require("colony.network.io")
    local config=Config.defaults(role)
    config.playerBridgeName="prs";config.colonyBridgeName="crs";config.colonyIntegratorName="integrator"
    config.masterId=w.masterId;config.deliveryChestName="delivery";config.returnChestName="returns"
    config.deliveryChannel="delivery-"..id;config.returnChannel="returns-"..id
    config.transferSettleSeconds=0;config.transferVerifyTimeoutSeconds=1;config.transferPollSeconds=.1
    config.pollIntervalSeconds=.1;config.helloSeconds=1;config.batchRetrySeconds=1
    config.colonyResponseTimeoutSeconds=3;config.messageTimeoutSeconds=3;config.craftPollSeconds=1
    config.chestReserveSlots=0
    local computer={id=id,config=config};w.computers[id]=computer
    w.device(id,"modem","modem",{})
    w.at(id,function()
        computer.store=Store.new("/journals/"..id,config);computer.store.load()
        computer.matcher=Matcher.new(config,computer.store)
        computer.io=IO.new(config,computer.store,computer.matcher)
    end)
    function computer.start()
        return w.at(id,function()
            local module=require(role=="master" and "colony.network.master" or "colony.network.client")
            computer.engine=module.new(config,computer.store,computer.io,computer.matcher)
            return computer.engine
        end)
    end
    function computer.restart()
        return w.at(id,function()
            computer.store=Store.new("/journals/"..id,config);computer.store.load()
            computer.matcher=Matcher.new(config,computer.store);computer.io=IO.new(config,computer.store,computer.matcher)
            return computer.start()
        end)
    end
    return computer
end

function S.clientFixture()
    local w=S.world();local client=S.computer(w,2,"supply")
    w.chest(2,"delivery","D2");w.chest(2,"returns","R2")
    client.rs=w.bridge(2,"crs",false);client.integrator=w.integrator(2,"integrator")
    client.integrator.requests={S.request("R1","minecraft:stone",4)};client.start()
    function w.grant(turn,deliveries,session,policy)
        return w.at(2,client.engine.onMessage,1,{version=1,kind="turn",session=session or "S",turn=turn,deliveries=deliveries or {},policy=policy or {}})
    end
    function w.result(turn,deliveries,requests,session)
        return w.at(2,client.engine.onMessage,1,{version=1,kind="result",session=session or "S",turn=turn,deliveries=deliveries or {},requests=requests or {}})
    end
    return w,client
end
return S
