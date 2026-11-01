# 项目状态（2026-07-24）

## 当前结论

这个项目已经能作为本地 macOS 应用使用，不是半成品空壳。源码、打包、Whisper 转写、SpeakerKit 说话人分离、YouTube 下载、B 站两段式下载都已跑通过。

## 已验证

- `swift build -c release`：通过。
- `bash build.sh`：可生成并签名 `dist/视频转文字.app`。
- `scripts/smoke.sh`：本地短音频可完成解码、转写。
- `SMOKE_DIARIZE=1 scripts/smoke.sh`：说话人分离可完成。
- `LOCAL_SAMPLE=/tmp/video2text-no-such-file scripts/smoke.sh`：YouTube 短公开视频下载、解码、转写通过。
- `scripts/smoke.sh --url https://www.bilibili.com/video/BV1nx411u79K`：B 站两段式下载、解码、转写通过。
- 已安装的 1.1 正式版对 5 条随机冻结的抖音公开视频完成真实下载和音频解码，结果 5/5；详见 `DOUYIN_5_VIDEO_REGRESSION_20260724.md`。

## 已修复

- B 站 CDN 下载中途断连时，原实现会直接失败。现在直接媒体下载有 3 次有限重试。
- 首次安装 yt-dlp 的流式下载也加了 3 次有限重试。

## 2026-11-01 新增（分支 feature/search-summary，版本 1.2 build 3）

- 关键词搜索（YouTube / B站）+ 勾选批量转写 + 可选转写完自动总结。
- 搜索排序：B站用 App 写入的 yt-dlp 插件（`YtDlpPlugins.swift`，搜索键 `bilisortrank/click/pubdate`）；YouTube「最多播放」用搜索页 `sp=CAM%3D`，按上传日期的 `sp=CAI%3D` 实测已失效，故 YouTube 不提供「最新发布」；App 自带的 yt-dlp 2026.06.09 不认 `ytsearchdate`。
- 一次粘贴多个链接逐个排队。
- YouTube 有字幕时直接用字幕（设置可关）；B站不取字幕，B站 AI 字幕要登录。
- 批量总结与汇总：调用本机 `claude -p`（sonnet），带 `--settings {"outputStyle":"default"}` 和自定义系统提示，避免套用用户全局输出风格。
- 本机已无 Xcode，命令行工具的 macOS 27 SDK 缺 SwiftUIMacros 插件；`build.sh` 已加回退到 macOS 26.5 SDK。

已用 `--smoke` 验证：多链接解析、YouTube 搜索、B站搜索（只有编号）、YouTube 人工字幕和自动字幕、无字幕回退、两条历史记录的单篇总结。窗口界面的点按流程需人工试用。

## 仍需注意

- 抖音公开视频已改为自动启动独立的临时 Chrome profile 完成 JavaScript 风控验证，再让 yt-dlp 读取该临时会话；不会读取用户日常浏览器 profile。抖音风控仍可能变化，升级后应保留真实链接回归测试。
- 目录刚初始化为 Git 仓库，建议后续所有功能变动都先跑 `scripts/smoke.sh` 和必要的平台链接验证。
- 当前没有单元测试，主要依赖 smoke 测试覆盖真实端到端路径。
