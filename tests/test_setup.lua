local S=require("tests.support")
local D=require("tests.display_support")
local Config=require("colony.network.config")
local Store=require("colony.network.store")

local function fixture(answers)
    local w=D.world();local native=w.terminal;local external=D.surface(100,38)
    local active=external
    _G.term={native=function() return native end,current=function() return active end,
        redirect=function(target) local previous=active;active=target;return previous end}
    for key,value in pairs(native) do if type(value)=="function" then
        local method=key
        if not term[method] then term[method]=function(...) return active[method](...) end end
    end end
    local f={w=w,native=native,external=external,frames={},reads=0,config=Config.defaults("master")}
    function f.current() return active end
    _G.read=function()
        f.reads=f.reads+1;assert(f.reads<=100,"setup repeated an unanswered or invalid prompt indefinitely")
        assert(active==native,"setup read from a redirected external display")
        local x,y=native.getCursorPos();assert(x>=1 and x<=51 and y>=1 and y<=19,"setup input cursor is off the built-in computer screen")
        local frame={text=native.dump(),x=x,y=y};f.frames[#f.frames+1]=frame
        if f.beforeRead then f.beforeRead(frame) end
        local value=type(answers)=="function" and answers(f,frame) or answers and answers[f.reads]
        if type(value)=="table" and value.error then error(value.error,0) end
        assert(value~=nil,"scripted setup input exhausted at: "..frame.text)
        return value
    end
    _G.write=function(value) return active.write(value) end
    function f.renderer() return require("colony.network.setup_ui").new(f.config) end
    return f
end

local function hardware(f,role)
    local w=f.w;local id=role=="master" and 1 or 2;w.id=id;w.masterId=1
    local inspected=0
    local function forbidden() inspected=inspected+1;error("setup invoked an inventory list or size instead of inspecting its methods",0) end
    for _,name in ipairs({"delivery-one","return-one","delivery-two","return-two"}) do
        w.device(id,name,"enderchests:ender_chest",{list=forbidden,size=forbidden})
        w.devices[id][name].types.inventory=true;w.devices[id][name].types.custom_inventory=true
    end
    w.device(id,"bad-inventory","inventory",{size=forbidden})
    w.device(id,"unrelated-speaker","speaker",{playNote=forbidden})
    w.device(id,"main-monitor","monitor",f.external)
    w.device(id,"colony-monitor","monitor",D.surface(100,38))
    w.bridge(id,role=="master" and "prs-bridge" or "colony-rs-bridge",role=="master")
    if role=="supply" then w.integrator(id,"colony-integrator") end
    local originalType=peripheral.getType
    peripheral.getType=function(name)
        local device=(w.devices[w.id] or {})[name]
        if device and device.types.custom_inventory then return device.kind,"inventory","custom_inventory" end
        return originalType(name)
    end
    peripheral.getMethods=function(name)
        local device=(w.devices[w.id] or {})[name];if not device then return nil end
        local methods={};for key,value in pairs(device.api) do if type(value)=="function" then methods[#methods+1]=key end end
        table.sort(methods);return methods
    end
    return function() return inspected end
end

local function workflowFixture(role,steps)
    local nextStep=1
    local f=fixture(function(_,frame)
        if frame.text:find("Enter continues",1,true) or frame.text:find("Enter next page",1,true) then return "" end
        local step=assert(steps[nextStep],"unexpected workflow page: "..frame.text)
        assert(frame.text:lower():find(step.label:lower(),1,true),"expected "..step.label.." but received: "..frame.text)
        if step.choice then
            for line in frame.text:gmatch("[^\n]+") do
                local number=line:match("^%s*(%d+)%) ")
                if number and line:find(step.choice,1,true) then nextStep=nextStep+1;return number end
            end
            return "n"
        end
        nextStep=nextStep+1;return step.answer or ""
    end)
    f.config=Config.defaults(role);f.inspected=hardware(f,role)
    function f.done() Test.equal(nextStep,#steps+1,"workflow did not consume the expected questions") end
    return f
end

Test.case("setup asks and validates one visible question on the native 51 by 19 computer",function()
    local f=fixture({"not-a-number","-1","42"});local ui=f.renderer()
    local answer=ui.ask({title="Colony supply setup",label="Master computer ID",required=true,
        help={"Enter the nonnegative ID of the single PRS master computer."},
        validate=function(value) local n=tonumber(value);return n~=nil and n>=0 and n%1==0,"Use a nonnegative integer computer ID" end})
    Test.equal(answer,"42");Test.equal(f.reads,3)
    assert(f.frames[1].text:find("Master computer ID",1,true))
    assert(f.frames[2].text:find("Use a nonnegative integer",1,true))
    assert(f.frames[3].text:find("Use a nonnegative integer",1,true))
    assert(f.native.clears>=3,"invalid input scrolled another question into the existing screen")
    Test.equal(f.external.writes,0);assert(f.external.scale==nil)
    ui.close();assert(f.current()==f.external,"setup did not restore the caller's redirected terminal")
end)

Test.case("wrapped setup validation preserves both error lines above the controls and input",function()
    local f=fixture({string.rep("x",128),"42"});local ui=f.renderer()
    local message="The computer ID must be a nonnegative integer. Enter the ID printed by the id command."
    Test.equal(ui.ask({title="Colony supply setup",label="Master computer ID",required=true,
        validate=function(value) return tonumber(value)~=nil,message end}),"42")
    local visible=f.frames[2].text
    assert(visible:gsub("%s",""):find(message:gsub("%s",""),1,true),"wrapped validation error was overwritten by the page controls")
    assert(visible:find("Enter keeps current",1,true));Test.equal(f.frames[2].y,18);ui.close()
end)

Test.case("required setup retries empty input while an explicit existing value remains visible",function()
    local f=fixture({"","colony-two"});local ui=f.renderer()
    local answer=ui.ask({title="Colony identity",label="Colony label",required=true,help={"Use a short name for this colony."}})
    Test.equal(answer,"colony-two");assert(f.frames[2].text:find("required",1,true))
    ui.close()
    f=fixture({""});ui=f.renderer()
    answer=ui.ask({title="Colony identity",label="Colony label",current="Clockwork",required=true})
    Test.equal(answer,"Clockwork");assert(f.frames[1].text:find("Clockwork",1,true));ui.close()
end)

Test.case("one-page setup text accepts literal colony labels N and P",function()
    for _,label in ipairs({"N","P"}) do
        local f=fixture({label});local ui=f.renderer()
        Test.equal(ui.ask({title="Colony identity",label="Colony label",required=true}),label)
        Test.equal(f.reads,1);ui.close()
    end
end)

Test.case("numbered peripheral selection pages through many devices and preserves exact names",function()
    local choices={};for i=1,30 do choices[i]={label="peripheral-choice-"..string.format("%03d",i),value="peripheral-value-"..i,detail="enderchests:ender_chest / inventory"} end
    local f=fixture(function(_,frame)
        if frame.text:find("peripheral-choice-021",1,true) then return "21" end
        return "n"
    end)
    local ui=f.renderer();local value=ui.choose({title="Delivery inventory",label="Choose the Ender Chest",required=true,
        help={"Each entry shows its network name and every exposed peripheral type."},choices=choices})
    Test.equal(value,"peripheral-value-21");assert(f.reads>1,"thirty peripheral names were packed into one screen")
    Test.equal(f.external.writes,0);ui.close()
end)

Test.case("setup never retains a disconnected current device in place of the connected choice",function()
    local f=fixture({""});local ui=f.renderer()
    local selected=ui.choose({title="Player storage",label="Choose the PRS Bridge",current="removed-prs",required=true,
        choices={{label="connected-prs",value="connected-prs"}}})
    Test.equal(selected,"connected-prs");assert(f.frames[1].text:find("unavailable",1,true));ui.close()
end)

Test.case("setup wraps full 128-character peripheral names and keeps the choice prompt on screen",function()
    local name="ender_chest_"..string.rep("x",112).."_END"
    Test.equal(#name,128)
    local f=fixture({"1"});local ui=f.renderer()
    Test.equal(ui.choose({title="Return inventory",label="Choose overflow Ender Chest",required=true,
        choices={{label=name,value=name,detail="enderchests:ender_chest / inventory / custom_inventory"}}}),name)
    local compact=f.frames[1].text:gsub("%s","")
    assert(compact:find("ender_chest_",1,true) and compact:find("_END",1,true),"peripheral name was silently clipped")
    assert(f.frames[1].text:find("custom_inventory",1,true),"multiple peripheral types were clipped")
    ui.close()
end)

Test.case("setup notices paginate long instructions on the native computer and acknowledge each page",function()
    local f=fixture(function() return "" end);local ui=f.renderer();local lines={}
    for i=1,40 do lines[i]="Instruction "..i..": wire this computer to the designated inventory network." end
    ui.notice({title="Hardware instructions",lines=lines})
    assert(f.reads>1,"long instructions overflowed instead of paging")
    local seen={};for _,frame in ipairs(f.frames) do for id in frame.text:gmatch("Instruction (%d+):") do seen[tonumber(id)]=true end end
    for i=1,40 do assert(seen[i],"setup omitted instruction "..i) end
    ui.close();Test.equal(f.external.writes,0)
end)

Test.case("numbered setup menus reject invalid selections on the same question before selecting hardware",function()
    local f=fixture({"0","3","junk","2"});local ui=f.renderer()
    local answer=ui.choose({title="Required PRS bridge",label="Choose PRS bridge",required=true,
        choices={{label="prs-left",value="prs-left"},{label="prs-right",value="prs-right"}}})
    Test.equal(answer,"prs-right");Test.equal(f.reads,4)
    for i=2,4 do
        assert(f.frames[i].text:find("Choose PRS bridge",1,true))
        assert(f.frames[i].text:find("Enter a listed number",1,true),"invalid choice lost its visible validation error")
    end
    Test.equal(f.external.writes,0);ui.close()
end)

Test.case("setup cancellation and terminated input restore native redirection without peripheral actions",function()
    for _,input in ipairs({":q",{error="Terminated"}}) do
        local f=fixture({input});local ui=f.renderer();local before=textutils.serialize(f.config)
        local ok,err=pcall(ui.ask,{title="Master setup",label="Colony computer ID"})
        assert(not ok and (tostring(err):find("cancelled",1,true) or tostring(err):find("Terminated",1,true)))
        assert(f.current()==f.external,"cancelled read left input redirected to the native terminal")
        ui.close();Test.equal(textutils.serialize(f.config),before);Test.equal(#f.w.calls,0)
    end
end)

Test.case("actual runtime refuses retained hardware setup before creating pages or altering either journal slot",function()
    for _,role in ipairs({"master","supply"}) do
        local f=fixture(function() error("retained setup must never ask for input") end)
        f.config=Config.defaults(role);f.config.monitorName="retained-monitor";f.config.maxTransferChunk=7
        Config.save(f.config)
        local store=Store.new("/colony/"..role.."_v4_state",f.config)
        if role=="master" then
            store.data.master={pendingTransfer={kind="export",count=4},craftJobs={stone={state="timed out"}}}
        else store.data.client={intent={kind="import",count=4},turn={phase="processing"}} end
        store.save();store.save()
        local before=textutils.serialize(f.w.files);local ui=require("colony.network.setup_ui");local originalNew=ui.new
        local created=0;ui.new=function() created=created+1;error("unsafe setup renderer initialization") end
        local ok,err=pcall(require("colony.network.runtime").run,role,"setup");ui.new=originalNew
        assert(not ok and tostring(err):find("retained",1,true),"runtime did not explain why retained transfer hardware is protected")
        Test.equal(created,0);Test.equal(f.reads,0);Test.equal(f.native.clears,0)
        Test.equal(textutils.serialize(f.w.files),before);Test.equal(#f.w.calls,0)
    end
end)

local function monitorStep(role)
    return {label=role=="master" and "master overview monitor" or "this colony's monitor",choice="main-monitor"}
end
local function routeSteps(steps,id,label,suffix,monitor)
    local function add(step) steps[#steps+1]=step end
    add({label="Colony computer ID",answer=tostring(id)})
    add({label="Colony label",answer=label or ""})
    add({label="Choose the chest TO",choice="delivery-"..suffix})
    add({label="Choose the chest FROM",choice="return-"..suffix})
    add({label="Delivery colors",answer=""})
    add({label="Return colors",answer=""})
    add(monitor and {label="Master dashboard",choice=monitor} or {label="Master dashboard",answer="0"})
end
local function supplySteps(save)
    return {monitorStep("supply"),{label="Master computer ID",answer="2"},
        {label="Master computer ID",answer="-1"},{label="Master computer ID",answer="1"},
        {label="Colony Integrator",choice="colony-integrator"},{label="Colony RS Bridge",choice="colony-rs-bridge"},
        {label="Choose the chest TO",choice="delivery-one"},{label="Choose the chest FROM",choice="return-one"},
        {label="Delivery colors",answer="red-pink-white"},{label="Return colors",answer="red-pink-black"},
        {label="Save these settings?",answer=save or "yes"}}
end
local function protectDraft(f)
    local beforeConfig=textutils.serialize(f.config);local beforeFiles=textutils.serialize(f.w.files)
    f.beforeRead=function()
        Test.equal(textutils.serialize(f.config),beforeConfig,"setup mutated live configuration before saving")
        Test.equal(textutils.serialize(f.w.files),beforeFiles,"setup wrote files before final confirmation")
    end
end
local function noHardware(f)
    Test.equal(f.inspected(),0);Test.equal(#f.w.calls,0,"setup accessed a bridge")
    Test.equal(f.external.writes,0);assert(f.external.scale==nil);assert(f.current()==f.external)
    for _,frame in ipairs(f.frames) do
        assert(not frame.text:find("bad-inventory",1,true),"inventory lacking list/size was offered")
        assert(not frame.text:find("unrelated-speaker",1,true),"unrelated peripheral was offered")
    end
end

Test.case("master setup uses numbered mod inventories, pauses automation and saves two separate colony color routes",function()
    local steps={monitorStep("master"),{label="PRS Bridge",choice="prs-bridge"}}
    routeSteps(steps,7,nil,"one","colony-monitor");routeSteps(steps,8,nil,"two")
    steps[#steps+1]={label="Colony computer ID",answer=""};steps[#steps+1]={label="Save these settings?",answer="yes"}
    local f=workflowFixture("master",steps);f.config.maxTransferChunk=7;f.config.craftingTimeoutSeconds=900
    protectDraft(f);assert(require("colony.network.setup").run(f.config));f.done();noHardware(f)
    local saved=Config.load("master");Test.equal(saved.automationEnabled,false);Test.equal(saved.playerBridgeName,"prs-bridge")
    Test.equal(saved.monitorName,"main-monitor");Test.equal(saved.maxTransferChunk,7);Test.equal(saved.craftingTimeoutSeconds,900)
    Test.equal(#saved.colonies,2)
    local first,second=saved.colonies[1],saved.colonies[2]
    Test.equal(first.id,7);Test.equal(first.label,"Clockwork");Test.equal(first.deliveryChest,"delivery-one")
    Test.equal(first.returnChest,"return-one");Test.equal(first.deliveryChannel,"red-blue-white")
    Test.equal(first.returnChannel,"red-blue-black");Test.equal(first.monitorName,"colony-monitor")
    Test.equal(second.id,8);Test.equal(second.label,"Stardust");Test.equal(second.deliveryChest,"delivery-two")
    Test.equal(second.returnChest,"return-two");Test.equal(second.deliveryChannel,"red-pink-white")
    Test.equal(second.returnChannel,"red-pink-black");Test.equal(second.monitorName,"")
    local allFrames={};for _,frame in ipairs(f.frames) do allFrames[#allFrames+1]=frame.text end
    local visible=table.concat(allFrames,"\n")
    assert(visible:find("custom_inventory",1,true),"mod peripheral type details were omitted")
    assert(visible:find("red-blue-white",1,true) and visible:find("red-pink-white",1,true),"suggested physical dyes were not displayed")
end)

Test.case("actual supply setup validates the other computer ID and maps integrator local bridge and both chests without storage calls",function()
    local f=workflowFixture("supply",supplySteps());f.config.maxImportsPerTurn=17;f.config.autoCraftEnabled=false
    Config.save(f.config)
    protectDraft(f);f.w.at(2,require("colony.network.runtime").run,"supply","setup");f.done();noHardware(f)
    local saved=Config.load("supply");Test.equal(saved.masterId,1);Test.equal(saved.colonyIntegratorName,"colony-integrator")
    Test.equal(saved.colonyBridgeName,"colony-rs-bridge");Test.equal(saved.deliveryChestName,"delivery-one")
    Test.equal(saved.returnChestName,"return-one");Test.equal(saved.deliveryChannel,"red-pink-white")
    Test.equal(saved.returnChannel,"red-pink-black");Test.equal(saved.monitorName,"main-monitor")
    Test.equal(saved.autoCraftEnabled,false);Test.equal(saved.maxImportsPerTurn,17)
    local sawSelf,sawRange=false,false
    for _,frame in ipairs(f.frames) do
        sawSelf=sawSelf or frame.text:find("other computer's ID",1,true)~=nil
        sawRange=sawRange or frame.text:find("0 to 2147483647",1,true)~=nil
        if frame.text:find("Choose the chest FROM",1,true) then
            assert(not frame.text:find("delivery-one",1,true),"delivery inventory could also be selected for returns")
        end
    end
    assert(sawSelf and sawRange,"computer ID errors were not visible on the same question")
end)

Test.case("editing an existing master colony replaces its route while preserving policy overrides directions and the other colony",function()
    local steps={monitorStep("master"),{label="PRS Bridge",choice="prs-bridge"}}
    routeSteps(steps,7,"Clockwork revised","one","colony-monitor")
    steps[#steps+1]={label="Colony computer ID",answer=""};steps[#steps+1]={label="Save these settings?",answer="yes"}
    local f=workflowFixture("master",steps)
    f.config.playerBridgeName="prs-bridge";f.config.monitorName="main-monitor";f.config.pollIntervalSeconds=2
    f.config.colonies={{id=7,label="Clockwork",deliveryChest="delivery-one",returnChest="return-one",
        deliveryChannel="red-blue-white",returnChannel="red-blue-black",monitorName="colony-monitor",
        outputDirection="west",returnDirection="east",overrides={autoCraftEnabled=false,maxItemsPerTurn=7}},
        {id=8,deliveryChest="delivery-two",returnChest="return-two",deliveryChannel="red-pink-white",returnChannel="red-pink-black"}}
    Config.save(f.config);local other=textutils.serialize(f.config.colonies[2]);protectDraft(f)
    assert(require("colony.network.setup").run(f.config));f.done();noHardware(f)
    local saved=Config.load("master");Test.equal(#saved.colonies,2);Test.equal(saved.colonies[1].label,"Clockwork revised")
    Test.equal(saved.colonies[1].outputDirection,"west");Test.equal(saved.colonies[1].returnDirection,"east")
    Test.equal(saved.colonies[1].overrides.autoCraftEnabled,false);Test.equal(saved.colonies[1].overrides.maxItemsPerTurn,7)
    Test.equal(saved.pollIntervalSeconds,2);Test.equal(textutils.serialize(saved.colonies[2]),other)
end)

Test.case("setup cancel and final no discard hardware drafts and preserve persisted configuration and both journal slots",function()
    local variants={{role="master",steps={monitorStep("master"),{label="PRS Bridge",choice="prs-bridge"},{label="Colony computer ID",answer=":q"}}},
        {role="supply",steps=supplySteps("no")}}
    for _,variant in ipairs(variants) do
        local f=workflowFixture(variant.role,variant.steps);f.config.maxTransferChunk=7;Config.save(f.config)
        local store=Store.new("/colony/"..variant.role.."_v4_state",f.config);store.data.history={{kind="INFO",message="Prior setup"}}
        store.save();store.save();local before=textutils.serialize(f.w.files);local original=textutils.serialize(f.config)
        protectDraft(f);Test.equal(require("colony.network.setup").run(f.config),false);f.done();noHardware(f)
        Test.equal(textutils.serialize(f.config),original);Test.equal(textutils.serialize(f.w.files),before)
    end
end)

Test.case("failed final setup save leaves live configuration and persisted transfer journals intact",function()
    local f=workflowFixture("supply",supplySteps());Config.save(f.config)
    local store=Store.new("/colony/supply_v4_state",f.config);store.save();store.save()
    local before=textutils.serialize(f.w.files);local original=textutils.serialize(f.config);protectDraft(f)
    f.w.writeFail=true
    local ok,err=pcall(require("colony.network.setup").run,f.config)
    assert(not ok and tostring(err):find("Cannot write network configuration",1,true));f.done();noHardware(f)
    Test.equal(textutils.serialize(f.config),original);Test.equal(textutils.serialize(f.w.files),before)
end)

return true
