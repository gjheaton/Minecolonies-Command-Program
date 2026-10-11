local S=require('tests.support')
local Client=require('colony.network.client')
local function fixture()
    local w,c=S.clientFixture()
    c.config.overflowEnabled=true;c.config.defaultItemKeep=0;c.config.buildingItemKeep=0
    c.integrator.requests={}
    local sapling={name='minecraft:cherry_sapling',maxCount=64}
    c.rs.add(sapling,53)
    local api=w.devices[2].crs.api
    api.exportItemToPeripheral=function() return nil,'NOT_CONNECTED' end
    w.grant(1);w.result(1)
    assert(c.store.data.client.intent and c.store.data.client.intent.kind=='return')
    api.isConnected=function() return true end
    local recovery=Client.zeroReturnRecovery(c.config,c.store,c.io,c.matcher)
    local f={w=w,c=c,api=api,recovery=recovery}
    function f.preview() return w.at(2,recovery.previewZeroReturn) end
    function f.confirm(text) return w.at(2,recovery.reconcileZeroReturn,text or 'ZERO RETURN minecraft:cherry_sapling 53') end
    return f
end
Test.case('unknown overflow zero recovery previews without modifying storage or journal and cancels safely',function()
    local f=fixture();local state=textutils.serialize(f.c.store.data,{allow_repetitions=true});local files=textutils.serialize(f.w.files)
    local preview=assert(f.preview());Test.equal(preview.count,53);Test.equal(preview.beforeChest,0);Test.equal(preview.currentChest,0)
    assert(not f.confirm('wrong'));Test.equal(textutils.serialize(f.c.store.data,{allow_repetitions=true}),state)
    Test.equal(textutils.serialize(f.w.files),files)
end)
Test.case('operator zero-return acknowledgment clears only the held operation, audits it, and survives restart without exporting',function()
    local f=fixture();local calls=0
    f.api.exportItemToPeripheral=function() calls=calls+1;error('Recovery exported items') end
    local ledgers=textutils.serialize({shipments=f.c.store.data.client.shipments,selectors=f.c.store.data.client.returnSelectors})
    assert(f.preview());assert(f.confirm());Test.equal(calls,0)
    assert(not f.c.store.data.client.intent and not f.c.store.data.client.fault)
    Test.equal(textutils.serialize({shipments=f.c.store.data.client.shipments,selectors=f.c.store.data.client.returnSelectors}),ledgers)
    local found=false;for _,entry in ipairs(f.c.store.data.history) do if entry.kind=='OPERATOR_ZERO_RETURN' then found=true end end;assert(found)
    f.c.restart();assert(not f.c.store.data.client.intent and not f.c.store.data.client.fault);Test.equal(calls,0)
end)
Test.case('zero-return recovery refuses changed chests, hardware, unknown connection, active turns, and known results',function()
    local changes={
        function(f) f.w.insert(f.w.channels.R2,{name='minecraft:cherry_sapling'},1) end,
        function(f) f.w.insert(f.w.channels.R2,{name='minecraft:stone'},1) end,
        function(f) f.c.config.returnChestName='other' end,
        function(f) f.api.isConnected=function() return false end end,
        function(f) f.api.isConnected=function() return nil end end,
        function(f) f.api.listItems=function() return nil,'NOT_CONNECTED' end end,
        function(f) f.c.store.data.client.turn.phase='awaiting' end,
        function(f) f.c.store.data.client.intent.reported=0 end,
        function(f) f.c.store.data.client.intent.reported=1 end,
        function(f) f.c.store.data.client.intent.physicalBefore=nil end,
        function(f) f.c.store.data.client.intent.count=0/0 end,
        function(f) f.c.store.data.client.intent.kind='import' end,
        function(f) f.c.store.data.client.fault.code='OTHER' end,
        function(f) f.c.store.data.client.shipments.X={id='X',verified=true,item={name='minecraft:stone'},count=1,imported=0} end,
    }
    for _,change in ipairs(changes) do
        local f=fixture();change(f)
        local state=textutils.serialize(f.c.store.data,{allow_repetitions=true});local files=textutils.serialize(f.w.files)
        assert(not f.preview());assert(not f.confirm())
        Test.equal(textutils.serialize(f.c.store.data,{allow_repetitions=true}),state);Test.equal(textutils.serialize(f.w.files),files)
    end
end)
Test.case('zero-return recovery rechecks operation and physical quantities after preview',function()
    for _,change in ipairs({
        function(f) f.c.store.data.client.intent.count=52 end,
        function(f) f.w.insert(f.w.channels.R2,{name='minecraft:cherry_sapling'},1) end,
        function(f) f.api.isConnected=function() return false end end,
    }) do
        local f=fixture();assert(f.preview());change(f);assert(not f.confirm());assert(f.c.store.data.client.intent)
    end
end)
Test.case('zero-return recovery preserves partially imported deliveries and requires a fresh preview for another acknowledgment',function()
    local f=fixture();local item={name='minecraft:stone'}
    f.w.insert(f.w.channels.D2,item,2)
    f.c.store.data.client.shipments.X={id='X',requestId='R',verified=true,item=item,count=3,imported=1}
    local ledger=textutils.serialize(f.c.store.data.client.shipments)
    assert(f.preview());assert(f.confirm())
    Test.equal(textutils.serialize(f.c.store.data.client.shipments),ledger)
    assert(not f.confirm())
end)
Test.case('zero-return recovery retains the hold if either durable journal write fails' ,function()
    for failedWrite=1,2 do
        local f=fixture();assert(f.preview());local original=f.c.store.save;local writes=0
        f.c.store.save=function() writes=writes+1;if writes==failedWrite then return nil,'Disk full' end;return original() end
        assert(not f.confirm());assert(f.c.store.data.client.intent and f.c.store.data.client.fault)
        f.c.store.save=original;f.c.restart();assert(f.c.store.data.client.intent and f.c.store.data.client.fault)
    end
end)
return true
