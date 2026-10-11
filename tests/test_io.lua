local S=require("tests.support")
local IO=require("colony.network.io")
local Store=require("colony.network.store")
local Config=require("colony.network.config")

Test.case("supply hardware boundary refuses every PRS operation",function()
    local w,client=S.clientFixture()
    local prs=w.bridge(2,"prs",true)
    prs.add({name="minecraft:stone"},10)
    local candidate=client.matcher.requestCandidates(S.request("R","minecraft:stone",1))[1]
    w.at(2,function()
        local stock,err=client.io.stock();assert(stock==nil and err:find("cannot access PRS"))
        local moved=client.io.exportPRS(candidate,prs.items[w.identity({name="minecraft:stone"})],1,"delivery")
        assert(moved==nil)
        assert(client.io.importPRS({name="minecraft:stone"},1,"returns")==nil)
        assert(client.io.craft(candidate,1)==nil)
        local craftable,craftError=client.io.craftable(candidate)
        assert(craftable~=true and tostring(craftError):find("cannot access PRS"))
    end)
    Test.equal(#w.callsFor(nil,true),0,"colony reached PRS")
end)

Test.case("inventory verification distinguishes same-name NBT and opaque hashes",function()
    local w,client=S.clientFixture()
    local chest=w.channels.D2
    w.insert(chest,{name="minecraft:iron_pickaxe",nbt="hash-a",maxCount=1},1)
    w.insert(chest,{name="minecraft:iron_pickaxe",nbt="hash-b",maxCount=1},1)
    w.at(2,function()
        local items=assert(client.io.snapshot("delivery"))
        Test.equal(client.io.count(items,{name="minecraft:iron_pickaxe",nbt="hash-a"}),1)
        Test.equal(client.io.count(items,{name="minecraft:iron_pickaxe",nbt="hash-b"}),1)
        Test.equal(client.io.count(items,{name="minecraft:iron_pickaxe"}),0,"generic identity claimed an opaque NBT item")
        Test.equal(client.io.capacity("delivery",items,{name="minecraft:iron_pickaxe",nbt="hash-a",maxCount=1},1),24)
    end)
end)

Test.case("inventory snapshot rejects inconsistent list and detail",function()
    local w,client=S.clientFixture()
    w.insert(w.channels.D2,{name="minecraft:stone"},4)
    w.devices[2].delivery.api.getItemDetail=function() return {name="minecraft:stone",count=3} end
    w.at(2,function()
        local items,err=client.io.snapshot("delivery")
        assert(items==nil and err:find("changed during snapshot"))
    end)
end)

Test.case("two-slot journal recovers prior durable revision and rejects two corrupt slots",function()
    local w=S.world()
    local store=Store.new("/journal",Config.defaults("master"))
    store.data.value="before";store.save();store.data.value="after";store.save()
    w.files["/journal.a"]="broken"
    local recovered=Store.new("/journal",Config.defaults("master"));recovered.load()
    Test.equal(recovered.data.value,"before")
    w.files["/journal.b"]="broken"
    local ok,err=pcall(function() Store.new("/journal",Config.defaults("master")).load() end)
    assert(not ok and tostring(err):find("refusing new transfers"))
end)

Test.case("journal write failure latches and blocks later writes",function()
    local w=S.world();local store=Store.new("/journal",Config.defaults("master"))
    store.save();w.writeFail=true
    local ok,err=pcall(store.save);assert(not ok and tostring(err):find("Persistence failure"))
    w.writeFail=false;local second,secondErr=pcall(store.save)
    assert(not second and tostring(secondErr):find("Persistence failure"))
end)

Test.case("route configuration refuses reused names or color channels",function()
    S.world();local config=Config.defaults("master")
    config.colonies={{id=2,deliveryChest="D2",returnChest="R2",deliveryChannel="red-white-blue",returnChannel="red-white-black"},
        {id=3,deliveryChest="D3",returnChest="R3",deliveryChannel="RED-WHITE-BLUE",returnChannel="yellow-white-black"}}
    local ok,err=Config.validate(config);assert(not ok and err:find("exclusive"))
    config.colonies[2].deliveryChannel="yellow-white-blue";config.colonies[2].returnChest="D2"
    ok,err=Config.validate(config);assert(not ok and err:find("exclusive"))
    config.colonies[2].returnChest="R3";assert(Config.validate(config))
end)

Test.case("unknown stack limits reserve a chest slot until inventory details teach the actual limit",function()
    local w,c=S.clientFixture();w.chest(2,"delivery","D2",2);w.channels.D2.size=2
    local pearl={name="minecraft:ender_pearl"}
    w.at(2,function()
        local empty=assert(c.io.snapshot("delivery"))
        Test.equal(c.io.capacity("delivery",empty,pearl,1),1,"unknown item consumed reserved slots")
        w.insert(w.channels.D2,{name=pearl.name,maxCount=16},1)
        local learned=assert(c.io.snapshot("delivery"))
        Test.equal(c.io.capacity("delivery",learned,pearl,1),15,"known stack size did not fill existing slot safely")
        Test.equal(c.io.capacity("delivery",learned,pearl,0),31)
    end)
end)

Test.case("real bridge IO preserves returned failure reasons and thrown errors while keeping unknown zero and positive quantities distinct",function()
    for _,mode in ipairs({"reason","unknown","throw","zero","positive"}) do
        local w,c=S.clientFixture();w.insert(w.channels.D2,{name="minecraft:stone"},4)
        local original=w.devices[2].crs.api.importItemFromPeripheral;local calls=0
        w.devices[2].crs.api.importItemFromPeripheral=function(filter,chest)
            calls=calls+1
            if mode=="reason" then return nil,"NOT_CONNECTED" end
            if mode=="unknown" then return nil end
            if mode=="throw" then error("Bridge disconnected during import",0) end
            if mode=="zero" then return 0,"INVALID_TARGET" end
            return original(filter,chest),"successful import detail"
        end
        local count,err
        w.at(2,function() count,err=c.io.importColony({name="minecraft:stone"},4,"delivery") end)
        Test.equal(calls,1)
        if mode=="reason" then Test.equal(count,nil);Test.equal(err,"NOT_CONNECTED")
        elseif mode=="unknown" then Test.equal(count,nil);Test.equal(err,"Transfer result unknown")
        elseif mode=="throw" then Test.equal(count,nil);Test.equal(err,"Bridge disconnected during import")
        elseif mode=="zero" then Test.equal(count,0);Test.equal(err,nil)
        else Test.equal(count,4);Test.equal(err,nil) end
        Test.equal(w.count(w.channels.D2,{name="minecraft:stone"}),mode=="positive" and 0 or 4)
    end
end)

Test.case("bridge connection diagnostics select the configured role bridge and preserve unknown states without reading or mutating RS storage",function()
    for _,mode in ipairs({"true","false","false_reason","nil_reason","invalid","throw","no_method","missing"}) do
        local w,c=S.clientFixture();w.bridge(2,"prs",true);w.bridge(2,"other-crs",false)
        local api=w.devices[2].crs.api;local statusCalls=0
        api.listItems=function() error("connection status queried stock",0) end
        api.importItemFromPeripheral=function() error("connection status imported",0) end
        api.exportItemToPeripheral=function() error("connection status exported",0) end
        api.isConnected=function()
            statusCalls=statusCalls+1
            if mode=="true" then return true end
            if mode=="false" then return false end
            if mode=="false_reason" then return false,"Network controller is offline" end
            if mode=="nil_reason" then return nil,"NOT_CONNECTED" end
            if mode=="invalid" then return "probably" end
            error("Connection query unavailable",0)
        end
        if mode=="no_method" then api.isConnected=nil end
        if mode=="missing" then c.config.colonyBridgeName="missing-crs" end
        local before=textutils.serialize(w.files);local revision=c.store.data.revision;local result
        w.at(2,function() result=c.io.bridgeStatus() end)
        if mode=="missing" then
            Test.equal(result.connected,false);assert(result.error:find("missing-crs",1,true));Test.equal(statusCalls,0)
        else
            Test.equal(result.name,"crs")
            Test.equal(statusCalls,mode=="no_method" and 0 or 1)
            if mode=="true" then Test.equal(result.connected,true);Test.equal(result.error,nil)
            elseif mode=="false" then Test.equal(result.connected,false);Test.equal(result.error,"NOT_CONNECTED")
            elseif mode=="false_reason" then Test.equal(result.connected,false);Test.equal(result.error,"Network controller is offline")
            else
                Test.equal(result.connected,nil)
                if mode=="nil_reason" then Test.equal(result.error,"NOT_CONNECTED")
                elseif mode=="throw" then Test.equal(result.error,"Connection query unavailable")
                elseif mode=="no_method" then assert(result.error:find("lacks isConnected",1,true))
                else assert(result.error:find("connection unknown",1,true)) end
            end
        end
        Test.equal(#w.calls,0);Test.equal(c.store.data.revision,revision);Test.equal(textutils.serialize(w.files),before)
    end
end)

local SHEARS_PRISTINE="552887824c43124013fd24f6edcde0fb"
local SHEARS_DAMAGED="02c06ecf0eda564a1aa1f1a1f23e36be"
local SHEARS_ENCHANTED="16794e149aa387a647d12ce3a88645ce"
local EMPTY_COMPOUND="41883520c3071f5f4a4a4613fb005e0c"

Test.case("export evidence binds AP compound tools to their unique physical CC hash without reading or moving storage",function()
    for _,variant in ipairs({
        {nbt={Damage=0},hash=SHEARS_PRISTINE,damage=0},
        {nbt={Damage=42},hash=SHEARS_DAMAGED,damage=42},
        {nbt={Damage=0,Enchantments={{id="minecraft:unbreaking",lvl=3}}},hash=SHEARS_ENCHANTED,damage=0},
    }) do
        local w,c=S.clientFixture()
        local source={name="minecraft:shears",nbt=variant.nbt,amount=1,fingerprint="AP-source-variant"}
        local before={[2]={name="minecraft:stone",count=12},[5]={name="minecraft:shears",nbt="unrelated-physical-hash",count=1}}
        local after=S.copy(before)
        after[9]={name=source.name,nbt=variant.hash,count=1,damage=variant.damage,maxDamage=238,maxCount=1}
        local beforeFiles=textutils.serialize(w.files)
        w.at(2,function()
            local baseline=assert(c.io.exportBaseline(before))
            local item,delta=c.io.exportEvidence(baseline,after,source,1)
            assert(item,"AP compound did not bind to physical CC identity")
            Test.equal(item.name,source.name);Test.equal(item.nbt,variant.hash);Test.equal(delta,1)
            Test.equal(item.fingerprint,nil,"evidence invented an AP selector")
            Test.equal(c.io.count(after,item),1)
        end)
        Test.equal(#w.calls,0);Test.equal(textutils.serialize(w.files),beforeFiles)
    end
end)

Test.case("export evidence aggregates one physical identity across slots while preserving every other variant",function()
    local w,c=S.clientFixture()
    local before={[1]={name="minecraft:stone",nbt="selected-hash",count=5},[2]={name="minecraft:stone",nbt="other-hash",count=11}}
    local after=S.copy(before);after[1].count=7;after[8]={name="minecraft:stone",nbt="selected-hash",count=3}
    w.at(2,function()
        local baseline=assert(c.io.exportBaseline(before))
        local item,delta=c.io.exportEvidence(baseline,after,{name="minecraft:stone",nbt={display={Name="selected"}},fingerprint="AP-selected"},5)
        assert(item);Test.equal(item.nbt,"selected-hash");Test.equal(delta,5)
        Test.equal(c.io.count(after,item)-c.io.count(before,item),5)
        Test.equal(c.io.count(after,{name="minecraft:stone",nbt="other-hash"}),11)
    end)
    Test.equal(#w.calls,0)
end)

Test.case("export evidence rejects phantom delayed wrong-item mixed-variant and collateral inventory changes",function()
    local modes={"phantom","delayed","wrong-name","two-variants","collateral-loss","collateral-gain","quantity-mismatch"}
    for _,mode in ipairs(modes) do
        local w,c=S.clientFixture()
        local before={[1]={name="minecraft:stone",count=4},[2]={name="minecraft:shears",nbt=SHEARS_DAMAGED,count=1}}
        local after=S.copy(before);local reported=1
        if mode=="wrong-name" then after[3]={name="minecraft:iron_pickaxe",nbt=SHEARS_PRISTINE,count=1}
        elseif mode=="two-variants" then
            reported=2;after[3]={name="minecraft:shears",nbt=SHEARS_PRISTINE,count=1};after[4]={name="minecraft:shears",nbt=SHEARS_ENCHANTED,count=1}
        elseif mode~="phantom" and mode~="delayed" then
            after[3]={name="minecraft:shears",nbt=SHEARS_PRISTINE,count=1}
            if mode=="collateral-loss" then after[1].count=3
            elseif mode=="collateral-gain" then after[1].count=5
            elseif mode=="quantity-mismatch" then reported=2 end
        end
        w.at(2,function()
            local item,err=c.io.exportEvidence(assert(c.io.exportBaseline(before)),after,{name="minecraft:shears",nbt={Damage=0},fingerprint="AP-pristine"},reported)
            Test.equal(item,nil,mode.." was credited");assert(type(err)=="string" and err~="",mode.." has no diagnostic")
        end)
        Test.equal(#w.calls,0,mode.." retried a transfer")
    end
end)

Test.case("physical export evidence requires a known finite positive integer bridge quantity",function()
    local quantities={{nil},{false},{"1"},{0},{-1},{0.5},{math.huge},{-math.huge},{0/0}}
    for _,value in ipairs(quantities) do
        local w,c=S.clientFixture()
        w.at(2,function()
            local baseline=assert(c.io.exportBaseline({}))
            local item,err=c.io.exportEvidence(baseline,{[1]={name="minecraft:shears",nbt=SHEARS_PRISTINE,count=1}},
                {name="minecraft:shears",nbt={Damage=0},fingerprint="AP-pristine"},value[1])
            Test.equal(item,nil,"unknown/invalid quantity credited a physical gain");assert(type(err)=="string")
        end)
        Test.equal(#w.calls,0)
    end
end)

Test.case("export baselines detach from mutable snapshots and reject malformed physical counts",function()
    local w,c=S.clientFixture()
    w.at(2,function()
        local before={[1]={name="minecraft:stone",count=4},[2]={name="minecraft:shears",nbt=SHEARS_DAMAGED,count=1}}
        local baseline=assert(c.io.exportBaseline(before));local stable=textutils.serialize(baseline)
        before[1].count=99;before[2].nbt=SHEARS_ENCHANTED
        Test.equal(textutils.serialize(baseline),stable,"baseline followed a later mutable snapshot")
        local physical,delta=c.io.exportEvidence(baseline,{[1]={name="minecraft:stone",count=4},
            [2]={name="minecraft:shears",nbt=SHEARS_DAMAGED,count=1},[3]={name="minecraft:shears",nbt=SHEARS_PRISTINE,count=1}},
            {name="minecraft:shears",fingerprint="AP-pristine"},1)
        assert(physical);Test.equal(delta,1)
        for _,value in ipairs({{nil},{"1"},{false},{-1},{0.5},{math.huge},{0/0}}) do
            local rejected,err=c.io.exportBaseline({[1]={name="minecraft:shears",nbt=SHEARS_PRISTINE,count=value[1]}})
            Test.equal(rejected,nil,"malformed baseline count was accepted");assert(type(err)=="string")
        end
        local rejected,err=c.io.exportBaseline({[1]={count=1}})
        Test.equal(rejected,nil);assert(type(err)=="string")
    end)
    Test.equal(#w.calls,0)
end)

Test.case("inventory snapshots reject same-name same-count NBT changes between list and detail",function()
    for _,hashes in ipairs({{SHEARS_PRISTINE,SHEARS_DAMAGED},{false,EMPTY_COMPOUND},{EMPTY_COMPOUND,false}}) do
        local w,c=S.clientFixture();local api=w.devices[2].delivery.api
        api.list=function() return {[1]={name="minecraft:shears",count=1,nbt=hashes[1] or nil}} end
        api.getItemDetail=function() return {name="minecraft:shears",count=1,nbt=hashes[2] or nil,damage=0,maxCount=1} end
        w.at(2,function()
            local items,err=c.io.snapshot("delivery")
            Test.equal(items,nil,"detail silently replaced the physical NBT identity")
            assert(tostring(err):find("changed during snapshot",1,true))
        end)
        Test.equal(#w.calls,0)
    end
end)

Test.case("inventory snapshot retains stable hash and useful damage details",function()
    local w,c=S.clientFixture();local api=w.devices[2].delivery.api
    api.list=function() return {[1]={name="minecraft:shears",count=1,nbt=SHEARS_DAMAGED}} end
    api.getItemDetail=function() return {name="minecraft:shears",count=1,nbt=SHEARS_DAMAGED,damage=42,maxDamage=238,maxCount=1} end
    w.at(2,function()
        local items=assert(c.io.snapshot("delivery"));Test.equal(items[1].nbt,SHEARS_DAMAGED)
        Test.equal(items[1].damage,42);Test.equal(items[1].maxDamage,238);Test.equal(items[1].maxCount,1)
    end)
    Test.equal(#w.calls,0)
end)

Test.case("unbound physical hashes and structured NBT imports stop before any PRS or colony bridge transfer",function()
    for _,role in ipairs({"master","supply"}) do
        for _,nbt in ipairs({SHEARS_PRISTINE,EMPTY_COMPOUND,"{Damage:0}",{Damage=0}}) do
            local w=S.world();local c=S.computer(w,role=="master" and 1 or 2,role)
            w.chest(c.id,"delivery","boundary-delivery");w.bridge(c.id,role=="master" and "prs" or "crs",role=="master")
            local before=textutils.serialize(w.files)
            w.at(c.id,function()
                local quantity,err
                if role=="master" then quantity,err=c.io.importPRS({name="minecraft:shears",nbt=nbt},1,"delivery")
                else quantity,err=c.io.importColony({name="minecraft:shears",nbt=nbt},1,"delivery") end
                Test.equal(quantity,nil,"unbound NBT crossed the bridge");assert(type(err)=="string" and err~="")
            end)
            Test.equal(#w.calls,0,"CC hash was forwarded as AP SNBT");Test.equal(textutils.serialize(w.files),before)
        end
    end
end)

Test.case("plain imports bind the lowest exact CC slot using the AP zero-based fromSlot field",function()
    for _,role in ipairs({"master","supply"}) do
        local w=S.world();local c=S.computer(w,role=="master" and 1 or 2,role)
        local chest=w.chest(c.id,"delivery","slot-delivery");w.bridge(c.id,role=="master" and "prs" or "crs",role=="master")
        chest.slots={[1]={name="minecraft:stone",nbt="tagged-stone",count=1},[3]={name="minecraft:stone",count=2},
            [7]={name="minecraft:stone",count=3},[9]={name="minecraft:dirt",count=4}}
        w.at(c.id,function()
            local function import()
                if role=="master" then return c.io.importPRS({name="minecraft:stone"},4,"delivery") end
                return c.io.importColony({name="minecraft:stone"},4,"delivery")
            end
            Test.equal(import(),2,"slot-bound import scanned another stack")
            Test.equal(chest.slots[3],nil);Test.equal(chest.slots[7].count,3)
            Test.equal(import(),3)
            Test.equal(chest.slots[7],nil);Test.equal(chest.slots[1].count,1);Test.equal(chest.slots[9].count,4)
        end)
        local calls=w.callsFor("import");Test.equal(#calls,2)
        Test.equal(calls[1].filter.fromSlot,2);Test.equal(calls[2].filter.fromSlot,6)
        for _,call in ipairs(calls) do
            Test.equal(call.filter.name,"minecraft:stone");Test.equal(call.filter.count,4)
            Test.equal(call.filter.nbt,nil);Test.equal(call.filter.fingerprint,nil)
        end
    end
end)

Test.case("plain imports cannot select a same-name physical NBT variant or an unstable slot",function()
    for _,mode in ipairs({"only-tagged","unstable"}) do
        local w,c=S.clientFixture();local api=w.devices[2].delivery.api
        if mode=="only-tagged" then w.insert(w.channels.D2,{name="minecraft:stone",nbt="tagged-stone"},1)
        else
            api.list=function() return {[1]={name="minecraft:stone",count=1}} end
            api.getItemDetail=function() return {name="minecraft:stone",count=1,nbt=EMPTY_COMPOUND} end
        end
        w.at(2,function()
            local moved,err=c.io.importColony({name="minecraft:stone"},1,"delivery")
            Test.equal(moved,nil,mode.." selected an unproved plain slot");assert(type(err)=="string")
        end)
        Test.equal(#w.calls,0,mode.." reached the bridge")
    end
end)

Test.case("exact AP selectors survive the PRS to colony and overflow return cycle while CC exposes only physical hashes",function()
    for _,variant in ipairs({
        {name="minecraft:shears",nbt={Damage=0},maxCount=1},
        {name="minecraft:shears",nbt={Damage=42},maxCount=1},
        {name="minecraft:shears",nbt={Damage=0,Enchantments={{id="minecraft:unbreaking",lvl=3}}},maxCount=1},
        {name="minecraft:stone"},
    }) do
        local w=S.world({asymmetricNBT=true});local master=S.computer(w,1,"master");local client=S.computer(w,2,"supply")
        local delivery=w.chest(1,"output","selector-delivery");w.chest(2,"delivery","selector-delivery")
        local returns=w.chest(2,"returns","selector-returns");w.chest(1,"return-input","selector-returns")
        local prs=w.bridge(1,"prs",true);local crs=w.bridge(2,"crs",false)
        local source=prs.add(variant,1)
        local other={name=variant.name,nbt={Damage=variant.nbt and variant.nbt.Damage==0 and 42 or 0,display={Name="preexisting other variant"}},maxCount=1}
        w.insert(delivery,other,1)
        local physical,initialHash
        w.at(1,function()
            assert(master.io.stock()) -- A first AP stock read may materialize an empty tag.
            local before=assert(master.io.exportBaseline(assert(master.io.snapshot("output"))))
            local candidate=assert(master.matcher.requestCandidates(S.request("R",variant.name,1))[1])
            Test.equal(master.io.exportPRS(candidate,source,1,"output"),1)
            physical=assert(master.io.exportEvidence(before,assert(master.io.snapshot("output")),source,1))
            initialHash=w.ccNBT(variant.nbt or {})
            Test.equal(physical.nbt,initialHash,"physical inventory reused AP compound NBT")
            Test.equal(physical.fingerprint,nil,"CC invented a visible fingerprint")
            physical.fingerprint=source.fingerprint -- The master binds the successful exact export selector.
        end)
        w.at(2,function()
            Test.equal(client.io.importColony(physical,1,"delivery"),1)
            local imported
            for _,item in pairs(crs.items) do if item.fingerprint==source.fingerprint and item.amount>0 then imported=item end end
            assert(imported,"colony lost the exact source selector")
            Test.equal(imported.amount,1);Test.equal(imported.fingerprint,source.fingerprint)
            Test.equal(client.matcher.canonicalNBT(imported.nbt),client.matcher.canonicalNBT(variant.nbt or {}),"colony changed source compound metadata")
            Test.equal(client.io.exportColony(physical,1,"returns"),1)
            local returned=assert(client.io.snapshot("returns"));Test.equal(client.io.count(returned,physical),1)
        end)
        w.at(1,function() Test.equal(master.io.importPRS(physical,1,"return-input"),1) end)
        local restored=0
        for _,item in pairs(prs.items) do if item.fingerprint==source.fingerprint then restored=restored+item.amount end end
        Test.equal(restored,1,"overflow failed to restore the exact original PRS selector")
        Test.equal(w.count(delivery,{name=other.name,nbt=w.ccNBT(other.nbt)}),1,"exact import took the preexisting same-name variant")
        Test.equal(next(returns.slots),nil)
        Test.equal(#w.callsFor("export"),2);Test.equal(#w.callsFor("import"),2)
        for _,call in ipairs(w.calls) do if call.method=="export" or call.method=="import" then
            Test.equal(call.filter.fingerprint,source.fingerprint)
            Test.equal(call.filter.name,nil);Test.equal(call.filter.nbt,nil);Test.equal(call.filter.fromSlot,nil)
        end end
    end
end)

Test.case("master ordinary item exports require a valid exact AP selector before reaching PRS",function()
    for _,value in ipairs({{nil},{""},{false},{3},{string.rep("f",257)}}) do
        local w=S.world();local master=S.computer(w,1,"master")
        w.chest(1,"output","selector-invalid");local prs=w.bridge(1,"prs",true)
        prs.add({name="minecraft:stone"},2)
        w.at(1,function()
            local candidate=assert(master.matcher.requestCandidates(S.request("R","minecraft:stone",1))[1])
            local quantity,err=master.io.exportPRS(candidate,{name="minecraft:stone",amount=2,fingerprint=value[1]},1,"output")
            Test.equal(quantity,nil,"invalid selector allowed a generic name export");assert(type(err)=="string")
        end)
        Test.equal(#w.calls,0)
    end
end)

Test.case("invalid or unmatched AP import selectors never broaden to another same-name variant",function()
    for _,role in ipairs({"master","supply"}) do
        for _,selector in ipairs({{""},{false},{5},{string.rep("f",257)},{string.rep("a",32)}}) do
            local w=S.world({asymmetricNBT=true});local c=S.computer(w,role=="master" and 1 or 2,role)
            local chest=w.chest(c.id,"delivery","import-selector");w.bridge(c.id,role=="master" and "prs" or "crs",role=="master")
            w.insert(chest,{name="minecraft:shears",nbt={Damage=0},maxCount=1},1)
            w.insert(chest,{name="minecraft:shears",nbt={Damage=42},maxCount=1},1)
            w.at(c.id,function()
                local item={name="minecraft:shears",nbt=SHEARS_PRISTINE,fingerprint=selector[1]}
                local moved,err
                if role=="master" then moved,err=c.io.importPRS(item,1,"delivery")
                else moved,err=c.io.importColony(item,1,"delivery") end
                if selector[1]==string.rep("a",32) then Test.equal(moved,0)
                else Test.equal(moved,nil);assert(type(err)=="string") end
                Test.equal(w.count(chest,{name=item.name,nbt=SHEARS_PRISTINE}),1)
                Test.equal(w.count(chest,{name=item.name,nbt=SHEARS_DAMAGED}),1)
            end)
            local calls=w.callsFor("import")
            Test.equal(#calls,selector[1]==string.rep("a",32) and 1 or 0)
            if calls[1] then
                Test.equal(calls[1].filter.fingerprint,selector[1]);Test.equal(calls[1].filter.name,nil)
                Test.equal(calls[1].filter.nbt,nil);Test.equal(calls[1].filter.fromSlot,nil)
            end
        end
    end
end)

Test.case("physical export evidence rejects malformed current data and tampered serialized baselines",function()
    local w,c=S.clientFixture()
    w.at(2,function()
        local source={name="minecraft:shears",fingerprint="AP-pristine"}
        local before={[1]={name="minecraft:stone",count=4}}
        local baseline=assert(c.io.exportBaseline(before))
        local after=S.copy(before);after[2]={name=source.name,nbt=SHEARS_PRISTINE,count=1}
        for _,invalid in ipairs({
            {version=2,totals=baseline.totals},
            {version=1,totals="not an inventory"},
            {version=1,totals={forged={item={name="minecraft:stone"},count=4}}},
            {version=1,totals={[c.matcher.itemIdentity(before[1])]={item={name="minecraft:stone"},count=math.huge}}},
        }) do
            local item,err=c.io.exportEvidence(invalid,after,source,1)
            Test.equal(item,nil,"tampered baseline credited an export");assert(type(err)=="string")
        end
        for _,invalid in ipairs({
            {[1]={name=source.name,nbt=SHEARS_PRISTINE,count="1"}},
            {[1]={name=source.name,nbt=SHEARS_PRISTINE,count=0.5}},
            {[1]={name=source.name,nbt=SHEARS_PRISTINE,count=1},[2]={count=1}},
            {[0]={name=source.name,nbt=SHEARS_PRISTINE,count=1}},
        }) do
            local item,err=c.io.exportEvidence(baseline,invalid,source,1)
            Test.equal(item,nil,"malformed physical observation credited an export");assert(type(err)=="string")
        end
    end)
    Test.equal(#w.calls,0)
end)

Test.case("partial imports of an untagged physical stack keep its remainder untagged even when an AP selector was retained",function()
    for _,role in ipairs({"master","supply"}) do
        local w=S.world({asymmetricNBT=true});local c=S.computer(w,role=="master" and 1 or 2,role)
        local chest=w.chest(c.id,"delivery","plain-partial");local rs=w.bridge(c.id,role=="master" and "prs" or "crs",role=="master")
        rs.importLimit=2
        local source={name="minecraft:stone"};local physical={name=source.name,fingerprint=w.fingerprint(source)}
        local other={name=source.name,nbt={display={Name="different physical variant"}}}
        w.insert(chest,other,1);w.insert(chest,source,4)
        Test.equal(chest.slots[2].nbt,nil,"fixture materialized a tag before the import")
        w.at(c.id,function()
            local function import(count)
                if role=="master" then return c.io.importPRS(physical,count,"delivery") end
                return c.io.importColony(physical,count,"delivery")
            end
            Test.equal(import(4),2)
            local remainder=assert(c.io.snapshot("delivery"))
            Test.equal(remainder[2].count,2);Test.equal(remainder[2].nbt,nil,"AP fingerprint matching retagged the remainder")
            Test.equal(c.io.count(remainder,physical),2,"partial import changed the remaining physical identity")
            Test.equal(import(2),2);Test.equal(chest.slots[2],nil)
            Test.equal(rs.items[w.identity(source)].amount,4)
        end)
        Test.equal(w.count(chest,{name=other.name,nbt=w.ccNBT(other.nbt)}),1)
        local calls=w.callsFor("import");Test.equal(#calls,2)
        for index,call in ipairs(calls) do
            Test.equal(call.filter.name,source.name);Test.equal(call.filter.fromSlot,1)
            Test.equal(call.filter.count,index==1 and 4 or 2)
            Test.equal(call.filter.fingerprint,nil,"plain import invoked a tag-mutating fingerprint predicate")
            Test.equal(call.filter.nbt,nil)
        end
    end
end)
return true
