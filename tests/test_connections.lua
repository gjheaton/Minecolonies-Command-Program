local S=require("tests.support")
local D=require("tests.display_support")
local Config=require("colony.network.config")
local Store=require("colony.network.store")
local Protocol=require("colony.network.protocol")

local function pair()
    local w=D.world();local master=S.computer(w,1,"master");local client=S.computer(w,2,"supply")
    master.config.automationEnabled=false;client.config.helloSeconds=5;client.config.messageTimeoutSeconds=30
    master.config.colonies={{id=2,label="Clockwork",deliveryChest="master-delivery",returnChest="master-return",
        deliveryChannel=client.config.deliveryChannel,returnChannel=client.config.returnChannel}}
    local reads=0
    for _,chest in ipairs({{1,"master-delivery",client.config.deliveryChannel},{1,"master-return",client.config.returnChannel},
        {2,"delivery",client.config.deliveryChannel},{2,"returns",client.config.returnChannel}}) do
        local _,api=w.chest(table.unpack(chest));local originalList=api.list
        api.list=function() reads=reads+1;return originalList() end
    end
    master.rs=w.bridge(1,"prs",true);client.rs=w.bridge(2,"crs",false);client.integrator=w.integrator(2,"integrator")
    client.integrator.requests={S.request("LIVE","minecraft:stone",4)}
    local integrator=w.devices[2].integrator.api;local originalRequests=integrator.getRequests
    integrator.getRequests=function() reads=reads+1;return originalRequests() end
    master.start();client.start()
    function w.step(seconds)
        w.tick(2);w.flush();w.tick(1);w.flush();w.advance(seconds or 1)
    end
    function w.reads() return reads end
    return w,master,client
end
local function ack(confirmed,enabled,errorMessage)
    return {kind="hello_ack",version=1,routeConfirmed=confirmed,automationEnabled=enabled,error=errorMessage}
end

