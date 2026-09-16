# Changelog


## v0.1.2 - 2026-09-15

Source: https://github.com/likidu/readeck.koplugin  
License: MIT

### English

This release adds third-party launcher support, so the plugin can be pinned to SimpleUI (and ZenUI) quick actions and tab bars.

#### Added

- Added a stable `launch()` entry point that opens the configured download folder; SimpleUI's and ZenUI's plugin pickers discover it by convention (same as `weread.koplugin`).
- Added the official Readeck logo (`icons/readeck.svg`) for use as a quick-action icon.
- Added SimpleUI integration instructions to the README (English and Simplified Chinese).

#### Changed

- The "Go to download folder" menu entry and `launch()` now share one code path: an open document is closed first, and a prompt asks you to configure a download folder when none is set yet.

### 中文

本版本新增第三方启动器支持：可以把插件固定到 SimpleUI（以及 ZenUI）的快捷操作和底部栏。

#### 新增

- 新增稳定的 `launch()` 入口：打开已配置的下载文件夹；SimpleUI 和 ZenUI 的插件选择器会按约定自动发现该方法（与 `weread.koplugin` 一致）。
- 新增 Readeck 官方图标（`icons/readeck.svg`），可用作快捷操作图标。
- README（英文 / 简体中文）新增 SimpleUI 集成说明。

#### 变更

- 菜单中“前往下载文件夹”与 `launch()` 共用同一实现：先关闭正在阅读的文档再打开文件夹；尚未配置下载目录时会提示先配置。

## v0.1.1 - 2026-05-07

Source: https://github.com/iceyear/readeck.koplugin  
License: MIT

### English

This release is a maintenance and refactoring release focused on reliability, clearer sync behavior, Readeck 0.22.2 compatibility, and a more maintainable plugin structure.

#### Added

- Added plugin-provided i18n fallbacks with English and Simplified Chinese, while still reusing KOReader gettext strings when available.
- Added configurable log levels: `Info`, `Debug`, `Warnings`, and `Errors`.
- Added Readeck server feature detection through `/api/info`, with an automatic mode plus manual modern/legacy compatibility modes.
- Added bidirectional highlight sync for Readeck annotations and KOReader highlights, including note and color support for modern Readeck servers.
- Added highlight conflict strategies: merge changes, let Readeck overwrite KOReader, or let KOReader overwrite Readeck.
- Added a remote-deleted highlight policy so users can preserve local highlights or respect Readeck-side deletions.
- Added reading progress sync below 100% between KOReader and Readeck.
- Added file timestamp sync from Readeck metadata and estimated reading time as a KOReader keyword.
- Added periodic sync beta support.
- Added a dismissible, movable sync progress popup that can be reopened from the Readeck menu while sync is still running.
- Added KOReader runtime smoke tests and mock Readeck API network smoke tests for OAuth, article download, and highlight sync.

#### Changed

- Refactored the previous single-file implementation into smaller Lua modules; `main.lua` is now a compact plugin assembly entry point.
- Reorganized settings into clearer groups: server, authentication, client, article selection, article actions, highlights, periodic sync, and ratings/review tags.
- Reworked authentication around API token and OAuth device flow; username/password login is no longer exposed because current Readeck versions no longer support it.
- Improved sync status wording so archive/delete actions are reported accurately and less alarmingly.
- Improved article sync progress wording to show checked, downloaded, skipped, failed, and planned/completed local or remote actions.
- Made subprocess downloads experimental and explicit opt-in; failed or timed-out subprocess downloads now fall back to the stable blocking downloader.
- Reduced UI stalls by rendering status messages before slow work and by using async/cooperative paths only when KOReader runtime support is available.
- Updated development workflow with Stylua, Luacheck, Busted, KOReader runtime probes, and GitHub Actions CI.
- Documented the project as MIT-licensed open source at https://github.com/iceyear/readeck.koplugin and exposed this in the KOReader plugin About dialog.

#### Fixed

- Fixed misleading “Deleted” sync status text when articles were archived instead of deleted.
- Fixed repeated full-list redownload behavior by skipping already-downloaded articles by embedded Readeck ID.
- Fixed finished/read local actions being skipped incorrectly during sync in common archive workflows.
- Fixed Readeck 0.22.2 highlight payload compatibility for notes and transparent/none colors.
- Fixed progress popup behavior so dismissing it does not stop background sync progress tracking.
- Fixed saved experimental subprocess-download settings from old test builds being migrated back to stable defaults unless users explicitly opt in again.

