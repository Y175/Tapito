import SwiftUI
import TapitoVoiceCore

/// Explicit entry and visible pause/end controls; the microphone never starts on launch.
struct VoiceSessionPanel: View {
    let controller: TapitoVoiceController
    @ObservedObject var session: VoiceSession
    @State private var entryError: String?
    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if session.state.phase.isActive {
                    if [.preparing, .executing, .interrupting].contains(session.state.phase) {
                        ProgressView().controlSize(.small).tint(.indigo)
                    } else { Image(systemName: session.state.phase == .speaking ? "waveform" : "mic.fill").foregroundStyle(.indigo) }
                    Text(title).font(.caption.weight(.semibold)).lineLimit(1)
                    Spacer()
                    if ![.executing, .speaking, .interrupting].contains(session.state.phase) {
                        Button(session.state.phase == .paused ? "恢复" : "暂停") {
                            if session.state.phase == .paused { perform { try await session.resume() } }
                            else { session.pause() }
                        }.disabled(session.state.phase == .preparing)
                    }
                    Button("结束", role: .destructive) { session.end() }.frame(minHeight: 44)
                } else {
                    Button { perform { try await controller.execute() } } label: {
                        Label("开始连续语音", systemImage: "waveform").font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                    }
                    Spacer()
                    Button { showingDetails = true } label: {
                        Image(systemName: "info.circle").foregroundStyle(.secondary).frame(width: 44, height: 44)
                    }.accessibilityLabel("语音与隐私说明")
                }
            }
            if let error = entryError ?? session.state.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            } else if [.listening, .paused].contains(session.state.phase) {
                Text(session.state.transcript.isEmpty ? "说出任务；等待新任务时可说“结束对话”退出。" : session.state.transcript)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 2)
        .accessibilityIdentifier("tapito.voice.controls")
        .popover(isPresented: $showingDetails) {
            VStack(alignment: .leading, spacing: 12) {
                Text("连续语音").font(.headline)
                Text("任务执行时关闭麦克风与音频；完成并播报后继续聆听。你可以随时点击“结束”。")
                Text("语音转写和任务所需屏幕内容会发送给所选模型供应商。")
                    .foregroundStyle(.secondary)
            }.font(.subheadline).padding(20).frame(idealWidth: 300)
                .presentationCompactAdaptation(.popover)
        }
    }
    private var title: String {
        switch session.state.phase {
        case .idle, .ended: return "连续语音"
        case .preparing: return "准备麦克风"
        case .listening: return "正在聆听"
        case .executing: return "正在执行 · 麦克风已关闭"
        case .interrupting: return "正在停止后续操作"
        case .speaking: return "正在播报"
        case .paused: return "语音已暂停"
        case .failed: return "需要处理"
        }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        entryError = nil
        Task { @MainActor in
            do { try await action() }
            catch is CancellationError { /* Explicit end/lock already publishes the terminal state. */ }
            catch { entryError = error.localizedDescription }
        }
    }
}
