local S=require("tests.support")
local function fixture(count)
    local w=S.world();local master=S.computer(w,1,"master")
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

Test.case("reported stock with zero export is a desync error rather than a missing item",function()
    local w,m=fixture(1);m.rs.add({name="minecraft:stone"},8);m.rs.zeroExport=true
    w.untilTrue(function() return m.store.data.master.quarantine~=nil end)
    local pending=m.store.data.master.pendingTransfer
    assert(pending.definiteZero and pending.reported==0)
    Test.equal(m.store.data.master.colonies["2"].requests.R2.status,"error")
    Test.equal(#w.callsFor("export",true),1)
    for _=1,20 do w.step() end
    Test.equal(#w.callsFor("export",true),1,"zero transfer automatically retried")
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
return true
