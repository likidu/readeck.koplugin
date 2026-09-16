-- Presentation and subprocess orchestration for the plugin updater.
-- Network, verification, extraction, and rollback logic lives in
-- readeck.core.updater.

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")

local PluginUpdater = require("readeck.core.updater")

local UpdaterUI = {}

function UpdaterUI.install(Readeck, deps)
    local L = deps.L
    local T = deps.T
    local Log = deps.Log

    function Readeck:_updater()
        if not self._readeck_updater then
            self._readeck_updater = PluginUpdater:new({
                current_version = deps.PLUGIN_VERSION,
                plugin_dir = deps.PLUGIN_DIR,
            })
        end
        return self._readeck_updater
    end

    -- Run a blocking task off the UI thread. Uses KOReader's Trapper
    -- subprocess support when available (so the user can dismiss long
    -- operations) and falls back to a scheduled callback otherwise.
    function Readeck:_runUpdaterTask(message, task, callback, trap_widget)
        local ok_trapper, Trapper = pcall(require, "ui/trapper")
        if ok_trapper and Trapper and Trapper.wrap and not coroutine.running() then
            Trapper:wrap(function()
                self:_runUpdaterTask(message, task, callback, trap_widget)
            end)
            return
        end
        local message_widget
        if message then
            message_widget = InfoMessage:new({ text = message, timeout = 120 })
            UIManager:show(message_widget)
            trap_widget = message_widget
        end
        local function safe_task()
            local ok, result = xpcall(task, debug.traceback)
            if ok then
                return result
            end
            return { error = result }
        end
        local function finish(result)
            if message_widget then
                UIManager:close(message_widget)
            end
            callback(result)
        end
        if ok_trapper and Trapper and Trapper.dismissableRunInSubprocess then
            local completed, result = Trapper:dismissableRunInSubprocess(safe_task, trap_widget)
            if completed then
                UIManager:scheduleIn(0.1, function()
                    finish(result)
                end)
            else
                UIManager:scheduleIn(0.1, function()
                    finish({ cancelled = true, error = "cancelled" })
                end)
            end
        else
            UIManager:scheduleIn(0.1, function()
                finish(safe_task())
            end)
        end
    end

    function Readeck:_showUpdaterRelease(release)
        if PluginUpdater.compare_versions(release.version, deps.PLUGIN_VERSION) ~= 1 then
            UIManager:show(InfoMessage:new({
                text = T(L("Readeck is up to date (v%1)."), deps.PLUGIN_VERSION),
                timeout = 3,
            }))
            return
        end
        local notes = release.notes or L("No release notes were provided.")
        local viewer
        viewer = TextViewer:new({
            title = T(L("v%1 → v%2"), deps.PLUGIN_VERSION, release.version),
            text = notes,
            text_type = "general",
            auto_para_direction = true,
            buttons_table = {
                {
                    {
                        text = L("Cancel"),
                        callback = function()
                            UIManager:close(viewer)
                        end,
                    },
                    {
                        text = L("Download and install"),
                        callback = function()
                            UIManager:close(viewer)
                            UIManager:scheduleIn(0.1, function()
                                self:installUpdaterRelease(release)
                            end)
                        end,
                    },
                },
            },
        })
        UIManager:show(viewer)
    end

    function Readeck:checkForUpdates()
        NetworkMgr:runWhenOnline(function()
            self:_runUpdaterTask(L("Checking for updates…"), function()
                local release, err = self:_updater():fetch_release()
                return { release = release, error = err }
            end, function(result)
                if not result or not result.release then
                    if result and result.cancelled then
                        return
                    end
                    Log:warn("Update check failed", tostring(result and result.error))
                    UIManager:show(InfoMessage:new({
                        text = T(
                            L("Update check failed:\n%1"),
                            tostring(result and result.error or L("Unknown error"))
                        ),
                    }))
                    return
                end
                self:_showUpdaterRelease(result.release)
            end)
        end)
    end

    function Readeck:installUpdaterRelease(release)
        local ok_trapper, Trapper = pcall(require, "ui/trapper")
        if ok_trapper and Trapper and Trapper.wrap and not coroutine.running() then
            Trapper:wrap(function()
                self:installUpdaterRelease(release)
            end)
            return
        end

        local dialog = InfoMessage:new({
            text = T(L("Installing Readeck v%1…"), release.version),
            timeout = 300,
        })
        UIManager:show(dialog)

        self:_runUpdaterTask(nil, function()
            local ok, err = self:_updater():install_release(release)
            return { success = ok == true, error = err }
        end, function(result)
            if dialog then
                UIManager:close(dialog)
            end
            if not result or not result.success then
                if result and result.cancelled then
                    return
                end
                Log:error("Update installation failed", tostring(result and result.error))
                UIManager:show(InfoMessage:new({
                    text = T(
                        L("Update installation failed:\n%1"),
                        tostring(result and result.error or L("Unknown error"))
                    ),
                }))
                return
            end
            UIManager:show(ConfirmBox:new({
                text = T(L("Readeck v%1 was installed.\n\nRestart KOReader to apply the update?"), release.version),
                ok_text = L("Restart now"),
                cancel_text = L("Later"),
                ok_callback = function()
                    UIManager:restartKOReader()
                end,
            }))
        end, dialog)
    end

    function Readeck:cleanupUpdateBackup()
        self:_updater():cleanup_backup()
    end
end

return UpdaterUI
