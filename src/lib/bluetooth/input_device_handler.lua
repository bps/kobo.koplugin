---
--- Bluetooth input device handler.
--- Manages opening and closing of Bluetooth input devices for key event handling.
---
--- Uses a dedicated BluetoothInputReader that only reads from Bluetooth devices,
--- providing clean separation from other input sources (touchscreen, built-in buttons).
--- This allows key bindings to be processed exclusively for Bluetooth input.

local BluetoothInputReader = require("src/lib/bluetooth/bluetooth_input_reader")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local InputDeviceHandler = {
    -- Isolated readers: address -> path -> { reader, hid_parent }
    isolated_readers = {},
    -- Callbacks for isolated reader events
    key_event_callbacks = {},
    -- Callbacks for device open/close events
    device_open_callbacks = {},
    device_close_callbacks = {},
    -- HID devices already handed to hid-generic (see _bindUnclaimedHidDevices)
    hid_bind_attempts = {},
}

--- Directory where the kernel lists HID devices as <bus>:<vendor>:<product>.<instance>.
InputDeviceHandler.HID_DEVICES_DIR = "/sys/bus/hid/devices"

--- Bus number of Bluetooth HID devices in the kernel's HID IDs (BUS_BLUETOOTH, 0x0005).
InputDeviceHandler.HID_BUS_BLUETOOTH = "0005"

--- HID groups the kernel reserves for the hid-multitouch driver
--- (HID_GROUP_MULTITOUCH 0x0002 and HID_GROUP_MULTITOUCH_WIN_8 0x0100).
--- Kobo kernels do not ship that driver, so devices in these groups stay driverless.
InputDeviceHandler.HID_GROUPS_MULTITOUCH = { ["0002"] = true, ["0100"] = true }

--- Sysfs file that makes hid-generic claim an additional device ID.
InputDeviceHandler.HID_GENERIC_NEW_ID = "/sys/bus/hid/drivers/hid-generic/new_id"

--- Scan for up to five seconds, including late sibling collections.
InputDeviceHandler.INPUT_SCAN_INTERVAL = 0.2
InputDeviceHandler.INPUT_SCAN_MAX_POLLS = 25

---
--- Creates a new InputDeviceHandler instance.
--- @return table New InputDeviceHandler instance
function InputDeviceHandler:new()
    local instance = {}
    setmetatable(instance, self)
    self.__index = self

    instance.isolated_readers = {}
    instance.key_event_callbacks = {}
    instance.device_open_callbacks = {}
    instance.device_close_callbacks = {}
    instance.hid_bind_attempts = {}
    instance.pending_input_scans = {}

    return instance
end

---
--- Detects available Bluetooth input devices by scanning /sys/class/input/
---
--- Scans /sys/class/input/event* and checks each symlink for the "uhid" pattern,
--- which indicates a Bluetooth/USB HID device. Built-in Kobo devices use platform
--- paths that don't contain "uhid", making Bluetooth devices easy to identify.
---
--- Detection strategy:
---   - Bluetooth devices: symlink contains "uhid" (e.g., ../../devices/virtual/misc/uhid/...)
---   - Built-in devices: symlink contains "platform" (e.g., ../../devices/platform/...)
---
--- @return table Array of detected device paths (e.g., {"/dev/input/event4", "/dev/input/event5"})
function InputDeviceHandler:detectBluetoothInputDevices()
    local devices = {}
    local handle = io.popen("ls -1d /sys/class/input/event* 2>/dev/null")

    if not handle then
        logger.warn("InputDeviceHandler: Cannot access /sys/class/input/")

        return devices
    end

    local success, result = pcall(function()
        for event_path in handle:lines() do
            if self:_isBluetoothDevice(event_path) then
                local event_num = event_path:match("event(%d+)$")

                if event_num then
                    local device_path = "/dev/input/event" .. event_num
                    table.insert(devices, device_path)
                    logger.dbg("InputDeviceHandler: Found Bluetooth input device:", device_path)
                end
            end
        end
    end)

    if not success then
        logger.warn("InputDeviceHandler: Error scanning for Bluetooth devices:", result)
    end

    handle:close()

    return devices
