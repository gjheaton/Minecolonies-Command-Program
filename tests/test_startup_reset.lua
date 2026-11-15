local S = require("tests.support")

local function fixture()
    local w = S.world()
    local m = S.computer(w, 1, "master")
    m.rs = w.bridge(1, "prs", true)
    m.config.colonies = {}
    for _, id in ipairs({2, 4}) do
        local c = S.computer(w, id, "supply")
        c.config.deliveryChannel, c.config.returnChannel = "D"..id, "R"..id
        w.chest(id, "delivery", "D"..id); w.chest(id, "returns", "R"..id)
        w.chest(1, "delivery-"..id, "D"..id); w.chest(1, "returns-"..id, "R"..id)
        c.rs = w.bridge(id, "crs", false)
        c.integrator = w.integrator(id, "integrator")
        c.integrator.requests = {S.request("R"..id, "minecraft:stone", 4)}
        m.config.colonies[#m.config.colonies+1] = {id=id, label="Colony "..id,
            deliveryChest="delivery-"..id, returnChest="returns-"..id,
            deliveryChannel="D"..id, returnChannel="R"..id}
        c.start()
    end
    m.start()
    function w.step()
        w.tick(1); w.tick(2); w.tick(4); w.flush(); w.advance(.25)
    end
    function w.untilTrue(predicate)
        for _=1,160 do if predicate() then return end; w.step() end
        assert(predicate(), "startup handshake did not make progress")
    end
    return w, m
end

Test.case("Master-only restart releases both live Supply reservations", function()
    local w, m = fixture()
    w.drop.batch = 10000
    w.untilTrue(function()
        local a, b = w.computers[2].store.data.client.turn, w.computers[4].store.data.client.turn
        return a and b and a.phase=="waiting" and b.phase=="waiting"
    end)
    w.advance(1)
    m.restart()
    w.drop.batch = 0
    w.untilTrue(function()
        for _, id in ipairs({2,4}) do
            local cs = m.store.data.master.colonies[tostring(id)]
            if not (cs and cs.requests["R"..id]) then return false end
        end
        return true
    end)
end)

