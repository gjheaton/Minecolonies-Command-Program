local S=require("tests.support")
local Diagnostics=require("colony.network.diagnostics")
local function fixture(options)
    local w=S.world(options);local m=S.computer(w,1,"master");local c=S.computer(w,2,"supply")
    m.rs=w.bridge(1,"prs",true);m.rs.add({name="minecraft:cobblestone"},2)
    w.chest(1,"out","delivery");w.chest(1,"back","returns")
    w.chest(2,"delivery","delivery");w.chest(2,"returns","returns")
    c.rs=w.bridge(2,"crs",false);c.integrator=w.integrator(2,"integrator")
    c.config.deliveryChannel="red-white-blue";c.config.returnChannel="red-white-black"
    m.config.colonies={{id=2,deliveryChest="out",returnChest="back",deliveryChannel="red-white-blue",returnChannel="red-white-black"}}
    m.config.chestTestTimeoutSeconds=3;m.config.batchRetrySeconds=1
    m.start();c.start()
    c.handler=function(sender,message)
        local response=Diagnostics.handleClient(c.config,c.store,c.io,message,c.engine.canProbe)
        if response then c.io.send(sender,response) else c.engine.onMessage(sender,message) end
    end
    function w.probe() return w.at(1,Diagnostics.runMaster,m.config,m.store,m.io,m.matcher,2) end
    return w,m,c
end

