-- Hardware setup stays on the native computer screen and edits a draft.
-- No inventory, bridge, monitor or journal operation occurs in this wizard.
local Config=require("colony.network.config")
local SetupUI=require("colony.network.setup_ui")
local Devices=require("colony.network.devices")
local M={}

local function copy(value)
    if type(value)~="table" then return value end
    local out={};for key,child in pairs(value) do out[key]=copy(child) end;return out
end
local function textValid(value)
    return #value<=128 and not value:find("[%c]"),"Use at most 128 characters, without control characters."
end
local function idValid(value,optional)
    if optional and value=="" then return true end
    local id=tonumber(value)
    if not id or id~=id or id<0 or id>2147483647 or id%1~=0 then
        return false,"Use a computer ID from 0 to 2147483647."
    end
    if id==os.getComputerID() then return false,"Enter the other computer's ID; this computer is "..id.."." end
    return true
end
local function suggestedChannels(label)
    label=tostring(label or ""):lower()
    local colony=label:find("clockwork",1,true) and "blue" or label:find("stardust",1,true) and "pink"
    if colony then return "red-"..colony.."-white","red-"..colony.."-black" end
end
local function selectDevice(ui,spec,config,key,options)
    spec.choices=Devices.choices(config,key,options)
    spec.required=not spec.allowNone
    spec.validate=function(value) return Devices.available(config,key,value,options) end
    return ui.choose(spec)
end
local function channel(ui,label,current,help,unavailable)
    return ui.ask({title="CHEST COLORS",label=label,current=current,required=true,help=help,
        validate=function(value)
            local ok,err=textValid(value);if not ok then return false,err end
            if unavailable[value:lower()] then return false,"Each direction and colony needs its own color channel." end
            return true
        end}):lower()