end

---
--- Checks if an input device is a Bluetooth (uhid) device
--- @param event_path string Path to /sys/class/input/eventN
--- @return boolean True if device is Bluetooth
function InputDeviceHandler:_isBluetoothDevice(event_path)
    local handle = io.popen("readlink " .. event_path .. " 2>/dev/null")

    if not handle then
        return false
    end

    local target = handle:read("*l")
    handle:close()

    return target and target:match("uhid") ~= nil
end

---
--- Hands a driverless Bluetooth HID device to hid-generic so it gets an input node.
---
--- Remotes that emulate a touch screen carry a digitizer contact ID in their HID
--- descriptor, so the kernel files them under a multitouch HID group and leaves
--- them to hid-multitouch, which Kobo kernels do not ship. The device then sits on
--- the HID bus without a driver and never gets a /dev/input/eventN node. Writing
--- its ID to hid-generic's new_id makes hid-generic claim it (dynamic IDs match
--- any HID group), which creates the node. The ID stays registered until reboot,
--- so reconnects of the same device are bound by the kernel on its own.
---
--- Only a device that meets all of these is touched: on the Bluetooth bus,
--- without a driver, in a multitouch HID group and, when an address is given,
--- carrying that address, i.e. the paired device the plugin was asked to open.
--- Everything else is left to the kernel. Scheduled input scans allow time for
--- the node to appear without sleeping on the UI thread.
--- @param device_address string|nil Bluetooth address of the device to bind; any matching device when nil
--- @return number Number of devices handed to hid-generic
function InputDeviceHandler:_bindUnclaimedHidDevices(device_address)
    local ok, iterator, state = pcall(lfs.dir, InputDeviceHandler.HID_DEVICES_DIR)

    if not ok then
        return 0
    end

    local bound = 0

    for entry in iterator, state do
        local hid_path = InputDeviceHandler.HID_DEVICES_DIR .. "/" .. entry

        if self:_isBindableHidDevice(entry, hid_path, device_address) and self:_bindToHidGeneric(entry, hid_path) then
            bound = bound + 1
        end
    end

    return bound
end

---
--- Whether a HID device is one _bindUnclaimedHidDevices should hand to hid-generic.
--- @param entry string Directory entry, <bus>:<vendor>:<product>.<instance>
--- @param hid_path string Full sysfs path of the device
--- @param device_address string|nil Required Bluetooth address, or nil for any
--- @return boolean
function InputDeviceHandler:_isBindableHidDevice(entry, hid_path, device_address)
    local bus = entry:match("^(%x%x%x%x):%x%x%x%x:%x%x%x%x%.%x+$")

    if bus ~= InputDeviceHandler.HID_BUS_BLUETOOTH or self.hid_bind_attempts[hid_path] then
        return false
    end

    if lfs.attributes(hid_path .. "/driver", "mode") then
        return false
    end

    local modalias = self:_readSysfsFile(hid_path .. "/modalias") or ""
    local group = modalias:match("^hid:b%x+g(%x%x%x%x)")

    if not InputDeviceHandler.HID_GROUPS_MULTITOUCH[group] then
        return false
    end

    if device_address then
        local uevent = self:_readSysfsFile(hid_path .. "/uevent") or ""
        local uniq = uevent:match("HID_UNIQ=([%x:]+)")

        return self:_isSameBluetoothAddress(uniq, device_address)
    end

    return true
end

