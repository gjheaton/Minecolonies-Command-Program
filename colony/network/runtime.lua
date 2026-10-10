-- Only the processor invokes engine methods or performs an RS operation.
-- The receiver queues messages even while a bridge call yields.
local Config=require("colony.network.config")
local Store=require("colony.network.store")
local IO=require("colony.network.io")
local Protocol=require("colony.network.protocol")
local Diagnostics=require("colony.network.diagnostics")
local Matcher=require("colony.supply.matcher")
local SuiteUpdater=require("colony.lib.updater")
local Telemetry=require("colony.network.telemetry")
local Displays=require("colony.network.displays")
local M={}
local function staged(store,id)
    local data=store.data
    for _,entry in pairs(data.client and data.client.shipments or {}) do if (entry.count or 0)>(entry.imported or 0) then return true end end
    for key,colony in pairs(data.master and data.master.colonies or {}) do
        if id==nil or tostring(id)==key then
            for _,entry in pairs(colony.shipments or {}) do if (entry.count or 0)>(entry.imported or 0) then return true end end
        end
    end
    return false
end
local hardwareKeys={masterId=true,playerBridgeName=true,colonyBridgeName=true,colonyIntegratorName=true,deliveryChestName=true,returnChestName=true,deliveryChannel=true,returnChannel=true,colonyImportDirection=true,colonyExportDirection=true,usePeripheralTransfer=true,colonies=true}
local function retainedWork(store)
    local data=store.data
    if data.chestTest or staged(store) then return true end
    local client=data.client or {}
    if client.intent or client.fault or (client.turn and client.turn.phase~="finished") then return true end
    local master=data.master or {}
    if master.pendingTransfer or master.quarantine then return true end
    for _,colony in pairs(master.colonies or {}) do if colony.turn then return true end end
    for _,job in pairs(master.craftJobs or {}) do
        if job.state=="crafting" or job.state=="timed out" or job.state=="uncertain" then return true end
    end
    return false
