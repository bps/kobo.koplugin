---
--- Prevents the Exit command while Bluetooth is powered on.
--- Restart, sleep, reboot, power-off and direct UIManager:quit() calls are unchanged.

local DeviceListener = require("device/devicelistener")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local exit_settings = require("ui/elements/common_exit_menu_table")
local _ = require("gettext")

local ExitGuard = {}
local current_plugin
local installed = false

local function shouldBlockExit()
    return current_plugin.settings.prevent_exit_while_bluetooth_on ~= false
        and current_plugin.kobo_bluetooth:isBluetoothEnabled()
end

local function blockExit()
    if not shouldBlockExit() then
        return false
    end

    UIManager:show(InfoMessage:new({
        text = _("Turn Bluetooth off before exiting KOReader."),
        timeout = 3,
    }))

    return true
end

---
--- Installs the hooks once and follows the newest plugin instance.
--- KOReader creates a new plugin when switching between reader and file browser.
--- @param plugin table Plugin instance with settings and kobo_bluetooth
function ExitGuard.install(plugin)
    current_plugin = plugin

    if installed then
        return
    end

    installed = true

    -- Disable only the Exit leaf, not the parent containing restart and power actions.
    local exit_item = exit_settings.exit or exit_settings.exit_menu
    local original_enabled_func = exit_item.enabled_func
    exit_item.enabled_func = function(...)
        return not shouldBlockExit() and (not original_enabled_func or original_enabled_func(...))
    end

    -- Stop Exit before other plugins can tear down their resources.
    for _, method in ipairs({ "sendEvent", "broadcastEvent" }) do
        local original = UIManager[method]
        UIManager[method] = function(self, event, ...)
            if event.handler == "onExit" and blockExit() then
                return true
            end

            return original(self, event, ...)
        end
    end

    -- Keyboard bindings can dispatch directly through the widget tree.
    local original_onExit = DeviceListener.onExit
    function DeviceListener:onExit(...)
        if blockExit() then
            return true
        end

        return original_onExit(self, ...)
    end
end

return ExitGuard
