local runtime = dofile("test/integration/runtime.lua")
local sqlite = require("lua-ljsqlite3/init")
local writer = require("src/lib/kobo_state_writer")

local function database()
    local path = runtime.temporaryFile()
    local db = sqlite.open(path)
    runtime.cleanup(function() db:close() end)
    db:exec([[
        CREATE TABLE content (
            ContentID TEXT PRIMARY KEY, ContentType INTEGER, ___PercentRead REAL,
            ___FileOffset REAL, ___FileSize REAL, DateLastRead TEXT, ReadStatus INTEGER,
            ChapterIDBookmarked TEXT, ReadStateSynced TEXT
        );
        INSERT INTO content VALUES ('BOOK', 6, 10, 0, 0, '', 1, '', 'false');
        INSERT INTO content VALUES ('BOOK!!chapter.html', 9, 20, 0, 100, '', 1, '', 'false');
    ]])
    return path, db
end
local function unchanged(db)
    local result = db:exec("SELECT ___PercentRead FROM content ORDER BY ContentType")
    assert(result[1][1] == 10 and result[1][2] == 20, "partial progress update escaped rollback")
end

runtime.test("commits chapter and book progress together", function()
    local path, db = database()
    assert(writer.write(path, "BOOK", 50, 1, "reading"))
    local result = db:exec("SELECT ___PercentRead FROM content ORDER BY ContentType")
    assert(result[1][1] == 50 and result[1][2] == 50)
end)

for _, content_type in ipairs({ 9, 6 }) do
    runtime.test("rolls back when ContentType " .. content_type .. " update fails", function()
        local path, db = database()
        local trigger = db:prepare("CREATE TRIGGER reject_update BEFORE UPDATE ON content WHEN NEW.ContentType = "
            .. content_type .. " BEGIN SELECT RAISE(FAIL, 'injected update failure'); END")
        trigger:step()
        trigger:close()
        assert(writer.write(path, "BOOK", 50, 1, "reading") == false, "failed update reported success")
        unchanged(db)
        db:exec("DROP TRIGGER reject_update")
        assert(writer.write(path, "BOOK", 50, 1, "reading"), "failed write leaked a lock")
    end)
end

runtime.test("rolls back a COMMIT blocked by another reader", function()
    local path, db = database()
    db:exec("BEGIN")
    db:exec("SELECT * FROM content")
    assert(writer.write(path, "BOOK", 50, 1, "reading") == false, "busy commit reported success")
    unchanged(db)
    db:exec("ROLLBACK")
    assert(writer.write(path, "BOOK", 50, 1, "reading"), "busy commit leaked a write lock")
end)

runtime.test("returns failure rather than throwing when the database is locked", function()
    local path, db = database()
    db:exec("BEGIN EXCLUSIVE")
    assert(writer.write(path, "BOOK", 50, 1, "reading") == false)
    db:exec("ROLLBACK")
    unchanged(db)
end)

runtime.finish()
