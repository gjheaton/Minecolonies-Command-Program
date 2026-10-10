-- Keyboard setup pages for the computer's own screen. Setup never redirects
-- input to an external monitor or changes a monitor's text scale.
local SharedUI=require("colony.lib.ui")
local Util=require("colony.lib.util")
local M={CANCELLED="Setup cancelled; no settings were saved."}
local C=SharedUI.theme()

local function currentTerminal()
    if type(term.current)=="function" then return term.current() end
    return term
end

local function appendWrapped(blocks,text,width,color)
    if text==nil or tostring(text)=="" then return end
    local block={}
    for _,line in ipairs(Util.wrapText(tostring(text),width)) do block[#block+1]={text=line,color=color or C.text} end
    blocks[#blocks+1]=block
end

local function pagesFor(blocks,capacity)
    local pages,current={},{}
    local function finish()
        if #current>0 then pages[#pages+1]=current;current={} end
    end
    for _,block in ipairs(blocks) do
        if #block<=capacity and #current+#block>capacity then finish() end
        for _,line in ipairs(block) do
            if #current>=capacity then finish() end
            current[#current+1]=line
        end
    end
    finish()
    if #pages==0 then pages[1]={} end
    return pages
end

function M.new(config)
    config=config or {}
    local original=currentTerminal()
    local native=type(term.native)=="function" and term.native() or original
    local self={}
    local screen=SharedUI.newMonitor({monitor=native,protected=false})

    local function blinkOff()
        if native and type(native.setCursorBlink)=="function" then pcall(native.setCursorBlink,false) end
    end

    local function withNative(fn)
        local previous=currentTerminal()
        if type(term.redirect)=="function" then term.redirect(native) end
        local ok,result=pcall(fn)
        blinkOff()
        if type(term.redirect)=="function" then term.redirect(previous) end
        if not ok then error(result,0) end
        return result
    end

    local function helpBlocks(spec,width,blocks)
        local help=spec.help or {}
        if type(help)=="string" then help={help} end
        for _,text in ipairs(help) do appendWrapped(blocks,text,width,C.dim) end
    end

    local function layout(spec,errorMessage,kind,choices)
        local w,h=native.getSize()
        if w<20 or h<10 then error("Setup needs a computer screen at least 20 x 10 characters.",0) end
        local width=w-4
        local labels=Util.wrapText(tostring(spec.label or ""),width)
        if spec.label==nil or spec.label=="" then labels={} end
        local visibleLabels=math.min(#labels,math.max(1,math.min(3,h-9)))
        local firstRow=5+visibleLabels+(visibleLabels>0 and 1 or 0)
        local errorLines=errorMessage and Util.wrapText(errorMessage,width) or {}
        local errorRows=math.min(2,#errorLines)
        local lastRow=h-4-errorRows
        local capacity=math.max(1,lastRow-firstRow+1)
        local blocks={}
        if #labels>visibleLabels then
            local overflow={};for i=visibleLabels+1,#labels do overflow[#overflow+1]={text=labels[i],color=C.title} end
            blocks[#blocks+1]=overflow
        end
        if spec.current~=nil then
            local value=tostring(spec.current)
            if kind=="choose" then
                local available=value=="" and spec.allowNone
                for _,choice in ipairs(choices) do
                    if tostring(choice.value)==value then value=choice.label;available=true;break end
                end
                if not available then value=value.." (unavailable)" end
            end
            appendWrapped(blocks,"Current: "..(value=="" and (spec.noneLabel or "none / automatic") or value),width,C.accent)
        end
        helpBlocks(spec,width,blocks)
        if kind=="choose" then
            for index,choice in ipairs(choices) do
                local prefix=tostring(index)..") "
                local lines=Util.wrapText(choice.label,math.max(1,width-#prefix))
                local block={}
                for lineIndex,line in ipairs(lines) do
                    block[#block+1]={text=(lineIndex==1 and prefix or string.rep(" ",#prefix))..line,color=C.text}
                end
                if choice.detail and choice.detail~="" then
                    for _,line in ipairs(Util.wrapText(choice.detail,math.max(1,width-2))) do block[#block+1]={text="  "..line,color=C.dim} end
                end
                blocks[#blocks+1]=block
            end
            if #choices==0 then appendWrapped(blocks,"No matching choices are available.",width,C.warn) end
            if spec.allowNone then appendWrapped(blocks,"0) "..tostring(spec.noneLabel or "None / automatic"),width,C.accent) end
        elseif kind=="notice" then
            local lines=spec.lines or {}
            if type(lines)=="string" then lines={lines} end
            for _,line in ipairs(lines) do appendWrapped(blocks,line,width,C.text) end
        end
        return {w=w,h=h,width=width,labels=labels,labelCount=visibleLabels,firstRow=firstRow,
            pages=pagesFor(blocks,capacity),errorLines=errorLines,errorRows=errorRows}
    end

    local function input(spec,page,errorMessage,kind,choices)
        return withNative(function()
            local l=layout(spec,errorMessage,kind,choices)
            page=Util.clamp(page,1,#l.pages)
            screen.clear();screen.resetButtons()
            screen.drawHeader({title="MINECOLONIES SETUP",subtitle=spec.title or (tostring(config.role or "SUPPLY"):upper().." SETUP"),
                status="Computer keyboard  |  Page "..page.."/"..#l.pages})
            for index=1,l.labelCount do screen.writeAt(3,4+index,l.labels[index],C.title) end
            for index,line in ipairs(l.pages[page]) do screen.writeAt(3,l.firstRow+index-1,line.text,line.color) end
            for index=1,l.errorRows do
                screen.writeAt(3,l.h-3-l.errorRows+index,l.errorLines[index],C.danger)
            end
            local controls
            if kind=="notice" then controls=page<#l.pages and "Enter next page | N/P pages | :q cancels"
                or "Enter continues | N/P pages | :q cancels"
            elseif kind=="choose" then
                controls=spec.allowNone and "Number / 0=none / Enter=current / N/P / :q"
                    or "Number / Enter=current or only / N/P / :q"
            else controls="Enter keeps current | N/P help | :q cancels" end
            screen.writeAt(3,l.h-2,controls,C.dim)
            screen.writeAt(3,l.h-1,"> ",C.accent)
            native.setCursorPos(5,l.h-1)
            if type(native.setCursorBlink)=="function" then native.setCursorBlink(true) end
            local value=read()
            self.pageCount=#l.pages
            self.page=page
            return type(value)=="string" and value or tostring(value or "")
        end)
    end

    local function controls(value,page,kind)
        local command=Util.trim(value):lower()
        if command==":q" then error(M.CANCELLED,0) end
        -- Single-page text fields must still accept literal colony labels such
        -- as "N" and "P". Page controls are useful only when help has pages.
        if kind=="ask" and (self.pageCount or 1)==1 then return false,page end
        if command=="n" then return true,math.min(self.pageCount or 1,page+1) end
        if command=="p" then return true,math.max(1,page-1) end
        return false,page
    end

    local function validate(spec,value)
        if spec.required and value=="" then return false,"A value is required. Type an answer or :q to cancel." end
        if type(spec.validate)=="function" then
            local ok,reason=spec.validate(value)
            if ok~=true then return false,tostring(reason or "Enter a valid value.") end
        end
        return true
    end

    function self.ask(spec)
        spec=spec or {}
        local page,errorMessage=1,nil
        while true do
            local value=input(spec,page,errorMessage,"ask",{})
            local moved,nextPage=controls(value,page,"ask")
            if moved then page=nextPage
            else
                value=Util.trim(value)
                if value=="" and spec.current~=nil then value=tostring(spec.current) end
                local ok,reason=validate(spec,value)
                if ok then return value end
                errorMessage=reason
            end
        end
    end

    function self.choose(spec)
        spec=spec or {}
        local choices={}
        for _,choice in ipairs(spec.choices or {}) do
            if type(choice)=="string" then choices[#choices+1]={label=choice,value=choice}
            elseif type(choice)=="table" and choice.value~=nil then
                choices[#choices+1]={label=tostring(choice.label or choice.value),value=tostring(choice.value),
                    detail=choice.detail and tostring(choice.detail) or nil}
            end
        end
        if #choices==0 and not spec.allowNone then
            error("No choices are available for "..tostring(spec.label or spec.title or "this setup step")..". Connect the required hardware, then restart setup.",0)
        end
        local current=spec.current~=nil and tostring(spec.current) or nil
        local currentAvailable=current=="" and spec.allowNone
        for _,choice in ipairs(choices) do
            if choice.value==current then currentAvailable=true;break end
        end
        local page,errorMessage=1,nil
        while true do
            local answer=input(spec,page,errorMessage,"choose",choices)
            local moved,nextPage=controls(answer,page,"choose")
            if moved then page=nextPage
            else
                answer=Util.trim(answer)
                local value
                if answer=="" then
                    if currentAvailable then value=current
                    elseif #choices==1 then value=choices[1].value
                    elseif #choices==0 and spec.allowNone then value="" end
                elseif answer=="0" and spec.allowNone then value=""
                else
                    local number=tonumber(answer)
                    if number and number%1==0 and number>=1 and number<=#choices then value=choices[number].value end
                end
                if value~=nil then
                    -- "None" is an explicit allowed answer even when choosing
                    -- a peripheral is otherwise required by the workflow.
                    local ok,reason
                    if value=="" and spec.allowNone then ok=true
                    else ok,reason=validate(spec,value) end
                    if ok then return value end
                    errorMessage=reason
                else errorMessage="Enter a listed number"..(spec.allowNone and ", 0 for none" or "")..", or :q to cancel." end
            end
        end
    end

    function self.notice(spec)
        spec=spec or {}
        local page,errorMessage=1,nil
        while true do
            local value=input(spec,page,errorMessage,"notice",{})
            local moved,nextPage=controls(value,page,"notice")
            if moved then page=nextPage
            elseif Util.trim(value)=="" then
                if self.page<self.pageCount then page=self.page+1;errorMessage=nil
                else return end
            else errorMessage="Press Enter to continue, N/P for pages, or :q to cancel." end
        end
    end

    function self.setMonitor() return true end
    function self.close()
        blinkOff()
        if type(term.redirect)=="function" then term.redirect(original) end
    end
    return self
end

return M
