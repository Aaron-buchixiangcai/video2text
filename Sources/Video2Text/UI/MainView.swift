import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var history: HistoryStore
    @State private var urlInput = ""
    @State private var dropTargeted = false

    // 历史栏多选 / 重命名 / 设置入口
    @State private var selectMode = false
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
                    inputBar
                }
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
            TextField("粘贴视频链接（抖音 / B站 / YouTube ...）", text: $urlInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)

            Button("转写", action: submit)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

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
            if !history.records.isEmpty {
                Section("历史") {
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
        if selectMode {
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
            Text(TitleFormatter.shortDisplay(record.title))
                .lineLimit(1)
            Text(record.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
            if selectMode {
                barIconButton("checklist", help: allHistorySelected ? "取消全选" : "全选") {
                    toggleSelectAll()
                }
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
                barIconButton("checklist", help: "选择") { selectMode = true }
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
        selectMode = false
        selectedHistory.removeAll()
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
                    title: record.title
                )
                .id(record.id)
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
