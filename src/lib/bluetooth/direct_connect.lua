--- Direct-connect scheduling and retry policy for the Bluetooth controller.
--- Methods operate on the host controller's state to preserve its public API,
--- callback identities and device-instance handover behavior.
local DbusAdapter = require("src/lib/bluetooth/dbus_adapter")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local logger = require("logger")

local DirectConnect = {}

---
--- Stores the device whose input node was opened last; the direct connect loop
--- contacts it first after Bluetooth comes on (see _makeDirectConnectAttempt).
--- @param device_address string Bluetooth device address
function DirectConnect:_rememberLastConnectedDevice(device_address)
    local settings = self.plugin and self.plugin.settings

    if not settings or settings.bluetooth_last_connected == device_address then
        return
    end

    settings.bluetooth_last_connected = device_address
    self.plugin:saveSettings()
end

---
--- Whether a background connect attempt to this device is still in flight. That
--- attempt connects the device or fails within its time window; a second request
--- meanwhile would only show "busy" next to the connection the first one is
--- about to make.
--- @param device_address string Bluetooth device address
--- @return boolean
function DirectConnect:_isContactedInBackground(device_address)
    return self:_pendingDirectConnectSeconds() > 0 and self.direct_connect_last_attempt_address == device_address
end

---
--- Seconds the last background connect attempt may still occupy the stack
--- (a failed attempt takes about DIRECT_CONNECT_ATTEMPT_TICKS seconds).
--- @return number Seconds left, zero or negative when no attempt is pending
function DirectConnect:_pendingDirectConnectSeconds()
    return self.DIRECT_CONNECT_ATTEMPT_TICKS - (os.time() - self.direct_connect_last_attempt_time)
end

---
--- Starts the direct connect loop that runs alongside discovery-based auto-connect.
---
--- Discovery only notices a paired device once an inquiry cycle happens to see it
--- (20 to 30 seconds), and the Connected property arrives up to ten seconds after
--- the link is up. The loop is quicker on both ends. Every
--- DIRECT_CONNECT_TICK_SECONDS it looks for the input nodes of the paired devices
--- and opens the ones that exist right away (_openPresentInputNodes), which also
--- catches connections the remote initiates. With with_attempts it also asks the
--- stack to connect to a paired device directly, in the background
--- (_makeDirectConnectAttempt), and holds discovery back until the attempts have
--- had their time (_startDelayedDiscovery, _resumeDiscoveryAfterAttempt).
--- Attempts are only made right after Bluetooth comes on, not after a device
--- disconnects: contacting a device that was just switched off only keeps the
--- stack busy.
---
--- Loop state on the instance: direct_connect_task (the scheduled function, nil
--- while stopped), direct_connect_ticks (runs so far), direct_connect_attempts_left,
--- direct_connect_last_attempt_tick, _time and _address (the most recent
--- background attempt), direct_connect_discovery_pending (discovery still to be
--- started) and direct_connect_rearm_tick (the run on which discovery resumes
--- after an attempt).
---
--- Calling this while the loop runs keeps the running loop; with_attempts then
--- just renews its attempt budget.
--- @param with_attempts boolean Whether to make direct connection attempts
function DirectConnect:_startDirectConnect(with_attempts)
    if not self.input_handler or not self.device_manager then
        return
    end

    if with_attempts then
        self.direct_connect_attempts_left = self.DIRECT_CONNECT_MAX_ATTEMPTS
        self.direct_connect_ticks = 0
        self.direct_connect_last_attempt_tick = nil
    end

    if self.direct_connect_task then
        return
    end

    if not with_attempts then
        self.direct_connect_attempts_left = 0
        self.direct_connect_ticks = 0
    end

    logger.info("KoboBluetooth: Starting direct connect loop, attempts:", self.direct_connect_attempts_left)

    self.direct_connect_task = function()
        self:_runDirectConnectTick()
    end

    UIManager:scheduleIn(self.DIRECT_CONNECT_FIRST_TICK_SECONDS, self.direct_connect_task)
end

---
--- One run of the direct connect loop; schedules the next one while the loop is active.
function DirectConnect:_runDirectConnectTick()
    if not self.direct_connect_task or not self.is_auto_connect_active then
        return
    end

    local ticks = self.direct_connect_ticks

    self:_startDelayedDiscovery(ticks)

    local candidates = self:_openPresentInputNodes()

    if self:_isDirectAttemptDue(ticks) and #candidates > 0 then
        self:_makeDirectConnectAttempt(candidates, ticks)
    end

    self:_resumeDiscoveryAfterAttempt(ticks)

    self.direct_connect_ticks = ticks + 1

    if self.direct_connect_task then
        UIManager:scheduleIn(self.DIRECT_CONNECT_TICK_SECONDS, self.direct_connect_task)
    end
end

---
--- Opens the input node of every paired device whose node exists and returns the
--- paired devices that still have none, the candidates for a direct attempt.
--- The cached Connected flag is not consulted: right after Bluetooth comes back
--- on, the stack may still report the device that was connected before standby
--- as connected, which would skip it; an existing input node is what tells
--- whether a device is really connected.
--- @return table Array of paired devices without an input node
function DirectConnect:_openPresentInputNodes()
    local candidates = {}

    for _, device in ipairs(self.device_manager:getDevices()) do
        local has_name = device.name and device.name ~= ""

        if device.paired and has_name and not self:_hasOpenInputReader(device.address) then
            if self.input_handler:findInputNodeForDevice(device) then
                self:_onInputNodeDetected(device)
            else
                table.insert(candidates, device)
            end
        end
    end

    return candidates
end

