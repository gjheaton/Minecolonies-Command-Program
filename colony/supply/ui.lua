-- MineColonies Control Suite v3 - Supply monitor/terminal UI
local SharedUI = require("colony.lib.ui")
local Util = require("colony.lib.util")
local M = {}

local C = SharedUI.theme()

function M.new(config, store, cluster, transfer, engine, updater)
    local self = {
        view = "home",
        historyPage = 1,
        errorPage = 1,
    }

    local monitorUI = SharedUI.newMonitor({
        getMonitor = function() return transfer.monitor end,
        onFailure = function(err) store.log("MONITOR ERROR: " .. tostring(err)) end,
    })

    local tabs = {
        {id="home", label="HOME"},
        {id="health", label="HEALTH"},
        {id="history", label="HISTORY"},
        {id="errors", label="ERRORS"},
        {id="settings", label="SETTINGS"},
    }

    local function resolveMonitor()
        local mon
        if config.monitorName and peripheral.isPresent(config.monitorName) then
            local ok = pcall(function() mon = peripheral.wrap(config.monitorName) end)
            if not ok then mon = nil end
        else
            mon = peripheral.find("monitor")
        end
        transfer.monitor = mon
        if mon then
            pcall(mon.setTextScale, config.monitorTextScale or 0.5)
            return true
        end
        return false
    end

    local function statusColor(ok)
        return ok and C.good or C.danger
    end

    local function drawFrame(title, status, statusFg)
        monitorUI.resetButtons()
        monitorUI.clear()
        local w = monitorUI.size()
        monitorUI.drawHeader({
            title="MINECOLONIES SUPPLY MANAGER",
            subtitle=(transfer.colonyName or "Unknown Colony") .. "  [SUPPLY-v" .. config.PROGRAM_VERSION .. "]",
            status=status or title, statusFg=statusFg or C.dim, statusBg=C.panel,
            button=updater.availableVersion and {
                id="program_update", label=updater.buttonLabel(), bg=C.navActive, fg=C.navText,
                action=function() updater.install() end,
            } or nil,
        })
        monitorUI.center(4, title, C.title, C.bg)
        monitorUI.drawNav(self.view, tabs, nil, function(id)
            self.view = id
            self.draw()
        end)
        return w
    end

    local function drawHome()
        local h = engine.healthSnapshot()
        local cs = h.cluster
        local w, mh = monitorUI.size()
        drawFrame("SUPPLY STATUS",
            (h.overall and "ONLINE" or "DEGRADED") ..
            "  |  " .. tostring(cs.role) ..
            "  |  Turn " .. tostring(cs.turnId or "-"),
            h.overall and C.good or C.warn)

        local y = 5
        local function line(label, value, color)
            monitorUI.fillRow(y, C.bg)
            monitorUI.writeAt(2, y, Util.padRight(label, 18), C.dim, C.bg)
            monitorUI.writeAt(21, y, Util.clip(value, math.max(1,w-21)), color or C.text, C.bg)
            y = y + 1
        end

        line("Colony", transfer.colonyName, C.info)
        line("Computer", tostring(cs.id) .. " / " .. tostring(cs.role), C.info)
        line("Cluster", cs.ok and ("ONLINE [" .. table.concat(cs.activeIds,",") .. "]") or tostring(cs.fault),
            cs.ok and C.good or C.danger)
        line("Master", tostring(cs.masterId or "-"), C.text)
        line("PRS Turn", tostring(cs.turnId or "-"), cs.turnId == cs.id and C.good or C.dim)
        line("PRS", Util.healthWord(h.playerRS), statusColor(h.playerRS))
        line("CRS", Util.healthWord(h.colonyRS), statusColor(h.colonyRS))
        line("Transfer Chest", Util.healthWord(h.transferChest), statusColor(h.transferChest))
        line("Startup", h.startupReady and "PASSED" or "BLOCKED", statusColor(h.startupReady))
        line("AutoCraft", h.autoCraftEnabled and "ON" or "OFF", h.autoCraftEnabled and C.good or C.warn)
        line("Overstock", h.overstockEnabled and "ON" or "OFF", h.overstockEnabled and C.good or C.dim)
        line("Last Scan", tostring(h.lastScanText), C.dim)

        if y <= mh-2 then
            monitorUI.fillRow(y, C.panel)
            monitorUI.center(y,
                "Active " .. engine.stats.active ..
                " | Waiting " .. engine.stats.waiting ..
                " | Craft " .. engine.stats.crafting ..
                " | Blocked " .. engine.stats.blocked ..
                " | Errors " .. engine.stats.errors,
                engine.stats.errors > 0 and C.warn or C.text, C.panel)
        end
    end

    local function drawHealth()
        local h = engine.healthSnapshot()
        local w = drawFrame("HEALTH CHECKS", h.overall and "ONLINE" or "DEGRADED", h.overall and C.good or C.warn)
        local rows = {
            {"Colony integrator", h.colony, transfer.colonyName},
            {"Player RS (PRS)", h.playerRS, transfer.playerBridgeName or "?"},
            {"Colony RS (CRS)", h.colonyRS, transfer.colonyBridgeName or "?"},
            {"Warehouse external", h.warehouse, h.warehouse and "external storage online" or "not detected"},
            {"Transfer chest", h.transferChest, transfer.transferChestName or "?"},
            {"Cluster link", h.cluster.ok, h.cluster.ok and table.concat(h.cluster.activeIds,",") or h.cluster.fault},
            {"Startup suite", h.startupReady, h.startupReady and "all required checks passed" or "blocked"},
            {"PRS desync", not (h.desync and h.desync.suspected), h.desync and h.desync.detail or "not checked"},
            {"Pending transfer", h.pending == nil, h.pending and ("PENDING " .. tostring(h.pending.direction) .. " " .. tostring(h.pending.item)) or "none"},
        }
        local y = 5
        for _, row in ipairs(rows) do
            monitorUI.fillRow(y, (y%2==0) and C.panel or C.bg)
            monitorUI.writeAt(2,y,Util.padRight(row[1],20),C.dim,(y%2==0) and C.panel or C.bg)
            monitorUI.writeAt(23,y,row[2] and "OK" or "FAIL",row[2] and C.good or C.danger,(y%2==0) and C.panel or C.bg)
            monitorUI.writeAt(30,y,Util.clip(row[3] or "",math.max(1,w-30)),C.text,(y%2==0) and C.panel or C.bg)
            y=y+1
        end

        local checks = h.startupChecks or {}
        for _, id in ipairs({"functions","pending","chest_empty","movement","desync","cluster"}) do
            local c = checks[id]
            if c and y < select(2,monitorUI.size()) then
                monitorUI.fillRow(y,C.bg)
                monitorUI.writeAt(2,y,Util.padRight("Startup "..id,20),C.dim,C.bg)
                monitorUI.writeAt(23,y,c.ok and "OK" or "FAIL",c.ok and C.good or (c.severity=="WARNING" and C.warn or C.danger),C.bg)
                monitorUI.writeAt(30,y,Util.clip(c.detail or "",math.max(1,w-30)),C.text,C.bg)
                y=y+1
            end
        end
    end

    local function pagedRows(data, page, rowsPerPage)
        rowsPerPage = math.max(1,rowsPerPage)
        local pages = math.max(1,math.ceil(#data/rowsPerPage))
        page = math.max(1,math.min(page,pages))
        local out = {}
        local start = (page-1)*rowsPerPage+1
        for i=start,math.min(#data,start+rowsPerPage-1) do out[#out+1]=data[i] end
        return out,pages,page
    end

    local function drawHistory()
        local w,h = monitorUI.size()
        local rows,pages,page = pagedRows(store.data.history or {},self.historyPage,math.max(1,h-7))
        self.historyPage=page
        drawFrame("TRANSFER / EVENT HISTORY  " .. page .. "/" .. pages,"Newest first",C.dim)
        local y=5
        for _,e in ipairs(rows) do
            local text = tostring(e.time or "--:--:--") .. " " ..
                tostring(e.kind or "") .. " " .. tostring(e.direction or "") .. " " ..
                tostring(e.item or "") .. (e.amount and (" x"..tostring(e.amount)) or "") ..
                (e.detail and (" - "..tostring(e.detail)) or "")
            monitorUI.fillRow(y,(y%2==0) and C.panel or C.bg)
            monitorUI.writeAt(2,y,Util.clip(text,w-2),C.text,(y%2==0) and C.panel or C.bg)
            y=y+1
        end
        if h>=2 then
            monitorUI.addButton("hist_prev",1,h-1,math.floor(w/3),h-1,"PREV",C.nav,C.navText,function()
                self.historyPage=math.max(1,self.historyPage-1); self.draw()
            end)
            monitorUI.addButton("hist_refresh",math.floor(w/3)+1,h-1,math.floor(2*w/3),h-1,"REFRESH",C.navActive,C.navText,function()
                self.draw()
            end)
            monitorUI.addButton("hist_next",math.floor(2*w/3)+1,h-1,w,h-1,"NEXT",C.nav,C.navText,function()
                self.historyPage=math.min(pages,self.historyPage+1); self.draw()
            end)
        end
    end

    local function errorReason(e)
        local context = type(e) == "table" and e.context or nil
        if type(context) ~= "table" then return nil end

        local parts = {}

        local function add(label, value)
            if value == nil then return end
            local text = tostring(value)
            if text == "" then return end
            parts[#parts + 1] = (label and (label .. ": ") or "") .. text
        end

        add(nil, context.reason)
        add(nil, context.detail)
        add(nil, context.error)

        if type(context.checks) == "table" then
            local ids = {}
            for id in pairs(context.checks) do ids[#ids + 1] = tostring(id) end
            table.sort(ids)
            for _, id in ipairs(ids) do
                local check = context.checks[id]
                if type(check) == "table" and check.ok ~= true then
                    add(id, check.detail or check.reason or check.message)
                end
            end
        end

        if type(context.extra) == "table" then
            add(nil, context.extra.detail)
            add("CRS error", context.extra.crsError)
        end

        if #parts == 0 then
            add("Request", context.requestId)
            add("Item", context.item)
        end

        if #parts == 0 then return nil end
        return table.concat(parts, " | ")
    end

    local function drawErrors()
        local w,h = monitorUI.size()
        local errors = store.data.errors or {}
        local pages = math.max(1, #errors)
        self.errorPage = math.max(1, math.min(self.errorPage, pages))

        drawFrame(
            "ERROR / DEBUG DETAILS  " .. tostring(self.errorPage) .. "/" .. tostring(pages),
            #errors > 0 and (tostring(#errors) .. " recorded") or "No recorded errors",
            #errors > 0 and C.warn or C.good
        )

        local y = 5
        local bottom = math.max(5, h - 2)

        if #errors == 0 then
            monitorUI.center(y + 1, "No recorded errors.", C.good, C.bg)
        else
            local e = errors[self.errorPage]
            local header = tostring(e.time or "--:--:--") ..
                "  [" .. tostring(e.severity or "ERROR") .. "]"
            monitorUI.fillRow(y, C.panel)
            monitorUI.writeAt(
                2, y, Util.clip(header, math.max(1, w - 2)),
                e.severity == "WARNING" and C.warn or C.danger, C.panel)
            y = y + 1

            monitorUI.fillRow(y, C.bg)
            monitorUI.writeAt(2, y, "Code: " .. tostring(e.code or "ERROR"), C.title, C.bg)
            y = y + 1

            local function drawWrapped(label, text, color)
                if y > bottom or text == nil or tostring(text) == "" then return end
                monitorUI.fillRow(y, C.bg)
                monitorUI.writeAt(2, y, label, C.dim, C.bg)
                y = y + 1

                local width = math.max(8, w - 4)
                local lines = Util.wrapText(tostring(text), width)
                for _, line in ipairs(lines) do
                    if y > bottom then break end
                    monitorUI.fillRow(y, C.bg)
                    monitorUI.writeAt(3, y, Util.clip(line, width), color or C.text, C.bg)
                    y = y + 1
                end
            end

            drawWrapped("Message:", e.message, C.text)
            drawWrapped("Reason:", errorReason(e) or "No additional reason recorded.", C.warn)
        end

        monitorUI.addButton(
            "err_prev", 1, h - 1, math.floor(w / 4), h - 1, "PREV",
            C.nav, C.navText,
            function()
                self.errorPage = math.max(1, self.errorPage - 1)
                self.draw()
            end
        )
        monitorUI.addButton(
            "err_refresh", math.floor(w / 4) + 1, h - 1,
            math.floor(w / 2), h - 1, "REFRESH",
            C.navActive, C.navText,
            function() self.draw() end
        )
        monitorUI.addButton(
            "err_clear", math.floor(w / 2) + 1, h - 1,
            math.floor(3 * w / 4), h - 1, "CLEAR",
            C.warn, C.navText,
            function()
                store.clearErrors()
                self.errorPage = 1
                self.draw()
            end
        )
        monitorUI.addButton(
            "err_next", math.floor(3 * w / 4) + 1, h - 1,
            w, h - 1, "NEXT",
            C.nav, C.navText,
            function()
                self.errorPage = math.min(math.max(1, #errors), self.errorPage + 1)
                self.draw()
            end
        )
    end

    local function drawSettings()
        local w = drawFrame("SETTINGS","Touch to toggle",C.dim)
        local y=6
        local over = store.data.settings.overstockEnabled==true
        monitorUI.addButton("toggle_overstock",2,y,w-1,y+1,
            "OVERSTOCK RETURN: " .. (over and "ON" or "OFF"),
            over and C.good or C.nav,C.navText,function()
                store.data.settings.overstockEnabled = not over
                store.save(); self.draw()
            end)
        y=y+3
        local craft = store.data.settings.autoCraftEnabled==true
        monitorUI.addButton("toggle_craft",2,y,w-1,y+1,
            "AUTOCRAFT: " .. (craft and "ON" or "OFF"),
            craft and C.good or C.nav,C.navText,function()
                store.data.settings.autoCraftEnabled = not craft
                store.save(); self.draw()
            end)
        y=y+3
        monitorUI.center(y,"Default item keep: " .. tostring(config.defaultItemKeepStacks) .. " stacks",C.text,C.bg)
        y=y+1
        monitorUI.center(y,"Default building keep: " .. tostring(config.defaultBuildingKeepCount) .. " items",C.text,C.bg)
        y=y+2
        monitorUI.center(y,"Per-item overrides: /colony/supply_v3_state.txt -> settings.overstockKeep",C.dim,C.bg)
    end

    function self.draw()
        if not transfer.monitor then resolveMonitor() end
        if not transfer.monitor then return false end
        if self.view=="home" then drawHome()
        elseif self.view=="health" then drawHealth()
        elseif self.view=="history" then drawHistory()
        elseif self.view=="errors" then drawErrors()
        elseif self.view=="settings" then drawSettings()
        end
        return true
    end

    function self.renderTerminal()
        local h = engine.healthSnapshot()
        local cs = h.cluster
        SharedUI.resetTerminal(colors.white,colors.black)
        print("MineColonies Supply Manager v" .. config.PROGRAM_VERSION)
        print("Control Suite: v" .. config.SUITE_VERSION)
        print("Colony: " .. tostring(transfer.colonyName or "Unknown Colony"))

        SharedUI.setTerminalColor(h.overall and colors.lime or colors.orange)
        print("HEALTH:      " .. (h.overall and "ONLINE" or "DEGRADED"))

        SharedUI.setTerminalColor(colors.white)
        print("Cluster:     " .. (cs.ok and "ONLINE" or "ERROR") ..
            " [" .. table.concat(cs.activeIds or {},",") .. "]")
        print("Role:        " .. tostring(cs.role) .. "  Master: " .. tostring(cs.masterId or "-"))
        print("PRS turn:    " .. tostring(cs.turnId or "-"))
        print("PRS:         " .. Util.healthWord(h.playerRS) .. " [" .. tostring(transfer.playerBridgeName or "?") .. "]")
        print("CRS:         " .. Util.healthWord(h.colonyRS) .. " [" .. tostring(transfer.colonyBridgeName or "?") .. "]")
        print("Transfer:    " .. Util.healthWord(h.transferChest) .. " [" .. tostring(transfer.transferChestName or "?") .. "]")
        print("Startup:     " .. (h.startupReady and "PASSED" or "BLOCKED"))
        print("AutoCraft:   " .. (h.autoCraftEnabled and "ON" or "OFF"))
        print("Overstock:   " .. (h.overstockEnabled and "ON" or "OFF"))

        if not cs.ok then
            SharedUI.setTerminalColor(colors.red)
            print("ERROR:       " .. tostring(cs.fault))
        elseif h.pending then
            SharedUI.setTerminalColor(colors.red)
            print("ERROR:       Pending " .. tostring(h.pending.direction) .. " " .. tostring(h.pending.item))
        elseif #(h.errors or {}) > 0 then
            local e = h.errors[1]
            SharedUI.setTerminalColor(e.severity=="WARNING" and colors.orange or colors.red)
            print(tostring(e.severity or "ERROR") .. ":     " .. tostring(e.code or "") .. " - " .. tostring(e.message or ""))
        elseif h.desync and h.desync.suspected then
            SharedUI.setTerminalColor(colors.orange)
            print("WARNING:     " .. tostring(h.desync.detail or "possible PRS desync"))
        end

        local updateLine,updateColor=updater.terminalStatus()
        SharedUI.setTerminalColor(updateColor)
        print("UPDATE:      " .. tostring(updateLine))
        SharedUI.setTerminalColor(colors.white)
        print("Suite source: " .. tostring(updater.sourceLabel()))
        print(string.rep("-",50))
    end

    function self.eventLoop()
        resolveMonitor()
        self.draw()
        while true do
            local ev,a,b,c = os.pullEvent()
            if ev=="monitor_touch" and transfer.monitor then
                local okName,name=pcall(peripheral.getName,transfer.monitor)
                if okName and a==name then
                    local button=monitorUI.hitButton(b,c)
                    if button and type(button.action)=="function" then pcall(button.action) end
                end
            elseif ev=="peripheral" or ev=="peripheral_detach" then
                resolveMonitor()
                self.draw()
            end
        end
    end

    return self
end

return M
