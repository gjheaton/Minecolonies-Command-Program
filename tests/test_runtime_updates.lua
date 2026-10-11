local S=require("tests.support")
local D=require("tests.display_support")
local Config=require("colony.network.config")
local Store=require("colony.network.store")
local function encode(value) return textutils.serialize(value,{compact=true,allow_repetitions=true}) end
local function payload(data) return encode({master=data.master,client=data.client,chestTest=data.chestTest}) end

-- Real receiver, processor, display manager and UI; engine work and the HTTP
-- boundary are controlled to observe when a user action actually executes.
local function run(role,options,scenario)
    options=options or {}
    local w=D.world();local id=role=="master" and 1 or 2;local c=S.computer(w,id,role)
    c.config.monitorName="screen";c.config.pollIntervalSeconds=1;c.config.updateCheckSeconds=86400
    c.config.automationEnabled=false
    if role=="master" then
        c.config.colonies={D.route(2)};c.rs=w.bridge(id,"prs",true);w.chest(id,"D2","D2");w.chest(id,"R2","R2")
    else
        c.rs=w.bridge(id,"crs",false);c.integrator=w.integrator(id,"integrator")
        w.chest(id,"delivery","delivery");w.chest(id,"returns","returns")
    end
    local surface=w.monitor(id,"screen",100,38);Config.save(c.config)
    local store=Store.new("/colony/"..role.."_v4_state",c.config)
    store.data.master={pendingTransfer={kind="export",count=1,item={name="minecraft:shears"}},
        quarantine={code="TRANSFER_VERIFY",message="Held exact receipt"},craftJobs={rice={state="crafting",count=4}},
        colonies={["2"]={shipments={{id="held-shipment",count=1,imported=0}},requests={R={status="error"}}}}}
    store.data.client={intent={kind="import",shipmentId="held-shipment",count=1},
        fault={code="IMPORT_UNCERTAIN",message="Held original import"},requests={R={status="error"}},
        shipments={["held-shipment"]={id="held-shipment",count=1,imported=0}}}
    if options.reserved then store.data.chestTest={token="held-test",phase="inspect"} end
    store.save();local held=payload(store.data)
    local Engine=require(role=="master" and "colony.network.master" or "colony.network.client")
    local Displays=require("colony.network.displays");local Telemetry=require("colony.network.telemetry")
    local Updater=require("colony.lib.updater");local Protocol=require("colony.network.protocol")
    local saved={engine=Engine.new,displays=Displays.new,telemetry=Telemetry.new,updater=Updater.new,open=Protocol.open,
        parallel=parallel,sleep=sleep,pull=os.pullEvent,print=print}
    local f={w=w,c=c,surface=surface,checks=0,installs=0,ticks=0,messages=0,reconciles=0,updateGuards=0,
        outcome="current",terminal={}}
    Engine.new=function(_,runtimeStore)
        f.store=runtimeStore
        f.engine={snapshot=function() return {role=role,health={ok=true,detail="Connected"},requests={},colonies={}} end,
            busy=function() return true end,
            canUpdate=function() f.updateGuards=f.updateGuards+1;return false,"Held transfer prevents installation" end,
            tick=function() f.ticks=f.ticks+1;if options.stopped then error("Stopped held processor",0) end end,
            onMessage=function() f.messages=f.messages+1 end,
            reconcile=function() f.reconciles=f.reconciles+1;return false,"Original receipt stays held" end}
        return f.engine
    end
    Updater.new=function()
        local self={checkQueued=false,checking=false,installing=false,sourceLabel=function() return "github/fixture/repository@main" end}
        self.check=function()
            f.checks=f.checks+1
            assert(coroutine.running()==f.processor,"metadata lookup ran in the receiver")
            Test.equal(self.checkQueued,false);Test.equal(self.checking,true)
            self.remoteVersion=nil;self.remoteSuiteVersion=nil;self.availableVersion=nil;self.checkError=nil
            self.lastCheckedText="12:34:56"
            if f.outcome=="yield" then coroutine.yield("HTTP wait") end
            if f.outcome=="throw" then error("HTTP API disabled",0) end
            if f.outcome=="failure" then self.checkError="Remote source returned no response";return false,self.checkError end
            self.remoteVersion=Config.VERSION;self.remoteSuiteVersion=Config.VERSION
            if f.outcome=="available" then self.remoteVersion="4.0.3";self.availableVersion=self.remoteVersion end
            return self.availableVersion~=nil
        end
        self.install=function() f.installs=f.installs+1;return true end
        f.actual=self;return self
    end
    Telemetry.new=function() return {tick=function() end,onMessage=function() return false end,get=function() return nil end} end
    Protocol.open=function() return true end
    Displays.new=function(...)
        local args={...};f.proxy=args[5];f.manager=saved.displays(...);f.ui=f.manager.primary;return f.manager
    end
    _G.print=function(message) f.terminal[#f.terminal+1]=tostring(message) end
    _G.sleep=function(seconds) return coroutine.yield("processor wait",seconds) end
    os.pullEvent=function() return coroutine.yield("receiver wait") end
    local function resume(thread,...)
        local ok,marker,seconds=coroutine.resume(thread,...);assert(ok,marker);return marker,seconds
    end
    function f.step(expected)
        local marker,seconds=resume(f.processor);Test.equal(marker,expected or "processor wait")
        if marker=="processor wait" then w.advance(seconds) end
    end
    function f.event(...) Test.equal(resume(f.receiver,...),"receiver wait") end
    function f.find(text)
        for y=1,surface.height do local x=(surface.lines[y] or ""):find(text,1,true);if x then return x,y end end
    end
    function f.click(text)
        local x,y=f.find(text);assert(x,"control absent: "..text.."\n"..surface.dump());f.event("monitor_touch","screen",x,y)
    end
    function f.boot()
        f.step();if options.stopped then f.step() end
        Test.equal(f.checks,0);Test.equal(f.actual.checkQueued,true)
        f.step();Test.equal(f.checks,1);Test.equal(f.actual.checkQueued,false);Test.equal(f.actual.checking,false)
    end
    function f.settings() f.ui.view="settings";f.manager.draw();return surface.dump() end
    function f.unchanged()
        Test.equal(payload(f.store.data),held)
        local loaded=Store.new(store.path,c.config);loaded.load();Test.equal(payload(loaded.data),held)
        Test.equal(#w.calls,0,"checking update metadata invoked RS");Test.equal(f.installs,0)
    end
    _G.parallel={waitForAll=function(receiver,processor)
        f.receiver=coroutine.create(receiver);f.processor=coroutine.create(processor)
        Test.equal(resume(f.receiver),"receiver wait");scenario(f)
    end}
    local ok,err=pcall(w.at,id,require("colony.network.runtime").run,role)
    Engine.new,Displays.new,Telemetry.new,Updater.new,Protocol.open=saved.engine,saved.displays,saved.telemetry,saved.updater,saved.open
    _G.parallel,_G.sleep,os.pullEvent,_G.print=saved.parallel,saved.sleep,saved.pull,saved.print
    assert(ok,err);return f
end

Test.case("manual CHECK UPDATE queues through the real receiver while busy and displays the current version source and completion time",function()
    for _,role in ipairs({"master","supply"}) do run(role,nil,function(f)
        f.boot();f.click("CHECK UPDATE")
        Test.equal(f.checks,1,"touch performed metadata lookup inline");Test.equal(f.actual.checkQueued,true)
        assert(f.surface.dump():find("CHECK QUEUED",1,true))
        assert(f.engine.requestReconcile()==false);assert(f.engine.requestClearErrors()==false);assert(f.proxy.install()==false)
        f.step();Test.equal(f.checks,2);Test.equal(f.actual.checkQueued,false);Test.equal(f.actual.checking,false)
        Test.equal(f.updateGuards,0,"read-only check used installation guard")
        local screen=f.settings()
        assert(screen:find("CURRENT",1,true) and screen:find(Config.VERSION,1,true))
        assert(screen:find("12:34:56",1,true) and screen:find("Source:",1,true) and screen:find("@main",1,true))
        assert(not tostring(f.ui.notice):find("queued",1,true),"completed result stayed queued");f.unchanged()
    end) end
end)

Test.case("automatic update checks expose queued and executing flags and can run while a chest test reserves the processor",function()
    run("master",{reserved=true},function(f)
        f.step();Test.equal(f.checks,0);Test.equal(f.actual.checkQueued,true);Test.equal(f.ticks,0)
        assert(f.surface.dump():find("CHECK QUEUED",1,true))
        f.step();Test.equal(f.checks,1);Test.equal(f.actual.checkQueued,false);Test.equal(f.actual.checking,false)
        f.click("CHECK UPDATE");Test.equal(f.checks,1);f.step();Test.equal(f.checks,2)
        Test.equal(f.updateGuards,0);Test.equal(f.ticks,0);f.unchanged()
    end)
end)

Test.case("a stopped processor continues serialized metadata checks without resetting its held receipt or restarting engine work",function()
    run("supply",{stopped=true},function(f)
        f.boot();Test.equal(f.ticks,1);assert(f.engine.snapshot().statusMessage:find("Processor stopped",1,true))
        f.click("CHECK UPDATE");Test.equal(f.checks,1);f.step();Test.equal(f.checks,2)
        Test.equal(f.ticks,1);Test.equal(f.updateGuards,0)
        assert(f.engine.snapshot().statusMessage:find("Processor stopped",1,true))
        assert(f.settings():find("CURRENT",1,true));f.unchanged()
    end)
end)

Test.case("failed and thrown update checks visibly report their HTTP error and a later successful retry clears it",function()
    for _,outcome in ipairs({"failure","throw"}) do run("supply",nil,function(f)
        f.boot();f.outcome=outcome;f.click("CHECK UPDATE");f.step()
        Test.equal(f.actual.checkQueued,false);Test.equal(f.actual.checking,false)
        local reason=outcome=="throw" and "HTTP API disabled" or "Remote source returned no response"
        Test.equal(f.actual.checkError,reason)
        assert(f.settings():find(reason,1,true),"completed check error invisible in SETTINGS")
        assert(table.concat(f.terminal,"\n"):find(reason,1,true),"completed check error invisible on native terminal")
        assert(not f.engine.snapshot().statusMessage or not f.engine.snapshot().statusMessage:find("Processor stopped",1,true))
        f.outcome="current";f.click("RETRY UPDATE");f.step()
        assert(f.actual.checkError==nil);assert(f.settings():find("CURRENT",1,true));f.unchanged()
    end) end
end)

Test.case("a pending reconciliation cannot be replaced by a check and an HTTP wait keeps received messages queued",function()
    run("master",nil,function(f)
        f.boot();assert(f.engine.requestReconcile());local checks=f.checks
        f.click("CHECK UPDATE");Test.equal(f.actual.checkQueued,false);Test.equal(f.checks,checks)
        f.step();Test.equal(f.reconciles,1);Test.equal(f.checks,checks)
        f.outcome="yield";f.click("CHECK UPDATE");f.step("HTTP wait")
        Test.equal(f.actual.checkQueued,false);Test.equal(f.actual.checking,true)
        f.event("rednet_message",2,{kind="hello",version=1},require("colony.network.protocol").NAME)
        Test.equal(f.messages,0,"receiver invoked engine during HTTP lookup")
        f.step();Test.equal(f.actual.checking,false);Test.equal(f.messages,0)
        f.step();Test.equal(f.messages,1);f.unchanged()
    end)
end)

Test.case("an available update remains visible while busy but UI and runtime still prevent installation over a held transfer",function()
    run("master",nil,function(f)
        f.boot();f.outcome="available";f.click("CHECK UPDATE");f.step()
        Test.equal(f.actual.availableVersion,"4.0.3")
        assert(f.settings():find("4.0.3",1,true));f.click("UPDATE v4.0.3")
        Test.equal(f.installs,0);assert(f.ui.notice and f.ui.notice:find("safely",1,true))
        assert(f.proxy.install());f.step();Test.equal(f.installs,0);Test.equal(f.updateGuards,1)
        local warning=f.store.data.history[#f.store.data.history]
        Test.equal(warning.kind,"WARNING");assert(warning.message:find("Held transfer",1,true));f.unchanged()
    end)
end)
return true
