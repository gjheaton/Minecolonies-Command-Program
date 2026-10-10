local S=require("tests.support")
local D=require("tests.display_support")
local Config=require("colony.network.config")

local function fixture(role)
    local w=D.world();local config=Config.defaults(role or "master");local queries=0
    local function forbidden() queries=queries+1;error("device discovery queried inventory contents",0) end
    for _,name in ipairs({"main-monitor","free-monitor","owned-monitor-2","owned-monitor-3"}) do w.monitor(1,name) end
    for _,name in ipairs({"D2","R2","D3","R3","free-a","free-b"}) do
        w.device(1,name,"enderchests:ender_chest",{list=forbidden,size=forbidden})
        w.devices[1][name].types.inventory=true
    end
    w.device(1,"capability-only-chest","unusual:networked_inventory",{list=forbidden,size=forbidden})
    w.device(1,"incomplete-inventory","inventory",{list=forbidden})
    w.device(1,"speaker","speaker",{playNote=forbidden})
    w.device(1,"current-rs","rsBridge",{listItems=forbidden});w.device(1,"free-rs","rsBridge",{listItems=forbidden})
    w.device(1,"integrator","colonyIntegrator",{getRequests=forbidden})
    local originalType=peripheral.getType
    peripheral.getType=function(name)
        local device=w.devices[w.id] and w.devices[w.id][name]
        if device and device.types.inventory and device.kind~="inventory" then return device.kind,"inventory","custom_inventory" end
        return originalType(name)
    end
    return {w=w,config=config,queries=function() return queries end}
end
local function values(choices)
    local out={};for _,choice in ipairs(choices) do out[choice.value]=choice end;return out
end
local function routes(config)
    config.monitorName="main-monitor";config.colonies={D.route(2,"owned-monitor-2"),D.route(3,"owned-monitor-3")}
end

Test.case("peripheral discovery separates bridge integrator and mod inventory capabilities without any storage query",function()
    local f=fixture("supply");local Devices=require("colony.network.devices")
    local inventory=values(Devices.choices(f.config,"deliveryChestName"))
    assert(inventory["D2"] and inventory["capability-only-chest"])
    assert(not inventory["incomplete-inventory"] and not inventory["speaker"] and not inventory["free-rs"])
    assert(inventory.D2.detail:find("enderchests:ender_chest",1,true) and inventory.D2.detail:find("custom_inventory",1,true))
    local bridges=values(Devices.choices(f.config,"colonyBridgeName"));assert(bridges["current-rs"] and bridges["free-rs"])
    assert(not bridges.integrator and not bridges["D2"])
    local integrators=values(Devices.choices(f.config,"colonyIntegratorName"));assert(integrators.integrator and not integrators["current-rs"])
    local monitors=values(Devices.choices(f.config,"monitorName"));assert(monitors["free-monitor"] and not monitors.integrator)
    Test.equal(f.queries(),0);Test.equal(#f.w.calls,0)
end)

Test.case("master monitor choices retain the current overview and exclude dashboards owned by colony routes",function()
    local f=fixture();routes(f.config);local Devices=require("colony.network.devices")
    local overview=values(Devices.choices(f.config,"monitorName"))
    assert(overview["main-monitor"] and overview["free-monitor"])
    assert(not overview["owned-monitor-2"] and not overview["owned-monitor-3"])
    local draft=S.copy(f.config.colonies[1])
    local panel=values(Devices.choices(f.config,"monitorName",{route=draft,routeId=2}))
    assert(panel["owned-monitor-2"] and panel["free-monitor"])
    assert(not panel["main-monitor"] and not panel["owned-monitor-3"])
    Test.equal(f.queries(),0)
end)

Test.case("route inventory discovery excludes other colonies and the draft counterpart while retaining its current channel",function()
    local f=fixture();routes(f.config);local Devices=require("colony.network.devices")
    local draft=S.copy(f.config.colonies[1]);local options={route=draft,routeId=2}
    local choices=values(Devices.choices(f.config,"deliveryChest",options))
    assert(choices.D2 and choices["free-a"] and choices["capability-only-chest"])
    assert(not choices.R2 and not choices.D3 and not choices.R3)
    draft.returnChest="free-a";choices=values(Devices.choices(f.config,"deliveryChest",options))
    assert(not choices["free-a"] and choices.D2 and not choices.D3)
    local allowed,err=Devices.available(f.config,"deliveryChest","D3",options)
    assert(allowed==false and type(err)=="string", "save validation admitted another colony's chest")
    Test.equal(f.queries(),0)
end)

Test.case("colony inventory choices reject the other direction and detect disconnects at save time",function()
    local f=fixture("supply");local Devices=require("colony.network.devices")
    f.config.deliveryChestName="free-a";f.config.returnChestName="free-b"
    local deliveries=values(Devices.choices(f.config,"deliveryChestName"));assert(deliveries["free-a"] and not deliveries["free-b"])
    local returns=values(Devices.choices(f.config,"returnChestName"));assert(returns["free-b"] and not returns["free-a"])
    assert(Devices.available(f.config,"deliveryChestName","free-a"))
    f.w.devices[1]["free-a"]=nil
    local allowed,err=Devices.available(f.config,"deliveryChestName","free-a")
    assert(allowed==false and type(err)=="string", "disconnected inventory was still considered saveable")
    Test.equal(f.queries(),0)
end)

Test.case("device ownership includes all configuration fields and releases a replaced route draft chest",function()
    local f=fixture();routes(f.config);local Devices=require("colony.network.devices")
    f.config.playerBridgeName="current-rs";f.config.colonyBridgeName="free-rs"
    local bridges=values(Devices.choices(f.config,"playerBridgeName"))
    assert(bridges["current-rs"] and not bridges["free-rs"],"another configured bridge was offered as unused")
    local draft=S.copy(f.config.colonies[1]);draft.deliveryChest="free-a"
    local choices=values(Devices.choices(f.config,"returnChest",{route=draft,routeId=2}))
    assert(choices.D2 and choices.R2 and not choices["free-a"],"draft replacement did not release the former delivery assignment")
    Test.equal(f.queries(),0)
end)

return true
