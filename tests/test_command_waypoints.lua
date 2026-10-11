local S=require("tests.support")
local Waypoints=require("colony.command.waypoints")

Test.case("JourneyMap hut messages preserve negative coordinates and sanitize names without changing the target",function()
    local message=assert(Waypoints.message('§aClockwork, [x:999]', 'Farmer\n"hut"', {x=-1270,y=63,z=458}))
    assert(message:find("x:-1270, y:63, z:458",1,true))
    assert(not message:find("\n",1,true) and not message:find('"',1,true))
    local _,commas=message:gsub(",","");Test.equal(commas,3,"name injected JourneyMap fields")
    assert(message:match("^%[name:.*%]$"))
end)

Test.case("invalid or absent hut coordinates never discover or call a chat peripheral",function()
    local previous=peripheral
    _G.peripheral={find=function() error("invalid location attempted chat discovery") end}
    for _,position in ipairs({{}, {x=1,y=2,z=0/0},{x=1,y=2,z=math.huge},{x=1.5,y=2,z=3},{x=1,y=2,z="3"}}) do
        local sent,reason=Waypoints.share("Clockwork","Farmer",position)
        assert(not sent and reason:find("coordinates",1,true))
    end
    _G.peripheral=previous
end)

Test.case("MARK HUT uses the public Chat Box API once and reports acceptance without claiming a waypoint was created",function()
    local previous=peripheral;local calls=0
    _G.peripheral={find=function(kind)
        Test.equal(kind,"chatBox")
        return {sendMessage=function(message,prefix)
            calls=calls+1;Test.equal(message,"[name:Clockwork - Farmer, x:-1270, y:63, z:458]")
            Test.equal(prefix,"Colony Command");return true
        end}
    end}
    local sent,reason=Waypoints.share("Clockwork","Farmer",{x=-1270,y=63,z=458})
    Test.equal(calls,1);assert(sent and reason:find("public chat",1,true) and reason:find("Click",1,true))
    _G.peripheral=previous
end)

Test.case("missing detached busy and rejected Chat Boxes show failure without broadcasting via a fallback",function()
    local previous=peripheral
    for _,outcome in ipairs({"missing","detached","busy","reject","throw"}) do
        local calls=0
        _G.peripheral={find=function()
            if outcome=="missing" then return nil end
            if outcome=="detached" then error("detached") end
            return {sendMessage=function()
                calls=calls+1
                if outcome=="throw" then error("detached during send") end
                if outcome=="reject" then return nil,"Message exceeds range" end
                return false,"Chat Box is on cooldown"
            end}
        end}
        local sent,reason=Waypoints.share("Clockwork","Farmer",{x=1,y=2,z=3})
        assert(not sent and type(reason)=="string" and #reason>0);assert(calls<=1)
    end
    _G.peripheral=previous
end)
Test.case("work order markers require a unique target and never use the builder location",function()
    local hut={name="farmer",type="farmer",location={x=1,y=2,z=3}}
    local order={buildingName="farmer",builder={x=100,y=2,z=3}}
    Test.equal(Waypoints.orderHut(order,{hut}),hut)
    assert(not Waypoints.orderHut(order,{hut,{name="farmer",type="farmer"}}))
    assert(not Waypoints.orderHut({buildingName="builder",builder=hut.location},{hut}))
end)
for _, scenario in ipairs({
    {name="Buildings details", controls={"BUILDINGS","Farmer","MARK HUT"}},
    {name="Buildings row", controls={"BUILDINGS","MARK"}},
    {name="Construction Orders row", controls={"CONSTRUCTION","MARK"}},
    {name="Help Wanted row", controls={"HELP WANTED","MARK"}},
    {name="Help Wanted details", controls={"HELP WANTED","Farmer","MARK HUT"}},
}) do
Test.case("real Command "..scenario.name.." shares the selected hut and shows the JourneyMap click instruction",function()
    local D=require("tests.display_support")
    local Updater=require("colony.lib.updater")
    local saved={new=Updater.new,print=print,pull=os.pullEvent,timer=os.startTimer,redstone=redstone}
    local w=D.world();local screen=w.monitor(1,"screen",100,38);local calls={}
    local building={name="farmer",type="farmer",location={x=-1270,y=63,z=458},level=3,maxLevel=5,built=true}
    local colony={}
    local values={isInColony=true,getColonyName="Clockwork",getColonyID=2,getColonyStyle="fortress",
        getLocation={x=0,y=64,z=0},getHappiness=9,isActive=true,isUnderAttack=false,isUnderRaid=false,
        amountOfCitizens=0,maxOfCitizens=0,amountOfGraves=0,amountOfConstructionSites=0,
        getCitizens={},getBuildings={building},getRequests={},getWorkOrders={{buildingName="farmer",type="farmer",targetLevel=4}},getVisitors={},getResearch={}}
    for key,value in pairs(values) do local result=value;colony[key]=function() return result end end
    local chat={sendMessage=function(message,prefix) calls[#calls+1]={message=message,prefix=prefix};return true end}
    peripheral.find=function(kind)
        if kind=="monitor" then return screen elseif kind=="colonyIntegrator" then return colony elseif kind=="chatBox" then return chat end
    end
    peripheral.getName=function(api) return api==screen and "screen" or "integrator" end
    _G.redstone={setOutput=function() end,getOutput=function() return false end}
    _G.print=function() end
    os.startTimer=function() return 1 end
    Updater.new=function() return {buttonLabel=function() return "CHECK UPDATE" end,
        terminalStatus=function() return "CURRENT",colors.white end,sourceLabel=function() return "test" end,statusText=function() return "CURRENT" end,check=function() return false end} end
    local phase=0
    os.pullEvent=function()
        phase=phase+1
        local wanted=scenario.controls[phase]
        if not wanted then
            Test.equal(#calls,1)
            Test.equal(calls[1].message,"[name:Clockwork - Farmer, x:-1270, y:63, z:458]")
            assert(screen.dump():find("Waypoint shared in public chat",1,true))
            assert(screen.dump():find("JourneyMap",1,true),screen.dump())
            error("COMMAND_TEST_DONE",0)
        end
        for y=screen.height,1,-1 do
            local x=(screen.lines[y] or ""):find(wanted,1,true)
            if x then return "monitor_touch","screen",x,y end
        end
        error("Missing real Command control: "..wanted.." / "..screen.dump())
    end
    local ok,err=pcall(assert(loadfile(TEST_ROOT.."/colony_command.lua")))
    Updater.new,_G.print,os.pullEvent,os.startTimer,_G.redstone=saved.new,saved.print,saved.pull,saved.timer,saved.redstone
    assert(not ok and tostring(err)=="COMMAND_TEST_DONE",err)
end)
end
return true