end
local function master(ui,draft)
    draft.playerBridgeName=selectDevice(ui,{title="PLAYER STORAGE",label="Choose the PRS Bridge",current=draft.playerBridgeName,
        help={"Select the bridge connected to player storage.","Use its wired modem name to identify it."}},draft,"playerBridgeName")
    -- Wiring changes are applied only while idle (runtime checks retained
    -- work first), and must be tested before automatically moving items.
    draft.automationEnabled=false
    while true do
        local required=#draft.colonies==0
        local value=ui.ask({title="COLONY COMPUTER",label="Colony computer ID",required=required,
            help={"Run id on the colony computer for its number.","Enter an existing ID to edit its setup.",
                required and "Add the first colony before saving." or "Leave blank when all colonies are configured."},
            validate=function(answer) return idValid(answer,not required) end})
        if value=="" then return end
        local id=tonumber(value)
        local route
        for _,existing in ipairs(draft.colonies) do if existing.id==id then route=copy(existing);break end end
        local deviceOptions={route=route,routeId=route and route.id or nil}
        route=route or {id=id,overrides={}}
        deviceOptions.route=route
        local defaultLabel=route.label or (#draft.colonies==0 and "Clockwork" or #draft.colonies==1 and "Stardust" or nil)
        route.label=ui.ask({title="COLONY NAME",label="Colony label",current=defaultLabel,required=true,
            help={"Name shown on the master dashboard.","The connection uses the computer ID, not this name."},validate=textValid})
        local deliveryDefault,returnDefault=suggestedChannels(route.label)
        route.deliveryChest=selectDevice(ui,{title="MASTER DELIVERY",label="Choose the chest TO "..route.label,current=route.deliveryChest,
            help={"Select this colony's master delivery chest.","Physical colors: "..(route.deliveryChannel or deliveryDefault or "red / colony color / white")}},draft,"deliveryChest",deviceOptions)
        route.returnChest=selectDevice(ui,{title="MASTER RETURN",label="Choose the chest FROM "..route.label,current=route.returnChest,
            help={"Select this colony's master overflow return chest.","Physical colors: "..(route.returnChannel or returnDefault or "red / colony color / black")}},draft,"returnChest",deviceOptions)
        local usedChannels={}
        for _,other in ipairs(draft.colonies) do if other.id~=id then
            usedChannels[other.deliveryChannel:lower()]=true;usedChannels[other.returnChannel:lower()]=true
        end end
        route.deliveryChannel=channel(ui,"Delivery colors (TO colony)",route.deliveryChannel or deliveryDefault,
            {"Type the physical dyes in order, such as", "red-blue-white (Clockwork) or red-pink-white", "(Stardust). The colony must use the same colors."},usedChannels)
        usedChannels[route.deliveryChannel]=true
        route.returnChannel=channel(ui,"Return colors (FROM colony)",route.returnChannel or returnDefault,
            {"Type the physical dyes in order, such as", "red-blue-black (Clockwork) or red-pink-black", "(Stardust). This is a different chest channel."},usedChannels)
        route.monitorName=selectDevice(ui,{title="COLONY DISPLAY",label="Master dashboard for "..route.label,
            current=route.monitorName or "",allowNone=true,noneLabel="No extra colony dashboard",
            help={"Optional separate monitor beside the overview.","Use a 5 blocks wide x 3 high Advanced Monitor."}},draft,"monitorName",deviceOptions)
        local ok,err=Config.setColony(draft,route)
        if not ok then ui.notice({title="CHECK COLONY SETUP",lines={tostring(err),"Enter the same computer ID to try again."}}) end
    end
end
local function supply(ui,draft)
    draft.masterId=tonumber(ui.ask({title="MASTER COMPUTER",label="Master computer ID",
        current=draft.masterId>=0 and draft.masterId or nil,required=true,
        help={"Run id on the dedicated PRS master computer.","Enter that number, not its computer label."},validate=idValid}))
    draft.colonyIntegratorName=selectDevice(ui,{title="COLONY REQUESTS",label="Choose the Colony Integrator",current=draft.colonyIntegratorName,
        help={"Choose the integrator for this computer's colony."}},draft,"colonyIntegratorName")
    draft.colonyBridgeName=selectDevice(ui,{title="COLONY STORAGE",label="Choose the Colony RS Bridge",current=draft.colonyBridgeName,
        help={"Choose the bridge connected to this colony's storage."}},draft,"colonyBridgeName")
    local label=type(os.getComputerLabel)=="function" and os.getComputerLabel() or nil
    local deliveryDefault,returnDefault=suggestedChannels(label)
    draft.deliveryChestName=selectDevice(ui,{title="COLONY DELIVERY",label="Choose the chest TO this colony",current=draft.deliveryChestName,
        help={"Local delivery chest; matches the master's colors.","Physical colors: "..(draft.deliveryChannel~="" and draft.deliveryChannel or deliveryDefault or "red / colony color / white")}},draft,"deliveryChestName")
    draft.returnChestName=selectDevice(ui,{title="COLONY RETURN",label="Choose the chest FROM this colony",current=draft.returnChestName,
        help={"Local overflow return chest; matches the master.","Physical colors: "..(draft.returnChannel~="" and draft.returnChannel or returnDefault or "red / colony color / black")}},draft,"returnChestName")
    draft.deliveryChannel=channel(ui,"Delivery colors (TO colony)",draft.deliveryChannel~="" and draft.deliveryChannel or deliveryDefault,
        {"Match the delivery colors entered on the master.","Clockwork: red-blue-white", "Stardust: red-pink-white"},{})
    draft.returnChannel=channel(ui,"Return colors (FROM colony)",draft.returnChannel~="" and draft.returnChannel or returnDefault,
        {"Match the return colors entered on the master.","Clockwork: red-blue-black", "Stardust: red-pink-black"},{[draft.deliveryChannel]=true})
end
local function review(ui,draft)
    local lines={"Main monitor: "..(draft.monitorName~="" and draft.monitorName or "automatic / computer screen")}
    if draft.role=="master" then
        lines[#lines+1]="PRS Bridge: "..draft.playerBridgeName
        for _,route in ipairs(draft.colonies) do
            lines[#lines+1]=(route.label or "Colony").." (computer "..route.id..")"
            lines[#lines+1]="TO: "..route.deliveryChest.." / "..route.deliveryChannel
            lines[#lines+1]="FROM: "..route.returnChest.." / "..route.returnChannel
            lines[#lines+1]="Dashboard: "..(route.monitorName and route.monitorName~="" and route.monitorName or "none")
        end
        lines[#lines+1]="Master automation will be paused. Start the colony computers, then run diag and chesttest for each colony before enabling automation."
    else
        lines[#lines+1]="Master computer: "..draft.masterId
        lines[#lines+1]="Colony Integrator: "..draft.colonyIntegratorName
        lines[#lines+1]="Colony RS Bridge: "..draft.colonyBridgeName
        lines[#lines+1]="TO: "..draft.deliveryChestName.." / "..draft.deliveryChannel
        lines[#lines+1]="FROM: "..draft.returnChestName.." / "..draft.returnChannel
        lines[#lines+1]="Run colony_supply after setup so the master can communicate with this colony for chest tests."
    end
    ui.notice({title="REVIEW SETUP",lines=lines})
    return ui.ask({title="SAVE SETUP",label="Save these settings? (yes/no)",current="yes",required=true,
        help={"Yes saves the draft. No keeps the previous setup.","Timeouts, crafting and limits remain in SETTINGS."},
        validate=function(value) return value:lower()=="yes" or value:lower()=="no","Type yes or no, or :q to cancel." end}):lower()=="yes"
end

function M.run(config)
    local draft=copy(config)
    local ui=SetupUI.new(draft)
    local ok,result=pcall(function()
        ui.notice({title=draft.role=="master" and "PRS MASTER SETUP" or "COLONY SUPPLY SETUP",lines={
            "Answer one question at a time using this computer's keyboard.",
            "Choose devices by their listed numbers. N/P changes pages; Enter keeps a current answer.",
            ":q cancels without saving. Settings are saved only after the final confirmation.",
            "Operating monitors are 5 blocks wide x 3 high. Setup stays on this computer screen."}})
        ui.notice({title="IDENTIFY EACH DEVICE",lines={
            "Right-click the wired modem beside a chest or monitor to enable it. Chat shows its peripheral name.",
            "To check one device, disable its modem, compare the peripherals list, then enable it again.",
            "Write the peripheral name on a sign beside each chest or monitor. Chest colors are set by hand; setup cannot read the dyes."}})
        draft.monitorName=selectDevice(ui,{title="MAIN DISPLAY",label=draft.role=="master" and "Choose the master overview monitor" or "Choose this colony's monitor",
            current=draft.monitorName,allowNone=true,noneLabel="Automatic / computer screen",
            help={"Use a 5 blocks wide x 3 high Advanced Monitor.","With several monitors, select one by number."}},draft,"monitorName")
        if draft.role=="master" then master(ui,draft) else supply(ui,draft) end
        local valid,err=Config.validate(draft);if not valid then error(err,0) end
        if not review(ui,draft) then return false end
        Config.save(draft)
        for key in pairs(config) do config[key]=nil end
        for key,value in pairs(draft) do config[key]=copy(value) end
        return true
    end)
    ui.close()
    if not ok then
        if result==SetupUI.CANCELLED then print(SetupUI.CANCELLED);return false end
        error(result,0)
    end
    if result then
        print("Setup saved.")
        if draft.role=="master" then print("Automation paused. Test the chest connections.") end
    else print("Setup cancelled; no settings were saved.") end
    return result
end
return M
