import SwiftUI

/// 每条转录各自记住「带时间戳 / 分发言人」开关状态（按 id 区分，会话内保持）。
/// 存在 AppState 里、独立于视图，因此切到别的转录再切回来仍保留各自的选择。
@MainActor
final class TranscriptTogglesStore: ObservableObject {
    struct Toggles: Equatable {
        var showTimestamps = false
        var showSpeakers = true
    }

    @Published private var store: [UUID: Toggles] = [:]

    func toggles(for id: UUID) -> Toggles {
        store[id] ?? Toggles()
    }

    func binding(for id: UUID, keyPath: WritableKeyPath<Toggles, Bool>) -> Binding<Bool> {
        Binding(
            get: { (self.store[id] ?? Toggles())[keyPath: keyPath] },
            set: { newValue in
                var current = self.store[id] ?? Toggles()
                current[keyPath: keyPath] = newValue
                self.store[id] = current
            }
        )
    }
}
