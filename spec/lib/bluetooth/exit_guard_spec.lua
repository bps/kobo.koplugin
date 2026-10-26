require("spec.helper")

describe("Bluetooth exit guard", function()
    local saved_modules
    local bluetooth_on
    local guard, plugin
    local UIManager, DeviceListener, exit_settings
    local sent, broadcast, exits, messages
    local module_names = {
        "device/devicelistener",
        "ui/widget/infomessage",
        "ui/uimanager",
        "ui/elements/common_exit_menu_table",
        "gettext",
    }

    local function installGuard()
        guard = dofile("src/lib/bluetooth/exit_guard.lua")
        guard.install(plugin)
    end

    before_each(function()
        saved_modules = {}
        for _, name in ipairs(module_names) do
            saved_modules[name] = package.loaded[name]
        end

        bluetooth_on = false
        sent, broadcast, exits, messages = {}, {}, {}, {}
        UIManager = {
            sendEvent = function(self, event, arg)
                table.insert(sent, { self, event, arg })
                return "sent", arg
            end,
            broadcastEvent = function(self, event, arg)
                table.insert(broadcast, { self, event, arg })
                return "broadcast", arg
            end,
            show = function(_, message)
                table.insert(messages, message)
            end,
        }
        DeviceListener = {
            onExit = function(self, callback)
                table.insert(exits, { self, callback })
                return "exit", callback
            end,
        }
        exit_settings = {
            exit = {},
            exit_menu = {},
            restart_koreader = {},
        }
        package.loaded["device/devicelistener"] = DeviceListener
        package.loaded["ui/widget/infomessage"] = {
            new = function(_, message)
                return message
            end,
        }
        package.loaded["ui/uimanager"] = UIManager
        package.loaded["ui/elements/common_exit_menu_table"] = exit_settings
        package.loaded["gettext"] = function(text)
            return text
        end
        plugin = {
            settings = { prevent_exit_while_bluetooth_on = true },
            kobo_bluetooth = {
                isBluetoothEnabled = function()
                    return bluetooth_on
                end,
            },
        }
    end)

    after_each(function()
        for _, name in ipairs(module_names) do
            package.loaded[name] = saved_modules[name]
        end
    end)

    it("updates the Exit leaf dynamically without disabling the parent or restart", function()
        installGuard()
        assert.is_true(exit_settings.exit.enabled_func())
        bluetooth_on = true
        assert.is_false(exit_settings.exit.enabled_func())
        assert.is_nil(exit_settings.exit_menu.enabled_func)
        assert.is_nil(exit_settings.restart_koreader.enabled_func)
        bluetooth_on = false
        assert.is_true(exit_settings.exit.enabled_func())
    end)

    it("preserves an existing enabled predicate and its arguments", function()
        local allowed = false
        exit_settings.exit.enabled_func = function(arg)
            assert.are.equal("original", arg)
            return allowed
        end
        installGuard()
        assert.is_false(exit_settings.exit.enabled_func("original"))
        allowed = true
        assert.is_true(exit_settings.exit.enabled_func("original"))
        bluetooth_on = true
        assert.is_false(exit_settings.exit.enabled_func("original"))
    end)

    it("handles the single Exit item on devices without restart support", function()
        exit_settings.exit = nil
        installGuard()
        bluetooth_on = true
        assert.is_false(exit_settings.exit_menu.enabled_func())
        bluetooth_on = false
        assert.is_true(exit_settings.exit_menu.enabled_func())
    end)

    it("blocks Exit before either event dispatch path can notify other plugins", function()
        installGuard()
        bluetooth_on = true
        assert.is_true(UIManager:sendEvent({ handler = "onExit" }))
        assert.is_true(UIManager:broadcastEvent({ handler = "onExit" }))
        assert.are.equal(0, #sent)
        assert.are.equal(0, #broadcast)
        assert.are.equal(2, #messages)
        assert.are.equal("Turn Bluetooth off before exiting KOReader.", messages[1].text)
    end)

    it("blocks direct keyboard Exit handling without calling the original", function()
        installGuard()
        bluetooth_on = true
        assert.is_true(DeviceListener:onExit(function() end))
        assert.are.equal(0, #exits)
        assert.are.equal(1, #messages)
    end)

    it("preserves Exit dispatch, callbacks and return values while Bluetooth is off", function()
        installGuard()
        local event = { handler = "onExit" }
        local callback = function() end
        assert.are.same({ "sent", callback }, { UIManager:sendEvent(event, callback) })
        assert.are.same({ "broadcast", callback }, { UIManager:broadcastEvent(event, callback) })
        assert.are.same({ "exit", callback }, { DeviceListener:onExit(callback) })
        assert.are.same({ UIManager, event, callback }, sent[1])
        assert.are.same({ UIManager, event, callback }, broadcast[1])
        assert.are.same({ DeviceListener, callback }, exits[1])
        assert.are.equal(0, #messages)
    end)

    it("passes unrelated commands through while Bluetooth is on", function()
        installGuard()
        bluetooth_on = true
        for _, handler in ipairs({ "onRestart", "onRequestSuspend", "onRequestReboot", "onRequestPowerOff" }) do
            local event = { handler = handler }
            assert.are.equal("sent", UIManager:sendEvent(event))
            assert.are.equal("broadcast", UIManager:broadcastEvent(event))
        end
        assert.are.equal(4, #sent)
        assert.are.equal(4, #broadcast)
        assert.are.equal(0, #messages)
    end)

    it("allows Exit when the setting is disabled without querying Bluetooth", function()
        installGuard()
        bluetooth_on = true
        plugin.settings.prevent_exit_while_bluetooth_on = false
        plugin.kobo_bluetooth.isBluetoothEnabled = function()
            error("Bluetooth must not be queried when the guard is disabled")
        end
        assert.is_true(exit_settings.exit.enabled_func())
        assert.are.equal("sent", UIManager:sendEvent({ handler = "onExit" }))
        assert.are.equal("broadcast", UIManager:broadcastEvent({ handler = "onExit" }))
        assert.are.equal("exit", DeviceListener:onExit())
        assert.are.equal(0, #messages)
    end)

    it("uses the newest plugin instance without installing duplicate hooks", function()
        installGuard()
        local send = UIManager.sendEvent
        local broadcast_event = UIManager.broadcastEvent
        local on_exit = DeviceListener.onExit
        local enabled_func = exit_settings.exit.enabled_func
        bluetooth_on = true
        local replacement = {
            settings = { prevent_exit_while_bluetooth_on = false },
            kobo_bluetooth = { isBluetoothEnabled = function() return true end },
        }
        guard.install(replacement)
        assert.are.equal(send, UIManager.sendEvent)
        assert.are.equal(broadcast_event, UIManager.broadcastEvent)
        assert.are.equal(on_exit, DeviceListener.onExit)
        assert.are.equal(enabled_func, exit_settings.exit.enabled_func)
        assert.are.equal("sent", UIManager:sendEvent({ handler = "onExit" }))
        replacement.settings.prevent_exit_while_bluetooth_on = true
        assert.is_true(UIManager:sendEvent({ handler = "onExit" }))
        assert.are.equal(1, #messages)
        assert.are.equal(1, #sent)
    end)

    it("enables protection by default when the setting is absent", function()
        plugin.settings.prevent_exit_while_bluetooth_on = nil
        installGuard()
        bluetooth_on = true
        assert.is_false(exit_settings.exit.enabled_func())
    end)
end)
