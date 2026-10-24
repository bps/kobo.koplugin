---
--- Regression tests for bounded automatic reconnection and suspend cleanup.
require("spec.helper")
local time = require("ui/time")

describe("Bluetooth connection lifecycle", function()
    local KoboBluetooth = require("src/kobo_bluetooth")
    local DeviceManager = require("src/lib/bluetooth/device_manager")
    local InputHandler = require("src/lib/bluetooth/input_device_handler")
    local DbusMonitor = require("src/lib/bluetooth/dbus_monitor")
    local UIManager = require("ui/uimanager")
    local ConnectionAttempt = require("src/lib/bluetooth/connection_attempt")
    local instance

    before_each(function()
        resetAllMocks()
        UIManager:_reset()
        instance = KoboBluetooth:new()
        instance.plugin = { settings = { enable_auto_connect_polling = true } }
        instance.device_manager = DeviceManager:new()
        instance.input_handler = InputHandler:new()
        instance.dbus_monitor = DbusMonitor:new()
        instance.last_seen_rssi = {}
        instance.is_auto_connect_active = false
        instance.is_discovery_active = false
    end)

    after_each(function()
        instance:_cleanup(false)
        resetAllMocks()
        UIManager:_reset()
    end)

    it("stops discovery after 60 seconds without a nearby remote", function()
        instance:startAutoConnectPolling()
        assert.is_true(instance.is_auto_connect_active)
        assert.are.equal(60, UIManager._scheduled_tasks[1].time)
        UIManager:executeScheduledTasks(1)
        assert.is_false(instance.is_auto_connect_active)
        assert.is_false(instance.is_discovery_active)
        assert.is_false(instance.dbus_monitor:hasCallback("kobobluetooth:auto_connect"))
        assert.is_true(table.concat(getExecutedCommands(), "\n"):match("StopDiscovery") ~= nil)
    end)

    it("does not reset the discovery deadline on repeated starts", function()
        instance:startAutoConnectPolling()
        local timeout = instance.auto_connect_timeout_task
        local direct = instance.direct_connect_task
        instance:startAutoConnectPolling()
        assert.are.equal(timeout, instance.auto_connect_timeout_task)
        assert.are.equal(direct, instance.direct_connect_task)
        assert.are.equal(2, #UIManager._scheduled_tasks)
        assert.are.equal(timeout, UIManager._scheduled_tasks[1].callback)
        assert.are.equal(direct, UIManager._scheduled_tasks[2].callback)

        instance:stopAutoConnectPolling(false)
        assert.is_nil(next(UIManager._scheduled_tasks))
        instance:startAutoConnectPolling()
        assert.are_not.equal(timeout, instance.auto_connect_timeout_task)
        assert.are_not.equal(direct, instance.direct_connect_task)
        assert.are.equal(2, #UIManager._scheduled_tasks)
    end)

    it("preserves the automatic cooldown flag after a direct-attempt deferral", function()
        local calls = {}
        instance.connectToDevice = function(_, address, show, automatic)
            table.insert(calls, { address, show, automatic })
        end
        instance:_connectAfterPendingAttempt("AA:BB:CC:DD:EE:FF", false, 16, true)
        instance.deferred_connect_task()
        assert.are.same({ { "AA:BB:CC:DD:EE:FF", false, true } }, calls)
        assert.is_nil(instance.deferred_connect_task)
        assert.is_false(instance.direct_connect_wait_over)
    end)

    it("invalidates a deferred connection during cleanup", function()
        local calls = 0
        instance.connectToDevice = function()
            calls = calls + 1
        end
        instance:_connectAfterPendingAttempt("AA:BB:CC:DD:EE:FF", false, 16, true)
        local stale = instance.deferred_connect_task
        instance:_cleanup(false)
        stale()
        assert.are.equal(0, calls)
        assert.is_nil(instance.deferred_connect_task)
        assert.is_nil(next(UIManager._scheduled_tasks))
    end)

    it("ignores a stale discovery timeout from a previous window", function()
        instance:startAutoConnectPolling()
        local stale = instance.auto_connect_timeout_task
        instance:stopAutoConnectPolling(false)
        instance:startAutoConnectPolling()
        stale()
        assert.is_true(instance.is_auto_connect_active)
    end)

    it("does not stop discovery when it has not started any", function()
        instance:stopAutoConnectPolling(false)
        assert.are.equal(0, #getExecutedCommands())
    end)

    it("cleans up pending attempts and scans without restarting discovery", function()
        local device = { address = "AA:BB:CC:DD:EE:FF", path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF" }
        instance.device_manager:connectDevice(device)
        local stale = instance.device_manager.connection_attempt.poll
        instance.input_handler:openIsolatedInputDevice(device, false, true)
        instance:startAutoConnectPolling()
        instance:_cleanup(false)
        stale()
        assert.is_nil(instance.device_manager.connection_attempt)
        assert.is_nil(next(instance.input_handler.pending_input_scans))
        assert.is_false(instance.is_auto_connect_active)
        assert.is_nil(next(UIManager._scheduled_tasks))
    end)

    it("reserves the stack until the child's deadline after cancellation", function()
        local device = { address = "AA:BB:CC:DD:EE:FF", path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF" }
        instance.device_manager:connectDevice(device)
        instance.device_manager:cancelConnection()
        local another_manager = DeviceManager:new()
        assert.is_false(another_manager:connectDevice(device))
        local clock = stub(time, "now", function()
            return ConnectionAttempt.busy_until + time.s(1)
        end)
        assert.is_true(another_manager:connectDevice(device))
        clock:revert()
        another_manager:cancelConnection()
    end)

    it("serializes attempts across manager instances even after the deadline", function()
        local device = { address = "AA:BB:CC:DD:EE:FF", path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF" }
        instance.device_manager:connectDevice(device)
        local clock = stub(time, "now", function()
            return ConnectionAttempt.busy_until + time.s(1)
        end)
        assert.is_false(DeviceManager:new():connectDevice(device))
        clock:revert()
    end)
end)
