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

local function fixture(role,hasMonitor)
    local w=S.world()
    _G.colors={white=1,orange=2,magenta=4,lightBlue=8,yellow=16,lime=32,pink=64,gray=128,
        lightGray=256,cyan=512,purple=1024,blue=2048,brown=4096,green=8192,red=16384,black=32768}
    _G.keys={enter=28,numPadEnter=156,escape=1,backspace=14,delete=211}
    local terminal=surface(51,19);_G.term=terminal;term.current=function() return terminal end
    local monitor=surface(80,24)
    local config=Config.defaults(role or "master")
    local state={role=role or "master",health={{label="PRS",ok=true,detail="Connected"}},requests={},colonies={}}
    local store={data={history={},errors={}},failures=0,error=function() end}
    store.error=function() store.failures=store.failures+1 end
    local engine={snapshot=function() return state end,busy=function() return state.busy==true end}
    local io={monitor=function() if hasMonitor~=false then return monitor,"top" end end}
    local updater={checks=0,installs=0}
    updater.check=function() updater.checks=updater.checks+1;return true end
    updater.install=function() updater.installs=updater.installs+1;return true end
    local ui=require("colony.network.ui").new(config,store,engine,io,updater)
    local f={w=w,ui=ui,config=config,state=state,engine=engine,store=store,monitor=monitor,terminal=terminal,updater=updater}
    f.screen=hasMonitor==false and terminal or monitor
    f.terminalRenderer=ui.renderTerminal
    -- Most cases inspect the monitor directly. Avoid printing keyboard prompts
    -- to the test host; the terminal renderer is exercised separately below.
    ui.renderTerminal=function() end
    function f.touch(x,y)
        return hasMonitor==false and ui.handleEvent("mouse_click",1,x,y) or ui.handleEvent("monitor_touch","top",x,y)
    end
    function f.selectSetting(key)
        local schemas=Config.fields(config.role)
        local rows=f.screen.height-9
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
    for _,view in ipairs({"home","health","requests","history","errors","settings","routes"}) do
        f.ui.view=view;f.ui.draw()
        assert(f.monitor.dump():find("CHECK UPDATE",1,true),"upper-right update control absent")
    end
    f.ui.view="requests";f.ui.draw()
    local text=f.monitor.dump()
    assert(text:find("6 / 4 / 2",1,true) and text:find("IN PROGRESS",1,true))
    assert(text:find("completion requires MineColonies",1,true))
    Test.equal(f.store.failures,0,"protected drawing swallowed a rendering failure")
end)

Test.case("UI editor validates values and persists scalar settings without blocking read",function()
    local f=fixture()
    f.selectSetting("playerBridgeName");assert(f.ui.edit)
    f.type("prs-new")
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

Test.case("UI shows effective master policy and paused automation while serializing controls",function()
    local f=fixture("supply")
    f.state.effectivePolicy={autoCraftEnabled=false,maxRequestsPerTurn=2}
    f.ui.draw();assert(f.monitor.dump():find("Auto craft: OFF (MASTER)",1,true))
    f.selectSetting("maxRequestsPerTurn")
    assert(f.ui.edit.field.description:find("Effective master policy: 2",1,true))
    f.type("3");Test.equal(f.config.maxRequestsPerTurn,3)
    assert(f.ui.notice:find("Effective policy",1,true))
    local master=fixture();master.config.automationEnabled=false;master.ui.draw()
    assert(master.monitor.dump():find("AUTOMATION PAUSED",1,true))
    master.state.busy=true;master.ui.draw();master.touch(75,3)
    Test.equal(master.updater.checks,0,"busy update control bypassed serialized gate")
    master.state.busy=false;master.ui.draw();master.touch(75,3);Test.equal(master.updater.checks,1)
    master.updater.checking=true;master.ui.draw()
    assert(master.monitor.dump():find("CHECKING...",1,true));master.touch(75,3)
    Test.equal(master.updater.checks,1,"a running update check was queued twice")
    master.updater.checking=false;master.updater.installing=true;master.ui.draw()
    assert(master.monitor.dump():find("UPDATING...",1,true));master.updater.installing=false
    local reconciles=0;master.engine.requestReconcile=function() reconciles=reconciles+1;return true end
    master.ui.view="health";master.ui.draw();master.touch(40,23);Test.equal(reconciles,1)
end)

Test.case("UI history and terminal diagnostics show newest records without mirroring requests",function()
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
    assert(text:find("new fault",1,true) and not text:find("old fault",1,true))
    assert(text:find("Download unavailable",1,true),"terminal hid failed update check")
    assert(not text:find("minecraft:stone",1,true),"terminal mirrored request list")
end)

return true
