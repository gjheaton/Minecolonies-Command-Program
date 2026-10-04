-- MineColonies Control Suite v3 - Supply monitor/terminal UI
local SharedUI = require("colony.lib.ui")
local Util = require("colony.lib.util")
local M = {}

local C = SharedUI.theme()

function M.new(config, store, cluster, transfer, engine, updater)
    local self = {
        view = "home",
        historyPage = 1,
        requestPage = 1,
        errorPage = 1,
        checkingUpdate = false,
        overridePage = 1,
        overrideItem = nil,
        overrideDraft = nil,
        overrideDraftName = nil,
    }

    local monitorUI = SharedUI.newMonitor({
        getMonitor = function() return transfer.monitor end,
        onFailure = function(err) store.log("MONITOR ERROR: " .. tostring(err)) end,
    })

    local tabs = {
        {id="home", label="HOME"},
        {id="health", label="HEALTH"},
        {id="requests", label="REQUESTS"},
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

    local function requestStatusColor(status)
        status = tostring(status or ""):upper()
        if status == "MISSING"
            or status == "ERROR"
            or status == "FAILED"
            or status == "BLOCKED"
            or status == "ACK STALLED"
            or status == "PRS DESYNC" then
            return C.danger
        end
        if status == "RS STALE"
            or status == "PRS SUSPECT" then
            return C.warn
        end
        if status == "IN PROGRESS" then
            return C.good
        end
        if status == "CRS RECEIVED"
            or status == "CRS REFRESHED"
            or status:find("WAIT", 1, true)
            or status:find("VERIFY", 1, true) then
            return colors.lightBlue
        end
        return C.text
    end

    local function drawFrame(title, status, statusFg)
        monitorUI.resetButtons()
        monitorUI.clear()
        local w = monitorUI.size()
        local updateLabel
        local updateBg
        if self.checkingUpdate then
            updateLabel = "CHECKING..."
            updateBg = C.nav
        elseif updater.availableVersion then
            updateLabel =
                updater.buttonLabel()
                or ("UPDATE v" .. tostring(updater.availableVersion))
            updateBg = C.warn
        else
            updateLabel = "CHECK UPDATE"
            updateBg = C.navActive
        end

        monitorUI.drawHeader({
            title="MINECOLONIES SUPPLY MANAGER",
            subtitle=(transfer.colonyName or "Unknown Colony") .. "  [SUPPLY-v" .. config.PROGRAM_VERSION .. "]",
            status=status or title, statusFg=statusFg or C.dim, statusBg=C.panel,
            button={
                id="program_update",
                label=updateLabel,
                bg=updateBg,
                fg=C.navText,
                action=function()
                    if self.checkingUpdate then return end

                    if updater.availableVersion then
                        updater.install()
                        return
                    end

                    self.checkingUpdate = true
                    self.draw()
                    pcall(updater.check)
                    self.checkingUpdate = false
                    self.draw()
                end,
            },
        })
        monitorUI.center(4, title, C.title, C.bg)
        local navView = (self.view == "overrides" or self.view == "override_edit")
            and "settings" or self.view
        monitorUI.drawNav(navView, tabs, nil, function(id)
            self.view = id
            self.draw()
        end)
        return w
    end

    local function drawHome()
        local h = engine.healthSnapshot()
        local cs = h.cluster
        local w, mh = monitorUI.size()

        local function colonyNameFor(id)
            if id == nil then return "-" end
            local names = cs.memberNames or {}
            return tostring(
                names[tostring(id)]
                or names[tonumber(id)]
                or ("Computer " .. tostring(id))
            )
        end

        local turnName = colonyNameFor(cs.turnId)
        drawFrame(
            "SUPPLY STATUS",
            (h.overall and "ONLINE" or "DEGRADED") ..
                "  |  " .. tostring(cs.role) ..
                "  |  Turn " .. turnName,
            h.overall and C.good or C.warn
        )

        -- The upper status area is intentionally split into two columns.
        -- Left: this computer / transfer state.
        -- Right: live cluster membership using colony names.
        local split = math.max(40, math.floor(w * 0.57))
        split = math.min(split, math.max(22, w - 24))
        local rightX = math.min(w, split + 2)
        local leftValueX = math.min(split, 16)
        local leftValueWidth = math.max(1, split - leftValueX)

        local y = 5
        local function line(label, value, color)
            monitorUI.fill(1, y, split, y, C.bg, C.text)
            monitorUI.writeAt(
                2, y,
                Util.padRight(label, math.max(1, leftValueX - 3)),
                C.dim, C.bg
            )
            monitorUI.writeAt(
                leftValueX, y,
                Util.clip(tostring(value or ""), leftValueWidth),
                color or C.text, C.bg
            )
            y = y + 1
        end

        -- Right-hand cluster member list.
        if rightX <= w then
            monitorUI.fill(rightX, 5, w, 5, C.panel, C.title)
            monitorUI.center(
                5, "CLUSTER COLONIES", C.title, C.panel, rightX, w
            )

            local ry = 6
            for _, member in ipairs(cs.members or {}) do
                if ry >= mh then break end
                local memberId = tonumber(member.id)
                local memberColor = C.text
                if memberId == tonumber(cs.turnId) then
                    memberColor = C.good
                elseif memberId == tonumber(cs.masterId) then
                    memberColor = C.info
                end

                monitorUI.fill(rightX, ry, w, ry, C.bg, C.text)
                monitorUI.writeAt(
                    rightX + 1, ry,
                    Util.clip(
                        "(" .. tostring(member.id) .. ") " ..
                            tostring(member.name or colonyNameFor(member.id)),
                        math.max(1, w - rightX)
                    ),
                    memberColor, C.bg
                )
                ry = ry + 1
            end
        end

        line("Colony", transfer.colonyName, C.info)
        line("Computer", tostring(cs.id) .. " / " .. tostring(cs.role), C.info)
        line(
            "Cluster",
            cs.ok and ("ONLINE [" .. table.concat(cs.activeIds,",") .. "]")
                or tostring(cs.fault),
            cs.ok and C.good or C.danger
        )
        line("Master", colonyNameFor(cs.masterId), C.info)
        line(
            "PRS Turn",
            colonyNameFor(cs.turnId),
            cs.turnId == cs.id and C.good or C.dim
        )
        line("PRS", Util.healthWord(h.playerRS), statusColor(h.playerRS))
        line("CRS", Util.healthWord(h.colonyRS), statusColor(h.colonyRS))
        line(
            "Transfer Chest",
            Util.healthWord(h.transferChest),
            statusColor(h.transferChest)
        )

        local movementCheck =
            h.startupChecks and h.startupChecks.movement or nil
        local startupWaiting =
            not h.startupReady
            and type(movementCheck) == "table"
            and movementCheck.severity == "WAITING"
        local waitingDetail =
            startupWaiting and tostring(movementCheck.detail or "") or ""
        local startupWaitingLabel =
            waitingDetail:lower():find("orphan", 1, true)
                and "WAITING CHEST"
                or "WAITING TURN"

        line(
            "Startup",
            h.startupReady
                and "PASSED"
                or (startupWaiting and startupWaitingLabel or "BLOCKED"),
            h.startupReady
                and C.good
                or (startupWaiting and C.warn or C.danger)
        )

        line(
            "AutoCraft",
            h.autoCraftEnabled and "ON" or "OFF",
            h.autoCraftEnabled and C.good or C.warn
        )
        line(
            "Overstock",
            h.overstockEnabled and "ON" or "OFF",
            h.overstockEnabled and C.good or C.dim
        )
        line("Last Scan", tostring(h.lastScanText), C.dim)

        if y <= mh - 2 then
            monitorUI.fillRow(y, C.panel)
            monitorUI.center(
                y,
                "Active " .. engine.stats.active ..
                    " | Waiting " .. engine.stats.waiting ..
                    " | Craft " .. engine.stats.crafting ..
                    " | Blocked " .. engine.stats.blocked ..
                    " | Errors " .. engine.stats.errors,
                engine.stats.errors > 0 and C.warn or C.text,
                C.panel
            )
            y = y + 2
        end

        local missing = h.missingRequests or {}
        if #missing > 0 and y <= mh - 6 then
            monitorUI.fillRow(y, C.panel)
            monitorUI.center(
                y,
                "MISSING ITEMS (" .. tostring(#missing) .. ")",
                C.danger, C.panel
            )
            y = y + 1

            -- Preserve enough vertical space for Current Work. The full
            -- shortage list is always available on the REQUESTS page.
            local reserveForWork = 5
            local availableLines = math.max(1, mh - y - reserveForWork)
            local showCount = math.min(#missing, availableLines)

            if #missing > showCount and showCount > 1 then
                showCount = showCount - 1
            end

            for i = 1, showCount do
                local row = missing[i]
                monitorUI.fillRow(y, C.bg)
                local qty = tonumber(row.remaining) or tonumber(row.requested) or 0
                local itemText = tostring(
                    row.displayName or row.item or row.name or "Unknown")
                local text = tostring(qty) .. "x " .. itemText
                monitorUI.writeAt(
                    2, y,
                    Util.clip(text, math.max(1, w - 2)),
                    C.danger, C.bg
                )
                y = y + 1
            end

            if #missing > showCount and y <= mh - reserveForWork then
                monitorUI.fillRow(y, C.bg)
                monitorUI.writeAt(
                    2, y,
                    "+" .. tostring(#missing - showCount) ..
                        " more - see REQUESTS",
                    C.danger, C.bg
                )
                y = y + 1
            end

            if y <= mh - reserveForWork then y = y + 1 end
        end

        local work = h.currentWork
        if work and y <= mh - 4 then
            local status = tostring(work.status or "UNKNOWN")
            local upper = status:upper()
            local statusFg = C.text
            if upper:find("ERROR", 1, true)
                or upper:find("BLOCKED", 1, true)
                or upper:find("MISSING", 1, true)
                or upper:find("STALLED", 1, true)
                or upper:find("DESYNC", 1, true) then
                statusFg = C.danger
            elseif upper:find("STALE", 1, true)
                or upper:find("SUSPECT", 1, true) then
                statusFg = C.warn
            elseif upper:find("CRAFT", 1, true) then
                statusFg = C.warn
            elseif upper:find("SUPPLY", 1, true) then
                statusFg = C.good
            elseif upper:find("WAIT", 1, true)
                or upper:find("VERIFY", 1, true) then
                statusFg = colors.lightBlue
            end

            monitorUI.fillRow(y, C.panel)
            monitorUI.center(y, "CURRENT WORK", C.title, C.panel)
            y = y + 1

            monitorUI.fillRow(y, C.bg)
            monitorUI.writeAt(2, y, "Item:", C.dim, C.bg)
            monitorUI.writeAt(
                8, y,
                Util.clip(
                    tostring(work.displayName or work.item or "-") ..
                        "  [" .. tostring(work.item or "-") .. "]",
                    math.max(1, w - 8)
                ),
                C.text, C.bg
            )
            y = y + 1

            monitorUI.fillRow(y, C.bg)
            local counts =
                "Need " .. tostring(work.requested or 0) ..
                " | Sent " .. tostring(work.sent or 0) ..
                " | Rem " .. tostring(work.remaining or 0) ..
                " | PRS " ..
                    tostring(work.prsStock == nil and "?" or work.prsStock) ..
                " | CRS " ..
                    tostring(work.crsStock == nil and "?" or work.crsStock)
            monitorUI.writeAt(
                2, y,
                Util.clip(counts, math.max(1, w - 2)),
                C.text, C.bg
            )
            y = y + 1

            monitorUI.fillRow(y, C.bg)
            monitorUI.writeAt(2, y, "Status: ", C.dim, C.bg)
            monitorUI.writeAt(
                10, y,
                Util.clip(
                    status .. "  @ " ..
                        tostring(work.capturedAt or "--:--:--"),
                    math.max(1, w - 10)
                ),
                statusFg, C.bg
            )
            y = y + 1

            if y <= mh - 1 and tostring(work.detail or "") ~= "" then
                monitorUI.fillRow(y, C.bg)
                monitorUI.writeAt(
                    2, y,
                    Util.clip(
                        tostring(work.detail),
                        math.max(1, w - 2)
                    ),
                    C.dim, C.bg
                )
            end
        elseif not work and y <= mh - 2 then
            monitorUI.fillRow(y, C.panel)
            monitorUI.center(
                y,
                "CURRENT WORK: no active request",
                C.dim, C.panel
            )
        end
    end

    local function drawHealth()
        local h = engine.healthSnapshot()
        local w = drawFrame("HEALTH CHECKS", h.overall and "ONLINE" or "DEGRADED", h.overall and C.good or C.warn)
        local movementCheck = h.startupChecks and h.startupChecks.movement or nil
        local startupWaiting = not h.startupReady
            and type(movementCheck) == "table"
            and movementCheck.severity == "WAITING"

        local desync = type(h.desync) == "table" and h.desync or {}
        local staleCount = 0
        for _ in pairs(
            type(desync.staleItems) == "table"
                and desync.staleItems or {}
        ) do
            staleCount = staleCount + 1
        end
        local extractionHealthy =
            desync.extractionHealthy == true
        local extractionFailed =
            desync.extractionHealthy == false
        local extractionWord =
            extractionFailed and "FAIL"
            or (extractionHealthy and "OK" or "WARN")
        local extractionColor =
            extractionFailed and C.danger
            or (extractionHealthy and C.good or C.warn)

        local sharedPrsFault =
            type(h.cluster) == "table"
            and type(h.cluster.prsFault) == "table"
            and h.cluster.prsFault
            or nil

        local rows = {
            {"Colony integrator", h.colony, transfer.colonyName},
            {"Player RS (PRS)", h.playerRS, transfer.playerBridgeName or "?"},
            {"Colony RS (CRS)", h.colonyRS, transfer.colonyBridgeName or "?"},
            {"Warehouse external", h.warehouse, h.warehouse and "external storage online" or "not detected"},
            {"Transfer chest", h.transferChest, transfer.transferChestName or "?"},
            {
                "Transfer contents",
                h.transferChestItemCount ~= nil,
                h.transferChestItemCount ~= nil
                    and (tostring(h.transferChestItemCount) .. " item(s) / " ..
                        tostring(h.transferChestStackCount or 0) .. " stack(s)")
                    or "unavailable"
            },
            {"Cluster link", h.cluster.ok, h.cluster.ok and table.concat(h.cluster.activeIds,",") or h.cluster.fault},
            {
                "Cluster PRS",
                sharedPrsFault == nil,
                sharedPrsFault
                    and (
                        tostring(sharedPrsFault.name or ("Computer " ..
                            tostring(sharedPrsFault.id or "?"))) ..
                        " | " ..
                        tostring(sharedPrsFault.scope or "PRS") ..
                        " | " ..
                        tostring(sharedPrsFault.item or "?")
                    )
                    or "no shared PRS fault reported",
                sharedPrsFault and "FAIL" or nil,
                sharedPrsFault and C.danger or nil,
            },
            {
                "Startup suite",
                h.startupReady,
                h.startupReady and "all required checks passed"
                    or (startupWaiting and tostring(movementCheck.detail or "waiting for PRS turn") or "blocked"),
                startupWaiting and "WAIT" or nil,
                startupWaiting and C.warn or nil,
            },
            {
                "PRS extraction",
                not extractionFailed,
                tostring(desync.detail or "not checked"),
                extractionWord,
                extractionColor,
            },
            {
                "PRS desync items",
                staleCount == 0,
                staleCount == 0
                    and "none"
                    or (tostring(staleCount) ..
                        " failed exact item(s); shared PRS held until recovery"),
                staleCount > 0 and "FAIL" or nil,
                staleCount > 0 and C.danger or nil,
            },
            {"Pending transfer", h.pending == nil, h.pending and ("PENDING " .. tostring(h.pending.direction) .. " " .. tostring(h.pending.item)) or "none"},
        }
        local y = 5
        for _, row in ipairs(rows) do
            local bg = (y%2==0) and C.panel or C.bg
            local statusWord = row[4] or (row[2] and "OK" or "FAIL")
            local statusFg = row[5] or (row[2] and C.good or C.danger)
            monitorUI.fillRow(y, bg)
            monitorUI.writeAt(2,y,Util.padRight(row[1],20),C.dim,bg)
            monitorUI.writeAt(23,y,statusWord,statusFg,bg)
            monitorUI.writeAt(30,y,Util.clip(row[3] or "",math.max(1,w-30)),C.text,bg)
            y=y+1
        end

        local checks = h.startupChecks or {}
        for _, id in ipairs({"functions","pending","chest_empty","movement","desync","cluster"}) do
            local c = checks[id]
            if c and y < select(2,monitorUI.size()) then
                local checkWord = c.ok and "OK"
                    or (c.severity == "WAITING" and "WAIT" or "FAIL")
                local checkColor = c.ok and C.good
                    or ((c.severity == "WARNING" or c.severity == "WAITING")
                        and C.warn or C.danger)
                monitorUI.fillRow(y,C.bg)
                local checkLabel = id == "chest_empty"
                    and "Startup chest check"
                    or ("Startup " .. id)
                monitorUI.writeAt(2,y,Util.padRight(checkLabel,20),C.dim,C.bg)
                monitorUI.writeAt(23,y,checkWord,checkColor,C.bg)
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

    local function drawRequests()
        local w,h = monitorUI.size()
        local snapshot = engine.healthSnapshot()
        local data = snapshot.requestRows or {}
        local missing = snapshot.missingRequests or {}
        local rowsPerPage = math.max(1, h - 8)
        local rows,pages,page = pagedRows(
            data, self.requestPage, rowsPerPage)
        self.requestPage = page

        drawFrame(
            "ACTIVE REQUESTS  " .. tostring(page) .. "/" .. tostring(pages),
            "Active " .. tostring(#data) ..
                "  |  Missing " .. tostring(#missing),
            #missing > 0 and C.danger or C.good
        )

        local qtyW = 9
        local statusW = 13
        local usable = math.max(24, w - 5)
        local itemW = math.max(16, math.floor(usable * 0.34))
        local detailW = math.max(
            8,
            w - (2 + itemW + 1 + qtyW + 1 + statusW + 1)
        )

        local itemX = 2
        local sep1X = itemX + itemW
        local qtyX = sep1X + 1
        local sep2X = qtyX + qtyW
        local statusX = sep2X + 1
        local sep3X = statusX + statusW
        local detailX = sep3X + 1

        monitorUI.fillRow(5, C.panel)
        monitorUI.writeAt(itemX,5,Util.padRight("ITEM",itemW),C.dim,C.panel)
        monitorUI.writeAt(sep1X,5,"|",C.dim,C.panel)
        monitorUI.writeAt(qtyX,5,Util.padRight("SENT/QTY",qtyW),C.dim,C.panel)
        monitorUI.writeAt(sep2X,5,"|",C.dim,C.panel)
        monitorUI.writeAt(statusX,5,Util.padRight("STATUS",statusW),C.dim,C.panel)
        monitorUI.writeAt(sep3X,5,"|",C.dim,C.panel)
        monitorUI.writeAt(
            detailX,5,
            Util.padRight("DETAIL",math.max(1,w-detailX+1)),
            C.dim,C.panel
        )

        local y=6
        for _,row in ipairs(rows) do
            local bg=(y%2==0) and C.bg or C.panel
            monitorUI.fillRow(y,bg)

            local itemText=tostring(
                row.displayName or row.item or row.name or "Unknown")
            local qtyText=tostring(row.sent or 0) ..
                "/" .. tostring(row.requested or 0)
            local status=tostring(row.status or "WAITING")
            local detail=tostring(row.detail or "")

            monitorUI.writeAt(
                itemX,y,Util.padRight(Util.clip(itemText,itemW),itemW),
                status=="MISSING" and C.danger or C.text,bg
            )
            monitorUI.writeAt(sep1X,y,"|",C.dim,bg)
            monitorUI.writeAt(
                qtyX,y,Util.padRight(Util.clip(qtyText,qtyW),qtyW),
                C.text,bg
            )
            monitorUI.writeAt(sep2X,y,"|",C.dim,bg)
            monitorUI.writeAt(
                statusX,y,
                Util.padRight(Util.clip(status,statusW),statusW),
                requestStatusColor(status),bg
            )
            monitorUI.writeAt(sep3X,y,"|",C.dim,bg)
            monitorUI.writeAt(
                detailX,y,
                Util.clip(detail,math.max(1,w-detailX+1)),
                C.dim,bg
            )
            y=y+1
        end

        if #data==0 then
            monitorUI.center(
                7,
                "No active MineColonies requests.",
                C.good,C.bg
            )
        end

        monitorUI.addButton(
            "req_prev",1,h-1,math.floor(w/3),h-1,"PREV",
            C.nav,C.navText,function()
                self.requestPage=math.max(1,self.requestPage-1)
                self.draw()
            end
        )
        monitorUI.addButton(
            "req_refresh",math.floor(w/3)+1,h-1,
            math.floor(2*w/3),h-1,"REFRESH",
            C.navActive,C.navText,function()
                self.draw()
            end
        )
        monitorUI.addButton(
            "req_next",math.floor(2*w/3)+1,h-1,w,h-1,"NEXT",
            C.nav,C.navText,function()
                self.requestPage=math.min(pages,self.requestPage+1)
                self.draw()
            end
        )
    end

    local function drawHistory()
        local w,h = monitorUI.size()
        local rows,pages,page = pagedRows(store.data.history or {},self.historyPage,math.max(1,h-7))
        self.historyPage=page
        drawFrame("TRANSFER / EVENT HISTORY  " .. page .. "/" .. pages,"Newest first",C.dim)
        local function historyColor(e)
            local kind = tostring(e.kind or ""):upper()
            local direction = tostring(e.direction or ""):upper()
            local detail = tostring(e.detail or ""):upper()

            -- Priority matters: an error should remain red even when it also
            -- references a transfer direction or a craft operation.
            if kind:find("ERROR", 1, true)
                or kind:find("FAIL", 1, true)
                or detail:find("ERROR", 1, true)
                or detail:find("FAILED", 1, true) then
                return colors.red
            end

            if kind == "STARTUP"
                or kind == "RECOVERY"
                or kind == "HEALTH" then
                return colors.white
            end

            if kind == "CRAFT"
                or kind:find("CRAFT", 1, true) then
                return colors.yellow
            end

            if direction == "PRS>CRS" then
                return colors.lime
            end

            if direction == "CRS>PRS" then
                return colors.lightBlue
            end

            return colors.white
        end

        local y=5
        for _,e in ipairs(rows) do
            local text = tostring(e.time or "--:--:--") .. " " ..
                tostring(e.kind or "") .. " " .. tostring(e.direction or "") .. " " ..
                tostring(e.item or "") .. (e.amount and (" x"..tostring(e.amount)) or "") ..
                (e.detail and (" - "..tostring(e.detail)) or "")
            local bg = (y%2==0) and C.panel or C.bg
            monitorUI.fillRow(y,bg)
            monitorUI.writeAt(2,y,Util.clip(text,w-2),historyColor(e),bg)
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

    local function orphanRecoveryDisplay(e)
        if type(e) ~= "table"
            or tostring(e.code or "") ~= "ORPHAN_CHEST_QUARANTINE" then
            return nil
        end

        local recovery = type(store.data.recovery) == "table"
            and store.data.recovery.orphanChest or nil
        if type(recovery) ~= "table" then return nil end

        local summary = tostring(
            recovery.summary
            or (type(e.context) == "table" and e.context.detail)
            or "Unknown item"
        )

        local started = tonumber(recovery.firstSeen) or 0
        local errorEpoch = tonumber(e.epoch) or 0
        local errorSummary = type(e.context) == "table"
            and tostring(e.context.detail or "") or ""

        -- Only animate the error record which created the currently-active
        -- quarantine. Historical orphan errors stay historical.
        if started <= 0
            or math.abs(errorEpoch - started) > 2
            or (errorSummary ~= "" and errorSummary ~= summary) then
            return nil
        end

        local waitSeconds =
            math.max(30, math.floor(tonumber(config.orphanChestRecoverySeconds) or 180))
        local elapsed = math.max(0, os.epoch("utc") / 1000 - started)
        local remaining = math.max(0, math.ceil(waitSeconds - elapsed))

        local timeText
        if remaining > 0 then
            local minutes = math.floor(remaining / 60)
            local seconds = remaining % 60
            if minutes > 0 then
                timeText = tostring(minutes) .. "m " ..
                    string.format("%02d", seconds) .. "s remaining"
            else
                timeText = tostring(seconds) .. "s remaining"
            end
        else
            timeText = "0s remaining - return pending"
        end

        return summary .. "  -  " .. timeText
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

            local orphanDisplay = orphanRecoveryDisplay(e)
            if orphanDisplay then
                drawWrapped("Item:", orphanDisplay, C.warn)
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
        local w = drawFrame("SETTINGS","Touch to configure",C.dim)
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

        monitorUI.center(
            y,
            "Default item keep: " .. tostring(config.defaultItemKeepStacks) ..
                " stacks  |  Building keep: " ..
                tostring(config.defaultBuildingKeepCount),
            C.text,C.bg
        )
        y=y+2

        monitorUI.addButton(
            "open_overrides", 2, y, w-1, y+1,
            "PER-ITEM OVERSTOCK OVERRIDES",
            C.navActive, C.navText,
            function()
                self.overridePage = 1
                self.view = "overrides"
                self.draw()
            end
        )
        y=y+3

        local count=0
        for _ in pairs(store.data.settings.overstockKeep or {}) do count=count+1 end
        monitorUI.center(
            y,
            tostring(count) .. " per-item override" .. (count==1 and "" or "s") ..
                " configured",
            count>0 and C.warn or C.dim,C.bg
        )
    end

    local function drawOverrides()
        local w,h = monitorUI.size()
        local items, listErr = engine.listOverstockItems()
        local rowsPerPage = math.max(1, h - 9)
        local pages = math.max(1, math.ceil(#items / rowsPerPage))
        self.overridePage = math.max(1, math.min(self.overridePage, pages))

        drawFrame(
            "PER-ITEM OVERSTOCK  " .. tostring(self.overridePage) ..
                "/" .. tostring(pages),
            listErr and tostring(listErr) or "Touch an item to edit",
            listErr and C.warn or C.dim
        )

        local y=5
        monitorUI.fillRow(y,C.panel)
        monitorUI.writeAt(2,y,"ITEM",C.dim,C.panel)
        monitorUI.writeAt(math.max(2,w-27),y,"CRS",C.dim,C.panel)
        monitorUI.writeAt(math.max(2,w-16),y,"KEEP",C.dim,C.panel)
        monitorUI.writeAt(math.max(2,w-5),y,"OVR",C.dim,C.panel)
        y=y+1

        local first=(self.overridePage-1)*rowsPerPage+1
        local last=math.min(#items,first+rowsPerPage-1)

        for i=first,last do
            local item=items[i]
            local override=item.overrideKeep~=nil
            local keep=override and item.overrideKeep or item.defaultKeep
            local right =
                "CRS " .. tostring(item.amount or 0) ..
                "  KEEP " .. tostring(keep or 0) ..
                (override and "  *" or "")
            local name=tostring(item.displayName or item.name)
            local maxName=math.max(8,w-#right-6)
            local label=Util.clip(name,maxName) .. "  " .. right
            local bg=(y%2==0) and C.panel or C.bg
            monitorUI.addButton(
                "override_item_"..tostring(i),2,y,w-1,y,
                label,bg,override and C.warn or C.text,
                function()
                    self.overrideItem=item.name
                    self.overrideDraftName=nil
                    self.overrideDraft=nil
                    self.view="override_edit"
                    self.draw()
                end
            )
            y=y+1
        end

        if #items==0 then
            monitorUI.center(
                y+1,
                listErr and tostring(listErr) or "No CRS items or saved overrides found.",
                listErr and C.warn or C.dim,C.bg
            )
        end

        local third=math.floor(w/3)
        monitorUI.addButton(
            "override_prev",1,h-1,third,h-1,"PREV",
            C.nav,C.navText,function()
                self.overridePage=math.max(1,self.overridePage-1)
                self.draw()
            end
        )
        monitorUI.addButton(
            "override_back",third+1,h-1,math.floor(2*w/3),h-1,"BACK",
            C.navActive,C.navText,function()
                self.view="settings"
                self.draw()
            end
        )
        monitorUI.addButton(
            "override_next",math.floor(2*w/3)+1,h-1,w,h-1,"NEXT",
            C.nav,C.navText,function()
                self.overridePage=math.min(pages,self.overridePage+1)
                self.draw()
            end
        )
    end

    local function drawOverrideEdit()
        local w,h = monitorUI.size()
        local items = engine.listOverstockItems()
        local selected

        for _,item in ipairs(items or {}) do
            if item.name==self.overrideItem then
                selected=item
                break
            end
        end

        if not selected then
            selected={
                name=tostring(self.overrideItem or ""),
                displayName=tostring(self.overrideItem or "Unknown item"),
                amount=0,
                defaultKeep=config.defaultStackSize *
                    (config.defaultItemKeepStacks or 2),
                overrideKeep=(store.data.settings.overstockKeep or {})[
                    tostring(self.overrideItem or "")
                ],
            }
            selected.keep=selected.overrideKeep or selected.defaultKeep
        end

        if self.overrideDraftName~=selected.name then
            self.overrideDraftName=selected.name
            self.overrideDraft=tonumber(selected.overrideKeep)
                or tonumber(selected.defaultKeep)
                or 0
        end

        self.overrideDraft=math.max(0,math.floor(tonumber(self.overrideDraft) or 0))

        drawFrame("EDIT OVERSTOCK OVERRIDE","Changes apply when SAVE is touched",C.dim)

        local y=6
        monitorUI.center(
            y,
            Util.clip(tostring(selected.displayName or selected.name),math.max(1,w-4)),
            C.title,C.bg
        )
        y=y+1
        monitorUI.center(
            y,
            Util.clip(tostring(selected.name),math.max(1,w-4)),
            C.dim,C.bg
        )
        y=y+2

        monitorUI.center(
            y,
            "CRS stock: "..tostring(selected.amount or 0)..
            "  |  Default keep: "..tostring(selected.defaultKeep or 0),
            C.text,C.bg
        )
        y=y+1
        monitorUI.center(
            y,
            "Saved override: "..
                tostring(selected.overrideKeep==nil and "DEFAULT" or selected.overrideKeep)..
            "  |  New keep: "..tostring(self.overrideDraft),
            C.warn,C.bg
        )
        y=y+3

        local labels={
            {"-1024",-1024},{"-64",-64},{"-1",-1},
            {"+1",1},{"+64",64},{"+1024",1024},
        }
        local base=math.floor(w/#labels)
        local x=1
        for i,entry in ipairs(labels) do
            local x2=(i==#labels) and w or (x+base-1)
            local delta=entry[2]
            monitorUI.addButton(
                "override_delta_"..tostring(i),x,y,x2,y,
                entry[1],C.nav,C.navText,function()
                    self.overrideDraft=math.max(
                        0,
                        math.floor((tonumber(self.overrideDraft) or 0)+delta)
                    )
                    self.draw()
                end
            )
            x=x2+1
        end
        y=y+2

        if y<=h-3 then
            monitorUI.addButton(
                "override_zero",2,y,math.floor(w/3),y+1,
                "KEEP 0",C.warn,C.navText,function()
                    self.overrideDraft=0
                    self.draw()
                end
            )
            monitorUI.addButton(
                "override_default",math.floor(w/3)+1,y,
                math.floor(2*w/3),y+1,
                "USE DEFAULT",C.nav,C.navText,function()
                    engine.clearOverstockOverride(selected.name)
                    self.overrideDraft=selected.defaultKeep
                    self.overrideDraftName=selected.name
                    self.view="overrides"
                    self.draw()
                end
            )
            monitorUI.addButton(
                "override_save",math.floor(2*w/3)+1,y,w-1,y+1,
                "SAVE OVERRIDE",C.good,C.navText,function()
                    engine.setOverstockOverride(
                        selected.name,
                        math.floor(tonumber(self.overrideDraft) or 0)
                    )
                    self.view="overrides"
                    self.draw()
                end
            )
        end

        monitorUI.addButton(
            "override_edit_back",1,h-1,w,h-1,"BACK TO ITEM LIST",
            C.navActive,C.navText,function()
                self.view="overrides"
                self.draw()
            end
        )
    end

    function self.draw()
        if not transfer.monitor then resolveMonitor() end
        if not transfer.monitor then return false end
        if self.view=="home" then drawHome()
        elseif self.view=="health" then drawHealth()
        elseif self.view=="requests" then drawRequests()
        elseif self.view=="history" then drawHistory()
        elseif self.view=="errors" then drawErrors()
        elseif self.view=="settings" then drawSettings()
        elseif self.view=="overrides" then drawOverrides()
        elseif self.view=="override_edit" then drawOverrideEdit()
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
        local memberNames = cs.memberNames or {}
        local function terminalColonyName(id)
            if id == nil then return "-" end
            return tostring(
                memberNames[tostring(id)]
                or memberNames[tonumber(id)]
                or ("Computer " .. tostring(id))
            )
        end
        print("Role:        " .. tostring(cs.role) ..
            "  Master: " .. terminalColonyName(cs.masterId))
        print("PRS turn:    " .. terminalColonyName(cs.turnId))
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
        local refreshTimer = os.startTimer(1)

        while true do
            local ev,a,b,c = os.pullEvent()

            if ev=="monitor_touch" and transfer.monitor then
                local okName,name=pcall(peripheral.getName,transfer.monitor)
                if okName and a==name then
                    local button=monitorUI.hitButton(b,c)
                    if button and type(button.action)=="function" then
                        pcall(button.action)
                    end
                end
            elseif ev=="peripheral" or ev=="peripheral_detach" then
                resolveMonitor()
                self.draw()
            elseif ev=="timer" and a==refreshTimer then
                if self.view=="home"
                    or self.view=="health"
                    or self.view=="requests"
                    or self.view=="errors" then
                    pcall(self.draw)
                end
                refreshTimer=os.startTimer(1)
            end
        end
    end

    return self
end

return M