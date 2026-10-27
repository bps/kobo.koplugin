--- An owned dbus-monitor child with an unbuffered, non-blocking result pipe.
local Subprocess = require("src/lib/bluetooth/subprocess")
local UIManager = require("ui/uimanager")
local bit = require("bit")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
require("ffi/posix_h")

local C = ffi.C
local MonitorProcess = {}

function MonitorProcess.start()
    local pid, fd = ffiutil.runInSubProcess(function(_, write_fd)
        Subprocess.detachFromStorage(write_fd)
        if C.dup2(write_fd, 1) < 0 then
            C._exit(127)
        end
        if write_fd ~= 1 then
            C.close(write_fd)
        end
        local command = "dbus-monitor"
        local filter = "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged'"
        local argv = ffi.new("char *[4]", {
            ffi.cast("char *", command),
            ffi.cast("char *", "--system"),
            ffi.cast("char *", filter),
            nil,
        })
        C.execvp(command, argv)
        C._exit(127)
    end, true, false)
    if not pid then
        return nil
    end

    local process = { pid = pid, fd = fd }
    function process:close()
        if not self.pid then
            return
        end
        local child = self.pid
        self.pid = nil
        C.close(self.fd)
        self.fd = nil
        -- This is a direct, unreaped child: its PID cannot belong to another process.
        C.kill(child, 9) -- SIGKILL, as used by ffi/util.terminateSubProcess.
        local function reap()
            if not ffiutil.isSubProcessDone(child) then
                UIManager:scheduleIn(0.1, reap)
            end
        end
        reap()
    end
    local flags = C.fcntl(fd, C.F_GETFL, 0)
    if flags < 0 or C.fcntl(fd, C.F_SETFL, ffi.cast("int", bit.bor(flags, C.O_NONBLOCK))) < 0 then
        process:close()
        return nil
    end

    function process:read()
        local buffer = ffi.new("char[4096]")
        local count = tonumber(C.read(self.fd, buffer, 4096))
        if count > 0 then
            return ffi.string(buffer, count)
        end
        if count < 0 and (ffi.errno() == C.EAGAIN or ffi.errno() == C.EINTR) then
            return nil
        end
        return false -- EOF or fatal read error.
    end
    return process
end

return MonitorProcess
