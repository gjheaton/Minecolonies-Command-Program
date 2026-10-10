local S=require("tests.support")
local D=require("tests.display_support")
local Config=require("colony.network.config")
local Telemetry=require("colony.network.telemetry")
local Protocol=require("colony.network.protocol")

local function fixture()
    local w=S.world();local master=S.computer(w,1,"master");local source=S.computer(w,2,"supply")
    master.config.colonies={D.route(2),D.route(3)}
    local view={role="supply",programVersion="4.0.0",colonyName="Alpha",masterId=1,status="waiting",requests={},history={},errors={},
        settings=Config.defaults("supply"),health={ok=true,connected=true,detail="Waiting for master",checks={}}}
    view.settings.masterId=1
    local count={sourceSnapshots=0}
    source.engine={snapshot=function() count.sourceSnapshots=count.sourceSnapshots+1;return view end}
    master.engine={snapshot=function() error("Master telemetry requested a fresh domain snapshot") end}
    w.at(1,function() master.telemetry=Telemetry.new(master.config,master.store,master.io,master.engine) end)
    w.at(2,function() source.telemetry=Telemetry.new(source.config,source.store,source.io,source.engine) end)
    master.handler=master.telemetry.onMessage;source.handler=source.telemetry.onMessage
    local f={w=w,master=master,source=source,view=view,count=count}
    function f.publish() w.at(2,source.telemetry.tick);return assert(w.packet("telemetry",1)).message end
    function f.accept(message,sender) return w.at(1,master.telemetry.onMessage,sender or 2,message) end
    function f.get(id) return w.at(1,master.telemetry.get,id or 2) end
    return f
end

