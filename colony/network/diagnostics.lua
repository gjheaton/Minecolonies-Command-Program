-- Ender Chest identity is established by an actual one-item round trip, not
-- by matching two empty inventory lists or trusting peripheral names.
local Protocol=require("colony.network.protocol")
local Config=require("colony.network.config")
local M={}
local function countAll(items)
    local count=0; for _,item in pairs(items or {}) do count=count+(item.count or item.amount or 0) end; return count
end
local function snapshot(io,name) local items,err=io.snapshot(name); if not items then error(err,0) end; return items end
local function verify(io,config,fn)
    local deadline=io.now()+config.transferVerifyTimeoutSeconds
    repeat
        local ok,result=pcall(fn)
        if ok and result then return true end
        if io.now()>=deadline then return false,ok and "Inventory verification timed out" or tostring(result) end
        io.wait(config.transferPollSeconds)
    until false
end
function M.printReport(config,io)
    print("MineColonies "..config.role.." v"..Config.VERSION)
    local health=io.health()
    for name,check in pairs(health.checks) do print((check.ok and "OK   " or "FAIL ")..name..": "..tostring(check.detail)) end
    local names={}
    if config.role=="master" then
        for _,route in ipairs(config.colonies) do names[#names+1]=route.deliveryChest; names[#names+1]=route.returnChest end
    else names={config.deliveryChestName,config.returnChestName} end
    for _,name in ipairs(names) do
        local chest,err=io.describe(name)
        if chest then print(name..": "..chest.size.." slots, "..countAll(chest.contents).." items, pushItems="..tostring(chest.pushItems)..", pullItems="..tostring(chest.pullItems))
        else print("FAIL "..tostring(name)..": "..tostring(err)) end
    end
    print("Color labels are user configuration; chesttest verifies the physical channels.")
    if io.monitors then
        print("Supply displays: 5 blocks wide x 3 high, text scale 0.5 (100 x 38 characters).")
        for _,monitor in ipairs(io.monitors()) do
            print((monitor.sizeOK and monitor.color and "OK   " or "WARN ")..monitor.name..": "..tostring(monitor.width).." x "..tostring(monitor.height)..", color="..tostring(monitor.color)..", "..monitor.assigned)
        end
    end
end
function M.handleClient(config,store,io,message,canProbe)
    if message.kind~="probe" or type(message.token)~="string" or message.token=="" then return nil end
    local record=store.data.chestTest
    local response={kind="probe_result",token=message.token,phase=message.phase,ok=false}
    local function fail(err) response.error=tostring(err); return response end
    if record and record.token~=message.token then return fail("Another chest test is reserved; resume or release its token") end
    if message.phase=="abandon" then
        local output,outputErr=io.snapshot(config.deliveryChestName)
        local returns,returnErr=io.snapshot(config.returnChestName)
        if not output or not returns then return fail(outputErr or returnErr) end
        if countAll(output)~=0 or countAll(returns)~=0 then return fail("Manually recover test items and empty both channels before abandoning") end
        store.data.chestTest=nil; store.event("WARNING","Chest test abandoned after operator inventory recovery",{token=message.token})
        response.ok=true; return response
    end
    if message.phase=="release" then
        if record and record.intent then return fail("Test movement is uncertain; reconcile before releasing") end
        store.data.chestTest=nil; store.save(); response.ok=true; return response
    end
    if not record then
        if message.phase~="inspect" then return fail("No test reservation; start with inspection") end
        local ready,err=canProbe(); if not ready then return fail(err or "Supply turn is busy") end
        if config.deliveryChannel=="" or config.returnChannel=="" or config.deliveryChannel~=message.deliveryChannel or config.returnChannel~=message.returnChannel then
            return fail("Configured chest color channels do not match the master route")
        end
        local output,outputErr=io.describe(config.deliveryChestName)
        local returns,returnErr=io.describe(config.returnChestName)
        if not output or not returns then return fail(outputErr or returnErr) end
        if config.deliveryChestName==config.returnChestName or not output.pushItems then return fail("Distinct inventories with pushItems are required") end
        if countAll(output.contents)~=0 or countAll(returns.contents)~=0 then return fail("Both test channels must be empty") end
        record={token=message.token,phase="inspected",time=io.now()}
        store.data.chestTest=record; store.save()
    end
    if message.phase=="inspect" then
        response.ok=true; response.deliveryChest=config.deliveryChestName; response.returnChest=config.returnChestName
        return response
    end
    if message.phase~="return" or type(message.item)~="table" or message.count~=1 then return fail("Invalid test phase or item") end
    local ok,err=pcall(function()
        if record.phase=="returned" then response.ok=true; return end
        local output=snapshot(io,config.deliveryChestName); local returns=snapshot(io,config.returnChestName)
        if record.intent then
            if countAll(output)==0 and countAll(returns)==1 and io.count(returns,record.intent.item)==1 then
                record.intent=nil; record.phase="returned"; store.save(); response.ok=true; return
            end
            error("Interrupted test move cannot be proven; do not repeat it",0)
        end
        if countAll(output)~=1 or io.count(output,message.item)~=1 or countAll(returns)~=0 then error("The master delivery is absent, wrong, or the return channel is occupied",0) end
        local slot; for index,item in pairs(output) do if io.same(item,message.item) then slot=index end end
        record.intent={item=message.item,slot=slot,count=1}; store.save()
        local moved,moveErr=io.moveInventory(config.deliveryChestName,config.returnChestName,slot,1)
        local proven,proofErr=verify(io,config,function()
            local afterOutput=snapshot(io,config.deliveryChestName); local afterReturns=snapshot(io,config.returnChestName)
            return countAll(afterOutput)==0 and countAll(afterReturns)==1 and io.count(afterReturns,message.item)==1
        end)
        if not proven then error(moveErr or proofErr,0) end
        -- The physical delta is authoritative even if pushItems returned nil.
        record.intent=nil; record.phase="returned"; record.reported=moved; store.save(); response.ok=true
    end)
    if not ok then response.error=tostring(err) end
    return response
end
local function ask(io,config,id,message)
    local deadline=io.now()+config.chestTestTimeoutSeconds
    repeat
        io.send(id,message)
        local waitFor=math.min(config.batchRetrySeconds,math.max(.05,deadline-io.now()))
        local sender,response=rednet.receive(Protocol.NAME,waitFor)
        if sender==id and Protocol.valid(response) and response.kind=="probe_result" and response.token==message.token and response.phase==message.phase then
            if not response.ok then error(response.error or "Colony chest test refused",0) end
            return response
        end
    until io.now()>=deadline
    error("Colony chest test response timed out; reservation retained for safe resume",0)
end
function M.runMaster(config,store,io,matcher,id,itemName,abandon)
    if config.role~="master" then error("Run chesttest on the PRS master; leave the colony client running",0) end
    local route; for _,candidate in ipairs(config.colonies) do if candidate.id==id then route=candidate end end
    if not route then error("Configure the colony route before testing",0) end
    local master=store.data.master or {}
    -- No physical test can overlap an outstanding normal turn or shipment.
    if master.pendingTransfer or master.pending or master.intent or master.activeTurn then error("Reconcile/finish the normal master turn before testing",0) end
    for _,colony in pairs(master.colonies or {}) do
        if colony.grant or colony.pending or colony.intent or colony.turn then
            error("A normal colony turn is reserved; finish it before testing",0)
        end
    end
    local record=store.data.chestTest
    if record and record.colonyId~=id then error("Resume the recorded chest test for colony "..tostring(record.colonyId),0) end
    if abandon then
        if not record then error("No recorded chest test to abandon",0) end
        local output=snapshot(io,route.deliveryChest); local returns=snapshot(io,route.returnChest)
        if countAll(output)~=0 or countAll(returns)~=0 then error("Manually recover test items and empty both Ender Chest channels first",0) end
        print("Abandoning does not certify this test passed. Confirm you recovered any uncertain test item.")
        write("Type ABANDON: "); if read()~="ABANDON" then error("Abandon cancelled",0) end
        ask(io,config,id,{kind="probe",token=record.token,phase="abandon"})
        store.data.chestTest=nil; store.event("WARNING","Chest test abandoned after operator inventory recovery",{colonyId=id,token=record.token})
        print("Test reservation cleared. Run chesttest again before enabling supply.")
        return
    end
    if not record then
        local output=snapshot(io,route.deliveryChest); local returns=snapshot(io,route.returnChest)
        if countAll(output)~=0 or countAll(returns)~=0 then error("Both Ender Chest channels must be empty before testing",0) end
        local items,err=io.stock(); if not items then error(err,0) end
        local selected
        for _,item in pairs(items) do if item.name==(itemName or config.chestTestItem) and (item.amount or 0)>0 and matcher.canonicalNBT(item.nbt)=="" then selected=item; break end end
        if not selected then error("Store a plain, non-NBT "..tostring(itemName or config.chestTestItem).." in PRS for the test",0) end
        record={token=tostring(os.getComputerID())..":"..tostring(io.now()),colonyId=id,phase="inspect",item={name=selected.name,nbt=selected.nbt},variant=selected}
        store.data.chestTest=record; store.save()
    end
    local base={kind="probe",token=record.token}
    if record.phase=="inspect" then
        ask(io,config,id,{kind="probe",token=record.token,phase="inspect",deliveryChannel=route.deliveryChannel,returnChannel=route.returnChannel})
        record.phase="export_intent"; store.save()
        local candidate={name=record.item.name,hasNBT=false,raw=record.item}
        local moved,err=io.exportPRS(candidate,record.variant,1,route.deliveryChest,route)
        record.reportedExport=moved; record.exportError=err; store.save()
    end
    if record.phase=="export_intent" then
        local proven,err=verify(io,config,function()
            local items=snapshot(io,route.deliveryChest)
            return countAll(items)==1 and io.count(items,record.item)==1
        end)
        if not proven then error(record.exportError or err.."; export will not be repeated",0) end
        record.phase="return"; store.save()
    end
    if record.phase=="return" then
        ask(io,config,id,{kind="probe",token=record.token,phase="return",item=record.item,count=1})
        local proven,err=verify(io,config,function()
            local output=snapshot(io,route.deliveryChest); local returns=snapshot(io,route.returnChest)
            return countAll(output)==0 and countAll(returns)==1 and io.count(returns,record.item)==1
        end)
        if not proven then error(err.."; return channel identity could not be established",0) end
        local before,beforeErr=io.stock(); if not before then error(beforeErr,0) end
        record.prsBefore=io.count(before,record.item)
        record.phase="import_intent"; store.save()
        local imported,importErr=io.importPRS(record.item,1,route.returnChest,route)
        record.reportedImport,record.importError=imported,importErr; store.save()
        local confirmed,confirmErr=verify(io,config,function()
            local returns=snapshot(io,route.returnChest); local after=io.stock()
            return imported==1 and countAll(returns)==0 and after and io.count(after,record.item)>=record.prsBefore+1
        end)
        if not confirmed then error(importErr or confirmErr.."; import will not be repeated",0) end
        record.phase="release"; store.save()
    elseif record.phase=="import_intent" then
        local confirmed=verify(io,config,function()
            local returns=snapshot(io,route.returnChest); local after=io.stock()
            return countAll(returns)==0 and after and io.count(after,record.item)>=record.prsBefore+1
        end)
        if not confirmed then error("Interrupted PRS return cannot be proven and will not be repeated. Recover the test item manually, empty both channels, then use chesttest abandon "..id,0) end
        record.phase="release"; store.save()
    end
    if record.phase=="release" then
        ask(io,config,id,{kind="probe",token=record.token,phase="release"})
        store.data.chestTest=nil; store.event("CHEST_TEST","Ender Chest round trip passed",{colonyId=id,item=record.item.name})
        print("PASS: PRS -> delivery channel -> colony -> return channel -> PRS (1 "..record.item.name..")")
    end
end
return M
