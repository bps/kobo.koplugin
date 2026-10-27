require("spec.helper")
local ffi = require("ffi")
for _, declaration in ipairs({
    "int mkstemps(char *, int);",
    "int open(const char *, int, ...);",
    "int fsync(int);",
    "int close(int);",
    "static const unsigned O_RDONLY = 0;",
}) do
    pcall(ffi.cdef, declaration)
end

describe("Atomic decrypted archives", function()
    local saved, kdrm, path, writer_path, failure, output, input
    local names = {
        "ffi/archiver",
        "src/lib/drm/file_decryptor",
        "src/lib/drm/key_derivation",
        "src/lib/drm/archive_writer",
    }

    local function readFile(filename)
        local file = io.open(filename, "r")
        if not file then
            return nil
        end
        local text = file:read("*a")
        file:close()
        return text
    end

    before_each(function()
        saved = {}
        for _, name in ipairs(names) do
            saved[name] = package.loaded[name]
        end
        failure = nil
        path = os.tmpname()
        local file = assert(io.open(path, "w"))
        file:write("old valid book")
        file:close()
        input = {
            open = function()
                return true
            end,
            iterate = function()
                local i = 0
                return function()
                    i = i + 1
                    if i <= 2 then
                        return { index = i, path = i == 1 and "mimetype" or "chapter", mode = "file" }
                    end
                end
            end,
            extractToMemory = function(_, index)
                if failure == "extract" and index == 2 then
                    return nil
                end
                return index == 1 and "application/epub+zip" or "encrypted"
            end,
            close = function() end,
        }
        output = {
            open = function(_, filename)
                writer_path = filename
                assert(io.open(filename, "w")):close()
                return true
            end,
            addFileFromMemory = function(_, _, content)
                if failure == "write" then
                    return nil
                end
                local out = assert(io.open(writer_path, "a"))
                out:write(content)
                out:close()
                return true
            end,
            setZipCompression = function()
                return true
            end,
            close = function()
                return failure ~= "close"
            end,
        }
        package.loaded["ffi/archiver"] = {
            Reader = {
                new = function()
                    return input
                end,
            },
            Writer = {
                new = function()
                    return output
                end,
            },
        }
        package.loaded["src/lib/drm/file_decryptor"] = {
            decryptContentKey = function()
                return "key"
            end,
            decryptFileContent = function()
                if failure ~= "decrypt" then
                    return "decrypted"
                end
            end,
        }
        package.loaded["src/lib/drm/key_derivation"] = {
            findWorkingKey = function()
                return "user-key"
            end,
        }
        -- Model checked finalization separately from archive entry production.
        local archive_writer = dofile("src/lib/drm/archive_writer.lua")
        archive_writer.close = function(w)
            return w:close()
        end
        package.loaded["src/lib/drm/archive_writer"] = archive_writer
        kdrm = dofile("src/lib/drm/kobo_kdrm.lua")
        kdrm.getDeviceSerial = function()
            return "serial"
        end
        kdrm.getUserId = function()
            return "user"
        end
        kdrm.getContentKeys = function()
            return { chapter = "key" }
        end
    end)

    after_each(function()
        os.remove(path)
        if writer_path and writer_path ~= path then
            os.remove(writer_path)
        end
        writer_path = nil
        for _, name in ipairs(names) do
            package.loaded[name] = saved[name]
        end
    end)

    it("keeps the previous file visible until a complete archive is finalized", function()
        local original_close = output.close
        output.close = function(self)
            assert.are.equal("old valid book", readFile(path))
            return original_close(self)
        end
        assert.is_true(kdrm:decryptBook("book", "input", path, "kobo", "db"))
        assert.are_not.equal(path, writer_path)
        assert.are.equal("application/epub+zipdecrypted", readFile(path))
        assert.is_nil(readFile(writer_path))
    end)

    for _, stage in ipairs({ "extract", "decrypt", "write", "close" }) do
        it("preserves the previous cache and removes partial output on " .. stage .. " failure", function()
            failure = stage
            local ok = kdrm:decryptBook("book", "input", path, "kobo", "db")
            assert.is_false(ok)
            assert.are.equal("old valid book", readFile(path))
            assert.is_nil(readFile(writer_path))
        end)
    end
end)
