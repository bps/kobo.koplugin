local runtime = dofile("test/integration/runtime.lua")
local lfs = require("lfs")

local function quote(text)
    return "'" .. text:gsub("'", "'\\''") .. "'"
end
local function read(path)
    local file = assert(io.open(path, "r"))
    local text = file:read("*a")
    file:close()
    return text
end
local function write(path, text)
    local file = assert(io.open(path, "w"))
    assert(file:write(text))
    assert(file:close())
end
local function removeTree(path)
    if lfs.attributes(path, "mode") == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                removeTree(path .. "/" .. name)
            end
        end
        assert(lfs.rmdir(path))
    else
        assert(os.remove(path))
    end
end
local function fixture()
    local root = os.tmpname()
    os.remove(root)
    assert(lfs.mkdir(root))
    runtime.cleanup(function()
        removeTree(root)
    end)
    for _, dir in ipairs({ "out", "patches", "src", "spec" }) do
        assert(lfs.mkdir(root .. "/" .. dir))
    end
    write(root .. "/main.lua", "return true")
    write(root .. "/_meta.lua", "return {}")
    write(root .. "/src/module.lua", "return {}")
    write(root .. "/spec/private_spec.lua", "error('must not ship')")
    -- Redirect only the old script's fixed output directory so red tests cannot
    -- overwrite a developer's existing /tmp artifacts. The packaging logic is unchanged.
    local script = read("package.sh"):gsub('OUTPUT_DIR="/tmp"', 'OUTPUT_DIR="${OUTPUT_DIR:-/tmp}"')
    write(root .. "/package.bash", script)
    return root
end
local function build(root, prefix)
    return os.execute(
        "cd "
            .. quote(root)
            .. " && "
            .. (prefix or "")
            .. " OUTPUT_DIR="
            .. quote(root .. "/out")
            .. " bash package.bash > build.log 2>&1"
    ) == 0
end
local function entries(path)
    local pipe = assert(io.popen("unzip -Z1 " .. quote(path)))
    local result = pipe:read("*a")
    assert(pipe:close())
    return result
end

runtime.test("rebuilding removes deleted patches from the published ZIP", function()
    local root = fixture()
    write(root .. "/patches/2-obsolete.lua", "return true")
    assert(build(root), read(root .. "/build.log"))
    os.remove(root .. "/patches/2-obsolete.lua")
    write(root .. "/patches/2-current.lua", "return true")
    assert(build(root), read(root .. "/build.log"))
    local list = entries(root .. "/out/kobo-patches.zip")
    assert(not list:find("2-obsolete.lua", 1, true), "deleted patch remained in release ZIP")
    assert(list:find("2-current.lua", 1, true))
end)

runtime.test("ZIP failure fails the build even when an older artifact exists", function()
    local root = fixture()
    write(root .. "/patches/2-current.lua", "return true")
    assert(build(root))
    local pipe = assert(io.popen("command -v zip"))
    local zip = assert(pipe:read("*l"))
    pipe:close()
    assert(lfs.mkdir(root .. "/bin"))
    write(
        root .. "/bin/zip",
        '#!/bin/sh\ncase "$*" in *kobo-patches.zip*) exit 1 ;; esac\nexec ' .. quote(zip) .. ' "$@"\n'
    )
    assert(os.execute("chmod +x " .. quote(root .. "/bin/zip")) == 0)
    assert(not build(root, "PATH=" .. quote(root .. "/bin") .. ':"$PATH"'), "ZIP failure was reported as success")
end)

runtime.test("plugin ZIP contains runtime modules and excludes tests", function()
    local root = fixture()
    write(root .. "/patches/2-current.lua", "return true")
    assert(build(root))
    local list = entries(root .. "/out/kobo.koplugin.zip")
    assert(list:find("kobo.koplugin/main.lua", 1, true))
    assert(list:find("kobo.koplugin/_meta.lua", 1, true))
    assert(list:find("kobo.koplugin/src/module.lua", 1, true))
    assert(not list:find("private_spec", 1, true))
end)
runtime.finish()
