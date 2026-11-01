-- Volatile runtime state for MineColonies Supply 4.1.
-- Configuration is persistent elsewhere; turns, requests, transfer ledgers,
-- errors, telemetry history, craft tracking and recovery state live only in RAM.
-- A reboot intentionally starts from a clean operational state and rebuilds
-- from the physical chests, Refined Storage and MineColonies requests.
local M = {}

local function timestamp()
    local api=os
    if type(api)=="table" then
        if type(api.epoch)=="function" then
            local ok,value=pcall(api.epoch,"utc")
            if ok and type(value)=="number" then return value/1000 end
        end
        if type(api.clock)=="function" then
            local ok,value=pcall(api.clock)
            if ok and type(value)=="number" then return value end
        end
    end
    return 0
end

local function limit(entries, maximum)
    maximum=math.max(1,math.floor(tonumber(maximum) or 1))
    while #entries>maximum do table.remove(entries,1) end
end

function M.new(path,config)
    local self={
        path=path,
        data={schema=5,revision=0,history={},errors={}},
        fault=nil,
        volatile=true,
    }

    local function removeLegacyState()
        if type(path)~="string" or path=="" then return end
        for _,suffix in ipairs({".a",".b",".a.bak",".b.bak",".tmp",".old"}) do
            local candidate=path..suffix
            if fs.exists(candidate) and not fs.isDir(candidate) then
                pcall(fs.delete,candidate)
            end
        end
    end

    function self.load()
        -- 4.1 deliberately ignores all prior operational journals.
        removeLegacyState()
        self.data={schema=5,revision=0,history={},errors={}}
        self.fault=nil
        return self.data
    end

    function self.save()
        -- Preserve the transactional API for the running program, but never
        -- serialize runtime state to disk. A successful return means the
        -- in-memory state is available for the rest of this process lifetime.
        self.data.revision=(tonumber(self.data.revision) or 0)+1
        return true
    end

    function self.event(kind,message,context)
        local entries=self.data.history
        entries[#entries+1]={
            time=timestamp(),kind=kind,message=message,context=context,
        }
        limit(entries,config and config.maxHistoryEntries or 400)
        return true
    end

    function self.log(message)
        return self.event("INFO",message)
    end

    function self.error(code,message,context)
        local entries=self.data.errors
        entries[#entries+1]={
            time=timestamp(),code=code,message=message,
            context=context,severity="ERROR",
        }
        limit(entries,config and config.maxErrorEntries or 100)
        return true
    end

    function self.clearErrors()
        local entries=self.data.errors
        local count=type(entries)=="table" and #entries or 0
        self.data.errors={}
        self.event("ERROR_HISTORY_CLEARED",
            "Recorded runtime error history cleared; active runtime faults are unchanged",
            {count=count})
        return true,"Cleared "..count.." runtime errors; reboot also clears all runtime state"
    end

    self.addError=self.error
    return self
end

return M
