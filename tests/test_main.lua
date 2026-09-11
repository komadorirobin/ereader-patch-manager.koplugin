package.path = "./?.lua;" .. package.path

local scheduled
local registered
local settings = {}

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
package.loaded["ui/trapper"] = { dismissableRunInSubprocess = function() return false end }
package.loaded["ui/uimanager"] = {
    scheduleIn = function(_, _, callback) scheduled = callback end,
    show = function() end,
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

print("PASS main menu")
