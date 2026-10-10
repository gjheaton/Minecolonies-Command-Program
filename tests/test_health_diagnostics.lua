local S=require("tests.support")
local D=require("tests.display_support")

local ACTIVE="Turn preparation was interrupted; transfers need reconciliation"
local HISTORICAL="Colony response overdue; original chest handoff retained"
local function fixture()
    local w=D.world();local master=S.computer(w,1,"master")
    master.config.colonies={D.route(2),D.route(9)}
    master.config.colonies[1].label="Clockwork";master.config.colonies[2].label="Stardust"
    master.rs=w.bridge(1,"prs",true);master.start();master.engine.snapshot()
    local colony=master.store.data.master.colonies["9"];colony.error=ACTIVE
    master.store.error("COLONY_TIMEOUT",HISTORICAL,{colonyId=9})
    local monitor=D.surface(100,38);local writes={};local originalWrite=monitor.write
    monitor.write=function(text)
        local x,y=monitor.getCursorPos();writes[#writes+1]={text=text,x=x,y=y,color=monitor.getTextColor()}
        return originalWrite(text)
    end
    local ui=require("colony.network.ui").new(master.config,master.store,master.engine,{monitor=function() return monitor,"screen" end})
    local renderTerminal=ui.renderTerminal
    ui.renderTerminal=function() end
    local f={w=w,master=master,colony=colony,monitor=monitor,ui=ui,writes=writes}
    function f.terminal()
        local previousPrint,lines=print,{};_G.print=function(value) lines[#lines+1]=tostring(value) end
        local ok,err=pcall(renderTerminal);_G.print=previousPrint;assert(ok,err)
        return table.concat(lines,"\n")
    end
    function f.guard(fn)
        local originalNames,originalWrap,originalOpen=peripheral.getNames,peripheral.wrap,fs.open
        local discoveries,opens=0,0
        peripheral.getNames=function() discoveries=discoveries+1;error("diagnostic display queried hardware") end
        peripheral.wrap=function() discoveries=discoveries+1;error("diagnostic display wrapped hardware") end
        fs.open=function(...) opens=opens+1;return originalOpen(...) end
        local before=textutils.serialize(w.files);local ok,err=pcall(fn)
        peripheral.getNames=originalNames;peripheral.wrap=originalWrap;fs.open=originalOpen;assert(ok,err)
        Test.equal(discoveries,0);Test.equal(opens,0);Test.equal(#w.calls,0)
        Test.equal(textutils.serialize(w.files),before)
    end
    return f
end

Test.case("master HOME selects an active colony fault and HEALTH plus the native terminal expose its cached reason",function()
    local f=fixture()
    f.guard(function()
        f.ui.draw();assert(f.monitor.lines[14]:find("Stardust",1,true) and f.monitor.lines[14]:find("error",1,true))
        local clockwork,stardust
        for _,write in ipairs(f.writes) do
            if write.y==13 and write.text:find("Clockwork",1,true) then clockwork=write.color end
            if write.y==14 and write.text:find("Stardust",1,true) then stardust=write.color end
        end
        assert(clockwork and stardust and clockwork~=stardust,"active colony fault used the normal idle row color")
        f.ui.handleEvent("monitor_touch","screen",2,14)
        Test.equal(f.ui.view,"health");assert(f.ui.notice:find(ACTIVE,1,true))
        local health=f.monitor.dump();assert(health:find("Stardust [9]",1,true) and health:find(ACTIVE,1,true))
        local terminal=f.terminal();assert(terminal:find("ERROR: Stardust [9]",1,true) and terminal:find(ACTIVE,1,true))
        assert(terminal:find("RECORDED ERROR",1,true) and terminal:find("COLONY_TIMEOUT",1,true))
    end)
end)

Test.case("clearing the live colony error removes the current health check while the dated recorded event remains historical",function()
    local f=fixture()
    f.ui.view="health";f.ui.draw();assert(f.monitor.dump():find(ACTIVE,1,true));f.terminal()
    f.colony.error=nil
    f.guard(function()
        f.ui.draw();assert(not f.monitor.dump():find(ACTIVE,1,true),"cleared colony error remained a current health failure")
        local terminal=f.terminal();assert(not terminal:find(ACTIVE,1,true))
        assert(terminal:find("RECORDED ERROR 00:01:40",1,true) and terminal:find("COLONY_TIMEOUT",1,true))
        assert(terminal:find(HISTORICAL,1,true));Test.equal(#f.master.store.data.errors,1)
        f.ui.view="errors";f.ui.draw()
        assert(f.monitor.dump():find("see HEALTH for current status",1,true),"recorded errors screen did not distinguish current health")
    end)
end)

Test.case("cached colony details do not replace active master transfer faults with historical warnings",function()
    local f=fixture()
    f.master.store.data.master.quarantine={code="TRANSFER_VERIFY",message="Export quantity does not match the physical chest"}
    f.guard(function()
        f.ui.view="health";f.ui.draw()
        local text=f.monitor.dump();assert(text:find("Transfer integrity",1,true) and text:find("Export quantity",1,true))
        assert(text:find(ACTIVE,1,true))
        local terminal=f.terminal()
        assert(terminal:find("ERROR: Transfer integrity",1,true) and terminal:find("ERROR: Stardust [9]",1,true))
        assert(terminal:find("RECORDED ERROR",1,true))
    end)
end)

Test.case("actual retained import details render on the native colony and cached read-only master display without storage discovery or mutation",function()
    local w=D.world();local c=S.computer(w,2,"supply")
    local prefix="enderchests:ender_chest_"
    local chestName=prefix..string.rep("s",128-#prefix);Test.equal(#chestName,128)
    c.config.deliveryChestName=chestName
    w.chest(2,chestName,"D2");w.chest(2,"returns","R2")
    c.rs=w.bridge(2,"crs",false);c.integrator=w.integrator(2,"integrator")
    c.integrator.requests={S.request("R1","minecraft:stone",4)};c.start()
    local transfers=0;w.devices[2].crs.api.importItemFromPeripheral=function() transfers=transfers+1;return nil,"NOT_CONNECTED" end
    w.insert(w.channels.D2,{name="minecraft:stone"},4)
    local delivery={id="D1",requestId="R1",item={name="minecraft:stone"},count=4,verified=true,createdAt=100}
    w.at(2,c.engine.onMessage,1,{version=1,kind="turn",session="master-1",turn=1,policy={},deliveries={delivery}})
    c.store.data.client.intent.item.nbt={secret="private-item-metadata"};c.store.data.client.intent.raw={secret="private-transfer-metadata"}
    c.store.save()
    local master=S.computer(w,1,"master");master.config.colonies={D.route(2)}
    local Telemetry=require("colony.network.telemetry")
    local source=w.at(2,Telemetry.new,c.config,c.store,c.io,c.engine)
    local receiver=w.at(1,Telemetry.new,master.config,master.store,master.io,{snapshot=function() error("master telemetry requested hardware state") end})
    w.at(2,source.tick);local packet=assert(w.packet("telemetry",1)).message;assert(w.at(1,receiver.onMessage,2,packet))
    local monitor=D.surface(100,38);local UI=require("colony.network.ui")
    local localUI=UI.new(c.config,c.store,c.engine,{monitor=function() end})
    local remoteUI=UI.new(c.config,master.store,{snapshot=function() return receiver.get(2) end},
        {monitor=function() return monitor,"remote" end},nil,{readOnly=true,displayOnly=true,monitorName="remote",sourceId=2})
    localUI.view="errors";remoteUI.view="errors"
    local before=textutils.serialize(w.files);local previousNames,previousWrap,previousOpen=peripheral.getNames,peripheral.wrap,fs.open
    local discoveries,opens=0,0
    peripheral.getNames=function() discoveries=discoveries+1;error("transfer details discovered storage") end
    peripheral.wrap=function() discoveries=discoveries+1;error("transfer details wrapped storage") end
    fs.open=function(...) opens=opens+1;return previousOpen(...) end
    local ok,err=pcall(function()
        localUI.draw();remoteUI.draw()
        for _,surface in ipairs({w.terminal,monitor}) do
            local text=surface.dump()
            assert(text:find("Operation: Delivery import",1,true) and text:find("Item: minecraft:stone",1,true))
            assert(text:find("Quantity: 4",1,true) and text:find("Reported result: UNKNOWN",1,true))
            assert(text:find("Before chest: 4",1,true) and text:find("Observed change: 0",1,true))
            assert(text:find("Bridge error: NOT_CONNECTED",1,true))
            assert(text:gsub("%s",""):find(chestName,1,true),"the full chest name was lost when the transfer summary wrapped")
            assert(not text:find("table:",1,true),"a raw intent table address replaced the actionable transfer details")
        end
        assert(not textutils.serialize(receiver.get(2)):find("private-",1,true))
        assert(remoteUI.handleEvent("paste","replacement")==false and remoteUI.handleEvent("key",keys.enter)==false)
    end)
    peripheral.getNames=previousNames;peripheral.wrap=previousWrap;fs.open=previousOpen;assert(ok,err)
    Test.equal(discoveries,0);Test.equal(opens,0);Test.equal(transfers,1);Test.equal(#w.calls,0)
    Test.equal(textutils.serialize(w.files),before);Test.equal(c.store.data.client.shipments.D1.imported,0)
    assert(c.store.data.client.intent and c.store.data.client.intent.reported==nil)
end)

return true
