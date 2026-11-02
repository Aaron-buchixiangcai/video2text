# 本机测试接口

调试用。正常启动不会开启。开启后可以用 curl 操作正在运行的 App，走的代码和在界面上点按钮相同：搜索、提交转写、等待完成、读取文字稿、总结和汇总。

## 开启

```bash
open "/Applications/视频转文字.app" --args --test-api          # 默认端口 47821
open "/Applications/视频转文字.app" --args --test-api 48000    # 指定端口
```

- 只监听本机回环地址 127.0.0.1，其他机器连不上。
- 开启期间，本机任何程序都能调用它。它能下载视频、调用 Claude 消耗额度，所以测完请退出 App，再正常打开。
- App 已经在运行时，先退出再用上面的命令打开。
- 浏览器网页发来的请求（带 Origin 或 Sec-Fetch-* 头，或 Host 不是本机地址）一律返回 403。

## 接口

| 方法 | 路径 | 作用 |
|---|---|---|
| GET | `/status` | 当前任务（阶段、进度、错误、字数、分P标题）和批量总结的进度 |
| GET | `/wait?timeout=秒` | 一直等到任务都结束、总结也跑完再返回，默认最多等 1800 秒；返回内容同 `/status`，另加 `timedOut` |
| POST | `/search` | 搜索：`{"platform": "bilibili" 或 "youtube", "keyword": "…", "sort": "relevance" / "views" / "newest", "count": 10}` |
| POST | `/submit` | 与搜索面板的「转写所选」相同：`{"urls": […], "titles": […]（可选）, "topic": "汇总标题", "autoSummarize": true}`；返回 `summaryScheduled`，已有一批总结在跑时为 false |
| POST | `/summarize` | 对历史记录批量总结：`{"ids": [记录 id…], "topic": "…"}` |
| GET | `/history?limit=N` | 最近的历史记录列表 |
| GET | `/history/{id}` | 一条记录的完整文字稿（带时间戳）和总结 |
| GET | `/digests?limit=N` | 汇总列表 |
| GET | `/digests/{id}` | 一份汇总的 Markdown |
| GET | `/settings` | 当前设置 |
| POST | `/settings` | 只改传入的字段，例如 `{"maxBilibiliParts": 3, "diarizationEnabled": false}`；未知字段返回 400 |
| POST | `/ui` | 驱动界面，见下 |
| GET | `/ui/screenshot?dir=目录&name=前缀` | 把每个可见窗口（主窗口、搜索面板、设置窗口）各存成一张 PNG，返回路径 |

`POST /ui` 的字段都可选，可以一次传多个：

| 字段 | 作用 |
|---|---|
| `select` | `{"kind": "history" / "digest" / "task", "id": "…"}` 选中侧栏一项；`"none"` 回到首页 |
| `search` | `true` / `false` 打开或关闭搜索面板 |
| `selectMode` | `true` / `false` 进入或退出历史多选 |
| `summaryTab` | `true` 切到「总结」，`false` 切到「文字稿」，`null` 不再干预 |
| `stopSummary` | `true` 停止正在进行的总结 |
| `appearance` | `"dark"` / `"light"` / `"system"` |
| `window` | `{"width": 1100, "height": 700}` 调整主窗口大小（最小 760×480） |
| `settings` | `true` 打开设置窗口（会把 App 调到前台），`false` 关闭 |

截图由 App 自己画（不需要屏幕录制权限，窗口在别的桌面也能截）。少数东西会和屏幕上不一样，例如侧栏 ✨ 图标的颜色。

## 示例：搜 B站、转写前 3 条并汇总

```bash
API=http://127.0.0.1:47821
curl -s $API/search -d '{"keyword":"手冲咖啡 教程","sort":"views","count":3}'
curl -s $API/submit -d '{"urls":["https://www.bilibili.com/video/av…","…"],"topic":"手冲咖啡"}'
curl -s "$API/wait?timeout=3600"
curl -s "$API/digests?limit=1"
```

返回内容都是 JSON。出错时带 `error` 字段。
