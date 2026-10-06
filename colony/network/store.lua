-- Two-slot persistent journal. Never continue a mutation after a failed save.
local M = {}
local function read(path)
    if not fs.exists(path) then return nil end
    local h=fs.open(path,"r"); if not h then error("Cannot read journal "..path,0) end
    local source=h.readAll(); h.close()
    local ok,value=pcall(textutils.unserialize,source)
    if not ok or type(value)~="table" or value.schema~=4 or type(value.revision)~="number" then return nil end
    return value
end
function M.new(path,config)
    local self={path=path,data={schema=4,revision=0,history={},errors={}},fault=nil}
    function self.load()
        local first,second=read(path..".a"),read(path..".b")
        if not first and not second and (fs.exists(path..".a") or fs.exists(path..".b")) then
            error("Both persistent journal slots are invalid; refusing new transfers",0)
        end
        local selected=not first and second or not second and first or first and second and (first.revision>second.revision and first or second)
        if selected then self.data=selected end
        self.data.history=self.data.history or {}; self.data.errors=self.data.errors or {}
        return self.data
    end
    function self.save()
        if self.fault then error(self.fault,0) end
        local directory=fs.getDir(path); if directory~="" and not fs.exists(directory) then fs.makeDir(directory) end
        local revision=(self.data.revision or 0)+1
        self.data.schema=4; self.data.revision=revision
        local target=path..(revision%2==0 and ".a" or ".b")
        local source=textutils.serialize(self.data)
        local ok,err=pcall(function()
            local h=assert(fs.open(target,"w"),"Cannot write persistent journal")
            h.write(source); h.close()
            local verify=assert(fs.open(target,"r")); local saved=verify.readAll(); verify.close()
            assert(saved==source,"Persistent journal verification failed")
        end)
        if not ok then self.fault="Persistence failure: "..tostring(err); error(self.fault,0) end
        return true
    end
    function self.event(kind,message,context)
        local entries=self.data.history
        entries[#entries+1]={time=os.epoch and os.epoch("utc")/1000 or os.clock(),kind=kind,message=message,context=context}
        while #entries>(config and config.maxHistoryEntries or 400) do table.remove(entries,1) end
        self.save()
    end
    function self.log(message) self.event("INFO",message) end
    function self.error(code,message,context)
        local entries=self.data.errors
        entries[#entries+1]={time=os.epoch and os.epoch("utc")/1000 or os.clock(),code=code,message=message,context=context,severity="ERROR"}
        while #entries>(config and config.maxErrorEntries or 100) do table.remove(entries,1) end
        self.save()
    end
    self.addError=self.error
    return self
end
return M
