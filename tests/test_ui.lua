local S=require("tests.support")
local Config=require("colony.network.config")

local function surface(width,height)
    local self={width=width,height=height,lines={},writes=0,clears=0}
    local x,y=1,1
    function self.getSize() if self.failed then error("detached monitor") end; return self.width,self.height end
    function self.setTextColor() end
    function self.setBackgroundColor() end
    function self.isColor() return true end
    function self.setTextScale(value) self.scale=value end
    function self.setCursorPos(a,b)
        assert(a>=1 and a<=self.width and b>=1 and b<=self.height,"draw outside surface")
        x,y=a,b
    end
    function self.write(text)
        assert(#text<=self.width-x+1,"text exceeds surface")
        local previous=self.lines[y] or string.rep(" ",self.width)
        self.lines[y]=previous:sub(1,x-1)..text..previous:sub(x+#text)
        self.writes=self.writes+1
    end
    function self.clear() self.lines={};self.clears=self.clears+1 end
    function self.dump() local lines={};for i=1,self.height do lines[#lines+1]=self.lines[i] or "" end;return table.concat(lines,"\n") end
    return self
end

local function fixture(role,hasMonitor,width,height,options)
    local w=S.world()
    _G.colors={white=1,orange=2,magenta=4,lightBlue=8,yellow=16,lime=32,pink=64,gray=128,
        lightGray=256,cyan=512,purple=1024,blue=2048,brown=4096,green=8192,red=16384,black=32768}
    _G.keys={enter=28,numPadEnter=156,escape=1,backspace=14,delete=211}
    local terminal=surface(51,19);_G.term=terminal;term.current=function() return terminal end
    local monitor=surface(width or 80,height or 24)
    local config=Config.defaults(role or "master")
    local state={role=role or "master",health={{label="PRS",ok=true,detail="Connected"}},requests={},colonies={}}
    local store={data={history={},errors={}},failures=0,error=function() end}
    store.error=function() store.failures=store.failures+1 end
    local engine={snapshot=function() return state end,busy=function() return state.busy==true end}
    local io={monitor=function() if hasMonitor~=false then return monitor,"top" end end}
    local updater={checks=0,installs=0}
    updater.check=function() updater.checks=updater.checks+1;updater.checkQueued=true;return true end
    updater.install=function() updater.installs=updater.installs+1;return true end
    local ui=require("colony.network.ui").new(config,store,engine,io,updater,options)
    local f={w=w,ui=ui,config=config,state=state,engine=engine,store=store,monitor=monitor,terminal=terminal,updater=updater}
    f.screen=hasMonitor==false and terminal or monitor
    f.terminalRenderer=ui.renderTerminal
    -- Most cases inspect the monitor directly. Avoid printing keyboard prompts
    -- to the test host; the terminal renderer is exercised separately below.
    ui.renderTerminal=function() end
    function f.touch(x,y)
        return hasMonitor==false and ui.handleEvent("mouse_click",1,x,y) or ui.handleEvent("monitor_touch","top",x,y)
    end
    function f.click(label)
        for y=1,f.screen.height do
            local x=(f.screen.lines[y] or ""):find(label,1,true)
            if x then return f.touch(x,y) end
        end
        error("visible control missing: "..label.."\n"..f.screen.dump())
    end
    function f.selectSetting(key)
        local schemas=Config.fields(config.role)
        local rows=f.screen.height-((options and options.readOnly) and 9 or 10)
        for index,schema in ipairs(schemas) do
            if schema.key==key then
                ui.view="settings";ui.pages.settings=math.floor((index-1)/rows)+1;ui.draw()
                f.touch(2,5+(index-1)%rows);return
            end
        end
        error("setting not exposed: "..key)
    end
    function f.type(value)
        ui.handleEvent("paste",tostring(value));ui.handleEvent("key",keys.enter)
    end
    return f
end

Test.case("shared supply UI renders every existing tab and preserves verified quantities",function()
    local f=fixture()
    f.state.requests={{id="R",name="minecraft:stone",status="in progress",requested=6,shipped=4,imported=2}}
    for _,view in ipairs({"home","health","recovery","requests","history","errors","settings","routes"}) do
        f.ui.view=view;f.ui.draw()
        assert(f.monitor.dump():find("CHECK UPDATE",1,true),"upper-right update control absent")
        assert(f.monitor.dump():find("RUNNING",1,true),"master automation toggle absent from "..view)
    end
    f.ui.view="routes";f.ui.draw();f.click("ADD COLONY ROUTE")
    assert(f.monitor.dump():find("RUNNING",1,true),"master automation toggle absent from route editor")
    f.click("PER COLONY POLICY OVERRIDES")
    assert(f.monitor.dump():find("RUNNING",1,true),"master automation toggle absent from overrides editor")
    f.ui.view="requests";f.ui.draw()
    local text=f.monitor.dump()
    assert(text:find("6 / 4 / 2",1,true) and text:find("IN PROGRESS",1,true))
    assert(text:find("completion requires MineColonies",1,true))
    Test.equal(f.store.failures,0,"protected drawing swallowed a rendering failure")
end)

Test.case("master header automation toggle persists, resumes, and rolls back failed saves",function()
    local f=fixture("master")
    f.ui.view="history";f.ui.draw();f.click("RUNNING")
    Test.equal(f.config.automationEnabled,false)
    Test.equal(Config.load("master").automationEnabled,false)
    assert(f.monitor.dump():find("PAUSED",1,true),"paused state not displayed in the header")
    f.ui.view="errors";f.ui.draw();f.click("PAUSED")
    Test.equal(f.config.automationEnabled,true)
    Test.equal(Config.load("master").automationEnabled,true)
    f.w.writeFail=true;f.ui.view="requests";f.ui.draw();f.click("RUNNING")
    Test.equal(f.config.automationEnabled,true,"failed save changed live automation state")
    Test.equal(Config.load("master").automationEnabled,true,"failed save changed persisted automation state")
    assert(f.monitor.dump():find("RUNNING",1,true),"failed save displayed an unsaved paused state")
    Test.equal(f.store.failures,1,"failed header save was not recorded")
end)

Test.case("colony and read-only dashboards do not expose the master automation toggle",function()
    local supply=fixture("supply");supply.ui.draw()
    assert(not supply.monitor.dump():find("RUNNING",1,true) and not supply.monitor.dump():find("PAUSED",1,true))
    local remote=fixture("supply",true,80,24,{readOnly=true});remote.ui.draw()
    local text=remote.monitor.dump()
    assert(text:find("READ ONLY",1,true))
    assert(not text:find("RUNNING",1,true) and not text:find("PAUSED",1,true))
end)

Test.case("UI editor validates values and persists scalar settings without blocking read",function()
    local f=fixture()
    f.w.device(1,"prs-new","rsBridge",{})
    f.selectSetting("playerBridgeName");assert(f.ui.edit)
    local selected
    for index,choice in ipairs(f.ui.edit.choices or {}) do if choice.value=="prs-new" then selected=index end end
    assert(selected,"connected PRS bridge was not listed");f.type(tostring(selected))
    Test.equal(f.config.playerBridgeName,"prs-new")
    local saved=textutils.unserialize(f.w.files[Config.PATH]);Test.equal(saved.playerBridgeName,"prs-new")
    f.selectSetting("maxRequestsPerTurn");f.type("2.5")
    assert(f.ui.edit and f.ui.edit.error);Test.equal(f.config.maxRequestsPerTurn,8)
    f.ui.handleEvent("key",keys.delete);f.type("3")
    Test.equal(f.config.maxRequestsPerTurn,3)
    f.selectSetting("autoCraftEnabled");Test.equal(f.config.autoCraftEnabled,false)
    f.selectSetting("playerBridgeName");f.ui.handleEvent("char","x");f.ui.handleEvent("key",keys.escape)
    Test.equal(f.config.playerBridgeName,"prs-new","cancelled edit changed configuration")
end)

Test.case("UI refuses unsafe hardware changes and rolls back failed configuration saves",function()
    local f=fixture("supply")
    f.state.busy=true;f.selectSetting("masterId");f.type("5")
    assert(f.ui.edit.error);Test.equal(f.config.masterId,-1)
    f.ui.handleEvent("key",keys.escape);f.state.busy=false
    f.state.requests={{id="R",staged=4,requested=4,status="in progress"}}
    f.selectSetting("masterId");f.type("5")
    assert(f.ui.edit.error);Test.equal(f.config.masterId,-1)
    f.ui.handleEvent("key",keys.escape);f.state.requests={}
    f.selectSetting("masterId");f.w.writeFail=true;f.type("5")
    assert(f.ui.edit.error);Test.equal(f.config.masterId,-1,"failed save left changed live config")
end)

Test.case("UI filters monitor touches and falls back when a present monitor fails",function()
    local f=fixture();f.ui.view="settings";f.ui.draw()
    assert(f.ui.handleEvent("monitor_touch","wrong",2,5)==false)
    f.monitor.failed=true;f.ui.draw();f.ui.draw()
    Test.equal(f.store.failures,1,"same failed monitor logged repeatedly")
    assert(f.terminal.dump():find("SETTINGS",1,true),"failed monitor did not fall back to terminal")
    f.ui.handleEvent("mouse_click",1,2,5)
    Test.equal(f.config.automationEnabled,false,"terminal fallback clicks are unusable")
    f.ui.handleEvent("char","3");Test.equal(f.ui.view,"requests")
end)

Test.case("UI route drafts validate unique channels and persist policy overrides",function()
    local f=fixture();f.ui.view="routes";f.ui.draw();f.touch(2,22)
    assert(f.ui.route and f.ui.view=="route")
    local route=f.ui.route
    route.id=2;route.label="Test colony";route.deliveryChest="delivery";route.returnChest="returns"
    route.deliveryChannel="red-white-blue";route.returnChannel="red-white-blue"
    f.ui.draw();f.touch(2,22)
    assert(f.ui.view=="route" and #f.config.colonies==0,"duplicate channels saved")
    route.returnChannel="red-white-black";route.overrides={maxRequestsPerTurn=2,autoCraftEnabled=false}
    f.ui.draw();f.touch(2,22)
    Test.equal(#f.config.colonies,1);Test.equal(f.config.colonies[1].overrides.autoCraftEnabled,false)
    Test.equal(f.config.colonies[1].overrides.maxRequestsPerTurn,2)
    local saved=textutils.unserialize(f.w.files[Config.PATH]);Test.equal(saved.colonies[1].id,2)
    f.touch(2,5);f.ui.view="overrides";f.ui.draw()
    assert(not f.monitor.dump():find("Monitor text scale",1,true),"local hardware setting exposed as remote policy override")
end)

Test.case("UI shows effective master policy and paused automation",function()
    local f=fixture("supply")
    f.state.effectivePolicy={autoCraftEnabled=false,maxRequestsPerTurn=2}
    f.ui.draw();assert(f.monitor.dump():find("Auto craft: OFF (MASTER)",1,true))
    f.selectSetting("maxRequestsPerTurn")
    assert(f.ui.edit.field.description:find("Effective master policy: 2",1,true))
    f.type("3");Test.equal(f.config.maxRequestsPerTurn,3)
    assert(f.ui.notice:find("Effective policy",1,true))
    local master=fixture();master.config.automationEnabled=false;master.ui.draw()
    assert(master.monitor.dump():find("AUTOMATION PAUSED",1,true))
    local reconciles,completed=0,nil;master.engine.requestReconcile=function(callback) reconciles=reconciles+1;completed=callback;return true end
    master.ui.view="health";master.ui.draw();master.touch(40,23);Test.equal(reconciles,0)
    assert(master.monitor.dump():find("ONE recovery item",1,true))
    master.touch(40,23);Test.equal(reconciles,1)
    master.touch(40,23);Test.equal(reconciles,1,"duplicate recovery queued")
    completed(false,"Original receipt stays held")
    assert(master.monitor.dump():find("BLOCKED: Original receipt stays held",1,true))
    master.touch(40,23);Test.equal(reconciles,1,"review bypassed recovery disclosure")
    master.touch(40,23);Test.equal(reconciles,2)
    completed(true,"Held transfer verified")
    assert(master.monitor.dump():find("RECOVERED: Held transfer verified",1,true))
    assert(master.monitor.dump():find("Automation remains paused",1,true))
end)

Test.case("recovery disclosure and button fit the computer terminal and read-only dashboards cannot invoke them",function()
    local f=fixture("master",false)
    local calls=0;f.engine.requestReconcile=function() calls=calls+1;return true end
    f.ui.view="health";f.ui.draw()
    local function click(label)
        for y=1,f.screen.height do
            local x=(f.screen.lines[y] or ""):find(label,1,true)
            if x then f.touch(x,y);return end
        end
        error("Missing terminal button: "..label.." / "..f.screen.dump())
    end
    click("RECOVER TRANSFER");Test.equal(calls,0)
    assert(f.screen.dump():find("ONE recovery item",1,true))
    click("RUN RECOVERY");Test.equal(calls,1)
    local remote=fixture("supply",true,100,38,{readOnly=true,displayOnly=true})
    remote.engine.requestReconcile=function() error("remote invoked recovery") end
    remote.ui.view="recovery";remote.ui.draw()
    Test.equal(remote.ui.view,"health")
    assert(not remote.screen.dump():find("RUN RECOVERY",1,true))
end)

Test.case("UI queues read-only update checks during active work and keeps installation guarded",function()
    local f=fixture()
    f.state.busy=true;f.state.requests={{id="R",status="in progress",requested=6,shipped=4}}
    f.ui.view="settings";f.ui.draw();f.touch(75,3)
    Test.equal(f.updater.checks,1,"active work blocked the read-only version check")
    assert(f.ui.notice:find("queued",1,true) and not f.ui.notice:find("CURRENT",1,true))
    assert(f.monitor.dump():find("CHECK QUEUED",1,true))
    f.touch(75,3);Test.equal(f.updater.checks,1,"queued check was duplicated")
    f.updater.checkQueued=false;f.updater.checking=true;f.ui.draw()
    assert(f.monitor.lines[20]:find("CHECKING...",1,true),"result row did not show the running check")
    f.touch(75,3);Test.equal(f.updater.checks,1,"running check was duplicated")
    f.updater.checking=false;f.updater.availableVersion="4.0.2";f.updater.remoteSuiteVersion="4.0.2"
    f.updater.lastCheckedText="12:34:56";f.ui.draw()
    assert(f.ui.notice:find("UPDATE AVAILABLE",1,true) and not f.ui.notice:find("queued",1,true))
    f.touch(75,3);Test.equal(f.updater.installs,0,"active turn allowed installation")
    assert(f.ui.notice:find("press UPDATE again",1,true))
    f.state.busy=false;f.ui.draw();f.touch(75,3);Test.equal(f.updater.installs,1)
    f.updater.installing=true;f.ui.draw();assert(f.monitor.dump():find("UPDATING...",1,true))
    f.touch(75,3);Test.equal(f.updater.installs,1,"running installation was duplicated")
    Test.equal(f.store.failures,0,"successful read-only check changed the error journal")
    assert(next(f.w.files)==nil,"read-only update check wrote configuration or state")
end)

Test.case("UI exposes current version source and check time without repeating terminal output",function()
    local f=fixture("master",true,100,38)
    f.updater.sourceLabel=function() return "github/gjheaton/Minecolonies-Command-Program@main" end
    f.updater.statusText=function(checking)
        return checking and "CHECKING..." or f.updater.remoteSuiteVersion and "CURRENT (suite v"..f.updater.remoteSuiteVersion..")" or "NOT CHECKED"
    end
    f.ui.view="settings";f.ui.draw();f.touch(95,3)
    f.updater.checkQueued=false;f.updater.remoteSuiteVersion="4.0.2";f.updater.lastCheckedText="15:20:30";f.ui.draw()
    assert(f.monitor.lines[34]:find("Update: CURRENT (suite v4.0.2) @15:20:30",1,true))
    assert(f.monitor.lines[35]:find("Source: github/gjheaton/Minecolonies-Command-Program@main",1,true))
    assert(not f.ui.notice:find("queued",1,true),"accepted check remained queued after completion")
    local originalPrint,output=print,{}
    _G.print=function(message) output[#output+1]=tostring(message) end
    local firstCount
    local ok,err=pcall(function() f.terminalRenderer();firstCount=#output;f.terminalRenderer() end)
    _G.print=originalPrint;assert(ok,err)
    Test.equal(#output,firstCount,"unchanged current version feedback repeated on the computer")
    assert(output[1]:find("CURRENT (suite v4.0.2) @15:20:30",1,true))
    assert(table.concat(output,"\n"):gsub("%s",""):find("github/gjheaton/Minecolonies-Command-Program@main",1,true))
end)

Test.case("UI completes repeated checks without erasing an independent settings notice",function()
    local f=fixture()
    f.updater.remoteSuiteVersion="4.0.2";f.updater.lastCheckedText="15:20:30"
    f.ui.view="settings";f.ui.draw();f.touch(75,3)
    f.updater.checkQueued=false;f.ui.draw()
    assert(f.ui.notice:find("CURRENT",1,true),"unchanged check result left a stale queued notice")
    f.touch(75,3);Test.equal(f.updater.checks,2)
    f.ui.notice="Local default saved. Effective policy is set on the master / colony route."
    f.updater.checkQueued=false;f.ui.draw()
    assert(f.ui.notice:find("Local default saved",1,true),"check completion erased a settings result")
    assert(not f.ui.updateCheckPending,"completed duplicate-time check stayed pending")
end)

Test.case("UI displays failed update results and tolerates missing updater helper methods",function()
    local f=fixture("master",false)
    f.ui.view="settings";f.ui.draw();f.touch(48,3)
    f.updater.checkQueued=false;f.updater.checkError="Download unavailable";f.updater.lastCheckedText="16:20:30"
    f.ui.draw()
    assert(f.terminal.lines[15]:find("Update: ERROR: Download unavailable",1,true))
    assert(f.terminal.lines[15]:find("16:20:30",1,true))
    assert(f.terminal.lines[16]:find("Source: UNAVAILABLE",1,true))
    assert(f.ui.notice:find("Download unavailable",1,true) and not f.ui.notice:find("queued",1,true))
    f.updater.check=function() f.updater.checks=f.updater.checks+1;return false,"Another action is queued; try again" end
    f.touch(48,3)
    assert(not f.ui.updateCheckPending,"rejected check was marked queued")
    assert(f.ui.notice:find("Another action is queued",1,true))
end)

Test.case("UI update feedback fits native settings pages and stays absent from read-only dashboards",function()
    local f=fixture("master",false)
    f.updater.sourceLabel=function() return "github/gjheaton/Minecolonies-Command-Program@main" end
    f.updater.remoteSuiteVersion="4.0.2";f.updater.lastCheckedText="12:34:56"
    f.ui.view="settings"
    local count=f.terminal.height-10
    for page=1,math.ceil(#Config.fields("master")/count) do
        f.ui.pages.settings=page;f.ui.draw()
        assert(f.terminal.lines[15]:find("CURRENT",1,true) and f.terminal.lines[15]:find("12:34:56",1,true))
        assert(f.terminal.lines[16]:find("Source:",1,true) and f.terminal.lines[16]:find("@main",1,true))
        assert(f.terminal.lines[17]:find("COLONY ROUTES",1,true))
        assert(f.terminal.lines[18]:find("PREV",1,true) and f.terminal.lines[18]:find("NEXT",1,true))
    end
    f.touch(2,17);Test.equal(f.ui.view,"routes","source row covered the route control")
    local remote=fixture("supply",true,100,38,{readOnly=true,displayOnly=true})
    remote.updater.availableVersion="4.0.2"
    remote.updater.statusText=function() error("read-only updater status accessed") end
    remote.updater.sourceLabel=function() error("read-only updater source accessed") end
    remote.updater.buttonLabel=function() error("read-only updater control accessed") end
    remote.state.settings=remote.config;remote.ui.view="settings";remote.ui.draw()
    assert(not remote.monitor.dump():find("Source:",1,true) and not remote.monitor.dump():find("Update:",1,true))
    remote.touch(95,3);Test.equal(remote.updater.checks,0);Test.equal(remote.updater.installs,0)
    Test.equal(remote.store.failures,0,"read-only dashboard invoked updater helpers")
end)

Test.case("UI history shows newest records while terminal diagnostics show only current issues",function()
    local f=fixture()
    f.store.data.history={{time=100,kind="INFO",message="oldest"},{time=101,kind="INFO",message="newest"}}
    f.store.data.errors={{code="OLD",message="old fault"},{code="NEW",message="new fault",severity="WARNING"}}
    f.state.requests={{name="minecraft:stone",status="missing",requested=6}}
    f.ui.view="history";f.ui.draw();assert(f.monitor.lines[5]:find("newest",1,true))
    f.ui.view="errors";f.ui.draw();assert(f.monitor.lines[5]:find("NEW",1,true))
    f.updater.checkError="Download unavailable";f.ui.draw()
    assert(f.monitor.dump():find("RETRY UPDATE",1,true),"queued update failure is invisible")
    local originalPrint,output=print,{}
    _G.print=function(message) output[#output+1]=tostring(message) end
    local ok,err=pcall(f.terminalRenderer)
    _G.print=originalPrint
    assert(ok,err)
    local text=table.concat(output,"\n")
    assert(not text:find("new fault",1,true) and not text:find("old fault",1,true),"native terminal displayed archived records")
    assert(text:find("Download unavailable",1,true),"terminal hid failed update check")
    assert(not text:find("minecraft:stone",1,true),"terminal mirrored request list")
end)

Test.case("UI wraps current transfer identity across HEALTH pages and routes HOME fault taps to the rendered page",function()
    local registry="test:"..string.rep("i",123)
    local chest="enderchests:"..string.rep("c",116)
    local reason="PRS reported stock but exported zero; possible desync"
    local detail=reason.."\nItem: Golden Iron Hammer\nID: "..registry.."\nQuantity: 7\nColony: Stardust [9]\nChest: "..chest.."\nReported / chest change: 0 / 0"
    for _,hasMonitor in ipairs({true,false}) do
        local f=fixture("master",hasMonitor,100,38)
        f.state.health={{label="Dedicated PRS owner",ok=true,detail="Only this computer calls the player RS Bridge"},
            {label="Transfer integrity",ok=false,detail=detail}}
        f.state.colonies={{id=9,label="Stardust",state="error",detail="Current colony fault"}}
        f.ui.view="health";f.ui.draw()
        local bodies={}
        for page=1,12 do
            f.ui.pages.health=page;f.ui.draw()
            if f.ui.pages.health~=page then break end
            for row=5,f.screen.height-3 do bodies[#bodies+1]=f.screen.lines[row] or "" end
        end
        local text=table.concat(bodies,"\n");local compact=text:gsub("%s","")
        assert(compact:find(reason:gsub("%s",""),1,true) and compact:find("Item:GoldenIronHammer",1,true))
        assert(compact:find(registry,1,true) and compact:find(chest,1,true),"HEALTH clipped the full item or chest identifier")
        assert(compact:find("Quantity:7",1,true) and compact:find("Reported/chestchange:0/0",1,true))
        f.ui.view="home";f.ui.draw();f.touch(2,13)
        Test.equal(f.ui.view,"health")
        assert(f.screen.dump():find("Current colony fault",1,true),"HOME tap selected the check index instead of its wrapped page")
        if not hasMonitor then assert(f.ui.pages.health>1,"wrapped transfer details did not affect HEALTH pagination") end
        f.state.health[2]={label="Transfer integrity",ok=true,detail="No uncertain transfer"};f.state.colonies={}
        f.ui.pages.health=1;f.ui.draw()
        assert(not f.screen.dump():find("Golden Iron Hammer",1,true),"cleared quarantine kept attempted-item context live")
        Test.equal(f.store.failures,0)
        assert(next(f.w.files)==nil,"HEALTH rendering changed configuration or persisted state")
    end
end)

Test.case("native transfer diagnostics keep attempted item and quantity visible without scrolling or mirroring old records",function()
    local f=fixture("master",true,100,38)
    local registry="test:"..string.rep("i",123)
    local detail="PRS reported stock but exported zero; possible desync\nItem: Golden Iron Hammer\nID: "..registry.."\nQuantity: 7\nColony: Stardust [9]\nChest: "
        ..string.rep("c",128).."\nReported / chest change: 0 / 0"
    f.state.health={{label="Transfer integrity",ok=false,detail=detail}}
    for index=1,10 do f.state.health[#f.state.health+1]={label="Other current fault "..index,ok=false,detail=string.rep("x",90)} end
    f.store.data.errors={{code="OLD",message="Archived transfer item",context={item="minecraft:old_item"}}}
    f.ui.draw()
    local previousPrint,output=print,{}
    _G.print=function(text) assert(#text<=51,"native diagnostic line wrapped implicitly");output[#output+1]=text end
    local firstCount
    local ok,err=pcall(function() f.terminalRenderer();firstCount=#output;f.terminalRenderer() end)
    _G.print=previousPrint;assert(ok,err)
    Test.equal(#output,firstCount,"unchanged current fault printed twice")
    assert(#output<=18,"native diagnostics would scroll their first row away")
    local text=table.concat(output,"\n");local compact=text:gsub("%s","")
    assert(compact:find("Item:GoldenIronHammer",1,true) and compact:find("ID:"..registry,1,true))
    assert(text:find("Quantity: 7",1,true),"attempted quantity scrolled or clipped offscreen")
    assert(output[#output]:find("More current details: HEALTH",1,true))
    assert(not text:find("Archived transfer item",1,true) and not text:find("minecraft:old_item",1,true))
    f.state.health={{label="Transfer integrity",ok=true,detail="No uncertain transfer"}};f.ui.draw()
    output={};_G.print=function(text) output[#output+1]=text end
    ok,err=pcall(f.terminalRenderer);_G.print=previousPrint;assert(ok,err)
    Test.equal(#output,0,"cleared transfer fault remained on the native terminal")
end)

Test.case("recorded export context displays the attempted identity destination and measured result",function()
    local f=fixture("master",true,100,38)
    f.store.data.errors={{time=100,code="TRANSFER_ZERO",message="PRS reported stock but exported zero; possible desync",
        context={displayName="Golden Iron Hammer",item="test:iron_hammer",expected=7,colonyLabel="Stardust",colonyId=9,chest="delivery_chest",reported=0,actual=0}}}
    f.ui.view="errors";f.ui.draw()
    local text=f.monitor.dump()
    for _,value in ipairs({"displayName: Golden Iron Hammer","item: test:iron_hammer","expected: 7","colonyLabel: Stardust","chest: delivery_chest","reported: 0","actual: 0"}) do
        assert(text:find(value,1,true),"recorded transfer context omitted "..value)
    end
    assert(text:find("see HEALTH for current status",1,true))
end)

return true
