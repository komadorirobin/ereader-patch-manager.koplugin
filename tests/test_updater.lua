package.path = "./?.lua;" .. package.path

local trapper = { wrapped = false }

function trapper:isWrapped()
    return self.wrapped
end

function trapper:wrap(operation)
    self.wrapped = true
    local result = operation()
    self.wrapped = false
    return result
end

function trapper:dismissableRunInSubprocess(operation, widget, simple_string)
    self.last_widget = widget
    self.last_simple_string = simple_string
    if self.cancel_next then
        self.cancel_next = false
        return false
    end
    return true, operation()
end

local ui_manager = {}
function ui_manager:scheduleIn(_, operation) operation() end

local function stub(name, value)
    package.preload[name] = function() return value end
end

stub("ui/widget/confirmbox", { new = function(_, value) return value end })
stub("datastorage", { getDataDir = function() return "/tmp" end })
local device = {}
stub("device", device)
stub("ui/network/manager", {})
stub("ui/widget/notification", { new = function(_, value) return value end })
stub("ui/trapper", trapper)
stub("ui/uimanager", ui_manager)
stub("ltn12", { sink = {} })
stub("rapidjson", {})
stub("socket", {})
stub("socket.http", {})
stub("socketutil", {})
stub("gettext", function(value) return value end)

local helpers = require("patchmanager_updater")._test
assert(helpers.isNewer("1.1.0", "1.0.2"), "minor release should be newer")
assert(not helpers.isNewer("1.1.0", "1.1.0"), "equal releases must not update")
assert(not helpers.isNewer("1.0.9", "1.1.0"), "older releases must not update")

assert(helpers.safeArchivePath("ereader-patch-manager.koplugin/main.lua"))
assert(not helpers.safeArchivePath("../main.lua"))
assert(not helpers.safeArchivePath("ereader-patch-manager.koplugin/../main.lua"))
assert(not helpers.safeArchivePath("different.koplugin/main.lua"))
assert(not helpers.safeArchivePath("/ereader-patch-manager.koplugin/main.lua"))

local received
helpers.runTask(function()
    return { success = true, marker = "preserved" }
end, "Updating…", function(result)
    received = result
end, false)
assert(trapper.last_widget == "Updating…", "interactive updater should show progress")
assert(trapper.last_simple_string == false, "updater table results need KOReader serialization")
assert(received and received.success and received.marker == "preserved")

trapper.cancel_next = true
helpers.runTask(function() return { success = true } end, "Updating…", function(result)
    received = result
end, true)
assert(trapper.last_widget == false, "background updater should be quiet")
assert(received and received.error == "operation_cancelled")

local extracted_paths = {}
local Reader = {}
Reader.__index = Reader
function Reader:new() return setmetatable({}, Reader) end
function Reader:open() return true end
function Reader:iterate()
    local entries = {
        { path = "ereader-patch-manager.koplugin/" },
        { path = "ereader-patch-manager.koplugin/main.lua" },
    }
    local index = 0
    return function()
        index = index + 1
        return entries[index]
    end
end
function Reader:extractToPath(source, destination)
    extracted_paths[#extracted_paths + 1] = { source = source, destination = destination }
    return true
end
function Reader:close() end

package.preload["ffi/archiver"] = function() return { Reader = Reader } end
package.loaded["ffi/archiver"] = nil
local extracted, extract_err = helpers.extractArchive("/tmp/update.zip", "/tmp/plugins")
assert(extracted and not extract_err)
assert(extracted_paths[2].destination ==
    "/tmp/plugins/ereader-patch-manager.koplugin/main.lua")

function Reader:iterate()
    local yielded = false
    return function()
        if yielded then return nil end
        yielded = true
        return { path = "ereader-patch-manager.koplugin/../outside.lua" }
    end
end
extracted, extract_err = helpers.extractArchive("/tmp/update.zip", "/tmp/plugins")
assert(not extracted and extract_err == "unsafe_archive_path")

package.preload["ffi/archiver"] = function() error("archiver unavailable") end
package.loaded["ffi/archiver"] = nil
local legacy_called = false
device.unpackArchive = function(_, zip_path, parent, strip_root)
    legacy_called = zip_path == "/tmp/update.zip"
        and parent == "/tmp/plugins" and strip_root == false
    return true
end
extracted, extract_err = helpers.extractArchive("/tmp/update.zip", "/tmp/plugins")
assert(extracted and not extract_err and legacy_called,
    "older KOReader builds should retain the archive fallback")

print("PASS updater")
