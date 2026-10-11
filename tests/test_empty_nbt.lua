local S=require("tests.support")
local Matcher=require("colony.supply.matcher")
local Config=require("colony.network.config")
local EMPTY="41883520c3071f5f4a4a4613fb005e0c"
local function encode(value) return textutils.serialize(value,{compact=true,allow_repetitions=true}) end
local function shipment(id,requestId,item,count,at)
    return {id=id,requestId=requestId,item=S.copy(item),count=count,verified=true,createdAt=at or 100}
end
local function status(id) return {id=id,status="in progress"} end
local function physical(source,w)
    return {name=source.name,nbt=w.ccNBT(source.nbt),fingerprint=w.fingerprint(source)}
end
local function quantity(io,name,item,w) return w.at(2,function() return io.count(assert(io.snapshot(name)),item) end) end

Test.case("only the official root empty-compound hash aliases ordinary NBT and meaningful nested strings remain exact",function()
    S.world();local matcher=Matcher.new(Config.defaults("supply"),{})
    local item={name="minecraft:carrot"};local identity=matcher.itemIdentity(item)
    for _,value in ipairs({{},"{}","nil",EMPTY}) do
        Test.equal(matcher.canonicalNBT(value),"")
        Test.equal(matcher.itemIdentity({name=item.name,nbt=value}),identity)
    end
    for _,value in ipairs({string.rep("a",32),"552887824c43124013fd24f6edcde0fb",{Damage=0},
        {display={Name=EMPTY}},{[EMPTY]="literal key"},{literal=EMPTY},{literal="{}"},{literal="nil"}}) do
        assert(matcher.canonicalNBT(value)~="","a meaningful NBT value became empty")
        assert(matcher.itemIdentity({name=item.name,nbt=value})~=identity,"a real variant aliases an ordinary carrot")
    end
    assert(matcher.canonicalNBT({literal=EMPTY}):find(EMPTY,1,true),"root hash normalization erased a nested literal string")
    assert(matcher.canonicalNBT({[EMPTY]="literal key"}):find(EMPTY,1,true),"root hash normalization erased a nested literal key")
end)