---
--- Writes a HID device's ID to hid-generic's new_id and remembers the attempt.
--- @param entry string Directory entry, <bus>:<vendor>:<product>.<instance>
--- @param hid_path string Full sysfs path of the device
--- @return boolean True if the ID was written
function InputDeviceHandler:_bindToHidGeneric(entry, hid_path)
    self.hid_bind_attempts[hid_path] = true

    local bus, vendor, product = entry:match("^(%x%x%x%x):(%x%x%x%x):(%x%x%x%x)")
    local new_id = io.open(InputDeviceHandler.HID_GENERIC_NEW_ID, "w")

    if not new_id then
        logger.warn("InputDeviceHandler: Cannot write hid-generic new_id for", hid_path)

        return false
    end

    local written, err = new_id:write(string.format("%s %s %s", bus, vendor, product))
    new_id:close()

    if not written then
        logger.warn("InputDeviceHandler: hid-generic rejected the ID of", hid_path, ":", err)

        return false
    end

    logger.info("InputDeviceHandler: Bound driverless Bluetooth HID device to hid-generic:", hid_path)

    return true
end

---
--- Reads a whole sysfs file.
--- @param path string File path
--- @return string|nil Content, or nil if the file cannot be opened
function InputDeviceHandler:_readSysfsFile(path)
    local file = io.open(path, "r")

    if not file then
        return nil
    end

    local content = file:read("*a")
    file:close()

    return content
end

---
--- Compares two Bluetooth addresses, ignoring case and byte order: the HID
--- layer on MTK devices reports the address with its bytes reversed.
--- @param a string|nil
--- @param b string|nil
--- @return boolean
function InputDeviceHandler:_isSameBluetoothAddress(a, b)
    if not a or not b then
        return false
    end

    a, b = a:upper(), b:upper()

    if a == b then
        return true
    end

    local reversed = {}

    for byte in a:gmatch("%x%x") do
        table.insert(reversed, 1, byte)
    end

    return table.concat(reversed, ":") == b
end

---
--- Reads the HID parent and Bluetooth identity of an input node.
--- Never infer ownership from an event number or a non-unique device name.
--- @param device_path string Path to /dev/input/eventN
--- @return table|nil Identity with path, hid_parent and uniq
function InputDeviceHandler:_getInputIdentity(device_path)
    local event = device_path:match("^/dev/input/(event%d+)$")

    if not event then
        return nil
    end

    local sysfs_path = "/sys/class/input/" .. event
    local handle = io.popen("readlink " .. sysfs_path .. " 2>/dev/null")

    if not handle then
        return nil
    end

    local target = handle:read("*l")
    handle:close()
    local parent = target and target:match("^(.-/uhid/[^/]+)/input/")

    if not parent or not parent:match("/0005:") then
        return nil
    end

    local uniq = self:_readSysfsFile(sysfs_path .. "/device/uniq")
    uniq = uniq and uniq:match("^%s*(.-)%s*$")

    if not uniq or uniq == "" then
        local uevent = self:_readSysfsFile(sysfs_path .. "/device/../../uevent") or ""
        uniq = uevent:match("HID_UNIQ=([%x:]+)")
    end

    return { path = device_path, hid_parent = parent, uniq = uniq }
end

---
--- Finds every input collection belonging to a Bluetooth address.
--- A matching uniq establishes ownership of a HID parent. Siblings without a
--- uniq are accepted only under that parent; an explicit different uniq wins.
--- @param device_info table Device information with address
--- @return table Array of verified input identities, sorted by path
function InputDeviceHandler:findInputDevices(device_info)
    local identities, parents = {}, {}

    for _, path in ipairs(self:detectBluetoothInputDevices()) do
        local identity = self:_getInputIdentity(path)

        if identity then
            table.insert(identities, identity)

            if self:_isSameBluetoothAddress(identity.uniq, device_info.address) then
                parents[identity.hid_parent] = true
            end
        end
    end

    local matches = {}

    for _, identity in ipairs(identities) do
        local matching = self:_isSameBluetoothAddress(identity.uniq, device_info.address)
        local unidentified_sibling = (not identity.uniq or identity.uniq == "") and parents[identity.hid_parent]

        if matching or unidentified_sibling then
            table.insert(matches, identity)
        end
    end

    table.sort(matches, function(a, b)
        return a.path < b.path
    end)

    return matches
