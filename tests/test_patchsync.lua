package.path = "./?.lua;" .. package.path

local Core = require("patchsync_core")
local Service = require("patchsync_service")

local passed = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error(name .. ": " .. tostring(err), 0) end
    passed = passed + 1
end

local function tempDir(suffix)
    local path = os.tmpname() .. "-patchsync-" .. suffix
    os.remove(path)
    assert(os.execute(string.format("mkdir -p %q/patches %q/backups", path, path)))
    return path
end

local function write(path, content)
    local file = assert(io.open(path, "wb"))
    assert(file:write(content))
    file:close()
end

local function read(path)
    local file = assert(io.open(path, "rb"))
    local content = file:read("*a")
    file:close()
    return content
end

local function decoderWith(entries)
    return function()
        return { sha = "tree123", truncated = false, tree = entries }
    end
end

local function httpWith(content)
    return function(url)
        if url:sub(1, #Service.TREE_URL) == Service.TREE_URL then return "tree" end
        local filename = url:match("/([^/?]+)%?") or url:match("/([^/?]+)$")
        return content[filename]
    end
end

test("tree parsing filters non-patches and nested files", function()
    local parsed = assert(Core.parseTree("tree", decoderWith({
        { type = "blob", path = "2-good.lua", sha = "a1", size = 10 },
        { type = "blob", path = "README.md", sha = "b2", size = 10 },
        { type = "blob", path = "nested/2-hidden.lua", sha = "c3", size = 10 },
        { type = "tree", path = "2-directory.lua", sha = "d4" },
    })))
    assert(#parsed.patches == 1)
    assert(parsed.patches[1].path == "2-good.lua")
end)

test("manual verification repairs a stale file despite a matching saved SHA", function()
    local root = tempDir("verify")
    local stale = "return 'stale'\n"
    local current = "return 'current'\n"
    write(root .. "/patches/2-example.lua", stale)
    local result = Service.sync({
        http_get = httpWith({ ["2-example.lua"] = current }),
        decode = decoderWith({
            { type = "blob", path = "2-example.lua", sha = "beef", size = #current },
        }),
        patch_dir = root .. "/patches",
        backup_dir = root .. "/backups",
        known_shas = { ["2-example.lua"] = "beef" },
        auto_install_new = true,
        verify_existing = true,
    })
    assert(result.ok and result.updated == 1)
    assert(read(root .. "/patches/2-example.lua") == current)
end)

test("requests include cache identities", function()
    local root = tempDir("cache")
    local body = "return true\n"
    local urls = {}
    local result = Service.sync({
        http_get = function(url)
            urls[#urls + 1] = url
            if url:sub(1, #Service.TREE_URL) == Service.TREE_URL then return "tree" end
            return body
        end,
        decode = decoderWith({
            { type = "blob", path = "2-example.lua", sha = "cafe", size = #body },
        }),
        patch_dir = root .. "/patches",
        backup_dir = root .. "/backups",
        known_shas = {},
        auto_install_new = true,
        cache_buster = "test-123",
    })
    assert(result.ok and result.installed == 1)
    assert(urls[1]:find("patchsync=test%-123"))
    assert(urls[2]:find("blob=cafe"))
end)

test("existing enabled patch is updated and backed up", function()
    local root = tempDir("update")
    local old = "return 'old'\n"
    local new = "return 'new'\n"
    write(root .. "/patches/2-example.lua", old)
    local result = Service.sync({
        http_get = httpWith({ ["2-example.lua"] = new }),
        decode = decoderWith({
            { type = "blob", path = "2-example.lua", sha = "beef", size = #new },
        }),
        patch_dir = root .. "/patches",
        backup_dir = root .. "/backups",
        known_shas = { ["2-example.lua"] = "oldsha" },
        auto_install_new = true,
    })
    assert(result.ok and result.updated == 1)
    assert(read(root .. "/patches/2-example.lua") == new)
    assert(read(root .. "/backups/2-example.lua.bak") == old)
end)

test("disabled patch stays disabled when updated", function()
    local root = tempDir("disabled")
    local new = "return 2\n"
    write(root .. "/patches/2-example.lua.disabled", "return 1\n")
    local result = Service.sync({
        http_get = httpWith({ ["2-example.lua"] = new }),
        decode = decoderWith({
            { type = "blob", path = "2-example.lua", sha = "cafe", size = #new },
        }),
        patch_dir = root .. "/patches",
        backup_dir = root .. "/backups",
        known_shas = {},
        auto_install_new = true,
    })
    assert(result.updated == 1)
    assert(Core.fileExists(root .. "/patches/2-example.lua.disabled"))
    assert(not Core.fileExists(root .. "/patches/2-example.lua"))
end)

test("new patch can remain available or be explicitly installed", function()
    local root = tempDir("available")
    local body = "return true\n"
    local entry = { type = "blob", path = "2-new.lua", sha = "fade", size = #body }
    local common = {
        http_get = httpWith({ ["2-new.lua"] = body }),
        decode = decoderWith({ entry }),
        patch_dir = root .. "/patches",
        backup_dir = root .. "/backups",
        known_shas = {},
        auto_install_new = false,
    }
    local available = Service.sync(common)
    assert(available.available == 1)
    assert(not Core.fileExists(root .. "/patches/2-new.lua"))
    common.force_names = { ["2-new.lua"] = true }
    local installed = Service.sync(common)
    assert(installed.installed == 1)
    assert(Core.fileExists(root .. "/patches/2-new.lua"))
end)

test("invalid Lua never replaces the installed patch", function()
    local root = tempDir("invalid")
    local old = "return true\n"
    local broken = "return function(\n"
    write(root .. "/patches/2-example.lua", old)
    local result = Service.sync({
        http_get = httpWith({ ["2-example.lua"] = broken }),
        decode = decoderWith({
            { type = "blob", path = "2-example.lua", sha = "dead", size = #broken },
        }),
        patch_dir = root .. "/patches",
        backup_dir = root .. "/backups",
        known_shas = { ["2-example.lua"] = "oldsha" },
        auto_install_new = true,
    })
    assert(#result.errors == 1)
    assert(read(root .. "/patches/2-example.lua") == old)
end)

print(string.format("PASS %d", passed))
