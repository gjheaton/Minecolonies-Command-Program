local S=require("tests.support")
local Store=require("colony.network.store")
local Config=require("colony.network.config")

-- CC:Tweaked's official textutils.lua (mc-1.20.x, serialize_impl/serialize)
-- tracks active tables separately from already completed tables. Options
-- since 1.97.0 permit harmless repeated entries but never recursive entries:
-- https://github.com/cc-tweaked/CC-Tweaked/blob/mc-1.20.x/projects/core/src/main/resources/data/computercraft/lua/rom/apis/textutils.lua
Test.case("ComputerCraft simulation rejects repeated entries by default and recursive entries in both serialization modes",function()
    S.world();local item={name="minecraft:stone",count=4};local request={items={item},displayItem=item}
    local ok,err=pcall(textutils.serialize,request)
    assert(not ok and tostring(err):find("repeated entries",1,true),"hardware fixture silently duplicated aliases that ComputerCraft rejects")
    local saved=textutils.unserialize(textutils.serialize(request,{allow_repetitions=true}))
    Test.equal(saved.items[1].name,"minecraft:stone");Test.equal(saved.displayItem.count,4)
    assert(saved.items[1]~=saved.displayItem,"serialization unexpectedly restored shared object identity")
    local cycle={};cycle.child={parent=cycle}
    for _,options in ipairs({{}, {allow_repetitions=true}}) do
        ok,err=pcall(textutils.serialize,cycle,options)
        assert(not ok and tostring(err):find("recursive entries",1,true),"a genuine cycle was serialized")
    end
end)

Test.case("both journal slots round-trip shared request item and event context values with durable revisions",function()
    local w=S.world();local store=Store.new("/shared/journal",Config.defaults("master"))
    local item={name="minecraft:stone",nbt={variant="polished"},count=4};local request={id="R1",items={item},displayItem=item}
    local job={item=item,count=4,state="crafting"}
    store.data.master={craftJobs={stone=job},colonies={["2"]={turn={batch={requests={request}},orderedRequests={request}}}}}
    store.data.history={{kind="CRAFT_ACCEPTED",context=job}};store.save();Test.equal(store.data.revision,1)
    item.count=3;store.save();Test.equal(store.data.revision,2)
    local recovered=Store.new(store.path,Config.defaults("master"));recovered.load()
    Test.equal(recovered.data.revision,2);Test.equal(recovered.data.master.craftJobs.stone.item.count,3)
    Test.equal(recovered.data.master.colonies["2"].turn.batch.requests[1].displayItem.nbt.variant,"polished")
    Test.equal(recovered.data.history[1].context.item.count,3)
    w.files[store.path..".a"]="broken"
    local older=Store.new(store.path,Config.defaults("master"));older.load()
    Test.equal(older.data.revision,1);Test.equal(older.data.master.craftJobs.stone.item.count,4)
end)

Test.case("cyclic or unsupported journal values latch before filesystem access without advancing revision or damaging either slot",function()
    for _,kind in ipairs({"cycle","function"}) do
        local w=S.world();local store=Store.new("/guarded/journal",Config.defaults("master"));store.data.value="durable"
        store.save();store.save();local revision=store.data.revision;local before=textutils.serialize(w.files)
        if kind=="cycle" then local cycle={};cycle.self=cycle;store.data.invalid=cycle
        else store.data.invalid=function() end end
        local opens,directories=0,0;local originalOpen,originalDir=fs.open,fs.makeDir
        fs.open=function(...) opens=opens+1;return originalOpen(...) end
        fs.makeDir=function(...) directories=directories+1;return originalDir(...) end
        local ok,err=pcall(store.save)
        assert(not ok and tostring(err):find("Persistence failure",1,true))
        Test.equal(opens,0);Test.equal(directories,0);Test.equal(store.data.revision,revision)
        Test.equal(textutils.serialize(w.files),before);assert(store.fault)
        store.data.invalid=nil;assert(not pcall(store.save),"serialization failure did not latch later writes")
        Test.equal(opens,0);Test.equal(store.data.revision,revision)
        local recovered=Store.new(store.path,Config.defaults("master"));recovered.load()
        Test.equal(recovered.data.value,"durable");Test.equal(recovered.data.revision,revision)
    end
    local w=S.world();local store=Store.new("/not-created/journal",Config.defaults("master"))
    store.data.cycle=store.data;assert(not pcall(store.save));assert(not w.dirs["/not-created"])
    Test.equal(store.data.revision,0);assert(next(w.files)==nil)
end)