end

---
--- Finds a verified input node without waiting, for the direct connect loop.
--- @param device_info table Device information with address
--- @return string|nil Path to the first verified input collection
function InputDeviceHandler:findInputNodeForDevice(device_info)
    if not device_info or not device_info.address then
        return nil
    end

    self:_bindUnclaimedHidDevices(device_info.address)
    local devices = self:findInputDevices(device_info)

    return devices[1] and devices[1].path
end

--- Schedules bounded node discovery, including late sibling collections.
--- Pending scan identity invalidates stale callbacks after close or suspend.
--- @param device_info table Bluetooth device
--- @param show_messages boolean Whether to report input readiness
--- @param ready boolean Whether inputs are already open
function InputDeviceHandler:_scheduleInputScan(device_info, show_messages, ready)
    local address = device_info.address

    if self.pending_input_scans[address] then
        return
    end

    local polls = 0
    local scan

    scan = function()
        if self.pending_input_scans[address] ~= scan then
            return
        end

        polls = polls + 1
        local opened = self:openIsolatedInputDevice(device_info, show_messages ~= false and not ready, false)
        ready = ready or opened

        if polls >= InputDeviceHandler.INPUT_SCAN_MAX_POLLS then
            self.pending_input_scans[address] = nil

            if not ready and show_messages ~= false then
                UIManager:show(InfoMessage:new({
                    text = _("Bluetooth input device not found.\nYou may need to reconnect the device."),
                    timeout = 3,
                }))
            end

            return
        end

        UIManager:scheduleIn(InputDeviceHandler.INPUT_SCAN_INTERVAL, scan)
    end

    self.pending_input_scans[address] = scan
    UIManager:scheduleIn(InputDeviceHandler.INPUT_SCAN_INTERVAL, scan)
end

---
--- Cancels node discovery for one remote.
--- @param address string Bluetooth address
function InputDeviceHandler:_cancelInputScan(address)
    local scan = self.pending_input_scans[address]
    self.pending_input_scans[address] = nil

    if scan then
        UIManager:unschedule(scan)
    end
end

---
--- Automatically opens input devices for all connected paired devices.
--- @param paired_devices table Array of paired device information
function InputDeviceHandler:autoOpenConnectedDevices(paired_devices)
    logger.dbg("InputDeviceHandler: Auto-opening connected devices")

    for _, device in ipairs(paired_devices) do
        if device.connected then
            logger.info("InputDeviceHandler: Found connected device on startup:", device.name or device.address)

            local success = self:openIsolatedInputDevice(device, false, true)

            if success then
                logger.info("InputDeviceHandler: Auto-opened input device for", device.name or device.address)
            end
        end
    end
end

