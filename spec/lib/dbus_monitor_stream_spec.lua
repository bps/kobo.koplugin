require("spec.helper")

describe("D-Bus monitor stream safety", function()
    local Monitor, monitor, calls
    before_each(function()
        Monitor = dofile("src/lib/bluetooth/dbus_monitor.lua")
        monitor = Monitor:new()
        calls = {}
        monitor:registerCallback("test", function(address, properties)
            table.insert(calls, { address, properties })
        end)
    end)

    local signal = [[signal time=1.0 sender=:1.42 path=/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF; interface=org.freedesktop.DBus.Properties; member=PropertiesChanged
   string "org.bluez.Device1"
   array [
      dict entry(
         string "Connected"
         variant boolean true
      )
   ]
   array [
   ]
]]

    it("dispatches the final signal without waiting for another signal header", function()
        monitor:_consumeChunk(signal)
        monitor:_flushSignal()
        assert.are.same({ { "AA:BB:CC:DD:EE:FF", { Connected = true } } }, calls)
    end)

    it("retains split lines and nested arrays until the message is complete", function()
        local cut = assert(signal:find("boolean true", 1, true)) + 6
        monitor:_consumeChunk(signal:sub(1, cut))
        monitor:_flushSignal()
        assert.are.equal(0, #calls)
        monitor:_consumeChunk(signal:sub(cut + 1))
        monitor:_flushSignal()
        assert.are.equal(1, #calls)
    end)

    it("drains several messages in one chunk without losing buffered bodies", function()
        monitor:_consumeChunk(signal .. signal)
        monitor:_flushSignal()
        assert.are.equal(2, #calls)
    end)

    it("does not attach a late invalidated array to the next signal", function()
        local cut = assert(signal:find("   ]\n", 1, true)) + #"   ]\n" - 1
        monitor:_consumeChunk(signal:sub(1, cut))
        monitor:_flushSignal()
        assert.are.equal(1, #calls)
        monitor:_consumeChunk(signal:sub(cut + 1) .. signal)
        monitor:_flushSignal()
        assert.are.equal(2, #calls)
    end)

    it("bounds malformed output and resynchronizes at the next header", function()
        monitor:_consumeChunk(string.rep("x", 70000))
        monitor:_consumeChunk(signal)
        monitor:_flushSignal()
        assert.are.equal(1, #calls)
    end)

    it("closes only its owned transport and never invokes pkill", function()
        local closed = 0
        monitor.process = { close = function() closed = closed + 1 end }
        monitor.is_active = true
        clearExecutedCommands()
        monitor:stopMonitoring()
        monitor:stopMonitoring()
        assert.are.equal(1, closed)
        assert.are.equal(0, #getExecutedCommands())
    end)
end)
