local S=require("tests.support")
local Config=require("colony.network.config")
local Store=require("colony.network.store")
local function fixture(role,state)
    local w=S.world();local c=S.computer(w,1,role or "master");Config.save(c.config)
    local store=Store.new("/colony/"..c.config.role.."_v4_state",c.config);store.data=S.copy(state or {schema=4,revision=0,history={},errors={}})
    store.data.history=store.data.history or {};store.data.errors=store.data.errors or {};store.save()
    w.rs=w.bridge(1,role=="supply" and "crs" or "prs",role~="supply")
    _G.write=function() end;_G.read=function() error("unexpected interactive setup") end
    -- Setup/set execute the real runtime before entering its event loop.
    local Runtime=require("colony.network.runtime")
    function w.run(...) return w.at(1,Runtime.run,c.config.role,...) end
    return w,c,store
end

Test.case("runtime setup refuses retained turn, craft, shipment and chest test before prompting",function()
    for _,state in ipairs({
        {master={colonies={["2"]={turn={phase="WAIT_BATCH"}}}}},
        {master={craftJobs={stone={state="timed out"}}}},
        {master={colonies={["2"]={shipments={{count=4,imported=2}}}}}},
        {chestTest={token="retained",phase="export_intent"}},
    }) do
        local w=fixture("master",state)
        local configBefore=w.files[Config.PATH]
        local ok,err=pcall(w.run,"setup");assert(not ok and tostring(err):find("retained turns"))
        Test.equal(w.files[Config.PATH],configBefore)
        Test.equal(#w.callsFor(nil,true),0)
    end
end)

Test.case("runtime typed settings permit policy changes but reject hardware changes with retained work",function()
    local w=fixture("master",{master={pendingTransfer={kind="export",count=4}}})
    local ok,err=pcall(w.run,"set","playerBridgeName","replacement")
    assert(not ok and tostring(err):find("Retained work prevents"))
    w.run("set","craftingTimeoutSeconds","900");w.run("set","autoCraftEnabled","false")
    local config=Config.load("master");Test.equal(config.craftingTimeoutSeconds,900);Test.equal(config.autoCraftEnabled,false)
    Test.equal(config.playerBridgeName,"prs");Test.equal(#w.callsFor(nil,true),0)
end)

Test.case("runtime rejects invalid numeric and boolean values without changing persisted config",function()
    local w=fixture("master");local before=w.files[Config.PATH]
    for _,args in ipairs({{"set","maxTransferChunk","0"},{"set","autoCraftEnabled","yes"},{"set","masterId","4"}}) do
        local ok=pcall(w.run,table.unpack(args));assert(not ok)
        Test.equal(w.files[Config.PATH],before,"invalid CLI setting modified configuration")
    end
    Test.equal(#w.callsFor(nil,true),0)
end)

Test.case("runtime supply hardware changes are blocked by an interrupted import",function()
    local w=fixture("supply",{client={intent={kind="import",count=4,reported=4}}})
    local ok,err=pcall(w.run,"set","masterId","9");assert(not ok and tostring(err):find("Retained work prevents"))
    w.run("set","onHandTimeoutSeconds","180")
    local config=Config.load("supply");Test.equal(config.masterId,1);Test.equal(config.onHandTimeoutSeconds,180)
    Test.equal(#w.callsFor(nil,true),0)
end)

local function recoveryFixture()
    local w,c,store=fixture("master")
    c.config.colonyResponseTimeoutSeconds=3;c.config.helloSeconds=1
    c.config.colonies={
        {id=2,deliveryChest="D2",returnChest="R2",deliveryChannel="red-white-blue",returnChannel="red-white-black"},
        {id=3,deliveryChest="D3",returnChest="R3",deliveryChannel="yellow-white-blue",returnChannel="yellow-white-black"},
    }
    Config.save(c.config)
    for _,name in ipairs({"D2","R2","D3","R3"}) do w.chest(1,name,name) end
    local request=S.request("R2","minecraft:stone",4)
    local candidate=c.matcher.requestCandidates(request)[1]
    local variant=w.rs.add({name="minecraft:stone"},8)
    local record={id="R2",generation=1,requested=4,status="error",errorCode="PRS_QUARANTINE",createdAt=90,request=request}
    store.data.master={sessionCounter=1,turnCounter=1,shipmentCounter=0,
        colonies={["2"]={id=2,requests={R2=record},shipments={}},["3"]={id=3,requests={},shipments={}}},
        pendingTransfer={kind="export",colonyId=2,requestId="R2",generation=1,chest="D2",
            item={name=variant.name,fingerprint=variant.fingerprint},candidate=candidate,variant=variant,
            count=4,before=0,reported=0,session="master-1",turn=1,startedAt=90,verifySeconds=1,pollSeconds=.1,
            definiteZero=true,lastDelta=0,uncertain=true},
        quarantine={code="TRANSFER_VERIFY",message="PRS reported stock but exported zero; possible desync"},craftJobs={},
    }
    store.save()
    function w.hello()
        w.queue[#w.queue+1]={from=2,to=1,protocol=require("colony.network.protocol").NAME,
            message={version=1,kind="hello",role="supply",deliveryChannel="red-white-blue",returnChannel="red-white-black"}}
    end
    function w.reloaded()
        local saved=Store.new("/colony/master_v4_state",c.config);saved.load();return saved.data.master
    end
    return w,c,store
end

Test.case("CLI reconciliation confirms live colony and verifies one guarded probe without granting normal turns",function()
    local w=recoveryFixture();w.hello();w.run("reconcile")
    local state=w.reloaded()
    Test.equal(#w.callsFor("export",true),1,"CLI reconciliation repeated probe mutation")
    Test.equal(w.callsFor("export",true)[1].chest,"D2")
    Test.equal(w.callsFor("export",true)[1].filter.count,1)
    assert(state.pendingTransfer==nil and state.quarantine==nil)
    assert(state.colonies["2"].turn==nil,"verified CLI recovery retained internal turn")
    Test.equal(#state.colonies["2"].shipments,1)
    Test.equal(state.colonies["2"].shipments[1].count,1)
    Test.equal(w.count(w.channels.D2,{name="minecraft:stone"}),1)
    Test.equal(w.count(w.channels.D3,{name="minecraft:stone"}),0)
    for _,packet in ipairs(w.sent) do assert(packet.message.kind~="turn","CLI reconciliation granted a normal supply turn") end
end)

Test.case("CLI reconciliation waits a bounded interval for offline colony without any PRS mutation",function()
    local w,c=recoveryFixture();local started=w.now;w.run("reconcile")
    Test.equal(w.now-started,c.config.colonyResponseTimeoutSeconds)
    Test.equal(#w.callsFor("export",true),0)
    Test.equal(#w.callsFor("import",true),0)
    local state=w.reloaded();assert(state.pendingTransfer and state.quarantine)
    Test.equal(#state.colonies["2"].shipments,0)
end)

local function zeroRecoveryFixture()
    -- Generate the retained intent with the real supply engine, including its
    -- UNKNOWN bridge result and the master's closing RESULT, before the CLI.
    local w,c=S.clientFixture()
    local rice={name="farmersdelight:rice",displayName="Rice",nbt={batch="reserved"}}
    local deliveries={
        {id="D-RICE",requestId="R1",item=rice,count=1,verified=true,createdAt=99},
        {id="D-STONE",requestId="R2",item={name="minecraft:stone"},count=3,verified=true,createdAt=100},
    }
    c.integrator.requests={S.request("R1",rice.name,1),S.request("R2","minecraft:stone",3)}
    w.insert(w.channels.D2,rice,1);w.insert(w.channels.D2,{name="minecraft:stone"},3)
    local api=w.devices[2].crs.api;local originalImport=api.importItemFromPeripheral;local attempts=0
    api.importItemFromPeripheral=function() attempts=attempts+1;return nil,"NOT_CONNECTED" end
    assert(w.grant(1,deliveries));assert(w.result(1,deliveries,{{id="R1",status="error"},{id="R2",status="error"}}))
    Test.equal(attempts,1)
    local held=c.store.data.client
    assert(held.intent and held.intent.reported==nil and held.fault)
    Test.equal(held.intent.beforeChest,1);Test.equal(held.intent.beforeImported,0)
    Test.equal(held.turn.phase,"finished");Test.equal(held.shipments["D-RICE"].imported,0)
    api.importItemFromPeripheral=originalImport;api.isConnected=function() return true end
    Config.save(c.config)
    local path="/colony/supply_v4_state"
    local persisted=Store.new(path,c.config);persisted.data=S.copy(c.store.data);persisted.save()
    local f={w=w,c=c,rice=rice,api=api,path=path,before=S.copy(persisted.data),configBefore=w.files[Config.PATH]}
    w.calls={};w.sent={};w.queue={}
    w.devices[2].modem=nil -- Local operator recovery must work without rednet.
    function f.loaded()
        local saved=Store.new(path,c.config);saved.load();return saved.data
    end
    function f.run(id,answer,duringPrompt,role)
        local Runtime=require("colony.network.runtime")
        local Client=require("colony.network.client")
        local originalNew,originalOpen=Client.new,fs.open
        local originalPrint,originalWrite,originalRead=print,write,read
        local out={lines={},prompts=0,writes=0,engineNews=0,journals={}}
        Client.new=function() out.engineNews=out.engineNews+1;error("reconcile-zero constructed the supply engine",0) end
        fs.open=function(name,mode)
            local handle=originalOpen(name,mode)
            if mode=="w" then
                out.writes=out.writes+1
                if handle and name:sub(1,#path)==path then
                    local originalHandleWrite=handle.write
                    handle.write=function(source)
                        out.journals[#out.journals+1]=assert(textutils.unserialize(source))
                        return originalHandleWrite(source)
                    end
                end
            end
            return handle
        end
        print=function(...)
            local pieces={};for index=1,select("#",...) do pieces[index]=tostring(select(index,...)) end
            out.lines[#out.lines+1]=table.concat(pieces," ")
        end
        write=function(value) out.lines[#out.lines+1]=tostring(value) end
        read=function()
            out.prompts=out.prompts+1
            Test.equal(out.writes,0,"recovery wrote state before the operator's confirmation")
            if duringPrompt then duringPrompt(f) end
            return answer or ""
        end
        out.ok,out.err=pcall(w.at,2,Runtime.run,role or "supply","reconcile-zero",id)
        Client.new,fs.open=originalNew,originalOpen
        _G.print,_G.write,_G.read=originalPrint,originalWrite,originalRead
        out.text=table.concat(out.lines,"\n")
        Test.equal(out.engineNews,0,"preview/confirmation constructed an engine and could append boot faults")
        for _,call in ipairs(w.calls) do
            assert(call.method~="import" and call.method~="export" and call.method~="craft","reconcile-zero mutated an RS bridge")
            assert(not call.prs,"reconcile-zero touched player RS")
        end
        Test.equal(#w.sent,0,"local operator recovery sent a network handoff")
        Test.equal(w.files[Config.PATH],f.configBefore,"operator recovery changed transfer configuration")
        return out
    end
    return f
end

Test.case("reconcile-zero previews the real unknown rice import and cancellation writes no journal or boot fault",function()
    for _,answer in ipairs({"","cancel","ZERO D-STONE"}) do
        local f=zeroRecoveryFixture();local files=textutils.serialize(f.w.files,{compact=true})
        local out=f.run("D-RICE",answer)
        assert(out.ok,tostring(out.err));Test.equal(out.prompts,1);Test.equal(out.writes,0)
        assert(out.text:find("ZERO D-RICE",1,true),"CLI did not print the exact shipment-bound confirmation")
        assert(out.text:find("farmersdelight:rice",1,true),"preview omitted the retained item's identity")
        assert(out.text:find("delivery",1,true),"preview omitted the retained chest")
        assert(out.text:find("Original/current chest quantity: 1 / 1",1,true))
        assert(out.text:find("Imported ledger stays: 0",1,true))
        assert(out.text:find("CANCELLED",1,true))
        Test.equal(textutils.serialize(f.w.files,{compact=true}),files,"cancelled preview changed persisted state")
        Test.equal(f.w.count(f.w.channels.D2,f.rice),1)
        local saved=f.loaded();assert(saved.client.intent and saved.client.fault)
        Test.equal(#saved.errors,#f.before.errors,"cancelled command appended an engine boot fault")
    end
end)

Test.case("reconcile-zero exact confirmation durably audits while held then clears without credit or transfers",function()
    local f=zeroRecoveryFixture();local out=f.run("D-RICE","ZERO D-RICE")
    assert(out.ok,tostring(out.err));Test.equal(out.prompts,1);Test.equal(out.writes,2);Test.equal(#out.journals,2)
    local audited,cleared=out.journals[1],out.journals[2]
    assert(audited.client.intent and audited.client.fault,"operator audit was not persisted before releasing the hold")
    assert(cleared.client.intent==nil and cleared.client.fault==nil)
    local event=audited.history[#audited.history]
    Test.equal(event.kind,"OPERATOR_ZERO_IMPORT");Test.equal(event.context.shipmentId,"D-RICE")
    Test.equal(event.context.operatorConfirmation,"ZERO D-RICE")
    Test.equal(event.context.beforeChest,1);Test.equal(event.context.currentChest,1)
    Test.equal(event.context.beforeImported,0)
    Test.equal(event.context.session,f.before.client.intent.session)
    Test.equal(event.context.turn,f.before.client.intent.turn)
    Test.equal(event.context.item.name,f.rice.name)
    Test.equal(event.context.item.nbt,nil)
    local identity=f.c.matcher.itemIdentity(f.rice)
    Test.equal(event.context.itemIdentity,identity:sub(1,256))
    Test.equal(event.context.itemIdentityLength,#identity)
    Test.equal(event.context.itemIdentityTruncated,#identity>256)
    local saved=f.loaded();assert(saved.client.intent==nil and saved.client.fault==nil)
    Test.equal(#saved.history,#f.before.history+1);Test.equal(#saved.errors,#f.before.errors)
    Test.equal(saved.revision,f.before.revision+2)
    local expected=S.copy(f.before.client);expected.intent=nil;expected.fault=nil
    Test.equal(textutils.serialize(saved.client,{compact=true}),textutils.serialize(expected,{compact=true}),"confirmed zero changed the delivery/request ledger")
    Test.equal(f.w.count(f.w.channels.D2,f.rice),1)
    Test.equal(f.w.count(f.w.channels.D2,{name="minecraft:stone"}),3)
    Test.equal(saved.client.shipments["D-RICE"].imported,0)
end)

Test.case("reconcile-zero rechecks the physical source after the operator prompt and refuses a removed rice item",function()
    local f=zeroRecoveryFixture();local files=textutils.serialize(f.w.files,{compact=true})
    local out=f.run("D-RICE","ZERO D-RICE",function(current) current.w.take(current.w.channels.D2,current.rice,1) end)
    assert(out.ok,tostring(out.err));Test.equal(out.prompts,1);Test.equal(out.writes,0)
    assert(out.text:find("BLOCKED",1,true),"changed physical evidence was not reported as blocked")
    Test.equal(textutils.serialize(f.w.files,{compact=true}),files)
    local saved=f.loaded();assert(saved.client.intent and saved.client.fault)
    Test.equal(saved.client.shipments["D-RICE"].imported,0)
end)

Test.case("reconcile-zero rechecks bridge connection after prompting and retains the hold on disconnect",function()
    local f=zeroRecoveryFixture();local files=textutils.serialize(f.w.files,{compact=true})
    local out=f.run("D-RICE","ZERO D-RICE",function(current) current.api.isConnected=function() return false end end)
    assert(out.ok,tostring(out.err));Test.equal(out.prompts,1);Test.equal(out.writes,0)
    assert(out.text:find("BLOCKED",1,true))
    Test.equal(textutils.serialize(f.w.files,{compact=true}),files)
    local saved=f.loaded();assert(saved.client.intent and saved.client.fault)
end)

Test.case("reconcile-zero missing or different shipment IDs fail before prompting without journal changes",function()
    for _,id in ipairs({false,"D-STONE","missing"}) do
        local f=zeroRecoveryFixture();local files=textutils.serialize(f.w.files,{compact=true})
        local out=f.run(id or nil,"ZERO D-RICE")
        Test.equal(out.prompts,0);Test.equal(out.writes,0)
        if id==false then assert(not out.ok and tostring(out.err):find("Usage:",1,true))
        else assert(out.ok and out.text:find("BLOCKED",1,true),"different shipment argument was not rejected") end
        Test.equal(textutils.serialize(f.w.files,{compact=true}),files)
        local saved=f.loaded();assert(saved.client.intent and saved.client.fault)
    end
    local f=zeroRecoveryFixture();Config.save(Config.defaults("master"));f.configBefore=f.w.files[Config.PATH]
    local files=textutils.serialize(f.w.files,{compact=true})
    local out=f.run("D-RICE","ZERO D-RICE",nil,"master")
    assert(not out.ok and tostring(out.err):find("Usage:",1,true));Test.equal(out.prompts,0);Test.equal(out.writes,0)
    Test.equal(textutils.serialize(f.w.files,{compact=true}),files)
end)

Test.case("reconcile-zero disconnected or unreadable RS preview never asks for confirmation or writes state",function()
    for _,mode in ipairs({"disconnected","stock unreadable"}) do
        local f=zeroRecoveryFixture();local files=textutils.serialize(f.w.files,{compact=true})
        if mode=="disconnected" then f.api.isConnected=function() return false end
        else f.api.listItems=function() return nil,"NOT_CONNECTED" end end
        local out=f.run("D-RICE","ZERO D-RICE")
        assert(out.ok,tostring(out.err));Test.equal(out.prompts,0);Test.equal(out.writes,0)
        assert(out.text:find("BLOCKED",1,true))
        Test.equal(textutils.serialize(f.w.files,{compact=true}),files)
        local saved=f.loaded();assert(saved.client.intent and saved.client.fault)
    end
end)
return true