end
function M.run(role,...)
    local mode,arg2,arg3=...
    local config=Config.load(role)
    local store=Store.new("/colony/"..role.."_v4_state",config); store.load()
    if mode=="setup" or (not fs.exists(Config.PATH) and mode==nil) then
        if retainedWork(store) then error("Finish/reconcile retained turns, deliveries, crafts and chest tests before changing hardware setup",0) end
        if not require("colony.network.setup").run(config) or mode=="setup" then return end
    end
    local matcher=Matcher.new(config,store)
    local io=IO.new(config,store,matcher)
    if mode=="diag" or mode=="diagnostics" then Diagnostics.printReport(config,io,store); return end
    if mode=="reconcile-zero" then
        if role~="supply" or type(arg2)~="string" or arg2=="" or arg3~=nil then
            error("Usage: colony_supply reconcile-zero <shipment ID>",0)
        end
        -- Preview before constructing the engine: boot recovery would rewrite
        -- the held fault. This command only records an operator-confirmed zero.
        local recovery=require("colony.network.client").zeroImportRecovery(config,store,io,matcher)
        local preview,reason=recovery.previewZeroImport(arg2)
        if not preview then print("BLOCKED: "..tostring(reason));return end
        print("HELD DELIVERY IMPORT: "..preview.shipmentId)
        print("Item: "..preview.item.name.." x"..preview.count)
        print("Chest: "..preview.chest)
        print("Original/current chest quantity: "..preview.beforeChest.." / "..preview.currentChest)
        print("Imported ledger stays: "..preview.imported)
        print("Confirm only if NO items moved in that failed call and none were replaced.")
        print("Other deliveries remain unchanged; this command moves no items.")
        print("Type "..preview.confirmation.." to record zero, or anything else to cancel:")
        local confirmation=read()
        if confirmation~=preview.confirmation then print("CANCELLED: Held transfer unchanged");return end
        local ok,detail=recovery.reconcileZeroImport(arg2,confirmation)
        print((ok and "OK: " or "BLOCKED: ")..tostring(detail));return
    end
    if mode=="monitors" then
        print("All supply monitors: 5 blocks wide x 3 high, scale 0.5 (100 x 38 characters).")
        for _,monitor in ipairs(io.monitors()) do
            print(monitor.name..": "..tostring(monitor.width).." x "..tostring(monitor.height)..", color="..tostring(monitor.color)..", "..monitor.assigned..((monitor.sizeOK and monitor.color) and "" or " - check size / Advanced Monitor"))
        end
        if config.monitorName=="" then print("Overview monitor uses automatic selection only when exactly one monitor is visible.") end
        return
    end
    if mode=="monitor" and role=="master" then
        local id=tonumber(arg2)
        if not id or type(arg3)~="string" or arg3=="" then error("Usage: colony_master monitor <colony ID> <monitor peripheral | none>",0) end
        local route
        for _,candidate in ipairs(config.colonies) do if candidate.id==id then
            route={}; for key,value in pairs(candidate) do route[key]=value end; break
        end end
        if not route then error("Unknown colony computer ID "..tostring(arg2),0) end
        -- Display assignment changes no transfer channel, policy, or ledger.
        route.monitorName=arg3=="none" and "" or arg3
        local ok,err=Config.setColony(config,route); if not ok then error(err,0) end
        Config.save(config)
        print("Colony "..id.." dashboard: "..(route.monitorName~="" and route.monitorName or "none"))
        return
    end
    if mode=="set" then
        if hardwareKeys[arg2] and retainedWork(store) then error("Retained work prevents changing transfer hardware; pause and finish/reconcile it first",0) end
        local field; for _,candidate in ipairs(Config.fields(role)) do if candidate.key==arg2 then field=candidate end end
        if not field then error("Unknown setting; use SETTINGS in the application",0) end
        local value=arg3
        if field.type=="number" then value=tonumber(arg3) elseif field.type=="boolean" then
            if arg3~="true" and arg3~="false" then error("Boolean settings require true or false",0) end
            value=arg3=="true"
        end
        local ok,err=Config.set(config,arg2,value); if not ok then error(err,0) end
        Config.save(config); print("Saved "..arg2); return
    end
    local opened=Protocol.open()
    if not opened then error("No modem available for rednet. Connect a wired/wireless modem, then restart.",0) end
    if mode=="chesttest" then
        local abandon=arg2=="abandon"
        Diagnostics.runMaster(config,store,io,matcher,assert(tonumber(abandon and arg3 or arg2),"Usage: colony_master chesttest <colony ID> [item] | chesttest abandon <ID>"),abandon and nil or arg3,abandon)
        return
    end
    local Engine=require(role=="master" and "colony.network.master" or "colony.network.client")
    local engine=Engine.new(config,store,io,matcher)
    if mode=="reconcile" then
        local pending=store.data.master and store.data.master.pendingTransfer
        if role=="master" and pending and pending.definiteZero and pending.reported==0 then
            -- Master boot invalidates route confirmation. Obtain a fresh
            -- trusted hello before authorizing an explicit recovery probe.
            print("Waiting for the affected colony's channel confirmation...")
            local deadline=io.now()+config.colonyResponseTimeoutSeconds
            while io.now()<deadline do
                local sender,message=rednet.receive(Protocol.NAME,math.min(config.helloSeconds,deadline-io.now()))
                if sender and Protocol.valid(message) then
                    engine.onMessage(sender,message)
                    if sender==pending.colonyId and message.kind=="hello" then break end
                end
            end
        end
        local ok,err=engine.reconcile()
        pending=store.data.master and store.data.master.pendingTransfer
        if ok and pending and engine.verifyHeldTransfer then
            local deadline=io.now()+(pending.verifySeconds or config.transferVerifyTimeoutSeconds)
            repeat
                ok,err=engine.verifyHeldTransfer()
                if ok or io.now()>=deadline then break end
                io.wait(pending.pollSeconds or config.transferPollSeconds)
            until false
        end
        print((ok and "OK: " or "BLOCKED: ")..tostring(err)); return
    end
    if mode and mode~="" then error("Usage: "..(role=="master" and "colony_master" or "colony_supply").." [setup | diag | monitors | reconcile | set key value"..(role=="master" and " | monitor ID name | chesttest ID [item]" or " | reconcile-zero shipmentID").."]",0) end
    local inbox,action={},nil
    local processorFault
    local telemetryFault
    local originalSnapshot=engine.snapshot
    function engine.snapshot()
        local view=originalSnapshot()
        view.programVersion=Config.VERSION
        local hardware=io.health()
        if telemetryFault then hardware.checks["Dashboard telemetry"]={ok=false,detail=telemetryFault} end
        if type(view.health)=="table" and view.health[1]~=nil then
            for label,check in pairs(hardware.checks) do view.health[#view.health+1]={label=label,ok=check.ok,detail=check.detail} end
        else view.health=view.health or {}; view.health.checks=hardware.checks end
        if processorFault then view.statusMessage=processorFault; view.health.ok=false; view.health.detail=processorFault end
        view.effectivePolicy=store.data.client and store.data.client.turn and store.data.client.turn.policy or nil
        return view
    end
    function engine.canEditHardware()
        if engine.busy() or store.data.chestTest or processorFault then return false,"Finish/reconcile turns and tests before changing hardware" end
        if staged(store) then return false,"Import all verified shipments before changing hardware" end
        for _,job in pairs(store.data.master and store.data.master.craftJobs or {}) do
            if job.state=="crafting" or job.state=="timed out" or job.state=="uncertain" then return false,"Resolve pending crafts before changing PRS hardware" end
        end
        return true
    end
    function engine.canEditRoute(id)
        if engine.busy() or store.data.chestTest then return false,"Pause master automation and finish reserved turns before editing routes" end
        if staged(store,id) then return false,"This colony still has staged shipments" end
        return true
    end
    function engine.requestReconcile() action="reconcile"; return true end
    local actualUpdater=SuiteUpdater.new({appId=role,appVersion=Config.VERSION,suiteVersion=Config.VERSION,
        displayName=role=="master" and "PRS MASTER" or "COLONY SUPPLY",checkSeconds=config.updateCheckSeconds})
    local updater=setmetatable({}, {__index=actualUpdater})
    function updater.check() action="check"; return true end
    function updater.install() action="update"; return true end
    local telemetry=Telemetry.new(config,store,io,engine)
    local ui=Displays.new(config,store,engine,io,updater,telemetry)
    local nextCheck=io.now()
    local function processor()
        while true do
            local ok,err=pcall(function()
                while #inbox>0 do
                    local packet=table.remove(inbox,1)
                    local message=packet.message
                    if message.kind=="telemetry" or message.kind=="telemetry_request" then
                        local accepted,detail=pcall(telemetry.onMessage,packet.sender,message)
                        if not accepted then telemetryFault=tostring(detail) end
                    elseif role=="supply" and packet.sender==config.masterId and message.kind=="probe" then
                        local response=Diagnostics.handleClient(config,store,io,message,engine.canProbe)
                        if response then io.send(config.masterId,response) end
                    elseif not store.data.chestTest and not processorFault then engine.onMessage(packet.sender,message) end
                end
                if action then
                    local pending=action; action=nil
                    if pending=="check" then
                        actualUpdater.checking=true
                        local checked,checkError=pcall(actualUpdater.check)
                        actualUpdater.checking=false
                        if not checked then actualUpdater.checkError=tostring(checkError) end
                    elseif pending=="reconcile" and not store.data.chestTest then
                        local recovered,detail=engine.reconcile()
                        store.event(recovered and "RECOVERY" or "WARNING",detail or "Reconciliation finished")
                    elseif pending=="update" then
                        local allowed,reason=engine.canUpdate()
                        if allowed and not store.data.chestTest then
                            actualUpdater.installing=true
                            local updated,result=pcall(actualUpdater.install)
                            actualUpdater.installing=false
                            if not updated or result==false then store.error("UPDATE_FAILED",updated and "Installer did not commit an update; previous suite retained" or tostring(result)) end
                        else store.event("WARNING",reason or "Finish the current turn before updating") end
                    end
                end
                if not processorFault and not store.data.chestTest then engine.tick() end
                if io.now()>=nextCheck then action=action or "check"; nextCheck=io.now()+config.updateCheckSeconds end
            end)
            if not ok then
                processorFault="Processor stopped; restart after recovery: "..tostring(err)
                pcall(store.error,"PROCESSOR_ERROR",processorFault)
            end
            -- Display traffic remains available while automation is paused,
            -- a chest test is reserved, or a transfer needs recovery.
            local shown,detail=pcall(telemetry.tick)
            if shown then telemetryFault=nil else telemetryFault=tostring(detail) end
            pcall(ui.draw); pcall(ui.renderTerminal)
            sleep(config.pollIntervalSeconds)
        end
    end
    local function receiver()
        while true do
            local event={os.pullEvent()}
            if event[1]=="rednet_message" and event[4]==Protocol.NAME and Protocol.valid(event[3]) then
                if #inbox<256 then inbox[#inbox+1]={sender=event[2],message=event[3]} end
            elseif event[1]=="peripheral" then pcall(Protocol.open); pcall(ui.handleEvent,table.unpack(event))
            else pcall(ui.handleEvent,table.unpack(event)) end
        end
    end
    store.event("START",(role=="master" and "PRS Master" or "Colony Supply").." v"..Config.VERSION)
    ui.draw(); ui.renderTerminal()
    parallel.waitForAll(receiver,processor)
end
return M
