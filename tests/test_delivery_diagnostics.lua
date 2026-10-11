local S=require("tests.support")
local Diagnostics=require("colony.network.diagnostics")

local function fixture(item,count,imported)
    local w,c=S.clientFixture()
    c.store.data.client.shipments["shipment-183"]={id="shipment-183",requestId="R-COMPOST",
        item=item or {name="minecolonies:compost",displayName="Compost"},
        count=count or 16,imported=imported or 0,verified=true}
    c.store.data.client.fault={code="DELIVERY_MISSING",message="A verified delivery is missing from its reserved chest",time=w.now}
    c.store.save()
    return w,c
end

local function inspect(w,c,id)
    local previousPrint,lines=print,{}
    _G.print=function(value) lines[#lines+1]=tostring(value) end
    local called,ok,reason=pcall(w.at,2,Diagnostics.printDelivery,c.config,c.io,c.store,id or "shipment-183")
    _G.print=previousPrint
    assert(called,ok)
    return ok,table.concat(lines,"\n"),reason
end

local function unchanged(w,c)
    local state=textutils.serialize(c.store.data,{allow_repetitions=true})
    local files=textutils.serialize(w.files)
    local calls=#w.calls
    local function forbidden() error("Read-only diagnostic attempted a write or RS operation",0) end
    c.store.save,c.store.error,c.store.event=forbidden,forbidden,forbidden
    c.io.importColony,c.io.exportColony,c.io.colonyStock,c.io.stock=forbidden,forbidden,forbidden,forbidden
    return function()
        Test.equal(textutils.serialize(c.store.data,{allow_repetitions=true}),state)
        Test.equal(textutils.serialize(w.files),files)
        Test.equal(#w.calls,calls)
    end
end

Test.case("delivery diagnostics identify a missing shipment without transferring or rewriting its hold",function()
    local w,c=fixture();local verify=unchanged(w,c)
    local ok,text=inspect(w,c)
    assert(ok and text:find("DELIVERY: shipment-183",1,true))
    assert(text:find("Item: minecolonies:compost",1,true) and text:find("Grid name: Compost",1,true))
    assert(text:find("Request: R-COMPOST",1,true))
    assert(text:find("Verified quantity: 16",1,true) and text:find("Imported quantity: 0",1,true))
    assert(text:find("Outstanding quantity: 16",1,true) and text:find("Configured delivery chest: delivery",1,true))
    assert(text:find("Exact chest quantity: 0",1,true) and text:find("Same-name quantity: 0",1,true))
    assert(text:find("Physical quantities do not credit imports or prove delivery",1,true))
    verify()
end)

Test.case("delivery diagnostics distinguish an exact physical NBT identity from same-name stacks",function()
    local item={name="minecraft:iron_hoe",nbt="physical-expected",displayName="Iron Hoe"}
    local w,c=fixture(item,4,1)
    w.insert(w.channels.D2,item,2)
    w.insert(w.channels.D2,{name=item.name,nbt="physical-other"},5)
    local verify=unchanged(w,c)
    local ok,text=inspect(w,c)
    assert(ok and text:find("Imported quantity: 1",1,true) and text:find("Outstanding quantity: 3",1,true))
    assert(text:find("Exact chest quantity: 2",1,true) and text:find("Same-name quantity: 7 (identity unverified)",1,true))
    assert(text:find("physical-expected",1,true) and text:find("physical-other",1,true))
    verify()
end)

Test.case("delivery diagnostics never label unreadable or throwing inventory as empty",function()
    for _,throws in ipairs({false,true}) do
        local w,c=fixture();local verify=unchanged(w,c)
        c.io.snapshot=function()
            if throws then error("inventory detached",0) end
            return nil,"inventory detached"
        end
        local ok,text=inspect(w,c)
        assert(not ok and text:find("BLOCKED: Cannot read the configured delivery chest: inventory detached",1,true))
        assert(not text:find("Exact chest quantity: 0",1,true))
        verify()
    end
end)

Test.case("delivery diagnostics require the exact existing colony shipment and valid retained quantities",function()
    local w,c=fixture();local verify=unchanged(w,c)
    c.io.snapshot=function() error("Invalid input caused a physical read",0) end
    for _,id in ipairs({"shipment-18","shipment-183-extra","",string.rep("x",257)}) do
        local ok,text=inspect(w,c,id);assert(not ok and text:find("BLOCKED:",1,true))
    end
    c.config.role="master"
    local ok,text=inspect(w,c);assert(not ok and text:find("colony supply computer",1,true))
    c.config.role="supply"
    verify()
    c.store.data.client.shipments["shipment-183"].imported=17
    ok,text=inspect(w,c);assert(not ok and text:find("invalid retained item or quantity data",1,true))
end)

Test.case("delivery diagnostics bound NBT output and describe remaining matching slots without mutations",function()
    local w,c=fixture({name="minecraft:iron_hoe",nbt="expected"},6)
    for index=1,6 do w.insert(w.channels.D2,{name="minecraft:iron_hoe",nbt=string.rep(tostring(index),300)},1) end
    local verify=unchanged(w,c)
    local ok,text=inspect(w,c)
    assert(ok and text:find("Exact chest quantity: 0",1,true) and text:find("Same-name quantity: 6",1,true))
    local _,slots=text:gsub("CC NBT:","")
    Test.equal(slots,4)
    assert(text:find("Additional matching slots: 2",1,true))
    assert(not text:find(string.rep("1",97),1,true),"slot NBT output exceeded its preview limit")
    verify()
end)

Test.case("new missing-delivery faults preserve the actual remaining shipment quantity and exact diagnostic ID",function()
    local w,c=S.clientFixture();c.rs.importLimit=2
    local delivery={id="shipment-183",requestId="R1",item={name="minecraft:stone"},count=6,imported=0,
        verified=true,createdAt=100}
    w.insert(w.channels.D2,delivery.item,6)
    w.grant(1,{delivery});w.result(1,{delivery},{{id="R1",status="in progress"}})
    Test.equal(c.store.data.client.shipments[delivery.id].imported,2)
    w.take(w.channels.D2,delivery.item,4)
    local calls=#w.callsFor("import",false)
    w.grant(2,{delivery})
    Test.equal(#w.callsFor("import",false),calls)
    Test.equal(c.store.data.client.fault.code,"DELIVERY_MISSING")
    local event=c.store.data.errors[#c.store.data.errors]
    Test.equal(event.code,"DELIVERY_MISSING")
    Test.equal(event.context.shipmentId,delivery.id)
    Test.equal(event.context.requestId,"R1")
    Test.equal(event.context.item,"minecraft:stone")
    Test.equal(event.context.chest,"delivery")
    Test.equal(event.context.expected,4)
    Test.equal(event.context.observed,0)
    local verify=unchanged(w,c)
    local ok,text=inspect(w,c,delivery.id)
    assert(ok and text:find("Outstanding quantity: 4",1,true) and text:find("Exact chest quantity: 0",1,true))
    verify()
end)