Test.case("fully imported requests become acknowledgement errors after ten minutes without resupply",function()
    local w,m=fixture()
    w.untilTrue(function()
        local cs=m.store.data.master.colonies["4"]
        return cs and cs.requests.R4~=nil
    end)
    -- The current deployment's external RS importer owns chest -> CRS moves.
    -- Seed its confirmed cumulative receipt, rather than simulate a CRS export.
    local shipment={id="ACK1",requestId="R4",generation=1,count=4,imported=4,
        verified=true,item={name="minecraft:stone"},crsBaseline=0}
    m.store.data.master.colonies["4"].shipments={S.copy(shipment)}
    w.computers[4].store.data.client.shipments.ACK1=S.copy(shipment)
    w.at(1,m.engine.snapshot);w.tick(4)
    local record=m.store.data.master.colonies["4"].requests.R4
    assert(record.fullyImportedAt)
    local exports=#w.callsFor("export",true)
    w.now=record.fullyImportedAt+599
    w.at(1,m.engine.snapshot)
    Test.equal(record.status,"in progress")
    w.advance(1)
    w.at(1,m.engine.snapshot)
    Test.equal(record.status,"error")
    Test.equal(record.errorCode,"MC_ACK_OVERDUE")
    for _=1,20 do w.step() end
    local rows=w.at(4,w.computers[4].engine.snapshot).requests
    Test.equal(rows[1].status,"error")
    Test.equal(#w.callsFor("export",true),exports,"acknowledgement error resent stock")
    Test.equal(#w.callsFor("craft",true),0)
    w.computers[4].integrator.requests={}
    w.untilTrue(function() return record.status=="delivered" end)
    Test.equal(#w.callsFor("export",true),exports)
end)

Test.case("new Master grant arriving before reset receipt cannot reserve an idle client",function()
    local w,m=fixture()
    local c=w.computers[4]
    w.untilTrue(function() return c.store.data.client.turn and c.store.data.client.turn.phase=="finished" end)
    w.queue={}
    m.restart();m.store.data.master.colonyCursor=1
    w.advance(1);w.tick(4);w.deliver()
    w.tick(1)
    local grantIndex
    for index,packet in ipairs(w.queue) do
        if packet.to==4 and packet.message.kind=="turn" then grantIndex=index;break end
    end
    assert(grantIndex,"new Master grant was not queued")
    local old=c.store.data.client.turn
    w.deliver(grantIndex)
    assert(c.store.data.client.turn==old,"client reserved a turn from an unacknowledged Master session")
    w.flush()
    w.untilTrue(function()
        local cs=m.store.data.master.colonies["4"]
        return cs and cs.requests.R4~=nil
    end)
end)

Test.case("Stardust request with zero count and positive minimum cannot strand its batch", function()
    local w, m = fixture()
    w.computers[4].integrator.requests = {{id="MINIMUM", name="Stone", count=0,
        minCount=4, items={{name="minecraft:stone", count=0}}}}
    w.untilTrue(function()
        local cs=m.store.data.master.colonies["4"]
        return cs and cs.requests.MINIMUM ~= nil
    end)
    Test.equal(m.store.data.master.colonies["4"].requests.MINIMUM.requested,4)
end)

Test.case("large unused Integrator metadata cannot silently prevent Stardust batch transmission", function()
    local w,m=fixture()
    local request=S.request("LARGE","minecraft:stone",4)
    request.recipe={debug=string.rep("x",5000)}
    request.items[1].tags={debug=string.rep("y",5000)}
    w.computers[4].integrator.requests={request}
    w.untilTrue(function()
        local cs=m.store.data.master.colonies["4"]
        return cs and cs.requests.LARGE ~= nil
    end)
    local packet=w.packet("batch",1)
    assert(packet)
    Test.equal(m.store.data.master.colonies["4"].requests.LARGE.requested,4)
end)

Test.case("untransmittable exact request closes reservation with a visible error and no shipment", function()
    local w,m=fixture()
    local request=S.request("NBT-LARGE","minecraft:stone",4,string.rep("x",5000))
    w.computers[4].integrator.requests={request}
    w.untilTrue(function()
        local cs=m.store.data.master.colonies["4"]
        return cs and cs.error and cs.error:find("protocol limits",1,true)
    end)
    local cs=m.store.data.master.colonies["4"]
    assert(cs.turn.phase~="WAIT_BATCH")
    Test.equal(#cs.shipments,0)
    local found=false
    for _,event in ipairs(w.computers[4].store.data.errors) do if event.code=="BATCH_LIMIT" then found=true end end
    assert(found,"local batch error was not recorded")
end)

Test.case("smaller wire batches retain exact alternatives and eventually visit every request", function()
    local w,m=fixture()
    local requests={}
    for index=1,10 do
        local request={id="WIDE"..index,count=1,name="Wide request",items={}}
        for alternative=1,600 do
            request.items[#request.items+1]={name="minecraft:item_"..alternative,count=1}
        end
        requests[#requests+1]=request
    end
    w.computers[4].integrator.requests=requests
    w.untilTrue(function()
        local cs=m.store.data.master.colonies["4"]
        for index=1,10 do if not (cs and cs.requests["WIDE"..index]) then return false end end
        return true
    end)
    local shortened=false
    for _,packet in ipairs(w.sent) do
        if packet.from==4 and packet.message.kind=="batch" and packet.message.authoritative then
            if #packet.message.requests<8 then shortened=true end
            for _,request in ipairs(packet.message.requests) do Test.equal(#request.items,600) end
        end
    end
    assert(shortened,"fixture did not exercise smaller batches")
end)

Test.case("batch send failures are visible and the original batch retries after transport recovers", function()
    local w,m=fixture()
    local c=w.computers[4]
    local original=c.io.send
    local blocked=true
    c.io.send=function(id,message)
        if blocked and message.kind=="batch" then return false,"test transport failure" end
        return original(id,message)
    end
    w.untilTrue(function() return c.store.data.client.turn and c.store.data.client.turn.phase=="waiting" end)
    local turn=c.store.data.client.turn
    local snapshot=w.at(4,c.engine.snapshot)
    assert(snapshot.statusMessage:find("Batch not sent",1,true))
    assert(not snapshot.health.ok)
    blocked=false
    w.untilTrue(function()
        local cs=m.store.data.master.colonies["4"]
        return cs and cs.requests.R4 ~= nil
    end)
    assert(c.store.data.client.turn.turn==turn.turn)
    snapshot=w.at(4,c.engine.snapshot)
    assert(not snapshot.statusMessage:find("Batch not sent",1,true))
end)

Test.case("Master send failures identify colony and retain the original grant for retry",function()
    local w,m=fixture()
    local original=m.io.send
    local blocked=true
    m.io.send=function(id,message)
        if blocked and id==4 and message.kind=="turn" then return false,"Message exceeds protocol limits" end
        return original(id,message)
    end
    w.untilTrue(function()
        local cs=m.store.data.master.colonies["4"]
        return cs and cs.turn and cs.turn.sendError
    end)
    local held=m.store.data.master.colonies["4"].turn
    assert(held.sendError:find("protocol limits",1,true))
    local found=false
    for _,event in ipairs(m.store.data.errors) do
        if event.code=="NETWORK_SEND" and event.context.colonyId==4 then found=true end
    end
    assert(found,"Master hid a failed turn transmission")
    blocked=false
    w.untilTrue(function() return m.store.data.master.colonies["4"].requests.R4~=nil end)
    assert(m.store.data.master.colonies["4"].turn.id==held.id)
    assert(held.sendError==nil)
end)

Test.case("late startup ACK never erases a fresh turn and stale startup hello never resets it", function()
    local w, m = fixture()
    w.drop.batch = 10000
    w.untilTrue(function() return w.computers[4].store.data.client.turn ~= nil end)
    local c = w.computers[4]
    local turn = c.store.data.client.turn
    local ack = w.packet("hello_ack", 4)
    local hello
    for _, packet in ipairs(w.sent) do
        if packet.from==4 and packet.message.kind=="hello" and packet.message.startupReset then
            hello = packet; break
        end
    end
    assert(hello and ack)
    w.at(4, c.engine.onMessage, 1, ack.message)
    assert(c.store.data.client.turn == turn, "late ACK erased the live turn")
    local reserved = m.store.data.master.colonies["4"].turn
    w.at(1, m.engine.onMessage, 4, hello.message)
    assert(m.store.data.master.colonies["4"].turn == reserved, "duplicate hello reset a live turn")
end)

Test.case("lost reset ACK and grant-before-ACK recover without repeated staging resets", function()
    local w, m = fixture()
    w.drop.hello_ack = 2
    w.tick(2); w.tick(4); w.flush()
    w.tick(1); w.flush()
    assert(w.computers[2].store.data.client.turn==nil, "turn accepted before reset ACK")
    w.untilTrue(function()
        local cs = m.store.data.master.colonies["4"]
        return cs and cs.requests.R4 ~= nil
    end)
    local count = 0
    for _, event in ipairs(m.store.data.history) do if event.kind=="BOOT_RESET" then count=count+1 end end
    Test.equal(count, 2, "lost ACK repeated a physical staging reset")
end)

Test.case("Supply restart rejects old boot receipts and delayed old-process hellos", function()
    local w, m = fixture()
    w.untilTrue(function() return w.computers[4].store.data.client.turn ~= nil end)
    local c = w.computers[4]
    local oldAck = w.packet("hello_ack", 4)
    local oldHello
    for _, packet in ipairs(w.sent) do
        if packet.from==4 and packet.message.kind=="hello" then oldHello=packet end
    end
    c.restart()
    assert(not w.at(4, c.engine.onMessage, 1, oldAck.message))
    assert(c.store.data.client.bootResetPending)
    w.advance(1); w.tick(4); w.flush()
    assert(not c.store.data.client.bootResetPending)
    local turn = m.store.data.master.colonies["4"].turn
    assert(not w.at(1, m.engine.onMessage, 4, oldHello.message))
    assert(m.store.data.master.colonies["4"].turn == turn)
end)
