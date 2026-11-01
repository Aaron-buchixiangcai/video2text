import Foundation

struct AppSettings: Codable, Equatable {
    var model: String = Transcriber.defaultModel
    /// "zh" / "en" / "auto"
    var language: String = "zh"
    var cookiesPath: String?
    var diarizationEnabled: Bool = true
    /// YouTube 视频有字幕时直接用字幕，不下载音频转写
    var preferSubtitles: Bool = true

    var languageOrNil: String? { language == "auto" ? nil : language }
    var cookiesURL: URL? {
        guard let cookiesPath else { return nil }
        let trimmed = cookiesPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        // 仅接受绝对路径、可读的普通文件。目录、相对路径和旧的误填值会被忽略，
        // 避免 yt-dlp 把它们当 cookies 文件并尝试写回。
        guard expanded.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true,
              FileManager.default.isReadableFile(atPath: url.path) else {
            return nil
        }
        return url
    }

    static let availableModels: [(id: String, label: String)] = [
        ("openai_whisper-large-v3-v20240930_626MB", "Large v3 Turbo 量化（626MB，推荐）"),
        ("openai_whisper-large-v3_947MB", "Large v3 量化（947MB，中文更准）"),
        ("openai_whisper-large-v3", "Large v3 完整（~3GB，最准最慢）"),
        ("openai_whisper-small", "Small（~500MB，快但中文较弱）"),
    ]
}

extension AppSettings {
    /// 逐个字段 decodeIfPresent：旧版本存下的设置缺新字段时沿用默认值，不整体作废
    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? model
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? language
        cookiesPath = try container.decodeIfPresent(String.self, forKey: .cookiesPath)
        diarizationEnabled = try container.decodeIfPresent(Bool.self, forKey: .diarizationEnabled) ?? diarizationEnabled
        preferSubtitles = try container.decodeIfPresent(Bool.self, forKey: .preferSubtitles) ?? preferSubtitles
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    private static let key = "appSettings"

    @Published var settings: AppSettings {
        didSet { save() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           var decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            if decoded.cookiesPath != nil, decoded.cookiesURL == nil {
                decoded.cookiesPath = nil
                if let cleaned = try? JSONEncoder().encode(decoded) {
                    UserDefaults.standard.set(cleaned, forKey: Self.key)
                }
            }
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
