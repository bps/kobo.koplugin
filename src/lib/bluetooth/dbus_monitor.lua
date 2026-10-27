---
--- DBus monitor for Bluetooth device property changes.
--- Monitors D-Bus signals for property changes on Bluetooth devices using a non-blocking
--- poll() pattern similar to bluetooth_input_reader.lua.
---
--- This provides event-driven detection of device connections, disconnections, and
--- RSSI changes without continuous polling of device state.

local MonitorProcess = require("src/lib/bluetooth/monitor_process")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local DbusMonitor = {
    process = nil,
    monitor_fd = nil,
    property_callbacks = {}, -- key -> {callback = function, priority = number}
    sorted_callbacks = {}, -- array of {key, callback, priority} sorted by priority
    is_active = false,
    poll_task = nil,
    current_signal = {},
}

---
--- Creates a new DbusMonitor instance.
--- @return table New DbusMonitor instance
function DbusMonitor:new()
    local instance = {
        process = nil,
        monitor_fd = nil,
        pending = "",
        signal_bytes = 0,
        depth = 0,
        property_callbacks = {}, -- key -> {callback = function, priority = number}
        sorted_callbacks = {}, -- array of {key, callback, priority} sorted by priority
        is_active = false,
        poll_task = nil,
        current_signal = {},
    }
    setmetatable(instance, self)
    self.__index = self

    return instance
end

---
--- Registers a universal callback for property changes on any device.
--- The callback will be invoked for all property changes from any Bluetooth device.
--- Callbacks are executed in priority order (lower priority numbers execute first).
--- @param key string Unique identifier for this callback (e.g., "auto_detection", "auto_connect")
--- @param callback function Callback function(device_address, properties) where device_address is the device and properties is a table of changed properties
--- @param priority number Optional priority for execution order (default: 100). Lower numbers execute first. Use 0-19 for critical operations like cache sync.
function DbusMonitor:registerCallback(key, callback, priority)
    if not key or not callback then
        logger.warn("DbusMonitor: Invalid key or callback")

        return
    end

    priority = priority or 100

    self.property_callbacks[key] = {
        callback = callback,
        priority = priority,
    }

    self:_rebuildSortedCallbacks()

    logger.dbg("DbusMonitor: Registered callback:", key, "with priority:", priority)
end

---
--- Unregisters a callback by its key.
--- @param key string Unique identifier for the callback
function DbusMonitor:unregisterCallback(key)
    if not key then
        return
    end

    self.property_callbacks[key] = nil

    self:_rebuildSortedCallbacks()

    logger.dbg("DbusMonitor: Unregistered callback:", key)
end

