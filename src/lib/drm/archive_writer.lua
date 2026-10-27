--- Checked archive finalization and atomic publication of decrypted books.
local ffi = require("ffi")
require("ffi/posix_h")

local ArchiveWriter = {}

function ArchiveWriter.createTemporary(path)
    local template = path .. ".tmp.XXXXXX"
    local buffer = ffi.new("char[?]", #template + 1, template)
    local fd = ffi.C.mkstemps(buffer, 0)
    if fd < 0 then
        return nil, "Could not create temporary archive"
    end
    ffi.C.close(fd)
    return ffi.string(buffer)
end

function ArchiveWriter.close(writer)
    -- KOReader's Writer:close() discards archive_write_close's return value.
    -- Close explicitly while the GC-managed archive pointer is still available.
    local archive = ffi.loadlib("archive", "13")
    local result = archive.archive_write_close(writer.archive)
    local err = result ~= archive.ARCHIVE_OK and "Could not finalize output archive" or nil
    writer.archive = nil -- The FFI finalizer frees the already-closed archive.
    writer:close()
    return err == nil, err
end

function ArchiveWriter.publish(temporary, path)
    local fd = ffi.C.open(temporary, ffi.C.O_RDONLY)
    if fd < 0 then
        return false, "Could not open completed archive for syncing"
    end
    local synced = ffi.C.fsync(fd) == 0
    local closed = ffi.C.close(fd) == 0
    if not synced or not closed then
        return false, "Could not sync completed archive"
    end
    return os.rename(temporary, path)
end

return ArchiveWriter
