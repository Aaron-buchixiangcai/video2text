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

## 2026-11-02 更新（版本 1.2 build 8，未合并进 main）

- B站下载 HTTP 567：下载请求一律带 `Range: bytes=0-`（Bilibili-Evolved #5857、yt-dlp #17847）。实测 15 条全部成功，修复前约 3/5。
- B站分P视频：逐P下载、转写、分离说话人，拼成一份文字稿，每P开头插分P标题（Utterance.isPartMarker），时间按P从 00:00 起算；设置「最多转写前 N P」默认 10。收藏夹 / 合集 / 稍后再看的 `?bvid=` 链接先改写成视频本身。
- 总结：文稿约 30 秒合成一行再发给 Claude；超过 8 万字分段写笔记再合成。调用 claude 前去掉继承来的 Claude Code 会话变量，并把 PWD 指向临时目录（PWD 在桌面时，系统会以本 App 名义弹授权框，claude 一直卡住）。
- 界面：标题按列宽截断并可悬停看全名；总结和汇总按 Markdown 排版；进度条显示主题、可停止；设置分三页；菜单和设置窗口改为中文；失败提示只显示 ERROR 行并给中文说明。
- 测试接口（`--test-api`，只监听本机）：见 `docs/TEST_API.md`。界面检查用它截取了 9 个界面的深色 / 浅色 / 最小窗口截图。

已用测试接口在 App 里验证：B站搜索、3 条视频转写 + 自动总结 + 汇总、6P 课程取前 2P（分P标题、每P时间、说话人、总结引用 [P1 00:31]）、停止总结、失败提示。

## 仍需注意

- 只有背景音乐、没有人声的视频，Whisper 会编出歌词或「优优独播剧场」之类的水印文字；总结时 Claude 能认出来，但这类视频没有可用内容。
- App 自带的 yt-dlp 是 2026.06.09，已超过 90 天，可在设置「下载」页点「检查更新」。

- 抖音公开视频已改为自动启动独立的临时 Chrome profile 完成 JavaScript 风控验证，再让 yt-dlp 读取该临时会话；不会读取用户日常浏览器 profile。抖音风控仍可能变化，升级后应保留真实链接回归测试。
- 目录刚初始化为 Git 仓库，建议后续所有功能变动都先跑 `scripts/smoke.sh` 和必要的平台链接验证。
- 当前没有单元测试，主要依赖 smoke 测试覆盖真实端到端路径。
