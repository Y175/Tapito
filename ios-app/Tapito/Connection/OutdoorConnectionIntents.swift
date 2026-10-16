import AppIntents
import Foundation
import TapitoConnectionKit

/// First template step, before changing radios. Errors here can safely stop the shortcut.
struct PrepareOutdoorConnectionIntent: AppIntent {
    static let title: LocalizedStringResource = "准备 Tapito 户外连接"
    static let description = IntentDescription("启动已授权的 Tapito 内置 VPN；已有连接时返回 ready，无需切换飞行模式。")
    static var openAppWhenRun: Bool { false }
    static var supportedModes: IntentModes { .background }
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        return .result(value: try await DeviceConnectionServices.shared.outdoor.prepare())
    }
}

/// Errors are returned as data so Shortcuts can restore airplane mode before displaying a failure.
struct ConnectOutdoorOfflineIntent: AppIntent {
    static let title: LocalizedStringResource = "建立 Tapito 离线连接"
    static var openAppWhenRun: Bool { false }
    static var supportedModes: IntentModes { .background }
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Parameter(title: "初始化编号") var ticket: String
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let id = UUID(uuidString: ticket) else {
            return .result(value: "无效的初始化编号；请重新添加 Tapito 户外初始化快捷指令")
        }
        let result = await DeviceConnectionServices.shared.outdoor.connectOffline(ticket: id)
        let data = try JSONEncoder().encode(result)
        return .result(value: String(decoding: data, as: UTF8.self))
    }
}

/// Runs only after airplane mode is off. Does not open Tapito, record audio, or submit an agent task.
struct FinishOutdoorConnectionIntent: AppIntent {
    static let title: LocalizedStringResource = "检查 Tapito 户外连接"
    static var openAppWhenRun: Bool { false }
    static var supportedModes: IntentModes { .background }
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Parameter(title: "离线连接回执") var receipt: String
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        do {
            let result = try JSONDecoder().decode(OfflineConnectionReceipt.self, from: Data(receipt.utf8))
            try await DeviceConnectionServices.shared.outdoor.finishAfterNetworkRestored(result)
            return .result(value: "Tapito 操控连接已就绪，可以开始语音任务")
        } catch {
            BackgroundExecutionTrace.record("connection.outdoorFailed domain=\((error as NSError).domain) code=\((error as NSError).code)")
            return .result(value: "Tapito 初始化未完成：\(error.localizedDescription)。请确认飞行模式已关闭。")
        }
    }
}