local function pair()
    local w=S.world();local m=S.computer(w,1,"master");local c=S.computer(w,2,"supply")
    c.config.deliveryChannel="D2";c.config.returnChannel="R2"
    m.config.colonies={{id=2,label="Clockwork",deliveryChest="master-delivery",returnChest="master-return",deliveryChannel="D2",returnChannel="R2"}}
    w.chest(1,"master-delivery","D2");w.chest(1,"master-return","R2")
    w.chest(2,"delivery","D2");w.chest(2,"returns","R2")
    m.rs=w.bridge(1,"prs",true);c.rs=w.bridge(2,"crs",false);c.integrator=w.integrator(2,"integrator")
    c.integrator.requests={S.request("R1","minecraft:stone",4)};c.start();m.start()
    function w.step() w.tick(1);w.tick(2);w.flush();w.advance(.25) end
    function w.untilTrue(predicate)
        for _=1,240 do if predicate() then return end;w.step() end
        assert(predicate(),"serialization regression failed to finish its real engine transaction")
    end
    return w,m,c
end

Test.case("the real master aliased batch and work queue survive restart and deliver exactly one verified shipment",function()
    local w,m,c=pair();m.rs.add({name="minecraft:stone"},16)
    w.untilTrue(function() local cs=m.store.data.master.colonies["2"];return cs and cs.turn and cs.turn.phase=="PROCESS" end)
    local turn=m.store.data.master.colonies["2"].turn
    assert(turn.orderedRequests[1]==turn.batch.requests[1],"fixture failed to reach the actual master reference alias")
    local ok,err=pcall(textutils.serialize,m.store.data)
    assert(not ok and tostring(err):find("repeated entries",1,true),"default ComputerCraft serialization did not reproduce the reported processor error")
    assert(m.store.save());m.restart()
    w.untilTrue(function() return m.store.data.master.pendingTransfer~=nil end)
    Test.equal(#w.callsFor("export",true),1);Test.equal(w.count(w.channels.D2,{name="minecraft:stone"}),4)
    m.restart()
    w.untilTrue(function() local item=c.rs.items[w.identity({name="minecraft:stone"})];return item and item.amount==4 end)
    for _=1,30 do w.step() end
    Test.equal(#w.callsFor("export",true),1);Test.equal(#w.callsFor("import",false),1)
    Test.equal(m.store.data.master.colonies["2"].shipments[1].count,4)
    Test.equal(c.store.data.client.requests.R1.status,"in progress")
end)

Test.case("persistent accepted craft jobs tolerate shared event context and restart without submitting a second craft",function()
    local w,m,c=pair();m.rs.recipes["minecraft:stone"]=true;m.rs.neverFinishCraft=true;m.config.craftingTimeoutSeconds=5
    w.untilTrue(function() return #w.callsFor("craft",true)==1 end)
    local identity,job=next(m.store.data.master.craftJobs);assert(identity and job.state=="crafting")
    m.store.event("CRAFT_CONTEXT","Inspect accepted asynchronous craft",job)
    assert(m.store.data.history[#m.store.data.history].context==job)
    local ok,err=pcall(textutils.serialize,m.store.data);assert(not ok and tostring(err):find("repeated entries",1,true))
    m.restart();w.advance(10);for _=1,35 do w.step() end
    Test.equal(#w.callsFor("craft",true),1);assert(m.store.data.master.craftJobs[identity])
    m.rs.add({name="minecraft:stone"},4)
    w.untilTrue(function() local item=c.rs.items[w.identity({name="minecraft:stone"})];return item and item.amount==4 end)
    Test.equal(#w.callsFor("craft",true),1);Test.equal(#w.callsFor("export",true),1)
end)

Test.case("real client request snapshots with shared item metadata persist through a turn and restart",function()
    local w,c=S.clientFixture();local item={name="minecraft:stone",count=4};local raw=S.request("R1","minecraft:stone",4)
    raw.items={item};raw.displayItem=item
    w.devices[2].integrator.api.getRequests=function() return {raw} end
    assert(w.grant(1));local record=c.store.data.client.requests.R1
    assert(record.raw.items[1]==record.raw.displayItem,"client copy discarded the hardware request's benign alias")
    local ok,err=pcall(textutils.serialize,c.store.data);assert(not ok and tostring(err):find("repeated entries",1,true))
    c.restart();w.tick(2)
    Test.equal(c.store.data.client.requests.R1.raw.displayItem.count,4)
    Test.equal(c.store.data.client.requests.R1.totalCount,4);Test.equal(#w.callsFor("import",false),0)
end)

Test.case("real interrupted import fault contexts reuse intent safely and remain held after restart without another transfer",function()
    local w,c=S.clientFixture();c.rs.phantomImport=true;w.insert(w.channels.D2,{name="minecraft:stone"},4)
    local shipment={id="D1",requestId="R1",item={name="minecraft:stone"},count=4,verified=true,createdAt=100}
    assert(w.grant(1,{shipment}));assert(c.store.data.client.intent and c.store.data.client.fault)
    local context=c.store.data.errors[#c.store.data.errors].context
    assert(context.intent==c.store.data.client.intent,"fixture did not reach the actual client intent/event reference alias")
    local ok,err=pcall(textutils.serialize,c.store.data);assert(not ok and tostring(err):find("repeated entries",1,true))
    c.restart();w.tick(2)
    assert(c.store.data.errors[#c.store.data.errors].context==c.store.data.client.intent)
    assert(c.store.data.client.intent and c.store.data.client.fault);assert(not c.engine.canProbe())
    Test.equal(c.store.data.client.shipments.D1.imported,0);Test.equal(w.count(w.channels.D2,{name="minecraft:stone"}),4)
    Test.equal(#w.callsFor("import",false),1)
end)

Test.case("compact journal encoding preserves aliased values and fits a quota that rejects the pretty representation",function()
    local w=S.world();local store=Store.new("/compact/journal",Config.defaults("master"))
    local item={name="minecraft:stone",nbt={variant="polished",description="Quotes \" and slash \\ remain intact"}}
    store.data.requests={}
    for i=1,40 do store.data.requests[i]={id="R"..i,item=item,status="requested",count=i} end
    local pending={};for key,value in pairs(store.data) do pending[key]=value end;pending.revision=1
    local compact=textutils.serialize(pending,{compact=true,allow_repetitions=true})
    local pretty=textutils.serialize(pending,{allow_repetitions=true})
    assert(#compact<#pretty and pretty:find("\n",1,true),"fixture does not model compact versus default whitespace")
    local quota=S.quota(w,math.max(500,#compact)+500)
    assert(#pretty+500>quota.capacity,"pretty encoding would also fit the compact-only disk quota")
    assert(store.save());Test.equal(w.files[store.path..".b"],compact);Test.equal(quota.free(),0)
    local recovered=Store.new(store.path,Config.defaults("master"));recovered.load()
    Test.equal(recovered.data.revision,1);Test.equal(recovered.data.requests[40].count,40)
    Test.equal(recovered.data.requests[1].item.nbt.description,item.nbt.description)
    Test.equal(recovered.data.requests[40].item.name,item.name)
    assert(recovered.data.requests[1].item~=recovered.data.requests[40].item,"shared tables must reload as independent values")
end)

Test.case("a completely full ComputerCraft drive can overwrite the alternating target with a smaller verified journal without deleting files",function()
    local w=S.world();local store=Store.new("/full/journal",Config.defaults("master"))
    store.data.payload=string.rep("a",4096);store.save()
    store.data.payload=string.rep("b",8192);store.save()
    local first,second=w.files[store.path..".a"],w.files[store.path..".b"]
    local quota=S.quota(w,math.huge);quota.capacity=quota.used();Test.equal(quota.free(),0)
    store.data.payload=string.rep("c",1024);assert(store.save())
    Test.equal(store.data.revision,3);Test.equal(w.files[store.path..".a"],first)
    assert(#w.files[store.path..".b"]<#second and quota.free()>0)
    Test.equal(quota.stats.writeOpens,1);Test.equal(quota.stats.writes,1);Test.equal(quota.stats.deletes,0)
    local recovered=Store.new(store.path,Config.defaults("master"));recovered.load()
    Test.equal(recovered.data.revision,3);Test.equal(recovered.data.payload,string.rep("c",1024))
end)

Test.case("insufficient journal space fails before opening the alternating slot and preserves both durable revisions",function()
    local w=S.world();local store=Store.new("/limited/journal",Config.defaults("master"))
    store.data.payload="revision one";store.save();store.data.payload="revision two";store.save()
    local quota=S.quota(w,math.huge);quota.capacity=quota.used()+100
    local before=textutils.serialize(w.files);store.data.payload=string.rep("large",2000)
    local ok,err=pcall(store.save);assert(not ok and tostring(err):find("Persistence failure",1,true))
    Test.equal(store.data.revision,2);Test.equal(textutils.serialize(w.files),before)
    Test.equal(quota.stats.writeOpens,0);Test.equal(quota.stats.writes,0);Test.equal(quota.stats.mkdirs,0);Test.equal(quota.stats.deletes,0)
    quota.capacity=math.huge;assert(not pcall(store.save),"disk-space failure did not latch later writes")
    Test.equal(quota.stats.writeOpens,0)
    local recovered=Store.new(store.path,Config.defaults("master"));recovered.load()
    Test.equal(recovered.data.revision,2);Test.equal(recovered.data.payload,"revision two")
end)

Test.case("new journal preflight includes every missing directory and the minimum file allocation before creating anything",function()
    local w=S.world();local quota=S.quota(w,1499)
    local store=Store.new("/new/deep/journal",Config.defaults("master"))
    assert(not pcall(store.save));Test.equal(store.data.revision,0)
    assert(next(w.files)==nil and next(w.dirs)==nil)
    Test.equal(quota.stats.mkdirs,0);Test.equal(quota.stats.writeOpens,0)
    quota.capacity=1500;store=Store.new(store.path,Config.defaults("master"));assert(store.save())
    Test.equal(quota.used(),1500);Test.equal(quota.free(),0)
    Test.equal(quota.stats.mkdirs,2);Test.equal(quota.stats.writeOpens,1)
    local recovered=Store.new(store.path,Config.defaults("master"));recovered.load();Test.equal(recovered.data.revision,1)
end)

Test.case("a real master transfer whose intent cannot fit the disk stops before exporting and leaves both original journals intact",function()
    local w,m=pair();m.rs.add({name="minecraft:stone"},8)
    local save=m.store.save;local quota,before,revision
    m.store.save=function()
        if m.store.data.master.pendingTransfer and m.store.data.master.pendingTransfer.intent and not quota then
            quota=S.quota(w,math.huge);quota.capacity=quota.used()
            before=textutils.serialize(w.files);revision=m.store.data.revision
        end
        return save()
    end
    local ok,err=pcall(function() for _=1,30 do w.step() end end)
    assert(not ok and tostring(err):find("Persistence failure",1,true),"the full drive accepted an enlarged write-ahead intent")
    assert(quota and m.store.fault);Test.equal(m.store.data.revision,revision)
    Test.equal(textutils.serialize(w.files),before);Test.equal(quota.stats.writeOpens,0);Test.equal(quota.stats.writes,0)
    Test.equal(#w.callsFor("export",true),0);Test.equal(w.count(w.channels.D2,{name="minecraft:stone"}),0)
    quota.capacity=math.huge;m.restart()
    w.untilTrue(function() local item=w.computers[2].rs.items[w.identity({name="minecraft:stone"})];return item and item.amount==4 end)
    Test.equal(#w.callsFor("export",true),1);Test.equal(#w.callsFor("import",false),1)
end)

return true