Test.case("Ender Chest diagnostic proves both color channels and restores PRS test item",function()
    local w,m,c=fixture();w.probe()
    Test.equal(m.rs.items[w.identity({name="minecraft:cobblestone"})].amount,2)
    Test.equal(w.count(w.channels.delivery,{name="minecraft:cobblestone"}),0)
    Test.equal(w.count(w.channels.returns,{name="minecraft:cobblestone"}),0)
    Test.equal(#w.callsFor("export",true),1);Test.equal(#w.callsFor("import",true),1)
    Test.equal(#w.callsFor(nil,false),0,"chest diagnostic unexpectedly touched colony RS")
    assert(m.store.data.chestTest==nil and c.store.data.chestTest==nil)
end)

Test.case("Ender Chest diagnostic binds a known exact export to the physical CC hash and restores the original AP item",function()
    local w,m,c=fixture({asymmetricNBT=true});w.probe()
    local stock=w.at(1,m.io.stock)
    Test.equal(m.io.count(stock,{name="minecraft:cobblestone"}),2)
    Test.equal(next(w.channels.delivery.slots),nil);Test.equal(next(w.channels.returns.slots),nil)
    local exports,imports=w.callsFor("export",true),w.callsFor("import",true)
    Test.equal(#exports,1);Test.equal(#imports,1)
    assert(exports[1].filter.fingerprint)
    Test.equal(imports[1].filter.name,"minecraft:cobblestone")
    Test.equal(imports[1].filter.fingerprint,nil)
    Test.equal(imports[1].filter.fromSlot,0)
    Test.equal(imports[1].filter.nbt,nil,"a CC hash reached the AP NBT parser")
    assert(m.store.data.chestTest==nil and c.store.data.chestTest==nil)
end)

Test.case("Ender Chest diagnostic restart binds a persisted positive export without sending another item",function()
    local w,m,c=fixture({asymmetricNBT=true});local save=m.store.save;local interrupted=false
    m.store.save=function()
        local result=save();local record=m.store.data.chestTest
        if not interrupted and record and record.phase=="export_intent" and record.reportedExport==1 then
            interrupted=true;error("simulated interruption after the positive result was saved",0)
        end
        return result
    end
    local ok,err=pcall(w.probe);assert(not ok and tostring(err):find("simulated interruption"))
    Test.equal(#w.callsFor("export",true),1)
    assert(m.store.data.chestTest.physicalBefore and m.store.data.chestTest.stockItem)
    m.restart();w.probe()
    Test.equal(#w.callsFor("export",true),1);Test.equal(#w.callsFor("import",true),1)
    local stock=w.at(1,m.io.stock);Test.equal(m.io.count(stock,{name="minecraft:cobblestone"}),2)
    assert(m.store.data.chestTest==nil and c.store.data.chestTest==nil)
end)

Test.case("Ender Chest diagnostic never binds an unknown export to a different physical hash or replays it",function()
    local w,m,c=fixture({asymmetricNBT=true});m.rs.unknownExport=true
    local export=w.devices[1].prs.api.exportItemToPeripheral
    local taggedHash=w.ccNBT({display={Name="Changed during export"}})
    w.devices[1].prs.api.exportItemToPeripheral=function(...)
        local result=export(...)
        -- A genuine metadata change must still block an unknown outcome;
        -- CC's known empty compound is now the same original plain item.
        for _,item in pairs(w.channels.delivery.slots) do item.nbt=taggedHash end
        return result
    end
    local ok=pcall(w.probe);assert(not ok)
    Test.equal(m.store.data.chestTest.phase,"export_intent")
    Test.equal(#w.callsFor("export",true),1);Test.equal(#w.callsFor("import",true),0)
    Test.equal(w.count(w.channels.delivery,{name="minecraft:cobblestone",nbt=taggedHash}),1)
    m.restart();assert(not pcall(w.probe))
    Test.equal(#w.callsFor("export",true),1);Test.equal(#w.callsFor("import",true),0)
    assert(m.store.data.chestTest and c.store.data.chestTest)
end)

Test.case("Ender Chest diagnostic refuses collateral inventory changes even with a positive export",function()
    local w,m,c=fixture({asymmetricNBT=true});local export=w.devices[1].prs.api.exportItemToPeripheral
    w.devices[1].prs.api.exportItemToPeripheral=function(...)
        local result=export(...);w.insert(w.channels.delivery,{name="minecraft:dirt"},1);return result
    end
    assert(not pcall(w.probe));Test.equal(m.store.data.chestTest.phase,"export_intent")
    Test.equal(#w.callsFor("export",true),1);Test.equal(#w.callsFor("import",true),0)
    assert(c.store.data.chestTest)
end)

Test.case("Ender Chest diagnostic rejects color labels mismatching route before export",function()
    local w,m,c=fixture();c.config.deliveryChannel="yellow-white-blue"
    local ok,err=pcall(w.probe);assert(not ok and tostring(err):find("do not match"))
    Test.equal(#w.callsFor("export",true),0)
    Test.equal(m.rs.items[w.identity({name="minecraft:cobblestone"})].amount,2)
end)

Test.case("Ender Chest diagnostic detects same physical channel behind different names",function()
    local w,m,c=fixture()
    w.chest(1,"back","delivery");w.chest(2,"returns","delivery")
    local ok,err=pcall(w.probe);assert(not ok and tostring(err):find("return channel is occupied"))
    Test.equal(#w.callsFor("export",true),1);Test.equal(#w.callsFor("import",true),0)
    assert(m.store.data.chestTest and c.store.data.chestTest)
    ok=pcall(w.probe);assert(not ok);Test.equal(#w.callsFor("export",true),1,"failed channel test repeated test export")
end)

Test.case("Ender Chest diagnostic detects wrong remote delivery channel despite matching labels",function()
    local w,m,c=fixture();w.chest(2,"delivery","wrong-delivery")
    local ok,err=pcall(w.probe);assert(not ok and tostring(err):find("delivery is absent"))
    Test.equal(#w.callsFor("export",true),1);Test.equal(#w.callsFor("import",true),0)
    Test.equal(w.count(w.channels.delivery,{name="minecraft:cobblestone"}),1)
    Test.equal(w.count(w.channels["wrong-delivery"],{name="minecraft:cobblestone"}),0)
end)

Test.case("Ender Chest diagnostic detects wrong remote return channel",function()
    local w,m,c=fixture();w.chest(2,"returns","wrong-returns")
    local ok,err=pcall(w.probe);assert(not ok and tostring(err):find("return channel identity"))
    Test.equal(#w.callsFor("export",true),1);Test.equal(#w.callsFor("import",true),0)
    Test.equal(w.count(w.channels["wrong-returns"],{name="minecraft:cobblestone"}),1)
    Test.equal(w.count(w.channels.returns,{name="minecraft:cobblestone"}),0)
end)

Test.case("Ender Chest diagnostic retries lost probes and replies without repeating physical transfers",function()
    local w,m,c=fixture();w.drop={probe=1,probe_result=1};w.probe()
    Test.equal(#w.callsFor("export",true),1);Test.equal(#w.callsFor("import",true),1)
    Test.equal(m.rs.items[w.identity({name="minecraft:cobblestone"})].amount,2)
    assert(c.store.data.chestTest==nil)
end)

Test.case("Ender Chest diagnostic resumes failed export verification without another export",function()
    local w,m,c=fixture();m.rs.phantomExport=true
    local ok=pcall(w.probe);assert(not ok)
    Test.equal(m.store.data.chestTest.phase,"export_intent")
    Test.equal(#w.callsFor("export",true),1)
    m.restart();ok=pcall(w.probe);assert(not ok)
    Test.equal(#w.callsFor("export",true),1)
    assert(c.store.data.chestTest~=nil)
end)

Test.case("Ender Chest diagnostic cannot overlap a normal reserved colony turn",function()
    local w,m=fixture();w.tick(2);w.flush();w.tick(1)
    local ok,err=pcall(w.probe);assert(not ok and tostring(err):find("normal colony turn is reserved"))
    Test.equal(#w.callsFor("export",true),0)
end)

Test.case("Ender Chest diagnostic persistence failure prevents test export",function()
    local w,m=fixture();w.writeFail=true
    local ok,err=pcall(w.probe);assert(not ok and tostring(err):find("Persistence failure"))
    Test.equal(#w.callsFor("export",true),0)
end)

Test.case("Ender Chest test restart proves interrupted return import without importing twice",function()
    local w,m,c=fixture();local save=m.store.save
    m.store.save=function()
        local record=m.store.data.chestTest
        if record and record.reportedImport==1 then w.writeFail=true end
        return save()
    end
    local ok,err=pcall(w.probe);assert(not ok and tostring(err):find("Persistence failure"))
    Test.equal(#w.callsFor("export",true),1);Test.equal(#w.callsFor("import",true),1)
    Test.equal(m.rs.items[w.identity({name="minecraft:cobblestone"})].amount,2)
    Test.equal(w.count(w.channels.returns,{name="minecraft:cobblestone"}),0)
    w.writeFail=false;m.restart()
    Test.equal(m.store.data.chestTest.phase,"import_intent")
    w.probe()
    Test.equal(#w.callsFor("import",true),1,"resumed diagnostic repeated PRS import")
    assert(m.store.data.chestTest==nil and c.store.data.chestTest==nil)
end)

local function abandon(w,m,answer)
    _G.write=function() end;_G.read=function() return answer or "ABANDON" end
    return w.at(1,Diagnostics.runMaster,m.config,m.store,m.io,m.matcher,2,nil,true)
end

Test.case("Ender Chest abandon refuses occupied master channels without clearing reservation",function()
    local w,m,c=fixture();w.chest(2,"delivery","wrong-delivery")
    assert(not pcall(w.probe))
    local ok,err=pcall(abandon,w,m);assert(not ok and tostring(err):find("empty both Ender Chest channels"))
    assert(m.store.data.chestTest and c.store.data.chestTest)
    Test.equal(#w.callsFor("export",true),1);Test.equal(#w.callsFor("import",true),0)
end)

Test.case("Ender Chest abandon confirms operator recovery on both computers and logs warning instead of pass",function()
    local w,m,c=fixture();m.rs.phantomExport=true;assert(not pcall(w.probe))
    local ok,err=pcall(abandon,w,m,"no");assert(not ok and tostring(err):find("cancelled"))
    assert(m.store.data.chestTest and c.store.data.chestTest)
    abandon(w,m)
    assert(m.store.data.chestTest==nil and c.store.data.chestTest==nil)
    Test.equal(#w.callsFor("export",true),1);Test.equal(#w.callsFor("import",true),0)
    for _,computer in ipairs({m,c}) do
        local warning=false
        for _,entry in ipairs(computer.store.data.history) do
            assert(entry.kind~="CHEST_TEST","abandoned diagnostic recorded a pass")
            if entry.kind=="WARNING" and entry.message:find("abandoned") then warning=true end
        end
        assert(warning,"abandonment had no durable warning")
    end
end)

Test.case("Ender Chest abandon refuses occupied colony-only channel",function()
    local w,m,c=fixture();m.rs.phantomExport=true;assert(not pcall(w.probe))
    w.chest(2,"returns","unshared-returns");w.insert(w.channels["unshared-returns"],{name="minecraft:cobblestone"},1)
    local ok,err=pcall(abandon,w,m);assert(not ok and tostring(err):find("empty both channels"))
    assert(m.store.data.chestTest and c.store.data.chestTest)
    Test.equal(#w.callsFor("export",true),1);Test.equal(#w.callsFor("import",true),0)
end)

local function captureReport(w,computer,fn)
    local previousPrint,previousOpen,previousDir=print,fs.open,fs.makeDir
    local lines,writes,mkdirs={},0,0
    _G.print=function(value) lines[#lines+1]=tostring(value) end
    fs.open=function(path,mode) if mode~="r" then writes=writes+1 end;return previousOpen(path,mode) end
    fs.makeDir=function(...) mkdirs=mkdirs+1;return previousDir(...) end
    local before=textutils.serialize(w.files);local revision=computer.store.data.revision
    local ok,err=pcall(function() w.at(computer.id,fn) end)
    _G.print=previousPrint;fs.open=previousOpen;fs.makeDir=previousDir;assert(ok,err)
    Test.equal(writes,0);Test.equal(mkdirs,0);Test.equal(computer.store.data.revision,revision)
    Test.equal(textutils.serialize(w.files),before)
    return table.concat(lines,"\n")
end

Test.case("explicit bridge diagnostics report true false and unknown RS connections and read only the selected role's stock",function()
    for _,role in ipairs({"master","supply"}) do
        for _,state in ipairs({"connected","disconnected","unknown"}) do
            local w,m,c=fixture();local selected=role=="master" and m or c
            local name=role=="master" and "prs" or "crs";local api=w.devices[selected.id][name].api;local statusReads=0
            api.isConnected=function()
                statusReads=statusReads+1
                if state=="connected" then return true end
                if state=="disconnected" then return false,"NOT_CONNECTED" end
                return nil,"NETWORK_STATUS_UNAVAILABLE"
            end
            if state~="connected" then api.listItems=function() return nil,"INVENTORY_UNAVAILABLE" end end
            if role=="master" then selected.io.colonyStock=function() error("master read colony stock",0) end
            else selected.io.stock=function() error("supply read PRS stock",0) end end
            local report=captureReport(w,selected,function() Diagnostics.printReport(selected.config,selected.io,selected.store) end)
            assert(report:find("RS bridge: "..name,1,true));Test.equal(statusReads,1)
            if state=="connected" then
                assert(report:find("RS network connected: true",1,true) and report:find("RS stock read: OK",1,true))
            elseif state=="disconnected" then
                assert(report:find("RS network connected: false - NOT_CONNECTED",1,true))
                assert(report:find("RS stock read: FAIL - INVENTORY_UNAVAILABLE",1,true))
            else
                assert(report:find("RS network connected: UNKNOWN - NETWORK_STATUS_UNAVAILABLE",1,true))
                assert(report:find("RS stock read: FAIL - INVENTORY_UNAVAILABLE",1,true))
            end
            Test.equal(#w.callsFor("import"),0);Test.equal(#w.callsFor("export"),0);Test.equal(#w.callsFor("craft"),0)
            if role=="supply" then Test.equal(#w.callsFor(nil,true),0) end
        end
    end
end)

Test.case("actual diagnostic CLI inspects a retained unknown import without constructing the engine or rewriting its fault or journals",function()
    require("tests.display_support").world() -- Native CC terminal/color APIs for the real runtime module.
    local w,c=S.clientFixture();w.insert(w.channels.D2,{name="minecraft:stone"},4)
    local api=w.devices[2].crs.api;local transfers=0
    api.importItemFromPeripheral=function() transfers=transfers+1;return nil,"NOT_CONNECTED" end
    api.isConnected=function() return false,"NOT_CONNECTED" end
    api.listItems=function() return nil,"NOT_CONNECTED" end
    local delivery={id="D1",requestId="R1",item={name="minecraft:stone"},count=4,verified=true,createdAt=100}
    w.grant(1,{delivery});Test.equal(c.store.data.client.fault.code,"TRANSFER_DESYNC")
    local Config=require("colony.network.config");local Store=require("colony.network.store")
    w.at(2,function() Config.save(c.config) end)
    local runtimeStore=Store.new("/colony/supply_v4_state",c.config)
    runtimeStore.data=textutils.unserialize(textutils.serialize(c.store.data,{compact=true,allow_repetitions=true}))
    runtimeStore.save();runtimeStore.save()
    local beforeData=textutils.serialize(runtimeStore.data,{compact=true,allow_repetitions=true})
    local Client=require("colony.network.client");local originalNew=Client.new;local constructions=0
    Client.new=function() constructions=constructions+1;error("diagnostic command constructed a mutating client",0) end
    local ok,report=pcall(captureReport,w,c,function() require("colony.network.runtime").run("supply","diag") end)
    Client.new=originalNew;assert(ok,report)
    assert(report:find("RS bridge: crs",1,true) and report:find("RS network connected: false - NOT_CONNECTED",1,true))
    assert(report:find("RS stock read: FAIL - NOT_CONNECTED",1,true))
    assert(report:find("HELD TRANSFER: Delivery import",1,true) and report:find("Item: minecraft:stone x4",1,true))
    assert(report:find("Chest: delivery",1,true) and report:find("Before chest: 4; reported: UNKNOWN",1,true))
    assert(report:find("Bridge error: NOT_CONNECTED",1,true) and report:find("Shipment: D1",1,true))
    assert(report:find("Recorded chest change: 0",1,true),"the stored zero delta was omitted from the held-transfer inspection")
    local networkEnd=assert(report:find("RS bridge: crs",1,true));assert(networkEnd>report:find("Color labels",1,true))
    local reloaded=Store.new(runtimeStore.path,c.config);reloaded.load()
    Test.equal(textutils.serialize(reloaded.data,{compact=true,allow_repetitions=true}),beforeData)
    Test.equal(constructions,0);Test.equal(transfers,1);Test.equal(#w.callsFor(nil,true),0)
    Test.equal(w.count(w.channels.D2,{name="minecraft:stone"}),4)
    Test.equal(reloaded.data.client.shipments.D1.imported,0);Test.equal(reloaded.data.client.fault.code,"TRANSFER_DESYNC")
    assert(reloaded.data.client.intent and reloaded.data.client.intent.reported==nil)
end)

local function heldTargetFixture(reported)
    local w,m=fixture()
    local source=m.rs.items[w.identity({name="minecraft:cobblestone"})]
    m.store.data.master.pendingTransfer={kind="export",colonyId=2,requestId="R2",generation=1,chest="out",
        item={name=source.name,fingerprint=source.fingerprint,nbt={Private="original AP metadata"}},
        count=1,before=0,reported=reported,callError="ORIGINAL_EXPORT_ERROR",session="master-1",turn=1,
        startedAt=90,verifySeconds=1,pollSeconds=.1,uncertain=true}
    m.store.data.master.quarantine={code="TRANSFER_VERIFY",message="Original transfer remains held"}
    m.store.save()
    w.insert(w.channels.delivery,{name="minecraft:dirt"},3)
    local f={w=w,m=m,calls={}}
    local function encode(value) return textutils.serialize(value,{compact=true,allow_repetitions=true}) end
    function f.capture(ordinaryReport)
        local before={data=encode(m.store.data),fault=m.store.fault,inventory=encode(w.channels),stock=encode(m.rs.items)}
        local report=captureReport(w,m,function()
            if ordinaryReport then Diagnostics.printReport(m.config,m.io,m.store)
            else Diagnostics.printHeldMaster(m.config,m.io,m.store) end
        end)
        Test.equal(encode(m.store.data),before.data,"held-target inspection changed a fault or write-ahead intent")
        Test.equal(m.store.fault,before.fault);Test.equal(encode(w.channels),before.inventory,"zero-count inspection moved inventory")
        Test.equal(encode(m.rs.items),before.stock,"zero-count inspection changed PRS stock")
        return report
    end
    function f.spy(method,result)
        local api=w.devices[1].prs.api
        api[method]=function(filter,destination)
            f.calls[#f.calls+1]={method=method,filter=S.copy(filter),destination=destination}
            return result()
        end
        local other=method=="exportItem" and "exportItemToPeripheral" or "exportItem"
        api[other]=function() error("inspection selected the unconfigured export path",0) end
        api.importItemFromPeripheral=function() error("held export inspection imported an item",0) end
        api.craftItem=function() error("held export inspection crafted an item",0) end
    end
    function f.exactCall(method,destination)
        Test.equal(#f.calls,1)
        local call=f.calls[1];Test.equal(call.method,method);Test.equal(call.destination,destination)
        Test.equal(call.filter.name,"minecraft:cobblestone");Test.equal(call.filter.count,0)
        Test.equal(call.filter.fingerprint,nil);Test.equal(call.filter.nbt,nil)
        local fields=0;for _ in pairs(call.filter) do fields=fields+1 end
        Test.equal(fields,2,"target inspection sent fields beyond the zero-count registry-name filter")
    end
    return f
end

Test.case("held zero export diagnostics preserve original and zero-target errors with an exact zero-count name filter and no state changes",function()
    for _,mode in ipairs({"invalid target","zero with error","accepted","unknown","throw","malformed"}) do
        local f=heldTargetFixture(0)
        f.spy("exportItemToPeripheral",function()
            if mode=="invalid target" then return nil,"INVALID_TARGET" end
            if mode=="zero with error" then return 0,"INVALID_TARGET" end
            if mode=="accepted" then return 0 end
            if mode=="unknown" then return nil end
            if mode=="throw" then error("TARGET_CALL_THROWN",0) end
            return "malformed"
        end)
        local report=f.capture();f.exactCall("exportItemToPeripheral","out")
        assert(report:find("PRS connected: true",1,true),"diagnostic omitted the resolved PRS connection status")
        assert(report:find("ORIGINAL_EXPORT_ERROR",1,true),"diagnostic omitted the original held call error")
        if mode=="invalid target" or mode=="zero with error" then
            assert(report:find("INVALID_TARGET",1,true),"zero-count target inspection lost the API rejection")
        elseif mode=="accepted" then
            assert(report:lower():find("accepted",1,true),"valid zero-count target handler was not reported")
            assert(report:lower():find("insertion",1,true),"report did not limit the target acceptance conclusion")
        elseif mode=="throw" then assert(report:find("TARGET_CALL_THROWN",1,true)) end
    end
end)

Test.case("held zero export diagnostics use the configured directional method and output direction without peripheral fallback",function()
    local f=heldTargetFixture(0)
    f.m.config.usePeripheralTransfer=false;f.m.config.colonies[1].outputDirection="east"
    f.spy("exportItem",function() return 0 end)
    local report=f.capture();f.exactCall("exportItem","east")
    assert(report:find("exportItem",1,true) and report:find("east",1,true),"target report hid the configured directional path")
end)

Test.case("ordinary diagnostics and held positive unknown return or mismatched routes never submit a zero-target RPC",function()
    for _,mode in ipairs({"ordinary diag","positive","unknown","return","changed chest","wrong colony"}) do
        local f=heldTargetFixture(mode=="positive" and 1 or mode=="unknown" and nil or 0)
        local pending=f.m.store.data.master.pendingTransfer
        if mode=="unknown" then pending.reported=nil end
        if mode=="return" then pending.kind="import" end
        if mode=="changed chest" then f.m.config.colonies[1].deliveryChest="changed" end
        if mode=="wrong colony" then f.m.config.colonies[1].id=3 end
        f.spy("exportItemToPeripheral",function() error("nonzero/unknown or unmatched route submitted an inspection RPC",0) end)
        local report=f.capture(mode=="ordinary diag");Test.equal(#f.calls,0)
        assert(report:find("ORIGINAL_EXPORT_ERROR",1,true))
    end
end)
return true
