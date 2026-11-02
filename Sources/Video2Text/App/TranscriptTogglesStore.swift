import SwiftUI

/// 每条转录各自记住「带时间戳 / 分发言人」开关状态（按 id 区分，会话内保持）。
/// 存在 AppState 里、独立于视图，因此切到别的转录再切回来仍保留各自的选择。
@MainActor
final class TranscriptTogglesStore: ObservableObject {
    struct Toggles: Equatable {
        var showTimestamps = false
        var showSpeakers = true
    }

    /// 两个开关各自记录「用户是否手动切过」；没切过的那个跟随默认值，切一个不会把另一个的默认值固定下来
    private struct Overrides {
        var showTimestamps: Bool?
        var showSpeakers: Bool?
    }

    @Published private var store: [UUID: Overrides] = [:]

    /// speakersDefault：没手动切过时「分发言人」的初始状态（只有一位说话人时默认关）
    func toggles(for id: UUID, speakersDefault: Bool = true) -> Toggles {
        let overrides = store[id]
        return Toggles(
            showTimestamps: overrides?.showTimestamps ?? false,
            showSpeakers: overrides?.showSpeakers ?? speakersDefault
        )
    }

    func binding(for id: UUID, keyPath: WritableKeyPath<Toggles, Bool>, speakersDefault: Bool = true) -> Binding<Bool> {
        Binding(
            get: { self.toggles(for: id, speakersDefault: speakersDefault)[keyPath: keyPath] },
            set: { newValue in
                var overrides = self.store[id] ?? Overrides()
                if keyPath == \Toggles.showTimestamps {
                    overrides.showTimestamps = newValue
                } else {
                    overrides.showSpeakers = newValue
                }
                self.store[id] = overrides
            }
        )
    }
}
