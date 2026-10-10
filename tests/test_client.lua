local S=require("tests.support")
local function shipment(id,count,item)
    return {id=id or "D1",requestId="R1",item=item or {name="minecraft:stone"},count=count or 4,verified=true,createdAt=100}
end
local function response(status) return {{id="R1",status=status}} end

Test.case("colony drains only on next grant and completes only when MineColonies removes request",function()
    local w,c=S.clientFixture();w.grant(1)
    w.insert(w.channels.D2,{name="minecraft:stone"},4)
    local delivery=shipment();w.result(1,{delivery},response("in progress"))
    Test.equal(#w.callsFor("import",false),0,"result drained reserved chest")
    Test.equal(c.store.data.client.requests.R1.status,"in progress")
    w.grant(2,{delivery})
    Test.equal(#w.callsFor("import",false),1)
    Test.equal(w.packet("batch").message.imports.D1,4)
    Test.equal(c.store.data.client.requests.R1.status,"in progress","warehouse import completed MineColonies request")
    w.result(2,{delivery},response("in progress"))
    c.integrator.requests[1].count=1
    w.grant(3,{delivery});Test.equal(w.packet("batch").message.requests[1].totalCount,4)
    Test.equal(#w.callsFor("import",false),1,"same live request duplicated warehouse import")
    w.result(3,{delivery},response("in progress"))
    c.integrator.failed=true;w.grant(4,{delivery})
    assert(w.packet("batch").message.authoritative==false and w.packet("batch").message.activeIds==nil)
    Test.equal(c.store.data.client.requests.R1.status,"in progress","failed scan completed request")
    w.result(4,{delivery},response("in progress"));c.integrator.failed=false;c.integrator.requests={}
    w.grant(5,{delivery})
    Test.equal(c.store.data.client.requests.R1.status,"delivered")
    Test.equal(#c.engine.snapshot().requests,0)
end)

Test.case("duplicate grants and results do not replay colony imports",function()
    local w,c=S.clientFixture();local delivery=shipment()
    w.insert(w.channels.D2,{name="minecraft:stone"},4)
    w.grant(1,{delivery});w.grant(1,{delivery})
    Test.equal(#w.callsFor("import",false),1)
    w.result(1,{delivery},response("in progress"));w.result(1,{delivery},response("missing"))
    Test.equal(c.store.data.client.requests.R1.status,"in progress","duplicate result changed recorded outcome")
    Test.equal(#w.callsFor("import",false),1)
    c.restart();w.tick(2)
    Test.equal(#w.callsFor("import",false),1,"restart replayed completed import")
end)

Test.case("out-of-order grants and retired master sessions are rejected",function()
    local w,c=S.clientFixture();w.grant(10);w.result(10,{},response("missing"))
    assert(w.grant(9)==false);assert(w.grant(11,{},"new"))
    assert(w.grant(12,{},"S")==false,"retired session accepted")
    assert(w.result(10,{},response("crafting"),"S")==false,"stale result accepted")
    Test.equal(c.store.data.client.requests.R1.status,"missing")
    w.result(11,{},response("requested"),"new");assert(w.grant(10,{},"new")==false)
end)

Test.case("partial colony imports account cumulative quantities across turns",function()
    local w,c=S.clientFixture();local delivery=shipment();c.rs.importLimit=2
    w.insert(w.channels.D2,{name="minecraft:stone"},4)
    w.grant(1,{delivery});Test.equal(w.packet("batch").message.imports.D1,2)
    Test.equal(w.count(w.channels.D2,{name="minecraft:stone"}),2)
    w.result(1,{delivery},response("in progress"));w.grant(2,{delivery})
    Test.equal(w.packet("batch").message.imports.D1,4)
    Test.equal(w.count(w.channels.D2,{name="minecraft:stone"}),0)
    Test.equal(c.rs.items[w.identity({name="minecraft:stone"})].amount,4)
    Test.equal(c.store.data.client.requests.R1.status,"in progress")
end)

Test.case("delayed chest visibility verifies a single colony transfer",function()
    local w,c=S.clientFixture();c.rs.visibilityDelay=.4
    w.insert(w.channels.D2,{name="minecraft:stone"},4);w.grant(1,{shipment()})
    Test.equal(w.packet("batch").message.imports.D1,4)
    Test.equal(#w.callsFor("import",false),1)
    assert(c.store.data.client.fault==nil)
end)

Test.case("unverified colony import pauses and restart never replays mutation",function()
    local w,c=S.clientFixture();c.rs.phantomImport=true
    w.insert(w.channels.D2,{name="minecraft:stone"},4);w.grant(1,{shipment()})
    assert(c.store.data.client.intent and w.packet("batch").message.clientError)
    Test.equal(w.packet("batch").message.imports.D1,0)
    w.grant(1,{shipment()});c.restart();w.tick(2)
    Test.equal(#w.callsFor("import",false),1,"uncertain import retried")
    assert(not c.engine.canProbe())
end)

Test.case("journal failure before grant prevents all colony mutations",function()
    local w,c=S.clientFixture();w.insert(w.channels.D2,{name="minecraft:stone"},4)
    w.writeFail=true;local ok=pcall(w.grant,1,{shipment()});assert(not ok)
    Test.equal(#w.callsFor("import",false),0)
    Test.equal(w.count(w.channels.D2,{name="minecraft:stone"}),4)
end)

Test.case("bounded request selection rotates through every live request",function()
    local w,c=S.clientFixture();c.config.maxRequestsPerTurn=2;c.integrator.requests={}
    for i=1,5 do c.integrator.requests[i]=S.request("R"..i,"minecraft:stone",1) end
    local selected={}
    for turn=1,3 do
        w.grant(turn);local batch=w.packet("batch").message
        Test.equal(#batch.requests,2);Test.equal(#batch.activeIds,5)
        for _,request in ipairs(batch.requests) do selected[request.id]=true end
        w.result(turn)
    end
    for i=1,5 do assert(selected["R"..i],"live request never received a turn") end
end)

Test.case("overflow preserves items acceptable to a live equipment request",function()
    local w,c=S.clientFixture();c.config.overflowEnabled=true;c.config.defaultItemKeep=0;c.config.buildingItemKeep=0
    c.integrator.requests={{id="R1",name="Pickaxe",count=1,items={{name="minecraft:iron_pickaxe",count=1}}}}
    c.rs.add({name="minecraft:diamond_pickaxe",maxCount=1},5);c.rs.add({name="minecraft:dirt"},3)
    w.grant(1)
    Test.equal(w.count(w.channels.R2,{name="minecraft:dirt"}),3)
    Test.equal(w.count(w.channels.R2,{name="minecraft:diamond_pickaxe"}),0)
    Test.equal(c.rs.items[w.identity({name="minecraft:diamond_pickaxe"})].amount,5)
end)

Test.case("separate configurable craft and delivery deadlines retain quantities",function()
    local w,c=S.clientFixture();c.config.craftingTimeoutSeconds=7;c.config.onHandTimeoutSeconds=2
    w.grant(1);w.result(1,{},response("crafting"));w.advance(3);w.tick(2)
    Test.equal(c.store.data.client.requests.R1.status,"crafting")
    w.advance(4);w.tick(2);Test.equal(c.store.data.client.requests.R1.status,"timed out")
    w.grant(2);w.result(2,{},response("in progress"));w.advance(2);w.tick(2)
    Test.equal(c.store.data.client.requests.R1.status,"timed out")
    Test.equal(c.store.data.client.requests.R1.totalCount,4)
    Test.equal(#w.callsFor(nil,true),0)
end)

Test.case("client final accounting crash repairs retained import exactly once without repeating transfer",function()
    local w,c=S.clientFixture();w.insert(w.channels.D2,{name="minecraft:stone"},4)
    local save=c.store.save
    c.store.save=function()
        local state=c.store.data.client
        if not state.intent and state.shipments.D1 and state.shipments.D1.imported==4 then w.writeFail=true end
        return save()
    end
    local ok,err=pcall(w.grant,1,{shipment()});assert(not ok and tostring(err):find("Persistence failure"))
    Test.equal(#w.callsFor("import",false),1)
    Test.equal(w.count(w.channels.D2,{name="minecraft:stone"}),0)
    w.writeFail=false;c.restart();w.tick(2)
    assert(c.store.data.client.intent and c.store.data.client.intent.reported==4)
    Test.equal(c.store.data.client.shipments.D1.imported,0,"failed accounting falsely persisted import")
    w.result(1,{shipment()},response("error"))
    local repaired=w.at(2,c.engine.reconcile);assert(repaired)
    Test.equal(c.store.data.client.shipments.D1.imported,4)
    local again=w.at(2,c.engine.reconcile);assert(again)
    Test.equal(c.store.data.client.shipments.D1.imported,4,"second repair doubled imported ledger")
    Test.equal(#w.callsFor("import",false),1,"repair repeated source mutation")
    Test.equal(c.rs.items[w.identity({name="minecraft:stone"})].amount,4)
end)

Test.case("client restart with unknown import outcome remains paused despite an empty source chest",function()
    local w,c=S.clientFixture();w.insert(w.channels.D2,{name="minecraft:stone"},4)
    c.store.data.client.intent={kind="import",shipmentId="D1",item={name="minecraft:stone"},count=4,
        chest="delivery",beforeChest=4,beforeImported=0,startedAt=100}
    c.store.data.client.shipments.D1=shipment();c.store.data.client.shipments.D1.imported=0
    c.store.save();w.take(w.channels.D2,{name="minecraft:stone"},4)
    c.restart()
    local repaired,err=w.at(2,c.engine.reconcile)
    assert(not repaired and tostring(err):find("no reliable return value"))
    Test.equal(c.store.data.client.shipments.D1.imported,0)
    Test.equal(#w.callsFor("import",false),0)
end)

Test.case("completed shipment compaction waits for master receipt and ignores duplicate result",function()
    local w,c=S.clientFixture();local delivery=shipment();w.insert(w.channels.D2,{name="minecraft:stone"},4)
    w.grant(1,{delivery});w.result(1,{delivery},response("in progress"))
    assert(c.store.data.client.shipments.D1,"active imported shipment prematurely pruned")
    c.integrator.requests={};w.grant(2,{delivery})
    Test.equal(w.packet("batch").message.imports.D1,4)
    assert(c.store.data.client.shipments.D1,"receipt omitted before master completion")
    w.result(2,{delivery},response("delivered"));assert(c.store.data.client.shipments.D1==nil)
    w.result(2,{delivery},response("delivered"));assert(c.store.data.client.shipments.D1==nil,"duplicate result resurrected shipment")
    assert(c.store.data.client.requests.R1~=nil)
    c.config.requestRetentionSeconds=60;w.advance(61)
    w.grant(3);w.result(3);assert(c.store.data.client.requests.R1==nil,"expired completed ledger retained")
    Test.equal(#w.callsFor("import",false),1)
end)

Test.case("completed requests with partially imported deliveries survive retention pruning",function()
    local w,c=S.clientFixture();local delivery=shipment(nil,8)
    c.config.maxImportsPerTurn=2;c.config.requestRetentionSeconds=60
    w.insert(w.channels.D2,{name="minecraft:stone"},8)
    w.grant(1,{delivery});w.result(1,{delivery},response("in progress"))
    c.integrator.requests={};w.grant(2,{delivery});w.result(2,{delivery},response("delivered"))
    w.advance(61);w.grant(3,{delivery});w.result(3,{},response("delivered"))
    assert(c.store.data.client.requests.R1~=nil)
    assert(c.store.data.client.shipments.D1~=nil)
    Test.equal(c.store.data.client.shipments.D1.imported,6)
    Test.equal(w.count(w.channels.D2,{name="minecraft:stone"}),2)
end)

Test.case("a bridge NOT_CONNECTED return survives the client intent journal and restart without coercing unknown to zero or retrying",function()
    local w,c=S.clientFixture();local delivery=shipment();w.insert(w.channels.D2,{name="minecraft:stone"},4)
    local original=w.devices[2].crs.api.importItemFromPeripheral;local calls=0
    w.devices[2].crs.api.importItemFromPeripheral=function() calls=calls+1;return nil,"NOT_CONNECTED" end
    assert(w.grant(1,{delivery}))
    local intent=c.store.data.client.intent;assert(intent and intent.reported==nil)
    Test.equal(intent.callError,"NOT_CONNECTED");Test.equal(c.store.data.client.shipments.D1.imported,0)
    local event=c.store.data.errors[#c.store.data.errors]
    Test.equal(event.code,"TRANSFER_DESYNC");Test.equal(event.context.error,"NOT_CONNECTED");Test.equal(event.context.actualDelta,0)
    assert(w.packet("batch").message.clientError);Test.equal(w.packet("batch").message.imports.D1,0)
    w.devices[2].crs.api.importItemFromPeripheral=function(...) calls=calls+1;return original(...) end
    w.result(1,{delivery},response("error"));c.restart();w.tick(2)
    intent=c.store.data.client.intent;assert(intent and intent.reported==nil);Test.equal(intent.callError,"NOT_CONNECTED")
    local found=false
    for _,record in ipairs(c.store.data.errors) do
        if record.code=="TRANSFER_DESYNC" then found=true;Test.equal(record.context.error,"NOT_CONNECTED");Test.equal(record.context.actualDelta,0) end
    end
    assert(found);local repaired,err=w.at(2,c.engine.reconcile)
    assert(not repaired and tostring(err):find("no reliable return value",1,true))
    w.grant(2,{delivery});w.tick(2)
    Test.equal(calls,1);Test.equal(#w.callsFor("import",false),0)
    Test.equal(w.count(w.channels.D2,{name="minecraft:stone"}),4);Test.equal(c.store.data.client.shipments.D1.imported,0)
    assert(c.store.data.client.intent and c.store.data.client.fault)
end)

Test.case("a plain nil bridge result keeps the generic unknown error and remains held after restart",function()
    local w,c=S.clientFixture();local delivery=shipment();w.insert(w.channels.D2,{name="minecraft:stone"},4)
    local calls=0;w.devices[2].crs.api.importItemFromPeripheral=function() calls=calls+1;return nil end
    w.grant(1,{delivery});Test.equal(c.store.data.client.intent.callError,"Transfer result unknown")
    Test.equal(c.store.data.errors[#c.store.data.errors].context.error,"Transfer result unknown")
    w.result(1,{delivery},response("error"));c.restart();w.tick(2)
    local repaired,err=w.at(2,c.engine.reconcile);assert(not repaired and tostring(err):find("no reliable return value",1,true))
    Test.equal(calls,1);Test.equal(c.store.data.client.shipments.D1.imported,0)
    Test.equal(w.count(w.channels.D2,{name="minecraft:stone"}),4)
end)

Test.case("a definite zero with a bridge detail accounts nothing without an unknown intent and a later granted positive import accounts once",function()
    local w,c=S.clientFixture();local delivery=shipment();w.insert(w.channels.D2,{name="minecraft:stone"},4)
    local api=w.devices[2].crs.api;local original=api.importItemFromPeripheral;local calls=0
    api.importItemFromPeripheral=function() calls=calls+1;return 0,"INVALID_TARGET" end
    w.grant(1,{delivery})
    assert(c.store.data.client.intent==nil and c.store.data.client.fault==nil)
    Test.equal(w.packet("batch").message.imports.D1,0);Test.equal(w.count(w.channels.D2,{name="minecraft:stone"}),4)
    w.result(1,{delivery},response("in progress"))
    api.importItemFromPeripheral=function(...) calls=calls+1;return original(...) end
    w.grant(2,{delivery});Test.equal(w.packet("batch").message.imports.D1,4)
    w.grant(2,{delivery});Test.equal(calls,2);Test.equal(#w.callsFor("import",false),1)
    assert(c.store.data.client.intent==nil and c.store.data.client.fault==nil)
    Test.equal(w.count(w.channels.D2,{name="minecraft:stone"}),0);Test.equal(c.rs.items[w.identity({name="minecraft:stone"})].amount,4)
end)
return true
