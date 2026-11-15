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
