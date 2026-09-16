-- GitHub Release based self-updater for the Readeck plugin.
--
-- Update checks are read-only. Installation only runs after the user has
-- confirmed the release notes, verifies the release SHA-256, stages the
-- archive, and keeps the previous plugin directory as a rollback copy until
-- the next successful plugin initialization removes it.

local DataStorage = require("datastorage")
local Log = require("readeck.core.log")

local Updater = {}
Updater.__index = Updater

Updater.MAX_PACKAGE_BYTES = 10 * 1024 * 1024
Updater.MAX_RELEASE_NOTES_BYTES = 1600
Updater.API_URL = "https://api.github.com/repos/likidu/readeck.koplugin/releases/latest"
Updater.RELEASE_PREFIX = "https://github.com/likidu/readeck.koplugin/releases/download/"
Updater.PLUGIN_DIR_NAME = "readeck.koplugin"
Updater.PLUGIN_DIR_PATTERN = "^readeck%.koplugin/"
Updater.GITHUB_MIRRORS = {
    "https://gh-proxy.com/",
    "https://ghfast.top/",
    "https://ghproxy.net/",
}

local function plugin_dir_from_source()
    local source = debug.getinfo(1, "S").source or ""
    return source:match("^@?(.+)/readeck/core/[^/]+$")
end

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function read_file(path, max_bytes)
    local file, err = io.open(path, "rb")
    if not file then
        return nil, err
    end
    if max_bytes then
        local size, size_err = file:seek("end")
        if not size then
            file:close()
            return nil, size_err or "could not determine file size"
        end
        if size > max_bytes then
            file:close()
            return nil, "file is larger than expected"
        end
        local reset, reset_err = file:seek("set", 0)
        if not reset then
            file:close()
            return nil, reset_err or "could not rewind file"
        end
    end
    local data = file:read("*a")
    file:close()
    if not data then
        return nil, "could not read file"
    end
    return data
end

local function remove_file(path)
    if path then
        pcall(os.remove, path)
    end
end

local function remove_tree(path)
    if not path or path == "" then
        return nil, "invalid directory"
    end
    local ok, ffiutil = pcall(require, "ffi/util")
    if ok and ffiutil and ffiutil.purgeDir then
        local removed, err = pcall(ffiutil.purgeDir, path)
        if removed then
            return true
        end
        return nil, err
    end
    return nil, "directory cleanup unavailable"
end

local function make_path(path)
    local ok, util = pcall(require, "util")
    if ok and util and util.makePath then
        return util.makePath(path)
    end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs then
        return nil, "filesystem support unavailable"
    end
    if lfs.attributes(path, "mode") == "directory" then
        return true
    end
    return lfs.mkdir(path)
end

local function sha256_hex(data)
    local ok, sha2 = pcall(require, "ffi/sha2")
    if not ok or not sha2 or not sha2.sha256 then
        return nil, "SHA-256 support unavailable"
    end
    return sha2.sha256(data)
end

local function unpack_release(archive, stage)
    local Archiver = require("ffi/archiver")
    local reader = Archiver.Reader:new()
    if not reader:open(archive) then
        reader:close()
        return nil, reader.err or "could not open release archive"
    end
    local ok, err = true, nil
    for entry in reader:iterate() do
        local path = entry.path
        local safe = type(path) == "string"
            and path ~= ""
            and path:sub(1, 1) ~= "/"
            and path:find("\\", 1, true) == nil
            and path:match(Updater.PLUGIN_DIR_PATTERN) ~= nil
            and path:match("^%.%./") == nil
            and path:match("/%.%./") == nil
            and path:match("/%.%.$") == nil
        if not safe then
            ok, err = nil, "unsafe path in release archive"
            break
        end
        if not reader:extractToPath(path, stage .. "/" .. path) then
            ok, err = nil, reader.err or "archive extraction failed"
            break
        end
    end
    if reader.err then
        ok, err = nil, reader.err
    end
    reader:close()
    return ok, err
end

local function normalize_notes(notes)
    notes = trim(notes)
    if notes == "" then
        return nil
    end
    notes = notes:gsub("\r\n", "\n"):gsub("\r", "\n")
    notes = notes:gsub("^#+%s*", ""):gsub("\n#+%s*", "\n")
    notes = notes:gsub("%*%*(.-)%*%*", "%1")
    notes = notes:gsub("`(.-)`", "%1")
    if #notes > Updater.MAX_RELEASE_NOTES_BYTES then
        notes = notes:sub(1, Updater.MAX_RELEASE_NOTES_BYTES - 3) .. "..."
    end
    return notes
end