---
--- Opens all verified input collections for a Bluetooth device.
--- Repeated calls add late collections without reopening existing readers.
--- Unidentified nodes are rejected, even if their names match.
--- @param device_info table Device information with address
--- @param show_messages boolean Whether to show UI messages (default: true)
--- @param wait_for_device boolean Whether to wait for input nodes (default: false)
--- @return boolean True if inputs are open
--- @return boolean True if discovery is pending
function InputDeviceHandler:openIsolatedInputDevice(device_info, show_messages, wait_for_device)
    if not device_info or not device_info.address then
        return false
    end

    self:_bindUnclaimedHidDevices(device_info.address)
    local devices = self:findInputDevices(device_info)

    local readers = self.isolated_readers[device_info.address] or {}
    self.isolated_readers[device_info.address] = readers
    local opened = 0
    local closed_paths = {}

    for _, identity in ipairs(devices) do
        local existing = readers[identity.path]

        if not existing or existing.hid_parent ~= identity.hid_parent or not existing.reader:isOpen() then
            local reader = BluetoothInputReader:new()

            if reader:open(identity.path) then
                for _, callback in ipairs(self.key_event_callbacks) do
                    reader:registerKeyCallback(callback)
                end

                -- A reused event path must not remain assigned to another remote.
                local previous_owners = {}

                for address, owned in pairs(self.isolated_readers) do
                    if address ~= device_info.address and owned[identity.path] then
                        table.insert(previous_owners, address)
                    end
                end

                for _, address in ipairs(previous_owners) do
                    self:_closeInputNode(address, identity.path)
                end

                if existing then
                    existing.reader:close()
                end

                readers[identity.path] = { reader = reader, hid_parent = identity.hid_parent }
                self.isolated_readers[device_info.address] = readers

                if existing then
                    self:_notifyInputCallbacks(self.device_close_callbacks, device_info.address, identity.path)
                end

                opened = opened + 1
                self:_notifyInputCallbacks(self.device_open_callbacks, device_info.address, identity.path)
            elseif existing then
                existing.reader:close()
                readers[identity.path] = nil
                table.insert(closed_paths, identity.path)
            end
        end
    end

    if not next(readers) then
        self.isolated_readers[device_info.address] = nil
    end

    -- Close callbacks must see the final set, not an intermediate empty map.
    for _, path in ipairs(closed_paths) do
        self:_notifyInputCallbacks(self.device_close_callbacks, device_info.address, path)
    end

    if wait_for_device then
        self:_scheduleInputScan(device_info, show_messages, next(readers) ~= nil)
    end

    if not next(readers) then
        self.isolated_readers[device_info.address] = nil

        if show_messages ~= false and not self.pending_input_scans[device_info.address] then
            UIManager:show(InfoMessage:new({
                text = _("Bluetooth input device not found.\nYou may need to reconnect the device."),
                timeout = 3,
            }))
        end

        return false, self.pending_input_scans[device_info.address] ~= nil
    end

    if opened > 0 and show_messages ~= false then
        UIManager:show(InfoMessage:new({
            text = _("%s ready"):format(device_info.name or device_info.address),
            timeout = 2,
        }))
    end

    return true
end

---
--- Invokes per-node callbacks after the reader map has been updated.
--- @param callbacks table Callback array
--- @param address string Bluetooth address
--- @param path string Input path
function InputDeviceHandler:_notifyInputCallbacks(callbacks, address, path)
    for _, callback in ipairs(callbacks) do
        local ok, err = pcall(callback, address, path)

        if not ok then
            logger.warn("InputDeviceHandler: Input callback error:", err)
        end
    end
end

---
--- Closes one collection, retaining the other collections of the same remote.
--- @param address string Bluetooth address
--- @param path string Input path
function InputDeviceHandler:_closeInputNode(address, path)
    local readers = self.isolated_readers[address]
    local info = readers and readers[path]

    if not info then
        return
    end

    info.reader:close()
    readers[path] = nil

    if not next(readers) then
        self.isolated_readers[address] = nil
    end

    self:_notifyInputCallbacks(self.device_close_callbacks, address, path)
end

---
--- Closes every input collection of one remote.
--- @param device_info table Device information with address
function InputDeviceHandler:closeIsolatedInputDevice(device_info)
    self:_cancelInputScan(device_info.address)
    local readers = self.isolated_readers[device_info.address] or {}
    local paths = {}

    for path in pairs(readers) do
        table.insert(paths, path)
    end

    for _, path in ipairs(paths) do
        self:_closeInputNode(device_info.address, path)
    end
end

---
--- Closes all isolated Bluetooth input devices.
function InputDeviceHandler:closeAllIsolatedInputDevices()
    local pending = self.pending_input_scans
    self.pending_input_scans = {}

    for _, scan in pairs(pending) do
        UIManager:unschedule(scan)
    end

    local addresses = {}

    for address in pairs(self.isolated_readers) do
        table.insert(addresses, address)
    end

    for _, address in ipairs(addresses) do
        self:closeIsolatedInputDevice({ address = address })
    end
end

