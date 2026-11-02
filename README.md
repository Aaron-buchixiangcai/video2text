# 视频转文字

macOS 原生应用：粘贴视频链接（抖音 / Bilibili / YouTube 等 yt-dlp 支持的上千个网站），自动下载音频并**在本地**转写为文字稿。支持三种输出：纯文字、带时间戳、区分发言人。语音识别免费、离线进行；只有使用「总结」功能时，文字稿才会发给 Claude。

## 功能

- **链接转写**：粘贴链接 → 自动下载音频 → Whisper 本地识别（中英混合）
- **分享文案识别**：可直接粘贴抖音等平台的整段分享文字，应用会自动提取其中的链接；一次粘贴多个链接会逐个排队
- **关键词搜索 → 打包总结**：点「搜索…」按关键词搜 B站 / YouTube，可按「综合 / 最多播放 / 最新发布」排序（YouTube 无「最新发布」），列表显示播放量、时长、UP 主；勾选后批量转写，勾上「转写完后自动总结并生成汇总」即一键出汇总。B站短时间内多次搜索会被限流（HTTP 412），App 会自动等待重试
- **B站搜索插件**：yt-dlp 内置的 B站搜索不传排序参数、只保留链接，App 会写入一个 yt-dlp 插件（`~/Library/Application Support/Video2Text/bin/yt-dlp-plugins/`），沿用同一接口，只多传排序参数并保留标题、播放量
- **YouTube 字幕优先**：有字幕的 YouTube 视频直接用字幕，不下载音频（设置里可关；字幕没有说话人标注）
- **B站分P视频**：课程合集按P逐个下载转写，拼成一份文字稿，每P开头标出分P标题、时间从 00:00 起算；设置里可改最多转前几P（默认 10）。链接带 `?p=N` 时只转那一P；从收藏夹、合集、稍后再看点开的链接会先改写成视频本身
- **B站下载 HTTP 567**：镜像节点 upos-sz-mirrorcosov 拒绝不带 Range 头的请求，下载时一律带 `Range: bytes=0-`
- **批量总结**：历史栏多选后点 ✨，逐条写单篇总结，两条以上再生成一份汇总，显示在侧栏「汇总」里；单条记录也可点「总结」。调用本机 Claude Code 命令行（`claude -p`，模型 Sonnet 5.5），用你自己的账号和额度，需先在终端运行 `claude auth login`
- **简体中文输出**：中文识别结果会统一转换为简体，避免 Whisper 偶发输出繁体
- **本地文件**：把视频/音频文件直接拖进窗口（下载失败时的万能兜底）
- **说话人分离**：自动标注「说话人1 / 说话人2 …」（SpeakerKit / Pyannote v4，本地运行）
- **导出**：复制到剪贴板，或导出 .txt / .docx / .srt / .vtt / .md
- **历史记录**：转写结果自动保存，重启后可查
- **设置**（⌘,）：模型选择、识别语言、hf-mirror 镜像、cookies、yt-dlp 更新

## 构建

需要：Apple Silicon Mac，macOS 14+，Xcode Command Line Tools（`xcode-select --install`）。
没装 Xcode 时，新版 SDK 缺 SwiftUI 宏插件会编译失败，`build.sh` 会自动改用命令行工具自带的 macOS 26 SDK；手动编译用 `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build`。

```bash
bash build.sh            # 构建 + 打包 dist/视频转文字.app
bash build.sh --install  # 同时安装到 /Applications
open "dist/视频转文字.app"
```

## 首次运行

1. 应用引导下载 yt-dlp（约 35MB，存放在 `~/Library/Application Support/Video2Text/bin/`）
2. 第一次转写时自动下载 Whisper 模型（默认 turbo 量化版约 626MB）和说话人分离模型（约 100MB）
3. 模型首次加载需 1–3 分钟（CoreML 编译缓存），之后秒级加载

国内网络下载模型慢时，在设置中开启「hf-mirror.com 镜像」。

## 各平台说明

| 平台 | 状态 |
|---|---|
| YouTube | 直接可用 |
| Bilibili | 直接可用（应用内置两段式下载，绕开海外 IP 的 412 风控；大会员视频需 cookies） |
| 抖音 | 直接粘贴链接即可；应用会自动用隔离的临时浏览器会话完成风控验证，不读取个人 Chrome 数据 |
| 小红书 | 直接可用（`xhslink.com` 短链或整段分享文案直接粘贴即可；图文笔记无视频无法转写） |
| 其他 | yt-dlp 支持的站点都可尝试；直链 .mp4/.m4a 也可直接粘贴 |

只有登录后才能观看的视频才需要 cookies.txt；公开抖音链接通常无需手工配置。

## 命令行模式（调试用）

```bash
.build/debug/Video2Text --smoke [--language zh|en|auto] [--diarize] [--download-only] [--url 链接] [本地文件...]
.build/debug/Video2Text --smoke --search yt|bili 条数 关键词      # 测搜索
.build/debug/Video2Text --smoke --subtitles YouTube链接           # 测字幕
.build/debug/Video2Text --smoke --summarize-latest [条数]          # 总结最新几条历史，只打印不保存
.build/debug/Video2Text --smoke --extract-urls "一段含多个链接的文字"
.build/debug/Video2Text --smoke --url B站链接 --max-parts 3 --download-only  # 测分P下载
.build/debug/Video2Text --smoke --pipeline 主题 链接1 链接2 …     # 走 App 内完整流程：转写 → 总结 → 汇总（写入历史）
.build/debug/Video2Text --smoke --canonical-bili 链接             # 看收藏夹 / 合集链接改写结果
```

App 还带一个只在本机可用的测试接口，可以用 curl 搜索、提交、读结果、切换界面和截图，说明见 [docs/TEST_API.md](docs/TEST_API.md)。

## 开发验证

```bash
scripts/smoke.sh                 # 默认短音频：解码 → Whisper 转写
SMOKE_DIARIZE=1 scripts/smoke.sh # 同时验证说话人分离
scripts/smoke.sh /path/to/a.m4a  # 指定本地音视频文件
```

默认样例优先复用 `~/Library/Application Support/Video2Text/downloads/smoke/`
里的开发测试音频；如果本地没有样例，会用应用内下载器抓取一个 19 秒公开视频。

## 技术栈

- SwiftUI + Swift Package Manager（无需 Xcode 工程）
- [argmax-oss-swift](https://github.com/argmaxinc/argmax-oss-swift)（WhisperKit 语音识别 + SpeakerKit 说话人分离，CoreML / Apple Neural Engine）
- [yt-dlp](https://github.com/yt-dlp/yt-dlp) 独立二进制（视频音频下载）
- AVFoundation（音频解码，无需 ffmpeg）

数据目录：`~/Library/Application Support/Video2Text/`（模型、yt-dlp、历史记录）。
