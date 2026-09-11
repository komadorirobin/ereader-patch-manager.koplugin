local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local rapidjson = require("rapidjson")
local _ = require("gettext")

local Core = require("patchsync_core")
local Service = require("patchsync_service")

local SETTINGS_KEY = "ereader_patch_manager"

local EreaderPatchManager = WidgetContainer:extend{
    name = "ereaderpatchmanager",
    is_doc_only = false,
}

local function copyDefaults(settings)
    settings = type(settings) == "table" and settings or {}
    if settings.auto_sync == nil then settings.auto_sync = true end
    if settings.auto_install_new == nil then settings.auto_install_new = true end
    if type(settings.shas) ~= "table" then settings.shas = {} end
    if type(settings.catalog) ~= "table" then settings.catalog = {} end
    return settings
end

local function ensureDir(path)
    if lfs.attributes(path, "mode") == "directory" then return true end
    local ok, err = lfs.mkdir(path)
    if ok or lfs.attributes(path, "mode") == "directory" then return true end
    return nil, err
end

local function httpGet(url)
    local ok_require, http, ltn12, socket, socketutil = pcall(function()
        return require("socket/http"), require("ltn12"), require("socket"), require("socketutil")
    end)
    if not ok_require then return nil, "network modules unavailable" end

    local chunks = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local ok_request, code, headers, status = pcall(function()
        return socket.skip(1, http.request({
            url = url,
            method = "GET",
            headers = {
                ["User-Agent"] = "KOReader-Ereader-Patch-Manager/1.0",
                ["Accept"] = "application/vnd.github+json",
            },
            sink = ltn12.sink.table(chunks),
            redirect = true,
        }))
    end)
    pcall(function() socketutil:reset_timeout() end)

    if not ok_request then return nil, tostring(code) end
    if headers == nil then return nil, "network error (" .. tostring(code or status) .. ")" end
    if code ~= 200 then return nil, "HTTP " .. tostring(code) end
    return table.concat(chunks)
end

function EreaderPatchManager:init()
    self.settings = copyDefaults(G_reader_settings:readSetting(SETTINGS_KEY))
    self.patch_dir = DataStorage:getPatchesDir()
    self.state_dir = DataStorage:getSettingsDir() .. "/ereader-patch-manager"
    self.backup_dir = self.state_dir .. "/backups"
    self._sync_running = false

    ensureDir(self.patch_dir)
    ensureDir(self.state_dir)
    ensureDir(self.backup_dir)
    self.ui.menu:registerToMainMenu(self)

    UIManager:scheduleIn(8, function()
        if not self.settings.auto_sync or self._sync_running then return end
        local ok, online = pcall(function()
            return (NetworkMgr.isOnline and NetworkMgr:isOnline())
                or (NetworkMgr.isConnected and NetworkMgr:isConnected())
        end)
        if ok and online then self:_startSync(false) end
    end)
end

function EreaderPatchManager:saveSettings()
    G_reader_settings:saveSetting(SETTINGS_KEY, self.settings)
    G_reader_settings:flush()
end

function EreaderPatchManager:_notify(text, timeout)
    UIManager:show(Notification:new{ text = text, timeout = timeout or 4 })
end

function EreaderPatchManager:_showInfo(text)
    UIManager:show(InfoMessage:new{ text = text })
end

function EreaderPatchManager:_requestRestart(text)
    if UIManager.askForRestart then
        UIManager:askForRestart(text)
    else
        self:_showInfo(text .. "\n\n" .. _("Restart KOReader to apply the changes."))
    end
end

function EreaderPatchManager:_handleSyncResult(result, manual)
    self._sync_running = false
    if type(result) ~= "table" or not result.ok then
        local message = _("Patch synchronization failed: ") .. tostring(result and result.error or "unknown error")
        logger.warn("ereader patch manager:", message)
        if manual then self:_showInfo(message) else self:_notify(message, 6) end
        return
    end

    self.settings.catalog = result.catalog or {}
    self.settings.shas = result.shas or self.settings.shas
    self.settings.tree_sha = result.tree_sha
    self.settings.last_sync = os.time()
    self.settings.last_errors = result.errors
    self:saveSettings()

    local changed = (result.installed or 0) + (result.updated or 0)
    local summary = string.format(
        _("Patches synchronized. Installed: %d, updated: %d, unchanged: %d."),
        result.installed or 0, result.updated or 0, result.unchanged or 0)

    if #(result.errors or {}) > 0 then
        summary = summary .. "\n\n" .. _("Errors:") .. "\n" .. table.concat(result.errors, "\n")
        self:_showInfo(summary)
    elseif changed > 0 then
        self:_requestRestart(summary .. "\n\n" .. _("Restart KOReader to load the changed patches."))
    elseif manual then
        if (result.available or 0) > 0 then
            summary = summary .. "\n" .. string.format(
                _("Available but not installed: %d."), result.available)
        end
        self:_showInfo(summary)
    end
end