Test.case("telemetry starts waiting and master status reads never acquire inventory or persist cache",function()
    local f=fixture();local before=textutils.serialize(f.master.store.data)
    local waiting=f.get();Test.equal(waiting.telemetry.state,"waiting");Test.equal(#waiting.requests,0)
    assert(f.get(99)==nil)
    for _=1,3 do f.w.at(1,f.master.telemetry.tick);f.get();f.master.telemetry.status() end
    Test.equal(f.count.sourceSnapshots,0)
    Test.equal(textutils.serialize(f.master.store.data),before)
    Test.equal(#f.w.callsFor(nil,true),0)
    local refreshes=0;for _,packet in ipairs(f.w.sent) do if packet.message.kind=="telemetry_request" then refreshes=refreshes+1 end end
    Test.equal(refreshes,2,"master repeatedly refreshed idle dashboard routes")
end)

Test.case("telemetry reports compact bounded rows, explicit totals, latest events and sanitized fields",function()
    local f=fixture();f.source.config.telemetryMaxRequests=3;f.source.config.telemetryHistoryEntries=2;f.source.config.telemetryErrorEntries=1
    f.master.config.telemetryMaxRequests=3;f.master.config.telemetryHistoryEntries=2;f.master.config.telemetryErrorEntries=1
    for i=1,8 do f.view.requests[i]={id="R"..i,name="minecraft:stone",status="requested",requested=i,detail="line\000break\n"..string.rep("x",700),
        raw={private="private-raw-data"},secret="private-row-secret"} end
    for i=1,5 do f.view.history[i]={kind="IMPORT",time=i,message="event-"..i,context={item={name="minecraft:stone"},count=i,secret="private-context-secret"}} end
    for i=1,3 do f.view.errors[i]={code="FAULT"..i,time=i,message="fault-"..i,context={expected=4,secret="private-error-secret"}} end
    f.view.settings.secret="private-setting-secret";f.view.intent={secret="private-intent-secret"}
    local message=f.publish();assert(Protocol.valid(message))
    local snapshot=message.snapshot
    Test.equal(snapshot.programVersion,"4.0.0")
    Test.equal(#snapshot.requests,3);Test.equal(snapshot.totals.requests,8);Test.equal(snapshot.shown.requests,3);Test.equal(snapshot.truncated.requests,5)
    Test.equal(#snapshot.history,2);Test.equal(snapshot.history[1].message,"event-4");Test.equal(snapshot.history[2].message,"event-5")
    Test.equal(snapshot.errors[1].code,"FAULT3");Test.equal(snapshot.truncated.history,3);Test.equal(snapshot.truncated.errors,2)
    assert(not snapshot.requests[1].detail:find("[%c]"));assert(#snapshot.requests[1].detail<=512)
    assert(not textutils.serialize(snapshot):find("private-",1,true),"unbounded raw state leaked into dashboard packet")
    assert(f.accept(message));local cached=f.get()
    Test.equal(cached.totals.requests,8);Test.equal(cached.truncated.requests,5)
    Test.equal(#f.w.callsFor(nil,true),0)
end)

Test.case("duplicate, reordered, unknown and retired telemetry cannot refresh stale cached state",function()
    local f=fixture();local first=f.publish();assert(f.accept(first))
    local received=f.get().telemetry.receivedAt
    f.w.advance(f.master.config.telemetryStaleSeconds+1)
    assert(not f.accept(first));Test.equal(f.get().telemetry.receivedAt,received);Test.equal(f.get().telemetry.state,"stale")
    local unknown=S.copy(first);unknown.sequence=99;assert(not f.accept(unknown,99))
    Test.equal(f.get().telemetry.receivedAt,received)
    local fresh=S.copy(first);fresh.sequence=2;fresh.generatedAt=f.w.now;fresh.snapshot.colonyName="Alpha new";assert(f.accept(fresh))
    Test.equal(f.get().telemetry.state,"online");Test.equal(f.get().colonyName,"Alpha new")
    assert(not f.accept(first));Test.equal(f.get().telemetry.sequence,2)
    local reboot=S.copy(fresh);reboot.bootId="2:100000:2";reboot.sequence=1;assert(f.accept(reboot))
    assert(not f.accept(fresh),"retired boot sequence accepted")
    local older=S.copy(reboot);older.bootId="2:100000:0";older.sequence=999;assert(not f.accept(older),"older unobserved boot accepted")
    Test.equal(f.get().telemetry.bootId,reboot.bootId)
    Test.equal(f.master.telemetry.status().cachedColonies,1)
end)

Test.case("dashboard ages use receipt time and configured stale and offline deadlines",function()
    local f=fixture();Test.equal(f.master.config.telemetryStaleSeconds,20);Test.equal(f.master.config.telemetryOfflineSeconds,60)
    f.master.config.telemetryOfflineSeconds=75
    local message=f.publish();message.generatedAt=f.w.now+1000000;assert(f.accept(message))
    f.w.advance(21);Test.equal(f.get().telemetry.state,"stale")
    f.w.advance(53);Test.equal(f.get().telemetry.state,"stale")
    f.w.advance(2);Test.equal(f.get().telemetry.state,"offline")
    Test.equal(f.get().telemetry.age,76)
    assert(f.get().offline and f.get().stale)
end)

Test.case("refresh message floods cannot trigger extra snapshots, inventory calls or persistence",function()
    local f=fixture();f.publish();local before=textutils.serialize(f.source.store.data)
    for _=1,100 do assert(f.w.at(2,f.source.telemetry.onMessage,1,{kind="telemetry_request",version=1})) end
    assert(not f.w.at(2,f.source.telemetry.onMessage,99,{kind="telemetry_request",version=1}))
    Test.equal(f.count.sourceSnapshots,1)
    f.w.at(2,f.source.telemetry.tick);Test.equal(f.count.sourceSnapshots,1)
    f.w.advance(f.source.config.telemetryIntervalSeconds);f.publish();Test.equal(f.count.sourceSnapshots,2)
    Test.equal(textutils.serialize(f.source.store.data),before)
    Test.equal(#f.w.callsFor(nil,true),0)
end)

Test.case("telemetry cache is detached from callers and forbids hardware or display policy propagation",function()
    local f=fixture();f.view.requests={S.request("R","minecraft:stone",4)}
    f.view.effectivePolicy={maxRequestsPerTurn=2,masterId=9,colonyBridgeName="replacement",monitorName="stolen-screen",monitorTextScale=5,
        telemetryMaxRequests=1024}
    assert(f.accept(f.publish()));local cached=f.get()
    Test.equal(cached.effectivePolicy.maxRequestsPerTurn,2)
    assert(cached.effectivePolicy.masterId==nil and cached.effectivePolicy.colonyBridgeName==nil and cached.effectivePolicy.monitorName==nil
        and cached.effectivePolicy.monitorTextScale==nil and cached.effectivePolicy.telemetryMaxRequests==nil)
    cached.requests[1].name="modified";cached.settings.masterId=88
    Test.equal(f.get().requests[1].name,"minecraft:stone");Test.equal(f.get().settings.masterId,1)
end)

Test.case("maximum telemetry configuration remains inside protocol limits with explicit dropped counts",function()
    local f=fixture();f.source.config.telemetryMaxRequests=1024;f.source.config.telemetryHistoryEntries=200;f.source.config.telemetryErrorEntries=100
    for i=1,1024 do f.view.requests[i]={id="R"..i,name="minecraft:stone",displayName="Stone",status="requested",phase="requested",requested=64,shipped=32,
        imported=16,staged=16,detail=string.rep("x",600),firstSeen=1,lastSeen=2,lastResponse=3,phaseSince=4,craftStartedAt=5,deliveryStartedAt=6,completedAt=7,deadline=8} end
    for i=1,200 do f.view.history[i]={kind="EVENT",code="CODE",message=string.rep("y",600),severity="INFO",time=i,detail="details",item="minecraft:stone",count=64,
        context={requestId="R",shipmentId="D",colonyId=2,computerId=2,item="minecraft:stone",count=64,amount=64,reported=64,actualDelta=64,error="detail",kind="IMPORT",direction="IN",beforeChest=64,afterChest=0}} end
    for i=1,100 do f.view.errors[i]=S.copy(f.view.history[i]) end
    local message=f.publish();assert(Protocol.valid(message),"maximum dashboard packet exceeds protocol node budget")
    assert(message.snapshot.shown.requests<=1024)
    Test.equal(message.snapshot.totals.requests,1024)
    assert(type(message.snapshot.truncated)=="table" and message.snapshot.truncated.requests>0)
    Test.equal(message.snapshot.shown.requests+message.snapshot.truncated.requests,1024)
end)

Test.case("telemetry requires a durable boot identity and never silently starts after failed persistence",function()
    local f=fixture();f.source.store.save=function() return nil,"simulated lost journal write" end
    local ok,err=pcall(function() f.w.at(2,Telemetry.new,f.source.config,f.source.store,f.source.io,f.source.engine) end)
    assert(not ok and tostring(err):find("persist telemetry boot identity"))
    Test.equal(f.count.sourceSnapshots,0);Test.equal(#f.w.callsFor(nil,true),0)
end)

Test.case("removed telemetry routes cannot retain old cached dashboards or receive startup refreshes",function()
    local f=fixture();assert(f.accept(f.publish()))
    f.master.config.colonies={D.route(3)};f.w.at(1,f.master.telemetry.tick)
    assert(f.get(2)==nil);Test.equal(f.master.telemetry.status().cachedColonies,0)
    f.master.config.colonies={D.route(2),D.route(3)}
    Test.equal(f.get(2).telemetry.state,"waiting","re-added route reused another assignment's cached snapshot")
    f.w.at(1,f.master.telemetry.tick)
    local refresh=0;for _,packet in ipairs(f.w.sent) do if packet.to==2 and packet.message.kind=="telemetry_request" then refresh=refresh+1 end end
    Test.equal(refresh,1)
end)

return true
