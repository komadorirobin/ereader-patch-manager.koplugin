local Core = require("patchsync_core")

local Service = {}

Service.COMMIT_URL = "https://api.github.com/repos/komadorirobin/Ereader/commits/main"
Service.TREE_BASE = "https://api.github.com/repos/komadorirobin/Ereader/git/trees/"
Service.RAW_BASE = "https://raw.githubusercontent.com/komadorirobin/Ereader/"

local function encodePath(value)
    return tostring(value):gsub("[^%w%-._~]", function(char)
        return string.format("%%%02X", char:byte())
    end)
end

local function appendQuery(url, key, value)
    local separator = url:find("?", 1, true) and "&" or "?"
    return url .. separator .. encodePath(key) .. "=" .. encodePath(value)
end

local function copyTable(source)
    local result = {}
    for key, value in pairs(source or {}) do result[key] = value end
    return result
end

local function addError(result, filename, message)
    result.errors[#result.errors + 1] = string.format("%s: %s", filename, tostring(message))
    result.states[filename] = "error"
end

function Service.sync(options)
    options = options or {}
    local http_get = assert(options.http_get, "http_get is required")
    local patch_dir = assert(options.patch_dir, "patch_dir is required")
    local backup_dir = assert(options.backup_dir, "backup_dir is required")

    local cache_buster = options.cache_buster or tostring(os.time())
    local commit_url = appendQuery(Service.COMMIT_URL, "patchsync", cache_buster)
    local commit_body, commit_err = http_get(commit_url)
    if not commit_body then
        return { ok = false, error = commit_err or "could not fetch repository head" }
    end

    local commit_sha, commit_parse_err = Core.parseCommit(commit_body, options.decode)
    if not commit_sha then return { ok = false, error = commit_parse_err } end

    local tree_url = Service.TREE_BASE .. encodePath(commit_sha) .. "?recursive=1"
    tree_url = appendQuery(tree_url, "patchsync", cache_buster)
    local tree_body, tree_err = http_get(tree_url)
    if not tree_body then
        return { ok = false, error = tree_err or "could not fetch repository" }
    end

    local tree, parse_err = Core.parseTree(tree_body, options.decode)
    if not tree then return { ok = false, error = parse_err } end

    local result = {
        ok = true,
        tree_sha = tree.sha,
        catalog = tree.patches,
        shas = copyTable(options.known_shas),
        states = {},
        installed = 0,
        updated = 0,
        unchanged = 0,
        available = 0,
        errors = {},
    }

    for _, entry in ipairs(tree.patches) do
        local target, enabled_or_err = Core.locatePatch(patch_dir, entry.path)
        if target == nil and type(enabled_or_err) == "string" then
            addError(result, entry.path, enabled_or_err)
        else
            local forced = options.force_names and options.force_names[entry.path] == true
            local should_install = target ~= nil or options.auto_install_new or forced

            if not should_install then
                result.available = result.available + 1
                result.states[entry.path] = "available"
            elseif target
                    and result.shas[entry.path] == entry.sha
                    and not forced
                    and not options.verify_existing then
                result.unchanged = result.unchanged + 1
                result.states[entry.path] = enabled_or_err and "enabled" or "disabled"
            else
                -- Use the immutable commit that produced the catalogue. A raw
                -- main URL can briefly serve the previous file after a push.
                local raw_url = Service.RAW_BASE .. encodePath(commit_sha)
                    .. "/" .. encodePath(entry.path)
                raw_url = appendQuery(raw_url, "blob", entry.sha)
                local content, download_err = http_get(raw_url)
                if not content then
                    addError(result, entry.path, download_err or "download failed")
                else
                    local valid, validation_err = Core.validatePatch(entry, content)
                    if not valid then
                        addError(result, entry.path, validation_err)
                    else
                        local current = target and Core.readFile(target) or nil
                        if target and current == content then
                            result.unchanged = result.unchanged + 1
                            result.states[entry.path] = enabled_or_err and "enabled" or "disabled"
                            result.shas[entry.path] = entry.sha
                        else
                            local destination = target or (patch_dir .. "/" .. entry.path)
                            local backup = target and (backup_dir .. "/" .. entry.path .. ".bak") or nil
                            local replaced, replace_err = Core.replaceFile(destination, content, backup)
                            if not replaced then
                                addError(result, entry.path, replace_err)
                            else
                                if target then
                                    result.updated = result.updated + 1
                                else
                                    result.installed = result.installed + 1
                                end
                                result.states[entry.path] = target and
                                    (enabled_or_err and "enabled" or "disabled") or "enabled"
                                result.shas[entry.path] = entry.sha
                            end
                        end
                    end
                end
            end
        end
    end

    return result
end

return Service
