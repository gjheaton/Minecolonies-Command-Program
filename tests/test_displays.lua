local S=require("tests.support")
local D=require("tests.display_support")
local Config=require("colony.network.config")

Test.case("master monitor assignments preserve unique displays and stay outside colony policy",function()
    D.world();local config=Config.defaults("master");config.monitorName="main"
    config.colonies={D.route(2,"colony-two"),D.route(3,"colony-three")}
    assert(Config.validate(config))
    config.colonies[2].monitorName="colony-two"
    local ok=Config.validate(config);assert(not ok,"two colony views can claim the same monitor")
    config.colonies[2].monitorName="main"
    ok=Config.validate(config);assert(not ok,"colony display can claim the main monitor")
    config.colonies[2].monitorName=false
    ok=Config.validate(config);assert(not ok,"invalid monitor assignment accepted")
    config.colonies[2].monitorName=nil
    assert(Config.validate(config),"optional display breaks existing schema4 configuration")
    local policy=Config.policy(config,config.colonies[1])
    assert(policy.monitorName==nil and policy.monitorTextScale==nil,"display settings leaked into remote hardware policy")
    config.colonies[1].overrides={monitorName="another-monitor"}
    assert(not Config.validate(config),"route policy can change remote display hardware")
end)

local function fixture()
    local w=D.world();local c=S.computer(w,1,"master")
    c.config.monitorName="main";c.config.colonies={D.route(2,"alpha"),D.route(3,"beta")}
    c.config.monitorTextScale=1;c.config.automationEnabled=false
    local expected=Config.DISPLAY or {columns=100,rows=38}
    local monitors={main=w.monitor(1,"main",expected.columns,expected.rows),
        alpha=w.monitor(1,"alpha",expected.columns,expected.rows),beta=w.monitor(1,"beta",expected.columns,expected.rows)}
    local state={role="master",statusMessage="Automation paused",requests={},colonies={},health={{label="PRS",ok=true,detail="Ready"}}}
    local counts={snapshots=0,checks=0,updates=0,reconciles=0}
    local engine={snapshot=function() counts.snapshots=counts.snapshots+1;return S.copy(state) end,
        busy=function() return false end,canEditHardware=function() return true end,canEditRoute=function() return true end,
        requestReconcile=function() counts.reconciles=counts.reconciles+1;return true end}
    local updater={check=function() counts.checks=counts.checks+1;return true end,
        install=function() counts.updates=counts.updates+1;return true end}
    local snapshots={}
    for id=2,3 do
        local snapshot={role="supply",colonyName=id==2 and "Alpha" or "Beta",masterId=1,requests={},history={},errors={},
            health={ok=true,connected=true,detail="Waiting for turn"},settings=Config.defaults("supply"),telemetry={state="online",age=0,receivedAt=100}}
        snapshot.settings.masterId=1;snapshot.settings.maxRequestsPerTurn=id
        for n=1,70 do snapshot.requests[n]={id="R"..n,name=(id==2 and "alpha-item-" or "beta-item-")..n,status="requested",requested=n,shipped=0,imported=0} end
        snapshots[id]=snapshot
    end
    local telemetry={get=function(id) return S.copy(snapshots[tonumber(id)]) end}
    local manager=require("colony.network.displays").new(c.config,c.store,engine,c.io,updater,telemetry)
    local f={w=w,c=c,manager=manager,monitors=monitors,state=state,counts=counts,snapshots=snapshots}
    function f.draw() return w.at(1,manager.draw) end
    function f.event(...) return w.at(1,manager.handleEvent,...) end
    function f.touch(name,text)
        local monitor=assert(monitors[name])
        for y=1,monitor.height do local x=(monitor.lines[y] or ""):find(text,1,true)
            if x then return f.event("monitor_touch",name,x,y) end
        end
        error("visible control missing: "..name.." / "..text)
    end
    f.draw()
    return f
end

