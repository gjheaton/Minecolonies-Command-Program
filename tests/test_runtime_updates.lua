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
        outcome="current",terminal={},held=held}
    Engine.new=function(runtimeConfig,runtimeStore)
        f.config=runtimeConfig
        f.store=runtimeStore
        f.busy=true
        f.engine={snapshot=function() return {role=role,health={ok=true,detail="Connected"},requests={},colonies={}} end,
            busy=function() return f.busy end,
            canUpdate=function() f.updateGuards=f.updateGuards+1;return options.updatable and not f.busy,"Held transfer prevents installation" end,
            holdNewTurns=function(enabled) f.holding=enabled end,
            canWaitForUpdate=function() return not options.blockWait end,
            tick=function() f.ticks=f.ticks+1;if options.stopped then error("Stopped held processor",0) end end,
            onMessage=function(_,message)
                f.messages=f.messages+1
                if options.updatable and message.kind=="result" then f.busy=false end
                if options.updatable and message.kind=="turn" and not f.holding then f.busy=true end
            end,
            reconcile=function()
                f.reconciles=f.reconciles+1
                assert(coroutine.running()==f.processor,"recovery ran in receiver")
                if role=="master" then
                    Test.equal(runtimeConfig.automationEnabled,false)
                    Test.equal(Config.load("master").automationEnabled,false,"recovery started before pause was saved")
                end
                return options.recoverable==true,"Original receipt stays held"
            end,
            verifyHeldTransfer=function()
                f.verifications=(f.verifications or 0)+1
                if f.verified then
                    runtimeStore.data.master.pendingTransfer=nil
                    runtimeStore.data.master.quarantine=nil
                    runtimeStore.save()
                    return true,"Held transfer verified from physical chest quantities"
                end
                return false,"Transfer verification pending; existing intent retained"
            end}
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
        self.install=function()
            f.installs=f.installs+1
            if options.updatable then assert(not f.busy and f.holding,"installation did not safely close and hold turns") end
            if f.installOutcome=="throw" then error("Injected installation failure",0) end
            if f.installOutcome=="false" then return false end
            if f.installOutcome=="yield" then coroutine.yield("install wait") end
            return true
        end
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

Test.case("master recovery button serializes pause, verifies a single probe and reports completion without reboot",function()
    run("master",{recoverable=true},function(f)
        f.boot();f.config.automationEnabled=true;f.config.transferVerifyTimeoutSeconds=5;Config.save(f.config)
        f.ui.view="health";f.manager.draw();f.click("RECOVER TRANSFER")
        Test.equal(f.reconciles,0);f.click("RUN RECOVERY")
        Test.equal(f.reconciles,0,"click performed recovery inline")
        f.step();Test.equal(f.reconciles,1);Test.equal(f.verifications,1)
        assert(f.engine.requestReconcile()==false,"concurrent recovery accepted")
        assert(f.proxy.install()==false,"installation overlapped recovery")
        f.step();Test.equal(f.reconciles,1,"recovery submitted a second probe")
        f.verified=true;f.step()
        assert(f.surface.dump():find("RECOVERED",1,true),"recovery result absent: "..f.surface.dump().." / "..tostring(f.ui.recoveryResult))
        assert(not f.store.data.master.pendingTransfer and not f.store.data.master.quarantine)
        Test.equal(f.config.automationEnabled,false);Test.equal(Config.load("master").automationEnabled,false)
        Test.equal(f.installs,0)
    end)
end)

Test.case("blocked and expired recovery preserve the original hold and report BLOCKED with automation paused",function()
    for _,probe in ipairs({false,true}) do run("master",{recoverable=probe},function(f)
        f.boot();f.config.automationEnabled=true;Config.save(f.config)
        local completed,result
        assert(f.engine.requestReconcile(function(ok,detail) completed=ok;result=detail end))
        f.step()
        if probe then
            assert(completed==nil);f.w.advance(f.c.config.transferVerifyTimeoutSeconds+1);f.step()
        end
        Test.equal(completed,false);assert(result:find(probe and "remains held" or "Original receipt",1,true))
        Test.equal(f.reconciles,1);Test.equal(payload(f.store.data),f.held)
        Test.equal(Config.load("master").automationEnabled,false)
    end) end
end)

