import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var history: HistoryStore
    @ObservedObject var digests: DigestStore
    @ObservedObject var batchSummary: BatchSummaryRunner
    @State private var urlInput = ""
    @State private var dropTargeted = false

    // 批量总结：先让用户确认汇总标题
    @State private var askingSummaryTitle = false
    @State private var summaryTitle = ""

    // 历史栏多选 / 重命名 / 设置入口
    @State private var selectedHistory: Set<UUID> = []
    @State private var confirmBatchDelete = false
    @State private var showExportFormats = false
    @State private var renamingRecord: HistoryRecord?
    @State private var renameText = ""

    private var allHistorySelected: Bool {
        !history.records.isEmpty && selectedHistory.count == history.records.count
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 340)
        } detail: {
            detail
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        inputBar
                        summaryBanner
                    }
                }
        }
        .sheet(isPresented: $appState.showSearch) {
            SearchView(batchSummary: batchSummary)
                .environmentObject(appState)
        }
        .alert("总结选中的 \(selectedHistory.count) 条", isPresented: $askingSummaryTitle) {
            TextField("汇总标题", text: $summaryTitle)
            Button("取消", role: .cancel) {}
            Button("开始") { startBatchSummary() }
        } message: {
            Text("逐条写总结（已有的跳过），两条以上再生成一份汇总。用本机 Claude Code 的账号和额度。")
        }
        .dropDestination(for: URL.self) { urls, _ in
            let mediaURLs = urls.filter { $0.isFileURL }
            for url in mediaURLs {
                appState.submit(fileURL: url)
            }
            return !mediaURLs.isEmpty
        } isTargeted: { targeted in
            dropTargeted = targeted
        }
        .overlay {
            if dropTargeted {
                dropOverlay
            }
        }
        .sheet(isPresented: $appState.showSetup) {
            SetupView()
                .environmentObject(appState)
        }
        .alert("重命名", isPresented: renamingAlertPresented) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) { renamingRecord = nil }
            Button("确定") {
                if let record = renamingRecord {
                    history.rename(record, to: renameText)
                }
                renamingRecord = nil
            }
        } message: {
            Text("输入新的名称")
        }
        // 多选的勾选状态只在多选模式里有效；记录被删后也要从勾选里去掉
        .onChange(of: appState.selectMode) { _, isOn in
            if !isOn { selectedHistory.removeAll() }
        }
        .onChange(of: history.records.map(\.id)) { _, ids in
            selectedHistory.formIntersection(ids)
        }
        .onAppear { appState.openSettingsAction = { openSettings() } }
        .alert("删除选中的 \(selectedHistory.count) 条记录？", isPresented: $confirmBatchDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { performBatchDelete() }
        } message: {
            Text("此操作不可撤销。")
        }
    }

    // MARK: - 顶部输入栏

    private var inputBar: some View {
        HStack(spacing: 8) {
            // 占位文字要短：窗口最窄时输入框只有约 250pt，NSTextField 不会给占位文字加省略号
            TextField("粘贴视频链接（可多个）", text: $urlInput)
                .textFieldStyle(.roundedBorder)
                .help("支持抖音 / B站 / YouTube / 小红书，可一次粘贴多个链接")
                .onSubmit(submit)

            Button("转写", action: submit)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                appState.showSearch = true
            } label: {
                Label("搜索…", systemImage: "magnifyingglass")
            }
            .help("按关键词搜索 YouTube / B站 视频并批量转写")

            Button("打开文件…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.movie, .audio, .mpeg4Movie, .mp3]
                panel.allowsMultipleSelection = true
                if panel.runModal() == .OK {
                    for url in panel.urls {
                        appState.submit(fileURL: url)
                    }
                }
            }
        }
        .padding(10)
        .background(.bar)
    }

    private func submit() {
        appState.submit(urlString: urlInput)
        urlInput = ""
    }

    // MARK: - 批量总结进度条

    @ViewBuilder
    private var summaryBanner: some View {
        switch batchSummary.phase {
        case .idle:
            EmptyView()
        case let .waitingForTranscription(count):
            bannerRow("「\(bannerTopic)」这批 \(count) 个视频转写完后会自动总结", showsSpinner: false)
        case let .summarizing(done, total):
            // 几篇同时写，第一篇写完前完成数一直是 0，所以写明有几篇正在写
            bannerRow("正在总结「\(bannerTopic)」：已完成 \(done)/\(total)，\(min(3, total - done)) 篇正在写", showsSpinner: true)
        case .digesting:
            bannerRow("正在为「\(bannerTopic)」生成汇总", showsSpinner: true)
        case let .failed(message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .textSelection(.enabled)
                    .lineLimit(6)
                Spacer()
                Button("关闭") { batchSummary.dismissError() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.orange.opacity(0.12))
        }
    }

    private var bannerTopic: String { TitleFormatter.shortDisplay(batchSummary.topic, maxCharacters: 16) }

    private func bannerRow(_ text: String, showsSpinner: Bool) -> some View {
        HStack(spacing: 6) {
            if showsSpinner {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("停止") { appState.cancelSummary() }
                .controlSize(.small)
                .help("停止这批总结；已写好的单篇总结会保留")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.1))
    }

    // MARK: - 侧栏

    private var sidebar: some View {
        List(selection: $appState.selection) {
            if !appState.tasks.isEmpty {
                Section("任务") {
                    ForEach(appState.tasks) { task in
                        TaskRowView(task: task)
                            .tag(SidebarItem.task(task.id))
                            .contextMenu {
                                if !task.stage.isFinished {
                                    Button("取消") { appState.cancel(task) }
                                }
                                Button("移除", role: .destructive) { appState.remove(task) }
                            }
                    }
                }
            }
            if !digests.records.isEmpty {
                Section("汇总") {
                    ForEach(digests.records) { digest in
                        // 两行都放进 Label 的标题里，第二行才和标题左对齐，不会缩到图标下面
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(TitleFormatter.display(digest.title))
                                    .lineLimit(1)
                                Text("\(digest.recordIDs.count) 个视频 · \(digest.date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "sparkles")
                        }
                        .help(digest.title)
                        .tag(SidebarItem.digest(digest.id))
                        .contextMenu {
                            Button("删除", role: .destructive) {
                                digests.delete(digest)
                                if appState.selection == .digest(digest.id) {
                                    appState.selection = nil
                                }
                            }
                        }
                    }
                }
            }
            if !history.records.isEmpty {
                Section(appState.selectMode ? "历史 · 已选 \(selectedHistory.count)/\(history.records.count)" : "历史") {
                    ForEach(history.records) { record in
                        historyRow(record)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { sidebarBottomBar }
    }

    @ViewBuilder
    private func historyRow(_ record: HistoryRecord) -> some View {
        if appState.selectMode {
            Button {
                toggleSelection(record.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: selectedHistory.contains(record.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selectedHistory.contains(record.id) ? Color.accentColor : .secondary)
                    historyRowText(record)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu { recordContextMenu(record) }
        } else {
            historyRowText(record)
                .tag(SidebarItem.history(record.id))
                .contextMenu { recordContextMenu(record) }
        }
    }

    private func historyRowText(_ record: HistoryRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // 按侧栏宽度截断，悬停显示完整标题
            Text(TitleFormatter.display(record.title))
                .lineLimit(1)
            Text(record.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help(record.title)
    }

    @ViewBuilder
    private func recordContextMenu(_ record: HistoryRecord) -> some View {
        Button("重命名") {
            renameText = record.title
            renamingRecord = record
        }
        Button("删除", role: .destructive) {
            history.delete(record)
            if appState.selection == .history(record.id) {
                appState.selection = nil
            }
        }
    }

    private var sidebarBottomBar: some View {
        HStack(spacing: 0) {
            if appState.selectMode {
                // 与进入多选的 checklist 图标区分开，并按当前状态显示下一步动作
                barIconButton(allHistorySelected ? "checklist.unchecked" : "checklist.checked",
                              help: allHistorySelected ? "取消全选" : "全选") {
                    toggleSelectAll()
                }
                Spacer()
                barIconButton("sparkles", help: "总结选中的 \(selectedHistory.count) 项") {
                    summaryTitle = defaultSummaryTitle()
                    askingSummaryTitle = true
                }
                .disabled(selectedHistory.isEmpty || batchSummary.isRunning)
                Spacer()
                barIconButton("square.and.arrow.up", help: "导出选中的 \(selectedHistory.count) 项") {
                    showExportFormats = true
                }
                .disabled(selectedHistory.isEmpty)
                .confirmationDialog("选择导出格式", isPresented: $showExportFormats, titleVisibility: .visible) {
                    ForEach(ExportFileType.allCases) { type in
                        Button(type.rawValue) { batchExport(type) }
                    }
                }
                Spacer()
                barIconButton("trash", help: "删除选中的 \(selectedHistory.count) 项", role: .destructive) {
                    confirmBatchDelete = true
                }
                .disabled(selectedHistory.isEmpty)
                Spacer()
                barIconButton("checkmark", help: "完成") { exitSelectMode() }
            } else {
                SettingsLink {
                    barIconLabel("gearshape")
                }
                .buttonStyle(.borderless)
                .help("设置")
                Spacer()
                barIconButton("checklist", help: "选择") { appState.selectMode = true }
                    .disabled(history.records.isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// 统一尺寸的图标内容：所有底栏控件都用它，保证大小完全一致
    private func barIconLabel(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16))
            .frame(width: 30, height: 26)
            .contentShape(Rectangle())
    }

    private func barIconButton(
        _ symbol: String,
        help: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            barIconLabel(symbol)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    // MARK: - 多选操作

    private var renamingAlertPresented: Binding<Bool> {
        Binding(
            get: { renamingRecord != nil },
            set: { if !$0 { renamingRecord = nil } }
        )
    }

    private func toggleSelection(_ id: UUID) {
        if selectedHistory.contains(id) {
            selectedHistory.remove(id)
        } else {
            selectedHistory.insert(id)
        }
    }

    private func toggleSelectAll() {
        if allHistorySelected {
            selectedHistory.removeAll()
        } else {
            selectedHistory = Set(history.records.map(\.id))
        }
    }

    private func exitSelectMode() {
        appState.selectMode = false
        selectedHistory.removeAll()
    }

    private func defaultSummaryTitle() -> String {
        if selectedHistory.count == 1,
           let record = history.records.first(where: { selectedHistory.contains($0.id) }) {
            return record.title
        }
        return "\(selectedHistory.count) 个视频的汇总 \(Date().formatted(date: .numeric, time: .omitted))"
    }

    private func startBatchSummary() {
        let ids = history.records.filter { selectedHistory.contains($0.id) }.map(\.id)
        let title = summaryTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.summarize(recordIDs: ids, topic: title.isEmpty ? defaultSummaryTitle() : title)
        exitSelectMode()
    }

    private func performBatchDelete() {
        if case let .history(id)? = appState.selection, selectedHistory.contains(id) {
            appState.selection = nil
        }
        history.delete(ids: selectedHistory)
        exitSelectMode()
    }

    private func batchExport(_ type: ExportFileType) {
        let records = history.records.filter { selectedHistory.contains($0.id) }
        guard !records.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "导出到此文件夹"
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        var usedNames = Set<String>()
        var failures: [String] = []
        for record in records {
            // 历史批量导出无逐条开关上下文：导出完整内容（带时间戳；有说话人则带说话人）
            let data = TranscriptExporter.exportData(
                record.transcript, type: type,
                showTimestamps: true, showSpeakers: record.diarized,
                title: record.title
            )
            // 必须用净化过的主干：标题含 "/" 等会被当作路径分隔符导致写盘失败
            let stem = TranscriptExporter.safeFileStem(record.title)
            var name = "\(stem).\(type.fileExtension)"
            var n = 2
            while usedNames.contains(name)
                || FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
                name = "\(stem) \(n).\(type.fileExtension)"
                n += 1
            }
            usedNames.insert(name)
            do {
                try data.write(to: folder.appendingPathComponent(name), options: .atomic)
            } catch {
                failures.append(record.title)
            }
        }
        exitSelectMode()

        if !failures.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "有 \(failures.count) 条导出失败"
            alert.informativeText = failures.prefix(10).joined(separator: "\n")
                + (failures.count > 10 ? "\n…" : "")
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    // MARK: - 详情区

    @ViewBuilder
    private var detail: some View {
        switch appState.selection {
        case let .task(id):
            if let task = appState.task(for: id) {
                TaskDetailView(task: task)
                    .id(task.id)
            } else {
                placeholder
            }
        case let .history(id):
            if let record = appState.record(for: id) {
                TranscriptView(
                    id: record.id,
                    transcript: record.transcript,
                    diarized: record.diarized,
                    title: record.title,
                    summary: record.summary,
                    isSummarizing: batchSummary.isRunning,
                    onSummarize: {
                        appState.summarize(recordIDs: [record.id], topic: record.title)
                    }
                )
                .id(record.id)
            } else {
                placeholder
            }
        case let .digest(id):
            if let digest = digests.record(for: id) {
                DigestView(digest: digest)
                    .id(digest.id)
            } else {
                placeholder
            }
        case nil:
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.bubble")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("粘贴视频链接，或把视频文件拖进窗口")
                .foregroundStyle(.secondary)
            Text("点「搜索…」可按关键词批量找视频；点侧栏右下角的 \(Image(systemName: "checklist")) 多选历史，可批量总结")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dropOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accentColor.opacity(0.1))
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
            Text("松开以转写视频")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
        }
        .padding(16)
        .allowsHitTesting(false)
    }
}