Test.case("paused master keeps a colony connected through five-second hellos without granting turns or touching stored items",function()
    local w,m,c=pair();w.step()
    c.store.data.client.requests.KEEP={id="KEEP",count=2,totalCount=2,active=true,phase="in progress",status="in progress",phaseSince=w.now}
    c.store.data.client.shipments.HELD={id="HELD",requestId="KEEP",item={name="minecraft:stone"},count=2,imported=0}
    c.store.save();c.store.save()
    local state=c.store.data.client;local before=textutils.serialize(state);local files={c.store.path..".a",c.store.path..".b"}
    local first,second=w.files[files[1]],w.files[files[2]]
    local master=m.store.data.master.colonies["2"];local requests=textutils.serialize(master.requests);local shipments=textutils.serialize(master.shipments)
    for _=1,65 do w.step() end
    local snapshot=w.at(2,c.engine.snapshot)
    assert(snapshot.health.connected and snapshot.health.ok,"normal paused master lost connection despite regular acknowledgements")
    Test.equal(snapshot.health.automationEnabled,false);Test.equal(snapshot.health.routeConfirmed,true)
    assert(snapshot.health.detail:find("automation paused",1,true))
    Test.equal(textutils.serialize(state),before);Test.equal(w.files[files[1]],first);Test.equal(w.files[files[2]],second)
    Test.equal(textutils.serialize(master.requests),requests);Test.equal(textutils.serialize(master.shipments),shipments)
    assert(not master.turn and not m.store.data.master.pendingTransfer and not state.turn and not state.intent)
    local received=0
    for _,packet in ipairs(w.sent) do
        assert(packet.message.kind~="turn" and packet.message.kind~="batch" and packet.message.kind~="result","connection keepalive started a supply turn")
        if packet.message.kind=="hello_ack" then received=received+1;Test.equal(packet.to,2) end
    end
    assert(received>=13);Test.equal(w.reads(),0);Test.equal(#w.calls,0)
end)

Test.case("only well-formed acknowledgements from the configured master can refresh client connection state",function()
    local w,c=S.clientFixture();c.config.messageTimeoutSeconds=13;c.store.save();local before=textutils.serialize(c.store.data)
    local files=textutils.serialize(w.files);local sent=#w.sent
    assert(not w.at(2,c.engine.onMessage,99,ack(true,false)))
    for _,message in ipairs({{kind="hello_ack",version=2,routeConfirmed=true,automationEnabled=false},
        {kind="hello_ack",version=1,routeConfirmed="true",automationEnabled=false},
        {kind="hello_ack",version=1,routeConfirmed=true,automationEnabled=0},
        {kind="hello_ack",version=1,routeConfirmed=true},
        ack(false,false,{}),ack(false,false,string.rep("x",513)),
        {kind="hello_ack",routeConfirmed=true,automationEnabled=false}}) do
        assert(not w.at(2,c.engine.onMessage,1,message));assert(not c.engine.snapshot().health.connected)
    end
    local valid=ack(true,false);valid.session="malicious-session";valid.turn=42
    valid.deliveries={{id="FORGED",requestId="R1",item={name="minecraft:stone"},count=4,verified=true}}
    assert(w.at(2,c.engine.onMessage,1,valid));assert(c.engine.snapshot().health.connected)
    Test.equal(textutils.serialize(c.store.data),before);Test.equal(textutils.serialize(w.files),files);Test.equal(#w.sent,sent)
    assert(not c.store.data.client.turn and not c.store.data.client.shipments.FORGED)
    w.advance(14);assert(not w.at(2,c.engine.onMessage,99,ack(true,false)))
    assert(not c.engine.snapshot().health.connected);Test.equal(#w.calls,0)
end)

Test.case("channel mismatch acknowledgements prove connectivity but display an unhealthy route until a matching hello succeeds",function()
    local w,m,c=pair();c.config.deliveryChannel="wrong-channel";w.step()
    local first=w.at(2,c.engine.snapshot)
    assert(first.health.connected and not first.health.ok and first.health.routeConfirmed==false)
    assert(first.health.detail:find("color labels",1,true),"mismatched route lost the master's explanation")
    local monitor=w.monitor(2,"screen",100,38)
    local ui=w.at(2,require("colony.network.ui").new,c.config,c.store,c.engine,{monitor=function() return monitor,"screen" end})
    ui.view="health";w.at(2,ui.draw);assert(monitor.dump():find("color labels",1,true),"health screen hid the connected route mismatch")
    c.config.deliveryChannel=m.config.colonies[1].deliveryChannel;w.advance(5);w.step()
    local nextSnapshot=w.at(2,c.engine.snapshot)
    assert(nextSnapshot.health.connected and nextSnapshot.health.ok and nextSnapshot.health.routeConfirmed)
    assert(not nextSnapshot.health.detail:find("color labels",1,true));Test.equal(w.reads(),0);Test.equal(#w.calls,0)
end)

Test.case("connection acknowledgements cannot clear retained client faults and expire after the configured silence timeout",function()
    local w,c=S.clientFixture();c.config.messageTimeoutSeconds=7
    c.store.data.client.fault={code="IMPORT_UNCERTAIN",message="An import needs recovery"};c.store.save()
    local before=textutils.serialize(c.store.data);local files=textutils.serialize(w.files)
    assert(w.at(2,c.engine.onMessage,1,ack(true,false)))
    local view=c.engine.snapshot();assert(view.health.connected and not view.health.ok);Test.equal(view.health.detail,"An import needs recovery")
    Test.equal(textutils.serialize(c.store.data),before);Test.equal(textutils.serialize(w.files),files)
    w.advance(7);assert(c.engine.snapshot().health.connected);w.advance(.01);assert(not c.engine.snapshot().health.connected)
    assert(w.at(2,c.engine.onMessage,1,ack(true,true)));assert(c.engine.snapshot().health.connected)
    Test.equal(c.engine.snapshot().health.detail,"An import needs recovery");Test.equal(textutils.serialize(c.store.data),before)
    c.store.data.client.lastContact=w.now;c.store.save();c.restart()
    assert(not c.engine.snapshot().health.connected,"restarted client trusted a persisted historical connection timestamp")
    Test.equal(#w.calls,0)
end)

Test.case("master never acknowledges an unconfigured colony computer ID",function()
    local w,m=pair();local before=textutils.serialize(m.store.data);local sent=#w.sent
    assert(not w.at(1,m.engine.onMessage,3,{kind="hello",version=1,deliveryChannel="delivery-2",returnChannel="returns-2"}))
    Test.equal(#w.sent,sent);Test.equal(textutils.serialize(m.store.data),before);Test.equal(#w.calls,0)
end)

Test.case("a healthy master acknowledgement cannot erase an in-memory client persistence failure",function()
    local w,c=S.clientFixture();c.store.save();local originalSave=c.store.save
    c.store.save=function() return false,"simulated journal failure" end
    assert(not w.grant(1));local before=textutils.serialize(c.store.data);local files=textutils.serialize(w.files)
    assert(w.at(2,c.engine.onMessage,1,ack(true,false)))
    local view=c.engine.snapshot();assert(view.health.connected and not view.health.ok)
    assert(view.health.detail:find("Cannot persist supply state",1,true))
    Test.equal(textutils.serialize(c.store.data),before);Test.equal(textutils.serialize(w.files),files)
    Test.equal(#w.calls,0);c.store.save=originalSave
end)

local function actualRuntime(role,reserved,terminalOnly)
    local w,m,c=pair();local id=role=="master" and 1 or 2;local target=role=="master" and m or c
    target.config.pollIntervalSeconds=1;target.config.telemetryIntervalSeconds=5;target.config.updateCheckSeconds=604800
    local main
    if terminalOnly then target.config.monitorName="" else target.config.monitorName="main";main=w.monitor(id,"main",100,38) end
    Config.save(target.config)
    local journal=Store.new("/colony/"..role.."_v4_state",target.config)
    if reserved then journal.data.chestTest={token="held-connection-test",phase="inspect"};journal.save() end
    local Engine=require(role=="master" and "colony.network.master" or "colony.network.client")
    local originalNew=Engine.new;local messages={hello=0,hello_ack=0};local ticks,connectionReads=0,0
    Engine.new=function(...)
        local args={...};local engine=originalNew(...);target.engine=engine;target.store=args[2]
        local originalMessage,originalTick=engine.onMessage,engine.tick
        engine.onMessage=function(sender,message)
            if messages[message.kind]~=nil then messages[message.kind]=messages[message.kind]+1 end
            local before=w.reads();local calls=#w.calls;local result=originalMessage(sender,message)
            if message.kind=="hello" or message.kind=="hello_ack" then
                connectionReads=connectionReads+w.reads()-before
                Test.equal(#w.calls,calls,"connection dispatch invoked a bridge")
            end
            return result
        end
        engine.tick=function() ticks=ticks+1;return originalTick() end
        return engine
    end
    local oldParallel,oldSleep,oldPullEvent,oldPrint=parallel,sleep,os.pullEvent,print
    _G.sleep=function(seconds) return coroutine.yield("sleep",seconds) end
    local terminalOutput={}
    os.pullEvent=function() return coroutine.yield("event") end;_G.print=function(value) terminalOutput[#terminalOutput+1]=tostring(value) end
    local beginClient
    _G.parallel={waitForAll=function(receiver,processor)
        local receive,process=coroutine.create(receiver),coroutine.create(processor)
        local function resume(thread,...)
            local ok,kind,seconds=coroutine.resume(thread,...);assert(ok,kind);return kind,seconds
        end
        local function deliverAll()
            for _=1,100 do
                local packet=table.remove(w.queue,1);if not packet then return end
                if packet.to==id then
                    Test.equal(resume(receive,"rednet_message",packet.from,packet.message,packet.protocol),"event")
                else
                    local computer=w.computers[packet.to]
                    if computer then w.at(packet.to,computer.engine.onMessage,packet.from,packet.message) end
                end
            end
            error("runtime connection messages exceeded budget")
        end
        Test.equal(resume(receive),"event")
        beginClient=textutils.serialize(c.store.data.client)
        for _=1,45 do
            if role=="master" then w.tick(2) end
            -- Reservation keeps ordinary connection packets behind the same
            -- gate as other engine messages. Feed them without granting work.
            if reserved and role=="supply" then
                Test.equal(resume(receive,"rednet_message",1,ack(true,false),Protocol.NAME),"event")
            end
            deliverAll()
            local kind,seconds=resume(process);Test.equal(kind,"sleep")
            deliverAll();w.advance(seconds)
        end
    end}
    local ok,err=pcall(function() w.at(id,require("colony.network.runtime").run,role) end)
    Engine.new=originalNew;_G.parallel=oldParallel;_G.sleep=oldSleep;os.pullEvent=oldPullEvent;_G.print=oldPrint
    assert(ok,err)
    return {w=w,m=m,c=c,messages=messages,ticks=ticks,beginClient=beginClient,journal=journal,
        connectionReads=connectionReads,main=main,terminalOutput=terminalOutput}
end

Test.case("actual running paused master and colony runtimes exchange connection acknowledgements through their event receivers",function()
    for _,role in ipairs({"master","supply"}) do
        local f=actualRuntime(role);local view=f.w.at(2,f.c.engine.snapshot)
        assert(view.health.connected and view.health.ok and view.health.automationEnabled==false)
        assert(f.messages[role=="master" and "hello" or "hello_ack"]>=8,"runtime receiver did not dispatch connection messages to the engine")
        assert(f.ticks>=45)
        assert(not f.c.engine.snapshot().turn and not f.m.engine.snapshot().turn)
        -- Existing runtime health checks inspect chests while drawing. The
        -- connection dispatch itself never adds an inventory or bridge read.
        Test.equal(#f.w.calls,0);Test.equal(f.connectionReads,0)
        for _,packet in ipairs(f.w.sent) do assert(packet.message.kind~="turn" and packet.message.kind~="batch") end
    end
end)

Test.case("actual chest-test reservation keeps connection packets from invoking normal colony engine processing",function()
    local f=actualRuntime("supply",true)
    Test.equal(f.messages.hello_ack,0);Test.equal(f.ticks,0)
    assert(not f.c.engine.snapshot().health.connected)
    local saved=Store.new(f.journal.path,f.c.config);saved.load()
    assert(saved.data.chestTest and saved.data.chestTest.token=="held-connection-test")
    Test.equal(textutils.serialize(saved.data.client),f.beginClient)
    Test.equal(#f.w.calls,0);Test.equal(f.connectionReads,0)
end)

Test.case("actual connected paused colony runtime shows connection status on HOME HEALTH and the native keyboard screen",function()
    local f=actualRuntime("supply")
    assert(f.main.dump():find("Master connected; automation paused",1,true),"runtime HOME hid the healthy paused connection behind hardware checks")
    assert(table.concat(f.terminalOutput,"\n"):find("Master connected; automation paused",1,true),"attached monitor left the native keyboard screen without connection status")
    local view=f.w.at(2,f.c.engine.snapshot);assert(view.health.ok and next(view.health.checks))
    local ui=f.w.at(2,require("colony.network.ui").new,f.c.config,f.c.store,f.c.engine,{monitor=function() return f.main,"main" end})
    ui.view="health";f.w.at(2,ui.draw)
    assert(f.main.dump():find("Master connected; automation paused",1,true),"HEALTH displayed only healthy hardware and hid the master's state")
    local native=actualRuntime("supply",false,true)
    assert(native.w.terminal.dump():find("Master connected; automation paused",1,true),"native 51 by 19 HOME clipped the connection and paused status")
    Test.equal(#native.w.calls,0);Test.equal(native.connectionReads,0)
end)

return true