function EreaderPatchManager:_startSync(manual, force_names)
    if self._sync_running then
        if manual then self:_notify(_("Patch synchronization is already running.")) end
        return
    end

    local patch_ok, patch_err = ensureDir(self.patch_dir)
    local state_ok, state_err = ensureDir(self.state_dir)
    local backup_ok, backup_err = ensureDir(self.backup_dir)
    if not patch_ok or not state_ok or not backup_ok then
        self:_handleSyncResult({
            ok = false,
            error = patch_err or state_err or backup_err or "could not create storage directories",
        }, manual)
        return
    end

    self._sync_running = true
    local options = {
        http_get = httpGet,
        decode = rapidjson.decode,
        patch_dir = self.patch_dir,
        backup_dir = self.backup_dir,
        known_shas = self.settings.shas,
        auto_install_new = self.settings.auto_install_new,
        force_names = force_names,
    }
    local function worker()
        local ok, result = pcall(Service.sync, options)
        if ok then return result end
        return { ok = false, error = tostring(result) }
    end

    local trap = manual and _("Synchronizing Ereader patches…") or false
    local completed, result = Trapper:dismissableRunInSubprocess(worker, trap)
    if not completed then
        self._sync_running = false
        if manual then self:_notify(_("Patch synchronization cancelled.")) end
        return
    end
    self:_handleSyncResult(result, manual)
end

function EreaderPatchManager:syncNow(force_names)
    NetworkMgr:runWhenOnline(function() self:_startSync(true, force_names) end)
end

function EreaderPatchManager:_patchStatus(entry)
    local target, enabled_or_err = Core.locatePatch(self.patch_dir, entry.path)
    if target then return enabled_or_err and _("Enabled") or _("Disabled"), target, enabled_or_err end
    if type(enabled_or_err) == "string" then return _("Conflict"), nil, nil end
    return _("Available"), nil, nil
end

function EreaderPatchManager:_togglePatch(entry)
    local _, target, enabled = self:_patchStatus(entry)
    if not target then
        self:syncNow({ [entry.path] = true })
        return
    end

    local destination = enabled and (target .. ".disabled") or target:gsub("%.disabled$", "")
    local ok, err = os.rename(target, destination)
    if not ok then
        self:_showInfo(_("Could not change patch state: ") .. tostring(err))
        return
    end
    self:_requestRestart(_("Patch state changed. Restart KOReader to apply it."))
end

function EreaderPatchManager:_catalogMenu()
    local items = {}
    for _, catalog_entry in ipairs(self.settings.catalog or {}) do
        local entry = catalog_entry
        items[#items + 1] = {
            text = entry.path,
            checked_func = function()
                local _, target, enabled = self:_patchStatus(entry)
                return target ~= nil and enabled == true
            end,
            mandatory_func = function()
                local status = self:_patchStatus(entry)
                return status
            end,
            callback = function() self:_togglePatch(entry) end,
            hold_callback = function()
                local status = self:_patchStatus(entry)
                self:_showInfo(string.format(
                    "%s\n\n%s: %s\nSHA: %s\n%s: %s",
                    entry.path, _("Status"), status, tostring(entry.sha or "-"),
                    _("Size"), entry.size and (tostring(entry.size) .. " bytes") or "-"))
            end,
        }
    end
    if #items == 0 then
        items[1] = {
            text = _("No repository catalogue has been downloaded yet."),
            enabled = false,
        }
    end
    return items
end

function EreaderPatchManager:addToMainMenu(menu_items)
    menu_items.ereader_patch_manager = {
        text = _("Ereader Patch Manager"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return {
                {
                    text = _("Synchronize patches now"),
                    enabled_func = function() return not self._sync_running end,
                    callback = function() self:syncNow() end,
                },
                {
                    text = _("Automatic synchronization on startup"),
                    checked_func = function() return self.settings.auto_sync end,
                    callback = function()
                        self.settings.auto_sync = not self.settings.auto_sync
                        self:saveSettings()
                    end,
                },
                {
                    text = _("Install newly added patches automatically"),
                    checked_func = function() return self.settings.auto_install_new end,
                    callback = function()
                        self.settings.auto_install_new = not self.settings.auto_install_new
                        self:saveSettings()
                    end,
                    separator = true,
                },
                {
                    text_func = function()
                        return string.format(_("Repository patches (%d)"), #(self.settings.catalog or {}))
                    end,
                    sub_item_table_func = function() return self:_catalogMenu() end,
                },
                {
                    text_func = function()
                        if not self.settings.last_sync then return _("Last synchronization: never") end
                        return _("Last synchronization: ") .. os.date("%Y-%m-%d %H:%M", self.settings.last_sync)
                    end,
                    enabled = false,
                    separator = true,
                },
                {
                    text = _("About Ereader Patch Manager"),
                    keep_menu_open = true,
                    callback = function()
                        self:_showInfo(_([[Downloads root-level KOReader patches from komadorirobin/Ereader.

New patches are discovered from their numbered .lua filenames. Existing enabled or disabled patches are updated in place. Replaced files are backed up under the KOReader settings directory.

Patch changes take effect after KOReader restarts. Files not supplied by the Ereader repository are never modified or removed.]]))
                    end,
                },
            }
        end,
    }
end

return EreaderPatchManager