Test.case("recovery reports a reserved chest test without starting a transfer or clearing its journal",function()
    run("master",{reserved=true},function(f)
        f.boot();local completed,result
        assert(f.engine.requestReconcile(function(ok,detail) completed=ok;result=detail end));f.step()
        Test.equal(completed,false);assert(result:find("chest test",1,true));Test.equal(f.reconciles,0);f.unchanged()
    end)
end)

Test.case("failure to save the recovery pause prevents bridge work and reports a stopped processor",function()
    run("master",{recoverable=true},function(f)
        f.boot();local completed,result
        assert(f.engine.requestReconcile(function(ok,detail) completed=ok;result=detail end))
        local save=Config.save
        Config.save=function() error("Injected disk write failure",0) end
        local ok,err=pcall(f.step);Config.save=save;assert(ok,err)
        Test.equal(completed,false);assert(result:find("Injected disk write failure",1,true))
        Test.equal(f.reconciles,0);Test.equal(payload(f.store.data),f.held)
    end)
end)

Test.case("monitor recovery does not restart a stopped processor or clear its retained transfer",function()
    run("master",{stopped=true,recoverable=true},function(f)
        f.boot();local completed,result
        assert(f.engine.requestReconcile(function(ok,detail) completed=ok;result=detail end));f.step()
        Test.equal(completed,false);assert(result:find("Restart the stopped processor",1,true))
        Test.equal(f.reconciles,0);Test.equal(payload(f.store.data),f.held)
    end)
end)

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
    run("master",{blockWait=true},function(f)
        f.boot();f.outcome="available";f.click("CHECK UPDATE");f.step()
        Test.equal(f.actual.availableVersion,"4.0.3")
        assert(f.settings():find("4.0.3",1,true));f.click("UPDATE v4.0.3")
        Test.equal(f.installs,0);assert(f.actual.installQueued)
        f.step();Test.equal(f.installs,0);Test.equal(f.updateGuards,1)
        assert(not f.actual.installQueued and not f.holding)
        assert(f.ui.notice:find("Update blocked",1,true))
        local warning=f.store.data.history[#f.store.data.history]
        Test.equal(warning.kind,"WARNING");assert(warning.message:find("Held transfer",1,true));f.unchanged()
    end)
end)

Test.case("master UPDATE saves a pause drains existing turns and installs once without admitting fresh work",function()
    run("master",{updatable=true},function(f)
        f.boot();f.config.automationEnabled=true;Config.save(f.config)
        f.outcome="available";f.click("CHECK UPDATE");f.step();f.click("UPDATE v4.0.3")
        assert(f.holding and f.actual.installQueued);Test.equal(f.installs,0)
        f.step();Test.equal(f.installs,0)
        Test.equal(f.config.automationEnabled,false);Test.equal(Config.load("master").automationEnabled,false)
        f.step();Test.equal(f.installs,0)
        f.event("rednet_message",2,{kind="result",version=1},require("colony.network.protocol").NAME)
        f.event("rednet_message",2,{kind="turn",version=1},require("colony.network.protocol").NAME)
        f.step();Test.equal(f.installs,1);assert(not f.busy and not f.holding)
        f.step();Test.equal(f.installs,1);Test.equal(Config.load("master").automationEnabled,false)
        Test.equal(payload(f.store.data),f.held)
    end)
end)

Test.case("failed master update releases admission but retains the saved automation pause",function()
    run("master",{updatable=true},function(f)
        f.boot();f.config.automationEnabled=true;Config.save(f.config)
        f.outcome="available";f.click("CHECK UPDATE");f.step();f.click("UPDATE v4.0.3")
        f.installOutcome="false"
        f.event("rednet_message",2,{kind="result",version=1},require("colony.network.protocol").NAME)
        f.step();Test.equal(f.installs,1);assert(not f.holding and not f.actual.installQueued)
        Test.equal(Config.load("master").automationEnabled,false)
        assert(f.ui.notice:find("Update failed",1,true));Test.equal(payload(f.store.data),f.held)
    end)
end)

