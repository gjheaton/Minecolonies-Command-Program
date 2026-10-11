local S=require("tests.support")
local Master=require("colony.network.master")
local Store=require("colony.network.store")
local Config=require("colony.network.config")
local RICE="farmersdelight:rice"

local function encoded(value)
    return textutils.serialize(value,{compact=true,allow_repetitions=true})
end

local function fixture()
    local w=S.world({asymmetricNBT=true});local m=S.computer(w,1,"master")
    m.config.automationEnabled=false
    m.config.colonies={{id=2,label="Stardust",deliveryChest="D2",returnChest="R2",deliveryChannel="D2",returnChannel="R2"}}
    w.chest(1,"D2","D2");w.chest(1,"R2","R2")
    m.rs=w.bridge(1,"prs",true)
    -- Empty compound tags are equivalent to untagged items. Keep this legacy
    -- binding fixture genuinely tagged so AP's NBT table and CC's opaque hash
    -- still require an operator to bind the original physical identity.
    local source={name=RICE,nbt={display={Name='{"text":"Legacy Rice"}'}},displayName="Legacy Rice",maxCount=64}
    source.fingerprint=w.fingerprint(source)
    local CC_HASH=w.ccNBT(source.nbt)
    local physical={name=RICE,nbt=CC_HASH,displayName=source.displayName,maxCount=64}
    local variant=m.rs.add(source,8)
    w.devices[1].prs.api.isConnected=function() return true end
    w.insert(w.channels.D2,source,1);w.insert(w.channels.D2,{name="minecraft:stone"},3)
    local request=S.request("R1",RICE,1)
    local oldRequest=S.request("R2","minecraft:stone",3)
    local record={id="R1",requestId="R1",generation=1,requested=1,status="error",errorCode="PRS_QUARANTINE",
        detail="Held legacy export needs identity binding",request=request,signature=m.matcher.itemIdentity(request.items[1]),createdAt=90}
    local oldRecord={id="R2",requestId="R2",generation=1,requested=3,status="in progress",request=oldRequest,
        signature=m.matcher.itemIdentity(oldRequest.items[1]),createdAt=90}
    local previous={id="shipment-3",requestId="R2",generation=1,item={name="minecraft:stone"},
        count=3,imported=0,verified=true,createdAt=90,session="master-1",turn=6}
    local pending={kind="export",colonyId=2,requestId="R1",generation=1,chest="D2",item=S.copy(source),
        candidate=m.matcher.requestCandidates(request)[1],variant=S.copy(variant),count=1,before=0,reported=1,
        session="master-1",turn=7,startedAt=90,verifySeconds=1,pollSeconds=.1,uncertain=true,lastDelta=0}
    m.store.data.master={sessionCounter=1,turnCounter=7,shipmentCounter=3,colonyCursor=0,
        colonies={["2"]={id=2,requests={R1=record,R2=oldRecord},shipments={previous},routeConfirmed=true}},
        craftJobs={},pendingTransfer=pending,
        quarantine={code="TRANSFER_VERIFY",message="Legacy AP identity does not match the physical chest",
            context={colonyId=2,requestId="R1",item=RICE,expected=1,reported=1}},
    }
    m.store.save()
    local f={w=w,m=m,source=source,physical=physical,originalPending=pending,before=S.copy(m.store.data)}
    function f.loaded()
        local loaded=Store.new(m.store.path,m.config);loaded.load();return loaded.data
    end
    function f.recovery() return Master.legacyExportRecovery(m.config,m.store,m.io,m.matcher) end
    function f.noMoves()
        for _,call in ipairs(w.calls) do
            assert(call.method~="export" and call.method~="import" and call.method~="craft","legacy binding moved an item")
        end
        Test.equal(#w.sent,0,"legacy binding granted a colony handoff")
    end
    function f.readonly(action)
        local files=encoded(w.files);local data=encoded(m.store.data)
        local originalNew,originalOpen=Master.new,fs.open;local writes,news=0,0
        Master.new=function() news=news+1;error("readonly binding constructed an engine",0) end
        fs.open=function(path,mode)
            if mode=="w" then writes=writes+1 end
            return originalOpen(path,mode)
        end
        local ok,err=pcall(action)
        Master.new,fs.open=originalNew,originalOpen
        assert(ok,tostring(err));Test.equal(news,0);Test.equal(writes,0)
        Test.equal(encoded(w.files),files,"readonly binding changed journal files")
        Test.equal(encoded(m.store.data),data,"readonly binding changed in-memory state")
        f.noMoves()
    end
    return f
end

Test.case("legacy binding previews different AP and physical identities without startup or writes and cancels exact-ID mismatches",function()
    local f=fixture()
    f.readonly(function()
        local recovery=f.recovery()
        local confirmed,reason=recovery.reconcileBindExport(2,"BIND 2")
        assert(not confirmed and type(reason)=="string","binding accepted confirmation without a preview")
        local ok,review=recovery.previewBindExport(2);assert(ok,tostring(review))
        Test.equal(review.colonyId,2);Test.equal(review.confirmation,"BIND 2")
        Test.equal(encoded(review.sourceItem.nbt),encoded(f.source.nbt));Test.equal(review.sourceItem.fingerprint,f.source.fingerprint)
        Test.equal(review.item.nbt,f.physical.nbt);Test.equal(review.currentNameCount,1)
        Test.equal(review.before,0);Test.equal(review.reported,1);Test.equal(review.count,1)
        Test.equal(review.chest,"D2")
        for _,confirmation in ipairs({"","BIND 3","bind 2"," BIND 2"}) do
            local accepted=recovery.reconcileBindExport(2,confirmation);assert(not accepted)
        end
        local wrong=recovery.reconcileBindExport(3,"BIND 3");assert(not wrong)
    end)
end)

Test.case("legacy binding saves an operator audit before an atomic physical shipment while preserving the AP fingerprint",function()
    local f=fixture();local recovery=f.recovery();local ok,review=recovery.previewBindExport(2);assert(ok,tostring(review))
    local originalOpen=fs.open;local writes={}
    fs.open=function(path,mode)
        local handle=originalOpen(path,mode)
        if mode=="w" and handle then
            local originalWrite=handle.write
            handle.write=function(source) writes[#writes+1]=assert(textutils.unserialize(source));return originalWrite(source) end
        end
        return handle
    end
    local called,accepted,reason=pcall(recovery.reconcileBindExport,2,"BIND 2");fs.open=originalOpen
    assert(called and accepted,tostring(reason));Test.equal(#writes,2)
    local audit,final=writes[1],writes[2]
    assert(audit.master.pendingTransfer and audit.master.quarantine)
    Test.equal(#audit.master.colonies["2"].shipments,1)
    local event=audit.history[#audit.history];Test.equal(event.kind,"OPERATOR_BIND_EXPORT")
    Test.equal(event.context.colonyId,2);Test.equal(event.context.requestId,"R1")
    Test.equal(event.context.sourceFingerprint,f.source.fingerprint)
    Test.equal(event.context.physicalNBT,f.physical.nbt);Test.equal(event.context.confirmation,"BIND 2")
    assert(final.master.pendingTransfer==nil and final.master.quarantine==nil)
    Test.equal(#final.master.colonies["2"].shipments,2);Test.equal(final.master.shipmentCounter,4)
    local shipment=final.master.colonies["2"].shipments[2]
    Test.equal(shipment.item.name,RICE);Test.equal(shipment.item.nbt,f.physical.nbt)
    Test.equal(shipment.item.fingerprint,f.source.fingerprint,"binding replaced the source RS fingerprint with the chest fingerprint")
    Test.equal(shipment.count,1);Test.equal(shipment.imported,0);Test.equal(shipment.verified,true)
    Test.equal(shipment.requestId,"R1");Test.equal(shipment.generation,1)
    Test.equal(shipment.session,"master-1");Test.equal(shipment.turn,7)
    Test.equal(encoded(f.originalPending),encoded(f.before.master.pendingTransfer),"binding mutated original AP evidence")
    Test.equal(encoded(final.master.colonies["2"].shipments[1]),encoded(f.before.master.colonies["2"].shipments[1]))
    Test.equal(encoded(f.loaded()),encoded(final))
    Test.equal(f.w.count(f.w.channels.D2,f.physical),1)
    Test.equal(f.w.count(f.w.channels.D2,{name="minecraft:stone"}),3)
    f.noMoves()
end)

Test.case("legacy binding rejects unsafe outcomes variants reservations and missing old deliveries without writing",function()
    local variants={
        {"known zero",function(f) f.m.store.data.master.pendingTransfer.reported=0 end},
        {"unknown",function(f) f.m.store.data.master.pendingTransfer.reported=nil end},
        {"partial",function(f) f.m.store.data.master.pendingTransfer.count=2 end},
        {"multiple requested",function(f) local p=f.m.store.data.master.pendingTransfer;p.count=2;p.reported=2 end},
        {"nonzero baseline",function(f) f.m.store.data.master.pendingTransfer.before=1 end},
        {"new physical baseline",function(f) f.m.store.data.master.pendingTransfer.physicalBefore={} end},
        {"return direction",function(f) f.m.store.data.master.pendingTransfer.kind="import" end},
        {"wrong colony",function(f) f.m.store.data.master.pendingTransfer.colonyId=3 end},
        {"changed chest",function(f) f.m.config.colonies[1].deliveryChest="different" end},
        {"missing quarantine",function(f) f.m.store.data.master.quarantine=nil end},
        {"unrelated fault",function(f) f.m.store.data.master.quarantine.code="PRS_READ" end},
        {"reserved client turn",function(f) f.m.store.data.master.colonies["2"].turn={id=8,session="master-1",phase="WAIT_BATCH"} end},
        {"request generation",function(f) f.m.store.data.master.colonies["2"].requests.R1.generation=2 end},
        {"empty AP fingerprint",function(f) f.m.store.data.master.pendingTransfer.item.fingerprint="" end},
        {"missing PRS connection check",function(f) f.m.io.bridgeStatus=nil end},
        {"offline PRS",function(f) f.w.devices[1].prs.api.isConnected=function() return false end end},
        {"unreadable PRS",function(f) f.w.devices[1].prs.api.listItems=function() return nil,"NOT_CONNECTED" end end},
        {"two physical variants",function(f) f.w.insert(f.w.channels.D2,{name=RICE,nbt=string.rep("c",32)},1) end},
        {"extra physical quantity",function(f) f.w.insert(f.w.channels.D2,f.physical,1) end},
        {"old delivery missing",function(f) f.w.take(f.w.channels.D2,{name="minecraft:stone"},1) end},
    }
    for _,variant in ipairs(variants) do
        local f=fixture();variant[2](f)
        f.readonly(function()
            local accepted,reason=f.recovery().previewBindExport(2)
            assert(not accepted and type(reason)=="string",variant[1].." allowed an unsafe legacy binding")
        end)
    end
end)

Test.case("legacy binding revalidates the original evidence source route and all staged deliveries after preview",function()
    local changes={
        {"physical identity",function(f) f.w.take(f.w.channels.D2,f.physical,1);f.w.insert(f.w.channels.D2,{name=RICE,nbt=string.rep("c",32)},1) end},
        {"source fingerprint",function(f) f.m.store.data.master.pendingTransfer.item.fingerprint=string.rep("d",32) end},
        {"source inventory",function(f) f.w.devices[1].prs.api.listItems=function() return nil,"NOT_CONNECTED" end end},
        {"route channel",function(f) f.m.config.colonies[1].deliveryChannel="changed-channel" end},
        {"bridge selection",function(f) f.m.config.playerBridgeName="different-prs" end},
        {"new reservation",function(f) f.m.store.data.master.colonies["2"].turn={id=8,session="master-1",phase="WAIT_BATCH"} end},
        {"other delivery",function(f) f.w.take(f.w.channels.D2,{name="minecraft:stone"},1) end},
    }
    for _,change in ipairs(changes) do
        local f=fixture();local recovery=f.recovery();local ok,review=recovery.previewBindExport(2);assert(ok,tostring(review))
        change[2](f)
        f.readonly(function()
            local accepted,reason=recovery.reconcileBindExport(2,"BIND 2")
            assert(not accepted and type(reason)=="string",change[1].." changed after preview but binding was accepted")
        end)
    end
end)

local function blockOtherRequests(f)
    local state=f.m.store.data.master;local cs=state.colonies["2"]
    local reason=state.quarantine.message
    cs.requests.R2.status,cs.requests.R2.errorCode,cs.requests.R2.detail="error","PRS_QUARANTINE",reason
    cs.requests.R3={id="R3",status="error",errorCode="CLIENT",detail="Colony bridge unavailable"}
    cs.requests.R4={id="R4",status="error",errorCode="PRS_QUARANTINE",detail="Legacy quarantine wording"}
    cs.error=reason
    state.colonies["3"]={id=3,requests={
        related={id="related",status="error",errorCode="PRS_QUARANTINE",detail=reason},
        unrelated={id="unrelated",status="error",errorCode="CRAFT_UNKNOWN",detail="Craft result unknown"},
    },shipments={},error="Colony connection unavailable"}
end

Test.case("legacy binding resumes all PRS quarantine requests while retaining independent client and craft faults",function()
    local f=fixture();blockOtherRequests(f)
    local state=f.m.store.data.master
    state.craftJobs.rice={state="crafting",item=S.copy(f.source),exported=5,count=10,createdAt=90}
    state.craftJobs.other={state="uncertain",item={name=RICE,nbt={Batch="other"}},exported=7,count=10,createdAt=90}
    f.m.store.save()
    local unrelated=S.copy({client=state.colonies["2"].requests.R3,
        craft=state.colonies["3"].requests.unrelated,connection=state.colonies["3"].error,job=state.craftJobs.other})
    local recovery=f.recovery();local ok,review=recovery.previewBindExport(2);assert(ok,tostring(review))
    local bound,reason=recovery.reconcileBindExport(2,"BIND 2");assert(bound,tostring(reason))
    local saved=f.loaded().master
    Test.equal(saved.colonies["2"].requests.R1.status,"in progress")
    Test.equal(saved.colonies["2"].requests.R2.status,"requested");Test.equal(saved.colonies["2"].requests.R2.errorCode,nil)
    Test.equal(saved.colonies["2"].requests.R4.status,"requested");Test.equal(saved.colonies["2"].requests.R4.errorCode,nil)
    Test.equal(saved.colonies["3"].requests.related.status,"requested");Test.equal(saved.colonies["3"].requests.related.errorCode,nil)
    Test.equal(saved.colonies["2"].error,nil)
    Test.equal(encoded({client=saved.colonies["2"].requests.R3,
        craft=saved.colonies["3"].requests.unrelated,connection=saved.colonies["3"].error,job=saved.craftJobs.other}),encoded(unrelated))
    Test.equal(saved.craftJobs.rice.exported,6)
    f.noMoves()
end)

Test.case("legacy binding audit or clearing journal failure keeps the export held and a restart never resends it",function()
    for _,failedWrite in ipairs({1,2}) do
        local f=fixture()
        blockOtherRequests(f)
        local job={state="crafting",item=S.copy(f.source),exported=5,count=10,createdAt=90}
        f.m.store.data.master.craftJobs.rice=job;f.m.store.save()
        local beforeColonies=S.copy(f.m.store.data.master.colonies)
        local originalShipments=f.m.store.data.master.colonies["2"].shipments
        local recovery=f.recovery();local ok,review=recovery.previewBindExport(2);assert(ok,tostring(review))
        local originalOpen=fs.open;local writes=0
        fs.open=function(path,mode)
            if mode=="w" then writes=writes+1;if writes==failedWrite then return nil,"Write failure" end end
            return originalOpen(path,mode)
        end
        local called,accepted,reason=pcall(recovery.reconcileBindExport,2,"BIND 2");fs.open=originalOpen
        assert(called and not accepted and type(reason)=="string")
        local state=f.m.store.data.master
        assert(state.pendingTransfer and state.quarantine,"failed persistence released the held export")
        Test.equal(state.shipmentCounter,3);Test.equal(#state.colonies["2"].shipments,1)
        Test.equal(state.colonies["2"].shipments,originalShipments,"failed clearing replaced a live shipment ledger reference")
        Test.equal(state.craftJobs.rice,job);Test.equal(job.exported,5,"failed clearing credited the retained craft output")
        Test.equal(encoded(state.colonies),encoded(beforeColonies),"failed binding cleared another request's fault")
        local saved=f.loaded()
        assert(saved.master.pendingTransfer and saved.master.quarantine)
        Test.equal(saved.master.shipmentCounter,3);Test.equal(#saved.master.colonies["2"].shipments,1)
        Test.equal(saved.master.craftJobs.rice.exported,5)
        Test.equal(encoded(saved.master.colonies),encoded(beforeColonies),"failed binding persisted changes to other request faults")
        Test.equal(#saved.history,#f.before.history+(failedWrite==2 and 1 or 0))
        if failedWrite==2 then Test.equal(saved.history[#saved.history].kind,"OPERATOR_BIND_EXPORT") end
        f.m.restart()
        for _=1,8 do f.w.tick(1);f.w.advance(.25) end
        assert(f.m.store.data.master.pendingTransfer and f.m.store.data.master.quarantine)
        Test.equal(#f.m.store.data.master.colonies["2"].shipments,1)
        Test.equal(f.w.count(f.w.channels.D2,f.physical),1)
        f.noMoves()
    end
end)

Test.case("a freshly restarted master sends the bound original rice delivery for one exact colony import without a new export",function()
    local f=fixture();local recovery=f.recovery();local ok,review=recovery.previewBindExport(2);assert(ok,tostring(review))
    local accepted,reason=recovery.reconcileBindExport(2,"BIND 2");assert(accepted,tostring(reason));f.noMoves()
    local c=S.computer(f.w,2,"supply")
    c.config.deliveryChannel="D2";c.config.returnChannel="R2"
    f.w.chest(2,"delivery","D2");f.w.chest(2,"returns","R2")
    c.rs=f.w.bridge(2,"crs",false);c.integrator=f.w.integrator(2,"integrator")
    c.integrator.requests={S.request("R1",RICE,1),S.request("R2","minecraft:stone",3)}
    c.start();f.m.config.automationEnabled=true;f.m.restart()
    local function step()
        f.w.tick(1);f.w.tick(2);f.w.flush();f.w.advance(.25)
    end
    local function imported()
        local cs=f.m.store.data.master.colonies["2"]
        return #cs.shipments==2 and cs.shipments[2].imported==1
    end
    for _=1,100 do if imported() then break end;step() end
    assert(imported(),"the bound original shipment never reached the colony")
    for _=1,24 do step() end
    Test.equal(#f.w.callsFor("export",true),0,"binding caused the master to export a replacement item")
    local exactImports=0
    for _,call in ipairs(f.w.callsFor("import",false)) do
        if call.filter.fingerprint==f.source.fingerprint then exactImports=exactImports+1;Test.equal(call.filter.count,1) end
    end
    Test.equal(exactImports,1,"the original rice was not imported exactly once by its preserved AP identity")
    Test.equal(f.w.count(f.w.channels.D2,f.physical),0)
    local rice=c.rs.items[f.w.identity(f.source)];assert(rice);Test.equal(rice.amount,1)
    Test.equal(c.store.data.client.requests.R1.status,"in progress","binding claimed delivery before MineColonies removed its request")
    Test.equal(f.m.store.data.master.colonies["2"].requests.R1.status,"in progress")
end)

local function runtimeFixture(role)
    -- Runtime's UI imports need CC colors even though these local commands
    -- return before display creation and the receiver/processor event loop.
    require("tests.display_support").world()
    local f=fixture();local config=role=="supply" and Config.defaults("supply") or f.m.config
    Config.save(config)
    local persisted=Store.new("/colony/"..(role or "master").."_v4_state",config)
    persisted.data=S.copy(f.m.store.data);persisted.save();f.m.store=persisted
    f.w.devices[1].modem=nil
    function f.cli(mode,id,answer,duringPrompt,extra)
        local Runtime=require("colony.network.runtime")
        local Client=require("colony.network.client")
        local originalMasterNew,originalClientNew=Master.new,Client.new
        local originalOpen,originalPrint,originalWrite,originalRead=fs.open,print,write,read
        local out={lines={},prompts=0,writes=0,news=0,journals={}}
        local function noEngine() out.news=out.news+1;error("local recovery command constructed an engine",0) end
        Master.new,Client.new=noEngine,noEngine
        fs.open=function(path,mode)
            local handle=originalOpen(path,mode)
            if mode=="w" then
                out.writes=out.writes+1
                if handle then
                    local originalHandleWrite=handle.write
                    handle.write=function(source) out.journals[#out.journals+1]=assert(textutils.unserialize(source));return originalHandleWrite(source) end
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
            out.prompts=out.prompts+1;Test.equal(out.writes,0,"CLI changed state before confirmation")
            if duringPrompt then duringPrompt(f) end
            return answer or ""
        end
        out.ok,out.err=pcall(Runtime.run,role or "master",mode,id,extra)
        Master.new,Client.new=originalMasterNew,originalClientNew
        fs.open,_G.print,_G.write,_G.read=originalOpen,originalPrint,originalWrite,originalRead
        out.text=table.concat(out.lines,"\n")
        Test.equal(out.news,0,"local inspection/recovery constructed an engine")
        f.noMoves()
        return out
    end
    return f
end

Test.case("transferdiag and cancelled reconcile-bind inspect the native AP and CC identity mismatch without writes modem or engine",function()
    local f=runtimeFixture();local files=encoded(f.w.files)
    local diag=f.cli("transferdiag")
    assert(diag.ok,tostring(diag.err));Test.equal(diag.prompts,0);Test.equal(diag.writes,0)
    assert(diag.text:find("AP item NBT: table:",1,true))
    assert(diag.text:find("CC NBT: string: "..f.physical.nbt,1,true))
    assert(diag.text:find("AP fingerprint: "..f.source.fingerprint,1,true))
    assert(diag.text:find("Original/current AP identity count: 0 / 0",1,true))
    assert(diag.text:find("Same-name quantity: 1 (identity unverified)",1,true))
    Test.equal(encoded(f.w.files),files)
    for _,answer in ipairs({"","BIND 3","cancel"}) do
        local current=runtimeFixture();local before=encoded(current.w.files)
        local out=current.cli("reconcile-bind","2",answer)
        assert(out.ok,tostring(out.err));Test.equal(out.prompts,1);Test.equal(out.writes,0)
        assert(out.text:find("Type BIND 2",1,true));assert(out.text:find("CANCELLED",1,true))
        assert(out.text:find("ABSENT before",1,true));assert(out.text:find("untouched and unreplaced",1,true))
        Test.equal(encoded(current.w.files),before)
        assert(current.loaded().master.pendingTransfer and current.loaded().master.quarantine)
    end
end)

Test.case("reconcile-bind exact CLI confirmation persists the audited original physical shipment and rechecks prompt-time changes",function()
    local f=runtimeFixture();local out=f.cli("reconcile-bind","2","BIND 2")
    assert(out.ok,tostring(out.err));Test.equal(out.prompts,1);Test.equal(out.writes,2)
    assert(out.text:find("OK:",1,true))
    assert(out.journals[1].master.pendingTransfer and out.journals[1].master.quarantine)
    Test.equal(out.journals[1].history[#out.journals[1].history].kind,"OPERATOR_BIND_EXPORT")
    local saved=f.loaded();assert(saved.master.pendingTransfer==nil and saved.master.quarantine==nil)
    Test.equal(#saved.master.colonies["2"].shipments,2)
    Test.equal(saved.master.colonies["2"].shipments[2].item.nbt,f.physical.nbt)
    Test.equal(saved.master.colonies["2"].shipments[2].item.fingerprint,f.source.fingerprint)
    for _,change in ipairs({
        function(current) current.w.take(current.w.channels.D2,current.physical,1) end,
        function(current) current.w.devices[1].prs.api.isConnected=function() return false end end,
    }) do
        local current=runtimeFixture();local before=encoded(current.w.files)
        local blocked=current.cli("reconcile-bind","2","BIND 2",change)
        assert(blocked.ok,tostring(blocked.err));Test.equal(blocked.prompts,1);Test.equal(blocked.writes,0)
        assert(blocked.text:find("BLOCKED:",1,true));Test.equal(encoded(current.w.files),before)
        assert(current.loaded().master.pendingTransfer and current.loaded().master.quarantine)
    end
end)

Test.case("reconcile-bind accepts unrelated PRS stock amount changes while the operator confirmation is pending",function()
    local f=runtimeFixture();local unrelated={name="minecraft:dirt"}
    f.m.rs.add(unrelated,4)
    local out=f.cli("reconcile-bind","2","BIND 2",function(current) current.m.rs.add(unrelated,3) end)
    assert(out.ok,tostring(out.err));Test.equal(out.prompts,1);Test.equal(out.writes,2)
    assert(out.text:find("OK:",1,true),"an unrelated stock quantity invalidated the held export evidence")
    local saved=f.loaded();assert(saved.master.pendingTransfer==nil and saved.master.quarantine==nil)
    Test.equal(#saved.master.colonies["2"].shipments,2)
    Test.equal(saved.master.colonies["2"].shipments[2].item.nbt,f.physical.nbt)
    Test.equal(saved.master.colonies["2"].shipments[2].item.fingerprint,f.source.fingerprint)
    Test.equal(f.m.rs.items[f.w.identity(unrelated)].amount,7)
    Test.equal(f.w.count(f.w.channels.D2,f.physical),1)
end)

Test.case("legacy transfer CLI rejects wrong role missing extra or unknown colony arguments before prompting or writing",function()
    for _,args in ipairs({
        {mode="reconcile-bind"},
        {mode="reconcile-bind",id="2",extra="unexpected"},
        {mode="transferdiag",id="2"},
        {mode="reconcile-bind",id="2",role="supply"},
        {mode="transferdiag",role="supply"},
        {mode="reconcile-bind",id="3",blocked=true},
    }) do
        local f=runtimeFixture(args.role);local before=encoded(f.w.files)
        local out=f.cli(args.mode,args.id,"BIND 2",nil,args.extra)
        Test.equal(out.prompts,0);Test.equal(out.writes,0)
        if args.blocked then assert(out.ok and out.text:find("BLOCKED:",1,true))
        else assert(not out.ok and tostring(out.err):find("Usage:",1,true)) end
        Test.equal(encoded(f.w.files),before)
        assert(f.loaded().master.pendingTransfer and f.loaded().master.quarantine)
    end
end)

return true
