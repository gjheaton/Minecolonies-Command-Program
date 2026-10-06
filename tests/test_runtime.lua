local S=require("tests.support")
local Config=require("colony.network.config")
local Store=require("colony.network.store")
local function fixture(role,state)
    local w=S.world();local c=S.computer(w,1,role or "master");Config.save(c.config)
    local store=Store.new("/colony/"..c.config.role.."_v4_state",c.config);store.data=S.copy(state or {schema=4,revision=0,history={},errors={}})
    store.data.history=store.data.history or {};store.data.errors=store.data.errors or {};store.save()
    w.rs=w.bridge(1,role=="supply" and "crs" or "prs",role~="supply")
    _G.write=function() end;_G.read=function() error("unexpected interactive setup") end
    -- Setup/set execute the real runtime before entering its event loop.
    local Runtime=require("colony.network.runtime")
    function w.run(...) return w.at(1,Runtime.run,c.config.role,...) end
    return w,c,store
end

Test.case("runtime setup refuses retained turn, craft, shipment and chest test before prompting",function()
    for _,state in ipairs({
        {master={colonies={["2"]={turn={phase="WAIT_BATCH"}}}}},
        {master={craftJobs={stone={state="timed out"}}}},
        {master={colonies={["2"]={shipments={{count=4,imported=2}}}}}},
        {chestTest={token="retained",phase="export_intent"}},
    }) do
        local w=fixture("master",state)
        local configBefore=w.files[Config.PATH]
        local ok,err=pcall(w.run,"setup");assert(not ok and tostring(err):find("retained turns"))
        Test.equal(w.files[Config.PATH],configBefore)
        Test.equal(#w.callsFor(nil,true),0)
    end
end)

Test.case("runtime typed settings permit policy changes but reject hardware changes with retained work",function()
    local w=fixture("master",{master={pendingTransfer={kind="export",count=4}}})
    local ok,err=pcall(w.run,"set","playerBridgeName","replacement")
    assert(not ok and tostring(err):find("Retained work prevents"))
    w.run("set","craftingTimeoutSeconds","900");w.run("set","autoCraftEnabled","false")
    local config=Config.load("master");Test.equal(config.craftingTimeoutSeconds,900);Test.equal(config.autoCraftEnabled,false)
    Test.equal(config.playerBridgeName,"prs");Test.equal(#w.callsFor(nil,true),0)
end)

Test.case("runtime rejects invalid numeric and boolean values without changing persisted config",function()
    local w=fixture("master");local before=w.files[Config.PATH]
    for _,args in ipairs({{"set","maxTransferChunk","0"},{"set","autoCraftEnabled","yes"},{"set","masterId","4"}}) do
        local ok=pcall(w.run,table.unpack(args));assert(not ok)
        Test.equal(w.files[Config.PATH],before,"invalid CLI setting modified configuration")
    end
    Test.equal(#w.callsFor(nil,true),0)
end)

Test.case("runtime supply hardware changes are blocked by an interrupted import",function()
    local w=fixture("supply",{client={intent={kind="import",count=4,reported=4}}})
    local ok,err=pcall(w.run,"set","masterId","9");assert(not ok and tostring(err):find("Retained work prevents"))
    w.run("set","onHandTimeoutSeconds","180")
    local config=Config.load("supply");Test.equal(config.masterId,1);Test.equal(config.onHandTimeoutSeconds,180)
    Test.equal(#w.callsFor(nil,true),0)
end)

local function recoveryFixture()
    local w,c,store=fixture("master")
    c.config.colonyResponseTimeoutSeconds=3;c.config.helloSeconds=1
    c.config.colonies={
        {id=2,deliveryChest="D2",returnChest="R2",deliveryChannel="red-white-blue",returnChannel="red-white-black"},
        {id=3,deliveryChest="D3",returnChest="R3",deliveryChannel="yellow-white-blue",returnChannel="yellow-white-black"},
    }
    Config.save(c.config)
    for _,name in ipairs({"D2","R2","D3","R3"}) do w.chest(1,name,name) end
    local request=S.request("R2","minecraft:stone",4)
    local candidate=c.matcher.requestCandidates(request)[1]
    local variant=w.rs.add({name="minecraft:stone"},8)
    local record={id="R2",generation=1,requested=4,status="error",errorCode="PRS_QUARANTINE",createdAt=90,request=request}
    store.data.master={sessionCounter=1,turnCounter=1,shipmentCounter=0,
        colonies={["2"]={id=2,requests={R2=record},shipments={}},["3"]={id=3,requests={},shipments={}}},
        pendingTransfer={kind="export",colonyId=2,requestId="R2",generation=1,chest="D2",
            item={name=variant.name,fingerprint=variant.fingerprint},candidate=candidate,variant=variant,
            count=4,before=0,reported=0,session="master-1",turn=1,startedAt=90,verifySeconds=1,pollSeconds=.1,
            definiteZero=true,lastDelta=0,uncertain=true},
        quarantine={code="TRANSFER_VERIFY",message="PRS reported stock but exported zero; possible desync"},craftJobs={},
    }
    store.save()
    function w.hello()
        w.queue[#w.queue+1]={from=2,to=1,protocol=require("colony.network.protocol").NAME,
            message={version=1,kind="hello",role="supply",deliveryChannel="red-white-blue",returnChannel="red-white-black"}}
    end
    function w.reloaded()
        local saved=Store.new("/colony/master_v4_state",c.config);saved.load();return saved.data.master
    end
    return w,c,store
end

Test.case("CLI reconciliation confirms live colony and verifies one guarded probe without granting normal turns",function()
    local w=recoveryFixture();w.hello();w.run("reconcile")
    local state=w.reloaded()
    Test.equal(#w.callsFor("export",true),1,"CLI reconciliation repeated probe mutation")
    Test.equal(w.callsFor("export",true)[1].chest,"D2")
    Test.equal(w.callsFor("export",true)[1].filter.count,1)
    assert(state.pendingTransfer==nil and state.quarantine==nil)
    assert(state.colonies["2"].turn==nil,"verified CLI recovery retained internal turn")
    Test.equal(#state.colonies["2"].shipments,1)
    Test.equal(state.colonies["2"].shipments[1].count,1)
    Test.equal(w.count(w.channels.D2,{name="minecraft:stone"}),1)
    Test.equal(w.count(w.channels.D3,{name="minecraft:stone"}),0)
    for _,packet in ipairs(w.sent) do assert(packet.message.kind~="turn","CLI reconciliation granted a normal supply turn") end
end)

Test.case("CLI reconciliation waits a bounded interval for offline colony without any PRS mutation",function()
    local w,c=recoveryFixture();local started=w.now;w.run("reconcile")
    Test.equal(w.now-started,c.config.colonyResponseTimeoutSeconds)
    Test.equal(#w.callsFor("export",true),0)
    Test.equal(#w.callsFor("import",true),0)
    local state=w.reloaded();assert(state.pendingTransfer and state.quarantine)
    Test.equal(#state.colonies["2"].shipments,0)
end)
return true
