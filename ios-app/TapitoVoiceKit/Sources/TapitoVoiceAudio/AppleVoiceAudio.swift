#if os(iOS)
import AVFoundation
import Foundation
import Speech
import TapitoVoiceCore

/// The real-time audio callback only appends to the current recognition request.
private final class RecognitionInput: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var receivedAudio = false
    private var lastFrameTime: TimeInterval?
    func replace(_ next: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); defer { lock.unlock() }; request = next; receivedAudio = false
    }
    func append(_ buffer: AVAudioPCMBuffer) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let request, buffer.frameLength > 0 else { return false }
        lastFrameTime = ProcessInfo.processInfo.systemUptime
        request.append(buffer)
        let first = !receivedAudio; receivedAudio = true
        return first
    }
    func hasRecentFrames(since started: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ProcessInfo.processInfo.systemUptime - max(started, lastFrameTime ?? started) < 3
    }
}

/// On-device Mandarin capture and output-only speech, never active during device execution.
@MainActor public final class AppleVoiceAudio: NSObject, VoiceAudio, AVSpeechSynthesizerDelegate {
    private let recognizer: SFSpeechRecognizer?
    private let beforeActivation: @MainActor () async throws -> Void
    /// Fixed metadata only; no transcription, response or raw audio.
    private let diagnostic: @MainActor (String) -> Void
    private let input = RecognitionInput()
    private let engine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private var events: (@MainActor (VoiceAudioEvent) -> Void)?
    private var recognition: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var silence: Task<Void, Never>?
    private var captureMonitor: Task<Void, Never>?
    private var generation = UUID()
    private var segment = UUID()
    private var lastText = ""
    private var tapped = false
    private var active = false
    private var ownsSession = false
    private var playback: (utterance: AVSpeechUtterance, id: UUID)?
    private var observers: [NSObjectProtocol] = []

    /// The hook lets the host release its old playback-only audio owner first.
    public init(beforeActivation: @escaping @MainActor () async throws -> Void = {},
                diagnostic: @escaping @MainActor (String) -> Void = { _ in }) {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        self.beforeActivation = beforeActivation; self.diagnostic = diagnostic
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notice in
                let interrupted = notice.name == AVAudioSession.interruptionNotification &&
                    (notice.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue == AVAudioSession.InterruptionType.began.rawValue
                let lostRoute = notice.name == AVAudioSession.routeChangeNotification &&
                    (notice.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                let reset = notice.name == AVAudioSession.mediaServicesWereResetNotification
                if interrupted || lostRoute || reset {
                    Task { @MainActor in
                        guard let self, self.active || self.ownsSession else { return }
                        self.events?(.failure(lostRoute ? "音频设备已断开，请重新开始语音对话" : "语音被系统中断，请重新开始对话"))
                    }
                }
            })
        }
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    /// Complete authorization before the host creates its recording Live Activity.
    public func prepare() async throws {
        guard !active else { throw error("语音采集已启动") }
        let token = UUID(); generation = token
        // Reuse a granted permission; repeated system authorization requests delay Action Button starts.
        if AVAudioApplication.shared.recordPermission != .granted {
            guard await AVAudioApplication.requestRecordPermission() else { throw error("请在系统设置中允许 Tapito 使用麦克风") }
        }
        guard generation == token else { throw CancellationError() }
        var authorization = SFSpeechRecognizer.authorizationStatus()
        if authorization == .notDetermined {
            authorization = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        guard generation == token else { throw CancellationError() }
        guard authorization == .authorized else { throw error("请在系统设置中允许 Tapito 使用语音识别") }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw error("当前设备的中文离线语音识别不可用，请检查系统语言与语音资源")
        }
    }

