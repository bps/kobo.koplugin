local runtime = dofile("test/integration/runtime.lua")
local ffi = require("ffi")
local util = require("ffi/util")
local tasks = {}
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_, _, callback) tasks[callback] = true end,
        unschedule = function(_, callback) tasks[callback] = nil end,
    }
end
local Monitor = require("src/lib/bluetooth/dbus_monitor")
local Process = require("src/lib/bluetooth/monitor_process")

local function drain()
    for _ = 1, 100 do
        local pending = tasks
        tasks = {}
        for callback in pairs(pending) do callback() end
        if not next(tasks) then return end
        util.usleep(10000)
    end
    error("process cleanup did not finish")
end

runtime.test("handles split writes and a final signal without blocking on the writer", function()
    local monitor = Monitor:new()
    local calls = 0
    monitor:registerCallback("test", function(address, properties)
        assert(address == "AA:BB:CC:DD:EE:FF" and properties.Connected == true)
        calls = calls + 1
    end)
    runtime.cleanup(function() monitor:stopMonitoring(); drain() end)
    assert(monitor:startMonitoring())
    for _ = 1, 100 do
        monitor:_pollForEvents()
        if calls > 0 then break end
        util.usleep(10000)
    end
    assert(calls == 1, "did not receive final signal from still-running writer")
    assert(not util.isSubProcessDone(monitor.process.pid), "writer should still be running")
end)

runtime.test("stops and reaps only its own child", function()
    local first, second = assert(Process.start()), assert(Process.start())
    local first_pid, second_pid = first.pid, second.pid
    runtime.cleanup(function() first:close(); second:close(); drain() end)
    first:close()
    drain()
    assert(util.isSubProcessDone(first_pid), "first child was not reaped")
    assert(ffi.C.kill(second_pid, 0) == 0, "second child was killed")
    assert(not util.isSubProcessDone(second_pid), "second child exited unexpectedly")
end)

runtime.test("an empty open stream reports would-block rather than EOF", function()
    local process = assert(Process.start())
    runtime.cleanup(function() process:close(); drain() end)
    local empty = false
    for _ = 1, 16 do
        local chunk = process:read()
        assert(chunk ~= false, "an empty live pipe was treated as EOF")
        if chunk == nil then empty = true; break end
    end
    assert(empty, "stream never reported would-block")
    assert(not util.isSubProcessDone(process.pid))
end)

runtime.test("EOF stops the monitor and closes its read descriptor", function()
    local monitor = Monitor:new()
    runtime.cleanup(function() monitor:stopMonitoring(); drain() end)
    assert(monitor:startMonitoring())
    local fd, pid = monitor.monitor_fd, monitor.process.pid
    ffi.C.kill(pid, 9)
    for _ = 1, 100 do
        monitor:_pollForEvents()
        if not monitor:isActive() then break end
        util.usleep(10000)
    end
    assert(not monitor:isActive(), "EOF left the polling task active")
    assert(monitor.monitor_fd == nil)
    assert(ffi.C.fcntl(fd, ffi.C.F_GETFL, 0) == -1, "read descriptor leaked")
end)
runtime.finish()
