local Core = {}

local MAX_PATCH_SIZE = 1024 * 1024
local PATCH_PATTERN = "^%d+%-%w[%w%._%-]*%.lua$"

local function readFile(path)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    local content = file:read("*a")
    file:close()
    return content
end

local function writeFile(path, content)
    local file, err = io.open(path, "wb")
    if not file then return nil, err end
    local ok, write_err = file:write(content)
    if ok then ok, write_err = file:flush() end
    file:close()
    if not ok then return nil, write_err end
    return true
end

function Core.fileExists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

function Core.parseTree(body, decode)
    if type(body) ~= "string" or body == "" then
        return nil, "empty repository response"
    end
    if type(decode) ~= "function" then
        return nil, "JSON decoder unavailable"
    end

    local ok, data = pcall(decode, body)
    if not ok or type(data) ~= "table" then
        return nil, "invalid repository response"
    end
    if data.truncated then
        return nil, "repository response was truncated"
    end

    local patches = {}
    for _, entry in ipairs(data.tree or {}) do
        local is_entry = type(entry) == "table"
        local path = is_entry and entry.path or nil
        if is_entry
                and entry.type == "blob"
                and type(path) == "string"
                and not path:find("/", 1, true)
                and path:match(PATCH_PATTERN)
                and type(entry.sha) == "string"
                and entry.sha:match("^[0-9a-fA-F]+$") then
            patches[#patches + 1] = {
                path = path,
                sha = entry.sha:lower(),
                size = tonumber(entry.size),
            }
        end
    end
    table.sort(patches, function(a, b) return a.path < b.path end)

    return {
        sha = type(data.sha) == "string" and data.sha or nil,
        patches = patches,
    }
end

function Core.locatePatch(patch_dir, filename)
    local enabled = patch_dir .. "/" .. filename
    local disabled = enabled .. ".disabled"
    local has_enabled = Core.fileExists(enabled)
    local has_disabled = Core.fileExists(disabled)
    if has_enabled and has_disabled then
        return nil, "both enabled and disabled copies exist"
    end
    if has_enabled then return enabled, true end
    if has_disabled then return disabled, false end
    return nil, nil
end

function Core.validatePatch(entry, content)
    if type(content) ~= "string" or content == "" then
        return nil, "downloaded patch is empty"
    end
    if #content > MAX_PATCH_SIZE then
        return nil, "downloaded patch exceeds 1 MiB"
    end
    if entry.size and entry.size >= 0 and #content ~= entry.size then
        return nil, string.format("size mismatch: expected %d bytes, received %d", entry.size, #content)
    end

    local loader = loadstring or load
    local chunk, err = loader(content, "@" .. entry.path)
    if not chunk then
        return nil, "Lua syntax error: " .. tostring(err)
    end
    return true
end

function Core.readFile(path)
    return readFile(path)
end

function Core.replaceFile(target, content, backup_path)
    local temp_path = target .. ".patchsync.tmp"
    os.remove(temp_path)

    local ok, err = writeFile(temp_path, content)
    if not ok then return nil, "could not write temporary file: " .. tostring(err) end

    if Core.fileExists(target) and backup_path then
        local previous, read_err = readFile(target)
        if not previous then
            os.remove(temp_path)
            return nil, "could not read existing patch: " .. tostring(read_err)
        end
        local backup_ok, backup_err = writeFile(backup_path, previous)
        if not backup_ok then
            os.remove(temp_path)
            return nil, "could not create backup: " .. tostring(backup_err)
        end
    end

    local renamed, rename_err = os.rename(temp_path, target)
    if not renamed then
        os.remove(temp_path)
        return nil, "could not replace patch: " .. tostring(rename_err)
    end
    return true
end

return Core
