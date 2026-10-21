import Foundation

protocol DeviceBridge: Sendable {
    func supportsBackgroundExecution(tool: String) async -> Bool
    func approvalContext(imageID: String) async throws -> String
    func acceptApproval(imageID: String) async throws
    func authorizeTaskInput(imageID: String) async throws
    func screenshot() async throws -> FrameImage
    func tap(x: Int, y: Int, imageID: String) async throws
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws
    func installedApplications() async throws -> Data
    func systemActionContext() async throws -> String
    func authorizeSystemAction(authorizationID: String, taskScoped: Bool) async throws
    func systemAction(name: String, text: String, arguments: [String], imageID: String) async throws
    func bringApplicationToForeground(bundleID: String) async throws -> Bool
    func cancelTransport()
    func stop() async
}

extension DeviceBridge {
    func bringApplicationToForeground(bundleID: String) async throws -> Bool { false }
    func systemActionContext() async throws -> String { throw AppError.unavailable("当前通道不支持独立系统操作") }
    func authorizeSystemAction(authorizationID: String, taskScoped: Bool) async throws { throw AppError.unavailable("当前通道不支持独立系统操作") }
    func installedApplications() async throws -> Data { throw AppError.unavailable("当前通道不支持查询 App") }
    func systemAction(name: String, text: String, arguments: [String], imageID: String) async throws { throw AppError.unavailable("当前通道不支持此操作") }
    func cancelTransport() {}
    func supportsBackgroundExecution(tool: String) async -> Bool { false }
    func approvalContext(imageID: String) async throws -> String { "foreground-only" }
    func acceptApproval(imageID: String) async throws {}
    func authorizeTaskInput(imageID: String) async throws {
        throw AppError.unavailable("当前输入通道不支持任务内自动授权")
    }
}

struct UnavailableBridge: DeviceBridge {
    static let screenshotMessage = "设备未连接。请在设置 → 手机操控 → 连接与验证中建立 VPN 回环连接。"
    func screenshot() async throws -> FrameImage { throw AppError.unavailable(Self.screenshotMessage) }
    func tap(x: Int, y: Int, imageID: String) async throws { throw AppError.unavailable("设备未连接") }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws { throw AppError.unavailable("设备未连接") }
    func stop() async {}
}
