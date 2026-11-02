import AppKit
import Network

/// 本机测试接口：只在启动参数带 --test-api [端口] 时开启，只接受 127.0.0.1 的连接。
/// 直接操作正在运行的 AppState，和在界面上点按钮走同一套代码。接口说明见 docs/TEST_API.md
final class TestAPI: @unchecked Sendable {
    static let defaultPort: UInt16 = 47821

    private let listener: NWListener
    private let port: UInt16
    private weak var appState: AppState?

    /// 没带 --test-api 时返回 nil
    static func portFromArguments(_ args: [String] = CommandLine.arguments) -> UInt16? {
        guard let index = args.firstIndex(of: "--test-api") else { return nil }
        if index + 1 < args.count, let port = UInt16(args[index + 1]) { return port }
        return defaultPort
    }

    init(appState: AppState, port: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? 47821)
        self.appState = appState
        self.port = port
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { state in
            if case let .failed(error) = state { NSLog("测试接口启动失败: \(error)") }
        }
        listener.start(queue: .main)
        NSLog("测试接口已开启: http://127.0.0.1:\(port)")
    }

    // MARK: - HTTP

    private struct Request {
        let method: String
        let path: String
        let query: [String: String]
        /// 头部名转成小写
        let headers: [String: String]
        let body: Data
    }

    private func accept(_ connection: NWConnection) {
        // 已限定只监听回环接口，这里再按来源地址确认一次
        guard case let .hostPort(host, _) = connection.endpoint,
              "\(host)".hasPrefix("127.") || "\(host)".hasPrefix("::1") else {
            connection.cancel()
            return
        }
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                guard self.isTrusted(request) else {
                    self.respond(connection, status: 403, json: ["error": "只接受本机命令行请求"])
                    return
                }
                Task { @MainActor in
                    let (status, json) = await self.route(request)
                    self.respond(connection, status: status, json: json)
                }
            } else if isComplete || error != nil || buffer.count > 1 << 20 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    /// 浏览器网页发来的请求带 Origin，DNS 重绑定的请求 Host 不是本机地址；这两种都拒绝，
    /// 免得开着接口时任意网页能让 App 下载视频、调用 Claude
    private func isTrusted(_ request: Request) -> Bool {
        // 浏览器的每个请求都带 Sec-Fetch-*，curl 和脚本不带；跨站 GET 不带 Origin，只能靠它拦
        guard request.headers["origin"] == nil,
              request.headers["sec-fetch-site"] == nil,
              request.headers["sec-fetch-mode"] == nil else { return false }
        let allowedHosts = ["127.0.0.1", "localhost", "[::1]"].map { "\($0):\(port)" }
        return request.headers["host"].map(allowedHosts.contains) ?? false
    }

    /// 头部和 Content-Length 指定的正文都收齐才返回
    private static func parse(_ data: Data) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        let parts = lines[0].components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // 负数或超过 1MB 的长度当作收不齐，由 receive 关闭连接
        let length = headers["content-length"].flatMap { Int($0) } ?? 0
        guard (0...(1 << 20)).contains(length) else { return nil }
        let body = data[headerEnd.upperBound...]
        guard body.count >= length else { return nil }

        let components = URLComponents(string: parts[1])
        var query: [String: String] = [:]
        components?.queryItems?.forEach { query[$0.name] = $0.value ?? "" }
        return Request(
            method: parts[0].uppercased(),
            path: components?.path ?? parts[1],
            query: query,
            headers: headers,
            body: Data(body.prefix(length))
        )
    }

    private func respond(_ connection: NWConnection, status: Int, json: Any) {
        let body = (try? JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )) ?? Data("{}".utf8)
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 409: "Conflict",
                      503: "Service Unavailable"][status] ?? "Error"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - 路由

    @MainActor
    private func route(_ request: Request) async -> (Int, Any) {
        guard let appState else { return (503, ["error": "App 未就绪"]) }
        let parsedBody = request.body.isEmpty ? [:] : (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
        guard let body = parsedBody else { return (400, ["error": "请求体不是 JSON 对象"]) }
        let limit = max(0, Int(request.query["limit"] ?? "") ?? 20)
        let segments = request.path.split(separator: "/").map(String.init)

        switch (request.method, segments.first ?? "", segments.dropFirst().first) {
        case ("GET", "status", nil):
            return (200, status(appState))

        case ("GET", "wait", nil):
            // 等到所有任务结束且没有总结在跑，最多 timeout 秒（默认 1800）
            let deadline = Date().addingTimeInterval(Double(request.query["timeout"] ?? "") ?? 1800)
            while Date() < deadline, isBusy(appState) {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            var result = status(appState)
            result["timedOut"] = isBusy(appState)
            return (200, result)

        case ("POST", "search", nil):
            guard let keyword = body["keyword"] as? String, !keyword.isEmpty else {
                return (400, ["error": "缺少 keyword"])
            }
            do {
                let results = try await VideoSearch.search(
                    keyword: keyword,
                    platform: (body["platform"] as? String) == "youtube" ? .youtube : .bilibili,
                    count: body["count"] as? Int ?? 10,
                    sort: Self.sort(body["sort"] as? String)
                )
                return (200, ["results": results.map { Self.json($0) }])
            } catch {
                return (200, ["error": error.localizedDescription])
            }

        case ("POST", "submit", nil):
            // 与搜索面板的「转写所选」相同：{"urls": [...], "topic": "...", "autoSummarize": true}
            guard let urls = body["urls"] as? [String], !urls.isEmpty else {
                return (400, ["error": "缺少 urls"])
            }
            let titles = body["titles"] as? [String] ?? []
            let results = urls.enumerated().map { index, url in
                SearchResult(
                    id: url, url: url, title: index < titles.count ? titles[index] : nil,
                    duration: nil, uploader: nil, viewCount: nil
                )
            }
            let before = Set(appState.tasks.map(\.id))
            let wantsSummary = body["autoSummarize"] as? Bool ?? true
            let scheduled = appState.submit(
                searchResults: results,
                topic: body["topic"] as? String ?? "测试",
                autoSummarize: wantsSummary
            )
            let added = appState.tasks.filter { !before.contains($0.id) }.map { $0.id.uuidString }
            var response: [String: Any] = ["taskIDs": added, "summaryScheduled": scheduled]
            if wantsSummary && !scheduled {
                response["note"] = "没有安排自动总结：已有一批总结在进行，或找不到 claude 命令行"
            }
            return (200, response)

        case ("POST", "summarize", nil):
            let ids = (body["ids"] as? [String] ?? []).compactMap(UUID.init)
            guard !ids.isEmpty else { return (400, ["error": "缺少 ids"]) }
            guard appState.summarize(recordIDs: ids, topic: body["topic"] as? String ?? "测试") else {
                return (409, ["started": false, "error": "已有一批总结在进行"])
            }
            return (200, ["started": true])

        case ("GET", "history", nil):
            return (200, ["records": appState.history.records.prefix(limit).map { Self.json($0, full: false) }])

        case let ("GET", "history", id?):
            guard let record = UUID(uuidString: id).flatMap(appState.record(for:)) else {
                return (404, ["error": "没有这条记录"])
            }
            return (200, Self.json(record, full: true))

        case ("GET", "digests", nil):
            return (200, ["digests": appState.digests.records.prefix(limit).map { Self.json($0, full: false) }])

        case let ("GET", "digests", id?):
            guard let digest = appState.digests.records.first(where: { $0.id.uuidString == id }) else {
                return (404, ["error": "没有这份汇总"])
            }
            return (200, Self.json(digest, full: true))

        case ("POST", "ui", nil):
            return (200, applyUI(body, appState: appState))

        case ("GET", "ui", "screenshot"):
            // 把每个可见窗口（含搜索面板、提示框）各画成一张 PNG
            let dir = URL(fileURLWithPath: request.query["dir"] ?? NSTemporaryDirectory() + "v2t-ui", isDirectory: true)
            let name = request.query["name"] ?? "shot"
            return (200, ["files": Self.snapshotWindows(to: dir, name: name)])

        case ("GET", "settings", nil):
            return (200, Self.settingsJSON(appState.settingsStore.settings))

        case ("POST", "settings", nil):
            // 只改传进来的字段：{"maxBilibiliParts": 3, "diarizationEnabled": false}
            let known: Set<String> = ["model", "language", "cookiesPath", "diarizationEnabled",
                                      "preferSubtitles", "maxBilibiliParts"]
            let unknown = body.keys.filter { !known.contains($0) }.sorted()
            guard unknown.isEmpty else { return (400, ["error": "未知字段：\(unknown.joined(separator: "、"))"]) }
            var merged = Self.settingsJSON(appState.settingsStore.settings)
            body.forEach { merged[$0.key] = $0.value }
            guard let data = try? JSONSerialization.data(withJSONObject: merged),
                  let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
                return (400, ["error": "设置格式不对"])
            }
            appState.settingsStore.settings = settings
            return (200, Self.settingsJSON(settings))

        default:
            return (404, ["error": "没有这个接口", "endpoints": [
                "GET /status", "GET /wait?timeout=秒", "POST /search", "POST /submit", "POST /summarize",
                "GET /history?limit=N", "GET /history/{id}", "GET /digests?limit=N", "GET /digests/{id}",
                "GET /settings", "POST /settings", "POST /ui", "GET /ui/screenshot?dir=目录&name=前缀",
            ]])
        }
    }

    // MARK: - 界面控制与截图

    /// {"select": {"kind": "history" | "digest" | "task", "id": "…"} 或 "none", "search": true, "selectMode": false,
    ///  "summaryTab": true, "settings": true, "stopSummary": true, "appearance": "dark" | "light" | "system", "window": {"width": 900, "height": 600}}
    @MainActor
    private func applyUI(_ body: [String: Any], appState: AppState) -> [String: Any] {
        var applied: [String] = []
        if body["select"] as? String == "none" {
            appState.selection = nil
            applied.append("select")
        } else if let select = body["select"] as? [String: Any],
                  let id = (select["id"] as? String).flatMap(UUID.init) {
            switch select["kind"] as? String {
            case "history": appState.selection = .history(id)
            case "digest": appState.selection = .digest(id)
            default: appState.selection = .task(id)
            }
            applied.append("select")
        }
        if body["stopSummary"] as? Bool == true { appState.cancelSummary(); applied.append("stopSummary") }
        if let search = body["search"] as? Bool { appState.showSearch = search; applied.append("search") }
        if let selectMode = body["selectMode"] as? Bool { appState.selectMode = selectMode; applied.append("selectMode") }
        if body.keys.contains("summaryTab") {
            appState.forceSummaryTab = body["summaryTab"] as? Bool
            applied.append("summaryTab")
        }
        if let appearance = body["appearance"] as? String {
            NSApp.appearance = appearance == "dark" ? NSAppearance(named: .darkAqua)
                : appearance == "light" ? NSAppearance(named: .aqua) : nil
            applied.append("appearance")
        }
        if let settings = body["settings"] as? Bool {
            if settings {
                // macOS 14 起 showSettingsWindow: 不再可用，改用 MainView 注入的 openSettings
                NSApp.activate(ignoringOtherApps: true)
                appState.openSettingsAction?()
            } else {
                Self.settingsWindows().forEach { $0.close() }
            }
            applied.append("settings")
        }
        if let size = body["window"] as? [String: Any],
           let width = size["width"] as? Double, let height = size["height"] as? Double,
           let window = Self.mainWindow() {
            var frame = window.frame
            frame.origin.y += frame.height - height
            frame.size = NSSize(width: width, height: height)
            window.setFrame(frame, display: true)
            applied.append("window")
        }
        return ["applied": applied, "windows": NSApp.windows.filter(\.isVisible).map {
            ["title": $0.title, "width": $0.frame.width, "height": $0.frame.height, "sheet": $0.isSheet] as [String: Any]
        }]
    }

    @MainActor
    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && !$0.isSheet && !settingsWindows().contains($0) && $0.frame.width > 300 }
    }

    @MainActor
    private static func settingsWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.identifier?.rawValue.contains("Settings") == true || $0.identifier?.rawValue.contains("settings") == true }
    }

    /// 用视图自己的绘制结果截图，不需要屏幕录制权限，窗口在别的桌面也能画
    @MainActor
    private static func snapshotWindows(to dir: URL, name: String) -> [[String: Any]] {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return [["error": "无法创建目录：\(error.localizedDescription)"]]
        }
        var files: [[String: Any]] = []
        for (index, window) in NSApp.windows.enumerated() where window.isVisible && window.frame.width > 50 {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            let kind = window.isSheet ? "sheet" : settingsWindows().contains(window) ? "settings" : "window"
            let url = dir.appendingPathComponent("\(name)-\(kind)-\(index).png")
            do {
                try png.write(to: url, options: .atomic)
                files.append(["path": url.path, "title": window.title, "kind": kind,
                              "width": view.bounds.width, "height": view.bounds.height])
            } catch {
                files.append(["error": "写入失败：\(error.localizedDescription)", "path": url.path])
            }
        }
        return files
    }

    // MARK: - 序列化

    @MainActor
    private func isBusy(_ appState: AppState) -> Bool {
        appState.tasks.contains { !$0.stage.isFinished } || appState.batchSummary.isRunning
    }

    @MainActor
    private func status(_ appState: AppState) -> [String: Any] {
        let tasks: [[String: Any]] = appState.tasks.map { task in
            var item: [String: Any] = [
                "id": task.id.uuidString,
                "title": task.title,
                "source": task.source.displayName,
                "stage": task.stage.label,
                "transcriptSource": task.transcriptSource.rawValue,
                "diarized": task.diarized,
            ]
            if let progress = task.stage.progress { item["progress"] = progress }
            if case let .failed(message) = task.stage { item["error"] = message }
            if let transcript = task.transcript {
                item["characters"] = transcript.plainText.count
                item["partTitles"] = transcript.utterances.filter(\.isMarker).map(\.text)
            }
            return item
        }
        let phase: [String: Any]
        switch appState.batchSummary.phase {
        case .idle: phase = ["phase": "idle"]
        case let .waitingForTranscription(count): phase = ["phase": "waitingForTranscription", "count": count]
        case let .summarizing(done, total): phase = ["phase": "summarizing", "done": done, "total": total]
        case .digesting: phase = ["phase": "digesting"]
        case let .failed(message): phase = ["phase": "failed", "error": message]
        }
        return ["tasks": tasks, "batchSummary": phase, "busy": isBusy(appState)]
    }

    private static func sort(_ value: String?) -> SearchSort {
        switch value {
        case "views": return .views
        case "newest": return .newest
        default: return .relevance
        }
    }

    private static func json(_ result: SearchResult) -> [String: Any] {
        var item: [String: Any] = ["id": result.id, "url": result.url, "title": result.displayTitle]
        if let duration = result.duration { item["duration"] = duration }
        if let uploader = result.uploader { item["uploader"] = uploader }
        if let viewCount = result.viewCount { item["viewCount"] = viewCount }
        return item
    }

    private static func json(_ record: HistoryRecord, full: Bool) -> [String: Any] {
        var item: [String: Any] = [
            "id": record.id.uuidString,
            "title": record.title,
            "source": record.source,
            "date": ISO8601DateFormatter().string(from: record.date),
            "transcriptSource": record.transcriptSource?.rawValue ?? TranscriptSource.whisper.rawValue,
            "diarized": record.diarized,
            "characters": record.transcript.plainText.count,
            "hasSummary": record.summary != nil,
        ]
        if full {
            item["transcript"] = TranscriptExporter.render(
                record.transcript, showTimestamps: true, showSpeakers: record.diarized
            )
            item["summary"] = record.summary ?? NSNull()
        }
        return item
    }

    private static func json(_ digest: DigestRecord, full: Bool) -> [String: Any] {
        var item: [String: Any] = [
            "id": digest.id.uuidString,
            "title": digest.title,
            "date": ISO8601DateFormatter().string(from: digest.date),
            "videoTitles": digest.videoTitles,
        ]
        if full { item["markdown"] = digest.markdown }
        return item
    }

    private static func settingsJSON(_ settings: AppSettings) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(settings),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}
