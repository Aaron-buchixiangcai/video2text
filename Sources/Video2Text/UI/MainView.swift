import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var history: HistoryStore
    @State private var urlInput = ""
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            detail
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            inputBar
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
    }

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
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.title)
                                .lineLimit(1)
                            Text(record.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(SidebarItem.history(record.id))
                        .contextMenu {
                            Button("删除", role: .destructive) {
                                history.delete(record)
                                if appState.selection == .history(record.id) {
                                    appState.selection = nil
                                }
                            }
                        }
                    }
                }
            }
        }
    }

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