---
--- Whether the loop should make a background connect attempt on this run: the
--- attempt budget is not used up and the previous attempt has had its time.
--- @param ticks number Runs of the loop so far
--- @return boolean
function DirectConnect:_isDirectAttemptDue(ticks)
    if self.direct_connect_attempts_left <= 0 then
        return false
    end

    return self.direct_connect_last_attempt_tick == nil
        or ticks - self.direct_connect_last_attempt_tick >= self.DIRECT_CONNECT_ATTEMPT_TICKS
end

---
--- Asks the stack to connect to one candidate in the background, the device used
--- last first: that is the device most likely to be switched on, and a direct
--- attempt reaches it within seconds. The stack handles one connection at a time
--- and a failed attempt occupies it for about DIRECT_CONNECT_ATTEMPT_TICKS
--- seconds, so one device per attempt. Discovery is stopped for the attempt,
--- because an attempt made while a scan runs tends to time out even against a
--- device that is on; _resumeDiscoveryAfterAttempt starts it again.
---
--- A direct attempt only reaches the device that was connected last; the stack
--- still knows how to page it. Another paired device is not reached this way
--- (the log shows timeouts even when it is on), whereas the scan sees it within
--- seconds and the connect that follows succeeds at once. So with several
--- candidates this is the only attempt, and the scan takes over.
--- @param candidates table Paired devices without an input node, at least one
--- @param ticks number Runs of the loop so far
function DirectConnect:_makeDirectConnectAttempt(candidates, ticks)
    self:_sortByLastConnected(candidates)

    local device = candidates[1]

    if self.is_discovery_active then
        DbusAdapter.stopDiscovery()
        self.is_discovery_active = false
    end

    self.direct_connect_discovery_pending = false
    self.direct_connect_rearm_tick = ticks + self.DIRECT_CONNECT_ATTEMPT_TICKS
    self.direct_connect_last_attempt_tick = ticks
    self.direct_connect_last_attempt_time = os.time()
    self.direct_connect_last_attempt_address = device.address

    if #candidates > 1 then
        self.direct_connect_attempts_left = 0
    else
        self.direct_connect_attempts_left = self.direct_connect_attempts_left - 1
    end

    self.device_manager:connectDeviceInBackground(device)
end

---
--- Starts discovery once the loop has run DIRECT_CONNECT_DISCOVERY_DELAY_TICKS
--- times without a background attempt claiming the radio first.
--- @param ticks number Runs of the loop so far
function DirectConnect:_startDelayedDiscovery(ticks)
    if not self.direct_connect_discovery_pending or ticks < self.DIRECT_CONNECT_DISCOVERY_DELAY_TICKS then
        return
    end

    self.direct_connect_discovery_pending = false
    self.is_discovery_active = DbusAdapter.startDiscovery()
end

---
--- Resumes discovery once a background attempt has had its time, so the
--- RSSI-based auto-connect finds whatever is switched on.
--- @param ticks number Runs of the loop so far
function DirectConnect:_resumeDiscoveryAfterAttempt(ticks)
    if not self.direct_connect_rearm_tick or ticks < self.direct_connect_rearm_tick then
        return
    end

    self.direct_connect_rearm_tick = nil
    logger.info("KoboBluetooth: Resuming discovery after direct connect attempt")
    self.is_discovery_active = DbusAdapter.startDiscovery()
end

---
--- Orders devices so that the one connected most recently comes first.
--- @param devices table Array of device information, sorted in place
function DirectConnect:_sortByLastConnected(devices)
    local last = self.plugin and self.plugin.settings and self.plugin.settings.bluetooth_last_connected

    table.sort(devices, function(a, b)
        if (a.address == last) ~= (b.address == last) then
            return a.address == last
        end

        return a.address < b.address
    end)
end

---
--- Stops the direct connect loop.
function DirectConnect:_stopDirectConnect()
    self.direct_connect_attempts_left = 0
    self.direct_connect_discovery_pending = false
    self.direct_connect_rearm_tick = nil

    if self.direct_connect_task then
        UIManager:unschedule(self.direct_connect_task)
        self.direct_connect_task = nil
        logger.dbg("KoboBluetooth: Stopped direct connect loop")
    end
end

---
--- Defers a connection request until a pending background connect attempt has
--- had its time: the attempt occupies the stack, and any other request fails
--- with "in progress" meanwhile. If the attempt connects the requested device in
--- the meantime, nothing more is done. direct_connect_wait_over marks the
--- deferred request so that it is not deferred a second time.
--- @param address string The Bluetooth address of the device to connect to
--- @param show_notification boolean Whether to tell the user about the wait
--- @param wait_seconds number Seconds until the pending attempt has had its time
--- @param automatic boolean Whether to apply the automatic retry cooldown
function DirectConnect:_connectAfterPendingAttempt(address, show_notification, wait_seconds, automatic)
    logger.info("KoboBluetooth: Waiting", wait_seconds, "s for a pending background connect before connecting")

    if self.deferred_connect_task then
        UIManager:unschedule(self.deferred_connect_task)
    end

    local task
    task = function()
        if self.deferred_connect_task ~= task then
            return
        end

        self.deferred_connect_task = nil

        if self:_hasOpenInputReader(address) then
            logger.info("KoboBluetooth: Device connected while waiting, nothing more to do:", address)

            return
        end

        self.direct_connect_wait_over = true
        self:connectToDevice(address, show_notification, automatic)
        self.direct_connect_wait_over = false
    end

    self.deferred_connect_task = task
    UIManager:scheduleIn(wait_seconds, task)

    if show_notification then
        UIManager:show(InfoMessage:new({
            text = _("Bluetooth is busy, connecting in a moment..."),
            timeout = wait_seconds,
        }))
    end
end

return DirectConnect