Test.case("master update cannot install or drain new work when saving its automation pause fails",function()
    run("master",{updatable=true},function(f)
        f.boot();f.config.automationEnabled=true;Config.save(f.config)
        f.outcome="available";f.click("CHECK UPDATE");f.step();f.click("UPDATE v4.0.3")
        local save=Config.save;Config.save=function() error("Injected pause write failure",0) end
        local ok,err=pcall(f.step);Config.save=save;assert(ok,err)
        Test.equal(f.installs,0);assert(not f.holding and not f.actual.installQueued)
        assert(f.ui.notice:find("pause write failure",1,true));Test.equal(payload(f.store.data),f.held)
        local ticks=f.ticks;f.step();Test.equal(f.ticks,ticks,"stopped processor admitted more work")
    end)
end)
Test.case("colony UPDATE queues through an active turn then installs once despite a following grant in the same receiver inbox",function()
    run("supply",{updatable=true},function(f)
        f.boot();f.outcome="available";f.click("CHECK UPDATE");f.step();f.click("UPDATE v4.0.3")
        assert(f.holding and f.actual.installQueued);assert(f.surface.dump():find("UPDATE QUEUED",1,true))
        f.step();f.step();Test.equal(f.installs,0)
        assert(f.engine.requestReconcile()==false,"waiting update lost its queue reservation")
        f.event("rednet_message",1,{kind="result",version=1},require("colony.network.protocol").NAME)
        f.event("rednet_message",1,{kind="turn",version=1},require("colony.network.protocol").NAME)
        f.step();Test.equal(f.installs,1);Test.equal(f.busy,false)
        assert(not f.holding and not f.actual.installQueued)
        f.step();Test.equal(f.installs,1,"queued update installed twice")
        Test.equal(payload(f.store.data),f.held) -- Existing transfer evidence is untouched by scheduling.
    end)
end)

Test.case("queued colony installation keeps turns held during HTTP work and releases admission after failure",function()
    for _,outcome in ipairs({"false","throw","yield"}) do
        run("supply",{updatable=true},function(f)
            f.boot();f.outcome="available";f.click("CHECK UPDATE");f.step();f.click("UPDATE v4.0.3")
            f.installOutcome=outcome
            f.event("rednet_message",1,{kind="result",version=1},require("colony.network.protocol").NAME)
            if outcome=="yield" then
                f.step("install wait");assert(f.holding and f.actual.installing)
                local messages=f.messages
                f.event("rednet_message",1,{kind="turn",version=1},require("colony.network.protocol").NAME)
                Test.equal(f.messages,messages,"receiver ran a grant during installation")
                f.step()
            else f.step() end
            Test.equal(f.installs,1);assert(not f.holding and not f.actual.installQueued and not f.actual.installing)
            if outcome~="yield" then
                Test.equal(f.store.data.errors[#f.store.data.errors].code,"UPDATE_FAILED")
                assert(f.ui.notice:find("Update failed",1,true),"failed installation kept the queued notice")
                f.event("rednet_message",1,{kind="turn",version=1},require("colony.network.protocol").NAME)
            end
            f.step();Test.equal(f.busy,true,"failed/returned installation left turn admission frozen")
            Test.equal(f.installs,1)
        end)
    end
end)
Test.case("an ambiguous transfer cancels the waiting colony update and frees recovery actions without installing or changing its evidence",function()
    run("supply",{blockWait=true},function(f)
        f.boot();f.outcome="available";f.click("CHECK UPDATE");f.step();f.click("UPDATE v4.0.3")
        assert(f.actual.installQueued and f.holding)
        f.step();assert(not f.actual.installQueued and not f.holding);Test.equal(f.installs,0)
        assert(f.ui.notice:find("Update blocked",1,true),"blocked installation still displayed a queued notice")
        assert(f.engine.requestReconcile(),"blocked update prevented transfer recovery")
        f.step();Test.equal(f.reconciles,1);Test.equal(payload(f.store.data),f.held)
    end)
end)
return true
