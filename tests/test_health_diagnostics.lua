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

return true