    /// Acquire input only after permission and the host's required presentation are ready.
    public func start(events: @escaping @MainActor (VoiceAudioEvent) -> Void) async throws {
        guard !active else { throw error("语音采集已启动") }
        guard AVAudioApplication.shared.recordPermission == .granted,
              SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw error("语音权限已改变，请在 Tapito 中重新授权")
        }
        let token = UUID(); generation = token
        self.events = events
        try await beforeActivation()
        guard generation == token else { throw CancellationError() }
        do {
            let session = AVAudioSession.sharedInstance()
            ownsSession = true
            // Listening owns input exclusively. The voice coordinator fully releases
            // this session before dispatching a task; mixing cannot prevent error 9022.
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            try engine.inputNode.setVoiceProcessingEnabled(false)
            guard session.mode == .default, session.categoryOptions.contains(.mixWithOthers),
                  !engine.inputNode.isVoiceProcessingEnabled else {
                throw error("语音音频配置未生效，未开始执行任务")
            }
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw error("麦克风没有有效音频输入") }
            active = true
            startSegment()
            let pipe = input
            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                if pipe.append(buffer) {
                    Task { @MainActor in
                        guard let self, self.generation == token, self.active else { return }
                        self.events?(.captureActive(true))
                    }
                }
            }
            tapped = true
            engine.prepare(); try engine.start()
            diagnostic("voice.audio mode=capture engineRunning=true")
            let started = ProcessInfo.processInfo.systemUptime
            captureMonitor = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self, self.active, self.generation == token else { return }
                    guard self.engine.isRunning, self.input.hasRecentFrames(since: started) else {
                        self.events?(.failure("麦克风采集已停止，请重新开始语音对话")); return
                    }
                }
            }
        } catch {
            let original = error
            do { try stop() }
            catch { throw self.error(original.localizedDescription + "；音频释放失败：" + error.localizedDescription) }
            throw original
        }
    }

    /// Stops recording before deactivation, including permission/startup cancellation.
    public func stop() throws {
        generation = UUID(); segment = UUID(); active = false
        silence?.cancel(); silence = nil
        captureMonitor?.cancel(); captureMonitor = nil
        input.replace(nil); request?.endAudio(); request = nil
        recognition?.cancel(); recognition = nil
        stopSpeaking(); engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        events?(.captureActive(false)); events = nil
        if ownsSession {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            ownsSession = false
        }
        diagnostic("voice.audio mode=released engineRunning=\(engine.isRunning) tapped=\(tapped) sessionOwned=\(ownsSession)")
    }

    /// Acquire output only after the screen-control run has completely drained.
    public func preparePlayback(events: @escaping @MainActor (VoiceAudioEvent) -> Void) async throws {
        guard !active, !ownsSession, !engine.isRunning, !tapped else {
            throw error("录音尚未释放，未开始播报")
        }
        let token = UUID(); generation = token
        self.events = events
        try await beforeActivation()
        guard generation == token else { throw CancellationError() }
        do {
            let session = AVAudioSession.sharedInstance()
            ownsSession = true
            try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
            try session.setActive(true)
            diagnostic("voice.audio mode=playback engineRunning=false")
        } catch {
            let original = error
            do { try stop() }
            catch { throw self.error(original.localizedDescription + "；音频释放失败：" + error.localizedDescription) }
            throw original
        }
    }

    /// Speech never shares a microphone session; new utterances wait until playback finishes.
    public func speak(_ text: String) throws -> UUID {
        guard ownsSession, !active, !engine.isRunning else { throw error("播报音频状态无效") }
        guard let voice = AVSpeechSynthesisVoice(language: "zh-CN") else { throw error("中文播报语音不可用") }
        stopSpeaking()
        let utterance = AVSpeechUtterance(string: text), id = UUID()
        utterance.voice = voice
        playback = (utterance, id); synthesizer.speak(utterance)
        return id
    }
    public func stopSpeaking() { playback = nil; synthesizer.stopSpeaking(at: .immediate) }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, let playback = self.playback, playback.utterance === utterance else { return }
            self.playback = nil; self.events?(.playbackFinished(playback.id))
        }
    }

    private func startSegment() {
        guard active, let recognizer else { return }
        segment = UUID(); let token = segment
        lastText = ""; silence?.cancel(); silence = nil
        request?.endAudio(); recognition?.cancel()
        let next = SFSpeechAudioBufferRecognitionRequest()
        next.requiresOnDeviceRecognition = true; next.shouldReportPartialResults = true
        next.contextualStrings = ["Tapito", "结束对话"]
        next.taskHint = .dictation; request = next; input.replace(next)
        recognition = recognizer.recognitionTask(with: next) { [weak self] result, failure in
            // Extract immutable text before crossing back to the session actor.
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true
            let failureMessage = failure.map { "\(($0 as NSError).domain) \(($0 as NSError).code)：\($0.localizedDescription)" }
            Task { @MainActor in
                guard let self, self.active, self.segment == token else { return }
                if let text, !text.isEmpty {
                    if text != self.lastText {
                        self.lastText = text; self.events?(.partial(text))
                        self.silence?.cancel()
                        self.silence = Task { [weak self] in
                            do { try await Task.sleep(for: .milliseconds(1_100)) } catch { return }
                            guard let self, self.active, self.segment == token else { return }
                            self.finishSegment()
                        }
                    }
                    if final { self.finishSegment(); return }
                } else if final { self.startSegment(); return }
                if let failureMessage { self.events?(.failure("语音识别中断，未自动提交未完成的听写。\(failureMessage)")) }
            }
        }
    }
    private func finishSegment() {
        let text = lastText, previous = segment
        if !text.isEmpty { events?(.utterance(text)) }
        // Submitting a turn synchronously stops capture. Never restart recognition afterward.
        if active, segment == previous { startSegment() }
    }
    private func error(_ message: String) -> NSError {
        NSError(domain: "Tapito.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
#endif
