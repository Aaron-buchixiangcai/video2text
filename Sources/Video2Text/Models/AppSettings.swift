import Foundation

struct AppSettings: Codable, Equatable {
    var model: String = Transcriber.defaultModel
    /// "zh" / "en" / "auto"
    var language: String = "zh"
    /// 国内网络使用 hf-mirror.com 下载模型
    var useMirror: Bool = false
    var cookiesPath: String?
    var diarizationEnabled: Bool = true

    var languageOrNil: String? { language == "auto" ? nil : language }
    var endpoint: String? { useMirror ? "https://hf-mirror.com" : nil }
    var cookiesURL: URL? {
        guard let cookiesPath, !cookiesPath.isEmpty else { return nil }
        return URL(fileURLWithPath: (cookiesPath as NSString).expandingTildeInPath)
    }

    static let availableModels: [(id: String, label: String)] = [
        ("openai_whisper-large-v3-v20240930_626MB", "Large v3 Turbo 量化（626MB，推荐）"),
        ("openai_whisper-large-v3_947MB", "Large v3 量化（947MB，中文更准）"),
        ("openai_whisper-large-v3", "Large v3 完整（~3GB，最准最慢）"),
        ("openai_whisper-small", "Small（~500MB，快但中文较弱）"),
    ]
}

@MainActor
final class SettingsStore: ObservableObject {
    private static let key = "appSettings"

    @Published var settings: AppSettings {
        didSet { save() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
