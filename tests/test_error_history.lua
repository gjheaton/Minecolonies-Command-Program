local S=require("tests.support")
local D=require("tests.display_support")
local Config=require("colony.network.config")
local Store=require("colony.network.store")

local function encode(value) return textutils.serialize(value,{compact=true,allow_repetitions=true}) end
local function retainedState()
    return {
        master={pendingTransfer={kind="export",item={name="minecraft:shears"},count=1,reported=1,uncertain=true},
            quarantine={code="TRANSFER_VERIFY",message="Unresolved physical receipt"},
            colonies={["4"]={requests={R1={status="error",requested=1}},shipments={{id="shipment-27",count=1,imported=0}}}},
            craftJobs={rice={state="crafting",count=4}}},
        client={intent={kind="import",shipmentId="shipment-27",count=1,reported=nil},
            fault={code="IMPORT_UNCERTAIN",message="Import still needs reconciliation"},
            requests={R1={status="error",requested=1}},shipments={["shipment-27"]={count=1,imported=0}}},
        chestTest={token="reserved-test",phase="inspect"},
        settings={automationEnabled=false,maxTransferChunk=32},
    }
end
local function journalFixture(role,path)
    local w=D.world();local config=Config.defaults(role or "master")
    local store=Store.new(path or "/error-history/journal",config)
    for key,value in pairs(retainedState()) do store.data[key]=value end
    store.event("START","Original start")
    store.error("IMPORT_UNCERTAIN","Old import error",{shipmentId="shipment-27"})
    store.error("TRANSFER_VERIFY","Old receipt error",{item="minecraft:shears"})
    return w,config,store
end
local function unchangedPayload(data)
    return encode({master=data.master,client=data.client,chestTest=data.chestTest,settings=data.settings})
end