#### Upgrade Notes

- Readeck username/password login is not supported. Use OAuth device flow or an API token.
- If upgrading from an early experimental build and sync/authentication behaves strangely, clear the old `readeck.lua` plugin settings and configure the plugin again.
- Experimental subprocess downloads are off by default. Keep them disabled unless you are testing that backend on your device/server.

### 中文

这是一个偏维护和重构的版本，重点是提高同步可靠性、理清同步行为、兼容 Readeck 0.22.2，并把插件结构整理到更容易长期维护的状态。

#### 新增

- 新增插件自带 i18n 回退，提供英文和简体中文，同时仍会优先复用 KOReader 已有 gettext 文本。
- 新增日志等级设置：`Info`、`Debug`、`Warnings`、`Errors`。
- 新增通过 `/api/info` 自动探测 Readeck 服务端能力，并支持手动固定新版/旧版兼容模式。
- 新增 Readeck annotations 与 KOReader highlights 的双向高亮同步，并支持新版 Readeck 的笔记和颜色字段。
- 新增高亮冲突策略：合并变更、Readeck 覆盖 KOReader、KOReader 覆盖 Readeck。
- 新增远端已删除高亮的处理策略：可保留本地高亮，也可尊重 Readeck 远端删除。
- 新增低于 100% 的阅读进度在 KOReader 与 Readeck 之间同步。
- 新增下载文件按 Readeck 元数据设置时间戳，并将预计阅读时间写入 KOReader 关键词。
- 新增周期同步 Beta。
- 新增可关闭、可移动的同步进度框；同步仍在进行时，可从 Readeck 菜单重新显示。
- 新增 KOReader runtime smoke 测试和 mock Readeck API 网络 smoke 测试，覆盖 OAuth、文章下载和高亮同步。

#### 变更

- 将原本单文件为主的实现重构为多个较小的 Lua 模块；`main.lua` 现在只负责插件装配。
- 重新整理设置菜单分组：服务器、认证、客户端、文章选择、文章动作、高亮、周期同步、评分/评论标签。
- 认证流程改为围绕 API token 和 OAuth 设备授权；当前 Readeck 已不支持用户名/密码登录，因此插件不再暴露该方式。
- 改进同步状态文案，归档和删除会分别显示，避免“明明归档却显示删除”的惊吓感。
- 改进文章同步进度文案，会显示已检查、已下载、已跳过、失败，以及本地/远端即将或已经执行的动作。
- 子进程下载改为实验性显式开启；如果失败或超时，会回退到稳定的阻塞下载路径。
- 减少 UI 卡顿：慢操作前先渲染状态提示，并且只在 KOReader runtime 支持时使用异步/协作式路径。
- 更新开发流程，加入 Stylua、Luacheck、Busted、KOReader runtime probe 和 GitHub Actions CI。
- 明确项目以 MIT 协议开源，源码仓库为 https://github.com/iceyear/readeck.koplugin，并在 KOReader 插件“关于”弹窗中显示。

#### 修复

- 修复设置为归档时，状态消息仍显示 “Deleted” 的误导性问题。
- 修复同步时可能重复处理整批已下载文章的问题，现在会通过文件名内嵌的 Readeck ID 跳过已存在文章。
- 修复常见归档流程中，同步时本地已完成/已读动作可能被错误跳过的问题。
- 修复 Readeck 0.22.2 高亮 payload 对笔记和透明/none 颜色字段的兼容性。
- 修复进度框被关闭后影响后台同步进度追踪的问题。
- 修复早期测试版本保存过的实验性子进程下载设置：升级后会回到稳定默认值，除非用户再次显式开启。

#### 升级提示

- 不再支持 Readeck 用户名/密码登录，请使用 OAuth 设备授权或 API token。
- 如果从很早期实验版本升级后，同步或认证表现异常，请清除旧的 `readeck.lua` 插件配置并重新配置。
- 实验性子进程下载默认关闭。除非你正在专门测试该后端在自己设备/服务器上的表现，否则建议保持关闭。
