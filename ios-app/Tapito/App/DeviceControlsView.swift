import SwiftUI

/// Presents the VPN connection controls independently of Agent and conversation UI.
struct DeviceControlsView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            DeviceConnectionSettingsView()
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        }
    }
}
