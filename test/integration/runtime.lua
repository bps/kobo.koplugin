-- Separate process: deliberately do not load spec/helper.lua or its I/O mocks.
local base = assert(os.getenv("KOREADER_BASE"), "Set KOREADER_BASE to a koreader-base checkout")
package.path = "./?.lua;" .. base .. "/?.lua;" .. base .. "/thirdparty/?.lua;" .. package.path
local ffi = require("ffi")
ffi.loadlib = function(name) return ffi.load(name) end
package.preload["libs/libkoreader-lfs"] = function() return require("lfs") end
package.preload.logger = function()
    return setmetatable({}, { __index = function() return function() end end })
end

local Runtime = { failures = 0, successes = 0 }
local cleanups
function Runtime.cleanup(fn) table.insert(cleanups, 1, fn) end
function Runtime.test(name, fn)
    cleanups = {}
    local ok, err = xpcall(fn, debug.traceback)
    for _, cleanup in ipairs(cleanups) do
        local cleaned, cleanup_err = pcall(cleanup)
        if not cleaned and ok then ok, err = false, cleanup_err end
    end
    if ok then
        Runtime.successes = Runtime.successes + 1
        print("PASS " .. name)
    else
        Runtime.failures = Runtime.failures + 1
        print("FAIL " .. name .. "\n" .. tostring(err))
    end
end
function Runtime.temporaryFile()
    local path = os.tmpname()
    Runtime.cleanup(function() os.remove(path) end)
    return path
end
function Runtime.finish()
    print(string.format("%d native integration tests passed; %d failed", Runtime.successes, Runtime.failures))
    assert(Runtime.failures == 0, "Native integration suite failed")
end
return Runtime
