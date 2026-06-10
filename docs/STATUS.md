# 项目状态（2026-06-10）

## 当前结论

这个项目已经能作为本地 macOS 应用使用，不是半成品空壳。源码、打包、Whisper 转写、SpeakerKit 说话人分离、YouTube 下载、B 站两段式下载都已跑通过。

## 已验证

- `swift build -c release`：通过。
- `bash build.sh`：可生成并签名 `dist/视频转文字.app`。
- `scripts/smoke.sh`：本地短音频可完成解码、转写。
- `SMOKE_DIARIZE=1 scripts/smoke.sh`：说话人分离可完成。
- `LOCAL_SAMPLE=/tmp/video2text-no-such-file scripts/smoke.sh`：YouTube 短公开视频下载、解码、转写通过。
- `scripts/smoke.sh --url https://www.bilibili.com/video/BV1nx411u79K`：B 站两段式下载、解码、转写通过。

## 已修复

- B 站 CDN 下载中途断连时，原实现会直接失败。现在直接媒体下载有 3 次有限重试。
- 首次安装 yt-dlp 的流式下载也加了 3 次有限重试。

## 仍需注意

- 抖音公开视频解析返回 `Fresh cookies (not necessarily logged in) are needed`。这属于平台风控，应用里已经支持在设置中填写 `cookies.txt`，但需要用户提供当前可用 cookies 后再测完整链路。
- 目录刚初始化为 Git 仓库，建议后续所有功能变动都先跑 `scripts/smoke.sh` 和必要的平台链接验证。
- 当前没有单元测试，主要依赖 smoke 测试覆盖真实端到端路径。
