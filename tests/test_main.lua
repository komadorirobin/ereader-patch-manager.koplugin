package.path = "./?.lua;" .. package.path

local scheduled
local registered
local settings = {}
local wrapped = 0
local shown, restarts = {}, {}

local WidgetContainer = {}
function WidgetContainer:extend(definition)
    definition.__index = definition
    return setmetatable(definition, { __index = self })
end

package.loaded["datastorage"] = {
    getPatchesDir = function() return "/tmp/ereader-patch-manager-main/patches" end,
    getSettingsDir = function() return "/tmp/ereader-patch-manager-main/settings" end,
}
package.loaded["ui/widget/infomessage"] = { new = function(_, value) return value end }
package.loaded["ui/network/manager"] = {
    isOnline = function() return false end,
    isConnected = function() return false end,
}
package.loaded["ui/widget/notification"] = { new = function(_, value) return value end }
package.loaded["ui/trapper"] = {
    dismissableRunInSubprocess = function() return false end,
    isWrapped = function() return false end,
    wrap = function(_, callback)
        wrapped = wrapped + 1
        return callback()
    end,
}
package.loaded["ui/uimanager"] = {
    scheduleIn = function(_, _, callback) scheduled = callback end,
    show = function(_, widget) shown[#shown + 1] = widget end,
    askForRestart = function(_, text)
        assert(type(text) == "string", "restart prompt must receive translated text")
        restarts[#restarts + 1] = text
    end,
}
package.loaded["ui/widget/container/widgetcontainer"] = WidgetContainer
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function() return "directory" end,
    mkdir = function() return true end,
}
package.loaded["logger"] = { warn = function() end }
package.loaded["rapidjson"] = { decode = function() return {} end }
package.loaded["gettext"] = function(text) return text end

G_reader_settings = {
    readSetting = function(_, key) return settings[key] end,
    saveSetting = function(_, key, value) settings[key] = value end,
    flush = function() end,
}

local Plugin = dofile("main.lua")
local instance = setmetatable({
    ui = {
        menu = {
            registerToMainMenu = function(_, plugin) registered = plugin end,
        },
    },
}, { __index = Plugin })

instance:init()
assert(registered == instance, "plugin should register its main menu")
assert(type(scheduled) == "function", "automatic startup sync should be scheduled")
scheduled()
assert(instance._sync_running == false, "offline startup must not start a sync")

local menu = {}
instance:addToMainMenu(menu)
assert(type(menu.ereader_patch_manager) == "table")
assert(type(menu.ereader_patch_manager.sub_item_table_func) == "function")
assert(#menu.ereader_patch_manager.sub_item_table_func() >= 5)

instance:_startSync(true)
assert(wrapped == 1, "synchronization should run inside Trapper")
assert(instance._sync_running == true, "sync should remain active until its completion callback")
scheduled()
assert(instance._sync_running == false, "cancelled synchronization should release its running state")

print("PASS main menu")

local original_patch_dir = instance.patch_dir
local original_rename = os.rename
local UIManager = package.loaded["ui/uimanager"]
local original_restart = UIManager.askForRestart
local original_sync = instance.syncNow
local root = os.tmpname()
assert(os.remove(root))
assert(os.execute(string.format("mkdir %q", root)))
instance.patch_dir = root
local entry = { path = "2-example.lua", sha = "abc123", size = 12 }
local second = { path = "2-second.lua", sha = "def456", size = 12 }
local content = "return true\n"

local function writePatch(item)
    local file = assert(io.open(root .. "/" .. item.path, "wb"))
    assert(file:write(content))
    assert(file:close())
end
local function readPatch(path)
    local file = assert(io.open(path, "rb"))
    local data = file:read("*a")
    file:close()
    return data
end
local function missing(path)
    local file = io.open(path, "rb")
    if file then file:close(); return false end
    return true
end
local function resetPrompts()
    shown, restarts = {}, {}
end
local passed, failed = 0, 0
local function test(name, callback)
    resetPrompts()
    local ok, err = pcall(callback)
    -- Restore mocked APIs even when an assertion fails.
    os.rename = original_rename
    UIManager.askForRestart = original_restart
    instance.syncNow = original_sync
    if ok then
        passed = passed + 1
        print("PASS " .. name)
    else
        failed = failed + 1
        print("FAIL " .. name .. ": " .. tostring(err))
    end
end

writePatch(entry)
writePatch(second)
instance.settings.catalog = { entry, second }
local items = instance:_catalogMenu()

test("disabling a patch updates the file and requests restart without crashing", function()
    assert(items[1].checked_func() and items[1].mandatory_func() == "Enabled")
    items[1].callback()
    assert(missing(root .. "/" .. entry.path))
    assert(readPatch(root .. "/" .. entry.path .. ".disabled") == content)
    assert(not items[1].checked_func() and items[1].mandatory_func() == "Disabled")
    assert(#restarts == 1 and #shown == 0)
end)

test("enabling a patch updates the file and requests restart without crashing", function()
    assert(not items[1].checked_func())
    items[1].callback()
    assert(readPatch(root .. "/" .. entry.path) == content)
    assert(missing(root .. "/" .. entry.path .. ".disabled"))
    assert(items[1].checked_func() and items[1].mandatory_func() == "Enabled")
    assert(#restarts == 1 and #shown == 0)
end)

test("rename failure shows an error without changing the patch or requesting restart", function()
    os.rename = function() return nil, "permission denied" end
    items[1].callback()
    assert(readPatch(root .. "/" .. entry.path) == content)
    assert(missing(root .. "/" .. entry.path .. ".disabled"))
    assert(#restarts == 0 and #shown == 1)
    assert(shown[1].text:find("Could not change patch state: permission denied", 1, true))
end)

test("patch details work for each menu entry without calling the loop index", function()
    items[1].hold_callback()
    items[2].hold_callback()
    assert(#shown == 2 and #restarts == 0)
    assert(shown[1].text:find(entry.path, 1, true) and shown[1].text:find(entry.sha, 1, true))
    assert(shown[2].text:find(second.path, 1, true) and shown[2].text:find(second.sha, 1, true))
    assert(shown[1].text:find("Status: Enabled", 1, true))
end)

test("KOReader without a restart prompt receives an informational message", function()
    UIManager.askForRestart = nil
    items[2].callback()
    assert(readPatch(root .. "/" .. second.path .. ".disabled") == content)
    assert(#restarts == 0 and #shown == 1)
    assert(shown[1].text:find("Restart KOReader to apply the changes.", 1, true))
end)

test("an uninstalled catalogue entry still requests installation", function()
    local requested
    instance.syncNow = function(_, names) requested = names end
    instance:_togglePatch({ path = "2-not-installed.lua" })
    assert(requested["2-not-installed.lua"] == true)
    assert(#restarts == 0 and #shown == 0)
end)

for _, item in ipairs({ entry, second }) do
    os.remove(root .. "/" .. item.path)
    os.remove(root .. "/" .. item.path .. ".disabled")
end
assert(os.remove(root))
instance.patch_dir = original_patch_dir
print(string.format("%d patch-menu tests passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
