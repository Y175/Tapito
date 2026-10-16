import SwiftUI
import TapitoConnectionKit

/// A replaceable presentation adapter. Connection ordering and lifecycle live in TapitoConnectionKit.
struct ConnectionSetupSection: View {
    @ObservedObject private var services = DeviceConnectionServices.shared
    @ObservedObject private var vpn = DeviceConnectionServices.shared.vpn
    @State private var busy = false
    @State private var failure: String?
    @Environment(\.openURL) private var openURL
    var body: some View {
        Section {
            LabeledContent("本机回环", value: vpn.enabled ? "Tapito 内置 VPN" : "外部 VPN")
            Button(vpn.enabled ? "重新配置内置 VPN" : "启用 Tapito 内置 VPN") {
                perform { try await services.enableEmbeddedVPN() }
            }.disabled(busy || !PairingFlow.shared.canChangeRoute)
            if vpn.enabled {
                Button("改用外部 VPN") { perform { try await services.useExternalVPN() } }
                    .disabled(busy || !PairingFlow.shared.canChangeRoute)
            }
            if let shortcut = Bundle.main.url(forResource: "Tapito 户外初始化", withExtension: "shortcut", subdirectory: "ConnectionResources") {
                ShareLink(item: shortcut, preview: SharePreview("Tapito 户外初始化")) {
                    Label("添加户外初始化快捷指令", systemImage: "square.and.arrow.up")
                }
            } else {
                Text("安装包缺少户外快捷指令，请更新 Tapito。").foregroundStyle(.red)
            }
            Button("运行户外初始化") {
                var components = URLComponents()
                components.scheme = "shortcuts"; components.host = "run-shortcut"
                components.queryItems = [URLQueryItem(name: "name", value: "Tapito 户外初始化")]
                guard let url = components.url else { failure = "无法构造快捷指令入口"; return }
                openURL(url) { accepted in
                    if !accepted { failure = "无法打开快捷指令，请确认已安装系统快捷指令 App" }
                }
            }.disabled(!vpn.enabled || busy || !PairingFlow.shared.canChangeRoute)
            if services.outdoorPhase != .idle { Text(phaseText).font(.footnote) }
            if PairingFlow.shared.connectionBootstrapActive {
                Button("取消初始化", role: .destructive) {
                    services.outdoor.cancel()
                    failure = "已取消初始化；请确认飞行模式已关闭。"
                }
            }
            if busy { ProgressView() }
            if let failure { Text(failure).font(.footnote).foregroundStyle(.red) }
        } header: { Text("Tapito 连接准备") } footer: {
            Text("内置 VPN 只处理本机操控数据。首次需允许添加 VPN 配置，可能替换当前 VPN。户外快捷指令需先添加，运行时保持手机解锁：先启动 VPN，再离线建链，最后恢复网络。中途手动停止快捷指令或系统中断时，请自行关闭飞行模式。")
        }
    }
    private var phaseText: String {
        switch services.outdoorPhase {
        case .idle: return ""
        case .startingVPN: return "正在启动本机 VPN"
        case .awaitingOffline: return "等待快捷指令切换离线状态"
        case .connecting: return "正在建立手机操控连接"
        case .awaitingNetwork: return "等待快捷指令恢复网络"
        case .checking: return "正在检查恢复后的连接"
        case .ready: return "操控连接已就绪"
        case .failed: return "初始化未完成，请查看快捷指令返回的原因"
        }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true; failure = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await operation() } catch { failure = error.localizedDescription }
        }
    }
}
