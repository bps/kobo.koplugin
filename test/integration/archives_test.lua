local runtime = dofile("test/integration/runtime.lua")
local archiver = require("ffi/archiver")
local cache = require("src/lib/drm/cache_manager")
local checked = require("src/lib/drm/archive_writer")
local ffi = require("ffi")
local lfs = require("lfs")
-- Cryptography is outside this suite; archive, filesystem and rename operations are real.
package.loaded["src/lib/drm/file_decryptor"] = {
    decryptContentKey = function()
        return "key"
    end,
    decryptFileContent = function(_, content)
        return "decrypted:" .. content
    end,
}
package.loaded["src/lib/drm/key_derivation"] = {
    findWorkingKey = function()
        return "key"
    end,
}
local kdrm = require("src/lib/drm/kobo_kdrm")
kdrm.getDeviceSerial = function()
    return "serial"
end
kdrm.getUserId = function()
    return "user"
end
kdrm.getContentKeys = function()
    return { chapter = "key" }
end

local function contents(path)
    local file = assert(io.open(path, "rb"))
    local result = file:read("*a")
    file:close()
    return result
end
local function inputArchive()
    local path = runtime.temporaryFile()
    local writer = archiver.Writer:new()
    assert(writer:open(path, "zip"))
    assert(writer:addFileFromMemory("mimetype", "application/epub+zip"))
    assert(writer:addFileFromMemory("chapter", "encrypted"))
    assert(checked.close(writer))
    return path
end

runtime.test("cache path lookup preserves a real existing file", function()
    local path = runtime.temporaryFile()
    local file = assert(io.open(path, "w"))
    file:write("existing cache")
    file:close()
    local dir, name = path:match("^(.*)/([^/]+)$")
    assert(cache:ensureCachePath(name, dir) == path)
    assert(contents(path) == "existing cache")
end)

runtime.test("publishes a readable ZIP with stored mimetype and decrypted content", function()
    local input, output = inputArchive(), runtime.temporaryFile()
    assert(kdrm:decryptBook("book", input, output, "kobo", "db"))
    local bytes = contents(output)
    assert(bytes:byte(9) == 0 and bytes:byte(10) == 0, "mimetype was compressed")
    local reader = archiver.Reader:new()
    assert(reader:open(output))
    local entries = {}
    for entry in reader:iterate() do
        table.insert(entries, entry.path)
        local text = reader:extractToMemory(entry.index)
        assert(text == (entry.path == "mimetype" and "application/epub+zip" or "decrypted:encrypted"))
    end
    reader:close()
    assert(entries[1] == "mimetype" and #entries == 2)
end)

runtime.test("failed decryption leaves the previous complete archive byte-for-byte intact", function()
    local input, output = inputArchive(), inputArchive()
    local before = contents(output)
    local decryptor = package.loaded["src/lib/drm/file_decryptor"]
    local original = decryptor.decryptFileContent
    runtime.cleanup(function()
        decryptor.decryptFileContent = original
    end)
    decryptor.decryptFileContent = function()
        return nil
    end
    assert(kdrm:decryptBook("book", input, output, "kobo", "db") == false)
    assert(contents(output) == before)
end)

runtime.test("detects native libarchive finalization errors instead of publishing them", function()
    local output = runtime.temporaryFile()
    local archive = ffi.loadlib("archive")
    ffi.cdef("int archive_write_open_fd(struct archive *, int);")
    local fd = ffi.C.open(output, ffi.C.O_WRONLY)
    assert(fd >= 0)
    local writer = archiver.Writer:new()
    writer.archive = ffi.gc(archive.archive_write_new(), archive.archive_free)
    assert(archive.archive_write_set_format_by_name(writer.archive, "zip") == archive.ARCHIVE_OK)
    assert(archive.archive_write_open_fd(writer.archive, fd) == archive.ARCHIVE_OK)
    assert(writer:addFileFromMemory("chapter", "content"))
    ffi.C.close(fd) -- The buffered ZIP trailer can no longer be written.
    assert(checked.close(writer) == false, "archive close error was ignored")
end)

runtime.test("failed rename does not remove a destination directory", function()
    local destination = runtime.temporaryFile()
    os.remove(destination)
    assert(lfs.mkdir(destination))
    runtime.cleanup(function()
        lfs.rmdir(destination)
    end)
    assert(kdrm:decryptBook("book", inputArchive(), destination, "kobo", "db") == false)
    assert(lfs.attributes(destination, "mode") == "directory")
end)
runtime.finish()
