require("spec.helper")

describe("Direct-connect policy characterization", function()
    local Bluetooth = require("src/kobo_bluetooth")
    local UIManager = require("ui/uimanager")
    local instance, attempts, devices

    before_each(function()
        resetAllMocks()
        UIManager:_reset()
        devices = {
            { address = "AA", name = "first", paired = true },
            { address = "BB", name = "last used", paired = true },
        }
        attempts = {}
        instance = Bluetooth:new()
        instance.plugin = { settings = { bluetooth_last_connected = "BB" } }
        instance.device_manager = {
            getDevices = function() return devices end,
            connectDeviceInBackground = function(_, device) attempts[#attempts + 1] = device.address end,
        }
        instance.input_handler = {
            getIsolatedReader = function() return nil end,
            findInputNodeForDevice = function() return nil end,
        }
        instance.is_auto_connect_active = true
        instance.direct_connect_last_attempt_time = 0
    end)

    after_each(function() instance:_stopDirectConnect() end)

    it("keeps the existing scheduled task while renewing its attempt budget", function()
        instance:_startDirectConnect(false)
        local task = instance.direct_connect_task
        assert.are.equal(0, instance.direct_connect_attempts_left)
        instance:_startDirectConnect(true)
        assert.are.equal(task, instance.direct_connect_task)
        assert.are.equal(Bluetooth.DIRECT_CONNECT_MAX_ATTEMPTS, instance.direct_connect_attempts_left)
        assert.are.equal(1, #UIManager._scheduled_tasks)
    end)

    it("contacts the last-used device once before handing multiple candidates to discovery", function()
        instance:_startDirectConnect(true)
        instance:_runDirectConnectTick()
        assert.are.same({ "BB" }, attempts)
        assert.are.equal(0, instance.direct_connect_attempts_left)
        assert.are.equal("BB", instance.direct_connect_last_attempt_address)
        assert.is_true(instance:_isContactedInBackground("BB"))
        instance:_runDirectConnectTick()
        assert.are.same({ "BB" }, attempts)
    end)

    it("invalidates a stale direct-loop callback on stop", function()
        instance:_startDirectConnect(true)
        local stale = instance.direct_connect_task
        instance:_stopDirectConnect()
        stale()
        assert.are.equal(0, #attempts)
        assert.is_nil(instance.direct_connect_task)
        assert.are.equal(0, instance.direct_connect_attempts_left)
    end)

    it("opens present input nodes instead of contacting their device", function()
        local opened = {}
        instance.input_handler.findInputNodeForDevice = function(_, device)
            if device.address == "AA" then return "/dev/input/event5" end
        end
        instance._onInputNodeDetected = function(_, device) opened[#opened + 1] = device.address end
        local candidates = instance:_openPresentInputNodes()
        assert.are.same({ "AA" }, opened)
        assert.are.same({ devices[2] }, candidates)
    end)
end)
