#if DEBUG
import ActivityKit
import SwiftUI
import WidgetKit

/// A diagnostic-only control; the normal voice control remains unchanged.
struct IslandPresentationProbeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.y175.tapito.island-presentation-probe") {
            ControlWidgetButton(action: StartIslandPresentationProbeIntent()) {
                Label("Tapito 展开验证", systemImage: "rectangle.expand.vertical")
            }
        }
        .displayName("Tapito 展开验证")
        .description("仅验证灵动岛展开，不录音、不执行任务。")
    }
}

/// Static content isolates presentation from recording, progress updates and layout height.
struct IslandPresentationProbeWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: IslandPresentationProbeAttributes.self) { context in
            ProbeContent(id: context.attributes.probeID).padding()
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    Text("Tapito 展开验证").font(.headline).foregroundStyle(.cyan)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProbeContent(id: context.attributes.probeID)
                }
            } compactLeading: {
                Image(systemName: "testtube.2").foregroundStyle(.cyan)
            } compactTrailing: {
                Text("测试").foregroundStyle(.cyan)
            } minimal: {
                Image(systemName: "testtube.2").foregroundStyle(.cyan)
            }
            .keylineTint(.cyan)
        }
    }
}

private struct ProbeContent: View {
    let id: UUID
    var body: some View {
        VStack(spacing: 8) {
            Text("仅验证展示 · 不录音").font(.caption).foregroundStyle(.white)
            Button(intent: EndIslandPresentationProbeIntent(probeID: id)) {
                Label("关闭测试", systemImage: "xmark.circle.fill")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }.tint(.cyan)
        }
    }
}
#endif
