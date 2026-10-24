local test_helper = require("spec.helper")

describe("InputDeviceHandler collection ownership", function()
    local InputDeviceHandler = require("src/lib/bluetooth/input_device_handler")
    local Reader = require("src/lib/bluetooth/bluetooth_input_reader")
    local UIManager = require("ui/uimanager")
    local io_mock = test_helper.createIOOpenMocker()
    local handler, nodes, original_popen
    local remote = { address = "AA:BB:CC:DD:EE:FF", name = "Identical name" }
    local other = { address = "11:22:33:44:55:66", name = "Identical name" }

    local function node(path, parent, uniq, hid_uniq)
        nodes[path] = { parent = parent }
        local sysfs = path:gsub("/dev/input/", "/sys/class/input/") .. "/device/"

        for filename, content in pairs({
            uniq = uniq or "",
            ["../../uevent"] = hid_uniq and ("HID_UNIQ=" .. hid_uniq .. "\n") or "",
        }) do
            io_mock.setMockFile(sysfs .. filename, {
                read = function()
                    return content
                end,
                close = function() end,
            })
        end
    end

    before_each(function()
        resetAllMocks()
        handler = InputDeviceHandler:new()
        UIManager:_reset()
        nodes = {}
        original_popen = io.popen
        io_mock.install()
        io.popen = function(command)
            if command:match("^ls ") then
                local paths = {}

                for path in pairs(nodes) do
                    table.insert(paths, (path:gsub("/dev/input/", "/sys/class/input/")))
                end

                table.sort(paths)

                return {
                    lines = function()
                        local i = 0

                        return function()
                            i = i + 1

                            return paths[i]
                        end
                    end,
                    close = function() end,
                }
            end

            local event = command:match("readlink /sys/class/input/(event%d+)")
            local info = event and nodes["/dev/input/" .. event]

            return {
                read = function()
                    return info and ("../../devices/virtual/misc/uhid/" .. info.parent .. "/input/input9/" .. event)
                end,
                close = function() end,
            }
        end
    end)

    after_each(function()
        handler:closeAllIsolatedInputDevices()
        UIManager:_reset()
        io.popen = original_popen
        io_mock.uninstall()
        io_mock.clear()
    end)

    it("binds before finding a verified node for the direct connect loop", function()
        local bound_for = {}
        handler._bindUnclaimedHidDevices = function(_, address)
            table.insert(bound_for, address)
            node("/dev/input/event5", "0005:0001:0001.0001", remote.address)

            return 0
        end

        assert.are.equal("/dev/input/event5", handler:findInputNodeForDevice(remote))
        assert.are.same({ remote.address }, bound_for)
        assert.is_nil(handler:findInputNodeForDevice(other))
        assert.is_nil(handler:findInputNodeForDevice({}))
        assert.is_nil(handler:findInputNodeForDevice(nil))
    end)

    it("opens every verified collection through the direct connect path", function()
        node("/dev/input/event5", "0005:0001:0001.0001", remote.address)
        node("/dev/input/event6", "0005:0001:0001.0001", "")
        local bluetooth = require("src/kobo_bluetooth"):new()
        bluetooth.input_handler = handler
        bluetooth.device_manager = {
            getDevices = function()
                return { { address = remote.address, name = remote.name, paired = true } }
            end,
            updateDeviceProperties = function() end,
        }
        bluetooth.plugin = { settings = {} }
        bluetooth.last_seen_rssi = {}

        assert.are.same({}, bluetooth:_openPresentInputNodes())
        assert.is_not_nil(handler:getIsolatedReader(remote.address, "/dev/input/event5"))
        assert.is_not_nil(handler:getIsolatedReader(remote.address, "/dev/input/event6"))

        node("/dev/input/event7", "0005:0001:0001.0001", "")
        handler.pending_input_scans[remote.address]()
        assert.is_not_nil(handler:getIsolatedReader(remote.address, "/dev/input/event7"))
    end)

    it("names the device in the ready notification", function()
        node("/dev/input/event5", "0005:0001:0001.0001", remote.address)
        assert.is_true(handler:openIsolatedInputDevice(remote, true))
        local ui = require("ui/uimanager")

        assert.are.equal(remote.name .. " ready", ui._show_calls[#ui._show_calls].text)
    end)

    it("opens every matching collection but no collection of another remote", function()
        node("/dev/input/event5", "0005:0001:0001.0001", remote.address)
        node("/dev/input/event6", "0005:0001:0001.0001", "")
        node("/dev/input/event7", "0005:0001:0001.0002", other.address)

        assert.is_true(handler:openIsolatedInputDevice(remote, false))
        assert.is_not_nil(handler:getIsolatedReader(remote.address, "/dev/input/event5"))
        assert.is_not_nil(handler:getIsolatedReader(remote.address, "/dev/input/event6"))
        assert.is_nil(handler:getIsolatedReader(remote.address, "/dev/input/event7"))
        assert.is_nil(handler.isolated_readers[other.address])
    end)

    it("accepts reversed MTK addresses and HID_UNIQ when input uniq is absent", function()
        node("/dev/input/event8", "0005:0001:0001.0001", nil, "ff:ee:dd:cc:bb:aa")

        assert.is_true(handler:openIsolatedInputDevice(remote, false))
        assert.is_not_nil(handler:getIsolatedReader(remote.address))
    end)

    it("does not attach a sibling with an explicit conflicting address", function()
        node("/dev/input/event5", "0005:0001:0001.0001", remote.address)
        node("/dev/input/event6", "0005:0001:0001.0001", other.address)

        handler:openIsolatedInputDevice(remote, false)
        assert.is_nil(handler:getIsolatedReader(remote.address, "/dev/input/event6"))
    end)

    it("rejects unidentified nodes instead of falling back to event4", function()
        node("/dev/input/event4", "0005:0001:0001.0001", "")
        node("/dev/input/event5", "0005:0001:0001.0002", other.address)

        assert.is_false(handler:openIsolatedInputDevice(remote, false))
        assert.is_nil(next(handler.isolated_readers))
    end)

    it("keeps same-model remotes separate and transfers reused paths safely", function()
        node("/dev/input/event5", "0005:0001:0001.0001", remote.address)
        node("/dev/input/event6", "0005:0001:0001.0002", other.address)
        handler:openIsolatedInputDevice(remote, false)
        handler:openIsolatedInputDevice(other, false)
        local first = handler:getIsolatedReader(remote.address)
        assert.is_not_nil(handler:getIsolatedReader(other.address, "/dev/input/event6"))
        assert.is_nil(handler:getIsolatedReader(other.address, "/dev/input/event5"))
        node("/dev/input/event5", "0005:0001:0001.0002", other.address)
        handler:openIsolatedInputDevice(other, false)

        assert.is_false(first:isOpen())
        assert.is_nil(handler.isolated_readers[remote.address])
        assert.is_not_nil(handler:getIsolatedReader(other.address, "/dev/input/event5"))
    end)

    it("rejects non-Bluetooth uhid devices", function()
        node("/dev/input/event5", "0003:0001:0001.0001", remote.address)
        assert.is_false(handler:openIsolatedInputDevice(remote, false))
    end)

    it("keeps readers and callbacks idempotent while adding a late collection", function()
        node("/dev/input/event5", "0005:0001:0001.0001", remote.address)
        local opened = {}
        handler:registerDeviceOpenCallback(function(address, path)
            table.insert(opened, { address, path })
        end)
        handler:openIsolatedInputDevice(remote, false)
        local first = handler:getIsolatedReader(remote.address)
        node("/dev/input/event6", "0005:0001:0001.0001", remote.address)
        handler:openIsolatedInputDevice(remote, false)
        handler:openIsolatedInputDevice(remote, false)

        assert.are.equal(first, handler:getIsolatedReader(remote.address, "/dev/input/event5"))
        assert.are.equal(2, #opened)
    end)

    it("reopens a reused event path when its HID parent changes", function()
        node("/dev/input/event5", "0005:0001:0001.0001", remote.address)
        handler:openIsolatedInputDevice(remote, false)
        local first = handler:getIsolatedReader(remote.address)
        node("/dev/input/event5", "0005:0001:0001.0002", remote.address)
        handler:openIsolatedInputDevice(remote, false)

        assert.is_false(first:isOpen())
        assert.are_not.equal(first, handler:getIsolatedReader(remote.address))
    end)

    it("keeps successful collections if another reader cannot be opened", function()
        node("/dev/input/event5", "0005:0001:0001.0001", remote.address)
        node("/dev/input/event6", "0005:0001:0001.0001", remote.address)
        local original_open = Reader.open
        local stub_open = stub(Reader, "open", function(self, path)
            if path == "/dev/input/event6" then
                return false
            end

            return original_open(self, path)
        end)

        assert.is_true(handler:openIsolatedInputDevice(remote, false))
        assert.is_not_nil(handler:getIsolatedReader(remote.address, "/dev/input/event5"))
        assert.is_nil(handler:getIsolatedReader(remote.address, "/dev/input/event6"))
        stub_open:revert()
    end)

    it("retains later successful nodes after a stale replacement fails", function()
        node("/dev/input/event5", "0005:0001:0001.0001", remote.address)
        handler:openIsolatedInputDevice(remote, false)
        local first = handler:getIsolatedReader(remote.address)
        node("/dev/input/event5", "0005:0001:0001.0002", remote.address)
        node("/dev/input/event6", "0005:0001:0001.0002", remote.address)
        local original_open = Reader.open
        local live_on_close = false
        handler:registerDeviceCloseCallback(function()
            live_on_close = handler:getIsolatedReader(remote.address, "/dev/input/event6") ~= nil
        end)
        local failing = stub(Reader, "open", function(self, path)
            if path == "/dev/input/event5" then
                return false
            end

            return original_open(self, path)
        end)
        assert.is_true(handler:openIsolatedInputDevice(remote, false))
        assert.is_false(first:isOpen())
        assert.is_not_nil(handler:getIsolatedReader(remote.address, "/dev/input/event6"))
        assert.is_true(live_on_close)
        failing:revert()
    end)

    it("registers and clears key callbacks on every collection", function()
        node("/dev/input/event5", "0005:0001:0001.0001", remote.address)
        node("/dev/input/event6", "0005:0001:0001.0001", remote.address)
        handler:registerKeyEventCallback(function() end)
        handler:openIsolatedInputDevice(remote, false)
        handler:registerKeyEventCallback(function() end)

        for _, info in pairs(handler.isolated_readers[remote.address]) do
            assert.are.equal(2, #info.reader.callbacks)
        end

        handler:clearKeyEventCallbacks()

        for _, info in pairs(handler.isolated_readers[remote.address]) do
            assert.are.same({}, info.reader.callbacks)
        end
    end)

    it("attributes events from every collection to the correct MAC", function()
        node("/dev/input/event5", "0005:0001:0001.0001", remote.address)
        node("/dev/input/event6", "0005:0001:0001.0001", remote.address)
        handler:openIsolatedInputDevice(remote, false)

        for path, info in pairs(handler.isolated_readers[remote.address]) do
            info.reader.poll = function()
                return { { code = 106, value = 1, device_path = path } }
            end
        end

        local events = handler:pollIsolatedReaders(0)
        assert.are.equal(2, #events)

        for _, event in ipairs(events) do
            assert.are.equal(remote.address, event.device_address)
        end
    end)

    it("does not mark a remote disconnected until its last collection closes", function()
        node("/dev/input/event5", "0005:0001:0001.0001", remote.address)
        node("/dev/input/event6", "0005:0001:0001.0001", remote.address)
        handler:openIsolatedInputDevice(remote, false)
        local KoboBluetooth = require("src/kobo_bluetooth")
        local updates = {}
        local bluetooth = {
            plugin = { settings = {} },
            input_handler = handler,
            device_manager = {
                updateDeviceProperties = function(_, address, properties)
                    table.insert(updates, { address, properties })
                end,
            },
        }
        local closed = {}
        handler:registerDeviceCloseCallback(function(address, path)
            table.insert(closed, path)
            KoboBluetooth.onInputDeviceClosed(bluetooth, address, path)
        end)
        handler:getIsolatedReader(remote.address, "/dev/input/event5"):close()
        handler:pollIsolatedReaders(0)

        assert.are.equal(0, #updates)
        assert.are.equal(1, #closed)
        assert.is_true(handler:hasIsolatedReaders())
        handler:getIsolatedReader(remote.address, "/dev/input/event6"):close()
        handler:pollIsolatedReaders(0)

        assert.are.equal(1, #updates)
        assert.are.equal(2, #closed)
        assert.is_false(handler:hasIsolatedReaders())
        assert.is_nil(handler.isolated_readers[remote.address])
    end)

    it("discovers delayed nodes without sleeping and scans for late siblings", function()
        local ffiutil = require("ffi/util")
        local sleep = spy.on(ffiutil, "sleep")
        local opened, pending = handler:openIsolatedInputDevice(remote, false, true)
        assert.is_false(opened)
        assert.is_true(pending)
        assert.is_false(handler:hasIsolatedReaders())
        node("/dev/input/event5", "0005:0001:0001.0001", remote.address)
        UIManager:executeScheduledTasks(1)
        assert.is_not_nil(handler:getIsolatedReader(remote.address, "/dev/input/event5"))
        node("/dev/input/event6", "0005:0001:0001.0001", remote.address)
        UIManager:executeScheduledTasks(1)
        assert.is_not_nil(handler:getIsolatedReader(remote.address, "/dev/input/event6"))
        UIManager:executeScheduledTasks(30)
        assert.is_nil(next(handler.pending_input_scans))
        assert.spy(sleep).was_not_called()
        sleep:revert()
    end)

    it("expires unavailable input discovery instead of rescheduling forever", function()
        local opened, pending = handler:openIsolatedInputDevice(remote, true, true)
        assert.is_false(opened)
        assert.is_true(pending)
        UIManager:executeScheduledTasks(30)
        assert.is_nil(next(handler.pending_input_scans))
        assert.is_nil(next(UIManager._scheduled_tasks))
        assert.is_false(handler:hasIsolatedReaders())
        assert.are.equal(1, #UIManager._show_calls)
        assert.is_true(UIManager._show_calls[1].text:match("not found") ~= nil)
    end)

    it("invalidates pending scans when the remote is closed", function()
        handler:openIsolatedInputDevice(remote, false, true)
        local stale = handler.pending_input_scans[remote.address]
        handler:closeIsolatedInputDevice(remote)
        node("/dev/input/event5", "0005:0001:0001.0001", remote.address)
        stale()
        UIManager:executeScheduledTasks(30)
        assert.is_false(handler:hasIsolatedReaders())
        assert.is_nil(next(handler.pending_input_scans))
    end)

    it("does not extend an existing scan window on duplicate connection signals", function()
        handler:openIsolatedInputDevice(remote, false, true)
        local scan = handler.pending_input_scans[remote.address]
        handler:openIsolatedInputDevice(remote, false, true)
        assert.are.equal(scan, handler.pending_input_scans[remote.address])
        assert.are.equal(1, #UIManager._scheduled_tasks)
    end)

    it("closes every collection even when a close callback fails", function()
        node("/dev/input/event5", "0005:0001:0001.0001", remote.address)
        node("/dev/input/event6", "0005:0001:0001.0001", remote.address)
        handler:openIsolatedInputDevice(remote, false)
        local first = handler:getIsolatedReader(remote.address)
        local count = 0
        handler:registerDeviceCloseCallback(function()
            error("callback error")
        end)
        handler:registerDeviceCloseCallback(function()
            count = count + 1
        end)
        handler:closeAllIsolatedInputDevices()

        assert.are.equal(2, count)
        assert.is_false(first:isOpen())
        assert.is_nil(next(handler.isolated_readers))
    end)
end)

local helper = require("spec.helper")

describe("InputDeviceHandler hid-generic binding", function()
    local InputDeviceHandler
    local lfs
    local io_mock
    local handler
    local written

    local HID_DIR = "/sys/bus/hid/devices"
    local RING = "0005:05AC:0220.0003"

    setup(function()
        InputDeviceHandler = require("src/lib/bluetooth/input_device_handler")
        lfs = require("libs/libkoreader-lfs")
        io_mock = helper.createIOOpenMocker()
    end)

    -- Describes a HID device in sysfs: driver link present or not, modalias, uevent
    local function hidDevice(entry, opts)
        local path = HID_DIR .. "/" .. entry
        lfs._setFileState(path .. "/driver", { exists = opts.driver == true })
        io_mock.setMockFile(path .. "/modalias", {
            read = function()
                return opts.modalias
            end,
            close = function() end,
        })
        io_mock.setMockFile(path .. "/uevent", {
            read = function()
                return "HID_ID=" .. entry:sub(1, 19) .. "\nHID_UNIQ=" .. (opts.uniq or "") .. "\n"
            end,
            close = function() end,
        })
    end

    before_each(function()
        resetAllMocks()
        lfs._clearFileStates()
        io_mock.install()
        written = {}
        io_mock.setMockFile(InputDeviceHandler.HID_GENERIC_NEW_ID, {
            write = function(_, text)
                table.insert(written, text)
                return true
            end,
            close = function() end,
        })
        handler = InputDeviceHandler:new()
        lfs._setDirectoryContents(HID_DIR, { ".", "..", RING })
        hidDevice(RING, { driver = false, modalias = "hid:b0005g0002v000005ACp00000220", uniq = "F6:0E:5A:FF:01:1D" })
    end)

    after_each(function()
        io_mock.uninstall()
        io_mock.clear()
        lfs._clearFileStates()
    end)

    it("should hand a driverless multitouch Bluetooth device to hid-generic once", function()
        assert.are.equal(1, handler:_bindUnclaimedHidDevices("1D:01:FF:5A:0E:F6"))
        assert.are.equal(1, #written)
        assert.are.equal("0005 05AC 0220", written[1])

        -- The ID stays registered until reboot: no second write for the same device
        assert.are.equal(0, handler:_bindUnclaimedHidDevices("1D:01:FF:5A:0E:F6"))
        assert.are.equal(1, #written)
    end)

    it("should match the address in either byte order", function()
        assert.are.equal(1, handler:_bindUnclaimedHidDevices("F6:0E:5A:FF:01:1D"))
    end)

    it("should leave a device that already has a driver alone", function()
        hidDevice(RING, { driver = true, modalias = "hid:b0005g0002v000005ACp00000220", uniq = "F6:0E:5A:FF:01:1D" })

        assert.are.equal(0, handler:_bindUnclaimedHidDevices("1D:01:FF:5A:0E:F6"))
        assert.are.equal(0, #written)
    end)

    it("should leave a device with another address alone", function()
        assert.are.equal(0, handler:_bindUnclaimedHidDevices("00:11:22:33:44:55"))
        assert.are.equal(0, #written)
    end)

    it("should leave devices outside the multitouch HID groups alone", function()
        hidDevice(RING, { driver = false, modalias = "hid:b0005g0001v000005ACp00000220", uniq = "F6:0E:5A:FF:01:1D" })

        assert.are.equal(0, handler:_bindUnclaimedHidDevices("1D:01:FF:5A:0E:F6"))
        assert.are.equal(0, #written)
    end)

    it("should leave devices on other buses alone", function()
        local usb = "0003:1234:5678.0001"
        lfs._setDirectoryContents(HID_DIR, { usb })
        hidDevice(usb, { driver = false, modalias = "hid:b0003g0002v00001234p00005678", uniq = "" })

        assert.are.equal(0, handler:_bindUnclaimedHidDevices())
        assert.are.equal(0, #written)
    end)

    it("should bind any matching device when no address is given", function()
        assert.are.equal(1, handler:_bindUnclaimedHidDevices())
        assert.are.equal("0005 05AC 0220", written[1])
    end)

    it("should report failure to write new_id and not retry the device", function()
        io_mock.setMockFileFailure(InputDeviceHandler.HID_GENERIC_NEW_ID)

        assert.are.equal(0, handler:_bindUnclaimedHidDevices("1D:01:FF:5A:0E:F6"))
        assert.are.equal(0, handler:_bindUnclaimedHidDevices("1D:01:FF:5A:0E:F6"))
    end)

    it("should not count a bind the kernel rejected", function()
        io_mock.setMockFile(InputDeviceHandler.HID_GENERIC_NEW_ID, {
            write = function()
                return nil, "Invalid argument"
            end,
            close = function() end,
        })

        assert.are.equal(0, handler:_bindUnclaimedHidDevices("1D:01:FF:5A:0E:F6"))
    end)
end)
