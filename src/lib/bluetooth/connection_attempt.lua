---
--- One bounded Bluetooth connection attempt. All D-Bus work runs in a
--- double-forked child; the UI polls a one-byte result without blocking.
local DbusAdapter = require("src/lib/bluetooth/dbus_adapter")
local DeviceParser = require("src/lib/bluetooth/device_parser")
local Subprocess = require("src/lib/bluetooth/subprocess")
local UIManager = require("ui/uimanager")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local time = require("ui/time")

require("ffi/posix_h")

local ConnectionAttempt = {
    POLL_INTERVAL = 0.1,
    MAX_POLLS = 130,
    busy_until = 0,
}

---
--- Starts Connect followed by verification of the live Connected property.
--- A method error (including AlreadyConnected) is not conclusive: live state wins.
--- @param device table Device with address and path
--- @param on_complete function Called once with a verified success boolean
--- @return table|nil Cancellable attempt, or nil if the child could not start
function ConnectionAttempt.start(device, on_complete)
    if
        (ConnectionAttempt.current and ConnectionAttempt.current.active)
        or time.now() < ConnectionAttempt.busy_until
        or not DbusAdapter.prepare()
    then
        return nil
    end

    local pid, fd = ffiutil.runInSubProcess(function(_, write_fd)
        Subprocess.detachFromStorage(write_fd)
        DbusAdapter.connectDevice(device.path)
        local output = DbusAdapter.getManagedObjects()
        local connected = false

        for _, live in ipairs(DeviceParser.parseDiscoveredDevices(output or "")) do
            if live.path == device.path and live.connected then
                connected = true

                break
            end
        end

        ffiutil.writeToFD(write_fd, connected and "1" or "0", true)
    end, true, true)

    if not pid then
        return nil
    end

    local attempt = { active = true, fd = fd }
    local polls = 0
    local deadline = time.now() + time.s(ConnectionAttempt.MAX_POLLS * ConnectionAttempt.POLL_INTERVAL)
    ConnectionAttempt.busy_until = deadline
    ConnectionAttempt.current = attempt

    ---
    --- Stops tracking the child and closes its result pipe.
    --- The child is auto-reaped and its D-Bus calls have explicit reply timeouts.
    --- Keep the global reservation until its deadline: cancellation does not
    --- cancel an in-flight D-Bus call, so an immediate retry would overlap it.
    function attempt:cancel()
        if not self.active then
            return
        end

        self.active = false
        UIManager:unschedule(self.poll)
        ffi.C.close(self.fd)
    end

    attempt.poll = function()
        if not attempt.active then
            return
        end

        polls = polls + 1
        local available = ffiutil.getNonBlockingReadSize(fd)

        if available and available > 0 then
            local result = ffi.new("char[1]")
            local count = ffi.C.read(fd, result, 1)
            attempt:cancel()
            ConnectionAttempt.busy_until = 0
            on_complete(count == 1 and result[0] == string.byte("1"))

            return
        end

        if polls >= ConnectionAttempt.MAX_POLLS or time.now() >= deadline then
            attempt:cancel()
            ConnectionAttempt.busy_until = 0
            on_complete(false)

            return
        end

        UIManager:scheduleIn(ConnectionAttempt.POLL_INTERVAL, attempt.poll)
    end

    UIManager:scheduleIn(ConnectionAttempt.POLL_INTERVAL, attempt.poll)

    return attempt
end

return ConnectionAttempt
