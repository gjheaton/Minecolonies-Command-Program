-- The master owns one control display and independent, read-only colony
-- dashboards. A dashboard consumes cached telemetry; it never queries PRS.
local Config=require("colony.network.config")
local UI=require("colony.network.ui")
local Util=require("colony.lib.util")
local M={}

local function copy(value)
    if type(value)~="table" then return value end
    local out={};for key,child in pairs(value) do out[key]=copy(child) end;return out
end

function M.new(config,store,engine,io,updater,telemetry)
    local self={panels={}}
    local display=Config.DISPLAY or {blocksWide=5,blocksHigh=3,textScale=.5}
    local fixedScale=display.textScale or .5
    local primaryBinding=config.monitorName
    local primaryIO={monitor=function()
        local monitor,name=io.monitor()
        -- If no main monitor is named, discovery must never borrow a monitor
        -- assigned to a colony. The main controls can use the terminal.
        if config.role=="master" and (not config.monitorName or config.monitorName=="") then
            for _,route in ipairs(config.colonies or {}) do
                if name and route.monitorName==name then return nil,nil end
            end
        end
        return monitor,name
    end}
    self.primary=UI.new(config,store,engine,primaryIO,updater,{expectedSize=display,fixedTextScale=fixedScale})

    local function waiting(route,reason)
        return {role="supply",computerId=route.id,colonyName=route.label or ("Colony "..tostring(route.id)),
            requests={},colonies={},history={},errors={},settings={},
            health={ok=false,connected=false,detail=reason or "Awaiting first colony telemetry update"},
            telemetry={state="waiting",offline=true},offline=true}
    end

    local function refreshSnapshot(panel)
        local received
        if telemetry and type(telemetry.get)=="function" then
            local ok,value=pcall(telemetry.get,panel.route.id)
            if ok and type(value)=="table" then received=copy(value) end
        end
        panel.snapshot=received or waiting(panel.route)
        -- Reset to defaults each time so fields omitted by a later report do
        -- not retain an unrelated client's values. The UI keeps its own pages.
        local reported=type(panel.snapshot.settings)=="table" and panel.snapshot.settings or {}
        local defaults=Config.defaults("supply")
        for key in pairs(panel.config) do panel.config[key]=nil end
        for key,value in pairs(defaults) do panel.config[key]=copy(value) end
        for _,field in ipairs(Config.fields("supply")) do
            if type(reported[field.key])==field.type then panel.config[field.key]=reported[field.key] end
        end
        panel.config.role="supply"
        panel.config.label=panel.snapshot.colonyName or panel.route.label
        panel.config.masterId=tonumber(panel.snapshot.masterId) or os.getComputerID()
        panel.config.deliveryChannel=reported.deliveryChannel or panel.route.deliveryChannel
        panel.config.returnChannel=reported.returnChannel or panel.route.returnChannel
        panel.config.monitorTextScale=fixedScale
        panel.config.programVersion=panel.snapshot.programVersion or Config.VERSION
        panel.snapshot.computerId=panel.route.id
        return panel.snapshot
    end

    local function clearUnassigned(name)
        if type(name)~="string" or name=="" then return end
        -- A former dashboard can become the primary display or be reassigned
        -- to another colony in the same save. Its new owner must keep control.
        if name==config.monitorName then return end
        for _,route in ipairs(config.colonies or {}) do if route.monitorName==name then return end end
        local ok,mon=pcall(io.monitor,name)
        if not ok or not mon then return end
        pcall(function()
            mon.setTextScale(fixedScale)
            local w,h=mon.getSize()
            mon.setBackgroundColor(colors.black);mon.setTextColor(colors.orange);mon.clear()
            mon.setCursorPos(1,1);mon.write(Util.clip("COLONY DISPLAY UNASSIGNED",w))
            if h>=2 then mon.setCursorPos(1,2);mon.write(Util.clip("Assign this monitor in master SETTINGS / COLONY ROUTES.",w)) end
        end)
    end

    local function syncPanels(redraw)
        local active,names={},{}
        local changed=primaryBinding~=config.monitorName
        primaryBinding=config.monitorName
        if config.role=="master" then
            for _,route in ipairs(config.colonies or {}) do
                local name=route.monitorName
                if type(name)=="string" and name~="" and name~=config.monitorName and not names[name] then
                    local id=tostring(route.id)
                    active[id]=true;names[name]=true
                    local panel=self.panels[id]
                    if not panel then
                        changed=true
                        panel={route=route,config=Config.defaults("supply"),monitorName=name}
                        panel.options={readOnly=true,displayOnly=true,monitorName=name,sourceId=route.id,
                            expectedSize=display,fixedTextScale=fixedScale}
                        local remoteEngine={snapshot=function() return refreshSnapshot(panel) end,busy=function() return false end}
                        local remoteIO={monitor=function() return io.monitor(panel.route.monitorName) end}
                        -- No shared journal or updater is exposed to a remote
                        -- panel. Its controls only change local view state.
                        panel.ui=UI.new(panel.config,{data={}},remoteEngine,remoteIO,nil,panel.options)
                        self.panels[id]=panel
                    elseif panel.monitorName~=name then
                        changed=true
                        clearUnassigned(panel.monitorName)
                    end
                    panel.route=route;panel.monitorName=name
                    panel.options.monitorName=name;panel.options.sourceId=route.id
                end
            end
        end
        for id,panel in pairs(self.panels) do
            if not active[id] then clearUnassigned(panel.monitorName);self.panels[id]=nil;changed=true end
        end
        if changed and redraw then
            -- Event-driven rebinding must repaint immediately, including a
            -- terminal primary that can now reclaim a single free monitor.
            pcall(self.primary.draw)
            for _,panel in pairs(self.panels) do
                local ok,err=pcall(panel.ui.draw)
                panel.drawError=not ok and tostring(err) or nil
            end
        end
    end

    function self.draw()
        syncPanels()
        self.primary.draw()
        -- Configuration order gives predictable rendering and diagnostics.
        for _,route in ipairs(config.colonies or {}) do
            local panel=self.panels[tostring(route.id)]
            if panel then
                local ok,err=pcall(panel.ui.draw)
                panel.drawError=not ok and tostring(err) or nil
            end
        end
    end

    function self.renderTerminal() self.primary.renderTerminal() end

    function self.handleEvent(event,a,b,c)
        if type(event)=="table" then return self.handleEvent(table.unpack(event)) end
        syncPanels(true)
        if event=="monitor_touch" then
            for _,panel in pairs(self.panels) do
                if panel.monitorName==a then return panel.ui.handleEvent(event,a,b,c) end
            end
            local consumed=self.primary.handleEvent(event,a,b,c)
            syncPanels(true)
            return consumed
        end
        if event=="monitor_resize" or event=="peripheral" or event=="peripheral_detach" then
            local consumed=self.primary.handleEvent(event,a,b,c)
            for _,panel in pairs(self.panels) do
                if panel.monitorName==a then panel.ui.handleEvent(event,a,b,c) end
            end
            return consumed
        end
        -- Keyboard, paste, terminal mouse, and terminal resize events belong
        -- exclusively to the main controls. Remote dashboards have no editor.
        local consumed=self.primary.handleEvent(event,a,b,c)
        syncPanels(true)
        return consumed
    end

    function self.refresh() self.draw();self.renderTerminal() end
    syncPanels()
    return self
end

return M
