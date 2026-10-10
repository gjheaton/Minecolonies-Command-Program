local S=require("tests.support")
local D=require("tests.display_support")
local Config=require("colony.network.config")
local Store=require("colony.network.store")

local function fixture(state)
    local w=D.world();local c=S.computer(w,1,"master")
    c.config.monitorName="main";c.config.colonies={D.route(2,"alpha"),D.route(3,"beta")};Config.save(c.config)
    local store=Store.new("/colony/master_v4_state",c.config)
    if state then store.data.master=state end
    store.save()
    _G.write=function() end;_G.read=function() error("unexpected interactive setup") end
    function w.run(...) return w.at(1,require("colony.network.runtime").run,"master",...) end
    return w,c,store
end

Test.case("monitor CLI changes display ownership while preserving retained transfer journals and settings",function()
    local w,c,store=fixture({pendingTransfer={kind="export",count=4},craftJobs={stone={state="timed out"}}})
    c.config.maxTransferChunk=7;Config.save(c.config)
    store.save();local first=w.files[store.path..".a"];local second=w.files[store.path..".b"]
    w.run("monitor","2","gamma")
    local config=Config.load("master");Test.equal(config.colonies[1].monitorName,"gamma")
    Test.equal(config.monitorName,"main");Test.equal(config.maxTransferChunk,7)
    Test.equal(config.colonies[1].deliveryChest,"D2");Test.equal(config.colonies[1].returnChannel,"returns-2")
    Test.equal(w.files[store.path..".a"],first);Test.equal(w.files[store.path..".b"],second)
    local before=w.files[Config.PATH]
    assert(not pcall(w.run,"monitor","2","beta"));Test.equal(w.files[Config.PATH],before)
    assert(not pcall(w.run,"monitor","2","main"));Test.equal(w.files[Config.PATH],before)
    w.run("monitor","2","none");Test.equal(Config.load("master").colonies[1].monitorName,"")
    Test.equal(w.files[store.path..".a"],first);Test.equal(w.files[store.path..".b"],second)
    Test.equal(#w.callsFor(nil,true),0)
end)

Test.case("monitor CLI lists assigned sizes without querying RS or altering configuration",function()
    local w=fixture()
    w.device(1,"main","monitor",D.surface(100,38));w.device(1,"alpha","monitor",D.surface(50,19))
    local before=textutils.serialize(w.files);local previousPrint,lines=print,{}
    _G.print=function(message) lines[#lines+1]=tostring(message) end
    local ok,err=pcall(w.run,"monitors");_G.print=previousPrint;assert(ok,err)
    local output=table.concat(lines,"\n")
    assert(output:find("main: 100 x 38",1,true) and output:find("overview",1,true))
    assert(output:find("alpha: 50 x 19",1,true) and output:find("colony 2",1,true))
    Test.equal(textutils.serialize(w.files),before);Test.equal(#w.callsFor(nil,true),0)
end)

Test.case("existing schema4 configuration loads fixed display scale and local telemetry defaults",function()
    local w,c=fixture();c.config.monitorTextScale=1;c.config.maxTransferChunk=7
    c.config.telemetryIntervalSeconds=nil;c.config.telemetryStaleSeconds=nil;c.config.telemetryOfflineSeconds=nil
    w.files[Config.PATH]=textutils.serialize(c.config)
    local loaded=Config.load("master")
    Test.equal(loaded.schema,4);Test.equal(loaded.monitorTextScale,.5);Test.equal(loaded.maxTransferChunk,7)
    Test.equal(loaded.telemetryIntervalSeconds,5);Test.equal(loaded.telemetryStaleSeconds,20);Test.equal(loaded.telemetryOfflineSeconds,60)
    local policy=Config.policy(loaded)
    for _,key in ipairs({"telemetryIntervalSeconds","telemetryStaleSeconds","telemetryOfflineSeconds","telemetryMaxRequests","telemetryHistoryEntries","telemetryErrorEntries"}) do
        assert(policy[key]==nil,"local display policy propagated to a colony")
        local route=D.route(2);route.overrides={[key]=loaded[key]}
        assert(not Config.setColony(loaded,route),"telemetry setting accepted as hardware policy override")
    end
end)

local function eventLoop(role,options)
    options=options or {}
    local w=D.world();local id=role=="master" and 1 or 2;local c=S.computer(w,id,role)
    c.config.monitorName="main";c.config.pollIntervalSeconds=1;c.config.telemetryIntervalSeconds=1
    if role=="master" then c.config.automationEnabled=false end
    local main=w.monitor(id,"main",100,38)
    local remote
    if role=="master" then
        c.config.colonies={D.route(2,"alpha")};remote=w.monitor(id,"alpha",100,38)
        for _,name in ipairs({"D2","R2"}) do w.chest(id,name,name) end
        c.rs=w.bridge(id,"prs",true)
    else
        c.rs=w.bridge(id,"crs",false);c.integrator=w.integrator(id,"integrator")
        w.chest(id,"delivery","delivery");w.chest(id,"returns","returns")
    end
    Config.save(c.config)
    local store=Store.new("/colony/"..role.."_v4_state",c.config)
    if options.reserved then store.data.chestTest={token="reserved-test",phase="inspect"};store.save() end
    local Engine=require(role=="master" and "colony.network.master" or "colony.network.client")
    local originalNew=Engine.new
    local count={engineTicks=0,engineTelemetryMessages=0}
    Engine.new=function(...)
        local engine=originalNew(...);local originalTick,originalMessage=engine.tick,engine.onMessage
        engine.tick=function()
            count.engineTicks=count.engineTicks+1
            if options.fault then error("simulated engine processor failure",0) end
            return originalTick()
        end
        engine.onMessage=function(sender,message)
            if message.kind=="telemetry" or message.kind=="telemetry_request" then count.engineTelemetryMessages=count.engineTelemetryMessages+1 end
            return originalMessage(sender,message)
        end
        return engine
    end
    local oldParallel,oldSleep,oldPullEvent,oldPrint=parallel,sleep,os.pullEvent,print
    _G.sleep=function(seconds) return coroutine.yield("sleep",seconds) end
    os.pullEvent=function() return coroutine.yield("event") end
    _G.print=function() end
    _G.parallel={waitForAll=function(receiver,processor)
        local receive,process=coroutine.create(receiver),coroutine.create(processor)
        local function resume(thread,...)
            local ok,kind,seconds=coroutine.resume(thread,...);assert(ok,kind);return kind,seconds
        end
        Test.equal(resume(receive),"event")
        for step=1,8 do
            local message
            if role=="master" then
                message={version=1,kind="telemetry",bootId="2:100000:1",sequence=step,generatedAt=w.now,
                    snapshot={role="supply",colonyName="Runtime colony "..step,requests={},history={},errors={},settings={},health={ok=true,connected=true,detail="Waiting"}}}
            else message={version=1,kind="telemetry_request"} end
            Test.equal(resume(receive,"rednet_message",role=="master" and 2 or 1,message,require("colony.network.protocol").NAME),"event")
            local kind,seconds=resume(process);Test.equal(kind,"sleep");w.advance(seconds)
        end
    end}
    local ok,err=pcall(function() w.at(id,require("colony.network.runtime").run,role) end)
    Engine.new=originalNew;_G.parallel=oldParallel;_G.sleep=oldSleep;os.pullEvent=oldPullEvent;_G.print=oldPrint
    assert(ok,err)
    return {w=w,c=c,store=store,main=main,remote=remote,count=count}
end

Test.case("actual paused runtime routes telemetry outside engine and refreshes colony displays without PRS calls",function()
    local f=eventLoop("master")
    assert(f.remote.dump():find("Runtime colony 8",1,true),"paused runtime did not refresh cached colony display")
    Test.equal(f.count.engineTelemetryMessages,0)
    Test.equal(#f.w.callsFor(nil,true),0,"paused dashboard acquired PRS inventory")
    for _,packet in ipairs(f.w.sent) do assert(packet.message.kind~="turn","paused runtime granted a supply turn") end
end)

Test.case("actual runtime receives display traffic while a chest test reserves all supply transfers",function()
    local f=eventLoop("master",{reserved=true})
    assert(f.remote.dump():find("Runtime colony 8",1,true))
    Test.equal(f.count.engineTicks,0);Test.equal(f.count.engineTelemetryMessages,0)
    Test.equal(#f.w.callsFor(nil,true),0)
    local saved=Store.new("/colony/master_v4_state",f.c.config);saved.load();assert(saved.data.chestTest)
end)

Test.case("actual stopped supply processor keeps publishing fresh telemetry that exposes the fault",function()
    local f=eventLoop("supply",{fault=true})
    Test.equal(f.count.engineTicks,1,"runtime repeated a stopped processor mutation")
    Test.equal(f.count.engineTelemetryMessages,0)
    local packets={};for _,packet in ipairs(f.w.sent) do if packet.message.kind=="telemetry" then packets[#packets+1]=packet end end
    Test.equal(#packets,8,"processor fault stopped display updates")
    local latest=packets[#packets].message
    assert(latest.snapshot.statusMessage:find("Processor stopped",1,true));assert(latest.snapshot.health.ok==false)
    Test.equal(#f.w.callsFor(nil,false),0,"fault telemetry acquired new colony inventory")
    local master=S.computer(f.w,1,"master");master.config.monitorName="master-main";master.config.colonies={D.route(2,"remote")}
    f.w.monitor(1,"master-main",100,38);local remote=f.w.monitor(1,"remote",100,38)
    local engine={snapshot=function() return {role="master",requests={},colonies={},health={ok=true}} end,busy=function() return false end}
    local telemetry=f.w.at(1,require("colony.network.telemetry").new,master.config,master.store,master.io,engine)
    assert(f.w.at(1,telemetry.onMessage,2,latest))
    local manager=f.w.at(1,require("colony.network.displays").new,master.config,master.store,engine,master.io,nil,telemetry)
    f.w.at(1,manager.draw)
    assert(remote.dump():find("ONLINE",1,true) and remote.dump():find("Processor stopped",1,true),"fresh fault snapshot hid stopped processor")
end)

return true
