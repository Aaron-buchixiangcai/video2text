import Foundation
import SwiftUI

enum SidebarItem: Hashable {
    case task(UUID)
    case history(UUID)
}

@MainActor
final class AppState: ObservableObject {
    @Published var tasks: [TranscriptionTask] = []
    @Published var selection: SidebarItem?
    @Published var ytDlpInstalled: Bool
    @Published var showSetup = false

    let coordinator = PipelineCoordinator()
    let history = HistoryStore()
    let settingsStore = SettingsStore()

    init() {
        AppPaths.ensureAll()
        ytDlpInstalled = YtDlpManager.isInstalled
        showSetup = !ytDlpInstalled
        coordinator.historyStore = history
    }

    func submit(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let task = TranscriptionTask(source: .remote(trimmed))
        enqueue(task)
    }

    func submit(fileURL: URL) {
        let task = TranscriptionTask(source: .localFile(fileURL))
        enqueue(task)
    }

    private func enqueue(_ task: TranscriptionTask) {
        tasks.insert(task, at: 0)
        selection = .task(task.id)
        coordinator.enqueue(task, settings: settingsStore.settings)
    }

    func cancel(_ task: TranscriptionTask) {
        coordinator.cancel(task)
    }

    func remove(_ task: TranscriptionTask) {
        coordinator.cancel(task)
        tasks.removeAll { $0.id == task.id }
        if selection == .task(task.id) { selection = nil }
    }

    func task(for id: UUID) -> TranscriptionTask? {
        tasks.first { $0.id == id }
    }

    func record(for id: UUID) -> HistoryRecord? {
        history.records.first { $0.id == id }
    }
}
