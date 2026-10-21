// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct DeviceConnectionSettingsView: View {
    @State private var flow = PairingFlow.shared
    @State private var showingTouchTest = false
    @State private var localAddress = PairingFlow.shared.vpnConfiguration.localAddress
    @State private var peerAddress = PairingFlow.shared.vpnConfiguration.peerAddress
    @State private var error: String?
    private enum AddressField: Hashable { case local, peer }
    @FocusState private var editing: AddressField?
    var body: some View {
        Form {
            ConnectionSetupSection()
            vpnConfigurationSection
            PairingSection { showingTouchTest = true }
        }
            .navigationTitle("VPN 回环控制")
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $showingTouchTest) {
                TouchVerificationView(flow: PairingFlow.shared)
            }
            .toolbar {
                ToolbarItem(id: "vpnLoopbackSave", placement: .confirmationAction) {
                    if changed {
                        Button("保存", action: save)
                            .accessibilityIdentifier("saveVPNLoopbackConfiguration")
                            .disabled(!flow.canChangeConfiguration)
                    }
                }
            }
            .task { PairingFlow.shared.resume() }
    }
    private var changed: Bool {
        localAddress != flow.vpnConfiguration.localAddress || peerAddress != flow.vpnConfiguration.peerAddress
    }
    private var vpnConfigurationSection: some View {
        Section {
            addressRow("接口地址", text: $localAddress,
                defaultAddress: VPNLoopbackConfiguration.defaults.localAddress,
                candidates: [VPNLoopbackConfiguration.defaults.localAddress, "198.18.0.1"],
                field: .local, identifier: "vpnLoopbackInterfaceAddress")
            addressRow("对端地址", text: $peerAddress,
                defaultAddress: VPNLoopbackConfiguration.defaults.peerAddress,
                candidates: [VPNLoopbackConfiguration.defaults.peerAddress],
                field: .peer, identifier: "vpnLoopbackPeerAddress")
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        } footer: {
            Text("配对仅建立授权。内置 VPN 启用后会在连接时自动启动；外部 VPN 需自行开启并匹配地址。无 Wi-Fi 时可运行户外初始化快捷指令。修改地址后需重新配置内置 VPN。")
        }
        .keyboardType(.numbersAndPunctuation)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.done)
        .disabled(!flow.canChangeConfiguration)
        .onSubmit(save)
    }
    private func addressRow(_ title: String, text: Binding<String>, defaultAddress: String,
                            candidates: [String], field: AddressField, identifier: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(defaultAddress, text: text)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(identifier)
                    .focused($editing, equals: field)
                Menu {
                    ForEach(candidates, id: \.self) { address in
                        Button(address) {
                            text.wrappedValue = address
                            error = nil
                            editing = nil
                        }
                    }
                    Divider()
                    Button("自定义") { editing = field }
                        .accessibilityIdentifier(identifier + "Custom")
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title + "选项")
                .accessibilityIdentifier(identifier + "Presets")
            }
        }
    }
    private func save() {
        do {
            try flow.saveVPNConfiguration(localAddress: localAddress, peerAddress: peerAddress)
            localAddress = flow.vpnConfiguration.localAddress
            peerAddress = flow.vpnConfiguration.peerAddress
            error = nil; editing = nil
        } catch let failure as NCMControlError {
            if case .unavailable(let message) = failure { error = message }
        } catch {
            self.error = "请输入不同的有效 IPv4 地址"
        }
    }
}
