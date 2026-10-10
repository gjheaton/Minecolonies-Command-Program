local S=require("tests.support")
local D=require("tests.display_support")
local Config=require("colony.network.config")
local Store=require("colony.network.store")

local function fixture(role,width,height,options)
    options=options or {};local w=D.world();w.id=role=="supply" and 2 or 1
    local config=Config.defaults(role);local queries=0
    keys.left=203;keys.right=205;keys.pageUp=201;keys.pageDown=209
    local function forbidden() queries=queries+1;error("peripheral picker invoked storage",0) end
    local monitor
    if width then monitor=w.monitor(w.id,"screen",width,height);config.monitorName="screen" end
    local surface=monitor or w.terminal
    local f={w=w,config=config,surface=surface,monitor=monitor,guards=0,blocked=false}
    function f.inventory(name)
        w.device(w.id,name,"enderchests:ender_chest",{list=forbidden,size=forbidden})
        w.devices[w.id][name].types.inventory=true
    end
    for _,name in ipairs({"current-delivery","current-return","free-delivery","free-return","D2","R2","D3","R3"}) do f.inventory(name) end
    for _,name in ipairs({"current-rs","free-rs"}) do w.device(w.id,name,"rsBridge",{listItems=forbidden}) end
    w.device(w.id,"integrator","colonyIntegrator",{getRequests=forbidden})
    w.monitor(w.id,"free-monitor",100,38);w.monitor(w.id,"owned-monitor",100,38)
    w.device(w.id,"bad-inventory","inventory",{list=forbidden})
    if role=="supply" then
        config.colonyBridgeName="current-rs";config.deliveryChestName="current-delivery";config.returnChestName="current-return"
    else config.playerBridgeName="current-rs";config.colonies={D.route(2,"owned-monitor"),D.route(3)} end
    Config.save(config)
    local store=Store.new("/picker/"..role.."_v4_state",config);store.save();store.save();f.store=store
    local state={role=role,health={ok=true},requests={},settings=S.copy(config)};f.state=state
    local engine={snapshot=function() return state end,busy=function() return state.busy==true end}
    engine.canEditHardware=function() f.guards=f.guards+1;return not f.blocked,"Retained transfer prevents changing hardware" end
    engine.canEditRoute=function() f.guards=f.guards+1;return not f.blocked,"Retained delivery prevents changing this route" end
    f.engine=engine
    local io={monitor=function() if monitor then return monitor,"screen" end end}
    f.ui=require("colony.network.ui").new(config,store,engine,io,nil,options)
    f.terminalRenderer=f.ui.renderTerminal
    f.ui.renderTerminal=function() end
    function f.click(x,y) return monitor and f.ui.handleEvent("monitor_touch","screen",x,y) or f.ui.handleEvent("mouse_click",1,x,y) end
    function f.find(text,reverse)
        local start,finish,step=reverse and surface.height or 1,reverse and 1 or surface.height,reverse and -1 or 1
        for y=start,finish,step do local x=(surface.lines[y] or ""):find(text,1,true);if x then return x,y end end
    end
    function f.clickText(text,reverse) local x,y=f.find(text,reverse);assert(x,"screen text absent: "..text.."\n"..surface.dump());return f.click(x,y) end
    function f.show(text)
        for _=1,50 do
            local x,y=f.find(text);if x then return x,y end
            assert(f.ui.edit and f.ui.edit.kind=="peripheral","no picker to page through")
            f.ui.handleEvent("char","n")
        end
        error("peripheral was never visible: "..text)
    end
    function f.openSetting(key)
        local count=surface.height-9
        for index,field in ipairs(Config.fields(role)) do if field.key==key then
            f.ui.view="settings";f.ui.pages.settings=math.floor((index-1)/count)+1;f.ui.draw();f.click(2,5+(index-1)%count);return
        end end
        error("setting is not exposed: "..key)
    end
    function f.number(value)
        local edit=assert(f.ui.edit,"no active picker")
        for i,choice in ipairs(edit.choices or {}) do if choice.value==value then return i end end
        error("device not selectable: "..value)
    end
    function f.select(value)
        local number=f.number(value);f.ui.handleEvent("paste",tostring(number));f.ui.handleEvent("key",keys.enter)
    end
    function f.openRoute(id)
        f.ui.view="routes";f.ui.draw();f.clickText("["..id.."]")
    end
    function f.noHardware() Test.equal(queries,0);Test.equal(#w.calls,0) end
    return f
end

Test.case("SETTINGS offers role-specific numbered bridge integrator monitor and chest pickers while preserving scalar editors",function()
    for _,role in ipairs({"master","supply"}) do
        local f=fixture(role,100,38)
        local fields=role=="master" and {{"playerBridgeName","free-rs"},{"monitorName","free-monitor"}}
            or {{"colonyBridgeName","free-rs"},{"colonyIntegratorName","integrator"},{"monitorName","free-monitor"},
                {"deliveryChestName","free-delivery"},{"returnChestName","free-return"}}
        for _,field in ipairs(fields) do
            f.openSetting(field[1]);assert(f.ui.edit and f.ui.edit.kind=="peripheral","hardware field still requires typing a name")
            f.select(field[2]);assert(not f.ui.edit);Test.equal(f.config[field[1]],field[2]);Test.equal(Config.load(role)[field[1]],field[2])
        end
        f.openSetting("craftingTimeoutSeconds");assert(f.ui.edit and f.ui.edit.kind~="peripheral")
        f.ui.handleEvent("paste","900");f.ui.handleEvent("key",keys.enter);Test.equal(f.config.craftingTimeoutSeconds,900)
        f.noHardware()
    end
end)

Test.case("peripheral pickers page full names on 51 by 19 and 100 by 38 screens for keyboard and wrapped-row touch selection",function()
    for _,dimensions in ipairs({{false,false},{100,38}}) do for _,mode in ipairs({"numeric","touch"}) do
        local f=fixture("supply",dimensions[1],dimensions[2])
        for i=1,40 do f.inventory("inventory-"..string.format("%03d",i)) end
        local name="zz_ender_chest_"..string.rep("x",109).."_END";Test.equal(#name,128);f.inventory(name)
        f.openSetting("deliveryChestName");assert(f.ui.edit.kind=="peripheral")
        local pages=0
        while not f.find("_END") do
            pages=pages+1;assert(pages<=50,"picker never displayed the full peripheral name")
            f.ui.handleEvent("char","n")
        end
        assert(pages>0 and f.ui.edit.pageCount>1,"many peripheral names were squeezed into a single page")
        local text=f.surface.dump():gsub("%s","")
        assert(text:find("zz_ender_chest_",1,true) and text:find("_END",1,true),"128-character choice was clipped")
        if mode=="numeric" then f.select(name) else f.clickText("_END") end
        assert(not f.ui.edit);Test.equal(f.config.deliveryChestName,name);Test.equal(Config.load("supply").deliveryChestName,name)
        f.noHardware()
    end end
end)

Test.case("touch picker saves respect retained transfer guards and roll back live configuration when persistence fails",function()
    local f=fixture("supply",100,38);local before=textutils.serialize(f.w.files)
    f.blocked=true;f.openSetting("deliveryChestName");f.show("free-delivery");f.clickText("free-delivery")
    assert(f.ui.edit and f.ui.edit.error:find("Retained",1,true));Test.equal(f.guards,1)
    Test.equal(f.config.deliveryChestName,"current-delivery");Test.equal(textutils.serialize(f.w.files),before)
    f.blocked=false;f.w.writeFail=true;f.clickText("free-delivery")
    assert(f.ui.edit and f.ui.edit.error);Test.equal(f.guards,2)
    Test.equal(f.config.deliveryChestName,"current-delivery");Test.equal(textutils.serialize(f.w.files),before)
    f.noHardware()
end)

Test.case("cancelled numbered picker input and touch cancellation never alter configuration or transfer journals",function()
    local f=fixture("supply",100,38);local before=textutils.serialize(f.w.files)
    f.openSetting("deliveryChestName");f.ui.handleEvent("paste",tostring(f.number("free-delivery")))
    f.ui.handleEvent("key",keys.escape);assert(not f.ui.edit);Test.equal(textutils.serialize(f.w.files),before)
    f.openSetting("deliveryChestName");f.clickText("CANCEL",true);assert(not f.ui.edit)
    Test.equal(textutils.serialize(f.w.files),before);Test.equal(f.config.deliveryChestName,"current-delivery");f.noHardware()
end)

Test.case("hotplug refresh invalidates a pending numeric index and a detached stale touch choice cannot be saved",function()
    local f=fixture("supply",100,38);local before=textutils.serialize(f.w.files)
    f.openSetting("deliveryChestName");f.ui.handleEvent("paste",tostring(f.number("free-delivery")))
    f.inventory("aaa-new-device");f.ui.handleEvent("peripheral","aaa-new-device")
    f.ui.handleEvent("key",keys.enter)
    Test.equal(f.config.deliveryChestName,"current-delivery");Test.equal(textutils.serialize(f.w.files),before)
    f.ui.handleEvent("key",keys.escape);f.openSetting("deliveryChestName")
    local x,y=f.show("free-delivery");f.w.devices[f.w.id]["free-delivery"]=nil;f.click(x,y)
    assert(f.ui.edit and f.ui.edit.error);Test.equal(f.config.deliveryChestName,"current-delivery")
    Test.equal(textutils.serialize(f.w.files),before);f.noHardware()
end)

Test.case("route peripheral selections edit a draft and revalidate occupied or disconnected devices only when SAVE ROUTE is chosen",function()
    local f=fixture("master",100,38);local before=textutils.serialize(f.w.files)
    f.openRoute(2);f.clickText("Master delivery chest peripheral")
    assert(f.ui.edit.kind=="peripheral");assert(f.ui.edit.deviceOptions.routeId==2)
    assert(not pcall(f.number,"D3") and not pcall(f.number,"R2"),"route picker offered another assigned chest")
    f.show("free-delivery");f.clickText("free-delivery");assert(not f.ui.edit);Test.equal(f.ui.route.deliveryChest,"free-delivery")
    Test.equal(f.config.colonies[1].deliveryChest,"D2");Test.equal(textutils.serialize(f.w.files),before)
    f.w.devices[f.w.id]["free-delivery"]=nil;f.clickText("SAVE ROUTE")
    assert(f.ui.route and f.ui.notice);Test.equal(textutils.serialize(f.w.files),before)
    f.inventory("free-delivery");f.blocked=true;f.ui.draw();f.clickText("SAVE ROUTE")
    assert(f.ui.route and f.ui.notice:find("Retained",1,true));Test.equal(textutils.serialize(f.w.files),before)
    f.blocked=false;f.ui.draw();f.clickText("SAVE ROUTE")
    assert(not f.ui.route);Test.equal(f.config.colonies[1].deliveryChest,"free-delivery")
    Test.equal(Config.load("master").colonies[1].deliveryChest,"free-delivery")
    f.noHardware()
end)

Test.case("route monitor and return inventory pickers exclude owned devices and cancelling discards the whole route draft",function()
    local f=fixture("master",100,38);local before=textutils.serialize(f.w.files)
    f.openRoute(2);f.clickText("Master colony dashboard monitor")
    assert(f.ui.edit.kind=="peripheral");assert(not pcall(f.number,"screen"),"route panel could claim the overview monitor")
    f.select("free-monitor");Test.equal(f.ui.route.monitorName,"free-monitor")
    f.clickText("Master return chest peripheral");assert(f.ui.edit.kind=="peripheral")
    assert(not pcall(f.number,"D2") and not pcall(f.number,"D3"),"return picker admitted an assigned delivery channel")
    f.select("free-return");Test.equal(f.ui.route.returnChest,"free-return")
    Test.equal(textutils.serialize(f.w.files),before);Test.equal(f.config.colonies[1].returnChest,"R2")
    f.clickText("CANCEL",true);assert(not f.ui.route);Test.equal(f.ui.view,"routes")
    Test.equal(textutils.serialize(f.w.files),before);Test.equal(f.config.colonies[1].monitorName,"owned-monitor");f.noHardware()
end)

Test.case("the keyboard terminal renders the monitor's same numbered picker page without scrolling or storage discovery",function()
    local f=fixture("supply",100,38);local name="zz_ender_chest_"..string.rep("x",109).."_END";f.inventory(name)
    f.openSetting("deliveryChestName");f.show("_END")
    local oldPrint=print;local printed=0;_G.print=function() printed=printed+1 end
    local ok,err=pcall(f.terminalRenderer);_G.print=oldPrint;assert(ok,err)
    local terminal=f.w.terminal.dump():gsub("%s","")
    assert(terminal:find("zz_ender_chest_",1,true) and terminal:find("_END",1,true),"keyboard terminal clipped a full peripheral name")
    local choiceNumber=tostring(f.number(name))..")"
    assert(terminal:find(choiceNumber,1,true),"terminal and monitor showed different choice numbers")
    Test.equal(printed,0,"picker terminal output scrolled away instead of rendering a page");f.noHardware()
    local page=f.ui.edit.page;assert(page>1)
    f.ui.handleEvent("char","p");f.terminalRenderer();Test.equal(f.ui.edit.page,page-1)
    assert(not f.w.terminal.dump():find("_END",1,true),"terminal did not follow the monitor's previous page")
    f.ui.handleEvent("char","n");f.terminalRenderer();Test.equal(f.ui.edit.page,page)
    assert(f.w.terminal.dump():find("_END",1,true))
    local message="This delivery is still reserved by a retained turn. Finish the transfer before editing."
    f.engine.canEditHardware=function() return false,message end
    f.select(name);assert(f.ui.edit and f.ui.edit.error==message);f.terminalRenderer()
    assert(f.w.terminal.dump():gsub("%s",""):find(message:gsub("%s",""),1,true),"native picker error was clipped or overwritten by controls")
    assert(f.w.terminal.dump():find("Number + Enter",1,true));f.noHardware()
end)

Test.case("read-only colony panels never discover peripherals create pickers or access persistence when settings are touched",function()
    local f=fixture("supply",100,38,{readOnly=true,displayOnly=true,monitorName="screen",sourceId=2})
    local discovery,opens=0,0;local originalNames=peripheral.getNames;local originalOpen=fs.open
    peripheral.getNames=function() discovery=discovery+1;error("read-only panel discovered hardware") end
    fs.open=function(...) opens=opens+1;return originalOpen(...) end
    local before=textutils.serialize(f.w.files)
    local ok,err=pcall(function()
        f.openSetting("deliveryChestName");assert(not f.ui.edit)
        f.ui.handleEvent("paste","1");f.ui.handleEvent("key",keys.enter)
        f.ui.handleEvent("peripheral","unused-new-device");f.ui.draw()
        Test.equal(textutils.serialize(f.w.files),before);Test.equal(discovery,0);Test.equal(opens,0);f.noHardware()
    end)
    peripheral.getNames=originalNames;fs.open=originalOpen;assert(ok,err)
end)

return true