--- Compare two dotted versions. Accepts an optional leading "v".
--- Returns 1 when left is newer, -1 when older, 0 when equal, nil when
--- either side is not a plain X.Y.Z version.
function Updater.compare_versions(left, right)
    local function parts(version)
        local raw = tostring(version or ""):gsub("^v", "")
        if not raw:match("^%d+%.%d+%.%d+$") then
            return nil
        end
        local out = {}
        for number in raw:gmatch("%d+") do
            out[#out + 1] = tonumber(number)
        end
        return out
    end
    local left_parts, right_parts = parts(left), parts(right)
    if not left_parts or not right_parts then
        return nil
    end
    for i = 1, 3 do
        if left_parts[i] > right_parts[i] then
            return 1
        end
        if left_parts[i] < right_parts[i] then
            return -1
        end
    end
    return 0
end

--- Build the ordered list of URLs to try: direct first (or mirror first when
--- prefer_mirror), then the others. Only the update API and this project's
--- release downloads are ever fetched.
function Updater.candidate_urls(url, prefer_mirror)
    local is_allowed = url == Updater.API_URL
        or (type(url) == "string" and url:sub(1, #Updater.RELEASE_PREFIX) == Updater.RELEASE_PREFIX)
    if not is_allowed then
        return {}
    end
    local direct, proxies = { url }, {}
    for _, prefix in ipairs(Updater.GITHUB_MIRRORS) do
        proxies[#proxies + 1] = prefix .. url
    end
    local out = {}
    local first, second = prefer_mirror and proxies or direct, prefer_mirror and direct or proxies
    for _, candidate in ipairs(first) do
        out[#out + 1] = candidate
    end
    for _, candidate in ipairs(second) do
        out[#out + 1] = candidate
    end
    return out
end

--- Extract the installable release description from a GitHub
--- /releases/latest API response, or nil + reason when unusable.
function Updater.parse_release(data)
    if type(data) ~= "table" or data.draft == true or data.prerelease == true then
        return nil, "invalid release metadata"
    end
    local version = type(data.tag_name) == "string" and data.tag_name:match("^v(%d+%.%d+%.%d+)$") or nil
    if not version then
        return nil, "invalid release tag"
    end

    local archive_name = Updater.PLUGIN_DIR_NAME .. "-v" .. version .. ".zip"
    local checksum_name = archive_name .. ".sha256"
    local archive_url, checksum_url, archive_size
    for _, asset in ipairs(data.assets or {}) do
        if asset.name == archive_name then
            archive_url = asset.browser_download_url
            archive_size = tonumber(asset.size)
        elseif asset.name == checksum_name then
            checksum_url = asset.browser_download_url
        end
    end
    local function valid_url(url)
        return type(url) == "string" and url:sub(1, #Updater.RELEASE_PREFIX) == Updater.RELEASE_PREFIX
    end
    if not valid_url(archive_url) or not valid_url(checksum_url) then
        return nil, "release package or checksum is missing"
    end
    if archive_size and archive_size > Updater.MAX_PACKAGE_BYTES then
        return nil, "release package is too large"
    end
    return {
        version = version,
        archive_url = archive_url,
        checksum_url = checksum_url,
        archive_size = archive_size,
        notes = normalize_notes(data.body),
        release_url = data.html_url,
    }
end

function Updater:new(options)
    options = options or {}
    local obj = {
        current_version = assert(options.current_version, "current_version required"),
        plugin_dir = options.plugin_dir or plugin_dir_from_source(),
        settings_dir = options.settings_dir or DataStorage:getSettingsDir(),
    }
    assert(obj.plugin_dir and obj.plugin_dir ~= "", "plugin directory unavailable")
    return setmetatable(obj, self)
end

function Updater:_http_get(url, destination, on_download, total_hint, max_bytes)
    local http = require("socket/http")
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")
    local sink, chunks, file, limit_error
    if destination then
        file = io.open(destination, "wb")
        if not file then
            return nil, "cannot create download file"
        end
        local file_sink = ltn12.sink.file(file)
        local received = 0
        sink = function(chunk, err)
            if chunk then
                if max_bytes and received + #chunk > max_bytes then
                    limit_error = "download exceeds size limit"
                    file_sink(nil, limit_error)
                    return nil, limit_error
                end
                received = received + #chunk
                if on_download then
                    on_download(received, total_hint)
                end
            end
            return file_sink(chunk, err)
        end
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    else
        chunks = {}
        sink = ltn12.sink.table(chunks)
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    end
    local code, headers, status = require("socket").skip(
        1,
        http.request({
            url = url,
            method = "GET",
            headers = {
                ["User-Agent"] = "KOReader-Readeck-Updater/1.0",
                ["Accept"] = "application/vnd.github+json",
            },
            sink = sink,
            redirect = true,
        })
    )
    socketutil:reset_timeout()
    if limit_error then
        remove_file(destination)
        return nil, limit_error
    end
    if headers == nil or code ~= 200 then
        if destination then
            remove_file(destination)
        end
        return nil, "HTTP " .. tostring(code or status or "error")
    end
    return destination and true or table.concat(chunks)
end

function Updater:_http_get_with_mirrors(url, destination, on_download, total_hint, max_bytes)
    local candidates = Updater.candidate_urls(url, false)
    if #candidates == 0 then
        return nil, "update URL is not allowed"
    end
    local last_error
    for index, candidate in ipairs(candidates) do
        if on_download then
            on_download(0, total_hint)
        end
        local ok, err = self:_http_get(candidate, destination, on_download, total_hint, max_bytes)
        if ok then
            Log:info("Update resource fetched", "source=" .. tostring(index), "proxy=" .. tostring(candidate ~= url))
            return ok
        end
        if err == "download exceeds size limit" then
            return nil, err
        end
        last_error = err
        Log:warn("Update resource source failed", "source=" .. tostring(index), "error=" .. tostring(err))
    end
    return nil, last_error or "all update sources failed"
end

--- Fetch and parse the latest release metadata from GitHub.
function Updater:fetch_release()
    local body, err = self:_http_get_with_mirrors(Updater.API_URL)
    if not body then
        return nil, err
    end
    local ok_json, json = pcall(require, "json")
    if not ok_json then
        return nil, "JSON support unavailable"
    end
    local ok, data = pcall(json.decode, body)
    if not ok then
        return nil, "invalid GitHub response"
    end
    return Updater.parse_release(data)
end

-- The backup must survive installation so a failed activation can be rolled
-- back. Reaching the end of the next plugin initialization confirms that the
-- new copy can load, at which point the previous copy is no longer needed.
function Updater:cleanup_backup()
    local backup = self.plugin_dir .. ".backup"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs and not lfs.attributes(backup, "mode") then
        return true
    end
    local removed, err = remove_tree(backup)
    if removed then
        Log:info("Previous update backup removed")
        return true
    end
    Log:warn("Could not remove previous update backup", tostring(err))
    return nil, err
end

--- Download, verify, and activate a parsed release. Returns true on success.
--- on_progress receives { stage, percent } events.
function Updater:install_release(release, on_progress)
    local function report(stage, percent)
        if on_progress then
            on_progress({ stage = stage, percent = percent })
        end
    end
    report("preparing", 0)
    local archive = self.settings_dir .. "/readeck-update.zip"
    local checksum = archive .. ".sha256"
    local stage_dir = self.settings_dir .. "/readeck-update-stage"
    remove_file(archive)
    remove_file(checksum)
    remove_tree(stage_dir)
    local made, make_err = make_path(stage_dir)
    if not made then
        return nil, "cannot create staging directory: " .. tostring(make_err)
    end

    local archive_size = tonumber(release.archive_size) or 0
    local ok, err = self:_http_get_with_mirrors(release.archive_url, archive, function(received, total)
        local ratio = total and total > 0 and math.min(1, received / total) or 0
        report("downloading", math.floor(5 + ratio * 70))
    end, archive_size, Updater.MAX_PACKAGE_BYTES)
    if not ok then
        remove_tree(stage_dir)
        return nil, err
    end

    report("checksum", 76)
    local checksum_ok, checksum_err = self:_http_get_with_mirrors(release.checksum_url, checksum)
    if not checksum_ok then
        remove_file(archive)
        remove_tree(stage_dir)
        return nil, checksum_err
    end
    local package, package_err = read_file(archive, Updater.MAX_PACKAGE_BYTES)
    local checksum_body = read_file(checksum, 4096)
    if not package or not checksum_body then
        remove_file(archive)
        remove_file(checksum)
        remove_tree(stage_dir)
        return nil, package_err or "invalid checksum file"
    end
    report("verifying", 82)
    local expected = checksum_body:match("^%s*([0-9a-fA-F]+)")
    local digest, digest_err = sha256_hex(package)
    if not expected or #expected ~= 64 or not digest or digest ~= expected:lower() then
        remove_file(archive)
        remove_file(checksum)
        remove_tree(stage_dir)
        return nil, digest_err or "SHA-256 verification failed"
    end

    report("extracting", 90)
    local unpacked, unpack_err = unpack_release(archive, stage_dir)
    remove_file(archive)
    remove_file(checksum)
    if not unpacked then
        remove_tree(stage_dir)
        return nil, unpack_err or "archive extraction failed"
    end
    local staged_plugin = stage_dir .. "/" .. Updater.PLUGIN_DIR_NAME
    local meta = read_file(staged_plugin .. "/_meta.lua", 65536)
    local main = read_file(staged_plugin .. "/main.lua", 1024 * 1024)
    local staged_version = meta and meta:match('version%s*=%s*"([^"]+)"') or nil
    if not main or staged_version ~= release.version then
        remove_tree(stage_dir)
        return nil, "release package structure or version is invalid"
    end

    report("installing", 97)
    local backup = self.plugin_dir .. ".backup"
    remove_tree(backup)
    local moved_old, move_old_err = os.rename(self.plugin_dir, backup)
    if not moved_old then
        remove_tree(stage_dir)
        return nil, move_old_err or "could not back up plugin"
    end
    local moved_new, move_new_err = os.rename(staged_plugin, self.plugin_dir)
    if not moved_new then
        os.rename(backup, self.plugin_dir)
        remove_tree(stage_dir)
        return nil, move_new_err or "could not activate update"
    end
    remove_tree(stage_dir)
    report("complete", 100)
    return true
end

return Updater
