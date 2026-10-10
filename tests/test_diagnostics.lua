local S=require("tests.support")
local Diagnostics=require("colony.network.diagnostics")
local function fixture()
    local w=S.world();local m=S.computer(w,1,"master");local c=S.computer(w,2,"supply")
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
return true