---
--- Rebuilds the sorted callbacks list from the property_callbacks map.
--- Called after registration or unregistration to maintain sorted order.
function DbusMonitor:_rebuildSortedCallbacks()
    self.sorted_callbacks = {}

    for key, callback_info in pairs(self.property_callbacks) do
        table.insert(self.sorted_callbacks, {
            key = key,
            callback = callback_info.callback,
            priority = callback_info.priority,
        })
    end

    table.sort(self.sorted_callbacks, function(a, b)
        return a.priority < b.priority
    end)

    logger.dbg("DbusMonitor: Rebuilt sorted callbacks list,", #self.sorted_callbacks, "callbacks")
end

--- Starts an owned monitor subprocess.
function DbusMonitor:_spawnProcess()
    return MonitorProcess.start()
end

function DbusMonitor:startMonitoring()
    if self.is_active then
        return true
    end
    self.process = self:_spawnProcess()
    if not self.process then
        return false
    end
    self.monitor_fd = self.process.fd
    self.is_active = true
    self:_schedulePoll()
    return true
end

function DbusMonitor:stopMonitoring()
    self.is_active = false
    if self.poll_task then
        UIManager:unschedule(self.poll_task)
        self.poll_task = nil
    end
    if self.process then
        self.process:close()
        self.process = nil
    end
    self.monitor_fd = nil
    self.current_signal = {}
    self.pending = ""
    self.signal_bytes = 0
    self.depth = 0
end

---
--- Checks if monitoring is active.
--- @return boolean True if monitoring is active, false otherwise
function DbusMonitor:isActive()
    return self.is_active
end

---
--- Schedules the next poll iteration.
function DbusMonitor:_schedulePoll()
    if not self.is_active then
        return
    end

    self.poll_task = function()
        if not self.is_active or not self.process then
            return
        end

        self:_pollForEvents()

        if self.is_active then
            UIManager:scheduleIn(0.1, self.poll_task)
        end
    end

    UIManager:scheduleIn(0.1, self.poll_task)
end

--- Reads bounded chunks without mixing stdio buffers and kernel readiness.
function DbusMonitor:_pollForEvents()
    if not self.process then
        return
    end
    for _ = 1, 16 do
        local chunk = self.process:read()
        if chunk == nil then
            -- dbus-monitor does not separate every message with a blank line.
            -- Wait for a quiet poll before dispatching the last balanced message.
            self:_flushSignal()
            return
        elseif chunk == false then
            self:_flushSignal()
            self:stopMonitoring()
            return
        end
        self:_consumeChunk(chunk)
    end
end

function DbusMonitor:_consumeChunk(chunk)
    self.pending = self.pending .. chunk
    if #self.pending + self.signal_bytes > 65536 then
        self.pending = ""
        self.current_signal = {}
        self.signal_bytes = 0
        self.depth = 0
        logger.warn("DbusMonitor: Dropping oversized signal")
        return
    end
    while true do
        local ending = self.pending:find("\n", 1, true)
        if not ending then
            return
        end
        local line = self.pending:sub(1, ending - 1)
        self.pending = self.pending:sub(ending + 1)
        self:_processSignalLine(line)
    end
end

function DbusMonitor:_flushSignal(at_boundary)
    if (at_boundary or self.pending == "") and self.depth == 0 and #self.current_signal > 1 then
        self:_parseAndDispatchSignal(self.current_signal)
        self.current_signal = {}
        self.signal_bytes = 0
    end
end

--- Tracks nested D-Bus containers without counting brackets in quoted values.
function DbusMonitor:_processSignalLine(line)
    if line:match("^signal%s") then
        self:_flushSignal(true)
        self.current_signal = { line }
        self.signal_bytes = #line
        self.depth = 0
        return true
    end
    if #self.current_signal == 0 then
        return false
    end
    table.insert(self.current_signal, line)
    self.signal_bytes = self.signal_bytes + #line
    local quoted, escaped = false, false
    for character in line:gmatch(".") do
        if escaped then
            escaped = false
        elseif quoted and character == "\\" then
            escaped = true
        elseif character == '"' then
            quoted = not quoted
        elseif not quoted then
            if character == "[" or character == "(" or character == "{" then
                self.depth = self.depth + 1
            elseif character == "]" or character == ")" or character == "}" then
                self.depth = self.depth - 1
            end
        end
    end
    if line:match("^%s*$") then
        self:_flushSignal(true)
        return true
    end
    return false
end

---
--- Parses a complete D-Bus signal and dispatches to all registered callbacks.
--- @param signal_lines table Array of lines comprising the signal
function DbusMonitor:_parseAndDispatchSignal(signal_lines)
    local signal_text = table.concat(signal_lines, "\n")

    logger.dbg("DbusMonitor: Parsing signal block")

    local device_address = self:_extractDeviceAddress(signal_text)

    if not device_address then
        logger.dbg("DbusMonitor: No device address found in signal")

        return
    end

    logger.dbg("DbusMonitor: Signal for device:", device_address)

    local properties = self:_extractProperties(signal_text)

    if not next(properties) then
        logger.dbg("DbusMonitor: No properties found in signal")

        return
    end

    logger.info("DbusMonitor: Property changes for", device_address, ":", self:_propertiesToString(properties))

    -- Invoke callbacks in pre-sorted priority order
    for _, callback_info in ipairs(self.sorted_callbacks) do
        logger.dbg(
            "DbusMonitor: Invoking callback:",
            callback_info.key,
            "(priority:",
            callback_info.priority,
            ") for device:",
            device_address
        )

        local ok, err = pcall(callback_info.callback, device_address, properties)

        if not ok then
            logger.warn("DbusMonitor: Callback error for", callback_info.key, ":", err)
        end
    end

    if #self.sorted_callbacks == 0 then
        logger.dbg("DbusMonitor: No callbacks registered")
    end
end

---
--- Extracts the Bluetooth device address from a D-Bus signal.
--- @param signal_text string The complete signal text
--- @return string|nil Device address in format "XX:XX:XX:XX:XX:XX" or nil
function DbusMonitor:_extractDeviceAddress(signal_text)
    local address = signal_text:match("path=/org/bluez/hci0/dev_([A-F0-9_]+)")

    if address then
        return address:gsub("_", ":")
    end

    return nil
end

---
--- Extracts properties from a D-Bus signal.
--- @param signal_text string The complete signal text
--- @return table Table of property names to values
function DbusMonitor:_extractProperties(signal_text)
    local properties = {}

    local in_array = false

    for line in signal_text:gmatch("[^\n]+") do
        if line:match("array%s*%[") then
            in_array = true
        elseif line:match("^%s*%]") then
            in_array = false
        elseif in_array then
            local key = line:match('string%s+"([^"]+)"')

            if key then
                local value_line = signal_text:match(key .. '"\n%s*variant%s+([^\n]+)')

                if value_line then
                    local value_type, value = value_line:match("(%w+)%s+(.+)")

                    if value_type == "boolean" then
                        properties[key] = value:match("true") ~= nil
                    elseif value_type == "int32" or value_type == "int16" then
                        properties[key] = tonumber(value)
                    elseif value_type == "string" then
                        properties[key] = value:match('"([^"]*)"') or value
                    else
                        properties[key] = value
                    end

                    logger.dbg("DbusMonitor: Parsed property:", key, "=", properties[key])
                end
            end
        end
    end

    return properties
end

---
--- Converts properties table to a human-readable string for logging.
--- @param properties table Properties table
--- @return string String representation
function DbusMonitor:_propertiesToString(properties)
    local parts = {}

    for key, value in pairs(properties) do
        table.insert(parts, string.format("%s=%s", key, tostring(value)))
    end

    return table.concat(parts, ", ")
end

---
--- Gets the number of registered callbacks.
--- @return number Number of callbacks
function DbusMonitor:getCallbackCount()
    local count = 0

    for _ in pairs(self.property_callbacks) do
        count = count + 1
    end

    return count
end

---
--- Checks if a callback with the given key is registered.
--- @param key string The callback key to check for
--- @return boolean True if callback is registered, false otherwise
function DbusMonitor:hasCallback(key)
    return self.property_callbacks[key] ~= nil
end

return DbusMonitor
