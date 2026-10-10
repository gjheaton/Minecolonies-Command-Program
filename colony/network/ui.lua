-- MineColonies Control Suite - shared master / colony supply interface.
-- Uses the suite's monitor framework, palette, navigation and update control.
local SharedUI = require("colony.lib.ui")
local Util = require("colony.lib.util")
local Config = require("colony.network.config")
local Devices = require("colony.network.devices")
local M = {}
local C = SharedUI.theme()
local hardwareKeys={masterId=true,playerBridgeName=true,colonyBridgeName=true,colonyIntegratorName=true,
    deliveryChestName=true,returnChestName=true,deliveryChannel=true,returnChannel=true,
    usePeripheralTransfer=true,colonyImportDirection=true,colonyExportDirection=true}

local tabs = {
    {id="home", label="HOME"}, {id="health", label="HEALTH"},
    {id="requests", label="REQUESTS"}, {id="history", label="HISTORY"},
    {id="errors", label="ERRORS"}, {id="settings", label="SETTINGS"},
}

local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
end

local function list(value)
    if type(value) ~= "table" then return {} end
    if #value > 0 then return value end
    local out = {}
    for key, row in pairs(value) do
        if type(row) == "table" then
            local entry = copy(row)
            entry.id = entry.id or key
            out[#out + 1] = entry
        end
    end
    table.sort(out, function(a,b) return tostring(a.id) < tostring(b.id) end)
    return out
end

local function statusColor(status)
    status = tostring(status or ""):lower()
    if status:find("error",1,true) or status == "missing" or status == "failed" then return C.danger end
    if status:find("timed",1,true) or status:find("warn",1,true) or status == "blocked" then return C.warn end
    if status == "crafting" then return C.title end
    if status == "complete" or status == "delivered" or status == "in progress" or status == "online" then return C.good end
    if status == "requested" or status == "verified" or status == "waiting" then return C.accent end
    return C.text
end

local function textOf(value)
    if type(value) == "table" then
        return tostring(value.message or value.detail or value.reason or value.error or value.label or value.code or "")
    end
    return tostring(value or "")
end

local function newestFirst(value)
    local rows=list(value)
    local out={}
    -- The network journal appends records; the suite shows newest events first.
    for i=#rows,1,-1 do out[#out+1]=rows[i] end
    return out
end

local function timeOf(value)
    if type(value)=="number" and os.date then
        local ok,time=pcall(os.date,"%H:%M:%S",math.floor(value))
        if ok then return time end
    end
    return tostring(value or "--:--:--")
end

local function colonyFailure(colony)
    local state=tostring(colony.status or colony.phase or colony.state or ""):lower()
    local explicit=textOf(colony.error or colony.routeError)
    if state:find("error",1,true) or state=="failed" or explicit~="" then
        local detail=textOf(colony.detail or colony.error or colony.routeError)
        return detail~="" and detail or "Colony reports an error; check its HEALTH screen."
    end
end

function M.new(config, store, engine, io, updater, options)
    options=options or {}
    local self = {view="home", pages={}, edit=nil, route=nil, routeSelections={}, notice=nil, checkingUpdate=false}
    local mon, monName, hasMonitor
    local monitorSizeError
    local snapshot = {}
    local lastTerminal = nil
    local monitorFailure = nil
    local draw

    local function logError(code, message)
        if options.readOnly then return end
        if store and type(store.error) == "function" then pcall(store.error, code, tostring(message))
        elseif store and type(store.log) == "function" then pcall(store.log, code .. ": " .. tostring(message)) end
    end

    local function resolveMonitor()
        local candidate, name
        if io and type(io.monitor) == "function" then
            local ok, result, n = pcall(io.monitor)
            if ok then candidate, name = result, n end
        end
        if candidate then
            local ok,w,h=pcall(candidate.getSize)
            if not ok or type(w)~="number" or type(h)~="number" or w<1 or h<1 then
                local reason="Monitor unavailable: "..tostring(w)
                if monitorFailure~=reason then logError("MONITOR",reason); monitorFailure=reason end
                self.notice=options.displayOnly and "Monitor unavailable." or "Monitor unavailable; controls moved to the computer terminal."
                candidate,name=nil,nil
            else monitorFailure=nil end
        end
        monitorSizeError=nil
        if candidate and candidate.setTextScale then pcall(candidate.setTextScale,options.fixedTextScale or config.monitorTextScale or 0.5) end
        if candidate and options.expectedSize then
            local expected=options.expectedSize
            local ok,w,h=pcall(candidate.getSize)
            local columns=expected.columns or expected.width
            local rows=expected.rows or expected.height
            if ok and columns and rows and (w~=columns or h~=rows) then
                monitorSizeError="Use "..tostring(expected.blocksWide or 5).." x "..tostring(expected.blocksHigh or 3).." monitor blocks at scale "..tostring(options.fixedTextScale or expected.textScale or .5).."."
                pcall(function()
                    candidate.setBackgroundColor(C.bg);candidate.setTextColor(C.warn);candidate.clear()
                    candidate.setCursorPos(1,1);candidate.write(Util.clip("MONITOR SIZE",w))
                    if h>=2 then candidate.setCursorPos(1,2);candidate.write(Util.clip(monitorSizeError,w)) end
                    if h>=3 then candidate.setCursorPos(1,3);candidate.write(Util.clip("Detected "..w.." x "..h.."; expected "..columns.." x "..rows.." characters.",w)) end
                end)
                if not options.displayOnly then candidate=nil;self.notice=monitorSizeError.." Controls are on the computer terminal." end
            end
        end
        hasMonitor = candidate ~= nil
        mon,monName=candidate,name or options.monitorName
        if not mon and not options.displayOnly then mon=term.current() end
        self.monitorName=monName
        self.monitorPresent=hasMonitor
        return mon
    end

    local screen = SharedUI.newMonitor({
        getMonitor=function() return mon or resolveMonitor() end,
        onFailure=function(err) logError("MONITOR", err); mon=nil end,
    })
    local function nativeTerminal()
        if type(term.native)=="function" then return term.native() end
        return term.current()
    end
    local terminalPicker=SharedUI.newMonitor({getMonitor=nativeTerminal})

    local function data()
        if store and type(store.data) == "table" then return store.data end
        return {}
    end

    local function snap()
        local ok, result = pcall(engine.snapshot)
        if ok and type(result) == "table" then snapshot = result
        else snapshot = {health={overall=false, error="Status unavailable: " .. tostring(result)}} end
        return snapshot
    end

    local function role()
        return tostring(config.role or snapshot.role or "colony"):lower()
    end

    local function fields()
        if type(Config.fields) == "function" then return Config.fields(role()) or {} end
        return {}
    end

    local function effective(key)
        local policy=snapshot.effectivePolicy or (type(snapshot.turn)=="table" and snapshot.turn.policy)
        if role()~="master" and type(policy)=="table" and policy[key]~=nil then return policy[key],true end
        if options.readOnly then
            if type(snapshot.settings)=="table" then return snapshot.settings[key],false end
            return nil,false
        end
        return config[key],false
    end

    local function errors()
        return newestFirst(snapshot.errors or data().errors)
    end

    local function isBusy()
        if type(engine.busy)=="function" then
            local ok,busy=pcall(engine.busy)
            if ok and busy then return true end
        end
        return snapshot.busy == true or (type(snapshot.session) == "table" and snapshot.session.busy == true)
    end

    local function setValue(key, value)
        if options.readOnly then return false,"Remote colony dashboards are read-only." end
        if hardwareKeys[key] and config[key]~=value then
            if type(engine.canEditHardware)=="function" then
                local allowed,result,reason=pcall(engine.canEditHardware,key,value)
                if not allowed or result==false then return false,tostring(reason or result) end
            else
                if isBusy() then return false,"Finish the current turn before changing transfer hardware." end
                for _,request in ipairs(list(snapshot.requests or snapshot.requestRows)) do
                    local staged=request.staged or math.max(0,(request.shipped or request.verified or request.sent or 0)-(request.imported or 0))
                    if staged>0 then return false,"Import staged deliveries before changing transfer hardware." end
                end
                if #list(snapshot.crafts)>0 then return false,"Finish pending crafts before changing PRS hardware." end
            end
        end
        local old = copy(config[key])
        local ok, accepted, err = pcall(Config.set, config, key, value)
        if not ok or accepted == false then return false, tostring(err or accepted) end
        local saved, result, reason = pcall(Config.save, config)
        if not saved or result == false then
            config[key] = old
            return false, tostring(reason or result)
        end
        self.notice = "Saved. Hardware / network changes require restart."
        return true
    end

    local function saveRoute(route)
        if options.readOnly then return false,"Remote colony dashboards are read-only." end
        for key in pairs(self.routeSelections) do
            local ok,available,reason=pcall(Devices.available,config,key,route[key],{route=route,routeId=self.routeId})
            if not ok or not available then return false,tostring(reason or available) end
        end
        if isBusy() then return false, "Wait until the current turn has finished before editing routes." end
        if type(engine.canEditRoute)=="function" then
            local ok,allowed,reason=pcall(engine.canEditRoute,route.id)
            if not ok or allowed==false then return false,tostring(reason or allowed) end
        else
            for _,request in ipairs(list(snapshot.requests or snapshot.requestRows)) do
                if tonumber(request.colonyId)==tonumber(route.id)
                    and (request.shipped or request.verified or request.sent or 0)>(request.imported or 0) then
                    return false,"This colony still has staged deliveries; import them before editing its route."
                end
            end
        end
        local routes = copy(config.colonies or {})
        local found = false
        for i, row in ipairs(routes) do
            if tonumber(row.id) == tonumber(route.id) then routes[i] = copy(route); found=true; break end
        end
        if not found then routes[#routes + 1] = copy(route) end
        return setValue("colonies", routes)
    end

    local function refreshPicker(edit,hotplug)
        if options.readOnly or not edit or edit.kind~="peripheral" then return end
        local ok,choices=pcall(Devices.choices,config,edit.field.key,edit.deviceOptions)
        if not ok then edit.choices={};edit.error="Device list unavailable: "..tostring(choices);return end
        local changed=#(edit.choices or {})~=#choices
        if not changed then
            for i,choice in ipairs(choices) do
                if choice.value~=edit.choices[i].value then changed=true;break end
            end
        end
        edit.choices=choices
        edit.currentAvailable=edit.current=="" and edit.spec.allowNone
        for _,choice in ipairs(choices) do if choice.value==edit.current then edit.currentAvailable=true;break end end
        if hotplug and changed then
            edit.value="";edit.page=1;edit.error="Devices changed. Choose from the refreshed list."
        end
    end

    local function editField(field, value, onSave, deviceOptions)
        if options.readOnly then return end
        local spec=Devices.spec(field.key,deviceOptions and deviceOptions.route~=nil)
        self.edit = {field=field, value=value == nil and "" or tostring(value), onSave=onSave, error=nil}
        if spec then
            self.edit.kind="peripheral";self.edit.spec=spec
            self.edit.current=self.edit.value;self.edit.value="";self.edit.page=1
            self.edit.deviceOptions=deviceOptions
            self.edit.choices={};refreshPicker(self.edit)
        end
        self.edit.replace = true
        lastTerminal = nil
        draw()
    end

    local function acceptPeripheral(value)
        local edit=self.edit
        if not edit or edit.kind~="peripheral" or options.readOnly then return end
        local ok,available,reason=pcall(Devices.available,config,edit.field.key,value,edit.deviceOptions)
        if not ok or not available then edit.error=tostring(reason or available);return end
        local saved,accepted,err=pcall(edit.onSave,value)
        if not saved or accepted==false then edit.error=tostring(err or accepted);return end
        if edit.deviceOptions and edit.deviceOptions.route then self.routeSelections[edit.field.key]=true end
        self.edit=nil;lastTerminal=nil
    end

    local function savePickerInput()
        local edit=self.edit
        local answer=Util.trim(edit.value)
        if answer:lower()==":q" then self.edit=nil;lastTerminal=nil;return end
        if answer=="" and edit.currentAvailable then acceptPeripheral(edit.current);return end
        if answer=="0" and edit.spec.allowNone then acceptPeripheral("");return end
        local number=tonumber(answer)
        if number and number%1==0 and number>=1 and number<=#edit.choices then acceptPeripheral(edit.choices[number].value);return end
        edit.error="Enter a listed number"..(edit.spec.allowNone and ", 0 for "..tostring(edit.spec.noneLabel or "none") or "").."."
    end

    local function saveEdit()
        local edit = self.edit
        if not edit then return end
        if edit.kind=="peripheral" then savePickerInput();return end
        local value = Util.trim(edit.value)
        local field = edit.field
        if field.type == "number" or field.type == "integer" then
            value = tonumber(value)
            if not value or value ~= value or value == math.huge or value == -math.huge then
                edit.error = "Enter a finite number."; return
            end
            if (field.type == "integer" or field.integer) and value % 1 ~= 0 then edit.error="Enter a whole number."; return end
            if field.min and value < field.min then edit.error="Minimum: " .. tostring(field.min); return end
            if field.max and value > field.max then edit.error="Maximum: " .. tostring(field.max); return end
        elseif field.type == "boolean" then
            if value == "true" or value == "on" then value = true
            elseif value == "false" or value == "off" then value = false
            else edit.error="Enter true or false."; return end
        end
        local ok, accepted, err = pcall(edit.onSave, value)
        if not ok or accepted == false then edit.error=tostring(err or accepted); return end
        self.edit = nil
        lastTerminal = nil
    end

    local function pageRows(rows, name, count)
        count = math.max(1, count)
        local pages = math.max(1, math.ceil(#rows / count))
        local page = Util.clamp(self.pages[name] or 1, 1, pages)
        self.pages[name] = page
        local out = {}
        for i=(page-1)*count+1, math.min(#rows,page*count) do out[#out+1] = rows[i] end
        return out, page, pages
    end

    local function footer(name, page, pages, middleLabel, middleAction)
        local w,h = screen.size()
        if not w or h < 8 then return end
        local left, right = math.floor(w/3), math.floor(w*2/3)
        screen.addButton(name.."_prev",1,h-1,left,h-1,"PREV",C.nav,C.text,function()
            self.pages[name]=math.max(1,page-1); draw()
        end)
        screen.addButton(name.."_middle",left+1,h-1,right,h-1,middleLabel or "REFRESH",C.navActive,C.text,function()
            if middleAction then middleAction() end
            draw()
        end)
        screen.addButton(name.."_next",right+1,h-1,w,h-1,"NEXT",C.nav,C.text,function()
            self.pages[name]=math.min(pages,page+1); draw()
        end)
    end

    local function update()
        if options.readOnly then return end
        if not updater or self.checkingUpdate or updater.checking or updater.installing then return end
        if isBusy() then self.notice="Update waits until the active turn is safely closed."; draw(); return end
        local method = updater.availableVersion and updater.install or updater.check
        if type(method) ~= "function" then return end
        self.checkingUpdate = true
        draw()
        local ok, result, reason = pcall(method)
        self.checkingUpdate = false
        if not ok or result == false then
            self.notice = "Update: " .. tostring(reason or result)
            logError("UPDATE", self.notice)
        end
        draw()
    end

    local function frame(title, status, color)
        screen.clear()
        screen.resetButtons()
        local label = "CHECK UPDATE"
        if updater and updater.installing then label="UPDATING..."
        elseif self.checkingUpdate or (updater and updater.checking) then label="CHECKING..."
        elseif updater and updater.availableVersion then
            label = (type(updater.buttonLabel)=="function" and updater.buttonLabel()) or ("UPDATE v"..tostring(updater.availableVersion))
        elseif updater and updater.checkError then label="RETRY UPDATE"
        end
        local titleName = role()=="master" and "MINECOLONIES SUPPLY MASTER" or "MINECOLONIES SUPPLY CLIENT"
        local subtitle = tostring(snapshot.colonyName or config.label or config.colonyName or (role()=="master" and "PLAYER REFINED STORAGE" or "Colony"))
            .. "  [v" .. tostring(config.PROGRAM_VERSION or config.programVersion or Config.VERSION) .. "]"
        if options.readOnly then
            local telemetry=type(snapshot.telemetry)=="table" and snapshot.telemetry or {}
            local state=tostring(telemetry.state or (snapshot.offline and "offline") or (snapshot.stale and "stale") or "waiting"):upper()
            local age=tonumber(telemetry.age)
            local sourceAge=tonumber(telemetry.sourceAge)
            if sourceAge then age=math.max(age or 0,sourceAge) end
            local freshness=age and ("Last update "..math.max(0,math.floor(age)).."s ago") or "Awaiting first update"
            local partial=snapshot.truncated or telemetry.truncated
            if type(partial)=="table" then
                local any=false;for _,value in pairs(partial) do if value==true or type(value)=="number" and value>0 then any=true;break end end;partial=any
            end
            status="COLONY #"..tostring(options.sourceId or snapshot.computerId or "?").."  "..state.."  "..freshness..(partial and "  PARTIAL" or "")
            color=state=="ONLINE" and (color or C.good) or C.warn
            subtitle=subtitle.."  REMOTE DASHBOARD"
            local countKey=({requests="requests",history="history",errors="errors",health="healthChecks"})[self.view]
            if countKey and type(snapshot.totals)=="table" and tonumber(snapshot.totals[countKey]) then
                local total=math.max(0,math.floor(snapshot.totals[countKey]))
                local shown=type(snapshot.shown)=="table" and tonumber(snapshot.shown[countKey]) or nil
                if shown then title=title.."  ["..math.max(0,math.floor(shown)).."/"..total.." reported]" end
            end
        end
        local button=options.readOnly and {id="read_only",label="READ ONLY",bg=C.nav,fg=C.dim}
            or {id="program_update",label=label,bg=updater and (updater.availableVersion or updater.checkError) and C.warn or C.navActive,action=update}
        screen.drawHeader({title=titleName,subtitle=subtitle,status=status or "",statusFg=color or C.dim,
            pageTitle=title,button=button})
        local active = (self.view=="routes" or self.view=="route" or self.view=="overrides") and "settings" or self.view
        screen.drawNav(active,tabs,nil,function(id) self.view=id; self.notice=nil; draw() end)
    end

    local function row(y, text, color, action)
        local w,h = screen.size()
        if not w or y < 5 or y > h-2 then return end
        local bg = y%2==0 and C.panel or C.bg
        screen.fillRow(y,bg)
        screen.writeAt(2,y,Util.clip(text,w-2),color or C.text,bg)
        if action then screen.addTouchArea("row_"..y,1,y,w,y,action) end
    end

    local function healthRows()
        local h = snapshot.health
        if type(h) ~= "table" then h={overall=h~=false} end
        local rows = {}
        local checks = h.checks or h.startupChecks or snapshot.checks or (#h>0 and h) or {}
        for key,check in pairs(checks) do
            if type(check) == "table" then
                local ok = check.ok == true
                local warning = tostring(check.severity or ""):lower()=="warning" or check.waiting==true
                rows[#rows+1] = {label=check.label or tostring(key),detail=textOf(check),ok=ok,
                    severity=ok and "OK" or (warning and "WARNING" or "ERROR")}
            elseif type(check) == "boolean" then
                rows[#rows+1] = {label=tostring(key),detail="",ok=check,severity=check and "OK" or "ERROR"}
            end
        end
        table.sort(rows,function(a,b) return a.label < b.label end)
        for _,message in ipairs(list(h.warnings or snapshot.warnings)) do
            rows[#rows+1]={label="Warning",detail=textOf(message),ok=false,severity="WARNING"}
        end
        for _,key in ipairs({"error","fault","reason"}) do
            local message = h[key] or snapshot[key]
            if message and tostring(message)~="" then rows[#rows+1]={label="Supply",detail=textOf(message),ok=false,severity="ERROR"} end
        end
        if h.detail and textOf(h.detail)~="" then
            local detail=textOf(h.detail)
            local duplicate=false
            for _,check in ipairs(rows) do if check.label=="Supply" and check.detail==detail then duplicate=true;break end end
            if not duplicate then
                local ok=h.overall~=false and h.ok~=false
                local warning=tostring(h.severity or ""):lower()=="warning" or h.waiting==true
                rows[#rows+1]={label="Supply",detail=detail,ok=ok,severity=ok and "OK" or (warning and "WARNING" or "ERROR")}
            end
        end
        if role()=="master" then
            for _,colony in ipairs(list(snapshot.colonies)) do
                local detail=colonyFailure(colony)
                if detail then
                    rows[#rows+1]={label=tostring(colony.label or colony.name or "Colony").." ["..tostring(colony.id or colony.colonyId or "?").."]",
                        detail=detail,ok=false,severity="ERROR"}
                end
            end
        end
        if #rows==0 then
            local ok=h.overall~=false and h.ok~=false
            rows[1]={label="Supply",detail=h.detail or (ok and "Ready" or "Check configuration and peripheral connections."),ok=ok,severity=ok and "OK" or "ERROR"}
        end
        return rows
    end

    local function drawHome()
        local healthy=true
        for _,check in ipairs(healthRows()) do if not check.ok then healthy=false; break end end
        frame("SUPPLY STATUS",snapshot.statusMessage or (healthy and "ONLINE" or "DEGRADED"),healthy and C.good or C.warn)
        local requests = list(snapshot.requests or snapshot.requestRows)
        local counts = {}
        for _,r in ipairs(requests) do local s=tostring(r.status or "requested"):lower(); counts[s]=(counts[s] or 0)+1 end
        local turn = snapshot.turn or snapshot.session
        local turnName = type(turn)=="table" and (turn.label or turn.colonyId or turn.id or turn.phase) or turn
        row(5,"Role: "..role():upper().."   Computer: "..tostring(options.sourceId or snapshot.computerId or os.getComputerID()),C.dim)
        row(6,"Current turn: "..tostring(turnName or "Waiting").."   "..tostring(snapshot.phase or ""),C.accent)
        local autoCraft,inherited=effective("autoCraftEnabled")
        local totalRequests=type(snapshot.totals)=="table" and tonumber(snapshot.totals.requests) or #requests
        totalRequests=math.max(#requests,math.floor(totalRequests or #requests))
        local requestCount=tostring(totalRequests)..(totalRequests>#requests and (" ("..#requests.." shown)") or "")
        local craftText=autoCraft==nil and "UNAVAILABLE" or (autoCraft and "ON" or "OFF")
        row(7,"Active requests: "..requestCount.."   Auto craft: "..craftText..(inherited and " (MASTER)" or ""))
        row(8,(totalRequests>#requests and "Shown rows - " or "").."Requested: "..(counts.requested or 0).."   In progress: "..(counts["in progress"] or 0).."   Crafting: "..(counts.crafting or 0))
        row(9,"Missing: "..(counts.missing or 0).."   Timed out: "..(counts["timed out"] or 0).."   Errors: "..(counts.error or 0),
            (counts.error or counts.missing or counts["timed out"]) and C.warn or C.good)
        row(10,"VERIFIED = chest checked; COMPLETE = MineColonies request gone.",C.dim)
        if self.notice then row(11,self.notice,C.warn)
        elseif options.readOnly then
            local health=type(snapshot.health)=="table" and snapshot.health or {}
            local reportedStatus=snapshot.statusMessage or health.detail or snapshot.status
            if reportedStatus then row(11,"Reported status: "..textOf(reportedStatus),healthy and C.dim or C.danger) end
        elseif role()=="master" and config.automationEnabled==false then row(11,"AUTOMATION PAUSED - existing deliveries can drain; no new supply is sent.",C.warn)
        elseif updater and updater.checkError then row(11,"Update check failed: "..tostring(updater.checkError),C.warn)
        elseif role()=="supply" and snapshot.statusMessage then row(11,textOf(snapshot.statusMessage),healthy and C.good or C.warn) end
        if role()=="master" then
            row(12,"COLONIES  (routes in SETTINGS)",C.title,function() self.view="routes"; draw() end)
            local y=13
            for _,colony in ipairs(list(snapshot.colonies or config.colonies)) do
                local label=tostring(colony.label or colony.name or "Colony").." ["..tostring(colony.id or colony.colonyId or "?").."]"
                local detail=colonyFailure(colony)
                row(y,label.." "
                    .. tostring(colony.status or colony.phase or colony.state or (colony.online==false and "OFFLINE" or "")),
                    (detail or colony.online==false) and C.warn or C.text,detail and function()
                        self.notice=label..": "..detail;self.view="health"
                        local _,h=screen.size()
                        for index,check in ipairs(healthRows()) do
                            if check.label==label then self.pages.health=math.floor((index-1)/math.max(1,h-7))+1;break end
                        end
                        draw()
                    end or nil)
                y=y+1
            end
        else
            row(12,"Master computer: "..tostring(config.masterId or "Not configured"),C.dim)
            row(13,"Delivery channel: "..tostring(config.deliveryChannel or "-"),C.accent)
            row(14,"Returns channel: "..tostring(config.returnChannel or "-"),C.accent)
        end
    end

    local function drawHealth()
        local w,h=screen.size()
        local rows,page,pages=pageRows(healthRows(),"health",h-7)
        frame("SYSTEM HEALTH  "..page.."/"..pages,"Required peripherals / protocol / transfer safety",C.dim)
        for i,check in ipairs(rows) do
            row(4+i,Util.padRight(check.label,math.min(22,math.floor(w/3))).." "..check.severity.."  "..check.detail,
                check.ok and C.good or (check.severity=="WARNING" and C.warn or C.danger))
        end
        if self.notice then row(h-2,self.notice,C.warn) end
        local reconcile=not options.readOnly and type(engine.requestReconcile)=="function" and function()
            local ok,result,err=pcall(engine.requestReconcile)
            self.notice=(ok and result~=false) and "Reconciliation queued; uncertain transfers remain reserved." or tostring(err or result)
        end or nil
        footer("health",page,pages,reconcile and "RECONCILE" or nil,reconcile)
    end

    local function drawRequests()
        local w,h=screen.size()
        local requests=list(snapshot.requests or snapshot.requestRows)
        local rows,page,pages=pageRows(requests,"requests",h-9)
        frame("ACTIVE REQUESTS  "..page.."/"..pages,"VERIFIED is staged; completion requires MineColonies acknowledgement.",C.dim)
        local wide=w>=70
        local itemWidth=math.max(8,w-(wide and 49 or 27))
        local quantityWidth=wide and 22 or 11
        row(5,Util.padRight("ITEM",itemWidth).." "..Util.padRight(wide and "REQ / VERIFIED / IMPORT" or "VERIFY/REQ",quantityWidth).." STATUS",C.dim)
        for i,r in ipairs(rows) do
            local shipped=r.shipped or r.verified or r.sent or ((r.staged or 0)+(r.imported or 0))
            local quantity=wide and (tostring(r.requested or r.count or 0).." / "..tostring(shipped).." / "..tostring(r.imported or 0))
                or (tostring(shipped).."/"..tostring(r.requested or r.count or 0))
            local item=tostring(r.displayName or r.item or r.name or r.id or "Unknown")
            row(5+i,Util.padRight(item,itemWidth).." "..Util.padRight(quantity,quantityWidth).." "..tostring(r.status or "requested"):upper(),statusColor(r.status),function()
                self.notice=item..": "..tostring(r.detail or r.message or "").."; imported "..tostring(r.imported or 0)
                draw()
            end)
        end
        if #requests==0 then row(7,"No active MineColonies requests.",C.good) end
        row(h-2,self.notice or "Requests persist until removed by MineColonies; quantities prevent duplicate supply.",C.dim)
        footer("requests",page,pages)
    end

    local function drawHistory()
        local _,h=screen.size()
        local rows,page,pages=pageRows(newestFirst(snapshot.history or data().history),"history",h-7)
        frame("TRANSFER / EVENT HISTORY  "..page.."/"..pages,"VERIFIED shipments and acknowledged completions are separate events.",C.dim)
        for i,e in ipairs(rows) do
            local kind=tostring(e.kind or e.event or e.status or "")
            local color=kind:lower():find("craft",1,true) and C.title or statusColor(kind)
            if tostring(e.direction or ""):find("RETURN",1,true) then color=C.accent end
            local context=type(e.context)=="table" and e.context or {}
            local amount=e.amount or context.amount or context.count
            row(4+i,timeOf(e.time or e.at).." "..kind.." "..tostring(e.item or context.item or "")
                ..(amount and (" x"..tostring(amount)) or "").." "..textOf(e.detail or e.message),color)
        end
        footer("history",page,pages)
    end

    local function drawErrors()
        local w,h=screen.size()
        local records=errors()
        local page=Util.clamp(self.pages.errors or 1,1,math.max(1,#records)); self.pages.errors=page
        frame("ERROR / DEBUG DETAILS  "..page.."/"..math.max(1,#records),#records.." recorded; see HEALTH for current status.",#records>0 and C.warn or C.good)
        if #records==0 then row(6,"No recorded errors.",C.good)
        else
            local e=records[page]
            row(5,timeOf(e.time or e.at).." ["..tostring(e.severity or "ERROR").."] "..tostring(e.code or ""),
                tostring(e.severity or ""):upper()=="WARNING" and C.warn or C.danger)
            local text=textOf(e).."\n"..textOf(e.context)
            if type(e.context)=="table" then
                for _,key in ipairs({"item","colonyId","requestId","shipmentId","reason","expected","observed","reported","actualDelta","beforeChest","afterChest"}) do
                    if e.context[key]~=nil then text=text.."\n"..key..": "..tostring(e.context[key]) end
                end
            end
            for i,line in ipairs(Util.wrapText(text,math.max(1,w-4))) do row(5+i,line,C.text) end
        end
        footer("errors",page,math.max(1,#records))
    end

    local function drawSettings()
        local _,h=screen.size()
        local schemas=fields()
        local rows,page,pages=pageRows(schemas,"settings",h-9)
        frame("SETTINGS  "..page.."/"..pages,options.readOnly and "Reported colony configuration; edit on its computer or the master." or "Touch a setting. Devices use numbered lists of available peripherals.",C.dim)
        for i,field in ipairs(rows) do
            local value=config[field.key]
            if options.readOnly then
                value=nil
                if type(snapshot.settings)=="table" then value=snapshot.settings[field.key] end
            end
            local current,inherited=effective(field.key)
            local label=tostring(field.label or field.key)..": "..(current==nil and (options.readOnly and "UNAVAILABLE" or "AUTO / unset") or tostring(current))
                ..(inherited and (" [MASTER; local "..tostring(value).."]") or "")
            local function saveSetting(v)
                local ok,err=setValue(field.key,v)
                if ok and inherited then self.notice="Local default saved. Effective policy is set on the master / colony route." end
                return ok,err
            end
            row(4+i,label,field.type=="boolean" and (current and C.good or C.warn) or C.text,not options.readOnly and function()
                if field.type=="boolean" then
                    local ok,err=saveSetting(not value)
                    if not ok then self.notice=err end
                    draw()
                else
                    local schema=copy(field)
                    if inherited then
                        schema.label=schema.label.." (local default)"
                        schema.description="Effective master policy: "..tostring(current)..". To change active behavior, edit this colony's route override on the master."
                    end
                    editField(schema,value,saveSetting)
                end
            end or nil)
        end
        row(h-3,self.notice or (options.readOnly and "Read-only telemetry. Master policy overrides are marked MASTER." or "Changes are saved. Optional device lists include NONE / AUTO."),C.dim)
        if role()=="master" then row(h-2,"COLONY ROUTES / OVERRIDES  >",C.accent,function() self.view="routes"; draw() end) end
        footer("settings",page,pages)
    end

    local routeFields={
        {key="id",label="Computer ID",type="integer",min=0},
        {key="label",label="Colony name",type="string"},
        {key="monitorName",label="Master colony dashboard monitor",type="string"},
        {key="deliveryChest",label="Master delivery chest peripheral",type="string"},
        {key="returnChest",label="Master return chest peripheral",type="string"},
        {key="deliveryChannel",label="Delivery Ender color code",type="string"},
        {key="returnChannel",label="Return Ender color code",type="string"},
        {key="outputDirection",label="PRS export direction",type="string"},
        {key="returnDirection",label="PRS import direction",type="string"},
    }

    local function drawRoutes()
        local _,h=screen.size()
        local rows,page,pages=pageRows(list(config.colonies),"routes",h-9)
        frame("COLONY ROUTES  "..page.."/"..pages,"Each colony needs two exclusive, physically matching Ender color channels.",C.dim)
        for i,r in ipairs(rows) do
            row(4+i,"["..tostring(r.id).."] "..tostring(r.label).."  "..tostring(r.deliveryChannel).." / "..tostring(r.returnChannel).."  Monitor: "..tostring(r.monitorName or "none"),C.text,function()
                self.route=copy(r); self.routeId=r.id;self.routeSelections={}; self.view="route"; draw()
            end)
        end
        row(h-3,self.notice or "Route edits take effect after restart; existing delivery records are preserved.",C.dim)
        row(h-2,"ADD COLONY ROUTE  >",C.accent,function()
            self.route={label="",monitorName="",deliveryChest="",returnChest="",deliveryChannel="",returnChannel="",outputDirection="west",returnDirection="west",overrides={}}
            self.routeId=nil
            self.routeSelections={}
            self.view="route"; draw()
        end)
        footer("routes",page,pages,"BACK",function() self.view="settings" end)
    end

    local function drawRoute()
        local _,h=screen.size()
        local rows,page,pages=pageRows(routeFields,"route",h-10)
        frame("EDIT COLONY ROUTE  "..page.."/"..pages,"Editing draft. SAVE validates unique computer IDs and channels.",C.dim)
        for i,f in ipairs(rows) do
            row(4+i,f.label..": "..tostring(self.route[f.key] or ""),C.text,function()
                editField(f,self.route[f.key],function(value)
                    if f.key=="id" and self.routeId and value~=self.routeId then return false,"An existing route's ID is fixed; add a route for a different computer." end
                    self.route[f.key]=value; return true
                end,{route=self.route,routeId=self.routeId})
            end)
        end
        row(h-4,self.notice or "Map the color labels to your actual Ender Chests; colors cannot be discovered.",C.dim)
        row(h-3,"PER COLONY POLICY OVERRIDES  >",C.accent,function() self.view="overrides"; draw() end)
        row(h-2,"SAVE ROUTE  >",C.good,function()
            local ok,err=saveRoute(self.route)
            if ok then self.view="routes"; self.route=nil else self.notice=err end
            draw()
        end)
        footer("route",page,pages,"CANCEL",function() self.route=nil; self.view="routes" end)
    end

    local function drawOverrides()
        local _,h=screen.size()
        local schemas,seen={},{}
        local allFields={}
        for _,r in ipairs({"master","supply"}) do
            for _,f in ipairs(Config.fields(r) or {}) do allFields[#allFields+1]=f end
        end
        for _,f in ipairs(allFields) do
            local policyKey=type(Config.isPolicyKey)=="function" and Config.isPolicyKey(f.key)
                or (type(Config.isPolicyKey)~="function" and f.key~="masterId" and (f.type=="number" or f.type=="integer" or f.type=="boolean"))
            if not seen[f.key] and policyKey then
                schemas[#schemas+1]=f; seen[f.key]=true
            end
        end
        local rows,page,pages=pageRows(schemas,"overrides",h-9)
        frame("COLONY OVERRIDES  "..page.."/"..pages,"Draft values override master policy. Empty value restores the master default.",C.dim)
        self.route.overrides=self.route.overrides or {}
        for i,f in ipairs(rows) do
            local value=self.route.overrides[f.key]
            row(4+i,f.label..": "..(value==nil and ("MASTER ("..tostring(config[f.key])..")") or tostring(value)),C.text,function()
                local editSchema=copy(f); editSchema.type="string"
                editField(editSchema,value,function(v)
                    if v=="" then self.route.overrides[f.key]=nil; return true end
                    if f.type=="number" or f.type=="integer" then
                        local n=tonumber(v)
                        if not n or n~=n or n==math.huge or n==-math.huge then return false,"Enter a finite number, or leave empty." end
                        if (f.type=="integer" or f.integer) and n%1~=0 then return false,"Enter a whole number." end
                        if f.min and n<f.min then return false,"Minimum: "..f.min end
                        if f.max and n>f.max then return false,"Maximum: "..f.max end
                        v=n
                    elseif f.type=="boolean" then
                        if v=="true" or v=="on" then v=true elseif v=="false" or v=="off" then v=false else return false,"Enter true, false, or leave empty." end
                    end
                    self.route.overrides[f.key]=v; return true
                end)
            end)
        end
        if #schemas==0 then row(6,"Policy overrides are available with: colony_master.lua route",C.dim) end
        row(h-2,"Save changes using SAVE ROUTE on the previous screen.",C.dim)
        footer("overrides",page,pages,"BACK",function() self.view="route" end)
    end

    local function pickerPages(edit,width,capacity)
        local blocks={}
        local current={{text="CURRENT"..(edit.currentAvailable and "" or " (unavailable)"),color=C.accent}}
        for _,line in ipairs(Util.wrapText(edit.current=="" and tostring(edit.spec.noneLabel or "None") or edit.current,width)) do
            current[#current+1]={text=line,color=C.accent}
        end
        blocks[#blocks+1]=current
        for index,choice in ipairs(edit.choices) do
            local prefix=tostring(index)..") "
            local block={}
            for lineIndex,line in ipairs(Util.wrapText(choice.label,math.max(1,width-#prefix))) do
                block[#block+1]={text=(lineIndex==1 and prefix or string.rep(" ",#prefix))..line,
                    color=choice.value==edit.current and C.accent or C.text,index=index}
            end
            if choice.detail and choice.detail~="" then
                for _,line in ipairs(Util.wrapText(choice.detail,math.max(1,width-2))) do
                    block[#block+1]={text="  "..line,color=C.dim,index=index}
                end
            end
            blocks[#blocks+1]=block
        end
        if #edit.choices==0 then
            local block={}
            for _,line in ipairs(Util.wrapText("No unused compatible devices. Connect a device or free its assignment, then refresh.",width)) do
                block[#block+1]={text=line,color=C.warn}
            end
            blocks[#blocks+1]=block
        end
        local pages,page={},{}
        local function finish() if #page>0 then pages[#pages+1]=page;page={} end end
        for _,block in ipairs(blocks) do
            if #block<=capacity and #page+#block>capacity then finish() end
            for _,line in ipairs(block) do
                if #page>=capacity then finish() end
                page[#page+1]=line
            end
        end
        finish()
        return pages
    end

    local function drawPicker(canvas)
        local screen=canvas or screen
        local edit=self.edit
        local w,h=screen.size()
        screen.clear();screen.resetButtons()
        if w<32 or h<16 then
            screen.drawHeader({title="SELECT PERIPHERAL",subtitle=edit.field.label,status="Computer keyboard: Escape cancels."})
            screen.writeAt(2,5,"Use the computer screen or a larger monitor.",C.warn)
            screen.addButton("picker_cancel",1,h-1,w,h,"CANCEL",C.nav,C.text,function() self.edit=nil;lastTerminal=nil;draw() end)
            return
        end
        -- The keyboard and monitor share global numbers and the same page.
        -- Fit each page on the native computer even when the monitor is larger.
        local native=nativeTerminal()
        local ok,nativeWidth,nativeHeight=pcall(native.getSize)
        local pageWidth,pageHeight=w,h
        if ok and nativeWidth>=32 and nativeHeight>=16 then
            pageWidth=math.min(pageWidth,nativeWidth);pageHeight=math.min(pageHeight,nativeHeight)
        end
        local pages=pickerPages(edit,pageWidth-4,math.max(1,pageHeight-11))
        edit.pageCount=math.max(1,#pages)
        edit.page=Util.clamp(edit.page or 1,1,edit.pageCount)
        screen.drawHeader({title="SELECT PERIPHERAL",subtitle=edit.field.label or edit.field.key,
            status="Unused "..tostring(edit.spec.kind).." devices; current selection included.",
            pageTitle="DEVICES  "..edit.page.."/"..edit.pageCount})
        for index,line in ipairs(pages[edit.page] or {}) do
            local y=4+index
            local bg=y%2==0 and C.panel or C.bg
            screen.fillRow(y,bg);screen.writeAt(3,y,line.text,line.color,bg)
            if line.index then
                local choiceNumber=line.index
                screen.addTouchArea("picker_choice_"..choiceNumber,1,y,w,y,function()
                    acceptPeripheral(edit.choices[choiceNumber].value);draw()
                end)
            end
        end
        if edit.error then
            for index,line in ipairs(Util.wrapText(edit.error,w-4)) do
                if index>2 then break end
                screen.writeAt(3,h-7+index,line,C.danger)
            end
        end
        screen.writeAt(3,h-4,"Number + Enter / touch / N,P pages / Esc cancel",C.dim)
        screen.writeAt(3,h-3,"Choice: "..edit.value.."_",C.text)
        local first,second=math.floor(w/3),math.floor(w*2/3)
        screen.addButton("picker_prev",1,h-2,first,h-2,"PREV",C.nav,C.text,function()
            edit.page=math.max(1,edit.page-1);edit.value="";draw()
        end)
        screen.addButton("picker_keep",first+1,h-2,second,h-2,"KEEP CURRENT",edit.currentAvailable and C.navActive or C.nav,edit.currentAvailable and C.text or C.dim,function()
            if edit.currentAvailable then acceptPeripheral(edit.current);draw() end
        end)
        screen.addButton("picker_next",second+1,h-2,w,h-2,"NEXT",C.nav,C.text,function()
            edit.page=math.min(edit.pageCount,edit.page+1);edit.value="";draw()
        end)
        screen.addButton(edit.spec.allowNone and "picker_none" or "picker_refresh",1,h-1,math.floor(w/2),h,
            edit.spec.allowNone and "NONE / AUTO (0)" or "REFRESH",C.navActive,C.text,function()
                if edit.spec.allowNone then acceptPeripheral("") else refreshPicker(edit,true) end
                draw()
            end)
        screen.addButton("picker_cancel",math.floor(w/2)+1,h-1,w,h,"CANCEL",C.nav,C.text,function()
            self.edit=nil;lastTerminal=nil;draw()
        end)
    end

    local function drawEdit()
        if self.edit.kind=="peripheral" then drawPicker();return end
        local w,h=screen.size()
        screen.clear(); screen.resetButtons()
        screen.drawHeader({title="EDIT SETTING",subtitle=self.edit.field.label or self.edit.field.key,
            status="Computer keyboard: Enter saves, Escape cancels.",pageTitle=""})
        local text=self.edit.value.."_"
        if #text>w-4 then text=text:sub(-(w-4)) end
        screen.fill(2,5,w-1,5,C.panel)
        screen.writeAt(3,5,text,C.text,C.panel)
        local field=self.edit.field
        local detail=field.description or ((field.min and ("Min "..field.min.."  ") or "")..(field.max and ("Max "..field.max) or ""))
        for i,line in ipairs(Util.wrapText(detail,math.max(1,w-4))) do if 6+i<h-2 then screen.writeAt(3,6+i,line,C.dim) end end
        if self.edit.error then screen.writeAt(2,h-3,self.edit.error,C.danger) end
        screen.addButton("edit_save",1,h-1,math.floor(w/2),h,"SAVE",C.navActive,C.text,function() saveEdit(); draw() end)
        screen.addButton("edit_cancel",math.floor(w/2)+1,h-1,w,h,"CANCEL",C.nav,C.text,function() self.edit=nil; lastTerminal=nil; draw() end)
    end

    draw=function()
        resolveMonitor()
        snap()
        if options.displayOnly and (not mon or monitorSizeError) then screen.resetButtons();return end
        local w,h=screen.size()
        if not w or not h then return end
        if w<24 or h<10 then
            screen.clear(); screen.resetButtons()
            screen.writeAt(1,1,"SUPPLY "..role():upper(),C.title)
            screen.writeAt(1,2,"Monitor too small.",C.warn)
            screen.writeAt(1,3,"Resize to 24 x 10+.",C.dim)
            screen.writeAt(1,4,"CLI: setup / config",C.dim)
            return
        end
        if options.readOnly and (self.view=="routes" or self.view=="route" or self.view=="overrides") then self.view="settings" end
        if self.edit then drawEdit()
        elseif self.view=="home" then drawHome()
        elseif self.view=="health" then drawHealth()
        elseif self.view=="requests" then drawRequests()
        elseif self.view=="history" then drawHistory()
        elseif self.view=="errors" then drawErrors()
        elseif self.view=="settings" then drawSettings()
        elseif self.view=="routes" then drawRoutes()
        elseif self.view=="route" then drawRoute()
        elseif self.view=="overrides" then drawOverrides() end
    end
    self.draw=draw

    function self.renderTerminal()
        if options.displayOnly then return end
        if not hasMonitor then return end
        if self.edit and self.edit.kind=="peripheral" then
            local marker={"PICKER",self.edit.field.key,self.edit.current,self.edit.value,tostring(self.edit.page),tostring(self.edit.error)}
            for _,choice in ipairs(self.edit.choices) do marker[#marker+1]=choice.value..":"..tostring(choice.detail) end
            marker=table.concat(marker,"\n")
            if marker~=lastTerminal then lastTerminal=marker;drawPicker(terminalPicker) end
            return
        end
        local lines={}
        local health=type(snapshot.health)=="table" and snapshot.health or {}
        if role()=="supply" and not options.readOnly and health.ok~=false and snapshot.statusMessage then
            lines[#lines+1]={text="Supply: "..textOf(snapshot.statusMessage),color=C.good}
        end
        for _,check in ipairs(healthRows()) do
            if not check.ok then lines[#lines+1]={text=check.severity..": "..check.label.." - "..check.detail,color=check.severity=="WARNING" and C.warn or C.danger} end
        end
        local currentErrors=errors()
        if #currentErrors>0 then
            local e=currentErrors[1]
            lines[#lines+1]={text="RECORDED "..tostring(e.severity or "ERROR"):upper().." "..timeOf(e.time or e.at)..": "..tostring(e.code or "").." "..textOf(e),
                color=tostring(e.severity or ""):upper()=="WARNING" and C.warn or C.danger}
        end
        if updater and updater.checkError then lines[#lines+1]={text="WARNING: Update check failed - "..tostring(updater.checkError),color=C.warn} end
        if self.edit then
            lines[#lines+1]={text="EDIT: "..tostring(self.edit.field.label or self.edit.field.key),color=C.title}
            lines[#lines+1]={text=self.edit.value.."_",color=C.text}
            lines[#lines+1]={text=self.edit.error or (self.edit.kind=="peripheral" and "Type a device number; Enter selects. N/P pages; Escape cancels." or "Enter saves; Escape cancels."),color=self.edit.error and C.danger or C.dim}
        end
        local content={}
        for _,line in ipairs(lines) do content[#content+1]=line.text..":"..tostring(line.color) end
        local marker=table.concat(content,"\n")
        if marker==lastTerminal then return end
        lastTerminal=marker
        SharedUI.resetTerminal(C.text,C.bg)
        for _,line in ipairs(lines) do SharedUI.setTerminalColor(line.color); print(line.text) end
        SharedUI.setTerminalColor(C.text)
    end

    function self.handleEvent(event, a,b,c)
        if type(event)=="table" then return self.handleEvent(table.unpack(event)) end
        if options.displayOnly and (event=="char" or event=="paste" or event=="key" or event=="mouse_click" or event=="term_resize") then return false end
        if event=="monitor_resize" or event=="term_resize" or event=="peripheral" or event=="peripheral_detach" then
            if event=="peripheral" or event=="peripheral_detach" then refreshPicker(self.edit,true) end
            mon=nil; lastTerminal=nil; draw(); return false
        end
        if self.edit and not options.readOnly then
            if event=="char" then
                local command=tostring(a):lower()
                if self.edit.kind=="peripheral" and (command=="n" or command=="p") then
                    self.edit.page=Util.clamp(self.edit.page+(command=="n" and 1 or -1),1,self.edit.pageCount or 1)
                    self.edit.value=""
                else
                    if self.edit.replace then self.edit.value=""; self.edit.replace=false end
                    self.edit.value=self.edit.value..tostring(a)
                end
            elseif event=="paste" then
                if self.edit.replace then self.edit.value=""; self.edit.replace=false end
                self.edit.value=self.edit.value..tostring(a):gsub("[\r\n]","")
            elseif event=="key" then
                if a==keys.enter or a==keys.numPadEnter then saveEdit()
                elseif a==keys.escape then self.edit=nil; lastTerminal=nil
                elseif self.edit.kind=="peripheral" and (a==keys.left or a==keys.pageUp or a==keys.right or a==keys.pageDown) then
                    local delta=(a==keys.left or a==keys.pageUp) and -1 or 1
                    self.edit.page=Util.clamp(self.edit.page+delta,1,self.edit.pageCount or 1);self.edit.value=""
                elseif a==keys.backspace then self.edit.value=self.edit.value:sub(1,-2); self.edit.replace=false
                elseif a==keys.delete then self.edit.value=""; self.edit.replace=false
                else return false end
            elseif event~="monitor_touch" and event~="mouse_click" then return false end
            if event=="char" or event=="paste" or event=="key" then draw(); self.renderTerminal(); return true end
        end
        local x,y
        if event=="monitor_touch" and hasMonitor and not monitorSizeError and (monName and a==monName or not monName and not options.displayOnly) then x,y=b,c
        elseif event=="mouse_click" and not hasMonitor then x,y=b,c end
        if x and y then
            local button=screen.hitButton(x,y)
            if button and type(button.action)=="function" then button.action(); self.renderTerminal(); return true end
        end
        if event=="char" and not self.edit and not options.readOnly then
            local selected=tonumber(a)
            if selected and tabs[selected] then self.view=tabs[selected].id; self.notice=nil; draw(); return true end
        end
        return false
    end

    function self.refresh() draw(); self.renderTerminal() end
    return self
end

return M
