import SwiftUI

struct TaskRowView: View {
    @ObservedObject var task: TranscriptionTask

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(TitleFormatter.shortDisplay(task.title))
                .lineLimit(1)

            HStack(spacing: 6) {
                stageBadge
                if let progress = task.stage.progress {
                    ProgressView(value: progress)
                        .controlSize(.small)
                } else if !task.stage.isFinished {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var stageBadge: some View {
        switch task.stage {
        case .completed:
            Label("完成", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed:
            Label("失败", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        case .cancelled:
            Label("已取消", systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        default:
            Text(task.stage.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct TaskDetailView: View {
    @ObservedObject var task: TranscriptionTask

    var body: some View {
        if let transcript = task.transcript {
            VStack(spacing: 0) {
                if case .diarizing = task.stage {
                    banner("正在分离说话人，下方为初步文字稿…")
                }
                TranscriptView(
                    transcript: transcript,
                    diarized: task.diarized,
                    title: task.title
                )
            }
        } else {
            VStack(spacing: 16) {
                switch task.stage {
                case let .failed(message):
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.red)
                    Text("处理失败")
                        .font(.headline)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: 480)
                case .cancelled:
                    Text("任务已取消")
                        .foregroundStyle(.secondary)
                default:
                    ProgressView(value: task.stage.progress)
                        .progressViewStyle(.circular)
                    Text(task.stage.label + progressSuffix)
                        .font(.headline)
                    Text(TitleFormatter.shortDisplay(task.title))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: 480)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var progressSuffix: String {
        if let p = task.stage.progress, p > 0 {
            return "  \(Int(p * 100))%"
        }
        return ""
    }

    private func banner(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.yellow.opacity(0.15))
    }
}
