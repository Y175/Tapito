import Foundation

enum AppError: LocalizedError, Equatable {
    case invalid(String), unavailable(String), protocolViolation(String), stopped, timeout, unknownOutcome
    /// A local, unsent input needs visual inspection; the valid OCR frame can still be reused.
    case observationRequired(String)
    /// A fresh local comparison found a changed target; no input was dispatched.
    case screenChanged(String)
    /// Screen-service preparation failed before capture/input; the task must not keep restarting it.
    case screenCaptureUnavailable(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let s), .unavailable(let s), .protocolViolation(let s), .observationRequired(let s), .screenChanged(let s), .screenCaptureUnavailable(let s): return s
        case .stopped: return "已停止"
        case .timeout: return "桥接超时，已断开；没有自动重发动作"
        case .unknownOutcome: return "动作结果未知；未自动重发。"
        }
    }
}
