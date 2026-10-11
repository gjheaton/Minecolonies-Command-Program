local S=require("tests.support")
local function fixture(count,options)
    local w=S.world(options);local master=S.computer(w,1,"master")
    master.rs=w.bridge(1,"prs",true);master.config.colonies={}
    for id=2,(count or 2)+1 do
        local c=S.computer(w,id,"supply")
        c.config.deliveryChannel="D"..id;c.config.returnChannel="R"..id
        w.chest(id,"delivery","D"..id);w.chest(id,"returns","R"..id)
        w.chest(1,"delivery-"..id,"D"..id);w.chest(1,"returns-"..id,"R"..id)
        c.rs=w.bridge(id,"crs",false);c.integrator=w.integrator(id,"integrator")
        c.integrator.requests={S.request("R"..id,"minecraft:stone",4)}
        master.config.colonies[#master.config.colonies+1]={id=id,label="Colony "..id,
            deliveryChest="delivery-"..id,returnChest="returns-"..id,deliveryChannel="D"..id,returnChannel="R"..id}
        c.start()
    end
    master.start()
    function w.step()
        w.tick(1)
        for id=2,(count or 2)+1 do w.tick(id) end
        w.flush();w.advance(.25)
    end
    function w.untilTrue(predicate,detail,limit)
        for _=1,limit or 160 do if predicate() then return end;w.step() end
        assert(predicate(),detail or "simulation condition was not reached")
    end
    function w.grants()
        local seen,out={},{}
        for _,packet in ipairs(w.sent) do if packet.message.kind=="turn" then
            local key=packet.to..":"..packet.message.session..":"..packet.message.turn
            if not seen[key] then seen[key]=true;out[#out+1]=packet end
        end end
        return out
    end
    return w,master
end

Test.case("two colonies share one PRS writer in round-robin turns without duplicate shipment",function()
    local w,m=fixture();m.rs.add({name="minecraft:stone"},64)
    w.untilTrue(function()
        local a,b=w.computers[2],w.computers[3]
        return a.rs.items[w.identity({name="minecraft:stone"})] and b.rs.items[w.identity({name="minecraft:stone"})]
    end,"both colonies failed to import their verified shipments")
    local grants=w.grants();Test.equal(grants[1].to,2);Test.equal(grants[2].to,3);Test.equal(grants[3].to,2)
    for _,call in ipairs(w.callsFor(nil,true)) do Test.equal(call.computer,1,"PRS writer was not master") end
    for id=2,3 do
        local c=w.computers[id];Test.equal(c.rs.items[w.identity({name="minecraft:stone"})].amount,4)
        Test.equal(c.store.data.client.requests["R"..id].status,"in progress")
        Test.equal(m.store.data.master.colonies[tostring(id)].requests["R"..id].status,"in progress")
    end
    for _=1,45 do w.step() end
    Test.equal(#w.callsFor("export",true),2,"live MineColonies request resent imported items")
    w.computers[2].integrator.requests={}
    w.untilTrue(function() return m.store.data.master.colonies["2"].requests.R2.status=="delivered" end)
    Test.equal(m.store.data.master.colonies["3"].requests.R3.status,"in progress")
end)

Test.case("hoe alternatives with absent higher tiers deliver stocked exact equipment instead of reporting missing",function()
    local w,m=fixture(1)
    local c=w.computers[2]
    local request={id="HOE",name="Hoe minimum level wood",count=1,items={}}
    for _,tier in ipairs({"wooden","stone","iron","diamond","netherite"}) do
        request.items[#request.items+1]={name="minecraft:"..tier.."_hoe",count=1}
    end
    c.integrator.requests={request}
    m.rs.add({name="minecraft:wooden_hoe"},3)
    m.rs.add({name="minecraft:stone_hoe"},2)
    m.rs.add({name="minecraft:wooden_hoe",nbt={Damage=4,Enchantments={{id="minecraft:unbreaking",lvl=1}}}},1)
    m.rs.add({name="minecraft:iron_hoe",nbt={Enchantments={{id="minecraft:unbreaking",lvl=1}}}},1)
    local diamond=m.rs.add({name="minecraft:diamond_hoe"},1)
    m.rs.recipes["minecraft:iron_hoe"]=true
    w.untilTrue(function()
        local item=c.rs.items[w.identity({name="minecraft:diamond_hoe"})]
        return item and item.amount==1
    end,"stocked hoe was not delivered")
    Test.equal(#w.callsFor("export",true),1)
    Test.equal(w.callsFor("export",true)[1].filter.fingerprint,diamond.fingerprint)
    Test.equal(#w.callsFor("craft",true),0)
    Test.equal(m.store.data.master.colonies["2"].requests.HOE.status,"in progress")
end)

Test.case("master update admission hold finishes an existing turn without granting another",function()
    local w,m=fixture(1);m.rs.add({name="minecraft:stone"},16);m.rs.visibilityDelay=.75
    w.untilTrue(function() return m.store.data.master.pendingTransfer~=nil end)
    assert(m.engine.canWaitForUpdate(),"ordinary pending chest verification blocked draining")
    m.engine.holdNewTurns(true)
    w.untilTrue(function() return not m.engine.busy() end,"master did not drain reserved turn")
    local grants=#w.grants()
    for _=1,30 do w.step() end
    Test.equal(#w.grants(),grants,"master admitted new turn while update held")
    assert(m.engine.canUpdate())
    m.engine.holdNewTurns(false)
    w.untilTrue(function() return #w.grants()>grants end,"released update admission did not resume turns")
end)

Test.case("lost grant, batch, result and acknowledgement recover using original transaction",function()
    local w,m=fixture(1);m.rs.add({name="minecraft:stone"},16)
    w.drop={turn=1,batch=1,result=1,received=1}
    w.untilTrue(function()
        local rs=w.computers[2].rs;local item=rs.items[w.identity({name="minecraft:stone"})]
        return item and item.amount==4
    end,"retry handshake never imported delivery",260)
    Test.equal(#w.callsFor("export",true),1)
    Test.equal(#w.callsFor("import",false),1)
    local stale=w.packet("batch",1)
    local before=#w.calls
    local accepted=w.at(1,m.engine.onMessage,2,stale.message)
    assert(accepted==true or accepted==false)
    for _=1,25 do w.step() end
    Test.equal(#w.callsFor("export",true),1,"reordered old batch caused another delivery")
    assert(#w.calls>=before)
end)

Test.case("delayed PRS chest visibility produces one verified shipment",function()
    local w,m=fixture(1);m.rs.add({name="minecraft:stone"},8);m.rs.visibilityDelay=.75
    w.untilTrue(function()
        local cs=m.store.data.master.colonies["2"]
        return cs and #cs.shipments==1
    end,"delayed export was not verified")
    Test.equal(#w.callsFor("export",true),1)
    assert(m.store.data.master.quarantine==nil)
    Test.equal(m.store.data.master.colonies["2"].shipments[1].count,4)
end)

Test.case("positive bridge count without chest delta quarantines PRS and is never replayed",function()
    local w,m=fixture(1);m.rs.add({name="minecraft:stone"},8);m.rs.phantomExport=true
    w.untilTrue(function() return m.store.data.master.quarantine~=nil end,"phantom export did not quarantine")
    assert(m.store.data.master.pendingTransfer)
    Test.equal(#m.store.data.master.colonies["2"].shipments,0)
    Test.equal(#w.callsFor("export",true),1)
    m.restart();for _=1,20 do w.step() end
    Test.equal(#w.callsFor("export",true),1,"restart resent uncertain export")
    assert(m.store.data.master.quarantine~=nil)
end)

Test.case("reported stock with zero export is held rather than marked missing or automatically retried",function()
    local w,m=fixture(1);m.rs.add({name="minecraft:stone"},8);m.rs.zeroExport=true
    w.untilTrue(function() return m.store.data.master.quarantine~=nil end)
    local pending=m.store.data.master.pendingTransfer
    assert(pending.definiteZero and pending.reported==0)
    Test.equal(m.store.data.master.colonies["2"].requests.R2.status,"error")
    Test.equal(#w.callsFor("export",true),1)
    for _=1,20 do w.step() end
    Test.equal(#w.callsFor("export",true),1,"zero transfer automatically retried")
end)

Test.case("zero exports preserve AP target and filter failures without claiming storage desync or releasing the held chest",function()
    for _,reason in ipairs({"INVALID_TARGET","NO_VALID_COUNT"}) do
        local w,m=fixture(1);local kelp={name="minecraft:kelp"};m.rs.add(kelp,64)
        w.computers[2].integrator.requests={S.request("R2",kelp.name,53)}
        local attempts=0
        w.devices[1].prs.api.exportItemToPeripheral=function(filter,chest)
            attempts=attempts+1;Test.equal(chest,"delivery-2")
            return 0,reason
        end
        w.untilTrue(function() return m.store.data.master.quarantine~=nil end)
        local pending=m.store.data.master.pendingTransfer
        Test.equal(pending.reported,0);Test.equal(pending.callError,reason);Test.equal(pending.lastDelta,0)
        assert(pending.definiteZero and pending.uncertain)
        local fault=m.store.data.master.quarantine
        assert(fault.message:find("PRS export returned 0",1,true) and fault.message:find(reason,1,true))
        assert(not fault.message:find("desync",1,true),"a target/filter rejection was incorrectly diagnosed as storage desync")
        Test.equal(fault.context.callError,reason)
        Test.equal(m.rs.items[w.identity(kelp)].amount,64,"the rejected export changed real available stock")
        for _=1,20 do w.step() end
        Test.equal(attempts,1,"reporting the true failure started an automatic retry")
        assert(m.store.data.master.pendingTransfer==pending and m.store.data.master.quarantine==fault)
        Test.equal(#m.store.data.master.colonies["2"].shipments,0)
        local health
        for _,row in ipairs(m.engine.snapshot().health) do if row.label=="Transfer integrity" then health=row end end
        assert(health and health.detail:find("Bridge reason: "..reason,1,true))
    end
end)

Test.case("restart after uncertain export accounts observed chest contents without new PRS export",function()
    local w,m=fixture(1);m.rs.add({name="minecraft:stone"},8)
    w.untilTrue(function() return m.store.data.master.pendingTransfer~=nil end)
    Test.equal(#w.callsFor("export",true),1)
    local pending=m.store.data.master.pendingTransfer
    assert(w.count(w.channels.D2,{name="minecraft:stone"})==4)
    m.restart()
    w.untilTrue(function() return m.store.data.master.pendingTransfer==nil end,"restart did not reconcile physical chest")
    Test.equal(#w.callsFor("export",true),1)
    Test.equal(#m.store.data.master.colonies["2"].shipments,1)
    Test.equal(m.store.data.master.colonies["2"].shipments[1].count,4)
end)

Test.case("master write-ahead save failure prevents PRS transfer",function()
    local w,m=fixture(1);m.rs.add({name="minecraft:stone"},8)
    local save=m.store.save
    m.store.save=function()
        if m.store.data.master.pendingTransfer and m.store.data.master.pendingTransfer.intent then w.writeFail=true end
        return save()
    end
    local ok,err=pcall(function() for _=1,30 do w.step() end end)
    assert(not ok and tostring(err):find("Persistence failure"))
    Test.equal(#w.callsFor("export",true),0,"unpersisted intent mutated PRS")
    Test.equal(w.count(w.channels.D2,{name="minecraft:stone"}),0)
end)

Test.case("one accepted craft is shared across colonies and survives timeout and restart",function()
    local w,m=fixture();m.rs.recipes["minecraft:stone"]=true;m.rs.neverFinishCraft=true
    m.config.craftingTimeoutSeconds=3;m.config.craftCooldownSeconds=1
    w.untilTrue(function() return #w.grants()>=4 end,"colonies stalled behind asynchronous craft")
    Test.equal(#w.callsFor("craft",true),1,"same item submitted concurrent crafts")
    w.advance(10);for _=1,20 do w.step() end
    Test.equal(#w.callsFor("craft",true),1,"craft timeout resubmitted existing job")
    local timedOut=0;for _,job in pairs(m.store.data.master.craftJobs) do if job.state=="timed out" then timedOut=timedOut+1 end end
    Test.equal(timedOut,1)
    m.restart();for _=1,30 do w.step() end
    Test.equal(#w.callsFor("craft",true),1,"restart lost craft reservation")
end)

Test.case("disabled autocrafting reports missing without submitting recipe",function()
    local w,m=fixture(1);m.config.autoCraftEnabled=false;m.rs.recipes["minecraft:stone"]=true
    w.untilTrue(function()
        local cs=m.store.data.master.colonies["2"];return cs and cs.requests.R2 and cs.requests.R2.status=="missing"
    end)
    Test.equal(#w.callsFor("craft",true),0)
end)

Test.case("configured transfer and turn limits bound shipments",function()
    local w,m=fixture(1);m.rs.add({name="minecraft:stone"},64)
    m.config.maxTransferChunk=3;m.config.maxItemsPerTurn=3
    w.computers[2].integrator.requests={S.request("R2","minecraft:stone",8)}
    w.untilTrue(function()
        local cs=m.store.data.master.colonies["2"];local total=0
        for _,delivery in ipairs(cs and cs.shipments or {}) do total=total+delivery.count end
        return total==8
    end,"bounded shipments failed to finish requested quantity")
    local totals={}
    for _,shipment in ipairs(m.store.data.master.colonies["2"].shipments) do
        assert(shipment.count<=3);totals[shipment.turn]=(totals[shipment.turn] or 0)+shipment.count
    end
    for _,total in pairs(totals) do assert(total<=3,"configured per-turn item limit exceeded") end
    Test.equal(#w.callsFor("export",true),3)
end)

Test.case("live requests beyond batch limit receive fair service",function()
    local w,m=fixture(1);m.config.maxRequestsPerTurn=2;m.rs.add({name="minecraft:stone"},64)
    local c=w.computers[2];c.integrator.requests={}
    for i=1,5 do c.integrator.requests[i]=S.request("R"..i,"minecraft:stone",1) end
    w.untilTrue(function()
        local cs=m.store.data.master.colonies["2"];return cs and #cs.shipments==5
    end,"batch limit starved live request")
    local seen={};for _,delivery in ipairs(m.store.data.master.colonies["2"].shipments) do seen[delivery.requestId]=true end
    for i=1,5 do assert(seen["R"..i]) end
    for _,packet in ipairs(w.sent) do if packet.message.kind=="batch" then assert(#packet.message.requests<=2) end end
end)

Test.case("colony overflow returns to master while protecting active request stock",function()
    local w,m=fixture(1);m.config.defaultItemKeep=0;m.config.buildingItemKeep=0
    local c=w.computers[2];c.config.overflowEnabled=true;c.config.defaultItemKeep=0;c.config.buildingItemKeep=0
    c.rs.add({name="minecraft:stone"},10);c.rs.add({name="minecraft:dirt"},5)
    m.rs.add({name="minecraft:stone"},4)
    w.untilTrue(function() return m.rs.items[w.identity({name="minecraft:dirt"})]~=nil end,"returns were not imported to PRS")
    Test.equal(m.rs.items[w.identity({name="minecraft:dirt"})].amount,5)
    Test.equal(c.rs.items[w.identity({name="minecraft:stone"})].amount,10,"overflow removed active MineColonies item")
    Test.equal(#w.callsFor("import",true),1)
end)

Test.case("partial export with unknown bridge outcome remains held after restart",function()
    local w,m=fixture(1);m.rs.add({name="minecraft:stone"},8);m.rs.exportLimit=2;m.rs.unknownExport=true
    w.untilTrue(function() return m.store.data.master.pendingTransfer~=nil end)
    Test.equal(w.count(w.channels.D2,{name="minecraft:stone"}),2)
    m.restart();w.untilTrue(function() return m.store.data.master.quarantine~=nil end)
    assert(m.store.data.master.pendingTransfer~=nil)
    Test.equal(#m.store.data.master.colonies["2"].shipments,0,"partial unknown mutation credited as finished shipment")
    Test.equal(#w.callsFor("export",true),1)
    for _=1,20 do w.step() end
    Test.equal(#w.callsFor("export",true),1,"ambiguous partial export repeated")
end)

Test.case("crash saving export result reconciles write-ahead intent without replacement",function()
    local w,m=fixture(1);m.rs.add({name="minecraft:stone"},8)
    local save=m.store.save
    m.store.save=function()
        local pending=m.store.data.master.pendingTransfer
        if pending and pending.reported~=nil then w.writeFail=true end
        return save()
    end
    local ok,err=pcall(function() for _=1,40 do w.step() end end)
    assert(not ok and tostring(err):find("Persistence failure"))
    Test.equal(#w.callsFor("export",true),1)
    Test.equal(w.count(w.channels.D2,{name="minecraft:stone"}),4)
    w.writeFail=false;m.restart()
    w.untilTrue(function() return m.store.data.master.pendingTransfer==nil end)
    Test.equal(#w.callsFor("export",true),1)
    Test.equal(#m.store.data.master.colonies["2"].shipments,1)
end)

Test.case("mismatched Ender Chest channel registration prevents granting or exporting",function()
    local w,m=fixture(1);m.rs.add({name="minecraft:stone"},8)
    w.computers[2].config.deliveryChannel="wrong-colors"
    for _=1,25 do w.step() end
    Test.equal(#w.grants(),0)
    Test.equal(#w.callsFor("export",true),0)
    assert(m.store.data.master.colonies["2"].routeError or m.store.data.master.colonies["2"].error)
end)

Test.case("failed MineColonies scan closes error turn without completing live request",function()
    local w,m=fixture(1);m.rs.add({name="minecraft:stone"},8)
    w.untilTrue(function() return w.computers[2].store.data.client.requests.R2~=nil end)
    local c=w.computers[2];c.integrator.failed=true
    w.untilTrue(function()
        local packet=w.packet("result",2)
        return packet and packet.message.turn>=2
    end,"failed scan stranded its reserved turn")
    assert(m.store.data.master.colonies["2"].requests.R2.status~="delivered")
    assert(c.store.data.client.requests.R2.status~="delivered")
    c.integrator.failed=false
    w.untilTrue(function() return m.store.data.master.colonies["2"].requests.R2.status=="in progress" end,
        "successful authoritative scan did not resume progress")
    Test.equal(#w.callsFor("export",true),1)
end)

Test.case("accepted craft output is verified and delivered without a second craft",function()
    local w,m=fixture(1);m.rs.recipes["minecraft:stone"]=true;m.rs.craftDelay=2
    w.untilTrue(function()
        local item=w.computers[2].rs.items[w.identity({name="minecraft:stone"})];return item and item.amount==4
    end,"accepted craft output was never delivered")
    Test.equal(#w.callsFor("craft",true),1)
    Test.equal(#w.callsFor("export",true),1)
    Test.equal(m.store.data.master.colonies["2"].requests.R2.status,"in progress")
    w.untilTrue(function()
        for _,job in pairs(m.store.data.master.craftJobs) do if job.state~="complete" then return false end end
        return true
    end,"delivered craft output never released its reservation")
    Test.equal(#w.callsFor("craft",true),1)
end)

Test.case("uncertain craft submission waits for physical output instead of resubmitting",function()
    local w,m=fixture(1);m.rs.recipes["minecraft:stone"]=true;m.rs.unknownCraft=true;m.rs.craftDelay=3
    w.untilTrue(function()
        local jobs=m.store.data.master.craftJobs
        for _,job in pairs(jobs) do if job.state=="uncertain" then return true end end
        return false
    end,"unknown craft call was not retained")
    m.restart()
    w.untilTrue(function()
        local item=w.computers[2].rs.items[w.identity({name="minecraft:stone"})];return item and item.amount==4
    end,"proven output from uncertain craft did not resume delivery")
    Test.equal(#w.callsFor("craft",true),1)
    Test.equal(#w.callsFor("export",true),1)
end)

Test.case("a colony crafting request does not block another colony with on-hand stock",function()
    local w,m=fixture();m.rs.recipes["minecraft:stone"]=true;m.rs.neverFinishCraft=true
    m.rs.add({name="minecraft:dirt"},4);w.computers[3].integrator.requests={S.request("R3","minecraft:dirt",4)}
    w.untilTrue(function()
        local item=w.computers[3].rs.items[w.identity({name="minecraft:dirt"})];return item and item.amount==4
    end,"crafting colony blocked on-hand colony")
    Test.equal(#w.callsFor("craft",true),1)
    Test.equal(m.store.data.master.colonies["2"].requests.R2.status,"crafting")
end)

Test.case("local colony import limits remain effective unless master route explicitly overrides",function()
    local w,m=fixture(1);m.rs.add({name="minecraft:stone"},8)
    w.computers[2].config.maxImportsPerTurn=1
    w.untilTrue(function()
        local item=w.computers[2].rs.items[w.identity({name="minecraft:stone"})];return item and item.amount>=1
    end)
    local imports=w.callsFor("import",false);Test.equal(imports[1].filter.count,1)
    m.config.colonies[1].overrides={maxImportsPerTurn=2}
    w.untilTrue(function() return #w.callsFor("import",false)>=2 end)
    imports=w.callsFor("import",false);Test.equal(imports[2].filter.count,2)
end)

Test.case("master restart preserves per-turn item budget after a verified partial shipment",function()
    local w,m=fixture(1);m.rs.add({name="minecraft:stone"},64)
    m.config.maxTransferChunk=3;m.config.maxItemsPerTurn=4
    w.computers[2].integrator.requests={S.request("Ra","minecraft:stone",5),S.request("Rb","minecraft:stone",5)}
    w.untilTrue(function() return m.store.data.master.pendingTransfer~=nil end)
    local turn=m.store.data.master.pendingTransfer.turn
    m.restart()
    w.untilTrue(function()
        local result=w.packet("result",2);return result and result.message.turn==turn
    end,"restarted reserved turn did not finish")
    local total=0
    for _,delivery in ipairs(m.store.data.master.colonies["2"].shipments) do if delivery.turn==turn then total=total+delivery.count end end
    assert(total>0 and total<=4,"restart reset configured item budget")
    for _,call in ipairs(w.callsFor("export",true)) do assert(call.filter.count<=3) end
end)

Test.case("master and client prune only completed shipments acknowledged by both peers",function()
    local w,m=fixture(1);m.rs.add({name="minecraft:stone"},8);local c=w.computers[2]
    w.untilTrue(function()
        local item=c.rs.items[w.identity({name="minecraft:stone"})];return item and item.amount==4
    end)
    c.integrator.requests={}
    w.untilTrue(function()
        local cs=m.store.data.master.colonies["2"]
        return cs and cs.requests.R2 and cs.requests.R2.status=="delivered" and #cs.shipments==0
            and next(c.store.data.client.shipments)==nil
    end,"completed acknowledged delivery records were not compacted")
    Test.equal(#w.callsFor("export",true),1)
    m.config.requestRetentionSeconds=60;c.config.requestRetentionSeconds=60;w.advance(61)
    w.untilTrue(function()
        return m.store.data.master.colonies["2"].requests.R2==nil and c.store.data.client.requests.R2==nil
    end,"completed request retention failed to compact journals")
    Test.equal(#w.callsFor("export",true),1)
end)

local function realCadence(w,count)
    function w.step()
        w.tick(1)
        for id=2,count+1 do w.tick(id) end
        w.flush();w.advance(1)
    end
end

Test.case("one-second craft polling does not starve turns for colonies with on-hand stock",function()
    local w,m=fixture();m.config.pollIntervalSeconds=1;m.config.craftPollSeconds=1
    m.rs.recipes["minecraft:stone"]=true;m.rs.neverFinishCraft=true;m.rs.add({name="minecraft:dirt"},4)
    w.computers[3].integrator.requests={S.request("R3","minecraft:dirt",4)};realCadence(w,2)
    w.untilTrue(function()
        local item=w.computers[3].rs.items[w.identity({name="minecraft:dirt"})];return item and item.amount==4
    end,"a craft due on every processor tick starved another colony's stock delivery",80)
    Test.equal(#w.callsFor("craft",true),1)
    Test.equal(m.store.data.master.colonies["2"].requests.R2.status,"crafting")
end)

Test.case("staggered persistent crafts at one-second cadence still serve a third colony",function()
    local w,m=fixture(3);m.config.pollIntervalSeconds=1;m.config.craftPollSeconds=1
    m.rs.recipes["minecraft:stone"]=true;m.rs.recipes["minecraft:dirt"]=true;m.rs.neverFinishCraft=true
    m.rs.add({name="minecraft:sand"},4)
    w.computers[3].integrator.requests={S.request("R3","minecraft:dirt",4)}
    w.computers[4].integrator.requests={S.request("R4","minecraft:sand",4)};realCadence(w,3)
    w.untilTrue(function()
        local item=w.computers[4].rs.items[w.identity({name="minecraft:sand"})];return item and item.amount==4
    end,"staggered due crafts starved the third colony",120)
    Test.equal(#w.callsFor("craft",true),2)
end)

Test.case("explicit zero-export recovery probes honor cooldown and resume delivery after repair",function()
    local w,m=fixture(1);m.config.desyncProbeSeconds=3;m.rs.add({name="minecraft:stone"},8);m.rs.zeroExport=true
    w.untilTrue(function()
        local cs=m.store.data.master.colonies["2"]
        return m.store.data.master.quarantine and cs and cs.turn==nil
    end,"paused zero-export result was not acknowledged")
    assert(w.at(1,m.engine.reconcile));Test.equal(#w.callsFor("export",true),2)
    w.untilTrue(function()
        local pending=m.store.data.master.pendingTransfer;return pending and pending.recoveryProbe and pending.definiteZero
    end,"zero diagnostic probe was not held")
    local started,err=w.at(1,m.engine.reconcile)
    assert(not started and tostring(err):find("interval"));Test.equal(#w.callsFor("export",true),2)
    m.rs.zeroExport=false;w.advance(3);assert(w.at(1,m.engine.reconcile))
    Test.equal(#w.callsFor("export",true),3)
    w.untilTrue(function() return m.store.data.master.quarantine==nil and m.store.data.master.pendingTransfer==nil end)
    w.untilTrue(function()
        local item=w.computers[2].rs.items[w.identity({name="minecraft:stone"})];return item and item.amount==4
    end,"repaired desync probe never resumed the original delivery")
    Test.equal(m.store.data.master.colonies["2"].requests.R2.status,"in progress")
    Test.equal(#w.callsFor("export",true),4)
end)

local function heldZeroShears()
    local w,m=fixture(1,{asymmetricNBT=true})
    local item={name="minecraft:shears",nbt={Damage=0},maxCount=1,displayName="Pristine Shears"}
    w.computers[2].integrator.requests={S.request("R2",item.name,1,item.nbt)}
    m.rs.add(item,2);m.rs.zeroExport=true
    w.untilTrue(function()
        local cs=m.store.data.master.colonies["2"]
        return m.store.data.master.quarantine and cs and cs.turn==nil
    end,"zero shears export was not held after the result acknowledgement")
    local pending=m.store.data.master.pendingTransfer
    assert(pending and pending.definiteZero and pending.reported==0 and pending.lastDelta==0)
    assert(pending.physicalBefore and pending.item.fingerprint)
    Test.equal(#w.callsFor("export",true),1)
    return w,m,item,pending
end

local function journalValue(value)
    return textutils.serialize(value,{allow_repetitions=true,compact=true})
end

Test.case("zero-export recovery retains the original intent when chest contents appear during the stock read",function()
    local w,m,item,pending=heldZeroShears()
    local baseline=journalValue(pending.physicalBefore)
    local source=journalValue(pending.item)
    local originalList=w.devices[1].prs.api.listItems;local revealed=false
    w.devices[1].prs.api.listItems=function(...)
        local items=originalList(...)
        if not revealed then
            revealed=true
            Test.equal(w.insert(w.channels.D2,item,1),1,"late original item was not staged")
        end
        return items
    end
    m.rs.zeroExport=false
    local started,err=w.at(1,m.engine.reconcile)
    assert(revealed,"recovery did not read refreshed PRS stock")
    assert(not started and tostring(err):find("changed"),"changed original chest was accepted as a new probe baseline")
    Test.equal(#w.callsFor("export",true),1,"recovery exported again after original contents appeared")
    Test.equal(m.store.data.master.pendingTransfer,pending,"recovery replaced the original held intent")
    Test.equal(journalValue(pending.physicalBefore),baseline,"recovery changed the original physical baseline")
    Test.equal(journalValue(pending.item),source,"recovery changed the original exact source selector")
    Test.equal(pending.reported,0);Test.equal(pending.count,1)
    assert(m.store.data.master.quarantine)
    Test.equal(m.store.data.master.colonies["2"].turn,nil)
    Test.equal(#m.store.data.master.colonies["2"].shipments,0,"late ambiguous contents received shipment credit")
    Test.equal(#w.callsFor("import",false),0,"colony imported from the retained held chest")
end)

Test.case("zero-export recovery rejects a refreshed variant with a changed AP fingerprint",function()
    local w,m,item,pending=heldZeroShears()
    local baseline=journalValue(pending.physicalBefore)
    local source=journalValue(pending.item)
    local fingerprint=pending.item.fingerprint
    local originalList=w.devices[1].prs.api.listItems;local replaced=false
    w.devices[1].prs.api.listItems=function(...)
        local items=originalList(...)
        for _,entry in ipairs(items) do
            if entry.name==item.name then
                Test.equal(m.matcher.itemIdentity(entry),m.matcher.itemIdentity(pending.item))
                entry.fingerprint="changed-exact-AP-fingerprint";replaced=true
            end
        end
        return items
    end
    m.rs.zeroExport=false
    local started,err=w.at(1,m.engine.reconcile)
    assert(replaced,"recovery did not inspect the refreshed exact variant")
    assert(not started and tostring(err):find("fingerprint"),"recovery accepted a different exact AP selector")
    Test.equal(#w.callsFor("export",true),1,"recovery exported with a changed AP fingerprint")
    Test.equal(m.store.data.master.pendingTransfer,pending,"recovery replaced the original held intent")
    Test.equal(journalValue(pending.physicalBefore),baseline)
    Test.equal(journalValue(pending.item),source)
    Test.equal(pending.item.fingerprint,fingerprint)
    Test.equal(pending.reported,0)
    assert(m.store.data.master.quarantine)
    Test.equal(m.store.data.master.colonies["2"].turn,nil)
    Test.equal(#m.store.data.master.colonies["2"].shipments,0)
    Test.equal(#w.callsFor("import",false),0)
end)

Test.case("zero-export recovery finds the original exact fingerprint among same-name NBT variants",function()
    local w,m,item,pending=heldZeroShears()
    local originalList=w.devices[1].prs.api.listItems
    w.devices[1].prs.api.listItems=function(...)
        local items=originalList(...)
        local other=S.copy(items[1]);other.fingerprint="another-AP-fingerprint";other.displayName="Renamed Shears"
        table.insert(items,1,other)
        return items
    end
    m.rs.zeroExport=false
    local started,err=w.at(1,m.engine.reconcile)
    assert(started,err)
    Test.equal(#w.callsFor("export",true),2)
    local probe=m.store.data.master.pendingTransfer
    assert(probe and probe.recoveryProbe)
    Test.equal(probe.item.fingerprint,pending.item.fingerprint)
    Test.equal(probe.variant.fingerprint,pending.item.fingerprint)
    Test.equal(w.callsFor("export",true)[2].filter.fingerprint,pending.item.fingerprint)
    assert(w.at(1,m.engine.verifyHeldTransfer))
    local shipment=m.store.data.master.colonies["2"].shipments[1]
    assert(shipment and shipment.verified)
    Test.equal(shipment.item.fingerprint,pending.item.fingerprint)
    Test.equal(shipment.count,1)
end)

Test.case("active zero-export snapshots identify the held item without hardware reads or journal mutation",function()
    local w,m,item,pending=heldZeroShears()
    local data=journalValue(m.store.data);local files=journalValue(w.files)
    local calls=#w.calls;local revision=m.store.data.revision
    for _=1,3 do
        local snapshot=w.at(1,m.engine.snapshot)
        local health
        for _,row in ipairs(snapshot.health) do if row.label=="Transfer integrity" then health=row end end
        assert(health and not health.ok)
        for _,value in ipairs({item.displayName,item.name,"Colony 2","delivery-2","Reported / chest change: 0 / 0"}) do
            assert(health.detail:find(value,1,true),"held transfer HEALTH context omitted "..value)
        end
        assert(snapshot.statusMessage:find(item.displayName,1,true))
        Test.equal(snapshot.pendingTransfer.item.fingerprint,pending.item.fingerprint)
        snapshot.pendingTransfer.item.nbt.Damage=42
        Test.equal(pending.item.nbt.Damage,0,"read-only snapshot shared its exact item with the live intent")
    end
    Test.equal(#w.calls,calls,"rendering transfer context performed a hardware read")
    Test.equal(m.store.data.revision,revision,"rendering transfer context saved the journal")
    Test.equal(journalValue(m.store.data),data,"rendering transfer context mutated the live journal")
    Test.equal(journalValue(w.files),files,"rendering transfer context changed durable journal slots")
end)

Test.case("failed MineColonies scan preserves independently verified import acknowledgement",function()
    local w,m=fixture(1);m.rs.add({name="minecraft:stone"},8)
    w.untilTrue(function()
        local cs=m.store.data.master.colonies["2"];return cs and #cs.shipments==1
    end)
    w.computers[2].integrator.failed=true
    w.untilTrue(function()
        local cs=m.store.data.master.colonies["2"];return cs.shipments[1] and cs.shipments[1].imported==4
    end,"failed MC scan discarded a physical delivery import receipt")
    assert(m.store.data.master.colonies["2"].requests.R2.status~="delivered")
    Test.equal(#w.callsFor("export",true),1);Test.equal(#w.callsFor("import",false),1)
end)

Test.case("one transient phantom craft-output snapshot does not release its craft reservation",function()
    local w,m=fixture(1);m.rs.recipes["minecraft:stone"]=true;m.rs.neverFinishCraft=true
    m.config.craftPollSeconds=1;m.config.craftStableReadsRequired=2
    w.untilTrue(function()
        local cs=m.store.data.master.colonies["2"]
        return #w.callsFor("craft",true)==1 and cs and cs.turn==nil
    end)
    w.advance(1);m.rs.add({name="minecraft:stone"},4)
    w.tick(1)
    local job;for _,entry in pairs(m.store.data.master.craftJobs) do job=entry end
    Test.equal(job.outputReads,1)
    Test.equal(job.state,"crafting","one stock snapshot released accepted craft")
    m.rs.items[w.identity({name="minecraft:stone"})].amount=0
    w.flush();for _=1,25 do w.step() end
    Test.equal(job.state,"crafting")
    Test.equal(job.outputReads,0,"disappearing phantom output remained a stable sample")
    Test.equal(#w.callsFor("craft",true),1,"transient phantom stock allowed a duplicate craft")
end)

Test.case("operator zero recovery retains the master's original rice shipment and imports all six staged items once without exporting replacement stock",function()
    local w,m=fixture(1);local c=w.computers[2];local rice={name="farmersdelight:rice"}
    local items={rice,{name="minecraft:stone"},{name="minecraft:cobblestone"},{name="minecraft:oak_planks"},
        {name="minecraft:dirt"},{name="minecraft:glass"}}
    c.integrator.requests={}
    for index,item in ipairs(items) do
        local id=index==1 and "000-rice" or "Z"..index
        c.integrator.requests[#c.integrator.requests+1]=S.request(id,item.name,1);m.rs.add(item,8)
    end
    local api=w.devices[2].crs.api;local originalImport=api.importItemFromPeripheral;local attempts=0
    api.importItemFromPeripheral=function() attempts=attempts+1;return nil,"NOT_CONNECTED" end
    api.isConnected=function() return false,"NOT_CONNECTED" end
    w.untilTrue(function()
        local state=c.store.data.client;local cs=m.store.data.master.colonies["2"]
        return state.intent and state.turn.phase=="finished" and cs and cs.turn==nil
    end,"the disconnected client did not close its retained error turn",260)
    m.config.automationEnabled=false
    local intent=c.store.data.client.intent;Test.equal(intent.item.name,rice.name);Test.equal(intent.beforeChest,1)
    Test.equal(intent.count,1);Test.equal(intent.callError,"NOT_CONNECTED");assert(intent.reported==nil)
    local shipmentId=intent.shipmentId;local cs=m.store.data.master.colonies["2"]
    Test.equal(#cs.shipments,6);Test.equal(#w.callsFor("export",true),6);Test.equal(attempts,1)
    for _,item in ipairs(items) do Test.equal(w.count(w.channels.D2,item),1) end
    local source=textutils.serialize(w.channels.D2.slots)
    api.isConnected=function() return true end
    api.importItemFromPeripheral=function(...) attempts=attempts+1;return originalImport(...) end
    local recovery=require("colony.network.client").zeroImportRecovery(c.config,c.store,c.io,c.matcher)
    assert(w.at(2,recovery.previewZeroImport,shipmentId))
    assert(w.at(2,recovery.reconcileZeroImport,shipmentId,"ZERO "..shipmentId))
    Test.equal(textutils.serialize(w.channels.D2.slots),source);Test.equal(attempts,1)
    Test.equal(c.store.data.client.shipments[shipmentId].imported,0)
    c.restart();m.restart();m.config.automationEnabled=true
    w.untilTrue(function()
        local state=m.store.data.master.colonies["2"]
        if not state or #state.shipments~=6 then return false end
        for _,shipment in ipairs(state.shipments) do if shipment.imported~=1 then return false end end
        return true
    end,"the original staged shipments were not acknowledged after zero recovery",260)
    for _=1,20 do w.step() end
    Test.equal(#w.callsFor("export",true),6,"the master exported replacement items for existing verified shipments")
    Test.equal(#w.callsFor("import",false),6);Test.equal(attempts,7)
    for _,item in ipairs(items) do
        Test.equal(c.rs.items[w.identity(item)].amount,1);Test.equal(m.rs.items[w.identity(item)].amount,7)
        Test.equal(w.count(w.channels.D2,item),0)
    end
    Test.equal(c.store.data.client.shipments[shipmentId].imported,1)
    Test.equal(m.store.data.master.colonies["2"].requests["000-rice"].status,"in progress")
    for _,call in ipairs(w.callsFor(nil,true)) do Test.equal(call.computer,1) end
    c.integrator.requests={}
    w.untilTrue(function()
        local state=m.store.data.master.colonies["2"]
        return state.requests["000-rice"].status=="delivered" and #state.shipments==0
    end,"completed MC requests did not release the old shipments")
    Test.equal(#w.callsFor("export",true),6);Test.equal(#w.callsFor("import",false),6)
end)

Test.case("two colonies receive the exact AP-selected pristine and damaged tools despite different physical CC NBT hashes",function()
    local w,m=fixture(2,{asymmetricNBT=true})
    local pristine={name="minecraft:shears",nbt={Damage=0},maxCount=1}
    local damaged={name="minecraft:shears",nbt={Damage=42},maxCount=1}
    local enchanted={name="minecraft:shears",nbt={Damage=0,Enchantments={{id="minecraft:unbreaking",lvl=2}}},maxCount=1}
    local c2,c3=w.computers[2],w.computers[3]
    c2.integrator.requests={S.request("R2",pristine.name,1,pristine.nbt)}
    c3.integrator.requests={S.request("R3",damaged.name,1,damaged.nbt)}
    m.rs.add(pristine,4);m.rs.add(damaged,4);m.rs.add(enchanted,2)
    w.insert(w.channels.D2,enchanted,1)
    w.untilTrue(function()
        local a,b=c2.rs.items[w.identity(pristine)],c3.rs.items[w.identity(damaged)]
        return a and b and a.amount==1 and b.amount==1
    end,"AP table NBT did not bind to the actual CC identities")
    for id,source in pairs({[2]=pristine,[3]=damaged}) do
        local cs=m.store.data.master.colonies[tostring(id)];local delivery=cs.shipments[1]
        Test.equal(delivery.item.name,source.name);Test.equal(delivery.item.nbt,w.ccNBT(source.nbt))
        Test.equal(delivery.item.fingerprint,w.fingerprint(source));Test.equal(delivery.count,1)
        Test.equal(cs.requests["R"..id].status,"in progress")
        Test.equal(w.computers[id].store.data.client.requests["R"..id].status,"in progress")
    end
    Test.equal(w.count(w.channels.D2,{name=enchanted.name,nbt=w.ccNBT(enchanted.nbt)}),1)
    Test.equal(m.rs.items[w.identity(enchanted)].amount,2)
    Test.equal(#w.callsFor("export",true),2);Test.equal(#w.callsFor("import",false),2)
    for _,call in ipairs(w.callsFor("import",false)) do
        assert(call.filter.fingerprint and call.filter.name==nil and call.filter.nbt==nil)
    end
    for _=1,24 do w.step() end
    Test.equal(#w.callsFor("export",true),2,"live equipment requests received duplicate tools")
    c2.integrator.requests={}
    w.untilTrue(function() return m.store.data.master.colonies["2"].requests.R2.status=="delivered" end)
    Test.equal(m.store.data.master.colonies["3"].requests.R3.status,"in progress")
end)

Test.case("restart between an asymmetric tool export and verification retains the full physical baseline and imports once",function()
    local w,m=fixture(1,{asymmetricNBT=true});local c=w.computers[2]
    local source={name="minecraft:shears",nbt={Damage=0},maxCount=1}
    local untouched={name="minecraft:shears",nbt={Damage=42},maxCount=1}
    local glass={name="minecraft:glass",nbt={}}
    local physicalGlass={name=glass.name,nbt=w.ccNBT(glass.nbt)}
    c.integrator.requests={S.request("R2",source.name,1,source.nbt)};m.rs.add(source,2)
    w.insert(w.channels.D2,untouched,1);w.insert(w.channels.D2,glass,5)
    m.rs.visibilityDelay=.5
    w.untilTrue(function() return m.store.data.master.pendingTransfer~=nil end)
    local held=m.store.data.master.pendingTransfer
    Test.equal(held.reported,1);assert(held.physicalBefore and held.physicalBefore.version==1)
    local baseline=held.physicalBefore.totals
    Test.equal(baseline[m.matcher.itemIdentity({name=untouched.name,nbt=w.ccNBT(untouched.nbt)})].count,1)
    Test.equal(baseline[m.matcher.itemIdentity(physicalGlass)].count,5)
    Test.equal(#w.callsFor("export",true),1)
    m.restart();w.untilTrue(function()
        local entry=c.rs.items[w.identity(source)];return entry and entry.amount==1
    end,"restart could not verify the retained table-to-hash export")
    Test.equal(#w.callsFor("export",true),1);Test.equal(#w.callsFor("import",false),1)
    Test.equal(w.count(w.channels.D2,{name=untouched.name,nbt=w.ccNBT(untouched.nbt)}),1)
    Test.equal(w.count(w.channels.D2,physicalGlass),5)
    local delivery=m.store.data.master.colonies["2"].shipments[1]
    Test.equal(delivery.item.nbt,w.ccNBT(source.nbt));Test.equal(delivery.item.fingerprint,w.fingerprint(source))
    c.restart();for _=1,24 do w.step() end
    Test.equal(#w.callsFor("export",true),1);Test.equal(#w.callsFor("import",false),1)
end)

Test.case("partial asymmetric tool exports bind each verified quantity without completing a live MineColonies request",function()
    local w,m=fixture(1,{asymmetricNBT=true});local c=w.computers[2]
    local source={name="minecraft:shears",nbt={Damage=42},maxCount=1}
    c.integrator.requests={S.request("R2",source.name,3,source.nbt)};m.rs.add(source,5);m.rs.exportLimit=1
    w.untilTrue(function() local entry=c.rs.items[w.identity(source)];return entry and entry.amount==3 end)
    local total=0;for _,shipment in ipairs(m.store.data.master.colonies["2"].shipments) do
        total=total+shipment.count;Test.equal(shipment.item.nbt,w.ccNBT(source.nbt))
        Test.equal(shipment.item.fingerprint,w.fingerprint(source));Test.equal(shipment.count,1)
    end
    Test.equal(total,3);Test.equal(#w.callsFor("export",true),3);Test.equal(#w.callsFor("import",false),3)
    for _=1,20 do w.step() end
    Test.equal(#w.callsFor("export",true),3);Test.equal(c.store.data.client.requests.R2.status,"in progress")
    Test.equal(m.rs.items[w.identity(source)].amount,2)
end)

Test.case("an unknown export result cannot bind a new CC tool identity and remains held across restart",function()
    local w,m=fixture(1,{asymmetricNBT=true});local c=w.computers[2]
    local source={name="minecraft:shears",nbt={Damage=0},maxCount=1}
    c.integrator.requests={S.request("R2",source.name,1,source.nbt)};m.rs.add(source,2);m.rs.unknownExport=true
    w.untilTrue(function() return m.store.data.master.quarantine~=nil end)
    local held=m.store.data.master.pendingTransfer;assert(held and held.reported==nil and held.physicalBefore)
    Test.equal(#m.store.data.master.colonies["2"].shipments,0)
    Test.equal(w.count(w.channels.D2,{name=source.name,nbt=w.ccNBT(source.nbt)}),1)
    Test.equal(#w.callsFor("export",true),1);Test.equal(#w.callsFor("import",false),0)
    m.restart();c.restart();for _=1,24 do w.step() end
    assert(m.store.data.master.pendingTransfer and m.store.data.master.quarantine)
    Test.equal(#w.callsFor("export",true),1);Test.equal(#w.callsFor("import",false),0)
end)

Test.case("a positive tool export with any unrelated chest change refuses a physical identity binding and never retries",function()
    local w,m=fixture(1,{asymmetricNBT=true});local c=w.computers[2]
    local source={name="minecraft:shears",nbt={Damage=0},maxCount=1}
    c.integrator.requests={S.request("R2",source.name,1,source.nbt)};m.rs.add(source,2)
    local api=w.devices[1].prs.api;local original=api.exportItemToPeripheral
    api.exportItemToPeripheral=function(filter,name)
        local moved=original(filter,name);w.insert(w.channels.D2,{name="minecraft:glass"},1);return moved
    end
    w.untilTrue(function() return m.store.data.master.quarantine~=nil end)
    Test.equal(#m.store.data.master.colonies["2"].shipments,0)
    Test.equal(#w.callsFor("export",true),1);Test.equal(#w.callsFor("import",false),0)
    m.restart();for _=1,20 do w.step() end
    Test.equal(#w.callsFor("export",true),1);assert(m.store.data.master.pendingTransfer)
end)

Test.case("asymmetric damaged and enchanted overflow returns import by their original AP fingerprints on the master only",function()
    local w,m=fixture(1,{asymmetricNBT=true});local c=w.computers[2]
    c.integrator.requests={};c.config.overflowEnabled=true;c.config.defaultItemKeep=0;c.config.buildingItemKeep=0
    local damaged={name="minecraft:shears",nbt={Damage=42},maxCount=1}
    local enchanted={name="minecraft:shears",nbt={Damage=0,Enchantments={{id="minecraft:unbreaking",lvl=3}}},maxCount=1}
    c.rs.add(damaged,2);c.rs.add(enchanted,1)
    w.untilTrue(function()
        local a,b=m.rs.items[w.identity(damaged)],m.rs.items[w.identity(enchanted)]
        return a and b and a.amount==2 and b.amount==1
    end,"master did not import exact AP selectors from the physical overflow hashes")
    Test.equal(c.rs.items[w.identity(damaged)].amount,0);Test.equal(c.rs.items[w.identity(enchanted)].amount,0)
    Test.equal(#w.callsFor("export",false),2);Test.equal(#w.callsFor("import",true),3)
    Test.equal(#w.callsFor("export",true),0);Test.equal(#w.callsFor("import",false),0)
    local found=false
    for _,packet in ipairs(w.sent) do if packet.message.kind=="batch" and #(packet.message.returnSelectors or {})==2 then
        found=true
        for _,selector in ipairs(packet.message.returnSelectors) do
            assert(type(selector.item.nbt)=="string" and #selector.item.nbt==32)
            local source=selector.item.nbt==w.ccNBT(damaged.nbt) and damaged or enchanted
            Test.equal(selector.fingerprint,w.fingerprint(source))
        end
    end end
    assert(found,"client omitted retained selector rows from its batch")
    for _,call in ipairs(w.callsFor("import",true)) do
        Test.equal(call.computer,1);assert(call.filter.fingerprint and call.filter.nbt==nil and call.filter.name==nil)
    end
    w.untilTrue(function() return next(c.store.data.client.returnSelectors)==nil end)
    c.restart();m.restart();for _=1,24 do w.step() end
    Test.equal(#w.callsFor("export",false),2);Test.equal(#w.callsFor("import",true),3)
end)

Test.case("malformed or duplicate return selectors never start a PRS import or accept the current batch",function()
    local mutations={
        function(row) row.fingerprint="";return {row} end,
        function(row) row.item.nbt={Damage=42};return {row} end,
        function(row) return {row,S.copy(row)} end,
        function(row) return {[2]=row} end,
        function(row) row.item.name=false;return {row} end,
        function(row) row.fingerprint=string.rep("f",257);return {row} end,
    }
    for index,mutate in ipairs(mutations) do
        local w,m=fixture(1,{asymmetricNBT=true});local c=w.computers[2];c.integrator.requests={}
        local source={name="minecraft:shears",nbt={Damage=42},maxCount=1};w.insert(w.channels.R2,source,1)
        local selector={item={name=source.name,nbt=w.ccNBT(source.nbt)},fingerprint=w.fingerprint(source)}
        local send=c.io.send
        c.io.send=function(id,message)
            if message.kind=="batch" then message=S.copy(message);message.returnSelectors=mutate(S.copy(selector)) end
            return send(id,message)
        end
        w.untilTrue(function()
            for _,entry in ipairs(m.store.data.errors) do if entry.code=="BAD_BATCH" then return true end end
            return false
        end,"malformed return selector was accepted: "..index)
        local cs=m.store.data.master.colonies["2"];assert(cs.turn and cs.turn.phase=="WAIT_BATCH")
        Test.equal(#w.callsFor("import",true),0);Test.equal(#w.callsFor("export",true),0)
        Test.equal(w.count(w.channels.R2,selector.item),1)
        assert(m.store.data.master.pendingTransfer==nil)
    end
end)

Test.case("omitting a present overflow selector retains its binding and a later conflicting fingerprint is rejected",function()
    local w,m=fixture(1,{asymmetricNBT=true});local c=w.computers[2]
    c.integrator.requests={}
    m.config.maxReturnItemsPerTurn=1
    local source={name="minecraft:shears",nbt={Damage=42},maxCount=1}
    local physical={name=source.name,nbt=w.ccNBT(source.nbt)}
    w.insert(w.channels.R2,source,2)
    c.store.data.client.returnSelectors[c.matcher.itemIdentity(physical)]={item=physical,fingerprint=w.fingerprint(source)}
    c.store.save()
    w.untilTrue(function() return #w.callsFor("import",true)==1 end)
    Test.equal(w.count(w.channels.R2,physical),1)
    local send=c.io.send;local seen=0
    c.io.send=function(id,message)
        if message.kind=="batch" then
            message=S.copy(message);seen=seen+1
            if seen==1 then
                message.returnSelectors={};message.clientError="read-only held colony error"
            else
                for _,selector in ipairs(message.returnSelectors or {}) do selector.fingerprint=string.rep("e",32) end
            end
        end
        return send(id,message)
    end
    w.untilTrue(function()
        for _,entry in ipairs(m.store.data.errors) do if entry.code=="BAD_BATCH" then return true end end
        return false
    end,"master accepted a changed selector over a remaining physical stack")
    Test.equal(#w.callsFor("import",true),1);Test.equal(w.count(w.channels.R2,physical),1)
    assert(seen>=2,"the omitted selector did not pass through a retained error handshake")
    local identity=m.matcher.itemIdentity(physical)
    Test.equal(m.store.data.master.colonies["2"].returnSelectors[identity].fingerprint,w.fingerprint(source))
end)
Test.case("ordinary kelp avoids AP fingerprint cache mutation and journals its selector before verified delivery",function()
    local w,m=fixture(1);local kelp={name="minecraft:kelp"};local source=m.rs.add(kelp,64)
    local c=w.computers[2];c.integrator.requests={S.request("R2",kelp.name,53)}
    local api=w.devices[1].prs.api;local original=api.exportItemToPeripheral;local poisoned=false
    api.exportItemToPeripheral=function(filter,chest)
        local pending=m.store.data.master.pendingTransfer
        assert(pending and pending.intent and pending.physicalBefore,"bridge call lacked durable baseline")
        Test.equal(pending.item.fingerprint,source.fingerprint)
        if filter.fingerprint then poisoned=true;return 0 end
        Test.equal(filter.name,kelp.name);Test.equal(pending.selectionMode,"plain-name")
        assert(not poisoned,"fingerprint selection poisoned the real plain-item cache before export")
        return original(filter,chest)
    end
    w.untilTrue(function() local entry=c.rs.items[w.identity(kelp)];return entry and entry.amount==53 end)
    Test.equal(poisoned,false);assert(not m.store.data.master.quarantine)
    local record=m.store.data.master.colonies["2"].requests.R2
    Test.equal(record.status,"in progress","delivery prematurely completed the MineColonies request")
    for _=1,20 do w.step() end
    Test.equal(c.rs.items[w.identity(kelp)].amount,53,"outstanding request duplicated the verified shipment")
    c.integrator.requests={}
    w.untilTrue(function() return record.status=="delivered" end)
end)

Test.case("mixed fresh and harmless transport variants export by guarded name and import their verified physical slot",function()
    for _,case in ipairs({
        {name="minecraft:clock",nbt={["quark:clock_calculated"]=1}},
        {name="minecraft:compass",nbt={["quark:compass_calculated"]=1}},
        {name="minecolonies:ancienttome",nbt={raidWillHappen=false}},
    }) do
        local w,m=fixture(1,{asymmetricNBT=true});local c=w.computers[2]
        c.integrator.requests={S.request("R2",case.name,1)}
        m.rs.add({name=case.name,nbt=case.nbt},9)
        m.rs.add({name=case.name},1)
        local api=w.devices[1].prs.api;local original=api.exportItemToPeripheral
        api.exportItemToPeripheral=function(filter,chest)
            local pending=m.store.data.master.pendingTransfer
            assert(pending and pending.intent and pending.selectionMode=="transient-name")
            if filter.fingerprint then return 0,"simulated AP live-cache mismatch" end
            Test.equal(filter.name,case.name)
            return original(filter,chest)
        end
        w.untilTrue(function()
            for _,entry in pairs(c.rs.items) do if entry.name==case.name and entry.amount==1 then return true end end
            return false
        end,"transient "..case.name.." did not reach colony storage")
        assert(not m.store.data.master.quarantine and not c.store.data.client.fault)
        local shipment=m.store.data.master.colonies["2"].shipments[1]
        assert(shipment and shipment.item.transientNameImport==true)
        Test.equal(shipment.item.fingerprint,nil)
        local exports=w.callsFor("export",true);Test.equal(#exports,1)
        Test.equal(exports[1].filter.name,case.name);Test.equal(exports[1].filter.fingerprint,nil)
        local imports=w.callsFor("import",false);Test.equal(#imports,1)
        Test.equal(imports[1].filter.name,case.name);Test.equal(imports[1].filter.fingerprint,nil)
        assert(type(imports[1].filter.fromSlot)=="number","verified physical slot was not bound")
    end
end)

Test.case("unexpected tagged item during a plain-name export is held across reboot without shipment credit or automatic retry",function()
    local w,m=fixture(1);local kelp={name="minecraft:kelp"};m.rs.add(kelp,8)
    w.computers[2].integrator.requests={S.request("R2",kelp.name,1)}
    local calls=0
    w.devices[1].prs.api.exportItemToPeripheral=function(filter,chest)
        calls=calls+1;Test.equal(filter.name,kelp.name);Test.equal(filter.fingerprint,nil)
        w.insert(w.channels.D2,{name=kelp.name,nbt="unexpected-tagged-variant"},1)
        return 1
    end
    w.untilTrue(function() return m.store.data.master.quarantine~=nil end)
    local state=m.store.data.master;Test.equal(state.pendingTransfer.selectionMode,"plain-name")
    assert(state.pendingTransfer.lastError:find("tagged",1,true))
    Test.equal(#state.colonies["2"].shipments,0)
    m.restart();for _=1,20 do w.step() end
    Test.equal(calls,1);assert(m.store.data.master.quarantine)
    Test.equal(#m.store.data.master.colonies["2"].shipments,0)
end)

Test.case("a retained legacy zero export recovers with one explicit plain-name probe preserving its original AP fingerprint and remaining quantity",function()
    local w,m=fixture(1);local kelp={name="minecraft:kelp"};m.rs.add(kelp,8)
    w.computers[2].integrator.requests={S.request("R2",kelp.name,4)}
    m.rs.zeroExport=true
    w.untilTrue(function()
        local state=m.store.data.master;return state.quarantine and state.colonies["2"].turn==nil
    end)
    m.config.automationEnabled=false
    local pending=m.store.data.master.pendingTransfer
    pending.selectionMode=nil -- A deployed 4.0.4 zero-export intent has no selector marker.
    local fingerprint=pending.item.fingerprint
    m.store.save();m.rs.zeroExport=false
    assert(w.at(1,m.engine.reconcile))
    local probe=m.store.data.master.pendingTransfer
    assert(probe.recoveryProbe);Test.equal(probe.count,1);Test.equal(probe.selectionMode,"plain-name")
    Test.equal(probe.item.fingerprint,fingerprint)
    Test.equal(w.callsFor("export",true)[2].filter.count,1)
    Test.equal(w.callsFor("export",true)[2].filter.name,kelp.name)
    assert(w.at(1,m.engine.verifyHeldTransfer))
    local cs=m.store.data.master.colonies["2"]
    Test.equal(cs.shipments[1].count,1);Test.equal(cs.shipments[1].item.fingerprint,fingerprint)
    m.config.automationEnabled=true
    w.untilTrue(function() local entry=w.computers[2].rs.items[w.identity(kelp)];return entry and entry.amount==4 end)
    Test.equal(m.rs.items[w.identity(kelp)].amount,4)
end)

Test.case("retained fingerprint-zero transport items recover once after harmless metadata appears",function()
    for _,case in ipairs({
        {name="minecraft:clock",nbt={["quark:clock_calculated"]=1}},
        {name="minecolonies:ancienttome",nbt={raidWillHappen=false}},
    }) do
        local w,m=fixture(1,{asymmetricNBT=true});local c=w.computers[2]
        local item={name=case.name};c.integrator.requests={S.request("R2",item.name,1)}
        local original=m.rs.add(item,1);m.rs.zeroExport=true
        w.untilTrue(function()
            local state=m.store.data.master;return state.quarantine and state.colonies["2"].turn==nil
        end)
        m.config.automationEnabled=false
        local pending=m.store.data.master.pendingTransfer
        pending.selectionMode="fingerprint" -- The selector retained by suite 4.0.16/4.0.17.
        Test.equal(pending.item.fingerprint,original.fingerprint)
        m.rs.add({name=item.name,nbt=case.nbt},9)
        m.store.save();m.rs.zeroExport=false
        assert(w.at(1,m.engine.reconcile))
        local probe=m.store.data.master.pendingTransfer
        assert(probe.recoveryProbe);Test.equal(probe.count,1);Test.equal(probe.selectionMode,"transient-name")
        local exports=w.callsFor("export",true);Test.equal(#exports,2)
        Test.equal(exports[2].filter.name,item.name);Test.equal(exports[2].filter.fingerprint,nil)
        assert(w.at(1,m.engine.verifyHeldTransfer))
        local shipment=m.store.data.master.colonies["2"].shipments[1]
        assert(shipment.item.transientNameImport==true);Test.equal(shipment.item.fingerprint,nil)
        m.config.automationEnabled=true
        w.untilTrue(function()
            for _,entry in pairs(c.rs.items) do if entry.name==item.name and entry.amount==1 then return true end end
            return false
        end,"recovered "..item.name.." did not import exactly once")
        Test.equal(#w.callsFor("export",true),2);Test.equal(#w.callsFor("import",false),1)
        assert(not m.store.data.master.quarantine and not c.store.data.client.fault)
    end
end)
return true
