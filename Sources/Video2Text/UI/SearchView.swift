import SwiftUI

/// 按关键词搜索视频，勾选后批量转写；可选转写完自动总结
struct SearchView: View {
    @EnvironmentObject var appState: AppState
    /// 直接观察：已有总结在跑时，下方「自动总结」开关要跟着变灰
    @ObservedObject var batchSummary: BatchSummaryRunner
    @Environment(\.dismiss) private var dismiss

    @State private var keyword = ""
    @State private var platform: SearchPlatform = .bilibili
    @State private var sort: SearchSort = .relevance
    @State private var count = 10
    @State private var results: [SearchResult] = []
    @State private var selected: Set<String> = []
    @State private var searching = false
    @State private var status: String?
    @State private var errorMessage: String?
    @State private var autoSummarize = true

    private let claudeAvailable = Summarizer.locateClaude() != nil
    private var canAutoSummarize: Bool { claudeAvailable && !batchSummary.isRunning }

    private var trimmedKeyword: String {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var allSelected: Bool {
        !results.isEmpty && selected.count == results.count
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            content
            Divider()
            footer
        }
        // 主窗口最小高度 480，弹窗要比它矮，否则底部按钮会被挡住
        .frame(width: 640, height: 440)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Picker("平台", selection: $platform) {
                ForEach(SearchPlatform.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 130)

            TextField("搜索关键词", text: $keyword)
                .textFieldStyle(.roundedBorder)
                .onSubmit(search)

            Picker("排序", selection: $sort) {
                ForEach(platform.supportedSorts) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 96)
            .onChange(of: platform) { _, newPlatform in
                if !newPlatform.supportedSorts.contains(sort) { sort = .relevance }
            }

            Picker("数量", selection: $count) {
                ForEach([5, 10, 20, 30], id: \.self) { Text("\($0) 条").tag($0) }
            }
            .labelsHidden()
            .frame(width: 80)

            Button("搜索", action: search)
                .disabled(trimmedKeyword.isEmpty || searching)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if searching {
            VStack(spacing: 12) {
                ProgressView()
                Text(status ?? "搜索中…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            Text(errorMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            Text(platform == .bilibili
                 ? "输入关键词，搜索 B站视频。\n短时间内多次搜索可能被 B站限流，过几分钟再试即可。"
                 : "输入关键词，搜索 YouTube 视频")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(results) { result in
                Button {
                    toggle(result.id)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selected.contains(result.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(result.id) ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.displayTitle)
                                .lineLimit(2)
                            if let detail = detailText(result) {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if !results.isEmpty {
                Button(allSelected ? "取消全选" : "全选", action: toggleAll)
            }
            // 不能总结时显示为未勾选，避免看起来会总结、实际不会
            Toggle("转写完后自动总结并生成汇总", isOn: canAutoSummarize ? $autoSummarize : .constant(false))
                .disabled(!canAutoSummarize)
                .help(!claudeAvailable ? "未找到 claude 命令行，无法总结"
                      : batchSummary.isRunning ? "已有一批总结在进行；这批转写完后可在历史里多选再总结"
                      : "用本机 Claude Code 的账号写总结")
            if claudeAvailable && batchSummary.isRunning {
                Text("（已有一批总结在进行）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("转写所选（\(selected.count)）", action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
        }
        .padding(12)
    }

    private func detailText(_ result: SearchResult) -> String? {
        let parts = [result.viewCountText, result.duration.map(formatTimestamp), result.uploader].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func toggleAll() {
        selected = allSelected ? [] : Set(results.map(\.id))
    }

    private func search() {
        guard !trimmedKeyword.isEmpty, !searching else { return }
        searching = true
        status = nil
        errorMessage = nil
        results = []
        let keyword = trimmedKeyword, platform = platform, count = count, sort = sort
        Task {
            defer { searching = false }
            do {
                let found = try await VideoSearch.search(
                    keyword: keyword, platform: platform, count: count, sort: sort,
                    onRetry: { seconds in
                        Task { @MainActor in status = "B站限流，\(seconds) 秒后重试…" }
                    }
                )
                results = found
                selected = Set(found.map(\.id))
                if found.isEmpty { errorMessage = "没有搜到视频" }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func submit() {
        let chosen = results.filter { selected.contains($0.id) }
        appState.submit(
            searchResults: chosen,
            topic: trimmedKeyword.isEmpty ? "搜索结果" : trimmedKeyword,
            autoSummarize: autoSummarize && canAutoSummarize
        )
        dismiss()
    }
}
