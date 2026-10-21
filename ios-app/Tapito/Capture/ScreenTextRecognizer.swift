import Foundation
import Vision
import ImageIO
import CoreML

/// Local recognition returns text and geometry, never a control tree or input focus.
protocol ScreenTextRecognizing: Sendable {
    func recognize(_ frame: FrameImage) async throws -> ScreenTextObservation
}

/// Vision runs on this actor's executor, keeping recognition work off the main UI actor.
actor VisionScreenTextRecognizer: ScreenTextRecognizing {
    private let diagnostic: @Sendable (String) async -> Void
    init(diagnostic: @escaping @Sendable (String) async -> Void = { _ in }) { self.diagnostic = diagnostic }

    func recognize(_ frame: FrameImage) async throws -> ScreenTextObservation {
        try Task.checkCancellation()
        let started = ContinuousClock.now
        guard let source = CGImageSourceCreateWithData(frame.png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == frame.width, image.height == frame.height else {
            throw AppError.protocolViolation("OCR 截图无法解码或像素尺寸不一致")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        if let orientation = properties?[kCGImagePropertyOrientation] as? NSNumber, orientation.intValue != 1 {
            throw AppError.protocolViolation("OCR 截图带有未应用的旋转，不能作为点击参照")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let languages = ["zh-Hans", "en-US"]
        do {
            let supported = try request.supportedRecognitionLanguages()
            guard languages.allSatisfy(supported.contains) else { throw AppError.unavailable("本机 Vision 不支持所需的中英文识别") }
            request.recognitionLanguages = languages
            // Phone-control runs can be backgrounded. Do not let Vision select Metal/GPU work
            // whose foreground eligibility differs from the run's capture/input authorization.
            let stages = try request.supportedComputeStageDevices
            guard !stages.isEmpty else { throw AppError.unavailable("Vision 未提供 OCR 计算设备") }
            for (stage, devices) in stages {
                guard let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) else {
                    throw AppError.unavailable("本机 OCR 计算阶段不支持 CPU，不能保证后台识别")
                }
                request.setComputeDevice(cpu, for: stage)
            }
            try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        } catch let error as AppError { throw error }
        catch {
            let failure = error as NSError
            throw AppError.unavailable("本机 OCR 执行失败（\(failure.domain)/\(failure.code)）；未自动切换模型")
        }
        try Task.checkCancellation()
        guard let results = request.results else { throw AppError.protocolViolation("Vision 未返回 OCR 结果") }
        let sorted = results.sorted {
            $0.boundingBox.midY == $1.boundingBox.midY ? $0.boundingBox.minX < $1.boundingBox.minX : $0.boundingBox.midY > $1.boundingBox.midY
        }
        var candidates: [ScreenTextCandidate] = []
        var excluded = 0, adjusted = 0
        for (index, observation) in sorted.enumerated() {
            guard let text = observation.topCandidates(1).first, !text.string.isEmpty,
                  text.confidence.isFinite, (0...1).contains(text.confidence) else { throw AppError.protocolViolation("Vision 文字候选无效") }
            let box = observation.boundingBox
            let checked = ScreenTextCandidate.PixelBounds.checked(box, width: frame.width, height: frame.height)
            if checked.bounds == nil || checked.adjusted {
                // Geometry and ordinal only: never persist recognized text or screenshot bytes in diagnostics.
                await diagnostic("ocr.geometry frame=\(frame.id) candidate=\(index + 1) raw=\(box.origin.x),\(box.origin.y),\(box.width),\(box.height) size=\(frame.width)x\(frame.height) disposition=\(checked.reason ?? "subpixel_adjustment")")
            }
            guard let bounds = checked.bounds else { excluded += 1; continue }
            if checked.adjusted { adjusted += 1 }
            candidates.append(.init(id: "text-\(index + 1)", text: text.string, confidence: text.confidence, bounds: bounds))
        }
        try Task.checkCancellation()
        await diagnostic("ocr.completed frame=\(frame.id) recognized=\(results.count) returned=\(candidates.count) excluded=\(excluded) adjusted=\(adjusted)")
        let time = started.duration(to: .now).components
        return .init(frameID: frame.id, width: frame.width, height: frame.height, candidates: candidates,
            elapsedMS: Int(time.seconds * 1_000 + time.attoseconds / 1_000_000_000_000_000), excludedCandidates: excluded, adjustedCandidates: adjusted)
    }
}