Test.case("three assigned master monitors retain independent navigation and page state",function()
    local f=fixture();local a=f.manager.panels["2"].ui;local b=f.manager.panels["3"].ui
    Test.equal(f.monitors.main.scale,.5);Test.equal(f.monitors.alpha.scale,.5);Test.equal(f.monitors.beta.scale,.5)
    f.touch("alpha","REQUESTS");f.touch("alpha","NEXT")
    Test.equal(a.view,"requests");Test.equal(a.pages.requests,2)
    Test.equal(b.view,"home");Test.equal(f.manager.primary.view,"home")
    f.touch("beta","HISTORY");Test.equal(b.view,"history")
    f.event("char","2");Test.equal(f.manager.primary.view,"health")
    Test.equal(a.view,"requests");Test.equal(a.pages.requests,2);Test.equal(b.view,"history")
    f.draw();assert(f.monitors.alpha.dump():find("alpha-item-",1,true))
    assert(not f.monitors.alpha.dump():find("beta-item-",1,true))
    assert(not f.monitors.main.dump():find("alpha-item-",1,true))
    Test.equal(#f.w.callsFor(nil,true),0,"dashboard rendered by querying PRS")
end)

Test.case("remote monitor settings and action controls cannot mutate local configuration or invoke updater",function()
    local f=fixture();local panel=f.manager.panels["2"]
    local sourceBefore=textutils.serialize(f.snapshots[2].settings)
    local localBefore=textutils.serialize(f.c.config)
    f.touch("alpha","SETTINGS")
    local rendered=f.monitors.alpha.dump();assert(rendered:find("READ ONLY",1,true))
    assert(rendered:find("Read-only telemetry",1,true))
    f.event("monitor_touch","alpha",2,5)
    f.event("paste","replacement-hardware");f.event("key",keys.enter)
    assert(panel.ui.edit==nil,"remote screen opened an editor")
    f.event("monitor_touch","alpha",f.monitors.alpha.width,1)
    f.touch("alpha","HEALTH")
    f.event("monitor_touch","alpha",math.floor(f.monitors.alpha.width/2),f.monitors.alpha.height-1)
    Test.equal(f.counts.checks,0);Test.equal(f.counts.updates,0);Test.equal(f.counts.reconciles,0)
    Test.equal(textutils.serialize(f.snapshots[2].settings),sourceBefore)
    Test.equal(textutils.serialize(f.c.config),localBefore)
    Test.equal(#f.w.callsFor(nil,true),0)
end)

Test.case("unplugging a remote monitor preserves primary controls and never hijacks terminal",function()
    local f=fixture();f.touch("alpha","REQUESTS")
    local primary=f.manager.primary;local terminalBefore=f.w.terminal.dump();local terminalWrites=f.w.terminal.writes
    f.monitors.alpha.failed=true
    f.event("peripheral_detach","alpha");f.draw()
    Test.equal(f.w.terminal.dump(),terminalBefore);Test.equal(f.w.terminal.writes,terminalWrites)
    Test.equal(primary.view,"home");assert(f.monitors.main.dump():find("SUPPLY MASTER",1,true))
    f.touch("main","HEALTH");Test.equal(primary.view,"health")
    f.monitors.alpha.failed=false;f.event("peripheral","alpha");f.draw()
    Test.equal(f.manager.panels["2"].ui.view,"requests")
    Test.equal(#f.w.callsFor(nil,true),0)
end)

Test.case("a mismatched remote monitor shows a size warning without blocking supply or taking primary control",function()
    local f=fixture();f.monitors.alpha.width=50;f.monitors.alpha.height=19
    f.event("monitor_resize","alpha");f.draw()
    assert(f.monitors.alpha.dump():find("MONITOR SIZE",1,true))
    assert(f.monitors.alpha.dump():find("5 x 3",1,true))
    assert(f.monitors.main.dump():find("SUPPLY MASTER",1,true))
    assert(f.c.store.data.master==nil,"display warning changed transfer state")
    Test.equal(#f.w.callsFor(nil,true),0)
    f.monitors.alpha.width=Config.DISPLAY.columns;f.monitors.alpha.height=Config.DISPLAY.rows
    f.event("monitor_resize","alpha");f.draw()
    assert(not f.monitors.alpha.dump():find("MONITOR SIZE",1,true))
end)

Test.case("paused automation continues rendering fresh cached colony telemetry and explicit stale state",function()
    local f=fixture();f.snapshots[2].colonyName="Alpha refreshed"
    f.snapshots[2].telemetry={state="stale",age=25,receivedAt=100}
    f.draw();local text=f.monitors.alpha.dump()
    assert(text:find("Alpha refreshed",1,true));assert(text:find("STALE",1,true))
    Test.equal(f.c.config.automationEnabled,false)
    Test.equal(f.counts.checks,0);Test.equal(f.counts.updates,0);Test.equal(f.counts.reconciles,0)
    Test.equal(#f.w.callsFor(nil,true),0)
end)

Test.case("readonly UI remains inert even if passed real action and persistence handlers",function()
    local f=fixture();local sourceConfig=Config.defaults("supply");sourceConfig.monitorName="alpha";sourceConfig.masterId=1
    local saved=textutils.serialize(f.w.files);local sourceBefore=textutils.serialize(sourceConfig)
    local engine={snapshot=function() return S.copy(f.snapshots[2]) end,busy=function() return false end,
        requestReconcile=function() f.counts.reconciles=f.counts.reconciles+1;return true end}
    local updater={availableVersion="4.2.0",install=function() f.counts.updates=f.counts.updates+1;return true end,
        check=function() f.counts.checks=f.counts.checks+1;return true end}
    local ui=require("colony.network.ui").new(sourceConfig,f.c.store,engine,{monitor=function() return f.c.io.monitor("alpha") end},updater,
        {readOnly=true,displayOnly=true,monitorName="alpha",sourceId=2,expectedSize=Config.DISPLAY,fixedTextScale=.5})
    f.w.at(1,ui.draw);f.w.at(1,ui.handleEvent,"monitor_touch","alpha",f.monitors.alpha.width,1)
    ui.view="health";f.w.at(1,ui.draw)
    f.w.at(1,ui.handleEvent,"monitor_touch","alpha",math.floor(f.monitors.alpha.width/2),f.monitors.alpha.height-1)
    local rows=f.monitors.alpha.height-9
    for i,field in ipairs(Config.fields("supply")) do if field.key=="autoCraftEnabled" then
        ui.view="settings";ui.pages.settings=math.floor((i-1)/rows)+1;f.w.at(1,ui.draw)
        f.w.at(1,ui.handleEvent,"monitor_touch","alpha",2,5+(i-1)%rows)
    end end
    assert(ui.edit==nil);f.w.at(1,ui.handleEvent,"paste","different");f.w.at(1,ui.handleEvent,"key",keys.enter)
    f.w.at(1,ui.renderTerminal)
    Test.equal(f.counts.updates,0);Test.equal(f.counts.checks,0);Test.equal(f.counts.reconciles,0)
    Test.equal(textutils.serialize(sourceConfig),sourceBefore);Test.equal(textutils.serialize(f.w.files),saved)
end)

Test.case("remote tabs disclose truncated totals, unreported settings and fresh processor faults",function()
    local f=fixture();local snapshot=f.snapshots[2];snapshot.totals={requests=71};snapshot.shown={requests=70};snapshot.truncated={requests=1}
    snapshot.statusMessage="Processor stopped; restart after recovery: simulated fault";snapshot.health.ok=false;snapshot.health.detail=snapshot.statusMessage
    snapshot.settings.maxImportsPerTurn=nil
    f.draw();local text=f.monitors.alpha.dump()
    assert(text:find("ONLINE",1,true) and text:find("PARTIAL",1,true))
    assert(text:find("71 (70 shown)",1,true))
    assert(text:find("Processor stopped",1,true),"fresh display traffic hid stopped automation")
    f.touch("alpha","REQUESTS");assert(f.monitors.alpha.dump():find("70/71 reported",1,true))
    local ui=f.manager.panels["2"].ui;local rows=f.monitors.alpha.height-9
    for i,field in ipairs(Config.fields("supply")) do if field.key=="maxImportsPerTurn" then
        ui.view="settings";ui.pages.settings=math.floor((i-1)/rows)+1;f.draw()
        assert((f.monitors.alpha.lines[5+(i-1)%rows] or ""):find("UNAVAILABLE",1,true),"omitted remote setting pretended to be default")
    end end
    Test.equal(#f.w.callsFor(nil,true),0)
end)

Test.case("reassigning a colony display clears old content and retains its independent page",function()
    local f=fixture();f.touch("alpha","REQUESTS");f.touch("alpha","NEXT")
    f.monitors.gamma=f.w.monitor(1,"gamma",Config.DISPLAY.columns,Config.DISPLAY.rows)
    f.c.config.colonies[1].monitorName="gamma";f.draw()
    assert(f.monitors.alpha.dump():find("UNASSIGNED",1,true));assert(not f.monitors.alpha.dump():find("alpha-item-",1,true))
    assert(f.monitors.gamma.dump():find("alpha-item-",1,true));Test.equal(f.manager.panels["2"].ui.pages.requests,2)
    local before=f.manager.panels["2"].ui.pages.requests
    f.event("monitor_touch","alpha",f.monitors.alpha.width,f.monitors.alpha.height-1)
    Test.equal(f.manager.panels["2"].ui.pages.requests,before,"old screen retained control of moved dashboard")
    f.c.config.colonies[1].monitorName="";f.draw();assert(f.manager.panels["2"]==nil)
    assert(f.monitors.gamma.dump():find("UNASSIGNED",1,true))
end)

Test.case("a former colony monitor can become primary without being cleared as unassigned",function()
    local f=fixture();f.monitors.gamma=f.w.monitor(1,"gamma",100,38)
    f.c.config.monitorName="alpha";f.c.config.colonies[1].monitorName="gamma"
    f.draw();f.event("monitor_touch","alpha",1,5)
    assert(f.monitors.alpha.dump():find("SUPPLY MASTER",1,true))
    assert(not f.monitors.alpha.dump():find("UNASSIGNED",1,true),"remap cleanup erased the new main monitor")
    assert(f.monitors.gamma.dump():find("Alpha",1,true))
    f.touch("alpha","HEALTH");Test.equal(f.manager.primary.view,"health")
end)

Test.case("swapping two colony monitors immediately transfers touch ownership without clearing the new owner",function()
    local f=fixture();f.touch("alpha","REQUESTS");f.touch("alpha","NEXT")
    f.c.config.colonies[1].monitorName="beta";f.c.config.colonies[2].monitorName="alpha"
    f.event("peripheral","beta")
    assert(f.monitors.beta.dump():find("alpha-item-",1,true))
    assert(f.monitors.alpha.dump():find("Beta",1,true))
    assert(not f.monitors.alpha.dump():find("UNASSIGNED",1,true) and not f.monitors.beta.dump():find("UNASSIGNED",1,true))
    Test.equal(f.manager.panels["2"].ui.pages.requests,2)
    f.touch("beta","HISTORY");Test.equal(f.manager.panels["2"].ui.view,"history");Test.equal(f.manager.panels["3"].ui.view,"home")
end)

return true
