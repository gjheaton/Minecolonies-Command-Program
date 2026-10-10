local S=require("tests.support")
local D={}

function D.surface(width,height)
    local self={width=width,height=height,lines={},writes=0,clears=0}
    local x,y=1,1
    function self.getSize() if self.failed then error("detached monitor") end;return self.width,self.height end
    function self.setTextColor(value) if self.failed then error("detached monitor") end;self.textColor=value end
    function self.setBackgroundColor(value) if self.failed then error("detached monitor") end;self.backgroundColor=value end
    function self.getTextColor() return self.textColor or 1 end
    function self.getBackgroundColor() return self.backgroundColor or 32768 end
    function self.getCursorPos() return x,y end
    function self.setCursorBlink(value) self.cursorBlink=value end
    function self.getCursorBlink() return self.cursorBlink==true end
    function self.clearLine() self.lines[y]=string.rep(" ",self.width) end
    function self.isColor() return true end
    function self.setTextScale(value) self.scale=value end
    function self.setCursorPos(a,b)
        assert(a>=1 and a<=self.width and b>=1 and b<=self.height,"draw outside monitor bounds")
        x,y=a,b
    end
    function self.write(text)
        assert(#text<=self.width-x+1,"text exceeds available monitor width")
        local line=self.lines[y] or string.rep(" ",self.width)
        self.lines[y]=line:sub(1,x-1)..text..line:sub(x+#text);self.writes=self.writes+1
    end
    function self.clear() if self.failed then error("detached monitor") end;self.lines={};self.clears=self.clears+1 end
    function self.dump() local rows={};for i=1,self.height do rows[#rows+1]=self.lines[i] or "" end;return table.concat(rows,"\n") end
    return self
end

function D.world()
    local w=S.world()
    _G.colors={white=1,orange=2,magenta=4,lightBlue=8,yellow=16,lime=32,pink=64,gray=128,
        lightGray=256,cyan=512,purple=1024,blue=2048,brown=4096,green=8192,red=16384,black=32768}
    _G.keys={enter=28,numPadEnter=156,escape=1,backspace=14,delete=211}
    local terminal=D.surface(51,19);_G.term=terminal;term.current=function() return terminal end
    w.terminal=terminal
    function w.monitor(id,name,width,height)
        local monitor=D.surface(width or 100,height or 38)
        w.device(id,name,"monitor",monitor);return monitor
    end
    return w
end

function D.route(id,monitorName)
    return {id=id,label="Colony "..id,deliveryChest="D"..id,returnChest="R"..id,
        deliveryChannel="delivery-"..id,returnChannel="returns-"..id,monitorName=monitorName}
end
return D
