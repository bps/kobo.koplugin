---
-- Unit tests for DeviceManager module.

require("spec.helper")
local time = require("ui/time")

describe("DeviceManager", function()
    local DeviceManager
    local UIManager

    setup(function()
        DeviceManager = require("src/lib/bluetooth/device_manager")
        UIManager = require("ui/uimanager")
    end)

    before_each(function()
        resetAllMocks()
        UIManager:_reset()
    end)

    describe("new", function()
        it("should create a new instance with empty cache", function()
            local manager = DeviceManager:new()

            assert.is_not_nil(manager)
            assert.is_table(manager.devices_cache)
            assert.are.equal(0, #manager.devices_cache)
        end)
    end)

    describe("scanForDevices", function()
        it("should show scanning message", function()
            setMockExecuteResult(0)
            setMockPopenOutput("")

            local manager = DeviceManager:new()
            manager:scanForDevices(1)

            assert.are.equal(1, #UIManager._show_calls)
            assert.is_not_nil(UIManager._show_calls[1].widget.text)
        end)

        it("should call callback with nil and show error if discovery fails to start", function()
            setMockExecuteResult(1)

            local manager = DeviceManager:new()
            local callback_called = false
            local callback_devices = "not_called"

            manager:scanForDevices(1, function(devices)
                callback_called = true
                callback_devices = devices
            end)

            assert.is_true(callback_called)
            assert.is_nil(callback_devices)
            assert.are.equal(2, #UIManager._show_calls)
        end)

        it("should schedule callback that parses devices on success", function()
            setMockExecuteResult(0)
            local dbus_output = [[
object path "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"
  string "Address"
    variant string "AA:BB:CC:DD:EE:FF"
  string "Name"
    variant string "Test Device"
  string "Paired"
    variant boolean true
  string "Connected"
    variant boolean false
]]
            setMockPopenOutput(dbus_output)

            local manager = DeviceManager:new()
            local callback_called = false
            local callback_devices = nil

            manager:scanForDevices(1, function(devices)
                callback_called = true
                callback_devices = devices
            end)

            -- Callback should be scheduled but not called yet
            assert.is_false(callback_called)
            assert.are.equal(1, #UIManager._scheduled_tasks)

            -- Clear executed commands from startDiscovery
            clearExecutedCommands()

            -- Invoke the scheduled callback
            local scheduled_callback = UIManager._scheduled_tasks[1].callback
            scheduled_callback()

            assert.is_true(callback_called)
            assert.is_not_nil(callback_devices)
            assert.are.equal(1, #callback_devices)
            assert.are.equal("Test Device", callback_devices[1].name)

            -- Verify stopDiscovery was called
            local commands = getExecutedCommands()
            assert.are.equal(1, #commands)
            assert.is_true(commands[1]:match("StopDiscovery") ~= nil)
        end)

        it("should use default scan duration if not provided", function()
            setMockExecuteResult(0)
            setMockPopenOutput("")

            local manager = DeviceManager:new()
            manager:scanForDevices()

            assert.is_not_nil(manager)
        end)

        it("should call callback with nil when getManagedObjects fails", function()
            setMockExecuteResult(0)
            setMockPopenFailure()

            local manager = DeviceManager:new()
            local callback_called = false
            local callback_devices = "not_called"

            manager:scanForDevices(1, function(devices)
                callback_called = true
                callback_devices = devices
            end)

            -- Clear executed commands from startDiscovery
            clearExecutedCommands()

            -- Invoke the scheduled callback
            assert.are.equal(1, #UIManager._scheduled_tasks)
            local scheduled_callback = UIManager._scheduled_tasks[1].callback
            scheduled_callback()

            assert.is_true(callback_called)
            assert.is_nil(callback_devices)

            -- Verify stopDiscovery was called
            local commands = getExecutedCommands()
            assert.are.equal(1, #commands)
            assert.is_true(commands[1]:match("StopDiscovery") ~= nil)
        end)

        it("should use default empty callback if none provided", function()
            setMockExecuteResult(0)
            setMockPopenOutput("")

            local manager = DeviceManager:new()
            -- Should not error when no callback provided
            manager:scanForDevices(1)

            assert.are.equal(1, #UIManager._scheduled_tasks)
            local scheduled_callback = UIManager._scheduled_tasks[1].callback
            -- Should not error when invoking default callback
            scheduled_callback()
        end)
    end)

    describe("connectDevice", function()
        local device, manager

        local function liveState(connected)
            setMockPopenOutput([[
object path "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"
  string "Address"
    variant string "AA:BB:CC:DD:EE:FF"
  string "Name"
    variant string "Test Device"
  string "Paired"
    variant boolean true
  string "Connected"
    variant boolean ]] .. tostring(connected))
        end

        before_each(function()
            device = {
                path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF",
                name = "Test Device",
                address = "AA:BB:CC:DD:EE:FF",
            }
            manager = DeviceManager:new()
            liveState(true)
        end)

        after_each(function()
            manager:cancelConnection()
        end)

        it("returns before notifying or opening input devices", function()
            local callback = spy.new(function() end)
            assert.is_true(manager:connectDevice(device, callback))
            assert.spy(callback).was_not_called()
            assert.are.equal(0, #UIManager._show_calls)
            UIManager:executeScheduledTasks(1)
            assert.spy(callback).was_called_with(device)
            assert.are.equal(1, #UIManager._show_calls)
            assert.is_true(manager.devices_cache[device.address].connected)
        end)

        it("verifies live state rather than trusting a successful method reply", function()
            liveState(false)
            local callback = spy.new(function() end)
            assert.is_true(manager:connectDevice(device, callback))
            UIManager:executeScheduledTasks(1)
            assert.spy(callback).was_not_called()
            assert.is_true(UIManager._show_calls[1].text:match("Failed") ~= nil)
        end)

        it("accepts an AlreadyConnected-style method error when live state is connected", function()
            setMockExecuteResult(1)
            local callback = spy.new(function() end)
            manager:connectDevice(device, callback)
            UIManager:executeScheduledTasks(1)
            assert.spy(callback).was_called(1)
        end)

        it("serializes attempts across all remotes", function()
            manager:connectDevice(device)
            assert.is_false(manager:connectDevice(device))
            assert.is_false(manager:connectDevice({
                path = "/org/bluez/hci0/dev_11_22_33_44_55_66",
                address = "11:22:33:44:55:66",
            }))
            UIManager:executeScheduledTasks(1)
            assert.is_true(manager:connectDevice(device))
        end)

        it("throttles automatic retries after failure but permits an explicit retry", function()
            liveState(false)
            manager:connectDevice(device, nil, true)
            UIManager:executeScheduledTasks(1)
            assert.is_false(manager:connectDevice(device, nil, true))
            assert.is_true(manager:connectDevice(device))
        end)

        it("allows automatic retries after the cooldown expires", function()
            liveState(false)
            manager:connectDevice(device, nil, true)
            UIManager:executeScheduledTasks(1)
            local clock = stub(time, "now", function()
                return manager.connection_cooldowns[device.address] + time.s(1)
            end)
            assert.is_true(manager:connectDevice(device, nil, true))
            clock:revert()
        end)

        it("does not call stale completion callbacks after cleanup", function()
            local callback = spy.new(function() end)
            manager:connectDevice(device, callback)
            local attempt = manager.connection_attempt
            local stale = attempt.poll
            manager:cancelConnection()
            stale()
            UIManager:executeScheduledTasks(1)
            assert.spy(callback).was_not_called()
            assert.is_false(attempt.active)
            assert.is_nil(manager.connection_attempt)
            assert.are.equal(0, #UIManager._show_calls)
        end)

        it("handles subprocess startup failure without leaving an active slot", function()
            setMockRunInSubProcessResult(false)
            assert.is_false(manager:connectDevice(device))
            assert.is_nil(manager.connection_attempt)
            assert.is_nil(manager.connection_token)
        end)

        it("times out a child that never produces a result", function()
            local ffiutil = require("ffi/util")
            local unreadable = stub(ffiutil, "getNonBlockingReadSize", function()
                return 0
            end)
            local callback = spy.new(function() end)
            manager:connectDevice(device, callback)
            UIManager:executeScheduledTasks(150)
            assert.spy(callback).was_not_called()
            assert.is_nil(manager.connection_attempt)
            assert.is_nil(next(UIManager._scheduled_tasks))
            assert.are.equal(1, #UIManager._show_calls)
            unreadable:revert()
        end)

        it("uses an available verified result even when completion polling is delayed", function()
            local callback = spy.new(function() end)
            manager:connectDevice(device, callback)
            local clock = stub(time, "now", function()
                return 9999999999
            end)
            UIManager:executeScheduledTasks(1)
            clock:revert()
            assert.spy(callback).was_called(1)
            assert.is_nil(manager.connection_attempt)
        end)

        it("does not verify another device's connection as success", function()
            setMockPopenOutput([[
object path "/org/bluez/hci0/dev_11_22_33_44_55_66"
  string "Address"
    variant string "11:22:33:44:55:66"
  string "Connected"
    variant boolean true
]])
            local callback = spy.new(function() end)
            manager:connectDevice(device, callback)
            UIManager:executeScheduledTasks(1)
            assert.spy(callback).was_not_called()
        end)

        it("does not burn the cooldown when no attempt can start", function()
            setMockRunInSubProcessResult(false)
            assert.is_false(manager:connectDevice(device, nil, true))
            assert.is_nil(manager.connection_cooldowns[device.address])
            setMockRunInSubProcessResult(12345)
            assert.is_true(manager:connectDevice(device, nil, true))
        end)

        it("does not cancel a connection when disconnecting a different remote", function()
            local callback = spy.new(function() end)
            manager:connectDevice(device, callback)
            manager:disconnectDevice({
                address = "11:22:33:44:55:66",
                path = "/org/bluez/hci0/dev_11_22_33_44_55_66",
                name = "Another remote",
            })
            assert.is_not_nil(manager.connection_attempt)
            UIManager:executeScheduledTasks(1)
            assert.spy(callback).was_called(1)
        end)

        it("reports completion once even if a scheduled callback runs again", function()
            local callback = spy.new(function() end)
            manager:registerDeviceConnectCallback(callback)
            manager:connectDevice(device)
            local poll = manager.connection_attempt.poll
            poll()
            poll()
            assert.spy(callback).was_called(1)
        end)
    end)

    describe("disconnectDevice", function()
        it("should show success message on successful disconnection", function()
            setMockExecuteResult(0)

            local device = {
                path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF",
                name = "Test Device",
                address = "AA:BB:CC:DD:EE:FF",
            }

            local manager = DeviceManager:new()
            local result = manager:disconnectDevice(device)

            assert.is_true(result)
            assert.are.equal(1, #UIManager._show_calls)
        end)

        it("should call on_success callback after disconnection", function()
            setMockExecuteResult(0)

            local device = {
                path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF",
                name = "Test Device",
                address = "AA:BB:CC:DD:EE:FF",
            }

            local callback_called = false

            local manager = DeviceManager:new()
            manager:disconnectDevice(device, function()
                callback_called = true
            end)

            assert.is_true(callback_called)
        end)

        it("should show error message on failed disconnection", function()
            setMockExecuteResult(1)

            local device = {
                path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF",
                name = "Test Device",
                address = "AA:BB:CC:DD:EE:FF",
            }

            local manager = DeviceManager:new()
            local result = manager:disconnectDevice(device)

            assert.is_false(result)
            assert.are.equal(1, #UIManager._show_calls)
        end)
    end)

    describe("toggleConnection", function()
        it("should connect when device is not connected", function()
            setMockExecuteResult(0)

            local device = {
                path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF",
                name = "Test Device",
                address = "AA:BB:CC:DD:EE:FF",
                connected = false,
            }

            local connect_called = false

            local manager = DeviceManager:new()
            manager:toggleConnection(device, function()
                connect_called = true
            end)

            assert.is_false(connect_called)
            setMockPopenOutput("") -- The child already captured state; inspect the async attempt.
            assert.is_not_nil(manager.connection_attempt)
            manager:cancelConnection()
        end)

        it("should disconnect when device is connected", function()
            setMockExecuteResult(0)

            local device = {
                path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF",
                name = "Test Device",
                address = "AA:BB:CC:DD:EE:FF",
                connected = true,
            }

            local disconnect_called = false

            local manager = DeviceManager:new()
            manager:toggleConnection(device, nil, function()
                disconnect_called = true
            end)

            assert.is_true(disconnect_called)
        end)
    end)

    describe("removeDevice", function()
        it("should show success message on successful removal", function()
            setMockExecuteResult(0)

            local device = {
                path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF",
                name = "Test Device",
                address = "AA:BB:CC:DD:EE:FF",
            }

            local manager = DeviceManager:new()
            local result = manager:removeDevice(device)

            assert.is_true(result)
            assert.are.equal(1, #UIManager._show_calls)
            assert.is_true(UIManager._show_calls[1].text:match("Removed") ~= nil)
        end)

        it("should call on_success callback after removal", function()
            setMockExecuteResult(0)

            local device = {
                path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF",
                name = "Test Device",
                address = "AA:BB:CC:DD:EE:FF",
            }

            local callback_called = false
            local callback_device = nil

            local manager = DeviceManager:new()
            manager:removeDevice(device, function(dev)
                callback_called = true
                callback_device = dev
            end)

            assert.is_true(callback_called)
            assert.are.equal(device, callback_device)
        end)

        it("should show error message on failed removal", function()
            setMockExecuteResult(1)

            local device = {
                path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF",
                name = "Test Device",
                address = "AA:BB:CC:DD:EE:FF",
            }

            local manager = DeviceManager:new()
            local result = manager:removeDevice(device)

            assert.is_false(result)
            assert.are.equal(1, #UIManager._show_calls)
            assert.is_true(UIManager._show_calls[1].text:match("Failed to remove") ~= nil)
        end)

        it("should not call on_success callback on failed removal", function()
            setMockExecuteResult(1)

            local device = {
                path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF",
                name = "Test Device",
                address = "AA:BB:CC:DD:EE:FF",
            }

            local callback_called = false

            local manager = DeviceManager:new()
            manager:removeDevice(device, function()
                callback_called = true
            end)

            assert.is_false(callback_called)
        end)
    end)

    describe("loadDevices", function()
        it("should cache all devices", function()
            local dbus_output = [[
object path "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"
  string "Address"
    variant string "AA:BB:CC:DD:EE:FF"
  string "Name"
    variant string "Paired Device"
  string "Paired"
    variant boolean true
  string "Connected"
    variant boolean false
object path "/org/bluez/hci0/dev_11_22_33_44_55_66"
  string "Address"
    variant string "11:22:33:44:55:66"
  string "Name"
    variant string "Unpaired Device"
  string "Paired"
    variant boolean false
  string "Connected"
    variant boolean false
]]
            setMockPopenOutput(dbus_output)

            local manager = DeviceManager:new()
            manager:loadDevices()

            local device_count = 0

            for _ in pairs(manager.devices_cache) do
                device_count = device_count + 1
            end

            assert.are.equal(2, device_count)
            assert.are.equal("Paired Device", manager.devices_cache["AA:BB:CC:DD:EE:FF"].name)
            assert.is_true(manager.devices_cache["AA:BB:CC:DD:EE:FF"].paired)
            assert.are.equal("Unpaired Device", manager.devices_cache["11:22:33:44:55:66"].name)
            assert.is_false(manager.devices_cache["11:22:33:44:55:66"].paired)
        end)

        it("should handle empty response", function()
            setMockPopenOutput("")

            local manager = DeviceManager:new()
            manager:loadDevices()

            local device_count = 0

            for _ in pairs(manager.devices_cache) do
                device_count = device_count + 1
            end

            assert.are.equal(0, device_count)
        end)

        it("should replace previous cache", function()
            local first_output = [[
object path "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"
  string "Address"
    variant string "AA:BB:CC:DD:EE:FF"
  string "Paired"
    variant boolean true
]]
            setMockPopenOutput(first_output)

            local manager = DeviceManager:new()
            manager:loadDevices()

            local device_count = 0

            for _ in pairs(manager.devices_cache) do
                device_count = device_count + 1
            end

            assert.are.equal(1, device_count)

            local second_output = [[
object path "/org/bluez/hci0/dev_11_22_33_44_55_66"
  string "Address"
    variant string "11:22:33:44:55:66"
  string "Paired"
    variant boolean true
object path "/org/bluez/hci0/dev_22_33_44_55_66_77"
  string "Address"
    variant string "22:33:44:55:66:77"
  string "Paired"
    variant boolean true
]]
            setMockPopenOutput(second_output)

            manager:loadDevices()

            device_count = 0

            for _ in pairs(manager.devices_cache) do
                device_count = device_count + 1
            end

            assert.are.equal(2, device_count)
        end)
    end)

    describe("getDevices", function()
        it("should return the cached devices", function()
            local dbus_output = [[
object path "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"
  string "Address"
    variant string "AA:BB:CC:DD:EE:FF"
  string "Paired"
    variant boolean true
]]
            setMockPopenOutput(dbus_output)

            local manager = DeviceManager:new()
            manager:loadDevices()

            local devices = manager:getDevices()

            assert.are.equal(1, #devices)
            assert.are.equal("AA:BB:CC:DD:EE:FF", devices[1].address)
        end)
    end)

    describe("trustDevice", function()
        it("should show success message on successful trust", function()
            setMockExecuteResult(0)

            local device = {
                path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF",
                name = "Test Device",
                address = "AA:BB:CC:DD:EE:FF",
            }

            local manager = DeviceManager:new()
            local result = manager:trustDevice(device)

            assert.is_true(result)
            assert.are.equal(1, #UIManager._show_calls)
        end)

        it("should call on_success callback after trusting", function()
            setMockExecuteResult(0)

            local device = {
                path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF",
                name = "Test Device",
                address = "AA:BB:CC:DD:EE:FF",
            }

            local callback_called = false
            local callback_device = nil

            local manager = DeviceManager:new()
            manager:trustDevice(device, function(dev)
                callback_called = true
                callback_device = dev
            end)

            assert.is_true(callback_called)
            assert.are.equal(device, callback_device)
        end)

        it("should show error message on failed trust", function()
            setMockExecuteResult(1)

            local device = {
                path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF",
                name = "Test Device",
                address = "AA:BB:CC:DD:EE:FF",
            }

            local manager = DeviceManager:new()
            local result = manager:trustDevice(device)

            assert.is_false(result)
            assert.are.equal(1, #UIManager._show_calls)
        end)

        it("should not call on_success callback on failed trust", function()
            setMockExecuteResult(1)

            local device = {
                path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF",
                name = "Test Device",
                address = "AA:BB:CC:DD:EE:FF",
            }

            local callback_called = false

            local manager = DeviceManager:new()
            manager:trustDevice(device, function()
                callback_called = true
            end)

            assert.is_false(callback_called)
        end)
    end)

    describe("untrustDevice", function()
        it("should show success message on successful untrust", function()
            setMockExecuteResult(0)

            local device = {
                path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF",
                name = "Test Device",
                address = "AA:BB:CC:DD:EE:FF",
            }

            local manager = DeviceManager:new()
            local result = manager:untrustDevice(device)

            assert.is_true(result)
            assert.are.equal(1, #UIManager._show_calls)
        end)

        it("should call on_success callback after untrusting", function()
            setMockExecuteResult(0)

            local device = {
                path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF",
                name = "Test Device",
                address = "AA:BB:CC:DD:EE:FF",
            }

            local callback_called = false
            local callback_device = nil

            local manager = DeviceManager:new()
            manager:untrustDevice(device, function(dev)
                callback_called = true
                callback_device = dev
            end)

            assert.is_true(callback_called)
            assert.are.equal(device, callback_device)
        end)

        it("should show error message on failed untrust", function()
            setMockExecuteResult(1)

            local device = {
                path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF",
                name = "Test Device",
                address = "AA:BB:CC:DD:EE:FF",
            }

            local manager = DeviceManager:new()
            local result = manager:untrustDevice(device)

            assert.is_false(result)
            assert.are.equal(1, #UIManager._show_calls)
        end)

        it("should not call on_success callback on failed untrust", function()
            setMockExecuteResult(1)

            local device = {
                path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF",
                name = "Test Device",
                address = "AA:BB:CC:DD:EE:FF",
            }

            local callback_called = false

            local manager = DeviceManager:new()
            manager:untrustDevice(device, function()
                callback_called = true
            end)

            assert.is_false(callback_called)
        end)
    end)
    describe("connectDeviceInBackground", function()
        before_each(function()
            -- Clear cached modules so ffi/util mock is used fresh
            package.loaded["src/lib/bluetooth/dbus_adapter"] = nil
            package.loaded["ffi/util"] = nil
        end)

        it("should return true when background connect starts successfully", function()
            setMockRunInSubProcessResult(12345)

            local device = {
                path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF",
                name = "Test Device",
                address = "AA:BB:CC:DD:EE:FF",
            }

            local manager = DeviceManager:new()
            local result = manager:connectDeviceInBackground(device)

            assert.is_true(result)
        end)

        it("should return false when background connect fails to start", function()
            setMockRunInSubProcessResult(false)

            local device = {
                path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF",
                name = "Test Device",
                address = "AA:BB:CC:DD:EE:FF",
            }

            local manager = DeviceManager:new()
            local result = manager:connectDeviceInBackground(device)

            assert.is_false(result)
        end)

        it("should call DbusAdapter.connectDeviceInBackground with device path", function()
            setMockRunInSubProcessResult(12345)

            local device = {
                path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF",
                name = "Test Device",
                address = "AA:BB:CC:DD:EE:FF",
            }

            local manager = DeviceManager:new()
            manager:connectDeviceInBackground(device)

            -- Verify the subprocess was started (callback was captured)
            local captured_callback = getMockRunInSubProcessCallback()
            assert.is_not_nil(captured_callback)
        end)
    end)
end)
