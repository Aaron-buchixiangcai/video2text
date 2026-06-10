# 视频转文字

macOS 原生应用：粘贴视频链接（抖音 / Bilibili / YouTube 等 yt-dlp 支持的上千个网站），自动下载音频并**在本地**转写为文字稿。支持三种输出：纯文字、带时间戳、区分发言人。完全免费、离线识别、不上传任何内容。

## 功能

- **链接转写**：粘贴链接 → 自动下载音频 → Whisper 本地识别（中英混合）
- **分享文案识别**：可直接粘贴抖音等平台的整段分享文字，应用会自动提取其中的链接
- **简体中文输出**：中文识别结果会统一转换为简体，避免 Whisper 偶发输出繁体
- **本地文件**：把视频/音频文件直接拖进窗口（下载失败时的万能兜底）
- **说话人分离**：自动标注「说话人1 / 说话人2 …」（SpeakerKit / Pyannote v4，本地运行）
- **导出**：复制到剪贴板，或导出 .txt / .docx / .srt / .vtt / .md
- **历史记录**：转写结果自动保存，重启后可查
- **设置**（⌘,）：模型选择、识别语言、hf-mirror 镜像、cookies、yt-dlp 更新

## 构建

需要：Apple Silicon Mac，macOS 14+，Xcode Command Line Tools（`xcode-select --install`）。

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
| 抖音 | 时好时坏（抖音风控频繁变化）。失败时：① 设置中配置 cookies.txt ② 设置中点「检查更新」升级 yt-dlp ③ 浏览器下载视频后拖入窗口 |
| 其他 | yt-dlp 支持的站点都可尝试；直链 .mp4/.m4a 也可直接粘贴 |

cookies.txt 导出方法：浏览器装「Get cookies.txt LOCALLY」扩展，登录目标网站后导出，把文件路径填到设置中。

## 命令行模式（调试用）

```bash
.build/debug/Video2Text --smoke [--language zh|en|auto] [--diarize] [--url 链接] [本地文件...]
```

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
