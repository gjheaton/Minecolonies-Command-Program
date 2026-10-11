local S=require("tests.support")
local D=require("tests.display_support")
local Config=require("colony.network.config")
local Store=require("colony.network.store")
local IO=require("colony.network.io")
local Protocol=require("colony.network.protocol")
local Runtime=require("colony.network.runtime")
local Master=require("colony.network.master")
local Client=require("colony.network.client")
local Diagnostics=require("colony.network.diagnostics")

local function encode(value) return textutils.serialize(value,{compact=true,allow_repetitions=true}) end
local function patched(changes,fn)
    local original={}
    for index,change in ipairs(changes) do original[index]=change[1][change[2]];change[1][change[2]]=change[3] end
    local ok,err=pcall(fn)
    for index=#changes,1,-1 do changes[index][1][changes[index][2]]=original[index] end
    assert(ok,err)
end
local function unexpected(label) return function() error("Unexpected "..label,0) end end
local function quiet() return {_G,"print",function() end} end
local function fixture(role,state)
    local w=D.world();local config=Config.defaults(role)
    config.playerBridgeName="prs";config.colonyBridgeName="crs";config.colonyIntegratorName="integrator"
    config.masterId=1;config.deliveryChestName="delivery";config.returnChestName="returns"
    Config.save(config)
    local store=Store.new("/colony/"..role.."_v4_state",config)
    for key,value in pairs(state or {}) do store.data[key]=S.copy(value) end
    assert(store.save())
    function w.run(...) return Runtime.run(role,...) end
    function w.loaded() local loaded=Store.new(store.path,Config.load(role));loaded.load();return loaded.data end
    return w,config,store
end