---
--- Registers a callback for key events from isolated readers.
--- This callback will receive events ONLY from Bluetooth devices.
---
--- @param callback function Callback function(key_code, key_value, time, device_path) where:
---   - key_code: The key code (ev.code)
---   - key_value: 1 for press, 0 for release, 2 for repeat
---   - time: Event timestamp table with sec and usec fields
---   - device_path: Path to the input device (e.g., "/dev/input/event4")
function InputDeviceHandler:registerKeyEventCallback(callback)
    table.insert(self.key_event_callbacks, callback)

    for _, readers in pairs(self.isolated_readers) do
        for _, info in pairs(readers) do
            info.reader:registerKeyCallback(callback)
        end
    end

    logger.dbg("InputDeviceHandler: Registered key event callback")
end

---
--- Registers a callback for device open events.
--- Called when an isolated input device is successfully opened.
---
--- @param callback function Callback function(device_address, device_path) where:
---   - device_address: MAC address of the Bluetooth device
---   - device_path: Path to the input device (e.g., "/dev/input/event4")
function InputDeviceHandler:registerDeviceOpenCallback(callback)
    table.insert(self.device_open_callbacks, callback)
    logger.dbg("InputDeviceHandler: Registered device open callback")
end

---
--- Registers a callback for device close events.
--- Called when an isolated input device is closed.
---
--- @param callback function Callback function(device_address, device_path) where:
---   - device_address: MAC address of the Bluetooth device
---   - device_path: Path to the input device that was closed
function InputDeviceHandler:registerDeviceCloseCallback(callback)
    table.insert(self.device_close_callbacks, callback)
    logger.dbg("InputDeviceHandler: Registered device close callback")
end

---
--- Clears all registered key event callbacks.
function InputDeviceHandler:clearKeyEventCallbacks()
    self.key_event_callbacks = {}

    for _, readers in pairs(self.isolated_readers) do
        for _, info in pairs(readers) do
            info.reader:clearCallbacks()
        end
    end

    logger.dbg("InputDeviceHandler: Cleared all key event callbacks")
end

---
--- Polls all isolated readers for input events.
--- Should be called periodically (e.g., via UIManager scheduling).
--- Automatically cleans up readers that have been closed due to device disconnect.
---
--- @param timeout_ms number Optional timeout in milliseconds (default: 0 for non-blocking)
--- @return table|nil Array of all events from all Bluetooth devices, or nil if none
function InputDeviceHandler:pollIsolatedReaders(timeout_ms)
    local all_events, disconnected = {}, {}

    for address, readers in pairs(self.isolated_readers) do
        for path, info in pairs(readers) do
            local events = info.reader:poll(timeout_ms)

            for _, ev in ipairs(events or {}) do
                local new_ev = {}

                for k, v in pairs(ev) do
                    new_ev[k] = v
                end

                new_ev.device_address = address
                table.insert(all_events, new_ev)
            end

            if not info.reader:isOpen() then
                table.insert(disconnected, { address = address, path = path })
            end
        end
    end

    for _, node in ipairs(disconnected) do
        self:_closeInputNode(node.address, node.path)
    end

    if #all_events > 0 then
        return all_events
    end

    return nil
end

---
--- Gets one open reader of a remote, optionally for a specific collection.
--- @param device_address string Bluetooth address
--- @param device_path string|nil Input path; otherwise the first sorted path
--- @return table|nil BluetoothInputReader
function InputDeviceHandler:getIsolatedReader(device_address, device_path)
    local readers = self.isolated_readers[device_address] or {}

    if device_path then
        return readers[device_path] and readers[device_path].reader
    end

    local paths = {}

    for path in pairs(readers) do
        table.insert(paths, path)
    end

    table.sort(paths)

    return paths[1] and readers[paths[1]].reader
end

---
--- Checks whether any remote has an open input reader.
--- @return boolean
function InputDeviceHandler:hasIsolatedReaders()
    for _, readers in pairs(self.isolated_readers) do
        for _, info in pairs(readers) do
            if info.reader:isOpen() then
                return true
            end
        end
    end

    return false
end

return InputDeviceHandler