Test.case("tagged tool imports select its physical slot without retagging unrelated untagged chest stacks",function()
    local w,c=S.clientFixture();w.asymmetricNBT=true
    local carrot={name="minecraft:carrot"};local wheat={name="minecraft:wheat"};local hoe={name="minecraft:iron_hoe",nbt={Damage=0},maxCount=1}
    w.insert(w.channels.D2,carrot,36);w.insert(w.channels.D2,wheat,7);w.insert(w.channels.D2,hoe,1)
    local originalCarrot=w.channels.D2.slots[1];local originalWheat=w.channels.D2.slots[2]
    assert(originalCarrot.nbt==nil and originalWheat.nbt==nil)
    local deliveries={shipment("shipment-182","R-HOE",physical(hoe,w),1,99),shipment("shipment-183","R-CARROT",carrot,3,100)}
    c.integrator.requests={S.request("R-HOE",hoe.name,1),S.request("R-CARROT",carrot.name,3)}
    assert(w.grant(1,deliveries));local imports=w.callsFor("import",false)
    Test.equal(#imports,2);Test.equal(imports[1].filter.fingerprint,w.fingerprint(hoe));Test.equal(imports[1].filter.fromSlot,2)
    Test.equal(imports[2].filter.name,carrot.name);Test.equal(imports[2].filter.fromSlot,0)
    assert(originalCarrot.nbt==nil and originalWheat.nbt==nil,"a tagged import mutated a different physical stack")
    Test.equal(originalCarrot.count,33);Test.equal(originalWheat.count,7)
    Test.equal(w.packet("batch").message.imports["shipment-182"],1)
    Test.equal(w.packet("batch").message.imports["shipment-183"],3)
    assert(c.store.data.client.fault==nil and c.store.data.client.intent==nil)
    assert(w.result(1,deliveries,{status("R-HOE"),status("R-CARROT")}))
    c.restart();w.tick(2);assert(w.grant(2,deliveries));Test.equal(#w.callsFor("import",false),2)
    Test.equal(w.count(w.channels.D2,carrot),33);Test.equal(w.count(w.channels.D2,wheat),7)
end)

local function missingCarrotFixture(tagged)
    local w,c=S.clientFixture();w.asymmetricNBT=true;c.config.maxImportsPerTurn=3
    local carrot={name="minecraft:carrot"};local wheat={name="minecraft:wheat"};local stone={name="minecraft:stone"}
    local chestCarrot={name=carrot.name,nbt=tagged and {display={Name="Tagged carrot"}} or {}}
    w.insert(w.channels.D2,chestCarrot,36)
    w.insert(w.channels.D2,wheat,3);w.insert(w.channels.D2,{name=wheat.name,nbt={}},4)
    w.insert(w.channels.D2,stone,2)
    local deliveries={shipment("shipment-183","R-CARROT",carrot,3,99),
        shipment("shipment-184","R-WHEAT",wheat,5,100),shipment("shipment-185","R-WHEAT",{name=wheat.name,nbt={}},2,101),
        shipment("shipment-186","R-STONE",stone,2,102)}
    c.integrator.requests={S.request("R-CARROT",carrot.name,3),S.request("R-WHEAT",wheat.name,7),S.request("R-STONE",stone.name,2)}
    -- Run the previous deployment's matching through the real engine to
    -- produce its held DELIVERY_MISSING journal, then restore the new matcher.
    local originalCanonical,originalIdentity=c.matcher.canonicalNBT,c.matcher.itemIdentity
    c.matcher.canonicalNBT=function(value) if value==EMPTY then return EMPTY end;return originalCanonical(value) end
    c.matcher.itemIdentity=function(item) return item.name.."|NBT|"..c.matcher.canonicalNBT(item.nbt) end
    assert(w.grant(1,deliveries));assert(w.result(1,deliveries,{{id="R-CARROT",status="error"},{id="R-WHEAT",status="error"},{id="R-STONE",status="error"}}))
    c.matcher.canonicalNBT,c.matcher.itemIdentity=originalCanonical,originalIdentity
    assert(c.store.data.client.fault and c.store.data.client.fault.code=="DELIVERY_MISSING")
    assert(c.store.data.client.intent==nil);Test.equal(#w.callsFor("import",false),0)
    return w,c,carrot,wheat,stone,deliveries
end

Test.case("an existing three-carrot missing delivery reconciles empty-tag stock without moving items or advancing any receipt",function()
    local w,c,carrot,wheat,stone,deliveries=missingCarrotFixture()
    local before=encode(c.store.data.client.shipments);local requests=encode(c.store.data.client.requests)
    local chest=encode(w.channels.D2.slots)
    c.restart();assert(c.store.data.client.fault and c.store.data.client.fault.code=="DELIVERY_MISSING")
    Test.equal(quantity(c.io,"delivery",carrot,w),36)
    Test.equal(quantity(c.io,"delivery",wheat,w),7,"separate nil and empty-tag stacks did not aggregate")
    local ok,detail=w.at(2,c.engine.reconcile);assert(ok,detail)
    assert(c.store.data.client.fault==nil and c.store.data.client.intent==nil)
    Test.equal(encode(c.store.data.client.shipments),before);Test.equal(encode(c.store.data.client.requests),requests)
    Test.equal(encode(w.channels.D2.slots),chest);Test.equal(#w.callsFor("import",false),0)
    Test.equal(#w.callsFor("export",false),0);Test.equal(#w.callsFor(nil,true),0)
    assert(w.grant(2,deliveries));local imports=w.callsFor("import",false)
    Test.equal(#imports,1);Test.equal(imports[1].filter.name,carrot.name);Test.equal(imports[1].filter.fromSlot,0)
    Test.equal(imports[1].filter.count,3);Test.equal(c.store.data.client.shipments["shipment-183"].imported,3)
    Test.equal(quantity(c.io,"delivery",carrot,w),33);Test.equal(quantity(c.io,"delivery",wheat,w),7)
    Test.equal(quantity(c.io,"delivery",stone,w),2)
    for _,id in ipairs({"shipment-184","shipment-185","shipment-186"}) do Test.equal(c.store.data.client.shipments[id].imported,0) end
    assert(w.grant(2,deliveries));Test.equal(#w.callsFor("import",false),1,"duplicate grant repeated the three-carrot import")
    assert(w.result(2,deliveries,{status("R-CARROT"),status("R-WHEAT"),status("R-STONE")}))
    c.restart();w.tick(2);assert(w.grant(3,deliveries))
    Test.equal(c.store.data.client.shipments["shipment-183"].imported,3)
    Test.equal(quantity(c.io,"delivery",carrot,w),33)
    local batch=w.packet("batch").message;Test.equal(batch.imports["shipment-183"],3)
    assert(c.store.data.client.requests["R-CARROT"].status~="delivered","warehouse import completed a still-active MineColonies request")
    local carrotImports=0
    for _,call in ipairs(w.callsFor("import",false)) do if call.filter.name==carrot.name then carrotImports=carrotImports+1 end end
    Test.equal(carrotImports,1,"restart imported extra carrots from unassigned stock")
end)

Test.case("missing delivery repair still refuses a genuinely tagged carrot and preserves every outstanding receipt",function()
    local w,c,carrot,_,_,deliveries=missingCarrotFixture(true)
    c.restart();local ledger=encode(c.store.data.client.shipments);local files=encode(w.files)
    Test.equal(quantity(c.io,"delivery",carrot,w),0)
    local ok,detail=w.at(2,c.engine.reconcile)
    assert(not ok and detail:find("verified shipment is still missing",1,true))
    assert(c.store.data.client.fault and c.store.data.client.fault.code=="DELIVERY_MISSING")
    Test.equal(encode(c.store.data.client.shipments),ledger);Test.equal(encode(w.files),files)
    Test.equal(#w.callsFor("import",false),0);Test.equal(#w.callsFor("export",false),0)
    assert(w.grant(2,deliveries));Test.equal(#w.callsFor("import",false),0)
    for _,delivery in ipairs(deliveries) do Test.equal(c.store.data.client.shipments[delivery.id].imported,0) end
end)

local function legacyBaseline(name)
    return {version=1,totals={
        [name.."|NBT|"]={item={name=name},count=20},
        [name.."|NBT|"..EMPTY]={item={name=name,nbt=EMPTY},count=16},
    }}
end

Test.case("physical baseline verification merges old empty-tag keys without rewriting the retained journal",function()
    local _,c=S.clientFixture();local carrot={name="minecraft:carrot"}
    local baseline=legacyBaseline(carrot.name);local original=encode(baseline)
    local unchanged=assert(c.io.exportBaseline({[1]={name=carrot.name,nbt=EMPTY,count=36}}))
    assert(c.io.sameExportBaseline(baseline,unchanged));assert(c.io.sameExportBaseline(unchanged,baseline))
    local item,delta=c.io.exportEvidence(baseline,{[1]={name=carrot.name,nbt=EMPTY,count=34},[2]={name=carrot.name,count=5}},carrot,3,"plain-name")
    assert(item);Test.equal(item.name,carrot.name);Test.equal(item.nbt,nil);Test.equal(delta,3)
    Test.equal(encode(baseline),original,"read-only baseline compatibility rewrote the durable original")
end)

Test.case("empty-tag baseline compatibility refuses corrupt keys real tagged gains losses and nonfinite quantities",function()
    local _,c=S.clientFixture();local carrot={name="minecraft:carrot"}
    local cases={
        {name="legacy key without exact hash descriptor",change=function(b) b.totals[carrot.name.."|NBT|"..EMPTY].item.nbt=nil end},
        {name="legacy key for a genuinely tagged descriptor",change=function(b) b.totals[carrot.name.."|NBT|"..EMPTY].item.nbt=string.rep("a",32) end},
        {name="infinite original quantity",change=function(b) b.totals[carrot.name.."|NBT|"].count=math.huge end},
        {name="unrelated item loss",change=function(b) b.totals["minecraft:stone|NBT|"]={item={name="minecraft:stone"},count=2} end},
        {name="tagged physical gain",items={[1]={name=carrot.name,count=36},[2]={name=carrot.name,nbt=string.rep("a",32),count=3}}},
        {name="infinite current quantity",items={[1]={name=carrot.name,nbt=EMPTY,count=math.huge}}},
        {name="original quantity decrease",items={[1]={name=carrot.name,nbt=EMPTY,count=35}}},
    }
    for _,case in ipairs(cases) do
        local baseline=legacyBaseline(carrot.name);if case.change then case.change(baseline) end
        local before=encode(baseline)
        local item,reason=c.io.exportEvidence(baseline,case.items or {[1]={name=carrot.name,nbt=EMPTY,count=39}},carrot,3,"plain-name")
        assert(item==nil and type(reason)=="string",case.name.." was accepted")
        Test.equal(encode(baseline),before)
    end
end)

Test.case("legacy and normalized client return bindings coalesce only when their exact AP fingerprints agree",function()
    for _,mode in ipairs({"legacy","equivalent duplicate","conflicting duplicate"}) do
        local w,c=S.clientFixture();w.asymmetricNBT=true
        local carrot={name="minecraft:carrot",nbt={}};local fp=w.fingerprint(carrot)
        w.insert(w.channels.R2,carrot,8)
        local oldKey=carrot.name.."|NBT|"..EMPTY;local key=c.matcher.itemIdentity({name=carrot.name})
        c.store.data.client.returnSelectors[oldKey]={item={name=carrot.name,nbt=EMPTY},fingerprint=fp}
        if mode~="legacy" then
            c.store.data.client.returnSelectors[key]={item={name=carrot.name},fingerprint=mode=="conflicting duplicate" and string.rep("f",32) or fp}
        end
        local wheat={name="minecraft:wheat"};w.insert(w.channels.D2,wheat,1)
        local delivery=shipment("D-WHEAT","R1",wheat,1)
        c.store.save();c.restart()
        assert(c.store.data.client.returnSelectors[oldKey],"boot silently discarded the legacy binding")
        local ledger=encode(c.store.data.client.returnSelectors)
        assert(w.grant(1,{delivery}));local batch=w.packet("batch").message
        if mode=="conflicting duplicate" then
            assert(c.store.data.client.fault and c.store.data.client.fault.code=="RETURN_SELECTOR")
            Test.equal(#w.callsFor("import",false),0,"conflicting retained selectors allowed a delivery import")
            Test.equal(encode(c.store.data.client.returnSelectors),ledger)
        else
            assert(c.store.data.client.fault==nil)
            Test.equal(#batch.returnSelectors,1);Test.equal(batch.returnSelectors[1].fingerprint,fp)
            Test.equal(batch.returnSelectors[1].item.nbt,nil)
            Test.equal(#w.callsFor("import",false),1)
        end
        Test.equal(quantity(c.io,"returns",{name=carrot.name},w),8)
        Test.equal(#w.callsFor("export",false),0)
    end
end)

Test.case("master accepts old empty-tag return keys but keeps physical bindings held against changed or conflicting fingerprints",function()
    for _,mode in ipairs({"matching","equivalent duplicate","changed incoming","conflicting retained"}) do
        local w=S.world({asymmetricNBT=true});local m=S.computer(w,1,"master")
        m.rs=w.bridge(1,"prs",true);m.config.automationEnabled=false
        m.config.colonies={{id=2,label="Stardust",deliveryChest="master-delivery",returnChest="master-return",deliveryChannel="D2",returnChannel="R2"}}
        w.chest(1,"master-delivery","D2");w.chest(1,"master-return","R2")
        local carrot={name="minecraft:carrot",nbt={}};local fp=w.fingerprint(carrot);w.insert(w.channels.R2,carrot,8)
        m.start();w.at(1,m.engine.onMessage,2,{version=1,kind="hello",deliveryChannel="D2",returnChannel="R2"})
        local cs=m.store.data.master.colonies["2"];local oldKey=carrot.name.."|NBT|"..EMPTY;local key=m.matcher.itemIdentity({name=carrot.name})
        cs.returnSelectors={[oldKey]={item={name=carrot.name,nbt=EMPTY},fingerprint=fp}}
        if mode=="conflicting retained" then cs.returnSelectors[key]={item={name=carrot.name},fingerprint=string.rep("f",32)} end
        cs.turn={phase="WAIT_BATCH",id=1,session="S",policy=Config.policy(m.config)};m.store.save()
        local retained=encode(cs.returnSelectors)
        local rows={{item={name=carrot.name},fingerprint=mode=="changed incoming" and string.rep("f",32) or fp}}
        if mode=="equivalent duplicate" then rows[#rows+1]={item={name=carrot.name,nbt=EMPTY},fingerprint=fp} end
        local accepted=w.at(1,m.engine.onMessage,2,{version=1,kind="batch",session="S",turn=1,
            requests={},activeIds={},imports={},returnSelectors=rows,authoritative=true})
        if mode=="changed incoming" or mode=="conflicting retained" then
            assert(not accepted);Test.equal(cs.turn.phase,"WAIT_BATCH");Test.equal(encode(cs.returnSelectors),retained)
        else
            assert(accepted);Test.equal(cs.turn.phase,"READY");Test.equal(cs.returnSelectors[key].fingerprint,fp)
            Test.equal(#cs.turn.batch.returnSelectors,1);Test.equal(cs.returnSelectors[key].item.nbt,nil)
        end
        Test.equal(w.at(1,function() return m.io.count(assert(m.io.snapshot("master-return")),{name=carrot.name}) end),8)
        Test.equal(#w.callsFor("import",true),0);Test.equal(#w.callsFor("export",true),0)
    end
end)

Test.case("repairing the real empty-tag carrot handoff imports shipment183 once without resupplying after either computer reboots",function()
    local w=S.world({asymmetricNBT=true});local m=S.computer(w,1,"master");local c=S.computer(w,2,"supply")
    c.config.deliveryChannel="D2";c.config.returnChannel="R2"
    m.config.colonies={{id=2,label="Stardust",deliveryChest="master-delivery",returnChest="master-return",deliveryChannel="D2",returnChannel="R2"}}
    w.chest(1,"master-delivery","D2");w.chest(1,"master-return","R2")
    w.chest(2,"delivery","D2");w.chest(2,"returns","R2")
    m.rs=w.bridge(1,"prs",true);c.rs=w.bridge(2,"crs",false);c.integrator=w.integrator(2,"integrator")
    local carrot={name="minecraft:carrot"}
    w.insert(w.channels.D2,{name=carrot.name,nbt={}},33);m.rs.add(carrot,8)
    c.integrator.requests={S.request("R-CARROT",carrot.name,3)}
    m.store.data.master={shipmentCounter=182}
    local originalCanonical=c.matcher.canonicalNBT
    c.matcher.canonicalNBT=function(value) if value==EMPTY then return EMPTY end;return originalCanonical(value) end
    c.matcher.itemIdentity=function(item) return item.name.."|NBT|"..c.matcher.canonicalNBT(item.nbt) end
    c.start();m.start()
    function w.step() w.tick(1);w.tick(2);w.flush();w.advance(.25) end
    function w.untilTrue(predicate,detail)
        for _=1,240 do if predicate() then return end;w.step() end
        assert(predicate(),detail or "empty-tag handoff did not reach its expected state")
    end
    w.untilTrue(function() return c.store.data.client.fault~=nil end)
    Test.equal(c.store.data.client.fault.code,"DELIVERY_MISSING");m.config.automationEnabled=false
    w.untilTrue(function()
        local cs=m.store.data.master.colonies["2"]
        return cs and cs.turn==nil and c.store.data.client.turn and c.store.data.client.turn.phase=="finished"
    end)
    Test.equal(#w.callsFor("export",true),1);Test.equal(#w.callsFor("import",false),0)
    local cs=m.store.data.master.colonies["2"];Test.equal(#cs.shipments,1)
    Test.equal(cs.shipments[1].id,"shipment-183");Test.equal(cs.shipments[1].count,3);Test.equal(cs.shipments[1].imported,0)
    c.restart();Test.equal(quantity(c.io,"delivery",carrot,w),36)
    local ok,detail=w.at(2,c.engine.reconcile);assert(ok,detail)
    Test.equal(#w.callsFor("export",true),1);Test.equal(#w.callsFor("import",false),0)
    m.config.automationEnabled=true
    w.untilTrue(function() return m.store.data.master.colonies["2"].shipments[1].imported==3 end)
    Test.equal(#w.callsFor("export",true),1);Test.equal(#w.callsFor("import",false),1)
    Test.equal(quantity(c.io,"delivery",carrot,w),33)
    for _=1,24 do w.step() end
    c.restart();m.restart();for _=1,36 do w.step() end
    Test.equal(#w.callsFor("export",true),1,"master resupplied an already imported live request")
    Test.equal(#w.callsFor("import",false),1,"restart repeated the verified three-carrot import")
    Test.equal(quantity(c.io,"delivery",carrot,w),33)
    Test.equal(c.store.data.client.shipments["shipment-183"].imported,3)
    Test.equal(m.store.data.master.colonies["2"].shipments[1].imported,3)
    Test.equal(m.store.data.master.colonies["2"].requests["R-CARROT"].status,"in progress")
end)

Test.case("normalizing empty NBT keeps the highest configured overflow reserve under either saved identity key",function()
    for _,nbt in ipairs({false,{},EMPTY}) do
        local w,c=S.clientFixture();w.asymmetricNBT=true;c.integrator.requests={}
        c.config.overflowEnabled=true;c.config.defaultItemKeep=0;c.config.buildingItemKeep=0
        c.config.maxReturnItemsPerTurn=64;c.config.maxTransferChunk=64
        local carrot={name="minecraft:carrot",nbt=nbt or nil}
        local legacyKey=carrot.name.."|NBT|"..EMPTY;local canonicalKey=c.matcher.itemIdentity(carrot)
        c.config.keepCounts={[canonicalKey]=0,[legacyKey]=64}
        local configured=encode(c.config.keepCounts)
        c.rs.add(carrot,64)
        assert(w.grant(1));Test.equal(#w.callsFor("export",false),0,"normalization discarded the saved overflow reserve")
        Test.equal(encode(c.config.keepCounts),configured,"overflow rewrote the user's saved keep-count keys")
        Test.equal(quantity(c.io,"returns",{name=carrot.name},w),0)
        assert(c.store.data.client.fault==nil)
        Test.equal(c.rs.items[w.identity(carrot)].amount,64)
        local tagged={name=carrot.name,nbt=string.rep("a",32)}
        local keys=c.matcher.itemIdentityKeys(tagged)
        Test.equal(#keys,1);Test.equal(keys[1],c.matcher.itemIdentity(tagged))
        assert(keys[1]~=canonicalKey and keys[1]~=legacyKey,"genuinely tagged overflow stock inherited a plain-item reserve")
    end
end)

return true