Test.case("runtime source help and invalid options work without a module loader or ComputerCraft globals",function()
    for _,role in ipairs({"master","supply"}) do
        local lines={}
        -- Supply only the Lua primitives used by argument parsing and output.
        -- There is no require, fs, colors, peripheral, engine or package cache.
        local environment={type=type,select=select,error=error,tonumber=tonumber,table={concat=table.concat},
            print=function(message) lines[#lines+1]=tostring(message) end}
        local isolated=assert(loadfile(TEST_ROOT.."/colony/network/runtime.lua","t",environment))()
        isolated.run(role,"--help")
        Test.equal(#lines,1);assert(lines[1]:find("Usage: colony_"..role,1,true))
        assert(lines[1]:find("--clear-errors",1,true))
        for _,args in ipairs({{"--unknown"},{"--help","extra"},{"-diag"}}) do
            local ok,err=pcall(isolated.run,role,table.unpack(args))
            assert(not ok and tostring(err):find("Usage: colony_"..role,1,true),tostring(err))
        end
        Test.equal(#lines,1,"invalid options printed or entered normal startup")
        assert(environment.require==nil and environment.fs==nil and environment.colors==nil)
    end
end)

Test.case("prefixed help lists role options before any configuration journal hardware or engine access",function()
    for _,role in ipairs({"master","supply"}) do
        S.world();local lines={}
        patched({
            {Config,"load",unexpected("help configuration load")},
            {Store,"new",unexpected("help journal construction")},
            {IO,"new",unexpected("help peripheral construction")},
            {Protocol,"open",unexpected("help modem opening")},
            {Master,"new",unexpected("help master construction")},
            {Client,"new",unexpected("help colony construction")},
            {_G,"print",function(message) lines[#lines+1]=tostring(message) end},
        },function() Runtime.run(role,"--help") end)
        local output=table.concat(lines,"\n")
        for _,option in ipairs({"--setup","--diag","--monitors","--set","--reconcile","--clear-errors"}) do
            assert(output:find(option,1,true),"help omitted "..option)
        end
        assert(output:find(role=="master" and "--reconcile-bind" or "--reconcile-zero",1,true))
    end
end)

Test.case("invalid prefixed modes roles and arities fail before configuration recovery or hardware startup",function()
    S.world()
    patched({
        {Config,"load",unexpected("invalid option configuration load")},
        {Store,"new",unexpected("invalid option journal construction")},
        {IO,"new",unexpected("invalid option peripheral construction")},
        {Protocol,"open",unexpected("invalid option modem opening")},
        {Master,"new",unexpected("invalid option master construction")},
        {Client,"new",unexpected("invalid option colony construction")},quiet(),
    },function()
        for _,args in ipairs({
            {"master","--unknown"},{"supply","--unknown"},{"master","-diag"},{"master","----diag"},
            {"master","--help","extra"},{"master","--setup","extra"},{"master","--diag","extra"},
            {"supply","--monitors","extra"},{"master","--clear-errors","extra"},{"supply","--reconcile","extra"},
            {"supply","--transferdiag"},{"supply","--monitor","4","screen"},{"supply","--reconcile-bind","4"},
            {"master","--reconcile-zero","shipment-27"},{"supply","--chesttest","4"},
            {"master","--set","autoCraftEnabled"},{"master","--set","autoCraftEnabled","true","extra"},
            {"master","--monitor","4"},{"master","--reconcile-bind"},{"supply","--reconcile-zero"},
            {"master","--chesttest"},{"master","--chesttest","--abandon"},
            {"master","--chesttest","--abandon","4","extra"},
        }) do
            local ok,err=pcall(Runtime.run,table.unpack(args))
            assert(not ok and tostring(err):find("Usage:",1,true),"invalid option reached startup: "..table.concat(args," ").." => "..tostring(err))
        end
    end)
end)

Test.case("prefixed setup preserves retained turn shipment craft chest test and colony import safeguards",function()
    for _,entry in ipairs({
        {role="master",state={master={colonies={["4"]={turn={phase="WAIT_BATCH"}}}}}},
        {role="master",state={master={colonies={["4"]={shipments={{count=1,imported=0}}}}}}},
        {role="master",state={master={craftJobs={rice={state="crafting"}}}}},
        {role="master",state={chestTest={phase="export_intent"}}},
        {role="supply",state={client={intent={kind="import",count=1}}}},
    }) do
        local w=fixture(entry.role,entry.state);local files=encode(w.files)
        patched({{_G,"read",unexpected("retained setup prompt")},{IO,"new",unexpected("retained setup hardware")},quiet()},function()
            local ok,err=pcall(w.run,"--setup")
            assert(not ok and tostring(err):find("retained turns",1,true))
        end)
        Test.equal(encode(w.files),files);Test.equal(#w.calls,0);Test.equal(#w.sent,0)
    end
end)

Test.case("prefixed typed settings change policy while retained transfers still prevent hardware changes",function()
    for _,role in ipairs({"master","supply"}) do
        local state=role=="master" and {master={pendingTransfer={kind="export",count=1}}} or {client={intent={kind="import",count=1}}}
        local w,config,store=fixture(role,state);local journal=encode(w.loaded())
        patched({{Protocol,"open",unexpected("settings modem opening")},{Master,"new",unexpected("settings engine")},{Client,"new",unexpected("settings engine")},quiet()},function()
            local key=role=="master" and "playerBridgeName" or "masterId"
            local ok,err=pcall(w.run,"--set",key,role=="master" and "replacement" or "9")
            assert(not ok and tostring(err):find("Retained work prevents",1,true))
            w.run("--set","craftingTimeoutSeconds","901")
            w.run("--set","autoCraftEnabled","false")
            w.run("--set","monitorName","--screen_alias")
            Test.equal(Config.load(role).monitorName,"--screen_alias","value was parsed as another option")
            w.run("--set","monitorName","")
            Test.equal(Config.load(role).monitorName,"","empty string setting was rejected")
            local before=w.files[Config.PATH]
            assert(not pcall(w.run,"--set","autoCraftEnabled","yes"))
            Test.equal(w.files[Config.PATH],before)
        end)
        local updated=Config.load(role)
        Test.equal(updated.craftingTimeoutSeconds,901);Test.equal(updated.autoCraftEnabled,false)
        Test.equal(updated.playerBridgeName,config.playerBridgeName);Test.equal(updated.masterId,config.masterId)
        Test.equal(encode(w.loaded()),journal);Test.equal(#w.calls,0);Test.equal(#w.sent,0)
    end
end)

Test.case("prefixed clear-errors durably removes recorded errors without clearing active transfer faults or ledgers",function()
    for _,role in ipairs({"master","supply"}) do
        local held={master={pendingTransfer={kind="export",count=1},quarantine={code="TRANSFER_VERIFY"},
            colonies={["4"]={shipments={{id="shipment-27",count=1,imported=0}}}}},
            client={intent={kind="import",shipmentId="shipment-27"},fault={code="IMPORT_UNCERTAIN"},
                shipments={["shipment-27"]={count=1,imported=0}}},chestTest={phase="inspect"}}
        local w,config,store=fixture(role,held)
        store.error("IMPORT_UNCERTAIN","Old recorded failure")
        local configText=w.files[Config.PATH]
        patched({{IO,"new",unexpected("clear-errors hardware")},{Protocol,"open",unexpected("clear-errors modem")},
            {Master,"new",unexpected("clear-errors engine")},{Client,"new",unexpected("clear-errors engine")},quiet()},function()
            w.run("--clear-errors")
        end)
        local loaded=w.loaded();Test.equal(#loaded.errors,0)
        for key,value in pairs(held) do Test.equal(encode(loaded[key]),encode(value),"archive clear changed live "..key) end
        Test.equal(loaded.history[#loaded.history].kind,"ERROR_HISTORY_CLEARED")
        Test.equal(w.files[Config.PATH],configText);Test.equal(#w.calls,0);Test.equal(#w.sent,0)
    end
end)

Test.case("prefixed diagnostics and monitor listings inspect peripherals without journal writes or transfers",function()
    for _,role in ipairs({"master","supply"}) do
        local w,config=fixture(role)
        w.bridge(1,role=="master" and "prs" or "crs",role=="master")
        if role=="supply" then w.integrator(1,"integrator");w.chest(1,"delivery","delivery");w.chest(1,"returns","returns") end
        w.monitor(1,"screen",100,38)
        local files=encode(w.files)
        patched({{Protocol,"open",unexpected("diagnostic modem")},{Master,"new",unexpected("diagnostic engine")},
            {Client,"new",unexpected("diagnostic engine")},quiet()},function()
            w.run("--diag");w.run("--diagnostics");w.run("--monitors")
            if role=="master" then w.run("--transferdiag") end
        end)
        Test.equal(encode(w.files),files);Test.equal(#w.callsFor("export"),0)
        Test.equal(#w.callsFor("import"),0);Test.equal(#w.callsFor("craft"),0);Test.equal(#w.sent,0)
    end
end)

Test.case("prefixed static recoveries and legacy aliases pass the original IDs to the same guarded preview",function()
    for _,role in ipairs({"master","supply"}) do
        local w=fixture(role);local files=encode(w.files);local previews={}
        local recovery=function()
            return role=="master" and {previewBindExport=function(id) previews[#previews+1]=id;return false,"Held transfer is not eligible" end}
                or {previewZeroImport=function(id) previews[#previews+1]=id;return nil,"Held transfer is not eligible" end}
        end
        local module=role=="master" and Master or Client
        local method=role=="master" and "legacyExportRecovery" or "zeroImportRecovery"
        local mode=role=="master" and "reconcile-bind" or "reconcile-zero"
        local id=role=="master" and "4" or "shipment-27"
        patched({{module,method,recovery},{Master,"new",unexpected("static recovery master")},
            {Client,"new",unexpected("static recovery colony")},{Protocol,"open",unexpected("static recovery modem")},
            {_G,"read",unexpected("ineligible recovery confirmation")},quiet()},function()
            w.run("--"..mode,id);w.run(mode,id)
        end)
        Test.equal(#previews,2);Test.equal(previews[1],id);Test.equal(previews[2],id)
        Test.equal(encode(w.files),files);Test.equal(#w.calls,0);Test.equal(#w.sent,0)
    end
end)

Test.case("prefixed reconcile and its legacy alias preserve the engine's guarded recovery result",function()
    for _,role in ipairs({"master","supply"}) do
        local w=fixture(role);local files=encode(w.files);local constructions,reconciliations,opens=0,0,0
        local module=role=="master" and Master or Client
        patched({{module,"new",function()
            constructions=constructions+1
            return {reconcile=function() reconciliations=reconciliations+1;return false,"Transfer still needs reconciliation" end}
        end},{Protocol,"open",function() opens=opens+1;return true end},quiet()},function()
            w.run("--reconcile");w.run("reconcile")
        end)
        Test.equal(constructions,2);Test.equal(reconciliations,2);Test.equal(opens,2)
        Test.equal(encode(w.files),files);Test.equal(#w.calls,0);Test.equal(#w.sent,0)
    end
end)

Test.case("prefixed chest tests keep colony IDs and item values intact and accept canonical nested abandon",function()
    local w=fixture("master");local files=encode(w.files);local invocations={}
    patched({{Protocol,"open",function() return true end},
        {Diagnostics,"runMaster",function(config,store,io,matcher,id,item,abandon)
            invocations[#invocations+1]={id=id,item=item,abandon=abandon}
        end},{Master,"new",unexpected("chest test engine")},quiet()},function()
        w.run("--chesttest","4","minecolonies:rice")
        w.run("--chesttest","--abandon","4")
        w.run("chesttest","abandon","4")
    end)
    Test.equal(#invocations,3);Test.equal(invocations[1].id,4)
    Test.equal(invocations[1].item,"minecolonies:rice");Test.equal(invocations[1].abandon,false)
    for index=2,3 do Test.equal(invocations[index].id,4);Test.equal(invocations[index].item,nil);Test.equal(invocations[index].abandon,true) end
    Test.equal(encode(w.files),files);Test.equal(#w.calls,0);Test.equal(#w.sent,0)
end)

Test.case("prefixed monitor assignment retains active transfers and treats none as a value",function()
    local w,config=fixture("master",{master={pendingTransfer={kind="export",count=1}}})
    config.colonies={D.route(4,"screen")};Config.save(config)
    local journal=encode(w.loaded())
    patched({{Protocol,"open",unexpected("monitor assignment modem")},{Master,"new",unexpected("monitor assignment engine")},quiet()},function()
        w.run("--monitor","4","replacement_screen")
        Test.equal(Config.load("master").colonies[1].monitorName,"replacement_screen")
        w.run("--monitor","4","none")
    end)
    Test.equal(Config.load("master").colonies[1].monitorName,"")
    Test.equal(encode(w.loaded()),journal);Test.equal(#w.calls,0);Test.equal(#w.sent,0)
end)

Test.case("zero-return CLI previews without starting an engine and cancels without releasing a hold",function()
    local w=fixture("supply");local files=encode(w.files);local acknowledged=0
    patched({{Client,"zeroReturnRecovery",function() return {
        previewZeroReturn=function() return {item={name="minecraft:cherry_sapling"},count=53,chest="returns",
            beforeChest=0,currentChest=0,confirmation="ZERO"} end,
        reconcileZeroReturn=function() acknowledged=acknowledged+1;return true,"Acknowledged" end} end},
        {Client,"new",unexpected("zero return engine")},{Protocol,"open",unexpected("zero return modem")},
        {_G,"read",function() return "cancel" end},quiet()},function() w.run("--reconcile-zero-return") end)
    Test.equal(acknowledged,0);Test.equal(encode(w.files),files);Test.equal(#w.calls,0)
end)

Test.case("zero-return CLI passes the exact preview confirmation to recovery without engine startup",function()
    local w=fixture("supply");local received
    local answer="ZERO"
    patched({{Client,"zeroReturnRecovery",function() return {
        previewZeroReturn=function() return {item={name="minecraft:cherry_sapling"},count=53,chest="returns",
            beforeChest=0,currentChest=0,confirmation=answer} end,
        reconcileZeroReturn=function(value) received=value;return true,"Acknowledged" end} end},
        {Client,"new",unexpected("zero return engine")},{Protocol,"open",unexpected("zero return modem")},
        {_G,"read",function() return answer end},quiet()},function() w.run("--reconcile-zero-return") end)
    Test.equal(received,answer);Test.equal(#w.calls,0)
end)

Test.case("deliverydiag inspects the selected shipment without constructing an engine or granting chest access",function()
    local w=fixture("supply");local files=encode(w.files);local seen
    patched({{Diagnostics,"printDelivery",function(config,io,store,id) seen=id end},
        {Client,"new",unexpected("delivery diagnostic engine")},{Protocol,"open",unexpected("delivery diagnostic modem")},quiet()},
        function() w.run("--deliverydiag","shipment-183") end)
    Test.equal(seen,"shipment-183");Test.equal(encode(w.files),files);Test.equal(#w.calls,0)
    patched({quiet()},function()
        for _,args in ipairs({{"--deliverydiag"},{"--deliverydiag","shipment-183","extra"}}) do
            local ok=pcall(w.run,table.unpack(args));assert(not ok)
        end
        local master=fixture("master");assert(not pcall(master.run,"--deliverydiag","shipment-183"))
    end)
end)
