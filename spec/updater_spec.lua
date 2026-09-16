package.path = "./readeck.koplugin/?.lua;" .. package.path

-- Stubs for KOReader / platform modules used lazily by the updater.
local stub_downloads = {}
local function stub_serve(url)
    -- Exact-key lookup only: URLs are prefixes of one another (the checksum
    -- URL contains the archive URL), so substring matching would misroute.
    return stub_downloads[url]
end

package.preload["logger"] = function()
    return {
        info = function() end,
        warn = function() end,
        err = function() end,
        dbg = function() end,
    }
end
package.preload["datastorage"] = function()
    return {
        getSettingsDir = function()
            return "/tmp/readeck-updater-spec/settings"
        end,
    }
end
package.preload["ffi/sha2"] = function()
    -- Deterministic fake digest: test checksums are computed with it.
    return {
        sha256 = function(data)
            return string.format("%064x", #data)
        end,
    }
end
package.preload["socketutil"] = function()
    return {
        FILE_BLOCK_TIMEOUT = 30,
        FILE_TOTAL_TIMEOUT = 30,
        LARGE_BLOCK_TIMEOUT = 30,
        LARGE_TOTAL_TIMEOUT = 30,
        set_timeout = function() end,
        reset_timeout = function() end,
    }
end
package.preload["ltn12"] = function()
    return {
        sink = {
            table = function(chunks)
                return function(chunk)
                    if chunk then
                        chunks[#chunks + 1] = chunk
                    end
                    return true
                end
            end,
            file = function(file)
                return function(chunk, err)
                    if chunk then
                        file:write(chunk)
                        return true
                    end
                    file:close()
                    if err then
                        return nil, err
                    end
                    return true
                end
            end,
        },
    }
end
package.preload["socket"] = function()
    return {
        skip = function(discard, ...)
            return select(discard + 1, ...)
        end,
    }
end
package.preload["socket/http"] = function()
    return {
        request = function(options)
            local response = stub_serve(options.url)
            if response == nil then
                return 1, nil, "no stub response"
            end
            if type(response) == "string" then
                response = { body = response }
            end
            if response.fail then
                return 1, 500, {}, "stub failure"
            end
            local sink = options.sink
            if sink then
                sink(response.body, nil)
                sink(nil, nil)
            end
            return 1, 200, { ["content-length"] = #(response.body or "") }, "HTTP/1.1 200 OK"
        end,
    }
end
package.preload["json"] = function()
    local payloads = {}
    return {
        decode = function(body)
            for pattern, payload in pairs(payloads) do
                if body:find(pattern, 1, true) then
                    return payload
                end
            end
            error("unexpected JSON body")
        end,
        -- Test hook: register an API payload for a body substring.
        __register = function(marker, payload)
            payloads[marker] = payload
        end,
    }
end
package.preload["ffi/archiver"] = function()
    return {
        Reader = {
            new = function()
                local archive_entries
                return {
                    open = function(self, archive)
                        local handle = io.open(archive, "rb")
                        if not handle then
                            self.err = "missing archive"
                            return false
                        end
                        local marker = handle:read("*a")
                        handle:close()
                        archive_entries = stub_serve(marker) or {}
                        return true
                    end,
                    iterate = function()
                        local index = 0
                        return function()
                            index = index + 1
                            return archive_entries[index]
                        end
                    end,
                    extractToPath = function(_, path, target)
                        local marker
                        for _, entry in ipairs(archive_entries or {}) do
                            if entry.path == path then
                                marker = entry.content_marker
                                break
                            end
                        end
                        if target:sub(-1) == "/" then
                            os.execute('mkdir -p "' .. target:sub(1, -2) .. '"')
                            return true
                        end
                        local directory = target:match("^(.*)/[^/]+$")
                        os.execute('mkdir -p "' .. directory .. '"')
                        local payload = marker and stub_serve(marker) or ""
                        local handle = io.open(target, "wb")
                        if not handle then
                            return false
                        end
                        handle:write(payload)
                        handle:close()
                        return true
                    end,
                    close = function() end,
                }
            end,
        },
    }
end
package.preload["ffi/util"] = function()
    return {
        purgeDir = function(path)
            os.execute('rm -rf "' .. path .. '"')
            return true
        end,
    }
end
package.preload["util"] = function()
    return {
        makePath = function(path)
            os.execute('mkdir -p "' .. path .. '"')
            return true
        end,
    }
end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, _)
            local ok, what = pcall(function()
                return io.open(path)
            end)
            if ok and what then
                what:close()
                return "file"
            end
            return nil
        end,
        mkdir = function(path)
            os.execute('mkdir -p "' .. path .. '"')
            return true
        end,
    }
end

-- Load the real updater even when another spec file left a fake in the
-- package cache.
package.preload["readeck.core.updater"] = nil
for name in pairs(package.loaded) do
    if name == "readeck" or name:match("^readeck%.") then
        package.loaded[name] = nil
    end
end
local Updater = require("readeck.core.updater")

local function make_updater(overrides)
    local options = {
        current_version = "1.2.3",
        plugin_dir = "/tmp/readeck-updater-spec/plugins/readeck.koplugin",
        settings_dir = "/tmp/readeck-updater-spec/settings",
    }
    for key, value in pairs(overrides or {}) do
        options[key] = value
    end
    return Updater:new(options)
end

local function reset_workspace()
    os.execute("rm -rf /tmp/readeck-updater-spec")
    os.execute('mkdir -p "/tmp/readeck-updater-spec/plugins/readeck.koplugin"')
    os.execute('mkdir -p "/tmp/readeck-updater-spec/settings"')
    for key in pairs(stub_downloads) do
        stub_downloads[key] = nil
    end
end

local function write_workspace_file(path, content)
    local handle = io.open(path, "wb")
    assert(handle, "cannot write " .. path)
    handle:write(content)
    handle:close()
end

local function valid_release_payload(version)
    local zip_name = "readeck.koplugin-v" .. version .. ".zip"
    return {
        tag_name = "v" .. version,
        draft = false,
        prerelease = false,
        html_url = "https://github.com/likidu/readeck.koplugin/releases/tag/v" .. version,
        body = "## Release notes\n**Fixes** things",
        assets = {
            {
                name = zip_name,
                browser_download_url = Updater.RELEASE_PREFIX .. "v" .. version .. "/" .. zip_name,
                size = 2048,
            },
            {
                name = zip_name .. ".sha256",
                browser_download_url = Updater.RELEASE_PREFIX .. "v" .. version .. "/" .. zip_name .. ".sha256",
                size = 96,
            },
        },
    }
end

describe("readeck.core.updater", function()
    it("compares dotted versions and rejects malformed ones", function()
        assert.is_true(Updater.compare_versions("1.2.4", "1.2.3") == 1)
        assert.is_true(Updater.compare_versions("v1.2.3", "1.2.3") == 0)
        assert.is_true(Updater.compare_versions("1.2.2", "1.2.3") == -1)
        assert.is_true(Updater.compare_versions("1.10.0", "1.9.9") == 1)
        assert.is_nil(Updater.compare_versions("invalid", "1.2.3"))
        assert.is_nil(Updater.compare_versions("1.2.3-beta", "1.2.3"))
    end)

    it("tries direct download first and mirrors after", function()
        local direct_first = Updater.candidate_urls(Updater.API_URL, false)
        assert.are.equal(1 + #Updater.GITHUB_MIRRORS, #direct_first)
        assert.are.equal(Updater.API_URL, direct_first[1])
        assert.is_true(direct_first[2]:find("gh%-proxy%.com/") ~= nil)
        local mirror_first = Updater.candidate_urls(Updater.API_URL, true)
        assert.are.equal(Updater.API_URL, mirror_first[#mirror_first])
        assert.are.equal(0, #Updater.candidate_urls("https://example.com/update.zip", false))
    end)

    it("parses a valid latest release and extracts asset URLs", function()
        local release = Updater.parse_release(valid_release_payload("1.2.4"))
        assert.is.truthy(release)
        assert.are.equal("1.2.4", release.version)
        assert.are.equal(2048, release.archive_size)
        assert.is_true(release.archive_url:find("readeck%.koplugin%-v1%.2%.4%.zip$", -0) ~= nil)
        assert.is_true(release.checksum_url:find("%.sha256$") ~= nil)
        assert.are.equal("Release notes\nFixes things", release.notes)
    end)

    it("rejects draft, prerelease, bad tags, and missing checksums", function()
        assert.is_nil(Updater.parse_release({ draft = true }))
        local prerelease = valid_release_payload("1.2.4")
        prerelease.prerelease = true
        assert.is_nil(Updater.parse_release(prerelease))
        local bad_tag = valid_release_payload("1.2.4")
        bad_tag.tag_name = "latest"
        assert.is_nil(select(1, Updater.parse_release(bad_tag)))
        local no_checksum = valid_release_payload("1.2.4")
        no_checksum.assets = { no_checksum.assets[1] }
        local ok, err = Updater.parse_release(no_checksum)
        assert.is_nil(ok)
        assert.are.equal("release package or checksum is missing", err)
    end)

    it("fetches the latest release through the GitHub API", function()
        reset_workspace()
        local payload = valid_release_payload("1.2.4")
        package.preload["json"]()
        local json = require("json")
        json.__register("likidu/readeck.koplugin/releases/latest", payload)
        stub_downloads[Updater.API_URL] = '{"marker": "likidu/readeck.koplugin/releases/latest"}'
        local release, err = make_updater():fetch_release()
        assert.is_nil(err)
        assert.are.equal("1.2.4", release.version)
    end)

    it("downloads, verifies, and activates an update with rollback backup", function()
        reset_workspace()
        local plugin_dir = "/tmp/readeck-updater-spec/plugins/readeck.koplugin"
        write_workspace_file(plugin_dir .. "/_meta.lua", 'version = "1.2.3"\n')
        write_workspace_file(plugin_dir .. "/main.lua", "-- old main\n")

        local payload = Updater.parse_release(valid_release_payload("1.2.4"))
        local archive_marker = payload.archive_url
        local checksum_marker = payload.checksum_url
        stub_downloads[archive_marker] = "zipbytes-v1.2.4"
        -- Fake sha256 of the archive body, matching the stubbed ffi/sha2.
        stub_downloads[checksum_marker] = string.format("%064x", #"zipbytes-v1.2.4")
            .. "  readeck.koplugin-v1.2.4.zip\n"
        -- The archiver stub keys the staged tree off the archive bytes and
        -- maps each entry's content through stub_downloads markers.
        stub_downloads["zipbytes-v1.2.4"] = {
            { path = "readeck.koplugin/", content_marker = "dir" },
            { path = "readeck.koplugin/_meta.lua", content_marker = "new-meta" },
            { path = "readeck.koplugin/main.lua", content_marker = "new-main" },
        }
        stub_downloads["new-meta"] = 'name = "readeck"\nversion = "1.2.4"\n'
        stub_downloads["new-main"] = "-- new main\n"

        local stages = {}
        local ok, err = make_updater():install_release(payload, function(event)
            stages[#stages + 1] = event.stage
        end)
        assert.is_true(ok)
        assert.is_nil(err)
        local milestones = {}
        for _, stage in ipairs(stages) do
            if milestones[#milestones] ~= stage then
                milestones[#milestones + 1] = stage
            end
        end
        assert.are.same(
            { "preparing", "downloading", "checksum", "verifying", "extracting", "installing", "complete" },
            milestones
        )
        local meta = io.open(plugin_dir .. "/_meta.lua", "rb")
        assert.is.truthy(meta, "activated plugin _meta.lua is missing")
        assert.are.equal('name = "readeck"\nversion = "1.2.4"\n', meta:read("*a"))
        meta:close()
        local backup = io.open(plugin_dir .. ".backup/_meta.lua", "rb")
        assert.is.truthy(backup, "rollback backup is missing")
        assert.are.equal('version = "1.2.3"\n', backup:read("*a"))
        backup:close()
        assert.is_nil(
            os.rename(
                "/tmp/readeck-updater-spec/settings/readeck-update-stage",
                "/tmp/readeck-updater-spec/settings/leftover"
            ),
            "staging directory was not cleaned up"
        )
    end)

    it("refuses to install when the SHA-256 checksum does not match", function()
        reset_workspace()
        local payload = Updater.parse_release(valid_release_payload("1.2.4"))
        stub_downloads[payload.archive_url] = "zipbytes-v1.2.4"
        stub_downloads[payload.checksum_url] = string.format("%064x", 999999) .. "  readeck.koplugin-v1.2.4.zip\n"

        local ok, err = make_updater():install_release(payload)
        assert.is_nil(ok)
        assert.are.equal("SHA-256 verification failed", err)
        assert.is_nil(
            os.rename(
                "/tmp/readeck-updater-spec/settings/readeck-update-stage",
                "/tmp/readeck-updater-spec/settings/leftover"
            ),
            "staging directory survived a failed install"
        )
    end)

    it("refuses to install a staged package with a mismatched version", function()
        reset_workspace()
        local payload = Updater.parse_release(valid_release_payload("1.2.4"))
        local archive_marker = payload.archive_url
        stub_downloads[archive_marker] = "zipbytes-v1.2.4"
        stub_downloads[payload.checksum_url] = string.format("%064x", #"zipbytes-v1.2.4")
            .. "  readeck.koplugin-v1.2.4.zip\n"
        stub_downloads["zipbytes-v1.2.4"] = {
            { path = "readeck.koplugin/", content_marker = "dir" },
            { path = "readeck.koplugin/_meta.lua", content_marker = "new-meta" },
            { path = "readeck.koplugin/main.lua", content_marker = "new-main" },
        }
        -- Staged version does not match the release version.
        stub_downloads["new-meta"] = 'version = "9.9.9"\n'
        stub_downloads["new-main"] = "-- new main\n"

        local ok, err = make_updater():install_release(payload)
        assert.is_nil(ok)
        assert.are.equal("release package structure or version is invalid", err)
    end)

    it("cleans up a leftover backup directory", function()
        reset_workspace()
        local backup = "/tmp/readeck-updater-spec/plugins/readeck.koplugin.backup"
        os.execute('mkdir -p "' .. backup .. '"')
        assert.is_true(make_updater():cleanup_backup())
        -- Directory existence is asserted via the lfs stub below.
        local lfs = require("libs/libkoreader-lfs")
        assert.is_nil(lfs.attributes(backup, "mode"), "backup directory was not removed")
    end)

    after_each(function()
        reset_workspace()
    end)
end)
