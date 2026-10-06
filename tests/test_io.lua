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
return true