Test.case("clearing archived errors durably retains live faults and every transfer ledger across repeated loads",function()
    for _,role in ipairs({"master","supply"}) do
        local w,config,store=journalFixture(role)
        local held=unchangedPayload(store.data);local revision=store.data.revision
        local previous=encode(store.data.history);local master,client=store.data.master,store.data.client
        local ok,detail=store.clearErrors();assert(ok and type(detail)=="string")
        Test.equal(#store.data.errors,0);Test.equal(store.data.revision,revision+1)
        Test.equal(unchangedPayload(store.data),held)
        assert(store.data.master==master and store.data.client==client,"archive clear replaced the live engine journal")
        local event=store.data.history[#store.data.history]
        Test.equal(event.kind,"ERROR_HISTORY_CLEARED");Test.equal(event.context.count,2)
        local history=S.copy(store.data.history);table.remove(history)
        Test.equal(encode(history),previous,"clearing errors erased prior event history")
        for _=1,3 do
            local loaded=Store.new(store.path,config);loaded.load()
            Test.equal(#loaded.data.errors,0);Test.equal(unchangedPayload(loaded.data),held)
            Test.equal(loaded.data.history[#loaded.data.history].kind,"ERROR_HISTORY_CLEARED")
            store=loaded
        end
        local files=encode(w.files);revision=store.data.revision
        assert(store.clearErrors());Test.equal(store.data.revision,revision)
        Test.equal(encode(w.files),files,"empty archive clear performed another journal write")
        Test.equal(#w.calls,0);Test.equal(#w.sent,0)
    end
end)

Test.case("clearing the error archive bounds its audit history and never resets live safety state",function()
    local _,config,store=journalFixture();config.maxHistoryEntries=2
    store.event("RECOVERY","Original recovery audit")
    local held=unchangedPayload(store.data)
    assert(store.clearErrors());Test.equal(#store.data.history,2)
    Test.equal(store.data.history[1].kind,"RECOVERY")
    Test.equal(store.data.history[2].kind,"ERROR_HISTORY_CLEARED")
    Test.equal(unchangedPayload(store.data),held)
end)

Test.case("false nil or thrown archive saves restore the visible records history and revision",function()
    for _,mode in ipairs({"false","nil","throw"}) do
        local w,config,store=journalFixture()
        local data,files=encode(store.data),encode(w.files)
        local errors,history=store.data.errors,store.data.history
        store.save=function()
            store.data.revision=999
            if mode=="throw" then error("Simulated archive save failure",0) end
            if mode=="false" then return false,"Simulated archive save failure" end
            return nil,"Simulated archive save failure"
        end
        local ok,detail=store.clearErrors();assert(ok==false and type(detail)=="string")
        Test.equal(encode(store.data),data);Test.equal(encode(w.files),files)
        assert(store.data.errors==errors and store.data.history==history)
        assert(store.fault,"unconfirmed archive persistence did not latch its save fault")
        local loaded=Store.new(store.path,config);loaded.load()
        Test.equal(#loaded.data.errors,2);Test.equal(unchangedPayload(loaded.data),unchangedPayload(store.data))
    end
end)

Test.case("a real failed archive journal write leaves both original revisions and live safety holds intact",function()
    local w,config,store=journalFixture();local data,files=encode(store.data),encode(w.files)
    w.writeFail=true
    local ok,detail=store.clearErrors();assert(ok==false and detail:find("records retained",1,true))
    Test.equal(encode(store.data),data);Test.equal(encode(w.files),files);assert(store.fault)
    local loaded=Store.new(store.path,config);loaded.load()
    Test.equal(#loaded.data.errors,2);assert(loaded.data.master.pendingTransfer and loaded.data.master.quarantine)
    assert(loaded.data.client.intent and loaded.data.client.fault)
end)

Test.case("an archive readback failure keeps current records held while every transfer remains intact if reboot loads the written revision",function()
    local w,config,store=journalFixture();local data=encode(store.data)
    local payload=unchangedPayload(store.data);local revision=store.data.revision
    local target=store.path..((revision+1)%2==0 and ".a" or ".b")
    local originalOpen=fs.open
    fs.open=function(path,mode)
        local handle=originalOpen(path,mode)
        if path==target and mode=="r" and handle then
            local originalRead=handle.readAll
            handle.readAll=function() return originalRead().." readback mismatch" end
        end
        return handle
    end
    local ok,detail=store.clearErrors();fs.open=originalOpen
    assert(ok==false and type(detail)=="string");Test.equal(encode(store.data),data);assert(store.fault)
    local loaded=Store.new(store.path,config);loaded.load()
    Test.equal(loaded.data.revision,revision+1);Test.equal(#loaded.data.errors,0)
    Test.equal(unchangedPayload(loaded.data),payload)
    Test.equal(loaded.data.history[#loaded.data.history].kind,"ERROR_HISTORY_CLEARED")
    Test.equal(#w.calls,0);Test.equal(#w.sent,0)
end)

Test.case("clear-errors CLI runs locally before IO engine or modem construction and refuses extra arguments",function()
    for _,role in ipairs({"master","supply"}) do
        local w,config,store=journalFixture(role,"/colony/"..role.."_v4_state")
        Config.save(config)
        local held,configText=unchangedPayload(store.data),w.files[Config.PATH]
        local IO=require("colony.network.io");local Protocol=require("colony.network.protocol")
        local Engine=require(role=="master" and "colony.network.master" or "colony.network.client")
        local originalIO,originalEngine,originalOpen,originalPrint,originalRead=IO.new,Engine.new,Protocol.open,print,read
        local output={}
        IO.new=function() error("clear-errors constructed IO",0) end
        Engine.new=function() error("clear-errors constructed an engine",0) end
        Protocol.open=function() error("clear-errors opened rednet",0) end
        _G.print=function(message) output[#output+1]=tostring(message) end
        _G.read=function() error("clear-errors asked for unnecessary confirmation",0) end
        local runtime=require("colony.network.runtime")
        local invalid,invalidError=pcall(runtime.run,role,"clear-errors","extra")
        local unchanged=Store.new(store.path,config);unchanged.load();Test.equal(#unchanged.data.errors,2)
        local ok,err=pcall(runtime.run,role,"clear-errors")
        IO.new,Engine.new,Protocol.open,_G.print,_G.read=originalIO,originalEngine,originalOpen,originalPrint,originalRead
        assert(not invalid and tostring(invalidError):find("Usage:",1,true));assert(ok,err)
        assert(table.concat(output,"\n"):find("OK:",1,true))
        local loaded=Store.new(store.path,config);loaded.load();Test.equal(#loaded.data.errors,0)
        Test.equal(unchangedPayload(loaded.data),held);Test.equal(w.files[Config.PATH],configText)
        Test.equal(#w.calls,0);Test.equal(#w.sent,0)
    end
end)

local function findLabel(surface,label)
    for y=1,surface.height do local x=(surface.lines[y] or ""):find(label,1,true);if x then return x,y end end
end
local function uiFixture(options,width,height)
    local w=D.world();local config=Config.defaults("supply")
    local store=Store.new("/ui-history/journal",config)
    store.data.client=retainedState().client;store.error("IMPORT_UNCERTAIN","Historical import failure")
    local monitor=D.surface(width or 100,height or 38);local queued,callback=0,nil
    local engine={snapshot=function() return {role="supply",health={ok=false,detail="Current held import"},requests={}} end}
    engine.requestClearErrors=function(done) queued=queued+1;callback=done;return true,"Queued" end
    local ui=require("colony.network.ui").new(config,store,engine,{monitor=function() return monitor,"screen" end},nil,options)
    ui.renderTerminal=function() end;ui.view="errors";ui.draw()
    return {w=w,config=config,store=store,monitor=monitor,ui=ui,engine=engine,
        queued=function() return queued end,callback=function() return callback end}
end

Test.case("local CLEAR HISTORY waits for durable completion and keeps live health faults visible",function()
    for _,size in ipairs({{100,38},{51,19}}) do
        local f=uiFixture(nil,size[1],size[2]);local x,y=findLabel(f.monitor,"CLEAR HISTORY")
        assert(x and y,"local error archive has no clear control")
        f.ui.handleEvent("monitor_touch","screen",x,y)
        Test.equal(f.queued(),1);Test.equal(#f.store.data.errors,1)
        assert(f.ui.clearingErrors and not tostring(f.ui.notice):find("errors cleared",1,true))
        f.ui.handleEvent("monitor_touch","screen",x,y);Test.equal(f.queued(),1,"pending clear was queued twice")
        local callback=assert(f.callback());local ok,detail=f.store.clearErrors();callback(ok,detail)
        assert(not f.ui.clearingErrors and f.ui.notice:find("errors cleared",1,true))
        Test.equal(#f.store.data.errors,0);assert(f.store.data.client.intent and f.store.data.client.fault)
        assert(not findLabel(f.monitor,"CLEAR HISTORY"));f.ui.view="health";f.ui.draw()
        assert(f.monitor.dump():find("Current held import",1,true),"clearing archive hid the active health fault")
    end
end)

Test.case("failed or rejected UI clears retain the archive and read-only colony dashboards expose no clear action",function()
    local f=uiFixture();local x,y=findLabel(f.monitor,"CLEAR HISTORY")
    f.ui.handleEvent("monitor_touch","screen",x,y);f.callback()(false,"Disk full")
    assert(not f.ui.clearingErrors and f.ui.notice:find("Disk full",1,true))
    Test.equal(#f.store.data.errors,1);assert(findLabel(f.monitor,"CLEAR HISTORY"))
    f.engine.requestClearErrors=function() return false,"Another action is queued" end
    f.ui.handleEvent("monitor_touch","screen",x,y)
    assert(not f.ui.clearingErrors and f.ui.notice:find("Another action is queued",1,true))
    Test.equal(#f.store.data.errors,1)
    local remote=uiFixture({readOnly=true,displayOnly=true,monitorName="screen",sourceId=4})
    assert(not findLabel(remote.monitor,"CLEAR HISTORY"));assert(not findLabel(remote.monitor,"CLEARING..."))
    remote.ui.handleEvent("monitor_touch","screen",x,y)
    Test.equal(remote.queued(),0);Test.equal(#remote.store.data.errors,1)
end)

local function queuedRuntime(role,stopped,saveFailure)
    local w,config,store=journalFixture(role,"/colony/"..role.."_v4_state")
    store.data.chestTest=nil;store.save();Config.save(config)
    local Engine=require(role=="master" and "colony.network.master" or "colony.network.client")
    local Displays=require("colony.network.displays");local Telemetry=require("colony.network.telemetry")
    local Updater=require("colony.lib.updater");local Protocol=require("colony.network.protocol")
    local originals={engine=Engine.new,displays=Displays.new,telemetry=Telemetry.new,updater=Updater.new,
        open=Protocol.open,parallel=parallel,sleep=sleep,print=print}
    local capture={ticks=0,callbacks=0,checks=0}
    Protocol.open=function() return true end
    Engine.new=function(_,runtimeStore)
        capture.store=runtimeStore
        capture.engine={snapshot=function() return {role=role,health={ok=true,detail="Connected"},requests={}} end,
            busy=function() return true end,canUpdate=function() return false,"Held transfer" end,
            tick=function()
                capture.ticks=capture.ticks+1
                if stopped and capture.ticks==1 then error("Simulated stopped processor",0) end
            end,onMessage=function() error("Unexpected engine message",0) end,
            reconcile=function() error("Clear action was overwritten by reconcile",0) end}
        return capture.engine
    end
    Updater.new=function() return {check=function() capture.checks=capture.checks+1 end,
        install=function() error("Clear action was overwritten by update",0) end} end
    Telemetry.new=function() return {tick=function() end,onMessage=function() end} end
    Displays.new=function(_,_,_,_,updater)
        capture.updater=updater
        return {draw=function() end,renderTerminal=function() end,handleEvent=function() end}
    end
    _G.print=function() end
    _G.sleep=function() return coroutine.yield("processor wait") end
    _G.parallel={waitForAll=function(_,processor)
        local thread=coroutine.create(processor)
        local function step()
            local ok,marker=coroutine.resume(thread);assert(ok,marker)
            Test.equal(marker,"processor wait")
        end
        if stopped then
            step();step();step() -- Latch the fault, schedule, then consume its update check.
            assert(capture.engine.snapshot().statusMessage:find("Processor stopped",1,true))
        end
        local held=unchangedPayload(capture.store.data)
        local errors=#capture.store.data.errors;local revision=capture.store.data.revision
        local queued,reason=capture.engine.requestClearErrors(function(success,detail)
            capture.callbacks=capture.callbacks+1;capture.success=success;capture.detail=detail
            local durable=Store.new(store.path,config);durable.load()
            capture.callbackErrors=#durable.data.errors
            capture.callbackPayload=unchangedPayload(durable.data)
        end)
        assert(queued and type(reason)=="string");Test.equal(capture.callbacks,0)
        Test.equal(capture.store.data.revision,revision);Test.equal(#capture.store.data.errors,errors)
        assert(capture.engine.requestReconcile()==false,"reconcile overwrote the pending clear")
        assert(capture.updater.check()==false,"update check overwrote the pending clear")
        assert(capture.updater.install()==false,"installer overwrote the pending clear")
        assert(capture.engine.requestClearErrors(function() error("Duplicate clear callback",0) end)==false)
        if saveFailure then w.writeFail=true end
        step();Test.equal(capture.callbacks,1);Test.equal(capture.success,not saveFailure)
        Test.equal(capture.callbackErrors,saveFailure and errors or 0,"callback ran before durable clear result")
        Test.equal(capture.callbackPayload,held)
        Test.equal(unchangedPayload(capture.store.data),held)
        if stopped or saveFailure then
            assert(capture.engine.snapshot().statusMessage:find("Processor stopped",1,true),"clearing archive reset the stopped processor")
        end
        if stopped then Test.equal(capture.ticks,1,"successful archive clear restarted a stopped engine") end
        if saveFailure then
            Test.equal(#capture.store.data.errors,errors+1) -- The retained clear failure is itself a current processor error.
            Test.equal(capture.ticks,0,"failed archive save allowed a subsequent engine tick")
        else Test.equal(#capture.store.data.errors,0) end
    end}
    local ok,err=pcall(w.at,1,require("colony.network.runtime").run,role)
    Engine.new,Displays.new,Telemetry.new,Updater.new,Protocol.open=originals.engine,originals.displays,originals.telemetry,originals.updater,originals.open
    _G.parallel,_G.sleep,_G.print=originals.parallel,originals.sleep,originals.print
    assert(ok,err);Test.equal(#w.calls,0);Test.equal(#w.sent,0)
    return capture
end

Test.case("the running processor serializes clear requests and completes callbacks only after durable save",function()
    for _,role in ipairs({"master","supply"}) do
        queuedRuntime(role,false,false)
        queuedRuntime(role,true,false)
    end
end)

Test.case("a queued archive clear that cannot save reports failure and stops further engine work",function()
    queuedRuntime("supply",false,true)
end)

return true
