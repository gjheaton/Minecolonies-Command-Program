-- Standalone operator recovery for a held PRS export which reported zero.
-- Intentionally has no require() calls and no os/time dependency.
local STATE="/colony/master_v4_state"
local CONFIRM="ZERO EXPORT"

local function readState(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local h=fs.open(path,"r")
    if not h then return nil end
    local source=h.readAll()
    h.close()
    local ok,value=pcall(textutils.unserialize,source)
    if not ok or type(value)~="table" or value.schema~=4
        or type(value.revision)~="number" then return nil end
    return value
end

local function latest()
    local a,b=readState(STATE..".a"),readState(STATE..".b")
    if not a and not b then return nil,"No valid Master v4 journal slot exists" end
    if not a then return b end
    if not b then return a end
    return a.revision>b.revision and a or b
end

local function copy(value,seen)
    if type(value)~="table" then return value end
    seen=seen or {}
    if seen[value] then error("Journal contains a cycle; refusing repair",0) end
    seen[value]=true
    local out={}
    for k,v in pairs(value) do out[copy(k,seen)]=copy(v,seen) end
    seen[value]=nil
    return out
end

local function validate(state)
    local master=type(state)=="table" and state.master
    local pending=type(master)=="table" and master.pendingTransfer
    local quarantine=type(master)=="table" and master.quarantine
    if type(pending)~="table" or pending.kind~="export" then
        return nil,"No held PRS export exists"
    end
    if pending.reported~=0 or pending.intent then
        return nil,"Held export is not an explicit bridge-reported zero"
    end
    if pending.uncertain~=true then
        return nil,"Held export is not marked uncertain"
    end
    if type(quarantine)~="table" or quarantine.code~="TRANSFER_VERIFY" then
        return nil,"Held export is not the active transfer-verification quarantine"
    end
    if type(pending.chest)~="string" or pending.chest=="" then
        return nil,"Held export has no delivery chest"
    end
    if type(pending.colonyId)~="number" and type(pending.colonyId)~="string" then
        return nil,"Held export has no colony ID"
    end
    if type(pending.requestId)~="string" or pending.requestId=="" then
        return nil,"Held export has no request ID"
    end

    if not peripheral.isPresent(pending.chest) then
        return nil,"Held delivery chest is not currently visible: "..pending.chest
    end
    local chest=peripheral.wrap(pending.chest)
    if not chest or type(chest.list)~="function" then
        return nil,"Held delivery peripheral is not an inventory: "..pending.chest
    end
    local ok,items=pcall(chest.list)
    if not ok or type(items)~="table" then
        return nil,"Cannot inspect held delivery chest"
    end
    local total=0
    for _,entry in pairs(items) do
        if type(entry)~="table" or type(entry.count)~="number" or entry.count<1
            or entry.count%1~=0 then
            return nil,"Held delivery chest returned invalid inventory data"
        end
        total=total+entry.count
    end
    if total~=0 then
        return nil,"Held delivery chest is not empty ("..tostring(total).." item(s)); repair refused"
    end

    local cs=type(master.colonies)=="table" and master.colonies[tostring(pending.colonyId)]
    if type(cs)~="table" then
        return nil,"Held colony ledger is missing"
    end
    local record=type(cs.requests)=="table" and cs.requests[pending.requestId]
    if type(record)~="table" then
        return nil,"Held request record is missing"
    end
    if pending.generation~=nil and record.generation~=pending.generation then
        return nil,"Held request generation no longer matches"
    end

    return {
        pending=pending,
        quarantine=quarantine,
        colony=cs,
        request=record,
        chestItems=total,
    }
end

local function writeNext(current)
    local nextState=copy(current)
    local master=nextState.master
    local pending=master.pendingTransfer
    local cs=master.colonies[tostring(pending.colonyId)]
    local heldReason=master.quarantine and master.quarantine.message

    if cs.turn and cs.turn.phase=="RECOVERY" then cs.turn=nil end

    for _,colony in pairs(master.colonies or {}) do
        for _,request in pairs(colony.requests or {}) do
            if request.errorCode=="PRS_QUARANTINE" then
                request.status="requested"
                request.detail="Operator-confirmed zero export; retrying from an empty chest"
                request.errorCode=nil
            end
        end
        if colony.error==heldReason then
            colony.error=nil
            colony.errorSource=nil
        end
    end

    master.pendingTransfer=nil
    master.quarantine=nil
    nextState.revision=(current.revision or 0)+1
    nextState.schema=4

    local source=textutils.serialize(nextState,{compact=true,allow_repetitions=true})
    if type(source)~="string" or source=="" then
        return nil,"Journal serialization failed"
    end

    local target=STATE..(nextState.revision%2==0 and ".a" or ".b")
    local h,err=fs.open(target,"w")
    if not h then return nil,"Cannot open target journal slot: "..tostring(err) end
    local ok,writeErr=pcall(h.write,source)
    pcall(h.close)
    if not ok then return nil,"Journal write failed: "..tostring(writeErr) end

    local verify=readState(target)
    if not verify or verify.revision~=nextState.revision then
        return nil,"Journal read-back verification failed; previous slot remains authoritative"
    end
    if verify.master and (verify.master.pendingTransfer or verify.master.quarantine) then
        return nil,"Journal verification found the hold still present; previous slot remains available"
    end
    return true,target,nextState.revision
end

print("MineColonies Master standalone zero-export repair")
print("This tool moves no items and credits no shipment.")
print()

local state,loadErr=latest()
if not state then error(loadErr,0) end
local checked,checkErr=validate(state)
if not checked then error(checkErr,0) end

print("Journal revision: "..tostring(state.revision))
print("Colony: "..tostring(checked.pending.colonyId))
print("Item: "..tostring(checked.pending.item and checked.pending.item.name or "UNKNOWN")..
    " x"..tostring(checked.pending.count or "?"))
print("Chest: "..tostring(checked.pending.chest))
print("Bridge reported: 0; current chest items: 0")
print()
print("Type "..CONFIRM.." to clear only this stale zero-export hold.")
write("> ")
local answer=read()
if answer~=CONFIRM then
    print("CANCELLED: Journal unchanged")
    return
end

-- Re-read after confirmation so nothing can change between preview and commit.
local fresh,freshErr=latest()
if not fresh then error(freshErr,0) end
if fresh.revision~=state.revision then
    error("Journal changed after review; run the repair again",0)
end
local freshChecked,freshCheckErr=validate(fresh)
if not freshChecked then error(freshCheckErr,0) end

local ok,target,revision=writeNext(fresh)
if not ok then error(target,0) end
print("OK: stale zero-export hold cleared; no shipment credited.")
print("New journal revision: "..tostring(revision))
print("Written slot: "..tostring(target))
print("Reboot the Master to resume from the empty delivery chest.")
